// macos/Engram/Views/SessionListView.swift
import SwiftUI

enum SortField: String { case created, updated }

struct SessionListView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var sessions: [Session] = []
    @State private var selectedSession: Session?
    @State private var selectedSources: Set<String> = []
    @State private var selectedProjects: Set<String> = []
    @State private var availableProjects: [String] = []
    @State private var sourceCounts: [String: Int] = [:]
    @State private var projectCounts: [String: Int] = [:]
    @State private var agentFilter: Bool? = false
    @State private var sortField: SortField = .created
    @State private var sortAsc = false
    @State private var pendingSelection: Session?
    @Binding var deepLinkSession: Session?
    @State private var totalCount: Int = 0
    @State private var hasMore = true
    @State private var renameTarget: Session?
    @State private var renameText: String = ""
    private let pageSize = 50

    let allSources = ["claude-code", "codex", "cursor", "gemini-cli",
                      "opencode", "iflow", "qwen", "kimi", "cline",
                      "vscode", "antigravity", "windsurf"]

    var currentSort: SessionSort {
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
                // Row 1: Source picker | Project picker | Sort
                HStack(spacing: 6) {
                    MultiSelectPicker(
                        emptyLabel: "All sources",
                        icon: "cpu",
                        items: allSources,
                        counts: sourceCounts,
                        selected: $selectedSources
                    )
                    MultiSelectPicker(
                        emptyLabel: "All projects",
                        icon: "folder",
                        items: availableProjects,
                        counts: projectCounts,
                        selected: $selectedProjects
                    )
                    Spacer()
                    sortButton("Created", field: .created)
                    sortButton("Updated", field: .updated)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // Row 2: Agent filter
                HStack(spacing: 6) {
                    Chip(label: "All",         selected: agentFilter == nil,   color: .secondary) { agentFilter = nil }
                    Chip(label: "Agent only",  selected: agentFilter == true,  color: .purple)    { agentFilter = true }
                    Chip(label: "Hide agents", selected: agentFilter == false, color: .orange)    { agentFilter = false }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                Divider()

                List(sessions, selection: $selectedSession) { session in
                    SessionRow(session: session)
                        .tag(session)
                        .contextMenu {
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
                        .onAppear {
                            if session == sessions.last && hasMore {
                                Task { await loadMore() }
                            }
                        }
                }

                // Footer: count + clean empty + loading indicator
                HStack {
                    Text("\(sessions.count) of \(totalCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Spacer()
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
                    if hasMore {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 260, maxWidth: 380)

            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 200)
            } else {
                Text("Select a session")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            availableProjects = (try? db.listProjects()) ?? []
            sourceCounts  = (try? db.countsBySource())  ?? [:]
            projectCounts = (try? db.countsByProject()) ?? [:]
            await reload()
        }
        .task(id: selectedSources)  { await reload() }
        .task(id: selectedProjects) { await reload() }
        .task(id: agentFilter)      { await reload() }
        .task(id: sortField)        { await reload() }
        .task(id: sortAsc)          { await reload() }
        .onChange(of: deepLinkSession) { _, session in
            guard let session else { return }
            pendingSelection = session
            selectedSources = []
            selectedProjects = []
            agentFilter = nil
            deepLinkSession = nil
        }
        .task(id: pendingSelection?.id) {
            guard let pending = pendingSelection else { return }
            if sessions.contains(pending) {
                selectedSession = pending
                pendingSelection = nil
            }
        }
        .alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Session name", text: $renameText)
            Button("Rename") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespaces)
                try? db.renameSession(id: target.id, name: name.isEmpty ? nil : name)
                renameTarget = nil
                Task { await reload() }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Enter a new name for this session.")
        }
    }

    func reload() async {
        totalCount = (try? db.countSessions(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter
        )) ?? 0
        sessions = (try? db.listSessions(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            sort: currentSort,
            limit: pageSize
        )) ?? []
        hasMore = sessions.count < totalCount
        if let pending = pendingSelection, sessions.contains(pending) {
            selectedSession = pending
            pendingSelection = nil
        } else if selectedSession == nil || !sessions.contains(selectedSession!) {
            selectedSession = sessions.first
        }
    }

    func loadMore() async {
        guard hasMore else { return }
        let next = (try? db.listSessions(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            sort: currentSort,
            limit: pageSize,
            offset: sessions.count
        )) ?? []
        sessions.append(contentsOf: next)
        hasMore = sessions.count < totalCount
    }

    @ViewBuilder
    func sortButton(_ label: String, field: SortField) -> some View {
        let active = sortField == field
        Button {
            if active { sortAsc.toggle() }
            else { sortField = field; sortAsc = false }
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
    let emptyLabel: String
    let icon: String
    let items: [String]
    var counts: [String: Int] = [:]
    @Binding var selected: Set<String>
    @State private var showPopover = false

    var buttonLabel: String {
        switch selected.count {
        case 0:  return emptyLabel
        case 1:  return selected.first!
        default: return "\(selected.count) selected"
        }
    }
    var isFiltered: Bool { !selected.isEmpty }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
                Text(buttonLabel)
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
                                        Text(item)
                                            .font(.caption)
                                            .foregroundStyle(on ? Color.accentColor : Color.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        if let n = counts[item] {
                                            Text("\(n)")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .monospacedDigit()
                                        }
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
    let label: String
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

// MARK: - SessionRow

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(session.source)
                    .font(.caption2).bold()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if session.isSubAgent {
                    Text("agent")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(session.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    if session.sizeCategory == .huge {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    Text(session.formattedSize)
                        .font(.caption2)
                        .fontWeight(session.sizeCategory != .normal ? .bold : .regular)
                        .foregroundColor(
                            session.sizeCategory == .huge ? .red :
                            session.sizeCategory == .large ? .orange : .gray
                        )
                        .monospacedDigit()
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(session.displayDate)
                if session.displayUpdatedDate != session.displayDate {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Text(session.displayUpdatedDate)
                }
                Text("·")
                Text("\(session.messageCount) msgs")
                if let proj = session.project {
                    Text("·")
                    Text(proj).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
