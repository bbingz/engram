// macos/CodingMemory/Views/SessionListView.swift
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var sessions: [Session] = []
    @State private var selectedSource: String? = nil
    @State private var selectedSession: Session?

    let sources = ["claude-code", "codex", "cursor", "gemini-cli",
                   "opencode", "iflow", "qwen", "kimi", "cline",
                   "vscode", "antigravity", "windsurf"]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Chip(label: "All", selected: selectedSource == nil) { selectedSource = nil }
                        ForEach(sources, id: \.self) { src in
                            Chip(label: src, selected: selectedSource == src) {
                                selectedSource = selectedSource == src ? nil : src
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                Divider()
                List(sessions, selection: $selectedSession) { session in
                    SessionRow(session: session)
                        .tag(session)
                }
            }
            .frame(minWidth: 200, maxWidth: 280)

            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 200)
            } else {
                Text("Select a session")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: selectedSource) { await reload() }
    }

    func reload() async {
        sessions = (try? db.listSessions(source: selectedSource, limit: 100)) ?? []
    }
}

struct Chip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(session.source)
                    .font(.caption2).bold()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(session.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(session.displayDate)
                Text("·")
                Text("\(session.messageCount) msgs")
                if let proj = session.project {
                    Text("·")
                    Text(proj).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
