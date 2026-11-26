import AppKit
import Combine
import Foundation

@MainActor
final class KDEConnectModule: BaseGadgetModule, ObservableObject, KDEConnectTransportDelegate {
    override var identifier: String { "kde-connect" }
    override var displayName: String { L10n.tr("kdeconnect.title") }

    private enum DefaultsKey {
        static let enabled = "KDEConnect.enabled"
        static let clipboardSync = "KDEConnect.clipboardSync"
    }

    struct DeviceState: Identifiable, Equatable {
        let id: String
        var name: String
        var deviceType: String
        var peerIP: String?
        var isConnected: Bool
        var isPaired: Bool
        var hasIncomingPairRequest: Bool
        var isPairingPending: Bool
        var fingerprintShort: String?
    }

    struct FileTransferStatus: Equatable {
        enum Direction: Equatable {
            case sending
            case receiving
        }

        let filename: String
        let direction: Direction
        let bytesTransferred: Int64
        let totalBytes: Int64

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1.0, max(0.0, Double(bytesTransferred) / Double(totalBytes)))
        }
    }

    private let defaults = UserDefaults.standard
    private let identityStore = KDEConnectIdentityStore()
    private let transferQueue = DispatchQueue(label: "com.macgadgets.kdeconnect.transfer")

    private var transport: KDEConnectTransport?
    private var discoveryTimer: Timer?
    private var clipboardTimer: Timer?

    private var lastObservedChangeCount: Int = NSPasteboard.general.changeCount
    private var lastClipboardTimestampMs: Int64 = 0
    private var pairingRequestedByUs: Set<String> = []
    private var incomingPairRequests: Set<String> = []
    private var connectedLinks: [String: KDEConnectLink] = [:]

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: DefaultsKey.enabled)
            if isEnabled {
                startService()
            } else {
                stopService()
            }
            onStateChange?()
        }
    }

    @Published var isClipboardSyncEnabled: Bool {
        didSet {
            defaults.set(isClipboardSyncEnabled, forKey: DefaultsKey.clipboardSync)
            updateClipboardTimer()
            onStateChange?()
        }
    }

    @Published private(set) var devices: [DeviceState] = []
    @Published private(set) var activeTransfer: FileTransferStatus?
    @Published private(set) var lastTransferMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var localFingerprintShort: String = ""
    let localDeviceName: String

    var connectedPairedCount: Int {
        devices.filter { $0.isConnected && $0.isPaired }.count
    }

    var summaryText: String {
        if !isEnabled {
            return L10n.tr("kdeconnect.summary.off")
        }
        let count = connectedPairedCount
        if count > 0 {
            return L10n.tr("kdeconnect.summary.connected", count)
        }
        return L10n.tr("kdeconnect.summary.listening")
    }

    override init() {
        if defaults.object(forKey: DefaultsKey.enabled) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: DefaultsKey.enabled)
        }

        if defaults.object(forKey: DefaultsKey.clipboardSync) == nil {
            self.isClipboardSyncEnabled = true
        } else {
            self.isClipboardSyncEnabled = defaults.bool(forKey: DefaultsKey.clipboardSync)
        }

        self.localDeviceName = Host.current().localizedName ?? "Mac"
        super.init()

        rebuildDeviceList()
        if isEnabled {
            startService()
        }
    }

    override func refreshMenuState() {
        rebuildDeviceList()
        if isEnabled {
            transport?.broadcastIdentity()
        }
    }

    override func shutdown() {
        stopService()
    }

    // MARK: - Service Lifecycle

    func startService() {
        guard transport == nil else { return }
        errorMessage = nil

        do {
            let localId = identityStore.localDeviceId
            let localIdentity = try KDEConnectCrypto.loadOrCreateIdentity(deviceId: localId)
            localFingerprintShort = KDEConnectCrypto.formattedFingerprint(of: localIdentity.certificateDER)

            let newTransport = KDEConnectTransport(
                localIdentity: localIdentity,
                identityStore: identityStore,
                localDeviceName: localDeviceName
            )
            newTransport.delegate = self
            try newTransport.start()
            self.transport = newTransport

            startDiscoveryTimer()
            updateClipboardTimer()
            rebuildDeviceList()
        } catch {
            errorMessage = error.localizedDescription
            stopService()
        }
    }

    func stopService() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil

        transport?.stop()
        transport = nil
        connectedLinks.removeAll()
        pairingRequestedByUs.removeAll()
        incomingPairRequests.removeAll()
        rebuildDeviceList()
    }

    func refreshDiscovery() {
        errorMessage = nil
        if transport == nil && isEnabled {
            startService()
        } else {
            transport?.broadcastIdentity()
        }
    }

    func connectByIP(_ ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transport?.broadcastIdentity(toSpecificIP: trimmed)
    }

    // MARK: - Pairing Actions

    func requestPair(deviceId: String) {
        guard let link = connectedLinks[deviceId] else { return }
        pairingRequestedByUs.insert(deviceId)
        rebuildDeviceList()
        do {
            try link.send(KDEConnectPacket.pair(accept: true))
        } catch {
            pairingRequestedByUs.remove(deviceId)
            errorMessage = error.localizedDescription
            rebuildDeviceList()
        }
    }

    func acceptPair(deviceId: String) {
        guard let link = connectedLinks[deviceId] else { return }
        let trusted = KDEConnectTrustedDevice(
            deviceId: link.deviceId,
            deviceName: link.deviceName,
            deviceType: link.deviceType,
            certificateDER: link.peerCertificateDER,
            fingerprintHex: link.fingerprintHex,
            pairedAt: Date()
        )
        identityStore.saveTrustedDevice(trusted)
        incomingPairRequests.remove(deviceId)
        pairingRequestedByUs.remove(deviceId)

        do {
            try link.send(KDEConnectPacket.pair(accept: true))
        } catch {
            errorMessage = error.localizedDescription
        }
        rebuildDeviceList()
        updateClipboardTimer()
        onStateChange?()
    }

    func rejectOrUnpair(deviceId: String) {
        incomingPairRequests.remove(deviceId)
        pairingRequestedByUs.remove(deviceId)
        identityStore.removeTrustedDevice(deviceId: deviceId)

        if let link = connectedLinks[deviceId] {
            try? link.send(KDEConnectPacket.pair(accept: false))
        }
        rebuildDeviceList()
        updateClipboardTimer()
        onStateChange?()
    }

    // MARK: - Clipboard Actions

    func sendClipboardNow(to deviceId: String) {
        guard let link = connectedLinks[deviceId],
              identityStore.trustedDevice(for: deviceId) != nil,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            return
        }
        do {
            try link.send(KDEConnectPacket.clipboard(content: text))
            lastTransferMessage = L10n.tr("kdeconnect.clipboard_sent")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - File Sharing Actions

    func chooseAndSendFiles(to deviceId: String) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.tr("kdeconnect.send")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            sendFiles(to: deviceId, urls: panel.urls)
        }
    }

    func sendFiles(to deviceId: String, urls: [URL]) {
        guard let transport,
              let link = connectedLinks[deviceId],
              identityStore.trustedDevice(for: deviceId) != nil else {
            return
        }

        let fileURLs = urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        guard !fileURLs.isEmpty else { return }

        transferQueue.async { [weak self] in
            for url in fileURLs {
                let filename = url.lastPathComponent
                let totalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

                Task { @MainActor [weak self] in
                    self?.activeTransfer = FileTransferStatus(
                        filename: filename,
                        direction: .sending,
                        bytesTransferred: 0,
                        totalBytes: totalSize
                    )
                    self?.errorMessage = nil
                }

                do {
                    try transport.sendFile(to: link, fileURL: url) { sent, total in
                        Task { @MainActor [weak self] in
                            self?.activeTransfer = FileTransferStatus(
                                filename: filename,
                                direction: .sending,
                                bytesTransferred: sent,
                                totalBytes: total
                            )
                        }
                    }
                    Task { @MainActor [weak self] in
                        self?.activeTransfer = nil
                        self?.lastTransferMessage = L10n.tr("kdeconnect.file_sent", filename)
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.activeTransfer = nil
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func openDownloadsFolder() {
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(downloads)
        }
    }

    // MARK: - KDEConnectTransportDelegate

    nonisolated func transport(_ transport: KDEConnectTransport, didConnect link: KDEConnectLink) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedLinks[link.deviceId] = link

            // Update stored device name if already paired
            if var trusted = self.identityStore.trustedDevice(for: link.deviceId),
               trusted.deviceName != link.deviceName {
                trusted.deviceName = link.deviceName
                self.identityStore.saveTrustedDevice(trusted)
            }

            self.rebuildDeviceList()
            self.updateClipboardTimer()
            self.onStateChange?()

            // Push initial clipboard state on connect if paired and enabled
            if self.isClipboardSyncEnabled,
               self.identityStore.trustedDevice(for: link.deviceId) != nil,
               let content = NSPasteboard.general.string(forType: .string),
               !content.isEmpty {
                let ts = self.lastClipboardTimestampMs > 0
                    ? self.lastClipboardTimestampMs
                    : Int64(Date().timeIntervalSince1970 * 1000)
                try? link.send(KDEConnectPacket.clipboardConnect(content: content, timestamp: ts))
            }
        }
    }

    nonisolated func transport(_ transport: KDEConnectTransport, didDisconnect deviceId: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedLinks.removeValue(forKey: deviceId)
            self.pairingRequestedByUs.remove(deviceId)
            self.incomingPairRequests.remove(deviceId)
            self.rebuildDeviceList()
            self.updateClipboardTimer()
            self.onStateChange?()
        }
    }

    nonisolated func transport(
        _ transport: KDEConnectTransport,
        didReceivePacket packet: KDEConnectPacket,
        from link: KDEConnectLink
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handlePacket(packet, from: link)
        }
    }

    // MARK: - Packet Handling

    private func handlePacket(_ packet: KDEConnectPacket, from link: KDEConnectLink) {
        switch packet.type {
        case KDEConnectPacketType.pair:
            handlePairPacket(packet, from: link)

        case KDEConnectPacketType.clipboard, KDEConnectPacketType.clipboardConnect:
            guard identityStore.trustedDevice(for: link.deviceId) != nil else { return }
            handleClipboardPacket(packet)

        case KDEConnectPacketType.shareRequest:
            guard identityStore.trustedDevice(for: link.deviceId) != nil else { return }
            handleSharePacket(packet, from: link)

        default:
            break
        }
    }

    private func handlePairPacket(_ packet: KDEConnectPacket, from link: KDEConnectLink) {
        guard let accept = packet.pairFlag else { return }
        if accept {
            if pairingRequestedByUs.contains(link.deviceId) {
                let trusted = KDEConnectTrustedDevice(
                    deviceId: link.deviceId,
                    deviceName: link.deviceName,
                    deviceType: link.deviceType,
                    certificateDER: link.peerCertificateDER,
                    fingerprintHex: link.fingerprintHex,
                    pairedAt: Date()
                )
                identityStore.saveTrustedDevice(trusted)
                pairingRequestedByUs.remove(link.deviceId)
                incomingPairRequests.remove(link.deviceId)
                updateClipboardTimer()
                onStateChange?()
            } else if identityStore.trustedDevice(for: link.deviceId) == nil {
                incomingPairRequests.insert(link.deviceId)
            }
        } else {
            pairingRequestedByUs.remove(link.deviceId)
            incomingPairRequests.remove(link.deviceId)
            identityStore.removeTrustedDevice(deviceId: link.deviceId)
            updateClipboardTimer()
            onStateChange?()
        }
        rebuildDeviceList()
    }

    private func handleClipboardPacket(_ packet: KDEConnectPacket) {
        guard isClipboardSyncEnabled,
              let content = packet.clipboardContent,
              !content.isEmpty else {
            return
        }

        if packet.type == KDEConnectPacketType.clipboardConnect,
           let ts = packet.clipboardTimestamp,
           ts > 0,
           lastClipboardTimestampMs > 0,
           ts <= lastClipboardTimestampMs {
            return
        }

        let current = NSPasteboard.general.string(forType: .string)
        if current == content {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        lastObservedChangeCount = NSPasteboard.general.changeCount
        lastClipboardTimestampMs = packet.clipboardTimestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        lastTransferMessage = L10n.tr("kdeconnect.clipboard_received")
    }

    private func handleSharePacket(_ packet: KDEConnectPacket, from link: KDEConnectLink) {
        if let port = packet.transferPort,
           let rawName = packet.shareFilename,
           let transport {
            let safeName = (rawName as NSString).lastPathComponent
            let filename = safeName.isEmpty ? "shared_file" : safeName
            let destinationURL = Self.uniqueDownloadsURL(for: filename)
            let expectedSize = packet.payloadSize

            transferQueue.async { [weak self] in
                Task { @MainActor [weak self] in
                    self?.activeTransfer = FileTransferStatus(
                        filename: filename,
                        direction: .receiving,
                        bytesTransferred: 0,
                        totalBytes: expectedSize ?? 0
                    )
                    self?.errorMessage = nil
                }

                do {
                    try transport.receiveFile(
                        from: link,
                        port: port,
                        expectedSize: expectedSize,
                        destinationURL: destinationURL
                    ) { received, total in
                        Task { @MainActor [weak self] in
                            self?.activeTransfer = FileTransferStatus(
                                filename: filename,
                                direction: .receiving,
                                bytesTransferred: received,
                                totalBytes: total
                            )
                        }
                    }
                    Task { @MainActor [weak self] in
                        self?.activeTransfer = nil
                        self?.lastTransferMessage = L10n.tr("kdeconnect.file_received", destinationURL.lastPathComponent)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: destinationURL)
                    Task { @MainActor [weak self] in
                        self?.activeTransfer = nil
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        // Handle shared URL or plain text via Share plugin
        let sharedContent = packet.shareURL ?? packet.shareText
        if let sharedContent, !sharedContent.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sharedContent, forType: .string)
            lastObservedChangeCount = NSPasteboard.general.changeCount
            lastTransferMessage = L10n.tr("kdeconnect.clipboard_received")
        }
    }

    // MARK: - Timers & Helpers

    private func startDiscoveryTimer() {
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transport?.broadcastIdentity()
            }
        }
    }

    private func updateClipboardTimer() {
        let shouldRun = isEnabled && isClipboardSyncEnabled && connectedPairedCount > 0
        if shouldRun && clipboardTimer == nil {
            lastObservedChangeCount = NSPasteboard.general.changeCount
            clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pollLocalClipboard()
                }
            }
        } else if !shouldRun {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func pollLocalClipboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount
        lastClipboardTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        guard isClipboardSyncEnabled,
              let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            return
        }

        let packet = KDEConnectPacket.clipboard(content: text)
        for (deviceId, link) in connectedLinks where identityStore.trustedDevice(for: deviceId) != nil {
            try? link.send(packet)
        }
    }

    private func rebuildDeviceList() {
        let trustedMap = identityStore.trustedDevices()
        var merged: [String: DeviceState] = [:]

        for (id, trusted) in trustedMap {
            let link = connectedLinks[id]
            merged[id] = DeviceState(
                id: id,
                name: link?.deviceName ?? trusted.deviceName,
                deviceType: link?.deviceType ?? trusted.deviceType,
                peerIP: link?.peerIP,
                isConnected: link != nil,
                isPaired: true,
                hasIncomingPairRequest: false,
                isPairingPending: false,
                fingerprintShort: KDEConnectCrypto.formattedFingerprint(of: trusted.certificateDER)
            )
        }

        for (id, link) in connectedLinks where merged[id] == nil {
            merged[id] = DeviceState(
                id: id,
                name: link.deviceName,
                deviceType: link.deviceType,
                peerIP: link.peerIP,
                isConnected: true,
                isPaired: false,
                hasIncomingPairRequest: incomingPairRequests.contains(id),
                isPairingPending: pairingRequestedByUs.contains(id),
                fingerprintShort: KDEConnectCrypto.formattedFingerprint(of: link.peerCertificateDER)
            )
        }

        devices = merged.values.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected && !rhs.isConnected }
            if lhs.isPaired != rhs.isPaired { return lhs.isPaired && !rhs.isPaired }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func uniqueDownloadsURL(for filename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let candidate = downloads.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 1
        while true {
            let numbered = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let url = downloads.appendingPathComponent(numbered)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            index += 1
        }
    }
}
