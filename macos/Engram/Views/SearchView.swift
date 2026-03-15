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
    @EnvironmentObject var db: DatabaseManager
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searchModes: [String] = []
    @State private var warning: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedMode: SearchMode = .hybrid
    @State private var embeddingStatus: EmbeddingStatus?

    @State private var webPort: Int = 3457

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
        .task {
            let configPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".engram/settings.json")
            if let data = try? Data(contentsOf: configPath),
               let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = settings["httpPort"] as? Int {
                webPort = port
            }
        }
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

    // MARK: - Network

    func loadEmbeddingStatus() {
        let port = webPort
        Task {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/search/status") else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, _) = try await URLSession.shared.data(for: request)
                let resp = try JSONDecoder().decode(EmbeddingStatusResponse.self, from: data)
                await MainActor.run {
                    embeddingStatus = EmbeddingStatus(
                        available: resp.available,
                        model: resp.model,
                        embeddedCount: resp.embeddedCount ?? 0,
                        totalSessions: resp.totalSessions ?? 0,
                        progress: resp.progress ?? 0
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
        let port = webPort
        let mode = selectedMode.rawValue
        Task {
            defer { isSearching = false }

            guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "http://127.0.0.1:\(port)/api/search?q=\(encoded)&mode=\(mode)&limit=20") else { return }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(SearchAPIResponse.self, from: data)

                await MainActor.run {
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
                            customName: nil
                        )
                        return SearchResult(
                            id: sess.id,
                            session: session,
                            snippet: r.snippet ?? "",
                            matchType: r.matchType ?? "keyword",
                            score: r.score ?? 0
                        )
                    }
                }
            } catch {
                // Fallback to local FTS — run query off main thread
                let db = self.db
                let sessions: [Session] = (try? await Task.detached {
                    try db.readInBackground { d in
                        try Session.fetchAll(d, sql: """
                            SELECT s.* FROM sessions_fts f
                            JOIN sessions s ON s.id = f.session_id
                            WHERE sessions_fts MATCH ? AND s.hidden_at IS NULL
                            LIMIT 20
                        """, arguments: [q])
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

// MARK: - API response types

struct EmbeddingStatusResponse: Decodable {
    let available: Bool
    let model: String?
    let embeddedCount: Int?
    let totalSessions: Int?
    let progress: Int?
}

struct SearchAPIResponse: Decodable {
    let results: [SearchAPIResult]?
    let searchModes: [String]?
    let warning: String?
}

struct SearchAPIResult: Decodable {
    let session: SearchAPISession?
    let snippet: String?
    let matchType: String?
    let score: Double?
}

struct SearchAPISession: Decodable {
    let id: String
    let source: String?
    let startTime: String?
    let endTime: String?
    let cwd: String?
    let project: String?
    let model: String?
    let messageCount: Int?
    let userMessageCount: Int?
    let assistantMessageCount: Int?
    let systemMessageCount: Int?
    let summary: String?
    let filePath: String?
    let sizeBytes: Int?
    let indexedAt: String?
    let agentRole: String?
}

// MARK: - Source badge

struct SourceBadge: View {
    let source: String

    private var label: String {
        let map: [String: String] = [
            "claude-code": "Claude", "codex": "Codex", "copilot": "Copilot",
            "gemini-cli": "Gemini", "kimi": "Kimi", "qwen": "Qwen",
            "minimax": "MiniMax", "lobsterai": "Lobster", "cline": "Cline",
            "cursor": "Cursor", "windsurf": "Windsurf", "antigravity": "Antigravity",
            "opencode": "OpenCode", "iflow": "iFlow", "vscode": "VS Code",
        ]
        return map[source] ?? source
    }

    private var color: Color {
        let map: [String: Color] = [
            "claude-code": .orange, "codex": .green, "copilot": .gray,
            "gemini-cli": .cyan, "cursor": .blue, "cline": .teal,
        ]
        return map[source] ?? .secondary
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
