import AppKit
import Combine

/// Status bar gadget that suppresses idle sleep for a chosen duration, using the
/// same IOKit power assertion mechanism as `caffeinate -d -t 57600`, cancellable anytime.
@MainActor
final class KeepAwakeModule: BaseGadgetModule, ObservableObject {
    override var identifier: String { "keep-awake" }
    override var displayName: String { L10n.tr("keep_awake.title") }

    private enum DefaultsKey {
        static let allowDisplaySleep = "KeepAwake.allowDisplaySleep"
        static let moduleEnabled = "KeepAwake.moduleEnabled"
    }

    static let defaultQuickDuration: TimeInterval = 16 * 60 * 60 // 57600 seconds

    struct Preset: Identifiable {
        let id: String
        let shortKey: String
        let titleKey: String
        let duration: TimeInterval?

        var shortTitle: String { L10n.tr(shortKey) }
        var title: String { L10n.tr(titleKey) }
    }

    static let presets: [Preset] = [
        Preset(id: "15m", shortKey: "keep_awake.preset.15m.short", titleKey: "keep_awake.preset.15m.title", duration: 15 * 60),
        Preset(id: "30m", shortKey: "keep_awake.preset.30m.short", titleKey: "keep_awake.preset.30m.title", duration: 30 * 60),
        Preset(id: "1h", shortKey: "keep_awake.preset.1h.short", titleKey: "keep_awake.preset.1h.title", duration: 60 * 60),
        Preset(id: "2h", shortKey: "keep_awake.preset.2h.short", titleKey: "keep_awake.preset.2h.title", duration: 2 * 60 * 60),
        Preset(id: "4h", shortKey: "keep_awake.preset.4h.short", titleKey: "keep_awake.preset.4h.title", duration: 4 * 60 * 60),
        Preset(id: "8h", shortKey: "keep_awake.preset.8h.short", titleKey: "keep_awake.preset.8h.title", duration: 8 * 60 * 60),
        Preset(id: "16h", shortKey: "keep_awake.preset.16h.short", titleKey: "keep_awake.preset.16h.title", duration: 16 * 60 * 60),
        Preset(id: "inf", shortKey: "keep_awake.preset.inf.short", titleKey: "keep_awake.preset.inf.title", duration: nil)
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
    @Published var isModuleEnabled: Bool {
        didSet {
            defaults.set(isModuleEnabled, forKey: DefaultsKey.moduleEnabled)
            if !isModuleEnabled {
                cancel()
            }
            onStateChange?()
        }
    }

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
        if UserDefaults.standard.object(forKey: DefaultsKey.moduleEnabled) == nil {
            self.isModuleEnabled = true
        } else {
            self.isModuleEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.moduleEnabled)
        }
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
            let msg = L10n.tr("keep_awake.error.invalid_duration", input)
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
        finish(reason: L10n.tr("keep_awake.finished.cancelled"))
    }

    override func refreshMenuState() {
        now = Date()
        if let session, let remaining = session.remaining(at: now), remaining <= 0 {
            finish(reason: L10n.tr("keep_awake.finished.expired"))
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
            lastErrorMessage = L10n.tr("keep_awake.error.assertion_denied")
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
            finish(reason: L10n.tr("keep_awake.finished.expired"))
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
