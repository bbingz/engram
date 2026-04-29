// macos/Engram/Components/SectionHeader.swift
import SwiftUI

struct SectionHeader: View {
    let icon: String
    let title: String
    var badge: String? = nil
    var onRefresh: (() -> Void)? = nil
    var trailingAction: (label: String, action: () -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceHighlight)
                    .clipShape(Capsule())
                    .foregroundStyle(Theme.secondaryText)
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let trailing = trailingAction {
                Button(action: trailing.action) {
                    HStack(spacing: 4) {
                        Text(trailing.label)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }
}
