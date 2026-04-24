// macos/Engram/Views/Projects/ArchiveSheet.swift
//
// Archive flow: move a project under _archive/<category>/ — the daemon
// auto-suggests the category via heuristic (YYYYMMDD- prefix, empty,
// .git + content) but the user can override.

import SwiftUI

struct ArchiveSheet: View {
    let projectName: String
    @Environment(EngramServiceClient.self) var serviceClient
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
    @State private var errorDetails: ProjectMoveServiceErrorDetails?
    @State private var showConfirmDialog: Bool = false

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

            if !nativeProjectMigrationCommandsEnabled {
                Label(nativeProjectMigrationUnavailableMessage, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if isLoadingCwds {
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

                // Round 4 Gemini Minor: previously hardcoded ~/-Code-/_archive/
                // which is wrong for any user whose projects live elsewhere.
                // The actual destination is the src's parent joined with
                // _archive/<category>/<basename> — show that so the user
                // can verify.
                Text("Will move to \(previewArchiveDst()) (or similar).")
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
                if !nativeProjectMigrationCommandsEnabled {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if residualRefCount != nil {
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
                    // Round 4 Gemini Critical: Archive physically moves
                    // the project dir. Any editor/shell/build attached
                    // to the old path will break on next fs access. The
                    // Archive button now triggers a confirmationDialog;
                    // the actual work only starts after explicit confirm.
                    Button("Archive") { showConfirmDialog = true }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            selectedCwd.isEmpty || isExecuting
                                || availableCwds.isEmpty
                        )
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(isExecuting)
        .task {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await loadCwds()
        }
        .onDisappear { activeTask?.cancel() }
        .confirmationDialog(
            "Archive project?",
            isPresented: $showConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("Archive to \(previewArchiveDst())", role: .destructive) {
                activeTask = Task { await runArchive() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This physically moves \(selectedCwd) to the _archive folder. "
                    + "Any editor, shell, or build running in that path will see "
                    + "files vanish mid-session. Close them first."
            )
        }
    }

    /// Build the "Will move to …" preview string without hitting the
    /// backend — the rule is: <src's parent>/_archive/<category>/<basename>.
    /// Matches `suggestArchiveTarget` semantics for the default case;
    /// when category is "auto-detect", placeholder `<category>` is shown.
    private func previewArchiveDst() -> String {
        let src = selectedCwd.isEmpty ? "<source>" : selectedCwd
        let parent = (src as NSString).deletingLastPathComponent
        let base = (src as NSString).lastPathComponent
        let cat = category.isEmpty ? "<category>" : category
        let full = "\(parent)/_archive/\(cat)/\(base)"
        // Collapse $HOME to ~ for display.
        let home = NSHomeDirectory()
        if full.hasPrefix(home) {
            return "~" + full.dropFirst(home.count)
        }
        return full
    }

    private func loadCwds() async {
        isLoadingCwds = true
        defer { isLoadingCwds = false }
        do {
            let response = try await serviceClient.projectCwds(project: projectName)
            availableCwds = response.cwds
            selectedCwd = response.cwds.first ?? ""
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
            let res = try await serviceClient.projectArchive(
                EngramServiceProjectArchiveRequest(
                    src: selectedCwd,
                    archiveTo: category.isEmpty ? nil : category,
                    dryRun: false,
                    force: false,
                    auditNote: nil,
                    actor: "app"
                )
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
        } catch {
            if Task.isCancelled { return }
            errorMessage = projectMoveErrorMessage(error)
            retryPolicy = projectMoveRetryPolicy(error)
            errorDetails = projectMoveErrorDetails(error)
        }
    }
}
