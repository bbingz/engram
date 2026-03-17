// macos/Engram/Views/SessionListView.swift
import SwiftUI
import Combine

enum SortField: String { case created, updated }

struct SessionListView: View {
    @EnvironmentObject var db: DatabaseManager
    @AppStorage("groupingMode") private var groupingMode: GroupingMode = .project
    @State private var groups: [GroupInfo] = []
    @State private var expandedGroups: Set<String> = []
    @State private var selectedSession: Session?
    @AppStorage("selectedSourcesStr") private var selectedSourcesStr: String = ""
    @AppStorage("selectedProjectsStr") private var selectedProjectsStr: String = ""
    @AppStorage("agentFilterMode") private var agentFilterMode: Int = 2  // 0=all, 1=agents, 2=hide
    @AppStorage("sortField") private var sortField: SortField = .created
    @AppStorage("sortAsc") private var sortAsc = false

    private var selectedSources: Set<String> {
        selectedSourcesStr.isEmpty ? [] : Set(selectedSourcesStr.components(separatedBy: "\t"))
    }
    private var selectedSourcesBinding: Binding<Set<String>> {
        Binding(
            get: { selectedSources },
            set: { selectedSourcesStr = $0.sorted().joined(separator: "\t") }
        )
    }
    private var selectedProjects: Set<String> {
        selectedProjectsStr.isEmpty ? [] : Set(selectedProjectsStr.components(separatedBy: "\t"))
    }
    private var selectedProjectsBinding: Binding<Set<String>> {
        Binding(
            get: { selectedProjects },
            set: { selectedProjectsStr = $0.sorted().joined(separator: "\t") }
        )
    }
    private var agentFilter: Bool? {
        agentFilterMode == 0 ? nil : agentFilterMode == 1 ? true : false
    }
    @State private var pendingSelection: Session?
    @Binding var deepLinkSession: Session?
    @State private var renameTarget: Session?
    @State private var renameText: String = ""
    @State private var showingTrash = false
    @State private var hiddenCount: Int = 0
    @State private var refreshTrigger = UUID()
    @State private var sidebarCollapsed = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 320
    @State private var dragBaseWidth: Double = 0
    @State private var availableProjects: [String] = []
    @State private var filterTask: Task<Void, Never>?
    @State private var lastGroupingMode: GroupingMode = .project

    private var filterFingerprint: String {
        "\(groupingMode)-\(selectedSourcesStr)-\(selectedProjectsStr)-\(agentFilterMode)-\(sortField)-\(sortAsc)-\(showingTrash)"
    }

    let allSources = ["claude-code", "codex", "copilot", "cursor", "gemini-cli",
                      "opencode", "iflow", "qwen", "kimi", "minimax",
                      "lobsterai", "cline", "vscode", "antigravity", "windsurf"]

