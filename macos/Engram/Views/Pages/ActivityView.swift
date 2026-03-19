// macos/Engram/Views/Pages/ActivityView.swift
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var dailyActivity: [(date: String, count: Int)] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var todayCount = 0
    @State private var weekCount = 0
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(sourceDist.count)", label: "Active Sources")
                    KPICard(value: "\(todayCount)", label: "Sessions Today")
                    KPICard(value: "\(weekCount)", label: "This Week")
                }
                SectionHeader(icon: "chart.bar", title: "Daily Activity", badge: "30d")
                ActivityChart(data: dailyActivity).frame(height: 200)
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)
                SectionHeader(icon: "chart.pie", title: "By Source")
                ForEach(sourceDist.prefix(10), id: \.source) { item in
                    HStack {
                        SourcePill(source: item.source)
                        Spacer()
                        Text("\(item.count) sessions")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0xA0A1A8))
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dailyActivity = try db.dailyActivity(days: 30)
            hourlyActivity = try db.hourlyActivity()
            sourceDist = try db.sourceDistribution()
            let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
            let weekAgo = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
            todayCount = try db.listSessions(since: today, limit: 1000).count
            weekCount = try db.listSessions(since: weekAgo, limit: 10000).count
        } catch { print("ActivityView error:", error) }
    }
}
