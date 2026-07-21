// macos/EngramCoreWrite/ProjectMove/Orchestrator.swift
// Mirrors src/core/project-move/orchestrator.ts (Node parity baseline).
//
// Wires Stage 1 (paths/encoding/git/lock/retry-policy), Stage 2 (fs-ops,
// jsonl-patch, gemini-projects-json), Stage 3 (sources, review) and the
// Stage 4.1 migration_log writer into a single transaction-with-compensation.
//
// Pipeline:
//   A. startMigration                    (state='fs_pending')
//   0. Git dirty check                   (CLI policy decision)
//   0.5 acquireLock                      (cross-process advisory lock)
//   1. safeMoveDir physical
//   2. Rename per-project dirs for each source that groups by project
//      (Claude Code = encoded cwd, Gemini = SHA-256 cwd, iFlow = iflow-encoded)
//   3. Scan all source roots → findReferencingFiles → patchFile (per-file CAS)
//   B. markFsDone                        (state='fs_done', detail = stats)
//   C. applyMigrationDb in transaction   (state='committed')
//   99. release lock; return PipelineResult
//
// Compensation: any FS step throwing reverses the work LIFO:
//   reverse-patch files → restore Gemini projects.json → reverse dir renames
//   → safeMoveDir dst→src back → failMigration → release lock.
import Foundation
import EngramCoreRead
import GRDB

// MARK: - errors

/// Pre-flight: target dir for a per-source rename already exists. Raised
/// BEFORE any physical FS change so the caller skips compensation.
public struct DirCollisionError: ProjectMoveError, Equatable {
    public let sourceId: SourceId
    public let oldDir: String
    public let newDir: String

    public init(sourceId: SourceId, oldDir: String, newDir: String) {
        self.sourceId = sourceId
        self.oldDir = oldDir
        self.newDir = newDir
    }

    public var errorName: String { "DirCollisionError" }
    public var errorMessage: String {
        "project-move: \(sourceId.rawValue) target dir already exists — \(newDir). " +
        "Another project is using that path; refusing to overwrite. " +
        "Move the target aside or merge sessions manually, then retry."
    }
    public var errorDetails: ErrorDetails? {
        ErrorDetails(sourceId: sourceId.rawValue, oldDir: oldDir, newDir: newDir)
    }
}

/// Pre-flight: a Gemini (or iFlow) per-project dir is shared across multiple
/// projects because the encoding isn't injective. Renaming would silently
/// steal sessions from the other project.
public struct SharedEncodingCollisionError: ProjectMoveError, Equatable {
    public let sourceId: SourceId
    public let dir: String
    public let sharingCwds: [String]

    public init(sourceId: SourceId, dir: String, sharingCwds: [String]) {
        self.sourceId = sourceId
        self.dir = dir
        self.sharingCwds = sharingCwds
    }

    public var errorName: String { "SharedEncodingCollisionError" }
    public var errorMessage: String {
        "project-move: \(sourceId.rawValue) dir \(dir) is shared with other projects " +
        "[\(sharingCwds.joined(separator: ", "))]. Renaming would steal their sessions. " +
        "Manually separate the dirs before retrying."
    }
    public var errorDetails: ErrorDetails? {
        ErrorDetails(sourceId: sourceId.rawValue, sharingCwds: sharingCwds)
    }
}

/// Cooperative cancel before the DB commit boundary (Wave 8 long-ops).
/// After a successful `beginCommitIfNotCancelled`, cancel is ignored.
/// When cancel runs after FS mutation, `compensationSucceeded` reports whether
/// rollback fully restored disk state (contract 3).
public struct ProjectMoveCancelledError: ProjectMoveError, Equatable {
    /// True when no residual FS damage remains (or never mutated FS).
    public let compensationSucceeded: Bool
    /// Human-readable compensation failure summary when `compensationSucceeded` is false.
    public let compensationDetail: String?

    public init(compensationSucceeded: Bool = true, compensationDetail: String? = nil) {
        self.compensationSucceeded = compensationSucceeded
        self.compensationDetail = compensationDetail
    }

    public var errorName: String {
        compensationSucceeded
            ? "ProjectMoveCancelledError"
            : "ProjectMoveCancelCompensationFailedError"
    }

    public var errorMessage: String {
        if compensationSucceeded {
            return "project-move: cancelled before commit boundary — no migration was committed"
        }
        let detail = compensationDetail ?? "compensation reported residual failures"
        return "project-move: cancelled before commit but compensation was incomplete — \(detail). Do not assume disk/index are clean; inspect Migration History before retrying."
    }

    public var errorDetails: ErrorDetails? {
        ErrorDetails(
            state: compensationSucceeded ? "cancelled" : "cancelled_compensation_failed"
        )
    }
}

public enum OrchestratorError: ProjectMoveError, Equatable {
    case missingPaths(src: String, dst: String)
    case sameSourceAndDest(path: String)
    case dstInsideSrc(src: String, dst: String)
    case srcInsideDst(src: String, dst: String)
    case gitDirty(src: String)
    case dirRenameFailed(sourceId: SourceId, oldDir: String, newDir: String, message: String)

    public var errorName: String {
        switch self {
        case .dirRenameFailed:
            "DirRenameFailedError"
        default:
            "OrchestratorError"
        }
    }

    public var errorMessage: String {
        switch self {
        case .missingPaths:
            "project-move: source and destination paths are required"
        case .sameSourceAndDest(let path):
            "project-move: source and destination are the same path — \(path)"
        case .dstInsideSrc(let src, let dst):
            "project-move: destination \(dst) is inside source \(src)"
        case .srcInsideDst(let src, let dst):
            "project-move: source \(src) is inside destination \(dst)"
        case .gitDirty(let src):
            "project-move: git worktree has tracked changes — \(src)"
        case .dirRenameFailed(let sourceId, let oldDir, let newDir, let message):
            "project-move: \(sourceId.rawValue) dir rename failed \(oldDir) -> \(newDir): \(message)"
        }
    }

    public var errorDetails: ErrorDetails? {
        switch self {
        case .dirRenameFailed(let sourceId, let oldDir, let newDir, _):
            ErrorDetails(sourceId: sourceId.rawValue, oldDir: oldDir, newDir: newDir)
        default:
            nil
        }
    }
}

