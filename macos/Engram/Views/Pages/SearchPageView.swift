// macos/Engram/Views/Pages/SearchPageView.swift
import SwiftUI

private enum SearchTimeFilter: String, CaseIterable, Identifiable {
    case all
    case last7Days
    case last30Days
    case last90Days
    case lastYear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Any time"
        case .last7Days: return "7 days"
        case .last30Days: return "30 days"
        case .last90Days: return "90 days"
        case .lastYear: return "1 year"
        }
    }

    private var days: Int? {
        switch self {
        case .all: return nil
        case .last7Days: return 7
        case .last30Days: return 30
        case .last90Days: return 90
        case .lastYear: return 365
        }
    }

    func sinceString(now: Date = Date()) -> String? {
        guard let days,
              let date = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            return nil
        }
        return ISO8601DateFormatter().string(from: date)
    }
}

/// Result-state of a keyword search. `failed` distinguishes a real backend
/// fault (service AND local FTS both threw) from a genuine no-match so the UI
/// doesn't read a down index as "your data is missing".
enum SearchOutcome: Equatable {
    case empty, results, failed

    static func classify(query: String, results: [SearchResult], didFail: Bool) -> SearchOutcome {
        if didFail { return .failed }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return results.isEmpty ? .empty : .results
    }

    /// Result-agnostic overload for callers (e.g. CommandPaletteView) that track
    /// emptiness as a Bool rather than a `[SearchResult]` array. Same precedence:
    /// a real backend fault wins over both empty query and no-match.
    static func classify(query: String, isEmptyResults: Bool, didFail: Bool) -> SearchOutcome {
        if didFail { return .failed }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return isEmptyResults ? .empty : .results
    }
}

