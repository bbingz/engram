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

// MARK: - Shared Utilities

/// ISO-8601 parser (thread-safe, reused).
private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Local-time display formatter (HH:mm:ss).
private let localTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.timeZone = .current
    return f
}()

/// Local-time display formatter for hour buckets (MMM d, HH:00).
private let localHourFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d, HH:00"
    f.timeZone = .current
    return f
}()

/// Parse an ISO-8601 UTC timestamp and format as local HH:mm:ss.
/// Used across Observability views (LogStream, ErrorDashboard, TraceExplorer).
func formatTimestamp(_ ts: String) -> String {
    if let date = iso8601Formatter.date(from: ts) {
        return localTimeFormatter.string(from: date)
    }
    // Fallback: try without fractional seconds
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: ts) {
        return localTimeFormatter.string(from: date)
    }
    // Last resort: extract raw time substring (already UTC, but better than nothing)
    if let tIndex = ts.firstIndex(of: "T") {
        let time = ts[ts.index(after: tIndex)...]
        return String(time.prefix(8))
    }
    return String(ts.suffix(8))
}

/// Parse a UTC hour-bucket string (e.g. "2026-03-23T05") and format as local time.
func formatHourBucket(_ hour: String) -> String {
    // Hour bucket format: "2026-03-23T05" — append ":00:00Z" to make valid ISO-8601
    let isoString = hour + ":00:00Z"
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: isoString) {
        return localHourFormatter.string(from: date)
    }
    return hour
}

// MARK: - NSAppearance helper

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
