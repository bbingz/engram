// macos/Engram/Components/ProjectBadge.swift
import SwiftUI

struct ProjectBadge: View {
    let project: String
    var source: String = ""

    /// Last path component of a project path — the one shared short project
    /// label (HomeView, SearchPageView, ProjectsView, TodayWorkbenchSupport).
    static func shortLabel(_ project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    private var displayName: String {
        Self.shortLabel(project)
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
