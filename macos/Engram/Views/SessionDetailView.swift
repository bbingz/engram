// macos/Engram/Views/SessionDetailView.swift
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.engram.app", category: "SessionDetail")
private let agentSessionPreviewLimit = 20
private let agentSessionListMaxHeight: CGFloat = 220
// Transcript paging: small/normal sessions load fully (unchanged). Only sessions
// past this message count load incrementally — a first page, then "Load more /
// Load all" — so a huge transcript isn't fully materialized on open. Counts and
// search reflect the loaded prefix and the UI says so; nothing is silently
// truncated (the full transcript is always one click away).
private let transcriptPageThreshold = 800
private let transcriptPageSize = 500

struct SessionDetailView: View {
    let session: Session
    var onBack: (() -> Void)? = nil
    /// Prime the find bar with this query when the session opens from keyword
    /// search (nil for every other entry point — find bar stays closed/empty).
    var searchTerm: String? = nil
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var isFavorite = false
    @State private var favoriteLoadSessionId: String?
    @State private var handoffStatus: String? = nil
    @State private var showReplay = false
    @State private var showResume = false
    @State private var messages: [ChatMessage] = []
    @State private var isLoadingMessages = false
    // Per-session summary: seeded from session.summary, regeneratable on demand
    // through EngramServiceClient.generateSummary (the service summarizer).
    @State private var summaryText: String?
    @State private var isSummarizing = false
    @State private var summaryError: String?

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

    // Transcript paging state. `hasMoreToLoad` gates the "Load more / Load all"
    // footer. `loadedProducedCount` is the next adapter offset in PRODUCED-message
    // space (counts pre-filter messages, incl. tool rows the UI drops) so appended
    // pages don't drift at the seam.
    @State private var hasMoreToLoad = false
    @State private var isLoadingMore = false
    @State private var loadedProducedCount = 0
    @State private var transcriptLoadTask: Task<Void, Never>? = nil
    // Bumped whenever `displayIndexed` is recomputed; the match-scan task is keyed
    // on it (plus searchText) so the off-main scan re-runs after a filter change or
    // a paged rebuild, never on a stale snapshot.
    @State private var displayVersion = 0

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
        // Drive the off-main match rescan (keyed on displayVersion + searchText).
        displayVersion &+= 1
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

    /// Initial transcript window: `nil` (load the whole transcript, the prior
    /// behavior) for sessions at or below the paging threshold; a first-page
    /// limit for larger ones. Pure so the gating is unit-testable.
    static func initialTranscriptLimit(messageCount: Int) -> Int? {
        messageCount > transcriptPageThreshold ? transcriptPageSize : nil
    }

    /// After a windowed load returns `returnedCount` messages for a `requestedLimit`,
    /// there may be more iff the page came back full. A nil limit means "load all",
    /// so never more. Pure so the pager state is unit-testable.
    static func hasMoreAfterLoad(returnedCount: Int, requestedLimit: Int?) -> Bool {
        guard let requestedLimit else { return false }
        return returnedCount >= requestedLimit
    }

    /// Re-runs the match scan whenever the query OR the displayed set changes.
    /// `\u{1}` separates the two so distinct (version, query) pairs can't collide.
    private var matchScanToken: String { "\(displayVersion)\u{1}\(searchText)" }

