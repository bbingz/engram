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
//      (Claude Code = encoded cwd, Gemini = basename, iFlow = iflow-encoded)
//   3. Scan all source roots → findReferencingFiles → patchFile (per-file CAS)
//   B. markFsDone                        (state='fs_done', detail = stats)
//   C. applyMigrationDb in transaction   (state='committed')
//   99. release lock; return PipelineResult
//
// Compensation: any FS step throwing reverses the work LIFO:
//   reverse-patch files → restore Gemini projects.json → reverse dir renames
//   → safeMoveDir dst→src back → failMigration → release lock.
import Foundation
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

public enum OrchestratorError: Error, Equatable {
    case missingPaths(src: String, dst: String)
    case sameSourceAndDest(path: String)
    case dstInsideSrc(src: String, dst: String)
    case srcInsideDst(src: String, dst: String)
    case gitDirty(src: String)
    case dirRenameFailed(sourceId: SourceId, oldDir: String, newDir: String, message: String)
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
    public init(path: String, occurrences: Int) {
        self.path = path
        self.occurrences = occurrences
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
    case committed, dryRun = "dry-run", failed
}

public struct PipelineResult: Equatable, Sendable {
    public let migrationId: String
    public let state: PipelineState
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
        rolledBackOf: String? = nil
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
    }
}

// MARK: - main entry point

public enum ProjectMoveOrchestrator {

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
        let src = canonicalize(options.src)
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
        if git.dirty && !options.force {
            throw OrchestratorError.gitDirty(src: src)
        }

        // Dry-run: read-only scan + plan, no FS or DB side effects.
        if options.dryRun {
            return try buildDryRunPlan(
                src: src,
                dst: dst,
                git: git,
                homeDirectory: options.homeDirectory
            )
        }

        let migrationId = UUID().uuidString
        let oldBasename = basename(src)
        let newBasename = basename(dst)
        let lockPath = options.lockPath ?? MigrationLock.defaultLockPath()

        // Lock BEFORE startMigration: a LockBusyError must not leave a stale
        // fs_pending row that blocks the watcher for the TTL window.
        try MigrationLock.acquire(migrationId: migrationId, lockPath: lockPath)

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
        var geminiProjectsPlan: GeminiProjectsJsonUpdatePlan?
        var geminiProjectsApplied = false

