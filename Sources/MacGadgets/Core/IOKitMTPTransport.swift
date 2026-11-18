import Foundation
import IOKit
import IOKit.usb
import CUSBBridge

struct USBMTPDeviceCandidate: Equatable {
    let locationID: UInt32
    let vendorID: UInt16
    let productID: UInt16
    let interfaceNumber: UInt8
    let manufacturer: String
    let product: String
    let serialNumber: String

    var fallbackDisplayName: String {
        let p = product.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { return p }
        let m = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return "\(m) Android" }
        return "Android Phone"
    }
}

final class IOKitMTPTransport: MTPUSBTransport {
    private var handle: CUSBHandle?
    let maxPacketSizeIn: Int
    let maxPacketSizeOut: Int
    let locationID: UInt32

    private init(
        handle: CUSBHandle,
        locationID: UInt32,
        maxPacketSizeIn: Int,
        maxPacketSizeOut: Int
    ) {
        self.handle = handle
        self.locationID = locationID
        self.maxPacketSizeIn = maxPacketSizeIn
        self.maxPacketSizeOut = maxPacketSizeOut
    }

    deinit {
        close()
    }

    static func enumerateCandidates() -> [USBMTPDeviceCandidate] {
        var buffer = Array(repeating: CUSBDeviceCandidate(), count: 16)
        let count = buffer.withUnsafeMutableBufferPointer { ptr in
            cusb_enumerate_mtp_candidates(ptr.baseAddress, Int32(ptr.count))
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { c in
            USBMTPDeviceCandidate(
                locationID: c.location_id,
                vendorID: c.vendor_id,
                productID: c.product_id,
                interfaceNumber: c.interface_number,
                manufacturer: withUnsafeBytes(of: c.manufacturer) { Self.cString(from: $0) },
                product: withUnsafeBytes(of: c.product) { Self.cString(from: $0) },
                serialNumber: withUnsafeBytes(of: c.serial_number) { Self.cString(from: $0) }
            )
        }
    }

    static func open(candidate: USBMTPDeviceCandidate, seize: Bool = false) throws -> IOKitMTPTransport {
        var handle: CUSBHandle?
        var mpsIn: UInt16 = 512
        var mpsOut: UInt16 = 512
        var ioReturn: Int32 = 0

        let status = cusb_open(
            candidate.locationID,
            candidate.interfaceNumber,
            seize,
            &handle,
            &mpsIn,
            &mpsOut,
            &ioReturn
        )
        switch status {
        case CUSB_OK:
            guard let handle else { throw MTPTransportError.deviceNotFound }
            return IOKitMTPTransport(
                handle: handle,
                locationID: candidate.locationID,
                maxPacketSizeIn: max(64, Int(mpsIn)),
                maxPacketSizeOut: max(64, Int(mpsOut))
            )
        case CUSB_ERR_NOT_FOUND:
            throw MTPTransportError.deviceNotFound
        case CUSB_ERR_BUSY:
            throw MTPTransportError.deviceBusy
        case CUSB_ERR_NO_ENDPOINTS:
            throw MTPTransportError.noEndpoints
        case CUSB_ERR_DISCONNECTED:
            throw MTPTransportError.disconnected
        case CUSB_ERR_TIMEOUT:
            throw MTPTransportError.timeout
        default:
            throw MTPTransportError.ioError(ioReturn)
        }
    }

    static func isDevicePresent(locationID: UInt32) -> Bool {
        cusb_is_device_present(locationID)
    }

    /// Resets the device to clear a stalled MTP endpoint (falls back to re-enumeration).
    @discardableResult
    static func resetDevice(locationID: UInt32, reenumerate: Bool = false) -> Bool {
        var ioReturn: Int32 = 0
        return cusb_reset_device(locationID, reenumerate, &ioReturn)
    }

    func bulkWrite(_ data: Data, timeoutMs: UInt32) throws {
        guard let handle else { throw MTPTransportError.disconnected }
        var ioReturn: Int32 = 0
        let status: CUSBStatus
        if data.isEmpty {
            status = cusb_bulk_write(handle, nil, 0, timeoutMs, &ioReturn)
        } else {
            status = data.withUnsafeBytes { ptr in
                cusb_bulk_write(handle, ptr.baseAddress, UInt32(data.count), timeoutMs, &ioReturn)
            }
        }
        try throwIfError(status, ioReturn: ioReturn)
    }

    func bulkRead(maxLength: Int, timeoutMs: UInt32) throws -> Data {
        guard let handle else { throw MTPTransportError.disconnected }
        var buf = Data(count: maxLength)
        var length = UInt32(maxLength)
        var ioReturn: Int32 = 0
        let status = buf.withUnsafeMutableBytes { ptr in
            cusb_bulk_read(handle, ptr.baseAddress, &length, timeoutMs, &ioReturn)
        }
        try throwIfError(status, ioReturn: ioReturn)
        buf.count = Int(length)
        return buf
    }

    func clearStall(directionIn: Bool) throws {
        guard let handle else { throw MTPTransportError.disconnected }
        let status = cusb_clear_stall(handle, directionIn)
        try throwIfError(status, ioReturn: 0)
    }

    func close() {
        if let handle {
            cusb_close(handle)
            self.handle = nil
        }
    }

    private func throwIfError(_ status: CUSBStatus, ioReturn: Int32) throws {
        switch status {
        case CUSB_OK: return
        case CUSB_ERR_BUSY: throw MTPTransportError.deviceBusy
        case CUSB_ERR_DISCONNECTED: throw MTPTransportError.disconnected
        case CUSB_ERR_TIMEOUT: throw MTPTransportError.timeout
        case CUSB_ERR_NOT_FOUND: throw MTPTransportError.deviceNotFound
        default: throw MTPTransportError.ioError(ioReturn)
        }
    }

    private static func cString(from rawBuffer: UnsafeRawBufferPointer) -> String {
        guard let base = rawBuffer.baseAddress else { return "" }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var count = 0
        while count < rawBuffer.count && bytes[count] != 0 {
            count += 1
        }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) ?? ""
    }
}

