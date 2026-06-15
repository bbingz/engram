// macos/Engram/Views/Pages/AgentsView.swift
import SwiftUI

struct AgentsView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

    @State private var parents: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var pendingSuggestions: [Session] = []
    @State private var subAgentCount = 0
    @State private var activeCount = 0
    @State private var inFlightRows: Set<String> = []
    @State private var linkTarget: Session? = nil
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load agent sessions: \(loadError)")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(subAgentCount)", label: "Agent Sessions")
                    KPICard(value: "\(activeCount)", label: "Active (7d)")
                }

                if isLoading && parents.isEmpty && pendingSuggestions.isEmpty {
                    HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                        .padding(.vertical, 24)
                } else if parents.isEmpty && pendingSuggestions.isEmpty {
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

                    SectionHeader(icon: "cpu", title: "Agent Sessions")
                    LazyVStack(spacing: 4) {
                        ForEach(parents) { session in
                            ExpandableSessionCard(
                                session: session,
                                confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                onTap: {
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                },
                                onChildTap: { child in
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(child))
                                },
                                onConfirmSuggestion: { child in confirmSuggestion(child) },
                                onDismissSuggestion: { child in dismissSuggestion(child) }
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
        .task(id: serviceStatusStore.totalSessions) { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        let db = self.db
        do {
            let data = try await Task.detached { () -> (parents: [Session], confirmed: [String: Int], suggested: [String: Int], pending: [Session], subAgents: [Session]) in
                let topLevel = try db.listSessions(subAgent: false, topLevelOnly: true, limit: 200)
                let parentIds = topLevel.map(\.id)
                let confirmed = try db.childCount(parentIds: parentIds)
                let suggested = try db.suggestedChildCount(parentIds: parentIds)
                // Keep only top-level sessions that actually own a group.
                let groups = topLevel.filter { (confirmed[$0.id] ?? 0) + (suggested[$0.id] ?? 0) > 0 }
                let pending = try db.pendingSuggestionSessions(limit: 200)
                // KPI source: the subagent population (NOT rendered as the list).
                let subAgents = try db.listSessions(subAgent: true, limit: 200)
                return (groups, confirmed, suggested, pending, subAgents)
            }.value
            parents = data.parents
            confirmedCounts = data.confirmed
            suggestedCounts = data.suggested
            pendingSuggestions = data.pending
            subAgentCount = data.subAgents.count
            activeCount = Self.activeRoleCount(among: data.subAgents)
            loadError = nil
        } catch {
            EngramLogger.error("AgentsView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }

    /// Resolve a pending child's suggested parent id to the loaded parent's
    /// display title; fall back to the raw id when that parent isn't loaded.
    private func suggestedParentTitle(for child: Session) -> String? {
        guard let parentId = child.suggestedParentId else { return nil }
        return parents.first { $0.id == parentId }?.displayTitle ?? parentId
    }

    private static func activeRoleCount(among subAgents: [Session]) -> Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return Set(subAgents.filter { s in
            EngramTimestampParser.date(from: s.startTime).map { $0 > weekAgo } ?? false
        }.compactMap(\.agentRole)).count
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
                loadError = error.localizedDescription
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
                loadError = error.localizedDescription
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
                .accessibilityIdentifier("agents_setParent")
            }
        }
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
