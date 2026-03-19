// macos/Engram/Components/BarChart.swift
import SwiftUI

struct BarChartItem: Identifiable {
    let id = UUID()
    let label: String
    let value: Int
    let color: Color
}

struct BarChart: View {
    let items: [BarChartItem]

    private var maxValue: Int { items.map(\.value).max() ?? 1 }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 90, alignment: .trailing)
                    GeometryReader { geo in
                        let width = maxValue > 0
                            ? geo.size.width * CGFloat(item.value) / CGFloat(maxValue)
                            : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.color.opacity(0.6))
                            .frame(width: max(width, 2), height: 16)
                    }
                    .frame(height: 16)
                    Text("\(item.value)")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 50, alignment: .leading)
                }
            }
        }
    }
}
