// macos/Engram/Views/Pages/ActivityView.swift
import SwiftUI

struct ActivityView: View {
    @Environment(DatabaseManager.self) var db
    @State private var dailyActivity: [(date: String, count: Int)] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var todayCount = 0
    @State private var weekCount = 0
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load activity: \(loadError)")
                }
                HStack(spacing: 12) {
                    KPICard(value: "\(sourceDist.count)", label: "Active Sources")
                    KPICard(value: "\(todayCount)", label: "Sessions Today")
                    KPICard(value: "\(weekCount)", label: "This Week")
                }
                SectionHeader(icon: "chart.bar", title: "Daily Activity", badge: "30d")
                ActivityChart(data: dailyActivity)
                    .frame(height: 200)
                    .accessibilityIdentifier("activity_dailyChart")
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)
                    .accessibilityIdentifier("activity_heatmap")
                SectionHeader(icon: "chart.pie", title: "By Source")
                ForEach(sourceDist.prefix(10), id: \.source) { item in
                    HStack {
                        SourcePill(source: item.source)
                        Spacer()
                        Text("\(item.count) sessions")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("activity_container")
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        // UI-C1/C2: run the 5 sequential GRDB reads off the main thread.
        let db = self.db
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        let weekAgo = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        do {
            let loaded = try await Task.detached {
                let daily = try db.dailyActivity(days: 30)
                let hourly = try db.hourlyActivity()
                let dist = try db.sourceDistribution()
                let todayN = try db.countSessionsSince(today)
                let weekN = try db.countSessionsSince(weekAgo)
                return (daily, hourly, dist, todayN, weekN)
            }.value
            dailyActivity = loaded.0
            hourlyActivity = loaded.1
            sourceDist = loaded.2
            todayCount = loaded.3
            weekCount = loaded.4
            loadError = nil
        } catch {
            EngramLogger.error("ActivityView load failed", module: .ui, error: error)
            loadError = error.localizedDescription
        }
    }
}
