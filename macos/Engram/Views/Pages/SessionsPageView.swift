// macos/Engram/Views/Pages/SessionsPageView.swift
import SwiftUI

struct SessionsPageView: View {
    @Environment(DatabaseManager.self) var db
    @AppStorage("sessions.showHidden") private var showHiddenSessions = false

    @State private var sessions: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var totalCount = 0
    @State private var totalMessages = 0
    @State private var avgDurationSeconds: Double?
    @State private var timeFilter = "All Time"
    @State private var sourceFilter: String? = nil
    @State private var availableSources: [String] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    private let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load sessions: \(loadError)")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(totalCount)", label: "Total Sessions")
                        .accessibilityIdentifier("sessions_kpiCard_total")
                    KPICard(value: formatNumber(totalMessages), label: "Messages")
                        .accessibilityIdentifier("sessions_kpiCard_messages")
                    KPICard(value: avgDuration, label: "Avg Duration")
                        .accessibilityIdentifier("sessions_kpiCard_avgDuration")
                }

                HStack(spacing: 12) {
                    FilterPills(options: timeOptions, selected: $timeFilter)
                        .accessibilityIdentifier("sessions_filterPills")
                    Spacer()
                    Toggle("Show hidden sessions", isOn: $showHiddenSessions)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("sessions_showHiddenToggle")
                    if !availableSources.isEmpty {
                        Picker("Source", selection: Binding(
                            get: { sourceFilter ?? "All" },
                            set: { sourceFilter = $0 == "All" ? nil : $0 }
                        )) {
                            Text("All Sources").tag("All")
                            ForEach(availableSources, id: \.self) { source in
                                Text(SourceColors.label(for: source)).tag(source)
                            }
                        }
                        .frame(width: 140)
                        .accessibilityIdentifier("sessions_sourcePicker")
                    }
                }

                if sessions.isEmpty && !isLoading {
                    EmptyState(icon: "bubble.left.and.bubble.right", title: "No sessions", message: "No sessions match your filters")
                        .accessibilityIdentifier("sessions_emptyState")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            ExpandableSessionCard(
                                session: session,
                                confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                includeHiddenChildren: showHiddenSessions,
                                onTap: {
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                },
                                onChildTap: { child in
                                    NotificationCenter.default.post(name: .openSession, object: SessionBox(child))
                                }
                            )
                            .accessibilityIdentifier("sessions_row_\(index)")
                        }
                    }
                    .accessibilityIdentifier("sessions_list")
                }
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions_container")
        .task { await loadData() }
        .onChange(of: timeFilter) { _, _ in Task { await loadData() } }
        .onChange(of: sourceFilter) { _, _ in Task { await loadData() } }
        .onChange(of: showHiddenSessions) { _, _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let db = self.db
            let sources: Set<String> = sourceFilter.map { [$0] } ?? []
            let since = sinceDate(for: timeFilter)
            let includeHidden = showHiddenSessions
            let data = try await Task.detached {
                let loaded = try db.listSessions(
                    sources: sources,
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false,
                    sort: .updatedDesc,
                    limit: 200
                )
                let stats = try db.sessionListStats(
                    sources: sources,
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false
                )
                let sourceOptions = try db.sessionListStats(
                    since: since,
                    includeHidden: includeHidden,
                    subAgent: false
                ).sources
                let parentIds = loaded.map(\.id)
                let confirmed = try db.childCount(parentIds: parentIds, includeHidden: includeHidden)
                let suggested = try db.suggestedChildCount(parentIds: parentIds, includeHidden: includeHidden)
                return (loaded, confirmed, suggested, stats, sourceOptions)
            }.value
            sessions = data.0
            confirmedCounts = data.1
            suggestedCounts = data.2
            totalCount = data.3.totalSessions
            totalMessages = data.3.totalMessages
            avgDurationSeconds = data.3.avgDurationSeconds
            availableSources = data.4
            loadError = nil
        } catch {
            EngramLogger.error("SessionsPage load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }

    private func sinceDate(for filter: String) -> String? {
        let cal = Calendar.current
        let now = Date()
        let formatter = ISO8601DateFormatter()
        switch filter {
        case "Today": return formatter.string(from: cal.startOfDay(for: now))
        case "This Week": return formatter.string(from: cal.date(byAdding: .day, value: -7, to: now) ?? now)
        case "This Month": return formatter.string(from: cal.date(byAdding: .month, value: -1, to: now) ?? now)
        default: return nil
        }
    }

    private var avgDuration: String {
        guard let avg = avgDurationSeconds else { return "—" }
        if avg < 60 { return "\(Int(avg))s" }
        if avg < 3600 { return "\(Int(avg / 60))m" }
        return String(format: "%.1fh", avg / 3600)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