// MARK: - USB Hotplug Monitor (IOKit Notification)

final class USBHotplugMonitor {
    private let queue = DispatchQueue(label: "com.macgadgets.usb-hotplug")
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let onTopologyChanged: () -> Void
    private var debounceWorkItem: DispatchWorkItem?

    init(onTopologyChanged: @escaping () -> Void) {
        self.onTopologyChanged = onTopologyChanged
    }

    deinit {
        stop()
    }

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let classes = [kIOUSBDeviceClassName, "IOUSBHostDevice"]
        let types = [kIOFirstMatchNotification, kIOTerminatedNotification]

        for cls in classes {
            for notifType in types {
                guard let matching = IOServiceMatching(cls) else { continue }
                var iter: io_iterator_t = 0
                let kr = IOServiceAddMatchingNotification(
                    port,
                    notifType,
                    matching,
                    { refcon, iterator in
                        // Drain iterator to arm future notifications
                        while case let obj = IOIteratorNext(iterator), obj != 0 {
                            IOObjectRelease(obj)
                        }
                        guard let refcon else { return }
                        let monitor = Unmanaged<USBHotplugMonitor>.fromOpaque(refcon).takeUnretainedValue()
                        monitor.scheduleNotify()
                    },
                    selfPtr,
                    &iter
                )
                if kr == KERN_SUCCESS && iter != 0 {
                    // Drain initial matches to arm notifications
                    while case let obj = IOIteratorNext(iter), obj != 0 {
                        IOObjectRelease(obj)
                    }
                    iterators.append(iter)
                }
            }
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        for iter in iterators {
            IOObjectRelease(iter)
        }
        iterators.removeAll()
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onTopologyChanged()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.45, execute: item)
    }
}
