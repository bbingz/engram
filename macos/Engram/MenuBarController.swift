// macos/Engram/MenuBarController.swift
import AppKit
import SwiftUI

@MainActor
class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    // Stored so openWindow() can inject them into the standalone window
    private let db: DatabaseManager
    private let indexer: IndexerProcess

    init(db: DatabaseManager, indexer: IndexerProcess) {
        self.db = db
        self.indexer = indexer

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover    = NSPopover()
        popover.contentSize = NSSize(width: 760, height: 640)
        popover.behavior    = .transient

        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(db)
                .environmentObject(indexer)
        )

        super.init()

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "brain.head.profile",
                                accessibilityDescription: "Engram")
            // Receive both left and right mouse-up so we can distinguish them
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.action = #selector(handleClick)
            btn.target = self
        }

        // Update badge with session count
        Task { @MainActor in
            for await total in indexer.$totalSessions.values {
                self.statusItem.button?.title = total > 0 ? " \(total)" : ""
            }
        }

        // Listen for settings open requests from ContentView gear button
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettings, object: nil
        )
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
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
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(db)
                .environmentObject(indexer)
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = String(localized: "Settings")
        win.setContentSize(NSSize(width: 520, height: 500))
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = win
    }

    // MARK: - Standalone window

    @objc func openWindow() {
        // Close popover if open
        if popover.isShown { popover.performClose(nil) }

        // Reuse existing window if still alive
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: ContentView()
                .environmentObject(db)
                .environmentObject(indexer)
        )

        let win = NSWindow(contentViewController: hostingController)
        win.title = "Engram"
        win.setContentSize(NSSize(width: 900, height: 640))
        win.minSize = NSSize(width: 600, height: 400)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false   // keep object alive so we can reopen
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
