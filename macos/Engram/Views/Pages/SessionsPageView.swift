// macos/Engram/Views/Pages/SessionsPageView.swift
import SwiftUI

struct SessionsPageView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @AppStorage("sessions.showHidden") private var showHiddenSessions = false
    // Global escape hatch from the human-driven default view. Shared key across
    // SessionsPage / Home / Timeline so one toggle reveals everything everywhere.
    @AppStorage("sessions.showAll") private var showAllSessions = false
    @AppStorage(SessionsFilterPersistence.sessionFilterKey) private var sessionFilterStorage = "All"
    @AppStorage(SessionsFilterPersistence.timeFilterKey) private var timeFilterStorage = "All Time"
    /// Empty string sentinel for Optional source (AppStorage cannot hold String?).
    @AppStorage(SessionsFilterPersistence.sourceFilterKey) private var sourceFilterStorage = ""

    @State private var sessions: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var totalCount = 0
    @State private var totalMessages = 0
    @State private var avgDurationSeconds: Double?
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load sessions: \(loadError)")
                }
                if let actionStatus {
                    AlertBanner(message: actionStatus)
                        .accessibilityIdentifier("sessions_actionStatus")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(totalCount)", label: "Total Sessions")
                        .accessibilityIdentifier("sessions_kpiCard_total")
                    KPICard(value: formatNumber(totalMessages), label: "Messages")
                        .accessibilityIdentifier("sessions_kpiCard_messages")
                    KPICard(value: avgDuration, label: "Avg Duration")
                        .accessibilityIdentifier("sessions_kpiCard_avgDuration")
                }

                HStack(spacing: 12) {
                    FilterPills(options: sessionOptions, selected: sessionFilterBinding)
                        .accessibilityIdentifier("sessions_sessionFilterPills")
                    FilterPills(options: timeOptions, selected: timeFilterBinding)
                        .accessibilityIdentifier("sessions_filterPills")
                    Spacer()
                    Toggle("Show all sessions", isOn: $showAllSessions)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("sessions_showAllToggle")
                        .help("Include single-shot and automated sessions, not just ones you actively drove")
                    Toggle("Show hidden sessions", isOn: $showHiddenSessions)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("sessions_showHiddenToggle")
                    if !availableSources.isEmpty {
                        Picker("Source", selection: sourceFilterBinding) {
                            Text("All Sources").tag("All")
                            ForEach(availableSources, id: \.self) { source in
                                Text(SourceColors.label(for: source)).tag(source)
                            }
                        }
                        .frame(width: 140)
                        .accessibilityIdentifier("sessions_sourcePicker")
                    }
                }

                if isLoading && sessions.isEmpty {
                    LazyVStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                    }
                    .accessibilityIdentifier("sessions_skeleton")
                } else if sessions.isEmpty {
                    EmptyState(icon: "bubble.left.and.bubble.right", title: "No sessions", message: "No sessions match your filters")
                        .accessibilityIdentifier("sessions_emptyState")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            ExpandableSessionCard(
                                session: session,
                                confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                includeHiddenChildren: showHiddenSessions,
                                onTap: {
                                    handlers.recordAccess(session)
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                },
                                onChildTap: { child in
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(child))
                                },
                                onResume: { resumeTarget = $0; handlers.recordAccess($0) },
                                onCopyResumeCommand: { handlers.copyResumeCommand($0) },
                                onHandoff: { handlers.handoff($0) },
                                onReplay: { replayTarget = $0 },
                                onConfirmSuggestion: { child in confirmSuggestion(child) },
                                onDismissSuggestion: { child in dismissSuggestion(child) },
                                onRelate: { relateTarget = $0 },
                                onHide: { handlers.setHidden($0, hidden: $0.hiddenAt == nil) },
                                onRename: { beginRename($0) },
                                onExportMarkdown: { handlers.export($0, format: "markdown") },
                                onExportJSON: { handlers.export($0, format: "json") },
                                // M19: one toggle for Browse and Starred — target is !isFavorite.
                                onToggleFavorite: { session in
                                    handlers.setFavorite(session, favorite: session.favoriteToggleTarget)
                                },
                                isHidden: session.hiddenAt != nil
                            )
                            .accessibilityIdentifier("sessions_row_\(index)")
                            .onAppear {
                                if index == sessions.count - 1 { loadMoreIfNeeded() }
                            }
                        }
                        if isLoadingMore {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                    }
                    .accessibilityIdentifier("sessions_list")
                }
            }
            .padding(24)
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
            // Candidates are deduped server-side via INSERT OR IGNORE, so the
            // list-card path passes an empty existing set (the detail view, which
            // already holds the related list, passes the real set).
            RelatedSessionPicker(
                source: target,
                existingRelatedIds: [],
                onLinked: {}
            )
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
            AnyHashable(showHiddenSessions),
            AnyHashable(showAllSessions),
            AnyHashable(serviceStatusStore.totalSessions),
        ]) {
            // Drop any favorite-triggered reload for the previous filter so it
            // cannot finish after this filter's load and clobber the list.
            favoriteReloadTask?.cancel()
            favoriteReloadTask = nil
            let filterKey: [AnyHashable] = [
                AnyHashable(sessionFilter),
                AnyHashable(timeFilter),
                AnyHashable(sourceFilter),
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
        do {
            let db = self.db
            let sources: Set<String> = sourceFilter.map { [$0] } ?? []
            let since = sinceDate(for: timeFilter)
            let includeHidden = showHiddenSessions
            let humanDriven = !showAllSessions
            let favoritesOnly = self.favoritesOnly
            // Preserve the loaded window on an index-tick refresh; otherwise a
            // fresh load starts at the first page.
            let pageSize = preservePagination
                ? BrowseReloadCoalescer.refreshLimit(loadedCount: sessions.count, pageSize: Self.pageSize)
                : Self.pageSize
            let data = try await Task.detached {
                let loaded = try db.listSessions(
                    sources: sources,
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false,
                    topLevelOnly: true,
                    humanDriven: humanDriven,
                    favoritesOnly: favoritesOnly,
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
                    favoritesOnly: favoritesOnly
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
                    favoriteIds = Set((try? db.listFavorites())?.map(\.id) ?? [])
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
            totalMessages = data.3.totalMessages
            avgDurationSeconds = data.3.avgDurationSeconds
            availableSources = data.4
            // Drop a persisted source that disappeared so the page never stays empty.
            sourceFilterStorage = SessionsFilterPersistence.sanitizedSourceStorage(
                stored: sourceFilterStorage,
                available: availableSources
            )
            loadError = nil
        } catch {
            guard Self.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            EngramLogger.error("SessionsPage load failed", module: .ui, error: error)
            loadError = error.localizedDescription
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
                await loadData()
            } catch {
                EngramLogger.error("SessionsPage confirm suggestion failed", module: .ui, error: error)
                actionStatus = error.localizedDescription
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
                }
                await loadData()
            } catch {
                EngramLogger.error("SessionsPage dismiss suggestion failed", module: .ui, error: error)
                actionStatus = error.localizedDescription
            }
        }
    }

    private func beginRename(_ session: Session) {
        renameText = session.customName ?? session.displayTitle
        renameTarget = session
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
                let offset = sessions.count
                let pageSize = Self.pageSize
                let more = try await Task.detached {
                    let loaded = try db.listSessions(
                        sources: sources,
                        since: since,
                        includeHidden: includeHidden,
                        subAgent: false,
                        topLevelOnly: true,
                        humanDriven: humanDriven,
                        favoritesOnly: favoritesOnly,
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
                        favoriteIds = Set((try? db.listFavorites())?.map(\.id) ?? [])
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
        let cal = Calendar.current
        let now = Date()
        let formatter = ISO8601DateFormatter()
        switch filter {
        case "Today": return formatter.string(from: cal.startOfDay(for: now))
        case "This Week": return formatter.string(from: cal.date(byAdding: .day, value: -7, to: now) ?? now)
        case "This Month": return formatter.string(from: cal.date(byAdding: .month, value: -1, to: now) ?? now)
        default: return nil
        }
    }

    private var avgDuration: String {
        guard let avg = avgDurationSeconds else { return "—" }
        if avg < 60 { return "\(Int(avg))s" }
        if avg < 3600 { return "\(Int(avg / 60))m" }
        return String(format: "%.1fh", avg / 3600)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Rename sheet (shared by browse pages)

struct RenameSessionSheet: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { onSave() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}
