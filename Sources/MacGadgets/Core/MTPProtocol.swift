import Foundation

// MARK: - Transport Abstraction

enum MTPTransportError: Error, LocalizedError {
    case deviceNotFound
    case deviceBusy
    case noEndpoints
    case disconnected
    case timeout
    case ioError(Int32)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "未检测到可用的 MTP 设备"
        case .deviceBusy: return "USB MTP 接口被其他程序占用"
        case .noEndpoints: return "未找到有效的 USB 批量传输端点"
        case .disconnected: return "USB 设备已断开连接"
        case .timeout: return "USB 传输超时，请确认手机处于解锁并允许文件传输状态"
        case .ioError(let code): return "USB 通信错误 (0x\(String(code, radix: 16)))"
        }
    }
}

protocol MTPUSBTransport: AnyObject {
    var maxPacketSizeIn: Int { get }
    var maxPacketSizeOut: Int { get }
    func bulkWrite(_ data: Data, timeoutMs: UInt32) throws
    func bulkRead(maxLength: Int, timeoutMs: UInt32) throws -> Data
    func clearStall(directionIn: Bool) throws
    func close()
}

// MARK: - MTP Protocol Constants & Models

enum MTPContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

enum MTPOperationCode: UInt16 {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getNumObjects = 0x1006
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case deleteObject = 0x100B
    case sendObjectInfo = 0x100C
    case sendObject = 0x100D
    case moveObject = 0x1019
    case copyObject = 0x101A
    case getPartialObject = 0x101B
    case getPartialObject64 = 0x95C1
    case getObjectPropValue = 0x9803
    case setObjectPropValue = 0x9804
}

enum MTPResponseCode: UInt16 {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case invalidTransactionID = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case storeFull = 0x200C
    case objectWriteProtected = 0x200D
    case storeReadOnly = 0x200E
    case accessDenied = 0x200F
    case storeNotAvailable = 0x2013
    case invalidParentObject = 0x201A
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E
    case transactionCancelled = 0x201F
    case invalidObjectPropCode = 0xA801
    case invalidObjectPropValue = 0xA803
    case objectPropNotSupported = 0xA80A
}

enum MTPObjectFormat: UInt16 {
    case undefined = 0x3000
    case association = 0x3001
}

enum MTPObjectProperty: UInt16 {
    case objectSize = 0xDC04
    case objectFileName = 0xDC07
}

enum MTPError: Error, LocalizedError {
    case invalidContainer
    case unexpectedContainerType(UInt16)
    case protocolError(UInt16)
    case invalidDataset(String)
    case unsupportedOperation(String)
    case fileIO(String)

    var errorDescription: String? {
        switch self {
        case .invalidContainer: return "MTP 数据包格式无效"
        case .unexpectedContainerType(let t): return "收到意外的 MTP 容器类型: \(t)"
        case .protocolError(let code):
            let hex = String(format: "0x%04X", code)
            switch MTPResponseCode(rawValue: code) {
            case .accessDenied: return "手机拒绝访问（\(hex)），请确认手机已解锁并允许文件传输"
            case .storeFull: return "手机存储空间已满（\(hex)）"
            case .storeReadOnly, .objectWriteProtected: return "目标目录只读或受保护（\(hex)）"
            case .storeNotAvailable: return "手机存储不可用，请确认文件传输模式已开启（\(hex)）"
            case .invalidObjectHandle: return "文件或目录句柄已失效（\(hex)）"
            case .operationNotSupported: return "设备不支持此 MTP 操作（\(hex)）"
            default: return "MTP 协议错误: \(hex)"
            }
        case .invalidDataset(let msg): return "MTP 数据解析失败: \(msg)"
        case .unsupportedOperation(let msg): return "不支持的操作: \(msg)"
        case .fileIO(let msg): return "本地文件读写失败: \(msg)"
        }
    }
}

struct MTPDeviceInfo: Equatable {
    let manufacturer: String
    let model: String
    let deviceVersion: String
    let serialNumber: String
    let operationsSupported: Set<UInt16>

    var displayName: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            return trimmedModel
        }
        let trimmedMfg = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedMfg.isEmpty ? "Android Phone" : trimmedMfg
    }
}

struct MTPStorageInfo: Equatable {
    let storageID: UInt32
    let storageType: UInt16
    let filesystemType: UInt16
    let accessCapability: UInt16
    let maxCapacity: UInt64
    let freeSpaceInBytes: UInt64
    let storageDescription: String
    let volumeLabel: String

    var displayName: String {
        let desc = storageDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { return desc }
        let label = volumeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        return "存储 \(String(format: "0x%08X", storageID))"
    }

