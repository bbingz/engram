// macos/Engram/Views/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @Environment(DatabaseManager.self) var db
    @State private var sessions: [Session] = []
    @State private var timeGroups: [(date: String, sessions: [Session])] = []
    @State private var agentFilter: Bool? = false   // default: hide agents
    @State private var selectedSources: Set<String> = []
    @State private var selectedProjects: Set<String> = []
    @Binding var selectedTab: AppTab
    @Binding var deepLinkSession: Session?
    @State private var totalCount: Int = 0
    @State private var hasMore = true
    private let pageSize = 50

    @State private var availableProjects: [String] = []

    private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale.current
        return f
    }()
    private static let headerDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = Locale.current
        f.doesRelativeDateFormatting = true
        return f
    }()

    let allSources = ["claude-code", "codex", "copilot", "pi", "cursor", "gemini-cli",
                      "opencode", "iflow", "qwen", "kimi", "minimax",
                      "lobsterai", "cline", "vscode", "antigravity", "windsurf"]

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 6) {
                MultiSelectPicker(
                    emptyLabel: "All sources",
                    icon: "cpu",
                    items: allSources,
                    selected: $selectedSources
                )
                MultiSelectPicker(
                    emptyLabel: "All projects",
                    icon: "folder",
                    items: availableProjects,
                    selected: $selectedProjects
                )
                Spacer()
                // Agent filter chips
                HStack(spacing: 6) {
                    Chip(label: "All",         selected: agentFilter == nil,   color: .secondary) { agentFilter = nil }
                    Chip(label: "Agent only",  selected: agentFilter == true,  color: .purple)    { agentFilter = true }
                    Chip(label: "Hide agents", selected: agentFilter == false, color: .orange)    { agentFilter = false }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            if timeGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("No sessions match the current filters.")
                }
            } else {
                List {
                    ForEach(timeGroups, id: \.date) { group in
                        Section(header: sectionHeader(group.date)) {
                            ForEach(group.sessions) { session in
                                TimelineSessionRow(session: session)
                                    .onTapGesture(count: 2) {
                                        deepLinkSession = session
                                        selectedTab = .sessions
                                    }
                            }
                        }
                    }
                    if hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .onAppear {
                                Task { await loadMore() }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            let db = self.db
            availableProjects = (try? await Task.detached {
                try db.readInBackground { d in
                    try String.fetchAll(d, sql: "SELECT DISTINCT project FROM sessions WHERE project IS NOT NULL AND hidden_at IS NULL ORDER BY project")
                }
            }.value) ?? []
            await reload()
        }
        .task(id: selectedSources)  { await reload() }
        .task(id: selectedProjects) { await reload() }
        .task(id: agentFilter)      { await reload() }
    }

    @ViewBuilder
    func sectionHeader(_ date: String) -> some View {
        HStack {
            Text(date)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.vertical, 4)
        .background(.clear)
    }

    func reload() async {
        sessions = (try? db.listSessionsChronologically(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            limit: pageSize
        )) ?? []
        totalCount = (try? db.countSessions(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter
        )) ?? 0
        hasMore = sessions.count < totalCount
        groupSessionsByDate()
    }

    func loadMore() async {
        guard hasMore else { return }
        let next = (try? db.listSessionsChronologically(
            sources: selectedSources,
            projects: selectedProjects,
            subAgent: agentFilter,
            limit: pageSize,
            offset: sessions.count
        )) ?? []
        sessions.append(contentsOf: next)
        hasMore = sessions.count < totalCount
        groupSessionsByDate()
    }

    func groupSessionsByDate() {
        var groups: [(date: String, sessions: [Session])] = []
        var currentGroup: [Session] = []
        var currentDate: String?

        for session in sessions {
            let sessionDate = String(session.startTime.prefix(10))
            if sessionDate != currentDate {
                if !currentGroup.isEmpty, let date = currentDate {
                    groups.append((date: formatDateHeader(date), sessions: currentGroup))
                }
                currentDate = sessionDate
                currentGroup = [session]
            } else {
                currentGroup.append(session)
            }
        }
        if !currentGroup.isEmpty, let date = currentDate {
            groups.append((date: formatDateHeader(date), sessions: currentGroup))
        }

        timeGroups = groups
    }

    func formatDateHeader(_ dateString: String) -> String {
        if let date = Self.dateParser.date(from: dateString) {
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return String(localized: "Today")
            } else if calendar.isDateInYesterday(date) {
                return String(localized: "Yesterday")
            }
            return Self.headerDisplayFormatter.string(from: date)
        }
        return dateString
    }
}

struct TimelineSessionRow: View {
    let session: Session

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let timeDisplay: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.locale = Locale.current
        return f
    }()

    private var sourceColor: Color { SourceDisplay.color(for: session.source) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sourceColor)
                .frame(width: 6, height: 6)
            Text(verbatim: session.project ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: session.displayTitle)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            if session.isSubAgent {
                Text("agent")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
            Text(verbatim: SourceDisplay.label(for: session.source))
                .font(.caption)
                .foregroundStyle(sourceColor)
            Text(verbatim: timeString(from: session.startTime))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help("Double-click to open in Sessions")
    }

    func timeString(from isoDate: String) -> String {
        if let date = Self.isoParser.date(from: isoDate) {
            return Self.timeDisplay.string(from: date)
        }
        return String(isoDate.prefix(16))
    }
}
