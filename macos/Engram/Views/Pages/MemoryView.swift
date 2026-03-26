// macos/Engram/Views/Pages/MemoryView.swift
import SwiftUI

struct MemoryView: View {
    @Environment(DaemonClient.self) var daemonClient
    @State private var memoryFiles: [MemoryFile] = []
    @State private var searchText = ""
    @State private var selectedFile: MemoryFile? = nil
    @State private var isLoading = true
    @State private var error: String? = nil

    private var filteredFiles: [MemoryFile] {
        if searchText.isEmpty { return memoryFiles }
        let q = searchText.lowercased()
        return memoryFiles.filter { $0.name.lowercased().contains(q) || $0.project.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
    }

    private var groupedByProject: [(project: String, files: [MemoryFile])] {
        let grouped = Dictionary(grouping: filteredFiles) { $0.project }
        return grouped.sorted { $0.key < $1.key }.map { (project: $0.key, files: $0.value) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField("Search memory files...", text: $searchText).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("memory_search")

                if let error { AlertBanner(message: error) }

                if let selected = selectedFile {
                    HStack {
                        Button(action: { selectedFile = nil }) {
                            HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("All Memory") }
                                .font(.callout).foregroundStyle(Theme.accent)
                        }.buttonStyle(.plain)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.name).font(.headline).foregroundStyle(Theme.primaryText)
                        Text(selected.project).font(.caption).foregroundStyle(Theme.tertiaryText)
                        Divider().opacity(0.2)
                        Text(selected.preview)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ForEach(groupedByProject, id: \.project) { group in
                        SectionHeader(icon: "folder", title: group.project)
                        ForEach(group.files) { file in
                            Button(action: { selectedFile = file }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.callout).foregroundStyle(Theme.primaryText)
                                        Text(file.preview.prefix(80)).font(.caption).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(formatSize(file.sizeBytes)).font(.caption).foregroundStyle(Theme.tertiaryText)
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.tertiaryText.opacity(0.5))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.surface)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                    if filteredFiles.isEmpty && !isLoading {
                        EmptyState(icon: "brain", title: "No memory files", message: "Memory files from ~/.claude/projects/ will appear here")
                            .accessibilityIdentifier("memory_emptyState")
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("memory_container")
        .task { await loadData() }
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do { memoryFiles = try await daemonClient.fetch("/api/memory") }
        catch { self.error = "Could not load memory: \(error.localizedDescription)" }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}
