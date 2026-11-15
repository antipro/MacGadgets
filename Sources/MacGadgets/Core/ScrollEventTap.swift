import ApplicationServices
import CoreGraphics
import Foundation

/// Identifies where a `CGEventType.scrollWheel` event originated.
enum ScrollInputSource: Equatable {
    /// Traditional notched/stepped external mouse scroll wheel (`isContinuous == 0`).
    case mouseWheel
    /// Continuous pixel-based scrolling from a trackpad or touch surface (`isContinuous != 0`).
    case trackpad
}

/// Configuration snapshot read by the CGEventTap callback.
struct ScrollReversalConfig: Equatable {
    var invertMouseWheel: Bool = false
    var invertTrackpad: Bool = false
    var invertHorizontal: Bool = false

    var isAnyEnabled: Bool {
        invertMouseWheel || invertTrackpad
    }
}

/// Pure, testable logic for classifying a scroll event and deciding which axes to flip.
enum ScrollReversalLogic {
    static func classify(isContinuous: Int64) -> ScrollInputSource {
        isContinuous == 0 ? .mouseWheel : .trackpad
    }

    static func shouldInvertVertical(source: ScrollInputSource, config: ScrollReversalConfig) -> Bool {
        switch source {
        case .mouseWheel:
            return config.invertMouseWheel
        case .trackpad:
            return config.invertTrackpad
        }
    }

    static func shouldInvertHorizontal(source: ScrollInputSource, config: ScrollReversalConfig) -> Bool {
        config.invertHorizontal && shouldInvertVertical(source: source, config: config)
    }
}

/// Wraps a `CGEvent.tapCreate` session event tap that intercepts `.scrollWheel` events
/// and negates vertical (and optionally horizontal) scroll deltas for mouse wheel / trackpad.
final class ScrollEventTap {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var _config = ScrollReversalConfig()

    var config: ScrollReversalConfig {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _config
        }
        set {
            lock.lock()
            _config = newValue
            lock.unlock()
        }
    }

    var isRunning: Bool {
        eventTap != nil
    }

    /// Returns true if Accessibility permission is currently granted to this process.
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        if !prompt {
            return AXIsProcessTrusted()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Starts the event tap on the main run loop. Returns false if permission is missing or creation fails.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil {
            return true
        }

        guard Self.hasAccessibilityPermission(prompt: false) else {
            return false
        }

        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let instance = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return instance.handleEvent(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            NSLog("MacGadgets: CGEvent.tapCreate failed despite AXIsProcessTrusted() == true")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        self.eventTap = tap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .scrollWheel else {
            return Unmanaged.passUnretained(event)
        }

        let currentConfig = self.config
        guard currentConfig.isAnyEnabled else {
            return Unmanaged.passUnretained(event)
        }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        let source = ScrollReversalLogic.classify(isContinuous: isContinuous)

        let invertV = ScrollReversalLogic.shouldInvertVertical(source: source, config: currentConfig)
        let invertH = ScrollReversalLogic.shouldInvertHorizontal(source: source, config: currentConfig)

        if invertV {
            // Read all three representations before mutating any field so CoreGraphics
            // doesn't overwrite high-precision pixel deltas while we flip line deltas.
            let delta1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let pointDelta1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let fixedDelta1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)

            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -delta1)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDelta1)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedDelta1)
        }

        if invertH {
            let delta2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let pointDelta2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let fixedDelta2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -delta2)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pointDelta2)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedDelta2)
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
