// macos/Engram/Views/Pages/ProjectsView.swift
import SwiftUI

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

struct ProjectsView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(DaemonClient.self) var daemonClient
    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var selectedProject: DatabaseManager.ProjectGroup? = nil
    @State private var isLoading = true
    @State private var renameTarget: String?
    @State private var archiveTarget: String?
    @State private var showUndoSheet = false
    @State private var hasRecentMigrations = false

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return projectGroups.filter { group in
            guard let date = isoFormatter.date(from: group.lastActive) else { return false }
            return date > weekAgo
        }.count
    }

    private var avgSessions: Int {
        guard !projectGroups.isEmpty else { return 0 }
        return projectGroups.reduce(0) { $0 + $1.sessionCount } / projectGroups.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(projectGroups.count)", label: "Total Projects")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                    KPICard(value: "\(avgSessions)", label: "Avg Sessions")
                }

                if let selected = selectedProject {
                    HStack {
                        Button(action: { selectedProject = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("All Projects")
                            }
                            .font(.callout)
                            .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    SectionHeader(icon: "folder", title: selected.project)
                    ForEach(selected.sessions) { session in
                        SessionCard(session: session) {
                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                        }
                    }
                } else {
                    HStack {
                        SectionHeader(icon: "folder", title: "Projects")
                        Spacer()
                        Button {
                            showUndoSheet = true
                        } label: {
                            Label("Undo Recent Move…", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!hasRecentMigrations)
                        .help(
                            hasRecentMigrations
                                ? "Pick a recent committed migration to reverse"
                                : "No recent committed migrations to undo"
                        )
                        .accessibilityIdentifier("projects_undoButton")
                    }
                    if projectGroups.isEmpty && !isLoading {
                        EmptyState(icon: "folder", title: "No projects", message: "Sessions without project associations won't appear here")
                            .accessibilityIdentifier("projects_emptyState")
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(projectGroups.enumerated()), id: \.element.id) { index, group in
                                HStack(spacing: 0) {
                                    Button(action: { selectedProject = group }) {
                                        HStack {
                                            Text(group.project.split(separator: "/").last.map(String.init) ?? group.project)
                                                .font(.callout)
                                                .foregroundStyle(Theme.primaryText)
                                            Text(group.project)
                                                .font(.caption)
                                                .foregroundStyle(Theme.tertiaryText)
                                                .lineLimit(1)
                                            Spacer()
                                            Text("\(group.sessionCount)")
                                                .font(.caption)
                                                .foregroundStyle(Theme.secondaryText)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(Theme.surfaceHighlight)
                                                .clipShape(Capsule())
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)

                                    Menu {
                                        Button {
                                            renameTarget = group.project
                                        } label: {
                                            Label("Rename…", systemImage: "pencil")
                                        }
                                        Button {
                                            archiveTarget = group.project
                                        } label: {
                                            Label("Archive…", systemImage: "archivebox")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.caption)
                                            .foregroundStyle(Theme.tertiaryText)
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .accessibilityLabel("Project options")
                                    .accessibilityIdentifier("projects_menu_\(index)")

                                    // Chevron as a separate Button so it keeps a
                                    // visible click target (previously it was a
                                    // no-op sibling of the Menu button).
                                    Button(action: { selectedProject = group }) {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.tertiaryText.opacity(0.5))
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 8)
                                    .accessibilityLabel("Open project details")
                                }
                                .background(Theme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("projects_group_\(index)")
                            }
                        }
                        .accessibilityIdentifier("projects_list")
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("projects_container")
        .task { await loadData() }
        .sheet(item: Binding(
            get: { renameTarget.map(SheetWrappedString.init) },
            set: { renameTarget = $0?.value }
        )) { wrapped in
            RenameSheet(projectName: wrapped.value)
        }
        .sheet(item: Binding(
            get: { archiveTarget.map(SheetWrappedString.init) },
            set: { archiveTarget = $0?.value }
        )) { wrapped in
            ArchiveSheet(projectName: wrapped.value)
        }
        .sheet(isPresented: $showUndoSheet) {
            UndoSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectsDidChange)) { _ in
            Task { await loadData() }
        }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do { projectGroups = try db.listSessionsByProject() } catch { print("ProjectsView error:", error) }
        // Refresh the Undo button's enabled state — cheap call, at most 5 rows.
        // Reviewer minor #7: distinguish "no migrations" from "daemon failed"
        // so the tooltip doesn't lie when the daemon is unreachable.
        do {
            let migrations = try await daemonClient.listProjectMigrations(
                state: "committed",
                limit: 1
            )
            hasRecentMigrations = !migrations.isEmpty
        } catch {
            print("ProjectsView: listProjectMigrations failed:", error)
            // Leave previous value intact — the user may have cached state
            // from a successful earlier fetch. Falls to false on first load.
        }
    }
}

/// Wrap a String so it can drive `.sheet(item:)` which requires Identifiable.
/// Used because the project name IS the identifier for the sheet presentation.
private struct SheetWrappedString: Identifiable {
    let value: String
    var id: String { value }
}
