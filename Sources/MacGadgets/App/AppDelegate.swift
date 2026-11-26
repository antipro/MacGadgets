import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var preferencesWindow: NSWindow?
    private var modules: [BaseGadgetModule] = []
    private var keepAwakeModule: KeepAwakeModule?
    private var scrollReverserModule: ScrollReverserModule?
    private var androidDriveModule: AndroidDriveModule?
    private var kdeConnectModule: KDEConnectModule?
    private var globalClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
            button.image = menuBarIcon()
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem

        let keepAwake = KeepAwakeModule()
        let scrollReverser = ScrollReverserModule()
        let androidDrive = AndroidDriveModule()
        let kdeConnect = KDEConnectModule()
        self.keepAwakeModule = keepAwake
        self.scrollReverserModule = scrollReverser
        self.androidDriveModule = androidDrive
        self.kdeConnectModule = kdeConnect
        self.modules = [keepAwake, scrollReverser, androidDrive, kdeConnect]

        for module in modules {
            module.onStateChange = { [weak self] in
                self?.refreshStatusItem()
            }
        }

        setupPopover(keepAwake: keepAwake, scrollReverser: scrollReverser, androidDrive: androidDrive, kdeConnect: kdeConnect)
        LocalizationManager.shared.onLanguageChange = { [weak self] in
            self?.refreshStatusItem()
            self?.preferencesWindow?.title = L10n.tr("prefs.window_title")
        }
        refreshStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalClickMonitor()
        modules.forEach { $0.shutdown() }
    }

    // MARK: - Popover Setup

    private func setupPopover(
        keepAwake: KeepAwakeModule,
        scrollReverser: ScrollReverserModule,
        androidDrive: AndroidDriveModule,
        kdeConnect: KDEConnectModule
    ) {
        let rootView = ControlCenterView(
            keepAwake: keepAwake,
            scrollReverser: scrollReverser,
            androidDrive: androidDrive,
            kdeConnect: kdeConnect,
            onOpenPreferences: { [weak self] in
                self?.openPreferences()
            },
            onQuit: { [weak self] in
                self?.quit()
            },
            onOpenCustomInput: { [weak self] in
                self?.focusPopoverWindow()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        self.popover = popover
    }

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu(from: sender)
            return
        }
        togglePopover(from: sender)
    }

    private func togglePopover(from button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        modules.forEach { $0.refreshMenuState() }
        refreshStatusItem()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installGlobalClickMonitor()
    }

    private func focusPopoverWindow() {
        NSApp.activate(ignoringOtherApps: true)
        popover?.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        popover?.performClose(nil)
        let menu = NSMenu()
        let prefsItem = NSMenuItem(title: L10n.tr("menu.preferences"), action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        let aboutItem = NSMenuItem(title: L10n.tr("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.tr("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPreferences() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = preferencesWindow {
            window.title = L10n.tr("prefs.window_title")
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let keepAwakeModule, let scrollReverserModule, let androidDriveModule, let kdeConnectModule else { return }
        let prefsView = PreferencesView(
            keepAwake: keepAwakeModule,
            scrollReverser: scrollReverserModule,
            androidDrive: androidDriveModule,
            kdeConnect: kdeConnectModule
        )
        let hostingController = NSHostingController(rootView: prefsView)
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.tr("prefs.window_title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.preferencesWindow = window
    }

    // MARK: - NSPopoverDelegate & Outside Click

    func popoverDidClose(_ notification: Notification) {
        removeGlobalClickMonitor()
    }

    private func installGlobalClickMonitor() {
        removeGlobalClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.popover?.performClose(nil)
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - Status Bar Rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let activeTitles = modules.compactMap { $0.statusBarTitle }
        let activeSymbols = modules.compactMap { $0.statusBarSymbolName }

        button.image = menuBarIcon(symbolName: activeSymbols.first)
        button.title = activeTitles.isEmpty ? "" : " " + activeTitles.joined(separator: " ")

        var tooltips = ["MacGadgets"]
        if let keepAwakeModule, keepAwakeModule.isModuleEnabled, keepAwakeModule.isActive, let title = keepAwakeModule.statusBarTitle {
            tooltips.append(L10n.tr("tooltip.keep_awake", title))
        }
        if let scrollReverserModule, scrollReverserModule.isModuleEnabled, scrollReverserModule.isActiveAndRunning {
            tooltips.append(scrollReverserModule.summaryText)
        }
        if let androidDriveModule, androidDriveModule.isModuleEnabled, androidDriveModule.isMounted {
            tooltips.append(androidDriveModule.summaryText)
        }
        if let kdeConnectModule, kdeConnectModule.isEnabled, kdeConnectModule.connectedPairedCount > 0 {
            tooltips.append(kdeConnectModule.summaryText)
        }
        button.toolTip = tooltips.joined(separator: "\n")
    }

    private func menuBarIcon(symbolName: String? = nil) -> NSImage? {
        let name = symbolName ?? "cup.and.saucer.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "MacGadgets")
        image?.isTemplate = true
        return image
    }

    // MARK: - Actions

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacGadgets",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            .credits: NSAttributedString(
                string: L10n.tr("about.credits"),
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func systemDidWake() {
        modules.forEach { $0.refreshMenuState() }
        refreshStatusItem()
    }
}
