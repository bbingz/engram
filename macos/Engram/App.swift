// macos/Engram/App.swift
import SwiftUI

@main
struct EngramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.db)
                .environmentObject(appDelegate.indexer)
                .environmentObject(appDelegate.daemonClient)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let environment: AppEnvironment
    let db: DatabaseManager
    let indexer: IndexerProcess
    let daemonClient: DaemonClient
    private var menuBarController: MenuBarController?
    private var mcpServer: MCPServer?
    private var onboardingWindow: NSWindow?
    private var popoverWindow: NSWindow?

    override init() {
        self.environment = AppEnvironment.fromCommandLine()
        self.db = DatabaseManager(path: environment.dbPath)
        self.indexer = IndexerProcess()
        #if DEBUG
        if environment.mockDaemon {
            MockURLProtocol.requestHandler = { request in
                MockDaemonFixtures.response(for: request.url!.path)
            }
            let mockSession = createMockSession()
            self.daemonClient = DaemonClient(port: 9999, session: mockSession)
        } else {
            self.daemonClient = DaemonClient(port: environment.daemonPort)
        }
        #else
        self.daemonClient = DaemonClient(port: environment.daemonPort)
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time: migrate plaintext API keys from settings.json to Keychain
        migrateKeysToKeychainIfNeeded()

        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Appearance override for screenshot tests
        if let idx = CommandLine.arguments.firstIndex(of: "--appearance"),
           CommandLine.arguments.indices.contains(idx + 1) {
            let name: NSAppearance.Name = CommandLine.arguments[idx + 1] == "dark"
                ? .darkAqua : .aqua
            NSApp.appearance = NSAppearance(named: name)
        }

        // Open SQLite
        do { try db.open() } catch { print("DB error:", error) }

        // Start MCP server
        let tools = MCPTools(db: db)
        mcpServer = MCPServer(tools: tools)
        mcpServer?.start()

        // Start Node.js indexer
        // Look for daemon.js in the bundle Resources/node/ directory
        let nodePath = UserDefaults.standard.string(forKey: "nodejsPath") ?? "/usr/local/bin/node"
        let resolvedNodePath: String
        if FileManager.default.fileExists(atPath: nodePath) {
            resolvedNodePath = nodePath
        } else if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/node") {
            resolvedNodePath = "/opt/homebrew/bin/node"
        } else {
            resolvedNodePath = nodePath  // fall back, will fail with a clear error
        }
        let portPref = UserDefaults.standard.integer(forKey: "httpPort")
        let _ = portPref > 0 ? portPref : 3456  // reserved for future MCPServer port wiring
        let scriptPath = Bundle.main.path(forResource: "daemon", ofType: "js", inDirectory: "node") ?? ""

        if environment.autoStartDaemon && !scriptPath.isEmpty {
            indexer.start(nodePath: resolvedNodePath, scriptPath: scriptPath)
        } else if scriptPath.isEmpty {
            print("Warning: daemon.js not bundled — indexer disabled (normal during development)")
        }

        // Setup menu bar (or standalone popover window in test mode)
        if environment.popoverStandalone {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: PopoverView()
                .environmentObject(db)
                .environmentObject(indexer)
                .environmentObject(daemonClient))
            window.title = "Popover Preview"
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.setContentSize(NSSize(width: 400, height: 600))
            window.styleMask.remove(.resizable)
            self.popoverWindow = window
        } else {
            menuBarController = MenuBarController(db: db, indexer: indexer, daemonClient: daemonClient)
        }

        // First-run onboarding (skip in test mode)
        let isTestMode = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || !environment.autoStartDaemon
        if !isTestMode {
            if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                showOnboarding()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            menuBarController?.openWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        indexer.stop()
        mcpServer?.stop()
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            self.completeOnboarding()
        }
        let hostingController = NSHostingController(rootView: onboardingView)

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Welcome to Engram"
        win.setContentSize(NSSize(width: 460, height: 380))
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.center()

        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = win
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onboardingWindow?.close()
        onboardingWindow = nil

        // Revert to accessory mode, then open the main window
        NSApp.setActivationPolicy(.accessory)
        menuBarController?.openWindow()
    }
}
