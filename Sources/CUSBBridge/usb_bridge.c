#include "CUSBBridge.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>

struct CUSBHandleOpaque {
    IOUSBDeviceInterface500 **device;
    IOUSBInterfaceInterface300 **interface;
    UInt8 bulk_in_pipe;
    UInt8 bulk_out_pipe;
    UInt16 bulk_in_max_packet;
    UInt16 bulk_out_max_packet;
    uint32_t location_id;
};

static void copy_cfstring_prop(io_service_t service, CFStringRef key, char *dst, size_t dst_size) {
    if (!dst || dst_size == 0) return;
    dst[0] = '\0';
    CFTypeRef prop = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!prop) return;
    if (CFGetTypeID(prop) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)prop, dst, (CFIndex)dst_size, kCFStringEncodingUTF8);
    }
    CFRelease(prop);
}

static bool get_uint32_prop(io_service_t service, CFStringRef key, uint32_t *out_val) {
    CFTypeRef prop = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!prop) return false;
    bool ok = false;
    if (CFGetTypeID(prop) == CFNumberGetTypeID()) {
        SInt64 v = 0;
        if (CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt64Type, &v)) {
            *out_val = (uint32_t)v;
            ok = true;
        }
    }
    CFRelease(prop);
    return ok;
}

static bool contains_case_insensitive(const char *haystack, const char *needle) {
    if (!haystack || !needle || needle[0] == '\0') return false;
    return strcasestr(haystack, needle) != NULL;
}

static kern_return_t query_device_interface(io_service_t service, IOUSBDeviceInterface500 ***out_dev) {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    if (kr != KERN_SUCCESS || !plugIn) {
        return kr != KERN_SUCCESS ? kr : kIOReturnError;
    }

    IOUSBDeviceInterface500 **dev = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(
        plugIn,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID500),
        (LPVOID *)&dev
    );
    if (hr != 0 || !dev) {
        hr = (*plugIn)->QueryInterface(
            plugIn,
            CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
            (LPVOID *)&dev
        );
    }
    (*plugIn)->Release(plugIn);

    if (hr != 0 || !dev) {
        return kIOReturnNoDevice;
    }
    *out_dev = dev;
    return KERN_SUCCESS;
}

static kern_return_t query_usb_interface(io_service_t service, IOUSBInterfaceInterface300 ***out_intf) {
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service,
        kIOUSBInterfaceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugIn,
        &score
    );
    if (kr != KERN_SUCCESS || !plugIn) {
        return kr != KERN_SUCCESS ? kr : kIOReturnError;
    }

    IOUSBInterfaceInterface300 **intf = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(
        plugIn,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
        (LPVOID *)&intf
    );
    (*plugIn)->Release(plugIn);

    if (hr != 0 || !intf) {
        return kIOReturnNoDevice;
    }
    *out_intf = intf;
    return KERN_SUCCESS;
}

static void read_usb_string_descriptor(IOUSBDeviceInterface500 **dev, UInt8 index, char *dst, size_t dst_size) {
    if (!dev || index == 0 || !dst || dst_size == 0) return;
    if (dst[0] != '\0') return;

    UInt8 buf[256];
    memset(buf, 0, sizeof(buf));
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
    req.bRequest = kUSBRqGetDescriptor;
    req.wValue = (UInt16)((kUSBStringDesc << 8) | index);
    req.wIndex = 0x0409; // en-US
    req.wLength = sizeof(buf);
    req.pData = buf;
    req.noDataTimeout = 1000;
    req.completionTimeout = 1000;

    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    if (kr != kIOReturnSuccess || req.wLenDone < 2) return;

    UInt8 len = buf[0];
    if (len > req.wLenDone) len = (UInt8)req.wLenDone;
    if (len <= 2) return;

    CFStringRef str = CFStringCreateWithBytes(
        kCFAllocatorDefault,
        buf + 2,
        len - 2,
        kCFStringEncodingUTF16LE,
        false
    );
    if (str) {
        CFStringGetCString(str, dst, (CFIndex)dst_size, kCFStringEncodingUTF8);
        CFRelease(str);
    }
}

