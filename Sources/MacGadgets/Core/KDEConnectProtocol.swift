import Foundation

enum KDEConnectPacketType {
    static let identity = "kdeconnect.identity"
    static let pair = "kdeconnect.pair"
    static let clipboard = "kdeconnect.clipboard"
    static let clipboardConnect = "kdeconnect.clipboard.connect"
    static let shareRequest = "kdeconnect.share.request"
}

enum KDEConnectConstants {
    static let protocolVersion = 7
    static let udpPortRange: ClosedRange<UInt16> = 1714...1764
    static let defaultPort: UInt16 = 1716
    static let transferPortRange: ClosedRange<UInt16> = 1739...1764

    static let supportedCapabilities: [String] = [
        KDEConnectPacketType.clipboard,
        KDEConnectPacketType.clipboardConnect,
        KDEConnectPacketType.shareRequest
    ]
}

enum KDEConnectProtocolError: Error, LocalizedError {
    case invalidJSON
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Invalid KDE Connect JSON packet"
        case .missingField(let field):
            return "Missing required field '\(field)' in KDE Connect packet"
        }
    }
}

struct KDEConnectPacket {
    let id: Int64
    let type: String
    let body: [String: Any]
    let payloadSize: Int64?
    let payloadTransferInfo: [String: Any]?

    init(
        id: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        type: String,
        body: [String: Any] = [:],
        payloadSize: Int64? = nil,
        payloadTransferInfo: [String: Any]? = nil
    ) {
        self.id = id
        self.type = type
        self.body = body
        self.payloadSize = payloadSize
        self.payloadTransferInfo = payloadTransferInfo
    }

    func encode() throws -> Data {
        var dict: [String: Any] = [
            "id": id,
            "type": type,
            "body": body
        ]
        if let payloadSize {
            dict["payloadSize"] = payloadSize
        }
        if let payloadTransferInfo {
            dict["payloadTransferInfo"] = payloadTransferInfo
        }
        var data = try JSONSerialization.data(withJSONObject: dict, options: [])
        data.append(0x0A) // '\n'
        return data
    }

