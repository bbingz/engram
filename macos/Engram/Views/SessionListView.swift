// macos/Engram/Views/SessionListView.swift
import SwiftUI

enum SortField: String { case created, updated }

struct SessionListView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var groupingMode: GroupingMode = .project
    @State private var groups: [(key: String, count: Int, lastUpdated: String)] = []
    @State private var expandedGroups: Set<String> = []
    @State private var groupSessions: [String: [Session]] = [:]
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
    @State private var sortVersion: Int = 0  // Used to force refresh

    let allSources = ["claude-code", "codex", "cursor", "gemini-cli",
                      "opencode", "iflow", "qwen", "kimi", "cline",
                      "vscode", "antigravity", "windsurf"]

    func getCurrentSort() -> SessionSort {
        switch (sortField, sortAsc) {
        case (.created, false): return .createdDesc
        case (.created, true):  return .createdAsc
        case (.updated, false): return .updatedDesc
        case (.updated, true):  return .updatedAsc
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Row 1: Source picker | Project picker | Grouping mode toggle
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
                    // Grouping mode toggle
                    Picker("", selection: $groupingMode) {
                        ForEach(GroupingMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode == .project ? "folder" : "cpu")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .help("Group by project or source")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Row 2: Agent filter + Sort buttons
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

                // Grouped list
                List {
                    ForEach(groups, id: \.key) { group in
                        let key = group.key
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedGroups.contains(key) },
                                set: { open in
                                    if open {
                                        expandedGroups.insert(key)
                                        Task { await loadSessions(for: key) }
                                    } else {
                                        expandedGroups.remove(key)
                                    }
                                }
                            )
                        ) {
                            if let sessions = groupSessions[key] {
                                if sessions.isEmpty {
                                    Text("No sessions")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.vertical, 4)
                                } else {
                                    ForEach(sessions, id: \.id) { session in
                                        SessionRow(session: session)
                                            .tag(session)
                                            .background(selectedSession?.id == session.id ? Color.accentColor.opacity(0.1) : Color.clear)
                                            .onTapGesture {
                                                selectedSession = session
                                            }
                                            .contextMenu {
                                                if showingTrash {
                                                    Button("Restore") {
                                                        try? db.unhideSession(id: session.id)
                                                        Task { await reload() }
                                                    }
                                                } else {
                                                    Button("Rename...") {
                                                        renameText = session.customName ?? session.summary ?? ""
                                                        renameTarget = session
                                                    }
                                                    Divider()
                                                    Button("Delete", role: .destructive) {
                                                        try? db.hideSession(id: session.id)
                                                        Task { await reload() }
                                                    }
                                                }
                                            }
                                    }
                                }
                            } else {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 4)
                            }
                        } label: {
                            GroupHeader(
                                title: group.key,
                                count: group.count,
                                icon: groupingMode == .project ? "folder" : "cpu",
                                lastUpdated: String(group.lastUpdated.prefix(10))
                            )
                        }
                    }
                }
                .listStyle(.inset)

                // Footer: count + clean empty + trash
                HStack(spacing: 6) {
                    let totalSessions = groups.reduce(0) { $0 + $1.count }
                    Text("\(totalSessions) sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if !showingTrash {
                        Button {
                            if let n = try? db.hideEmptySessions(), n > 0 {
                                Task { await reload() }
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
                        .help("Hide all sessions with 0 messages")
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
                    .help(showingTrash ? "Back to sessions" : "Show hidden sessions")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 260, maxWidth: 500)

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
        .task {
            await reload()
        }
        .task(id: selectedSources)  { await reload() }
        .task(id: selectedProjects) { await reload() }
        .task(id: agentFilter)      { await reload() }
        .task(id: groupingMode)     { await reload() }
        .task(id: sortVersion)      { await reload() }
        .task(id: showingTrash)     { await reload() }
        .onChange(of: deepLinkSession) { _, session in
            guard let session else { return }
            pendingSelection = session
            selectedSources = []
            selectedProjects = []
            agentFilter = nil
            deepLinkSession = nil
        }
        .onChange(of: pendingSelection?.id) { _, _ in
            guard let pending = pendingSelection else { return }
            // Find which group contains this session
            Task {
                // Reload to ensure we have the latest data
                await reload()
                // Try to find and expand the group
                if let groupKey = findGroupKey(for: pending) {
                    expandedGroups.insert(groupKey)
                    await loadSessions(for: groupKey)
                    selectedSession = pending
                    pendingSelection = nil
                }
            }
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Note", text: $renameText)
            Button("Save") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespaces)
                try? db.renameSession(id: target.id, name: name.isEmpty ? nil : name)
                renameTarget = nil
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Displayed as: note | original title. Leave empty to clear.")
        }
    }

    func findGroupKey(for session: Session) -> String? {
        switch groupingMode {
        case .project:
            return session.project ?? "(unknown)"
        case .source:
            return session.source
        }
    }

    func reload() async {
        hiddenCount = (try? db.countHiddenSessions()) ?? 0
        if showingTrash {
            // Trash view doesn't use grouping
            groups = []
            expandedGroups = []
            groupSessions = [:]
            // Handle trash view separately if needed
        } else {
            groups = (try? db.listGroups(
                by: groupingMode,
                sources: selectedSources,
                projects: selectedProjects,
                subAgent: agentFilter
            )) ?? []

            // IMPORTANT: Clear cached sessions first to force SwiftUI to re-render
            // This must happen BEFORE loading new data
            let keysToReload = Array(expandedGroups)
            groupSessions = [:]  // Clear all cached sessions

            // Re-load sessions for all expanded groups with new sort order
            for groupKey in keysToReload {
                if let sessions = try? db.listSessionsInGroup(
                    by: groupingMode,
                    key: groupKey,
                    sources: selectedSources,
                    projects: selectedProjects,
                    subAgent: agentFilter,
                    sort: getCurrentSort()
                ) {
                    groupSessions[groupKey] = sessions
                }
            }
        }
    }

    func loadSessions(for groupKey: String) async {
        guard groupSessions[groupKey] == nil else { return }
        groupSessions[groupKey] = (try? db.listSessionsInGroup(
            by: groupingMode,
            key: groupKey,
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            sort: getCurrentSort()
        )) ?? []
    }

    @ViewBuilder
    func sortButton(_ label: LocalizedStringKey, field: SortField) -> some View {
        let active = sortField == field
        Button {
            if active {
                sortAsc.toggle()
            } else {
                sortField = field
                sortAsc = false
            }
            sortVersion += 1  // Trigger refresh
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

// MARK: - MultiSelectPicker

struct MultiSelectPicker: View {
    let emptyLabel: LocalizedStringKey
    let icon: String
    let items: [String]
    @Binding var selected: Set<String>
    @State private var showPopover = false

    var isFiltered: Bool { !selected.isEmpty }

    @ViewBuilder
    var buttonText: some View {
        switch selected.count {
        case 0:  Text(emptyLabel)
        case 1:  Text(verbatim: selected.first!)
        default: Text("\(selected.count) selected")
        }
    }

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
                                let on = selected.contains(item)
                                Button {
                                    if on { selected.remove(item) } else { selected.insert(item) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(verbatim: item)
                                            .font(.caption)
                                            .foregroundStyle(on ? Color.accentColor : Color.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        if on {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(on ? Color.accentColor.opacity(0.08) : Color.clear)
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
}

// MARK: - Chip

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

// MARK: - GroupHeader

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

// MARK: - SessionRow (unchanged from original)

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
            // Line 1: title + size warning
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

            // Line 2: source dot + source name + agent badge + date
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

            // Line 3: message count + project
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
