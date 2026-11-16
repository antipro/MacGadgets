import Foundation

struct VFSEntry: Equatable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let createdAt: Date
    let modifiedAt: Date
    let storageID: UInt32
    let handle: UInt32
}

enum VFSError: Error, LocalizedError {
    case notFound
    case alreadyExists
    case isDirectory
    case notDirectory
    case readOnlyStorage
    case invalidPath
    case mtpError(Error)

    var errorDescription: String? {
        switch self {
        case .notFound: return "文件或目录不存在"
        case .alreadyExists: return "目标已存在"
        case .isDirectory: return "目标是文件夹"
        case .notDirectory: return "目标不是文件夹"
        case .readOnlyStorage: return "手机存储为只读"
        case .invalidPath: return "无效的路径"
        case .mtpError(let err): return err.localizedDescription
        }
    }
}

/// Bridges POSIX/WebDAV paths to an MTPClientProtocol instance, adding:
/// - Single-storage root flattening (feels like a USB flash drive)
/// - Multi-storage virtual folders
/// - In-memory isolation of macOS Finder metadata sidecars (._*, .DS_Store, .Spotlight-V100, etc.)
/// - Zero-byte PUT staging for macOS webdavfs copy sequences
/// - Short-lived directory caching & temp-file read caching for Range requests
final class MTPVirtualFileSystem {
    struct StorageRoot {
        let storageID: UInt32
        let folderName: String
        let info: MTPStorageInfo
    }

    private struct SidecarEntry {
        var isDirectory: Bool
        var data: Data
        var createdAt: Date
        var modifiedAt: Date
    }

    private let client: MTPClientProtocol
    private let lock = NSLock()
    private let cacheTTL: TimeInterval = 2.5

    private var storages: [StorageRoot] = []
    private var directoryCache: [String: (timestamp: Date, entries: [VFSEntry])] = [:]
    private var sidecars: [String: SidecarEntry] = [:]
    private var pendingZeroByteFiles: [String: Date] = [:]
    private var downloadedReadCache: [UInt32: (url: URL, modifiedAt: Date?, size: UInt64)] = [:]
    private var downloadedOrder: [UInt32] = []
    private let tempDir: URL

    init(client: MTPClientProtocol) {
        self.client = client
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacGadgetsMTP-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir
    }

    deinit {
        cleanupTempFiles()
    }

    func cleanupTempFiles() {
        lock.lock()
        downloadedReadCache.removeAll()
        downloadedOrder.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    func refreshStorages() throws -> [StorageRoot] {
        let ids = try client.getStorageIDs()
        var loaded: [StorageRoot] = []
        var usedNames: Set<String> = []

        for id in ids {
            guard let info = try? client.getStorageInfo(storageID: id) else { continue }
            var baseName = sanitizeFilename(info.displayName)
            if baseName.isEmpty { baseName = "Storage" }
            var candidate = baseName
            var idx = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(baseName) \(idx)"
                idx += 1
            }
            usedNames.insert(candidate.lowercased())
            loaded.append(StorageRoot(storageID: id, folderName: candidate, info: info))
        }

        lock.lock()
        self.storages = loaded
        self.directoryCache.removeAll()
        lock.unlock()
        return loaded
    }

    func storageSummary() -> (totalBytes: UInt64, freeBytes: UInt64, storages: [MTPStorageInfo]) {
        lock.lock()
        let current = storages
        lock.unlock()

        var total: UInt64 = 0
        var free: UInt64 = 0
        for s in current {
            total &+= s.info.maxCapacity
            free &+= s.info.freeSpaceInBytes
        }
        return (total, free, current.map { $0.info })
    }

    func refreshStorageCapacity() {
        lock.lock()
        let current = storages
        lock.unlock()

        var updated: [StorageRoot] = []
        for s in current {
            if let info = try? client.getStorageInfo(storageID: s.storageID) {
                updated.append(StorageRoot(storageID: s.storageID, folderName: s.folderName, info: info))
            } else {
                updated.append(s)
            }
        }
        lock.lock()
        self.storages = updated
        lock.unlock()
    }

