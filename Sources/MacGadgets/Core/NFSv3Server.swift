import Foundation
import Darwin

/// User-space SunRPC / MOUNTv3 / NFSv3 over TCP server backed by `MTPVirtualFileSystem`.
/// Designed so macOS Finder can mount Android MTP storage natively via NFSv3 without kernel
/// extensions or macFUSE.
final class NFSv3Server {
    let vfs: MTPVirtualFileSystem
    let exportName: String

    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var isRunning = false
    private let acceptQueue = DispatchQueue(label: "com.macgadgets.nfsv3.accept")
    private let clientQueue = DispatchQueue(label: "com.macgadgets.nfsv3.client", attributes: .concurrent)

    /// Invoked when a write cannot be committed because the USB link stalled/disconnected.
    var onTransportFailure: ((String) -> Void)?

    private var lastTransportFailureNotified: Date?
    private let stateLock = NSLock()
    private var pathToID: [String: UInt64] = ["/": 1]
    private var idToPath: [UInt64: String] = [1: "/"]
    private var nextFileID: UInt64 = 2

    private struct StagingFile {
        var url: URL
        var path: String
        var isDirty: Bool
        var isFlushing: Bool
        var lastWriteAt: Date
        var lastFailureAt: Date?
    }
    private var stagingFiles: [UInt64: StagingFile] = [:]
    private let tempDir: URL
    private let flushQueue = DispatchQueue(label: "com.macgadgets.nfsv3.flush")
    private var idleFlushTimer: DispatchSourceTimer?
    private let localHostIPs: Set<UInt32>
    private let uid: UInt32 = Darwin.getuid()
    private let gid: UInt32 = Darwin.getgid()
    private let writeVerifier: UInt64 = 0x4D474E4653333031

