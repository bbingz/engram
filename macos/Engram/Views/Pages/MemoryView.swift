// macos/Engram/Views/Pages/MemoryView.swift
import SwiftUI

struct MemoryView: View {
    @EnvironmentObject var daemonClient: DaemonClient
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
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(hex: 0x6E7078))
                    TextField("Search memory files...", text: $searchText).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let error { AlertBanner(message: error) }

                if let selected = selectedFile {
                    HStack {
                        Button(action: { selectedFile = nil }) {
                            HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("All Memory") }
                                .font(.callout).foregroundStyle(Color(hex: 0x4A8FE7))
                        }.buttonStyle(.plain)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.name).font(.headline).foregroundStyle(.white)
                        Text(selected.project).font(.caption).foregroundStyle(Color(hex: 0x6E7078))
                        Divider().opacity(0.2)
                        Text(selected.preview)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color(hex: 0xA0A1A8))
                            .textSelection(.enabled)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.02))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ForEach(groupedByProject, id: \.project) { group in
                        SectionHeader(icon: "folder", title: group.project)
                        ForEach(group.files) { file in
                            Button(action: { selectedFile = file }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.callout).foregroundStyle(.white)
                                        Text(file.preview.prefix(80)).font(.caption).foregroundStyle(Color(hex: 0x6E7078)).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(formatSize(file.sizeBytes)).font(.caption).foregroundStyle(Color(hex: 0x6E7078))
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color(hex: 0x6E7078).opacity(0.5))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color.white.opacity(0.02))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.04), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                    if filteredFiles.isEmpty && !isLoading {
                        EmptyState(icon: "brain", title: "No memory files", message: "Memory files from ~/.claude/projects/ will appear here")
                    }
                }
            }
            .padding(24)
        }
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