    var isReadOnly: Bool {
        accessCapability == 1
    }
}

struct MTPObjectInfo: Equatable {
    let handle: UInt32
    let storageID: UInt32
    let objectFormat: UInt16
    let protectionStatus: UInt16
    let size: UInt64
    let parentHandle: UInt32
    let associationType: UInt16
    let filename: String
    let dateCreated: Date?
    let dateModified: Date?

    var isFolder: Bool {
        objectFormat == MTPObjectFormat.association.rawValue
    }
}

// MARK: - Client Protocol (for Mockability)

protocol MTPClientProtocol: AnyObject {
    func getDeviceInfo() throws -> MTPDeviceInfo
    func getStorageIDs() throws -> [UInt32]
    func getStorageInfo(storageID: UInt32) throws -> MTPStorageInfo
    func getObjectHandles(storageID: UInt32, parentHandle: UInt32) throws -> [UInt32]
    func getObjectInfo(handle: UInt32) throws -> MTPObjectInfo
    func getObject(handle: UInt32) throws -> Data
    func getObjectToFile(handle: UInt32, destinationURL: URL) throws
    func getPartialObject(handle: UInt32, offset: UInt64, maxBytes: UInt32) throws -> Data?
    func createFolder(storageID: UInt32, parentHandle: UInt32, name: String) throws -> UInt32
    func uploadFile(storageID: UInt32, parentHandle: UInt32, filename: String, fileURL: URL, fileSize: UInt64) throws -> UInt32
    func deleteObject(handle: UInt32) throws
    func moveObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws
    func renameObject(handle: UInt32, newName: String) throws
    func copyObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws -> UInt32
    /// Best-effort recovery after a stalled transaction (clears endpoint stalls, drops the session).
    func resetSession()
    func close()
}

// MARK: - Binary Helpers

struct MTPBinaryReader {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { max(0, data.count - offset) }

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw MTPError.invalidDataset("EOF reading UInt8") }
        let val = data[data.startIndex + offset]
        offset += 1
        return val
    }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw MTPError.invalidDataset("EOF reading UInt16") }
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        offset += 2
        return b0 | (b1 << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw MTPError.invalidDataset("EOF reading UInt32") }
        let i = data.startIndex + offset
        let val = UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
        offset += 4
        return val
    }

    mutating func readUInt64() throws -> UInt64 {
        let low = UInt64(try readUInt32())
        let high = UInt64(try readUInt32())
        return low | (high << 32)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw MTPError.invalidDataset("EOF skipping \(count) bytes")
        }
        offset += count
    }

    mutating func readUInt16Array() throws -> [UInt16] {
        let count = Int(try readUInt32())
        guard count >= 0, remaining >= count * 2 else {
            throw MTPError.invalidDataset("Invalid UInt16 array length \(count)")
        }
        var result: [UInt16] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readUInt16())
        }
        return result
    }

    mutating func readUInt32Array() throws -> [UInt32] {
        let count = Int(try readUInt32())
        guard count >= 0, remaining >= count * 4 else {
            throw MTPError.invalidDataset("Invalid UInt32 array length \(count)")
        }
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readUInt32())
        }
        return result
    }

    mutating func readMTPString() throws -> String {
        let charCount = Int(try readUInt8())
        if charCount == 0 { return "" }
        let byteCount = charCount * 2
        guard offset + byteCount <= data.count else {
            throw MTPError.invalidDataset("EOF reading MTP string of \(charCount) chars")
        }
        let slice = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + byteCount))
        offset += byteCount

        // Strip trailing UTF-16LE null terminator if present
        var strData = slice
        if strData.count >= 2 && strData[strData.count - 1] == 0 && strData[strData.count - 2] == 0 {
            strData = strData.dropLast(2)
        }
        return String(data: strData, encoding: .utf16LittleEndian) ?? ""
    }
}

struct MTPBinaryWriter {
    private(set) var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    mutating func writeMTPString(_ string: String) {
        if string.isEmpty {
            writeUInt8(0)
            return
        }
        let utf16Units = Array(string.utf16)
        // MTP string count is UInt8 including null terminator (max 255)
        let maxUnits = min(utf16Units.count, 254)
        let countWithNull = UInt8(maxUnits + 1)
        writeUInt8(countWithNull)
        for i in 0..<maxUnits {
            writeUInt16(utf16Units[i])
        }
        writeUInt16(0) // Null terminator
    }
}

