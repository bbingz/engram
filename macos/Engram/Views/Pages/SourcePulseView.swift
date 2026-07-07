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
    @State private var disabledSources: Set<String> = []

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
                let groups = Self.groupedSourceRows(catalog: SourceCatalog.all, live: sources)
                if groups.allSatisfy(\.rows.isEmpty) && !isLoading {
                    EmptyState(icon: "antenna.radiowaves.left.and.right", title: "No sources", message: "No adapter sources detected")
                        .accessibilityIdentifier("sourcePulse_emptyState")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            sourceRowsGroup(group)
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
        // Per-source ingest opt-out state (feature #2 slice B) for toggle render.
        if let disabled = try? await serviceClient.disabledSources() {
            disabledSources = Set(disabled)
        }
        await loadCosts()
    }

    /// Toggle ingest for a source, then refresh so the list reflects the new
    /// disabled set, hidden/unhidden counts, and toggle state.
    private func setSourceEnabled(_ source: String, enabled: Bool) async {
        do {
            try await serviceClient.setSourceEnabled(source: source, enabled: enabled)
            // Optimistic local update so the toggle reflects instantly; loadData
            // reconciles with the authoritative service set right after.
            if enabled {
                disabledSources.remove(source)
            } else {
                disabledSources.insert(source)
            }
            await loadData()
        } catch {
            self.error = error.localizedDescription
        }
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
    private func sourceRowsGroup(_ group: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.secondaryText)
                if group.id == "archived" {
                    factPill("Default off", color: Theme.gray)
                }
                Spacer()
                Text("\(group.rows.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .accessibilityIdentifier("sourcePulse_sourceGroup_\(group.id)")

            LazyVStack(spacing: 4) {
                ForEach(group.rows) { row in
                    sourceRow(row, isArchived: group.id == "archived")
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(_ row: SourceRow, isArchived: Bool) -> some View {
        let isDisabled = disabledSources.contains(row.id)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                switch row {
                case let .detected(source):
                    detectedRow(source, isArchived: isArchived)
                case let .catalogOnly(entry):
                    catalogOnlyRow(entry)
                }
            }
            .opacity(isDisabled ? 0.5 : 1)
            sourceIngestToggle(sourceID: row.id, isDisabled: isDisabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Per-source ingest control (feature #2 slice B). Disabling stops indexing
    /// the source and hides its existing sessions; enabling reverses both.
    @ViewBuilder
    private func sourceIngestToggle(sourceID: String, isDisabled: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Toggle(
                "",
                isOn: Binding(
                    get: { !isDisabled },
                    set: { newValue in
                        Task { await setSourceEnabled(sourceID, enabled: newValue) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(isDisabled ? "Indexing disabled — turn on to resume" : "Indexing enabled — turn off to stop and hide")
            .accessibilityIdentifier("sourcePulse_ingestToggle_\(sourceID)")
            if isDisabled {
                Text("DISABLED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.orange.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private func detectedRow(_ source: EngramServiceSourceInfo, isArchived: Bool) -> some View {
        HStack(spacing: 12) {
            SourcePill(source: source.name)
            healthBadge(source.healthStatus)
            Spacer()
            Text("\(source.sessionCount) sessions")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            if source.latestIndexed != nil {
                let now = Date()
                let freshness = SourceIndexFreshness.classify(source.latestIndexed, now: now)
                let isStale = freshness == .stale && !isArchived
                Text(SourceIndexFreshness.relativeAgeText(source.latestIndexed, now: now))
                    .font(.caption)
                    .foregroundStyle(isStale ? Theme.orange : Theme.tertiaryText)
                if isStale {
                    Text("STALE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.orange.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
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

    @ViewBuilder
    private func catalogOnlyRow(_ entry: SourceCatalogEntry) -> some View {
        HStack(spacing: 12) {
            SourcePill(source: entry.id)
            Text("NOT DETECTED")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.gray)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.gray.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer()
            Text("0 sessions")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            PathExistsIndicator(path: entry.defaultPath)
        }
        HStack(spacing: 8) {
            if entry.cacheOnly {
                factPill("Cache only", color: Theme.gray)
                    .help("Live capture is off for this source; only cached/transcript data is indexed.")
            }
            Text(verbatim: entry.defaultPath)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.tertiaryText)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("sourcePulse_catalogOnlyRow")
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

    /// One row in the merged Sources list: either a live (detected) source with
    /// indexed sessions and health, or a catalog source that the service did
    /// not return because it has no indexed sessions yet.
    enum SourceRow: Identifiable {
        case detected(EngramServiceSourceInfo)
        case catalogOnly(SourceCatalogEntry)

        var id: String {
            switch self {
            case let .detected(source): return source.id
            case let .catalogOnly(entry): return entry.id
            }
        }
    }

    struct SourceGroup: Identifiable {
        let id: String
        let title: String
        let rows: [SourceRow]
    }

    /// Overlay the static catalog with live service rows, keyed by source id.
    /// Catalog order is preserved; catalog sources with a live row render the
    /// detected (health) row, the rest render a "not detected" row. Any live
    /// source missing from the catalog is appended so nothing is dropped.
    /// Pure (no SwiftUI / service) so it is unit-testable in isolation.
    static func mergedSourceRows(
        catalog: [SourceCatalogEntry],
        live: [EngramServiceSourceInfo]
    ) -> [SourceRow] {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let catalogIDs = Set(catalog.map(\.id))
        var rows: [SourceRow] = catalog.map { entry in
            if let source = liveByID[entry.id] {
                return .detected(source)
            }
            return .catalogOnly(entry)
        }
        rows.append(contentsOf: live.filter { !catalogIDs.contains($0.id) }.map(SourceRow.detected))
        return rows
    }

    static func groupedSourceRows(
        catalog: [SourceCatalogEntry],
        live: [EngramServiceSourceInfo]
    ) -> [SourceGroup] {
        let rows = mergedSourceRows(catalog: catalog, live: live)
        let archivedIDs = Set(catalog.filter(\.archivedByDefault).map(\.id))
        let active = rows.filter { !archivedIDs.contains($0.id) }
        let archived = rows.filter { archivedIDs.contains($0.id) }
        return [
            SourceGroup(id: "active", title: "Active Sources", rows: active),
            SourceGroup(id: "archived", title: "Archived", rows: archived),
        ].filter { !$0.rows.isEmpty }
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
