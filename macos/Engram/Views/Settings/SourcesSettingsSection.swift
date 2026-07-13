// macos/Engram/Views/Settings/SourcesSettingsSection.swift
import AppKit
import SwiftUI

struct SourcesSettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(icon: "folder", title: "Data Sources")

            GroupBox("Data sources (read-only)") {
                Text("Default-on sources are auto-detected and indexed automatically. Archived sources stay off until enabled from Workspace > Sources > Archived; the full source catalog, live health, search and token coverage, and undetected sources live there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            ClaudeCodeProfilesSettingsCard()

            GroupBox("MCP Client Setup") {
                MCPSetupGuideView()
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Claude Code Profiles

struct ClaudeCodeProfilesSettingsCard: View {
    @Environment(EngramServiceClient.self) private var serviceClient

    @State private var status: EngramServiceClaudeCodeProfilesStatusResponse?
    @State private var autoDiscover = true
    @State private var customProjectsRoots: [String] = []
    @State private var loading = false
    @State private var saving = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var refreshGeneration = 0

    var body: some View {
        GroupBox("Claude Code Profiles") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Automatically discover ~/.claude-*/projects",
                    isOn: $autoDiscover
                )
                .disabled(loading || saving)
                .accessibilityIdentifier("claudeProfiles_autoDiscover")

                Text("Choose a Claude Code projects folder. Custom folders are indexed and archived, but their source files are protected from automatic local reclamation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                profileRows

                HStack(spacing: 8) {
                    Button("Add Projects Folder…") { addProjectsFolder() }
                        .disabled(loading || saving)
                        .accessibilityIdentifier("claudeProfiles_add")

                    Button("Save") { Task { await save() } }
                        .disabled(loading || saving)
                        .accessibilityIdentifier("claudeProfiles_save")

                    Button("Refresh") { Task { await loadStatus() } }
                        .disabled(loading || saving)
                        .accessibilityIdentifier("claudeProfiles_refresh")

                    if loading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading profiles…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if saving {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(messageIsError ? Color.red : Color.green)
                        .accessibilityIdentifier("claudeProfiles_message")
                }

                Text("Configuration changes never delete existing sessions or archives.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .task { await loadStatus() }
    }

    @ViewBuilder
    private var profileRows: some View {
        if let status {
            let automaticProfiles = status.profiles.filter { $0.origin != "custom" }
            let customProfilesByRoot = status.profiles
                .filter { $0.origin == "custom" }
                .reduce(into: [String: EngramServiceClaudeCodeProfileStatus]()) { result, profile in
                    if result[profile.projectsRoot] == nil {
                        result[profile.projectsRoot] = profile
                    }
                }

            ForEach(automaticProfiles, id: \.id) { profile in
                ClaudeCodeProfileStatusRow(profile: profile)
                    .accessibilityIdentifier("claudeProfiles_row_\(profile.id)")
            }

            ForEach(customProjectsRoots, id: \.self) { root in
                if let profile = customProfilesByRoot[root] {
                    ClaudeCodeProfileStatusRow(
                        profile: profile,
                        remove: { removeCustomRoot(root) }
                    )
                    .accessibilityIdentifier("claudeProfiles_row_\(profile.id)")
                } else {
                    ClaudeCodePendingProfileRow(projectsRoot: root) {
                        removeCustomRoot(root)
                    }
                }
            }

            if automaticProfiles.isEmpty, customProjectsRoots.isEmpty, !loading {
                Text("No Claude Code profiles found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if status.configurationError != nil {
                Label("Profile configuration is invalid.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @MainActor
    private func loadStatus() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        loading = true
        message = nil
        defer {
            if refreshGeneration == generation {
                loading = false
            }
        }
        do {
            let response = try await serviceClient.claudeCodeProfilesStatus()
            guard refreshGeneration == generation else { return }
            apply(response)
        } catch {
            guard refreshGeneration == generation else { return }
            message = String(localized: "Error: profile status is unavailable.")
            messageIsError = true
        }
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        message = nil
        defer { saving = false }
        do {
            let response = try await serviceClient.configureClaudeCodeProfiles(
                EngramServiceConfigureClaudeCodeProfilesRequest(
                    autoDiscover: autoDiscover,
                    customProjectsRoots: customProjectsRoots
                )
            )
            apply(response)
            message = String(localized: "Saved.")
            messageIsError = false
        } catch {
            message = String(localized: "Error: profile configuration could not be saved.")
            messageIsError = true
        }
    }

    @MainActor
    private func addProjectsFolder() {
        guard customProjectsRoots.count < 64 else {
            message = String(localized: "Error: no more than 64 custom projects folders can be added.")
            messageIsError = true
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Add Projects Folder")
        panel.message = String(localized: "Choose a Claude Code projects folder. Custom folders are indexed and archived, but their source files are protected from automatic local reclamation.")
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let canonicalURL = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard canonicalURL.lastPathComponent == "projects",
              FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: canonicalURL.path)
        else {
            message = String(localized: "Error: selected folder must be a Claude Code projects directory.")
            messageIsError = true
            return
        }
        guard !customProjectsRoots.contains(canonicalURL.path) else { return }

        customProjectsRoots.append(canonicalURL.path)
        customProjectsRoots.sort()
        message = nil
        messageIsError = false
    }

    private func removeCustomRoot(_ projectsRoot: String) {
        customProjectsRoots.removeAll { $0 == projectsRoot }
        message = nil
        messageIsError = false
    }

    private func apply(_ response: EngramServiceClaudeCodeProfilesStatusResponse) {
        status = response
        autoDiscover = response.autoDiscover
        customProjectsRoots = response.customProjectsRoots
    }
}

private struct ClaudeCodeProfileStatusRow: View {
    let profile: EngramServiceClaudeCodeProfileStatus
    let remove: (() -> Void)?

    init(profile: EngramServiceClaudeCodeProfileStatus, remove: (() -> Void)? = nil) {
        self.profile = profile
        self.remove = remove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(profile.available ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(verbatim: profile.displayName)
                    .font(.caption.bold())
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "Origin: %@"),
                        localizedOrigin
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                Text(
                    verbatim: profile.available
                        ? String(localized: "Available")
                        : String(localized: "Unavailable")
                )
                    .font(.caption2)
                    .foregroundStyle(profile.available ? .green : .orange)
                if let remove {
                    Button("Remove", action: remove)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("claudeProfiles_remove_\(profile.id)")
                }
            }

            Text(verbatim: profile.projectsRoot)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "%lld files · %@ · %lld indexed · %lld archived · %lld empty ignored"),
                    Int64(profile.discoveredFileCount),
                    ByteCountFormatter.string(
                        fromByteCount: profile.discoveredSourceBytes,
                        countStyle: .file
                    ),
                    Int64(profile.indexedLocatorCount),
                    Int64(profile.capturedCount),
                    Int64(profile.ignoredEmptyCaptureCount)
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "HQ %lld · M1 %lld"),
                        Int64(profile.hqVerifiedCount),
                        Int64(profile.m1VerifiedCount)
                    )
                )
                Text(
                    verbatim: profile.sourceReclamationAllowed
                        ? String(localized: "Local source reclamation allowed")
                        : String(localized: "Source files protected from local reclamation")
                )
                .foregroundStyle(
                    profile.sourceReclamationAllowed ? Color.secondary : Color.blue
                )
            }
            .font(.caption2)

            if profile.error != nil {
                Text("Profile status unavailable.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var localizedOrigin: String {
        switch profile.origin {
        case "default": String(localized: "Default")
        case "automatic": String(localized: "Automatic")
        default: String(localized: "Custom")
        }
    }
}

private struct ClaudeCodePendingProfileRow: View {
    let projectsRoot: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: projectsRoot)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Pending save")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Source files protected from local reclamation")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            Spacer()
            Button("Remove", action: remove)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("claudeProfiles_remove_pending")
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