enum MTPDateParser {
    private static let formatterBasic: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 15 else { return nil }
        let prefix15 = String(trimmed.prefix(15))
        if trimmed.hasSuffix("Z") {
            let utcFormatter = DateFormatter()
            utcFormatter.locale = Locale(identifier: "en_US_POSIX")
            utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            utcFormatter.dateFormat = "yyyyMMdd'T'HHmmss"
            return utcFormatter.date(from: prefix15)
        }
        return formatterBasic.date(from: prefix15)
    }

    static func format(_ date: Date) -> String {
        formatterBasic.string(from: date)
    }
}

// MARK: - MTP Client

final class MTPClient: MTPClientProtocol {
    static let rootParentHandle: UInt32 = 0xFFFFFFFF

    private let transport: MTPUSBTransport
    private let lock = NSLock()
    private var nextTransactionID: UInt32 = 1
    private var sessionOpen = false
    private var cachedDeviceInfo: MTPDeviceInfo?

    private let commandTimeoutMs: UInt32 = 5000
    // Large uploads over USB 2.0 can legitimately take tens of seconds; a short
    // timeout aborts mid-transfer and leaves the device's MTP stack wedged.
    private let dataTimeoutMs: UInt32 = 120_000
    private let readChunkSize = 65536
    // Android f_mtp uses 16KB USB bulk buffers; matching 16KB and keeping the first
    // packet (12-byte header + 16372 payload) aligned to maxPacketSizeOut prevents
    // mid-stream USB short packets that stall the device.
    private let writeChunkSize = 16384

    private static let debugLoggingEnabled = ProcessInfo.processInfo.environment["MACGADGETS_MTP_LOG"] != nil

    private func debugLog(_ message: @autoclosure () -> String) {
        guard Self.debugLoggingEnabled else { return }
        FileHandle.standardError.write(Data("[mtp] \(message())\n".utf8))
    }

    init(transport: MTPUSBTransport) {
        self.transport = transport
    }

    func openSession() throws {
        try withLock {
            // Query DeviceInfo before or right after opening session
            if cachedDeviceInfo == nil {
                cachedDeviceInfo = try? performGetDeviceInfo(transactionID: 0)
            }
            let resp = try performCommandNoData(
                op: .openSession,
                params: [1],
                explicitTransactionID: 0
            )
            if resp.code == MTPResponseCode.ok.rawValue {
                sessionOpen = true
                nextTransactionID = 1
                if cachedDeviceInfo == nil {
                    cachedDeviceInfo = try? performGetDeviceInfo(transactionID: takeTransactionID())
                }
                return
            }
            if resp.code == MTPResponseCode.sessionAlreadyOpen.rawValue {
                // Close existing stale session and reopen cleanly
                _ = try? performCommandNoData(op: .closeSession, params: [], explicitTransactionID: 1)
                let retry = try performCommandNoData(op: .openSession, params: [1], explicitTransactionID: 0)
                if retry.code == MTPResponseCode.ok.rawValue || retry.code == MTPResponseCode.sessionAlreadyOpen.rawValue {
                    sessionOpen = true
                    nextTransactionID = 1
                    if cachedDeviceInfo == nil {
                        cachedDeviceInfo = try? performGetDeviceInfo(transactionID: takeTransactionID())
                    }
                    return
                }
                throw MTPError.protocolError(retry.code)
            }
            throw MTPError.protocolError(resp.code)
        }
    }

    func getDeviceInfo() throws -> MTPDeviceInfo {
        try withLock {
            if let cachedDeviceInfo { return cachedDeviceInfo }
            let info = try performGetDeviceInfo(transactionID: sessionOpen ? takeTransactionID() : 0)
            cachedDeviceInfo = info
            return info
        }
    }

    func getStorageIDs() throws -> [UInt32] {
        try withLock {
            let result = try performCommandExpectingData(op: .getStorageIDs, params: [])
            var reader = MTPBinaryReader(result.data)
            return try reader.readUInt32Array()
        }
    }

    func getStorageInfo(storageID: UInt32) throws -> MTPStorageInfo {
        try withLock {
            let result = try performCommandExpectingData(op: .getStorageInfo, params: [storageID])
            var reader = MTPBinaryReader(result.data)
            let storageType = try reader.readUInt16()
            let fsType = try reader.readUInt16()
            let accessCap = try reader.readUInt16()
            let maxCap = try reader.readUInt64()
            let freeSpace = try reader.readUInt64()
            _ = try reader.readUInt32() // freeSpaceInImages
            let desc = try reader.readMTPString()
            let label = try reader.readMTPString()
            return MTPStorageInfo(
                storageID: storageID,
                storageType: storageType,
                filesystemType: fsType,
                accessCapability: accessCap,
                maxCapacity: maxCap,
                freeSpaceInBytes: freeSpace,
                storageDescription: desc,
                volumeLabel: label
            )
        }
    }

