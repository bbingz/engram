// macos/Engram/Views/Settings/SourcesSettingsSection.swift
import SwiftUI

struct SourcesSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "folder", title: "Data Sources")

            GroupBox("Data sources (read-only)") {
                Text("Sources are auto-detected and indexed automatically. The full source catalog — live health, search and token coverage, and undetected sources — lives in Workspace > Sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
