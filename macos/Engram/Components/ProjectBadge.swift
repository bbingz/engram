// macos/Engram/Components/ProjectBadge.swift
import SwiftUI

struct ProjectBadge: View {
    let project: String
    var source: String = ""

    private var displayName: String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    var body: some View {
        Text(displayName)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SourceColors.color(for: source).opacity(0.08))
            .foregroundStyle(Theme.secondaryText)
            .clipShape(Capsule())
    }
}
