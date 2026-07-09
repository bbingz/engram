// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

/// How many rows the Continue / Follow-ups panels actually render. The badge
/// must report the same number so it never advertises rows that aren't shown.
/// Not `private` so the panel-badge contract is unit-testable via @testable.
let todayPanelRowLimit = 5

struct HomeView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore
    // Shared global escape hatch (see SessionsPageView). When off (default), the
    // Continue list shows only human-driven sessions.
    @AppStorage("sessions.showAll") private var showAllSessions = false

    // Debounce/coalesce index-tick reloads vs. immediate filter-change reloads (#3).
    @State private var lastFilterKey: [AnyHashable]? = nil
    @State private var kpi: DatabaseManager.KPIStats?
    @State private var recentSessions: [Session] = []
    @State private var followUpSessions: [Session] = []
    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var projectWarnings: [String: String] = [:]
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var handledFollowUps = TodayHandledFollowUps()
    @State private var isLoading = true
    @State private var alertMessage: String? = nil
    @State private var resumeSession: Session?
    @State private var copyingSessionId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                kpiSection
                if let alertMessage {
                    AlertBanner(message: alertMessage)
                }
                workbenchGrid
            }
            .padding(24)
        }
        .modernScrollIndicators()
        .accessibilityIdentifier("home_container")
        .task(id: [AnyHashable(serviceStatusStore.totalSessions), AnyHashable(showAllSessions)]) {
            let filterKey: [AnyHashable] = [AnyHashable(showAllSessions)]
            let plan = BrowseReloadCoalescer.plan(filterKey: filterKey, lastFilterKey: lastFilterKey)
            if plan.debounce {
                try? await Task.sleep(for: BrowseReloadCoalescer.debounceInterval)
                if Task.isCancelled { return }
            }
            lastFilterKey = filterKey
            await loadData()
        }
        .sheet(item: $resumeSession) { session in
            ResumeDialog(session: session)
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        let freshness = serviceStatusStore.dataFreshness(now: Date())
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Theme.primaryText)
                Text("Continue work, close follow-ups, and check service readiness.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            ServiceStatusPill(
                isRunning: serviceStatusStore.isRunning,
                label: serviceStatusStore.displayString,
                detail: serviceStatusDetail(freshness)
            )
        }
        .accessibilityIdentifier("home_todayHeader")
    }

    @ViewBuilder
    private var kpiSection: some View {
        if let kpi {
            let freshness = serviceStatusStore.dataFreshness(now: Date())
            HStack(spacing: 12) {
                KPICard(
                    value: serviceCountValue(serviceStatusStore.todayParentSessions, freshness: freshness),
                    label: serviceTodayLabel(freshness)
                )
                    .accessibilityIdentifier("home_kpiCard_today")
                Button { navigate(to: .sessions) } label: {
                    KPICard(value: formatNumber(kpi.sessions), label: "Sessions")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home_kpiCard_sessions")
                Button { navigate(to: .projects) } label: {
                    KPICard(value: "\(kpi.projects)", label: "Projects")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home_kpiCard_projects")
                Button { navigate(to: .settings) } label: {
                    KPICard(value: serviceStateValue(freshness), label: "Service")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home_kpiCard_service")
            }
            .accessibilityIdentifier("home_kpiCards")
        } else {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            }
        }
    }

    private var workbenchGrid: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                continueSection
                followUpsSection
            }
            HStack(alignment: .top, spacing: 16) {
                changedReposSection
                serviceStateSection
            }
        }
    }

    private var indexingState: some View {
        EmptyState(
            icon: "arrow.triangle.2.circlepath",
            title: "Indexing your sessions…",
            message: "This panel fills in as your sessions are indexed"
        )
        .frame(height: 120)
    }

    private var continueSection: some View {
        WorkbenchPanel(
            icon: "play.circle",
            title: "Continue",
            trailingAction: recentSessions.count > todayPanelRowLimit
                ? (label: String(localized: "See all"), action: { navigate(to: .sessions) })
                : nil,
            badge: recentSessions.isEmpty ? nil : "\(min(recentSessions.count, todayPanelRowLimit))"
        ) {
            if recentSessions.isEmpty && isIndexing {
                indexingState
            } else if recentSessions.isEmpty && !isLoading {
                EmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No recent work",
                    message: "Recent resumable sessions will appear here"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recentSessions.prefix(todayPanelRowLimit).enumerated()), id: \.element.id) { index, session in
                        TodaySessionRow(
                            session: session,
                            detail: session.project.map(projectLabel) ?? compactPath(session.cwd),
                            countBadge: childBadge(for: session),
                            isCopying: copyingSessionId == session.id,
                            onOpen: { open(session) },
                            onCopyCommand: { copyResumeCommand(session) },
                            onResume: { resumeSession = session }
                        )
                        .accessibilityIdentifier("home_recentSession_\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("home_recentSessions")
    }

    private var followUpsSection: some View {
        WorkbenchPanel(
            icon: "checklist",
            title: "Follow-ups",
            trailingAction: followUpSessions.count > todayPanelRowLimit
                ? (label: String(localized: "See all"), action: { navigate(to: .sessions) })
                : nil,
            badge: followUpSessions.isEmpty ? nil : "\(min(followUpSessions.count, todayPanelRowLimit))"
        ) {
            if followUpSessions.isEmpty && isIndexing {
                indexingState
            } else if followUpSessions.isEmpty && !isLoading {
                EmptyState(
                    icon: "checklist",
                    title: "No follow-ups found",
                    message: "Deferred, follow-up, TODO, and review markers land here"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(followUpSessions.prefix(todayPanelRowLimit).enumerated()), id: \.element.id) { index, session in
                        TodaySessionRow(
                            session: session,
                            detail: String(localized: "Needs review") + " · \(session.displayUpdatedDate)",
                            countBadge: nil,
                            isCopying: copyingSessionId == session.id,
                            onOpen: { open(session) },
                            onCopyCommand: { copyResumeCommand(session) },
                            onResume: { resumeSession = session },
                            onMarkHandled: { markFollowUpHandled(session) }
                        )
                        .accessibilityIdentifier("home_followUpSession_\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("home_followUps")
    }

    private var changedReposSection: some View {
        WorkbenchPanel(
            icon: "arrow.triangle.branch",
            title: "Changed Repos",
            trailingAction: projectGroups.count > 5
                ? (label: String(localized: "See all"), action: { navigate(to: .projects) })
                : nil,
            badge: projectGroups.isEmpty ? nil : "\(projectGroups.count)"
        ) {
            if projectGroups.isEmpty && isIndexing {
                indexingState
            } else if projectGroups.isEmpty && !isLoading {
                EmptyState(
                    icon: "folder",
                    title: "No project activity",
                    message: "Recently touched projects will appear here"
                )
                .frame(height: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(projectGroups.prefix(5).enumerated()), id: \.element.id) { index, group in
                        ChangedRepoRow(
                            group: group,
                            warning: projectWarnings[group.id],
                            onOpen: {
                                if let session = group.sessions.first {
                                    open(session)
                                }
                            },
                            onOpenWarning: { navigate(to: .projects) }
                        )
                        .accessibilityIdentifier("home_changedRepo_\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("home_changedRepos")
    }

    @ViewBuilder
    private var serviceStateSection: some View {
        let freshness = serviceStatusStore.dataFreshness(now: Date())
        WorkbenchPanel(icon: "checkmark.shield", title: "Service State") {
            VStack(spacing: 10) {
                ServiceStateRow(
                    icon: serviceStatusStore.isRunning ? "checkmark.circle.fill" : "xmark.octagon.fill",
                    title: "Indexer",
                    value: serviceStatusText(freshness),
                    tint: serviceStatusStore.isRunning ? Theme.green : Theme.red
                )
                ServiceStateRow(
                    icon: "calendar",
                    title: "Today indexed",
                    value: serviceParentSessionsText(freshness),
                    tint: Theme.accent
                )
            }
        }
        .accessibilityIdentifier("home_serviceState")
    }

    private func serviceStateValue(_ freshness: ServiceDataFreshness) -> String {
        switch freshness {
        case .live:
            return String(localized: "Running")
        case .stale:
            return String(localized: "Stale")
        case .expired:
            return String(localized: "Check")
        }
    }

    private func serviceCountValue(_ count: Int, freshness: ServiceDataFreshness) -> String {
        switch freshness {
        case .expired:
            return "—"
        case .live, .stale:
            return "\(count)"
        }
    }

    private func serviceTodayLabel(_ freshness: ServiceDataFreshness) -> String {
        switch freshness {
        case .stale(let asOf):
            return "Today \(Self.asOfText(asOf))"
        case .live, .expired:
            return "Today"
        }
    }

    private func serviceStatusDetail(_ freshness: ServiceDataFreshness) -> String? {
        switch freshness {
        case .stale(let asOf):
            return Self.asOfText(asOf)
        case .live, .expired:
            return nil
        }
    }

    private func serviceStatusText(_ freshness: ServiceDataFreshness) -> String {
        switch freshness {
        case .stale(let asOf):
            return "\(serviceStatusStore.displayString) \(Self.asOfText(asOf))"
        case .live, .expired:
            return serviceStatusStore.displayString
        }
    }

    private func serviceParentSessionsText(_ freshness: ServiceDataFreshness) -> String {
        switch freshness {
        case .expired:
            return "—"
        case .live:
            return String.localizedStringWithFormat(
                String(localized: "%lld parent sessions"),
                serviceStatusStore.todayParentSessions
            )
        case .stale(let asOf):
            let parentSessions = String.localizedStringWithFormat(
                String(localized: "%lld parent sessions"),
                serviceStatusStore.todayParentSessions
            )
            return "\(parentSessions) \(Self.asOfText(asOf))"
        }
    }

    private static func asOfText(_ date: Date) -> String {
        "as of \(serviceFreshnessTimeFormatter.string(from: date))"
    }

    private static let serviceFreshnessTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let db = self.db
        let serviceClient = self.serviceClient
        let handledIds = handledFollowUps.handledIds
        let humanDriven = !showAllSessions
        do {
            let data = try await Task.detached {
                let kpi = try db.kpiStats()
                let rawRecent = try db.recentSessions(limit: 12, humanDriven: humanDriven)
                let followUps = try loadTodayFollowUps(from: db, limit: 8, excluding: handledIds)
                let projects = try db.listSessionsByProject(limit: 5)
                let repos = try db.listGitRepos()
                let countIds = Array(Set((rawRecent + followUps).map(\.id)))
                let confirmed = try db.childCount(parentIds: countIds)
                let suggested = try db.suggestedChildCount(parentIds: countIds)
                let recent = TodayWorkbenchRanking.continueSessions(
                    from: rawRecent,
                    confirmedCounts: confirmed,
                    suggestedCounts: suggested,
                    limit: 8
                )
                return (kpi, recent, followUps, projects, repos, confirmed, suggested)
            }.value
            let migrations = (try? await serviceClient.projectMigrations(
                EngramServiceProjectMigrationsRequest(state: "committed", limit: 25)
            ).migrations) ?? []
            kpi = data.0
            recentSessions = data.1
            followUpSessions = data.2
            projectGroups = data.3
            projectWarnings = Dictionary(uniqueKeysWithValues: data.3.compactMap { group in
                guard let warning = TodayProjectWarning.warning(
                    for: group,
                    repos: data.4,
                    migrations: migrations
                ) else {
                    return nil
                }
                return (group.id, warning)
            })
            confirmedCounts = data.5
            suggestedCounts = data.6
            alertMessage = nil
        } catch {
            EngramLogger.error("HomeView load failed", module: .ui, error: error)
            alertMessage = String.localizedStringWithFormat(
                String(localized: "Failed to load Today: %@"),
                error.localizedDescription
            )
        }
    }

    private func open(_ session: Session) {
        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
    }

    private func navigate(to screen: Screen) {
        NotificationCenter.default.post(name: .navigateToScreen, object: screen.rawValue)
    }

    private var isIndexing: Bool {
        serviceStatusStore.status == .starting
    }

    private func copyResumeCommand(_ session: Session) {
        copyingSessionId = session.id
        Task {
            defer { copyingSessionId = nil }
            do {
                let response = try await serviceClient.resumeCommand(sessionId: session.id)
                let item = try TodayResumeCommand.copyableClipboardItem(from: response)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
                alertMessage = item.message
            } catch {
                EngramLogger.error("HomeView copy resume command failed", module: .ui, error: error)
                alertMessage = String(localized: "Failed to copy resume command")
            }
        }
    }

    private func markFollowUpHandled(_ session: Session) {
        handledFollowUps.markHandled(session.id)
        followUpSessions.removeAll { $0.id == session.id }
    }

    private func childBadge(for session: Session) -> String? {
        if let confirmed = confirmedCounts[session.id], confirmed > 0 {
            return String.localizedStringWithFormat(String(localized: "%lld agents"), confirmed)
        }
        if let suggested = suggestedCounts[session.id], suggested > 0 {
            return String.localizedStringWithFormat(String(localized: "%lld suggested"), suggested)
        }
        return nil
    }

    private func projectLabel(_ project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    private func compactPath(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

private struct WorkbenchPanel<Content: View>: View {
    let icon: String
    let title: String
    var trailingAction: (label: String, action: () -> Void)? = nil
    var badge: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: icon, title: title, badge: badge, trailingAction: trailingAction)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct TodaySessionRow: View {
    let session: Session
    let detail: String
    let countBadge: String?
    let isCopying: Bool
    let onOpen: () -> Void
    let onCopyCommand: () -> Void
    let onResume: () -> Void
    var onMarkHandled: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            SourcePill(source: session.source)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(Theme.primaryText)
                HStack(spacing: 6) {
                    Text(detail)
                    Text(relativeTime(session.startTime))
                    if let countBadge {
                        Text(countBadge)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceHighlight)
                            .clipShape(Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onOpen) {
                Image(systemName: "text.page")
            }
            .buttonStyle(.borderless)
            .help("Open transcript")
            Button(action: onCopyCommand) {
                Image(systemName: isCopying ? "clock" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy resume command")
            .disabled(isCopying)
            Button(action: onResume) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Resume session")
            if let onMarkHandled {
                Button(action: onMarkHandled) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Mark follow-up handled")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeTime(_ iso: String) -> String {
        TodayRelativeTime.format(iso)
    }
}

private struct ChangedRepoRow: View {
    let group: DatabaseManager.ProjectGroup
    let warning: String?
    let onOpen: () -> Void
    let onOpenWarning: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(projectLabel(group.project))
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(Theme.primaryText)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%lld recent transcripts"),
                            group.sessionCount
                        )
                        + " · \(String(group.lastActive.prefix(10)))"
                    )
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                if let warning {
                    Button(action: onOpenWarning) {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(Theme.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Open Projects")
                    .accessibilityIdentifier("home_changedRepoWarning")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func projectLabel(_ project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }
}

private func loadTodayFollowUps(
    from db: DatabaseManager,
    limit: Int,
    excluding handledIds: Set<String>,
    now: Date = Date()
) throws -> [Session] {
    var seen = Set<String>()
    var matches: [Session] = []
    let since = ISO8601DateFormatter().string(from: now.addingTimeInterval(-TodayFollowUps.recencyWindow))
    for query in TodayFollowUps.queries {
        let results = try db.searchWithSnippets(query: query, limit: limit, since: since)
        for result in results
        where TodayFollowUps.isEligible(result.session, handledIds: handledIds, now: now)
            && seen.insert(result.session.id).inserted {
            matches.append(result.session)
            if matches.count >= limit {
                return matches
            }
        }
    }
    return matches
}

/// Scoping rules for the Today "Follow-ups" panel. `searchWithSnippets` is
/// history-wide and owned by another module, so the view narrows its keyword
/// set and post-filters hits to a recent, top-level, unhandled window here.
enum TodayFollowUps {
    /// Recent window for follow-ups, in seconds (72h).
    static let recencyWindow: TimeInterval = 72 * 3600

    /// Follow-up-specific markers only — broad terms like "review"/"todo" would
    /// match almost any transcript and surfaced unrelated sessions.
    static let queries = ["follow-up", "followup", "deferred", "remaining", "延后", "跟进"]

    static func isEligible(_ session: Session, handledIds: Set<String>, now: Date) -> Bool {
        if handledIds.contains(session.id) { return false }
        // Top-level only: never surface confirmed or suggested children.
        if session.parentSessionId != nil || session.suggestedParentId != nil { return false }
        guard let started = EngramTimestampParser.date(from: session.startTime) else {
            return false
        }
        // Recent window only (no lower bound, so minor clock skew on a
        // just-started session can't drop it).
        return now.timeIntervalSince(started) <= recencyWindow
    }
}

private struct ServiceStateRow: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(LocalizedStringKey(title))
                .font(.callout)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ServiceStatusPill: View {
    let isRunning: Bool
    let label: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Theme.green : Theme.orange)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryText)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
