// macos/Engram/Views/Pages/SourcePulseView.swift
import SwiftUI

struct SourcePulseView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    @State private var sources: [EngramServiceSourceInfo] = []
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var liveSessions: [EngramServiceLiveSessionInfo] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var liveTimer: Timer?
    @State private var expandedGroups: Set<String> = []

    private var totalIndexed: Int { sources.reduce(0) { $0 + $1.sessionCount } }
    private var activeSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "active" } }
    private var idleSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "idle" } }
    private var recentSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "recent" || $0.activityLevel == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(sources.count)", label: "Active Sources")
                    KPICard(value: formatNumber(totalIndexed), label: "Total Indexed")
                    if !activeSessions.isEmpty {
                        KPICard(value: "\(activeSessions.count)", label: "Active")
                    }
                    if !idleSessions.isEmpty {
                        KPICard(value: "\(idleSessions.count)", label: "Idle")
                    }
                }
                .accessibilityIdentifier("sourcePulse_statusGrid")

                // Live Sessions section — grouped by activity level
                if !liveSessions.isEmpty {
                    SectionHeader(icon: "bolt.fill", title: "Sessions (\(liveSessions.count))",
                                 onRefresh: { Task { await loadLiveSessions() } })

                    sessionGroup("Active", color: .green, sessions: activeSessions)
                    sessionGroup("Idle", color: .yellow, sessions: idleSessions)
                    sessionGroup("Recent", color: .gray, sessions: recentSessions)
                }
                if let error {
                    AlertBanner(message: "Failed to load source data: \(error)")
                }
                SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "Sources",
                             onRefresh: { Task { await loadData() } })
                if sources.isEmpty && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources", message: "No adapter sources detected")
                        .accessibilityIdentifier("sourcePulse_emptyState")
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
        .accessibilityIdentifier("sourcePulse_container")
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
            let response = try await serviceClient.liveSessions()
            liveSessions = response.sessions
        } catch {
            liveSessions = []
        }
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            sources = try await serviceClient.sources()
        } catch {
            self.error = error.localizedDescription
            do {
                sourceDist = try db.sourceDistribution()
                sources = sourceDist.map { EngramServiceSourceInfo(name: $0.source, sessionCount: $0.count, latestIndexed: nil) }
            } catch {}
        }
        do { sourceDist = try db.sourceDistribution() } catch {}
    }

    @ViewBuilder
    private func sessionGroup(_ label: String, color: Color, sessions: [EngramServiceLiveSessionInfo]) -> some View {
        if !sessions.isEmpty {
            let isExpanded = expandedGroups.contains(label)
            let shown = isExpanded ? sessions : Array(sessions.prefix(10))

            HStack(spacing: 6) {
                Label(label, systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                Text("(\(sessions.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(shown) { session in
                    LiveSessionCard(session: session)
                }
                if sessions.count > 10 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedGroups.remove(label)
                            } else {
                                expandedGroups.insert(label)
                            }
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "+ \(sessions.count - 10) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
