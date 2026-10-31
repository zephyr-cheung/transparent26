import AppKit
import Foundation

final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var signalSources: [DispatchSourceSignal] = []
    private var rescuePanel: NSPanel?
    private var state = State.load()

    private var enabled: Bool {
        get { state.enabled }
        set { state.enabled = newValue; state.save() }
    }

    private var alpha: Float {
        get { state.alpha }
        set { state.alpha = newValue; state.save() }
    }

    /// 0 means "every display".
    private var display: UInt32 {
        get { state.display }
        set { state.display = newValue; state.save() }
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installExitGuards()
        buildStatusItem()

        if enabled {
            apply()
        }

        // A frontmost-app switch can reset the override; re-assert our state.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reapply),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowServer.restore()
    }

    // MARK: - State

    private func apply() {
        let target = enabled ? alpha : 1.0
        WindowServer.setMenuBarAlpha(target, display: display)
        refreshStatusItemTitle()
        updateRescuePanel()
    }

    @objc private func reapply() {
        guard enabled else { return }
        apply()
    }

    private func setEnabled(_ value: Bool) {
        enabled = value
        apply()
        rebuildMenu()
    }

    private func refreshStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let symbol = NSImage(
            systemSymbolName: enabled ? "rectangle.topthird.inset.filled" : "rectangle.topthird.inset",
            accessibilityDescription: "透明菜单栏"
        )
        symbol?.isTemplate = true
        button.image = symbol
        button.title = enabled ? " \(Int(alpha * 100))%" : ""
    }

    // MARK: - Menu

    private func buildStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset",
            accessibilityDescription: "透明菜单栏"
        )
        button.image?.isTemplate = true
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: stateDescription, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "透明菜单栏",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let alphaItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let alphaMenu = NSMenu()
        for preset in [Float(0.15), 0.3, 0.45, 0.6, 0.75, 1.0] {
            let item = NSMenuItem(
                title: String(format: "%.2f", preset),
                action: #selector(selectAlpha(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: preset)
            item.state = abs(alpha - preset) < 0.001 ? .on : .off
            alphaMenu.addItem(item)
        }
        alphaItem.submenu = alphaMenu
        alphaItem.isEnabled = enabled
        menu.addItem(alphaItem)

        let displayItem = NSMenuItem(title: "作用于", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let all = NSMenuItem(title: "所有显示器", action: #selector(selectDisplay(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = NSNumber(value: 0)
        all.state = display == 0 ? .on : .off
        displayMenu.addItem(all)
        for id in WindowServer.activeDisplays() {
            let item = NSMenuItem(
                title: "显示器 \(id)",
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: UInt32(id))
            item.state = display == UInt32(id) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        displayItem.isEnabled = enabled
        menu.addItem(displayItem)

        menu.addItem(.separator())

        let restore = NSMenuItem(title: "还原并退出", action: #selector(restoreAndQuit), keyEquivalent: "r")
        restore.target = self
        menu.addItem(restore)

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refreshStatusItemTitle()
    }

    private var stateDescription: String {
        guard WindowServer.isAvailable else { return "SkyLight 不可用" }
        guard enabled else { return "菜单栏正常" }
        let target = display == 0 ? "所有显示器" : "显示器 \(display)"
        return String(format: "透明 %.0f%% · %@", alpha * 100, target)
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        setEnabled(!enabled)
    }

    @objc private func selectAlpha(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        alpha = number.floatValue
        apply()
        rebuildMenu()
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        if enabled { WindowServer.setMenuBarAlpha(1.0, display: display) }
        display = number.uint32Value
        apply()
        rebuildMenu()
    }

    @objc private func restoreAndQuit() {
        enabled = false
        WindowServer.restore()
        updateRescuePanel()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Rescue panel

    /// Below roughly 20% the status item itself is unreadable/invisible, so a small
    /// floating button keeps the user from being locked out of their own menu bar.
    private func updateRescuePanel() {
        guard enabled, alpha <= 0.2 else {
            rescuePanel?.orderOut(nil)
            return
        }
        if rescuePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 132, height: 30),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let button = NSButton(title: "还原菜单栏", target: self, action: #selector(rescueRestore))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 0, y: 0, width: 132, height: 30)
            panel.contentView = button
            rescuePanel = panel
        }

        if let screen = NSScreen.main {
            let frame = screen.frame
            let size = rescuePanel?.frame.size ?? NSSize(width: 132, height: 30)
            rescuePanel?.setFrameOrigin(
                NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 8)
            )
        }
        rescuePanel?.orderFrontRegardless()
    }

    @objc private func rescueRestore() {
        enabled = false
        WindowServer.restore()
        updateRescuePanel()
        rebuildMenu()
    }

    // MARK: - Exit guards

    /// The override belongs to this WindowServer connection and disappears when the
    /// process dies, but every explicit exit path still puts the menu bar back.
    private func installExitGuards() {
        atexit {
            WindowServer.restore()
        }

        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                WindowServer.restore()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