static bool device_has_msft_mtp_descriptor(IOUSBDeviceInterface500 **dev) {
    if (!dev) return false;
    UInt8 buf[64];
    memset(buf, 0, sizeof(buf));
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
    req.bRequest = kUSBRqGetDescriptor;
    req.wValue = (UInt16)((kUSBStringDesc << 8) | 0xEE);
    req.wIndex = 0x0000;
    req.wLength = sizeof(buf);
    req.pData = buf;
    req.noDataTimeout = 800;
    req.completionTimeout = 800;

    IOReturn kr = (*dev)->DeviceRequestTO(dev, &req);
    if (kr != kIOReturnSuccess || req.wLenDone < 18) return false;

    // Microsoft OS String Descriptor starts with length 0x12, type 0x03, "MSFT100" in UTF-16LE
    if (buf[2] == 'M' && buf[4] == 'S' && buf[6] == 'F' && buf[8] == 'T') {
        UInt8 vendorCode = buf[16];
        UInt8 extBuf[64];
        memset(extBuf, 0, sizeof(extBuf));
        IOUSBDevRequestTO extReq;
        memset(&extReq, 0, sizeof(extReq));
        extReq.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
        extReq.bRequest = vendorCode;
        extReq.wValue = 0;
        extReq.wIndex = 4; // Extended Compat ID
        extReq.wLength = sizeof(extBuf);
        extReq.pData = extBuf;
        extReq.noDataTimeout = 800;
        extReq.completionTimeout = 800;

        if ((*dev)->DeviceRequestTO(dev, &extReq) == kIOReturnSuccess && extReq.wLenDone >= 24) {
            if (memcmp(extBuf + 18, "MTP", 3) == 0 || memcmp(extBuf + 18, "PTP", 3) == 0) {
                return true;
            }
        }
    }
    return false;
}

static io_iterator_t create_usb_device_iterator_for_class(const char *class_name) {
    io_iterator_t iter = 0;
    CFMutableDictionaryRef matching = IOServiceMatching(class_name);
    if (matching) {
        if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS) {
            return iter;
        }
    }
    return 0;
}

