import Foundation

public enum SourceName: String, CaseIterable, Codable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case copilot
    case geminiCli = "gemini-cli"
    case opencode
    case iflow
    case qwen
    case qoder
    case kimi
    case minimax
    case lobsterai
    case commandcode
    case cline
    case cursor
    case vscode
    case antigravity
    case windsurf
}
