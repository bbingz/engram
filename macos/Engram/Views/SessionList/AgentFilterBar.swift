// macos/Engram/Views/SessionList/AgentFilterBar.swift
import SwiftUI

/// Horizontal row of pill-style buttons for filtering by source/agent.
/// Multi-select: tapping a pill toggles it. "All" clears the selection.
struct AgentFilterBar: View {
    let sourceCounts: [(source: String, count: Int)]
    @Binding var selectedSources: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                // "All" pill
                pillButton(label: "All", color: .secondary, isSelected: selectedSources.isEmpty) {
                    selectedSources = []
                }

                ForEach(sourceCounts.filter { $0.count > 0 }, id: \.source) { item in
                    let isSelected = selectedSources.contains(item.source)
                    let sourceColor = SourceColors.color(for: item.source)
                    pillButton(
                        label: "\(SourceColors.label(for: item.source)) \(item.count)",
                        color: sourceColor,
                        isSelected: isSelected,
                        dot: sourceColor
                    ) {
                        if isSelected {
                            selectedSources.remove(item.source)
                        } else {
                            selectedSources.insert(item.source)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pillButton(
        label: String,
        color: Color,
        isSelected: Bool,
        dot: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? color.opacity(0.25) : Color.secondary.opacity(0.1))
            .foregroundStyle(isSelected ? color : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