// MARK: - input/output

public struct DirRenamePlan: Equatable, Sendable {
    public let sourceId: SourceId
    public let oldDir: String
    public let newDir: String
    public init(sourceId: SourceId, oldDir: String, newDir: String) {
        self.sourceId = sourceId
        self.oldDir = oldDir
        self.newDir = newDir
    }
}

public struct ManifestEntry: Equatable, Sendable {
    public let path: String
    public let occurrences: Int
    public let backupPath: String?
    public init(path: String, occurrences: Int, backupPath: String? = nil) {
        self.path = path
        self.occurrences = occurrences
        self.backupPath = backupPath
    }
}

public struct PerSourceStats: Equatable, Sendable {
    public let id: String
    public let root: String
    public let filesPatched: Int
    public let occurrences: Int
    public let issues: [WalkIssue]
    public init(id: String, root: String, filesPatched: Int, occurrences: Int, issues: [WalkIssue]) {
        self.id = id
        self.root = root
        self.filesPatched = filesPatched
        self.occurrences = occurrences
        self.issues = issues
    }
}

public enum SkippedDirReason: String, Equatable, Sendable { case noop, missing }

public struct SkippedDirEntry: Equatable, Sendable {
    public let sourceId: SourceId
    public let reason: SkippedDirReason
    public init(sourceId: SourceId, reason: SkippedDirReason) {
        self.sourceId = sourceId
        self.reason = reason
    }
}

public enum PipelineState: String, Equatable, Sendable {
    case committed, dryRun = "dry-run", failed, cancelled
}

public struct PipelineResult: Equatable, Sendable {
    public let migrationId: String
    public let state: PipelineState
    public let src: String
    public let dst: String
    public let moveStrategy: MoveResult.Strategy
    public let ccDirRenamed: Bool
    public let renamedDirs: [DirRenamePlan]
    public let skippedDirs: [SkippedDirEntry]
    public let perSource: [PerSourceStats]
    public let totalFilesPatched: Int
    public let totalOccurrences: Int
    public let sessionsUpdated: Int
    public let aliasCreated: Bool
    public let review: ReviewResult
    public let git: GitDirtyStatus
    public let manifest: [ManifestEntry]
    public let error: String?
}

public struct RunProjectMoveOptions: Sendable {
    public var src: String
    public var dst: String
    public var dryRun: Bool
    public var force: Bool
    public var archived: Bool
    public var auditNote: String?
    public var actor: MigrationLogActor
    public var homeDirectory: URL
    public var lockPath: String?
    public var rolledBackOf: String?
    /// Internal escape hatch for undo: the undo preflight and reverse move must
    /// share one project-move lock, so runUndo acquires it before validation
    /// and then invokes the normal pipeline without reacquiring.
    public var lockAlreadyHeld: Bool
    /// Cooperative cancel probe. Checked only before the commit boundary.
    public var shouldCancel: @Sendable () -> Bool
    /// Atomic transition into the non-interruptible commit sequence (Phase B/C).
    /// Return `false` if cancel already won; `true` commits cancel-immunity.
    /// Defaults to `{ !shouldCancel() }` when not supplied by the service.
    public var beginCommitIfNotCancelled: @Sendable () -> Bool
    /// Invoked after Phase C succeeds (optional bookkeeping; commit immunity is
    /// established by `beginCommitIfNotCancelled`).
    public var onPastCommit: (@Sendable () -> Void)?

    public init(
        src: String,
        dst: String,
        dryRun: Bool = false,
        force: Bool = false,
        archived: Bool = false,
        auditNote: String? = nil,
        actor: MigrationLogActor = .cli,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        lockPath: String? = nil,
        rolledBackOf: String? = nil,
        lockAlreadyHeld: Bool = false,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beginCommitIfNotCancelled: (@Sendable () -> Bool)? = nil,
        onPastCommit: (@Sendable () -> Void)? = nil
    ) {
        self.src = src
        self.dst = dst
        self.dryRun = dryRun
        self.force = force
        self.archived = archived
        self.auditNote = auditNote
        self.actor = actor
        self.homeDirectory = homeDirectory
        self.lockPath = lockPath
        self.rolledBackOf = rolledBackOf
        self.lockAlreadyHeld = lockAlreadyHeld
        self.shouldCancel = shouldCancel
        // Capture shouldCancel for the default atomic probe without retaining self.
        let cancelProbe = shouldCancel
        self.beginCommitIfNotCancelled = beginCommitIfNotCancelled ?? { !cancelProbe() }
        self.onPastCommit = onPastCommit
    }
}

public struct UndoProjectMoveRunResult: Sendable {
    public let reverse: ReverseMoveRequest
    public let pipelineResult: PipelineResult

    public init(reverse: ReverseMoveRequest, pipelineResult: PipelineResult) {
        self.reverse = reverse
        self.pipelineResult = pipelineResult
    }
}

// MARK: - main entry point

public enum ProjectMoveOrchestrator {
    public static func runUndo(
        writer: EngramDatabaseWriter,
        migrationId: String,
        force: Bool,
        actor: MigrationLogActor,
        lockPath requestedLockPath: String? = nil,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beginCommitIfNotCancelled: (@Sendable () -> Bool)? = nil,
        onPastCommit: (@Sendable () -> Void)? = nil
    ) async throws -> UndoProjectMoveRunResult {
        if shouldCancel() {
            throw ProjectMoveCancelledError()
        }
        let lockPath = requestedLockPath ?? MigrationLock.defaultLockPath()
        try MigrationLock.acquire(migrationId: "undo-\(migrationId)", lockPath: lockPath)
        defer { MigrationLock.release(lockPath: lockPath) }

        let reverse = try UndoMigration.prepareReverseRequest(
            migrationId: migrationId,
            log: GRDBMigrationLogReader(writer: writer),
            sessions: GRDBSessionByIdReader(writer: writer)
        )
        if shouldCancel() {
            throw ProjectMoveCancelledError()
        }
        let pipelineResult = try await run(
            writer: writer,
            options: RunProjectMoveOptions(
                src: reverse.src,
                dst: reverse.dst,
                dryRun: false,
                force: force,
                archived: false,
                auditNote: "undo of \(migrationId)",
                actor: actor,
                lockPath: lockPath,
                rolledBackOf: reverse.originalMigrationId,
                lockAlreadyHeld: true,
                shouldCancel: shouldCancel,
                beginCommitIfNotCancelled: beginCommitIfNotCancelled,
                onPastCommit: onPastCommit
            )
        )
        return UndoProjectMoveRunResult(reverse: reverse, pipelineResult: pipelineResult)
    }

