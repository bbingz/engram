// macos/Engram/Views/Pages/ActivityView.swift
import SwiftUI

struct ActivityView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(\.engramFixedDate) var fixedDate
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    // Coalesce background index-tick reloads so indexing churn doesn't refetch
    // the activity charts on every count bump (#3).
    @State private var lastFilterKey: [AnyHashable]? = nil
    @State private var dailySourceActivity: [(date: String, segments: [(source: String, count: Int)])] = []
    @State private var hourlyActivity: [Int] = Array(repeating: 0, count: 24)
    @State private var sourceDist: [(source: String, count: Int)] = []
    @State private var topFiles: [(filePath: String, action: String, totalCount: Int, sessionCount: Int)] = []
    @State private var todayCount = 0
    @State private var weekCount = 0
    @State private var isLoading = true
    @State private var loadGeneration = 0
    @State private var loadError: String? = nil
    @State private var openRequestId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let loadError {
                    AlertBanner(message: "Failed to load activity: \(loadError)", action: ("Retry", { Task { await loadData() } }))
                }
                if isLoading && dailySourceActivity.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("activity_loading")
                } else if sourceDist.isEmpty && weekCount == 0 && loadError == nil {
                    EmptyState(icon: "chart.bar", title: "No activity yet", message: "Indexed sessions will appear here")
                        .accessibilityIdentifier("activity_emptyState")
                } else {
                    activityBody
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("activity_container")
        .task(id: serviceStatusStore.browseReloadToken) {
            let filterKey: [AnyHashable] = []
            let plan = BrowseReloadCoalescer.plan(filterKey: filterKey, lastFilterKey: lastFilterKey)
            if plan.debounce {
                try? await Task.sleep(for: BrowseReloadCoalescer.debounceInterval)
                if Task.isCancelled { return }
            }
            lastFilterKey = filterKey
            await loadData()
        }
    }

    @ViewBuilder private var activityBody: some View {
        HStack(spacing: 12) {
            KPICard(value: "\(sourceDist.count)", label: "Active Sources")
            KPICard(value: "\(todayCount)", label: "Sessions Today")
            KPICard(value: "\(weekCount)", label: "This Week")
        }
        SectionHeader(icon: "chart.bar", title: "Daily Activity", badge: "30d")
        StackedActivityChart(data: dailySourceActivity, sourceOrder: sourceDist.map(\.source))
            .frame(height: 200)
            .accessibilityIdentifier("activity_dailyChart")
        SectionHeader(icon: "clock", title: "When You Work")
        HeatmapGrid(data: hourlyActivity)
            .accessibilityIdentifier("activity_heatmap")
        SectionHeader(icon: "chart.pie", title: "By Source")
        ForEach(sourceDist.prefix(10), id: \.source) { item in
            Button {
                openMostRecent(source: item.source)
            } label: {
                HStack {
                    SourcePill(source: item.source)
                    Spacer()
                    Text("\(item.count) sessions")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            // One VoiceOver stop: pill + count read as a single button.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("activity_sourceRow")
        }
        if !topFiles.isEmpty {
            SectionHeader(icon: "doc.text", title: "Top Files")
            // fileActivity groups by (file_path, action), so the same path can
            // appear under different actions. Key the row on a composite id of
            // both to avoid a duplicate-id collision in ForEach.
            ForEach(topFiles.map(TopFileRow.init)) { file in
                HStack {
                    Text((file.filePath as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(file.action)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    Text("\(file.totalCount)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("activity_topFileRow")
            }
        }
    }

    private func openMostRecent(source: String) {
        let requestId = UUID()
        openRequestId = requestId
        let token = SessionNavigationGate.begin()
        let db = self.db
        Task {
            do {
                let session = try await Task.detached {
                    try db.listSessions(
                        sources: [source],
                        topLevelOnly: true,
                        humanDriven: true,
                        sort: .updatedDesc,
                        limit: 1
                    ).first
                }.value
                guard openRequestId == requestId,
                      SessionNavigationGate.isCurrent(token) else { return }
                guard let session else {
                    SessionNavigationGate.complete(token)
                    return
                }
                NotificationCenter.default.post(
                    name: .openSession,
                    object: SessionBox(session, navigationId: token)
                )
            } catch {
                if openRequestId == requestId {
                    SessionNavigationGate.complete(token)
                }
                EngramLogger.error("ActivityView source drill-in failed", module: .ui, error: error)
            }
        }
    }

    private func loadData() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        // UI-C1/C2: run the GRDB reads off the main thread.
        let db = self.db
        let now = fixedDate ?? Date()
        let today = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: now))
        let weekAgo = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now)
        let thirtyDaysAgo = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now)
        do {
            let loaded = try await Task.detached {
                let dailySource = try db.dailySourceActivity(days: 30, now: now)
                let hourly = try db.hourlyActivity()
                let dist = try db.sourceDistribution()
                let todayN = try db.countSessionsSince(today)
                let weekN = try db.countSessionsSince(weekAgo)
                let files = try db.fileActivity(project: nil, since: thirtyDaysAgo, limit: 8)
                return (dailySource, hourly, dist, todayN, weekN, files)
            }.value
            guard BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            dailySourceActivity = loaded.0
            hourlyActivity = loaded.1
            sourceDist = loaded.2
            todayCount = loaded.3
            weekCount = loaded.4
            topFiles = loaded.5
            loadError = nil
        } catch {
            guard BrowseReloadCoalescer.shouldApplyLoad(
                resultGeneration: generation,
                currentGeneration: loadGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            EngramLogger.error("ActivityView load failed", module: .ui, error: error)
            loadError = ServiceErrorPresenter.displayMessage(for: error)
        }
    }
}

/// Identifiable wrapper for a Top Files row. fileActivity groups by
/// (file_path, action), so `filePath` alone is not unique — the id is the
/// (filePath, action) pair.
private struct TopFileRow: Identifiable {
    let filePath: String
    let action: String
    let totalCount: Int
    let sessionCount: Int

    var id: String { "\(filePath)-\(action)" }

    init(_ row: (filePath: String, action: String, totalCount: Int, sessionCount: Int)) {
        self.filePath = row.filePath
        self.action = row.action
        self.totalCount = row.totalCount
        self.sessionCount = row.sessionCount
    }
}
