// macos/Engram/Views/Pages/SearchPageView.swift
import SwiftUI

struct SearchPageView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var query = ""
    @State private var timeFilter = "All Time"
    @State private var results: [Session] = []
    @State private var isSearching = false

    private let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search sessions...", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await performSearch() } }
                    if !query.isEmpty {
                        Button(action: { query = ""; results = [] }) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0x6E7078))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                FilterPills(options: timeOptions, selected: $timeFilter)

                if results.isEmpty && !query.isEmpty && !isSearching {
                    EmptyState(icon: "magnifyingglass", title: "No results", message: "Try a different search term")
                } else if results.isEmpty && query.isEmpty {
                    EmptyState(icon: "magnifyingglass", title: "Search sessions", message: "Search by summary, project, or content")
                } else {
                    Text("\(results.count) results").font(.caption).foregroundStyle(Color(hex: 0x6E7078))
                    LazyVStack(spacing: 4) {
                        ForEach(results) { session in
                            SessionCard(session: session) {
                                NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .onChange(of: query) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await performSearch()
            }
        }
        .onChange(of: timeFilter) { _ in Task { await performSearch() } }
    }

    private func performSearch() async {
        guard !query.isEmpty else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        do {
            let searchResults = try db.search(query: query, limit: 100)
            let since = sinceDate(for: timeFilter)
            if let since {
                results = searchResults.filter { $0.startTime >= since }
            } else {
                results = searchResults
            }
        } catch { print("SearchPage error:", error) }
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
}
