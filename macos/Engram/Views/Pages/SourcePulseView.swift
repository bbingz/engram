// macos/Engram/Views/Pages/SourcePulseView.swift
import SwiftUI

struct SourcePulseView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var daemonClient: DaemonClient

    @State private var sources: [SourceInfo] = []
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var liveSessions: [LiveSessionInfo] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var liveTimer: Timer?

    private var totalIndexed: Int { sources.reduce(0) { $0 + $1.sessionCount } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(sources.count)", label: "Active Sources")
                    KPICard(value: formatNumber(totalIndexed), label: "Total Indexed")
                    if !liveSessions.isEmpty {
                        KPICard(value: "\(liveSessions.count)", label: "Live Now")
                    }
                }

                // Live Sessions section
                if !liveSessions.isEmpty {
                    SectionHeader(icon: "bolt.fill", title: "Live Sessions",
                                 onRefresh: { Task { await loadLiveSessions() } })
                    LazyVStack(spacing: 4) {
                        ForEach(liveSessions) { session in
                            LiveSessionCard(session: session)
                        }
                    }
                }
                if let error {
                    AlertBanner(message: "Failed to load source data: \(error)")
                }
                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "Sources",
                             onRefresh: { Task { await loadData() } })
                if sources.isEmpty && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources", message: "No adapter sources detected")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(sources) { source in
                            HStack(spacing: 12) {
                                SourcePill(source: source.name)
                                Spacer()
                                Text("\(source.sessionCount) sessions")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                if let latest = source.latestIndexed {
                                    Text(latest.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !sourceDist.isEmpty {
                    SectionHeader(icon: "chart.pie", title: "Distribution")
                    BarChart(items: sourceDist.prefix(10).map { item in
                        BarChartItem(label: SourceColors.label(for: item.source), value: item.count, color: SourceColors.color(for: item.source))
                    })
                }
            }
            .padding(24)
        }
        .task {
            await loadData()
            await loadLiveSessions()
            // Auto-refresh live sessions every 10s
            liveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                Task { @MainActor in await loadLiveSessions() }
            }
        }
        .onDisappear { liveTimer?.invalidate(); liveTimer = nil }
    }

    private func loadLiveSessions() async {
        do {
            let response: LiveSessionsResponse = try await daemonClient.fetch("/api/live")
            liveSessions = response.sessions
        } catch {
            liveSessions = []
        }
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            sources = try await daemonClient.fetch("/api/sources")
        } catch {
            self.error = error.localizedDescription
            do {
                sourceDist = try db.sourceDistribution()
                sources = sourceDist.map { SourceInfo(name: $0.source, sessionCount: $0.count, latestIndexed: nil) }
            } catch {}
        }
        do { sourceDist = try db.sourceDistribution() } catch {}
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
