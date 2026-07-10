// macos/Engram/Views/Projects/UndoSheet.swift
//
// Undo flow: lists the most recent committed migrations and lets the user
// pick one to reverse. The orchestrator's undoMigration walks the
// migration_log and runs runProjectMove in reverse, writing a new
// migration_log row with rolledBackOf set to the original.

import SwiftUI

/// Shared parser for the ISO-8601 timestamps the daemon emits, with a
/// fallback for the rare case where `startedAt` comes back in SQLite's
/// default string format. Gemini minor #12.
private let migrationISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let migrationSQLiteFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private let migrationHumanFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

private func humanizeMigrationTimestamp(_ raw: String) -> String {
    let parsed =
        migrationISOFormatter.date(from: raw)
        ?? migrationSQLiteFormatter.date(from: raw)
    guard let date = parsed else { return raw }
    return migrationHumanFormatter.localizedString(for: date, relativeTo: Date())
}

struct UndoSheet: View {
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

    @State private var migrations: [EngramServiceMigrationLogEntry] = []
    @State private var selectedMigrationId: String?
    @State private var isLoading = true
    @State private var isExecuting = false
    @State private var errorMessage: String?
    @State private var retryPolicy: String = "safe"
    @State private var activeTask: Task<Void, Never>?
    /// Stable id for cancel / reconnect / idempotent re-submit (Wave 8 long-ops).
    @State private var activeOperationId: String?
    @State private var isReconnecting = false
    @FocusState private var focusedMigrationId: String?
    /// IDs where retry_policy: 'never' came back (UndoStale etc.) — these
    /// can't be retried, so the UI disables the row. Codex minor #5.
    @State private var disabledMigrationIds: Set<String> = []
    /// Gemini Round 4 Important: previously the disabled row was just
    /// dimmed — user had no idea why. Now the reason (error message) is
    /// stashed per-id and rendered inline under the disabled row so the
    /// user can read "this migration's newPath was overlaid by migration
    /// X" instead of guessing.
    @State private var disabledReasons: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Undo Recent Move")
                .font(.headline)
            Text("Pick a committed migration to reverse.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if !nativeProjectMigrationCommandsEnabled {
                Label(nativeProjectMigrationUnavailableMessage, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if isLoading {
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
                    ForEach(Array(migrations.enumerated()), id: \.element.id) { index, m in
                        migrationRow(m, index: index)
                    }
                }
                if isExecuting {
                    // Round 4 feedback: Undo runs a full reverse migration
                    // (patch files + rename dirs + move physical dir back).
                    // Without a spinner the sheet looks frozen for seconds.
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            isReconnecting
                                ? projectMoveReconnectingMessage()
                                : "Reversing migration — restoring files and directories…"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                        HStack {
                            Text(retryPolicyExplainer(retryPolicy))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if retryPolicyAllowsRetry(retryPolicy),
                               selectedMigrationId != nil
                            {
                                Button("Retry") {
                                    activeTask = Task { await runUndo() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isExecuting)
                            }
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
                if !nativeProjectMigrationCommandsEnabled {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        if isExecuting, let operationId = activeOperationId {
                            Task {
                                _ = try? await serviceClient.cancelProjectMoveBatch(
                                    operationId: operationId
                                )
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Undo") {
                        activeTask = Task { await runUndo() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        selectedMigrationId == nil
                            || isExecuting
                            || (selectedMigrationId.map { disabledMigrationIds.contains($0) } ?? false)
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isExecuting)
        .task {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await loadMigrations()
        }
        .onMoveCommand(perform: moveSelection)
        .onDisappear { activeTask?.cancel() }
    }

    @ViewBuilder
    private func migrationRow(_ m: EngramServiceMigrationLogEntry, index: Int) -> some View {
        Button(action: {
            if !disabledMigrationIds.contains(m.id) {
                selectedMigrationId = m.id
                focusedMigrationId = m.id
            }
        }) {
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
                        Text(humanizeMigrationTimestamp(m.startedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help(m.startedAt)  // hover to see raw ISO
                        Text(m.id.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("by \(m.actor)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    // Gemini Round 4: inline reason for disabled rows so
                    // the user isn't left guessing.
                    if let reason = disabledReasons[m.id] {
                        Label("Can't undo: \(reason)", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.top, 2)
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
            .opacity(disabledMigrationIds.contains(m.id) ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .focusable(!disabledMigrationIds.contains(m.id))
        .focused($focusedMigrationId, equals: m.id)
        .disabled(isExecuting || disabledMigrationIds.contains(m.id))
        .accessibilityIdentifier("undo_migrationRow_\(index)")
        .accessibilityLabel(
            disabledMigrationIds.contains(m.id)
                ? "Migration \(m.id.prefix(8)) — can't undo: \(disabledReasons[m.id] ?? "blocked")"
                : "Migration \(m.id.prefix(8)) — \(m.oldBasename) to \(m.newBasename)"
        )
    }

    private func loadMigrations() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await serviceClient.projectMigrations(
                EngramServiceProjectMigrationsRequest(state: "committed", limit: 5)
            )
            migrations = response.migrations
            if selectedMigrationId == nil {
                selectFirstAvailableMigration()
            }
        } catch {
            errorMessage = "Failed to load migrations: \(error.localizedDescription)"
        }
    }

    private func selectFirstAvailableMigration() {
        guard let first = migrations.first(where: { !disabledMigrationIds.contains($0.id) }) else {
            return
        }
        selectedMigrationId = first.id
        focusedMigrationId = first.id
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !isExecuting else { return }
        let selectable = migrations.filter { !disabledMigrationIds.contains($0.id) }
        guard !selectable.isEmpty else { return }
        let current = selectedMigrationId.flatMap { id in selectable.firstIndex { $0.id == id } } ?? 0
        let nextIndex: Int
        switch direction {
        case .up, .left:
            nextIndex = max(current - 1, 0)
        case .down, .right:
            nextIndex = min(current + 1, selectable.count - 1)
        @unknown default:
            nextIndex = current
        }
        let next = selectable[nextIndex].id
        selectedMigrationId = next
        focusedMigrationId = next
    }

    private func runUndo() async {
        guard let id = selectedMigrationId else { return }
        errorMessage = nil
        isReconnecting = false
        isExecuting = true
        let operationId = UUID().uuidString
        activeOperationId = operationId
        defer {
            isExecuting = false
            isReconnecting = false
            activeTask = nil
            activeOperationId = nil
        }
        let request = EngramServiceProjectUndoRequest(
            migrationId: id,
            force: false,
            actor: "app",
            operationId: operationId
        )
        do {
            let res = try await executeUndoWithReconnect(request)
            if Task.isCancelled { return }
            if res.state == "cancelled" {
                errorMessage = projectMoveCancelledBeforeCommitMessage(kind: "Undo")
                retryPolicy = "safe"
                return
            }
            if res.state == "committed" {
                if !res.review.own.isEmpty {
                    // Gemini follow-up: surface residual refs instead of
                    // silently closing. Undo usually has zero (it's a
                    // reverse move), but a half-failed reverse can leave
                    // some behind.
                    errorMessage =
                        "Undo committed, but \(res.review.own.count) file(s) still reference the undone path. Re-run undo to retry, or open Migration History to review."
                    retryPolicy = "never"
                    return
                }
                NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                dismiss()
            } else {
                errorMessage = "Unexpected state: \(res.state)"
            }
        } catch {
            if Task.isCancelled { return }
            errorMessage = projectMoveErrorMessage(error)
            retryPolicy = projectMoveRetryPolicy(error)
            // Codex minor #5: on a 'never' policy (UndoStale, etc.), mark
            // this specific migration as disabled so the user can't retry
            // the same stale row. They can still try a different one.
            // Cancelled-before-commit uses retryPolicy "safe" and must stay retryable.
            if retryPolicy == "never" {
                disabledMigrationIds.insert(id)
                disabledReasons[id] = errorMessage ?? "Undo failed"
                selectedMigrationId = nil
            }
        }
    }

    private func executeUndoWithReconnect(
        _ request: EngramServiceProjectUndoRequest
    ) async throws -> EngramServiceProjectMoveResult {
        do {
            return try await serviceClient.projectUndo(request)
        } catch {
            guard projectMoveIsReconnectableError(error) else { throw error }
            isReconnecting = true
            defer { isReconnecting = false }
            return try await serviceClient.projectUndo(request)
        }
    }
}
