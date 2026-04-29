// macos/Engram/Views/SearchView.swift
import SwiftUI

enum SearchMode: String, CaseIterable {
    case hybrid, keyword, semantic
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

struct SearchView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchModes: [String] = []
    @State private var warning: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedMode: SearchMode = .hybrid
    @State private var embeddingStatus: EmbeddingStatus?

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

            // Mode toggle
            HStack(spacing: 4) {
                ForEach(SearchMode.allCases, id: \.self) { mode in
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
                                Text(cleanSnippet(result.snippet))
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
                // Fallback to local FTS — run query off main thread
                // CJK: use LIKE (trigram MATCH broken for CJK byte alignment)
                let db = self.db
                let isCJK = q.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
                let sessions: [Session] = (try? await Task.detached {
                    if isCJK {
                        return try db.readInBackground { d in
                            try Session.fetchAll(d, sql: """
                                SELECT DISTINCT s.* FROM sessions_fts f
                                JOIN sessions s ON s.id = f.session_id
                                WHERE f.content LIKE ? AND s.hidden_at IS NULL
                                ORDER BY s.start_time DESC
                                LIMIT 20
                            """, arguments: ["%\(q)%"])
                        }
                    } else {
                        return try db.readInBackground { d in
                            try Session.fetchAll(d, sql: """
                                SELECT s.* FROM sessions_fts f
                                JOIN sessions s ON s.id = f.session_id
                                WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
                                LIMIT 20
                            """, arguments: [q])
                        }
                    }
                }.value) ?? []
                await MainActor.run {
                    searchModes = ["keyword (offline)"]
                    warning = nil
                    results = sessions.map { s in
                        SearchResult(id: s.id, session: s, snippet: "", matchType: "keyword", score: 0)
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

    func cleanSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
            origin: nil,
            hiddenAt: nil,
            customName: customName,
            tier: tier,
            toolMessageCount: toolMessageCount ?? 0,
            generatedTitle: generatedTitle ?? title,
            parentSessionId: parentSessionId,
            suggestedParentId: suggestedParentId,
            linkSource: linkSource
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
