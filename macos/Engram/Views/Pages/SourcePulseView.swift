// macos/Engram/Views/Pages/SourcePulseView.swift
import AppKit
import SwiftUI

struct SourcePulseView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient

    @State private var sources: [EngramServiceSourceInfo] = []
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var liveSessions: [EngramServiceLiveSessionInfo] = []
    @State private var costs: EngramServiceCostsResponse? = nil
    @State private var costsError: String? = nil
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var liveTimer: Timer?
    @State private var liveRefreshTask: Task<Void, Never>? = nil
    @State private var expandedGroups: Set<String> = []

    private var totalIndexed: Int { sources.reduce(0) { $0 + $1.sessionCount } }
    private var archiveStorePath: String { (db.path as NSString).abbreviatingWithTildeInPath }
    private var activeSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "active" } }
    private var idleSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "idle" } }
    private var recentSessions: [EngramServiceLiveSessionInfo] { liveSessions.filter { $0.activityLevel == "recent" || $0.activityLevel == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    KPICard(value: "\(sources.count)", label: "Active Sources")
                    KPICard(value: formatNumber(totalIndexed), label: "Archived Sessions")
                    if !activeSessions.isEmpty {
                        KPICard(value: "\(activeSessions.count)", label: "Active")
                    }
                    if !idleSessions.isEmpty {
                        KPICard(value: "\(idleSessions.count)", label: "Idle")
                    }
                }
                .accessibilityIdentifier("sourcePulse_statusGrid")

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(Theme.tertiaryText)
                    Text("Local archive store")
                        .foregroundStyle(Theme.secondaryText)
                    Text(archiveStorePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    Button(action: revealArchiveStore) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .help("Reveal archive store in Finder")
                    .accessibilityLabel("Reveal archive store in Finder")
                    .accessibilityIdentifier("sourcePulse_revealArchiveStore")
                }
                .font(.caption)
                .accessibilityIdentifier("sourcePulse_archiveStore")

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
                    .help("Indexing runs automatically in the background; refresh re-reads current counts.")
                if sources.isEmpty && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources", message: "No adapter sources detected")
                        .accessibilityIdentifier("sourcePulse_emptyState")
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(sources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    SourcePill(source: source.name)
                                    healthBadge(source.healthStatus)
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
                                HStack(spacing: 8) {
                                    if source.liveSyncDisabled {
                                        factPill("Cache only", color: Theme.gray)
                                            .help("Live capture is off for this source; only cached/transcript data is indexed.")
                                    }
                                    factPill("Search \(source.searchCoveragePercent)%")
                                    if source.failedIndexJobCount > 0 {
                                        factPill("\(source.failedIndexJobCount) issue\(source.failedIndexJobCount == 1 ? "" : "s")", color: Theme.orange)
                                            .help("Index jobs that failed for this source. They retry automatically on the next indexing pass.")
                                    }
                                    factPill(Self.tokenCoveragePillText(source.tokenCoveragePercent))
                                    if source.costedSessionCount > 0 {
                                        factPill("\(source.costedSessionCount) costed")
                                    }
                                    if let metric = source.latestUsageMetric,
                                       let value = source.latestUsageValue {
                                        factPill(
                                            Self.usagePillText(
                                                metric: metric,
                                                value: value,
                                                unit: source.latestUsageUnit,
                                                limit: source.latestUsageLimitValue
                                            ),
                                            color: usageColor(source.latestUsageStatus)
                                        )
                                    }
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

                if let costsError {
                    AlertBanner(message: "Failed to load cost data: \(costsError)")
                }
                CostSummarySection(costs: costs, isLoading: isLoading && costs == nil)
            }
            .padding(24)
        }
        .accessibilityIdentifier("sourcePulse_container")
        .task {
            await loadData()
            await loadLiveSessions()
            // Auto-refresh live sessions every 10s. Track the inner Task and cancel
            // the prior one each tick so it can't outlive the view / pile up.
            liveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                liveRefreshTask?.cancel()
                liveRefreshTask = Task { @MainActor in await loadLiveSessions() }
            }
        }
        .onDisappear {
            liveTimer?.invalidate(); liveTimer = nil
            liveRefreshTask?.cancel(); liveRefreshTask = nil
        }
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
        let db = self.db
        do {
            sources = try await serviceClient.sources()
        } catch {
            self.error = error.localizedDescription
            // UI-C1/C2: DB fallback read runs off the main thread.
            if let dist = try? await Task.detached(operation: { try db.sourceDistribution() }).value {
                sourceDist = dist
                sources = dist.map { EngramServiceSourceInfo(name: $0.source, sessionCount: $0.count, latestIndexed: nil) }
            }
        }
        // Distribution chart read also off-main.
        if let dist = try? await Task.detached(operation: { try db.sourceDistribution() }).value {
            sourceDist = dist
        }
        await loadCosts()
    }

    private func loadCosts() async {
        do {
            costs = try await serviceClient.costs()
            costsError = nil
        } catch {
            costsError = error.localizedDescription
        }
    }

    private func revealArchiveStore() {
        NSWorkspace.shared.selectFile(db.path, inFileViewerRootedAtPath: "")
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

    static func usagePillText(metric: String, value: Double, unit: String?, limit: Double? = nil) -> String {
        "\(metric) \(formattedPressureValue(metric: metric, value: value, unit: unit, limit: limit))"
    }

    static func tokenCoveragePillText(_ percent: Int) -> String {
        "Tokens \(min(100, max(0, percent)))%"
    }

    static func formattedUsageValue(_ value: Double, unit: String?, limit: Double? = nil) -> String {
        if let limit {
            return "\(oneDecimalUsageNumber(value))/\(oneDecimalUsageNumber(limit))\(unit ?? "")"
        }
        switch unit {
        case "tokens":
            return "\(compactUsageNumber(value)) tok"
        case "%", nil:
            return "\(decimalUsageNumber(value))%"
        case "$":
            return "$\(decimalUsageNumber(value))"
        case let unit?:
            return "\(decimalUsageNumber(value))\(unit)"
        }
    }

    private static func formattedPressureValue(metric: String, value: Double, unit: String?, limit: Double?) -> String {
        let base = formattedUsageValue(value, unit: unit, limit: limit)
        guard isPercentUnit(unit),
              limit == nil,
              metric.lowercased().contains("remaining")
        else {
            return base
        }
        let used = min(100, max(0, 100 - value))
        return "\(base) (\(formattedUsageValue(used, unit: "%")) used)"
    }

    private static func isPercentUnit(_ unit: String?) -> Bool {
        unit == nil || unit == "%"
    }

    private static func compactUsageNumber(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return decimalUsageNumber(value)
    }

    private static func decimalUsageNumber(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private static func oneDecimalUsageNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    @ViewBuilder
    private func healthBadge(_ status: String) -> some View {
        let color: Color = switch status {
        case "critical": .red
        case "healthy": Theme.green
        case "attention": Theme.orange
        case "partial": Theme.orange
        case "empty": Theme.gray
        default: Theme.gray
        }
        Text(status.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func usageColor(_ status: String?) -> Color {
        switch Self.normalizedUsageStatusForDisplay(status) {
        case "critical": .red
        case "attention": Theme.orange
        default: Theme.tertiaryText
        }
    }

    static func normalizedUsageStatusForDisplay(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    @ViewBuilder
    private func factPill(_ text: String, color: Color = Theme.tertiaryText) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceHighlight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
