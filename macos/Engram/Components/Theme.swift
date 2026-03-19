// macos/Engram/Components/Theme.swift
import SwiftUI
import AppKit

/// Adaptive color tokens — automatically switch between dark and light appearance.
enum Theme {
    // MARK: - Backgrounds

    /// Main content area background
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x1A/255, green: 0x1D/255, blue: 0x24/255, alpha: 1)
            : NSColor.windowBackgroundColor
    })

    /// Card / section surface
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.02)
            : NSColor.black.withAlphaComponent(0.03)
    })

    /// Card border
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.04)
            : NSColor.black.withAlphaComponent(0.06)
    })

    /// Slightly brighter surface for badges, pills
    static let surfaceHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.05)
    })

    /// Search bar / input field background
    static let inputBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.04)
            : NSColor.black.withAlphaComponent(0.04)
    })

    // MARK: - Text

    /// Primary text (titles, KPI numbers)
    static let primaryText = Color.primary

    /// Secondary text (labels, descriptions)
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0xA0/255, green: 0xA1/255, blue: 0xA8/255, alpha: 1)
            : NSColor.secondaryLabelColor
    })

    /// Tertiary text (timestamps, section labels)
    static let tertiaryText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x6E/255, green: 0x70/255, blue: 0x78/255, alpha: 1)
            : NSColor.tertiaryLabelColor
    })

    // MARK: - Sidebar

    /// Selected sidebar item background
    static let sidebarSelection = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x4A/255, green: 0x8F/255, blue: 0xE7/255, alpha: 0.25)
            : NSColor(srgbRed: 0x4A/255, green: 0x8F/255, blue: 0xE7/255, alpha: 0.12)
    })

    /// Selected sidebar item text
    static let sidebarSelectedText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0x6C/255, green: 0xB4/255, blue: 0xFF/255, alpha: 1)
            : NSColor(srgbRed: 0x4A/255, green: 0x8F/255, blue: 0xE7/255, alpha: 1)
    })

    // MARK: - Accent (same in both modes)

    static let accent = Color(hex: 0x4A8FE7)
    static let green = Color(hex: 0x30D158)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)
    static let gray = Color(hex: 0x636366)
}

// MARK: - NSAppearance helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
