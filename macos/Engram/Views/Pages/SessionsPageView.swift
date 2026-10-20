// macos/Engram/Views/Pages/SessionsPageView.swift
import SwiftUI

// MARK: - Table row model (agent-sessions-style flattened hierarchy)

/// One row of the sessions table. Parents and (expanded) children interleave in
/// a single flat row array, indented by `depth` — mirroring the agent-sessions
/// pattern of flattening the hierarchy into the same table instead of an
/// outline/nested-card structure.
struct SessionTableRow: Identifiable {
    enum Kind: Equatable { case parent, confirmedChild, suggestedChild }
    let id: String
    let session: Session
    let kind: Kind
    let depth: Int
    /// Sequence position across all rows (parent+children), for UI tests.
    let index: Int
    var hasChildren = false
    var childCount = 0
    var isExpanded = false

    var isSuggestedChild: Bool { kind == .suggestedChild }
}

/// Loaded children of one expanded parent.
struct SessionChildrenBox: Equatable {
    var confirmed: [Session] = []
    var suggested: [Session] = []
}

struct SessionsPageView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @Environment(\.engramFixedDate) var fixedDate
    @AppStorage("sessions.showHidden") private var showHiddenSessions = false
    // Global escape hatch from the human-driven default view. Shared key across
    // SessionsPage / Home / Timeline so one toggle reveals everything everywhere.
    @AppStorage("sessions.showAll") private var showAllSessions = false
    @AppStorage(SessionsFilterPersistence.sessionFilterKey) private var sessionFilterStorage = "All"
    @AppStorage(SessionsFilterPersistence.timeFilterKey) private var timeFilterStorage = "All Time"
    /// Empty string sentinel for Optional source (AppStorage cannot hold String?).
    @AppStorage(SessionsFilterPersistence.sourceFilterKey) private var sourceFilterStorage = ""
    /// Wave 6C-1 (design §9): restrict the list to sessions ingested on the HQ
    /// machine. SQL-side, not post-filter, because the page paginates.
    @AppStorage(SessionsFilterPersistence.hqOnlyKey) private var hqOnly = false

    @State private var sessions: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var totalCount = 0
    @State private var availableSources: [String] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadError: String? = nil
    // Session-action sheet targets + transient status banner.
    @State private var resumeTarget: Session? = nil
    @State private var replayTarget: Session? = nil
    @State private var renameTarget: Session? = nil
    @State private var renameText = ""
    @State private var relateTarget: Session? = nil
    @State private var actionStatus: String? = nil
    @State private var exportState: SessionExportState = .idle
    // Master-detail split state (agent-sessions pattern): raw table selection
    // paints instantly; `settledSession` is the debounced pane target so
    // arrow-key scrubbing through a long list doesn't tear down and rebuild
    // the transcript pane per row.
    @State private var selectedSessionId: String? = nil
    @State private var settledSession: Session? = nil
    // Hierarchy expansion state: expanded parents + their loaded child boxes.
    @State private var expandedParents: Set<String> = []
    @State private var childrenByParent: [String: SessionChildrenBox] = [:]
    @State private var loadingParents: Set<String> = []
    // Filter signature at the last load; distinguishes a filter change (reload
    // immediately from page one) from a background index tick (debounce + keep
    // pagination). See BrowseReloadCoalescer / #3.
    @State private var lastFilterKey: [AnyHashable]? = nil
    /// Bumped on every full load start so a slower favorite-triggered reload for
    /// filter A cannot overwrite a newer filter-B load that already applied.
    @State private var loadGeneration = 0
    /// Tracks the post-favorite reload so a filter change can cancel it.
    @State private var favoriteReloadTask: Task<Void, Never>? = nil

    private let sessionOptions = SessionsFilterPersistence.sessionOptions
    private let timeOptions = SessionsFilterPersistence.timeOptions
    private static let pageSize = 200
    /// Debounce window between raw table selection and the detail pane target.
    private static let selectionSettleInterval: Duration = .milliseconds(150)

    /// Pure gate for concurrent browse loads (favorite reload vs filter change).
    /// A completed load publishes only when it is still the newest generation and
    /// its task was not cancelled.
    static func shouldApplyLoad(
        resultGeneration: Int,
        currentGeneration: Int,
        isCancelled: Bool = false
    ) -> Bool {
        !isCancelled && resultGeneration == currentGeneration
    }

    /// Flattened row list: parents, then (for expanded parents with loaded
    /// children) their confirmed and suggested children indented one level.
    /// Pure so row order and badges are unit-testable without a view.
    nonisolated static func buildRows(
        sessions: [Session],
        confirmedCounts: [String: Int],
        suggestedCounts: [String: Int],
        expandedParents: Set<String>,
        childrenByParent: [String: SessionChildrenBox]
    ) -> [SessionTableRow] {
        var rows: [SessionTableRow] = []
        var index = 0
        for session in sessions {
            let confirmed = confirmedCounts[session.id] ?? 0
            let suggested = suggestedCounts[session.id] ?? 0
            let childCount = confirmed + suggested
            let isExpanded = expandedParents.contains(session.id)
            rows.append(
                SessionTableRow(
                    id: session.id,
                    session: session,
                    kind: .parent,
                    depth: 0,
                    index: index,
                    hasChildren: childCount > 0,
                    childCount: childCount,
                    isExpanded: isExpanded
                )
            )
            index += 1
            guard isExpanded, let box = childrenByParent[session.id] else { continue }
            for child in box.confirmed {
                rows.append(
                    SessionTableRow(
                        id: child.id,
                        session: child,
                        kind: .confirmedChild,
                        depth: 1,
                        index: index
                    )
                )
                index += 1
            }
            for child in box.suggested {
                rows.append(
                    SessionTableRow(
                        id: child.id,
                        session: child,
                        kind: .suggestedChild,
                        depth: 1,
                        index: index
                    )
                )
                index += 1
            }
        }
        return rows
    }

    private var tableRows: [SessionTableRow] {
        Self.buildRows(
            sessions: sessions,
            confirmedCounts: confirmedCounts,
            suggestedCounts: suggestedCounts,
            expandedParents: expandedParents,
            childrenByParent: childrenByParent
        )
    }

    private var sessionFilter: String {
        SessionsFilterPersistence.sanitizeSessionFilter(sessionFilterStorage)
    }

    private var timeFilter: String {
        SessionsFilterPersistence.sanitizeTimeFilter(timeFilterStorage)
    }

    private var sourceFilter: String? {
        SessionsFilterPersistence.resolvedSource(
            stored: sourceFilterStorage,
            available: availableSources
        )
    }

    private var favoritesOnly: Bool {
        sessionFilter == "Starred"
    }

    private var sessionFilterBinding: Binding<String> {
        Binding(
            get: { SessionsFilterPersistence.sanitizeSessionFilter(sessionFilterStorage) },
            set: { sessionFilterStorage = SessionsFilterPersistence.sanitizeSessionFilter($0) }
        )
    }

    private var timeFilterBinding: Binding<String> {
        Binding(
            get: { SessionsFilterPersistence.sanitizeTimeFilter(timeFilterStorage) },
            set: { timeFilterStorage = SessionsFilterPersistence.sanitizeTimeFilter($0) }
        )
    }

    private var sourceFilterBinding: Binding<String> {
        Binding(
            get: { sourceFilter ?? "All" },
            set: {
                sourceFilterStorage = SessionsFilterPersistence.storage(
                    from: $0 == "All" ? nil : $0
                )
            }
        )
    }

    /// True when any list filter differs from the first-launch defaults, so the
    /// empty state and the footer count can offer a one-tap reset.
    private var hasActiveFilters: Bool {
        sessionFilter != "All" || timeFilter != "All Time" || sourceFilter != nil || hqOnly
    }

    private func clearFilters() {
        sessionFilterStorage = "All"
        timeFilterStorage = "All Time"
        sourceFilterStorage = ""
        hqOnly = false
    }

    private var handlers: SessionActionHandlers {
        SessionActionHandlers(
            serviceClient: serviceClient,
            reload: { await reloadAfterMutation() },
            onStatus: { message in
                actionStatus = message
                // Auto-clear so a success banner doesn't linger as a permanent
                // warning; only clear if nothing replaced it meanwhile.
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if actionStatus == message { actionStatus = nil }
                }
            }
        )
    }

    /// Favorite/hide/rename mutations reload the list; track the task so a
    /// subsequent filter change can cancel it before a newer load starts.
    private func reloadAfterMutation() async {
        favoriteReloadTask?.cancel()
        let task = Task {
            await loadData()
        }
        favoriteReloadTask = task
        await task.value
    }

    private func export(_ session: Session, format: String) {
        var next = exportState
        guard next.begin(sessionId: session.id) else { return }
        exportState = next
        handlers.export(session, format: format) { terminal in
            guard exportState == .inFlight(sessionId: session.id) else { return }
            exportState = terminal
            Task {
                try? await Task.sleep(for: .seconds(3))
                if exportState == terminal { exportState = .idle }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if let loadError {
                AlertBanner(message: "Failed to load sessions: \(loadError)", action: ("Retry", { Task { await loadData() } }))
            }
            if let actionStatus {
                AlertBanner(message: actionStatus)
                    .accessibilityIdentifier("sessions_actionStatus")
                    // VoiceOver does not auto-announce a banner whose text
                    // swaps in place; announce each new status transition.
                    .onAppear {
                        AccessibilityNotification.Announcement(actionStatus).post()
                    }
                    .onChange(of: actionStatus) { _, message in
                        AccessibilityNotification.Announcement(message).post()
                    }
            }
            SessionExportStatusBanner(state: exportState)
                .accessibilityIdentifier("sessions_exportStatus")
            HSplitView {
                listPane
                    .frame(minWidth: 360, maxWidth: .infinity)
                detailPane
                    .frame(minWidth: 420, maxWidth: .infinity)
                    .background(Theme.surface)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions_container")
        .sheet(item: $resumeTarget) { ResumeDialog(session: $0) }
        .sheet(item: $replayTarget) {
            SessionReplayView(sessionId: $0.id)
                .frame(minWidth: 600, minHeight: 450)
        }
        .sheet(item: $renameTarget) { target in
            RenameSessionSheet(
                text: $renameText,
                onCancel: { renameTarget = nil },
                onSave: {
                    handlers.rename(target, to: renameText)
                    renameTarget = nil
                }
            )
        }
        .sheet(item: $relateTarget) { target in
            RelatedSessionPicker(
                source: target,
                onLinked: {}
            )
        }
        // Settled selection: the row highlight paints immediately from the raw
        // table selection; the transcript pane follows after a short debounce so
        // rapid row changes don't reload the pane per keystroke.
        .task(id: selectedSessionId) {
            guard let id = selectedSessionId else {
                settledSession = nil
                return
            }
            try? await Task.sleep(for: Self.selectionSettleInterval)
            guard !Task.isCancelled else { return }
            guard let session = findSession(id) else { return }
            settledSession = session
            handlers.recordAccess(session)
        }
        // Single id-keyed task: any filter change cancels the in-flight load and
        // starts a fresh one, so a slower older load can't land last and leave
        // the list showing the previous filter's sessions. A bare index-count
        // tick (filters unchanged) is debounced and preserves pagination so
        // scrolling doesn't jump back to page one while indexing runs (#3).
        .task(id: [
            AnyHashable(sessionFilter),
            AnyHashable(timeFilter),
            AnyHashable(sourceFilter),
            AnyHashable(hqOnly),
            AnyHashable(showHiddenSessions),
            AnyHashable(showAllSessions),
            AnyHashable(serviceStatusStore.browseReloadToken),
        ]) {
            // Drop any favorite-triggered reload for the previous filter so it
            // cannot finish after this filter's load and clobber the list.
            favoriteReloadTask?.cancel()
            favoriteReloadTask = nil
            let filterKey: [AnyHashable] = [
                AnyHashable(sessionFilter),
                AnyHashable(timeFilter),
                AnyHashable(sourceFilter),
                AnyHashable(hqOnly),
                AnyHashable(showHiddenSessions),
                AnyHashable(showAllSessions),
            ]
            let plan = BrowseReloadCoalescer.plan(filterKey: filterKey, lastFilterKey: lastFilterKey)
            if plan.debounce {
                try? await Task.sleep(for: BrowseReloadCoalescer.debounceInterval)
                if Task.isCancelled { return }
            }
            lastFilterKey = filterKey
            await loadData(preservePagination: plan.preservePagination)
        }
    }

    // MARK: - List pane (filter header + table + footer)

    private var listPane: some View {
        VStack(spacing: 0) {
            filterHeader
            Divider().opacity(0.4)
            if isLoading && sessions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("sessions_skeleton")
            } else if sessions.isEmpty {
                EmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No sessions",
                    message: "No sessions match your filters",
                    action: hasActiveFilters ? ("Clear filters", { clearFilters() }) : nil
                )
                .accessibilityIdentifier("sessions_emptyState")
            } else {
                sessionTable
            }
            footerBar
        }
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FilterPills(options: sessionOptions, selected: sessionFilterBinding)
                    .accessibilityIdentifier("sessions_sessionFilterPills")
                FilterPills(options: timeOptions, selected: timeFilterBinding)
                    .accessibilityIdentifier("sessions_filterPills")
                Spacer()
                if !availableSources.isEmpty {
                    Picker("Source", selection: sourceFilterBinding) {
                        Text("All Sources").tag("All")
                        ForEach(availableSources, id: \.self) { source in
                            Text(SourceColors.label(for: source)).tag(source)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .accessibilityIdentifier("sessions_sourcePicker")
                }
            }
            HStack(spacing: 16) {
                Toggle("Show all sessions", isOn: $showAllSessions)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("sessions_showAllToggle")
                    .help("Include single-shot and automated sessions, not just ones you actively drove")
                Toggle("Show hidden sessions", isOn: $showHiddenSessions)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("sessions_showHiddenToggle")
                    .help("Include sessions you hid from the list")
                Toggle("HQ only", isOn: $hqOnly)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("sessions_hqOnlyToggle")
                    .help("Show only sessions indexed from the HQ machine")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var sessionTable: some View {
        Table(tableRows, selection: $selectedSessionId) {
            TableColumn("★") { row in
                Button {
                    toggleFavorite(row.session)
                } label: {
                    Image(systemName: row.session.isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(row.session.isFavorite ? Theme.orange : Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Session.favoriteAccessibilityLabel(isFavorite: row.session.isFavorite)
                )
            }
            .width(min: 24, ideal: 30, max: 40)

            TableColumn("Source") { row in
                HStack(spacing: 4) {
                    SourcePill(source: row.session.source)
                    OriginBadge(origin: row.session.origin)
                }
            }
            .width(min: 76, ideal: 92, max: 130)

            TableColumn("Session") { row in
                SessionTableCell(
                    row: row,
                    onToggleExpand: { toggleExpand(row) },
                    onResume: { resumeTarget = $0; handlers.recordAccess($0) },
                    onCopyResumeCommand: { handlers.copyResumeCommand($0) },
                    onHandoff: { handlers.handoff($0) },
                    onReplay: { replayTarget = $0 },
                    onRelate: { relateTarget = $0 },
                    onHide: { handlers.setHidden($0, hidden: $0.hiddenAt == nil) },
                    onRename: { beginRename($0) },
                    onExportMarkdown: { export($0, format: "markdown") },
                    onExportJSON: { export($0, format: "json") },
                    exportsDisabled: !exportState.allowsExportAction,
                    onToggleFavorite: { session, completion in
                        toggleFavorite(session, completion: completion)
                    },
                    onConfirmSuggestion: { child in confirmSuggestion(child) },
                    onDismissSuggestion: { child in dismissSuggestion(child) }
                )
                .onAppear {
                    if row.index == tableRows.count - 1 { loadMoreIfNeeded() }
                }
            }

            TableColumn("Updated") { row in
                Text(RelativeTimeText.format(row.session.endTime ?? row.session.startTime, style: .compact))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .help(row.session.displayUpdatedDate)
            }
            .width(min: 64, ideal: 76, max: 110)

            TableColumn("Project") { row in
                if let project = row.session.project {
                    Text(project)
                        .lineLimit(1)
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("—")
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .width(min: 80, ideal: 130, max: 220)

            TableColumn("Msgs") { row in
                Text("\(row.session.messageCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 48, max: 64)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("sessions_list")
    }

    /// One-line footer (agent-sessions pattern): service state on the left,
    /// session counts on the right; the count doubles as a "clear filters"
    /// button only while a filter is actually active.
    private var footerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                if serviceStatusStore.isRunning {
                    Circle()
                        .fill(Theme.green)
                        .frame(width: 6, height: 6)
                }
                Text(serviceStatusStore.displayString)
                    .lineLimit(1)
            }
            .scaledFont(10)
            .foregroundStyle(Theme.tertiaryText)
            Spacer()
            if hasActiveFilters {
                Button {
                    clearFilters()
                } label: {
                    Text("\(sessions.count) of \(totalCount) sessions · Clear filters")
                        .scaledFont(10)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sessions_footerCount")
            } else {
                Text("\(totalCount) sessions")
                    .scaledFont(10)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityIdentifier("sessions_footerCount")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let session = settledSession {
            SessionDetailView(session: session, onBack: nil, searchTerm: nil)
                .id(session.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.title3)
                    .foregroundStyle(Theme.tertiaryText)
                Text("Select a session to view its transcript")
                    .scaledFont(11)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Locate a session by id across loaded parents and expanded children.
    private func findSession(_ id: String) -> Session? {
        if let parent = sessions.first(where: { $0.id == id }) { return parent }
        for box in childrenByParent.values {
            if let child = box.confirmed.first(where: { $0.id == id }) { return child }
            if let child = box.suggested.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    // MARK: - Row actions

    private func toggleFavorite(
        _ session: Session,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        handlers.setFavorite(
            session,
            favorite: session.favoriteToggleTarget,
            completion: completion
        )
    }

    private func toggleExpand(_ row: SessionTableRow) {
        if expandedParents.contains(row.id) {
            expandedParents.remove(row.id)
        } else {
            expandedParents.insert(row.id)
            if childrenByParent[row.id] == nil {
                loadChildren(of: row.id)
            }
        }
    }

    private func loadChildren(of parentId: String) {
        guard !loadingParents.contains(parentId) else { return }
        loadingParents.insert(parentId)
        let includeHidden = showHiddenSessions
        let generation = loadGeneration
        let db = self.db
        Task.detached {
            let confirmed = (try? db.childSessions(
                parentId: parentId,
                includeHidden: includeHidden,
                limit: 20
            )) ?? []
            let suggested = (try? db.suggestedChildSessions(
                parentId: parentId,
                includeHidden: includeHidden
            )) ?? []
            // Child rows can be skip-tier by design. Use raw favorites membership
            // so a starred child can still be unstarred after re-expanding it.
            let favoriteIds = Set((try? db.favoriteIds()) ?? [])
            let box = SessionChildrenBox(
                confirmed: Session.applyingFavoriteIds(confirmed, favoriteIds: favoriteIds),
                suggested: Session.applyingFavoriteIds(suggested, favoriteIds: favoriteIds)
            )
            await MainActor.run {
                loadingParents.remove(parentId)
                // Drop a load that raced a full reload for a newer generation.
                guard generation == loadGeneration else { return }
                childrenByParent[parentId] = box
            }
        }
    }

    private func confirmSuggestion(_ child: Session) {
        Task {
            do {
                let response = try await serviceClient.confirmSuggestion(sessionId: child.id)
                guard response.ok else {
                    actionStatus = response.error ?? "Failed to confirm suggestion"
                    return
                }
                // The child moves suggested → confirmed: refresh its parent box
                // so the row re-renders in place instead of staying stale.
                invalidateChildren(of: child.suggestedParentId)
                await loadData()
            } catch {
                EngramLogger.error("SessionsPage confirm suggestion failed", module: .ui, error: error)
                actionStatus = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    private func dismissSuggestion(_ child: Session) {
        Task {
            do {
                if let suggestedParentId = child.suggestedParentId {
                    try await serviceClient.dismissSuggestion(
                        sessionId: child.id,
                        suggestedParentId: suggestedParentId
                    )
                    invalidateChildren(of: suggestedParentId)
                }
                await loadData()
            } catch {
                EngramLogger.error("SessionsPage dismiss suggestion failed", module: .ui, error: error)
                actionStatus = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    /// Drop a parent's loaded child box and reload it while it stays expanded.
    private func invalidateChildren(of parentId: String?) {
        guard let parentId else { return }
        childrenByParent[parentId] = nil
        if expandedParents.contains(parentId) {
            loadChildren(of: parentId)
        }
    }

    private func beginRename(_ session: Session) {
        renameText = session.customName ?? session.displayTitle
        renameTarget = session
    }

    // MARK: - Data loading

    private func loadData(preservePagination: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            // Clear the spinner when this generation is still current (including
            // cancelled-but-newest). A superseded generation leaves isLoading to
            // the newer load that bumped the counter.
            if generation == loadGeneration {
                isLoading = false
            }
        }
        // Capture before begin — detail evaluates at end() (row 16).
        let capturedPageSize = preservePagination
            ? BrowseReloadCoalescer.refreshLimit(loadedCount: sessions.count, pageSize: Self.pageSize)
            : Self.pageSize
        let capturedSessionCount = sessions.count
        let span = Perf.begin(
            "loadData",
            "pageSize=\(capturedPageSize) sessions=\(capturedSessionCount) preserve=\(preservePagination)"
        )
        defer { Perf.end(span) }
        do {
            let db = self.db
            let sources: Set<String> = sourceFilter.map { [$0] } ?? []
            let since = sinceDate(for: timeFilter)
            let includeHidden = showHiddenSessions
            let humanDriven = !showAllSessions
            let favoritesOnly = self.favoritesOnly
            let origin: String? = hqOnly ? "hq" : nil
            // Preserve the loaded window on an index-tick refresh; otherwise a
            // fresh load starts at the first page.
            let pageSize = capturedPageSize
            let data = try await Task.detached {
                let loaded = try db.listSessions(
                    sources: sources,
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false,
                    topLevelOnly: true,
                    humanDriven: humanDriven,
                    favoritesOnly: favoritesOnly,
                    origin: origin,
                    sort: .updatedDesc,
                    limit: pageSize
                )
                let stats = try db.sessionListStats(
                    sources: sources,
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false,
                    topLevelOnly: true,
                    humanDriven: humanDriven,
                    favoritesOnly: favoritesOnly,
                    origin: origin
                )
                let sourceOptions = try db.sessionListStats(
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false,
                    favoritesOnly: favoritesOnly
                ).sources
                let parentIds = loaded.map(\.id)
                let confirmed = try db.childCount(parentIds: parentIds, includeHidden: includeHidden)
                let suggested = try db.suggestedChildCount(parentIds: parentIds, includeHidden: includeHidden)
                // Starred filter already implies membership; otherwise join the
                // favorites id set so Browse can toggle Add vs Remove correctly.
                let favoriteIds: Set<String>
                if favoritesOnly {
                    favoriteIds = Set(parentIds)
                } else {
                    favoriteIds = Set((try? db.favoriteIds()) ?? [])
                }
                let annotated = Session.applyingFavoriteIds(loaded, favoriteIds: favoriteIds)
                return (annotated, confirmed, suggested, stats, sourceOptions)
            }.value
            // Favorite reload for filter A must not overwrite a newer filter-B load.
            guard Self.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            sessions = data.0
            confirmedCounts = data.1
            suggestedCounts = data.2
            totalCount = data.3.totalSessions
            availableSources = data.4
            // Drop a persisted source that disappeared so the page never stays empty.
            sourceFilterStorage = SessionsFilterPersistence.sanitizedSourceStorage(
                stored: sourceFilterStorage,
                available: availableSources
            )
            // A filter change can remove the selected row: release the stale
            // selection instead of keeping an invisible detail pane target.
            if let selected = selectedSessionId, findSession(selected) == nil {
                selectedSessionId = nil
            }
            // Refresh child boxes of still-expanded parents (counts may have
            // changed after a mutation or re-scan).
            for parent in expandedParents where childrenByParent[parent] != nil {
                loadChildren(of: parent)
            }
            loadError = nil
        } catch {
            guard Self.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            EngramLogger.error("SessionsPage load failed", module: .ui, error: error)
            loadError = ServiceErrorPresenter.displayMessage(for: error)
        }
    }

    private func loadMoreIfNeeded() {
        // One page already on screen and more remain; guard against re-entrancy.
        guard !isLoading, !isLoadingMore else { return }
        guard sessions.count < totalCount else { return }
        isLoadingMore = true
        // Capture (do not bump) so a full reload that advances loadGeneration
        // invalidates this page append.
        let generation = loadGeneration
        let favoritesOnly = self.favoritesOnly
        Task {
            // Always clear the spinner; only the append path is generation-gated.
            defer { isLoadingMore = false }
            do {
                let db = self.db
                let sources: Set<String> = sourceFilter.map { [$0] } ?? []
                let since = sinceDate(for: timeFilter)
                let includeHidden = showHiddenSessions
                let humanDriven = !showAllSessions
                let origin: String? = hqOnly ? "hq" : nil
                let offset = sessions.count
                let pageSize = Self.pageSize
                // Capture before begin — detail evaluates at end() (row 16).
                let span = Perf.begin("loadMoreIfNeeded", "offset=\(offset) pageSize=\(pageSize)")
                defer { Perf.end(span) }
                let more = try await Task.detached {
                    let loaded = try db.listSessions(
                        sources: sources,
                        since: since,
                        includeHidden: includeHidden,
                        subAgent: false,
                        topLevelOnly: true,
                        humanDriven: humanDriven,
                        favoritesOnly: favoritesOnly,
                        origin: origin,
                        sort: .updatedDesc,
                        limit: pageSize,
                        offset: offset
                    )
                    let parentIds = loaded.map(\.id)
                    let confirmed = try db.childCount(parentIds: parentIds, includeHidden: includeHidden)
                    let suggested = try db.suggestedChildCount(parentIds: parentIds, includeHidden: includeHidden)
                    let favoriteIds: Set<String>
                    if favoritesOnly {
                        favoriteIds = Set(parentIds)
                    } else {
                        favoriteIds = Set((try? db.favoriteIds()) ?? [])
                    }
                    let annotated = Session.applyingFavoriteIds(loaded, favoriteIds: favoriteIds)
                    return (annotated, confirmed, suggested)
                }.value
                guard Self.shouldApplyLoad(
                    resultGeneration: generation,
                    currentGeneration: loadGeneration,
                    isCancelled: Task.isCancelled
                ) else { return }
                // De-dup on append in case a reload raced with this page fetch.
                let existing = Set(sessions.map(\.id))
                sessions.append(contentsOf: more.0.filter { !existing.contains($0.id) })
                confirmedCounts.merge(more.1) { _, new in new }
                suggestedCounts.merge(more.2) { _, new in new }
            } catch {
                guard Self.shouldApplyLoad(
                    resultGeneration: generation,
                    currentGeneration: loadGeneration,
                    isCancelled: Task.isCancelled
                ) else { return }
                EngramLogger.error("SessionsPage load-more failed", module: .ui, error: error)
            }
        }
    }

    private func sinceDate(for filter: String) -> String? {
        Self.sinceDate(for: filter, now: fixedDate ?? Date())
    }

    nonisolated static func sinceDate(for filter: String, now: Date) -> String? {
        let cal = Calendar.current
        let formatter = ISO8601DateFormatter()
        switch filter {
        case "Today": return formatter.string(from: cal.startOfDay(for: now))
        case "This Week": return formatter.string(from: cal.date(byAdding: .day, value: -7, to: now) ?? now)
        case "This Month": return formatter.string(from: cal.date(byAdding: .month, value: -1, to: now) ?? now)
        default: return nil
        }
    }
}

// MARK: - Session table cell (title column content)

/// The "Session" column cell: disclosure chevron + badges + title, plus the
/// full row context menu. Suggested-child rows also carry inline
/// Confirm/Dismiss buttons.
private struct SessionTableCell: View {
    let row: SessionTableRow
    var onToggleExpand: (() -> Void)? = nil
    var onResume: ((Session) -> Void)? = nil
    var onCopyResumeCommand: ((Session) -> Void)? = nil
    var onHandoff: ((Session) -> Void)? = nil
    var onReplay: ((Session) -> Void)? = nil
    var onRelate: ((Session) -> Void)? = nil
    var onHide: ((Session) -> Void)? = nil
    var onRename: ((Session) -> Void)? = nil
    var onExportMarkdown: ((Session) -> Void)? = nil
    var onExportJSON: ((Session) -> Void)? = nil
    var exportsDisabled = false
    var onToggleFavorite: ((Session, @escaping @MainActor (Bool) -> Void) -> Void)? = nil
    var onConfirmSuggestion: ((Session) -> Void)? = nil
    var onDismissSuggestion: ((Session) -> Void)? = nil

    private var session: Session { row.session }

    var body: some View {
        HStack(spacing: 6) {
            // Disclosure chevron (parents with children only); indented by depth.
            if row.hasChildren {
                Button(action: { onToggleExpand?() }) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse agent sessions" : "Expand agent sessions")
            } else {
                Spacer().frame(width: 12)
            }

            if row.hasChildren && !row.isExpanded {
                Text("\(row.childCount)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }

            if row.isSuggestedChild {
                Text("Suggested")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surfaceHighlight)
                    .foregroundStyle(Theme.tertiaryText)
                    .clipShape(Capsule())
            }
            if session.hiddenAt != nil {
                Text("Hidden")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surfaceHighlight)
                    .foregroundStyle(Theme.tertiaryText)
                    .clipShape(Capsule())
            }

            Text(session.displayTitle)
                .font(row.depth == 0 ? .callout : .caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.isSuggestedChild ? Theme.tertiaryText : Theme.primaryText)
                .accessibilityIdentifier("sessions_row_\(row.index)")

            if row.isSuggestedChild {
                Button("Confirm") { onConfirmSuggestion?(session) }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                Button("\u{00D7}") { onDismissSuggestion?(session) }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss suggestion")
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        // Remote/HQ-snapshot rows cannot be resumed locally (design §9): the
        // row has no local transcript file. Disable with a reason rather than
        // drop so the menu stays spatially stable.
        Button("Resume...") { onResume?(session) }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Resume this session in a terminal")
        Button("Copy Resume Command") { onCopyResumeCommand?(session) }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Copy the resume command to the clipboard")
        Button("Handoff") { onHandoff?(session) }
            .disabled(!ExpandableSessionCard.canResumeLocally(session))
            .help(session.isRemoteSnapshot ? "Only available on the HQ machine" : "Hand off to another tool")
        // Replay stays enabled for remote snapshots: the service falls back to
        // the indexed FTS timeline (canReplay).
        Button("Replay") { onReplay?(session) }
            .help("Replay this session")
        if let onRelate {
            Button("Link related session…") { onRelate(session) }
        }
        SessionWriteMenuItems(
            isHidden: session.hiddenAt != nil,
            isFavorite: session.isFavorite,
            onToggleFavorite: onToggleFavorite.map { cb in { cb(session, { _ in }) } },
            onRename: onRename.map { cb in { cb(session) } },
            onExportMarkdown: onExportMarkdown.map { cb in { cb(session) } },
            onExportJSON: onExportJSON.map { cb in { cb(session) } },
            exportsDisabled: exportsDisabled,
            exportAllowed: ExpandableSessionCard.canExport(session),
            onHide: onHide.map { cb in { cb(session) } }
        )
    }
}

// MARK: - Rename sheet (shared by browse pages)

struct RenameSessionSheet: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void
    // Keyboard-first: the name field owns focus when the sheet opens so the
    // user can type immediately (sheet has exactly one editable control).
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .focused($nameFocused)
                .onSubmit { onSave() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear { nameFocused = true }
    }
}