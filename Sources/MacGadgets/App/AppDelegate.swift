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
    private var modules: [BaseGadgetModule] = []
    private var keepAwakeModule: KeepAwakeModule?
    private var scrollReverserModule: ScrollReverserModule?
    private var androidDriveModule: AndroidDriveModule?
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
        self.keepAwakeModule = keepAwake
        self.scrollReverserModule = scrollReverser
        self.androidDriveModule = androidDrive
        self.modules = [keepAwake, scrollReverser, androidDrive]

        for module in modules {
            module.onStateChange = { [weak self] in
                self?.refreshStatusItem()
            }
        }

        setupPopover(keepAwake: keepAwake, scrollReverser: scrollReverser, androidDrive: androidDrive)
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
        androidDrive: AndroidDriveModule
    ) {
        let rootView = ControlCenterView(
            keepAwake: keepAwake,
            scrollReverser: scrollReverser,
            androidDrive: androidDrive,
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
        let aboutItem = NSMenuItem(title: "关于 MacGadgets", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 MacGadgets", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
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
        if let keepAwakeModule, keepAwakeModule.isActive, let title = keepAwakeModule.statusBarTitle {
            tooltips.append("防休眠中：\(title)")
        }
        if let scrollReverserModule, scrollReverserModule.isActiveAndRunning {
            tooltips.append(scrollReverserModule.summaryText)
        }
        if let androidDriveModule, androidDriveModule.isMounted {
            tooltips.append(androidDriveModule.summaryText)
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
                string: "常驻菜单栏的原生控制中心小工具集合：\n• 保持唤醒：基于 IOKit 电源断言（等同 caffeinate -d）\n• 滚动方向翻转：基于 CoreGraphics 事件拦截，独立翻转鼠标与触摸板\n• Android 磁盘：基于 IOKit USB + MTP + 本地 NFSv3 服务与 mDNS 别名，让安卓手机出现在访达「位置」中",
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
