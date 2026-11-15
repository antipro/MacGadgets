import AppKit
import Combine

/// Status bar gadget that suppresses idle sleep for a chosen duration, using the
/// same IOKit power assertion mechanism as `caffeinate -d -t 57600`, cancellable anytime.
@MainActor
final class KeepAwakeModule: BaseGadgetModule, ObservableObject {
    override var identifier: String { "keep-awake" }
    override var displayName: String { "保持唤醒" }

    private enum DefaultsKey {
        static let allowDisplaySleep = "KeepAwake.allowDisplaySleep"
    }

    static let defaultQuickDuration: TimeInterval = 16 * 60 * 60 // 57600 seconds

    struct Preset: Identifiable {
        let id: String
        let shortTitle: String
        let title: String
        let duration: TimeInterval?
    }

    static let presets: [Preset] = [
        Preset(id: "15m", shortTitle: "15分", title: "15 分钟", duration: 15 * 60),
        Preset(id: "30m", shortTitle: "30分", title: "30 分钟", duration: 30 * 60),
        Preset(id: "1h", shortTitle: "1小时", title: "1 小时", duration: 60 * 60),
        Preset(id: "2h", shortTitle: "2小时", title: "2 小时", duration: 2 * 60 * 60),
        Preset(id: "4h", shortTitle: "4小时", title: "4 小时", duration: 4 * 60 * 60),
        Preset(id: "8h", shortTitle: "8小时", title: "8 小时", duration: 8 * 60 * 60),
        Preset(id: "16h", shortTitle: "16小时", title: "16 小时（57600 秒）", duration: 16 * 60 * 60),
        Preset(id: "inf", shortTitle: "无限期", title: "无限期（直到取消）", duration: nil)
    ]

    struct Session {
        let startedAt: Date
        let duration: TimeInterval?   // nil means "until I cancel"
        let scope: PowerAssertionScope
        let presetId: String?

        var endsAt: Date? {
            duration.map { startedAt.addingTimeInterval($0) }
        }

        func remaining(at date: Date) -> TimeInterval? {
            guard let endsAt else { return nil }
            return endsAt.timeIntervalSince(date)
        }
    }

    private let defaults = UserDefaults.standard
    private let assertion = PowerAssertion()
    private var ticker: Timer?

    @Published private(set) var session: Session?
    @Published private(set) var now: Date = Date()
    @Published private(set) var lastFinishedMessage: String?
    @Published private(set) var lastErrorMessage: String?
    @Published var displayAllowedToSleep: Bool {
        didSet {
            defaults.set(displayAllowedToSleep, forKey: DefaultsKey.allowDisplaySleep)
            if let session {
                let scope: PowerAssertionScope = displayAllowedToSleep ? .system : .displayAndSystem
                let remaining = session.endsAt.map { max(1, $0.timeIntervalSinceNow) }
                _ = startSession(duration: remaining, scope: scope, presetId: session.presetId)
            }
        }
    }

    private static let endTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override var statusBarTitle: String? {
        guard let session else { return nil }
        guard let remaining = session.remaining(at: now) else { return "∞" }
        return DurationFormatter.countdown(max(0, remaining))
    }

    override var statusBarSymbolName: String? {
        guard session != nil else { return nil }
        return displayAllowedToSleep ? "bolt.circle.fill" : "sun.max.fill"
    }

    var isActive: Bool { session != nil }

    var isTimed: Bool { session?.duration != nil }

    var activePresetId: String? { session?.presetId }

    var remainingText: String? {
        guard let session, let remaining = session.remaining(at: now) else { return nil }
        return DurationFormatter.countdown(max(0, remaining))
    }

    var elapsedText: String? {
        guard let session, session.duration == nil else { return nil }
        return DurationFormatter.humanReadable(max(1, now.timeIntervalSince(session.startedAt)))
    }

    var endTimeText: String? {
        guard let endsAt = session?.endsAt else { return nil }
        return Self.endTimeFormatter.string(from: endsAt)
    }

    override init() {
        self.displayAllowedToSleep = UserDefaults.standard.bool(forKey: DefaultsKey.allowDisplaySleep)
        super.init()
    }

    // MARK: - Actions for UI

    func toggleQuickSession() {
        if isActive {
            cancel()
        } else {
            startPreset(Self.presets.first(where: { $0.id == "16h" })!)
        }
    }

    func startPreset(_ preset: Preset) {
        _ = startSession(duration: preset.duration, presetId: preset.id)
    }

    /// Parses and starts a custom duration string. Returns an error string on invalid input, or nil on success.
    @discardableResult
    func startCustom(input: String) -> String? {
        guard let seconds = DurationFormatter.parse(input) else {
            let msg = "无法识别时长“\(input)”，示例：90、45m、2h、57600s、16:00:00"
            lastErrorMessage = msg
            return msg
        }
        lastErrorMessage = nil
        _ = startSession(duration: seconds, presetId: nil)
        return nil
    }

    func extendOneHour() {
        guard let session, let endsAt = session.endsAt else { return }
        let remaining = max(0, endsAt.timeIntervalSinceNow) + 3600
        _ = startSession(duration: remaining, scope: session.scope, presetId: nil)
    }

    func cancel() {
        finish(reason: "已取消")
    }

    override func refreshMenuState() {
        now = Date()
        if let session, let remaining = session.remaining(at: now), remaining <= 0 {
            finish(reason: "已到时间，唤醒保护结束")
        }
    }

    // MARK: - Session control

    @discardableResult
    private func startSession(
        duration: TimeInterval?,
        scope: PowerAssertionScope? = nil,
        presetId: String?
    ) -> Bool {
        let effectiveScope = scope ?? (displayAllowedToSleep ? .system : .displayAndSystem)
        guard assertion.acquire(effectiveScope) else {
            lastErrorMessage = "系统拒绝了唤醒断言，可能受策略限制"
            return false
        }

        now = Date()
        session = Session(startedAt: now, duration: duration, scope: effectiveScope, presetId: presetId)
        lastFinishedMessage = nil
        lastErrorMessage = nil
        startTicker()
        onStateChange?()
        return true
    }

    private func finish(reason: String) {
        assertion.release()
        session = nil
        ticker?.invalidate()
        ticker = nil
        lastFinishedMessage = reason
        onStateChange?()
        NSSound(named: "Glass")?.play()
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    @objc private func handleTimerTick() {
        now = Date()
        guard let session else { return }
        if let remaining = session.remaining(at: now), remaining <= 0 {
            finish(reason: "已到时间，唤醒保护结束")
            return
        }
        onStateChange?()
    }

    override func shutdown() {
        ticker?.invalidate()
        ticker = nil
        assertion.release()
    }
}
