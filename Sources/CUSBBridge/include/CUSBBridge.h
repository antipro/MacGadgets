#ifndef CUSBBRIDGE_H
#define CUSBBRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t location_id;
    uint16_t vendor_id;
    uint16_t product_id;
    uint8_t interface_number;
    uint8_t interface_class;
    uint8_t interface_subclass;
    uint8_t interface_protocol;
    char manufacturer[256];
    char product[256];
    char serial_number[256];
    char interface_name[256];
    bool is_mtp_candidate;
} CUSBDeviceCandidate;

typedef enum {
    CUSB_OK = 0,
    CUSB_ERR_NOT_FOUND = -1,
    CUSB_ERR_BUSY = -2,
    CUSB_ERR_NO_ENDPOINTS = -3,
    CUSB_ERR_IO = -4,
    CUSB_ERR_TIMEOUT = -5,
    CUSB_ERR_DISCONNECTED = -6,
    CUSB_ERR_INVALID_ARG = -7
} CUSBStatus;

typedef struct CUSBHandleOpaque *CUSBHandle;

/// Enumerate currently connected USB devices that look like MTP/PTP candidates.
/// Returns the number of candidates written (up to max_count), or negative on error.
int32_t cusb_enumerate_mtp_candidates(CUSBDeviceCandidate *out_candidates, int32_t max_count);

/// Open the MTP interface for the USB device matching `location_id` and `interface_number`.
/// Returns CUSB_OK on success and populates `out_handle`.
CUSBStatus cusb_open(
    uint32_t location_id,
    uint8_t interface_number,
    CUSBHandle *out_handle,
    uint16_t *out_bulk_in_max_packet,
    uint16_t *out_bulk_out_max_packet,
    int32_t *out_io_return
);

/// Write `length` bytes to the Bulk-Out pipe.
CUSBStatus cusb_bulk_write(
    CUSBHandle handle,
    const void *data,
    uint32_t length,
    uint32_t timeout_ms,
    int32_t *out_io_return
);

/// Read up to `*in_out_length` bytes from the Bulk-In pipe.
CUSBStatus cusb_bulk_read(
    CUSBHandle handle,
    void *buffer,
    uint32_t *in_out_length,
    uint32_t timeout_ms,
    int32_t *out_io_return
);

/// Clear stall condition on Bulk-In (`direction_in = true`) or Bulk-Out (`false`).
CUSBStatus cusb_clear_stall(CUSBHandle handle, bool direction_in);

/// Close and release the USB handle.
void cusb_close(CUSBHandle handle);

/// Returns true if a device at `location_id` is currently present and registered in IORegistry.
bool cusb_is_device_present(uint32_t location_id);

/// Resets the USB device (and re-enumerates when needed) to recover from a stalled
/// MTP endpoint. Returns true when a recovery action was issued.
bool cusb_reset_device(uint32_t location_id, bool reenumerate, int32_t *out_io_return);

// MARK: - mDNS Host Alias

typedef struct CMDNSHandleOpaque *CMDNSHandle;

/// Publishes an mDNS A record so `<label>.local` resolves to `ipv4_network_order`
/// (for example 127.0.0.1). Needed so Finder lists the NFS mount under a friendly
/// server name in its "Locations" section instead of a bare loopback address.
/// Returns NULL on failure and writes a DNSServiceErrorType to `out_err` when provided.
CMDNSHandle cmdns_register_host(const char *label, uint32_t ipv4_network_order, int32_t *out_err);

/// Removes the mDNS A record and releases all resources.
void cmdns_unregister(CMDNSHandle handle);

/// Returns true when the alias has been published without a name conflict.
bool cmdns_is_registered(CMDNSHandle handle);

#ifdef __cplusplus
}
#endif

#endif // CUSBBRIDGE_H
