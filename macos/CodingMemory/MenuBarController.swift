// macos/CodingMemory/MenuBarController.swift
import AppKit

class MenuBarController {
    private var statusItem: NSStatusItem?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "brain.head.profile",
                                            accessibilityDescription: "CodingMemory")
    }
}
