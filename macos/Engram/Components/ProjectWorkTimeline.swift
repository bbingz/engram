// macos/Engram/Components/ProjectWorkTimeline.swift
import SwiftUI

/// Per-project work timeline embedded in the Projects detail view.
///
/// Surfaces `implementationTimeline(project:)` as a vertical rail of work-item
/// nodes, scoped to a single project. Each node prefers the AI semantic title
/// (`item.semanticTitle ?? item.title`) and opens the latest session on tap.
/// Previously the only project-level timeline was the project picker on the
/// global Timeline page; this puts it directly inside a project's detail so it
/// is discoverable where users expect it.
struct ProjectWorkTimeline: View {
    let project: String
    @Environment(DatabaseManager.self) private var db
    @Environment(\.engramServiceClient) private var serviceClient
    @Environment(\.engramFixedDate) private var fixedDate
    @State private var items: [ImplementationTimelineItem] = []
    @State private var isLoading = true
    /// Projects that already requested semantic title generation, preventing a load -> generate -> reload loop.
    @State private var requestedTitleGen: Set<String> = []
    @State private var openRequestId: UUID?
    /// Keyboard focus for timeline rows (Wave 8-6): .plain buttons draw no ring.
    @FocusState private var focusedItemId: String?

    private static let inputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        let now = fixedDate ?? Date()
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "chart.bar.xaxis", title: "Timeline")
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .accessibilityIdentifier("projectTimeline_loading")
            } else if items.isEmpty {
                Text("No summarized work for this project yet")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityIdentifier("projectTimeline_empty")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            open(item)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                TimelineRail(
                                    isFirst: index == 0,
                                    isLast: index == items.count - 1,
                                    color: Self.kindColor(item.kind)
                                )
                                TimelineNode(
                                    item: item,
                                    dateLabel: Self.dateRange(item, now: now),
                                    kindLabel: Self.kindLabel(item.kind),
                                    kindColor: Self.kindColor(item.kind)
                                )
                                .padding(.bottom, index == items.count - 1 ? 0 : 16)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Single VoiceOver stop: rail + node read as one button.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("projectTimeline_card")
                        // Keyboard navigation (Wave 8-6): visible ring + Enter/Space.
                        .focusable()
                        .focused($focusedItemId, equals: item.id)
                        .onKeyPress(keys: [.return, .space]) { _ in
                            guard focusedItemId == item.id else { return .ignored }
                            open(item)
                            return .handled
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.accent, lineWidth: 2)
                                .opacity(focusedItemId == item.id ? 1 : 0)
                                .allowsHitTesting(false)
                        )
                    }
                }
                .accessibilityIdentifier("projectTimeline_list")
            }
        }
        .accessibilityIdentifier("projectTimeline_container")
        // Reload when the user switches to a different project.
        .task(id: project) { await load() }
        .onDisappear { openRequestId = nil }
    }

    /// - Parameter showSpinner: Shows loading only on first load or project switch.
    ///   The post-generation reload passes false so the rendered rail updates in place.
    private func load(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        let db = self.db
        let project = self.project
        let now = fixedDate ?? Date()
        do {
            // Off the main thread (UI-C1/C2), same as the global Timeline page.
            items = try await Task.detached {
                try db.implementationTimeline(
                    days: ProjectWorkWindow.defaultDays,
                    project: project,
                    humanDriven: true,
                    now: now
                )
            }.value
        } catch {
            EngramLogger.error("ProjectWorkTimeline load failed", module: .ui, error: error)
            items = []
        }
        isLoading = false

        // If any work item lacks a semantic title, request one service-side
        // generation pass (persisted to work_item_titles), then reload the
        // saved titles. requestedTitleGen keeps this to one request per project.
        guard items.contains(where: { $0.semanticTitle == nil }),
              !requestedTitleGen.contains(project) else { return }
        requestedTitleGen.insert(project)
        _ = try? await serviceClient.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(project: project, now: now)
        )
        await load(showSpinner: false)
    }

    /// Opens the latest beat's session through the existing .openSession path.
    private func open(_ item: ImplementationTimelineItem) {
        guard let sessionId = item.beats.last?.sessionId else { return }
        let requestId = UUID()
        openRequestId = requestId
        let token = SessionNavigationGate.begin()
        let db = self.db
        Task {
            let session = try? await Task.detached(operation: {
                try db.getSession(id: sessionId)
            }).value
            guard openRequestId == requestId,
                  SessionNavigationGate.isCurrent(token) else { return }
            guard let session else {
                SessionNavigationGate.complete(token)
                return
            }
            NotificationCenter.default.post(
                name: .openSession,
                object: SessionBox(session, navigationId: token)
            )
        }
    }

    private static func kindColor(_ kind: SessionImplementationKind) -> Color {
        switch kind {
        case .implementation: Theme.accent
        case .fix: Theme.red
        case .optimization: Theme.green
        case .security: Theme.orange
        case .research: Theme.accent
        case .maintenance: Theme.gray
        case .deployment: Theme.green
        case .verification: Theme.green
        }
    }

    private static func dateLabel(_ dateStr: String, now: Date) -> String {
        guard let date = inputDateFormatter.date(from: dateStr) else { return dateStr }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return outputDateFormatter.string(from: date)
    }

    private static func dateRange(_ item: ImplementationTimelineItem, now: Date) -> String {
        let start = dateLabel(item.startDate, now: now)
        let end = dateLabel(item.endDate, now: now)
        return item.startDate == item.endDate ? start : "\(start) - \(end)"
    }

    private static func kindLabel(_ kind: SessionImplementationKind) -> String {
        switch kind {
        case .implementation: String(localized: "Feature")
        case .fix: String(localized: "Fix")
        case .optimization: String(localized: "Optimize")
        case .security: String(localized: "Security")
        case .research: String(localized: "Research")
        case .maintenance: String(localized: "Maintenance")
        case .deployment: String(localized: "Deploy")
        case .verification: String(localized: "Verify")
        }
    }
}

/// Vertical timeline rail: one connector segment plus a colored node dot per row.
/// GeometryReader tracks row height from TimelineNode content for a continuous line.
private struct TimelineRail: View {
    let isFirst: Bool
    let isLast: Bool
    let color: Color
    private let dotSize: CGFloat = 9
    private let lineWidth: CGFloat = 1.5
    private let dotTopInset: CGFloat = 7 // Aligns the dot with the first date/title line.

    var body: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            let dotY = dotTopInset + dotSize / 2
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: midX, y: isFirst ? dotY : 0))
                    path.addLine(to: CGPoint(x: midX, y: isLast ? dotY : geo.size.height))
                }
                .stroke(Theme.border, lineWidth: lineWidth)

                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    .position(x: midX, y: dotY)
            }
        }
        .frame(width: 18)
    }
}

/// Single work-item node content without the global Timeline card background.
private struct TimelineNode: View {
    let item: ImplementationTimelineItem
    let dateLabel: String
    let kindLabel: String
    let kindColor: Color

    private var outcome: String {
        item.beats.last?.assistantOutcome.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dateLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                Text(kindLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer(minLength: 8)
                Text(String.localizedStringWithFormat(String(localized: "%lld sessions"), item.beats.count))
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(item.semanticTitle ?? item.title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)
            if !outcome.isEmpty {
                Text(outcome)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
