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
