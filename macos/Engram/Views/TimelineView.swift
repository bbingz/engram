// macos/Engram/Views/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var db: DatabaseManager
    @State private var entries: [TimelineEntry] = []
    @State private var filterText = ""
    @State private var expandedProjects: Set<String> = []
    @State private var projectSessions: [String: [Session]] = [:]
    @State private var agentFilter: Bool? = false   // default: hide agents
    @Binding var selectedTab: Int
    @Binding var deepLinkSession: Session?

    var filtered: [TimelineEntry] {
        guard !filterText.isEmpty else { return entries }
        return entries.filter { ($0.project ?? "").localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 6) {
                TextField("Filter by project...", text: $filterText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            // Agent filter
            HStack(spacing: 6) {
                Chip(label: "All",         selected: agentFilter == nil,   color: .secondary) {
                    agentFilter = nil
                    projectSessions = [:]   // flush cached sessions
                }
                Chip(label: "Agent only",  selected: agentFilter == true,  color: .purple) {
                    agentFilter = true
                    projectSessions = [:]
                }
                Chip(label: "Hide agents", selected: agentFilter == false, color: .orange) {
                    agentFilter = false
                    projectSessions = [:]
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            List {
                ForEach(filtered, id: \.project) { entry in
                    let key = entry.project ?? ""
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expandedProjects.contains(key) },
                            set: { open in
                                if open {
                                    expandedProjects.insert(key)
                                    Task { await loadSessions(for: entry.project) }
                                } else {
                                    expandedProjects.remove(key)
                                }
                            }
                        )
                    ) {
                        if let sessions = projectSessions[key] {
                            if sessions.isEmpty {
                                Text("No sessions")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(sessions, id: \.id) { session in
                                    TimelineSessionRow(session: session)
                                        .onTapGesture(count: 2) {
                                            deepLinkSession = session
                                            selectedTab = 0
                                        }
                                }
                            }
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 4)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(verbatim: entry.project ?? String(localized: "(unknown)"))
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(entry.sessionCount)")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                            Text(String(entry.lastUpdated.prefix(10)))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .task { entries = (try? db.projectTimeline()) ?? [] }
    }

    func loadSessions(for project: String?) async {
        let key = project ?? ""
        guard projectSessions[key] == nil else { return }
        projectSessions[key] = (try? db.listSessionsForProject(project, subAgent: agentFilter)) ?? []
    }
}

struct TimelineSessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: session.source)
                .font(.caption2).bold()
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            if session.isSubAgent {
                Text("agent")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            Text(verbatim: session.displayTitle)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: session.displayDate)
                if session.displayUpdatedDate != session.displayDate {
                    Text(verbatim: "→ \(session.displayUpdatedDate)")
                        .foregroundStyle(.quaternary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help("Double-click to open in Sessions")
    }
}
