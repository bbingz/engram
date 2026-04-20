// macos/Engram/Views/Projects/RenameSheet.swift
//
// Rename flow for a project. Reverse-looks up the cwd from the DB — if the
// project name maps to exactly one cwd, auto-select; if multiple, show a
// picker (rare but possible when two dirs share a basename); if none,
// disable because there's no physical path to move.
//
// Calls POST /api/project/move via DaemonClient. Shows a dry-run preview
// first so the user sees the impact (file count + residual warnings)
// before committing. On success, posts a .projectsDidChange notification
// that ProjectsView observes to refresh.

import SwiftUI

struct RenameSheet: View {
    let projectName: String
    @Environment(DaemonClient.self) var daemonClient
    @Environment(\.dismiss) var dismiss

    @State private var availableCwds: [String] = []
    @State private var selectedCwd: String = ""
    @State private var newPath: String = ""
    @State private var isLoadingCwds = true
    @State private var isPreviewLoading = false
    @State private var isExecuting = false
    @State private var previewResult: ProjectMoveResult?
    @State private var errorMessage: String?
    @State private var retryPolicy: String = "safe"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Project")
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
                    "This project has no recorded cwd — engram can't locate it on disk. Use `engram project move` from the CLI with an explicit path.",
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
                        .foregroundStyle(.primary)
                }

                Text("New path:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/absolute/path/to/new/location", text: $newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isExecuting)

                if let preview = previewResult, preview.state == "dry-run" {
                    previewBox(preview)
                }

                if let error = errorMessage {
                    errorBox(error)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExecuting)

                if previewResult?.state != "dry-run" {
                    Button("Preview") { Task { await runPreview() } }
                        .disabled(
                            newPath.isEmpty
                                || selectedCwd.isEmpty
                                || isPreviewLoading
                                || isExecuting
                        )
                } else {
                    Button("Rename") { Task { await runRename() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(isExecuting)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await loadCwds() }
    }

    // MARK: - Preview / action subviews

    @ViewBuilder
    private func previewBox(_ preview: ProjectMoveResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                Text("Dry-run impact")
                    .font(.caption.weight(.medium))
            }
            Text(
                "\(preview.totalFilesPatched) file(s) will be patched · \(preview.totalOccurrences) occurrence(s)"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !preview.review.own.isEmpty {
                Text(
                    "⚠️ \(preview.review.own.count) residual own-scope ref(s) after patch — manual review may be needed"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
            if retryPolicy != "never" {
                Text(
                    "retry_policy: \(retryPolicy) — you can retry after resolving the cause."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

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

    private func runPreview() async {
        errorMessage = nil
        isPreviewLoading = true
        defer { isPreviewLoading = false }
        do {
            let res = try await daemonClient.projectMove(
                src: selectedCwd,
                dst: newPath,
                dryRun: true,
                force: false
            )
            previewResult = res
        } catch let apiErr as ProjectMoveAPIError {
            errorMessage = apiErr.message
            retryPolicy = apiErr.retryPolicy
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runRename() async {
        errorMessage = nil
        isExecuting = true
        defer { isExecuting = false }
        do {
            let res = try await daemonClient.projectMove(
                src: selectedCwd,
                dst: newPath,
                dryRun: false,
                force: false
            )
            if res.state == "committed" {
                NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                dismiss()
            } else {
                errorMessage = "Unexpected state: \(res.state)"
            }
        } catch let apiErr as ProjectMoveAPIError {
            errorMessage = apiErr.message
            retryPolicy = apiErr.retryPolicy
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let projectsDidChange = Notification.Name("projectsDidChange")
}
