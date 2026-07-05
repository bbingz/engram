// macos/Engram/Views/PopoverView.swift
import SwiftUI

enum PopoverRefreshPolicy {
    static let liveSessionCacheTTL: TimeInterval = 30
    static let refreshInterval: TimeInterval = liveSessionCacheTTL
}

struct PopoverDataSnapshot {
    let recentSessions: [Session]

    static let empty = PopoverDataSnapshot(recentSessions: [])
}

struct PopoverView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    @Environment(EngramServiceClient.self) var serviceClient

    @State private var data = PopoverDataSnapshot.empty
    @State private var liveSessions: [EngramServiceLiveSessionInfo] = []
    @State private var refreshTimer: Timer?
    @State private var refreshTask: Task<Void, Never>?

    // The Live section is a glance surface: cap how many cards can render so it
    // can't dominate the popover, spilling the rest into one overflow row.
    private static let liveSectionLimit = 5

    private var activeLiveCount: Int {
        liveSessions.filter { $0.activityLevel == "active" }.count
    }

    // Only genuinely-live sessions belong under a "Live" header. The service
    // also returns up to 24h of "recent" churn (kept for SourcePulseView); drop
    // it here, ordering active before idle then most-recent first.
    private var visibleLiveSessions: [EngramServiceLiveSessionInfo] {
        liveSessions
            .filter { $0.activityLevel == "active" || $0.activityLevel == "idle" }
            .sorted { lhs, rhs in
                if lhs.activityLevel != rhs.activityLevel {
                    return lhs.activityLevel == "active"
                }
                return lhs.lastModifiedAt > rhs.lastModifiedAt
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            liveSection
            Divider()
            timelineSection
            usageSection
            // Spacer fills the pinned min-box so the footer anchors to the
            // bottom instead of floating up while short content loads.
            Spacer(minLength: 0)
            footerSection
        }
        .padding(16)
        // Open at a stable height (420 matches the initial popover.contentSize
        // in MenuBarController.swift:57) so sections swap in place instead of
        // the window resizing as the timeline/live data lands. minWidth==maxWidth
        // pins the width while the flexible frame stretches the VStack to the
        // min-box so the trailing Spacer can anchor the footer.
        .frame(minWidth: 400, maxWidth: 400, minHeight: 420, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("popover_container")
        .task {
            await loadData()
            // Align refresh with the service's live-session cache TTL. Track
            // the inner Task so it can't outlive the view / pile up.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: PopoverRefreshPolicy.refreshInterval, repeats: true) { _ in
                refreshTask?.cancel()
                refreshTask = Task { @MainActor in await loadData() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate(); refreshTimer = nil
            refreshTask?.cancel(); refreshTask = nil
        }
    }

    // MARK: - Header

    private var headerSection: some View {
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
    }

    // MARK: - Live

    @ViewBuilder
    private var liveSection: some View {
        let visible = visibleLiveSessions
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Live",
                    badge: String.localizedStringWithFormat(
                        String(localized: "%lld active"),
                        activeLiveCount
                    )
                )
                ForEach(visible.prefix(Self.liveSectionLimit)) { session in
                    LiveSessionCard(session: session, onOpen: { openLive(session) })
                }
                if visible.count > Self.liveSectionLimit {
                    Button {
                        NotificationCenter.default.post(name: .openWindow, object: nil)
                    } label: {
                        Text("+\(visible.count - Self.liveSectionLimit) more")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("popover_liveOverflow")
                }
            }
            .accessibilityIdentifier("popover_liveSection")
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineSection: some View {
        if data.recentSessions.isEmpty {
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
                    let groups = groupedByDate(data.recentSessions)
                    ForEach(groups) { group in
                        Text(group.key)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, group.id == groups.first?.id ? 0 : 6)
                        ForEach(group.sessions) { session in
                            PopoverTimelineRow(session: session)
                        }
                    }
                }
            }
            // Bound the timeline so the popover stays a fixed-size glance and
            // scrolls internally instead of growing to fit every recent session.
            .frame(maxHeight: 240)
            .accessibilityIdentifier("popover_recentActivity")
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

    // MARK: - Data Loading

    private func loadData() async {
        let db = self.db
        let serviceClient = self.serviceClient
        async let liveSessionsResult: [EngramServiceLiveSessionInfo] = Self.loadLiveSessions(serviceClient)

        // Only the recent-session timeline needs DB work now; run it detached so
        // nothing blocks the main thread, and assign it before awaiting the live
        // IPC so the timeline paints without waiting on the service round-trip.
        let result: PopoverDataSnapshot = await Task.detached {
            // The menu-bar popover is a glance surface: always apply the
            // human-driven filter (per HumanDrivenFilter's contract) regardless
            // of the app's browse noise setting, so freshly-indexed untiered
            // agent/probe sessions can't flood the list with "Untitled" rows.
            let whereClause = """
                hidden_at IS NULL \
                AND (tier IS NULL OR tier != 'skip') \
                AND (\(HumanDrivenFilter.sqlPredicate))
                """

            let sessions: [Session]
            do {
                sessions = try db.readInBackground { d in
                    try Session.fetchAll(d, sql: """
                        SELECT * FROM sessions
                        WHERE \(whereClause)
                        ORDER BY start_time DESC LIMIT 30
                    """)
                }
            } catch {
                EngramLogger.error("PopoverView recent sessions load failed", module: .ui, error: error)
                sessions = []
            }
            return PopoverDataSnapshot(recentSessions: Array(sessions.prefix(12)))
        }.value
        data = result

        // Live section — silent-fail like the menu-bar badge so a transient
        // service hiccup hides the section instead of surfacing an error.
        liveSessions = await liveSessionsResult
    }

    // MARK: - Helpers

    private static func loadLiveSessions(_ serviceClient: EngramServiceClient) async -> [EngramServiceLiveSessionInfo] {
        (try? await serviceClient.liveSessions().sessions) ?? []
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
}

private struct PopoverTimelineRow: View {
    let session: Session
    @State private var isHovered = false

    var body: some View {
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
            Text(RelativeTimeText.format(session.startTime, style: .compact))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isHovered ? Color(.controlBackgroundColor).opacity(0.5) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .help("Open session")
        .onHover { hovering in
            isHovered = hovering
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
}
