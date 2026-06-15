// macos/Engram/Views/Pages/MemoryView.swift
import SwiftUI

struct MemoryView: View {
    @Environment(EngramServiceClient.self) var serviceClient
    @State private var memoryFiles: [EngramServiceMemoryFile] = []
    @State private var insights: [EngramServiceInsightInfo] = []
    @State private var searchText = ""
    @State private var selectedFile: EngramServiceMemoryFile? = nil
    @State private var selectedInsight: EngramServiceInsightInfo? = nil
    // Detail-on-demand: list rows carry only a preview, so the full body is
    // fetched off-main when a row is selected. nil while loading.
    @State private var selectedFileContent: String? = nil
    @State private var selectedInsightDetail: EngramServiceInsightInfo? = nil
    @State private var isDetailLoading = false
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var showNewInsight = false

    /// Detail text for a memory file: full content when present, otherwise the
    /// short preview (older/leaner service payloads omit `content`).
    static func detailText(for file: EngramServiceMemoryFile) -> String {
        file.content ?? file.preview
    }

    /// Mirror of the service-side guard (content must be >= 10 trimmed chars)
    /// so the Save button disables before any round-trip rejection.
    static func insightContentIsValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    /// Importance range the New Insight stepper exposes. Capped at 5 because the
    /// service-side `normalizedImportance` only accepts 0...5 — values above 5
    /// always failed the round-trip.
    static let insightImportanceRange: ClosedRange<Int> = 1...5

    private var filteredFiles: [EngramServiceMemoryFile] {
        if searchText.isEmpty { return memoryFiles }
        let q = searchText.lowercased()
        return memoryFiles.filter { $0.name.lowercased().contains(q) || $0.project.lowercased().contains(q) || $0.preview.lowercased().contains(q) }
    }

