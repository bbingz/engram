// macos/Engram/Views/Settings/SourcesSettingsSection.swift
import SwiftUI

struct DataSourceDef {
    let name: String
    let key: String
    let defaultPath: String
}

private let dataSources: [DataSourceDef] = [
    .init(name: "Claude Code",  key: "path.claude-code",  defaultPath: "~/.claude/projects"),
    .init(name: "Codex",        key: "path.codex",        defaultPath: "~/.codex/sessions"),
    .init(name: "Copilot CLI",  key: "path.copilot",      defaultPath: "~/.copilot/session-state"),
    .init(name: "Gemini CLI",   key: "path.gemini-cli",   defaultPath: "~/.gemini/tmp"),
    .init(name: "OpenCode",     key: "path.opencode",     defaultPath: "~/.local/share/opencode/opencode.db"),
    .init(name: "iFlow",        key: "path.iflow",        defaultPath: "~/.iflow/projects"),
    .init(name: "Qwen",         key: "path.qwen",         defaultPath: "~/.qwen/projects"),
    .init(name: "Kimi",         key: "path.kimi",         defaultPath: "~/.kimi/sessions"),
    .init(name: "Cline",        key: "path.cline",        defaultPath: "~/.cline/data/tasks"),
    .init(name: "Cursor",       key: "path.cursor",       defaultPath: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
    .init(name: "VS Code",      key: "path.vscode",       defaultPath: "~/Library/Application Support/Code/User/workspaceStorage"),
    .init(name: "Antigravity",  key: "path.antigravity",  defaultPath: "~/.gemini/antigravity/daemon"),
    .init(name: "Windsurf",     key: "path.windsurf",     defaultPath: "~/.codeium/windsurf/daemon"),
]

struct SourcesSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "folder", title: "Data Sources")

            GroupBox("Adapter Paths") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dataSources, id: \.key) { ds in
                        DataSourceRow(def: ds)
                    }
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
        self.exists = FileManager.default.fileExists(atPath: path)
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
    @State private var path: String = ""
    @State private var exists: Bool? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: def.name)
                .frame(width: 90, alignment: .leading)
            TextField(def.defaultPath, text: $path)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .onChange(of: path) { _, newValue in
                    savePath(newValue)
                    checkExists(newValue)
                }
            if let exists {
                PathExistsIndicator(exists: exists)
            }
        }
        .onAppear {
            path = UserDefaults.standard.string(forKey: def.key) ?? def.defaultPath
            checkExists(path)
        }
    }

    private func savePath(_ value: String) {
        if value == def.defaultPath {
            UserDefaults.standard.removeObject(forKey: def.key)
        } else {
            UserDefaults.standard.set(value, forKey: def.key)
        }
    }

    private func checkExists(_ rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        exists = FileManager.default.fileExists(atPath: expanded)
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
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
    }
}
