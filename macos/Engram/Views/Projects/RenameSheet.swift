// macos/Engram/Views/Projects/RenameSheet.swift
//
// Rename flow for a project. Reverse-looks up the cwd from the DB — if the
// project name maps to exactly one cwd, auto-select; if multiple, show a
// picker (rare but possible when two dirs share a basename); if none,
// disable because there's no physical path to move.
//
// Calls project move through EngramService. Shows a dry-run preview
// first so the user sees the impact (file count + residual warnings)
// before committing. On success, posts a .projectsDidChange notification
// that ProjectsView observes to refresh.

import SwiftUI

struct RenameSheet: View {
    let projectName: String
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

    @State private var availableCwds: [String] = []
    @State private var selectedCwd: String = ""
    @State private var newPath: String = ""
    @State private var isLoadingCwds = true
    @State private var isPreviewLoading = false
    @State private var isExecuting = false
    @State private var previewResult: EngramServiceProjectMoveResult?
    @State private var errorMessage: String?
    @State private var retryPolicy: String = "safe"
    @State private var activeTask: Task<Void, Never>?
    /// Populated when the migration committed but left residual old-path
    /// references in the user's own scope (review.own non-empty). Gemini
    /// follow-up high: previously the UI silently closed on any committed
    /// result even if the backend flagged these. Non-nil blocks auto-dismiss.
    @State private var residualRefCount: Int?
    /// Structured error details (Round 4): DirCollisionError / SharedEncoding
    /// carry sourceId + dir paths so the UI can show exactly which path
    /// conflicts instead of forcing users to parse the error message.
    @State private var errorDetails: ProjectMoveServiceErrorDetails?
    /// Round 4: keep the previous preview visible (dimmed) when the
    /// user edits the path, rather than hard-clearing it — the abrupt
    /// visual jump was called out as disorienting (Gemini Minor).
    @State private var previewStale: Bool = false