    /// Run the full project-move pipeline. Throws on failure with the
    /// original error type preserved (`LockBusyError`, `DirCollisionError`,
    /// `ConcurrentModificationError`, etc.) so downstream classifiers
    /// (RetryPolicyClassifier) work unchanged. Compensation is best-effort
    /// — the migration_log row records both the primary error and any
    /// rollback failures in a single string.
    public static func run(
        writer: EngramDatabaseWriter,
        options: RunProjectMoveOptions
    ) async throws -> PipelineResult {
        guard !options.src.isEmpty, !options.dst.isEmpty else {
            throw OrchestratorError.missingPaths(src: options.src, dst: options.dst)
        }
        let src = canonicalizeExistingSource(options.src)
        let dst = canonicalize(options.dst)
        if src == dst {
            throw OrchestratorError.sameSourceAndDest(path: src)
        }
        if dst.hasPrefix(src + "/") {
            throw OrchestratorError.dstInsideSrc(src: src, dst: dst)
        }
        if src.hasPrefix(dst + "/") {
            throw OrchestratorError.srcInsideDst(src: src, dst: dst)
        }

        // Step 0: git dirty (mechanism only — caller decides policy)
        let git = await GitDirty.check(src)
        if git.dirty && !git.untrackedOnly && !options.force {
            throw OrchestratorError.gitDirty(src: src)
        }

        // Dry-run: read-only scan + plan, no FS or DB side effects.
        if options.dryRun {
            if options.shouldCancel() {
                throw ProjectMoveCancelledError()
            }
            return try buildDryRunPlan(
                src: src,
                dst: dst,
                git: git,
                homeDirectory: options.homeDirectory
            )
        }

        // Cancel before any lock/log write — nothing to compensate.
        if options.shouldCancel() {
            throw ProjectMoveCancelledError()
        }

        let migrationId = UUID().uuidString
        let oldBasename = basename(src)
        let newBasename = basename(dst)
        let lockPath = options.lockPath ?? MigrationLock.defaultLockPath()

        // Lock BEFORE startMigration: a LockBusyError must not leave a stale
        // fs_pending row. Undo may pre-acquire the same lock so its migration-log
        // preflight and reverse move are atomic with respect to other moves.
        if !options.lockAlreadyHeld {
            try MigrationLock.acquire(migrationId: migrationId, lockPath: lockPath)
        }
        // Release on EVERY exit path — including a throw from the Phase-A write
        // below, which sits outside the do/catch. The original code released
        // only on the success and catch paths, so a Phase-A failure leaked the
        // lock (holding the live service pid) and permanently wedged all future
        // project moves until a service restart.
        defer {
            if !options.lockAlreadyHeld {
                MigrationLock.release(lockPath: lockPath)
            }
        }

        // (SIGINT handler intentionally omitted in the Swift port — Engram
        // services run as launchd helpers without a controlling terminal.
        // cleanupStaleMigrations() at startup converts any abandoned
        // non-terminal rows to 'failed' after STALE_MIGRATION_THRESHOLD.)

        // Phase A: persist intent.
        try writer.write { db in
            try MigrationLogStore.startMigration(
                db,
                input: StartMigrationInput(
                    id: migrationId,
                    oldPath: src,
                    newPath: dst,
                    oldBasename: oldBasename,
                    newBasename: newBasename,
                    dryRun: false,
                    auditNote: options.auditNote,
                    archived: options.archived,
                    actor: options.actor,
                    rolledBackOf: options.rolledBackOf
                )
            )
        }

        var manifest: [ManifestEntry] = []
        var perSource: [PerSourceStats] = []
        var renamedDirs: [DirRenamePlan] = []
        var skippedDirs: [SkippedDirEntry] = []
        var moveStrategy: MoveResult.Strategy = .rename
        var physicalMoveApplied = false
        /// Dirfd-pinned archive parent provision (mkdirat-owned segments only).
        var destinationParentToken: DestinationParentToken?
        var geminiProjectsPlan: GeminiProjectsJsonUpdatePlan?
        var geminiProjectsApplied = false
        var sqlitePatches: [OpenCodeSQLitePatchResult] = []
        let patchBackupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-project-move-\(migrationId)-patch-backups", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: patchBackupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: patchBackupRoot) }

        do {
            // Cancel after intent row exists but before FS mutation.
            if options.shouldCancel() {
                throw ProjectMoveCancelledError()
            }

            let roots = SessionSources.roots(homeDirectory: options.homeDirectory)

            // Step 0.5: per-source rename plans. If session content proves the
            // old cwd lives under a different grouped dir, trust the observed
            // dir over the theoretical encoder to avoid orphaning history after
            // upstream encoder drift or older buggy migrations.
            var dirRenamePlans: [DirRenamePlan] = []
            for root in roots {
                guard let encode = root.encodeProjectDir else { continue }
                var oldName = encode(src)
                let newName = encode(dst)
                if root.id == .geminiCli {
                    let projectsFile = ((root.path as NSString)
                        .deletingLastPathComponent as NSString)
                        .appendingPathComponent("projects.json")
                    geminiProjectsPlan = try GeminiProjectsJSON.plan(
                        filePath: projectsFile,
                        oldCwd: src,
                        newCwd: dst
                    )
                    oldName = geminiProjectsPlan?.oldEntry?.name ?? oldName
                }
                let observedOldDirs = findGroupedDirsWithCwd(rootPath: root.path, cwd: src)
                let oldDirs = observedOldDirs.isEmpty
                    ? [(root.path as NSString).appendingPathComponent(oldName)]
                    : observedOldDirs
                for oldDir in oldDirs {
                    if basename(oldDir) == newName {
                        skippedDirs.append(SkippedDirEntry(sourceId: root.id, reason: .noop))
                        continue
                    }
                    dirRenamePlans.append(DirRenamePlan(
                        sourceId: root.id,
                        oldDir: oldDir,
                        newDir: (root.path as NSString).appendingPathComponent(newName)
                    ))
                }
            }

            // Steps 0.5–0.8: planned-target map + disk existence + Gemini/iFlow
            // shared-encoding probes. Shared with dry_run so plans fail the same way.
            try assertDirRenamePreflight(
                plans: dirRenamePlans,
                roots: roots,
                src: src,
                dst: dst
            )

            // Step 0.9: archive destinations live under `_archive/<category>/…`
            // which may not exist yet. Provision only when `archived` so plain
            // renames keep their historical "parent must already exist" behavior.
            // Dirfd-pinned token: only mkdirat==0 segments; cleanup via unlinkat.
            if options.archived {
                destinationParentToken = try DestinationParentProvision.ensure(
                    destinationPath: dst
                )
            }

            // Step 1: physical move
            let moveResult = try SafeMoveDir.run(src: src, dst: dst)
            physicalMoveApplied = true
            moveStrategy = moveResult.strategy

            // Step 2: rename per-source dirs (ENOENT = source has no record
            // for this project; any other error wraps with sourceId context).
            for plan in dirRenamePlans {
                do {
                    try moveItemRespectingExisting(plan.oldDir, to: plan.newDir)
                    renamedDirs.append(plan)
                } catch CocoaError.fileNoSuchFile {
                    skippedDirs.append(SkippedDirEntry(sourceId: plan.sourceId, reason: .missing))
                } catch let err as NSError where err.domain == NSCocoaErrorDomain
                    && err.code == NSFileReadNoSuchFileError {
                    skippedDirs.append(SkippedDirEntry(sourceId: plan.sourceId, reason: .missing))
                } catch {
                    throw OrchestratorError.dirRenameFailed(
                        sourceId: plan.sourceId,
                        oldDir: plan.oldDir,
                        newDir: plan.newDir,
                        message: renameFailureMessage(error)
                    )
                }
            }
            let ccDirRenamed = renamedDirs.contains { $0.sourceId == .claudeCode }

            // Step 2.5: apply Gemini projects.json rewrite (after the dir
            // rename). A no-op source-specific project name can skip the
            // directory rename while still needing the registry key rewritten.
            let geminiDirTouched = renamedDirs.contains { $0.sourceId == .geminiCli }
                || skippedDirs.contains { $0.sourceId == .geminiCli && $0.reason == .noop }
            if let plan = geminiProjectsPlan,
               plan.oldEntry != nil || geminiDirTouched {
                try GeminiProjectsJSON.apply(plan: plan)
                geminiProjectsApplied = true
            }

            // Step 3: patch JSONL across all sources. Bounded concurrency to
            // avoid file-descriptor cliffs on very large session stores.
            let patchConcurrency = 50
            var totalFilesPatched = 0
            var totalOccurrences = 0
            for root in roots {
                var issues: [WalkIssue] = []
                let hits = SessionSources.findReferencingFiles(root: root.path, needle: src)
                let remapped = hits.map { file -> String in
                    for d in renamedDirs where file.hasPrefix(d.oldDir + "/") {
                        return d.newDir + String(file.dropFirst(d.oldDir.count))
                    }
                    return file
                }
                let perFile = await runWithConcurrency(items: remapped, limit: patchConcurrency) { file in
                    do {
                        let backupPath = try backupPatchInput(file: file, backupRoot: patchBackupRoot)
                        let count = try JsonlPatch.patchFile(at: file, oldPath: src, newPath: dst)
                        if count == 0 {
                            try? FileManager.default.removeItem(atPath: backupPath)
                        }
                        return PatchOutcome(file: file, count: count, backupPath: count > 0 ? backupPath : nil, error: nil)
                    } catch {
                        return PatchOutcome(file: file, count: 0, backupPath: nil, error: error)
                    }
                }
                var filesPatched = 0
                var occurrences = 0
                // First pass: record EVERY successful patch in the manifest so
                // compensation can revert all physical writes, regardless of
                // where a hard error sits in the result order. The original
                // single pass threw on the first hard error before recording a
                // success at a later index, leaving that file rewritten but
                // unreverted on rollback (silent corruption).
                for r in perFile where r.error == nil && r.count > 0 {
                    manifest.append(ManifestEntry(path: r.file, occurrences: r.count, backupPath: r.backupPath))
                    filesPatched += 1
                    occurrences += r.count
                }
                // Second pass: surface hard errors only after the manifest
                // covers every successful patch.
                for r in perFile {
                    guard let err = r.error else { continue }
                    // Hard errors mean we cannot guarantee the file was
                    // patched correctly — propagate so compensation runs.
                    if err is InvalidUtf8Error || err is ConcurrentModificationError {
                        throw err
                    }
                    issues.append(WalkIssue(
                        path: r.file,
                        reason: .statFailed,
                        detail: errorMessage(err)
                    ))
                }
                if root.id == .opencode {
                    do {
                        let sqlitePatch = try OpenCodeSQLiteProjectMove.patch(
                            root: root.path,
                            oldPath: src,
                            newPath: dst
                        )
                        if sqlitePatch.occurrences > 0 {
                            sqlitePatches.append(sqlitePatch)
                            filesPatched += 1
                            occurrences += sqlitePatch.occurrences
                        }
                    } catch {
                        throw error
                    }
                }
                perSource.append(PerSourceStats(
                    id: root.id.rawValue,
                    root: root.path,
                    filesPatched: filesPatched,
                    occurrences: occurrences,
                    issues: issues
                ))
                totalFilesPatched += filesPatched
                totalOccurrences += occurrences
            }

            // Atomic cancel/commit boundary (contract 1): either cancel wins
            // (no Phase B/C) or commit-started wins and later cancel is ignored.
            if !options.beginCommitIfNotCancelled() {
                throw ProjectMoveCancelledError()
            }

            // Phase B/C are non-interruptible once beginCommitIfNotCancelled returned true.
            let detail = buildFsDoneDetail(
                moveStrategy: moveStrategy,
                perSource: perSource,
                renamedDirs: renamedDirs,
                skippedDirs: skippedDirs,
                geminiProjectsApplied: geminiProjectsApplied,
                manifest: manifest
            )
            try writer.write { db in
                try MigrationLogStore.markFsDone(
                    db,
                    input: MarkFsDoneInput(
                        id: migrationId,
                        filesPatched: totalFilesPatched,
                        occurrences: totalOccurrences,
                        ccDirRenamed: ccDirRenamed,
                        detail: detail
                    )
                )
            }

            // Phase C: commit DB (sessions + local_state + alias + log).
            let dbResult: ApplyMigrationResult = try writer.write { db in
                try MigrationLogStore.applyMigrationDb(
                    db,
                    input: ApplyMigrationInput(
                        migrationId: migrationId,
                        oldPath: src,
                        newPath: dst,
                        oldBasename: oldBasename,
                        newBasename: newBasename
                    )
                )
            }

            options.onPastCommit?()

            // Step 6: review scan for residual refs.
            let review = ReviewScan.run(
                oldPath: src,
                newPath: dst,
                homeDirectory: options.homeDirectory
            )

            // Success: keep created parents; only release dirfd pins.
            destinationParentToken?.release()
            destinationParentToken = nil

            return PipelineResult(
                migrationId: migrationId,
                state: .committed,
                src: src,
                dst: dst,
                moveStrategy: moveStrategy,
                ccDirRenamed: ccDirRenamed,
                renamedDirs: renamedDirs,
                skippedDirs: skippedDirs,
                perSource: perSource,
                totalFilesPatched: totalFilesPatched,
                totalOccurrences: totalOccurrences,
                sessionsUpdated: dbResult.sessionsUpdated,
                aliasCreated: dbResult.aliasCreated,
                review: review,
                git: git,
                manifest: manifest,
                error: nil
            )
        } catch {
            // Compensation: pre-flight failures haven't touched the FS.
            // Cancel-before-FS also has nothing to reverse when physicalMoveApplied
            // is still false; cancel-after-FS runs full compensation.
            let wasCancel = error is ProjectMoveCancelledError
            let preflightFailure = error is DirCollisionError
                || error is SharedEncodingCollisionError
                || (wasCancel && !physicalMoveApplied && manifest.isEmpty)
            let report: CompensationReport
            if preflightFailure {
                report = CompensationReport.empty
            } else {
                report = compensate(
                    manifest: manifest,
                    originalSrc: src,
                    attemptedDst: dst,
                    renamedDirs: renamedDirs,
                    geminiProjectsPlan: geminiProjectsApplied ? geminiProjectsPlan : nil,
                    sqlitePatches: sqlitePatches,
                    physicalMoveApplied: physicalMoveApplied
                )
            }
            // Drop empty destination parents we created (dirfd-pinned unlinkat).
            destinationParentToken?.cleanup()
            destinationParentToken = nil

            // Contract 3: cancelled + clean compensation → clean cancelled error.
            // Cancelled + residual compensation failures → partial/unsafe error.
            if wasCancel {
                let clean = compensationFullySucceeded(report)
                let detail = clean ? nil : formatCompensationFailuresOnly(report)
                let cancelError = ProjectMoveCancelledError(
                    compensationSucceeded: clean,
                    compensationDetail: detail
                )
                let combined = formatFailureWithCompensation(
                    primary: cancelError.errorMessage,
                    report: report
                )
                try? writer.write { db in
                    try? MigrationLogStore.failMigration(db, id: migrationId, error: combined)
                }
                throw cancelError
            }

            let combined = formatFailureWithCompensation(
                primary: errorMessage(error),
                report: report
            )
            // Best-effort: failMigration may itself fail (DB outage, race).
            // We still re-throw the ORIGINAL error so callers' instanceof
            // checks (LockBusyError → retry .wait) continue to work.
            try? writer.write { db in
                try? MigrationLogStore.failMigration(db, id: migrationId, error: combined)
            }
            throw error
        }
    }

