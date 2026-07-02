// macos/Engram/Models/SourceCatalog.swift
import Foundation

/// One configured-but-not-necessarily-detected source.
///
/// `id` is the canonical `sessions.source` value (e.g. `"claude-code"`); it
/// resolves to a display name through `SourceColors.longLabel`. `defaultPath`
/// is where the adapter looks for transcripts. `cacheOnly` is true only for
/// sources whose adapters run with live gRPC sync disabled.
struct SourceCatalogEntry {
    let id: String
    let defaultPath: String
    let cacheOnly: Bool
}

/// Single canonical catalog of the source adapters Engram ships with.
///
/// Mirrors the unique source ids registered by `SessionAdapterFactory.defaultAdapters()`.
/// Used by `SourcePulseView` to surface configured-but-empty/undetected
/// sources that the live service query (`GROUP BY source`) cannot return
/// because they have no indexed sessions yet.
enum SourceCatalog {
    static let all: [SourceCatalogEntry] = [
        .init(source: "claude-code", defaultPath: "~/.claude/projects"),
        .init(source: "codex",       defaultPath: "~/.codex/sessions"),
        .init(source: "grok",        defaultPath: "~/.grok/sessions"),
        .init(source: "pi",          defaultPath: "~/.pi/agent/sessions"),
        .init(source: "minimax",     defaultPath: "~/.claude/projects"),
        .init(source: "mimo",        defaultPath: "~/.claude-mimo/projects"),
        .init(source: "doubao",      defaultPath: "~/.claude-doubao/projects"),
        .init(source: "glm",         defaultPath: "~/.claude-glm/projects"),
        .init(source: "deepseek",    defaultPath: "~/.claude-ds/projects"),
        .init(source: "lobsterai",   defaultPath: "~/.claude/projects"),
        .init(source: "gemini-cli",  defaultPath: "~/.gemini/tmp"),
        .init(source: "opencode",    defaultPath: "~/.local/share/opencode/opencode.db"),
        .init(source: "iflow",       defaultPath: "~/.iflow/projects"),
        .init(source: "qwen",        defaultPath: "~/.qwen/projects"),
        .init(source: "qoder",       defaultPath: "~/.qoder/projects"),
        .init(source: "kimi",        defaultPath: "~/.kimi/sessions"),
        .init(source: "commandcode", defaultPath: "~/.commandcode/projects"),
        .init(source: "cline",       defaultPath: "~/.cline/data/tasks"),
        .init(source: "cursor",      defaultPath: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
        .init(source: "vscode",      defaultPath: "~/Library/Application Support/Code/User/workspaceStorage"),
        .init(source: "windsurf",    defaultPath: "~/.codeium/windsurf/daemon"),
        .init(source: "antigravity", defaultPath: "~/.gemini/antigravity-cli/brain"),
        .init(source: "copilot",     defaultPath: "~/.copilot/session-state"),
    ]
}

private extension SourceCatalogEntry {
    /// Cache-only state is derived from the canonical live-sync-disabled set so
    /// the catalog can never drift from the adapter factory's gRPC config.
    init(source: String, defaultPath: String) {
        self.id = source
        self.defaultPath = defaultPath
        self.cacheOnly = LiveSyncDisabledSources.isLiveSyncDisabled(source)
    }
}
