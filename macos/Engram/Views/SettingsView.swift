// macos/Engram/Views/SettingsView.swift
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

    // AI Summary settings (stored in Node.js config file)
    @State private var aiProvider: String = "openai"
    @State private var openaiApiKey: String = ""
    @State private var openaiModel: String = "gpt-4o-mini"
    @State private var anthropicApiKey: String = ""
    @State private var anthropicModel: String = "claude-3-haiku-20240307"

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
                    Text(verbatim: indexer.status.displayString)
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
                    Text(verbatim: "http://localhost:\(httpPort)/mcp")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section("MCP Client Setup") {
                MCPSetupGuideView(nodejsPath: nodejsPath)
            }

            Section("AI Summary") {
                Picker("Provider", selection: $aiProvider) {
                    Text("OpenAI").tag("openai")
                    Text("Anthropic").tag("anthropic")
                }
                .pickerStyle(.segmented)
                .onChange(of: aiProvider) { saveAISettings() }

                if aiProvider == "openai" {
                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("sk-...", text: $openaiApiKey)
                            .frame(width: 300)
                            .onChange(of: openaiApiKey) { saveAISettings() }
                    }
                    Picker("Model", selection: $openaiModel) {
                        Text("GPT-4o Mini").tag("gpt-4o-mini")
                        Text("GPT-4o").tag("gpt-4o")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: openaiModel) { saveAISettings() }
                } else {
                    HStack {
                        Text("API Key")
                        Spacer()
                        SecureField("sk-ant-...", text: $anthropicApiKey)
                            .frame(width: 300)
                            .onChange(of: anthropicApiKey) { saveAISettings() }
                    }
                    Picker("Model", selection: $anthropicModel) {
                        Text("Claude 3 Haiku").tag("claude-3-haiku-20240307")
                        Text("Claude 3.5 Sonnet").tag("claude-3-5-sonnet-20241022")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: anthropicModel) { saveAISettings() }
                }

                Text("API keys are stored locally in ~/.engram/settings.json")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear { loadAISettings() }
    }

    private func saveAISettings() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/settings.json")
        var settings: [String: Any] = [:]

        // Read existing settings
        if let data = try? Data(contentsOf: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        // Update AI settings
        settings["aiProvider"] = aiProvider
        settings["openaiApiKey"] = openaiApiKey
        settings["openaiModel"] = openaiModel
        settings["anthropicApiKey"] = anthropicApiKey
        settings["anthropicModel"] = anthropicModel

        // Save
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
            try? data.write(to: configPath)
        }
    }

    private func loadAISettings() {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram/settings.json")

        guard let data = try? Data(contentsOf: configPath),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let provider = settings["aiProvider"] as? String {
            aiProvider = provider
        }
        if let key = settings["openaiApiKey"] as? String {
            openaiApiKey = key
        }
        if let model = settings["openaiModel"] as? String {
            openaiModel = model
        }
        if let key = settings["anthropicApiKey"] as? String {
            anthropicApiKey = key
        }
        if let model = settings["anthropicModel"] as? String {
            anthropicModel = model
        }
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
    @AppStorage("mcpScriptPath") var scriptPath: String = "~/.engram/dist/index.js"

    private var resolvedScript: String {
        (scriptPath as NSString).expandingTildeInPath
    }

    private static let clients: [MCPClientDef] = [
        MCPClientDef(
            name: "Claude Code",
            configPath: "~/.claude.json or: claude mcp add",
            snippet: { node, script in
                "claude mcp add engram \(node) \(script)"
            }
        ),
        MCPClientDef(
            name: "Gemini CLI",
            configPath: "~/.gemini/settings.json",
            snippet: { node, script in
                """
                "engram": {
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
                "engram": {
                  "command": "\(node)",
                  "args": ["\(script)"]
                }
                """
            }
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("MCP Script")
                    .frame(width: 90, alignment: .leading)
                TextField("~/.engram/dist/index.js", text: $scriptPath)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                PathExistsIndicator(path: resolvedScript)
            }
            Text("Add engram to your MCP clients using the configurations below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Self.clients, id: \.name) { client in
                MCPClientRow(client: client, nodePath: nodejsPath, scriptPath: resolvedScript)
            }
        }
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

// MARK: - Shared Components

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

// MARK: - Database Info

struct DatabaseInfoView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var dbSize: String = "..."
    @State private var sessionCount: String = "..."
    private let dbPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".engram/index.sqlite").path

    var body: some View {
        HStack {
            Text("Path")
            Spacer()
            Text(verbatim: dbPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        HStack {
            Text("Size")
            Spacer()
            Text(verbatim: dbSize)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Sessions")
            Spacer()
            Text(verbatim: sessionCount)
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
