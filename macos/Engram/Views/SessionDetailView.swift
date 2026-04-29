// macos/Engram/Views/SessionDetailView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.engram.app", category: "SessionDetail")

struct SessionDetailView: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var isFavorite = false
    @State private var handoffStatus: String? = nil
    @State private var showReplay = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    @State private var isSummarizing = false
    @State private var summaryError: String? = nil
    @State private var currentSummary: String?

    // Parent/child hierarchy
    @State private var confirmedParent: Session?
    @State private var suggestedParent: Session?
    @State private var childrenSessions: [Session] = []

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
                    Task {
                        let next = !isFavorite
                        do {
                            try await serviceClient.setFavorite(sessionId: session.id, favorite: next)
                            isFavorite = next
                        } catch {
                            logger.error("Failed to toggle favorite: \(error.localizedDescription)")
                        }
                    }
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail_toolbar")

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
                .accessibilityIdentifier("detail_findBar")
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

            // Confirmed parent breadcrumb
            if let parent = confirmedParent {
                Button(action: { navigateToSession(parent) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.caption2)
                        Text("Parent: \(parent.displayTitle)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }

            // Suggested parent breadcrumb (only when no confirmed parent)
            if confirmedParent == nil, let suggested = suggestedParent {
                HStack(spacing: 8) {
                    Text("← Suggested parent: \(suggested.displayTitle)")
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(Theme.tertiaryText)

                    Text("Suggested")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
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
                    .accessibilityIdentifier("detail_transcript")
                    .onChange(of: scrollTarget) { _, target in
                        if let target {
                            withAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            }

            // Child session list
            if !childrenSessions.isEmpty {
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Sessions (\(childrenSessions.count))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 16)

                    ForEach(childrenSessions, id: \.id) { child in
                        CompactChildRow(
                            session: child,
                            isConfirmed: true,
                            onTap: { navigateToSession(child) }
                        )
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail_container")
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
            var effectivePath = session.effectiveFilePath
            let source = session.source
            // Resolve relative paths against the DB's parent directory (test fixtures)
            if !effectivePath.isEmpty && !effectivePath.hasPrefix("/") {
                let dbDir = (db.path as NSString).deletingLastPathComponent
                let resolved = (dbDir as NSString).appendingPathComponent(effectivePath)
                if FileManager.default.fileExists(atPath: resolved) {
                    effectivePath = resolved
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
            loadParentInfo()
        }
        .onChange(of: typeVisibility) { _, _ in updateDisplayIndexed() }
        .onChange(of: showSystemPrompts) { _, _ in updateDisplayIndexed() }
        .onChange(of: showAgentComm) { _, _ in updateDisplayIndexed() }
        .onChange(of: searchText) { _, _ in updateMatchIndices() }
        .sheet(isPresented: $showReplay) {
            SessionReplayView(sessionId: session.id)
                .frame(minWidth: 600, minHeight: 450)
        }
    }

    // MARK: - Parent/Child Helpers

    private func loadParentInfo() {
        let sessionId = session.id
        let parentId = session.parentSessionId
        let suggestedId = session.suggestedParentId

        // Re-fetch session to get latest state (e.g. after confirm/dismiss)
        let freshSession = try? db.getSession(id: sessionId)
        let effectiveParentId = freshSession?.parentSessionId ?? parentId
        let effectiveSuggestedId = freshSession?.suggestedParentId ?? suggestedId

        var confirmed: Session?
        var suggested: Session?
        if let pid = effectiveParentId {
            confirmed = try? db.getSession(id: pid)
        } else if let spid = effectiveSuggestedId {
            suggested = try? db.getSession(id: spid)
        }

        // childSessions is nonisolated — fetch in background
        let dbRef = db
        Task.detached {
            let children = try? dbRef.childSessions(parentId: sessionId)
            await MainActor.run {
                confirmedParent = confirmed
                suggestedParent = suggested
                childrenSessions = children ?? []
            }
        }
    }

    private func navigateToSession(_ target: Session) {
        NotificationCenter.default.post(name: .openSession, object: SessionBox(target))
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


    func performHandoff() {
        Task {
            do {
                let response = try await serviceClient.handoff(
                    EngramServiceHandoffRequest(
                        cwd: session.cwd,
                        sessionId: session.id,
                        format: "markdown"
                    )
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(response.brief, forType: .string)
                handoffStatus = "Handoff copied! (\(response.sessionCount) sessions)"
                // Clear status after 3s
                try? await Task.sleep(for: .seconds(3))
                if handoffStatus?.hasPrefix("Handoff") == true { handoffStatus = nil }
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
        defer { isSummarizing = false }

        do {
            let response = try await serviceClient.generateSummary(
                EngramServiceGenerateSummaryRequest(sessionId: session.id)
            )
            if response.summary.isEmpty {
                summaryError = "Empty response from AI"
            } else {
                currentSummary = response.summary
            }
        } catch {
            summaryError = "Summary failed: \(error.localizedDescription)"
        }
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
