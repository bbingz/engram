// macos/Engram/Views/Projects/ArchiveSheet.swift
//
// Archive flow: move a project under _archive/<category>/ — the daemon
// auto-suggests the category via heuristic (YYYYMMDD- prefix, empty,
// .git + content) but the user can override.

import SwiftUI

struct ArchiveSheet: View {
    let projectName: String
    @Environment(DaemonClient.self) var daemonClient
    @Environment(\.dismiss) var dismiss

    @State private var availableCwds: [String] = []
    @State private var selectedCwd: String = ""
    @State private var category: String = ""  // empty = auto-suggest
    @State private var isLoadingCwds = true
    @State private var isExecuting = false
    @State private var errorMessage: String?
    @State private var retryPolicy: String = "safe"
    @State private var activeTask: Task<Void, Never>?
    @State private var residualRefCount: Int?
    @State private var errorDetails: ProjectMoveAPIError.Details?

    // English aliases match the MCP tool's canonical enum; labels in the
    // picker show the Chinese variants alongside for clarity.
    private let categoryOptions: [(value: String, label: String)] = [
        ("", "Auto-detect"),
        ("historical-scripts", "历史脚本 (historical-scripts)"),
        ("empty-project", "空项目 (empty-project)"),
        ("archived-done", "归档完成 (archived-done)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archive Project")
                .font(.headline)
            Text(projectName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if isLoadingCwds {
                ProgressView("Looking up project path…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if availableCwds.isEmpty {
                Label(
                    "This project has no recorded cwd — engram can't locate it on disk.",
                    systemImage: "questionmark.folder"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                if availableCwds.count > 1 {
                    Text("Source path (multiple cwds for this project):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedCwd) {
                        ForEach(availableCwds, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } else {
                    Text("Source path:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedCwd)
                        .font(.system(.caption, design: .monospaced))
                }

                Text("Archive category:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $category) {
                    ForEach(categoryOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(isExecuting)

                Text(
                    "Will move to ~/-Code-/_archive/<category>/\(projectName) (or similar)."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                if isExecuting {
                    // Round 4 feedback: no visible progress during the
                    // physical move + DB commit — user thought UI was
                    // frozen. Inline spinner mirrors RenameSheet.
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Archiving — moving files and updating index…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                // Gemini minor: users don't always realize archive =
                // physical file move. Any open editor / shell / build
                // running in the source dir will see the files vanish.
                Label(
                    "Archiving moves the physical directory. Active editors, shells, or builds in this path will break. Close them first.",
                    systemImage: "exclamationmark.bubble"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(8)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                        if let details = errorDetails {
                            if let src = details.sourceId {
                                Text("Source: \(src)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if let newDir = details.newDir {
                                Text("Conflict path: \(newDir)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(newDir)
                                    .textSelection(.enabled)
                            }
                        }
                        HStack {
                            Text(retryPolicyExplainer(retryPolicy))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if retryPolicyAllowsRetry(retryPolicy) {
                                Button("Retry") {
                                    activeTask = Task { await runArchive() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isExecuting)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let residual = residualRefCount, residual > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Archive committed, but \(residual) file(s) in the project's own scope still reference the old path.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .font(.caption)
                        Text("Run `engram project review` from the CLI to inspect.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            HStack {
                Spacer()
                if residualRefCount != nil {
                    Button("Close") {
                        NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isExecuting)
                    Button("Archive") {
                        activeTask = Task { await runArchive() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        selectedCwd.isEmpty || isExecuting || availableCwds.isEmpty
                    )
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(isExecuting)
        .task { await loadCwds() }
        .onDisappear { activeTask?.cancel() }
    }

    private func loadCwds() async {
        isLoadingCwds = true
        defer { isLoadingCwds = false }
        do {
            let cwds = try await daemonClient.projectCwds(forProject: projectName)
            availableCwds = cwds
            selectedCwd = cwds.first ?? ""
        } catch {
            errorMessage = "Failed to load project paths: \(error.localizedDescription)"
        }
    }

    private func runArchive() async {
        errorMessage = nil
        errorDetails = nil
        residualRefCount = nil
        isExecuting = true
        defer { isExecuting = false; activeTask = nil }
        do {
            let res = try await daemonClient.projectArchive(
                src: selectedCwd,
                archiveTo: category.isEmpty ? nil : category
            )
            if Task.isCancelled { return }
            if res.state == "committed" {
                if res.review.own.isEmpty {
                    NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                    dismiss()
                } else {
                    residualRefCount = res.review.own.count
                }
            } else {
                errorMessage = "Unexpected state: \(res.state)"
            }
        } catch let apiErr as ProjectMoveAPIError {
            if Task.isCancelled { return }
            errorMessage = apiErr.message
            retryPolicy = apiErr.retryPolicy
            errorDetails = apiErr.details
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            errorDetails = nil
        }
    }
}
