import Foundation
import EngramCoreWrite

extension EngramServiceCommandHandler {
    private static let projectMovePayloadListLimit = 100
    private static let projectMovePayloadIssueLimit = 25
    private static let projectMovePayloadStringLimit = 512
    private static let projectMovePorcelainLimit = 8 * 1024

    static func projectMove(
        _ request: EngramServiceProjectMoveRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        ServiceLogger.notice(
            "projectMove requested actor=\(request.actor ?? "mcp") dryRun=\(request.dryRun) force=\(request.force) src=\(request.src) dst=\(request.dst) operationId=\(request.operationId ?? "")",
            category: .writer
        )
        let operationId = normalizeOperationId(request.operationId)
        let fingerprint = "move|\(request.src)|\(request.dst)|\(request.dryRun)|\(request.force)|\(request.auditNote ?? "")"
        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try decodeMoveResult(cached)
        }

        do {
            // SEC-C2: confine before any filesystem work. force never relaxes this.
            try validateProjectMovePaths(src: request.src, dst: request.dst)
            let homeDirectory = homeDirectoryURL()
            let mapped = try await runPipelineSurvivingClientCancel(
                operationId: operationId,
                map: { mapPipelineResult($0, suggestion: nil) },
                cancelledMap: { cancelledMoveResult(from: $0, src: request.src, dst: request.dst) }
            ) {
                try await ProjectMoveOrchestrator.run(
                    writer: writer,
                    options: RunProjectMoveOptions(
                        src: request.src,
                        dst: request.dst,
                        dryRun: request.dryRun,
                        force: request.force,
                        archived: false,
                        auditNote: request.auditNote,
                        actor: parseActor(request.actor) ?? .mcp,
                        homeDirectory: homeDirectory,
                        rolledBackOf: nil,
                        shouldCancel: { shouldStop(operationId: operationId) },
                        onPastCommit: { markPastCommit(operationId: operationId) }
                    )
                )
            }
            ServiceLogger.notice(
                "projectMove finished migrationId=\(mapped.migrationId) state=\(mapped.state) filesPatched=\(mapped.totalFilesPatched) occurrences=\(mapped.totalOccurrences)",
                category: .writer
            )
            return mapped
        } catch {
            ServiceLogger.error("projectMove failed src=\(request.src) dst=\(request.dst)", category: .writer, error: error)
            throw error
        }
    }

    static func projectArchive(
        _ request: EngramServiceProjectArchiveRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        ServiceLogger.notice(
            "projectArchive requested actor=\(request.actor ?? "mcp") dryRun=\(request.dryRun) force=\(request.force) src=\(request.src) archiveTo=\(request.archiveTo ?? "") operationId=\(request.operationId ?? "")",
            category: .writer
        )
        let operationId = normalizeOperationId(request.operationId)
        let fingerprint = "archive|\(request.src)|\(request.archiveTo ?? "")|\(request.dryRun)|\(request.force)|\(request.auditNote ?? "")"
        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try decodeMoveResult(cached)
        }

        do {
            // SEC-C2: confine the caller-supplied source before resolving an
            // archive target. force never relaxes this.
            try validateProjectPathConfined(request.src, label: "source")
            let homeDirectory = homeDirectoryURL()
            let suggestion = try Archive.suggestTarget(
                src: request.src,
                options: ArchiveOptions(
                    archiveRoot: nil,
                    skipProbe: request.dryRun,
                    forceCategory: request.archiveTo
                )
            )
            // SEC-C2: confine the resolved archive destination as well, in case a
            // future archive-root override could escape the home directory.
            try validateProjectPathConfined(suggestion.dst, label: "archive destination")
            // rename(2) refuses to create intermediate parents.
            if !request.dryRun {
                try FileManager.default.createDirectory(
                    atPath: (suggestion.dst as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
            }
            let mapped = try await runPipelineSurvivingClientCancel(
                operationId: operationId,
                map: { mapPipelineResult($0, suggestion: suggestion) },
                cancelledMap: { cancelledMoveResult(from: $0, src: request.src, dst: suggestion.dst) }
            ) {
                try await ProjectMoveOrchestrator.run(
                    writer: writer,
                    options: RunProjectMoveOptions(
                        src: request.src,
                        dst: suggestion.dst,
                        dryRun: request.dryRun,
                        force: request.force,
                        archived: true,
                        auditNote: request.auditNote,
                        actor: parseActor(request.actor) ?? .mcp,
                        homeDirectory: homeDirectory,
                        rolledBackOf: nil,
                        shouldCancel: { shouldStop(operationId: operationId) },
                        onPastCommit: { markPastCommit(operationId: operationId) }
                    )
                )
            }
            ServiceLogger.notice(
                "projectArchive finished migrationId=\(mapped.migrationId) state=\(mapped.state) dst=\(suggestion.dst)",
                category: .writer
            )
            return mapped
        } catch {
            ServiceLogger.error("projectArchive failed src=\(request.src)", category: .writer, error: error)
            throw error
        }
    }

    static func projectUndo(
        _ request: EngramServiceProjectUndoRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        ServiceLogger.notice(
            "projectUndo requested actor=\(request.actor ?? "mcp") force=\(request.force) migrationId=\(request.migrationId) operationId=\(request.operationId ?? "")",
            category: .writer
        )
        let operationId = normalizeOperationId(request.operationId)
        let fingerprint = "undo|\(request.migrationId)|\(request.force)"
        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try decodeMoveResult(cached)
        }

        do {
            let mapped = try await runUndoSurvivingClientCancel(
                operationId: operationId,
                map: { mapPipelineResult($0.pipelineResult, suggestion: nil) },
                cancelledMap: { cancelledMoveResult(from: $0, src: nil, dst: nil) }
            ) {
                try await ProjectMoveOrchestrator.runUndo(
                    writer: writer,
                    migrationId: request.migrationId,
                    force: request.force,
                    actor: parseActor(request.actor) ?? .mcp,
                    shouldCancel: { shouldStop(operationId: operationId) },
                    onPastCommit: { markPastCommit(operationId: operationId) }
                )
            }
            ServiceLogger.notice(
                "projectUndo finished migrationId=\(mapped.migrationId) state=\(mapped.state)",
                category: .writer
            )
            return mapped
        } catch {
            ServiceLogger.error("projectUndo failed migrationId=\(request.migrationId)", category: .writer, error: error)
            throw error
        }
    }

    static func projectMoveBatch(
        _ request: EngramServiceProjectMoveBatchRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceJSONValue {
        ServiceLogger.notice(
            "projectMoveBatch requested bytes=\(request.yaml.utf8.count) force=\(request.force) operationId=\(request.operationId ?? "")",
            category: .writer
        )
        let operationId = normalizeOperationId(request.operationId)
        let fingerprint = "batch|\(request.yaml)|\(request.force)"
        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try decodeJSONValue(cached)
        }

        do {
            // Despite the field name `yaml` (kept for IPC backwards-compat),
            // the Swift batch driver accepts JSON only.
            let document = try Batch.parseJSON(Data(request.yaml.utf8))
            // SEC-C2: confine every operation before the batch driver runs.
            for operation in document.operations {
                try validateProjectPathConfined(operation.src, label: "source")
                if let dst = operation.dst, !dst.isEmpty {
                    try validateProjectPathConfined(dst, label: "destination")
                }
            }
            // Keep cancel flag for the duration; clear only the cancel bit after,
            // retaining completed payload for reconnect/idempotence.
            defer { ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId) }
            let result = await Batch.run(
                document,
                writer: writer,
                overrides: BatchOverrides(
                    homeDirectory: homeDirectoryURL(),
                    force: request.force
                ),
                shouldCancel: {
                    // Prefer registry shouldStop so post-commit cancel is ignored.
                    // Without operationId, fall back to Task cancellation.
                    if let operationId {
                        return ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId)
                    }
                    return Task.isCancelled
                }
            )
            ServiceLogger.notice(
                "projectMoveBatch finished completed=\(result.completed.count) failed=\(result.failed.count) skipped=\(result.skipped.count) cancelled=\(result.cancelled) remaining=\(result.remaining.count)",
                category: .writer
            )
            let encoded = encodeBatchResult(result)
            if let operationId, let data = try? JSONEncoder().encode(encoded) {
                ProjectMoveBatchCancelRegistry.shared.complete(operationId: operationId, payload: data)
            }
            return encoded
        } catch {
            failOperation(operationId: operationId, error: error)
            ServiceLogger.error("projectMoveBatch failed", category: .writer, error: error)
            throw error
        }
    }

    // MARK: - Long-op helpers

    private static func normalizeOperationId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// When `operationId` is set, run pipeline work in a detached task so a
    /// client timeout/disconnect (request-task cancel) does not tear down work
    /// after the commit boundary. Cooperative cancel still flows through the
    /// registry (`shouldStop` / `requestCancel`). Reconnect re-submits the same id.
    ///
    /// Registry completion is performed inside the detached task so joiners still
    /// observe a terminal payload even if this request task is cancelled mid-await.
    private static func runPipelineSurvivingClientCancel(
        operationId: String?,
        map: @escaping @Sendable (PipelineResult) -> EngramServiceProjectMoveResult,
        cancelledMap: @escaping @Sendable (ProjectMoveCancelledError) -> EngramServiceProjectMoveResult,
        _ body: @escaping @Sendable () async throws -> PipelineResult
    ) async throws -> EngramServiceProjectMoveResult {
        guard let operationId else {
            do {
                return map(try await body())
            } catch let error as ProjectMoveCancelledError {
                return cancelledMap(error)
            }
        }

        let work = Task.detached(priority: .userInitiated) {
            () -> Result<EngramServiceProjectMoveResult, Error> in
            do {
                let pipeline = try await body()
                let mapped = map(pipeline)
                completeOperation(operationId: operationId, result: mapped)
                return .success(mapped)
            } catch let error as ProjectMoveCancelledError {
                let mapped = cancelledMap(error)
                completeOperation(operationId: operationId, result: mapped)
                return .success(mapped)
            } catch {
                failOperation(operationId: operationId, error: error)
                return .failure(error)
            }
        }

        return try await withTaskCancellationHandler {
            switch await work.value {
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        } onCancel: {
            // Cooperative only — ignored after markPastCommit.
            ProjectMoveBatchCancelRegistry.shared.requestCancel(operationId: operationId)
        }
    }

    private static func runUndoSurvivingClientCancel(
        operationId: String?,
        map: @escaping @Sendable (UndoProjectMoveRunResult) -> EngramServiceProjectMoveResult,
        cancelledMap: @escaping @Sendable (ProjectMoveCancelledError) -> EngramServiceProjectMoveResult,
        _ body: @escaping @Sendable () async throws -> UndoProjectMoveRunResult
    ) async throws -> EngramServiceProjectMoveResult {
        guard let operationId else {
            do {
                return map(try await body())
            } catch let error as ProjectMoveCancelledError {
                return cancelledMap(error)
            }
        }

        let work = Task.detached(priority: .userInitiated) {
            () -> Result<EngramServiceProjectMoveResult, Error> in
            do {
                let undo = try await body()
                let mapped = map(undo)
                completeOperation(operationId: operationId, result: mapped)
                return .success(mapped)
            } catch let error as ProjectMoveCancelledError {
                let mapped = cancelledMap(error)
                completeOperation(operationId: operationId, result: mapped)
                return .success(mapped)
            } catch {
                failOperation(operationId: operationId, error: error)
                return .failure(error)
            }
        }

        return try await withTaskCancellationHandler {
            switch await work.value {
            case .success(let result):
                return result
            case .failure(let error):
                throw error
            }
        } onCancel: {
            ProjectMoveBatchCancelRegistry.shared.requestCancel(operationId: operationId)
        }
    }

    private static func shouldStop(operationId: String?) -> Bool {
        ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId)
    }

    private static func markPastCommit(operationId: String?) {
        ProjectMoveBatchCancelRegistry.shared.markPastCommit(operationId: operationId)
    }

    private static func resolveExistingOperation(
        operationId: String?,
        fingerprint: String
    ) async throws -> Data? {
        guard let operationId else { return nil }
        switch ProjectMoveBatchCancelRegistry.shared.beginOrJoin(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
        case .proceed:
            return nil
        case .completed(let data):
            return data
        case .join(let wait):
            return try await wait()
        case .fingerprintConflict:
            throw EngramServiceError.invalidRequest(
                message: "operation_id already used with a different project migration request"
            )
        }
    }

    private static func completeOperation(
        operationId: String?,
        result: EngramServiceProjectMoveResult
    ) {
        guard let operationId else { return }
        guard let data = try? JSONEncoder().encode(result) else { return }
        ProjectMoveBatchCancelRegistry.shared.complete(operationId: operationId, payload: data)
        ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId)
    }

    private static func failOperation(operationId: String?, error: Error) {
        guard let operationId else { return }
        let message: String
        if let pm = error as? ProjectMoveError {
            message = pm.errorMessage
        } else {
            message = error.localizedDescription
        }
        ProjectMoveBatchCancelRegistry.shared.completeWithError(operationId: operationId, message: message)
        ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId)
    }

    private static func decodeMoveResult(_ data: Data) throws -> EngramServiceProjectMoveResult {
        try JSONDecoder().decode(EngramServiceProjectMoveResult.self, from: data)
    }

    private static func decodeJSONValue(_ data: Data) throws -> EngramServiceJSONValue {
        try JSONDecoder().decode(EngramServiceJSONValue.self, from: data)
    }

    private static func cancelledMoveResult(
        from error: ProjectMoveCancelledError,
        src: String?,
        dst: String?
    ) -> EngramServiceProjectMoveResult {
        // State "cancelled" drives precise UI wording (cancelled before commit;
        // no migration was committed). Paths kept for logging only.
        _ = error
        _ = src
        _ = dst
        return EngramServiceProjectMoveResult(
            migrationId: "",
            state: "cancelled",
            moveStrategy: nil,
            ccDirRenamed: false,
            renamedDirs: nil,
            totalFilesPatched: 0,
            totalOccurrences: 0,
            sessionsUpdated: 0,
            aliasCreated: false,
            review: .init(own: [], other: []),
            git: nil,
            manifest: nil,
            perSource: nil,
            skippedDirs: nil,
            suggestion: nil
        )
    }

    private static func parseActor(_ value: String?) -> MigrationLogActor? {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "cli": return .cli
        case "mcp": return .mcp
        case "swift-ui": return .swiftUI
        case "batch": return .batch
        default: return nil
        }
    }

    private static func mapPipelineResult(
        _ result: PipelineResult,
        suggestion: ArchiveSuggestion?
    ) -> EngramServiceProjectMoveResult {
        let review = EngramServiceProjectMoveResult.ReviewBlock(
            own: result.review.own
                .prefix(Self.projectMovePayloadListLimit)
                .map { Self.cappedProjectMoveString($0) },
            other: result.review.other
                .prefix(Self.projectMovePayloadListLimit)
                .map { Self.cappedProjectMoveString($0) }
        )
        let manifest = result.manifest.prefix(Self.projectMovePayloadListLimit).map { entry in
            EngramServiceProjectMoveResult.ManifestEntry(
                path: Self.cappedProjectMoveString(entry.path),
                occurrences: entry.occurrences
            )
        }
        let perSource = result.perSource.map { stats in
            EngramServiceProjectMoveResult.PerSource(
                id: Self.cappedProjectMoveString(stats.id),
                root: Self.cappedProjectMoveString(stats.root),
                filesPatched: stats.filesPatched,
                occurrences: stats.occurrences,
                issues: stats.issues.isEmpty ? nil : stats.issues
                    .prefix(Self.projectMovePayloadIssueLimit)
                    .map { issue in
                    EngramServiceProjectMoveResult.PerSource.WalkIssue(
                        path: Self.cappedProjectMoveString(issue.path),
                        reason: issue.reason.rawValue,
                        detail: issue.detail.map { Self.cappedProjectMoveString($0) }
                    )
                }
            )
        }
        let skipped = result.skippedDirs.prefix(Self.projectMovePayloadListLimit).map { entry in
            EngramServiceProjectMoveResult.SkippedDir(
                sourceId: entry.sourceId.rawValue,
                reason: entry.reason.rawValue,
                dir: nil
            )
        }
        let archive = suggestion.map { s in
            EngramServiceProjectMoveResult.ArchiveSuggestion(
                category: s.category.rawValue,
                dst: Self.cappedProjectMoveString(s.dst),
                reason: Self.cappedProjectMoveString(s.reason)
            )
        }
        let git = EngramServiceProjectMoveResult.GitStatus(
            isGitRepo: result.git.isGitRepo,
            dirty: result.git.dirty,
            untrackedOnly: result.git.untrackedOnly,
            porcelain: Self.cappedProjectMoveString(result.git.porcelain, limit: Self.projectMovePorcelainLimit)
        )
        return EngramServiceProjectMoveResult(
            migrationId: result.migrationId,
            state: result.state.rawValue,
            moveStrategy: result.moveStrategy.rawValue,
            ccDirRenamed: result.ccDirRenamed,
            renamedDirs: result.renamedDirs
                .prefix(Self.projectMovePayloadListLimit)
                .map { Self.cappedProjectMoveString($0.newDir) },
            totalFilesPatched: result.totalFilesPatched,
            totalOccurrences: result.totalOccurrences,
            sessionsUpdated: result.sessionsUpdated,
            aliasCreated: result.aliasCreated,
            review: review,
            git: git,
            manifest: manifest.isEmpty ? nil : manifest,
            perSource: perSource,
            skippedDirs: skipped.isEmpty ? nil : skipped,
            suggestion: archive
        )
    }

    private static func cappedProjectMoveString(
        _ value: String,
        limit: Int = EngramServiceCommandHandler.projectMovePayloadStringLimit
    ) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "..."
    }

    private static func encodeBatchResult(_ result: BatchResult) -> EngramServiceJSONValue {
        // Keep keys snake_case to mirror Node parity.
        let completed: [EngramServiceJSONValue] = result.completed.map { pr in
            .object([
                "migration_id": .string(pr.migrationId),
                "state": .string(pr.state.rawValue),
                "src": .string(pr.src),
                "dst": .string(pr.dst),
                "files_patched": .number(Double(pr.totalFilesPatched)),
                "occurrences": .number(Double(pr.totalOccurrences)),
                "sessions_updated": .number(Double(pr.sessionsUpdated)),
            ])
        }
        let failed: [EngramServiceJSONValue] = result.failed.map { f in
            .object([
                "src": .string(f.operation.src),
                "dst": f.operation.dst.map { .string($0) } ?? .null,
                "archive": .bool(f.operation.archive),
                "error": .string(f.error),
            ])
        }
        let skipped: [EngramServiceJSONValue] = result.skipped.map { op in
            .object([
                "src": .string(op.src),
                "dst": op.dst.map { .string($0) } ?? .null,
                "archive": .bool(op.archive),
            ])
        }
        // Wave 7C M05 / Wave 8 long-ops: explicit cancelled + remaining.
        // Wording contract: remaining = not-yet-started (or cancelled mid-op before commit).
        let remaining: [EngramServiceJSONValue] = result.remaining.map { op in
            .object([
                "src": .string(op.src),
                "dst": op.dst.map { .string($0) } ?? .null,
                "archive": .bool(op.archive),
            ])
        }
        return .object([
            "completed": .array(completed),
            "failed": .array(failed),
            "skipped": .array(skipped),
            "remaining": .array(remaining),
            "cancelled": .bool(result.cancelled),
        ])
    }
}
