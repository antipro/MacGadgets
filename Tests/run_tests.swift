import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
        exit(1)
    }
}

private func testDurationFormatter() {
    check(DurationFormatter.parse("57600s") == 57600, "57600s should parse to 57600")
    check(DurationFormatter.parse("90") == 5400, "90 should parse to 5400s (90m)")
    check(DurationFormatter.parse("45m") == 2700, "45m should parse to 2700s")
    check(DurationFormatter.parse("2h") == 7200, "2h should parse to 7200s")
    check(DurationFormatter.parse("1h30m") == 5400, "1h30m should parse to 5400s")
    check(DurationFormatter.parse("16:00:00") == 57600, "16:00:00 should parse to 57600s")
    check(DurationFormatter.parse("15:30") == 930, "15:30 should parse to 930s")
    check(DurationFormatter.parse("16 小时") == 57600, "16 小时 should parse to 57600s")
    check(DurationFormatter.parse("") == nil, "empty string should be nil")
    check(DurationFormatter.parse("0") == nil, "0 should be nil")
    check(DurationFormatter.parse("-5m") == nil, "negative should be nil")
    check(DurationFormatter.parse("abc") == nil, "invalid should be nil")
    check(DurationFormatter.parse("12:34:56:78") == nil, "too many colons should be nil")

    check(DurationFormatter.countdown(57600) == "16:00:00", "countdown 57600")
    check(DurationFormatter.countdown(90) == "01:30", "countdown 90")
    check(DurationFormatter.countdown(0) == "00:00", "countdown 0")
    check(DurationFormatter.humanReadable(57600) == "16 小时", "humanReadable 57600")
    check(DurationFormatter.humanReadable(5400) == "1 小时30 分", "humanReadable 5400")
    check(DurationFormatter.humanReadable(45) == "45 秒", "humanReadable 45")
}

private func testScrollReversalLogic() {
    check(ScrollReversalLogic.classify(isContinuous: 0) == .mouseWheel, "0 is mouseWheel")
    check(ScrollReversalLogic.classify(isContinuous: 1) == .trackpad, "1 is trackpad")

    let mouseOnly = ScrollReversalConfig(invertMouseWheel: true, invertTrackpad: false, invertHorizontal: false)
    check(ScrollReversalLogic.shouldInvertVertical(source: .mouseWheel, config: mouseOnly), "mouse inverted")
    check(!ScrollReversalLogic.shouldInvertVertical(source: .trackpad, config: mouseOnly), "trackpad not inverted")
    check(!ScrollReversalLogic.shouldInvertHorizontal(source: .mouseWheel, config: mouseOnly), "horizontal off")

    let bothWithH = ScrollReversalConfig(invertMouseWheel: true, invertTrackpad: true, invertHorizontal: true)
    check(ScrollReversalLogic.shouldInvertVertical(source: .mouseWheel, config: bothWithH), "mouse V inverted")
    check(ScrollReversalLogic.shouldInvertVertical(source: .trackpad, config: bothWithH), "trackpad V inverted")
    check(ScrollReversalLogic.shouldInvertHorizontal(source: .mouseWheel, config: bothWithH), "mouse H inverted")
    check(ScrollReversalLogic.shouldInvertHorizontal(source: .trackpad, config: bothWithH), "trackpad H inverted")
}

private func testPowerAssertion() {
    let assertion = PowerAssertion(reason: "MacGadgets unit test")
    check(!assertion.isActive, "initially inactive")
    check(assertion.acquire(.displayAndSystem), "acquire displayAndSystem succeeds")
    check(assertion.isActive, "active after acquire")
    check(assertion.activeScopes == [.display, .system], "both display and system assertions held")
    assertion.release()
    check(!assertion.isActive, "inactive after release")
    check(assertion.activeScopes.isEmpty, "scopes empty after release")
}

// MARK: - MTP & WebDAV Tests

private final class MockMTPUSBTransport: MTPUSBTransport {
    let maxPacketSizeIn = 512
    let maxPacketSizeOut = 512
    var queuedResponses: [Data] = []
    var writtenPackets: [Data] = []
    var closed = false

    func bulkWrite(_ data: Data, timeoutMs: UInt32) throws {
        writtenPackets.append(data)
    }

    func bulkRead(maxLength: Int, timeoutMs: UInt32) throws -> Data {
        guard !queuedResponses.isEmpty else {
            throw MTPTransportError.timeout
        }
        return queuedResponses.removeFirst()
    }

    func clearStall(directionIn: Bool) throws {}

