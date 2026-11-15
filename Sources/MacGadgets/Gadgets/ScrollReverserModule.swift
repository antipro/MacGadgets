import AppKit
import Combine

/// Menu bar gadget that independently reverses mouse scroll wheel and trackpad
/// scrolling directions using a native CoreGraphics event tap.
@MainActor
final class ScrollReverserModule: BaseGadgetModule, ObservableObject {
    override var identifier: String { "scroll-reverser" }
    override var displayName: String { "滚动方向翻转" }

    private enum DefaultsKey {
        static let invertMouseWheel = "ScrollReverser.invertMouseWheel"
        static let invertTrackpad = "ScrollReverser.invertTrackpad"
        static let invertHorizontal = "ScrollReverser.invertHorizontal"
    }

    private let defaults = UserDefaults.standard
    private let eventTap = ScrollEventTap()
    private var permissionPollTimer: Timer?
    private var hasPromptedThisSession = false

    @Published var invertMouseWheel: Bool {
        didSet {
            defaults.set(invertMouseWheel, forKey: DefaultsKey.invertMouseWheel)
            applyConfig(promptIfNeeded: invertMouseWheel)
        }
    }

    @Published var invertTrackpad: Bool {
        didSet {
            defaults.set(invertTrackpad, forKey: DefaultsKey.invertTrackpad)
            applyConfig(promptIfNeeded: invertTrackpad)
        }
    }

    @Published var invertHorizontal: Bool {
        didSet {
            defaults.set(invertHorizontal, forKey: DefaultsKey.invertHorizontal)
            applyConfig(promptIfNeeded: false)
        }
    }

    @Published private(set) var isTapRunning: Bool = false

    private var currentConfig: ScrollReversalConfig {
        ScrollReversalConfig(
            invertMouseWheel: invertMouseWheel,
            invertTrackpad: invertTrackpad,
            invertHorizontal: invertHorizontal
        )
    }

    override var statusBarSymbolName: String? {
        isActiveAndRunning ? "arrow.up.arrow.down.circle.fill" : nil
    }

    var isAnyEnabled: Bool {
        currentConfig.isAnyEnabled
    }

    var isActiveAndRunning: Bool {
        isAnyEnabled && isTapRunning
    }

    var needsPermission: Bool {
        isAnyEnabled && !isTapRunning
    }

    var summaryText: String {
        guard isAnyEnabled else { return "滚动方向翻转：未开启" }
        if !isTapRunning {
            return "滚动方向翻转：等待辅助功能权限"
        }
        var targets: [String] = []
        if invertMouseWheel { targets.append("鼠标滚轮") }
        if invertTrackpad { targets.append("触摸板") }
        return "滚动方向翻转：已翻转 \(targets.joined(separator: "、"))"
    }

    override init() {
        self.invertMouseWheel = UserDefaults.standard.bool(forKey: DefaultsKey.invertMouseWheel)
        self.invertTrackpad = UserDefaults.standard.bool(forKey: DefaultsKey.invertTrackpad)
        self.invertHorizontal = UserDefaults.standard.bool(forKey: DefaultsKey.invertHorizontal)
        super.init()
        eventTap.config = currentConfig
        syncEventTapState(promptIfNeeded: false)
    }

    // MARK: - Actions for UI

    func toggleMouseWheel() {
        invertMouseWheel.toggle()
    }

    func toggleTrackpad() {
        invertTrackpad.toggle()
    }

    func requestPermission() {
        let granted = ScrollEventTap.hasAccessibilityPermission(prompt: true)
        if !granted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            startPermissionPolling()
        } else {
            syncEventTapState(promptIfNeeded: false)
        }
        onStateChange?()
    }

    override func refreshMenuState() {
        if isAnyEnabled && !eventTap.isRunning {
            _ = eventTap.start()
            isTapRunning = eventTap.isRunning
            if isTapRunning {
                stopPermissionPolling()
            }
        }
    }

    // MARK: - Event tap & persistence

    private func applyConfig(promptIfNeeded: Bool) {
        eventTap.config = currentConfig
        syncEventTapState(promptIfNeeded: promptIfNeeded)
        onStateChange?()
    }

    private func syncEventTapState(promptIfNeeded: Bool) {
        guard isAnyEnabled else {
            stopPermissionPolling()
            eventTap.stop()
            isTapRunning = false
            return
        }

        if eventTap.start() {
            stopPermissionPolling()
            isTapRunning = true
            return
        }

        isTapRunning = false
        if promptIfNeeded && !hasPromptedThisSession {
            hasPromptedThisSession = true
            _ = ScrollEventTap.hasAccessibilityPermission(prompt: true)
        }
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(handlePermissionPollTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    @objc private func handlePermissionPollTick() {
        checkPermissionAndRetry()
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func checkPermissionAndRetry() {
        guard isAnyEnabled else {
            stopPermissionPolling()
            isTapRunning = false
            return
        }
        if eventTap.start() {
            stopPermissionPolling()
            isTapRunning = true
            onStateChange?()
        }
    }

    override func shutdown() {
        stopPermissionPolling()
        eventTap.stop()
        isTapRunning = false
    }
}
