// macos/Engram/Views/SearchView.swift
import SwiftUI

enum SearchMode: String, CaseIterable {
    case hybrid, keyword, semantic

    /// Modes the product can actually serve. Semantic/hybrid require vector
    /// embeddings (sqlite-vec), which the Swift product does not implement yet,
    /// so when embeddings are unavailable only keyword is offered — no false
    /// promise. When embeddings become available the richer modes return.
    static func availableModes(embeddingAvailable: Bool) -> [SearchMode] {
        embeddingAvailable ? [.hybrid, .keyword, .semantic] : [.keyword]
    }
}

struct EmbeddingStatus {
    let available: Bool
    let model: String?
    let embeddedCount: Int
    let totalSessions: Int
    let progress: Int
}

struct SearchResult: Identifiable {
    let id: String
    let session: Session?
    let snippet: String
    let matchType: String
    let score: Double
}

/// Renders an FTS5 search snippet that may contain `<mark>…</mark>` highlight
/// tags into an `AttributedString`: matched runs are bolded so they stand out
/// against the secondary-styled snippet body, and the tags are removed. Unlike
/// the previous `cleanSnippet` regex, other `<…>` text is preserved verbatim —
/// the FTS snippet only emits `<mark>` markers, so any other angle brackets are
/// real transcript content, not tags to strip.
enum SnippetHighlighter {
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: "<mark>") {
            result.append(AttributedString(String(rest[..<open.lowerBound])))
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "</mark>") else {
                result.append(AttributedString(String(afterOpen)))
                return result
            }
            var marked = AttributedString(String(afterOpen[..<close.lowerBound]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            result.append(marked)
            rest = afterOpen[close.upperBound...]
        }
        result.append(AttributedString(String(rest)))
        return result
    }
}

