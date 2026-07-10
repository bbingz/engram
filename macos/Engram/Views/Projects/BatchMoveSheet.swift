// macos/Engram/Views/Projects/BatchMoveSheet.swift
//
// Minimal batch-move sheet. Takes the selected project names, reverse-
// resolves each project's recorded cwd, and lets the user edit ONE
// destination path per project. Builds the JSON body the batch handler
// parses and calls projectMoveBatch.
//
// DRY-RUN CONTRACT: the batch service handler IGNORES the request-level
// dryRun field (EngramServiceCommandHandler+ProjectMigration runs
// Batch.run with dryRun: doc.defaults.dryRun, parsed only from the JSON
// body's defaults.dry_run). So Preview MUST carry defaults.dry_run=true in
// the body; Commit omits it. Relying on the request field would silently
// commit real moves during Preview.

import SwiftUI

/// One editable batch-move row: a project and its resolved cwd (nil when
/// the project has no recorded path — that row is skipped, not moved).
struct BatchMoveRow: Identifiable {
    let project: String
    let cwd: String?
    var newPath: String
    var id: String { project }
}

/// Parsed counts from the snake_case batch response (encodeBatchResult).
struct BatchMoveOutcome: Equatable {
    var completed: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
    /// Ops not started after cooperative cancel (Wave 7C M05).
    var remaining: Int = 0
    var cancelled: Bool = false
    var cancelUnsafe: Bool = false
    var cancelErrorName: String?
    var cancelErrorMessage: String?
    var failures: [(src: String, error: String)] = []

    static func == (lhs: BatchMoveOutcome, rhs: BatchMoveOutcome) -> Bool {
        lhs.completed == rhs.completed
            && lhs.failed == rhs.failed
            && lhs.skipped == rhs.skipped
            && lhs.remaining == rhs.remaining
            && lhs.cancelled == rhs.cancelled
            && lhs.cancelUnsafe == rhs.cancelUnsafe
            && lhs.cancelErrorName == rhs.cancelErrorName
            && lhs.cancelErrorMessage == rhs.cancelErrorMessage
            && lhs.failures.map(\.src) == rhs.failures.map(\.src)
            && lhs.failures.map(\.error) == rhs.failures.map(\.error)
    }
}

