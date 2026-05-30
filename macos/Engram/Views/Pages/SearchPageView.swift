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

struct SearchPageView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    private let lockedProject: String?
    private let embeddedInParentScroll: Bool
    private let contentPadding: CGFloat

    @State private var query = ""
    @State private var selectedMode: SearchMode = .keyword
    @State private var selectedProjectFilter: String?
    @State private var selectedSourceFilter: String?
    @State private var selectedTimeFilter: SearchTimeFilter = .all
    @State private var projectFilters: [(name: String, count: Int)] = []
    @State private var sourceFilters: [(name: String, count: Int)] = []
    @State private var results: [SearchResult] = []
    @State private var searchModes: [String] = []
    @State private var warning: String? = nil
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var embeddingStatus: EmbeddingStatus? = nil

    private var availableModes: [SearchMode] {
        SearchMode.availableModes(embeddingAvailable: embeddingStatus?.available ?? false)
    }

    private var emptySearchMessage: String {
        embeddingStatus?.available == true
            ? "Search sessions by keyword, semantic meaning, or both"
            : "Search sessions by keyword"
    }

    private var hasClearableFilters: Bool {
        selectedSourceFilter != nil || selectedTimeFilter != .all || (lockedProject == nil && selectedProjectFilter != nil)
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
            await loadEmbeddingStatus()
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
                        Button(action: { query = ""; results = []; searchModes = []; warning = nil }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("search_input")

                filterBar

                // Mode selector + embedding status
                HStack(spacing: 12) {
                    if availableModes.count > 1 {
                        ForEach(availableModes, id: \.self) { mode in
                            Button(action: { selectedMode = mode; triggerSearch() }) {
                                Text(mode.rawValue.capitalized)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedMode == mode
                                        ? Theme.accent.opacity(0.25)
                                        : Theme.surface)
                                    .foregroundStyle(selectedMode == mode
                                        ? Theme.sidebarSelectedText
                                        : Theme.secondaryText)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    if let status = embeddingStatus, status.available {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.green).frame(width: 6, height: 6)
                            Text("\(status.embeddedCount)/\(status.totalSessions) embedded")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }

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
                } else if results.isEmpty && !query.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "No results", message: "Try a different search term or mode")
                        .accessibilityIdentifier("search_emptyState")
                } else if results.isEmpty && query.isEmpty {
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
                                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                        }
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

    private var filterBar: some View {
        HStack(spacing: 8) {
            projectFilterControl
            sourceFilterControl
            timeFilterControl
            if hasClearableFilters {
                Button {
                    if lockedProject == nil {
                        selectedProjectFilter = nil
                    }
                    selectedSourceFilter = nil
                    selectedTimeFilter = .all
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .help("Clear search filters")
                .accessibilityIdentifier("search_clearFilters")
            }
            Spacer()
        }
        .controlSize(.small)
        .accessibilityIdentifier("search_filters")
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
        guard query.count >= 2 else { results = []; return }
        if !availableModes.contains(selectedMode) {
            selectedMode = availableModes.first ?? .keyword
        }
        isSearching = true
        defer { isSearching = false }

        do {
            let response = try await serviceClient.search(
                EngramServiceSearchRequest(
                    query: query,
                    mode: selectedMode.rawValue,
                    limit: 30,
                    project: selectedProjectFilter,
                    source: selectedSourceFilter,
                    since: selectedTimeFilter.sinceString()
                )
            )

            searchModes = response.searchModes ?? []
            warning = response.warning
            results = response.items.map(\.searchResult)
        } catch {
            // Fallback to local FTS
            do {
                let localResults = try db.searchWithSnippets(
                    query: query,
                    limit: 30,
                    sources: selectedSourceFilter.map { Set([$0]) } ?? [],
                    projects: selectedProjectFilter.map { Set([$0]) } ?? [],
                    since: selectedTimeFilter.sinceString()
                )
                searchModes = ["keyword (offline)"]
                warning = nil
                results = localResults.map { r in
                    SearchResult(id: r.session.id, session: r.session, snippet: r.snippet, matchType: "keyword", score: 0)
                }
            } catch {
                EngramLogger.error("SearchPage fallback search failed", module: .ui, error: error)
            }
        }
    }

    // MARK: - Embedding Status

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

    private func loadEmbeddingStatus() async {
        do {
            let resp = try await serviceClient.embeddingStatus()
            embeddingStatus = EmbeddingStatus(
                available: resp.available,
                model: resp.model,
                embeddedCount: resp.embeddedCount,
                totalSessions: resp.totalSessions,
                progress: resp.progress
            )
            if !availableModes.contains(selectedMode) {
                selectedMode = availableModes.first ?? .keyword
            }
        } catch {
            embeddingStatus = nil
            if selectedMode != .keyword {
                selectedMode = .keyword
            }
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

// SearchResult and EmbeddingStatus are defined in SearchView.swift (shared with Popover)
