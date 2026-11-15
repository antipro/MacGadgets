import AppKit

/// Base class providing the boilerplate most gadget modules need: a delegate hook
/// that notifies the app shell when menu content or status bar state changes.
@MainActor
class BaseGadgetModule: NSObject, GadgetModule {
    var identifier: String { "base" }
    var displayName: String { "Gadget" }

    var statusBarTitle: String? { nil }
    var statusBarSymbolName: String? { nil }

    /// Called whenever the gadget needs the status bar item re-rendered.
    var onStateChange: (() -> Void)?

    func populateMenu(into menu: NSMenu) {}
    func refreshMenuState() {}
    func shutdown() {}
}