    init(vfs: MTPVirtualFileSystem, exportName: String) {
        self.vfs = vfs
        let cleaned = exportName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.exportName = cleaned.isEmpty ? "Android" : cleaned
        self.localHostIPs = Self.discoverLocalIPv4Addresses()
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacGadgetsNFS-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    var exportPath: String {
        "/\(exportName)"
    }

    // MARK: - Debug Logging

    private static let debugLogURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["MACGADGETS_NFS_LOG"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }()

    private func dbg(_ message: @autoclosure () -> String) {
        guard let url = Self.debugLogURL else { return }
        let line = "[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(message())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func mountURL(host: String = "127.0.0.1") -> URL {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#+%"))
        let encoded = exportName.addingPercentEncoding(withAllowedCharacters: allowed) ?? exportName
        return URL(string: "nfs://\(host):\(port)/\(encoded)")!
    }

    func start() throws -> UInt16 {
        guard !isRunning else { return port }

        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var v6Only: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = 0
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        var boundAddr = sockaddr_in6()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameRes = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &boundLen)
            }
        }
        guard nameRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin6_port)
        self.isRunning = true

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }

        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.flushIdleStagingFiles()
        }
        timer.resume()
        idleFlushTimer = timer

        return self.port
    }

    func stop() {
        isRunning = false
        idleFlushTimer?.cancel()
        idleFlushTimer = nil
        flushAllStagingFiles()
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        stateLock.lock()
        for (_, stage) in stagingFiles {
            try? FileManager.default.removeItem(at: stage.url)
        }
        stagingFiles.removeAll()
        stateLock.unlock()
    }

    // MARK: - Accept Loop & Local Peer Check

    private static func discoverLocalIPv4Addresses() -> Set<UInt32> {
        var ips: Set<UInt32> = [inet_addr("127.0.0.1")]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(first) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ptr = cursor {
                if let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    ips.insert(sin.sin_addr.s_addr)
                }
                cursor = ptr.pointee.ifa_next
            }
        }
        return ips
    }

    private func isLocalPeer(_ addr: sockaddr_in6) -> Bool {
        var raw = addr.sin6_addr
        let data = withUnsafeBytes(of: &raw) { Data($0) }
        if data.prefix(12) == Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]) {
            let ip4 = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
            return localHostIPs.contains(ip4) || Self.discoverLocalIPv4Addresses().contains(ip4)
        }
        var loop6 = in6addr_loopback
        let loopData = withUnsafeBytes(of: &loop6) { Data($0) }
        if data == loopData { return true }
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(first) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let ptr = cursor {
                if let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) {
                    var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    let local6 = withUnsafeBytes(of: &sin6.sin6_addr) { Data($0) }
                    if local6 == data { return true }
                }
                cursor = ptr.pointee.ifa_next
            }
        }
        return false
    }

    private func acceptLoop(listenFD: Int32) {
        while isRunning {
            var clientAddr = sockaddr_in6()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            if !isLocalPeer(clientAddr) {
                Darwin.close(clientFD)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var noDelay: Int32 = 1
            setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            clientQueue.async { [weak self] in
                self?.handleConnection(fd: clientFD)
            }
        }
    }

    // MARK: - SunRPC Framing Loop

    private func handleConnection(fd: Int32) {
        defer { Darwin.close(fd) }

        // Requests on one connection are handled in order: NFS semantics rely on
        // WRITE/COMMIT ordering, and serial processing keeps MTP work predictable.
        while isRunning {
            guard let msg = readRPCRecord(fd: fd) else { return }
            let reply = processRPCMessage(msg)
            if !writeRPCRecord(fd: fd, payload: reply) {
                return
            }
        }
    }

    private func processRPCMessage(_ msg: Data) -> Data {
        var r = XDRReader(msg)
        guard let xid = r.u32(),
              let msgType = r.u32(), msgType == 0,
              let rpcVers = r.u32(), rpcVers == 2,
              let prog = r.u32(),
              let vers = r.u32(),
              let proc = r.u32(),
              r.skipAuth(), // cred
              r.skipAuth()  // verf
        else {
            return makeRPCRejectReply(xid: 0, stat: 2)
        }

        if prog == 100005 && vers == 3 { // MOUNT v3
            let body = handleMountV3(proc: proc, reader: &r)
            return makeRPCAcceptReply(xid: xid, body: body)
        }
        if prog == 100003 && vers == 3 { // NFS v3
            let body = handleNFSv3(proc: proc, reader: &r)
            return makeRPCAcceptReply(xid: xid, body: body)
        }
        if prog == 100000 && proc == 3 { // PORTMAP GETPORT (best effort)
            var w = XDRWriter()
            _ = r.u32() // prog
            _ = r.u32() // vers
            _ = r.u32() // proto
            _ = r.u32() // port
            w.u32(UInt32(port))
            return makeRPCAcceptReply(xid: xid, body: w.data)
        }
        if proc == 0 { // NULL proc for any program
            return makeRPCAcceptReply(xid: xid, body: Data())
        }
        return makeRPCAcceptErrorReply(xid: xid, acceptStat: 1) // PROG_UNAVAIL
    }

    // MARK: - MOUNT v3

    private func handleMountV3(proc: UInt32, reader: inout XDRReader) -> Data {
        var w = XDRWriter()
        switch proc {
        case 0: // MOUNTPROC3_NULL
            return Data()
        case 1: // MOUNTPROC3_MNT
            _ = reader.string() // dirpath
            w.u32(0) // MNT3_OK
            w.opaque(encodeFileHandle(1)) // root handle
            w.u32(2) // auth_flavors count
            w.u32(1) // AUTH_UNIX
            w.u32(0) // AUTH_NONE
            return w.data
        case 3, 4: // UMNT / UMNTALL
            flushAllStagingFiles()
            return Data()
        case 5: // EXPORT
            w.u32(1) // value follows
            w.string(exportPath)
            w.u32(0) // groups list empty
            w.u32(0) // next export NULL
            return w.data
        default:
            return Data()
        }
    }

    // MARK: - NFS v3

    private enum NFSStat: UInt32 {
        case ok = 0
        case perm = 1
        case noent = 2
        case io = 5
        case acces = 13
        case exist = 17
        case notdir = 20
        case isdir = 21
        case inval = 22
        case notempty = 66
        case stale = 70
        case notsupp = 10004
    }

    private func handleNFSv3(proc: UInt32, reader: inout XDRReader) -> Data {
        switch proc {
        case 0: // NULL
            return Data()

        case 1: // GETATTR
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return statusOnly(.stale)
            }
            guard let attr = makeFattr3(path: path, fileID: fid) else {
                return statusOnly(.noent)
            }
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            w.bytes(attr)
            return w.data

        case 2: // SETATTR
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return statusOnly(.stale)
            }
            guard let setMode = reader.u32() else { return statusOnly(.inval) }
            if setMode != 0 { _ = reader.u32() } // mode
            if let setUid = reader.u32(), setUid != 0 { _ = reader.u32() }
            if let setGid = reader.u32(), setGid != 0 { _ = reader.u32() }
            var requestedSize: UInt64?
            if let setSize = reader.u32(), setSize != 0 {
                requestedSize = reader.u64()
            }
            if let setAtime = reader.u32(), setAtime == 2 { _ = reader.u32(); _ = reader.u32() }
            if let setMtime = reader.u32(), setMtime == 2 { _ = reader.u32(); _ = reader.u32() }
            if let hasGuard = reader.u32(), hasGuard != 0 { _ = reader.u32(); _ = reader.u32() }

            if let newSize = requestedSize {
                truncateStagingFile(fileID: fid, path: path, newSize: newSize)
                if newSize == 0 {
                    _ = flushStagingFile(fileID: fid, path: path)
                }
            }
            return wccSuccess(path: path, fileID: fid)

        case 3: // LOOKUP
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let name = reader.string() else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            let targetPath = childPath(parent: dirPath, name: name)
            do {
                _ = try vfs.stat(path: targetPath)
                let objID = idForPath(targetPath)
                guard let objAttr = makeFattr3(path: targetPath, fileID: objID) else {
                    return statusWithPostOpAttr(.noent, path: dirPath, fileID: dirID)
                }
                var w = XDRWriter()
                w.u32(NFSStat.ok.rawValue)
                w.opaque(encodeFileHandle(objID))
                w.u32(1); w.bytes(objAttr)
                appendPostOpAttr(&w, path: dirPath, fileID: dirID)
                return w.data
            } catch {
                return statusWithPostOpAttr(mapVFSError(error), path: dirPath, fileID: dirID)
            }

        case 4: // ACCESS
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid),
                  let accessMask = reader.u32() else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u32(accessMask & 0x3F)
            return w.data

        case 5: // READLINK
            return statusWithPostOpAttr(.inval, path: nil, fileID: 0)

        case 6: // READ
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid),
                  let offset = reader.u64(),
                  let count = reader.u32() else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }

            if let stageURL = stagingURLIfExists(fileID: fid) {
                guard let fh = try? FileHandle(forReadingFrom: stageURL) else {
                    return statusWithPostOpAttr(.io, path: path, fileID: fid)
                }
                defer { try? fh.close() }
                let size = (try? FileManager.default.attributesOfItem(atPath: stageURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                let data: Data
                if offset >= size {
                    data = Data()
                } else {
                    try? fh.seek(toOffset: offset)
                    data = (try? fh.read(upToCount: Int(count))) ?? Data()
                }
                let eof = offset + UInt64(data.count) >= size
                var w = XDRWriter()
                w.u32(NFSStat.ok.rawValue)
                appendPostOpAttr(&w, path: path, fileID: fid)
                w.u32(UInt32(data.count))
                w.u32(eof ? 1 : 0)
                w.opaque(data)
                return w.data
            }

            do {
                let entry = try vfs.stat(path: path)
                if entry.isDirectory {
                    return statusWithPostOpAttr(.isdir, path: path, fileID: fid)
                }
                let data = try vfs.readBytes(path: path, offset: offset, length: Int(count))
                let eof = offset + UInt64(data.count) >= entry.size
                var w = XDRWriter()
                w.u32(NFSStat.ok.rawValue)
                appendPostOpAttr(&w, path: path, fileID: fid)
                w.u32(UInt32(data.count))
                w.u32(eof ? 1 : 0)
                w.opaque(data)
                return w.data
            } catch {
                return statusWithPostOpAttr(mapVFSError(error), path: path, fileID: fid)
            }

        case 7: // WRITE
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid),
                  let offset = reader.u64(),
                  let count = reader.u32(),
                  let stable = reader.u32(),
                  let payload = reader.opaque() else {
                return wccError(.stale, path: nil, fileID: 0)
            }
            let writeLen = min(Int(count), payload.count)
            let chunk = payload.prefix(writeLen)

            guard writeToStagingFile(fileID: fid, path: path, offset: offset, data: chunk) else {
                return wccError(.io, path: path, fileID: fid)
            }
            if stable != 0 {
                dbg("WRITE stable=\(stable) \(path) off=\(offset) len=\(writeLen)")
            }

            // stable: 0=UNSTABLE, 1=DATA_SYNC, 2=FILE_SYNC
            // Only synchronous writes hit MTP right away; UNSTABLE writes stay in the
            // local staging file until COMMIT, otherwise a growing file would be
            // re-uploaded on every chunk and saturate the USB link.
            if stable == 2 || stable == 1 {
                if !flushStagingFile(fileID: fid, path: path) {
                    return wccError(.io, path: path, fileID: fid)
                }
            }

            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            w.u32(0) // pre_op_attr: false
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u32(UInt32(writeLen))
            w.u32(stable == 0 ? 0 : 2)
            w.u64(writeVerifier)
            return w.data

        case 8: // CREATE
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let name = reader.string(),
                  let how = reader.u32() else {
                return wccError(.stale, path: nil, fileID: 0)
            }
            _ = how
            let targetPath = childPath(parent: dirPath, name: name)
            let fid = idForPath(targetPath)

            dbg("CREATE \(targetPath)")
            // Pre-stage 0-byte file in VFS & staging
            let stageURL = ensureStagingFile(fileID: fid, path: targetPath, populateFromExisting: false)
            do {
                try vfs.stageOrWriteFile(path: targetPath, tempFileURL: stageURL, fileSize: 0)
                if MTPVirtualFileSystem.isMacOSMetadataPath(targetPath) {
                    removeStagingFile(fileID: fid)
                }
            } catch {
                removeStagingFile(fileID: fid)
                return wccError(mapVFSError(error), path: dirPath, fileID: dirID)
            }

            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            w.u32(1); w.opaque(encodeFileHandle(fid))
            appendPostOpAttr(&w, path: targetPath, fileID: fid)
            w.u32(0) // dir pre_op_attr false
            appendPostOpAttr(&w, path: dirPath, fileID: dirID)
            return w.data

        case 9: // MKDIR
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let name = reader.string() else {
                return wccError(.stale, path: nil, fileID: 0)
            }
            let targetPath = childPath(parent: dirPath, name: name)
            do {
                try vfs.createDirectory(path: targetPath)
                let fid = idForPath(targetPath)
                var w = XDRWriter()
                w.u32(NFSStat.ok.rawValue)
                w.u32(1); w.opaque(encodeFileHandle(fid))
                appendPostOpAttr(&w, path: targetPath, fileID: fid)
                w.u32(0) // dir pre_op_attr
                appendPostOpAttr(&w, path: dirPath, fileID: dirID)
                return w.data
            } catch {
                return wccError(mapVFSError(error), path: dirPath, fileID: dirID)
            }

        case 12, 13: // REMOVE, RMDIR
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let name = reader.string() else {
                return wccError(.stale, path: nil, fileID: 0)
            }
            let targetPath = childPath(parent: dirPath, name: name)
            let targetID = existingID(for: targetPath)
            if let targetID {
                removeStagingFile(fileID: targetID)
            }
            do {
                try vfs.delete(path: targetPath)
                forgetPathPrefix(targetPath)
                return wccSuccess(path: dirPath, fileID: dirID)
            } catch {
                return wccError(mapVFSError(error), path: dirPath, fileID: dirID)
            }

        case 14: // RENAME
            guard let fromDirFH = reader.opaque(), let fromDirID = decodeFileHandle(fromDirFH),
                  let fromDirPath = pathForID(fromDirID),
                  let fromName = reader.string(),
                  let toDirFH = reader.opaque(), let toDirID = decodeFileHandle(toDirFH),
                  let toDirPath = pathForID(toDirID),
                  let toName = reader.string() else {
                var w = XDRWriter()
                w.u32(NFSStat.stale.rawValue)
                w.u32(0); w.u32(0)
                w.u32(0); w.u32(0)
                return w.data
            }

            let srcPath = childPath(parent: fromDirPath, name: fromName)
            let dstPath = childPath(parent: toDirPath, name: toName)
            if let srcID = existingID(for: srcPath) {
                _ = flushStagingFile(fileID: srcID, path: srcPath)
            }
            do {
                try vfs.move(from: srcPath, to: dstPath, overwrite: true)
                renamePathMapping(from: srcPath, to: dstPath)
                var w = XDRWriter()
                w.u32(NFSStat.ok.rawValue)
                w.u32(0); appendPostOpAttr(&w, path: fromDirPath, fileID: fromDirID)
                w.u32(0); appendPostOpAttr(&w, path: toDirPath, fileID: toDirID)
                return w.data
            } catch {
                var w = XDRWriter()
                w.u32(mapVFSError(error).rawValue)
                w.u32(0); appendPostOpAttr(&w, path: fromDirPath, fileID: fromDirID)
                w.u32(0); appendPostOpAttr(&w, path: toDirPath, fileID: toDirID)
                return w.data
            }

        case 16: // READDIR
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let cookie = reader.u64(),
                  let _ = reader.fixed(8),
                  let count = reader.u32() else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            return buildReadDirReply(dirPath: dirPath, dirID: dirID, cookie: cookie, maxBytes: Int(count), plus: false)

        case 17: // READDIRPLUS
            guard let dirFH = reader.opaque(), let dirID = decodeFileHandle(dirFH),
                  let dirPath = pathForID(dirID),
                  let cookie = reader.u64(),
                  let _ = reader.fixed(8),
                  let _ = reader.u32(), // dircount
                  let maxcount = reader.u32() else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            return buildReadDirReply(dirPath: dirPath, dirID: dirID, cookie: cookie, maxBytes: Int(maxcount), plus: true)

        case 18: // FSSTAT
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            let summary = vfs.storageSummary()
            let tbytes = summary.totalBytes > 0 ? summary.totalBytes : 64_000_000_000
            let fbytes = summary.freeBytes
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u64(tbytes) // tbytes
            w.u64(fbytes) // fbytes
            w.u64(fbytes) // abytes
            w.u64(1_000_000) // tfiles
            w.u64(900_000)   // ffiles
            w.u64(900_000)   // afiles
            w.u32(0)         // invarsec
            return w.data

        case 19: // FSINFO
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u32(65536) // rtmax
            w.u32(65536) // rtpref
            w.u32(4096)  // rtmult
            w.u32(65536) // wtmax
            w.u32(65536) // wtpref
            w.u32(4096)  // wtmult
            w.u32(65536) // dtpref
            w.u64(0x7FFFFFFFFFFFFFFF) // maxfilesize
            w.u32(0); w.u32(1) // time_delta
            w.u32(0x18) // FSF3_HOMOGENEOUS | FSF3_CANSETTIME
            return w.data

        case 20: // PATHCONF
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return statusWithPostOpAttr(.stale, path: nil, fileID: 0)
            }
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u32(1)   // linkmax
            w.u32(255) // name_max
            w.u32(1)   // no_trunc
            w.u32(1)   // chown_restricted
            w.u32(0)   // case_insensitive
            w.u32(1)   // case_preserving
            return w.data

        case 21: // COMMIT
            guard let fhData = reader.opaque(), let fid = decodeFileHandle(fhData),
                  let path = pathForID(fid) else {
                return wccError(.stale, path: nil, fileID: 0)
            }
            let commitStart = Date()
            let commitOK = flushStagingFile(fileID: fid, path: path)
            dbg("COMMIT \(path) ok=\(commitOK) in \(String(format: "%.2f", Date().timeIntervalSince(commitStart)))s")
            guard commitOK else {
                return wccError(.io, path: path, fileID: fid)
            }
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            w.u32(0) // pre_op_attr
            appendPostOpAttr(&w, path: path, fileID: fid)
            w.u64(writeVerifier)
            return w.data

        default:
            return statusWithPostOpAttr(.notsupp, path: nil, fileID: 0)
        }
    }

    private func buildReadDirReply(dirPath: String, dirID: UInt64, cookie: UInt64, maxBytes: Int, plus: Bool) -> Data {
        do {
            let entries = try vfs.listDirectory(path: dirPath)
            let parentPath = MTPVirtualFileSystem.parentPath(of: dirPath)
            let parentID = idForPath(parentPath)

            struct DirRow {
                let fileID: UInt64
                let name: String
                let vfsPath: String
                let cookie: UInt64
                let entry: VFSEntry?
            }

            var rows: [DirRow] = [
                DirRow(fileID: dirID, name: ".", vfsPath: dirPath, cookie: 1, entry: nil),
                DirRow(fileID: parentID, name: "..", vfsPath: parentPath, cookie: 2, entry: nil)
            ]
            for (idx, item) in entries.enumerated() {
                let fid = idForPath(item.path)
                rows.append(DirRow(fileID: fid, name: item.name, vfsPath: item.path, cookie: UInt64(idx + 3), entry: item))
            }

            let startIdx = Int(cookie)
            var w = XDRWriter()
            w.u32(NFSStat.ok.rawValue)
            appendPostOpAttr(&w, path: dirPath, fileID: dirID)
            w.u64(writeVerifier) // cookieverf

            let budget = max(1024, min(maxBytes, 65536))
            var idx = startIdx
            var eof = true

            while idx < rows.count {
                let row = rows[idx]
                var itemWriter = XDRWriter()
                itemWriter.u32(1) // value follows
                itemWriter.u64(row.fileID)
                itemWriter.string(row.name)
                itemWriter.u64(row.cookie)
                if plus {
                    if let attr = makeFattr3(path: row.vfsPath, fileID: row.fileID, knownEntry: row.entry) {
                        itemWriter.u32(1); itemWriter.bytes(attr)
                        itemWriter.u32(1); itemWriter.opaque(encodeFileHandle(row.fileID))
                    } else {
                        itemWriter.u32(0)
                        itemWriter.u32(0)
                    }
                }
                if w.data.count + itemWriter.data.count + 8 > budget && idx > startIdx {
                    eof = false
                    break
                }
                w.bytes(itemWriter.data)
                idx += 1
            }

            w.u32(0) // no more entries
            w.u32(eof ? 1 : 0)
            return w.data
        } catch {
            return statusWithPostOpAttr(mapVFSError(error), path: dirPath, fileID: dirID)
        }
    }

    // MARK: - Write Staging & Flushing

    private func stagingURLIfExists(fileID: UInt64) -> URL? {
        stateLock.lock()
        let url = stagingFiles[fileID]?.url
        stateLock.unlock()
        return url
    }

    private func ensureStagingFile(fileID: UInt64, path: String, populateFromExisting: Bool) -> URL {
        stateLock.lock()
        if let existing = stagingFiles[fileID] {
            stateLock.unlock()
            return existing.url
        }
        stateLock.unlock()

        let url = tempDir.appendingPathComponent("nfs-stage-\(fileID)-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        if populateFromExisting, let entry = try? vfs.stat(path: path), !entry.isDirectory, entry.size > 0 {
            if let data = try? vfs.readBytes(path: path, offset: 0, length: Int(entry.size)) {
                try? data.write(to: url)
            }
        }

        stateLock.lock()
        stagingFiles[fileID] = StagingFile(url: url, path: path, isDirty: false, isFlushing: false, lastWriteAt: Date(), lastFailureAt: nil)
        stateLock.unlock()
        return url
    }

    private func writeToStagingFile(fileID: UInt64, path: String, offset: UInt64, data: Data) -> Bool {
        let url = ensureStagingFile(fileID: fileID, path: path, populateFromExisting: true)
        guard let fh = try? FileHandle(forUpdating: url) else { return false }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            try fh.write(contentsOf: data)
            stateLock.lock()
            if var st = stagingFiles[fileID] {
                st.isDirty = true
                st.lastWriteAt = Date()
                stagingFiles[fileID] = st
            }
            stateLock.unlock()
            return true
        } catch {
            return false
        }
    }

    private func truncateStagingFile(fileID: UInt64, path: String, newSize: UInt64) {
        let url = ensureStagingFile(fileID: fileID, path: path, populateFromExisting: newSize > 0)
        if let fh = try? FileHandle(forUpdating: url) {
            try? fh.truncate(atOffset: newSize)
            try? fh.close()
            stateLock.lock()
            if var st = stagingFiles[fileID] {
                st.isDirty = true
                stagingFiles[fileID] = st
            }
            stateLock.unlock()
        }
    }

    private func flushStagingFile(fileID: UInt64, path: String) -> Bool {
        stateLock.lock()
        guard var st = stagingFiles[fileID] else {
            stateLock.unlock()
            return true
        }
        if st.isFlushing {
            // Another flush is already pushing this file to the device.
            stateLock.unlock()
            return true
        }
        let isDirty = st.isDirty
        let url = st.url
        if isDirty {
            st.isDirty = false
            st.isFlushing = true
            stagingFiles[fileID] = st
        }
        stateLock.unlock()

        guard isDirty else { return true }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let started = Date()
        var succeeded = true
        do {
            try vfs.stageOrWriteFile(path: path, tempFileURL: url, fileSize: fileSize)
            vfs.flushPendingZeroByteIfNeeded(path: path)
        } catch {
            succeeded = false
            dbg("FLUSH FAILED \(path) size=\(fileSize) err=\(error)")
            if Self.isTransportLevelFailure(error) {
                stateLock.lock()
                let last = lastTransportFailureNotified
                let shouldNotify = last == nil || Date().timeIntervalSince(last!) > 30
                if shouldNotify { lastTransportFailureNotified = Date() }
                stateLock.unlock()
                if shouldNotify {
                    onTransportFailure?(error.localizedDescription)
                }
            }
        }
        dbg("FLUSH \(path) size=\(fileSize) ok=\(succeeded) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")

        stateLock.lock()
        if var current = stagingFiles[fileID] {
            current.isFlushing = false
            if !succeeded {
                current.isDirty = true
                current.lastFailureAt = Date()
            } else {
                current.lastFailureAt = nil
            }
            stagingFiles[fileID] = current
        }
        stateLock.unlock()

        return succeeded
    }

    /// Safety net for clients that never send COMMIT: push dirty staging files once
    /// they have been idle for a while, so nothing is silently left behind.
    private func flushIdleStagingFiles() {
        let now = Date()
        stateLock.lock()
        let candidates = stagingFiles.compactMap { fid, st -> (UInt64, String)? in
            guard st.isDirty, !st.isFlushing, now.timeIntervalSince(st.lastWriteAt) > 4.0 else { return nil }
            // Back off after a failed upload instead of hammering the device.
            if let failedAt = st.lastFailureAt, now.timeIntervalSince(failedAt) < 15.0 { return nil }
            return (fid, st.path)
        }
        stateLock.unlock()

        for (fid, path) in candidates {
            _ = flushStagingFile(fileID: fid, path: path)
        }
    }

    private func removeStagingFile(fileID: UInt64) {
        stateLock.lock()
        let removed = stagingFiles.removeValue(forKey: fileID)
        stateLock.unlock()
        if let url = removed?.url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func flushAllStagingFiles() {
        stateLock.lock()
        let items = stagingFiles.map { ($0.key, $0.value.url) }
        stateLock.unlock()
        for (fid, _) in items {
            if let path = pathForID(fid) {
                _ = flushStagingFile(fileID: fid, path: path)
            }
        }
    }

    // MARK: - FileHandle & Attribute Helpers

    private func idForPath(_ path: String) -> UInt64 {
        let norm = MTPVirtualFileSystem.normalizePath(path)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = pathToID[norm] { return existing }
        let id = nextFileID
        nextFileID += 1
        pathToID[norm] = id
        idToPath[id] = norm
        return id
    }

    private func existingID(for path: String) -> UInt64? {
        let norm = MTPVirtualFileSystem.normalizePath(path)
        stateLock.lock()
        defer { stateLock.unlock() }
        return pathToID[norm]
    }

    private func pathForID(_ id: UInt64) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return idToPath[id]
    }

    private func renamePathMapping(from: String, to: String) {
        let normFrom = MTPVirtualFileSystem.normalizePath(from)
        let normTo = MTPVirtualFileSystem.normalizePath(to)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let fid = pathToID.removeValue(forKey: normFrom) {
            pathToID[normTo] = fid
            idToPath[fid] = normTo
        }
        let prefix = normFrom + "/"
        let affected = pathToID.keys.filter { $0.hasPrefix(prefix) }
        for oldKey in affected {
            if let fid = pathToID.removeValue(forKey: oldKey) {
                let suffix = String(oldKey.dropFirst(normFrom.count))
                let newKey = normTo + suffix
                pathToID[newKey] = fid
                idToPath[fid] = newKey
            }
        }
    }

    private func forgetPathPrefix(_ path: String) {
        let norm = MTPVirtualFileSystem.normalizePath(path)
        let prefix = norm + "/"
        stateLock.lock()
        defer { stateLock.unlock() }
        if let fid = pathToID.removeValue(forKey: norm) {
            idToPath.removeValue(forKey: fid)
        }
        for key in pathToID.keys where key.hasPrefix(prefix) {
            if let fid = pathToID.removeValue(forKey: key) {
                idToPath.removeValue(forKey: fid)
            }
        }
    }

    private func encodeFileHandle(_ fileID: UInt64) -> Data {
        var w = XDRWriter()
        w.u64(0x4D474E4653330000) // "MGNFS3\0\0"
        w.u64(fileID)
        return w.data
    }

    private func decodeFileHandle(_ data: Data) -> UInt64? {
        guard data.count == 16 else { return nil }
        var r = XDRReader(data)
        guard let magic = r.u64(), magic == 0x4D474E4653330000 else { return nil }
        return r.u64()
    }

    private func makeFattr3(path: String, fileID: UInt64, knownEntry: VFSEntry? = nil) -> Data? {
        let resolvedEntry: VFSEntry?
        if let knownEntry {
            resolvedEntry = knownEntry
        } else {
            resolvedEntry = try? vfs.stat(path: path)
        }

        let isDir: Bool
        var size: UInt64
        let ctime: Date
        let mtime: Date

        if let entry = resolvedEntry {
            isDir = entry.isDirectory
            size = entry.isDirectory ? 512 : entry.size
            ctime = entry.createdAt
            mtime = entry.modifiedAt
        } else if let stageURL = stagingURLIfExists(fileID: fileID) {
            isDir = false
            size = (try? FileManager.default.attributesOfItem(atPath: stageURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            ctime = Date()
            mtime = ctime
        } else {
            return nil
        }

        if !isDir, let stageURL = stagingURLIfExists(fileID: fileID),
           let stagedSize = (try? FileManager.default.attributesOfItem(atPath: stageURL.path)[.size] as? NSNumber)?.uint64Value {
            size = stagedSize
        }

        var w = XDRWriter()
        w.u32(isDir ? 2 : 1) // NF3DIR : NF3REG
        w.u32(isDir ? 0o755 : 0o644)
        w.u32(isDir ? 2 : 1) // nlink
        w.u32(uid)
        w.u32(gid)
        w.u64(size)
        w.u64((size + 4095) & ~4095)
        w.u32(0); w.u32(0) // rdev
        w.u64(0x4D474E46)  // fsid
        w.u64(fileID)
        writeNFSTime(&w, mtime) // atime
        writeNFSTime(&w, mtime) // mtime
        writeNFSTime(&w, ctime) // ctime
        return w.data
    }

    private func appendPostOpAttr(_ w: inout XDRWriter, path: String?, fileID: UInt64) {
        if let path, let attr = makeFattr3(path: path, fileID: fileID) {
            w.u32(1)
            w.bytes(attr)
        } else {
            w.u32(0)
        }
    }

    private func statusOnly(_ status: NFSStat) -> Data {
        var w = XDRWriter()
        w.u32(status.rawValue)
        return w.data
    }

    private func statusWithPostOpAttr(_ status: NFSStat, path: String?, fileID: UInt64) -> Data {
        var w = XDRWriter()
        w.u32(status.rawValue)
        appendPostOpAttr(&w, path: path, fileID: fileID)
        return w.data
    }

    private func wccSuccess(path: String, fileID: UInt64) -> Data {
        var w = XDRWriter()
        w.u32(NFSStat.ok.rawValue)
        w.u32(0) // pre_op_attr
        appendPostOpAttr(&w, path: path, fileID: fileID)
        return w.data
    }

    private func wccError(_ status: NFSStat, path: String?, fileID: UInt64) -> Data {
        var w = XDRWriter()
        w.u32(status.rawValue)
        w.u32(0)
        appendPostOpAttr(&w, path: path, fileID: fileID)
        return w.data
    }

    private func writeNFSTime(_ w: inout XDRWriter, _ date: Date) {
        let t = max(0, date.timeIntervalSince1970)
        let sec = UInt32(t)
        let nsec = UInt32((t - Double(sec)) * 1_000_000_000)
        w.u32(sec)
        w.u32(nsec)
    }

    private func childPath(parent: String, name: String) -> String {
        if name == "." { return parent }
        if name == ".." { return MTPVirtualFileSystem.parentPath(of: parent) }
        return parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private static func isTransportLevelFailure(_ error: Error) -> Bool {
        if let transportError = error as? MTPTransportError {
            switch transportError {
            case .timeout, .disconnected, .deviceNotFound, .noEndpoints:
                return true
            case .deviceBusy, .ioError:
                return false
            }
        }
        return false
    }

    private func mapVFSError(_ error: Error) -> NFSStat {
        guard let vfsErr = error as? VFSError else { return .io }
        switch vfsErr {
        case .notFound: return .noent
        case .alreadyExists: return .exist
        case .isDirectory: return .isdir
        case .notDirectory: return .notdir
        case .readOnlyStorage: return .acces
        case .invalidPath: return .inval
        case .mtpError: return .io
        }
    }

    // MARK: - SunRPC Record Framing

    private func makeRPCAcceptReply(xid: UInt32, body: Data) -> Data {
        var w = XDRWriter()
        w.u32(xid)
        w.u32(1) // REPLY
        w.u32(0) // MSG_ACCEPTED
        w.u32(0); w.u32(0) // AUTH_NONE verifier
        w.u32(0) // SUCCESS
        w.bytes(body)
        return w.data
    }

    private func makeRPCAcceptErrorReply(xid: UInt32, acceptStat: UInt32) -> Data {
        var w = XDRWriter()
        w.u32(xid)
        w.u32(1)
        w.u32(0)
        w.u32(0); w.u32(0)
        w.u32(acceptStat)
        return w.data
    }

    private func makeRPCRejectReply(xid: UInt32, stat: UInt32) -> Data {
        var w = XDRWriter()
        w.u32(xid)
        w.u32(1)
        w.u32(1) // MSG_DENIED
        w.u32(stat)
        return w.data
    }

    private func readRPCRecord(fd: Int32) -> Data? {
        var assembled = Data()
        while true {
            guard let hdr = readExact(fd: fd, count: 4) else { return nil }
            let raw = (UInt32(hdr[0]) << 24) | (UInt32(hdr[1]) << 16) | (UInt32(hdr[2]) << 8) | UInt32(hdr[3])
            let isLast = (raw & 0x8000_0000) != 0
            let len = Int(raw & 0x7FFF_FFFF)
            guard len >= 0 && len <= 16 * 1024 * 1024 else { return nil }
            if len > 0 {
                guard let frag = readExact(fd: fd, count: len) else { return nil }
                assembled.append(frag)
            }
            if isLast { return assembled }
        }
    }

    private func writeRPCRecord(fd: Int32, payload: Data) -> Bool {
        let len = UInt32(payload.count) | 0x8000_0000
        var frame = Data([
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF)
        ])
        frame.append(payload)
        return writeAll(fd: fd, data: frame)
    }

    private func readExact(fd: Int32, count: Int) -> Data? {
        var out = Data(count: count)
        var offset = 0
        while offset < count {
            let n = out.withUnsafeMutableBytes { ptr in
                Darwin.recv(fd, ptr.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }
            offset += n
        }
        return out
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }
}

// MARK: - XDR Binary Readers & Writers (Big-Endian)

private struct XDRReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.endIndex else { return nil }
        let val = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        offset += 4
        return val
    }

    mutating func u64() -> UInt64? {
        guard let hi = u32(), let lo = u32() else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    mutating func fixed(_ count: Int) -> Data? {
        guard offset + count <= data.endIndex else { return nil }
        let slice = Data(data[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func opaque() -> Data? {
        guard let len = u32() else { return nil }
        let n = Int(len)
        let padded = (n + 3) & ~3
        guard offset + padded <= data.endIndex else { return nil }
        let slice = Data(data[offset..<(offset + n)])
        offset += padded
        return slice
    }

    mutating func string() -> String? {
        guard let d = opaque() else { return nil }
        return String(data: d, encoding: .utf8)
    }

    mutating func skipAuth() -> Bool {
        guard u32() != nil, opaque() != nil else { return false }
        return true
    }
}

private struct XDRWriter {
    var data = Data()

    mutating func u32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32((v >> 32) & 0xFFFFFFFF))
        u32(UInt32(v & 0xFFFFFFFF))
    }

    mutating func opaque(_ bytes: Data) {
        u32(UInt32(bytes.count))
        data.append(bytes)
        let pad = (4 - (bytes.count % 4)) % 4
        if pad > 0 { data.append(Data(count: pad)) }
    }

    mutating func string(_ s: String) {
        opaque(Data(s.utf8))
    }

    mutating func bytes(_ d: Data) {
        data.append(d)
    }
}
