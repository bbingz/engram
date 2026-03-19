// macos/Engram/Components/FilterPills.swift
import SwiftUI

struct FilterPills: View {
    let options: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(action: { selected = option }) {
                    Text(option)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected == option
                            ? Color(hex: 0x4A8FE7).opacity(0.25)
                            : Color.white.opacity(0.04))
                        .foregroundStyle(selected == option
                            ? Color(hex: 0x6CB4FF)
                            : Color(hex: 0xA0A1A8))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(selected == option
                                ? Color(hex: 0x4A8FE7).opacity(0.3)
                                : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
