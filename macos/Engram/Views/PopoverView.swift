// macos/Engram/Views/PopoverView.swift
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var db: DatabaseManager
    @EnvironmentObject var indexer: IndexerProcess

    @State private var sourceCount = 0
    @State private var projectCount = 0
    @State private var dbSize: Int64 = 0
    @State private var recentSessions: [Session] = []
    @State private var embeddingAvailable = false
    @State private var embeddingProgress: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            statsSection
            Divider()
            timelineSection
            footerSection
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { loadData() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: 10) {
                statusDot(
                    color: indexer.port != nil ? .green : .red,
                    label: indexer.port.map { "Web :\($0)" } ?? "Web"
                )
                statusDot(
                    color: indexer.status.isRunning ? .green : .red,
                    label: "MCP"
                )
                embeddingStatusView
            }
            .font(.caption2)
        }
    }

    private var embeddingStatusView: some View {
        Group {
            if !embeddingAvailable && embeddingProgress == nil {
                statusDot(color: .secondary, label: "Embedding", hollow: true)
            } else if let pct = embeddingProgress, pct < 100 {
                statusDot(color: .orange, label: "Embedding \(pct)%")
            } else {
                statusDot(color: .green, label: "Embedding")
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                statRow("Sessions", "\(indexer.totalSessions)")
                statRow("Sources", "\(sourceCount)")
            }
            GridRow {
                statRow("Projects", "\(projectCount)")
                statRow("DB Size", formattedSize(dbSize))
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color(.controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                let groups = groupedByDate(recentSessions)
                ForEach(groups) { group in
                    Text(group.key)
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.top, group.id == groups.first?.id ? 0 : 6)
                    ForEach(group.sessions) { session in
                        timelineRow(session)
                    }
                }
            }
        }
    }

    private func timelineRow(_ session: Session) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(SourceDisplay.color(for: session.source))
                .frame(width: 4, height: 4)
            Text(SourceDisplay.label(for: session.source))
                .font(.caption2)
                .foregroundStyle(SourceDisplay.color(for: session.source))
                .frame(width: 58, alignment: .leading)
            Text(session.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(relativeTime(session.startTime))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: .openWindow, object: SessionBox(session))
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

    // MARK: - Data Loading

    private func loadData() {
        sourceCount = (try? db.countsBySource())?.count ?? 0
        projectCount = (try? db.listProjects())?.count ?? 0
        dbSize = db.dbSizeBytes()
        let all = (try? db.listSessionsChronologically(subAgent: false, limit: 30)) ?? []
        recentSessions = Array(all.filter { $0.messageCount > 0 }.prefix(15))
        Task { await fetchEmbeddingStatus() }
    }

    private func fetchEmbeddingStatus() async {
        let port = indexer.port ?? 3457
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/search/status") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONDecoder().decode(EmbeddingStatusResponse.self, from: data)
            embeddingAvailable = status.available
            if status.available, let p = status.progress, p < 100 {
                embeddingProgress = p
            } else {
                embeddingProgress = nil
            }
        } catch {
            embeddingAvailable = false
            embeddingProgress = nil
        }
    }

    // MARK: - Helpers

    private func statusDot(color: Color, label: String, hollow: Bool = false) -> some View {
        HStack(spacing: 3) {
            if hollow {
                Circle().strokeBorder(color, lineWidth: 1).frame(width: 5, height: 5)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(label)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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
        let iso = Self.isoFormatter
        var groups: [(String, [Session])] = []
        var currentKey = ""
        var currentGroup: [Session] = []
        for s in sessions {
            let dateStr = String(s.startTime.prefix(10))
            let key: String
            if let date = iso.date(from: s.startTime) ?? Self.dateOnlyFormatter.date(from: dateStr) {
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

    private func relativeTime(_ ts: String) -> String {
        guard let d = Self.isoFormatter.date(from: ts) else { return "" }
        let secs = -d.timeIntervalSinceNow
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86400))d"
    }

    private func formattedSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
