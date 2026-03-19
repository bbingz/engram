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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