    // MARK: - dry run

    public static func buildDryRunPlan(
        src: String,
        dst: String,
        git: GitDirtyStatus,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> PipelineResult {
        let roots = SessionSources.roots(homeDirectory: homeDirectory)
        // Mirror live Step 0.5 plan construction (including missing old dirs),
        // then run the same 0.5–0.8 preflight before classifying renamed vs skipped.
        var dirRenamePlans: [DirRenamePlan] = []
        var skippedDirs: [SkippedDirEntry] = []

        for root in roots {
            guard let encode = root.encodeProjectDir else { continue }
            var oldName = encode(src)
            let newName = encode(dst)
            if root.id == .geminiCli {
                let projectsFile = ((root.path as NSString)
                    .deletingLastPathComponent as NSString)
                    .appendingPathComponent("projects.json")
                let plan = try GeminiProjectsJSON.plan(
                    filePath: projectsFile,
                    oldCwd: src,
                    newCwd: dst
                )
                oldName = plan.oldEntry?.name ?? oldName
            }
            let observedOldDirs = findGroupedDirsWithCwd(rootPath: root.path, cwd: src)
            let oldDirs = observedOldDirs.isEmpty
                ? [(root.path as NSString).appendingPathComponent(oldName)]
                : observedOldDirs
            for oldDir in oldDirs {
                if basename(oldDir) == newName {
                    skippedDirs.append(SkippedDirEntry(sourceId: root.id, reason: .noop))
                    continue
                }
                dirRenamePlans.append(DirRenamePlan(
                    sourceId: root.id,
                    oldDir: oldDir,
                    newDir: (root.path as NSString).appendingPathComponent(newName)
                ))
            }
        }

        try assertDirRenamePreflight(
            plans: dirRenamePlans,
            roots: roots,
            src: src,
            dst: dst
        )

        var renamedDirs: [DirRenamePlan] = []
        for plan in dirRenamePlans {
            if FileManager.default.fileExists(atPath: plan.oldDir) {
                renamedDirs.append(plan)
            } else {
                skippedDirs.append(SkippedDirEntry(sourceId: plan.sourceId, reason: .missing))
            }
        }

        var perSource: [PerSourceStats] = []
        var manifest: [ManifestEntry] = []
        var totalFilesPatched = 0
        var totalOccurrences = 0
        let dryRunReadCap: Int64 = 50 * 1024 * 1024

        for root in roots {
            var issues: [WalkIssue] = []
            var filesPatched = 0
            var occurrences = 0
            let hits = SessionSources.findReferencingFiles(root: root.path, needle: src)
            for file in hits {
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: file)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    if size > dryRunReadCap {
                        issues.append(WalkIssue(
                            path: file,
                            reason: .tooLarge,
                            detail: "size=\(size), cap=\(dryRunReadCap)"
                        ))
                        continue
                    }
                    let buf = try Data(contentsOf: URL(fileURLWithPath: file))
                    let patchResult = try JsonlPatch.patchBufferWithDotQuote(
                        buf,
                        oldPath: src,
                        newPath: dst
                    )
                    let fileOccurrences = patchResult.count
                    if fileOccurrences > 0 {
                        manifest.append(ManifestEntry(path: file, occurrences: fileOccurrences))
                        filesPatched += 1
                        occurrences += fileOccurrences
                    }
                } catch {
                    issues.append(WalkIssue(
                        path: file,
                        reason: .statFailed,
                        detail: errorMessage(error)
                    ))
                }
            }
            if root.id == .opencode {
                do {
                    let sqliteRefs = try OpenCodeSQLiteProjectMove.countReferences(
                        root: root.path,
                        oldPath: src
                    )
                    if sqliteRefs.occurrences > 0 {
                        manifest.append(ManifestEntry(
                            path: "\(sqliteRefs.databasePath)::session.directory",
                            occurrences: sqliteRefs.occurrences
                        ))
                        filesPatched += 1
                        occurrences += sqliteRefs.occurrences
                    }
                } catch {
                    issues.append(WalkIssue(
                        path: OpenCodeSQLiteProjectMove.databasePath(root: root.path),
                        reason: .statFailed,
                        detail: errorMessage(error)
                    ))
                }
            }
            perSource.append(PerSourceStats(
                id: root.id.rawValue,
                root: root.path,
                filesPatched: filesPatched,
                occurrences: occurrences,
                issues: issues
            ))
            totalFilesPatched += filesPatched
            totalOccurrences += occurrences
        }