    func getObjectHandles(storageID: UInt32, parentHandle: UInt32) throws -> [UInt32] {
        try withLock {
            let result = try performCommandExpectingData(
                op: .getObjectHandles,
                params: [storageID, 0x00000000, parentHandle]
            )
            var reader = MTPBinaryReader(result.data)
            return try reader.readUInt32Array()
        }
    }

    func getObjectInfo(handle: UInt32) throws -> MTPObjectInfo {
        try withLock {
            let result = try performCommandExpectingData(op: .getObjectInfo, params: [handle])
            var reader = MTPBinaryReader(result.data)
            let storageID = try reader.readUInt32()
            let format = try reader.readUInt16()
            let protection = try reader.readUInt16()
            let size32 = try reader.readUInt32()
            _ = try reader.readUInt16() // thumbFormat
            _ = try reader.readUInt32() // thumbCompressedSize
            _ = try reader.readUInt32() // thumbPixWidth
            _ = try reader.readUInt32() // thumbPixHeight
            _ = try reader.readUInt32() // imagePixWidth
            _ = try reader.readUInt32() // imagePixHeight
            _ = try reader.readUInt32() // imageBitDepth
            let parentHandle = try reader.readUInt32()
            let assocType = try reader.readUInt16()
            _ = try reader.readUInt32() // assocDesc
            _ = try reader.readUInt32() // sequenceNumber
            let filename = try reader.readMTPString()
            let dateCreatedStr = try reader.readMTPString()
            let dateModifiedStr = try reader.readMTPString()

            var fullSize = UInt64(size32)
            if size32 == 0xFFFFFFFF && format != MTPObjectFormat.association.rawValue {
                if let size64 = try? queryObjectSize64Locked(handle: handle) {
                    fullSize = size64
                }
            }

            return MTPObjectInfo(
                handle: handle,
                storageID: storageID,
                objectFormat: format,
                protectionStatus: protection,
                size: fullSize,
                parentHandle: parentHandle,
                associationType: assocType,
                filename: filename,
                dateCreated: MTPDateParser.parse(dateCreatedStr),
                dateModified: MTPDateParser.parse(dateModifiedStr)
            )
        }
    }

    func getObject(handle: UInt32) throws -> Data {
        try withLock {
            let result = try performCommandExpectingData(op: .getObject, params: [handle])
            return result.data
        }
    }