static int32_t enumerate_with_class(
    const char *class_name,
    CUSBDeviceCandidate *out_candidates,
    int32_t max_count
) {
    io_iterator_t dev_iter = create_usb_device_iterator_for_class(class_name);
    if (!dev_iter) return 0;

    int32_t count = 0;
    io_service_t dev_service = 0;

    while ((dev_service = IOIteratorNext(dev_iter)) != 0 && count < max_count) {
        IOUSBDeviceInterface500 **dev = NULL;
        if (query_device_interface(dev_service, &dev) == KERN_SUCCESS && dev) {
            UInt16 vid = 0, pid = 0;
            UInt32 loc = 0;
            (*dev)->GetDeviceVendor(dev, &vid);
            (*dev)->GetDeviceProduct(dev, &pid);
            (*dev)->GetLocationID(dev, &loc);

            // Skip Apple hubs/internal devices immediately
            if (vid != 0x05AC) {
                char manufacturer[256] = {0};
                char product[256] = {0};
                char serial[256] = {0};
                copy_cfstring_prop(dev_service, CFSTR("USB Vendor Name"), manufacturer, sizeof(manufacturer));
                if (manufacturer[0] == '\0') {
                    copy_cfstring_prop(dev_service, CFSTR("kUSBVendorString"), manufacturer, sizeof(manufacturer));
                }
                copy_cfstring_prop(dev_service, CFSTR("USB Product Name"), product, sizeof(product));
                if (product[0] == '\0') {
                    copy_cfstring_prop(dev_service, CFSTR("kUSBProductString"), product, sizeof(product));
                }
                copy_cfstring_prop(dev_service, CFSTR("USB Serial Number"), serial, sizeof(serial));
                if (serial[0] == '\0') {
                    copy_cfstring_prop(dev_service, CFSTR("kUSBSerialNumberString"), serial, sizeof(serial));
                }

                // Ensure device is configured if possible (best-effort)
                UInt8 currentConfig = 0;
                if ((*dev)->GetConfiguration(dev, &currentConfig) == kIOReturnSuccess && currentConfig == 0) {
                    IOUSBConfigurationDescriptorPtr cfgDesc = NULL;
                    if ((*dev)->GetConfigurationDescriptorPtr(dev, 0, &cfgDesc) == kIOReturnSuccess && cfgDesc) {
                        if ((*dev)->USBDeviceOpen(dev) == kIOReturnSuccess) {
                            (*dev)->SetConfiguration(dev, cfgDesc->bConfigurationValue);
                            (*dev)->USBDeviceClose(dev);
                        }
                    }
                }

                IOUSBFindInterfaceRequest req;
                req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
                req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
                req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
                req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

                io_iterator_t if_iter = 0;
                if ((*dev)->CreateInterfaceIterator(dev, &req, &if_iter) == kIOReturnSuccess && if_iter) {
                    io_service_t if_service = 0;
                    bool checked_msft = false;
                    bool has_msft_mtp = false;

                    while ((if_service = IOIteratorNext(if_iter)) != 0 && count < max_count) {
                        IOUSBInterfaceInterface300 **intf = NULL;
                        if (query_usb_interface(if_service, &intf) == KERN_SUCCESS && intf) {
                            UInt8 cls = 0, sub = 0, proto = 0, if_num = 0, eps = 0;
                            (*intf)->GetInterfaceClass(intf, &cls);
                            (*intf)->GetInterfaceSubClass(intf, &sub);
                            (*intf)->GetInterfaceProtocol(intf, &proto);
                            (*intf)->GetInterfaceNumber(intf, &if_num);
                            (*intf)->GetNumEndpoints(intf, &eps);

                            char if_name[256] = {0};
                            copy_cfstring_prop(if_service, CFSTR("kUSBStringDescriptor"), if_name, sizeof(if_name));
                            if (if_name[0] == '\0') {
                                UInt8 strIdx = 0;
                                if ((*intf)->USBInterfaceGetStringIndex(intf, &strIdx) == kIOReturnSuccess && strIdx > 0) {
                                    read_usb_string_descriptor(dev, strIdx, if_name, sizeof(if_name));
                                }
                            }

                            bool is_still_image = (cls == 0x06 && sub == 0x01 && proto == 0x01);
                            bool is_mtp_named = (contains_case_insensitive(if_name, "MTP") || contains_case_insensitive(if_name, "PTP"));
                            bool is_vendor_mtp = false;
                            if (!is_still_image && !is_mtp_named && cls == 0xFF && sub == 0xFF && proto == 0x00) {
                                if (!checked_msft) {
                                    checked_msft = true;
                                    has_msft_mtp = device_has_msft_mtp_descriptor(dev);
                                }
                                is_vendor_mtp = has_msft_mtp;
                            }

                            if (is_still_image || is_mtp_named || is_vendor_mtp) {
                                CUSBDeviceCandidate cand;
                                memset(&cand, 0, sizeof(cand));
                                cand.location_id = loc;
                                cand.vendor_id = vid;
                                cand.product_id = pid;
                                cand.interface_number = if_num;
                                cand.interface_class = cls;
                                cand.interface_subclass = sub;
                                cand.interface_protocol = proto;
                                snprintf(cand.manufacturer, sizeof(cand.manufacturer), "%s", manufacturer);
                                snprintf(cand.product, sizeof(cand.product), "%s", product);
                                snprintf(cand.serial_number, sizeof(cand.serial_number), "%s", serial);
                                snprintf(cand.interface_name, sizeof(cand.interface_name), "%s", if_name);
                                cand.is_mtp_candidate = true;
                                out_candidates[count++] = cand;
                            }

                            (*intf)->Release(intf);
                        }
                        IOObjectRelease(if_service);
                    }
                    IOObjectRelease(if_iter);
                }
            }
            (*dev)->Release(dev);
        }
        IOObjectRelease(dev_service);
    }

    IOObjectRelease(dev_iter);
    return count;
}

