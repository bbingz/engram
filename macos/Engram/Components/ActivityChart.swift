// macos/Engram/Components/ActivityChart.swift
import SwiftUI

struct ActivityChart: View {
    let data: [(date: String, count: Int)]
    var accentColor: Color = Theme.accent

    private var maxCount: Int { data.map(\.count).max() ?? 1 }

    private var accessibilitySummary: String {
        let total = data.reduce(0) { $0 + $1.count }
        guard let peak = data.max(by: { $0.count < $1.count }), peak.count > 0 else {
            return "\(data.count) days, no sessions"
        }
        return "\(data.count) days, \(total) sessions total, busiest \(peak.date) with \(peak.count)"
    }

    var body: some View {
        GeometryReader { geo in
            let barWidth = max((geo.size.width - CGFloat(data.count - 1) * 2) / CGFloat(max(data.count, 1)), 2)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, entry in
                    let height = maxCount > 0
                        ? geo.size.height * CGFloat(entry.count) / CGFloat(maxCount)
                        : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.8), accentColor.opacity(0.3)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: barWidth, height: max(height, 1))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session activity chart")
        .accessibilityValue(accessibilitySummary)
    }
}

struct StackedActivityChart: View {
    let data: [(date: String, segments: [(source: String, count: Int)])]
    let sourceOrder: [String]

    private var sourceRank: [String: Int] {
        Dictionary(uniqueKeysWithValues: sourceOrder.enumerated().map { ($0.element, $0.offset) })
    }

    private var maxCount: Int {
        max(data.map { day in day.segments.reduce(0) { $0 + $1.count } }.max() ?? 1, 1)
    }

    private var accessibilitySummary: String {
        let total = data.reduce(0) { running, day in
            running + day.segments.reduce(0) { $0 + $1.count }
        }
        return "\(data.count) days, \(total) sessions total across \(sourceOrder.count) sources"
    }

    var body: some View {
        GeometryReader { geo in
            let barWidth = max((geo.size.width - CGFloat(data.count - 1) * 2) / CGFloat(max(data.count, 1)), 2)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, entry in
                    let total = entry.segments.reduce(0) { $0 + $1.count }
                    let height = total > 0
                        ? geo.size.height * CGFloat(total) / CGFloat(maxCount)
                        : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            ForEach(sortedSegments(entry.segments), id: \.source) { segment in
                                Rectangle()
                                    .fill(SourceColors.color(for: segment.source).opacity(0.72))
                                    .frame(height: height * CGFloat(segment.count) / CGFloat(max(total, 1)))
                            }
                        }
                        .frame(width: barWidth, height: max(height, 1))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session activity chart by source")
        .accessibilityValue(accessibilitySummary)
    }

    private func sortedSegments(_ segments: [(source: String, count: Int)]) -> [(source: String, count: Int)] {
        segments.sorted {
            (sourceRank[$0.source] ?? Int.max, $0.source) < (sourceRank[$1.source] ?? Int.max, $1.source)
        }
    }
}
