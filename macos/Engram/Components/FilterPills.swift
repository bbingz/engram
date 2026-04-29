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
                            ? Theme.sidebarSelection
                            : Theme.border)
                        .foregroundStyle(selected == option
                            ? Theme.sidebarSelectedText
                            : Theme.secondaryText)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(selected == option
                                ? Theme.accent.opacity(0.3)
                                : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