    // MARK: - Path Helpers

    static func normalizePath(_ rawPath: String) -> String {
        var p = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        var components: [String] = []
        for comp in p.split(separator: "/") {
            if comp == "." { continue }
            if comp == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(String(comp))
        }
        return "/" + components.joined(separator: "/")
    }

    static func parentPath(of normalizedPath: String) -> String {
        if normalizedPath == "/" { return "/" }
        let comps = normalizedPath.split(separator: "/").dropLast()
        return "/" + comps.joined(separator: "/")
    }

    static func lastComponent(of normalizedPath: String) -> String {
        if normalizedPath == "/" { return "" }
        return String(normalizedPath.split(separator: "/").last ?? "")
    }

    static func isMacOSMetadataPath(_ normalizedPath: String) -> Bool {
        if normalizedPath == "/" { return false }
        let comps = normalizedPath.split(separator: "/").map(String.init)
        guard let last = comps.last else { return false }

        if last.hasPrefix("._") { return true }

        let metadataNames: Set<String> = [
            ".DS_Store",
            ".Spotlight-V100",
            ".Trashes",
            ".TemporaryItems",
            ".fseventsd",
            ".ql_disablethumbnails",
            ".ql_disablecache",
            ".metadata_never_index",
            ".metadata_never_index_unless_rootfs",
            ".metadata_direct_scope_only",
            ".hidden"
        ]
        if metadataNames.contains(last) { return true }

        let metadataDirs: Set<String> = [
            ".Spotlight-V100",
            ".Trashes",
            ".TemporaryItems",
            ".fseventsd"
        ]
        for comp in comps.dropLast() {
            if metadataDirs.contains(comp) {
                return true
            }
        }
        return false
    }

    private func sanitizeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    // MARK: - VFS Operations

    func stat(path rawPath: String) throws -> VFSEntry {
        let path = Self.normalizePath(rawPath)

        if Self.isMacOSMetadataPath(path) {
            lock.lock()
            let sidecar = sidecars[path]
            lock.unlock()
            if let sidecar {
                return VFSEntry(
                    path: path,
                    name: Self.lastComponent(of: path),
                    isDirectory: sidecar.isDirectory,
                    size: UInt64(sidecar.data.count),
                    createdAt: sidecar.createdAt,
                    modifiedAt: sidecar.modifiedAt,
                    storageID: 0,
                    handle: 0
                )
            }
            throw VFSError.notFound
        }

        if path == "/" {
            let now = Date()
            return VFSEntry(
                path: "/",
                name: "",
                isDirectory: true,
                size: 0,
                createdAt: now,
                modifiedAt: now,
                storageID: 0,
                handle: MTPClient.rootParentHandle
            )
        }

        lock.lock()
        let pendingDate = pendingZeroByteFiles[path]
        lock.unlock()
        if let pendingDate {
            return VFSEntry(
                path: path,
                name: Self.lastComponent(of: path),
                isDirectory: false,
                size: 0,
                createdAt: pendingDate,
                modifiedAt: pendingDate,
                storageID: 0,
                handle: 0
            )
        }

        let parent = Self.parentPath(of: path)
        let name = Self.lastComponent(of: path)
        let siblings = try listDirectory(path: parent)
        if let match = siblings.first(where: { $0.name == name }) {
            return match
        }
        throw VFSError.notFound
    }

    func listDirectory(path rawPath: String) throws -> [VFSEntry] {
        let path = Self.normalizePath(rawPath)

        if Self.isMacOSMetadataPath(path) {
            lock.lock()
            defer { lock.unlock() }
            guard let dir = sidecars[path] else { throw VFSError.notFound }
            guard dir.isDirectory else { throw VFSError.notDirectory }
            return sidecarChildrenLocked(of: path)
        }

        lock.lock()
        if let cached = directoryCache[path], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            let result = mergeVirtualEntriesLocked(parentPath: path, base: cached.entries)
            lock.unlock()
            return result
        }
        let currentStorages = storages
        lock.unlock()

