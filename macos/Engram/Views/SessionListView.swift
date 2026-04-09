// macos/Engram/Views/SessionListView.swift
import SwiftUI

struct SessionListView: View {
    @Environment(DatabaseManager.self) var db
    @Binding var deepLinkSession: Session?

    // MARK: - Persisted state
    @AppStorage("selectedSourcesStr") private var selectedSourcesStr: String = ""
    @AppStorage("selectedProjectsStr") private var selectedProjectsStr: String = ""
    @AppStorage("agentFilterMode") private var agentFilterMode: Int = 2  // 0=all, 1=agents, 2=hide

    // MARK: - Local state
    @State private var sessions: [Session] = []
    @State private var selectedSessionId: String?
    @State private var sortOrder: [KeyPathComparator<Session>] = [
        .init(\.startTime, order: .reverse)
    ]
    @State private var selectedProject: String?
    @State private var favoriteIds: Set<String> = []
    @State private var hiddenCount: Int = 0
    @State private var showingTrash = false
    @State private var renameTarget: Session?
    @State private var renameText: String = ""
    @State private var refreshTrigger = UUID()
    @State private var filterTask: Task<Void, Never>?
    @State private var isChurning = false
    /// Cached session to hold detail panel steady during reloads
    @State private var lastSelectedSession: Session?

    @State private var columnStore = ColumnVisibilityStore()

    // MARK: - Derived bindings

    private var selectedSources: Set<String> {
        selectedSourcesStr.isEmpty ? [] : Set(selectedSourcesStr.components(separatedBy: "\t"))
    }
    private var selectedSourcesBinding: Binding<Set<String>> {
        Binding(
            get: { selectedSources },
            set: { selectedSourcesStr = $0.sorted().joined(separator: "\t") }
        )
    }

    private var agentFilter: Bool? {
        agentFilterMode == 0 ? nil : agentFilterMode == 1 ? true : false
    }

    // MARK: - Cached derived state

    @State private var sourceCounts: [(source: String, count: Int)] = []
    @State private var projectList: [(name: String, count: Int)] = []
    @State private var filteredSessions: [Session] = []

    /// Recompute filtered sessions and derived counts from current state
    private func updateFilteredSessions() {
        // Recompute source counts and project list from full sessions
        let countsBySource = Dictionary(grouping: sessions, by: \.source).mapValues(\.count)
        sourceCounts = countsBySource.sorted { $0.value > $1.value }
            .map { (source: $0.key, count: $0.value) }
        let countsByProject = Dictionary(grouping: sessions.compactMap(\.project), by: { $0 }).mapValues(\.count)
        projectList = countsByProject.sorted { $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }

        var result = sessions
        if !selectedSources.isEmpty {
            result = result.filter { selectedSources.contains($0.source) }
        }
        if let proj = selectedProject {
            result = result.filter { $0.project == proj }
        }
        filteredSessions = result.sorted(using: sortOrder)
    }