struct SearchView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchModes: [String] = []
    @State private var warning: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedMode: SearchMode = .keyword
    @State private var embeddingStatus: EmbeddingStatus?

    private var availableModes: [SearchMode] {
        SearchMode.availableModes(embeddingAvailable: embeddingStatus?.available ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Embedding status
            embeddingStatusBar
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search sessions...", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        searchModes = []
                        warning = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            // Mode toggle — only shown when more than one mode is actually
            // serviceable (i.e. embeddings available). Keyword-only = no toggle.
            HStack(spacing: 4) {
                if availableModes.count > 1 {
                    ForEach(availableModes, id: \.self) { mode in
                        Button {
                            selectedMode = mode
                            if query.count >= 2 { performSearch() }
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selectedMode == mode ? Color.purple : Color(nsColor: .controlBackgroundColor))
                                .foregroundStyle(selectedMode == mode ? .white : .secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                // Search modes indicator
                if !searchModes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(searchModes, id: \.self) { mode in
                            Text(mode)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(modeColor(mode).opacity(0.15))
                                .foregroundStyle(modeColor(mode))
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Warning
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            // Results
            if results.isEmpty && query.count >= 2 && !isSearching {
                ContentUnavailableView.search(text: query)
            } else {
                List(results) { result in
                    if let session = result.session {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.displayTitle)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                matchBadge(result.matchType)
                            }
                            if !result.snippet.isEmpty {
                                Text(SnippetHighlighter.attributed(result.snippet))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 8) {
                                SourceBadge(source: session.source)
                                Text(session.displayDate)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(session.msgCountLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onChange(of: query) { _, new in
            searchTask?.cancel()
            if new.count >= 2 {
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    performSearch()
                }
            } else if new.isEmpty {
                results = []
                searchModes = []
                warning = nil
            }
        }
        .onAppear { loadEmbeddingStatus() }
    }

    // MARK: - Embedding status bar

    @ViewBuilder
    var embeddingStatusBar: some View {
        if let status = embeddingStatus {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.available ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
                if status.available {
                    Text(status.model ?? "embedding")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(status.embeddedCount)/\(status.totalSessions) sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if status.progress < 100 {
                        ProgressView(value: Double(status.progress), total: 100)
                            .frame(width: 80)
                        Text("\(status.progress)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Semantic search unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Service

    func loadEmbeddingStatus() {
        Task {
            do {
                let resp = try await serviceClient.embeddingStatus()
                await MainActor.run {
                    embeddingStatus = EmbeddingStatus(
                        available: resp.available,
                        model: resp.model,
                        embeddedCount: resp.embeddedCount,
                        totalSessions: resp.totalSessions,
                        progress: resp.progress
                    )
                    if !availableModes.contains(selectedMode) {
                        selectedMode = .keyword
                    }
                }
            } catch {
                await MainActor.run {
                    embeddingStatus = EmbeddingStatus(available: false, model: nil, embeddedCount: 0, totalSessions: 0, progress: 0)
                }
            }
        }
    }

    func performSearch() {
        guard query.count >= 2 else { return }
        isSearching = true

        let q = query
        let mode = selectedMode.rawValue
        Task {
            defer { isSearching = false }

            do {
                let response = try await serviceClient.search(
                    EngramServiceSearchRequest(query: q, mode: mode, limit: 20)
                )

                await MainActor.run {
                    searchModes = response.searchModes ?? []
                    warning = response.warning
                    results = response.items.map(\.searchResult)
                }
            } catch {
                // Fallback to local FTS — run query off main thread. Shares the
                // DatabaseManager search path so offline results get the same
                // <mark> highlighted snippets (and LIKE escaping / dedup) as the
                // service path, instead of an empty snippet.
                let db = self.db
                let hits = (try? await Task.detached {
                    try db.searchWithSnippets(query: q, limit: 20)
                }.value) ?? []
                await MainActor.run {
                    searchModes = ["keyword (offline)"]
                    warning = nil
                    results = hits.map { r in
                        SearchResult(id: r.session.id, session: r.session, snippet: r.snippet, matchType: "keyword", score: 0)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    func matchBadge(_ type: String) -> some View {
        Text(type == "both" ? "keyword + semantic" : type)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(modeColor(type).opacity(0.15))
            .foregroundStyle(modeColor(type))
            .clipShape(Capsule())
    }

    func modeColor(_ mode: String) -> Color {
        switch mode {
        case "keyword": return .blue
        case "semantic": return .purple
        case "both", "hybrid": return .green
        default: return .secondary
        }
    }

}

extension EngramServiceSearchResponse.Item {
    var searchResult: SearchResult {
        let totalMessages = messageCount
            ?? [userMessageCount, assistantMessageCount, systemMessageCount, toolMessageCount]
                .compactMap(\.self)
                .reduce(0, +)
        let session = Session(
            id: id,
            source: source ?? "unknown",
            startTime: startTime ?? "",
            endTime: endTime,
            cwd: cwd ?? "",
            project: project,
            model: model,
            messageCount: totalMessages,
            userMessageCount: userMessageCount ?? 0,
            assistantMessageCount: assistantMessageCount ?? 0,
            systemMessageCount: systemMessageCount ?? 0,
            summary: summary ?? title,
            filePath: filePath ?? "",
            sourceLocator: sourceLocator,
            sizeBytes: sizeBytes ?? 0,
            indexedAt: indexedAt ?? "",
            agentRole: agentRole,
            hiddenAt: nil,
            customName: customName,
            tier: tier,
            toolMessageCount: toolMessageCount ?? 0,
            generatedTitle: generatedTitle ?? title,
            parentSessionId: parentSessionId,
            suggestedParentId: suggestedParentId,
            linkSource: linkSource,
            qualityScore: qualityScore
        )
        return SearchResult(
            id: id,
            session: session,
            snippet: snippet ?? "",
            matchType: matchType ?? "keyword",
            score: score ?? 0
        )
    }
}

// MARK: - Source badge

struct SourceBadge: View {
    let source: String

    private var label: String {
        SourceColors.label(for: source)
    }

    private var color: Color {
        SourceColors.color(for: source)
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
