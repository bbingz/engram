// macos/Engram/Views/Workspace/WorkGraphView.swift
import SwiftUI

struct WorkGraphView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var repos: [GitRepo] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    private var activeCount: Int { repos.filter { $0.isActive }.count }
    private var idleCount: Int { repos.filter { isIdle($0) }.count }
    private var dormantCount: Int { repos.filter { isDormant($0) }.count }
    private var totalCommitSessions: Int { repos.reduce(0) { $0 + $1.sessionCount } }
    private var maxSessions: Int { repos.map { $0.sessionCount }.max() ?? 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI cards
                HStack(spacing: 12) {
                    KPICard(value: "\(activeCount)", label: "Active (24h)")
                    KPICard(value: "\(idleCount)", label: "Idle (7d)")
                    KPICard(value: "\(dormantCount)", label: "Dormant")
                    KPICard(value: "\(totalCommitSessions)", label: "Sessions")
                }

                if let error {
                    AlertBanner(message: "Failed to load repos: \(error)")
                }

                if !repos.isEmpty {
                    SectionHeader(icon: "point.3.connected.trianglepath.dotted", title: "Repo Activity",
                                  onRefresh: { Task { await loadData() } })

                    LazyVStack(spacing: 6) {
                        ForEach(repos) { repo in
                            WorkGraphRow(repo: repo, maxSessions: maxSessions)
                        }
                    }
                }

                if repos.isEmpty && !isLoading {
                    EmptyState(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "No repo data",
                        message: "Work Graph builds as repos are discovered from session working directories."
                    )
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func isIdle(_ repo: GitRepo) -> Bool {
        guard !repo.isActive else { return false }
        guard let ts = repo.lastCommitAt,
              let date = ISO8601DateFormatter().date(from: ts) else { return false }
        return date.timeIntervalSinceNow > -7 * 86400
    }

    private func isDormant(_ repo: GitRepo) -> Bool {
        guard !repo.isActive, !isIdle(repo) else { return false }
        return true
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            repos = try db.listGitRepos()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - WorkGraphRow

private struct WorkGraphRow: View {
    let repo: GitRepo
    let maxSessions: Int

    private var barFraction: Double {
        guard maxSessions > 0 else { return 0 }
        return Double(repo.sessionCount) / Double(maxSessions)
    }

    private var statusColor: Color {
        if repo.isActive { return .green }
        guard let ts = repo.lastCommitAt,
              let date = ISO8601DateFormatter().date(from: ts) else { return .gray }
        if date.timeIntervalSinceNow > -7 * 86400 { return .yellow }
        return .gray
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.primaryText)

                    if let branch = repo.branch {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                // Horizontal bar representing session count
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.border)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent.opacity(0.7))
                            .frame(width: geo.size.width * barFraction, height: 6)
                    }
                }
                .frame(height: 6)
            }

            Spacer()

            Text("\(repo.sessionCount)")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 28, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
