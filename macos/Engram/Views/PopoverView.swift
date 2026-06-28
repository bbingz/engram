// macos/Engram/Views/PopoverView.swift
import SwiftUI

struct PopoverView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @Environment(EngramServiceClient.self) var serviceClient

    @State private var sourceCount = 0
    @State private var projectCount = 0
    @State private var dbSize: Int64 = 0
    @State private var recentSessions: [Session] = []
    @State private var activeSourceCount: Int = 0
    @State private var totalSourceCount: Int = 0
    @State private var lastIndexedAgo: String = ""
    @State private var liveSessions: [EngramServiceLiveSessionInfo] = []
    @State private var hoveredSessionId: String?
    @State private var refreshTimer: Timer?
    @State private var refreshTask: Task<Void, Never>?

    private var activeLiveCount: Int {
        liveSessions.filter { $0.activityLevel == "active" }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            liveSection
            statsSection
            healthSummary
            Divider()
            timelineSection
            usageSection
            footerSection
        }
        .padding(16)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover_container")
        .task {
            await loadData()
            // Single 10s cadence refreshes both the recent timeline and the
            // live count while the popover stays open. Track the inner Task so
            // it can't outlive the view / pile up.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                refreshTask?.cancel()
                refreshTask = Task { @MainActor in await loadData() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate(); refreshTimer = nil
            refreshTask?.cancel(); refreshTask = nil
        }
    }

    // MARK: - Live

    @ViewBuilder
    private var liveSection: some View {
        if !liveSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Live",
                    badge: String.localizedStringWithFormat(
                        String(localized: "%lld active"),
                        activeLiveCount
                    )
                )
                ForEach(liveSessions) { session in
                    LiveSessionCard(session: session, onOpen: { openLive(session) })
                }
            }
            .accessibilityIdentifier("popover_liveSection")
        }
    }

    // MARK: - Usage

    @ViewBuilder
    private var usageSection: some View {
        if serviceStatusStore.usageData.isEmpty {
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Text("No usage data — set token limits in Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("popover_usageEmpty")
        } else {
            PopoverUsageSection(usageData: serviceStatusStore.usageData)
                .padding(.horizontal, 12)
        }
    }

    private func openLive(_ session: EngramServiceLiveSessionInfo) {
        guard let id = session.sessionId else { return }
        let db = self.db
        Task {
            let resolved = await Task.detached { () -> Session? in
                try? db.getSession(id: id)
            }.value
            guard let resolved else { return }
            NotificationCenter.default.post(name: .openWindow, object: SessionBox(resolved))
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Engram").font(.headline)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                statusDot(
                    color: serviceStatusStore.endpointPort != nil ? .green : .red,
                    label: serviceStatusStore.endpointPort.map { "Web :\($0)" } ?? "Web"
                )
                .accessibilityIdentifier("popover_status_web")
                statusDot(
                    color: serviceStatusStore.isRunning ? .green : .red,
                    label: "Service"
                )
                .accessibilityIdentifier("popover_status_service")
            }
            .font(.caption2)
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                statRow("Today", "\(serviceStatusStore.todayParentSessions)")
                statRow("Sources", "\(sourceCount)")
            }
            GridRow {
                statRow("Projects", "\(projectCount)")
                statRow("DB Size", formattedSize(dbSize))
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color(.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover_statsGrid")
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    // MARK: - Health Summary

    private var healthSummary: some View {
        HStack(spacing: 4) {
            Text("\(activeSourceCount)/\(totalSourceCount) sources active")
                .font(.caption2)
                .foregroundStyle(activeSourceCount == totalSourceCount && totalSourceCount > 0 ? .green : .secondary)
            Text("·")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("last \(lastIndexedAgo)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .onTapGesture {
            if let url = serviceHealthURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var serviceHealthURL: URL? {
        guard let port = serviceStatusStore.endpointPort else { return nil }
        let host = serviceStatusStore.endpointHost ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/health")
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineSection: some View {
        if recentSessions.isEmpty {
            Text(serviceStatusStore.status == .starting ? "Indexing your sessions…" : "No sessions yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier("popover_recentActivity")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let groups = groupedByDate(recentSessions)
                    ForEach(groups) { group in
                        Text(group.key)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, group.id == groups.first?.id ? 0 : 6)
                        ForEach(group.sessions) { session in
                            timelineRow(session)
                        }
                    }
                }
            }
            .accessibilityIdentifier("popover_recentActivity")
        }
    }

    private func timelineRow(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SourceDisplay.color(for: session.source))
                .frame(width: 4, height: 4)
            Text(session.project ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(session.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(SourceDisplay.label(for: session.source))
                .font(.caption2)
                .foregroundStyle(SourceDisplay.color(for: session.source))
            Text(relativeTime(session.startTime))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(hoveredSessionId == session.id ? Color(.controlBackgroundColor).opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .help("Open session")
        .onHover { hovering in
            hoveredSessionId = hovering ? session.id : (hoveredSessionId == session.id ? nil : hoveredSessionId)
        }
        // Single click matches the chevron/hover/.help affordances (and
        // LiveSessionCard); double click still works for muscle memory.
        .onTapGesture {
            NotificationCenter.default.post(name: .openWindow, object: SessionBox(session))
        }
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .openWindow, object: SessionBox(session))
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Spacer()
            Button {
                NotificationCenter.default.post(name: .openWindow, object: nil)
            } label: {
                Text("Open Window \(Image(systemName: "arrow.up.right"))")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            Spacer()
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        let db = self.db
        // All DB work (including sourceStats + the stats-derived health summary)
        // runs in the detached block so nothing blocks the main thread on return.
        let result: (Int, Int, [Session], Int64, Int, Int, String) = await Task.detached {
            func logged<T>(_ label: String, fallback: T, _ body: () throws -> T) -> T {
                do {
                    return try body()
                } catch {
                    EngramLogger.error("PopoverView \(label) load failed", module: .ui, error: error)
                    return fallback
                }
            }

            let counts: Int = logged("source count", fallback: 0) {
                try db.readInBackground { d in
                    try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT source) FROM sessions WHERE hidden_at IS NULL") ?? 0
                }
            }
            let projectCount: Int = logged("project count", fallback: 0) {
                try db.readInBackground { d in
                    try Int.fetchOne(d, sql: "SELECT COUNT(DISTINCT project) FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL") ?? 0
                }
            }
            // Build tier-based filter from settings
            let noiseFilter = PopoverView.readNoiseFilter()
            var noiseConditions = ["hidden_at IS NULL"]
            switch noiseFilter {
            case "all":
                break  // no tier filter
            case "hide-noise":
                noiseConditions.append("(tier IS NULL OR tier NOT IN ('skip', 'lite'))")
            case "hide-skip":
                noiseConditions.append("(tier IS NULL OR tier != 'skip')")
            default:  // "human-driven" (default): hide skip + only human-driven sessions
                noiseConditions.append("(tier IS NULL OR tier != 'skip')")
                noiseConditions.append("(\(HumanDrivenFilter.sqlPredicate))")
            }
            let whereClause = noiseConditions.joined(separator: " AND ")

            let sessions: [Session] = logged("recent sessions", fallback: []) {
                try db.readInBackground { d in
                    try Session.fetchAll(d, sql: """
                        SELECT * FROM sessions
                        WHERE \(whereClause)
                        ORDER BY start_time DESC LIMIT 30
                    """)
                }
            }
            let size: Int64 = logged("database size", fallback: 0) {
                let size = try FileManager.default.attributesOfItem(atPath: db.path)[.size]
                if let size = size as? Int64 { return size }
                if let size = size as? Int { return Int64(size) }
                if let size = size as? NSNumber { return size.int64Value }
                return 0
            }

            // Health summary (off main thread)
            let stats = logged("source stats", fallback: []) {
                try db.sourceStats()
            }
            let now = Date()
            let oneDaySec: TimeInterval = 86400
            let active = stats.filter { s in
                guard !s.latestIndexed.isEmpty, let d = EngramTimestampParser.date(from: s.latestIndexed) else { return false }
                return now.timeIntervalSince(d) < oneDaySec
            }.count
            let latest = stats.compactMap { s -> Date? in
                s.latestIndexed.isEmpty ? nil : EngramTimestampParser.date(from: s.latestIndexed)
            }.max()
            let agoLabel: String
            if let latest {
                let interval = now.timeIntervalSince(latest)
                if interval < 60 { agoLabel = "now" }
                else if interval < 3600 { agoLabel = "\(Int(interval / 60))m" }
                else if interval < 86400 { agoLabel = "\(Int(interval / 3600))h" }
                else { agoLabel = "\(Int(interval / 86400))d" }
            } else {
                agoLabel = "—"
            }
            return (counts, projectCount, sessions, size, active, stats.count, agoLabel)
        }.value
        sourceCount = result.0
        projectCount = result.1
        dbSize = result.3
        recentSessions = Array(result.2.prefix(15))
        activeSourceCount = result.4
        totalSourceCount = result.5
        lastIndexedAgo = result.6

        // Live section — silent-fail like the menu-bar badge so a transient
        // service hiccup hides the section instead of surfacing an error.
        liveSessions = (try? await serviceClient.liveSessions().sessions) ?? []
    }

    // MARK: - Helpers

    private func statusDot(color: Color, label: String, hollow: Bool = false) -> some View {
        HStack(spacing: 3) {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1).frame(width: 5, height: 5)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(label)
        }
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private struct DateGroup: Identifiable {
        let key: String
        let sessions: [Session]
        var id: String { key }
    }

    private func groupedByDate(_ sessions: [Session]) -> [DateGroup] {
        let cal = Calendar.current
        var groups: [(String, [Session])] = []
        var currentKey = ""
        var currentGroup: [Session] = []
        for s in sessions {
            let dateStr = String(s.startTime.prefix(10))
            let key: String
            if let date = EngramTimestampParser.date(from: s.startTime) ?? Self.dateOnlyFormatter.date(from: dateStr) {
                if cal.isDateInToday(date) { key = "TODAY" }
                else if cal.isDateInYesterday(date) { key = "YESTERDAY" }
                else { key = dateStr }
            } else { key = dateStr }
            if key != currentKey {
                if !currentGroup.isEmpty { groups.append((currentKey, currentGroup)) }
                currentKey = key; currentGroup = [s]
            } else { currentGroup.append(s) }
        }
        if !currentGroup.isEmpty { groups.append((currentKey, currentGroup)) }
        return groups.map { DateGroup(key: $0.0, sessions: $0.1) }
    }

    // Read noise filter setting from ~/.engram/settings.json
    nonisolated private static func readNoiseFilter() -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".engram/settings.json")
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "human-driven" // default
        }
        return (settings["noiseFilter"] as? String) ?? "human-driven"
    }

    private func relativeTime(_ ts: String) -> String {
        RelativeTimeText.format(ts, style: .compact)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
