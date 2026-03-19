// macos/Engram/Components/HeatmapGrid.swift
import SwiftUI

struct HeatmapGrid: View {
    let data: [Int]  // 24 values for hours 0-23
    var colorBase: Color = Color(hex: 0x4A8FE7)

    private var maxValue: Int { data.max() ?? 1 }

    private let hourLabels = ["12a", "", "", "3a", "", "", "6a", "", "", "9a", "", "",
                              "12p", "", "", "3p", "", "", "6p", "", "", "9p", "", ""]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let intensity = maxValue > 0 ? Double(data[hour]) / Double(maxValue) : 0
                    RoundedRectangle(cornerRadius: 3)
                        .fill(intensity > 0
                            ? colorBase.opacity(0.15 + intensity * 0.65)
                            : Color.white.opacity(0.02))
                        .frame(height: 24)
                        .overlay(
                            Group {
                                if data[hour] > 0 {
                                    Text("\(data[hour])")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        )
                }
            }
            HStack(spacing: 0) {
                ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                    Text(hourLabels[hour])
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0x6E7078))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