int32_t cusb_enumerate_mtp_candidates(CUSBDeviceCandidate *out_candidates, int32_t max_count) {
    if (!out_candidates || max_count <= 0) return CUSB_ERR_INVALID_ARG;
    int32_t count = enumerate_with_class(kIOUSBDeviceClassName, out_candidates, max_count);
    if (count == 0) {
        count = enumerate_with_class("IOUSBHostDevice", out_candidates, max_count);
    }
    return count;
}

static CUSBStatus open_with_class(
    const char *class_name,
    uint32_t location_id,
    uint8_t interface_number,
    bool seize,
    CUSBHandle *out_handle,
    uint16_t *out_bulk_in_max_packet,
    uint16_t *out_bulk_out_max_packet,
    int32_t *out_io_return
) {
    io_iterator_t dev_iter = create_usb_device_iterator_for_class(class_name);
    if (!dev_iter) return CUSB_ERR_NOT_FOUND;

    CUSBStatus result = CUSB_ERR_NOT_FOUND;
    io_service_t dev_service = 0;

    while ((dev_service = IOIteratorNext(dev_iter)) != 0) {
        uint32_t loc = 0;
        bool has_loc = get_uint32_prop(dev_service, CFSTR("locationID"), &loc);
        IOUSBDeviceInterface500 **dev = NULL;

        if (query_device_interface(dev_service, &dev) == KERN_SUCCESS && dev) {
            if (!has_loc) {
                UInt32 devLoc = 0;
                if ((*dev)->GetLocationID(dev, &devLoc) == kIOReturnSuccess) {
                    loc = devLoc;
                    has_loc = true;
                }
            }

            if (has_loc && loc == location_id) {
                IOUSBFindInterfaceRequest req;
                req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
                req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
                req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
                req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

                io_iterator_t if_iter = 0;
                if ((*dev)->CreateInterfaceIterator(dev, &req, &if_iter) == kIOReturnSuccess && if_iter) {
                    io_service_t if_service = 0;
                    while ((if_service = IOIteratorNext(if_iter)) != 0) {
                        IOUSBInterfaceInterface300 **intf = NULL;
                        if (query_usb_interface(if_service, &intf) == KERN_SUCCESS && intf) {
                            UInt8 if_num = 0;
                            (*intf)->GetInterfaceNumber(intf, &if_num);

                            if (if_num == interface_number) {
                                IOReturn kr = seize
                                    ? (*intf)->USBInterfaceOpenSeize(intf)
                                    : (*intf)->USBInterfaceOpen(intf);
                                if (kr == kIOReturnExclusiveAccess) {
                                    // Do not seize silently; report busy so caller can inform user or release ptpcamerad
                                    if (out_io_return) *out_io_return = kr;
                                    (*intf)->Release(intf);
                                    IOObjectRelease(if_service);
                                    result = CUSB_ERR_BUSY;
                                    break;
                                }
                                if (kr != kIOReturnSuccess) {
                                    if (out_io_return) *out_io_return = kr;
                                    (*intf)->Release(intf);
                                    IOObjectRelease(if_service);
                                    result = CUSB_ERR_IO;
                                    break;
                                }

                                UInt8 num_endpoints = 0;
                                (*intf)->GetNumEndpoints(intf, &num_endpoints);

                                UInt8 bulk_in_pipe = 0;
                                UInt8 bulk_out_pipe = 0;
                                UInt16 bulk_in_mps = 512;
                                UInt16 bulk_out_mps = 512;

                                // Pipe index 0 is control endpoint; data endpoints are 1..num_endpoints
                                for (UInt8 pipe = 1; pipe <= num_endpoints; pipe++) {
                                    UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
                                    UInt16 maxPacketSize = 0;
                                    if ((*intf)->GetPipeProperties(intf, pipe, &direction, &number, &transferType, &maxPacketSize, &interval) == kIOReturnSuccess) {
                                        if (transferType == kUSBBulk) {
                                            if (direction == kUSBIn && bulk_in_pipe == 0) {
                                                bulk_in_pipe = pipe;
                                                bulk_in_mps = maxPacketSize > 0 ? maxPacketSize : 512;
                                            } else if (direction == kUSBOut && bulk_out_pipe == 0) {
                                                bulk_out_pipe = pipe;
                                                bulk_out_mps = maxPacketSize > 0 ? maxPacketSize : 512;
                                            }
                                        }
                                    }
                                }

                                if (bulk_in_pipe == 0 || bulk_out_pipe == 0) {
                                    (*intf)->USBInterfaceClose(intf);
                                    (*intf)->Release(intf);
                                    IOObjectRelease(if_service);
                                    result = CUSB_ERR_NO_ENDPOINTS;
                                    break;
                                }

                                struct CUSBHandleOpaque *handle = (struct CUSBHandleOpaque *)calloc(1, sizeof(struct CUSBHandleOpaque));
                                handle->device = dev;
                                handle->interface = intf;
                                handle->bulk_in_pipe = bulk_in_pipe;
                                handle->bulk_out_pipe = bulk_out_pipe;
                                handle->bulk_in_max_packet = bulk_in_mps;
                                handle->bulk_out_max_packet = bulk_out_mps;
                                handle->location_id = location_id;

                                if (out_bulk_in_max_packet) *out_bulk_in_max_packet = bulk_in_mps;
                                if (out_bulk_out_max_packet) *out_bulk_out_max_packet = bulk_out_mps;
                                *out_handle = handle;

                                IOObjectRelease(if_service);
                                IOObjectRelease(if_iter);
                                IOObjectRelease(dev_service);
                                IOObjectRelease(dev_iter);
                                return CUSB_OK;
                            }
                            (*intf)->Release(intf);
                        }
                        IOObjectRelease(if_service);
                    }
                    IOObjectRelease(if_iter);
                }
                (*dev)->Release(dev);
                IOObjectRelease(dev_service);
                break;
            }
            (*dev)->Release(dev);
        }
        IOObjectRelease(dev_service);
    }

    IOObjectRelease(dev_iter);
    return result;
}

