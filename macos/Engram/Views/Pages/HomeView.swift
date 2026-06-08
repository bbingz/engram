// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

/// How many rows the Continue / Follow-ups panels actually render. The badge
/// must report the same number so it never advertises rows that aren't shown.
/// Not `private` so the panel-badge contract is unit-testable via @testable.
let todayPanelRowLimit = 5

private let todayISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Fallback ISO-8601 parser for whole-second timestamps (no fractional digits).
private let todayISOFormatterPlain = ISO8601DateFormatter()

struct HomeView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

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
        .task { await loadData() }
        .sheet(item: $resumeSession) { session in
            ResumeDialog(session: session)
        }
    }

    private var headerSection: some View {
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
                label: serviceStatusStore.displayString
            )
        }
        .accessibilityIdentifier("home_todayHeader")
    }

    @ViewBuilder
    private var kpiSection: some View {
        if let kpi {
            HStack(spacing: 12) {
                KPICard(value: "\(serviceStatusStore.todayParentSessions)", label: "Today")
                    .accessibilityIdentifier("home_kpiCard_today")
                KPICard(value: formatNumber(kpi.sessions), label: "Sessions")
                    .accessibilityIdentifier("home_kpiCard_sessions")
                KPICard(value: "\(kpi.projects)", label: "Projects")
                    .accessibilityIdentifier("home_kpiCard_projects")
                KPICard(value: serviceStateValue, label: "Service")
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

    private var continueSection: some View {
        WorkbenchPanel(
            icon: "play.circle",
            title: "Continue",
            badge: recentSessions.isEmpty ? nil : "\(min(recentSessions.count, todayPanelRowLimit))"
        ) {
            if recentSessions.isEmpty && !isLoading {
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
            badge: followUpSessions.isEmpty ? nil : "\(min(followUpSessions.count, todayPanelRowLimit))"
        ) {
            if followUpSessions.isEmpty && !isLoading {
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
            badge: projectGroups.isEmpty ? nil : "\(projectGroups.count)"
        ) {
            if projectGroups.isEmpty && !isLoading {
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
                            }
                        )
                        .accessibilityIdentifier("home_changedRepo_\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("home_changedRepos")
    }

    private var serviceStateSection: some View {
        WorkbenchPanel(icon: "checkmark.shield", title: "Service State") {
            VStack(spacing: 10) {
                ServiceStateRow(
                    icon: serviceStatusStore.isRunning ? "checkmark.circle.fill" : "xmark.octagon.fill",
                    title: "Indexer",
                    value: serviceStatusStore.displayString,
                    tint: serviceStatusStore.isRunning ? Theme.green : Theme.red
                )
                ServiceStateRow(
                    icon: "calendar",
                    title: "Today indexed",
                    value: String.localizedStringWithFormat(
                        String(localized: "%lld parent sessions"),
                        serviceStatusStore.todayParentSessions
                    ),
                    tint: Theme.accent
                )
                ServiceStateRow(
                    icon: "network",
                    title: "Web UI",
                    value: webEndpointLabel,
                    tint: serviceStatusStore.endpointPort == nil ? Theme.orange : Theme.green
                )
                ServiceStateRow(
                    icon: "brain",
                    title: "Embeddings",
                    value: serviceStatusStore.embeddingStatus ?? String(localized: "Check Advanced diagnostics"),
                    tint: serviceStatusStore.embeddingStatus == "unavailable" ? Theme.orange : Theme.secondaryText
                )
            }
        }
        .accessibilityIdentifier("home_serviceState")
    }

    private var serviceStateValue: String {
        serviceStatusStore.isRunning ? String(localized: "Running") : String(localized: "Check")
    }

    private var webEndpointLabel: String {
        guard let port = serviceStatusStore.endpointPort else {
            return String(localized: "Unavailable")
        }
        return "\(serviceStatusStore.endpointHost ?? "127.0.0.1"):\(port)"
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let db = self.db
        let serviceClient = self.serviceClient
        let handledIds = handledFollowUps.handledIds
        do {
            let data = try await Task.detached {
                let kpi = try db.kpiStats()
                let rawRecent = try db.recentSessions(limit: 12)
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
    var badge: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(icon: icon, title: title, badge: badge)
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

/// Renders an ISO-8601 start_time as a coarse "Xm ago" label. Parses both
/// fractional-second and whole-second timestamps — adapters that emit
/// `2026-06-01T10:00:00Z` (no fractional digits) used to render blank under a
/// fractional-only formatter.
enum TodayRelativeTime {
    static func format(_ iso: String, now: Date = Date()) -> String {
        guard let date = todayISOFormatter.date(from: iso)
            ?? todayISOFormatterPlain.date(from: iso) else {
            return ""
        }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

private struct ChangedRepoRow: View {
    let group: DatabaseManager.ProjectGroup
    let warning: String?
    let onOpen: () -> Void

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
                    HStack(spacing: 6) {
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "%lld recent transcripts"),
                                group.sessionCount
                            )
                            + " · \(String(group.lastActive.prefix(10)))"
                        )
                        if let warning {
                            Text(warning)
                                .foregroundStyle(Theme.orange)
                        }
                    }
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
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
    for query in TodayFollowUps.queries {
        // searchWithSnippets is unscoped (history-wide, no date filter), so
        // post-filter every hit to a recent, top-level, unhandled session before
        // surfacing it as today's follow-up.
        let results = try db.searchWithSnippets(query: query, limit: limit)
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
        guard let started = todayISOFormatter.date(from: session.startTime)
            ?? todayISOFormatterPlain.date(from: session.startTime) else {
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

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Theme.green : Theme.orange)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
