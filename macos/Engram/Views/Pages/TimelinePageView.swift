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
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    // Shared global escape hatch (see SessionsPageView).
    @AppStorage("sessions.showAll") private var showAllSessions = false
    @State private var timeline: [(date: String, sessions: [Session])] = []
    @State private var workTimeline: [ImplementationTimelineItem] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var timelineMode: TimelineMode = .work
    @State private var sortMode: TimelineSortMode = .activity
    @State private var range: TimelineRange = .month
    @State private var selectedProject: String = timelineAllProjects
    @State private var loadError: String? = nil
    @State private var isLoading = true
    // Debounce/coalesce index-tick reloads vs. immediate filter-change reloads (#3).
    @State private var lastFilterKey: [AnyHashable]? = nil
    // Session-action sheet targets + transient status banner.
    @State private var resumeTarget: Session? = nil
    @State private var replayTarget: Session? = nil
    @State private var renameTarget: Session? = nil
    @State private var renameText = ""
    @State private var actionStatus: String? = nil
    @State private var exportState: SessionExportState = .idle

    private var handlers: SessionActionHandlers {
        SessionActionHandlers(
            serviceClient: serviceClient,
            reload: { await loadData() },
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

    // Distinct projects across the loaded window, for the client-side filter.
    private var projectOptions: [String] {
        let names = Set(timeline.flatMap(\.sessions).compactMap(\.project))
        return [timelineAllProjects] + names.sorted()
    }

    // Timeline filtered client-side by the selected project (timeline-4).
    private var filteredTimeline: [(date: String, sessions: [Session])] {
        guard selectedProject != timelineAllProjects else { return timeline }
        return timeline.compactMap { group in
            let matched = group.sessions.filter { $0.project == selectedProject }
            return matched.isEmpty ? nil : (date: group.date, sessions: matched)
        }
    }

    // Per-day session counts for the chart band (timeline-1).
    private var chartData: [(date: String, count: Int)] {
        filteredTimeline.reversed().map { (date: $0.date, count: $0.sessions.count) }
    }

    private var workChartData: [(date: String, count: Int)] {
        let grouped = Dictionary(grouping: workTimeline, by: \.startDate)
        return grouped
            .map { (date: $0.key, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }

    private var visibleChartData: [(date: String, count: Int)] {
        timelineMode == .work ? workChartData : chartData
    }

    private var hasVisibleContent: Bool {
        timelineMode == .work ? !workTimeline.isEmpty : !filteredTimeline.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeader(icon: "chart.bar.xaxis", title: "Timeline", badge: range.badge)
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
                if projectOptions.count > 1 {
                    Picker("Project", selection: $selectedProject) {
                        ForEach(projectOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280, alignment: .leading)
                    .accessibilityIdentifier("timeline_projectPicker")
                }
                if let loadError {
                    AlertBanner(message: "Failed to load timeline: \(loadError)")
                        .accessibilityIdentifier("timeline_loadError")
                }
                if let actionStatus {
                    AlertBanner(message: actionStatus)
                        .accessibilityIdentifier("timeline_actionStatus")
                }
                SessionExportStatusBanner(state: exportState)
                    .accessibilityIdentifier("timeline_exportStatus")
                if !visibleChartData.isEmpty {
                    ActivityChart(data: visibleChartData)
                        .frame(height: 120)
                        .accessibilityIdentifier("timeline_chart")
                }
                if isLoading && !hasVisibleContent {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("timeline_loading")
                } else if !hasVisibleContent && loadError == nil && !isLoading {
                    EmptyState(icon: "calendar", title: "No activity", message: emptyMessage)
                        .accessibilityIdentifier("timeline_emptyState")
                } else if timelineMode == .work {
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
                        ForEach(filteredTimeline, id: \.date) { group in
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
            AnyHashable(serviceStatusStore.totalSessions)
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
            await loadData()
        }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let database = db
            let sort = sortMode.databaseSort
            let days = range.days
            let humanDriven = !showAllSessions
            let selectedProjectFilter = selectedProject == timelineAllProjects ? nil : selectedProject
            let data = try await Task.detached { [database, sort, days, humanDriven, selectedProjectFilter] in
                let tl = try database.sessionTimeline(days: days, sort: sort, humanDriven: humanDriven)
                let allSessions = tl.flatMap(\.sessions)
                let parentIds = allSessions.map(\.id)
                let confirmed = try database.childCount(parentIds: parentIds)
                let suggested = try database.suggestedChildCount(parentIds: parentIds)
                let work = try database.implementationTimeline(days: days, project: selectedProjectFilter, humanDriven: humanDriven)
                return (tl, confirmed, suggested, work)
            }.value
            timeline = data.0
            confirmedCounts = data.1
            suggestedCounts = data.2
            workTimeline = data.3
            loadError = nil
        } catch {
            EngramLogger.error("TimelinePage load failed", module: .ui, error: error)
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
                EngramLogger.error("TimelinePage confirm suggestion failed", module: .ui, error: error)
                loadError = error.localizedDescription
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
                EngramLogger.error("TimelinePage dismiss suggestion failed", module: .ui, error: error)
                loadError = error.localizedDescription
            }
        }
    }

    private func beginRename(_ session: Session) {
        renameText = session.customName ?? session.displayTitle
        renameTarget = session
    }

    private func formatDateLabel(_ dateStr: String) -> String {
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
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

    private var emptyMessage: String {
        switch timelineMode {
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
    }
}