CUSBStatus cusb_open(
    uint32_t location_id,
    uint8_t interface_number,
    bool seize,
    CUSBHandle *out_handle,
    uint16_t *out_bulk_in_max_packet,
    uint16_t *out_bulk_out_max_packet,
    int32_t *out_io_return
) {
    if (!out_handle) return CUSB_ERR_INVALID_ARG;
    *out_handle = NULL;
    if (out_io_return) *out_io_return = 0;

    CUSBStatus status = open_with_class(
        kIOUSBDeviceClassName,
        location_id,
        interface_number,
        seize,
        out_handle,
        out_bulk_in_max_packet,
        out_bulk_out_max_packet,
        out_io_return
    );
    if (status == CUSB_ERR_NOT_FOUND) {
        status = open_with_class(
            "IOUSBHostDevice",
            location_id,
            interface_number,
            seize,
            out_handle,
            out_bulk_in_max_packet,
            out_bulk_out_max_packet,
            out_io_return
        );
    }
    return status;
}

static CUSBStatus map_io_return(IOReturn kr) {
    if (kr == kIOReturnSuccess) return CUSB_OK;
    if (kr == kIOUSBTransactionTimeout || kr == kIOReturnTimeout) return CUSB_ERR_TIMEOUT;
    if (kr == kIOReturnNoDevice || kr == kIOReturnNotResponding) return CUSB_ERR_DISCONNECTED;
    if (kr == kIOReturnExclusiveAccess) return CUSB_ERR_BUSY;
    return CUSB_ERR_IO;
}

