// macos/Engram/Views/Projects/AliasSheet.swift
//
// Add/remove project aliases for one canonical project. Mutations are
// service-owned; listing is a read-only local index query so users can
// inspect current continuity state without leaving the app.
//
// BOTH-REQUIRED GUARD: a single service guard requires old_project AND
// new_project to be non-nil for BOTH add and remove. Remove must pass the
// alias row's canonical project when the sheet was opened from the alias side.

import SwiftUI

/// Parse the alias mutation result (.object) into a confirmation string.
func aliasConfirmation(_ value: EngramServiceJSONValue) -> String? {
    guard case .object(let root) = value else { return nil }
    guard case .bool(true)? = root["ok"] else { return nil }
    var action = ""
    var alias = ""
    var canonical = ""
    if case .string(let s)? = root["action"] { action = s }
    if case .string(let s)? = root["alias"] { alias = s }
    if case .string(let s)? = root["canonical"] { canonical = s }
    if action == "remove" {
        return "Alias removed: \(alias)"
    }
    return "Alias added: \(alias) → \(canonical)"
}

func aliasMutationRequest(
    action: String,
    input: String,
    projectName: String,
    aliases: [DatabaseManager.ProjectAlias],
    actor: String = "app"
) -> EngramServiceProjectAliasRequest? {
    let alias = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !alias.isEmpty else { return nil }
    let canonical = action == "remove"
        ? aliases.first { $0.alias == alias }?.canonical ?? projectName
        : projectName
    return EngramServiceProjectAliasRequest(
        action: action,
        oldProject: alias,
        newProject: canonical,
        actor: actor
    )
}

struct AliasSheet: View {
    let projectName: String
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

    @State private var aliases: [DatabaseManager.ProjectAlias] = []
    @State private var isLoadingAliases = false
    @State private var aliasLoadError: String?
    @State private var addInput: String = ""
    @State private var removeInput: String = ""
    @State private var isExecuting = false
    @State private var confirmation: String?
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project Aliases")
                .font(.headline)
            Text(projectName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if !nativeProjectMigrationCommandsEnabled {
                Label(nativeProjectMigrationUnavailableMessage, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                aliasListSection

                VStack(alignment: .leading, spacing: 6) {
                    Text("Add alias (old project path):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("/old/project/path", text: $addInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .disabled(isExecuting)
                        Button("Add") {
                            activeTask = Task { await mutate(action: "add", input: addInput) }
                        }
                        .disabled(isExecuting || addInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Remove alias:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("/old/project/path", text: $removeInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .disabled(isExecuting)
                        Button("Remove") {
                            activeTask = Task { await mutate(action: "remove", input: removeInput) }
                        }
                        .disabled(isExecuting || removeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Text("Aliases are read from the local index; add and remove operations are routed through EngramService.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let errorMessage {
                    AlertBanner(message: errorMessage)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isExecuting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(isExecuting)
        .task(id: projectName) {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await loadAliases()
        }
        .onDisappear { activeTask?.cancel() }
    }

    private var aliasListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Existing aliases", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoadingAliases {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let aliasLoadError {
                Label("Alias list unavailable: \(aliasLoadError)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if aliases.isEmpty {
                Text("No aliases recorded for this project.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(aliases) { alias in
                            Button {
                                removeInput = alias.alias
                            } label: {
                                HStack(spacing: 6) {
                                    Text(alias.alias)
                                        .font(.system(.caption2, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(alias.alias)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(alias.canonical)
                                        .font(.system(.caption2, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(alias.canonical)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Theme.surfaceHighlight)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Alias \(alias.alias) resolves to \(alias.canonical)")
                            .accessibilityHint("Click to copy this alias into the remove field")
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func loadAliases() async {
        aliasLoadError = nil
        isLoadingAliases = true
        defer { isLoadingAliases = false }
        let db = self.db
        do {
            let rows = try await Task.detached {
                try db.listProjectAliases(project: projectName)
            }.value
            if Task.isCancelled { return }
            aliases = rows
        } catch {
            if Task.isCancelled { return }
            aliasLoadError = error.localizedDescription
            aliases = []
        }
    }

    private func mutate(action: String, input: String) async {
        guard let request = aliasMutationRequest(
            action: action,
            input: input,
            projectName: projectName,
            aliases: aliases
        ) else { return }
        confirmation = nil
        errorMessage = nil
        isExecuting = true
        defer { isExecuting = false; activeTask = nil }
        do {
            let result = try await serviceClient.manageProjectAlias(request)
            if Task.isCancelled { return }
            confirmation = aliasConfirmation(result) ?? "Alias \(action) succeeded."
            if action == "add" { addInput = "" } else { removeInput = "" }
            await loadAliases()
            NotificationCenter.default.post(name: .projectsDidChange, object: nil)
        } catch {
            if Task.isCancelled { return }
            errorMessage = projectMoveErrorMessage(error)
        }
    }
}
