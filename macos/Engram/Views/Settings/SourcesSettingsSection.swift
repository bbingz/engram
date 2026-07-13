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

struct ClaudeCodeProfilesSettingsRow: Equatable, Identifiable {
    enum DetailState: Equatable {
        case current
        case statusUnavailable
        case pendingSave
    }

    let projectsRoot: String
    let profile: EngramServiceClaudeCodeProfileStatus?
    let canRemoveCustomRegistration: Bool
    let detailState: DetailState

    var id: String { rowAccessibilityIdentifier }

    var displayName: String {
        guard let profile else {
            return URL(fileURLWithPath: projectsRoot)
                .deletingLastPathComponent()
                .lastPathComponent
        }
        return profile.origin == "default"
            ? String(localized: "Default")
            : profile.displayName
    }

    var rowAccessibilityIdentifier: String {
        if let profile {
            return "claudeProfiles_row_\(profile.id)"
        }
        return "claudeProfiles_row_pending_\(Self.rootIdentifier(projectsRoot))"
    }

    var removeAccessibilityIdentifier: String {
        if let profile {
            return "claudeProfiles_remove_\(profile.id)"
        }
        return "claudeProfiles_remove_pending_\(Self.rootIdentifier(projectsRoot))"
    }

    var placeholderStatusText: String? {
        switch detailState {
        case .current:
            nil
        case .statusUnavailable:
            String(localized: "Profile status unavailable.")
        case .pendingSave:
            String(localized: "Pending save")
        }
    }

