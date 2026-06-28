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
    @Environment(EngramServiceClient.self) private var serviceClient
    @State private var items: [ImplementationTimelineItem] = []
    @State private var isLoading = true
    /// 已请求过语义标题生成的项目集合，避免 load -> 生成 -> reload 形成无限循环。
    @State private var requestedTitleGen: Set<String> = []

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
                                    dateLabel: Self.dateRange(item),
                                    kindLabel: Self.kindLabel(item.kind),
                                    kindColor: Self.kindColor(item.kind)
                                )
                                .padding(.bottom, index == items.count - 1 ? 0 : 16)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projectTimeline_card")
                    }
                }
                .accessibilityIdentifier("projectTimeline_list")
            }
        }
        .accessibilityIdentifier("projectTimeline_container")
        // Reload when the user switches to a different project.
        .task(id: project) { await load() }
    }

    /// - Parameter showSpinner: 仅首次/切换项目时显示加载态。语义标题生成后的
    ///   二次 reload 传 false，原地替换标题而不清空已渲染的轨道、不闪 ProgressView。
    private func load(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        let db = self.db
        let project = self.project
        do {
            // Off the main thread (UI-C1/C2), same as the global Timeline page.
            items = try await Task.detached {
                try db.implementationTimeline(days: 90, project: project, humanDriven: true)
            }.value
        } catch {
            EngramLogger.error("ProjectWorkTimeline load failed", module: .ui, error: error)
            items = []
        }
        isLoading = false

        // 若有工作项缺少 AI 语义标题，且该项目尚未请求过生成，则触发一次 service 端
        // 生成（写入 work_item_titles），完成后再 load 一次读取持久化标题。
        // requestedTitleGen 守卫确保每个项目最多请求一次，避免无限循环。
        guard items.contains(where: { $0.semanticTitle == nil }),
              !requestedTitleGen.contains(project) else { return }
        requestedTitleGen.insert(project)
        try? await serviceClient.generateProjectWorkTitles(
            EngramServiceGenerateProjectWorkTitlesRequest(project: project)
        )
        await load(showSpinner: false)
    }

    /// 点击节点：解析工作项最新 beat 的 sessionId -> Session，复用 .openSession 通道
    /// （由 MainWindowView 观察并切换到会话详情）。
    private func open(_ item: ImplementationTimelineItem) {
        guard let sessionId = item.beats.last?.sessionId else { return }
        let db = self.db
        Task {
            guard let session = try? await Task.detached(operation: {
                try db.getSession(id: sessionId)
            }).value else { return }
            NotificationCenter.default.post(name: .openSession, object: SessionBox(session))
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

    private static func dateLabel(_ dateStr: String) -> String {
        guard let date = inputDateFormatter.date(from: dateStr) else { return dateStr }
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return outputDateFormatter.string(from: date)
    }

    private static func dateRange(_ item: ImplementationTimelineItem) -> String {
        let start = dateLabel(item.startDate)
        let end = dateLabel(item.endDate)
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

/// 竖直时间轴轨道：每行一段连接线 + 一个彩色节点圆点。
/// GeometryReader 自适应行高（由 TimelineNode 内容决定）以画出连续连接线。
private struct TimelineRail: View {
    let isFirst: Bool
    let isLast: Bool
    let color: Color
    private let dotSize: CGFloat = 9
    private let lineWidth: CGFloat = 1.5
    private let dotTopInset: CGFloat = 7 // 让圆点与日期/标题首行对齐

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

/// 单个工作项节点内容（从 WorkTimelineCard 抽出，去掉盒子背景，由轨道承担分隔）。
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