    struct GroupInfo: Identifiable {
        let id: String
        let count: Int
        let lastUpdated: String
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                sidebarPanel
                sidebarDivider
            }
            detailPanel
        }
        .task {
            let db = self.db
            availableProjects = (try? await Task.detached {
                try db.readInBackground { d in
                    try String.fetchAll(d, sql: "SELECT DISTINCT project FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL ORDER BY project")
                }
            }.value) ?? []
            lastGroupingMode = groupingMode
            await loadGroups()
            // Handle deep link set before this view appeared (e.g. from Timeline tab)
            if let session = deepLinkSession {
                handleDeepLink(session)
            }
        }
        .onChange(of: filterFingerprint) { _, _ in
            filterTask?.cancel()
            filterTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await loadGroups()
                // Preserve expanded groups selectively
                if groupingMode != lastGroupingMode {
                    expandedGroups = []
                    lastGroupingMode = groupingMode
                } else {
                    let validKeys = Set(groups.map(\.id))
                    expandedGroups = expandedGroups.filter { validKeys.contains($0) }
                }
            }
        }
        .onChange(of: deepLinkSession) { _, session in
            handleDeepLink(session)
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            renameAlertContent
        } message: {
            Text("Displayed as: note | original title. Leave empty to clear.")
        }
    }

    // MARK: - Views

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            // Filter bar — row 1: filters
            HStack(spacing: 6) {
                MultiSelectPicker(
                    emptyLabel: "All sources",
                    icon: "cpu",
                    items: allSources,
                    selected: selectedSourcesBinding,
                    colorForItem: { SourceDisplay.color(for: $0) },
                    labelForItem: { SourceDisplay.label(for: $0) }
                )
                MultiSelectPicker(
                    emptyLabel: "All projects",
                    icon: "folder",
                    items: availableProjects,
                    selected: selectedProjectsBinding
                )
                Spacer()
                HStack(spacing: 4) {
                    Chip(label: "All",     selected: agentFilterMode == 0, color: .secondary) { agentFilterMode = 0 }
                    Chip(label: "Agents",  selected: agentFilterMode == 1, color: .purple)    { agentFilterMode = 1 }
                    Chip(label: "Hide",    selected: agentFilterMode == 2, color: .orange)    { agentFilterMode = 2 }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            // Filter bar — row 2: sort & grouping
            HStack(spacing: 6) {
                sortButton("Created", field: .created)
                sortButton("Updated", field: .updated)
                Spacer()
                Picker("", selection: $groupingMode) {
                    ForEach(GroupingMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode == .project ? "folder" : "cpu")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            // List - each GroupSection manages its own data loading
            List {
                ForEach(groups) { group in
                    GroupSection(
                        group: group,
                        groupingMode: groupingMode,
                        isExpanded: expandedGroups.contains(group.id),
                        selectedSession: $selectedSession,
                        showingTrash: showingTrash,
                        sortField: $sortField,
                        sortAsc: $sortAsc,
                        selectedSources: selectedSources,
                        selectedProjects: selectedProjects,
                        agentFilter: agentFilter,
                        refreshTrigger: refreshTrigger,
                        onToggle: { toggleGroup(group.id) },
                        onDelete: { id in deleteSession(id) },
                        onRename: { session in renameTarget = session; renameText = session.customName ?? session.summary ?? "" },
                        onGroupRenamed: { refreshTrigger = UUID() }
                    )
                }
            }
            .listStyle(.inset)

            // Footer
            footerView
        }
        .frame(width: sidebarWidth)
    }

    private var sidebarDivider: some View {
        Color(.separatorColor)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragBaseWidth == 0 { dragBaseWidth = sidebarWidth }
                        let newWidth = dragBaseWidth + value.translation.width
                        sidebarWidth = min(max(newWidth, 260), 500)
                    }
                    .onEnded { _ in dragBaseWidth = 0 }
            )
    }

    private var detailPanel: some View {
        ZStack(alignment: .topLeading) {
            detailView
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(sidebarCollapsed ? "Show sidebar" : "Hide sidebar")
            .padding(8)
        }
    }

    private var footerView: some View {
        HStack(spacing: 6) {
            Text("\(groups.reduce(0) { $0 + $1.count }) sessions")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if !showingTrash {
                Button {
                    Task {
                        if let n = try? db.hideEmptySessions(), n > 0 {
                            await loadGroups()
                        }
                    }
                } label: {
                    Text("Clean Empty")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Button {
                showingTrash.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: showingTrash ? "trash.fill" : "trash")
                    if hiddenCount > 0 {
                        Text("\(hiddenCount)")
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(showingTrash ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                .foregroundStyle(showingTrash ? .red : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var detailView: some View {
        Group {
            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 200)
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Select a session to view its conversation.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var renameAlertContent: some View {
        Group {
            TextField("Note", text: $renameText)
            Button("Save") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespaces)
                try? db.renameSession(id: target.id, name: name.isEmpty ? nil : name)
                renameTarget = nil
                refreshTrigger = UUID()
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Actions

    private func toggleGroup(_ groupId: String) {
        if expandedGroups.contains(groupId) {
            expandedGroups.remove(groupId)
        } else {
            expandedGroups.insert(groupId)
        }
    }

    private func deleteSession(_ id: String) {
        if showingTrash {
            try? db.unhideSession(id: id)
        } else {
            try? db.hideSession(id: id)
        }
        refreshTrigger = UUID()
        Task { await loadGroups() }
    }

    private func handleDeepLink(_ session: Session?) {
        guard let session else { return }
        pendingSelection = session
        selectedSourcesStr = ""
        selectedProjectsStr = ""
        agentFilterMode = 0
        deepLinkSession = nil

        Task {
            await loadGroups()
            let groupKey = groupingMode == .project
                ? (session.project ?? "(unknown)")
                : session.source
            expandedGroups.insert(groupKey)
            selectedSession = session
            pendingSelection = nil
        }
    }

    // MARK: - Data Loading

    private func loadGroups() async {
        hiddenCount = (try? db.countHiddenSessions()) ?? 0

        if showingTrash {
            groups = []
            return
        }

        let sort: SessionSort = switch (sortField, sortAsc) {
        case (.created, false): .createdDesc
        case (.created, true):  .createdAsc
        case (.updated, false): .updatedDesc
        case (.updated, true):  .updatedAsc
        }

        do {
            let dbGroups = try db.listGroups(
                by: groupingMode,
                sources: selectedSources,
                projects: selectedProjects,
                subAgent: agentFilter,
                sort: sort
            )
            groups = dbGroups.map { GroupInfo(id: $0.key, count: $0.count, lastUpdated: $0.lastUpdated) }
        } catch {
            print("[SessionListView] error loading groups:", error)
            groups = []
        }
    }

    // MARK: - Sort Button

    @ViewBuilder
    private func sortButton(_ label: LocalizedStringKey, field: SortField) -> some View {
        let active = sortField == field
        Button {
            if active {
                sortAsc.toggle()
            } else {
                sortField = field
                sortAsc = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: active ? (sortAsc ? "arrow.up" : "arrow.down") : "arrow.up.arrow.down")
                    .opacity(active ? 1 : 0.3)
            }
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group Section

struct GroupSection: View {
    let group: SessionListView.GroupInfo
    let groupingMode: GroupingMode
    let isExpanded: Bool
    @Binding var selectedSession: Session?
    let showingTrash: Bool
    @Binding var sortField: SortField
    @Binding var sortAsc: Bool
    let selectedSources: Set<String>
    let selectedProjects: Set<String>
    let agentFilter: Bool?
    let refreshTrigger: UUID
    let onToggle: () -> Void
    let onDelete: (String) -> Void
    let onRename: (Session) -> Void
    var onGroupRenamed: (() -> Void)?

    @EnvironmentObject var db: DatabaseManager
    @State private var sessions: [Session] = []
    @State private var isLoading = false
    @State private var groupFilterTask: Task<Void, Never>?
    @State private var showRenameGroup = false
    @State private var renameGroupText = ""
    @State private var moveTarget: Session?
    @State private var moveProjectText = ""
    @State private var availableProjects: [String] = []

    private var groupFilterFingerprint: String {
        "\(sortField)-\(sortAsc)-\(selectedSources)-\(selectedProjects)-\(String(describing: agentFilter))-\(refreshTrigger)"
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { isExpanded },
                set: { _ in onToggle() }
            )
        ) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else if sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                        .tag(session)
                        .contentShape(Rectangle())
                        .background(selectedSession?.id == session.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .onTapGesture {
                            selectedSession = session
                        }
                        .contextMenu {
                            if showingTrash {
                                Button("Restore") { onDelete(session.id) }
                            } else {
                                Button("Rename...") { onRename(session) }
                                Menu("Move to Project") {
                                    ForEach(availableProjects.filter { $0 != session.project }, id: \.self) { proj in
                                        Button(proj) {
                                            try? db.moveSessionToProject(id: session.id, project: proj)
                                            onGroupRenamed?()
                                        }
                                    }
                                    Divider()
                                    Button("Other...") {
                                        moveTarget = session
                                        moveProjectText = session.project ?? ""
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { onDelete(session.id) }
                            }
                        }
                }
            }
        } label: {
            GroupHeader(
                title: group.id,
                count: group.count,
                icon: groupingMode == .project ? "folder" : "cpu",
                lastUpdated: String(group.lastUpdated.prefix(10))
            )
            .contextMenu {
                if groupingMode == .project && group.id != "(unknown)" {
                    Button("Rename Project...") {
                        renameGroupText = group.id
                        showRenameGroup = true
                    }
                }
            }
        }
        .alert("Rename Project", isPresented: $showRenameGroup) {
            TextField("Project name", text: $renameGroupText)
            Button("Save") {
                let newName = renameGroupText.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty, newName != group.id else { return }
                try? db.renameProject(from: group.id, to: newName)
                onGroupRenamed?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename all sessions in \"\(group.id)\" to a new project name.")
        }
        .alert("Move to Project", isPresented: Binding(
            get: { moveTarget != nil },
            set: { if !$0 { moveTarget = nil } }
        )) {
            TextField("Project name", text: $moveProjectText)
            Button("Move") {
                guard let session = moveTarget else { return }
                let newProject = moveProjectText.trimmingCharacters(in: .whitespaces)
                guard !newProject.isEmpty else { return }
                try? db.moveSessionToProject(id: session.id, project: newProject)
                moveTarget = nil
                onGroupRenamed?()
            }
            Button("Cancel", role: .cancel) { moveTarget = nil }
        } message: {
            Text("Move this session to a different project.")
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && sessions.isEmpty && !isLoading {
                loadSessions()
            }
            if expanded && availableProjects.isEmpty {
                availableProjects = ((try? db.countsByProject())?.keys.sorted()) ?? []
            }
        }
        .onChange(of: groupFilterFingerprint) { _, _ in
            guard isExpanded else { return }
            groupFilterTask?.cancel()
            groupFilterTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                loadSessions()
            }
        }
        .onAppear {
            if isExpanded && sessions.isEmpty && !isLoading {
                loadSessions()
            }
        }
    }

    private func loadSessions() {
        isLoading = true
        Task {
            let sort: SessionSort = switch (sortField, sortAsc) {
            case (.created, false): .createdDesc
            case (.created, true):  .createdAsc
            case (.updated, false): .updatedDesc
            case (.updated, true):  .updatedAsc
            }

            let loadedSessions = (try? db.listSessionsInGroup(
                by: groupingMode,
                key: group.id,
                sources: selectedSources,
                projects: selectedProjects,
                subAgent: agentFilter,
                sort: sort
            )) ?? []

            await MainActor.run {
                self.sessions = loadedSessions
                self.isLoading = false
            }
        }
    }
}

// MARK: - Supporting Views

struct MultiSelectPicker: View {
    let emptyLabel: LocalizedStringKey
    let icon: String
    let items: [String]
    @Binding var selected: Set<String>
    var colorForItem: ((String) -> Color)? = nil
    var labelForItem: ((String) -> String)? = nil
    @State private var showPopover = false

    var isFiltered: Bool { !selected.isEmpty }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
                buttonText
                    .lineLimit(1)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isFiltered
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            pickerPopover
        }
    }

    @ViewBuilder
    private var buttonText: some View {
        switch selected.count {
        case 0:  Text(emptyLabel)
        case 1:
            let item = selected.first!
            Text(verbatim: labelForItem?(item) ?? item)
        default: Text("\(selected.count) selected")
        }
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFiltered {
                Button {
                    selected = []
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear Filter")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if items.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(items, id: \.self) { item in
                            let isSelected = selected.contains(item)
                            Button {
                                if isSelected { selected.remove(item) } else { selected.insert(item) }
                            } label: {
                                HStack(spacing: 8) {
                                    if let colorFn = colorForItem {
                                        Circle()
                                            .fill(colorFn(item))
                                            .frame(width: 8, height: 8)
                                    }
                                    Text(verbatim: labelForItem?(item) ?? item)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(isSelected
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 200)
    }
}

struct Chip: View {
    let label: LocalizedStringKey
    let selected: Bool
    var color: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? color : Color.secondary.opacity(0.15))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct GroupHeader: View {
    let title: String
    let count: Int
    let icon: String
    let lastUpdated: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .fontWeight(.medium)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            Text(lastUpdated)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct SessionRow: View {
    let session: Session

    private var sourceColor: Color { SourceDisplay.color(for: session.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(verbatim: session.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if session.sizeCategory != .normal {
                    HStack(spacing: 2) {
                        if session.sizeCategory == .huge {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                        }
                        Text(session.formattedSize)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .foregroundStyle(session.sizeCategory == .huge ? .red : .orange)
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(sourceColor)
                    .frame(width: 7, height: 7)
                Text(verbatim: session.project ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if session.isSubAgent {
                    Text("agent")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(verbatim: SourceDisplay.label(for: session.source))
                    .font(.caption)
                    .foregroundStyle(sourceColor)
                Text(verbatim: session.displayDate)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                Text(session.msgCountLabel)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
