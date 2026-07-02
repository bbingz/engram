// macos/Engram/Components/SourceColors.swift
import SwiftUI

/// Single source of truth for source → color mapping.
/// Used by Popover (SourceBadge, SourceDisplay) and Main Window (SourcePill, charts).
enum SourceColors {
    static func color(for source: String) -> Color {
        switch source {
        case "claude-code":   return Color(hex: 0xD97757)
        // Grok/xAI is a monochrome brand; a fixed near-black (0x111827) is
        // invisible on a dark background. Color.primary adapts (black in light,
        // white in dark) and stays legible in both, matching Cursor/OpenCode.
        case "grok":          return Color.primary
        case "cursor":        return Color.primary
        case "codex":         return Color(hex: 0x3941FF)
        case "pi":            return Color(hex: 0xF59E0B)
        case "gemini-cli":    return Color(hex: 0x4285F4)
        case "windsurf":      return Color(hex: 0x00C4B3)
        case "cline":         return Color(hex: 0x6C47FF)
        case "vscode":        return Color(hex: 0x007ACC)
        case "antigravity", "antigravity-legacy":
                              return Color(hex: 0x4285F4)
        case "copilot":       return Color(hex: 0x1F6FEB)
        case "opencode":      return Color.primary
        case "iflow":         return Color(hex: 0x615CED)
        case "qwen":          return Color(hex: 0x615CED)
        case "qoder":         return Color(hex: 0x2563EB)
        case "kimi":          return Color(hex: 0x1080F8)
        case "minimax":       return Color(hex: 0xFF6A00)
        case "mimo":          return Color(hex: 0x0EA5E9)
        case "doubao":        return Color(hex: 0x16A34A)
        case "glm":           return Color(hex: 0x7C3AED)
        case "deepseek":      return Color(hex: 0x0F766E)
        case "lobsterai":     return Color(hex: 0xE11D48)
        case "commandcode":   return Color(hex: 0x22C55E)
        default:              return Color(hex: 0x8E8E93)
        }
    }

    static func label(for source: String) -> String {
        switch source {
        case "claude-code":   return "Claude"
        case "grok":          return "Grok"
        case "codex":         return "Codex"
        case "pi":            return "Pi"
        case "copilot":       return "Copilot"
        case "gemini-cli":    return "Gemini"
        case "kimi":          return "Kimi"
        case "qwen":          return "Qwen"
        case "qoder":         return "Qoder"
        case "minimax":       return "MiniMax"
        case "mimo":          return "Mimo"
        case "doubao":        return "Doubao"
        case "glm":           return "GLM"
        case "deepseek":      return "DeepSeek"
        case "lobsterai":     return "Lobster AI"
        case "commandcode":   return "Command Code"
        case "cline":         return "Cline"
        case "cursor":        return "Cursor"
        case "windsurf":      return "Windsurf"
        case "antigravity":   return "Antigravity"
        case "antigravity-legacy":
                              return "Antigravity Legacy"
        case "opencode":      return "OpenCode"
        case "iflow":         return "iFlow"
        case "vscode":        return "VS Code"
        default:              return source
        }
    }

    /// Disambiguated, longer display names for surfaces that need to tell
    /// similar sources apart (e.g. the Settings source-name table). Falls back
    /// to `label(for:)` for any source not explicitly disambiguated here.
    static func longLabel(for source: String) -> String {
        switch source {
        case "claude-code":   return "Claude Code"
        case "grok":          return "Grok Build"
        case "codex":         return "Codex"
        case "pi":            return "Pi"
        case "opencode":      return "OpenCode"
        case "copilot":       return "Copilot"
        case "gemini-cli":    return "Gemini CLI"
        case "iflow":         return "iFlow"
        case "qwen":          return "Qwen"
        case "qoder":         return "Qoder"
        case "kimi":          return "Kimi"
        case "mimo":          return "Mimo"
        case "doubao":        return "Doubao"
        case "glm":           return "GLM"
        case "deepseek":      return "DeepSeek"
        case "cline":         return "Cline"
        default:              return label(for: source)
        }
    }
}

// MARK: - Shared source display info

enum SourceDisplay {
    static func label(for source: String) -> String {
        SourceColors.label(for: source)
    }

    static func color(for source: String) -> Color {
        SourceColors.color(for: source)
    }

    /// Sources whose sessions genuinely run *inside* the real Claude Code app
    /// (a non-Claude model detected by model name within `~/.claude/projects`),
    /// where a "via Claude Code" cue is accurate. Provider-clone roots
    /// (kimi/qwen/glm/deepseek/mimo/doubao and the minimax/codex clones under
    /// `~/.claude-<name>/`) also carry originator="Claude Code" structurally, but
    /// they are separate forked provider CLIs — badging them all would be
    /// misleading, so they are intentionally excluded.
    private static let claudeCodeNativeDerivedSources: Set<String> = ["minimax", "lobsterai"]

    /// Whether a session warrants a "via Claude Code" originator badge. True only
    /// for native-derived sources whose originator classifies as Claude Code, so
    /// the badge never fires on every provider-clone-root session.
    static func showsViaClaudeCodeBadge(source: String, originator: String?) -> Bool {
        claudeCodeNativeDerivedSources.contains(source)
            && OriginatorClassifier.isClaudeCode(originator)
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
