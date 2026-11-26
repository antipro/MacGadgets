import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native frosted-glass NSVisualEffectView wrapper matching macOS Control Center.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ControlCenterView: View {
    @ObservedObject var keepAwake: KeepAwakeModule
    @ObservedObject var scrollReverser: ScrollReverserModule
    @ObservedObject var androidDrive: AndroidDriveModule
    @ObservedObject var kdeConnect: KDEConnectModule
    @ObservedObject private var l10n = LocalizationManager.shared
    var onOpenPreferences: () -> Void
    var onQuit: () -> Void
    var onOpenCustomInput: () -> Void

    @State private var showCustomInput = false
    @State private var customInput = ""
    @State private var customError: String?
    @State private var launchAtLogin = LaunchAtLogin.shared.isEnabled
    @State private var loginError: String?

    private let presetColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let _ = l10n.selection
        VStack(spacing: 10) {
            if keepAwake.isModuleEnabled {
                keepAwakeCard
            }
            if scrollReverser.isModuleEnabled {
                scrollReverserCard
            }
            if androidDrive.isModuleEnabled {
                androidDriveCard
            }
            if kdeConnect.isEnabled {
                kdeConnectCard
            }
            if !keepAwake.isModuleEnabled && !scrollReverser.isModuleEnabled && !androidDrive.isModuleEnabled && !kdeConnect.isEnabled {
                ControlCenterCard {
                    VStack(spacing: 8) {
                        Text(L10n.tr("control_center.no_modules_enabled"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button(action: onOpenPreferences) {
                            Text(L10n.tr("control_center.open_preferences"))
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
            footerBar
        }
        .padding(12)
        .frame(width: 328)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        .environment(\.layoutDirection, l10n.layoutDirection)
        .onAppear {
            launchAtLogin = LaunchAtLogin.shared.isEnabled
            keepAwake.refreshMenuState()
            scrollReverser.refreshMenuState()
            androidDrive.refreshMenuState()
            kdeConnect.refreshMenuState()
        }
    }

    // MARK: - Card 1: Keep Awake

    private var keepAwakeCard: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: { keepAwake.toggleQuickSession() }) {
                        ZStack {
                            Circle()
                                .fill(keepAwake.isActive ? Color.orange : Color.primary.opacity(0.1))
                                .frame(width: 36, height: 36)
                            Image(systemName: keepAwake.isActive
                                  ? (keepAwake.displayAllowedToSleep ? "bolt.circle.fill" : "sun.max.fill")
                                  : "cup.and.saucer.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(keepAwake.isActive ? .white : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(keepAwake.isActive ? L10n.tr("keep_awake.help.cancel") : L10n.tr("keep_awake.help.start_16h"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("keep_awake.title"))
                            .font(.system(size: 13, weight: .semibold))
                        keepAwakeSubtitle
                    }

                    Spacer(minLength: 4)

                    if keepAwake.isActive {
                        HStack(spacing: 4) {
                            if keepAwake.isTimed {
                                Button(action: { keepAwake.extendOneHour() }) {
                                    Text("+1h")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(Color.primary.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.tr("keep_awake.help.extend_1h"))
                            }

                            Button(action: { keepAwake.cancel() }) {
                                Text(L10n.tr("common.cancel"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr("keep_awake.help.cancel_now"))
                        }
                    }
                }

                LazyVGrid(columns: presetColumns, spacing: 6) {
                    ForEach(KeepAwakeModule.presets) { preset in
                        let selected = keepAwake.isActive && keepAwake.activePresetId == preset.id
                        Button(action: {
                            showCustomInput = false
                            customError = nil
                            keepAwake.startPreset(preset)
                        }) {
                            Text(preset.shortTitle)
                                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .foregroundColor(selected ? .white : .primary)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selected ? Color.orange : Color.primary.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.title)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(isOn: $keepAwake.displayAllowedToSleep) {
                            Text(L10n.tr("keep_awake.allow_display_sleep"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                        Spacer()

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showCustomInput.toggle()
                                customError = nil
                            }
                            if showCustomInput {
                                onOpenCustomInput()
                            }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                Text(L10n.tr("keep_awake.custom"))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(showCustomInput ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if showCustomInput {
                        HStack(spacing: 6) {
                            TextField(L10n.tr("keep_awake.custom_placeholder"), text: $customInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { submitCustomDuration() }

                            Button(L10n.tr("keep_awake.start")) {
                                submitCustomDuration()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }

                        if let customError {
                            Text(customError)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                    }

                    if let err = keepAwake.lastErrorMessage {
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var keepAwakeSubtitle: some View {
        if keepAwake.isActive {
            if let remaining = keepAwake.remainingText, let endTime = keepAwake.endTimeText {
                Text(L10n.tr("keep_awake.subtitle.remaining", remaining, endTime))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.orange)
            } else if let elapsed = keepAwake.elapsedText {
                Text(L10n.tr("keep_awake.subtitle.indefinite", elapsed))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
        } else if let finished = keepAwake.lastFinishedMessage {
            Text(finished)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else {
            Text(L10n.tr("keep_awake.subtitle.idle"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func submitCustomDuration() {
        if let err = keepAwake.startCustom(input: customInput) {
            customError = err
        } else {
            customError = nil
            customInput = ""
            showCustomInput = false
        }
    }

    // MARK: - Card 2: Scroll Reverser

    private var scrollReverserCard: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(L10n.tr("scroll.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    scrollStatusBadge
                }

                HStack(spacing: 8) {
                    ControlCenterTileButton(
                        title: L10n.tr("scroll.mouse_wheel"),
                        subtitle: scrollReverser.invertMouseWheel ? L10n.tr("scroll.state.reversed") : L10n.tr("scroll.state.default"),
                        symbolName: scrollReverser.invertMouseWheel ? "computermouse.fill" : "computermouse",
                        isActive: scrollReverser.invertMouseWheel,
                        activeColor: .accentColor
                    ) {
                        scrollReverser.toggleMouseWheel()
                    }

                    ControlCenterTileButton(
                        title: L10n.tr("scroll.trackpad"),
                        subtitle: scrollReverser.invertTrackpad ? L10n.tr("scroll.state.reversed") : L10n.tr("scroll.state.default"),
                        symbolName: scrollReverser.invertTrackpad ? "hand.draw.fill" : "hand.draw",
                        isActive: scrollReverser.invertTrackpad,
                        activeColor: .accentColor
                    ) {
                        scrollReverser.toggleTrackpad()
                    }
                }

                Toggle(isOn: $scrollReverser.invertHorizontal) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 10))
                        Text(L10n.tr("scroll.invert_horizontal"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!scrollReverser.isAnyEnabled)

                if scrollReverser.needsPermission {
                    Button(action: { scrollReverser.requestPermission() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L10n.tr("scroll.permission_prompt"))
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var scrollStatusBadge: some View {
        if !scrollReverser.isAnyEnabled {
            Text(L10n.tr("scroll.badge.off"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else if scrollReverser.needsPermission {
            Text(L10n.tr("scroll.badge.waiting"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        } else {
            Text(L10n.tr("scroll.badge.active"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
        }
    }

    // MARK: - Card 3: Android Drive

    private var androidDriveCard: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(androidDrive.isMounted ? Color.green : Color.primary.opacity(0.1))
                            .frame(width: 32, height: 32)
                        Image(systemName: androidDrive.isMounted ? "externaldrive.fill.badge.checkmark" : "smartphone")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(androidDrive.isMounted ? .white : .primary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("android.title"))
                            .font(.system(size: 13, weight: .semibold))
                        androidDriveSubtitle
                    }

                    Spacer(minLength: 4)

                    androidDriveBadge
                }

                switch androidDrive.state {
                case .mounted(let device):
                    VStack(alignment: .leading, spacing: 7) {
                        if device.totalBytes > 0 {
                            let used = device.totalBytes >= device.freeBytes
                                ? (device.totalBytes - device.freeBytes)
                                : 0
                            let fraction = min(1.0, max(0.0, Double(used) / Double(device.totalBytes)))

                            VStack(alignment: .leading, spacing: 3) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 5)
                                        Capsule()
                                            .fill(Color.green)
                                            .frame(width: max(4, geo.size.width * fraction), height: 5)
                                    }
                                }
                                .frame(height: 5)

                                HStack {
                                    Text(L10n.tr("android.storage.free", Self.formatBytes(device.freeBytes)))
                                    Spacer()
                                    Text(L10n.tr("android.storage.total", Self.formatBytes(device.totalBytes)))
                                }
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundColor(.secondary)
                            }
                        }

                        if device.isLikelyPTPOnly {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 10))
                                Text(L10n.tr("android.ptp_warning"))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.orange.opacity(0.10))
                            )
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 9))
                            Text(L10n.tr("android.finder_location", device.finderName))
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button(action: { androidDrive.openInFinder() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                    Text(L10n.tr("android.open_in_finder"))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button(action: { androidDrive.eject() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "eject.fill")
                                    Text(L10n.tr("android.eject"))
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr("android.help.eject"))
                        }
                    }

                case .error(let message, let canReleasePTPD):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11))
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.14))
                        )

                        HStack(spacing: 6) {
                            if canReleasePTPD {
                                Button(action: { androidDrive.releaseCameraLockAndRetry() }) {
                                    Text(L10n.tr("android.release_ptpd"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(Color.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button(action: { androidDrive.rescanAndMount() }) {
                                    Text(L10n.tr("android.rescan_and_mount"))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(Color.primary.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                case .idle, .scanning, .connecting:
                    HStack(spacing: 8) {
                        Text(L10n.tr("android.idle_hint"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 4)
                        Button(action: { androidDrive.rescanAndMount() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text(L10n.tr("android.scan"))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled({
                            if case .scanning = androidDrive.state { return true }
                            if case .connecting = androidDrive.state { return true }
                            return false
                        }())
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle(isOn: $androidDrive.isAutoMountEnabled) {
                        Text(L10n.tr("android.auto_mount"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Toggle(isOn: $androidDrive.openFinderOnMount) {
                        Text(L10n.tr("android.open_finder_on_mount"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!androidDrive.isAutoMountEnabled)
                }
            }
        }
    }

    @ViewBuilder
    private var androidDriveSubtitle: some View {
        switch androidDrive.state {
        case .idle:
            Text(L10n.tr("android.subtitle.idle"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .scanning:
            Text(L10n.tr("android.subtitle.scanning"))
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .connecting(let name):
            Text(L10n.tr("android.subtitle.connecting", name))
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .mounted(let dev):
            Text("\(dev.deviceName) · \(dev.mountPoint)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .error:
            Text(L10n.tr("android.subtitle.error"))
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var androidDriveBadge: some View {
        switch androidDrive.state {
        case .idle:
            Text(L10n.tr("android.badge.idle"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .scanning, .connecting:
            Text(L10n.tr("android.badge.mounting"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        case .mounted:
            Text(L10n.tr("android.badge.mounted"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
        case .error:
            Text(L10n.tr("android.badge.error"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    // MARK: - Card 4: KDE Connect

    private var kdeConnectCard: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Button(action: { kdeConnect.isEnabled.toggle() }) {
                        ZStack {
                            Circle()
                                .fill(kdeConnect.connectedPairedCount > 0 ? Color.blue : Color.primary.opacity(0.1))
                                .frame(width: 32, height: 32)
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(kdeConnect.connectedPairedCount > 0 ? .white : .primary)
                        }
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("kdeconnect.title"))
                            .font(.system(size: 13, weight: .semibold))
                        kdeConnectSubtitle
                    }

                    Spacer(minLength: 4)

                    if kdeConnect.isEnabled {
                        Button(action: { kdeConnect.refreshDiscovery() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(5)
                                .background(Color.primary.opacity(0.07))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("kdeconnect.refresh"))
                    }

                    kdeConnectBadge
                }

                if let error = kdeConnect.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if kdeConnect.isEnabled {
                    if kdeConnect.devices.isEmpty {
                        HStack {
                            Text(L10n.tr("kdeconnect.no_devices"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            if !kdeConnect.localFingerprintShort.isEmpty {
                                Text(kdeConnect.localFingerprintShort)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        VStack(spacing: 6) {
                            ForEach(kdeConnect.devices) { device in
                                kdeConnectDeviceRow(device)
                            }
                        }
                    }

                    if let transfer = kdeConnect.activeTransfer {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(transfer.direction == .sending
                                     ? L10n.tr("kdeconnect.sending", transfer.filename)
                                     : L10n.tr("kdeconnect.receiving", transfer.filename))
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(Int(transfer.fraction * 100))%")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            ProgressView(value: transfer.fraction)
                                .progressViewStyle(.linear)
                                .controlSize(.small)
                        }
                    } else if let msg = kdeConnect.lastTransferMessage {
                        HStack {
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(action: { kdeConnect.openDownloadsFolder() }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                    Text(L10n.tr("kdeconnect.downloads"))
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: $kdeConnect.isClipboardSyncEnabled) {
                        Text(L10n.tr("kdeconnect.clipboard_sync"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private func kdeConnectDeviceRow(_ device: KDEConnectModule.DeviceState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.isConnected ? "iphone" : "iphone.slash")
                .font(.system(size: 12))
                .foregroundColor(device.isConnected ? (device.isPaired ? .blue : .orange) : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if device.hasIncomingPairRequest {
                    Text(L10n.tr("kdeconnect.pair_request"))
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                } else if device.isPairingPending {
                    Text(L10n.tr("kdeconnect.pairing_pending"))
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                } else if let ip = device.peerIP, device.isConnected {
                    Text(ip)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } else {
                    Text(L10n.tr("kdeconnect.offline"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 4)

            if device.hasIncomingPairRequest {
                Button(action: { kdeConnect.acceptPair(deviceId: device.id) }) {
                    Text(L10n.tr("kdeconnect.accept"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: { kdeConnect.rejectOrUnpair(deviceId: device.id) }) {
                    Text(L10n.tr("kdeconnect.reject"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if device.isPaired && device.isConnected {
                Button(action: { kdeConnect.sendClipboardNow(to: device.id) }) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                        .padding(5)
                        .background(Color.primary.opacity(0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("kdeconnect.help.send_clipboard"))

                Button(action: { kdeConnect.chooseAndSendFiles(to: device.id) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "paperplane.fill")
                        Text(L10n.tr("kdeconnect.send_file"))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("kdeconnect.help.send_file"))

                Button(action: { kdeConnect.rejectOrUnpair(deviceId: device.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("kdeconnect.unpair"))
            } else if device.isConnected && !device.isPaired {
                Button(action: { kdeConnect.requestPair(deviceId: device.id) }) {
                    Text(device.isPairingPending ? L10n.tr("kdeconnect.pairing") : L10n.tr("kdeconnect.pair"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(device.isPairingPending ? Color.orange : Color.blue)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(device.isPairingPending)
            } else if device.isPaired {
                Button(action: { kdeConnect.rejectOrUnpair(deviceId: device.id) }) {
                    Text(L10n.tr("kdeconnect.unpair"))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard device.isPaired && device.isConnected else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        kdeConnect.sendFiles(to: device.id, urls: [url])
                    }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var kdeConnectSubtitle: some View {
        if !kdeConnect.isEnabled {
            Text(L10n.tr("kdeconnect.subtitle.off"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else if kdeConnect.connectedPairedCount > 0 {
            Text(L10n.tr("kdeconnect.subtitle.connected", kdeConnect.connectedPairedCount))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
        } else {
            Text(L10n.tr("kdeconnect.subtitle.listening", kdeConnect.localDeviceName))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var kdeConnectBadge: some View {
        if !kdeConnect.isEnabled {
            Text(L10n.tr("kdeconnect.badge.off"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else if kdeConnect.connectedPairedCount > 0 {
            Text(L10n.tr("kdeconnect.badge.connected"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
        } else {
            Text(L10n.tr("kdeconnect.badge.listening"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.shared.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.shared.isEnabled
                            loginError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.shared.isEnabled
                            loginError = error.localizedDescription
                        }
                    }
                )) {
                    Text(L10n.tr("footer.launch_at_login"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                Button(action: onOpenPreferences) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("footer.preferences"))

                Button(action: onQuit) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text(L10n.tr("footer.quit"))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let loginError {
                Text(loginError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - Reusable Control Center Components

private struct ControlCenterCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
    }
}

private struct ControlCenterTileButton: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? activeColor : Color.primary.opacity(0.1))
                        .frame(width: 30, height: 30)
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isActive ? .white : .primary)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(isActive ? activeColor : .secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? activeColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? activeColor.opacity(0.35) : Color.clear, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
    }
}