CUSBStatus cusb_bulk_write(
    CUSBHandle handle,
    const void *data,
    uint32_t length,
    uint32_t timeout_ms,
    int32_t *out_io_return
) {
    if (!handle || !handle->interface) return CUSB_ERR_INVALID_ARG;
    if (length > 0 && !data) return CUSB_ERR_INVALID_ARG;

    IOReturn kr = (*handle->interface)->WritePipeTO(
        handle->interface,
        handle->bulk_out_pipe,
        (void *)data,
        (UInt32)length,
        timeout_ms,
        timeout_ms
    );
    if (out_io_return) *out_io_return = kr;
    return map_io_return(kr);
}

CUSBStatus cusb_bulk_read(
    CUSBHandle handle,
    void *buffer,
    uint32_t *in_out_length,
    uint32_t timeout_ms,
    int32_t *out_io_return
) {
    if (!handle || !handle->interface || !buffer || !in_out_length) return CUSB_ERR_INVALID_ARG;

    UInt32 size = *in_out_length;
    IOReturn kr = (*handle->interface)->ReadPipeTO(
        handle->interface,
        handle->bulk_in_pipe,
        buffer,
        &size,
        timeout_ms,
        timeout_ms
    );
    *in_out_length = size;
    if (out_io_return) *out_io_return = kr;
    return map_io_return(kr);
}

CUSBStatus cusb_clear_stall(CUSBHandle handle, bool direction_in) {
    if (!handle || !handle->interface) return CUSB_ERR_INVALID_ARG;
    UInt8 pipe = direction_in ? handle->bulk_in_pipe : handle->bulk_out_pipe;
    IOReturn kr = (*handle->interface)->ClearPipeStallBothEnds(handle->interface, pipe);
    return map_io_return(kr);
}

void cusb_close(CUSBHandle handle) {
    if (!handle) return;
    if (handle->interface) {
        (*handle->interface)->USBInterfaceClose(handle->interface);
        (*handle->interface)->Release(handle->interface);
        handle->interface = NULL;
    }
    if (handle->device) {
        (*handle->device)->Release(handle->device);
        handle->device = NULL;
    }
    free(handle);
}

static bool is_device_present_with_class(const char *class_name, uint32_t location_id) {
    io_iterator_t dev_iter = create_usb_device_iterator_for_class(class_name);
    if (!dev_iter) return false;
    bool found = false;
    io_service_t dev_service = 0;
    while ((dev_service = IOIteratorNext(dev_iter)) != 0) {
        uint32_t loc = 0;
        if (get_uint32_prop(dev_service, CFSTR("locationID"), &loc) && loc == location_id) {
            found = true;
            IOObjectRelease(dev_service);
            break;
        }
        IOObjectRelease(dev_service);
    }
    IOObjectRelease(dev_iter);
    return found;
}

static io_service_t find_device_service_for_reset(uint32_t location_id) {
    const char *classes[2] = { kIOUSBDeviceClassName, "IOUSBHostDevice" };
    for (int ci = 0; ci < 2; ci++) {
        io_iterator_t iter = create_usb_device_iterator_for_class(classes[ci]);
        if (!iter) continue;
        io_service_t service = 0;
        while ((service = IOIteratorNext(iter)) != 0) {
            uint32_t loc = 0;
            bool hasLoc = get_uint32_prop(service, CFSTR("locationID"), &loc);
            if (!hasLoc) {
                IOUSBDeviceInterface500 **dev = NULL;
                if (query_device_interface(service, &dev) == KERN_SUCCESS && dev) {
                    UInt32 devLoc = 0;
                    if ((*dev)->GetLocationID(dev, &devLoc) == kIOReturnSuccess) {
                        loc = devLoc;
                        hasLoc = true;
                    }
                    (*dev)->Release(dev);
                }
            }
            if (hasLoc && loc == location_id) {
                IOObjectRelease(iter);
                return service;
            }
            IOObjectRelease(service);
        }
        IOObjectRelease(iter);
    }
    return 0;
}

