// macos/Engram/Views/Pages/TimelinePageView.swift
import SwiftUI

private enum TimelineSortMode: String, CaseIterable, Identifiable {
    case activity
    case created

    var id: String { rawValue }

    var databaseSort: SessionSort {
        switch self {
        case .activity:
            .updatedDesc
        case .created:
            .createdDesc
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .activity:
            "Active"
        case .created:
            "Created"
        }
    }
}

struct TimelinePageView: View {
    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    @Environment(DatabaseManager.self) var db
    @State private var timeline: [(date: String, sessions: [Session])] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var sortMode: TimelineSortMode = .activity
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    SectionHeader(icon: "chart.bar.xaxis", title: "Timeline", badge: "30d")
                    Spacer(minLength: 12)
                    Picker("Sort", selection: $sortMode) {
                        ForEach(TimelineSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 144)
                    .accessibilityIdentifier("timeline_sortPicker")
                }
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
                                    Text(sessionCountLabel(group.sessions.count))
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
        // .task(id:) cancels the in-flight load when the sort changes, so a
        // slower older load can't land last and show the previous sort's data.
        .task(id: sortMode) { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let database = db
            let sort = sortMode.databaseSort
            let data = try await Task.detached { [database, sort] in
                let tl = try database.sessionTimeline(days: 30, sort: sort)
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
        guard let date = Self.inputDateFormatter.date(from: dateStr) else { return dateStr }
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return Self.outputDateFormatter.string(from: date)
    }

    private func sessionCountLabel(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "%lld sessions"), count)
    }
}
