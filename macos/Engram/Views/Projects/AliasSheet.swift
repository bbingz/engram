// macos/Engram/Views/Projects/AliasSheet.swift
//
// Add/remove project aliases for one canonical project. The service
// handler supports action "add"|"remove" only — there is no "list" path
// (listing is MCP-only), so this sheet can add and remove aliases but
// cannot enumerate the existing ones.
//
// BOTH-REQUIRED GUARD: a single service guard requires old_project AND
// new_project to be non-nil for BOTH add and remove. So Remove must also
// pass newProject:<projectName>, not nil.

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

struct AliasSheet: View {
    let projectName: String
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

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

                Text("Aliases can be added or removed here, but existing aliases are managed via the engram MCP tool and cannot be listed in-app yet.")
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
        .onDisappear { activeTask?.cancel() }
    }

    private func mutate(action: String, input: String) async {
        let alias = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return }
        confirmation = nil
        errorMessage = nil
        isExecuting = true
        defer { isExecuting = false; activeTask = nil }
        do {
            // Both add AND remove must send newProject non-nil (service guard).
            let result = try await serviceClient.manageProjectAlias(
                EngramServiceProjectAliasRequest(
                    action: action,
                    oldProject: alias,
                    newProject: projectName,
                    actor: "app"
                )
            )
            if Task.isCancelled { return }
            confirmation = aliasConfirmation(result) ?? "Alias \(action) succeeded."
            if action == "add" { addInput = "" } else { removeInput = "" }
        } catch {
            if Task.isCancelled { return }
            errorMessage = projectMoveErrorMessage(error)
        }
    }
}
