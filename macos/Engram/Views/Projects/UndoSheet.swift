// macos/Engram/Views/Projects/UndoSheet.swift
//
// Undo flow: lists the most recent committed migrations and lets the user
// pick one to reverse. The orchestrator's undoMigration walks the
// migration_log and runs runProjectMove in reverse, writing a new
// migration_log row with rolledBackOf set to the original.

import SwiftUI

struct UndoSheet: View {
    @Environment(DaemonClient.self) var daemonClient
    @Environment(\.dismiss) var dismiss

    @State private var migrations: [MigrationLogEntry] = []
    @State private var selectedMigrationId: String?
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var errorMessage: String?
    @State private var retryPolicy: String = "safe"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Undo Recent Move")
                .font(.headline)
            Text("Pick a committed migration to reverse.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if isLoading {
                ProgressView("Loading recent migrations…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if migrations.isEmpty {
                Label("No recent committed migrations.", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(migrations) { m in
                        migrationRow(m)
                    }
                }
                if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                        if retryPolicy != "safe" {
                            Text("retry_policy: \(retryPolicy)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExecuting)
                Button("Undo") { Task { await runUndo() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedMigrationId == nil || isExecuting)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await loadMigrations() }
    }

    @ViewBuilder
    private func migrationRow(_ m: MigrationLogEntry) -> some View {
        Button(action: { selectedMigrationId = m.id }) {
            HStack(spacing: 10) {
                Image(
                    systemName: selectedMigrationId == m.id
                        ? "circle.inset.filled" : "circle"
                )
                .foregroundStyle(selectedMigrationId == m.id ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.oldBasename)
                            .font(.callout.weight(.medium))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(m.newBasename)
                            .font(.callout.weight(.medium))
                        if m.archived {
                            Text("archived")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(m.oldPath) → \(m.newPath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(m.startedAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(m.id.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("by \(m.actor)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(
                selectedMigrationId == m.id
                    ? Color.accentColor.opacity(0.08)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isExecuting)
    }

    private func loadMigrations() async {
        isLoading = true
        defer { isLoading = false }
        do {
            migrations = try await daemonClient.listProjectMigrations(
                state: "committed",
                limit: 5
            )
        } catch {
            errorMessage = "Failed to load migrations: \(error.localizedDescription)"
        }
    }

    private func runUndo() async {
        guard let id = selectedMigrationId else { return }
        errorMessage = nil
        isExecuting = true
        defer { isExecuting = false }
        do {
            let res = try await daemonClient.projectUndo(migrationId: id, force: false)
            if res.state == "committed" {
                NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                dismiss()
            } else {
                errorMessage = "Unexpected state: \(res.state)"
            }
        } catch let apiErr as ProjectMoveAPIError {
            errorMessage = apiErr.message
            retryPolicy = apiErr.retryPolicy
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
