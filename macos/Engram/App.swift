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
    let db           = DatabaseManager()
    let indexer      = IndexerProcess()
    let daemonClient = DaemonClient()
    private var menuBarController: MenuBarController?
    private var mcpServer: MCPServer?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time: migrate plaintext API keys from settings.json to Keychain
        migrateKeysToKeychainIfNeeded()

        // Hide from Dock — menu bar only
        NSApp.setActivationPolicy(.accessory)

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

        if !scriptPath.isEmpty {
            indexer.start(nodePath: resolvedNodePath, scriptPath: scriptPath)
        } else {
            print("Warning: daemon.js not bundled — indexer disabled (normal during development)")
        }

        // Setup menu bar
        menuBarController = MenuBarController(db: db, indexer: indexer, daemonClient: daemonClient)

        // First-run onboarding
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
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
