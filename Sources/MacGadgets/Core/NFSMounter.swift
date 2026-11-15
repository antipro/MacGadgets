import AppKit
import Foundation

enum NFSMountError: Error, LocalizedError {
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let msg):
            return "挂载 NFS 磁盘失败：\(msg)"
        }
    }
}

enum NFSMounter {
    static var mountsBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private static let trackedMountsKey = "AndroidDrive.createdMountDirs"

    /// Clean up any stale unmounted or dead mount directories left from an unexpected termination.
    static func cleanupStaleMounts() {
        let tracked = UserDefaults.standard.stringArray(forKey: trackedMountsKey) ?? []
        var remaining: [String] = []
        for path in tracked {
            _ = unmount(mountPoint: path, force: true)
            if FileManager.default.fileExists(atPath: path) && isMounted(atPath: path) {
                remaining.append(path)
            }
        }
        UserDefaults.standard.set(remaining, forKey: trackedMountsKey)
    }

    static func mount(
        port: UInt16,
        exportName: String,
        volumeName: String,
        hostAlias: MDNSHostAlias
    ) throws -> String {
        let fm = FileManager.default

        let sanitized = volumeName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "Android" : sanitized

        // Pick ~/DeviceName (outside hidden ~/Library so Finder shows it just like ~/OrbStack)
        var mountDir = mountsBaseDirectory.appendingPathComponent(baseName, isDirectory: true)
        if fm.fileExists(atPath: mountDir.path) {
            let tracked = Set(UserDefaults.standard.stringArray(forKey: trackedMountsKey) ?? [])
            if tracked.contains(mountDir.path) || isMounted(atPath: mountDir.path) {
                _ = unmount(mountPoint: mountDir.path, force: true)
            }
            if fm.fileExists(atPath: mountDir.path) {
                var idx = 2
                while fm.fileExists(atPath: mountDir.path) {
                    mountDir = mountsBaseDirectory.appendingPathComponent("\(baseName) (\(idx))", isDirectory: true)
                    idx += 1
                }
            }
        }

        try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
        recordTrackedMountDir(mountDir.path)

        // Finder labels the entry in "Locations" by server host name, so use the
        // published <device>.local alias rather than localhost.
        try waitForHostResolution(hostAlias.hostName, timeout: 3.0)

        let options = "nolocks,vers=3,tcp,port=\(port),mountport=\(port),soft,intr,noatime,rsize=65536,wsize=65536,timeo=600,retrans=6"
        let source = "\(hostAlias.hostName):/\(exportName)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
        proc.arguments = ["-o", options, source, mountDir.path]
        let stderrPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderrPipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(proc.terminationStatus)"
            try? fm.removeItem(at: mountDir)
            unrecordTrackedMountDir(mountDir.path)
            throw NFSMountError.mountFailed(errMsg)
        }

        return mountDir.path
    }

    private static func waitForHostResolution(_ hostName: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if resolvesToLoopback(hostName) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        if !resolvesToLoopback(hostName) {
            throw NFSMountError.mountFailed("本地主机名 \(hostName) 解析失败")
        }
    }

    private static func resolvesToLoopback(_ hostName: String) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostName, nil, &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            if let sa = node.pointee.ai_addr {
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    if sin.sin_addr.s_addr == inet_addr("127.0.0.1") { return true }
                } else if sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var addr = sin6.sin6_addr
                    var loop6 = in6addr_loopback
                    if memcmp(&addr, &loop6, MemoryLayout<in6_addr>.size) == 0 { return true }
                }
            }
            cursor = node.pointee.ai_next
        }
        return false
    }

    private static func recordTrackedMountDir(_ path: String) {
        var tracked = UserDefaults.standard.stringArray(forKey: trackedMountsKey) ?? []
        if !tracked.contains(path) {
            tracked.append(path)
            UserDefaults.standard.set(tracked, forKey: trackedMountsKey)
        }
    }

    private static func unrecordTrackedMountDir(_ path: String) {
        var tracked = UserDefaults.standard.stringArray(forKey: trackedMountsKey) ?? []
        tracked.removeAll { $0 == path }
        UserDefaults.standard.set(tracked, forKey: trackedMountsKey)
    }

    @discardableResult
    static func unmount(mountPoint: String, force: Bool = false) -> Bool {
        let url = URL(fileURLWithPath: mountPoint)
        var unmounted = false

        if !force {
            if (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil {
                unmounted = true
            }
        }

        if !unmounted {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/sbin/umount")
            proc.arguments = force ? ["-f", mountPoint] : [mountPoint]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                unmounted = (proc.terminationStatus == 0)
            } catch {
                unmounted = false
            }
        }

        if !unmounted {
            let diskutil = Process()
            diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            diskutil.arguments = force ? ["unmount", "force", mountPoint] : ["unmount", mountPoint]
            diskutil.standardOutput = Pipe()
            diskutil.standardError = Pipe()
            do {
                try diskutil.run()
                diskutil.waitUntilExit()
                unmounted = (diskutil.terminationStatus == 0)
            } catch {
                unmounted = false
            }
        }

        // Remove empty mountpoint directory only if it is no longer a mountpoint
        if unmounted || !isMounted(atPath: mountPoint) {
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: mountPoint), contents.isEmpty {
                try? FileManager.default.removeItem(atPath: mountPoint)
                unrecordTrackedMountDir(mountPoint)
            }
        }

        return unmounted
    }

    private static func isMounted(atPath path: String) -> Bool {
        mountPointIsActive(path)
    }

    /// True when `path` is currently the root of a mounted filesystem.
    static func mountPointIsActive(_ path: String) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return mounted.contains { $0.standardizedFileURL.path == target }
    }

    /// Removes a leftover mount-point directory when nothing is mounted there anymore.
    /// Finder often drops `.DS_Store`/`._*` into a browsed volume, so metadata-only
    /// leftovers are cleaned up before the directory itself is removed.
    static func removeMountPointIfEmpty(_ path: String) {
        guard !mountPointIsActive(path) else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }
        if !contents.isEmpty {
            let metadataNames: Set<String> = [".DS_Store", ".localized"]
            let onlyMetadata = contents.allSatisfy { name in
                metadataNames.contains(name) || name.hasPrefix("._") || name.hasPrefix(".Spotlight")
            }
            guard onlyMetadata else { return }
            for name in contents {
                try? fm.removeItem(atPath: (path as NSString).appendingPathComponent(name))
            }
        }
        try? fm.removeItem(atPath: path)
        unrecordTrackedMountDir(path)
    }
}
