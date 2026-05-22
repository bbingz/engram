// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

struct HomeView: View {
    @Environment(DatabaseManager.self) var db

    @State private var kpi: DatabaseManager.KPIStats?
    @State private var dailySourceActivity: [(date: String, segments: [(source: String, count: Int)])] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var tiers: (premium: Int, normal: Int, lite: Int, skip: Int) = (0, 0, 0, 0)
    @State private var recentSessions: [Session] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
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
                recentSessionsSection
            }
            .padding(24)
        }
        .modernScrollIndicators()
        .accessibilityIdentifier("home_container")
        .task { await loadData() }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            greetingText
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

    @ViewBuilder
    private var greetingText: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = NSFullUserName().components(separatedBy: " ").first ?? NSUserName()
        switch hour {
        case 5..<12:  Text("Good morning, \(name)")
        case 12..<17: Text("Good afternoon, \(name)")
        case 17..<22: Text("Good evening, \(name)")
        default:      Text("Good night, \(name)")
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
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "chart.bar", title: "Activity", badge: "30d")
                StackedActivityChart(data: dailySourceActivity, sourceOrder: sourceDist.map(\.source))
                    .frame(height: 140)
                sourceLegend
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home_dailyChart")

            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(icon: "clock", title: "When You Work")
                HeatmapGrid(data: hourlyActivity)
                tierSummary
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("home_heatmap")
        }
    }

    private var sourceLegend: some View {
        HStack(spacing: 10) {
            ForEach(sourceDist.prefix(6), id: \.source) { item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(SourceColors.color(for: item.source))
                        .frame(width: 6, height: 6)
                    Text(SourceColors.label(for: item.source))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("home_sourceDistribution")
    }

    private var tierSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Theme.tertiaryText)
                Text("Tiers")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            TierBar(
                premium: tiers.premium,
                normal: tiers.normal,
                lite: tiers.lite,
                skip: tiers.skip
            )
        }
        .padding(.top, 6)
        .accessibilityIdentifier("home_tierDistribution")
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
                    ExpandableSessionCard(
                        session: session,
                        confirmedChildCount: confirmedCounts[session.id] ?? 0,
                        suggestedChildCount: suggestedCounts[session.id] ?? 0,
                        onTap: {
                            NotificationCenter.default.post(
                                name: .openSession,
                                object: SessionBox(session)
                            )
                        },
                        onChildTap: { child in
                            NotificationCenter.default.post(
                                name: .openSession,
                                object: SessionBox(child)
                            )
                        }
                    )
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

        let db = self.db
        do {
            let data = try await Task.detached {
                let kpi = try db.kpiStats()
                let dailySource = try db.dailySourceActivity(days: 30)
                let hourly = try db.hourlyActivity()
                let source = try db.sourceDistribution()
                let tiers = try db.tierDistribution()
                let recent = try db.recentSessions(limit: 8)
                let parentIds = recent.map(\.id)
                let confirmed = try db.childCount(parentIds: parentIds)
                let suggested = try db.suggestedChildCount(parentIds: parentIds)
                return (kpi, dailySource, hourly, source, tiers, recent, confirmed, suggested)
            }.value
            kpi = data.0
            dailySourceActivity = data.1
            hourlyActivity = data.2
            sourceDist = data.3
            tiers = data.4
            recentSessions = data.5
            confirmedCounts = data.6
            suggestedCounts = data.7
            alertMessage = nil
        } catch {
            EngramLogger.error("HomeView load failed", module: .ui, error: error)
            // UI-M1: surface the failure to the user instead of only logging.
            alertMessage = "Failed to load dashboard: \(error.localizedDescription)"
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
