import AppKit
import SwiftUI

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
    var onQuit: () -> Void
    var onOpenCustomInput: () -> Void

    @State private var showCustomInput = false
    @State private var customInput = ""
    @State private var customError: String?
    @State private var launchAtLogin = LaunchAtLogin.shared.isEnabled
    @State private var loginError: String?

    private let presetColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(spacing: 10) {
            keepAwakeCard
            scrollReverserCard
            androidDriveCard
            footerBar
        }
        .padding(12)
        .frame(width: 328)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        .onAppear {
            launchAtLogin = LaunchAtLogin.shared.isEnabled
            keepAwake.refreshMenuState()
            scrollReverser.refreshMenuState()
            androidDrive.refreshMenuState()
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
                    .help(keepAwake.isActive ? "点击取消保持唤醒" : "点击立即开启 16 小时（57600 秒）")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("保持唤醒")
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
                                .help("延长 1 小时")
                            }

                            Button(action: { keepAwake.cancel() }) {
                                Text("取消")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("立即取消保持唤醒")
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
                            Text("仅保持系统唤醒（允许息屏）")
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
                                Text("自定义")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(showCustomInput ? .orange : .secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if showCustomInput {
                        HStack(spacing: 6) {
                            TextField("如 57600s、2h、90m、16:00:00", text: $customInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .onSubmit { submitCustomDuration() }

                            Button("开始") {
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
                Text("剩余 \(remaining) · 至 \(endTime)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.orange)
            } else if let elapsed = keepAwake.elapsedText {
                Text("持续唤醒中 · 已运行 \(elapsed)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
            }
        } else if let finished = keepAwake.lastFinishedMessage {
            Text(finished)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else {
            Text("未开启 · 默认 16 小时 (57600s)")
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
                    Text("滚动方向翻转")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    scrollStatusBadge
                }

                HStack(spacing: 8) {
                    ControlCenterTileButton(
                        title: "鼠标滚轮",
                        subtitle: scrollReverser.invertMouseWheel ? "已翻转" : "默认方向",
                        symbolName: scrollReverser.invertMouseWheel ? "computermouse.fill" : "computermouse",
                        isActive: scrollReverser.invertMouseWheel,
                        activeColor: .accentColor
                    ) {
                        scrollReverser.toggleMouseWheel()
                    }

                    ControlCenterTileButton(
                        title: "触摸板",
                        subtitle: scrollReverser.invertTrackpad ? "已翻转" : "默认方向",
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
                        Text("同时翻转水平滚动方向")
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
                            Text("需要「辅助功能」权限才能拦截滚轮，点击授权 →")
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
            Text("未开启")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else if scrollReverser.needsPermission {
            Text("等待授权")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        } else {
            Text("已生效")
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
                        Text("Android 磁盘")
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
                                    Text("可用 \(Self.formatBytes(device.freeBytes))")
                                    Spacer()
                                    Text("共 \(Self.formatBytes(device.totalBytes))")
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
                                Text("当前仅暴露 DCIM/Pictures，若需完整目录请在手机切换为「传输文件 (MTP)」")
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
                            Text("访达「位置」中显示为 \(device.finderName)")
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Button(action: { androidDrive.openInFinder() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                    Text("在访达中打开")
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
                                    Text("弹出")
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("安全卸载手机磁盘")
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
                                    Text("释放相机进程占用并重试")
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
                                    Text("重新扫描并挂载")
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
                        Text("插线并在手机选择「传输文件 (MTP)」")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 4)
                        Button(action: { androidDrive.rescanAndMount() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text("扫描")
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
                        Text("插入 Android 手机时自动挂载")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Toggle(isOn: $androidDrive.openFinderOnMount) {
                        Text("挂载后自动打开访达窗口")
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
            Text("未连接 · 自动识别 MTP 设备")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .scanning:
            Text("正在扫描 USB 设备...")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .connecting(let name):
            Text("正在连接 \(name)...")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .mounted(let dev):
            Text("\(dev.deviceName) · \(dev.mountPoint)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .error:
            Text("连接异常")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var androidDriveBadge: some View {
        switch androidDrive.state {
        case .idle:
            Text("待机")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        case .scanning, .connecting:
            Text("挂载中")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        case .mounted:
            Text("已挂载")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
        case .error:
            Text("需处理")
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
                    Text("登录时自动启动")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                Button(action: onQuit) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                        Text("退出")
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
