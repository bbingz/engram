// macos/Engram/Views/Pages/SessionsPageView.swift
import SwiftUI

struct SessionsPageView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var sessions: [Session] = []
    @State private var totalCount = 0
    @State private var totalMessages = 0
    @State private var timeFilter = "All Time"
    @State private var sourceFilter: String? = nil
    @State private var availableSources: [String] = []
    @State private var isLoading = true

    private let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
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
        .onChange(of: timeFilter) { _ in Task { await loadData() } }
        .onChange(of: sourceFilter) { _ in Task { await loadData() } }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let sources: Set<String> = sourceFilter.map { [$0] } ?? []
            let since = sinceDate(for: timeFilter)
            sessions = try db.listSessions(sources: sources, since: since, subAgent: false, limit: 200)
            totalCount = sessions.count
            totalMessages = sessions.reduce(0) { $0 + $1.messageCount }
            availableSources = Array(Set(sessions.map(\.source))).sorted()
        } catch {
            print("SessionsPage error:", error)
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
        let sessionsWithEnd = sessions.filter { $0.endTime != nil }
        guard !sessionsWithEnd.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        let totalSeconds = sessionsWithEnd.compactMap { s -> TimeInterval? in
            guard let start = formatter.date(from: s.startTime),
                  let end = s.endTime.flatMap({ formatter.date(from: $0) }) else { return nil }
            return end.timeIntervalSince(start)
        }.reduce(0, +)
        let avg = totalSeconds / Double(sessionsWithEnd.count)
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