bool cusb_reset_device(uint32_t location_id, bool reenumerate, int32_t *out_io_return) {
    if (out_io_return) *out_io_return = 0;
    io_service_t service = find_device_service_for_reset(location_id);
    if (!service) return false;

    IOUSBDeviceInterface500 **dev = NULL;
    kern_return_t kr = query_device_interface(service, &dev);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !dev) return false;

    bool didSomething = false;
    IOReturn openResult = (*dev)->USBDeviceOpen(dev);
    if (openResult == kIOReturnSuccess) {
        IOReturn resetResult = (*dev)->ResetDevice(dev);
        if (resetResult == kIOReturnSuccess) {
            didSomething = true;
        } else if (out_io_return) {
            *out_io_return = resetResult;
        }
        (*dev)->USBDeviceClose(dev);
    } else if (out_io_return) {
        *out_io_return = openResult;
    }

    if (reenumerate || !didSomething) {
        IOReturn reResult = (*dev)->USBDeviceReEnumerate(dev, 0);
        if (reResult == kIOReturnSuccess) {
            didSomething = true;
        } else if (out_io_return) {
            *out_io_return = reResult;
        }
    }

    (*dev)->Release(dev);
    return didSomething;
}

bool cusb_is_device_present(uint32_t location_id) {
    if (is_device_present_with_class(kIOUSBDeviceClassName, location_id)) {
        return true;
    }
    return is_device_present_with_class("IOUSBHostDevice", location_id);
}

// MARK: - mDNS Host Alias
//
// The dns_sd entry points live inside the dyld shared cache (libsystem_dnssd) and
// are not linkable with plain Command Line Tools, so resolve them dynamically.

#include <dns_sd.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/poll.h>
#include <netinet/in.h>

typedef DNSServiceErrorType (*FnCreateConnection)(DNSServiceRef *sdRef);
typedef DNSServiceErrorType (*FnRegisterRecord)(
    DNSServiceRef sdRef, DNSRecordRef *RecordRef, DNSServiceFlags flags,
    uint32_t interfaceIndex, const char *fullname, uint16_t rrtype, uint16_t rrclass,
    uint16_t rdlen, const void *rdata, uint32_t ttl,
    DNSServiceRegisterRecordReply callBack, void *context);
typedef int (*FnRefSockFD)(DNSServiceRef sdRef);
typedef DNSServiceErrorType (*FnProcessResult)(DNSServiceRef sdRef);
typedef void (*FnRefDeallocate)(DNSServiceRef sdRef);

static FnCreateConnection p_DNSServiceCreateConnection;
static FnRegisterRecord p_DNSServiceRegisterRecord;
static FnRefSockFD p_DNSServiceRefSockFD;
static FnProcessResult p_DNSServiceProcessResult;
static FnRefDeallocate p_DNSServiceRefDeallocate;
static pthread_once_t mdns_once = PTHREAD_ONCE_INIT;
static int mdns_symbols_ok = 0;

static void mdns_load_symbols(void) {
    p_DNSServiceCreateConnection = (FnCreateConnection)dlsym(RTLD_DEFAULT, "DNSServiceCreateConnection");
    p_DNSServiceRegisterRecord = (FnRegisterRecord)dlsym(RTLD_DEFAULT, "DNSServiceRegisterRecord");
    p_DNSServiceRefSockFD = (FnRefSockFD)dlsym(RTLD_DEFAULT, "DNSServiceRefSockFD");
    p_DNSServiceProcessResult = (FnProcessResult)dlsym(RTLD_DEFAULT, "DNSServiceProcessResult");
    p_DNSServiceRefDeallocate = (FnRefDeallocate)dlsym(RTLD_DEFAULT, "DNSServiceRefDeallocate");
    mdns_symbols_ok = p_DNSServiceCreateConnection && p_DNSServiceRegisterRecord &&
        p_DNSServiceRefSockFD && p_DNSServiceProcessResult && p_DNSServiceRefDeallocate;
}

struct CMDNSHandleOpaque {
    DNSServiceRef connection;
    DNSRecordRef record;
    pthread_t thread;
    int fd;
    volatile int running;
    volatile int registered;
    volatile int failed;
};