        do {
            let roots = SessionSources.roots(homeDirectory: options.homeDirectory)

            // Step 0.5: per-source rename plans
            var dirRenamePlans: [DirRenamePlan] = []
            for root in roots {
                guard let encode = root.encodeProjectDir else { continue }
                let oldName = encode(src)
                let newName = encode(dst)
                if oldName == newName {
                    skippedDirs.append(SkippedDirEntry(sourceId: root.id, reason: .noop))
                    continue
                }
                dirRenamePlans.append(DirRenamePlan(
                    sourceId: root.id,
                    oldDir: (root.path as NSString).appendingPathComponent(oldName),
                    newDir: (root.path as NSString).appendingPathComponent(newName)
                ))
            }

            // Step 0.6: pre-flight collision detection. APFS case-insensitive
            // case-only renames resolve to the same realpath — allow those
            // and only refuse genuine third-party collisions.
            for plan in dirRenamePlans {
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
            if let geminiPlan = dirRenamePlans.first(where: { $0.sourceId == .geminiCli }) {
                let geminiRoot = roots.first { $0.id == .geminiCli }
                if let geminiRoot {
                    let projectsFile = ((geminiRoot.path as NSString)
                        .deletingLastPathComponent as NSString)
                        .appendingPathComponent("projects.json")

                    let conflicts = try GeminiProjectsJSON.collectOtherCwdsSharingBasename(
                        filePath: projectsFile,
                        targetBasename: basename(dst),
                        srcCwd: src
                    )
                    if !conflicts.isEmpty {
                        throw SharedEncodingCollisionError(
                            sourceId: .geminiCli,
                            dir: geminiPlan.oldDir,
                            sharingCwds: conflicts
                        )
                    }
                    geminiProjectsPlan = try GeminiProjectsJSON.plan(
                        filePath: projectsFile,
                        oldCwd: src,
                        newCwd: dst
                    )
                }
            }

            // Step 1: physical move
            let moveResult = try SafeMoveDir.run(src: src, dst: dst)
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
                        message: error.localizedDescription
                    )
                }
            }
            let ccDirRenamed = renamedDirs.contains { $0.sourceId == .claudeCode }

            // Step 2.5: apply Gemini projects.json rewrite (after the dir rename).
            if let plan = geminiProjectsPlan,
               renamedDirs.contains(where: { $0.sourceId == .geminiCli }) {
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
                        let count = try JsonlPatch.patchFile(at: file, oldPath: src, newPath: dst)
                        return PatchOutcome(file: file, count: count, error: nil)
                    } catch {
                        return PatchOutcome(file: file, count: 0, error: error)
                    }
                }
                var filesPatched = 0
                var occurrences = 0
                for r in perFile {
                    if let err = r.error {
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
                    } else if r.count > 0 {
                        manifest.append(ManifestEntry(path: r.file, occurrences: r.count))
                        filesPatched += 1
                        occurrences += r.count
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

            // Phase B: mark FS complete.
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

            // Step 6: review scan for residual refs.
            let review = ReviewScan.run(
                oldPath: src,
                newPath: dst,
                homeDirectory: options.homeDirectory
            )

            MigrationLock.release(lockPath: lockPath)

            return PipelineResult(
                migrationId: migrationId,
                state: .committed,
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
            let preflightFailure = error is DirCollisionError
                || error is SharedEncodingCollisionError
            let report: CompensationReport
            if preflightFailure {
                report = CompensationReport.empty
            } else {
                report = compensate(
                    manifest: manifest,
                    originalSrc: src,
                    attemptedDst: dst,
                    renamedDirs: renamedDirs,
                    geminiProjectsPlan: geminiProjectsApplied ? geminiProjectsPlan : nil
                )
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
            MigrationLock.release(lockPath: lockPath)
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
        var renamedDirs: [DirRenamePlan] = []
        var skippedDirs: [SkippedDirEntry] = []

        for root in roots {
            guard let encode = root.encodeProjectDir else { continue }
            let oldName = encode(src)
            let newName = encode(dst)
            if oldName == newName {
                skippedDirs.append(SkippedDirEntry(sourceId: root.id, reason: .noop))
                continue
            }
            let plan = DirRenamePlan(
                sourceId: root.id,
                oldDir: (root.path as NSString).appendingPathComponent(oldName),
                newDir: (root.path as NSString).appendingPathComponent(newName)
            )
            if FileManager.default.fileExists(atPath: plan.oldDir) {
                renamedDirs.append(plan)
            } else {
                skippedDirs.append(SkippedDirEntry(sourceId: root.id, reason: .missing))
            }
        }

        var perSource: [PerSourceStats] = []
        var manifest: [ManifestEntry] = []
        var totalFilesPatched = 0
        var totalOccurrences = 0
        let needleData = Data(src.utf8)
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
                    let fileOccurrences = countOccurrences(of: needleData, in: buf)
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
    var dirsRestored: [DirRenamePlan]
    var dirRestoreErrors: [(sourceId: SourceId, error: String)]
    var moveReverted: Bool
    var moveRevertError: String?
    var geminiProjectsJsonRestored: GeminiRestoreOutcome

    enum GeminiRestoreOutcome: String, Equatable { case skipped, restored, failed }

    static let empty = CompensationReport(
        patchReverted: 0,
        patchFailed: [],
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
    geminiProjectsPlan: GeminiProjectsJsonUpdatePlan?
) -> CompensationReport {
    var report = CompensationReport.empty

    // 1. Reverse file patches LIFO (last patched first).
    for entry in manifest.reversed() {
        do {
            _ = try JsonlPatch.patchFile(
                at: entry.path,
                oldPath: attemptedDst,
                newPath: originalSrc
            )
            report.patchReverted += 1
        } catch {
            report.patchFailed.append((entry.path, errorMessage(error)))
        }
    }

    // 2. Reverse Gemini projects.json BEFORE the per-source dir rename — it
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

    // 3. Reverse per-source dir renames LIFO.
    for d in renamedDirs.reversed() {
        do {
            try moveItemRespectingExisting(d.newDir, to: d.oldDir)
            report.dirsRestored.append(d)
        } catch {
            report.dirRestoreErrors.append((d.sourceId, errorMessage(error)))
        }
    }

    // 4. Reverse the physical move.
    do {
        _ = try SafeMoveDir.run(src: attemptedDst, dst: originalSrc)
        report.moveReverted = true
    } catch {
        report.moveReverted = false
        report.moveRevertError = errorMessage(error)
    }
    return report
}

private func formatFailureWithCompensation(
    primary: String,
    report: CompensationReport
) -> String {
    var parts = [primary]
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
    if let move = report.moveRevertError {
        parts.append("rollback: physical move-back failed — \(move)")
    }
    return parts.joined(separator: " | ")
}

// MARK: - helpers

private struct PatchOutcome: Sendable {
    let file: String
    let count: Int
    let error: Error?
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

private func basename(_ p: String) -> String {
    var trimmed = p
    while trimmed.hasSuffix("/") && trimmed.count > 1 {
        trimmed.removeLast()
    }
    return (trimmed as NSString).lastPathComponent
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

private func countOccurrences(of needle: Data, in haystack: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    var cursor = haystack.startIndex
    var count = 0
    while cursor < haystack.endIndex {
        guard let hit = haystack.range(of: needle, in: cursor..<haystack.endIndex) else {
            break
        }
        count += 1
        cursor = hit.upperBound
    }
    return count
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
) -> [String: Any] {
    let perSourceJson = perSource.map { stats -> [String: Any] in
        [
            "id": stats.id,
            "files": stats.filesPatched,
            "occ": stats.occurrences,
            "issues": stats.issues.count,
        ]
    }
    let renamedJson = renamedDirs.map { d -> [String: Any] in
        [
            "source": d.sourceId.rawValue,
            "old": d.oldDir,
            "new": d.newDir,
        ]
    }
    let skippedJson = skippedDirs.map { e -> [String: Any] in
        [
            "sourceId": e.sourceId.rawValue,
            "reason": e.reason.rawValue,
        ]
    }
    return [
        "move_strategy": moveStrategy.rawValue,
        "per_source": perSourceJson,
        "renamed_dirs": renamedJson,
        "skipped_dirs": skippedJson,
        "gemini_projects_json_updated": geminiProjectsApplied,
        "manifest_paths": manifest.map(\.path),
    ]
}