    private static func rootIdentifier(_ root: String) -> String {
        Data(root.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ClaudeCodeProfilesSettingsState: Equatable {
    enum AddResult: Equatable {
        case added
        case duplicate
        case limitReached
        case notReady
    }

    private(set) var status: EngramServiceClaudeCodeProfilesStatusResponse?
    private(set) var customProjectsRoots: [String] = []
    private var persistedCustomProjectsRoots = Set<String>()
    private(set) var hasLoadedConfiguration = false
    var autoDiscover = false

    var canEdit: Bool { hasLoadedConfiguration }

    var configurationRequest: EngramServiceConfigureClaudeCodeProfilesRequest? {
        guard canEdit else { return nil }
        return EngramServiceConfigureClaudeCodeProfilesRequest(
            autoDiscover: autoDiscover,
            customProjectsRoots: customProjectsRoots
        )
    }

    var rows: [ClaudeCodeProfilesSettingsRow] {
        var result: [ClaudeCodeProfilesSettingsRow] = []
        var emittedRoots = Set<String>()
        let customRootSet = Set(customProjectsRoots)

        if let status {
            for profile in status.profiles {
                let registeredCustom = customRootSet.contains(profile.projectsRoot)
                if profile.origin == "custom", !registeredCustom {
                    continue
                }
                if profile.origin == "automatic", !autoDiscover, !registeredCustom {
                    continue
                }
                guard emittedRoots.insert(profile.projectsRoot).inserted else { continue }
                result.append(
                    ClaudeCodeProfilesSettingsRow(
                        projectsRoot: profile.projectsRoot,
                        profile: profile,
                        canRemoveCustomRegistration: registeredCustom,
                        detailState: .current
                    )
                )
            }
        }

        for root in customProjectsRoots where emittedRoots.insert(root).inserted {
            result.append(
                ClaudeCodeProfilesSettingsRow(
                    projectsRoot: root,
                    profile: nil,
                    canRemoveCustomRegistration: true,
                    detailState: persistedCustomProjectsRoots.contains(root)
                        ? .statusUnavailable
                        : .pendingSave
                )
            )
        }
        return result
    }

    mutating func applyStatusSuccess(
        _ response: EngramServiceClaudeCodeProfilesStatusResponse
    ) {
        guard response.configurationError == nil else {
            status = nil
            return
        }
        status = response
        autoDiscover = response.autoDiscover
        customProjectsRoots = response.customProjectsRoots
        persistedCustomProjectsRoots = Set(response.customProjectsRoots)
        hasLoadedConfiguration = true
    }

    mutating func applyStatusFailure() {
        status = nil
    }

    mutating func addCustomRoot(_ root: String) -> AddResult {
        guard canEdit else { return .notReady }
        guard !customProjectsRoots.contains(root) else { return .duplicate }
        guard customProjectsRoots.count < 64 else { return .limitReached }
        customProjectsRoots.append(root)
        customProjectsRoots.sort()
        return .added
    }

    mutating func removeCustomRoot(_ root: String) {
        guard canEdit else { return }
        customProjectsRoots.removeAll { $0 == root }
    }
}

struct ClaudeCodeProfilesSettingsCard: View {
    @Environment(EngramServiceClient.self) private var serviceClient

    @State private var editor = ClaudeCodeProfilesSettingsState()
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
                    isOn: $editor.autoDiscover
                )
                .disabled(!editor.canEdit || loading || saving)
                .accessibilityIdentifier("claudeProfiles_autoDiscover")

                Text("Choose a Claude Code projects folder. Custom folders are indexed and archived, but their source files are protected from automatic local reclamation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                profileRows

                HStack(spacing: 8) {
                    Button("Add Projects Folder…") { addProjectsFolder() }
                        .disabled(!editor.canEdit || loading || saving)
                        .accessibilityIdentifier("claudeProfiles_add")

                    Button("Save") { Task { await save() } }
                        .disabled(editor.configurationRequest == nil || loading || saving)
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
        ForEach(editor.rows) { row in
            if let profile = row.profile {
                ClaudeCodeProfileStatusRow(
                    row: row,
                    profile: profile,
                    remove: row.canRemoveCustomRegistration
                        ? { removeCustomRoot(row.projectsRoot) }
                        : nil
                )
                .accessibilityIdentifier(row.rowAccessibilityIdentifier)
            } else {
                ClaudeCodePendingProfileRow(row: row) {
                    removeCustomRoot(row.projectsRoot)
                }
                .accessibilityIdentifier(row.rowAccessibilityIdentifier)
            }
        }

        if editor.rows.isEmpty, editor.canEdit, !loading {
            Text("No Claude Code profiles found.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            editor.applyStatusSuccess(response)
            if response.configurationError != nil {
                message = String(localized: "Profile configuration is invalid.")
                messageIsError = true
            } else {
                message = nil
                messageIsError = false
            }
        } catch {
            guard refreshGeneration == generation else { return }
            editor.applyStatusFailure()
            message = String(localized: "Error: profile status is unavailable.")
            messageIsError = true
        }
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        guard let request = editor.configurationRequest else { return }
        saving = true
        message = nil
        defer { saving = false }
        do {
            let response = try await serviceClient.configureClaudeCodeProfiles(
                request
            )
            editor.applyStatusSuccess(response)
            if response.configurationError != nil {
                message = String(localized: "Profile configuration is invalid.")
                messageIsError = true
            } else {
                message = String(localized: "Saved.")
                messageIsError = false
            }
        } catch {
            message = String(localized: "Error: profile configuration could not be saved.")
            messageIsError = true
        }
    }

    @MainActor
    private func addProjectsFolder() {
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
        switch editor.addCustomRoot(canonicalURL.path) {
        case .added, .duplicate:
            message = nil
            messageIsError = false
        case .limitReached:
            message = String(localized: "Error: no more than 64 custom projects folders can be added.")
            messageIsError = true
        case .notReady:
            break
        }
    }

    private func removeCustomRoot(_ projectsRoot: String) {
        editor.removeCustomRoot(projectsRoot)
        message = nil
        messageIsError = false
    }
}

private struct ClaudeCodeProfileStatusRow: View {
    let row: ClaudeCodeProfilesSettingsRow
    let profile: EngramServiceClaudeCodeProfileStatus
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(profile.available ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(verbatim: row.displayName)
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
                        .accessibilityIdentifier(row.removeAccessibilityIdentifier)
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
    let row: ClaudeCodeProfilesSettingsRow
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.projectsRoot)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let statusText = row.placeholderStatusText {
                    Text(verbatim: statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Source files protected from local reclamation")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            Spacer()
            Button("Remove", action: remove)
                .buttonStyle(.borderless)
                .accessibilityIdentifier(row.removeAccessibilityIdentifier)
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