static void cmdns_record_callback(
    DNSServiceRef sdRef,
    DNSRecordRef RecordRef,
    DNSServiceFlags flags,
    DNSServiceErrorType errorCode,
    void *context
) {
    (void)sdRef;
    (void)RecordRef;
    (void)flags;
    struct CMDNSHandleOpaque *handle = (struct CMDNSHandleOpaque *)context;
    if (!handle) return;
    if (errorCode == kDNSServiceErr_NoError) {
        handle->registered = 1;
    } else {
        handle->failed = errorCode;
        handle->registered = 0;
    }
}

static void *cmdns_thread_main(void *arg) {
    struct CMDNSHandleOpaque *handle = (struct CMDNSHandleOpaque *)arg;
    while (handle->running) {
        struct pollfd pfd;
        pfd.fd = handle->fd;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, 200);
        if (pr > 0) {
            DNSServiceErrorType err = p_DNSServiceProcessResult(handle->connection);
            if (err != kDNSServiceErr_NoError) {
                handle->failed = err;
                break;
            }
        }
    }
    return NULL;
}

CMDNSHandle cmdns_register_host(const char *label, uint32_t ipv4_network_order, int32_t *out_err) {
    if (!label || label[0] == '\0') {
        if (out_err) *out_err = kDNSServiceErr_BadParam;
        return NULL;
    }

    pthread_once(&mdns_once, mdns_load_symbols);
    if (!mdns_symbols_ok) {
        if (out_err) *out_err = kDNSServiceErr_Unsupported;
        return NULL;
    }

    struct CMDNSHandleOpaque *handle = (struct CMDNSHandleOpaque *)calloc(1, sizeof(struct CMDNSHandleOpaque));
    if (!handle) {
        if (out_err) *out_err = kDNSServiceErr_NoMemory;
        return NULL;
    }

    DNSServiceErrorType err = p_DNSServiceCreateConnection(&handle->connection);
    if (err != kDNSServiceErr_NoError) {
        free(handle);
        if (out_err) *out_err = err;
        return NULL;
    }

    char fullname[256];
    snprintf(fullname, sizeof(fullname), "%s.local.", label);

    err = p_DNSServiceRegisterRecord(
        handle->connection,
        &handle->record,
        kDNSServiceFlagsUnique,
        kDNSServiceInterfaceIndexAny,
        fullname,
        kDNSServiceType_A,
        kDNSServiceClass_IN,
        4,
        &ipv4_network_order,
        0,
        cmdns_record_callback,
        handle
    );

    if (err != kDNSServiceErr_NoError) {
        p_DNSServiceRefDeallocate(handle->connection);
        free(handle);
        if (out_err) *out_err = err;
        return NULL;
    }

    handle->fd = p_DNSServiceRefSockFD(handle->connection);
    if (handle->fd < 0) {
        p_DNSServiceRefDeallocate(handle->connection);
        free(handle);
        if (out_err) *out_err = kDNSServiceErr_BadReference;
        return NULL;
    }

    handle->running = 1;
    if (pthread_create(&handle->thread, NULL, cmdns_thread_main, handle) != 0) {
        handle->running = 0;
        p_DNSServiceRefDeallocate(handle->connection);
        free(handle);
        if (out_err) *out_err = kDNSServiceErr_Unknown;
        return NULL;
    }

    for (int i = 0; i < 40 && !handle->registered && !handle->failed; i++) {
        usleep(25000);
    }

    if (out_err) *out_err = handle->failed;
    return handle;
}

void cmdns_unregister(CMDNSHandle handle) {
    if (!handle) return;
    handle->running = 0;
    if (handle->thread) {
        pthread_join(handle->thread, NULL);
    }
    if (handle->connection && p_DNSServiceRefDeallocate) {
        p_DNSServiceRefDeallocate(handle->connection);
        handle->connection = NULL;
    }
    free(handle);
}

bool cmdns_is_registered(CMDNSHandle handle) {
    if (!handle) return false;
    return handle->registered && !handle->failed;
}
