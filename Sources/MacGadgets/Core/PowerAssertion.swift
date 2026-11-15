import Foundation
import IOKit.pwr_mgt

/// Which idle-sleep behaviours to suppress while an assertion is held.
struct PowerAssertionScope: OptionSet, Hashable {
    let rawValue: Int

    static let system = PowerAssertionScope(rawValue: 1 << 0)
    static let display = PowerAssertionScope(rawValue: 1 << 1)

    /// `caffeinate -d`: display stays on (which also implies the system is not idle).
    static let displayOnly: PowerAssertionScope = [.display]
    /// `caffeinate -d -i`: display and system idle sleep are both suppressed.
    static let displayAndSystem: PowerAssertionScope = [.display, .system]
}

/// Thin wrapper around `IOPMAssertionCreateWithName` that keeps a set of
/// assertions alive until released. This is exactly what `caffeinate` does
/// internally, so no helper process is spawned.
final class PowerAssertion {
    private var assertionIDs: [PowerAssertionScope: IOPMAssertionID] = [:]
    private let reason: String

    init(reason: String = "MacGadgets keeps this Mac awake") {
        self.reason = reason
    }

    var isActive: Bool { !assertionIDs.isEmpty }
    var activeScopes: Set<PowerAssertionScope> { Set(assertionIDs.keys) }

    /// Acquire (or re-acquire) assertions for `scope`.
    @discardableResult
    func acquire(_ scope: PowerAssertionScope) -> Bool {
        release()
        guard !scope.isEmpty else { return true }

        if scope.contains(.system) {
            guard createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep, for: .system) else {
                release()
                return false
            }
        }
        if scope.contains(.display) {
            guard createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep, for: .display) else {
                release()
                return false
            }
        }
        return true
    }

    func release() {
        for (_, id) in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs.removeAll()
    }

    /// Returns the human readable reason macOS shows in `pmset -g assertions`.
    var assertionDescription: String { reason }

    private func createAssertion(_ type: String, for scope: PowerAssertionScope) -> Bool {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            NSLog("MacGadgets: failed to create power assertion %@ (0x%x)", type, result)
            return false
        }
        assertionIDs[scope] = id
        return true
    }

    deinit {
        for (_, id) in assertionIDs {
            IOPMAssertionRelease(id)
        }
    }
}