    private var groupedByProject: [(project: String, files: [EngramServiceMemoryFile])] {
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
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .accessibilityIdentifier("memory_search")

                if let error { AlertBanner(message: error) }

                if isLoading && memoryFiles.isEmpty && insights.isEmpty {
                    ProgressView("Loading memory…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("memory_loading")
                } else if let selected = selectedFile {
                    fileDetail(selected)
                } else {
                    insightsSection
                    filesSection
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("memory_container")
        .task { await loadData() }
        .sheet(isPresented: $showNewInsight) {
            NewInsightSheet(onSave: { content, importance in
                await saveInsight(content: content, importance: importance)
            })
        }
    }

    /// Save an insight. Returns `nil` on success (caller dismisses the sheet) or
    /// an error message to surface inside the still-open sheet on failure.
    private func saveInsight(content: String, importance: Int) async -> String? {
        do {
            _ = try await serviceClient.saveInsight(.init(
                content: content,
                wing: nil,
                room: nil,
                importance: Double(importance),
                sourceSessionId: nil,
                actor: "app"
            ))
            await loadData()
            return nil
        } catch {
            return "Could not save insight: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        SectionHeader(
            icon: "lightbulb",
            title: "Insights",
            onRefresh: { Task { await loadData() } },
            trailingAction: (label: "New Insight", action: { showNewInsight = true })
        )
        if insights.isEmpty {
            EmptyState(icon: "lightbulb", title: "No insights yet", message: "Save insights via save_insight or the New Insight button")
                .accessibilityIdentifier("memory_insights_emptyState")
        } else if let selected = selectedInsight {
            HStack {
                Button(action: { selectedInsight = nil; selectedInsightDetail = nil }) {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("All Insights") }
                        .font(.callout).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
                Spacer()
            }
            if isDetailLoading && selectedInsightDetail == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .accessibilityIdentifier("memory_insight_detail_loading")
            }
            // Render the fetched full insight when available; fall back to the
            // preview row so the body never goes blank.
            InsightDetailView(
                insight: selectedInsightDetail ?? selected,
                onDelete: { Task { await deleteInsight(selected) } }
            )
            .task(id: selected.id) { await loadInsightDetail(selected) }
        } else {
            ForEach(insights) { insight in
                Button(action: { selectedInsight = insight }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.content).font(.callout).foregroundStyle(Theme.primaryText).lineLimit(2)
                            Text(insightCaption(insight)).font(.caption).foregroundStyle(Theme.tertiaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.tertiaryText.opacity(0.5))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { Task { await deleteInsight(insight) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var filesSection: some View {
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
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                }.buttonStyle(.plain)
            }
        }
        if filteredFiles.isEmpty {
            EmptyState(icon: "brain", title: "No memory files", message: "Memory files from ~/.claude/projects/ will appear here")
                .accessibilityIdentifier("memory_emptyState")
        }
    }

    @ViewBuilder
    private func fileDetail(_ selected: EngramServiceMemoryFile) -> some View {
        HStack {
            Button(action: { selectedFile = nil; selectedFileContent = nil }) {
                HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("All Memory") }
                    .font(.callout).foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
            Spacer()
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(selected.name).font(.headline).foregroundStyle(Theme.primaryText)
            Text(selected.project).font(.caption).foregroundStyle(Theme.tertiaryText)
            Divider().opacity(0.2)
            if isDetailLoading && selectedFileContent == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("memory_file_detail_loading")
            } else {
                // Fetched full content when available, otherwise the preview the
                // list row carried.
                Text(selectedFileContent ?? Self.detailText(for: selected))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: selected.path) { await loadFileContent(selected) }
    }

    private func insightCaption(_ insight: EngramServiceInsightInfo) -> String {
        var parts: [String] = []
        if let wing = insight.wing, !wing.isEmpty { parts.append(wing) }
        parts.append("importance \(insight.importance)")
        return parts.joined(separator: " · ")
    }

    private func loadData() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let files = serviceClient.memoryFiles()
            async let rows = serviceClient.insights()
            memoryFiles = try await files
            insights = try await rows
        } catch {
            self.error = "Could not load memory: \(error.localizedDescription)"
        }
    }

    /// Fetch a memory file's full content on demand (list rows carry only a
    /// preview). Falls back to the preview on failure so the body never blanks.
    private func loadFileContent(_ file: EngramServiceMemoryFile) async {
        selectedFileContent = nil
        isDetailLoading = true
        defer { isDetailLoading = false }
        do {
            let response = try await serviceClient.memoryFileContent(path: file.path)
            // Guard against a stale fetch landing after the user navigated away.
            guard selectedFile?.path == file.path else { return }
            selectedFileContent = response.content
        } catch {
            guard selectedFile?.path == file.path else { return }
            selectedFileContent = Self.detailText(for: file)
        }
    }

    /// Fetch an insight's full content on demand (list rows carry only a
    /// truncated preview).
    private func loadInsightDetail(_ insight: EngramServiceInsightInfo) async {
        selectedInsightDetail = nil
        isDetailLoading = true
        defer { isDetailLoading = false }
        do {
            let detail = try await serviceClient.insightDetail(id: insight.id)
            guard selectedInsight?.id == insight.id else { return }
            selectedInsightDetail = detail ?? insight
        } catch {
            guard selectedInsight?.id == insight.id else { return }
            selectedInsightDetail = insight
        }
    }

    private func deleteInsight(_ insight: EngramServiceInsightInfo) async {
        do {
            _ = try await serviceClient.deleteInsight(.init(id: insight.id))
            if selectedInsight?.id == insight.id { selectedInsight = nil }
            await loadData()
        } catch {
            self.error = "Could not delete insight: \(error.localizedDescription)"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

private struct NewInsightSheet: View {
    /// Returns `nil` on success (the sheet dismisses) or an error message to
    /// render in-place so a failed save isn't silently hidden behind the sheet.
    let onSave: (String, Int) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var importance = 5
    @State private var isSaving = false
    @State private var saveError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Insight").font(.headline).foregroundStyle(Theme.primaryText)
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).stroke(Theme.border, lineWidth: 1))
                .accessibilityIdentifier("new_insight_content")
            // Backend `normalizedImportance` accepts only 0...5, so cap the
            // stepper at 1...5 (default 5) — values above 5 always failed.
            Stepper("Importance: \(importance)", value: $importance, in: MemoryView.insightImportanceRange)
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("new_insight_error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain)
                Button("Save") {
                    isSaving = true
                    saveError = nil
                    Task {
                        let error = await onSave(content.trimmingCharacters(in: .whitespacesAndNewlines), importance)
                        isSaving = false
                        if let error {
                            saveError = error
                        } else {
                            dismiss()
                        }
                    }
                }
                .disabled(isSaving || !MemoryView.insightContentIsValid(content))
                .accessibilityIdentifier("new_insight_save")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