    /// Sole match-index path: debounced, and the per-message content scan runs off
    /// the main actor so neither typing in the find bar nor a paged rebuild hitches
    /// the UI on a large transcript. Driven by `.task(id: matchScanToken)`, which
    /// re-runs (cancelling the prior scan) whenever the query OR the displayed set
    /// changes — always reading live state, so it can't clobber a concurrent edit.
    private func updateMatchIndicesDebounced() async {
        let query = searchText.lowercased()
        guard !query.isEmpty else { matchIndices = []; return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if Task.isCancelled { return }
        let snapshot = displayIndexed
        let indices: [Int] = await Task.detached(priority: .userInitiated) {
            snapshot.enumerated().compactMap { i, msg in
                msg.message.content.lowercased().contains(query) ? i : nil
            }
        }.value
        if Task.isCancelled { return }
        matchIndices = indices
        // Auto-scroll to the first match when navigation hasn't started yet
        // (currentMatchIndex < 0). The guard keeps an in-progress Prev/Next from
        // being yanked back to the top by a filter/page re-scan.
        if currentMatchIndex < 0, let first = indices.first {
            currentMatchIndex = 0
            scrollTarget = snapshot[first].id
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
                partiallyLoaded: hasMoreToLoad,
                onToggleFavorite: {
                    let sessionId = session.id
                    Task {
                        let next = !isFavorite
                        do {
                            try await serviceClient.setFavorite(sessionId: sessionId, favorite: next)
                            if favoriteLoadSessionId == sessionId {
                                isFavorite = next
                            }
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
                    currentMatch: Self.displayedFindMatchIndex(
                        current: currentMatchIndex,
                        count: matchIndices.count
                    ) ?? 0,
                    onPrev: { navigateFind(direction: -1) },
                    onNext: { navigateFind(direction: 1) }
                )
                .accessibilityIdentifier("detail_findBar")
                Divider()
            }

            // Partial-load search disclosure. Search state (searchText, match
            // highlights, ⌘G navigation) outlives the find bar — ⌘F and the toolbar
            // Find button toggle the bar without clearing the query — so this hint
            // lives OUTSIDE `if showFind`: whenever a search is active on a partially
            // loaded transcript, matches can't silently confine to the loaded prefix
            // without the user being told.
            if hasMoreToLoad && !searchText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.caption2)
                    Text("Search covers loaded messages only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Load all") { loadMoreMessages(all: true) }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("detail_findPartialHint")
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

            summarySection

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
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("Filtered Out", systemImage: "eye.slash")
                    } description: {
                        Text("All messages are hidden by current filters. Tap \"All\" to reset.")
                    }
                    .padding(.top, 20)
                    // More may be loadable even when the loaded page is fully filtered.
                    if hasMoreToLoad { transcriptLoadMoreFooter }
                }
            } else if messages.isEmpty {
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("No Messages", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text(unsupportedMessage)
                    }
                    .padding(.top, 20)
                    // A large session whose first page is entirely tool messages loads
                    // zero displayable rows but has more — keep the Load affordance.
                    if hasMoreToLoad { transcriptLoadMoreFooter }
                }
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
                                    RawMessageRow(message: msg, searchText: searchText)
                                        .id(msg.id)
                                    Divider().opacity(0.3)
                                }
                            }
                            if hasMoreToLoad {
                                transcriptLoadMoreFooter
                            }
                        }
                    }
                    .accessibilityIdentifier("detail_transcript")
                    .onChange(of: scrollTarget) { _, target in
                        if let target {
                            withAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if displayIndexed.count > 1 {
                            Button {
                                scrollTarget = displayIndexed.first?.id
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(8)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(16)
                            .help("Scroll to top")
                            .accessibilityIdentifier("detail_scrollToTop")
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
            hasMoreToLoad = false
            isLoadingMore = false
            loadedProducedCount = 0
            transcriptLoadTask?.cancel()
            transcriptLoadTask = nil
            // Clear transcript-derived + nav state too, or a stale per-type position
            // from the previous session can index out of the new (shorter) one.
            displayIndexed = []
            matchIndices = []
            currentMatchIndex = -1
            // Prime the find bar from a search-driven open; closed/empty otherwise.
            searchText = searchTerm ?? ""
            showFind = (searchTerm?.isEmpty == false)
            scrollTarget = nil
            summaryText = session.summary
            isSummarizing = false
            summaryError = nil
            navPositions = Dictionary(uniqueKeysWithValues: MessageType.allCases.map { ($0, -1) })
            childrenSessions = []
            childrenSessionCount = 0
            suggestedChildrenSessions = []
            suggestedChildrenSessionCount = 0
            showAgentSessions = false
            isFavorite = false
            favoriteLoadSessionId = session.id
            // Read favorite state off the main actor; assign back when it lands.
            let dbRef = db
            let sessionId = session.id
            Task.detached {
                let fav = (try? dbRef.isFavorite(sessionId: sessionId)) ?? false
                await MainActor.run {
                    if favoriteLoadSessionId == sessionId {
                        isFavorite = fav
                    }
                }
            }
            await loadInitialTranscript()
            // The detached parse can outlive a session switch; don't let the
            // trailing assignments stomp the next session's reset state.
            if Task.isCancelled { return }
            isLoadingMessages = false
            loadParentInfo()
        }
        .onChange(of: typeVisibility) { _, _ in updateDisplayIndexed() }
        .onChange(of: showSystemPrompts) { _, _ in updateDisplayIndexed() }
        .onChange(of: showAgentComm) { _, _ in updateDisplayIndexed() }
        // A new/edited query restarts find navigation from the top; the debounced
        // scan then re-selects the first match (guarded by currentMatchIndex < 0).
        .onChange(of: searchText) { _, _ in currentMatchIndex = -1; scrollTarget = nil }
        .task(id: matchScanToken) { await updateMatchIndicesDebounced() }
        .sheet(isPresented: $showReplay) {
            SessionReplayView(sessionId: session.id)
                .frame(minWidth: 600, minHeight: 450)
        }
        .sheet(isPresented: $showResume) {
            ResumeDialog(session: session)
        }
        .onDisappear {
            parentInfoTask?.cancel(); parentInfoTask = nil
            transcriptLoadTask?.cancel(); transcriptLoadTask = nil
        }
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

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Summary", systemImage: "text.alignleft")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(summaryText?.isEmpty == false ? "Regenerate" : "Generate") {
                        generateSummary()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("detail_generateSummary")
                }
            }
            if let summaryText, !summaryText.isEmpty {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let summaryError {
                Text(summaryError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("detail_summarySection")
    }

    private func generateSummary() {
        guard !isSummarizing else { return }
        let sessionId = session.id
        isSummarizing = true
        summaryError = nil
        Task {
            do {
                let response = try await serviceClient.generateSummary(
                    EngramServiceGenerateSummaryRequest(sessionId: sessionId)
                )
                guard favoriteLoadSessionId == sessionId else { return }
                summaryText = response.summary
            } catch {
                guard favoriteLoadSessionId == sessionId else { return }
                summaryError = "Summary failed: \(error.localizedDescription)"
            }
            if favoriteLoadSessionId == sessionId { isSummarizing = false }
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
        guard let newPos = Self.nextNavPosition(
            current: navPositions[type] ?? -1, direction: direction, count: matching.count
        ) else { return }
        navPositions[type] = newPos
        scrollTarget = matching[newPos].element.id
    }

    /// Next per-type nav position. Clamps `current` into range first so a stale
    /// position (e.g. left over from a longer prior session) can't index past the
    /// current matches — the `direction < 0` branch is otherwise unbounded and traps.
    /// Returns nil when there are no matches. Pure, so it's unit-testable.
    static func nextNavPosition(current: Int, direction: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let clamped = min(current, count - 1)
        if direction > 0 { return (clamped + 1) % count }
        return clamped <= 0 ? count - 1 : clamped - 1
    }

    static func nextFindMatchIndex(current: Int, direction: Int, count: Int) -> Int? {
        nextNavPosition(current: current, direction: direction, count: count)
    }

    static func displayedFindMatchIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(current, 0), count - 1)
    }

    func navigateFind(direction: Int) {
        guard let next = Self.nextFindMatchIndex(
            current: currentMatchIndex,
            direction: direction,
            count: matchIndices.count
        ) else { return }
        currentMatchIndex = next
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
        // "Copy" / "Copy Entire Conversation" / ⌘⌥C promise the whole transcript.
        // If only a prefix is loaded, load the rest first so the clipboard never
        // gets a silent partial copy.
        guard hasMoreToLoad else {
            copyLoadedTranscript()
            return
        }
        guard !isLoadingMore else {
            // A load is already in flight; don't drop the copy silently.
            showTranscriptStatus(String(localized: "Still loading — try Copy again in a moment"))
            return
        }
        transcriptLoadTask?.cancel()
        transcriptLoadTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }
            await appendMessages(all: true)
            if Task.isCancelled { return }
            copyLoadedTranscript()
        }
    }

    private func copyLoadedTranscript() {
        let text = TranscriptText.conversationText(indexedMessages)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Surface a transient status in the existing toast, auto-clearing after 3s
    /// (only if nothing else replaced it meanwhile).
    private func showTranscriptStatus(_ message: String) {
        handoffStatus = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if handoffStatus == message { handoffStatus = nil }
        }
    }

    // MARK: - Transcript loading / paging

    /// Resolve the on-disk transcript path, mapping a relative fixture path against
    /// the DB directory (matches the prior inline resolution).
    private func resolvedTranscriptPath() -> String {
        var path = session.effectiveFilePath
        if !path.isEmpty && !path.hasPrefix("/") {
            let dbDir = (db.path as NSString).deletingLastPathComponent
            let resolved = (dbDir as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: resolved) { path = resolved }
        }
        return path
    }

    /// Off-main parse of one window. Returns the displayable messages plus the
    /// PRODUCED count (pre-filter) so the caller can advance its offset without
    /// seam drift. Touches no view state.
    private func parseWindow(offset: Int, limit: Int?) async -> (messages: [ChatMessage], producedCount: Int) {
        let path = resolvedTranscriptPath()
        let source = session.source
        return await Task.detached(priority: .userInitiated) {
            await MessageParser.parseWindowed(filePath: path, source: source, offset: offset, limit: limit)
        }.value
    }

    /// Re-derive indexed messages, type counts, the filtered display set, AND the
    /// search match indices from the currently-loaded `messages` — all off the main
    /// actor (the match scan is O(N · content) and must not run on main). Rebuilding
    /// over the full loaded prefix keeps `typeIndex`/counts correct; because loaded
    /// `ChatMessage`s keep their identity, an appended page diffs cleanly so the
    /// scroll position is preserved.
    private func rebuildIndexed() async {
        let snapshot = messages
        let built = await Task.detached(priority: .userInitiated) {
            IndexedMessage.build(from: snapshot)
        }.value
        // The detached build can outlive a session switch; don't clobber the reset.
        if Task.isCancelled { return }
        indexedMessages = built.messages
        typeCounts = built.counts
        // Derive display + matches from LIVE state (not the entry snapshot): a chip
        // toggle or search edit during the off-main build must not be overwritten.
        // updateDisplayIndexed bumps displayVersion → the match scan re-runs off-main.
        updateDisplayIndexed()
    }

    /// First load for a session: the whole transcript for normal sessions, or a
    /// first page for large ones (`hasMoreToLoad` then drives the footer).
    private func loadInitialTranscript() async {
        let limit = Self.initialTranscriptLimit(messageCount: session.messageCount)
        let (parsed, produced) = await parseWindow(offset: 0, limit: limit)
        if Task.isCancelled { return }
        messages = parsed
        loadedProducedCount = produced
        hasMoreToLoad = Self.hasMoreAfterLoad(returnedCount: produced, requestedLimit: limit)
        await rebuildIndexed()
    }

    /// Append the next page — or, when `all`, the entire remainder — to the loaded
    /// transcript. Parses from `loadedProducedCount` (PRODUCED-message space) so
    /// earlier pages aren't re-materialized and the seam doesn't drift, then
    /// rebuilds the indexed view over the full prefix.
    private func appendMessages(all: Bool) async {
        let offset = loadedProducedCount
        let pageLimit: Int? = all ? nil : transcriptPageSize
        let (parsed, produced) = await parseWindow(offset: offset, limit: pageLimit)
        if Task.isCancelled { return }
        messages += parsed
        loadedProducedCount += produced
        hasMoreToLoad = all ? false : Self.hasMoreAfterLoad(returnedCount: produced, requestedLimit: pageLimit)
        await rebuildIndexed()
    }

    private func loadMoreMessages(all: Bool) {
        guard !isLoadingMore else { return }
        transcriptLoadTask?.cancel()
        transcriptLoadTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }
            await appendMessages(all: all)
        }
    }

    @ViewBuilder
    private var transcriptLoadMoreFooter: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.3)
            if isLoadingMore {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 10) {
                    Text(transcriptPartialLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(loadMoreButtonLabel) { loadMoreMessages(all: false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Load all") { loadMoreMessages(all: true) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityIdentifier("detail_loadMoreFooter")
    }

    private var transcriptPartialLabel: String {
        if messages.isEmpty {
            return String(localized: "No displayable messages in the loaded range")
        }
        return String.localizedStringWithFormat(
            String(localized: "Showing first %lld messages"), messages.count
        )
    }

    private var loadMoreButtonLabel: String {
        String.localizedStringWithFormat(
            String(localized: "Load %lld more"), transcriptPageSize
        )
    }
}

// MARK: - Raw message row

struct RawMessageRow: View {
    let message: ChatMessage
    var searchText: String = ""

    /// Case-insensitive yellow highlight of `query` in `text`. Self-contained so
    /// Text mode highlights without depending on ColorBarMessageView (not owned).
    private func highlight(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !query.isEmpty else { return attr }
        var searchStart = text.startIndex
        while let range = text.range(
            of: query,
            options: .caseInsensitive,
            range: searchStart..<text.endIndex
        ) {
            if let attrRange = Range(NSRange(range, in: text), in: attr) {
                attr[attrRange].backgroundColor = .yellow
                attr[attrRange].foregroundColor = .black
            }
            searchStart = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            if searchStart >= text.endIndex { break }
        }
        return attr
    }

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
            Text(highlight(message.content, query: searchText))
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
