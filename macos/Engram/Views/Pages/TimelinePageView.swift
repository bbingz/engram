// macos/Engram/Views/Pages/TimelinePageView.swift
import SwiftUI

struct TimelinePageView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var timeline: [(date: String, sessions: [Session])] = []
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
                                    SessionCard(session: session) {
                                        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                                    }
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
        do { timeline = try db.sessionTimeline(days: 30) } catch { print("TimelinePage error:", error) }
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
