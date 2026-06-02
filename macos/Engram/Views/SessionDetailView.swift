// macos/Engram/Views/SessionDetailView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.engram.app", category: "SessionDetail")
private let agentSessionPreviewLimit = 20
private let agentSessionListMaxHeight: CGFloat = 220

struct SessionDetailView: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var isFavorite = false
    @State private var handoffStatus: String? = nil
    @State private var showReplay = false
    @State private var showResume = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    // UI-M3: removed dead summary state (`isSummarizing`/`summaryError`/
    // `currentSummary`) + `generateSummary()` — there was no UI entry point and
    // the service summary is extractive, not the advertised AI summary. Summary
    // generation remains available via the MCP `generate_summary` tool.

    // Parent/child hierarchy
    @State private var confirmedParent: Session?
    @State private var suggestedParent: Session?
    @State private var childrenSessions: [Session] = []
    @State private var childrenSessionCount = 0
    @State private var suggestedChildrenSessions: [Session] = []
    @State private var suggestedChildrenSessionCount = 0
    @State private var showAgentSessions = false
    // Single tracked task for parent/child loading; cancelled before each reload
    // so the 3 entry points (initial load, confirm, dismiss) can't interleave writes.
    @State private var parentInfoTask: Task<Void, Never>? = nil

    @AppStorage("showSystemPrompts") var showSystemPrompts: Bool = false
    @AppStorage("showAgentComm") var showAgentComm: Bool = false

    // Transcript state
    @State private var viewMode: TranscriptViewMode = .session
    @State private var showFind = false
    @State private var searchText = ""
    @State private var currentMatchIndex: Int = -1
    @State private var indexedMessages: [IndexedMessage] = []
    @State private var typeCounts: [MessageType: Int] = [:]
    @State private var typeVisibility: [MessageType: Bool] = Self.defaultTypeVisibility
    @State private var navPositions: [MessageType: Int] = Dictionary(uniqueKeysWithValues: MessageType.allCases.map { ($0, -1) })
    @State private var scrollTarget: UUID? = nil

    @State private var displayIndexed: [IndexedMessage] = []
    @State private var matchIndices: [Int] = []

    private static let defaultTypeVisibility: [MessageType: Bool] = Dictionary(
        uniqueKeysWithValues: MessageType.allCases.map { type in
            (type, type == .user || type == .assistant)
        }
    )

    private func updateDisplayIndexed() {
        displayIndexed = indexedMessages.filter { idx in
            Self.isMessageVisible(
                idx,
                typeVisibility: typeVisibility,
                showSystemPrompts: showSystemPrompts,
                showAgentComm: showAgentComm
            )
        }
        updateMatchIndices()
    }

    /// Decides whether an indexed message survives the current filters.
    ///
    /// System-prompt / agent-comm messages are gated ONLY by their dedicated
    /// toggles, NOT by `typeVisibility`. The classifier maps them to
    /// `.system` / `.toolCall` / `.toolResult`, and `.system` has no chip and
    /// defaults to hidden — so running the `typeVisibility` gate first made the
    /// "Show System Prompts" toggle a no-op. Gate on `systemCategory` first.
    static func isMessageVisible(
        _ idx: IndexedMessage,
        typeVisibility: [MessageType: Bool],
        showSystemPrompts: Bool,
        showAgentComm: Bool
    ) -> Bool {
        switch idx.message.systemCategory {
        case .systemPrompt:
            return showSystemPrompts
        case .agentComm:
            return showAgentComm
        case .none:
            return typeVisibility[idx.messageType] ?? true
        }
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
                onResume: { showResume = true },
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
                HStack(spacing: 8) {
                    Button(action: { navigateToSession(parent) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left")
                                .font(.caption2)
                            Text("Parent: \(parent.displayTitle)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)

                    Button(action: unlinkParent) {
                        Image(systemName: "link.badge.minus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Unlink parent")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
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

                    Button(action: confirmSuggestedParent) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Confirm parent")

                    Button(action: dismissSuggestedParent) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
                    .help("Dismiss suggestion")
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
                                    ColorBarMessageView(indexed: indexed, searchText: searchText, onCopyAll: { copyAllTranscript() })
                                        .id(indexed.id)
                                }
                            case .text:
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

            agentSessionsSection
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
            // These exist only to register keyboard shortcuts; keep them out of the a11y tree.
            .accessibilityHidden(true)
        }
        // Single per-session load path (keyed by session.id) — favorite + messages +
        // parent info all run here so ordering is deterministic and re-runs on switch.
        .task(id: session.id) {
            isLoadingMessages = true
            messages = []
            indexedMessages = []
            typeCounts = [:]
            typeVisibility = Self.defaultTypeVisibility
            childrenSessions = []
            childrenSessionCount = 0
            suggestedChildrenSessions = []
            suggestedChildrenSessionCount = 0
            showAgentSessions = false
            // Read favorite state off the main actor; assign back when it lands.
            let dbRef = db
            let sessionId = session.id
            Task.detached {
                let fav = (try? dbRef.isFavorite(sessionId: sessionId)) ?? false
                await MainActor.run { isFavorite = fav }
            }
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
            // Parse + classify + initial filter all run off the main thread; the
            // finished arrays hop back together so a large transcript never
            // classifies/filters on the main actor.
            let visibility = typeVisibility
            let showSystem = showSystemPrompts
            let showAgent = showAgentComm
            let built = await Task.detached(priority: .userInitiated) {
                let parsed = MessageParser.parse(filePath: effectivePath, source: source)
                let result = IndexedMessage.build(from: parsed)
                let display = result.messages.filter {
                    Self.isMessageVisible(
                        $0,
                        typeVisibility: visibility,
                        showSystemPrompts: showSystem,
                        showAgentComm: showAgent
                    )
                }
                return (parsed, result.messages, result.counts, display)
            }.value
            messages = built.0
            indexedMessages = built.1
            typeCounts = built.2
            displayIndexed = built.3
            updateMatchIndices()
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
        .sheet(isPresented: $showResume) {
            ResumeDialog(session: session)
        }
        .onDisappear { parentInfoTask?.cancel(); parentInfoTask = nil }
    }

    // MARK: - Parent/Child Helpers

    @ViewBuilder
    private var agentSessionsSection: some View {
        let totalCount = childrenSessionCount + suggestedChildrenSessionCount
        if totalCount > 0 {
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showAgentSessions.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showAgentSessions ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 12)

                        Text(agentSessionsTitle(totalCount))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)

                        if childrenSessionCount > agentSessionPreviewLimit {
                            Text(showingAgentSessionsLabel(childrenSessions.count))
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryText)
                        }

                        if suggestedChildrenSessionCount > 0 {
                            Text(suggestedAgentSessionsLabel(suggestedChildrenSessionCount))
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiaryText)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAgentSessions {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(childrenSessions, id: \.id) { child in
                                CompactChildRow(
                                    session: child,
                                    isConfirmed: true,
                                    onTap: { navigateToSession(child) }
                                )
                                .padding(.horizontal, 12)
                            }
                            ForEach(suggestedChildrenSessions, id: \.id) { child in
                                CompactChildRow(
                                    session: child,
                                    isConfirmed: false,
                                    onTap: { navigateToSession(child) },
                                    onConfirm: { confirmSuggestedChild(child) },
                                    onDismiss: { dismissSuggestedChild(child) }
                                )
                                .padding(.horizontal, 12)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: agentSessionListMaxHeight)
                    .scrollIndicators(.visible)
                    .accessibilityIdentifier("detail_agentSessionsList")
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("detail_agentSessionsSection")
        }
    }

    private func loadParentInfo() {
        let sessionId = session.id
        let parentId = session.parentSessionId
        let suggestedId = session.suggestedParentId
        let dbRef = db

        // Cancel any prior load so the 3 entry points (initial / confirm / dismiss)
        // can't interleave their write-backs. All DB reads run off the main actor.
        parentInfoTask?.cancel()
        parentInfoTask = Task.detached {
            // Re-fetch session to get latest state (e.g. after confirm/dismiss)
            let freshSession = try? dbRef.getSession(id: sessionId)
            let effectiveParentId = freshSession?.parentSessionId ?? parentId
            let effectiveSuggestedId = freshSession?.suggestedParentId ?? suggestedId

            let confirmed = effectiveParentId.flatMap { try? dbRef.getSession(id: $0) }
            let suggested = effectiveParentId == nil
                ? effectiveSuggestedId.flatMap { try? dbRef.getSession(id: $0) }
                : nil

            let children = try? dbRef.childSessions(
                parentId: sessionId,
                limit: agentSessionPreviewLimit
            )
            let suggestedChildren = try? dbRef.suggestedChildSessions(parentId: sessionId)
            let counts = try? dbRef.childCount(parentIds: [sessionId])
            let suggestedCounts = try? dbRef.suggestedChildCount(parentIds: [sessionId])
            let childCount = counts?[sessionId] ?? children?.count ?? 0
            let suggestedChildCount = suggestedCounts?[sessionId] ?? suggestedChildren?.count ?? 0
            if Task.isCancelled { return }
            await MainActor.run {
                confirmedParent = confirmed
                suggestedParent = suggested
                childrenSessions = children ?? []
                childrenSessionCount = childCount
                suggestedChildrenSessions = suggestedChildren ?? []
                suggestedChildrenSessionCount = suggestedChildCount
            }
        }
    }

    private func confirmSuggestedChild(_ child: Session) {
        Task {
            _ = try? await serviceClient.confirmSuggestion(sessionId: child.id)
            loadParentInfo()
        }
    }

    private func confirmSuggestedParent() {
        Task {
            _ = try? await serviceClient.confirmSuggestion(sessionId: session.id)
            loadParentInfo()
        }
    }

    private func dismissSuggestedParent() {
        guard let suggestedId = suggestedParent?.id ?? session.suggestedParentId else { return }
        Task {
            try? await serviceClient.dismissSuggestion(
                sessionId: session.id,
                suggestedParentId: suggestedId
            )
            loadParentInfo()
        }
    }

    private func unlinkParent() {
        Task {
            _ = try? await serviceClient.clearParentSession(sessionId: session.id)
            loadParentInfo()
        }
    }

    private func dismissSuggestedChild(_ child: Session) {
        guard let suggestedId = child.suggestedParentId else { return }
        Task {
            try? await serviceClient.dismissSuggestion(
                sessionId: child.id,
                suggestedParentId: suggestedId
            )
            loadParentInfo()
        }
    }

    private func agentSessionsTitle(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "Agent Sessions (%lld)"), count)
    }

    private func showingAgentSessionsLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "showing %lld"), count)
    }

    private func suggestedAgentSessionsLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld suggested"), count)
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
        let text = TranscriptText.conversationText(displayIndexed)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
