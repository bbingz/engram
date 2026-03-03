// macos/Engram/Views/SessionListView.swift
import SwiftUI
import Combine

enum SortField: String { case created, updated }

struct SessionListView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var groupingMode: GroupingMode = .project
    @State private var groups: [GroupInfo] = []
    @State private var expandedGroups: Set<String> = []
    @State private var sessionsByGroup: [String: [Session]] = [:]
    @State private var selectedSession: Session?
    @State private var selectedSources: Set<String> = []
    @State private var selectedProjects: Set<String> = []
    @State private var agentFilter: Bool? = false
    @State private var sortField: SortField = .created
    @State private var sortAsc = false
    @State private var pendingSelection: Session?
    @Binding var deepLinkSession: Session?
    @State private var renameTarget: Session?
    @State private var renameText: String = ""
    @State private var showingTrash = false
    @State private var hiddenCount: Int = 0

    let allSources = ["claude-code", "codex", "cursor", "gemini-cli",
                      "opencode", "iflow", "qwen", "kimi", "cline",
                      "vscode", "antigravity", "windsurf"]

    struct GroupInfo: Identifiable {
        let id: String
        let count: Int
        let lastUpdated: String
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Filter bar
                HStack(spacing: 6) {
                    MultiSelectPicker(
                        emptyLabel: "All sources",
                        icon: "cpu",
                        items: allSources,
                        selected: $selectedSources
                    )
                    MultiSelectPicker(
                        emptyLabel: "All projects",
                        icon: "folder",
                        items: (try? db.listProjects()) ?? [],
                        selected: $selectedProjects
                    )
                    Spacer()
                    Picker("", selection: $groupingMode) {
                        ForEach(GroupingMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode == .project ? "folder" : "cpu")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Filter chips + Sort buttons
                HStack(spacing: 6) {
                    Chip(label: "All",         selected: agentFilter == nil,   color: .secondary) { agentFilter = nil }
                    Chip(label: "Agent only",  selected: agentFilter == true,  color: .purple)    { agentFilter = true }
                    Chip(label: "Hide agents", selected: agentFilter == false, color: .orange)    { agentFilter = false }
                    Spacer()
                    sortButton("Created", field: .created)
                    sortButton("Updated", field: .updated)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider()

                // List with explicit ID for forcing refresh
                List {
                    ForEach(groups) { group in
                        GroupSection(
                            group: group,
                            groupingMode: groupingMode,
                            sessions: sessionsByGroup[group.id] ?? [],
                            isExpanded: expandedGroups.contains(group.id),
                            selectedSession: $selectedSession,
                            showingTrash: showingTrash,
                            onToggle: { toggleGroup(group.id) },
                            onDelete: { id in deleteSession(id) },
                            onRename: { session in renameTarget = session; renameText = session.customName ?? session.summary ?? "" }
                        )
                    }
                }
                .listStyle(.inset)
                .id("\(groupingMode)_\(sortField)_\(sortAsc)_\(selectedSources.count)_\(selectedProjects.count)_\(agentFilter?.description ?? "nil")")

                // Footer
                footerView
            }
            .frame(minWidth: 260, maxWidth: 500)

            detailView
        }
        .task { await loadGroups() }
        .onChange(of: groupingMode) { _, _ in
            expandedGroups = []
            sessionsByGroup = [:]
            Task { await loadGroups() }
        }
        .onChange(of: selectedSources) { _, _ in
            expandedGroups = []
            sessionsByGroup = [:]
            Task { await loadGroups() }
        }
        .onChange(of: selectedProjects) { _, _ in
            expandedGroups = []
            sessionsByGroup = [:]
            Task { await loadGroups() }
        }
        .onChange(of: agentFilter) { _, _ in
            expandedGroups = []
            sessionsByGroup = [:]
            Task { await loadGroups() }
        }
        .onChange(of: sortField) { _, _ in
            sessionsByGroup = [:]
            Task { await reloadExpandedGroups() }
        }
        .onChange(of: sortAsc) { _, _ in
            sessionsByGroup = [:]
            Task { await reloadExpandedGroups() }
        }
        .onChange(of: showingTrash) { _, _ in
            Task { await loadGroups() }
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

    private var footerView: some View {
        HStack(spacing: 6) {
            Text("\(groups.reduce(0) { $0 + $1.count }) sessions")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if !showingTrash {
                Button {
                    if let n = try? db.hideEmptySessions(), n > 0 {
                        Task { await loadGroups() }
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
                Task {
                    await reloadExpandedGroups()
                }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Actions

    private func toggleGroup(_ groupId: String) {
        if expandedGroups.contains(groupId) {
            expandedGroups.remove(groupId)
            sessionsByGroup.removeValue(forKey: groupId)
        } else {
            expandedGroups.insert(groupId)
            Task {
                await loadSessions(for: groupId)
            }
        }
    }

    private func deleteSession(_ id: String) {
        if showingTrash {
            try? db.unhideSession(id: id)
        } else {
            try? db.hideSession(id: id)
        }
        Task { await loadGroups() }
    }

    private func handleDeepLink(_ session: Session?) {
        guard let session else { return }
        pendingSelection = session
        selectedSources = []
        selectedProjects = []
        agentFilter = nil
        deepLinkSession = nil

        Task {
            await loadGroups()
            let groupKey = groupingMode == .project
                ? (session.project ?? "(unknown)")
                : session.source
            expandedGroups.insert(groupKey)
            await loadSessions(for: groupKey)
            selectedSession = session
            pendingSelection = nil
        }
    }

    // MARK: - Data Loading

    private func loadGroups() async {
        hiddenCount = (try? db.countHiddenSessions()) ?? 0

        if showingTrash {
            groups = []
            sessionsByGroup = [:]
            return
        }

        let dbGroups = (try? db.listGroups(
            by: groupingMode,
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter
        )) ?? []

        groups = dbGroups.map { GroupInfo(id: $0.key, count: $0.count, lastUpdated: $0.lastUpdated) }
    }

    private func loadSessions(for groupId: String) async {
        let sort: SessionSort = switch (sortField, sortAsc) {
        case (.created, false): .createdDesc
        case (.created, true):  .createdAsc
        case (.updated, false): .updatedDesc
        case (.updated, true):  .updatedAsc
        }

        let sessions = (try? db.listSessionsInGroup(
            by: groupingMode,
            key: groupId,
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            sort: sort
        )) ?? []

        sessionsByGroup[groupId] = sessions
    }

    private func reloadExpandedGroups() async {
        // Reload all expanded groups with new sort order
        for groupId in expandedGroups {
            await loadSessions(for: groupId)
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
    let sessions: [Session]
    let isExpanded: Bool
    @Binding var selectedSession: Session?
    let showingTrash: Bool
    let onToggle: () -> Void
    let onDelete: (String) -> Void
    let onRename: (Session) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: .constant(isExpanded)
        ) {
            if sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                        .tag(session)
                        .background(selectedSession?.id == session.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .onTapGesture {
                            selectedSession = session
                        }
                        .contextMenu {
                            if showingTrash {
                                Button("Restore") { onDelete(session.id) }
                            } else {
                                Button("Rename...") { onRename(session) }
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
        }
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Supporting Views

struct MultiSelectPicker: View {
    let emptyLabel: LocalizedStringKey
    let icon: String
    let items: [String]
    @Binding var selected: Set<String>
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
        case 1:  Text(verbatim: selected.first!)
        default: Text("\(selected.count) selected")
        }
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFiltered {
                Button("Clear") { selected = [] }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            if items.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            let isSelected = selected.contains(item)
                            Button {
                                if isSelected { selected.remove(item) } else { selected.insert(item) }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(verbatim: item)
                                        .font(.caption)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 280)
            }
        }
        .frame(minWidth: 180, maxWidth: 240)
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

    private var sourceColor: Color {
        switch session.source {
        case "claude-code":  return .orange
        case "codex":        return .green
        case "cursor":       return .blue
        case "gemini-cli", "antigravity": return .cyan
        case "opencode":     return .indigo
        case "iflow":        return .purple
        case "qwen":        return .teal
        case "kimi":        return .pink
        case "cline":       return .mint
        case "windsurf":    return .brown
        default:            return .gray
        }
    }

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
                Text(verbatim: session.source)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if session.isSubAgent {
                    Text("agent")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(verbatim: session.displayDate)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                Text("\(session.messageCount) msgs")
                if let proj = session.project {
                    Text(verbatim: "·")
                    Image(systemName: "folder")
                        .imageScale(.small)
                    Text(verbatim: proj).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