    /// Validate the new-path input before enabling Preview:
    ///   - non-empty after trimming whitespace
    ///   - not equal to the source (including after trimming)
    ///   - a selected cwd exists
    /// Gemini Important: previously only `newPath.isEmpty` was checked,
    /// so whitespace-only paths and src == dst strings reached the
    /// backend.
    private var isPathValid: Bool {
        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if selectedCwd.isEmpty { return false }
        if trimmed == selectedCwd { return false }
        if isPreviewLoading || isExecuting { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Project")
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
                    .accessibilityLabel("New project path")
                    .accessibilityHint("Enter the full destination path; ~/… is accepted.")

                if isPreviewLoading {
                    // Round 4 feedback: previously only the Preview button
                    // went disabled while the scan ran — users thought the
                    // UI was frozen. Inline spinner + explicit copy makes
                    // the async work visible.
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning sources for references…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if isExecuting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Renaming — patching files and renaming dirs…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let preview = previewResult, preview.state == "dry-run" {
                    previewBox(preview)
                        .opacity(previewStale ? 0.5 : 1.0)
                    if previewStale {
                        Text(
                            "Path changed — click Preview again to refresh these numbers."
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }

                if let error = errorMessage {
                    errorBox(error)
                }
                if let residual = residualRefCount, residual > 0 {
                    residualWarningBox(residual)
                }
            }

            Divider()

            HStack {
                Spacer()
                if !nativeProjectMigrationCommandsEnabled {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if residualRefCount != nil {
                    // Post-commit state: offer explicit dismiss so the user
                    // has to acknowledge the residual-refs warning.
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

                    if previewResult?.state != "dry-run" {
                        Button("Preview") {
                            activeTask = Task { await runPreview() }
                        }
                        // Round 4 Gemini Critical: Enter must trigger
                        // Preview in this state so users don't have to
                        // move their hand to the mouse after typing.
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isPathValid)
                    } else {
                        Button("Rename") {
                            activeTask = Task { await runRename() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        // Round 4: disable on (a) executing, (b) preview
                        // still in flight — prevents concurrent Task
                        // spawn (code-reviewer I4) — (c) stale preview
                        // after path edit, so user can't commit against
                        // numbers that no longer reflect the input.
                        .disabled(isExecuting || isPreviewLoading || previewStale)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        // Codex + Gemini: prevent interactive dismissal while an operation
        // is running — otherwise the user thinks they cancelled, but the
        // Task keeps writing to the FS + DB.
        .interactiveDismissDisabled(isExecuting || isPreviewLoading)
        .task {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await loadCwds()
        }
        .onDisappear { activeTask?.cancel() }
        // Round 4: instead of hard-clearing the preview (abrupt visual
        // jump), flag it stale and render dimmed with an inline notice.
        // Rename button also gates on `!previewStale` so the user can't
        // commit against a result that no longer matches the input.
        .onChange(of: newPath) { _, _ in
            if previewResult != nil { previewStale = true }
        }
        .onChange(of: selectedCwd) { _, _ in
            if previewResult != nil { previewStale = true }
        }
    }

    // MARK: - Preview / action subviews

    @ViewBuilder
    private func previewBox(_ preview: EngramServiceProjectMoveResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

            // Round 4 feedback: users couldn't see *which* files would be
            // patched — only an aggregate count. For a destructive op on
            // arbitrary session files, that trust gap is a blocker. Expose
            // the per-file breakdown behind a DisclosureGroup so the common
            // case stays compact but inspection is one click away.
            if let manifest = preview.manifest, !manifest.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(manifest) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(shortenFilePath(entry.path))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(entry.path)  // full path on hover
                                Spacer(minLength: 6)
                                Text(
                                    entry.occurrences == 0
                                        ? "skipped"
                                        : "\(entry.occurrences)×"
                                )
                                .font(.caption2)
                                .foregroundStyle(
                                    entry.occurrences == 0 ? .orange : .secondary
                                )
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show affected files (\(manifest.count))")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }

            if !preview.review.own.isEmpty {
                Text(
                    "⚠️ \(preview.review.own.count) residual own-scope ref(s) after patch — manual review may be needed"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            // Round 4 Critical: surface perSource.issues (too_large /
            // stat_failed) — previously silently dropped at decode, so
            // users saw "N files will be patched" with no hint that some
            // files failed to scan (EACCES, etc.).
            let totalIssues = (preview.perSource ?? []).reduce(0) {
                $0 + ($1.issues?.count ?? 0)
            }
            if totalIssues > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    Text("⚠️ \(totalIssues) file(s) could not be scanned")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(preview.perSource ?? []) { src in
                        if let issues = src.issues, !issues.isEmpty {
                            ForEach(issues) { issue in
                                HStack(spacing: 4) {
                                    Text(reasonLabel(issue.reason))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                    Text(shortenFilePath(issue.path))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(issue.detail ?? issue.path)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Round 4 Critical: surface skippedDirs so users know which
            // sources did not participate in the rename (iFlow lossy
            // encoding collapse, etc.) rather than assume all 7 sources
            // migrated successfully.
            if let skipped = preview.skippedDirs, !skipped.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ℹ️ \(skipped.count) source(s) not renamed")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                    ForEach(skipped) { s in
                        Text("• \(s.sourceId): \(skippedReasonLabel(s.reason))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func reasonLabel(_ r: String) -> String {
        switch r {
        case "too_large": return "too large"
        case "stat_failed": return "permission / read error"
        default: return r
        }
    }

    private func skippedReasonLabel(_ r: String) -> String {
        switch r {
        case "noop":
            return "no directory rename needed (content-only patch, or lossy encoding produced same name)"
        case "missing":
            return "no directory exists for this project at this source"
        default:
            return r
        }
    }

    /// Shorten `/Users/example/.codex/sessions/2026-04-20/abc123.jsonl` to
    /// `~/.codex/…/abc123.jsonl` so the list stays readable on a 480pt
    /// sheet. The full path is accessible via `.help()` (hover tooltip).
    private func shortenFilePath(_ abs: String) -> String {
        let home = NSHomeDirectory()
        var s = abs
        if s.hasPrefix(home) {
            s = "~" + s.dropFirst(home.count)
        }
        // Collapse deep middle segments for very long paths.
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count > 5 {
            let head = parts.prefix(2).joined(separator: "/")
            let tail = parts.suffix(2).joined(separator: "/")
            return "\(head)/…/\(tail)"
        }
        return s
    }

    @ViewBuilder
    private func residualWarningBox(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Rename committed, but \(count) file(s) in the project's own scope still reference the old path.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
            Text(
                "This usually means the auto-fix regex didn't cover an edge case. Run `engram project review <old> <new>` from the CLI to list the remaining files."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
            // Round 4: structured error details (DirCollisionError /
            // SharedEncodingCollisionError) expose sourceId + conflict
            // path so the user doesn't have to parse the prose message
            // to figure out which directory to move aside.
            if let details = errorDetails {
                errorDetailsView(details)
            }
            HStack {
                Text(retryPolicyExplainer(retryPolicy))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if retryPolicyAllowsRetry(retryPolicy) {
                    Button("Retry") {
                        activeTask = Task { await runRename() }
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

    @ViewBuilder
    private func errorDetailsView(_ details: ProjectMoveServiceErrorDetails) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let src = details.sourceId {
                HStack(spacing: 6) {
                    Text("Source:")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(src)
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            if let newDir = details.newDir {
                HStack(spacing: 6) {
                    Text("Conflict path:")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(newDir)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(newDir)
                        .textSelection(.enabled)
                }
            }
            if let cwds = details.sharingCwds, !cwds.isEmpty {
                Text("Shared with: \(cwds.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Actions

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

    private func runPreview() async {
        errorMessage = nil
        errorDetails = nil
        isPreviewLoading = true
        defer { isPreviewLoading = false; activeTask = nil }
        do {
            let res = try await serviceClient.projectMove(
                EngramServiceProjectMoveRequest(
                    src: selectedCwd,
                    dst: newPath,
                    dryRun: true,
                    force: false,
                    auditNote: nil,
                    actor: "app"
                )
            )
            if Task.isCancelled { return }
            previewResult = res
            previewStale = false
        } catch {
            if Task.isCancelled { return }
            errorMessage = projectMoveErrorMessage(error)
            retryPolicy = projectMoveRetryPolicy(error)
            errorDetails = projectMoveErrorDetails(error)
        }
    }

    private func runRename() async {
        errorMessage = nil
        errorDetails = nil
        residualRefCount = nil
        isExecuting = true
        defer { isExecuting = false; activeTask = nil }
        do {
            let res = try await serviceClient.projectMove(
                EngramServiceProjectMoveRequest(
                    src: selectedCwd,
                    dst: newPath,
                    dryRun: false,
                    force: false,
                    auditNote: nil,
                    actor: "app"
                )
            )
            if Task.isCancelled { return }
            if res.state == "committed" {
                // Gemini follow-up high: don't auto-dismiss if the backend
                // flagged residual own-scope refs. Swap Rename button for
                // a Close button so the user explicitly acknowledges the
                // warning before the sheet closes.
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

extension Notification.Name {
    static let projectsDidChange = Notification.Name("projectsDidChange")
}