    func close() {
        closed = true
    }

    static func makeContainer(type: MTPContainerType, code: UInt16, txID: UInt32, payload: Data = Data()) -> Data {
        var writer = MTPBinaryWriter()
        writer.writeUInt32(UInt32(12 + payload.count))
        writer.writeUInt16(type.rawValue)
        writer.writeUInt16(code)
        writer.writeUInt32(txID)
        var out = writer.data
        out.append(payload)
        return out
    }

    static func makeResponse(code: MTPResponseCode, txID: UInt32, params: [UInt32] = []) -> Data {
        var writer = MTPBinaryWriter()
        for p in params { writer.writeUInt32(p) }
        return makeContainer(type: .response, code: code.rawValue, txID: txID, payload: writer.data)
    }
}

private final class MockMTPClient: MTPClientProtocol {
    struct Node {
        let handle: UInt32
        let storageID: UInt32
        var parentHandle: UInt32
        var name: String
        let isFolder: Bool
        var data: Data
        var modifiedAt: Date
    }

    var deviceInfo = MTPDeviceInfo(
        manufacturer: "Xiaomi",
        model: "Xiaomi Mi 9",
        deviceVersion: "1.0",
        serialNumber: "5ae79bcc",
        operationsSupported: [0x1001, 0x1002, 0x1004, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B, 0x100C, 0x100D, 0x1019, 0x101A, 0x101B, 0x9804]
    )

    var storages: [UInt32: MTPStorageInfo] = [
        0x00010001: MTPStorageInfo(
            storageID: 0x00010001,
            storageType: 3,
            filesystemType: 2,
            accessCapability: 0,
            maxCapacity: 128_000_000_000,
            freeSpaceInBytes: 64_000_000_000,
            storageDescription: "内部共享存储",
            volumeLabel: "Internal"
        )
    ]

    var nodes: [UInt32: Node] = [:]
    private var nextHandle: UInt32 = 10

    init() {
        let now = Date()
        nodes[1] = Node(handle: 1, storageID: 0x00010001, parentHandle: MTPClient.rootParentHandle, name: "DCIM", isFolder: true, data: Data(), modifiedAt: now)
        nodes[2] = Node(handle: 2, storageID: 0x00010001, parentHandle: 1, name: "hello.txt", isFolder: false, data: Data("HelloAndroid!".utf8), modifiedAt: now)
    }

    func getDeviceInfo() throws -> MTPDeviceInfo { deviceInfo }
    func getStorageIDs() throws -> [UInt32] { Array(storages.keys).sorted() }
    func getStorageInfo(storageID: UInt32) throws -> MTPStorageInfo {
        guard let info = storages[storageID] else { throw MTPError.protocolError(MTPResponseCode.invalidStorageID.rawValue) }
        return info
    }

    func getObjectHandles(storageID: UInt32, parentHandle: UInt32) throws -> [UInt32] {
        nodes.values
            .filter { $0.storageID == storageID && $0.parentHandle == parentHandle }
            .map { $0.handle }
            .sorted()
    }

    func getObjectInfo(handle: UInt32) throws -> MTPObjectInfo {
        guard let node = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        return MTPObjectInfo(
            handle: node.handle,
            storageID: node.storageID,
            objectFormat: node.isFolder ? MTPObjectFormat.association.rawValue : MTPObjectFormat.undefined.rawValue,
            protectionStatus: 0,
            size: UInt64(node.data.count),
            parentHandle: node.parentHandle,
            associationType: node.isFolder ? 1 : 0,
            filename: node.name,
            dateCreated: node.modifiedAt,
            dateModified: node.modifiedAt
        )
    }

    func getObject(handle: UInt32) throws -> Data {
        guard let node = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        return node.data
    }

    func getObjectToFile(handle: UInt32, destinationURL: URL) throws {
        let data = try getObject(handle: handle)
        try data.write(to: destinationURL)
    }

    func getPartialObject(handle: UInt32, offset: UInt64, maxBytes: UInt32) throws -> Data? {
        guard let node = nodes[handle] else { return nil }
        let start = Int(min(offset, UInt64(node.data.count)))
        let end = min(node.data.count, start + Int(maxBytes))
        return node.data.subdata(in: start..<end)
    }

    func createFolder(storageID: UInt32, parentHandle: UInt32, name: String) throws -> UInt32 {
        let h = nextHandle
        nextHandle += 1
        nodes[h] = Node(handle: h, storageID: storageID, parentHandle: parentHandle, name: name, isFolder: true, data: Data(), modifiedAt: Date())
        return h
    }