        if currentStorages.isEmpty {
            _ = try refreshStorages()
        }

        lock.lock()
        let activeStorages = storages
        lock.unlock()

        var entries: [VFSEntry] = []

        if path == "/" && activeStorages.count > 1 {
            let now = Date()
            for storage in activeStorages {
                entries.append(
                    VFSEntry(
                        path: "/" + storage.folderName,
                        name: storage.folderName,
                        isDirectory: true,
                        size: 0,
                        createdAt: now,
                        modifiedAt: now,
                        storageID: storage.storageID,
                        handle: MTPClient.rootParentHandle
                    )
                )
            }
        } else if !activeStorages.isEmpty {
            let target = try resolveDirectoryHandle(path: path)
            let handles = try client.getObjectHandles(storageID: target.storageID, parentHandle: target.handle)
            var seenNames: Set<String> = []
            for h in handles {
                guard let info = try? client.getObjectInfo(handle: h) else { continue }
                let cleanName = sanitizeFilename(info.filename)
                if cleanName.isEmpty || seenNames.contains(cleanName) { continue }
                seenNames.insert(cleanName)
                let childPath = path == "/" ? "/\(cleanName)" : "\(path)/\(cleanName)"
                let mtime = info.dateModified ?? info.dateCreated ?? Date()
                let ctime = info.dateCreated ?? mtime
                entries.append(
                    VFSEntry(
                        path: childPath,
                        name: cleanName,
                        isDirectory: info.isFolder,
                        size: info.isFolder ? 0 : info.size,
                        createdAt: ctime,
                        modifiedAt: mtime,
                        storageID: info.storageID,
                        handle: h
                    )
                )
            }
        }