    /// Selected session object — falls back to cached session during churning to prevent flicker
    private var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        if let found = sessions.first(where: { $0.id == id }) {
            return found
        }
        // During reload, the session may be temporarily absent — preserve the last selection
        if isChurning {
            return lastSelectedSession
        }
        return nil
    }

    private var filterFingerprint: String {
        "\(agentFilterMode)-\(showingTrash)-\(refreshTrigger)"
    }

    // MARK: - Body

    var body: some View {
        HSplitView {
            sidebarPanel
                .frame(minWidth: 420, idealWidth: 600)
            detailPanel
                .frame(minWidth: 200)
        }
        .task {
            isChurning = true
            await loadSessions()
            updateFilteredSessions()
            isChurning = false
            await loadFavorites()
            if let session = deepLinkSession {
                handleDeepLink(session)
            }
        }
        .onChange(of: filterFingerprint) { _, _ in
            filterTask?.cancel()
            filterTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                isChurning = true
                await loadSessions()
                updateFilteredSessions()
                isChurning = false
            }
        }
        .onChange(of: selectedSessionId) { _, newId in
            if let newId, let session = sessions.first(where: { $0.id == newId }) {
                lastSelectedSession = session
            }
        }
        .onChange(of: selectedSourcesStr) { _, _ in updateFilteredSessions() }
        .onChange(of: selectedProject) { _, _ in updateFilteredSessions() }
        .onChange(of: sortOrder) { _, _ in updateFilteredSessions() }
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

    // MARK: - Sidebar (filter bar + table + footer)

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            // Filter bar: agent pills + project search on same line
            HStack(spacing: 6) {
                AgentFilterBar(
                    sourceCounts: sourceCounts,
                    selectedSources: selectedSourcesBinding
                )

                Spacer()

                // Agent filter chips
                HStack(spacing: 4) {
                    Chip(label: "All",    selected: agentFilterMode == 0, color: .secondary) { agentFilterMode = 0 }
                    Chip(label: "Agents", selected: agentFilterMode == 1, color: .purple)    { agentFilterMode = 1 }
                    Chip(label: "Hide",   selected: agentFilterMode == 2, color: .orange)    { agentFilterMode = 2 }
                }

                ProjectSearchField(
                    allProjects: projectList,
                    selectedProject: $selectedProject
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // Table
            if filteredSessions.isEmpty && !sessions.isEmpty {
                EmptyState(icon: "line.3.horizontal.decrease.circle", title: "No matches", message: "No sessions match your current filters")
            } else if sessions.isEmpty && !isChurning {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
                    Spacer()
                }
                .padding(.horizontal, 10)
            } else {
                SessionTableView(
                    sessions: filteredSessions,
                    selectedSessionId: $selectedSessionId,
                    sortOrder: $sortOrder,
                    columns: columnStore,
                    favoriteIds: favoriteIds,
                    onToggleFavorite: { id, isFav in toggleFavorite(id: id, current: isFav) },
                    onDelete: { id in deleteSession(id) },
                    onRename: { session in renameTarget = session; renameText = session.customName ?? session.summary ?? "" },
                    onFilterProject: { project in selectedProject = project }
                )
            }

            // Footer
            footerView
        }
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        Group {
            if let session = selectedSession {
                SessionDetailView(session: session)
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

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 6) {
            Text("\(filteredSessions.count) sessions")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if !showingTrash {
                Button {
                    Task {
                        if let n = try? db.hideEmptySessions(), n > 0 {
                            await loadSessions()
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

    // MARK: - Rename alert

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

    // MARK: - Data loading

    private func loadSessions() async {
        hiddenCount = (try? db.countHiddenSessions()) ?? 0

        if showingTrash {
            sessions = (try? db.listHiddenSessions(limit: 500)) ?? []
        } else {
            do {
                sessions = try db.listSessions(
                    subAgent: agentFilter,
                    limit: 2000
                )
            } catch {
                print("[SessionListView] error loading sessions:", error)
                sessions = []
            }
        }

        // Refresh cached selection after reload
        if let id = selectedSessionId,
           let fresh = sessions.first(where: { $0.id == id }) {
            lastSelectedSession = fresh
        }
    }

    private func loadFavorites() async {
        let favs = (try? db.listFavorites()) ?? []
        favoriteIds = Set(favs.map(\.id))
    }

    // MARK: - Actions

    private func toggleFavorite(id: String, current: Bool) {
        if current {
            try? db.removeFavorite(sessionId: id)
            favoriteIds.remove(id)
        } else {
            try? db.addFavorite(sessionId: id)
            favoriteIds.insert(id)
        }
    }

    private func deleteSession(_ id: String) {
        if showingTrash {
            try? db.unhideSession(id: id)
        } else {
            try? db.hideSession(id: id)
        }
        refreshTrigger = UUID()
        Task { await loadSessions() }
    }

    private func handleDeepLink(_ session: Session?) {
        guard let session else { return }
        // Clear filters so the session is visible
        selectedSourcesStr = ""
        selectedProjectsStr = ""
        selectedProject = nil
        agentFilterMode = 0
        deepLinkSession = nil

        Task {
            await loadSessions()
            selectedSessionId = session.id
        }
    }
}

// MARK: - Supporting Views (kept for backward compatibility)

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
