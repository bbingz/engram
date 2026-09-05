// macos/Engram/Views/Pages/TimelinePageView.swift
import SwiftUI

private enum TimelineSortMode: String, CaseIterable, Identifiable {
    case activity
    case created

    var id: String { rawValue }

    var databaseSort: SessionSort {
        switch self {
        case .activity:
            .updatedDesc
        case .created:
            .createdDesc
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .activity:
            "Active"
        case .created:
            "Created"
        }
    }
}

private enum TimelineRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case all = 100_000

    var id: Int { rawValue }

    var days: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .all: "All"
        }
    }

    var badge: String {
        switch self {
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .all: "All"
        }
    }
}

private enum TimelineMode: String, CaseIterable, Identifiable {
    case work
    case sessions

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .work: "Work"
        case .sessions: "Sessions"
        }
    }
}

private let timelineAllProjects = "All Projects"

struct TimelinePageView: View {
    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient
    @Environment(\.engramFixedDate) var fixedDate
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    // Shared global escape hatch (see SessionsPageView).
    @AppStorage("sessions.showAll") private var showAllSessions = false
    @State private var timeline: [(date: String, sessions: [Session])] = []
    @State private var sessionChartData: [(date: String, count: Int)] = []
    @State private var workTimeline: [ImplementationTimelineItem] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var timelineMode: TimelineMode = .work
    @State private var sortMode: TimelineSortMode = .activity
    @State private var range: TimelineRange = .month
    @State private var selectedProject: String = timelineAllProjects
    @State private var appliedProject: String = timelineAllProjects
    @State private var appliedRange: TimelineRange = .month
    @State private var appliedMode: TimelineMode = .work
    @State private var appliedSort: TimelineSortMode = .activity
    @State private var availableProjects: [String] = []
    @State private var timelineTotalCount = 0
    @State private var timelineShownCount = 0
    @State private var timelineHasMore = false
    @State private var loadError: String? = nil
    @State private var isLoading = true
    // Debounce/coalesce index-tick reloads vs. immediate filter-change reloads (#3).
    @State private var lastFilterKey: [AnyHashable]? = nil
    /// Bumped on every full load so a slower prior detached read cannot overwrite
    /// a newer filter/range load (M10; mirrors SessionsPageView).
    @State private var loadGeneration = 0
    // Session-action sheet targets + transient status banner.
    @State private var resumeTarget: Session? = nil
    @State private var replayTarget: Session? = nil
    @State private var renameTarget: Session? = nil
    @State private var renameText = ""
    @State private var actionStatus: String? = nil
    @State private var exportState: SessionExportState = .idle
    /// Keyboard focus for session rows (Wave 8-1, mirrors SessionsPageView 7-1).
    @FocusState private var focusedSessionId: String?

    /// Pure gate for concurrent timeline loads (filter/range change mid-flight).
    static func shouldApplyLoad(
        resultGeneration: Int,
        currentGeneration: Int,
        isCancelled: Bool = false
    ) -> Bool {
        !isCancelled && resultGeneration == currentGeneration
    }

    static func reconciledProjectSelection(
        selectedProject: String,
        availableProjects: [String]
    ) -> String {
        guard selectedProject != timelineAllProjects,
              !availableProjects.contains(selectedProject) else {
            return selectedProject
        }
        return timelineAllProjects
    }

    static func rangeBadge(range: String, shown: Int, total: Int, hasMore: Bool) -> String {
        hasMore ? "\(range) · \(shown) of \(total)" : range
    }

