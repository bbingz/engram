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

                if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                        if retryPolicy != "never" {
                            Text("retry_policy: \(retryPolicy)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExecuting)
                Button("Archive") { Task { await runArchive() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        selectedCwd.isEmpty || isExecuting || availableCwds.isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await loadCwds() }
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
        isExecuting = true
        defer { isExecuting = false }
        do {
            let res = try await daemonClient.projectArchive(
                src: selectedCwd,
                archiveTo: category.isEmpty ? nil : category
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
