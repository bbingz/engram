// macos/CodingMemory/MenuBarController.swift
import AppKit
import SwiftUI

@MainActor
class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var window: NSWindow?

    // Stored so openWindow() can inject them into the standalone window
    private let db: DatabaseManager
    private let indexer: IndexerProcess

    init(db: DatabaseManager, indexer: IndexerProcess) {
        self.db = db
        self.indexer = indexer

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover    = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 600)
        popover.behavior    = .transient

        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(db)
                .environmentObject(indexer)
        )

        super.init()

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "brain.head.profile",
                                accessibilityDescription: "CodingMemory")
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

        let openItem = NSMenuItem(title: "Open Window", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit CodingMemory",
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
        win.title = "CodingMemory"
        win.setContentSize(NSSize(width: 900, height: 640))
        win.minSize = NSSize(width: 600, height: 400)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false   // keep object alive so we can reopen
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