        lock.lock()
        directoryCache[path] = (Date(), entries)
        let merged = mergeVirtualEntriesLocked(parentPath: path, base: entries)
        lock.unlock()
        return merged
    }

    func readBytes(path rawPath: String, offset: UInt64, length: Int) throws -> Data {
        let path = Self.normalizePath(rawPath)

        if Self.isMacOSMetadataPath(path) {
            lock.lock()
            let sidecar = sidecars[path]
            lock.unlock()
            guard let sidecar else { throw VFSError.notFound }
            guard !sidecar.isDirectory else { throw VFSError.isDirectory }
            let start = Int(min(offset, UInt64(sidecar.data.count)))
            let end = min(sidecar.data.count, start + max(0, length))
            return sidecar.data.subdata(in: start..<end)
        }

        lock.lock()
        let isPending = pendingZeroByteFiles[path] != nil
        lock.unlock()
        if isPending { return Data() }

        let entry = try stat(path: path)
        guard !entry.isDirectory else { throw VFSError.isDirectory }
        if entry.size == 0 || offset >= entry.size || length <= 0 {
            return Data()
        }

        let clampedLength = Int(min(UInt64(length), entry.size - offset))

        // Try partial read if device supports it
        if let partial = try? client.getPartialObject(
            handle: entry.handle,
            offset: offset,
            maxBytes: UInt32(min(clampedLength, Int(UInt32.max)))
        ) {
            return partial
        }

        // Fallback: download to temp file cache and read requested slice
        let cachedFile = try cachedDownloadFile(for: entry)
        let fh = try FileHandle(forReadingFrom: cachedFile)
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)
        return try fh.read(upToCount: clampedLength) ?? Data()
    }

    func stageOrWriteFile(path rawPath: String, tempFileURL: URL, fileSize: UInt64) throws {
        let path = Self.normalizePath(rawPath)
        guard path != "/" else { throw VFSError.isDirectory }

        if Self.isMacOSMetadataPath(path) {
            let data = (try? Data(contentsOf: tempFileURL)) ?? Data()
            let now = Date()
            lock.lock()
            sidecars[path] = SidecarEntry(isDirectory: false, data: data, createdAt: now, modifiedAt: now)
            lock.unlock()
            return
        }

        // Handle macOS webdavfs 0-byte pre-create PUT before LOCK + actual PUT
        if fileSize == 0 {
            let existing = try? stat(path: path)
            if existing == nil {
                // Verify parent exists before staging
                let parent = Self.parentPath(of: path)
                let parentEntry = try stat(path: parent)
                guard parentEntry.isDirectory else { throw VFSError.notDirectory }

                lock.lock()
                pendingZeroByteFiles[path] = Date()
                lock.unlock()
                return
            }
        }

        try writeRealFile(path: path, tempFileURL: tempFileURL, fileSize: fileSize)
    }

    func flushPendingZeroByteIfNeeded(path rawPath: String) {
        let path = Self.normalizePath(rawPath)
        lock.lock()
        let wasPending = pendingZeroByteFiles.removeValue(forKey: path) != nil
        lock.unlock()

        guard wasPending else { return }
        let emptyFile = tempDir.appendingPathComponent("empty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: emptyFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: emptyFile) }
        _ = try? writeRealFile(path: path, tempFileURL: emptyFile, fileSize: 0)
    }

    @discardableResult
    private func writeRealFile(path: String, tempFileURL: URL, fileSize: UInt64) throws -> UInt32 {
        lock.lock()
        pendingZeroByteFiles.removeValue(forKey: path)
        lock.unlock()

        let parent = Self.parentPath(of: path)
        let filename = Self.lastComponent(of: path)
        let targetDir = try resolveDirectoryHandle(path: parent)

        // Check storage read-only
        lock.lock()
        let isReadOnly = storages.first(where: { $0.storageID == targetDir.storageID })?.info.isReadOnly ?? false
        lock.unlock()
        if isReadOnly {
            throw VFSError.readOnlyStorage
        }

        // If target already exists on phone, MTP requires deleting old object first
        if let existing = try? stat(path: path) {
            if existing.isDirectory { throw VFSError.isDirectory }
            if existing.handle != 0 {
                try client.deleteObject(handle: existing.handle)
                invalidateReadCache(handle: existing.handle)
                invalidateDirectory(parent)
            }
        }

        let newHandle: UInt32
        do {
            newHandle = try client.uploadFile(
                storageID: targetDir.storageID,
                parentHandle: targetDir.handle,
                filename: filename,
                fileURL: tempFileURL,
                fileSize: fileSize
            )
        } catch {
            // One retry after clearing a possibly stalled USB endpoint.
            client.resetSession()
            newHandle = try client.uploadFile(
                storageID: targetDir.storageID,
                parentHandle: targetDir.handle,
                filename: filename,
                fileURL: tempFileURL,
                fileSize: fileSize
            )
        }
        invalidateDirectory(parent)
        refreshStorageCapacity()
        return newHandle
    }

    func createDirectory(path rawPath: String) throws {
        let path = Self.normalizePath(rawPath)
        guard path != "/" else { throw VFSError.alreadyExists }

        if Self.isMacOSMetadataPath(path) {
            let now = Date()
            lock.lock()
            sidecars[path] = SidecarEntry(isDirectory: true, data: Data(), createdAt: now, modifiedAt: now)
            lock.unlock()
            return
        }

        if (try? stat(path: path)) != nil {
            throw VFSError.alreadyExists
        }

        let parent = Self.parentPath(of: path)
        let name = Self.lastComponent(of: path)
        let targetDir = try resolveDirectoryHandle(path: parent)

        _ = try client.createFolder(storageID: targetDir.storageID, parentHandle: targetDir.handle, name: name)
        invalidateDirectory(parent)
    }

    func delete(path rawPath: String) throws {
        let path = Self.normalizePath(rawPath)
        guard path != "/" else { throw VFSError.invalidPath }

        if Self.isMacOSMetadataPath(path) {
            lock.lock()
            let prefix = path + "/"
            sidecars.removeValue(forKey: path)
            for key in sidecars.keys where key.hasPrefix(prefix) {
                sidecars.removeValue(forKey: key)
            }
            lock.unlock()
            return
        }

        lock.lock()
        let wasPending = pendingZeroByteFiles.removeValue(forKey: path) != nil
        lock.unlock()
        if wasPending { return }

        let entry = try stat(path: path)
        if entry.handle == MTPClient.rootParentHandle {
            throw VFSError.invalidPath
        }

        do {
            try client.deleteObject(handle: entry.handle)
        } catch {
            if entry.isDirectory {
                // Some MTP devices reject deleting non-empty folders directly; clear children first
                let children = try listDirectory(path: path)
                for child in children {
                    try delete(path: child.path)
                }
                try client.deleteObject(handle: entry.handle)
            } else {
                throw error
            }
        }

        invalidateReadCache(handle: entry.handle)
        invalidateDirectory(Self.parentPath(of: path))
        invalidateDirectoryPrefix(path)
        refreshStorageCapacity()
    }

    func move(from rawFrom: String, to rawTo: String, overwrite: Bool) throws {
        let from = Self.normalizePath(rawFrom)
        let to = Self.normalizePath(rawTo)
        guard from != "/", to != "/", from != to else { throw VFSError.invalidPath }

        if Self.isMacOSMetadataPath(from) || Self.isMacOSMetadataPath(to) {
            lock.lock()
            defer { lock.unlock() }
            guard let item = sidecars.removeValue(forKey: from) else { throw VFSError.notFound }
            sidecars[to] = item
            return
        }

        let srcEntry = try stat(path: from)
        let srcParent = Self.parentPath(of: from)
        let dstParent = Self.parentPath(of: to)
        let srcName = Self.lastComponent(of: from)
        let dstName = Self.lastComponent(of: to)

        if let existingDst = try? stat(path: to) {
            if !overwrite { throw VFSError.alreadyExists }
            if existingDst.handle != srcEntry.handle {
                try delete(path: to)
            }
        }

        if srcParent == dstParent {
            do {
                try client.renameObject(handle: srcEntry.handle, newName: dstName)
                invalidateDirectory(srcParent)
                invalidateDirectoryPrefix(from)
                return
            } catch {
                // Fallback for devices that don't support SetObjectPropValue
                try copyRecursive(srcEntry: srcEntry, destinationPath: to)
                try delete(path: from)
                return
            }
        }

        let dstParentTarget = try resolveDirectoryHandle(path: dstParent)
        do {
            try client.moveObject(
                handle: srcEntry.handle,
                targetStorageID: dstParentTarget.storageID,
                targetParentHandle: dstParentTarget.handle
            )
            if srcName != dstName {
                try client.renameObject(handle: srcEntry.handle, newName: dstName)
            }
            invalidateDirectory(srcParent)
            invalidateDirectory(dstParent)
            invalidateDirectoryPrefix(from)
        } catch {
            try copyRecursive(srcEntry: srcEntry, destinationPath: to)
            try delete(path: from)
        }
    }

    func copy(from rawFrom: String, to rawTo: String, overwrite: Bool) throws {
        let from = Self.normalizePath(rawFrom)
        let to = Self.normalizePath(rawTo)
        guard from != "/", to != "/", from != to else { throw VFSError.invalidPath }

        if Self.isMacOSMetadataPath(from) || Self.isMacOSMetadataPath(to) {
            lock.lock()
            defer { lock.unlock() }
            guard let item = sidecars[from] else { throw VFSError.notFound }
            sidecars[to] = item
            return
        }

        let srcEntry = try stat(path: from)
        if (try? stat(path: to)) != nil {
            if !overwrite { throw VFSError.alreadyExists }
            try delete(path: to)
        }
        try copyRecursive(srcEntry: srcEntry, destinationPath: to)
    }

    // MARK: - Internal Helpers

    private func copyRecursive(srcEntry: VFSEntry, destinationPath: String) throws {
        let dstParent = Self.parentPath(of: destinationPath)
        let dstName = Self.lastComponent(of: destinationPath)
        let dstDir = try resolveDirectoryHandle(path: dstParent)

        if srcEntry.isDirectory {
            _ = try client.createFolder(storageID: dstDir.storageID, parentHandle: dstDir.handle, name: dstName)
            invalidateDirectory(dstParent)
            let children = try listDirectory(path: srcEntry.path)
            for child in children {
                let childDst = destinationPath == "/" ? "/\(child.name)" : "\(destinationPath)/\(child.name)"
                try copyRecursive(srcEntry: child, destinationPath: childDst)
            }
        } else {
            // Try fast device-side CopyObject if keeping same filename
            if srcEntry.name == dstName,
               (try? client.copyObject(
                   handle: srcEntry.handle,
                   targetStorageID: dstDir.storageID,
                   targetParentHandle: dstDir.handle
               )) != nil {
                invalidateDirectory(dstParent)
                refreshStorageCapacity()
                return
            }

            let tempFile = tempDir.appendingPathComponent("copy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempFile) }
            try client.getObjectToFile(handle: srcEntry.handle, destinationURL: tempFile)
            let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? srcEntry.size
            _ = try client.uploadFile(
                storageID: dstDir.storageID,
                parentHandle: dstDir.handle,
                filename: dstName,
                fileURL: tempFile,
                fileSize: size
            )
            invalidateDirectory(dstParent)
            refreshStorageCapacity()
        }
    }

    private func resolveDirectoryHandle(path: String) throws -> (storageID: UInt32, handle: UInt32) {
        lock.lock()
        let activeStorages = storages
        lock.unlock()

        guard !activeStorages.isEmpty else {
            throw VFSError.notFound
        }

        let comps = path.split(separator: "/").map(String.init)

        if activeStorages.count == 1 {
            let storageID = activeStorages[0].storageID
            if comps.isEmpty {
                return (storageID, MTPClient.rootParentHandle)
            }
            var currentHandle = MTPClient.rootParentHandle
            var currentPath = ""
            for comp in comps {
                currentPath += "/\(comp)"
                let next = try findChild(inStorage: storageID, parentHandle: currentHandle, parentPath: currentPath == "/\(comp)" ? "/" : Self.parentPath(of: currentPath), name: comp)
                guard next.isDirectory else { throw VFSError.notDirectory }
                currentHandle = next.handle
            }
            return (storageID, currentHandle)
        } else {
            guard let storageName = comps.first else {
                throw VFSError.isDirectory
            }
            guard let storage = activeStorages.first(where: { $0.folderName == storageName }) else {
                throw VFSError.notFound
            }
            var currentHandle = MTPClient.rootParentHandle
            var currentPath = "/\(storageName)"
            for comp in comps.dropFirst() {
                let parentPath = currentPath
                currentPath += "/\(comp)"
                let next = try findChild(inStorage: storage.storageID, parentHandle: currentHandle, parentPath: parentPath, name: comp)
                guard next.isDirectory else { throw VFSError.notDirectory }
                currentHandle = next.handle
            }
            return (storage.storageID, currentHandle)
        }
    }

    private func findChild(
        inStorage storageID: UInt32,
        parentHandle: UInt32,
        parentPath: String,
        name: String
    ) throws -> VFSEntry {
        lock.lock()
        if let cached = directoryCache[parentPath], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            if let hit = cached.entries.first(where: { $0.name == name }) {
                lock.unlock()
                return hit
            }
        }
        lock.unlock()

        let handles = try client.getObjectHandles(storageID: storageID, parentHandle: parentHandle)
        for h in handles {
            guard let info = try? client.getObjectInfo(handle: h) else { continue }
            let clean = sanitizeFilename(info.filename)
            if clean == name {
                let childPath = parentPath == "/" ? "/\(clean)" : "\(parentPath)/\(clean)"
                let mtime = info.dateModified ?? info.dateCreated ?? Date()
                let ctime = info.dateCreated ?? mtime
                return VFSEntry(
                    path: childPath,
                    name: clean,
                    isDirectory: info.isFolder,
                    size: info.isFolder ? 0 : info.size,
                    createdAt: ctime,
                    modifiedAt: mtime,
                    storageID: info.storageID,
                    handle: h
                )
            }
        }
        throw VFSError.notFound
    }

    private func cachedDownloadFile(for entry: VFSEntry) throws -> URL {
        lock.lock()
        if let cached = downloadedReadCache[entry.handle],
           cached.size == entry.size,
           FileManager.default.fileExists(atPath: cached.url.path) {
            lock.unlock()
            return cached.url
        }
        lock.unlock()

        let dst = tempDir.appendingPathComponent("read-\(entry.handle)-\(UUID().uuidString)")
        try client.getObjectToFile(handle: entry.handle, destinationURL: dst)

        lock.lock()
        downloadedReadCache[entry.handle] = (dst, entry.modifiedAt, entry.size)
        downloadedOrder.removeAll { $0 == entry.handle }
        downloadedOrder.append(entry.handle)
        while downloadedOrder.count > 4 {
            let evicted = downloadedOrder.removeFirst()
            if let old = downloadedReadCache.removeValue(forKey: evicted) {
                try? FileManager.default.removeItem(at: old.url)
            }
        }
        lock.unlock()
        return dst
    }

    private func invalidateReadCache(handle: UInt32) {
        lock.lock()
        if let removed = downloadedReadCache.removeValue(forKey: handle) {
            try? FileManager.default.removeItem(at: removed.url)
        }
        downloadedOrder.removeAll { $0 == handle }
        lock.unlock()
    }

    private func invalidateDirectory(_ path: String) {
        lock.lock()
        directoryCache.removeValue(forKey: path)
        lock.unlock()
    }

    private func invalidateDirectoryPrefix(_ prefixPath: String) {
        let prefix = prefixPath == "/" ? "/" : prefixPath + "/"
        lock.lock()
        for key in directoryCache.keys {
            if key == prefixPath || key.hasPrefix(prefix) {
                directoryCache.removeValue(forKey: key)
            }
        }
        lock.unlock()
    }

    private func mergeVirtualEntriesLocked(parentPath: String, base: [VFSEntry]) -> [VFSEntry] {
        var result = base
        let existingNames = Set(base.map { $0.name })
        let prefix = parentPath == "/" ? "/" : parentPath + "/"

        for (p, date) in pendingZeroByteFiles {
            guard p.hasPrefix(prefix) else { continue }
            let rest = String(p.dropFirst(prefix.count))
            guard !rest.isEmpty, !rest.contains("/"), !existingNames.contains(rest) else { continue }
            result.append(
                VFSEntry(
                    path: p,
                    name: rest,
                    isDirectory: false,
                    size: 0,
                    createdAt: date,
                    modifiedAt: date,
                    storageID: 0,
                    handle: 0
                )
            )
        }
        let allNames = Set(result.map { $0.name })
        for sidecar in sidecarChildrenLocked(of: parentPath) where !allNames.contains(sidecar.name) {
            result.append(sidecar)
        }
        return result
    }

    private func sidecarChildrenLocked(of parentPath: String) -> [VFSEntry] {
        let prefix = parentPath == "/" ? "/" : parentPath + "/"
        var out: [VFSEntry] = []
        for (p, entry) in sidecars {
            guard p.hasPrefix(prefix) else { continue }
            let rest = String(p.dropFirst(prefix.count))
            guard !rest.isEmpty, !rest.contains("/") else { continue }
            out.append(
                VFSEntry(
                    path: p,
                    name: rest,
                    isDirectory: entry.isDirectory,
                    size: UInt64(entry.data.count),
                    createdAt: entry.createdAt,
                    modifiedAt: entry.modifiedAt,
                    storageID: 0,
                    handle: 0
                )
            )
        }
        return out
    }
}
