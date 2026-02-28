// macos/CodingMemory/Views/SettingsView.swift
import SwiftUI

struct DataSourceDef {
    let name: String
    let key: String
    let defaultPath: String
}

private let dataSources: [DataSourceDef] = [
    .init(name: "Claude Code",  key: "path.claude-code",  defaultPath: "~/.claude/projects"),
    .init(name: "Codex",        key: "path.codex",        defaultPath: "~/.codex/sessions"),
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

struct SettingsView: View {
    @AppStorage("httpPort")   var httpPort:   Int    = 3456
    @AppStorage("nodejsPath") var nodejsPath: String = "/usr/local/bin/node"
    @EnvironmentObject var indexer: IndexerProcess

    var body: some View {
        Form {
            Section("MCP Server") {
                HStack {
                    Text("HTTP Port")
                    Spacer()
                    TextField("3456", value: $httpPort, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Node.js Indexer") {
                HStack {
                    Text("Node.js Path")
                    Spacer()
                    TextField("/usr/local/bin/node", text: $nodejsPath)
                        .frame(width: 260)
                }
                HStack {
                    Text("Status")
                    Spacer()
                    Text(indexer.status.displayString)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data Sources") {
                ForEach(dataSources, id: \.key) { ds in
                    DataSourceRow(def: ds)
                }
            }

            Section("Database") {
                DatabaseInfoView()
            }

            Section("Launch") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { LaunchAgent.isEnabled },
                        set: { LaunchAgent.setEnabled($0) }
                    ))
                } else {
                    Text("Login item requires macOS 13+")
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                HStack {
                    Text("MCP HTTP endpoint")
                    Spacer()
                    Text("http://localhost:\(httpPort)/mcp")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section("MCP Client Setup") {
                MCPSetupGuideView(nodejsPath: nodejsPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}

// MARK: - MCP Setup Guide

struct MCPClientDef {
    let name: String
    let configPath: String
    let snippet: (String, String) -> String  // (nodePath, scriptPath) -> config
}

struct MCPSetupGuideView: View {
    let nodejsPath: String
    @AppStorage("mcpScriptPath") var scriptPath: String = "~/.coding-memory/dist/index.js"

    private var resolvedScript: String {
        (scriptPath as NSString).expandingTildeInPath
    }

    private var clients: [MCPClientDef] {[
        MCPClientDef(
            name: "Claude Code",
            configPath: "~/.claude.json or: claude mcp add",
            snippet: { node, script in
                "claude mcp add coding-memory \(node) \(script)"
            }
        ),
        MCPClientDef(
            name: "Gemini CLI",
            configPath: "~/.gemini/settings.json",
            snippet: { node, script in
                """
                "coding-memory": {
                  "command": "\(node)",
                  "args": ["\(script)"],
                  "trust": true
                }
                """
            }
        ),
        MCPClientDef(
            name: "Codex CLI",
            configPath: "~/.codex/config.yaml or: codex --mcp",
            snippet: { node, script in
                "codex --mcp-server \(node) \(script)"
            }
        ),
        MCPClientDef(
            name: "Cursor / VS Code",
            configPath: ".cursor/mcp.json or .vscode/mcp.json",
            snippet: { node, script in
                """
                "coding-memory": {
                  "command": "\(node)",
                  "args": ["\(script)"]
                }
                """
            }
        ),
    ]}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MCP Script")
                    .frame(width: 90, alignment: .leading)
                TextField("~/.coding-memory/dist/index.js", text: $scriptPath)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                scriptExistsIndicator
            }
            Text("Add coding-memory to your MCP clients using the configurations below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(clients, id: \.name) { client in
                MCPClientRow(client: client, nodePath: nodejsPath, scriptPath: resolvedScript)
            }
        }
    }

    @ViewBuilder
    private var scriptExistsIndicator: some View {
        let exists = FileManager.default.fileExists(atPath: resolvedScript)
        Circle()
            .fill(exists ? Color.green : Color.red)
            .frame(width: 8, height: 8)
            .help(exists ? "Script exists" : "Script not found")
    }
}

struct MCPClientRow: View {
    let client: MCPClientDef
    let nodePath: String
    let scriptPath: String
    @State private var copied = false

    private var snippet: String {
        client.snippet(nodePath, scriptPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(client.name)
                    .font(.caption.bold())
                Text(client.configPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Text(copied ? "Copied!" : "Copy")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(copied ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                        .foregroundStyle(copied ? .green : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Text(snippet)
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

// MARK: - Data Source Row

struct DataSourceRow: View {
    let def: DataSourceDef
    @State private var path: String = ""
    @State private var exists: Bool? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(def.name)
                .frame(width: 90, alignment: .leading)
            TextField(def.defaultPath, text: $path)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .onChange(of: path) { _, newValue in
                    savePath(newValue)
                    checkExists(newValue)
                }
            if let exists {
                Circle()
                    .fill(exists ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .help(exists ? "Path exists" : "Path not found")
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

// MARK: - Database Info

struct DatabaseInfoView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var dbSize: String = "..."
    @State private var sessionCount: String = "..."
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coding-memory/index.sqlite").path

    var body: some View {
        HStack {
            Text("Path")
            Spacer()
            Text(dbPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        HStack {
            Text("Size")
            Spacer()
            Text(dbSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Sessions")
            Spacer()
            Text(sessionCount)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { loadInfo() }
    }

    private func loadInfo() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let size = attrs[.size] as? Int {
            let mb = Double(size) / 1024 / 1024
            dbSize = String(format: "%.1f MB", mb)
        } else {
            dbSize = "N/A"
        }
        sessionCount = "\((try? db.countSessions()) ?? 0)"
    }
}
