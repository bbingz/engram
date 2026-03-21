// macos/Engram/MenuBarController.swift
import AppKit
import SwiftUI

@MainActor
class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    // Stored so openWindow() can inject them into the standalone window
    private let db: DatabaseManager
    private let indexer: IndexerProcess
    private let daemonClient: DaemonClient
    private var clickTimer: Timer?
    private var badgeTimer: Timer?
    private var dockIconObserver: NSObjectProtocol?
    private var lastShowDockIcon: Bool?

    init(db: DatabaseManager, indexer: IndexerProcess, daemonClient: DaemonClient) {
        self.db = db
        self.indexer = indexer
        self.daemonClient = daemonClient

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover    = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 420)
        popover.behavior    = .transient

        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(db)
                .environmentObject(indexer)
                .environmentObject(daemonClient)
        )

        super.init()

        if let btn = statusItem.button {
            let img = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "brain.head.profile",
                           accessibilityDescription: "Engram")
            img?.size = NSSize(width: 19, height: 15)
            img?.isTemplate = true
            btn.image = img
            // Receive both left and right mouse-up so we can distinguish them
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.action = #selector(handleClick)
            btn.target = self
        }

        // Update badge: total sessions + live count (consolidated, 10s poll)
        Task { @MainActor in
            // Initial badge
            self.updateBadge()
            // Re-update whenever totalSessions changes
            for await _ in indexer.$totalSessions.values {
                self.updateBadge()
            }
        }

        // Poll live sessions every 10s for badge update
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateBadge() }
        }

        // Listen for settings open requests from PopoverView/ContentView gear button
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettings, object: nil
        )

        // Listen for "Open Window" requests from PopoverView footer/timeline
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenWindow(_:)),
            name: .openWindow, object: nil
        )

        // Apply persistent Dock icon preference
        applyDockIconPreference()
        dockIconObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyDockIconPreference()
            }
        }
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if event.clickCount >= 2 {
            // Double-click: open standalone window
            clickTimer?.invalidate()
            clickTimer = nil
            if popover.isShown { popover.performClose(nil) }
            openWindow()
        } else {
            // Delay single-click to allow double-click detection
            clickTimer?.invalidate()
            clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.togglePopover()
                }
            }
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let btn = statusItem.button {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Right-click context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: String(localized: "Open Window"), action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit Engram"),
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self          // menuDidClose will nil out statusItem.menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    // Remove the menu after it closes so left-click still triggers the popover
    nonisolated func menuDidClose(_ menu: NSMenu) {
        Task { @MainActor in self.statusItem.menu = nil }
    }

    @objc func openSettings() {
        if popover.isShown { popover.performClose(nil) }

        // Reuse existing settings window if still alive
        if let win = settingsWindow {
            NSApp.setActivationPolicy(.regular)
            applyDockIcon()
            setupMainMenu()
            win.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(db)
                .environmentObject(indexer)
                .environmentObject(daemonClient)
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = String(localized: "Settings")
        win.setContentSize(NSSize(width: 520, height: 500))
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        setupMainMenu()
        win.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        self.settingsWindow = win
    }

    // MARK: - Standalone window (hybrid activation)

    @objc private func handleOpenWindow(_ notification: Notification) {
        openWindow()
        // If a SessionBox was passed, forward it after the window is ready
        if let box = notification.object as? SessionBox {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openSession, object: box)
            }
        }
    }

    @objc func openWindow() {
        // Close popover if open
        if popover.isShown { popover.performClose(nil) }

        // Reuse existing window if still alive
        if let win = window {
            // Must set policy BEFORE showing window, then activate after a run-loop tick
            NSApp.setActivationPolicy(.regular)
            applyDockIcon()
            setupMainMenu()
            win.makeKeyAndOrderFront(nil)
            // Delay activation to let macOS process the policy change
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let hostingController = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(db)
                .environmentObject(indexer)
                .environmentObject(daemonClient)
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Engram"
        win.setContentSize(NSSize(width: 900, height: 640))
        win.minSize = NSSize(width: 600, height: 400)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.titleVisibility = .hidden
        win.toolbarStyle = .unified
        win.styleMask.insert(.fullSizeContentView)

        // Switch to regular app: show Dock icon + main menu bar
        // Must set policy before showing window
        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        setupMainMenu()

        win.makeKeyAndOrderFront(nil)
        // Delay activation to let macOS process the policy change
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
        self.window = win
    }

    // When a window closes, check if any windows remain; if not, revert to accessory mode
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            let closingWindow = notification.object as? NSWindow
            if closingWindow === self.window {
                self.window = nil
            }
            if closingWindow === self.settingsWindow {
                self.settingsWindow = nil
            }
            // Only revert to accessory if no windows are open and user doesn't want persistent Dock icon
            if self.window == nil && self.settingsWindow == nil {
                let keepDock = UserDefaults.standard.bool(forKey: "showDockIcon")
                if !keepDock {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: - Dock icon

    private func applyDockIcon() {
        // Programmatically set the Dock icon from the asset catalog
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    private func updateBadge() {
        let total = indexer.totalSessions
        Task {
            do {
                let response: LiveSessionsResponse = try await daemonClient.fetch("/api/live")
                    let live = response.sessions.filter { $0.activityLevel == "active" }
                if live.isEmpty {
                    self.statusItem.button?.title = total > 0 ? " \(total)" : ""
                } else {
                    self.statusItem.button?.title = " \(total) \u{25CF} \(live.count)"
                }
            } catch {
                self.statusItem.button?.title = total > 0 ? " \(total)" : ""
            }
        }
    }

    private func applyDockIconPreference() {
        let show = UserDefaults.standard.bool(forKey: "showDockIcon")
        guard show != lastShowDockIcon else { return }
        lastShowDockIcon = show
        if show {
            NSApp.setActivationPolicy(.regular)
            applyDockIcon()
            setupMainMenu()
        } else if window == nil && settingsWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Main menu bar (shown in regular/window mode)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About Engram"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Engram"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (for Copy/Paste/Select All in text fields)
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
