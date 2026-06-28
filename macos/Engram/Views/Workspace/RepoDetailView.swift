// macos/Engram/Views/Workspace/RepoDetailView.swift
import SwiftUI

struct RepoDetailView: View {
    let repo: GitRepo
    let onBack: () -> Void
    @Environment(DatabaseManager.self) var db
    @State private var claudeMdContent: String?
    @State private var relatedSessions: [Session] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Breadcrumb
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Repos")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("repos_detail_back")

                // Header
                HStack(spacing: 8) {
                    Text(repo.name).font(.title2.bold())
                    if let branch = repo.branch {
                        Text(branch)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                if let msg = repo.lastCommitMsg {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let ts = repo.lastCommitAt {
                            Text(String(ts.prefix(10)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Quick actions
                HStack(spacing: 8) {
                    quickActionButton("Claude", icon: "terminal") {
                        let command = TerminalLauncher.appleScriptCommandLine(command: "claude", args: [], cwd: repo.path)
                        let script = "tell application \"Terminal\" to do script \"\(command)\""
                        NSAppleScript(source: script)?.executeAndReturnError(nil)
                    }
                    quickActionButton("VS Code", icon: "curlybraces") {
                        Process.launchedProcess(launchPath: "/usr/bin/open",
                                                arguments: ["-a", "Visual Studio Code", repo.path])
                    }
                    quickActionButton("Terminal", icon: "terminal.fill") {
                        Process.launchedProcess(launchPath: "/usr/bin/open",
                                                arguments: ["-a", "Terminal", repo.path])
                    }
                    quickActionButton("Finder", icon: "folder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path)
                    }
                    quickActionButton("Copy Path", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(repo.path, forType: .string)
                    }
                }

                // CLAUDE.md
                if let content = claudeMdContent {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                Text("CLAUDE.md")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)
                            }
                            Divider()
                            Text(content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(60)
                        }
                    }
                }

                // Related sessions
                if !relatedSessions.isEmpty {
                    Text("Recent Sessions")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(relatedSessions) { session in
                        Button {
                            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(SourceColors.color(for: session.source))
                                    .frame(width: 6, height: 6)
                                Text(session.displayTitle)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(Theme.primaryText)
                                Spacer()
                                Text(session.source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(session.displayDate)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("repos_detail_sessionRow")
                    }
                } else if !isLoading {
                    Text("No recent sessions for this repo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .task {
            // Load CLAUDE.md + related sessions off the main thread (UI-C1/C2).
            isLoading = true
            let db = self.db
            let path = repo.path
            let loaded = await Task.detached { () -> (String?, [Session]) in
                let claudePath = (path as NSString).appendingPathComponent("CLAUDE.md")
                let claude = try? String(contentsOfFile: claudePath, encoding: .utf8)
                let related = (try? db.sessionsForRepo(path: path, limit: 10)) ?? []
                return (claude, related)
            }.value
            claudeMdContent = loaded.0
            relatedSessions = loaded.1
            isLoading = false
        }
        .accessibilityIdentifier("repos_detail")
    }

    private func quickActionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 62, height: 52)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