enum BatchMoveBody {
    /// Build the JSON body the batch handler parses. `dryRun == true`
    /// emits defaults.dry_run:true (Preview); `dryRun == false` omits the
    /// dry_run flag entirely (Commit). Each operation is {src,dst}.
    static func make(operations: [(src: String, dst: String)], dryRun: Bool) -> String {
        var defaults: [String: EngramServiceJSONValue] = [:]
        if dryRun {
            defaults["dry_run"] = .bool(true)
        }
        let ops: [EngramServiceJSONValue] = operations.map { op in
            .object(["src": .string(op.src), "dst": .string(op.dst)])
        }
        let root: EngramServiceJSONValue = .object([
            "version": .number(1),
            "defaults": .object(defaults),
            "operations": .array(ops),
        ])
        guard let data = try? JSONEncoder().encode(root),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// Resume must re-issue the *same* dry-run identity that minted the operationId.
/// Preview YAML fingerprints include `defaults.dry_run`; Commit omits it.
enum BatchMoveResumeIdentity {
    /// When resuming an unresolved long-op, use the saved dry-run mode; otherwise
    /// the button-requested mode.
    static func effectiveDryRun(
        isResume: Bool,
        requestedDryRun: Bool,
        savedDryRun: Bool?
    ) -> Bool {
        if isResume, let savedDryRun {
            return savedDryRun
        }
        return requestedDryRun
    }

    /// Fresh Preview may reset session identity; Resume must not.
    static func shouldResetSessionForPreview(
        isResume: Bool,
        effectiveDryRun: Bool
    ) -> Bool {
        !isResume && effectiveDryRun
    }
}

/// Hand-pattern-match the bare EngramServiceJSONValue (no accessors) into
/// completed/failed/skipped counts and failed src+error lines.
func parseBatchMoveOutcome(_ value: EngramServiceJSONValue) -> BatchMoveOutcome {
    var outcome = BatchMoveOutcome()
    guard case .object(let root) = value else { return outcome }
    if case .array(let items)? = root["completed"] { outcome.completed = items.count }
    if case .array(let items)? = root["skipped"] { outcome.skipped = items.count }
    if case .array(let items)? = root["remaining"] { outcome.remaining = items.count }
    if case .bool(let cancelled)? = root["cancelled"] { outcome.cancelled = cancelled }
    if case .bool(let unsafe)? = root["cancel_unsafe"] { outcome.cancelUnsafe = unsafe }
    if case .string(let name)? = root["cancel_error_name"] { outcome.cancelErrorName = name }
    if case .string(let message)? = root["cancel_error_message"] { outcome.cancelErrorMessage = message }
    if case .array(let items)? = root["failed"] {
        outcome.failed = items.count
        for item in items {
            guard case .object(let entry) = item else { continue }
            var src = ""
            var message = ""
            if case .string(let s)? = entry["src"] { src = s }
            if case .string(let e)? = entry["error"] { message = e }
            outcome.failures.append((src: src, error: message))
        }
    }
    return outcome
}

struct BatchMoveSheet: View {
    let projects: [String]
    @Environment(EngramServiceClient.self) var serviceClient
    @Environment(\.dismiss) var dismiss

    @State private var rows: [BatchMoveRow] = []
    @State private var isLoadingCwds = true
    @State private var isExecuting = false
    @State private var outcome: BatchMoveOutcome?
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?
    @State private var longOpSession = ProjectLongOperationSession()
    @State private var isReconnecting = false
    /// Dry-run mode that minted the current unresolved operationId (Preview vs Commit).
    @State private var unresolvedRequestIsDryRun: Bool?

    /// Rows that actually have a destination to move (recorded cwd present).
    private var movableOperations: [(src: String, dst: String)] {
        rows.compactMap { row in
            guard let cwd = row.cwd else { return nil }
            let dst = row.newPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dst.isEmpty, dst != cwd else { return nil }
            return (src: cwd, dst: dst)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Selected Projects")
                .font(.headline)
            Text("\(projects.count) project(s) selected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if !nativeProjectMigrationCommandsEnabled {
                Label(nativeProjectMigrationUnavailableMessage, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else if isLoadingCwds {
                ProgressView("Looking up project paths…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($rows) { $row in
                            rowView($row)
                        }
                    }
                }
                .frame(maxHeight: 280)

                if isExecuting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(
                            isReconnecting
                                ? projectMoveReconnectingMessage()
                                : "Moving \(movableOperations.count) project(s)…"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let outcome {
                    outcomeBox(outcome)
                }
                if let errorMessage {
                    AlertBanner(message: errorMessage)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    if isExecuting || longOpSession.blocksDuplicateSubmit,
                       let operationId = longOpSession.operationId
                    {
                        // Explicit cooperative cancel only — never cancel await task.
                        Task {
                            _ = try? await serviceClient.cancelProjectMoveBatch(operationId: operationId)
                        }
                    } else {
                        longOpSession.reset()
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button("Preview") {
                    activeTask = Task { await run(dryRun: true) }
                }
                .disabled(isExecuting || movableOperations.isEmpty || longOpSession.blocksDuplicateSubmit)
                if longOpSession.blocksDuplicateSubmit && !isExecuting {
                    Button("Resume / Check Status") {
                        // Re-issue original dry-run identity (Preview stays Preview).
                        let resumeDryRun = unresolvedRequestIsDryRun ?? false
                        activeTask = Task { await run(dryRun: resumeDryRun) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Move") {
                        activeTask = Task { await run(dryRun: false) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isExecuting || movableOperations.isEmpty || longOpSession.blocksDuplicateSubmit)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(isExecuting)
        .task {
            guard nativeProjectMigrationCommandsEnabled else { return }
            await loadCwds()
        }
        .onDisappear {
            // Never cancel an in-flight migration await — Cancel uses cooperative
            // service cancel only; tearing down the client task would look like
            // peer disconnect and discard partial/reconnect results.
            guard !isExecuting else { return }
            activeTask?.cancel()
        }
    }

    @ViewBuilder
    private func rowView(_ row: Binding<BatchMoveRow>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.wrappedValue.project)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if row.wrappedValue.cwd == nil {
                Label("no recorded path — skipped", systemImage: "questionmark.folder")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                TextField("/absolute/path/to/new/location", text: row.newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .disabled(isExecuting || longOpSession.blocksDuplicateSubmit)
            }
        }
    }

    @ViewBuilder
    private func outcomeBox(_ outcome: BatchMoveOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Precise wording: cancelled ⇒ remaining ops never started (or
            // stopped before that op's commit). completed stay committed.
            let cancelPart: String = {
                if outcome.cancelled {
                    if outcome.remaining > 0 {
                        return " · \(outcome.remaining) remaining (cancelled before commit; completed stay committed)"
                    }
                    return " · cancelled before commit"
                }
                if outcome.remaining > 0 {
                    return " · \(outcome.remaining) remaining"
                }
                return ""
            }()
            Text("\(outcome.completed) completed · \(outcome.failed) failed · \(outcome.skipped) skipped\(cancelPart)")
                .font(.caption.weight(.medium))
            ForEach(Array(outcome.failures.enumerated()), id: \.offset) { _, failure in
                Text("• \(failure.src): \(failure.error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }

    private func loadCwds() async {
        isLoadingCwds = true
        defer { isLoadingCwds = false }
        var built: [BatchMoveRow] = []
        for project in projects {
            let cwd: String?
            do {
                cwd = try await serviceClient.projectCwds(project: project).cwds.first
            } catch {
                cwd = nil
            }
            built.append(BatchMoveRow(project: project, cwd: cwd, newPath: cwd ?? ""))
        }
        rows = built
    }

    private func run(dryRun: Bool) async {
        errorMessage = nil
        outcome = nil
        isReconnecting = false
        isExecuting = true
        defer {
            isExecuting = false
            isReconnecting = false
            activeTask = nil
        }
        let isResume = longOpSession.blocksDuplicateSubmit
        let effectiveDryRun = BatchMoveResumeIdentity.effectiveDryRun(
            isResume: isResume,
            requestedDryRun: dryRun,
            savedDryRun: unresolvedRequestIsDryRun
        )
        // Fresh Preview may mint a new id; Resume must keep the unresolved one.
        // Unconditional reset would destroy preview identity before resume.
        if BatchMoveResumeIdentity.shouldResetSessionForPreview(
            isResume: isResume,
            effectiveDryRun: effectiveDryRun
        ) {
            longOpSession.reset()
            unresolvedRequestIsDryRun = nil
        }
        let body = BatchMoveBody.make(operations: movableOperations, dryRun: effectiveDryRun)
        // Publish operationId to @State BEFORE any await so in-flight Cancel works.
        let prepared = ProjectLongOperationRunner.prepare(session: longOpSession)
        longOpSession = prepared.session
        isReconnecting = prepared.session.transientFailures > 0
        // Remember the request mode that minted this operationId for Resume.
        unresolvedRequestIsDryRun = effectiveDryRun
        let executeResult = await ProjectLongOperationRunner.execute(
            session: longOpSession,
            operationId: prepared.operationId,
            isReconnectable: projectMoveIsReconnectableError
        ) { operationId in
            try await serviceClient.projectMoveBatch(
                EngramServiceProjectMoveBatchRequest(
                    yaml: body,
                    dryRun: false,
                    force: false,
                    actor: "app",
                    operationId: operationId
                )
            )
        }
        longOpSession = executeResult.session
        isReconnecting = false
        switch executeResult.result {
        case .success(let result):
            // Terminal success: clear identity so Commit after Preview mints a new id.
            unresolvedRequestIsDryRun = nil
            let parsed = parseBatchMoveOutcome(result)
            outcome = parsed
            if parsed.cancelUnsafe {
                errorMessage = projectMoveCancelCompensationFailedMessage(
                    parsed.cancelErrorMessage ?? ""
                )
            }
            if !effectiveDryRun && parsed.failed == 0 && !parsed.cancelled && parsed.remaining == 0 {
                NotificationCenter.default.post(name: .projectsDidChange, object: nil)
                dismiss()
            }
        case .failure(let error):
            if longOpSession.blocksDuplicateSubmit {
                unresolvedRequestIsDryRun = effectiveDryRun
            } else {
                unresolvedRequestIsDryRun = nil
            }
            if projectMoveIsCancelCompensationFailure(error) {
                errorMessage = projectMoveCancelCompensationFailedMessage(
                    projectMoveErrorMessage(error)
                )
            } else {
                errorMessage = projectMoveErrorMessage(error)
                if longOpSession.blocksDuplicateSubmit {
                    errorMessage = (errorMessage ?? "") + "\n" + projectMoveResumeAvailableMessage()
                }
            }
        }
    }
}
