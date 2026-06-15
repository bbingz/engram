// macos/Engram/Views/Pages/SkillsView.swift
import AppKit
import SwiftUI

struct SkillsView: View {
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var skills: [EngramServiceSkillInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var error: String? = nil

    private var filteredSkills: [EngramServiceSkillInfo] {
        if searchText.isEmpty { return skills }
        let q = searchText.lowercased()
        return skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }
    private var globalSkills: [EngramServiceSkillInfo] { filteredSkills.filter { $0.scope == "global" } }
    private var pluginSkills: [EngramServiceSkillInfo] { filteredSkills.filter { $0.scope == "plugin" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField("Search skills...", text: $searchText).textFieldStyle(.plain)
                    Button { Task { await loadData() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                    .accessibilityIdentifier("skills_refresh")
                }
                .padding(10)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("skills_search")

                if let error { AlertBanner(message: error) }
                if isLoading && skills.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
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
        .refreshable { await loadData() }
        .task { await loadData() }
    }

    private func skillRow(_ skill: EngramServiceSkillInfo) -> some View {
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
        .contentShape(Rectangle())
        .contextMenu {
            Button { revealInFinder(skill.path) } label: { Label("Reveal in Finder", systemImage: "folder") }
        }
    }

    private func revealInFinder(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: "")
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { skills = try await serviceClient.skills() }
        catch { self.error = "Could not load skills: \(error.localizedDescription)" }
    }
}
