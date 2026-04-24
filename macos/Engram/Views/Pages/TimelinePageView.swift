// macos/Engram/Views/Pages/TimelinePageView.swift
import SwiftUI

struct TimelinePageView: View {
    @Environment(DatabaseManager.self) var db
    @State private var timeline: [(date: String, sessions: [Session])] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "chart.bar.xaxis", title: "Timeline", badge: "30d")
                if timeline.isEmpty && !isLoading {
                    EmptyState(icon: "calendar", title: "No activity", message: "No sessions in the last 30 days")
                        .accessibilityIdentifier("timeline_emptyState")
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(timeline, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(formatDateLabel(group.date))
                                        .font(.headline)
                                        .foregroundStyle(Theme.primaryText)
                                    Text("\(group.sessions.count) sessions")
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                    Spacer()
                                }
                                .padding(.top, 4)
                                ForEach(group.sessions) { session in
                                    ExpandableSessionCard(
                                        session: session,
                                        confirmedChildCount: confirmedCounts[session.id] ?? 0,
                                        suggestedChildCount: suggestedCounts[session.id] ?? 0,
                                        onTap: {
                                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                        },
                                        onChildTap: { child in
                                            NotificationCenter.default.post(name: .openSession, object: SessionBox(child))
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("timeline_container")
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let database = db
            let data = try await Task.detached { [database] in
                let tl = try database.sessionTimeline(days: 30)
                let allSessions = tl.flatMap(\.sessions)
                let parentIds = allSessions.map(\.id)
                let confirmed = try database.childCount(parentIds: parentIds)
                let suggested = try database.suggestedChildCount(parentIds: parentIds)
                return (tl, confirmed, suggested)
            }.value
            timeline = data.0
            confirmedCounts = data.1
            suggestedCounts = data.2
        } catch {
            EngramLogger.error("TimelinePage load failed", module: .ui, error: error)
        }
    }

    private func formatDateLabel(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}