        let ccDirRenamed = renamedDirs.contains { $0.sourceId == .claudeCode }
        return PipelineResult(
            migrationId: "dry-run",
            state: .dryRun,
            src: src,
            dst: dst,
            moveStrategy: .rename,
            ccDirRenamed: ccDirRenamed,
            renamedDirs: renamedDirs,
            skippedDirs: skippedDirs,
            perSource: perSource,
            totalFilesPatched: totalFilesPatched,
            totalOccurrences: totalOccurrences,
            sessionsUpdated: 0,
            aliasCreated: false,
            review: ReviewResult(own: [], other: []),
            git: git,
            manifest: manifest,
            error: nil
        )
    }
}

// MARK: - compensation

struct CompensationReport: Equatable {
    var patchReverted: Int
    var patchFailed: [(path: String, error: String)]
    var sqliteReverted: Int
    var sqliteFailed: [(path: String, error: String)]
    var dirsRestored: [DirRenamePlan]
    var dirRestoreErrors: [(sourceId: SourceId, error: String)]
    var moveReverted: Bool
    var moveRevertError: String?
    var geminiProjectsJsonRestored: GeminiRestoreOutcome

    enum GeminiRestoreOutcome: String, Equatable { case skipped, restored, failed }

    static let empty = CompensationReport(
        patchReverted: 0,
        patchFailed: [],
        sqliteReverted: 0,
        sqliteFailed: [],
        dirsRestored: [],
        dirRestoreErrors: [],
        moveReverted: false,
        moveRevertError: nil,
        geminiProjectsJsonRestored: .skipped
    )

