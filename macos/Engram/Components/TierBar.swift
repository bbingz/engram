// macos/Engram/Components/TierBar.swift
import SwiftUI

struct TierBar: View {
    let premium: Int
    let normal: Int
    let lite: Int
    let skip: Int

    private var total: Int { premium + normal + lite + skip }

    private let tierColors: [(String, Color)] = [
        ("premium", Color(hex: 0x4A8FE7)),
        ("normal", Color(hex: 0x30D158)),
        ("lite", Color(hex: 0xFF9F0A)),
        ("skip", Color(hex: 0x636366)),
    ]

    private var segments: [(name: String, count: Int, color: Color)] {
        [("premium", premium, tierColors[0].1),
         ("normal", normal, tierColors[1].1),
         ("lite", lite, tierColors[2].1),
         ("skip", skip, tierColors[3].1)]
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        if seg.count > 0 {
                            let width = geo.size.width * CGFloat(seg.count) / CGFloat(max(total, 1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(seg.color.opacity(0.7))
                                .frame(width: max(width, 4))
                        }
                    }
                }
            }
            .frame(height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 16) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 4) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text("\(seg.name) \(seg.count)")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
    }
}
