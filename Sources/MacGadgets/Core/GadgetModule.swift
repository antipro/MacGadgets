import AppKit

/// Protocol for pluggable menu bar gadget modules inside MacGadgets.
@MainActor
protocol GadgetModule: AnyObject {
    var identifier: String { get }
    var displayName: String { get }

    /// Build or append menu items for this gadget into the root menu.
    func populateMenu(into menu: NSMenu)

    /// Refresh dynamic item titles/states (e.g. countdown ticks).
    func refreshMenuState()

    /// Optional status bar text contribution when this gadget has active status.
    var statusBarTitle: String? { get }

    /// Optional SF Symbol name overriding the default status bar icon while active.
    var statusBarSymbolName: String? { get }

    /// Clean up any OS resources (timers, IOKit assertions, etc.) on app termination.
    func shutdown()
}
