// macos/Engram/Components/ActivityChart.swift
import SwiftUI

struct ActivityChart: View {
    let data: [(date: String, count: Int)]
    var accentColor: Color = Theme.accent

    private var maxCount: Int { data.map(\.count).max() ?? 1 }

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
    }
}
