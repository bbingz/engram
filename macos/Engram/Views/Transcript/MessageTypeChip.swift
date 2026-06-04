// macos/Engram/Views/Transcript/MessageTypeChip.swift
import SwiftUI

struct MessageTypeChip: View {
    let type: MessageType
    let currentIndex: Int
    let totalCount: Int
    var partiallyLoaded: Bool = false
    let isVisible: Bool
    let onToggle: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    private var chipColor: Color { type.color }

    // "N+" when only a prefix of the transcript is loaded: the count is a lower
    // bound, not the session total, and chip Prev/Next only cycles the loaded set.
    private var countLabel: String { "\(totalCount)\(partiallyLoaded ? "+" : "")" }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isVisible ? chipColor : .secondary)
                        .frame(width: 6, height: 6)
                    Text("\(type.label) \(currentIndex >= 0 ? "\(currentIndex + 1)/" : "")\(countLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(isVisible ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)

            if totalCount > 0 && isVisible {
                Button(action: onPrev) {
                    Text("∧").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: onNext) {
                    Text("∨").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .opacity(isVisible ? 1.0 : 0.5)
    }
}
