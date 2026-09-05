// macos/Engram/Components/SourcePill.swift
import SwiftUI

struct SourcePill: View {
    let source: String

    var body: some View {
        Text(SourceColors.label(for: source))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SourceColors.color(for: source).opacity(0.15))
            .foregroundStyle(SourceColors.color(for: source))
            .clipShape(Capsule())
    }
}

struct OriginBadge: View {
    let origin: String?

    var body: some View {
        if origin == "hq" {
            Text("HQ")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.orange.opacity(0.18))
                .foregroundStyle(Theme.orange)
                .clipShape(Capsule())
                // `.caption2` is a Dynamic Type style and scales; `fixedSize`
                // keeps the capsule from truncating at larger text sizes.
                .fixedSize()
                .accessibilityLabel("Session from HQ")
                .accessibilityIdentifier("originBadge_hq")
        }
    }
}
