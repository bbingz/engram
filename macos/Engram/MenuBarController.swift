// macos/Engram/MenuBarController.swift
import AppKit
import SwiftUI
import Observation

enum MenuBarClickAction: Equatable {
    case showContextMenu
    case togglePopover
    case openWindow
}

@MainActor
class MenuBarController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    // Stored so openWindow() can inject them into the standalone window
    private let db: DatabaseManager
    private let serviceStatusStore: EngramServiceStatusStore
    private let serviceClient: EngramServiceClient
    private let usagePressureNotifier = UsagePressureNotifier()
    private var badgeTimer: Timer?
    // Rate-limit the live-session FS scan: the badge timer AND every
    // Observation change (totalSessions / todayParentSessions) both call
    // updateBadge(), so without coalescing a burst of changes fans out into
    // repeated recursive live-session scans. Skip the scan if we ran one
    // recently and just refresh the cheap today-count label instead.
    private var lastBadgeScan: Date = .distantPast
    private static let badgeScanMinInterval: TimeInterval = 5
    private var dockIconObserver: NSObjectProtocol?
    private var lastShowDockIcon: Bool?
    private var lastShowMenuBarActivity: Bool?
    private let windowSize: NSSize

    /// When off, the menu bar shows only the static icon (no today/live counts,
    /// no usage gauge). Defaults ON via `register(defaults:)` in `init` so the
    /// current behavior is preserved for existing installs.
    private var showMenuBarActivity: Bool {
        UserDefaults.standard.bool(forKey: "showMenuBarActivity")
    }

    init(
        db: DatabaseManager,
        serviceStatusStore: EngramServiceStatusStore,
        serviceClient: EngramServiceClient,
        windowSize: NSSize? = nil
    ) {
        self.windowSize = windowSize ?? NSSize(width: 900, height: 640)
        self.db = db
        self.serviceStatusStore = serviceStatusStore
        self.serviceClient = serviceClient

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover    = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 420)
        popover.behavior    = .transient

        popover.contentViewController = NSHostingController(
            rootView: LocalizedRoot {
                PopoverView()
                    .environment(db)
                    .environment(serviceStatusStore)
                    .environment(serviceClient)
            }
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

        // Menu-bar activity (today/live counts + usage gauge) defaults ON to
        // preserve current behavior; users can silence the constantly-changing
        // badge from Settings ▸ General ▸ Menu Bar.
        UserDefaults.standard.register(defaults: ["showMenuBarActivity": true])
        lastShowMenuBarActivity = showMenuBarActivity

        // Update badge: total sessions + live count (consolidated, 30s poll)
        self.updateBadge()
        // Re-update whenever totalSessions changes (Observation framework)
        self.observeTotalSessions()
        // OBS-O2: reflect degraded/error service status in the menu bar.
        self.updateStatusIndicator()
        self.observeServiceStatus()
        usagePressureNotifier.observe(summary: serviceStatusStore.usagePressureSummary)
        self.observeUsagePressure()

        // Poll live sessions every 30s for badge update. The service caches the
        // live-session scan for 30s, so polling faster (the old 10s) just paid
        // extra IPC round-trips for the same cached payload; aligning the cadence
        // to the cache TTL removes ~2/3 of the always-on idle badge IPC traffic.
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateBadge()
                await self?.checkCostBudget()
            }
        }
        // Run an initial budget check at startup so a breach is surfaced without
        // waiting a full timer tick.
        Task { @MainActor in await self.checkCostBudget() }

        // Listen for settings open requests from popover and window controls.
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
                self?.applyMenuBarActivityPreference()
            }
        }
    }

    // MARK: - Click handling

    nonisolated static func clickAction(for eventType: NSEvent.EventType, clickCount: Int) -> MenuBarClickAction? {
        switch eventType {
        case .rightMouseUp:
            return .showContextMenu
        case .leftMouseUp:
            return clickCount >= 2 ? .openWindow : .togglePopover
        default:
            return nil
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        guard let action = Self.clickAction(for: event.type, clickCount: event.clickCount) else { return }

        switch action {
        case .showContextMenu:
            showContextMenu()
        case .togglePopover:
            togglePopover()
        case .openWindow:
            openWindow()
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

        // Order (integrate with service-resilience row 5): Open Window / Settings /
        // (Report an Issue, Show Onboarding) / separator / [Restart Service when
        // isFailed] / Quit — Help items before the separator.
        let openItem = NSMenuItem(title: String(localized: "Open Window"), action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let reportItem = NSMenuItem(
            title: String(localized: "Report an Issue…"),
            action: #selector(reportAnIssue),
            keyEquivalent: ""
        )
        reportItem.target = self
        menu.addItem(reportItem)

        let onboardItem = NSMenuItem(
            title: String(localized: "Show Onboarding"),
            action: #selector(showOnboardingFromMenu),
            keyEquivalent: ""
        )
        onboardItem.target = self
        menu.addItem(onboardItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit Engram"),
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self          // menuDidClose will nil out statusItem.menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc func reportAnIssue() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        NSWorkspace.shared.open(GitHubIssueURL.reportIssue(version: version, build: build))
    }

    @objc func showOnboardingFromMenu() {
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
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
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let hostingController = NSHostingController(
            rootView: LocalizedRoot {
                SettingsView()
                    .environment(db)
                    .environment(serviceStatusStore)
                    .environment(serviceClient)
            }
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = String(localized: "Settings")
        win.setContentSize(NSSize(width: 760, height: 540))
        win.minSize = NSSize(width: 720, height: 500)
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        NSApp.setActivationPolicy(.regular)
        applyDockIcon()
        setupMainMenu()
        win.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
        self.settingsWindow = win
    }

    // MARK: - Standalone window (hybrid activation)

    @objc private func handleOpenWindow(_ notification: Notification) {
        openWindow()
        // If a SessionBox was passed, forward it after the window is ready
        if let box = notification.object as? SessionBox {
            Task { @MainActor in
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
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let hostingController = NSHostingController(
            rootView: LocalizedRoot {
                MainWindowView()
                    .environment(db)
                    .environment(serviceStatusStore)
                    .environment(serviceClient)
            }
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = String(localized: "Engram")
        win.setContentSize(windowSize)
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
        Task { @MainActor in
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

    // MARK: - Observation

    private func observeTotalSessions() {
        withObservationTracking {
            _ = serviceStatusStore.totalSessions
            _ = serviceStatusStore.todayParentSessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateBadge()
                self?.observeTotalSessions()
            }
        }
    }

    /// OBS-O2: when indexing is degraded/errored, show a warning glyph + tooltip
    /// in the menu bar so the failure is no longer invisible.
    private func observeServiceStatus() {
        withObservationTracking {
            _ = serviceStatusStore.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusIndicator()
                self?.observeServiceStatus()
            }
        }
    }

    private func observeUsagePressure() {
        withObservationTracking {
            _ = serviceStatusStore.usageData
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusIndicator()
                if let self {
                    usagePressureNotifier.observe(summary: serviceStatusStore.usagePressureSummary)
                }
                self?.observeUsagePressure()
            }
        }
    }

    private func updateStatusIndicator() {
        guard let btn = statusItem.button else { return }
        switch serviceStatusStore.status {
        case .degraded(let message), .error(let message):
            let warn = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                               accessibilityDescription: "Engram service problem")
            warn?.size = NSSize(width: 17, height: 15)
            btn.image = warn
            btn.toolTip = message
        default:
            if showMenuBarActivity, let usage = serviceStatusStore.usagePressureSummary {
                let symbolName = usage.severity == .critical ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent"
                let warn = NSImage(systemSymbolName: symbolName,
                                   accessibilityDescription: usage.message)
                    ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                               accessibilityDescription: usage.message)
                warn?.size = NSSize(width: 17, height: 15)
                btn.image = warn
                btn.toolTip = usage.message
                return
            }
            let img = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "brain.head.profile",
                           accessibilityDescription: "Engram")
            img?.size = NSSize(width: 19, height: 15)
            img?.isTemplate = true
            btn.image = img
            btn.toolTip = serviceStatusStore.displayString
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
        guard showMenuBarActivity else {
            statusItem.button?.title = ""
            return
        }
        let today = serviceStatusStore.todayParentSessions
        // Coalesce: if we scanned live sessions recently, just refresh the cheap
        // today-count label and skip the recursive FS scan. The badge timer
        // still forces a periodic scan once the interval elapses.
        guard Date().timeIntervalSince(lastBadgeScan) >= Self.badgeScanMinInterval else {
            refreshTodayBadge(today)
            return
        }
        lastBadgeScan = Date()
        Task {
            do {
                let response = try await serviceClient.liveSessions()
                let live = response.sessions.filter { $0.activityLevel == "active" }
                if live.isEmpty {
                    self.statusItem.button?.title = today > 0 ? " \(today)" : ""
                } else {
                    self.statusItem.button?.title = " \(today) \u{25CF} \(live.count)"
                }
            } catch {
                self.statusItem.button?.title = today > 0 ? " \(today)" : ""
            }
        }
    }

    /// WP19: fetch today's / month-to-date spend and let the notifier raise a
    /// day-keyed budget-breach notification (at most once per local day).
    ///
    /// Gate the poll: when no cost budget is configured or threshold notifying
    /// is off/monitoring disabled, skip the costs() round-trip entirely so the
    /// badge timer doesn't flood telemetry + the DB for nothing.
    private func checkCostBudget() async {
        let settings = UsagePressureNotificationSettings.current()
        guard settings.monitorEnabled,
              settings.notifyOnCostThreshold,
              settings.dailyCostBudget > 0 || settings.monthlyCostBudget > 0 else {
            return
        }
        guard let costs = try? await serviceClient.costs() else { return }
        usagePressureNotifier.observeCosts(
            todayUsd: costs.todayUsd,
            monthToDateUsd: costs.monthToDateUsd
        )
    }

    /// Refresh only the today-count portion of the badge without a live-session
    /// FS scan. Preserves an existing "● N" live suffix if one is shown.
    private func refreshTodayBadge(_ today: Int) {
        let current = statusItem.button?.title ?? ""
        if let liveRange = current.range(of: " \u{25CF} ") {
            let liveSuffix = current[liveRange.lowerBound...]
            statusItem.button?.title = today > 0 ? " \(today)\(liveSuffix)" : String(liveSuffix)
        } else {
            statusItem.button?.title = today > 0 ? " \(today)" : ""
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

    /// Re-apply the badge + status glyph when the menu-bar activity toggle flips.
    /// Guarded on the last-applied value so unrelated UserDefaults churn is a no-op.
    private func applyMenuBarActivityPreference() {
        let show = showMenuBarActivity
        guard show != lastShowMenuBarActivity else { return }
        lastShowMenuBarActivity = show
        updateStatusIndicator()
        updateBadge()
    }

    @objc private func navigateToScreenAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let screen = Screen(rawValue: rawValue) else { return }
        NotificationCenter.default.post(name: .navigateToScreen, object: screen.rawValue)
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

        // View menu (navigation shortcuts)
        let viewMenu = NSMenu(title: String(localized: "View"))
        let viewShortcuts: [(Screen, String)] = [
            (.home, "1"),
            (.sessions, "2"),
            (.search, "3"),
            (.timeline, "4"),
            (.activity, "5"),
        ]
        for (screen, key) in viewShortcuts {
            let item = NSMenuItem(title: screen.localizedTitle, action: #selector(navigateToScreenAction(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = screen.rawValue
            viewMenu.addItem(item)
        }
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help menu (row 17) — after Window, before mainMenu assignment.
        let helpMenu = NSMenu(title: String(localized: "Help"))
        let reportItem = NSMenuItem(
            title: String(localized: "Report an Issue…"),
            action: #selector(reportAnIssue),
            keyEquivalent: ""
        )
        reportItem.target = self
        helpMenu.addItem(reportItem)
        let onboardItem = NSMenuItem(
            title: String(localized: "Show Onboarding"),
            action: #selector(showOnboardingFromMenu),
            keyEquivalent: ""
        )
        onboardItem.target = self
        helpMenu.addItem(onboardItem)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}
