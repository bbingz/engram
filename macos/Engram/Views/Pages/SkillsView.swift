// macos/Engram/Views/Pages/SkillsView.swift
import SwiftUI

struct SkillsView: View {
    @Environment(DaemonClient.self) var daemonClient
    @State private var skills: [SkillInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var error: String? = nil

    private var filteredSkills: [SkillInfo] {
        if searchText.isEmpty { return skills }
        let q = searchText.lowercased()
        return skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }
    private var globalSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "global" } }
    private var pluginSkills: [SkillInfo] { filteredSkills.filter { $0.scope == "plugin" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField("Search skills...", text: $searchText).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("skills_search")

                if let error { AlertBanner(message: error) }
                if !globalSkills.isEmpty {
                    SectionHeader(icon: "globe", title: "Global Commands")
                    ForEach(globalSkills) { skill in skillRow(skill) }
                }
                if !pluginSkills.isEmpty {
                    SectionHeader(icon: "puzzlepiece", title: "Plugin Skills")
                    ForEach(pluginSkills) { skill in skillRow(skill) }
                }
                if filteredSkills.isEmpty && !isLoading {
                    EmptyState(icon: "sparkles", title: "No skills found", message: "Skills from ~/.claude/ will appear here")
                        .accessibilityIdentifier("skills_emptyState")
                }
            }
            .padding(24)
            .accessibilityIdentifier("skills_list")
        }
        .task { await loadData() }
    }

    private func skillRow(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name).font(.callout).fontWeight(.medium).foregroundStyle(Theme.primaryText)
            if !skill.description.isEmpty {
                Text(skill.description).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            Text(skill.path).font(.caption2).foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { skills = try await daemonClient.fetch("/api/skills") }
        catch { self.error = "Could not load skills: \(error.localizedDescription)" }
    }
}
