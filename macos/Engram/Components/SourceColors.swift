// macos/Engram/Components/SourceColors.swift
import SwiftUI

/// Single source of truth for source → color mapping.
/// Used by Popover (SourceBadge, SourceDisplay) and Main Window (SourcePill, charts).
enum SourceColors {
    static func color(for source: String) -> Color {
        switch source {
        case "claude-code":   return Color(hex: 0x4A8FE7)  // Blue
        case "cursor":        return Color(hex: 0xA855F7)  // Purple
        case "codex":         return Color(hex: 0x30D158)  // Green
        case "gemini-cli":    return Color(hex: 0xFF9F0A)  // Orange
        case "windsurf":      return Color(hex: 0xFF453A)  // Red
        case "cline":         return Color(hex: 0x30B0C7)  // Teal
        case "vscode":        return Color(hex: 0x00A1F1)  // Cyan
        case "antigravity":   return Color(hex: 0xFF9F0A)  // Orange (same as gemini)
        case "copilot":       return Color(hex: 0x8E8E93)  // Gray
        case "opencode":      return Color(hex: 0x5856D6)  // Indigo
        case "iflow":         return Color(hex: 0xA855F7)  // Purple
        case "qwen":          return Color(hex: 0x30B0C7)  // Teal
        case "kimi":          return Color(hex: 0xFF6482)  // Pink
        case "minimax":       return Color(hex: 0xFF453A)  // Red
        case "lobsterai":     return Color(hex: 0xFFCC00)  // Yellow
        default:              return Color(hex: 0x8E8E93)  // Gray
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
