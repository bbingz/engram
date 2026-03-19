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
                .foregroundStyle(Color(hex: 0x6E7078))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .foregroundStyle(Color(hex: 0xA0A1A8))
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6E7078))
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
                    .foregroundStyle(Color(hex: 0x4A8FE7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }
}
