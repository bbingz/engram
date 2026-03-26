// macos/Engram/Views/Workspace/ReposView.swift
import SwiftUI

struct ReposView: View {
    @Environment(DatabaseManager.self) var db
    @State private var repos: [GitRepo] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var selectedRepo: GitRepo?
    @State private var sparklines: [String: [Int]] = [:]  // keyed by repo.path

    private var activeRepos: [GitRepo] { repos.filter { $0.isActive } }
    private var recentRepos: [GitRepo] { repos.filter { !$0.isActive } }
    private var dirtyCount: Int { repos.filter { $0.isDirty }.count }
    private var unpushedCount: Int { repos.filter { $0.unpushedCount > 0 }.count }

    var body: some View {
        if let repo = selectedRepo {
            RepoDetailView(repo: repo, onBack: { selectedRepo = nil })
                .accessibilityIdentifier("repos_detail")
        } else {
            repoListView
        }
    }

    private var repoListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // KPI cards
                HStack(spacing: 12) {
                    KPICard(value: "\(activeRepos.count)", label: "Active (24h)")
                    KPICard(value: "\(dirtyCount)", label: "Dirty")
                    KPICard(value: "\(unpushedCount)", label: "Unpushed")
                    KPICard(value: "\(repos.count)", label: "Total Repos")
                }

                if let error {
                    AlertBanner(message: "Failed to load repos: \(error)")
                }

                if !activeRepos.isEmpty {
                    SectionHeader(icon: "arrow.triangle.branch", title: "Active",
                                  onRefresh: { Task { await loadData() } })
                    LazyVStack(spacing: 4) {
                        ForEach(activeRepos) { repo in
                            RepoRow(repo: repo, sparkline: sparklines[repo.path] ?? [Int](repeating: 0, count: 7)) { selectedRepo = repo }
                        }
                    }
                }

                if !recentRepos.isEmpty {
                    SectionHeader(icon: "clock", title: "Recent")
                    LazyVStack(spacing: 4) {
                        ForEach(recentRepos) { repo in
                            RepoRow(repo: repo, sparkline: sparklines[repo.path] ?? [Int](repeating: 0, count: 7)) { selectedRepo = repo }
                        }
                    }
                }

                if repos.isEmpty && !isLoading {
                    EmptyState(
                        icon: "arrow.triangle.branch",
                        title: "No repos discovered",
                        message: "Repos are discovered from session working directories. Start some sessions first."
                    )
                    .accessibilityIdentifier("repos_emptyState")
                }
            }
            .padding(24)
            .accessibilityIdentifier("repos_list")
        }
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            repos = try db.listGitRepos()
            var map = [String: [Int]]()
            for repo in repos {
                map[repo.path] = (try? db.sparklineData(for: repo.path)) ?? [Int](repeating: 0, count: 7)
            }
            sparklines = map
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - RepoRow

private struct RepoRow: View {
    let repo: GitRepo
    let sparkline: [Int]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.primaryText)

                    if let branch = repo.branch {
                        Text(branch)
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if repo.isDirty {
                        let total = repo.dirtyCount + repo.untrackedCount
                        Text("\(total) changed")
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if repo.unpushedCount > 0 {
                        Text("\(repo.unpushedCount) unpushed")
                            .font(.caption2)
                            .foregroundStyle(Color.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    if let msg = repo.lastCommitMsg {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                    if let ts = repo.lastCommitAt {
                        Text(ts.prefix(10))
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
            }

            Spacer()

            if repo.sessionCount > 0 {
                Text("\(repo.sessionCount) sessions")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }

            SparklineView(values: sparkline, color: Theme.accent)

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
}
