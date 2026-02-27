// macos/CodingMemory/MenuBarController.swift
import AppKit
import SwiftUI

@MainActor
class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(db: DatabaseManager, indexer: IndexerProcess) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover    = NSPopover()
        popover.contentSize = NSSize(width: 500, height: 600)
        popover.behavior    = .transient

        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(db)
                .environmentObject(indexer)
        )

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "brain.head.profile",
                                accessibilityDescription: "CodingMemory")
            btn.action = #selector(toggle)
            btn.target = self
        }

        // Update badge with session count
        Task { @MainActor in
            for await total in indexer.$totalSessions.values {
                self.statusItem.button?.title = total > 0 ? " \(total)" : ""
            }
        }
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let btn = statusItem.button {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
