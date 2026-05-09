// macos/Engram/Components/SourceColors.swift
import SwiftUI

/// Single source of truth for source → color mapping.
/// Used by Popover (SourceBadge, SourceDisplay) and Main Window (SourcePill, charts).
enum SourceColors {
    static func color(for source: String) -> Color {
        switch source {
        case "claude-code":   return Color(hex: 0xD97757)
        case "cursor":        return Color.primary
        case "codex":         return Color(hex: 0x3941FF)
        case "gemini-cli":    return Color(hex: 0x4285F4)
        case "windsurf":      return Color(hex: 0x00C4B3)
        case "cline":         return Color(hex: 0x6C47FF)
        case "vscode":        return Color(hex: 0x007ACC)
        case "antigravity":   return Color(hex: 0x4285F4)
        case "copilot":       return Color(hex: 0x1F6FEB)
        case "opencode":      return Color.primary
        case "iflow":         return Color(hex: 0x615CED)
        case "qwen":          return Color(hex: 0x615CED)
        case "kimi":          return Color(hex: 0x1080F8)
        case "minimax":       return Color(hex: 0xFF6A00)
        case "lobsterai":     return Color(hex: 0xE11D48)
        default:              return Color(hex: 0x8E8E93)
        }
    }

    static func label(for source: String) -> String {
        switch source {
        case "claude-code":   return "Claude"
        case "codex":         return "Codex"
        case "copilot":       return "Copilot"
        case "gemini-cli":    return "Gemini"
        case "kimi":          return "Kimi"
        case "qwen":          return "Qwen"
        case "minimax":       return "MiniMax"
        case "lobsterai":     return "Lobster AI"
        case "cline":         return "Cline"
        case "cursor":        return "Cursor"
        case "windsurf":      return "Windsurf"
        case "antigravity":   return "Antigravity"
        case "opencode":      return "OpenCode"
        case "iflow":         return "iFlow"
        case "vscode":        return "VS Code"
        default:              return source
        }
    }
}

// MARK: - Shared source display info (used by SessionListView, PopoverView, TimelineView)

enum SourceDisplay {
    static func label(for source: String) -> String {
        SourceColors.label(for: source)
    }

    static func color(for source: String) -> Color {
        SourceColors.color(for: source)
    }
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
