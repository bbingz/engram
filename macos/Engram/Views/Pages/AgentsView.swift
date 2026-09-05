// macos/Engram/Views/Pages/AgentsView.swift
import SwiftUI

struct AgentsView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramServiceClient) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

    @State private var parents: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var pendingSuggestions: [Session] = []
    @State private var ambiguousSuggestions: [DatabaseManager.AmbiguousSuggestionSession] = []
    @State private var subAgentCount = 0
    @State private var activeCount = 0
    @State private var inFlightRows: Set<String> = []
    @State private var linkTarget: Session? = nil
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var lastFilterKey: [AnyHashable]? = nil
    @State private var loadError: String? = nil
    /// Keyboard focus for session rows (Wave 8-2, mirrors SessionsPageView 7-1).
    @FocusState private var focusedSessionId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load agent sessions: \(loadError)", action: ("Retry", { Task { await loadData() } }))
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(subAgentCount)", label: "Agent Sessions")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                }

                if isLoading && parents.isEmpty && pendingSuggestions.isEmpty && ambiguousSuggestions.isEmpty {
                    HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                        .padding(.vertical, 24)
                } else if parents.isEmpty && pendingSuggestions.isEmpty && ambiguousSuggestions.isEmpty {
                    EmptyState(icon: "cpu", title: "No agent sessions", message: "Agent sessions (subagents, dispatched tasks) will appear here")
                        .accessibilityIdentifier("agents_emptyState")
                } else {
                    if !pendingSuggestions.isEmpty {
                        SectionHeader(icon: "questionmark.circle", title: "Pending Suggestions", badge: "\(pendingSuggestions.count)")
                        LazyVStack(spacing: 4) {
                            ForEach(pendingSuggestions) { child in
                                PendingSuggestionRow(
                                    child: child,
                                    suggestedParentTitle: suggestedParentTitle(for: child),
                                    isBusy: inFlightRows.contains(child.id),
                                    onConfirm: { confirmSuggestion(child) },
                                    onDismiss: { dismissSuggestion(child) },
                                    onSetParent: { linkTarget = child }
                                )
                            }
                        }
                        .accessibilityIdentifier("agents_pendingList")
                    }

                    if !ambiguousSuggestions.isEmpty {
                        SectionHeader(icon: "questionmark.diamond", title: "Ambiguous", badge: "\(ambiguousSuggestions.count)")
                        LazyVStack(spacing: 4) {
                            ForEach(ambiguousSuggestions) { item in
                                AmbiguousSuggestionRow(
                                    item: item,
                                    isBusy: inFlightRows.contains(item.session.id),
                                    onSelectCandidate: { candidate in
                                        resolveAmbiguousSuggestion(item, candidate: candidate)
                                    },
                                    onDismiss: { dismissAmbiguousSuggestion(item) }
                                )
                            }
                        }
                        .accessibilityIdentifier("agents_ambiguousList")
                    }

                    SectionHeader(icon: "cpu", title: "Agent Sessions")
                    LazyVStack(spacing: 4) {
                        ForEach(parents) { session in
                            ExpandableSessionCard(
                                session: session,
                                confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                onTap: {
                                    open(session)
                                },
                                onChildTap: { child in
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(child))
                                },
                                onConfirmSuggestion: { child in confirmSuggestion(child) },
                                onDismissSuggestion: { child in dismissSuggestion(child) }
                            )
                            // Keyboard navigation (Wave 8-2): focus + ring +
                            // Enter/Space, sharing the tap's open path.
                            .focusable()
                            .focused($focusedSessionId, equals: session.id)
                            .onKeyPress(keys: [.return, .space]) { _ in
                                guard focusedSessionId == session.id else { return .ignored }
                                open(session)
                                return .handled
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                    .stroke(Theme.accent, lineWidth: 2)
                                    .opacity(focusedSessionId == session.id ? 1 : 0)
                                    .allowsHitTesting(false)
                            )
                        }
                    }
                    .accessibilityIdentifier("agents_list")
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("agents_container")
        .sheet(item: $linkTarget) { child in
            LinkParentPicker(child: child, onLinked: { Task { await loadData() } })
        }
        .task(id: serviceStatusStore.browseReloadToken) {
            let filterKey: [AnyHashable] = []
            let plan = BrowseReloadCoalescer.plan(
                filterKey: filterKey,
                lastFilterKey: lastFilterKey
            )
            if plan.debounce {
                try? await Task.sleep(for: BrowseReloadCoalescer.debounceInterval)
                if Task.isCancelled { return }
            }
            lastFilterKey = filterKey
            await loadData()
        }
    }

    /// The navigation notification shared by tap and keyboard. Static and pure
    /// so tests can verify the contract without a service client (Wave 8-2).
    static func openNotification(for session: Session) -> Notification {
        Notification(name: .openSession, object: SessionBox(session))
    }

    /// Shared by card tap and keyboard Enter/Space.
    func open(_ session: Session) {
        NotificationCenter.default.post(Self.openNotification(for: session))
    }

    private func loadData() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        let db = self.db
        do {
            let data = try await Task.detached { () -> (
                parents: [Session],
                confirmed: [String: Int],
                suggested: [String: Int],
                pending: [Session],
                ambiguous: [DatabaseManager.AmbiguousSuggestionSession],
                stats: DatabaseManager.AgentSessionStats
            ) in
                let pageSize = 200
                var groups: [Session] = []
                var confirmed: [String: Int] = [:]
                var suggested: [String: Int] = [:]
                var offset = 0
                while true {
                    let page = try db.agentParentSessions(limit: pageSize, offset: offset)
                    let parentIds = page.map(\.id)
                    confirmed.merge(try db.childCount(parentIds: parentIds)) { _, new in new }
                    suggested.merge(try db.suggestedChildCount(parentIds: parentIds)) { _, new in new }
                    groups.append(contentsOf: page)
                    guard page.count == pageSize else { break }
                    offset += page.count
                }
                let pending = try db.pendingSuggestionSessions(limit: 200)
                let ambiguous = try db.ambiguousSuggestionSessions(limit: 200)
                let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                let activeSince = ISO8601DateFormatter().string(from: weekAgo)
                let stats = try db.agentSessionStats(activeSince: activeSince)
                return (groups, confirmed, suggested, pending, ambiguous, stats)
            }.value
            guard BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            parents = data.parents
            confirmedCounts = data.confirmed
            suggestedCounts = data.suggested
            pendingSuggestions = data.pending
            ambiguousSuggestions = data.ambiguous
            subAgentCount = data.stats.total
            activeCount = data.stats.active
            loadError = nil
        } catch {
            guard BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            EngramLogger.error("AgentsView load failed", module: .ui, error: error)
            loadError = ServiceErrorPresenter.displayMessage(for: error)
        }
    }

    /// Resolve a pending child's suggested parent id to the loaded parent's
    /// display title; fall back to the raw id when that parent isn't loaded.
    private func suggestedParentTitle(for child: Session) -> String? {
        guard let parentId = child.suggestedParentId else { return nil }
        return parents.first { $0.id == parentId }?.displayTitle ?? parentId
    }

    private func confirmSuggestion(_ child: Session) {
        guard !inFlightRows.contains(child.id) else { return }
        inFlightRows.insert(child.id)
        Task {
            defer { inFlightRows.remove(child.id) }
            do {
                let response = try await serviceClient.confirmSuggestion(sessionId: child.id)
                guard response.ok else {
                    loadError = response.error ?? "Failed to confirm suggestion"
                    return
                }
                await loadData()
            } catch {
                EngramLogger.error("AgentsView confirm suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    private func dismissSuggestion(_ child: Session) {
        guard !inFlightRows.contains(child.id) else { return }
        inFlightRows.insert(child.id)
        Task {
            defer { inFlightRows.remove(child.id) }
            do {
                if let suggestedParentId = child.suggestedParentId {
                    // dismissSuggestion returns Void and signals failure only by
                    // throwing, so the catch below is the full error surface.
                    try await serviceClient.dismissSuggestion(
                        sessionId: child.id,
                        suggestedParentId: suggestedParentId
                    )
                }
                await loadData()
            } catch {
                EngramLogger.error("AgentsView dismiss suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    private func resolveAmbiguousSuggestion(
        _ item: DatabaseManager.AmbiguousSuggestionSession,
        candidate: DatabaseManager.AmbiguousSuggestionCandidate
    ) {
        let sessionId = item.session.id
        guard !inFlightRows.contains(sessionId) else { return }
        inFlightRows.insert(sessionId)
        Task {
            defer { inFlightRows.remove(sessionId) }
            do {
                let response = try await serviceClient.setParentSession(sessionId: sessionId, parentId: candidate.id)
                guard response.ok else {
                    loadError = response.error ?? "Failed to set parent"
                    return
                }
                await loadData()
            } catch {
                EngramLogger.error("AgentsView resolve ambiguous suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }

    private func dismissAmbiguousSuggestion(_ item: DatabaseManager.AmbiguousSuggestionSession) {
        let sessionId = item.session.id
        guard !inFlightRows.contains(sessionId) else { return }
        inFlightRows.insert(sessionId)
        Task {
            defer { inFlightRows.remove(sessionId) }
            do {
                let response = try await serviceClient.dismissAmbiguousSuggestion(sessionId: sessionId)
                guard response.ok else {
                    loadError = response.error ?? "Failed to dismiss suggestion"
                    return
                }
                await loadData()
            } catch {
                EngramLogger.error("AgentsView dismiss ambiguous suggestion failed", module: .ui, error: error)
                loadError = ServiceErrorPresenter.displayMessage(for: error)
            }
        }
    }
}

// MARK: - Pending suggestion inbox row

private struct PendingSuggestionRow: View {
    let child: Session
    let suggestedParentTitle: String?
    let isBusy: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
    let onSetParent: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SourcePill(source: child.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(child.displayTitle)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if let suggestedParentTitle {
                    Text("suggested under \(suggestedParentTitle)")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isBusy {
                ProgressView().scaleEffect(0.6)
            } else {
                Button("Confirm") { onConfirm() }
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                Button("Dismiss") { onDismiss() }
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .buttonStyle(.plain)
                Menu {
                    Button("Set parent…") { onSetParent() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .accessibilityLabel("More actions")
                .accessibilityIdentifier("agents_setParent")
            }
        }
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.listRowVerticalPadding)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

private struct AmbiguousSuggestionRow: View {
    let item: DatabaseManager.AmbiguousSuggestionSession
    let isBusy: Bool
    let onSelectCandidate: (DatabaseManager.AmbiguousSuggestionCandidate) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SourcePill(source: item.session.source)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.session.displayTitle)
                    .font(.callout)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(item.session.displayDate)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            if isBusy {
                ProgressView().scaleEffect(0.6)
            } else {
                HStack(spacing: 6) {
                    ForEach(item.candidates.prefix(3)) { candidate in
                        Button(candidate.displayTitle) { onSelectCandidate(candidate) }
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                            .lineLimit(1)
                            .frame(maxWidth: 120, alignment: .trailing)
                    }
                }
                Button("Dismiss") { onDismiss() }
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
                    .buttonStyle(.plain)
            }
        }
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.listRowVerticalPadding)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