    func getObjectToFile(handle: UInt32, destinationURL: URL) throws {
        try withLock {
            _ = FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let fh: FileHandle
            do {
                fh = try FileHandle(forWritingTo: destinationURL)
            } catch {
                throw MTPError.fileIO(error.localizedDescription)
            }
            defer { try? fh.close() }

            let txID = takeTransactionID()
            try sendCommandContainer(op: .getObject, transactionID: txID, params: [handle])

            let response = try receiveDataStreamingAndResponse(expectedTransactionID: txID) { chunk in
                try fh.write(contentsOf: chunk)
            }
            guard response.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(response.code)
            }
        }
    }

    func getPartialObject(handle: UInt32, offset: UInt64, maxBytes: UInt32) throws -> Data? {
        try withLock {
            let supported = cachedDeviceInfo?.operationsSupported ?? []
            if offset > UInt64(UInt32.max) {
                guard supported.contains(MTPOperationCode.getPartialObject64.rawValue) else {
                    return nil
                }
                let lo = UInt32(offset & 0xFFFFFFFF)
                let hi = UInt32((offset >> 32) & 0xFFFFFFFF)
                let result = try performCommandExpectingData(
                    op: .getPartialObject64,
                    params: [handle, lo, hi, maxBytes]
                )
                return result.data
            }

            if supported.contains(MTPOperationCode.getPartialObject.rawValue) {
                let result = try performCommandExpectingData(
                    op: .getPartialObject,
                    params: [handle, UInt32(offset), maxBytes]
                )
                return result.data
            }
            if supported.contains(MTPOperationCode.getPartialObject64.rawValue) {
                let result = try performCommandExpectingData(
                    op: .getPartialObject64,
                    params: [handle, UInt32(offset), 0, maxBytes]
                )
                return result.data
            }
            return nil
        }
    }

    func createFolder(storageID: UInt32, parentHandle: UInt32, name: String) throws -> UInt32 {
        try withLock {
            let infoData = buildObjectInfoDataset(
                storageID: storageID,
                parentHandle: parentHandle,
                filename: name,
                size: 0,
                isFolder: true
            )
            let txID = takeTransactionID()
            try sendCommandContainer(op: .sendObjectInfo, transactionID: txID, params: [storageID, parentHandle])
            try sendDataContainer(op: .sendObjectInfo, transactionID: txID, payload: infoData)
            let resp = try receiveResponseContainer(expectedTransactionID: txID)
            guard resp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(resp.code)
            }
            guard resp.params.count >= 3 else {
                throw MTPError.invalidDataset("SendObjectInfo response missing handle")
            }
            return resp.params[2]
        }
    }

    func uploadFile(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        fileURL: URL,
        fileSize: UInt64
    ) throws -> UInt32 {
        try withLock {
            let infoData = buildObjectInfoDataset(
                storageID: storageID,
                parentHandle: parentHandle,
                filename: filename,
                size: fileSize,
                isFolder: false
            )
            let txID1 = takeTransactionID()
            try sendCommandContainer(op: .sendObjectInfo, transactionID: txID1, params: [storageID, parentHandle])
            try sendDataContainer(op: .sendObjectInfo, transactionID: txID1, payload: infoData)
            let infoResp = try receiveResponseContainer(expectedTransactionID: txID1)
            guard infoResp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(infoResp.code)
            }
            guard infoResp.params.count >= 3 else {
                throw MTPError.invalidDataset("SendObjectInfo response missing handle")
            }
            let newHandle = infoResp.params[2]

            let txID2 = takeTransactionID()
            try sendCommandContainer(op: .sendObject, transactionID: txID2, params: [])
            do {
                try sendObjectDataFromFile(transactionID: txID2, fileURL: fileURL, fileSize: fileSize)
                let objResp = try receiveResponseContainer(expectedTransactionID: txID2)
                guard objResp.code == MTPResponseCode.ok.rawValue else {
                    throw MTPError.protocolError(objResp.code)
                }
            } catch {
                // A partially sent object leaves the device waiting for data: reset the
                // session so later operations do not inherit a wedged endpoint.
                resetSessionLocked()
                throw error
            }
            return newHandle
        }
    }

    func deleteObject(handle: UInt32) throws {
        try withLock {
            let resp = try performCommandNoData(op: .deleteObject, params: [handle, 0])
            guard resp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(resp.code)
            }
        }
    }

    func moveObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws {
        try withLock {
            let supported = cachedDeviceInfo?.operationsSupported ?? []
            guard supported.contains(MTPOperationCode.moveObject.rawValue) else {
                throw MTPError.unsupportedOperation("MoveObject")
            }
            let resp = try performCommandNoData(
                op: .moveObject,
                params: [handle, targetStorageID, targetParentHandle]
            )
            guard resp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(resp.code)
            }
        }
    }

    func renameObject(handle: UInt32, newName: String) throws {
        try withLock {
            let supported = cachedDeviceInfo?.operationsSupported ?? []
            guard supported.contains(MTPOperationCode.setObjectPropValue.rawValue) else {
                throw MTPError.unsupportedOperation("SetObjectPropValue")
            }
            var writer = MTPBinaryWriter()
            writer.writeMTPString(newName)
            let txID = takeTransactionID()
            try sendCommandContainer(
                op: .setObjectPropValue,
                transactionID: txID,
                params: [handle, UInt32(MTPObjectProperty.objectFileName.rawValue)]
            )
            try sendDataContainer(op: .setObjectPropValue, transactionID: txID, payload: writer.data)
            let resp = try receiveResponseContainer(expectedTransactionID: txID)
            guard resp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(resp.code)
            }
        }
    }

    func copyObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws -> UInt32 {
        try withLock {
            let supported = cachedDeviceInfo?.operationsSupported ?? []
            guard supported.contains(MTPOperationCode.copyObject.rawValue) else {
                throw MTPError.unsupportedOperation("CopyObject")
            }
            let resp = try performCommandNoData(
                op: .copyObject,
                params: [handle, targetStorageID, targetParentHandle]
            )
            guard resp.code == MTPResponseCode.ok.rawValue else {
                throw MTPError.protocolError(resp.code)
            }
            guard let newHandle = resp.params.first else {
                throw MTPError.invalidDataset("CopyObject response missing new handle")
            }
            return newHandle
        }
    }

    /// Best-effort recovery after a stalled or aborted MTP transaction.
    /// Clears endpoint stalls and drops the session so the next operation can
    /// start cleanly instead of leaving the phone's MTP stack wedged.
    func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        _ = try? transport.clearStall(directionIn: true)
        _ = try? transport.clearStall(directionIn: false)
        if sessionOpen {
            _ = try? performCommandNoData(op: .closeSession, params: [])
        }
        sessionOpen = false
        cachedDeviceInfo = nil
        nextTransactionID = 1
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if sessionOpen {
            _ = try? performCommandNoData(op: .closeSession, params: [])
            sessionOpen = false
        }
        transport.close()
    }

    // MARK: - Internal Locked Operations

    private func resetSessionLocked() {
        _ = try? transport.clearStall(directionIn: true)
        _ = try? transport.clearStall(directionIn: false)
        if sessionOpen {
            _ = try? performCommandNoData(op: .closeSession, params: [])
        }
        sessionOpen = false
        cachedDeviceInfo = nil
        nextTransactionID = 1
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func takeTransactionID() -> UInt32 {
        let id = nextTransactionID
        nextTransactionID = nextTransactionID == UInt32.max ? 1 : nextTransactionID + 1
        return id
    }

    private func queryObjectSize64Locked(handle: UInt32) throws -> UInt64 {
        let supported = cachedDeviceInfo?.operationsSupported ?? []
        guard supported.contains(MTPOperationCode.getObjectPropValue.rawValue) else {
            throw MTPError.unsupportedOperation("GetObjectPropValue")
        }
        let result = try performCommandExpectingData(
            op: .getObjectPropValue,
            params: [handle, UInt32(MTPObjectProperty.objectSize.rawValue)]
        )
        var reader = MTPBinaryReader(result.data)
        return try reader.readUInt64()
    }

    private func performGetDeviceInfo(transactionID: UInt32) throws -> MTPDeviceInfo {
        try sendCommandContainer(op: .getDeviceInfo, transactionID: transactionID, params: [])
        let result = try receiveDataAndResponse(expectedTransactionID: transactionID)
        var reader = MTPBinaryReader(result.data)
        _ = try reader.readUInt16() // standardVersion
        _ = try reader.readUInt32() // vendorExtensionID
        _ = try reader.readUInt16() // vendorExtensionVersion
        _ = try reader.readMTPString() // vendorExtensionDesc
        _ = try reader.readUInt16() // functionalMode
        let ops = try reader.readUInt16Array()
        _ = try reader.readUInt16Array() // eventsSupported
        _ = try reader.readUInt16Array() // devicePropertiesSupported
        _ = try reader.readUInt16Array() // captureFormats
        _ = try reader.readUInt16Array() // playbackFormats
        let manufacturer = try reader.readMTPString()
        let model = try reader.readMTPString()
        let version = try reader.readMTPString()
        let serial = try reader.readMTPString()

        return MTPDeviceInfo(
            manufacturer: manufacturer,
            model: model,
            deviceVersion: version,
            serialNumber: serial,
            operationsSupported: Set(ops)
        )
    }

    private struct MTPResponse {
        let code: UInt16
        let transactionID: UInt32
        let params: [UInt32]
    }

    private func performCommandNoData(
        op: MTPOperationCode,
        params: [UInt32],
        explicitTransactionID: UInt32? = nil
    ) throws -> MTPResponse {
        let txID = explicitTransactionID ?? takeTransactionID()
        try sendCommandContainer(op: op, transactionID: txID, params: params)
        return try receiveResponseContainer(expectedTransactionID: txID)
    }

    private func performCommandExpectingData(
        op: MTPOperationCode,
        params: [UInt32]
    ) throws -> (data: Data, response: MTPResponse) {
        let txID = takeTransactionID()
        try sendCommandContainer(op: op, transactionID: txID, params: params)
        return try receiveDataAndResponse(expectedTransactionID: txID)
    }

    // MARK: - Container Framing

    private func makeContainerHeader(length: UInt32, type: MTPContainerType, code: UInt16, transactionID: UInt32) -> Data {
        var writer = MTPBinaryWriter()
        writer.writeUInt32(length)
        writer.writeUInt16(type.rawValue)
        writer.writeUInt16(code)
        writer.writeUInt32(transactionID)
        return writer.data
    }

    private func sendCommandContainer(op: MTPOperationCode, transactionID: UInt32, params: [UInt32]) throws {
        var writer = MTPBinaryWriter()
        let totalLength = UInt32(12 + params.count * 4)
        writer.writeUInt32(totalLength)
        writer.writeUInt16(MTPContainerType.command.rawValue)
        writer.writeUInt16(op.rawValue)
        writer.writeUInt32(transactionID)
        for p in params {
            writer.writeUInt32(p)
        }
        try writeWithZLPHandling(writer.data, timeoutMs: commandTimeoutMs)
    }

    private func sendDataContainer(op: MTPOperationCode, transactionID: UInt32, payload: Data) throws {
        var container = makeContainerHeader(
            length: UInt32(12 + payload.count),
            type: .data,
            code: op.rawValue,
            transactionID: transactionID
        )
        container.append(payload)
        try writeWithZLPHandling(container, timeoutMs: dataTimeoutMs)
    }

    private func sendObjectDataFromFile(transactionID: UInt32, fileURL: URL, fileSize: UInt64) throws {
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw MTPError.fileIO(error.localizedDescription)
        }
        defer { try? fh.close() }

        let declaredLength: UInt32 = (fileSize + 12 >= UInt64(UInt32.max)) ? 0xFFFFFFFF : UInt32(fileSize + 12)
        let header = makeContainerHeader(
            length: declaredLength,
            type: .data,
            code: MTPOperationCode.sendObject.rawValue,
            transactionID: transactionID
        )

        // Send exactly `fileSize` bytes, keeping every intermediate bulkWrite call aligned
        // to `writeChunkSize` (a multiple of maxPacketSizeOut) so we never emit a premature
        // USB short packet in the middle of the SendObject data stream.
        var remaining = fileSize
        var totalBytesSent: UInt64 = 0
        var sentHeader = false

        var packet = Data()
        packet.reserveCapacity(writeChunkSize)

        while remaining > 0 {
            let maxPayloadForPacket = sentHeader ? writeChunkSize : max(1, writeChunkSize - header.count)
            let want = Int(min(UInt64(maxPayloadForPacket), remaining))
            let chunk = try fh.read(upToCount: want) ?? Data()

            packet.removeAll(keepingCapacity: true)
            if !sentHeader {
                packet.append(header)
                sentHeader = true
            }
            if chunk.isEmpty {
                packet.append(Data(count: Int(remaining)))
                remaining = 0
            } else {
                packet.append(chunk)
                remaining -= UInt64(chunk.count)
            }

            let chunkStart = Date()
            try transport.bulkWrite(packet, timeoutMs: dataTimeoutMs)
            totalBytesSent += UInt64(packet.count)
            let elapsed = Date().timeIntervalSince(chunkStart)
            if elapsed > 0.5 {
                let mbps = Double(packet.count) / elapsed / 1_048_576
                debugLog(String(format: "bulkWrite %.0fKB in %.2fs (%.2f MB/s)", Double(packet.count) / 1024, elapsed, mbps))
            }
        }

        if !sentHeader && fileSize == 0 {
            try transport.bulkWrite(header, timeoutMs: dataTimeoutMs)
            totalBytesSent = UInt64(header.count)
        }

        // USB bulk ZLP if total bytes is an exact multiple of maxPacketSizeOut
        let mps = max(1, transport.maxPacketSizeOut)
        if totalBytesSent > 0 && (totalBytesSent % UInt64(mps)) == 0 {
            try transport.bulkWrite(Data(), timeoutMs: commandTimeoutMs)
        }
    }

    private func writeWithZLPHandling(_ data: Data, timeoutMs: UInt32) throws {
        try transport.bulkWrite(data, timeoutMs: timeoutMs)
        let mps = max(1, transport.maxPacketSizeOut)
        if !data.isEmpty && (data.count % mps) == 0 {
            try transport.bulkWrite(Data(), timeoutMs: timeoutMs)
        }
    }

    private func receiveDataAndResponse(expectedTransactionID: UInt32) throws -> (data: Data, response: MTPResponse) {
        var buffer = Data()
        let resp = try receiveDataStreamingAndResponse(expectedTransactionID: expectedTransactionID) { chunk in
            buffer.append(chunk)
        }
        guard resp.code == MTPResponseCode.ok.rawValue else {
            throw MTPError.protocolError(resp.code)
        }
        return (buffer, resp)
    }

    private func receiveDataStreamingAndResponse(
        expectedTransactionID: UInt32,
        onDataChunk: (Data) throws -> Void
    ) throws -> MTPResponse {
        // Read first non-empty packet
        let first = try readNonEmptyPacket(timeoutMs: dataTimeoutMs)
        guard first.count >= 12 else { throw MTPError.invalidContainer }

        let containerLen = readLE32(first, at: 0)
        let containerType = readLE16(first, at: 4)
        let code = readLE16(first, at: 6)
        let txID = readLE32(first, at: 8)

        if containerType == MTPContainerType.response.rawValue {
            // No data phase; device returned an immediate response (usually an error)
            let params = parseResponseParams(first)
            return MTPResponse(code: code, transactionID: txID, params: params)
        }

        guard containerType == MTPContainerType.data.rawValue else {
            throw MTPError.unexpectedContainerType(containerType)
        }

        let initialPayload = first.subdata(in: 12..<first.count)
        if !initialPayload.isEmpty {
            try onDataChunk(initialPayload)
        }

        if containerLen == 0xFFFFFFFF {
            // Large >4GB object: read until short packet or ZLP
            while true {
                let chunk = try transport.bulkRead(maxLength: readChunkSize, timeoutMs: dataTimeoutMs)
                if chunk.isEmpty { break }
                try onDataChunk(chunk)
                if chunk.count < readChunkSize {
                    break
                }
            }
        } else {
            var bytesRead = first.count
            let expectedTotal = Int(containerLen)
            while bytesRead < expectedTotal {
                let chunk = try transport.bulkRead(maxLength: readChunkSize, timeoutMs: dataTimeoutMs)
                if chunk.isEmpty {
                    // Unexpected ZLP before container complete
                    throw MTPError.invalidContainer
                }
                if bytesRead + chunk.count > expectedTotal {
                    // Guard against piggybacked response (rare)
                    let dataPart = chunk.prefix(expectedTotal - bytesRead)
                    try onDataChunk(dataPart)
                    let leftover = Data(chunk.dropFirst(expectedTotal - bytesRead))
                    bytesRead = expectedTotal
                    if leftover.count >= 12 {
                        return try parseResponseContainer(leftover)
                    }
                    break
                } else {
                    try onDataChunk(chunk)
                    bytesRead += chunk.count
                }
            }
        }

        let resp = try receiveResponseContainer(expectedTransactionID: expectedTransactionID)
        return resp
    }

    private func receiveResponseContainer(expectedTransactionID: UInt32) throws -> MTPResponse {
        let packet = try readNonEmptyPacket(timeoutMs: commandTimeoutMs)
        return try parseResponseContainer(packet)
    }

    private func parseResponseContainer(_ packet: Data) throws -> MTPResponse {
        guard packet.count >= 12 else { throw MTPError.invalidContainer }
        let containerType = readLE16(packet, at: 4)
        guard containerType == MTPContainerType.response.rawValue else {
            throw MTPError.unexpectedContainerType(containerType)
        }
        let code = readLE16(packet, at: 6)
        let txID = readLE32(packet, at: 8)
        let params = parseResponseParams(packet)
        return MTPResponse(code: code, transactionID: txID, params: params)
    }

    private func parseResponseParams(_ packet: Data) -> [UInt32] {
        var params: [UInt32] = []
        var offset = 12
        while offset + 4 <= packet.count {
            params.append(readLE32(packet, at: offset))
            offset += 4
        }
        return params
    }

    private func readNonEmptyPacket(timeoutMs: UInt32) throws -> Data {
        for _ in 0..<4 {
            let data = try transport.bulkRead(maxLength: readChunkSize, timeoutMs: timeoutMs)
            if !data.isEmpty {
                return data
            }
        }
        throw MTPError.invalidContainer
    }

    private func buildObjectInfoDataset(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        size: UInt64,
        isFolder: Bool
    ) -> Data {
        var writer = MTPBinaryWriter()
        writer.writeUInt32(storageID)
        writer.writeUInt16(isFolder ? MTPObjectFormat.association.rawValue : MTPObjectFormat.undefined.rawValue)
        writer.writeUInt16(0) // protectionStatus
        writer.writeUInt32(size >= UInt64(UInt32.max) ? 0xFFFFFFFF : UInt32(size))
        writer.writeUInt16(0) // thumbFormat
        writer.writeUInt32(0) // thumbCompressedSize
        writer.writeUInt32(0) // thumbPixWidth
        writer.writeUInt32(0) // thumbPixHeight
        writer.writeUInt32(0) // imagePixWidth
        writer.writeUInt32(0) // imagePixHeight
        writer.writeUInt32(0) // imageBitDepth
        writer.writeUInt32(parentHandle)
        writer.writeUInt16(isFolder ? 0x0001 : 0x0000) // associationType: 1 = GenericFolder
        writer.writeUInt32(0) // associationDesc
        writer.writeUInt32(0) // sequenceNumber
        writer.writeMTPString(filename)
        let nowStr = MTPDateParser.format(Date())
        writer.writeMTPString(nowStr) // dateCreated
        writer.writeMTPString(nowStr) // dateModified
        writer.writeMTPString("")     // keywords
        return writer.data
    }

    private func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }
}