    func uploadFile(storageID: UInt32, parentHandle: UInt32, filename: String, fileURL: URL, fileSize: UInt64) throws -> UInt32 {
        let data = try Data(contentsOf: fileURL)
        let h = nextHandle
        nextHandle += 1
        nodes[h] = Node(handle: h, storageID: storageID, parentHandle: parentHandle, name: filename, isFolder: false, data: data, modifiedAt: Date())
        return h
    }

    func deleteObject(handle: UInt32) throws {
        guard let target = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        if target.isFolder {
            let hasChildren = nodes.values.contains { $0.parentHandle == handle }
            if hasChildren {
                throw MTPError.protocolError(MTPResponseCode.generalError.rawValue)
            }
        }
        nodes.removeValue(forKey: handle)
    }

    func moveObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws {
        guard var node = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        node.parentHandle = targetParentHandle
        nodes[handle] = node
    }

    func renameObject(handle: UInt32, newName: String) throws {
        guard var node = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        node.name = newName
        nodes[handle] = node
    }

    func copyObject(handle: UInt32, targetStorageID: UInt32, targetParentHandle: UInt32) throws -> UInt32 {
        guard let node = nodes[handle] else { throw MTPError.protocolError(MTPResponseCode.invalidObjectHandle.rawValue) }
        let h = nextHandle
        nextHandle += 1
        nodes[h] = Node(handle: h, storageID: targetStorageID, parentHandle: targetParentHandle, name: node.name, isFolder: node.isFolder, data: node.data, modifiedAt: Date())
        return h
    }

    func resetSession() {}

    func close() {}
}

private func testMTPBinaryAndClientFraming() throws {
    // 1. String & Date round-trip
    var w = MTPBinaryWriter()
    w.writeMTPString("你好Android.jpg")
    w.writeMTPString("")
    var r = MTPBinaryReader(w.data)
    let s1 = try r.readMTPString()
    let s2 = try r.readMTPString()
    check(s1 == "你好Android.jpg", "MTP UTF-16LE string round-trip")
    check(s2 == "", "empty MTP string round-trip")

    let parsedDate = MTPDateParser.parse("20261115T143000")
    check(parsedDate != nil, "MTP date parses")

    // 2. MTPClient OpenSession + GetDeviceInfo over MockMTPUSBTransport
    let transport = MockMTPUSBTransport()
    var devWriter = MTPBinaryWriter()
    devWriter.writeUInt16(100) // standardVersion
    devWriter.writeUInt32(6)   // vendorExtensionID
    devWriter.writeUInt16(100) // vendorExtensionVersion
    devWriter.writeMTPString("android.com")
    devWriter.writeUInt16(0)   // functionalMode
    devWriter.writeUInt32(2); devWriter.writeUInt16(0x1001); devWriter.writeUInt16(0x1002) // ops
    devWriter.writeUInt32(0) // events
    devWriter.writeUInt32(0) // props
    devWriter.writeUInt32(0) // captureFormats
    devWriter.writeUInt32(0) // playbackFormats
    devWriter.writeMTPString("Xiaomi")
    devWriter.writeMTPString("Mi 9")
    devWriter.writeMTPString("1.0")
    devWriter.writeMTPString("ABC123")

    transport.queuedResponses = [
        MockMTPUSBTransport.makeContainer(type: .data, code: MTPOperationCode.getDeviceInfo.rawValue, txID: 0, payload: devWriter.data),
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 0),
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 0) // OpenSession
    ]

    let client = MTPClient(transport: transport)
    try client.openSession()
    let info = try client.getDeviceInfo()
    check(info.manufacturer == "Xiaomi", "manufacturer parsed")
    check(info.model == "Mi 9", "model parsed")
    check(info.serialNumber == "ABC123", "serial parsed")
    check(info.operationsSupported.contains(0x1002), "operations parsed")
}