    static func == (lhs: CompensationReport, rhs: CompensationReport) -> Bool {
        lhs.patchReverted == rhs.patchReverted
            && lhs.patchFailed.map { "\($0.path)|\($0.error)" }
                == rhs.patchFailed.map { "\($0.path)|\($0.error)" }
            && lhs.sqliteReverted == rhs.sqliteReverted
            && lhs.sqliteFailed.map { "\($0.path)|\($0.error)" }
                == rhs.sqliteFailed.map { "\($0.path)|\($0.error)" }
            && lhs.dirsRestored == rhs.dirsRestored
            && lhs.dirRestoreErrors.map { "\($0.sourceId.rawValue)|\($0.error)" }
                == rhs.dirRestoreErrors.map { "\($0.sourceId.rawValue)|\($0.error)" }
            && lhs.moveReverted == rhs.moveReverted
            && lhs.moveRevertError == rhs.moveRevertError
            && lhs.geminiProjectsJsonRestored == rhs.geminiProjectsJsonRestored
    }
}

private func compensate(
    manifest: [ManifestEntry],
    originalSrc: String,
    attemptedDst: String,
    renamedDirs: [DirRenamePlan],
    geminiProjectsPlan: GeminiProjectsJsonUpdatePlan?,
    sqlitePatches: [OpenCodeSQLitePatchResult],
    physicalMoveApplied: Bool
) -> CompensationReport {
    var report = CompensationReport.empty

    // 1. Reverse sqlite patches LIFO. The exact session ids are captured
    // during the forward update so rollback cannot rewrite unrelated rows
    // that already belonged to the attempted destination path.
    for entry in sqlitePatches.reversed() {
        do {
            try OpenCodeSQLiteProjectMove.reverse(
                databasePath: entry.databasePath,
                sessionIds: entry.sessionIds,
                oldPath: attemptedDst,
                newPath: originalSrc
            )
            report.sqliteReverted += entry.occurrences
        } catch {
            report.sqliteFailed.append((entry.databasePath, errorMessage(error)))
        }
    }

    // 2. Reverse file patches LIFO (last patched first).
    for entry in manifest.reversed() {
        do {
            if let backupPath = entry.backupPath {
                try restorePatchBackup(backupPath: backupPath, targetPath: entry.path)
            } else {
                _ = try JsonlPatch.patchFile(
                    at: entry.path,
                    oldPath: attemptedDst,
                    newPath: originalSrc
                )
            }
            report.patchReverted += 1
        } catch {
            report.patchFailed.append((entry.path, errorMessage(error)))
        }
    }

    // 3. Reverse Gemini projects.json BEFORE the per-source dir rename — it
    // was applied AFTER the dir rename, so LIFO means it goes first.
    if let plan = geminiProjectsPlan {
        do {
            try GeminiProjectsJSON.reverse(plan: plan)
            report.geminiProjectsJsonRestored = .restored
        } catch {
            report.geminiProjectsJsonRestored = .failed
            report.dirRestoreErrors.append((
                .geminiCli,
                "projects.json reverse: \(errorMessage(error))"
            ))
        }
    }

    // 4. Reverse per-source dir renames LIFO.
    for d in renamedDirs.reversed() {
        do {
            try moveItemRespectingExisting(d.newDir, to: d.oldDir)
            report.dirsRestored.append(d)
        } catch {
            report.dirRestoreErrors.append((d.sourceId, errorMessage(error)))
        }
    }

    // 5. Reverse the physical move only if Step 1 completed. If SafeMoveDir.run
    // itself failed, attemptedDst may be a pre-existing user directory; moving
    // it back would corrupt unrelated data.
    if physicalMoveApplied {
        do {
            _ = try SafeMoveDir.run(src: attemptedDst, dst: originalSrc)
            report.moveReverted = true
        } catch {
            report.moveReverted = false
            report.moveRevertError = errorMessage(error)
        }
    }
    return report
}

