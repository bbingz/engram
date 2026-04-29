// macos/Engram/Views/Workspace/SparklineView.swift
import SwiftUI

struct SparklineView: View {
    let values: [Int]  // 7 values, one per day (most recent last)
    var color: Color = .blue

    var body: some View {
        let maxVal = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<values.count, id: \.self) { i in
                let height = values[i] > 0 ? max(CGFloat(values[i]) / CGFloat(maxVal), 0.1) : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(values[i] > 0 ? color.opacity(0.6 + 0.4 * Double(values[i]) / Double(maxVal)) : Color.clear)
                    .frame(width: 3, height: 16 * height)
            }
        }
        .frame(width: 25, height: 16)
    }
}
