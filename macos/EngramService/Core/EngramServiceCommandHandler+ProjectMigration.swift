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
        let actor = parseActor(request.actor) ?? .mcp
        let fingerprint = ProjectMoveOperationFingerprint.encode([
            "kind": "move",
            "src": request.src,
            "dst": request.dst,
            "dryRun": String(request.dryRun),
            "force": String(request.force),
            "auditNote": request.auditNote ?? "",
            "actor": actor.rawValue,
        ])

        // Contract 4: validate before registration so failed preflight does not
        // leave a running orphan. After registration every exit is terminal.
        try validateProjectMovePaths(src: request.src, dst: request.dst)

        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try materializeMoveResult(cached)
        }

        return try await produceMoveResult(
            operationId: operationId,
            map: { mapPipelineResult($0, suggestion: nil) }
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
                    actor: actor,
                    homeDirectory: homeDirectoryURL(),
                    rolledBackOf: nil,
                    shouldCancel: { shouldStop(operationId: operationId) },
                    beginCommitIfNotCancelled: {
                        ProjectMoveBatchCancelRegistry.shared.beginCommitIfNotCancelled(
                            operationId: operationId
                        )
                    }
                )
            )
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
        let actor = parseActor(request.actor) ?? .mcp

        // Preflight before registry registration (contract 4).
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
        try validateProjectPathConfined(suggestion.dst, label: "archive destination")
        if !request.dryRun {
            try FileManager.default.createDirectory(
                atPath: (suggestion.dst as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        }

        let fingerprint = ProjectMoveOperationFingerprint.encode([
            "kind": "archive",
            "src": request.src,
            "dst": suggestion.dst,
            "archiveTo": request.archiveTo ?? "",
            "dryRun": String(request.dryRun),
            "force": String(request.force),
            "auditNote": request.auditNote ?? "",
            "actor": actor.rawValue,
        ])

        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try materializeMoveResult(cached)
        }

        return try await produceMoveResult(
            operationId: operationId,
            map: { mapPipelineResult($0, suggestion: suggestion) }
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
                    actor: actor,
                    homeDirectory: homeDirectory,
                    rolledBackOf: nil,
                    shouldCancel: { shouldStop(operationId: operationId) },
                    beginCommitIfNotCancelled: {
                        ProjectMoveBatchCancelRegistry.shared.beginCommitIfNotCancelled(
                            operationId: operationId
                        )
                    }
                )
            )
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
        let actor = parseActor(request.actor) ?? .mcp
        let fingerprint = ProjectMoveOperationFingerprint.encode([
            "kind": "undo",
            "migrationId": request.migrationId,
            "force": String(request.force),
            "actor": actor.rawValue,
        ])

        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try materializeMoveResult(cached)
        }

        return try await produceMoveResult(
            operationId: operationId,
            map: { mapPipelineResult($0.pipelineResult, suggestion: nil) }
        ) {
            try await ProjectMoveOrchestrator.runUndo(
                writer: writer,
                migrationId: request.migrationId,
                force: request.force,
                actor: actor,
                shouldCancel: { shouldStop(operationId: operationId) },
                beginCommitIfNotCancelled: {
                    ProjectMoveBatchCancelRegistry.shared.beginCommitIfNotCancelled(
                        operationId: operationId
                    )
                }
            )
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

        // Preflight parse + path confinement before registration.
        let document = try Batch.parseJSON(Data(request.yaml.utf8))
        for operation in document.operations {
            try validateProjectPathConfined(operation.src, label: "source")
            if let dst = operation.dst, !dst.isEmpty {
                try validateProjectPathConfined(dst, label: "destination")
            }
        }

        let fingerprint = ProjectMoveOperationFingerprint.encode([
            "kind": "batch",
            "yaml": request.yaml,
            "force": String(request.force),
            "actor": request.actor ?? "",
        ])

        if let cached = try await resolveExistingOperation(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
            return try materializeJSONValue(cached)
        }

        guard let operationId else {
            let result = await Batch.run(
                document,
                writer: writer,
                overrides: BatchOverrides(
                    homeDirectory: homeDirectoryURL(),
                    force: request.force
                ),
                shouldCancel: { Task.isCancelled }
            )
            return encodeBatchResult(result)
        }

        // Detached producer; request only waits. Disconnect detaches waiter only.
        Task.detached(priority: .userInitiated) {
            let result = await Batch.run(
                document,
                writer: writer,
                overrides: BatchOverrides(
                    homeDirectory: homeDirectoryURL(),
                    force: request.force
                ),
                shouldCancel: {
                    ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId)
                }
            )
            ServiceLogger.notice(
                "projectMoveBatch finished completed=\(result.completed.count) failed=\(result.failed.count) skipped=\(result.skipped.count) cancelled=\(result.cancelled) remaining=\(result.remaining.count)",
                category: .writer
            )
            let encoded = encodeBatchResult(result)
            if let data = try? JSONEncoder().encode(encoded) {
                ProjectMoveBatchCancelRegistry.shared.complete(operationId: operationId, payload: data)
            } else {
                ProjectMoveBatchCancelRegistry.shared.completeWithFailure(
                    operationId: operationId,
                    failure: .init(
                        name: "ProjectMoveBatchEncodeError",
                        message: "failed to encode batch result",
                        retryPolicy: "never"
                    )
                )
            }
            ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId)
        }

        let terminal = try await ProjectMoveBatchCancelRegistry.shared.waitForTerminal(
            operationId: operationId
        )
        return try materializeJSONValue(terminal)
    }

    // MARK: - Long-op helpers

    private static func normalizeOperationId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shouldStop(operationId: String?) -> Bool {
        ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: operationId)
    }

    /// Produce pipeline work in a detached task and join via registry waiters.
    /// Parent-task cancel removes only the waiter — never requestCancel (contract 2).
    private static func produceMoveResult<Pipeline: Sendable>(
        operationId: String?,
        map: @escaping @Sendable (Pipeline) -> EngramServiceProjectMoveResult,
        _ body: @escaping @Sendable () async throws -> Pipeline
    ) async throws -> EngramServiceProjectMoveResult {
        guard let operationId else {
            do {
                return map(try await body())
            } catch let error as ProjectMoveCancelledError {
                return try mapCancelled(error)
            }
        }

        Task.detached(priority: .userInitiated) {
            do {
                let pipeline = try await body()
                let mapped = map(pipeline)
                completeOperation(operationId: operationId, result: mapped)
            } catch let error as ProjectMoveCancelledError {
                do {
                    let mapped = try mapCancelled(error)
                    completeOperation(operationId: operationId, result: mapped)
                } catch {
                    failOperation(operationId: operationId, error: error)
                }
            } catch {
                failOperation(operationId: operationId, error: error)
            }
        }

        let terminal = try await ProjectMoveBatchCancelRegistry.shared.waitForTerminal(
            operationId: operationId
        )
        return try materializeMoveResult(terminal)
    }

    private static func mapCancelled(
        _ error: ProjectMoveCancelledError
    ) throws -> EngramServiceProjectMoveResult {
        // Contract 3: only clean compensation maps to successful cancelled state.
        guard error.compensationSucceeded else {
            throw error
        }
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

    private static func resolveExistingOperation(
        operationId: String?,
        fingerprint: String
    ) async throws -> ProjectMoveBatchCancelRegistry.Terminal? {
        guard let operationId else { return nil }
        switch ProjectMoveBatchCancelRegistry.shared.beginOrJoin(
            operationId: operationId,
            fingerprint: fingerprint
        ) {
        case .proceed:
            return nil
        case .completed(let terminal):
            return terminal
        case .join(let wait):
            return try await wait()
        case .fingerprintConflict:
            throw EngramServiceError.invalidRequest(
                message: "operation_id already used with a different project migration request"
            )
        }
    }

    private static func materializeMoveResult(
        _ terminal: ProjectMoveBatchCancelRegistry.Terminal
    ) throws -> EngramServiceProjectMoveResult {
        switch terminal {
        case .success(let data):
            return try JSONDecoder().decode(EngramServiceProjectMoveResult.self, from: data)
        case .failure(let failure):
            throw structuredServiceError(failure)
        }
    }

    private static func materializeJSONValue(
        _ terminal: ProjectMoveBatchCancelRegistry.Terminal
    ) throws -> EngramServiceJSONValue {
        switch terminal {
        case .success(let data):
            return try JSONDecoder().decode(EngramServiceJSONValue.self, from: data)
        case .failure(let failure):
            throw structuredServiceError(failure)
        }
    }

    private static func structuredServiceError(
        _ failure: ProjectMoveBatchCancelRegistry.CachedFailure
    ) -> EngramServiceError {
        var details: [String: EngramServiceJSONValue]?
        if let detailsJSON = failure.detailsJSON,
           let data = detailsJSON.data(using: .utf8),
           let obj = try? JSONDecoder().decode([String: EngramServiceJSONValue].self, from: data)
        {
            details = obj
        }
        switch failure.name {
        case "InvalidRequest", "invalidRequest":
            return .invalidRequest(message: failure.message)
        case "ServiceUnavailable", "serviceUnavailable":
            return .serviceUnavailable(message: failure.message)
        default:
            return .commandFailed(
                name: failure.name,
                message: failure.message,
                retryPolicy: failure.retryPolicy,
                details: details
            )
        }
    }

    private static func completeOperation(
        operationId: String?,
        result: EngramServiceProjectMoveResult
    ) {
        guard let operationId else { return }
        guard let data = try? JSONEncoder().encode(result) else {
            failOperation(
                operationId: operationId,
                error: EngramServiceError.invalidRequest(message: "failed to encode project move result")
            )
            return
        }
        ProjectMoveBatchCancelRegistry.shared.complete(operationId: operationId, payload: data)
        ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId)
    }

    private static func failOperation(operationId: String?, error: Error) {
        guard let operationId else { return }
        let failure = cachedFailure(from: error)
        ProjectMoveBatchCancelRegistry.shared.completeWithFailure(
            operationId: operationId,
            failure: failure
        )
        ProjectMoveBatchCancelRegistry.shared.clear(operationId: operationId)
    }

    private static func cachedFailure(from error: Error) -> ProjectMoveBatchCancelRegistry.CachedFailure {
        if let service = error as? EngramServiceError {
            switch service {
            case .commandFailed(let name, let message, let retryPolicy, let details):
                let detailsJSON: String?
                if let details,
                   let data = try? JSONEncoder().encode(details),
                   let s = String(data: data, encoding: .utf8)
                {
                    detailsJSON = s
                } else {
                    detailsJSON = nil
                }
                return .init(
                    name: name,
                    message: message,
                    retryPolicy: retryPolicy,
                    detailsJSON: detailsJSON
                )
            case .invalidRequest(let message):
                return .init(name: "InvalidRequest", message: message, retryPolicy: "never")
            case .serviceUnavailable(let message):
                return .init(name: "ServiceUnavailable", message: message, retryPolicy: "safe")
            case .transportClosed(let message):
                return .init(name: "TransportClosed", message: message, retryPolicy: "safe")
            case .writerBusy(let message):
                return .init(name: "WriterBusy", message: message, retryPolicy: "safe")
            case .unauthorized(let message):
                return .init(name: "Unauthorized", message: message, retryPolicy: "never")
            case .unsupportedProvider(let provider):
                return .init(name: "UnsupportedProvider", message: provider, retryPolicy: "never")
            }
        }
        if let pm = error as? ProjectMoveError {
            let policy = RetryPolicyClassifier.classify(errorName: pm.errorName).rawValue
            var detailsJSON: String?
            if let details = pm.errorDetails, !details.isEmpty,
               let data = try? JSONEncoder().encode(details),
               let s = String(data: data, encoding: .utf8)
            {
                detailsJSON = s
            }
            return .init(
                name: pm.errorName,
                message: pm.errorMessage,
                retryPolicy: policy,
                detailsJSON: detailsJSON
            )
        }
        return .init(
            name: String(describing: type(of: error)),
            message: error.localizedDescription,
            retryPolicy: "never"
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
