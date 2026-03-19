// macos/Engram/Views/Pages/SkillsView.swift
import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var daemonClient: DaemonClient
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
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search skills...", text: $searchText).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))

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
                }
            }
            .padding(24)
        }
        .task { await loadData() }
    }

    private func skillRow(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name).font(.callout).fontWeight(.medium).foregroundStyle(.white)
            if !skill.description.isEmpty {
                Text(skill.description).font(.caption).foregroundStyle(Color(hex: 0xA0A1A8)).lineLimit(2)
            }
            Text(skill.path).font(.caption2).foregroundStyle(Color(hex: 0x6E7078))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.02))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { skills = try await daemonClient.fetch("/api/skills") }
        catch { self.error = "Could not load skills: \(error.localizedDescription)" }
    }
}
