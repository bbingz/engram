// macos/Engram/Components/HeatmapGrid.swift
import SwiftUI

struct HeatmapGrid: View {
    let data: [Int]  // 24 values for hours 0-23
    var colorBase: Color = Theme.accent

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
                            : Theme.surface)
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
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // UI-H3: expose the per-hour activity to VoiceOver as one labeled element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity by hour")
        .accessibilityValue(accessibilityValueText)
    }

    private func hourName(_ hour: Int) -> String {
        switch hour {
        case 0: return "12am"
        case 1..<12: return "\(hour)am"
        case 12: return "12pm"
        default: return "\(hour - 12)pm"
        }
    }

    private var accessibilityValueText: String {
        let active = data.enumerated().filter { $0.element > 0 }
        guard !active.isEmpty else { return "No activity" }
        return active.map { "\(hourName($0.offset)): \($0.element)" }.joined(separator: ", ")
    }
}
