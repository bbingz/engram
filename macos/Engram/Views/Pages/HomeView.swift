// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var db: DatabaseManager

    @State private var kpi: DatabaseManager.KPIStats?
    @State private var dailyActivity: [(date: String, count: Int)] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var tiers: (premium: Int, normal: Int, lite: Int, skip: Int) = (0, 0, 0, 0)
    @State private var recentSessions: [Session] = []
    @State private var isLoading = true
    @State private var alertMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greetingSection
                kpiSection
                if let alertMessage {
                    AlertBanner(message: alertMessage)
                }
                chartsSection
                distributionSection
                recentSessionsSection
            }
            .padding(24)
        }
        .accessibilityIdentifier("home_container")
        .task { await loadData() }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(Theme.primaryText)
            if let kpi {
                Text("\(kpi.sessions) sessions across \(kpi.sources) sources")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = NSFullUserName().components(separatedBy: " ").first ?? NSUserName()
        switch hour {
        case 5..<12:  return "Good morning, \(name)"
        case 12..<17: return "Good afternoon, \(name)"
        case 17..<22: return "Good evening, \(name)"
        default:      return "Good night, \(name)"
        }
    }

    // MARK: - KPI

    @ViewBuilder
    private var kpiSection: some View {
        if let kpi {
            HStack(spacing: 12) {
                KPICard(value: formatNumber(kpi.sessions), label: "Sessions")
                    .accessibilityIdentifier("home_kpiCard_sessions")
                KPICard(value: "\(kpi.sources)", label: "Sources")
                    .accessibilityIdentifier("home_kpiCard_sources")
                KPICard(value: formatNumber(kpi.messages), label: "Messages")
                    .accessibilityIdentifier("home_kpiCard_messages")
                KPICard(value: "\(kpi.projects)", label: "Projects")
                    .accessibilityIdentifier("home_kpiCard_projects")
            }
            .accessibilityIdentifier("home_kpiCards")
        } else {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            }
        }
    }

    // MARK: - Charts

    private var chartsSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                SectionHeader(icon: "chart.bar", title: "Activity", badge: "30d")
                ActivityChart(data: dailyActivity)
                    .frame(height: 140)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home_dailyChart")

            VStack(alignment: .leading) {
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home_heatmap")
        }
    }

    // MARK: - Distribution

    private var distributionSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                SectionHeader(icon: "chart.pie", title: "Sources")
                BarChart(items: sourceDist.prefix(7).map { item in
                    BarChartItem(
                        label: SourceColors.label(for: item.source),
                        value: item.count,
                        color: SourceColors.color(for: item.source)
                    )
                })
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home_sourceDistribution")

            VStack(alignment: .leading) {
                SectionHeader(icon: "square.stack.3d.up", title: "Tiers")
                TierBar(
                    premium: tiers.premium,
                    normal: tiers.normal,
                    lite: tiers.lite,
                    skip: tiers.skip
                )
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home_tierDistribution")
        }
    }

    // MARK: - Recent Sessions

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: "clock.arrow.circlepath", title: "Recent Sessions")
            if recentSessions.isEmpty && !isLoading {
                EmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No sessions yet",
                    message: "Sessions will appear here after indexing"
                )
                .frame(height: 100)
            } else {
                ForEach(Array(recentSessions.enumerated()), id: \.element.id) { index, session in
                    SessionCard(session: session) {
                        NotificationCenter.default.post(
                            name: .openSession,
                            object: SessionBox(session)
                        )
                    }
                    .accessibilityIdentifier("home_recentSession_\(index)")
                }
            }
        }
        .accessibilityIdentifier("home_recentSessions")
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        do {
            kpi = try db.kpiStats()
            dailyActivity = try db.dailyActivity(days: 30)
            hourlyActivity = try db.hourlyActivity()
            sourceDist = try db.sourceDistribution()
            tiers = try db.tierDistribution()
            recentSessions = try db.recentSessions(limit: 8)
            alertMessage = nil  // Alerts populated when health issues detected
        } catch {
            print("HomeView load error:", error)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
