// macos/Engram/Views/Pages/SearchPageView.swift
import SwiftUI

struct SearchPageView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var query = ""
    @State private var selectedMode: SearchMode = .hybrid
    @State private var results: [SearchResult] = []
    @State private var searchModes: [String] = []
    @State private var warning: String? = nil
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var embeddingStatus: EmbeddingStatus? = nil

    enum SearchMode: String, CaseIterable {
        case hybrid, keyword, semantic
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField("Search sessions...", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { triggerSearch() }
                    if !query.isEmpty {
                        Button(action: { query = ""; results = []; searchModes = [] }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiaryText)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("search_input")

                // Mode selector + embedding status
                HStack(spacing: 12) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
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
                    EmptyState(icon: "magnifyingglass", title: "Search sessions", message: "Hybrid search combines keyword (FTS), semantic (embeddings), and Viking")
                        .accessibilityIdentifier("search_emptyState")
                } else {
                    Text("\(results.count) results")
                        .font(.caption).foregroundStyle(Theme.tertiaryText)
                        .accessibilityIdentifier("search_resultCount")
                    LazyVStack(spacing: 4) {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                if let session = result.session {
                                    SessionCard(session: session) {
                                        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                    }
                                }
                                if !result.snippet.isEmpty {
                                    HStack(spacing: 6) {
                                        matchBadge(result.matchType)
                                        Text(cleanSnippet(result.snippet))
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
                    .accessibilityIdentifier("search_results")
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("search_container")
        .task { await loadEmbeddingStatus() }
        .onChange(of: query) { _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await performSearch()
            }
        }
    }

    // MARK: - Search

    private func triggerSearch() {
        searchTask?.cancel()
        searchTask = Task { await performSearch() }
    }

    private func performSearch() async {
        guard query.count >= 2 else { results = []; return }
        isSearching = true
        defer { isSearching = false }

        let port = UserDefaults.standard.integer(forKey: "httpPort")
        let webPort = port > 0 ? port : 3457

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:\(webPort)/api/search?q=\(encoded)&mode=\(selectedMode.rawValue)&limit=30") else { return }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(SearchAPIResponse.self, from: data)

            searchModes = response.searchModes ?? []
            warning = response.warning
            results = (response.results ?? []).compactMap { r in
                guard let sess = r.session else { return nil }
                let session = Session(
                    id: sess.id,
                    source: sess.source ?? "unknown",
                    startTime: sess.startTime ?? "",
                    endTime: sess.endTime,
                    cwd: sess.cwd ?? "",
                    project: sess.project,
                    model: sess.model,
                    messageCount: sess.messageCount ?? 0,
                    userMessageCount: sess.userMessageCount ?? 0,
                    assistantMessageCount: sess.assistantMessageCount ?? 0,
                    systemMessageCount: sess.systemMessageCount ?? 0,
                    summary: sess.summary,
                    filePath: sess.filePath ?? "",
                    sizeBytes: sess.sizeBytes ?? 0,
                    indexedAt: sess.indexedAt ?? "",
                    agentRole: sess.agentRole,
                    hiddenAt: nil,
                    customName: nil,
                    tier: nil,
                    toolMessageCount: 0,
                    generatedTitle: nil
                )
                return SearchResult(
                    id: sess.id,
                    session: session,
                    snippet: r.snippet ?? "",
                    matchType: r.matchType ?? "keyword",
                    score: r.score ?? 0
                )
            }
        } catch {
            // Fallback to local FTS
            do {
                let localResults = try db.search(query: query, limit: 30)
                searchModes = ["keyword (offline)"]
                warning = nil
                results = localResults.map { s in
                    SearchResult(id: s.id, session: s, snippet: "", matchType: "keyword", score: 0)
                }
            } catch {
                print("SearchPage error:", error)
            }
        }
    }

    // MARK: - Embedding Status

    private func loadEmbeddingStatus() async {
        let port = UserDefaults.standard.integer(forKey: "httpPort")
        let webPort = port > 0 ? port : 3457
        guard let url = URL(string: "http://127.0.0.1:\(webPort)/api/search/status") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            let resp = try JSONDecoder().decode(EmbeddingStatusResponse.self, from: data)
            embeddingStatus = EmbeddingStatus(
                available: resp.available,
                model: resp.model,
                embeddedCount: resp.embeddedCount ?? 0,
                totalSessions: resp.totalSessions ?? 0,
                progress: resp.progress ?? 0
            )
        } catch {
            embeddingStatus = nil
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

    private func cleanSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// SearchResult and EmbeddingStatus are defined in SearchView.swift (shared with Popover)