    private var handlers: SessionActionHandlers {
        SessionActionHandlers(
            serviceClient: serviceClient,
            reload: { await loadData(preservePagination: true) },
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

    // Distinct projects across the loaded window.
    private var projectOptions: [String] {
        [timelineAllProjects] + availableProjects
    }

    private var workChartData: [(date: String, count: Int)] {
        let grouped = Dictionary(grouping: workTimeline, by: \.startDate)
        return grouped
            .map { (date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        let projectOptionsSnapshot = projectOptions
        let timelineSnapshot = timeline
        let visibleModeSnapshot = appliedMode
        let visibleChartDataSnapshot = visibleModeSnapshot == .work
            ? workChartData
            : sessionChartData
        let hasVisibleContentSnapshot = visibleModeSnapshot == .work
            ? !workTimeline.isEmpty
            : !timelineSnapshot.isEmpty
        let headerSnapshotMatchesSelection = !isLoading
            && selectedProject == appliedProject
            && range == appliedRange
            && timelineMode == appliedMode
            && sortMode == appliedSort

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeader(
                        icon: "chart.bar.xaxis",
                        title: "Timeline",
                        badge: Self.rangeBadge(
                            range: appliedRange.badge,
                            shown: timelineShownCount,
                            total: timelineTotalCount,
                            hasMore: headerSnapshotMatchesSelection
                                && appliedMode == .sessions
                                && timelineHasMore
                        )
                    )
                    Spacer(minLength: 12)
                    Picker("Mode", selection: $timelineMode) {
                        ForEach(TimelineMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 176)
                    .accessibilityIdentifier("timeline_modePicker")
                    Picker("Range", selection: $range) {
                        ForEach(TimelineRange.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .accessibilityIdentifier("timeline_rangePicker")
                    Picker("Sort", selection: $sortMode) {
                        ForEach(TimelineSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 144)
                    .disabled(timelineMode == .work)
                    .accessibilityIdentifier("timeline_sortPicker")
                }
                Picker("Project", selection: $selectedProject) {
                    ForEach(projectOptionsSnapshot, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityIdentifier("timeline_projectPicker")
                if let loadError {
                    AlertBanner(message: "Failed to load timeline: \(loadError)", action: ("Retry", { Task { await loadData() } }))
                        .accessibilityIdentifier("timeline_loadError")
                }
                if let actionStatus {
                    AlertBanner(message: actionStatus)
                        .accessibilityIdentifier("timeline_actionStatus")
                }
                SessionExportStatusBanner(state: exportState)
                    .accessibilityIdentifier("timeline_exportStatus")
                if !isLoading && selectedProject == appliedProject
                    && visibleModeSnapshot == .sessions && timelineHasMore {
                    Text("Showing \(timelineShownCount) of \(timelineTotalCount)")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .accessibilityIdentifier("timeline_resultCount")
                }
                if headerSnapshotMatchesSelection
                    && !visibleChartDataSnapshot.isEmpty {
                    ActivityChart(data: visibleChartDataSnapshot)
                        .frame(height: 120)
                        .accessibilityIdentifier("timeline_chart")
                }
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("timeline_loading")
                } else if selectedProject != appliedProject {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("timeline_loading")
                } else if !hasVisibleContentSnapshot && loadError == nil && !isLoading {
                    EmptyState(
                        icon: "calendar",
                        title: "No activity",
                        message: emptyMessage(for: visibleModeSnapshot)
                    )
                        .accessibilityIdentifier("timeline_emptyState")
                } else if visibleModeSnapshot == .work {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(workTimeline, id: \.id) { item in
                            WorkTimelineCard(
                                item: item,
                                dateLabel: formatWorkDateRange(item),
                                kindLabel: kindLabel(item.kind)
                            )
                        }
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timelineSnapshot, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(formatDateLabel(group.date))
                                        .font(.headline)
                                        .foregroundStyle(Theme.primaryText)
                                    Text(sessionCountLabel(group.sessions.count))
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                    Spacer()
                                }
                                .padding(.top, 4)
                                ForEach(group.sessions) { session in
                                    ExpandableSessionCard(
                                        session: session,
                                        confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                        suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                        onTap: {
                                            open(session)
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
                                        onHide: { handlers.setHidden($0, hidden: $0.hiddenAt == nil) },
                                        onRename: { beginRename($0) },
                                        onExportMarkdown: { export($0, format: "markdown") },
                                        onExportJSON: { export($0, format: "json") },
                                        exportsDisabled: !exportState.allowsExportAction,
                                        onToggleFavorite: { session, completion in
                                            handlers.setFavorite(
                                                session,
                                                favorite: session.favoriteToggleTarget,
                                                completion: completion
                                            )
                                        },
                                        isHidden: session.hiddenAt != nil
                                    )
                                    // Keyboard navigation (Wave 8-1): plain-styled
                                    // card buttons draw no focus ring; add focus +
                                    // ring + Enter/Space to open (mirrors 7-1).
                                    .focusable()
                                    .focused($focusedSessionId, equals: session.id)
                                    .onKeyPress(keys: [.return, .space]) { _ in
                                        guard focusedSessionId == session.id else { return .ignored }
                                        open(session)
                                        return .handled
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                            .stroke(Theme.accent, lineWidth: 2)
                                            .opacity(focusedSessionId == session.id ? 1 : 0)
                                            .allowsHitTesting(false)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("timeline_container")
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
        // .task(id:) cancels the in-flight load when the sort changes, so a
        // slower older load can't land last and show the previous sort's data.
        .task(id: [
            AnyHashable(timelineMode),
            AnyHashable(sortMode),
            AnyHashable(range),
            AnyHashable(selectedProject),
            AnyHashable(showAllSessions),
            AnyHashable(serviceStatusStore.browseReloadToken)
        ]) {
            let filterKey: [AnyHashable] = [
                AnyHashable(timelineMode),
                AnyHashable(sortMode),
                AnyHashable(range),
                AnyHashable(selectedProject),
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
        let requestGeneration = loadGeneration
        if !preservePagination {
            isLoading = true
            clearVisibleSnapshot()
        }
        defer {
            if Self.shouldApplyLoad(
                resultGeneration: requestGeneration,
                currentGeneration: loadGeneration
            ) {
                isLoading = false
            }
        }
        do {
            let database = db
            let requestedSort = sortMode
            let sort = requestedSort.databaseSort
            let days = range.days
            let humanDriven = !showAllSessions
            let now = fixedDate ?? Date()
            let mode = timelineMode
            let requestedRange = range
            let requestedProject = selectedProject
            let data = try await Task.detached { [database, sort, requestedSort, days, humanDriven, now, mode, requestedRange, requestedProject] in
                let projects = switch mode {
                case .sessions:
                    try database.sessionTimelineProjects(
                        days: days,
                        sort: sort,
                        humanDriven: humanDriven,
                        now: now
                    )
                case .work:
                    try database.implementationTimelineProjects(
                        days: days,
                        humanDriven: humanDriven,
                        now: now
                    )
                }
                let reconciledProject = Self.reconciledProjectSelection(
                    selectedProject: requestedProject,
                    availableProjects: projects
                )
                let selectedProjectFilter = reconciledProject == timelineAllProjects ? nil : reconciledProject
                let tl = try database.sessionTimeline(
                    days: days,
                    sort: sort,
                    humanDriven: humanDriven,
                    project: selectedProjectFilter,
                    now: now
                )
                let favoriteIds = Set((try? database.listFavorites())?.map(\.id) ?? [])
                let annotatedTimeline = tl.groups.map { group in
                    (
                        date: group.date,
                        sessions: Session.applyingFavoriteIds(group.sessions, favoriteIds: favoriteIds)
                    )
                }
                let allSessions = annotatedTimeline.flatMap(\.sessions)
                let parentIds = allSessions.map(\.id)
                let confirmed = try database.childCount(parentIds: parentIds)
                let suggested = try database.suggestedChildCount(parentIds: parentIds)
                let work = try database.implementationTimeline(
                    days: days,
                    project: selectedProjectFilter,
                    humanDriven: humanDriven,
                    now: now
                )
                return (
                    timeline: annotatedTimeline,
                    chart: tl.dailyCounts,
                    totalCount: tl.totalCount,
                    hasMore: tl.hasMore,
                    confirmed: confirmed,
                    suggested: suggested,
                    work: work,
                    projects: projects,
                    range: requestedRange,
                    mode: mode,
                    sort: requestedSort,
                    selectedProject: reconciledProject
                )
            }.value
            guard Self.shouldApplyLoad(
                resultGeneration: requestGeneration,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            timeline = data.timeline
            sessionChartData = data.chart
            timelineTotalCount = data.totalCount
            timelineShownCount = data.timeline.reduce(0) { $0 + $1.sessions.count }
            timelineHasMore = data.hasMore
            confirmedCounts = data.confirmed
            suggestedCounts = data.suggested
            workTimeline = data.work
            availableProjects = data.projects
            selectedProject = data.selectedProject
            appliedProject = data.selectedProject
            appliedRange = data.range
            appliedMode = data.mode
            appliedSort = data.sort
            loadError = nil
        } catch {
            guard Self.shouldApplyLoad(
                resultGeneration: requestGeneration,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            EngramLogger.error("TimelinePage load failed", module: .ui, error: error)
            if !preservePagination {
                clearVisibleSnapshot()
                appliedProject = selectedProject
                appliedRange = range
                appliedMode = timelineMode
                appliedSort = sortMode
            }
            loadError = ServiceErrorPresenter.displayMessage(for: error)
        }
    }

    private func clearVisibleSnapshot() {
        timeline = []
        sessionChartData = []
        workTimeline = []
        confirmedCounts = [:]
        suggestedCounts = [:]
        timelineTotalCount = 0
        timelineShownCount = 0
        timelineHasMore = false
    }

    private func confirmSuggestion(_ child: Session) {
        Task {
            do {
                let response = try await serviceClient.confirmSuggestion(sessionId: child.id)
                guard response.ok else {
                    actionStatus = response.error ?? "Failed to confirm suggestion"
                    return
                }
                await loadData(preservePagination: true)
            } catch {
                EngramLogger.error("TimelinePage confirm suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
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
                await loadData(preservePagination: true)
            } catch {
                EngramLogger.error("TimelinePage dismiss suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    private func beginRename(_ session: Session) {
        renameText = session.customName ?? session.displayTitle
        renameTarget = session
    }

    /// The navigation notification shared by tap and keyboard. Static and pure
    /// so tests can verify the contract without a service client (Wave 8-1).
    static func openNotification(for session: Session) -> Notification {
        Notification(name: .openSession, object: SessionBox(session))
    }

    /// Shared by card tap and keyboard Enter/Space so both paths record access
    /// and navigate identically.
    func open(_ session: Session) {
        handlers.recordAccess(session)
        NotificationCenter.default.post(Self.openNotification(for: session))
    }

    private func formatDateLabel(_ dateStr: String) -> String {
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }
        let now = fixedDate ?? Date()
        if Calendar.current.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
           Calendar.current.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return Self.outputDateFormatter.string(from: date)
    }

    private func formatWorkDateRange(_ item: ImplementationTimelineItem) -> String {
        let start = formatDateLabel(item.startDate)
        let end = formatDateLabel(item.endDate)
        return item.startDate == item.endDate ? start : "\(start) - \(end)"
    }

    private func kindLabel(_ kind: SessionImplementationKind) -> String {
        switch kind {
        case .implementation: String(localized: "Feature")
        case .fix: String(localized: "Fix")
        case .optimization: String(localized: "Optimize")
        case .security: String(localized: "Security")
        case .research: String(localized: "Research")
        case .maintenance: String(localized: "Maintenance")
        case .deployment: String(localized: "Deploy")
        case .verification: String(localized: "Verify")
        }
    }

    private func emptyMessage(for mode: TimelineMode) -> String {
        switch mode {
        case .work:
            String(localized: "No summarized work in this range")
        case .sessions:
            String(localized: "No sessions in this range")
        }
    }

    private func sessionCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld sessions"), count)
    }
}

private struct WorkTimelineCard: View {
    let item: ImplementationTimelineItem
    let dateLabel: String
    let kindLabel: String

    private var outcome: String {
        item.beats.last?.assistantOutcome.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dateLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Text(kindLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceHighlight)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                if item.batchIndex > 1 {
                    Text(String.localizedStringWithFormat(String(localized: "Batch %lld"), item.batchIndex))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 8)
                Text(String.localizedStringWithFormat(String(localized: "%lld sessions"), item.beats.count))
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }

            Text(item.title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)

            if !outcome.isEmpty {
                Text(outcome)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        // One VoiceOver stop per card instead of five disconnected text runs.
        .accessibilityElement(children: .combine)
    }
}