private func testMTPUploadStreamsExactLength() throws {
    let transport = MockMTPUSBTransport()
    // OpenSession (GetDeviceInfo + OpenSession) then SendObjectInfo + SendObject.
    transport.queuedResponses = [
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 0), // GetDeviceInfo pre-open
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 0),           // OpenSession
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 1), // GetDeviceInfo post-open
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 2, params: [0x00010001, 0xFFFFFFFF, 42]),
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 3, params: [])
    ]

    let client = MTPClient(transport: transport)
    try client.openSession()
    let payload = Data(repeating: 0x5A, count: 700_000)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
    try payload.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let handle = try client.uploadFile(
        storageID: 0x00010001,
        parentHandle: MTPClient.rootParentHandle,
        filename: "big.bin",
        fileURL: tmp,
        fileSize: UInt64(payload.count)
    )
    check(handle == 42, "upload returns device-assigned handle")

    // Total bytes written for the SendObject data phase must be exactly 12 + payload bytes
    // (a ZLP may follow, which is empty and therefore contributes nothing).
    let openSessionOverhead = transport.writtenPackets[0].count // GetDeviceInfo
        + transport.writtenPackets[1].count                     // OpenSession
        + transport.writtenPackets[2].count                     // GetDeviceInfo post-open
    let sendObjectInfoAndCmd = transport.writtenPackets[3].count // SendObjectInfo command
        + transport.writtenPackets[4].count                      // SendObjectInfo dataset
        + transport.writtenPackets[5].count                      // SendObject command
    let totalWritten = transport.writtenPackets.reduce(0) { $0 + $1.count }
    let sendObjectBytes = totalWritten - openSessionOverhead - sendObjectInfoAndCmd
    check(sendObjectBytes == payload.count + 12, "SendObject data phase sends exactly the declared length")

    // Every intermediate data-phase packet must be an exact multiple of maxPacketSizeOut (512)
    // so USB never treats an intermediate chunk as a short-packet end-of-transfer.
    let dataPackets = Array(transport.writtenPackets.dropFirst(6))
    check(dataPackets.count > 1, "large upload splits across multiple USB transfers")
    for pkt in dataPackets.dropLast() {
        check(pkt.count % transport.maxPacketSizeOut == 0, "intermediate SendObject chunk aligned to maxPacketSizeOut")
    }
}

private func testMTPResetSessionReopensSession() throws {
    let transport = MockMTPUSBTransport()
    // 1) openSession() -> GetDeviceInfo + OpenSession
    // 2) resetSession() -> OpenSession (since session was open, closeSession runs first)
    // 3) uploadFile() -> SendObjectInfo + SendObject
    transport.queuedResponses = [
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 0), // GetDeviceInfo pre-open #1
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 0),           // OpenSession #1
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 1), // GetDeviceInfo post-open #1
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 2),           // CloseSession
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 0), // GetDeviceInfo pre-open #2
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 0),           // OpenSession #2
        MockMTPUSBTransport.makeResponse(code: .generalError, txID: 1), // GetDeviceInfo post-open #2
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 2, params: [0x00010001, 0xFFFFFFFF, 77]), // SendObjectInfo
        MockMTPUSBTransport.makeResponse(code: .ok, txID: 3, params: [])                            // SendObject
    ]

    let client = MTPClient(transport: transport)
    try client.openSession()
    client.resetSession()

    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reopen-\(UUID().uuidString)")
    try Data("abc".utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let handle = try client.uploadFile(
        storageID: 0x00010001,
        parentHandle: MTPClient.rootParentHandle,
        filename: "reopen.txt",
        fileURL: tmp,
        fileSize: 3
    )
    check(handle == 77, "upload succeeds on reopened session after resetSession()")
}