private func compensationFullySucceeded(_ report: CompensationReport) -> Bool {
    report.patchFailed.isEmpty
        && report.sqliteFailed.isEmpty
        && report.dirRestoreErrors.isEmpty
        && report.moveRevertError == nil
        && report.geminiProjectsJsonRestored != .failed
}

private func formatCompensationFailuresOnly(_ report: CompensationReport) -> String {
    formatFailureWithCompensation(primary: "", report: report)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func formatFailureWithCompensation(
    primary: String,
    report: CompensationReport
) -> String {
    var parts: [String] = []
    if !primary.isEmpty { parts.append(primary) }
    if !report.patchFailed.isEmpty, let first = report.patchFailed.first {
        parts.append(
            "rollback: \(report.patchFailed.count) file(s) could NOT be reverted " +
            "(e.g. \(first.path): \(first.error))"
        )
    }
    if !report.dirRestoreErrors.isEmpty, let first = report.dirRestoreErrors.first {
        parts.append(
            "rollback: \(report.dirRestoreErrors.count) dir rename(s) could NOT be reversed " +
            "(e.g. \(first.sourceId.rawValue): \(first.error))"
        )
    }
    if report.geminiProjectsJsonRestored == .failed {
        parts.append("rollback: ~/.gemini/projects.json reverse failed — inspect manually")
    }
    if !report.sqliteFailed.isEmpty, let first = report.sqliteFailed.first {
        parts.append(
            "rollback: \(report.sqliteFailed.count) sqlite source(s) could NOT be reverted " +
            "(e.g. \(first.path): \(first.error))"
        )
    }
    if let move = report.moveRevertError {
        parts.append("rollback: physical move-back failed — \(move)")
    }
    return parts.joined(separator: " | ")
}

// MARK: - helpers

/// Shared Steps 0.5–0.8 preflight for live and dry_run.
/// plannedTargets map + on-disk newDir collision + Gemini/iFlow shared-encoding probes.
/// Must run before any FS mutation (and on dry_run before reporting a green plan).
private func assertDirRenamePreflight(
    plans: [DirRenamePlan],
    roots: [SourceRoot],
    src: String,
    dst: String
) throws {
    var plannedTargets: [String: DirRenamePlan] = [:]
    for plan in plans {
        if let prev = plannedTargets[plan.newDir], prev.oldDir != plan.oldDir {
            throw DirCollisionError(sourceId: plan.sourceId, oldDir: prev.oldDir, newDir: plan.newDir)
        }
        plannedTargets[plan.newDir] = plan
    }

    // Step 0.6: pre-flight collision detection. APFS case-insensitive
    // case-only renames resolve to the same realpath — allow those
    // and only refuse genuine third-party collisions.
    for plan in plans {
        guard FileManager.default.fileExists(atPath: plan.newDir) else { continue }
        if let oldReal = realpathSafe(plan.oldDir),
           let newReal = realpathSafe(plan.newDir),
           oldReal == newReal {
            continue
        }
        throw DirCollisionError(
            sourceId: plan.sourceId,
            oldDir: plan.oldDir,
            newDir: plan.newDir
        )
    }

    // Step 0.7: Gemini-specific probes.
    if let geminiPlan = plans.first(where: { $0.sourceId == .geminiCli }) {
        let geminiRoot = roots.first { $0.id == .geminiCli }
        if let geminiRoot {
            let projectsFile = ((geminiRoot.path as NSString)
                .deletingLastPathComponent as NSString)
                .appendingPathComponent("projects.json")

            let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingProjectName(
                filePath: projectsFile,
                targetProjectName: SessionSources.encodeGemini(dst),
                srcCwd: src
            )
            if !conflicts.isEmpty {
                throw SharedEncodingCollisionError(
                    sourceId: .geminiCli,
                    dir: geminiPlan.oldDir,
                    sharingCwds: conflicts
                )
            }
        }
    }

    // Step 0.8: iFlow-specific lossy encoder probe. encodeIflow strips
    // leading/trailing dashes per segment, so src/dst can share the
    // same project dir name and skip the generic dir-collision check.
    if let iflowRoot = roots.first(where: { $0.id == .iflow }) {
        let targetEncodedDir = SessionSources.encodeIflow(dst)
        let conflicts = SessionSources.collectOtherIflowCwdsSharingEncodedDir(
            root: iflowRoot.path,
            targetEncodedDir: targetEncodedDir,
            srcCwd: src
        )
        if !conflicts.isEmpty {
            throw SharedEncodingCollisionError(
                sourceId: .iflow,
                dir: (iflowRoot.path as NSString).appendingPathComponent(targetEncodedDir),
                sharingCwds: conflicts
            )
        }
    }
}

private struct PatchOutcome: Sendable {
    let file: String
    let count: Int
    let backupPath: String?
    let error: Error?
}

private func backupPatchInput(file: String, backupRoot: String) throws -> String {
    let backupPath = (backupRoot as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(atPath: file, toPath: backupPath)
    return backupPath
}

private func restorePatchBackup(backupPath: String, targetPath: String) throws {
    let targetDir = (targetPath as NSString).deletingLastPathComponent
    let tempPath = (targetDir as NSString).appendingPathComponent(".engram-restore-\(UUID().uuidString)")
    try FileManager.default.copyItem(atPath: backupPath, toPath: tempPath)
    if rename(tempPath, targetPath) != 0 {
        let code = errno
        try? FileManager.default.removeItem(atPath: tempPath)
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
}

private func runWithConcurrency<T: Sendable, R: Sendable>(
    items: [T],
    limit: Int,
    fn: @Sendable @escaping (T) async -> R
) async -> [R] {
    if items.isEmpty { return [] }
    let bounded = max(1, min(limit, items.count))
    return await withTaskGroup(of: (Int, R).self, returning: [R].self) { group in
        var cursor = 0
        var pending = 0
        // Seed up to `bounded` workers
        while cursor < items.count && pending < bounded {
            let i = cursor
            let item = items[i]
            group.addTask { (i, await fn(item)) }
            cursor += 1
            pending += 1
        }
        var indexed = Array<R?>(repeating: nil, count: items.count)
        while let (idx, value) = await group.next() {
            indexed[idx] = value
            pending -= 1
            if cursor < items.count {
                let i = cursor
                let item = items[i]
                group.addTask { (i, await fn(item)) }
                cursor += 1
                pending += 1
            }
        }
        return indexed.compactMap { $0 }
    }
}

private func canonicalize(_ raw: String) -> String {
    URL(fileURLWithPath: raw).standardizedFileURL.path
}

private func canonicalizeExistingSource(_ raw: String) -> String {
    let path = canonicalize(raw)
    guard let realPath = realpathSafe(path),
          path.caseInsensitiveCompare(realPath) == .orderedSame
    else {
        return path
    }
    return realPath
}

private func basename(_ p: String) -> String {
    var trimmed = p
    while trimmed.hasSuffix("/") && trimmed.count > 1 {
        trimmed.removeLast()
    }
    return (trimmed as NSString).lastPathComponent
}

private let structuredCwdReadCapBytes: Int64 = 50 * 1024 * 1024

private func findGroupedDirsWithCwd(rootPath: String, cwd: String) -> [String] {
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    var dirs = Set<String>()
    for file in SessionSources.findReferencingFiles(root: rootPath, needle: cwd) {
        guard file.hasPrefix(prefix) else { continue }
        guard fileHasStructuredCwd(file, cwd: cwd) else { continue }
        let rest = String(file.dropFirst(prefix.count))
        guard let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
              !first.isEmpty
        else { continue }
        dirs.insert((rootPath as NSString).appendingPathComponent(String(first)))
    }
    return dirs.sorted()
}

private func fileHasStructuredCwd(_ file: String, cwd: String) -> Bool {
    do {
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > structuredCwdReadCapBytes { return false }
        let text = try String(contentsOfFile: file, encoding: .utf8)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if (file as NSString).lastPathComponent == ".project_root", trimmed == cwd {
                return true
            }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["cwd"] as? String == cwd {
                return true
            }
            if let payload = object["payload"] as? [String: Any],
               payload["cwd"] as? String == cwd {
                return true
            }
        }
    } catch {
        return false
    }
    return false
}

/// macOS `realpath(3)` that returns nil on failure rather than throwing.
private func realpathSafe(_ path: String) -> String? {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(path, &buf) != nil else { return nil }
    return String(cString: buf)
}

/// Foundation's `moveItem` masks `ENOENT` as `CocoaError.fileNoSuchFile`.
/// This wrapper preserves that contract while using the lower-level POSIX
/// `rename` for parity with Node (atomic single-syscall move).
private func moveItemRespectingExisting(_ src: String, to dst: String) throws {
    if rename(src, dst) == 0 { return }
    let code = errno
    if code == ENOENT {
        throw CocoaError(.fileNoSuchFile)
    }
    throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
    )
}

private func renameFailureMessage(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
        return "errno=\(nsError.code) \(nsError.localizedDescription)"
    }
    return errorMessage(error)
}

