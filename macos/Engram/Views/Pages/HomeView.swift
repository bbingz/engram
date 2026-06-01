// macos/Engram/Views/Pages/HomeView.swift
import SwiftUI

private let todayISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

struct HomeView: View {
    @Environment(DatabaseManager.self) var db
    @Environment(EngramServiceStatusStore.self) var serviceStatusStore

    @State private var kpi: DatabaseManager.KPIStats?
    @State private var recentSessions: [Session] = []
    @State private var followUpSessions: [Session] = []
    @State private var projectGroups: [DatabaseManager.ProjectGroup] = []
    @State private var confirmedCounts: [String: Int] = [:]
    @State private var suggestedCounts: [String: Int] = [:]
    @State private var isLoading = true
    @State private var alertMessage: String? = nil
    @State private var resumeSession: Session?

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
            badge: recentSessions.isEmpty ? nil : "\(recentSessions.count)"
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
                    ForEach(Array(recentSessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        TodaySessionRow(
                            session: session,
                            detail: session.project.map(projectLabel) ?? compactPath(session.cwd),
                            countBadge: childBadge(for: session),
                            onOpen: { open(session) },
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
            badge: followUpSessions.isEmpty ? nil : "\(followUpSessions.count)"
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
                    ForEach(Array(followUpSessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        TodaySessionRow(
                            session: session,
                            detail: "Needs review · \(session.displayUpdatedDate)",
                            countBadge: nil,
                            onOpen: { open(session) },
                            onResume: { resumeSession = session }
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
                    value: "\(serviceStatusStore.todayParentSessions) parent sessions",
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
                    value: serviceStatusStore.embeddingStatus ?? "Check Advanced diagnostics",
                    tint: serviceStatusStore.embeddingStatus == "unavailable" ? Theme.orange : Theme.secondaryText
                )
            }
        }
        .accessibilityIdentifier("home_serviceState")
    }

    private var serviceStateValue: String {
        serviceStatusStore.isRunning ? "Running" : "Check"
    }

    private var webEndpointLabel: String {
        guard let port = serviceStatusStore.endpointPort else {
            return "Unavailable"
        }
        return "\(serviceStatusStore.endpointHost ?? "127.0.0.1"):\(port)"
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        let db = self.db
        do {
            let data = try await Task.detached {
                let kpi = try db.kpiStats()
                let recent = try db.recentSessions(limit: 8)
                let followUps = try loadTodayFollowUps(from: db, limit: 8)
                let projects = try db.listSessionsByProject(limit: 5)
                let countIds = Array(Set((recent + followUps).map(\.id)))
                let confirmed = try db.childCount(parentIds: countIds)
                let suggested = try db.suggestedChildCount(parentIds: countIds)
                return (kpi, recent, followUps, projects, confirmed, suggested)
            }.value
            kpi = data.0
            recentSessions = data.1
            followUpSessions = data.2
            projectGroups = data.3
            confirmedCounts = data.4
            suggestedCounts = data.5
            alertMessage = nil
        } catch {
            EngramLogger.error("HomeView load failed", module: .ui, error: error)
            alertMessage = "Failed to load Today: \(error.localizedDescription)"
        }
    }

    private func open(_ session: Session) {
        NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
    }

    private func childBadge(for session: Session) -> String? {
        if let confirmed = confirmedCounts[session.id], confirmed > 0 {
            return "\(confirmed) agents"
        }
        if let suggested = suggestedCounts[session.id], suggested > 0 {
            return "\(suggested) suggested"
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
    let onOpen: () -> Void
    let onResume: () -> Void

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
            Button(action: onResume) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Resume session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = todayISOFormatter.date(from: iso) else {
            return ""
        }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

private struct ChangedRepoRow: View {
    let group: DatabaseManager.ProjectGroup
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
                    Text("\(group.sessionCount) recent transcripts · \(String(group.lastActive.prefix(10)))")
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

private func loadTodayFollowUps(from db: DatabaseManager, limit: Int) throws -> [Session] {
    let queries = ["follow-up", "followup", "deferred", "todo", "review", "remaining", "延后", "跟进"]
    var seen = Set<String>()
    var matches: [Session] = []
    for query in queries {
        let results = try db.searchWithSnippets(query: query, limit: limit)
        for result in results where seen.insert(result.session.id).inserted {
            matches.append(result.session)
            if matches.count >= limit {
                return matches
            }
        }
    }
    return matches
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
            Text(title)
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