private func testMTPVirtualFileSystemAndNFSv3() throws {
    let mockClient = MockMTPClient()
    let vfs = MTPVirtualFileSystem(client: mockClient)
    let roots = try vfs.refreshStorages()
    check(roots.count == 1, "one storage loaded")

    // Metadata sidecar should stay in memory and never touch mockClient.nodes
    let initialNodeCount = mockClient.nodes.count
    let tmpDS = FileManager.default.temporaryDirectory.appendingPathComponent("test-ds-\(UUID().uuidString)")
    try Data([1, 2, 3]).write(to: tmpDS)
    defer { try? FileManager.default.removeItem(at: tmpDS) }
    try vfs.stageOrWriteFile(path: "/.DS_Store", tempFileURL: tmpDS, fileSize: 3)
    check(mockClient.nodes.count == initialNodeCount, "metadata sidecar must not write to phone MTP")
    let dsRead = try vfs.readBytes(path: "/.DS_Store", offset: 0, length: 10)
    check(dsRead == Data([1, 2, 3]), "sidecar readable")

    // VFS directory, upload, rename, copy, delete checks
    try vfs.createDirectory(path: "/Notes")
    let noteTmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-note-\(UUID().uuidString)")
    try Data("HelloNFS".utf8).write(to: noteTmp)
    defer { try? FileManager.default.removeItem(at: noteTmp) }
    try vfs.stageOrWriteFile(path: "/Notes/a.txt", tempFileURL: noteTmp, fileSize: 8)
    let readNote = try vfs.readBytes(path: "/Notes/a.txt", offset: 0, length: 20)
    check(String(data: readNote, encoding: .utf8) == "HelloNFS", "VFS write+read works")
    try vfs.move(from: "/Notes/a.txt", to: "/Notes/b.txt", overwrite: true)
    let readMoved = try vfs.readBytes(path: "/Notes/b.txt", offset: 2, length: 3)
    check(String(data: readMoved, encoding: .utf8) == "llo", "VFS move+slice read works")
    try vfs.delete(path: "/Notes")
    let deletedExists = (try? vfs.stat(path: "/Notes")) != nil
    check(!deletedExists, "VFS recursive delete works")

    // Start NFSv3Server and perform real SunRPC MOUNT v3 MNT call over TCP
    let server = NFSv3Server(vfs: vfs, exportName: "MI 9")
    let port = try server.start()
    defer { server.stop() }
    check(port > 0, "NFSv3Server bound an ephemeral port")
    check(server.exportPath == "/MI 9", "NFSv3 exportPath formatted cleanly")

    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    check(fd >= 0, "TCP socket created")
    defer { Darwin.close(fd) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    check(rc == 0, "Connected to local NFSv3Server")

    func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    // Build SunRPC CALL: prog=100005 (MOUNT), vers=3, proc=1 (MNT), dirpath="/MI 9"
    var rpc = Data()
    appendU32(&rpc, 0x12345678) // xid
    appendU32(&rpc, 0)          // CALL
    appendU32(&rpc, 2)          // RPC version 2
    appendU32(&rpc, 100005)     // MOUNT
    appendU32(&rpc, 3)          // v3
    appendU32(&rpc, 1)          // MNT
    appendU32(&rpc, 0); appendU32(&rpc, 0) // cred AUTH_NONE
    appendU32(&rpc, 0); appendU32(&rpc, 0) // verf AUTH_NONE
    let dirBytes = Data("/MI 9".utf8)
    appendU32(&rpc, UInt32(dirBytes.count))
    rpc.append(dirBytes)
    let pad = (4 - (dirBytes.count % 4)) % 4
    if pad > 0 { rpc.append(Data(count: pad)) }

    var frame = Data()
    appendU32(&frame, UInt32(rpc.count) | 0x8000_0000)
    frame.append(rpc)

    let sent = frame.withUnsafeBytes { ptr in
        Darwin.send(fd, ptr.baseAddress!, frame.count, 0)
    }
    check(sent == frame.count, "Sent SunRPC MOUNT MNT call")

    var respHdr = [UInt8](repeating: 0, count: 4)
    let nHdr = Darwin.recv(fd, &respHdr, 4, MSG_WAITALL)
    check(nHdr == 4, "Received SunRPC record header")
    let rawLen = (UInt32(respHdr[0]) << 24) | (UInt32(respHdr[1]) << 16) | (UInt32(respHdr[2]) << 8) | UInt32(respHdr[3])
    let respLen = Int(rawLen & 0x7FFF_FFFF)
    check(respLen >= 28, "MOUNT MNT reply length valid")

    var respBody = [UInt8](repeating: 0, count: respLen)
    let nBody = Darwin.recv(fd, &respBody, respLen, MSG_WAITALL)
    check(nBody == respLen, "Received full MOUNT MNT reply")

    func readBE32(_ offset: Int) -> UInt32 {
        (UInt32(respBody[offset]) << 24)
            | (UInt32(respBody[offset + 1]) << 16)
            | (UInt32(respBody[offset + 2]) << 8)
            | UInt32(respBody[offset + 3])
    }
    check(readBE32(0) == 0x12345678, "XID matches")
    check(readBE32(4) == 1 && readBE32(8) == 0 && readBE32(20) == 0, "RPC ACCEPTED + SUCCESS")
    check(readBE32(24) == 0, "MNT3_OK status")
    check(readBE32(28) == 16, "16-byte NFSv3 root filehandle returned")
}

@main
struct TestRunner {
    static func main() throws {
        testDurationFormatter()
        testScrollReversalLogic()
        testPowerAssertion()
        try testMTPBinaryAndClientFraming()
        try testMTPUploadStreamsExactLength()
        try testMTPResetSessionReopensSession()
        try testMTPVirtualFileSystemAndNFSv3()
        print("All MacGadgets tests passed!")
    }
}
