// macos/Engram/Views/SessionListView.swift
import SwiftUI

struct SessionListView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Binding var deepLinkSession: Session?

    // MARK: - Persisted state
    @AppStorage("selectedSourcesStr") private var selectedSourcesStr: String = ""
    @AppStorage("selectedProjectsStr") private var selectedProjectsStr: String = ""
    @AppStorage("agentFilterMode") private var agentFilterMode: Int = 2  // 0=all, 1=agents, 2=hide
    // Persisted table sort + project filter so they survive app restarts.
    @AppStorage("sessionsSelectedProject") private var persistedProject: String = ""
    @AppStorage("sessionsSortKey") private var persistedSortKey: String = "startTime"
    @AppStorage("sessionsSortAscending") private var persistedSortAscending: Bool = false

    // MARK: - Local state
    @State private var sessions: [Session] = []
    @State private var selectedSessionId: String?
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
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
    @State private var loadGeneration = 0
    /// Cached session to hold detail panel steady during reloads
    @State private var lastSelectedSession: Session?

    @State private var columnStore = ColumnVisibilityStore()
    // Bumped when a column toggles so the table re-reads the (Observation-
    // ignored, AppStorage-backed) visibility flags. Cheap: re-renders the
    // already-loaded table, no data reload.
    @State private var columnRevision = 0
    @State private var loadError: String? = nil

    @ViewBuilder
    private var columnsMenu: some View {
        Menu {
            Toggle("Favorite", isOn: columnBinding(\.favorite))
            Toggle("Agent", isOn: columnBinding(\.agent))
            Toggle("Title", isOn: columnBinding(\.title))
            Toggle("Date", isOn: columnBinding(\.date))
            Toggle("Project", isOn: columnBinding(\.project))
            Toggle("Msgs", isOn: columnBinding(\.msgs))
            Toggle("Size", isOn: columnBinding(\.size))
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show or hide table columns")
    }

    private func columnBinding(_ keyPath: ReferenceWritableKeyPath<ColumnVisibilityStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { columnStore[keyPath: keyPath] },
            set: { columnStore[keyPath: keyPath] = $0; columnRevision += 1 }
        )
    }

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

    // MARK: - Persisted sort/project

    private func restorePersistedSortAndProject() {
        selectedProject = persistedProject.isEmpty ? nil : persistedProject
        sortOrder = [Self.comparator(forKey: persistedSortKey, ascending: persistedSortAscending)]
    }

    static func comparator(forKey key: String, ascending: Bool) -> KeyPathComparator<Session> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch key {
        case "source":       return .init(\.source, order: order)
        case "displayTitle": return .init(\.displayTitle, order: order)
        case "messageCount": return .init(\.messageCount, order: order)
        case "sizeBytes":    return .init(\.sizeBytes, order: order)
        default:             return .init(\.startTime, order: order)
        }
    }

    static func sortKey(for comparator: KeyPathComparator<Session>) -> String {
        let kp = comparator.keyPath
        if kp == \Session.source { return "source" }
        if kp == \Session.displayTitle { return "displayTitle" }
        if kp == \Session.messageCount { return "messageCount" }
        if kp == \Session.sizeBytes { return "sizeBytes" }
        return "startTime"
    }

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
        .onChange(of: selectedProject) { _, new in
            updateFilteredSessions()
            persistedProject = new ?? ""
        }
        .onChange(of: sortOrder) { _, new in
            updateFilteredSessions()
            if let first = new.first {
                persistedSortKey = Self.sortKey(for: first)
                persistedSortAscending = first.order == .forward
            }
        }
        .onAppear(perform: restorePersistedSortAndProject)
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

                // Column visibility — only meaningful for the flat table view.
                if agentFilterMode == 1 {
                    columnsMenu
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if let loadError {
                AlertBanner(message: "Failed to load sessions: \(loadError)")
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            // Session list
            if filteredSessions.isEmpty && !sessions.isEmpty {
                EmptyState(icon: "line.3.horizontal.decrease.circle", title: "No matches", message: "No sessions match your current filters")
            } else if sessions.isEmpty && !isChurning {
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
                    Spacer()
                }
                .padding(.horizontal, 10)
            } else if agentFilterMode == 1 {
                // Agents only: flat table view (dedicated agent browsing)
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
                .id(columnRevision)
            } else {
                // All (0) and Hide (2): expandable grouped view
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSessions) { session in
                            ExpandableSessionCard(
                                session: session,
                                confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                onTap: { selectSession(session) },
                                onChildTap: { child in selectSession(child) },
                                onConfirmSuggestion: { child in confirmSuggestion(child) },
                                onDismissSuggestion: { child in dismissSuggestion(child) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
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
                        if let response = try? await serviceClient.hideEmptySessions(),
                           response.hiddenCount > 0 {
                            await loadSessions()
                            updateFilteredSessions()
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
            // UI-H3: trash toggle is icon-only — give VoiceOver a label + state.
            .accessibilityLabel(showingTrash ? "Showing trash" : "Show trash")
            .accessibilityValue(hiddenCount > 0 ? "\(hiddenCount) hidden" : "")
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
                Task {
                    try? await serviceClient.renameSession(
                        sessionId: target.id,
                        name: name.isEmpty ? nil : name
                    )
                    renameTarget = nil
                    refreshTrigger = UUID()
                    await loadSessions()
                    updateFilteredSessions()
                }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Data loading

    private func loadSessions() async {
        // UI-C1/C2: run the synchronous GRDB reads + child-count IN-queries off the
        // main thread. `readInBackground` runs `pool.read` on the calling thread, so
        // calling these directly from a @MainActor func froze the UI on a large DB.
        loadGeneration += 1
        let generation = loadGeneration
        let db = self.db
        let showingTrash = self.showingTrash
        let agentFilter = self.agentFilter
        let useTopLevel = agentFilterMode != 1 // top-level only except "agents only" mode
        do {
            let loaded = try await Task.detached {
                let hidden = (try? db.countHiddenSessions()) ?? 0
                let sessions: [Session] = showingTrash
                    ? ((try? db.listHiddenSessions(limit: 500)) ?? [])
                    : try db.listSessions(
                        subAgent: agentFilter,
                        topLevelOnly: useTopLevel,
                        limit: 2000
                    )
                let ids = sessions.map(\.id)
                let confirmed = (try? db.childCount(parentIds: ids)) ?? [:]
                let suggested = (try? db.suggestedChildCount(parentIds: ids)) ?? [:]
                return (hidden, sessions, confirmed, suggested)
            }.value
            guard loadGeneration == generation else { return }
            hiddenCount = loaded.0
            sessions = loaded.1
            confirmedCounts = loaded.2
            suggestedCounts = loaded.3
            loadError = nil
        } catch {
            guard loadGeneration == generation else { return }
            EngramLogger.error("SessionListView load failed", module: .ui, error: error)
            sessions = []
            confirmedCounts = [:]
            suggestedCounts = [:]
            loadError = error.localizedDescription
        }

        // Refresh cached selection after reload
        if let id = selectedSessionId,
           let fresh = sessions.first(where: { $0.id == id }) {
            lastSelectedSession = fresh
        }
    }

    private func loadFavorites() async {
        let db = self.db
        let favs = await Task.detached { (try? db.listFavorites()) ?? [] }.value
        favoriteIds = Set(favs.map(\.id))
    }

    // MARK: - Actions

    private func toggleFavorite(id: String, current: Bool) {
        Task {
            let next = !current
            do {
                try await serviceClient.setFavorite(sessionId: id, favorite: next)
                if next {
                    favoriteIds.insert(id)
                } else {
                    favoriteIds.remove(id)
                }
            } catch {
                EngramLogger.error("SessionListView favorite update failed", module: .ui, error: error)
            }
        }
    }

    private func deleteSession(_ id: String) {
        Task {
            do {
                try await serviceClient.setSessionHidden(sessionId: id, hidden: !showingTrash)
                refreshTrigger = UUID()
                await loadSessions()
                updateFilteredSessions()
            } catch {
                EngramLogger.error("SessionListView hidden-state update failed", module: .ui, error: error)
            }
        }
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

    private func selectSession(_ session: Session) {
        selectedSessionId = session.id
    }

    private func confirmSuggestion(_ child: Session) {
        Task {
            _ = try? await serviceClient.confirmSuggestion(sessionId: child.id)
            await loadSessions()
            updateFilteredSessions()
        }
    }

    private func dismissSuggestion(_ child: Session) {
        Task {
            if let suggestedId = child.suggestedParentId {
                try? await serviceClient.dismissSuggestion(
                    sessionId: child.id,
                    suggestedParentId: suggestedId
                )
            }
            await loadSessions()
            updateFilteredSessions()
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