private func errorMessage(_ error: Error) -> String {
    if let pmErr = error as? ProjectMoveError {
        return pmErr.errorMessage
    }
    return (error as NSError).localizedDescription
}

private func buildFsDoneDetail(
    moveStrategy: MoveResult.Strategy,
    perSource: [PerSourceStats],
    renamedDirs: [DirRenamePlan],
    skippedDirs: [SkippedDirEntry],
    geminiProjectsApplied: Bool,
    manifest: [ManifestEntry]
) -> [String: JSONValue] {
    let perSourceJson = perSource.map { stats -> JSONValue in
        .object([
            "id": .string(stats.id),
            "files": .int(stats.filesPatched),
            "occ": .int(stats.occurrences),
            "issues": .int(stats.issues.count),
        ])
    }
    let renamedJson = renamedDirs.map { d -> JSONValue in
        .object([
            "source": .string(d.sourceId.rawValue),
            "old": .string(d.oldDir),
            "new": .string(d.newDir),
        ])
    }
    let skippedJson = skippedDirs.map { e -> JSONValue in
        .object([
            "sourceId": .string(e.sourceId.rawValue),
            "reason": .string(e.reason.rawValue),
        ])
    }
    return [
        "move_strategy": .string(moveStrategy.rawValue),
        "per_source": .array(perSourceJson),
        "renamed_dirs": .array(renamedJson),
        "skipped_dirs": .array(skippedJson),
        "gemini_projects_json_updated": .bool(geminiProjectsApplied),
        "manifest_paths": .array(manifest.map { .string($0.path) }),
    ]
}
