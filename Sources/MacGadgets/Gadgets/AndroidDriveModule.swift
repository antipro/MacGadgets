import AppKit
import Combine
import Foundation

@MainActor
final class AndroidDriveModule: BaseGadgetModule, ObservableObject {
    override var identifier: String { "android-drive" }
    override var displayName: String { L10n.tr("android.title") }

    private enum DefaultsKey {
        static let autoMount = "AndroidDrive.autoMount"
        static let openFinderOnMount = "AndroidDrive.openFinderOnMount"
    }

    struct MountedDevice: Equatable {
        let locationID: UInt32
        let deviceName: String
        let manufacturer: String
        let serialNumber: String
        let mountPoint: String
        var totalBytes: UInt64
        var freeBytes: UInt64
        let storageNames: [String]
        let isLikelyPTPOnly: Bool
        let finderName: String
    }

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting(deviceName: String)
        case mounted(MountedDevice)
        case error(message: String, canReleasePTPD: Bool)
    }

    private let defaults = UserDefaults.standard
    private let workQueue = DispatchQueue(label: "com.macgadgets.android-drive.work")
    private var hotplugMonitor: USBHotplugMonitor?
    private var healthTimer: Timer?
    private var unmountObserver: NSObjectProtocol?

    private var activeClient: MTPClient?
    private var activeVFS: MTPVirtualFileSystem?
    private var activeServer: NFSv3Server?
    private var activeHostAlias: MDNSHostAlias?
    private var activeLocationID: UInt32?
    private var activeMountPoint: String?
    private var manuallyEjectedLocationID: UInt32?
    private var isConnecting = false

    @Published var isAutoMountEnabled: Bool {
        didSet {
            defaults.set(isAutoMountEnabled, forKey: DefaultsKey.autoMount)
            if isAutoMountEnabled {
                manuallyEjectedLocationID = nil
                scanAndConnectIfNeeded(userInitiated: false)
            }
            onStateChange?()
        }
    }

    @Published var openFinderOnMount: Bool {
        didSet {
            defaults.set(openFinderOnMount, forKey: DefaultsKey.openFinderOnMount)
        }
    }

    @Published private(set) var state: ConnectionState = .idle

    override var statusBarSymbolName: String? {
        if case .mounted = state {
            return "externaldrive.fill.badge.checkmark"
        }
        return nil
    }

    var isMounted: Bool {
        if case .mounted = state { return true }
        return false
    }

    var summaryText: String {
        switch state {
        case .idle:
            return L10n.tr("android.summary.idle")
        case .scanning:
            return L10n.tr("android.summary.scanning")
        case .connecting(let name):
            return L10n.tr("android.summary.connecting", name)
        case .mounted(let dev):
            return L10n.tr("android.summary.mounted", dev.deviceName, dev.mountPoint)
        case .error(let msg, _):
            return L10n.tr("android.summary.error", msg)
        }
    }

    override init() {
        if defaults.object(forKey: DefaultsKey.autoMount) == nil {
            self.isAutoMountEnabled = true
        } else {
            self.isAutoMountEnabled = defaults.bool(forKey: DefaultsKey.autoMount)
        }
        if defaults.object(forKey: DefaultsKey.openFinderOnMount) == nil {
            self.openFinderOnMount = true
        } else {
            self.openFinderOnMount = defaults.bool(forKey: DefaultsKey.openFinderOnMount)
        }
        super.init()

        NFSMounter.cleanupStaleMounts()
        setupObservers()
        if isAutoMountEnabled {
            scanAndConnectIfNeeded(userInitiated: false)
        }
    }

    // MARK: - User Actions

    func rescanAndMount() {
        manuallyEjectedLocationID = nil
        scanAndConnectIfNeeded(userInitiated: true)
    }

    func openInFinder() {
        guard case .mounted(let dev) = state else { return }
        let url = URL(fileURLWithPath: dev.mountPoint)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSWorkspace.shared.open(url)
    }

    func eject() {
        if let loc = activeLocationID {
            manuallyEjectedLocationID = loc
        }
        teardownActiveSession(forceUnmount: false)
    }

    func releaseCameraLockAndRetry() {
        manuallyEjectedLocationID = nil
        state = .scanning
        onStateChange?()

        workQueue.async { [weak self] in
            Self.terminatePTPCameraDaemon()
            Thread.sleep(forTimeInterval: 0.5)
            let target = self
            DispatchQueue.main.async {
                target?.scanAndConnectIfNeeded(userInitiated: true)
            }
        }
    }

    override func refreshMenuState() {
        guard case .mounted(let dev) = state else { return }
        let vfs = activeVFS
        workQueue.async { [weak self] in
            let target = self
            if !IOKitMTPTransport.isDevicePresent(locationID: dev.locationID) {
                DispatchQueue.main.async {
                    target?.teardownActiveSession(forceUnmount: true)
                }
                return
            }
            if let vfs {
                vfs.refreshStorageCapacity()
                let summary = vfs.storageSummary()
                DispatchQueue.main.async {
                    guard let target else { return }
                    if case .mounted(var current) = target.state, current.locationID == dev.locationID {
                        current.totalBytes = summary.totalBytes
                        current.freeBytes = summary.freeBytes
                        target.state = .mounted(current)
                    }
                }
            }
        }
    }

    override func shutdown() {
        healthTimer?.invalidate()
        healthTimer = nil
        hotplugMonitor?.stop()
        hotplugMonitor = nil
        if let unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver)
            self.unmountObserver = nil
        }

        // Synchronously unmount & close during app termination
        let mp = activeMountPoint
        let server = activeServer
        let client = activeClient
        let vfs = activeVFS
        let hostAlias = activeHostAlias

        activeMountPoint = nil
        activeServer = nil
        activeClient = nil
        activeVFS = nil
        activeHostAlias = nil
        activeLocationID = nil

        if let mp {
            _ = NFSMounter.unmount(mountPoint: mp, force: true)
        }
        server?.stop()
        client?.close()
        hostAlias?.stop()
        vfs?.cleanupTempFiles()
    }

    // MARK: - Observers & Hotplug

    private func setupObservers() {
        let monitor = USBHotplugMonitor { [weak self] in
            Task { @MainActor in
                self?.handleUSBTopologyChanged()
            }
        }
        monitor.start()
        self.hotplugMonitor = monitor

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let path = notification.userInfo?["NSDevicePath"] as? String else { return }
            let target = self
            DispatchQueue.main.async {
                target?.handleSystemDidUnmount(path: path)
            }
        }
    }

    private func handleSystemDidUnmount(path: String) {
        guard let activeMountPoint, path == activeMountPoint else { return }
        if let loc = activeLocationID {
            manuallyEjectedLocationID = loc
        }
        // Volume was already unmounted by Finder/system; clean up server & MTP
        teardownActiveSession(forceUnmount: false, alreadyUnmounted: true)
    }

    private func handleUSBTopologyChanged() {
        if case .mounted(let dev) = state {
            workQueue.async { [weak self] in
                let target = self
                let stillPresent = IOKitMTPTransport.isDevicePresent(locationID: dev.locationID)
                if !stillPresent {
                    DispatchQueue.main.async {
                        target?.manuallyEjectedLocationID = nil
                        target?.teardownActiveSession(forceUnmount: true)
                    }
                }
            }
            return
        }

        if let ejectedLoc = manuallyEjectedLocationID {
            workQueue.async { [weak self] in
                let target = self
                if !IOKitMTPTransport.isDevicePresent(locationID: ejectedLoc) {
                    DispatchQueue.main.async {
                        target?.manuallyEjectedLocationID = nil
                        if target?.isAutoMountEnabled == true {
                            target?.scanAndConnectIfNeeded(userInitiated: false)
                        }
                    }
                }
            }
            return
        }

        if isAutoMountEnabled {
            scanAndConnectIfNeeded(userInitiated: false)
        }
    }

    // MARK: - Scan & Mount Pipeline

    private func scanAndConnectIfNeeded(userInitiated: Bool) {
        guard !isConnecting else { return }
        if case .mounted = state { return }

        isConnecting = true
        if userInitiated {
            state = .scanning
            onStateChange?()
        }

        let ejectedLoc = manuallyEjectedLocationID
        let shouldOpenFinder = openFinderOnMount

        workQueue.async { [weak self] in
            guard let self else { return }
            let candidates = IOKitMTPTransport.enumerateCandidates()

            guard let candidate = candidates.first(where: { $0.locationID != ejectedLoc }) else {
                Task { @MainActor in
                    self.isConnecting = false
                    if userInitiated {
                        self.state = .error(
                            message: L10n.tr("android.error.no_device"),
                            canReleasePTPD: false
                        )
                    } else if case .scanning = self.state {
                        self.state = .idle
                    }
                    self.onStateChange?()
                }
                return
            }

            Task { @MainActor in
                self.state = .connecting(deviceName: candidate.fallbackDisplayName)
                self.onStateChange?()
            }

            do {
                let transport = try IOKitMTPTransport.open(candidate: candidate)
                let client = MTPClient(transport: transport)
                do {
                    try client.openSession()
                    let deviceInfo = try client.getDeviceInfo()
                    let vfs = MTPVirtualFileSystem(client: client)
                    let storages = try vfs.refreshStorages()

                    guard !storages.isEmpty else {
                        client.close()
                        vfs.cleanupTempFiles()
                        Task { @MainActor in
                            self.isConnecting = false
                            self.state = .error(
                                message: L10n.tr("android.error.no_storage"),
                                canReleasePTPD: false
                            )
                            self.onStateChange?()
                        }
                        return
                    }

                    let rawName = deviceInfo.displayName.isEmpty ? candidate.fallbackDisplayName : deviceInfo.displayName
                    let volumeName = Self.sanitizeVolumeName(rawName)
                    let server = NFSv3Server(vfs: vfs, exportName: volumeName)
                    server.onTransportFailure = { [weak self] reason in
                        DispatchQueue.main.async {
                            self?.handleTransportFailure(reason: reason)
                        }
                    }
                    let port = try server.start()

                    let hostAlias: MDNSHostAlias
                    do {
                        hostAlias = try MDNSHostAlias(label: MDNSHostAlias.sanitize(volumeName))
                    } catch {
                        server.stop()
                        client.close()
                        vfs.cleanupTempFiles()
                        throw error
                    }

                    let mountPoint: String
                    do {
                        mountPoint = try NFSMounter.mount(
                            port: port,
                            exportName: server.exportName,
                            volumeName: volumeName,
                            hostAlias: hostAlias
                        )
                    } catch {
                        hostAlias.stop()
                        server.stop()
                        client.close()
                        vfs.cleanupTempFiles()
                        throw error
                    }

                    let summary = vfs.storageSummary()
                    let rootNames = Set(((try? vfs.listDirectory(path: "/")) ?? []).map { $0.name })
                    let likelyPTP = !rootNames.isEmpty && rootNames.isSubset(of: ["DCIM", "Pictures"])
                    let mounted = MountedDevice(
                        locationID: candidate.locationID,
                        deviceName: volumeName,
                        manufacturer: deviceInfo.manufacturer.isEmpty ? candidate.manufacturer : deviceInfo.manufacturer,
                        serialNumber: deviceInfo.serialNumber.isEmpty ? candidate.serialNumber : deviceInfo.serialNumber,
                        mountPoint: mountPoint,
                        totalBytes: summary.totalBytes,
                        freeBytes: summary.freeBytes,
                        storageNames: summary.storages.map { $0.displayName },
                        isLikelyPTPOnly: likelyPTP,
                        finderName: hostAlias.hostName
                    )

                    Task { @MainActor in
                        self.activeClient = client
                        self.activeVFS = vfs
                        self.activeServer = server
                        self.activeHostAlias = hostAlias
                        self.activeLocationID = candidate.locationID
                        self.activeMountPoint = mountPoint
                        self.isConnecting = false
                        self.state = .mounted(mounted)
                        self.startHealthTimer()
                        self.onStateChange?()

                        if shouldOpenFinder {
                            NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint))
                        }
                    }
                } catch {
                    client.close()
                    throw error
                }
            } catch let transportErr as MTPTransportError {
                let busy = (transportErr == .deviceBusy)
                let hasPTPD = busy && Self.isPTPCameraDaemonRunning()
                Task { @MainActor in
                    self.isConnecting = false
                    self.state = .error(
                        message: busy && hasPTPD
                            ? L10n.tr("android.error.ptpcamerad_busy")
                            : (transportErr.errorDescription ?? L10n.tr("android.error.usb_failed")),
                        canReleasePTPD: busy
                    )
                    self.onStateChange?()
                }
            } catch {
                Task { @MainActor in
                    self.isConnecting = false
                    self.state = .error(message: error.localizedDescription, canReleasePTPD: false)
                    self.onStateChange?()
                }
            }
        }
    }

    /// Called when the USB link stalls mid-transfer: the mount can no longer be trusted,
    /// so unmount it and tell the user how to recover instead of leaving Finder hanging.
    private func handleTransportFailure(reason: String) {
        guard case .mounted(let dev) = state else { return }
        let deviceName = dev.deviceName
        let locationID = dev.locationID

        // Drop the mount first so nothing else keeps talking to the wedged device.
        teardownActiveSession(forceUnmount: true, flushPendingWrites: false)
        state = .error(
            message: L10n.tr("android.error.transfer_recovering", deviceName, reason),
            canReleasePTPD: false
        )
        onStateChange?()

        workQueue.async { [weak self] in
            let reset = IOKitMTPTransport.resetDevice(locationID: locationID, reenumerate: true)
            Thread.sleep(forTimeInterval: 2.5)
            DispatchQueue.main.async {
                guard let self else { return }
                self.manuallyEjectedLocationID = nil
                if reset {
                    self.state = .idle
                    self.onStateChange?()
                    self.scanAndConnectIfNeeded(userInitiated: false)
                } else {
                    self.state = .error(
                        message: L10n.tr("android.error.transfer_failed", deviceName, reason),
                        canReleasePTPD: false
                    )
                    self.onStateChange?()
                }
            }
        }
    }

    private func teardownActiveSession(forceUnmount: Bool, alreadyUnmounted: Bool = false, flushPendingWrites: Bool = true) {
        healthTimer?.invalidate()
        healthTimer = nil

        let mp = activeMountPoint
        let server = activeServer
        let client = activeClient
        let vfs = activeVFS
        let hostAlias = activeHostAlias

        activeMountPoint = nil
        activeServer = nil
        activeClient = nil
        activeVFS = nil
        activeHostAlias = nil
        activeLocationID = nil
        state = .idle
        onStateChange?()

        workQueue.async {
            if let mp, !alreadyUnmounted {
                _ = NFSMounter.unmount(mountPoint: mp, force: forceUnmount)
            } else if let mp {
                NFSMounter.removeMountPointIfEmpty(mp)
            }
            server?.stop(flushPending: flushPendingWrites)
            client?.close()
            hostAlias?.stop()
            vfs?.cleanupTempFiles()
        }
    }

    private func startHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(
            timeInterval: 3.0,
            target: self,
            selector: #selector(handleHealthTimerTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    @objc private func handleHealthTimerTick() {
        guard case .mounted(let dev) = state else {
            healthTimer?.invalidate()
            healthTimer = nil
            return
        }
        workQueue.async { [weak self] in
            let target = self
            let usbPresent = IOKitMTPTransport.isDevicePresent(locationID: dev.locationID)
            let stillMounted = NFSMounter.mountPointIsActive(dev.mountPoint)
            if !usbPresent {
                DispatchQueue.main.async {
                    target?.manuallyEjectedLocationID = nil
                    target?.teardownActiveSession(forceUnmount: true)
                }
            } else if !stillMounted {
                DispatchQueue.main.async {
                    target?.teardownActiveSession(forceUnmount: false, alreadyUnmounted: true)
                }
            }
        }
    }

    nonisolated private static func sanitizeVolumeName(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Android Phone" : trimmed
    }

    nonisolated private static func isPTPCameraDaemonRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "ptpcamerad"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func terminatePTPCameraDaemon() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["ptpcamerad"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}

private extension MTPTransportError {
    static func == (lhs: MTPTransportError, rhs: MTPTransportError) -> Bool {
        switch (lhs, rhs) {
        case (.deviceNotFound, .deviceNotFound),
             (.deviceBusy, .deviceBusy),
             (.noEndpoints, .noEndpoints),
             (.disconnected, .disconnected),
             (.timeout, .timeout):
            return true
        case (.ioError(let a), .ioError(let b)):
            return a == b
        default:
            return false
        }
    }
}
