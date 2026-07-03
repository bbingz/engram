// macos/Engram/Views/Pages/ProjectsView.swift
import SwiftUI

struct ProjectsView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var projectAliases: [DatabaseManager.ProjectAlias] = []
    @State private var selectedProject: DatabaseManager.ProjectGroup? = nil
    @State private var isLoading = true
    @State private var renameTarget: String?
    @State private var archiveTarget: String?
    @State private var aliasTarget: String?
    @State private var showUndoSheet = false
    @State private var showHistorySheet = false
    @State private var showBatchSheet = false
    @State private var isSelecting = false
    @State private var selectedProjects: Set<String> = []
    /// Three-state: nil = haven't fetched yet / last fetch failed (unknown),
    /// empty = no committed migrations, non-empty = projects touched by
    /// recent committed migrations.
    /// Reviewer: silently preserving the last-known true value when the
    /// daemon becomes unreachable was misleading. Now the Undo button is
    /// disabled when we can't confirm the log is reachable.
    @State private var committedMigrationProjects: Set<String>? = nil
    @State private var loadError: String? = nil

    private var activeCount: Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return projectGroups.filter { group in
            guard let date = EngramTimestampParser.date(from: group.lastActive) else { return false }
            return date > weekAgo
        }.count
    }

    private var avgSessions: Int {
        guard !projectGroups.isEmpty else { return 0 }
        return projectGroups.reduce(0) { $0 + $1.sessionCount } / projectGroups.count
    }

    private var aliasCount: Int { projectAliases.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load projects: \(loadError)")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(projectGroups.count)", label: "Total Projects")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                    KPICard(value: "\(avgSessions)", label: "Avg Sessions")
                    KPICard(value: "\(aliasCount)", label: "Aliases")
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
                    ProjectContinuityPanel(
                        project: selected.project,
                        aliases: aliases(for: selected.project),
                        migrationState: migrationState(for: selected.project),
                        canManageMigrations: nativeProjectMigrationCommandsEnabled,
                        onAliases: { aliasTarget = selected.project },
                        onHistory: { showHistorySheet = true }
                    )
                    ProjectWorkTimeline(project: selected.project)
                    SearchPageView(
                        projectFilter: selected.project,
                        locksProject: true,
                        embeddedInParentScroll: true,
                        contentPadding: 0
                    )
                    LazyVStack(spacing: 4) {
                        ForEach(selected.sessions) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                } else {
                    HStack {
                        SectionHeader(icon: "folder", title: "Projects")
                        Spacer()
                        if nativeProjectMigrationCommandsEnabled {
                            if isSelecting && !selectedProjects.isEmpty {
                                Button {
                                    showBatchSheet = true
                                } label: {
                                    Label("Move Selected (\(selectedProjects.count))…", systemImage: "arrow.right.doc.on.clipboard")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("projects_batchMoveButton")
                            }
                            Button {
                                isSelecting.toggle()
                                if !isSelecting { selectedProjects.removeAll() }
                            } label: {
                                Label(isSelecting ? "Done" : "Select", systemImage: "checklist")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("projects_selectToggle")
                            Button {
                                showHistorySheet = true
                            } label: {
                                Label("History…", systemImage: "clock.arrow.circlepath")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("projects_historyButton")
                            Button {
                                showUndoSheet = true
                            } label: {
                                Label("Undo Recent Move…", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(committedMigrationProjects?.isEmpty != false)
                            .help(undoButtonHelp)
                            .accessibilityIdentifier("projects_undoButton")
                        }
                    }
                    if projectGroups.isEmpty && !isLoading {
                        EmptyState(icon: "folder", title: "No projects", message: "Sessions without project associations won't appear here")
                            .accessibilityIdentifier("projects_emptyState")
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(projectGroups.enumerated()), id: \.element.id) { index, group in
                                HStack(spacing: 0) {
                                    if nativeProjectMigrationCommandsEnabled && isSelecting {
                                        Button {
                                            if selectedProjects.contains(group.project) {
                                                selectedProjects.remove(group.project)
                                            } else {
                                                selectedProjects.insert(group.project)
                                            }
                                        } label: {
                                            Image(systemName: selectedProjects.contains(group.project) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedProjects.contains(group.project) ? Theme.accent : Theme.tertiaryText)
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.leading, 8)
                                        .accessibilityLabel("Select project")
                                        .accessibilityIdentifier("projects_checkbox_\(index)")
                                    }
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
                                            let rowAliasCount = aliasCount(for: group.project)
                                            if rowAliasCount > 0 {
                                                Label("\(rowAliasCount)", systemImage: "tag")
                                                    .font(.caption)
                                                    .foregroundStyle(Theme.secondaryText)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 2)
                                                    .background(Theme.surfaceHighlight)
                                                    .clipShape(Capsule())
                                                    .accessibilityLabel("\(rowAliasCount) aliases")
                                            }
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

                                    if nativeProjectMigrationCommandsEnabled {
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
                                            Button {
                                                aliasTarget = group.project
                                            } label: {
                                                Label("Aliases…", systemImage: "tag")
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
                                    }

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
                                // Round 4 Gemini Minor: right-click menu
                                // mirrors the ⋯ button for discoverability.
                                // New users aren't used to hunting for
                                // ellipsis icons and expect context menus.
                                .contextMenu {
                                    if nativeProjectMigrationCommandsEnabled {
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
                                        Button {
                                            aliasTarget = group.project
                                        } label: {
                                            Label("Aliases…", systemImage: "tag")
                                        }
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("projects_list")
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("projects_container")
        .task(id: serviceStatusStore.totalSessions) { await loadData() }
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
        .sheet(item: Binding(
            get: { aliasTarget.map(SheetWrappedString.init) },
            set: { aliasTarget = $0?.value }
        )) { wrapped in
            AliasSheet(projectName: wrapped.value)
        }
        .sheet(isPresented: $showUndoSheet) {
            UndoSheet()
        }
        .sheet(isPresented: $showHistorySheet) {
            MigrationHistoryView()
        }
        .sheet(isPresented: $showBatchSheet) {
            BatchMoveSheet(projects: Array(selectedProjects).sorted())
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectsDidChange)) { _ in
            isSelecting = false
            selectedProjects.removeAll()
            Task { await loadData() }
        }
    }

    private func aliases(for project: String) -> [DatabaseManager.ProjectAlias] {
        projectAliases.filter { alias in
            alias.canonical == project || alias.alias == project
        }
    }

    private func aliasCount(for project: String) -> Int {
        aliases(for: project).count
    }

    private var undoButtonHelp: String {
        switch committedMigrationProjects {
        case .some(let projects) where !projects.isEmpty:
            return "Pick a recent committed migration to reverse"
        case .some:
            return "No recent committed migrations to undo"
        case .none: return "Migration log unavailable — daemon may not be running"
        }
    }

    private func migrationState(for project: String) -> Bool? {
        committedMigrationProjects?.contains(project)
    }

    private static func projectsTouched(by migration: EngramServiceMigrationLogEntry) -> [String] {
        [
            migration.oldPath,
            migration.newPath,
            migration.oldBasename,
            migration.newBasename,
        ].filter { !$0.isEmpty }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        // UI-C1/C2: `listSessionsByProject()` fetches limit*10 rows + groups; run off-main.
        let db = self.db
        do {
            let snapshot = try await Task.detached {
                (
                    groups: try db.listSessionsByProject(),
                    aliases: try db.listProjectAliases()
                )
            }.value
            projectGroups = snapshot.groups
            projectAliases = snapshot.aliases
            loadError = nil
        } catch {
            EngramLogger.error("ProjectsView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
            projectAliases = []
        }
        guard nativeProjectMigrationCommandsEnabled else {
            committedMigrationProjects = []
            return
        }
        // Refresh the Undo button's enabled state. Reviewer follow-up:
        // reset to nil on failure instead of silently preserving the last
        // truthy value — the user deserves an honest "daemon unreachable"
        // indicator rather than a stale optimistic one.
        do {
            let response = try await serviceClient.projectMigrations(
                EngramServiceProjectMigrationsRequest(state: "committed", limit: 100)
            )
            committedMigrationProjects = Set(response.migrations.flatMap(Self.projectsTouched(by:)))
        } catch {
            EngramLogger.error("ProjectsView migration list failed", module: .ui, error: error)
            committedMigrationProjects = nil
        }
    }
}

private struct ProjectContinuityPanel: View {
    let project: String
    let aliases: [DatabaseManager.ProjectAlias]
    let migrationState: Bool?
    let canManageMigrations: Bool
    let onAliases: () -> Void
    let onHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Continuity", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if canManageMigrations {
                    Button {
                        onAliases()
                    } label: {
                        Label("Aliases", systemImage: "tag")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("projectDetail_aliasesButton")

                    Button {
                        onHistory()
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("projectDetail_historyButton")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                continuityMetric(
                    icon: "tag",
                    label: "Aliases",
                    value: "\(aliases.count)"
                )
                continuityMetric(
                    icon: "clock.arrow.circlepath",
                    label: "Migration Log",
                    value: migrationText
                )
            }

            if aliases.isEmpty {
                Text("No aliases recorded for \(project).")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(aliases.prefix(4)) { alias in
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
                    }
                    if aliases.count > 4 {
                        Text("+\(aliases.count - 4) more aliases")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("projectDetail_continuityPanel")
    }

    private var migrationText: String {
        switch migrationState {
        case .some(true): "Committed"
        case .some(false): "None"
        case .none: "Unavailable"
        }
    }

    private func continuityMetric(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(Theme.tertiaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(Theme.primaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrap a String so it can drive `.sheet(item:)` which requires Identifiable.
/// Used because the project name IS the identifier for the sheet presentation.
private struct SheetWrappedString: Identifiable {
    let value: String
    var id: String { value }
}
