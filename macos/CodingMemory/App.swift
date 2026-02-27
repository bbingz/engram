// macos/CodingMemory/App.swift
import SwiftUI

@main
struct CodingMemoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.indexer)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let db      = DatabaseManager()
    let indexer = IndexerProcess()
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
        let nodePath   = "/usr/local/bin/node"
        let scriptPath = Bundle.main.path(forResource: "daemon", ofType: "js", inDirectory: "node") ?? ""

        if !scriptPath.isEmpty {
            indexer.start(nodePath: nodePath, scriptPath: scriptPath)
        } else {
            print("Warning: daemon.js not bundled — indexer disabled (normal during development)")
        }

        // Setup menu bar
        menuBarController = MenuBarController(db: db, indexer: indexer)
    }

    func applicationWillTerminate(_ notification: Notification) {
        indexer.stop()
        mcpServer?.stop()
    }
}
