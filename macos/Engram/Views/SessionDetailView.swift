// macos/Engram/Views/SessionDetailView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.engram.app", category: "SessionDetail")

struct SessionDetailView: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess
    @EnvironmentObject var daemonClient: DaemonClient
    @State private var isFavorite = false
    @State private var handoffStatus: String? = nil
    @State private var showReplay = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    @State private var isSummarizing = false
    @State private var summaryError: String? = nil
    @State private var currentSummary: String?

    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false

    // Transcript state
    @State private var viewMode: TranscriptViewMode = .session
    @State private var showFind = false
    @State private var searchText = ""
    @State private var currentMatchIndex: Int = -1
    @State private var indexedMessages: [IndexedMessage] = []
    @State private var typeCounts: [MessageType: Int] = [:]
    @State private var typeVisibility: [MessageType: Bool] = Dictionary(uniqueKeysWithValues: MessageType.allCases.map { ($0, true) })
    @State private var navPositions: [MessageType: Int] = Dictionary(uniqueKeysWithValues: MessageType.allCases.map { ($0, -1) })
    @State private var scrollTarget: UUID? = nil

    @State private var displayIndexed: [IndexedMessage] = []
    @State private var matchIndices: [Int] = []

    private func updateDisplayIndexed() {
        displayIndexed = indexedMessages.filter { idx in
            guard typeVisibility[idx.messageType] ?? true else { return false }
            if !showSystemPrompts && idx.message.systemCategory == .systemPrompt { return false }
            if !showAgentComm && idx.message.systemCategory == .agentComm { return false }
            return true
        }
        updateMatchIndices()
    }

    private func updateMatchIndices() {
        guard !searchText.isEmpty else { matchIndices = []; return }
        let query = searchText.lowercased()
        matchIndices = displayIndexed.enumerated().compactMap { i, msg in
            msg.message.content.lowercased().contains(query) ? i : nil
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            TranscriptToolbar(
                session: session,
                onBack: onBack,
                isFavorite: isFavorite,
                typeCounts: typeCounts,
                typeVisibility: typeVisibility,
                navPositions: navPositions,
                onToggleFavorite: {
                    if isFavorite {
                        try? db.removeFavorite(sessionId: session.id)
                    } else {
                        try? db.addFavorite(sessionId: session.id)
                    }
                    isFavorite.toggle()
                },
                onCopyAll: { copyAllTranscript() },
                onToggleFind: { showFind.toggle() },
                onToggleType: { type in typeVisibility[type]?.toggle() },
                onShowAll: { for type in MessageType.allCases { typeVisibility[type] = true } },
                onNavPrev: { type in navigateType(type, direction: -1) },
                onNavNext: { type in navigateType(type, direction: 1) },
                onHandoff: { performHandoff() },
                onReplay: { showReplay = true },
                viewMode: $viewMode
            )

            // Handoff status toast
            if let status = handoffStatus {
                HStack(spacing: 6) {
                    Image(systemName: status.hasPrefix("Handoff copied") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(status.hasPrefix("Handoff copied") ? .green : .red)
                    Text(status)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: handoffStatus)
            }

            if showFind {
                TranscriptFindBar(
                    searchText: $searchText,
                    isVisible: $showFind,
                    matchCount: matchIndices.count,
                    currentMatch: max(currentMatchIndex, 0),
                    onPrev: { navigateFind(direction: -1) },
                    onNext: { navigateFind(direction: 1) }
                )
                Divider()
            }

            // Size warning banner
            if session.sizeCategory != .normal {
                HStack(spacing: 6) {
                    Image(systemName: session.sizeCategory == .huge
                          ? "exclamationmark.triangle.fill"
                          : "info.circle.fill")
                        .foregroundStyle(session.sizeCategory == .huge ? .red : .orange)
                    Text("This session is \(session.formattedSize) — loading may take a moment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (session.sizeCategory == .huge ? Color.red : Color.orange)
                        .opacity(0.08)
                )
            }

            if isLoadingMessages {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else if viewMode == .session && displayIndexed.isEmpty && !indexedMessages.isEmpty {
                ContentUnavailableView {
                    Label("Filtered Out", systemImage: "eye.slash")
                } description: {
                    Text("All messages are hidden by current filters. Tap \"All\" to reset.")
                }
                .padding(.top, 20)
            } else if messages.isEmpty {
                ContentUnavailableView {
                    Label("No Messages", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(unsupportedMessage)
                }
                .padding(.top, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            switch viewMode {
                            case .session:
                                ForEach(displayIndexed) { indexed in
                                    ColorBarMessageView(indexed: indexed, searchText: searchText)
                                        .id(indexed.id)
                                }
                            case .text:
                                ForEach(messages) { msg in
                                    RawMessageRow(message: msg)
                                    Divider().opacity(0.3)
                                }
                            case .json:
                                ForEach(messages) { msg in
                                    RawMessageRow(message: msg)
                                    Divider().opacity(0.3)
                                }
                            }
                        }
                    }
                    .onChange(of: scrollTarget) { _, target in
                        if let target {
                            withAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            }
        }
        .background {
            Group {
                Button("") { showFind.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { navigateFind(direction: 1) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { navigateFind(direction: -1) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("") { copyAllTranscript() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("") { if showFind { searchText = ""; showFind = false } }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .task {
            isFavorite = (try? db.isFavorite(sessionId: session.id)) ?? false
        }
        .task(id: session.id) {
            isLoadingMessages = true
            messages = []
            indexedMessages = []
            typeCounts = [:]
            let path = session.filePath
            let source = session.source
            // If filePath is empty, try to find the session file by scanning known directories
            var effectivePath = path
            if effectivePath.isEmpty {
                let home = NSHomeDirectory()
                switch source {
                case "claude-code":
                    effectivePath = findSessionFile(sessionId: session.id, baseDir: home + "/.claude/projects") ?? ""
                case "codex":
                    effectivePath = findSessionFile(sessionId: session.id, baseDir: home + "/.codex/sessions") ?? ""
                case "kimi":
                    effectivePath = findSessionFile(sessionId: session.id, baseDir: home + "/.kimi/chats") ?? ""
                case "copilot":
                    // Copilot stores as {sessionId}/events.jsonl
                    let copilotDirect = home + "/.copilot/session-state/\(session.id)/events.jsonl"
                    if FileManager.default.fileExists(atPath: copilotDirect) {
                        effectivePath = copilotDirect
                    } else {
                        effectivePath = findSessionFile(sessionId: session.id, baseDir: home + "/.copilot/session-state") ?? ""
                    }
                default:
                    break
                }
            }
            messages = await Task.detached(priority: .userInitiated) {
                MessageParser.parse(filePath: effectivePath, source: source)
            }.value
            let result = IndexedMessage.build(from: messages)
            indexedMessages = result.messages
            typeCounts = result.counts
            updateDisplayIndexed()
            isLoadingMessages = false
        }
        .onChange(of: typeVisibility) { _, _ in updateDisplayIndexed() }
        .onChange(of: showSystemPrompts) { _, _ in updateDisplayIndexed() }
        .onChange(of: showAgentComm) { _, _ in updateDisplayIndexed() }
        .onChange(of: searchText) { _, _ in updateMatchIndices() }
        .sheet(isPresented: $showReplay) {
            SessionReplayView(sessionId: session.id)
                .environmentObject(daemonClient)
                .frame(minWidth: 600, minHeight: 450)
        }
    }

    // MARK: - Helpers

    var unsupportedMessage: LocalizedStringKey {
        switch session.source {
        case "vscode":
            return "This source (\(session.source)) uses a SQLite database — conversation preview is not yet supported."
        default:
            return "No messages found."
        }
    }

    func navigateType(_ type: MessageType, direction: Int) {
        let matching = displayIndexed.enumerated().filter { $0.element.messageType == type }
        guard !matching.isEmpty else { return }
        let current = navPositions[type] ?? -1
        let newPos: Int
        if direction > 0 {
            newPos = (current + 1) % matching.count
        } else {
            newPos = current <= 0 ? matching.count - 1 : current - 1
        }
        navPositions[type] = newPos
        scrollTarget = matching[newPos].element.id
    }

    func navigateFind(direction: Int) {
        guard !matchIndices.isEmpty else { return }
        if direction > 0 {
            currentMatchIndex = (currentMatchIndex + 1) % matchIndices.count
        } else {
            currentMatchIndex = currentMatchIndex <= 0 ? matchIndices.count - 1 : currentMatchIndex - 1
        }
        let msgIndex = matchIndices[currentMatchIndex]
        let displayed = displayIndexed
        if msgIndex < displayed.count {
            scrollTarget = displayed[msgIndex].id
        }
    }

    /// Find a session file by scanning a base directory recursively (up to 3 levels)
    func findSessionFile(sessionId: String, baseDir: String) -> String? {
        let fm = FileManager.default
        let extensions = ["jsonl", "json", "ndjson"]

        // Quick check: direct file at baseDir/{sessionId}.{ext}
        for ext in extensions {
            let direct = (baseDir as NSString).appendingPathComponent("\(sessionId).\(ext)")
            if fm.fileExists(atPath: direct) { return direct }
        }

        // Recursive scan up to 3 levels deep
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: baseDir),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var depth = 0
        for case let fileURL as URL in enumerator {
            // Limit depth
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }

            let name = fileURL.lastPathComponent
            // Match: filename contains sessionId
            if name.contains(sessionId) {
                let ext = fileURL.pathExtension
                if extensions.contains(ext) {
                    return fileURL.path
                }
            }

            depth += 1
            if depth > 5000 { break } // safety limit
        }
        return nil
    }

    func performHandoff() {
        Task {
            do {
                struct HandoffRequest: Encodable {
                    let cwd: String
                }
                let response: HandoffResponse = try await daemonClient.post(
                    "/api/handoff",
                    body: HandoffRequest(cwd: session.cwd ?? "")
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response.brief, forType: .string)
                handoffStatus = "Handoff copied! (\(response.sessionCount) sessions)"
                // Clear status after 3s
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if handoffStatus?.hasPrefix("Handoff") == true { handoffStatus = nil }
                }
            } catch {
                handoffStatus = "Handoff failed: \(error.localizedDescription)"
            }
        }
    }

    func copyAllTranscript() {
        let text = displayIndexed.map { idx in
            let prefix: String
            switch idx.messageType {
            case .user:       prefix = "> "
            case .assistant:  prefix = ""
            case .tool:       prefix = "› "
            case .toolCall:   prefix = "› "
            case .toolResult: prefix = "‹ "
            case .thinking:   prefix = "~ "
            case .error:      prefix = "! "
            case .code:       prefix = "```\n"
            case .system:     prefix = "[system] "
            }
            return prefix + idx.message.content
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func generateSummary() async {
        guard !messages.isEmpty else { return }
        isSummarizing = true
        summaryError = nil

        let daemonPort = indexer.port ?? 3457
        guard let url = URL(string: "http://127.0.0.1:\(daemonPort)/api/summary") else {
            summaryError = "Invalid daemon URL"
            isSummarizing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: String] = ["sessionId": session.id]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            if let httpResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let summary = json["summary"] as? String, !summary.isEmpty {
                    currentSummary = summary
                } else {
                    summaryError = "Empty response from AI"
                }
            } else {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let errorMsg = json?["error"] as? String ?? "Unknown error (HTTP \(httpResponse?.statusCode ?? 0))"
                summaryError = errorMsg
            }
        } catch {
            summaryError = "Network error: \(error.localizedDescription)"
        }

        isSummarizing = false
    }
}

// MARK: - Raw message row

struct RawMessageRow: View {
    let message: ChatMessage

    var roleColor: Color {
        if message.isSystem { return .secondary }
        return message.role == "user" ? Color.accentColor : .purple
    }

    var roleLabel: LocalizedStringKey {
        if message.isSystem { return "[system]" }
        return message.role == "user" ? "[user]" : "[assistant]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(roleLabel)
                .font(.caption.monospaced().bold())
                .foregroundStyle(roleColor)
            Text(verbatim: message.content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(message.isSystem ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .opacity(message.isSystem ? 0.55 : 1.0)
    }
}
