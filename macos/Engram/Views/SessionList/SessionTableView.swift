// macos/Engram/Views/SessionList/SessionTableView.swift
import SwiftUI

/// SwiftUI Table displaying sessions with sortable columns.
struct SessionTableView: View {
    let sessions: [Session]
    @Binding var selectedSessionId: String?
    @Binding var sortOrder: [KeyPathComparator<Session>]
    var columns: ColumnVisibilityStore

    let favoriteIds: Set<String>
    var onToggleFavorite: ((String, Bool) -> Void)?
    var onDelete: ((String) -> Void)?
    var onRename: ((Session) -> Void)?
    var onFilterProject: ((String) -> Void)?

    var body: some View {
        Table(of: Session.self, selection: $selectedSessionId, sortOrder: $sortOrder) {
            // Favorite column (not sortable — no value: key path)
            TableColumn("") { session in
                let isFav = favoriteIds.contains(session.id)
                Button {
                    onToggleFavorite?(session.id, isFav)
                } label: {
                    Image(systemName: isFav ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFav ? Color.yellow : Color.gray.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
            .width(columns.favorite ? 28 : 0)

            // Agent / Source column
            TableColumn("Agent", value: \.source) { session in
                HStack(spacing: 4) {
                    Circle()
                        .fill(SourceColors.color(for: session.source))
                        .frame(width: 7, height: 7)
                    Text(SourceColors.label(for: session.source))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .width(min: columns.agent ? 56 : 0, ideal: columns.agent ? 64 : 0, max: columns.agent ? 80 : 0)

            // Title column (flexible)
            TableColumn("Title", value: \.displayTitle) { session in
                Text(session.displayTitle)
                    .lineLimit(1)
                    .help(session.displayTitle)
            }
            .width(min: columns.title ? 120 : 0, ideal: columns.title ? 300 : 0)

            // Date column
            TableColumn("Date", value: \.startTime) { session in
                Text(relativeDate(session.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: columns.date ? 70 : 0, ideal: columns.date ? 90 : 0, max: columns.date ? 110 : 0)

            // Project column (not sortable — project is optional)
            TableColumn("Project") { (session: Session) in
                Text(session.project ?? "--")
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: columns.project ? 60 : 0, ideal: columns.project ? 90 : 0, max: columns.project ? 140 : 0)

            // Message count column
            TableColumn("Msgs", value: \.messageCount) { session in
                Text("\(session.messageCount)")
                    .font(.caption)
                    .monospacedDigit()
            }
            .width(columns.msgs ? 44 : 0)

            // Size column
            TableColumn("Size", value: \.sizeBytes) { session in
                Text(session.formattedSize)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(session.sizeCategory == .huge ? .red : session.sizeCategory == .large ? .orange : .secondary)
            }
            .width(columns.size ? 50 : 0)
        } rows: {
            ForEach(sessions) { session in
                TableRow(session)
                    .contextMenu {
                        if !session.cwd.isEmpty {
                            Button("Open Working Directory") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd))
                            }
                        }
                        Button("Reveal Session Log") {
                            NSWorkspace.shared.selectFile(session.effectiveFilePath, inFileViewerRootedAtPath: "")
                        }
                        Divider()
                        Button("Copy Session ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.id, forType: .string)
                        }
                        if let project = session.project {
                            Button("Filter by Project: \(project)") {
                                onFilterProject?(project)
                            }
                        }
                        Divider()
                        Button("Rename...") { onRename?(session) }
                        let isFav = favoriteIds.contains(session.id)
                        Button(isFav ? "Remove from Saved" : "Save") {
                            onToggleFavorite?(session.id, isFav)
                        }
                        Divider()
                        Button("Delete", role: .destructive) { onDelete?(session.id) }
                    }
            }
        }
        .alternatingRowBackgrounds(.enabled)
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private func relativeDate(_ iso: String) -> String {
        guard let date = Self.isoFormatter.date(from: iso) else {
            return String(iso.prefix(10))
        }
        return Self.relFormatter.localizedString(for: date, relativeTo: Date())
    }
}
