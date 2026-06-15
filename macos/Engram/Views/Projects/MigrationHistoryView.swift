// macos/Engram/Views/Projects/MigrationHistoryView.swift
//
// Read-only browser for the project migration log. Lists every recorded
// migration (move/archive/undo) newest-first so the user can review what
// changed in-app instead of reaching for a CLI that does not ship.

import SwiftUI

// Local copies of UndoSheet's timestamp helpers (UndoSheet.swift:13-37).
// Copied rather than refactored per the surgical-diff rules.
private let historyISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let historySQLiteFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private let historyHumanFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

private func humanizeHistoryTimestamp(_ raw: String) -> String {
    let parsed =
        historyISOFormatter.date(from: raw)
        ?? historySQLiteFormatter.date(from: raw)
    guard let date = parsed else { return raw }
    return historyHumanFormatter.localizedString(for: date, relativeTo: Date())
}

struct MigrationHistoryView: View {
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

    @State private var migrations: [EngramServiceMigrationLogEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Migration History")
                .font(.headline)
            Text("Every recorded project move, archive, and undo.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if !nativeProjectMigrationCommandsEnabled {
                Label(nativeProjectMigrationUnavailableMessage, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if isLoading {
                ProgressView("Loading migration history…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let errorMessage {
                AlertBanner(
                    message: "Failed to load history: \(errorMessage)",
                    action: ("Retry", retry)
                )
            } else if migrations.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath", title: "No project migrations yet", message: "Moves, archives, and undos will appear here.")
                    .accessibilityIdentifier("history_emptyState")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(migrations.enumerated()), id: \.element.id) { index, m in
                            migrationRow(m)
                                .accessibilityIdentifier("history_row_\(index)")
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("history_container")
        .task {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await load()
        }
    }

    @ViewBuilder
    private func migrationRow(_ m: EngramServiceMigrationLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(m.oldBasename)
                    .font(.callout.weight(.medium))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(m.newBasename)
                    .font(.callout.weight(.medium))
                stateBadge(m.state)
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
                .truncationMode(.middle)
                .help("\(m.oldPath) → \(m.newPath)")
            HStack(spacing: 8) {
                Text(humanizeHistoryTimestamp(m.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(m.startedAt)
                Text("by \(m.actor)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let note = m.auditNote, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    @ViewBuilder
    private func stateBadge(_ state: String) -> some View {
        let color: Color = switch state {
        case "committed": .green
        case "failed": .red
        default: .secondary
        }
        Text(state)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func retry() {
        Task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await serviceClient.projectMigrations(
                EngramServiceProjectMigrationsRequest(state: nil, limit: 100)
            )
            migrations = response.migrations
        } catch {
            errorMessage = projectMoveErrorMessage(error)
        }
    }
}
