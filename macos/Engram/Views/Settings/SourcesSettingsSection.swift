// macos/Engram/Views/Settings/SourcesSettingsSection.swift
import SwiftUI

struct DataSourceDef {
    let name: String
    let defaultPath: String
    /// True for cache-only sources (Windsurf/Antigravity) whose adapters run
    /// with live gRPC sync disabled.
    var cacheOnly: Bool = false

    /// Display name comes from `SourceColors.longLabel` so the Settings catalog
    /// stays in sync with the rest of the app's source naming.
    init(source: String, defaultPath: String, cacheOnly: Bool = false) {
        self.name = SourceColors.longLabel(for: source)
        self.defaultPath = defaultPath
        self.cacheOnly = cacheOnly
    }
}

// Mirrors SessionAdapterFactory.defaultAdapters() (17 registered adapters).
private let dataSources: [DataSourceDef] = [
    .init(source: "claude-code", defaultPath: "~/.claude/projects"),
    .init(source: "codex",       defaultPath: "~/.codex/sessions"),
    .init(source: "minimax",     defaultPath: "~/.claude/projects"),
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
    .init(source: "windsurf",    defaultPath: "~/.codeium/windsurf/daemon", cacheOnly: true),
    .init(source: "antigravity", defaultPath: "~/.gemini/antigravity-cli/brain", cacheOnly: true),
    .init(source: "copilot",     defaultPath: "~/.copilot/session-state"),
]

struct SourcesSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "folder", title: "Data Sources")

            GroupBox("Detected source paths (read-only)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources are auto-detected and indexed automatically. There is no per-source on/off yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(dataSources, id: \.name) { ds in
                        DataSourceRow(def: ds)
                    }
                    Text("For live health, search and token coverage, see Workspace > Sources.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            GroupBox("MCP Client Setup") {
                MCPSetupGuideView()
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Path Exists Indicator

struct PathExistsIndicator: View {
    let exists: Bool

    init(exists: Bool) {
        self.exists = exists
    }

    init(path: String) {
        self.exists = FileManager.default.fileExists(
            atPath: (path as NSString).expandingTildeInPath
        )
    }

    var body: some View {
        Circle()
            .fill(exists ? Color.green : Color.red)
            .frame(width: 8, height: 8)
            .help(exists ? LocalizedStringKey("Path exists") : LocalizedStringKey("Path not found"))
    }
}

// MARK: - Data Source Row

struct DataSourceRow: View {
    let def: DataSourceDef

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: def.name)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: def.defaultPath)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if def.cacheOnly {
                Text("Cache only")
                    .font(.caption2)
                    .foregroundStyle(Theme.gray)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.gray.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help("Live capture is off for this source; only cached/transcript data is indexed.")
            }
            PathExistsIndicator(path: def.defaultPath)
        }
    }
}

// MARK: - MCP Setup Guide

struct MCPClientDef {
    let name: String
    let configPath: String
    let snippet: (String) -> String
}

struct MCPSetupGuideView: View {
    @AppStorage("mcpHelperPath") var helperPath: String = "/Applications/Engram.app/Contents/Helpers/EngramMCP"

    private var resolvedHelperPath: String {
        (helperPath as NSString).expandingTildeInPath
    }

    private static let clients: [MCPClientDef] = [
        MCPClientDef(
            name: "Claude Code",
            configPath: "~/.claude.json or: claude mcp add",
            snippet: { helper in
                "claude mcp add engram \(helper)"
            }
        ),
        MCPClientDef(
            name: "Gemini CLI",
            configPath: "~/.gemini/settings.json",
            snippet: { helper in
                """
                "engram": {
                  "command": "\(helper)",
                  "args": [],
                  "trust": true
                }
                """
            }
        ),
        MCPClientDef(
            name: "Codex CLI",
            configPath: "~/.codex/config.yaml or: codex --mcp",
            snippet: { helper in
                "codex --mcp-server \(helper)"
            }
        ),
        MCPClientDef(
            name: "Cursor / VS Code",
            configPath: ".cursor/mcp.json or .vscode/mcp.json",
            snippet: { helper in
                """
                "engram": {
                  "command": "\(helper)",
                  "args": []
                }
                """
            }
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Swift MCP Helper")
                    .frame(width: 90, alignment: .leading)
                TextField("/Applications/Engram.app/Contents/Helpers/EngramMCP", text: $helperPath)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                PathExistsIndicator(path: resolvedHelperPath)
            }
            Text("Primary setup: point MCP clients directly at the bundled Swift stdio helper. Mutating tools use Swift service IPC and fail closed when the service is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Node MCP and daemon HTTP settings are legacy rollback paths for Stage 3; keep them only for advanced compatibility.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.clients, id: \.name) { client in
                MCPClientRow(client: client, helperPath: resolvedHelperPath)
            }
        }
    }
}

struct MCPClientRow: View {
    let client: MCPClientDef
    let helperPath: String
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>? = nil

    private var snippet: String {
        client.snippet(helperPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: client.name)
                    .font(.caption.bold())
                Text(verbatim: client.configPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { copied = false }
                    }
                } label: {
                    Text(copied ? LocalizedStringKey("Copied!") : LocalizedStringKey("Copy"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(copied ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                        .foregroundStyle(copied ? .green : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Text(verbatim: snippet)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onDisappear { copyResetTask?.cancel(); copyResetTask = nil }
    }
}