    static func decode(fromLineData data: Data) throws -> KDEConnectPacket {
        guard let obj = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw KDEConnectProtocolError.invalidJSON
        }
        guard let type = obj["type"] as? String, !type.isEmpty else {
            throw KDEConnectProtocolError.missingField("type")
        }
        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let body = (obj["body"] as? [String: Any]) ?? [:]
        let payloadSize = (obj["payloadSize"] as? NSNumber)?.int64Value
        let payloadTransferInfo = obj["payloadTransferInfo"] as? [String: Any]
        return KDEConnectPacket(
            id: id,
            type: type,
            body: body,
            payloadSize: payloadSize,
            payloadTransferInfo: payloadTransferInfo
        )
    }

    // MARK: - Typed Accessors

    var deviceId: String? { body["deviceId"] as? String }
    var deviceName: String? { body["deviceName"] as? String }
    var deviceType: String? { body["deviceType"] as? String }
    var protocolVersion: Int? { (body["protocolVersion"] as? NSNumber)?.intValue }
    var tcpPort: UInt16? {
        guard let num = (body["tcpPort"] as? NSNumber)?.intValue, num > 0, num <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(num)
    }

    var pairFlag: Bool? { body["pair"] as? Bool }
    var pairTimestamp: Int64? { (body["timestamp"] as? NSNumber)?.int64Value }

    var clipboardContent: String? { body["content"] as? String }
    var clipboardTimestamp: Int64? { (body["timestamp"] as? NSNumber)?.int64Value }

    var shareFilename: String? { body["filename"] as? String }
    var shareURL: String? { body["url"] as? String }
    var shareText: String? { body["text"] as? String }
    var transferPort: UInt16? {
        guard let num = (payloadTransferInfo?["port"] as? NSNumber)?.intValue, num > 0, num <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(num)
    }

    // MARK: - Packet Builders

    static func identity(
        deviceId: String,
        deviceName: String,
        deviceType: String = "desktop",
        tcpPort: UInt16?
    ) -> KDEConnectPacket {
        var body: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": deviceName,
            "deviceType": deviceType,
            "protocolVersion": KDEConnectConstants.protocolVersion,
            "incomingCapabilities": KDEConnectConstants.supportedCapabilities,
            "outgoingCapabilities": KDEConnectConstants.supportedCapabilities
        ]
        if let tcpPort {
            body["tcpPort"] = Int(tcpPort)
        }
        return KDEConnectPacket(type: KDEConnectPacketType.identity, body: body)
    }

    static func pair(accept: Bool, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) -> KDEConnectPacket {
        var body: [String: Any] = ["pair": accept]
        if accept {
            body["timestamp"] = timestamp
        }
        return KDEConnectPacket(type: KDEConnectPacketType.pair, body: body)
    }

    static func clipboard(content: String) -> KDEConnectPacket {
        KDEConnectPacket(
            type: KDEConnectPacketType.clipboard,
            body: ["content": content]
        )
    }

    static func clipboardConnect(
        content: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> KDEConnectPacket {
        KDEConnectPacket(
            type: KDEConnectPacketType.clipboardConnect,
            body: [
                "content": content,
                "timestamp": timestamp
            ]
        )
    }

    static func shareFile(
        filename: String,
        size: Int64,
        port: UInt16,
        numberOfFiles: Int = 1,
        totalPayloadSize: Int64? = nil
    ) -> KDEConnectPacket {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return KDEConnectPacket(
            type: KDEConnectPacketType.shareRequest,
            body: [
                "filename": filename,
                "numberOfFiles": numberOfFiles,
                "totalPayloadSize": totalPayloadSize ?? size,
                "creationTime": nowMs,
                "lastModified": nowMs
            ],
            payloadSize: size,
            payloadTransferInfo: ["port": Int(port)]
        )
    }
}

/// Accumulates stream chunks and splits out `\n`-terminated JSON lines.
struct KDEConnectLineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if line.last == 0x0D { // strip optional '\r'
                line.removeLast()
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    var bufferedByteCount: Int { buffer.count }
}

struct KDEConnectTrustedDevice: Codable, Equatable {
    let deviceId: String
    var deviceName: String
    var deviceType: String
    let certificateDER: Data
    let fingerprintHex: String
    let pairedAt: Date
}

final class KDEConnectIdentityStore {
    private enum Keys {
        static let deviceId = "KDEConnect.localDeviceId"
        static let trustedDevices = "KDEConnect.trustedDevices"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var localDeviceId: String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = defaults.string(forKey: Keys.deviceId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(created, forKey: Keys.deviceId)
        return created
    }

    func trustedDevices() -> [String: KDEConnectTrustedDevice] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Keys.trustedDevices),
              let decoded = try? JSONDecoder().decode([String: KDEConnectTrustedDevice].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func trustedDevice(for deviceId: String) -> KDEConnectTrustedDevice? {
        trustedDevices()[deviceId]
    }

    func saveTrustedDevice(_ device: KDEConnectTrustedDevice) {
        lock.lock()
        defer { lock.unlock() }
        var map = (defaults.data(forKey: Keys.trustedDevices)
            .flatMap { try? JSONDecoder().decode([String: KDEConnectTrustedDevice].self, from: $0) }) ?? [:]
        map[device.deviceId] = device
        if let encoded = try? JSONEncoder().encode(map) {
            defaults.set(encoded, forKey: Keys.trustedDevices)
        }
    }

    func removeTrustedDevice(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = (defaults.data(forKey: Keys.trustedDevices)
            .flatMap { try? JSONDecoder().decode([String: KDEConnectTrustedDevice].self, from: $0) }) ?? [:]
        map.removeValue(forKey: deviceId)
        if let encoded = try? JSONEncoder().encode(map) {
            defaults.set(encoded, forKey: Keys.trustedDevices)
        }
    }
}