struct SearchPageView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    private let lockedProject: String?
    private let embeddedInParentScroll: Bool
    private let contentPadding: CGFloat

    @State private var query = ""
    @State private var selectedProjectFilter: String?
    @State private var selectedSourceFilter: String?
    @State private var selectedTimeFilter: SearchTimeFilter = .all
    @State private var selectedTaxonomyFilter: SessionTaxonomyFilter = .all
    @State private var projectFilters: [(name: String, count: Int)] = []
    @State private var sourceFilters: [(name: String, count: Int)] = []
    @State private var results: [SearchResult] = []
    @State private var resultConfirmedCounts: [String: Int] = [:]
    @State private var resultSuggestedCounts: [String: Int] = [:]
    @State private var searchModes: [String] = []
    @State private var warning: String? = nil
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var showAdvancedFilters = false

    private var emptySearchMessage: String {
        "Search sessions by keyword"
    }

    private var searchOutcome: SearchOutcome {
        SearchOutcome.classify(query: query, results: results, didFail: searchFailed)
    }

    private var hasClearableFilters: Bool {
        selectedSourceFilter != nil
            || selectedTimeFilter != .all
            || selectedTaxonomyFilter != .all
            || (lockedProject == nil && selectedProjectFilter != nil)
    }

    init(
        projectFilter: String? = nil,
        locksProject: Bool = false,
        embeddedInParentScroll: Bool = false,
        contentPadding: CGFloat = 24
    ) {
        self.lockedProject = locksProject ? projectFilter : nil
        self.embeddedInParentScroll = embeddedInParentScroll
        self.contentPadding = contentPadding
        _selectedProjectFilter = State(initialValue: projectFilter)
    }

    var body: some View {
        Group {
            if embeddedInParentScroll {
                searchContent
                    .padding(contentPadding)
            } else {
                ScrollView {
                    searchContent
                        .padding(contentPadding)
                }
            }
        }
        .accessibilityIdentifier("search_container")
        .task {
            await loadFilterOptions()
        }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await performSearch()
            }
        }
        .onChange(of: selectedProjectFilter) { _, _ in triggerSearchIfReady() }
        .onChange(of: selectedSourceFilter) { _, _ in triggerSearchIfReady() }
        .onChange(of: selectedTimeFilter) { _, _ in triggerSearchIfReady() }
        .onChange(of: selectedTaxonomyFilter) { _, _ in triggerSearchIfReady() }
        .onDisappear { searchTask?.cancel(); searchTask = nil }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField("Search sessions...", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { triggerSearch() }
                    if !query.isEmpty {
                        Button(action: {
                            query = ""
                            results = []
                            resultConfirmedCounts = [:]
                            resultSuggestedCounts = [:]
                            searchModes = []
                            warning = nil
                            searchFailed = false
                        }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("search_input")

                advancedFilterDisclosure

                // Active search modes
                if !searchModes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(searchModes, id: \.self) { mode in
                            Text(mode)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(modeColor(mode).opacity(0.15))
                                .foregroundStyle(modeColor(mode))
                                .clipShape(Capsule())
                        }
                    }
                }

                if let warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Theme.orange)
                }

                // Results
                if isSearching {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Searching...").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                } else if searchOutcome == .failed {
                    EmptyState(icon: "exclamationmark.triangle", title: "Search unavailable", message: "Could not reach the index. Try again.")
                        .accessibilityIdentifier("search_emptyState")
                } else if searchOutcome == .empty && !query.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "No results", message: "Try a different search term")
                        .accessibilityIdentifier("search_emptyState")
                } else if searchOutcome == .empty {
                    EmptyState(icon: "magnifyingglass", title: "Search sessions", message: emptySearchMessage)
                        .accessibilityIdentifier("search_emptyState")
                } else {
                    Text("\(results.count) results")
                        .font(.caption).foregroundStyle(Theme.tertiaryText)
                        .accessibilityIdentifier("search_resultCount")
                    LazyVStack(spacing: 4) {
                        ForEach(results) { result in
                            HStack(spacing: 8) {
                                // Value-band cue: a thin colored bar on the row's
                                // leading edge (high=green, medium=neutral, low=dim,
                                // unknown=clear to keep alignment).
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(valueBandColor(result.session?.valueBand))
                                    .frame(width: 3)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    if let session = result.session {
                                        SessionCard(session: session) {
                                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session, searchTerm: query))
                                        }
                                        HStack(spacing: 4) {
                                            SessionTaxonomyBadges(
                                                session: session,
                                                confirmedChildCount: resultConfirmedCounts[session.id] ?? 0,
                                                suggestedChildCount: resultSuggestedCounts[session.id] ?? 0
                                            )
                                        }
                                        .padding(.horizontal, 12)
                                    }
                                    if !result.snippet.isEmpty {
                                        HStack(spacing: 6) {
                                            matchBadge(result.matchType)
                                            Text(SnippetHighlighter.attributed(result.snippet))
                                                .font(.caption)
                                                .foregroundStyle(Theme.tertiaryText)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 4)
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("search_results")
                }
        }
    }

    private var advancedFilterDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvancedFilters) {
            filterBar
                .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label("Advanced filters", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                if hasClearableFilters {
                    Text(activeFilterSummary)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                if hasClearableFilters {
                    Button {
                        clearFilters()
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search filters")
                    .accessibilityIdentifier("search_clearFilters")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 2)
        .accessibilityIdentifier("search_advancedFilters")
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            projectFilterControl
            sourceFilterControl
            timeFilterControl
            taxonomyFilterControl
            Spacer()
        }
        .controlSize(.small)
        .accessibilityIdentifier("search_filters")
    }

    private var activeFilterSummary: String {
        var parts: [String] = []
        if let selectedProjectFilter, lockedProject == nil {
            parts.append(projectLabel(selectedProjectFilter))
        }
        if let selectedSourceFilter {
            parts.append(SourceColors.label(for: selectedSourceFilter))
        }
        if selectedTimeFilter != .all {
            parts.append(selectedTimeFilter.label)
        }
        if selectedTaxonomyFilter != .all {
            parts.append(selectedTaxonomyFilter.label)
        }
        return parts.joined(separator: " · ")
    }

    private func clearFilters() {
        if lockedProject == nil {
            selectedProjectFilter = nil
        }
        selectedSourceFilter = nil
        selectedTimeFilter = .all
        selectedTaxonomyFilter = .all
    }

    @ViewBuilder
    private var projectFilterControl: some View {
        if let lockedProject {
            Label(projectLabel(lockedProject), systemImage: "folder")
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .help(lockedProject)
                .accessibilityIdentifier("search_projectFilter_locked")
        } else {
            Menu {
                Button("All projects") { selectedProjectFilter = nil }
                Divider()
                ForEach(projectFilters, id: \.name) { option in
                    Button {
                        selectedProjectFilter = option.name
                    } label: {
                        if selectedProjectFilter == option.name {
                            Label("\(option.name) (\(option.count))", systemImage: "checkmark")
                        } else {
                            Text("\(option.name) (\(option.count))")
                        }
                    }
                }
            } label: {
                Label(selectedProjectFilter.map(projectLabel) ?? "All projects", systemImage: "folder")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("search_projectFilter")
        }
    }

    private var sourceFilterControl: some View {
        Menu {
            Button("All tools") { selectedSourceFilter = nil }
            Divider()
            ForEach(sourceFilters, id: \.name) { option in
                Button {
                    selectedSourceFilter = option.name
                } label: {
                    let title = "\(SourceColors.label(for: option.name)) (\(option.count))"
                    if selectedSourceFilter == option.name {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(selectedSourceFilter.map { SourceColors.label(for: $0) } ?? "All tools", systemImage: "hammer")
                .lineLimit(1)
        }
        .accessibilityIdentifier("search_sourceFilter")
    }

    private var timeFilterControl: some View {
        Menu {
            ForEach(SearchTimeFilter.allCases) { option in
                Button {
                    selectedTimeFilter = option
                } label: {
                    if selectedTimeFilter == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label(selectedTimeFilter.label, systemImage: "calendar")
                .lineLimit(1)
        }
        .accessibilityIdentifier("search_timeFilter")
    }

    private var taxonomyFilterControl: some View {
        Menu {
            Button {
                selectedTaxonomyFilter = .all
            } label: {
                if selectedTaxonomyFilter == .all {
                    Label(SessionTaxonomyFilter.all.label, systemImage: "checkmark")
                } else {
                    Text(SessionTaxonomyFilter.all.label)
                }
            }
            Divider()
            ForEach(SessionTaxonomyFilter.allCases.filter { $0 != .all }) { option in
                Button {
                    guard option.isSupported else { return }
                    selectedTaxonomyFilter = option
                } label: {
                    if selectedTaxonomyFilter == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Label(option.label, systemImage: option.systemImage)
                    }
                }
                .disabled(!option.isSupported)
            }
        } label: {
            Label(selectedTaxonomyFilter.label, systemImage: selectedTaxonomyFilter.systemImage)
                .lineLimit(1)
        }
        .accessibilityIdentifier("search_taxonomyFilter")
    }

    // MARK: - Search

    private func triggerSearch() {
        searchTask?.cancel()
        searchTask = Task { await performSearch() }
    }

    private func triggerSearchIfReady() {
        guard query.count >= 2 else { return }
        triggerSearch()
    }

    private func performSearch() async {
        guard query.count >= 2 else {
            results = []
            resultConfirmedCounts = [:]
            resultSuggestedCounts = [:]
            searchFailed = false
            return
        }
        isSearching = true
        searchFailed = false
        defer { isSearching = false }

        do {
            if let taxonomy = selectedTaxonomyFilter.tag {
                let db = self.db
                let localQuery = query
                let localSources = selectedSourceFilter.map { Set([$0]) } ?? []
                let localProjects = selectedProjectFilter.map { Set([$0]) } ?? []
                let localSince = selectedTimeFilter.sinceString()
                let localResults = try await Task.detached {
                    try db.searchWithSnippets(
                        query: localQuery,
                        limit: 30,
                        sources: localSources,
                        projects: localProjects,
                        since: localSince,
                        taxonomy: taxonomy
                    )
                }.value
                guard !Task.isCancelled else { return }
                let mapped = localResults.map { r in
                    SearchResult(id: r.session.id, session: r.session, snippet: r.snippet, matchType: "keyword", score: 0)
                }
                let decorated = await filterSearchResults(mapped, filter: selectedTaxonomyFilter)
                guard !Task.isCancelled else { return }
                searchModes = ["keyword (local taxonomy)"]
                warning = nil
                results = decorated.results
                resultConfirmedCounts = decorated.confirmedCounts
                resultSuggestedCounts = decorated.suggestedCounts
                return
            }

            let response = try await serviceClient.search(
                EngramServiceSearchRequest(
                    query: query,
                    mode: "keyword",
                    limit: 30,
                    project: selectedProjectFilter,
                    source: selectedSourceFilter,
                    since: selectedTimeFilter.sinceString()
                )
            )

            // A slower in-flight search must not clobber the results of a newer
            // query that superseded it: triggerSearch cancels this task, but the
            // round-trip already returned, so guard before mutating @State.
            guard !Task.isCancelled else { return }
            let mapped = response.items.map(\.searchResult)
            let decorated = await filterSearchResults(mapped, filter: selectedTaxonomyFilter)
            guard !Task.isCancelled else { return }
            searchModes = response.searchModes ?? []
            warning = response.warning
            results = decorated.results
            resultConfirmedCounts = decorated.confirmedCounts
            resultSuggestedCounts = decorated.suggestedCounts
        } catch {
            // Fallback to local FTS
            do {
                let db = self.db
                let fallbackQuery = query
                let fallbackSources = selectedSourceFilter.map { Set([$0]) } ?? []
                let fallbackProjects = selectedProjectFilter.map { Set([$0]) } ?? []
                let fallbackSince = selectedTimeFilter.sinceString()
                let localResults = try await Task.detached {
                    try db.searchWithSnippets(
                        query: fallbackQuery,
                        limit: 30,
                        sources: fallbackSources,
                        projects: fallbackProjects,
                        since: fallbackSince,
                        taxonomy: selectedTaxonomyFilter.tag
                    )
                }.value
                guard !Task.isCancelled else { return }
                let mapped = localResults.map { r in
                    SearchResult(id: r.session.id, session: r.session, snippet: r.snippet, matchType: "keyword", score: 0)
                }
                let decorated = await filterSearchResults(mapped, filter: selectedTaxonomyFilter)
                guard !Task.isCancelled else { return }
                searchModes = selectedTaxonomyFilter.tag == nil
                    ? ["keyword (offline)"]
                    : ["keyword (offline taxonomy)"]
                warning = nil
                results = decorated.results
                resultConfirmedCounts = decorated.confirmedCounts
                resultSuggestedCounts = decorated.suggestedCounts
            } catch {
                // Double-fault: service AND local FTS both threw. Surface a real
                // failure state instead of a misleading "No results".
                EngramLogger.error("SearchPage fallback search failed", module: .ui, error: error)
                guard !Task.isCancelled else { return }
                searchFailed = true
                results = []
                resultConfirmedCounts = [:]
                resultSuggestedCounts = [:]
            }
        }
    }

    private func filterSearchResults(
        _ candidates: [SearchResult],
        filter: SessionTaxonomyFilter
    ) async -> (results: [SearchResult], confirmedCounts: [String: Int], suggestedCounts: [String: Int]) {
        let sessionIds = candidates.compactMap(\.session?.id)
        guard !sessionIds.isEmpty else { return (candidates, [:], [:]) }
        let db = self.db
        let counts: ([String: Int], [String: Int]) = (try? await Task.detached {
            let confirmed = try db.childCount(parentIds: sessionIds)
            let suggested = try db.suggestedChildCount(parentIds: sessionIds)
            return (confirmed, suggested)
        }.value) ?? ([String: Int](), [String: Int]())
        let filtered = candidates.filter { result in
            guard let session = result.session else { return filter == .all }
            return filter.matches(
                session,
                confirmedChildCount: counts.0[session.id] ?? 0,
                suggestedChildCount: counts.1[session.id] ?? 0
            )
        }
        return (filtered, counts.0, counts.1)
    }

    private func loadFilterOptions() async {
        let db = self.db
        do {
            let (projects, sources) = try await Task.detached {
                let projects = try db.countsByProject()
                    .map { (name: $0.key, count: $0.value) }
                    .sorted { $0.name < $1.name }
                let sources = try db.sourceStats()
                    .map { (name: $0.source, count: $0.count) }
                    .sorted { $0.name < $1.name }
                return (projects, sources)
            }.value
            projectFilters = projects
            sourceFilters = sources
        } catch {
            EngramLogger.error("SearchPage filter load failed", module: .ui, error: error)
        }
    }

    // MARK: - Helpers

    private func matchBadge(_ type: String) -> some View {
        Text(type == "both" ? "keyword + semantic" : type)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(modeColor(type).opacity(0.15))
            .foregroundStyle(modeColor(type))
            .clipShape(Capsule())
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode {
        case "keyword": return .blue
        case "semantic": return .purple
        case "both", "hybrid": return Theme.green
        default: return .secondary
        }
    }

    private func projectLabel(_ project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    /// Leading value-band bar color (from Session.qualityScore). `.clear` for
    /// unknown so the bar still reserves width and result titles stay aligned.
    private func valueBandColor(_ band: Session.ValueBand?) -> Color {
        switch band {
        case .high: return Theme.green
        case .medium: return Theme.tertiaryText
        case .low: return Theme.tertiaryText.opacity(0.4)
        case .unknown, .none: return .clear
        }
    }
}

// SearchResult and SnippetHighlighter are defined in SearchSupport.swift.
