import Foundation
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static func projectMove(
        _ request: EngramServiceProjectMoveRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        ServiceLogger.notice(
            "projectMove requested actor=\(request.actor ?? "mcp") dryRun=\(request.dryRun) force=\(request.force) src=\(request.src) dst=\(request.dst)",
            category: .writer
        )
        do {
            // SEC-C2: confine before any filesystem work. force never relaxes this.
            try validateProjectMovePaths(src: request.src, dst: request.dst)
            let result = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: RunProjectMoveOptions(
                    src: request.src,
                    dst: request.dst,
                    dryRun: request.dryRun,
                    force: request.force,
                    archived: false,
                    auditNote: request.auditNote,
                    actor: parseActor(request.actor) ?? .mcp,
                    rolledBackOf: nil
                )
            )
            ServiceLogger.notice(
                "projectMove finished migrationId=\(result.migrationId) state=\(result.state.rawValue) filesPatched=\(result.totalFilesPatched) occurrences=\(result.totalOccurrences)",
                category: .writer
            )
            return mapPipelineResult(result, suggestion: nil)
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
            "projectArchive requested actor=\(request.actor ?? "mcp") dryRun=\(request.dryRun) force=\(request.force) src=\(request.src) archiveTo=\(request.archiveTo ?? "")",
            category: .writer
        )
        do {
            // SEC-C2: confine the caller-supplied source before resolving an
            // archive target. force never relaxes this.
            try validateProjectPathConfined(request.src, label: "source")
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
            let pipelineResult = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: RunProjectMoveOptions(
                    src: request.src,
                    dst: suggestion.dst,
                    dryRun: request.dryRun,
                    force: request.force,
                    archived: true,
                    auditNote: request.auditNote,
                    actor: parseActor(request.actor) ?? .mcp,
                    rolledBackOf: nil
                )
            )
            ServiceLogger.notice(
                "projectArchive finished migrationId=\(pipelineResult.migrationId) state=\(pipelineResult.state.rawValue) dst=\(suggestion.dst)",
                category: .writer
            )
            return mapPipelineResult(pipelineResult, suggestion: suggestion)
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
            "projectUndo requested actor=\(request.actor ?? "mcp") force=\(request.force) migrationId=\(request.migrationId)",
            category: .writer
        )
        do {
            // Pre-flight: validate state + compute the swapped src/dst.
            let logReader = GRDBMigrationLogReader(writer: writer)
            let sessionsReader = GRDBSessionByIdReader(writer: writer)
            let reverse = try UndoMigration.prepareReverseRequest(
                migrationId: request.migrationId,
                log: logReader,
                sessions: sessionsReader
            )
            let pipelineResult = try await ProjectMoveOrchestrator.run(
                writer: writer,
                options: RunProjectMoveOptions(
                    src: reverse.src,
                    dst: reverse.dst,
                    dryRun: false,
                    force: request.force,
                    archived: false,
                    auditNote: "undo of \(request.migrationId)",
                    actor: parseActor(request.actor) ?? .mcp,
                    rolledBackOf: reverse.originalMigrationId
                )
            )
            ServiceLogger.notice(
                "projectUndo finished migrationId=\(pipelineResult.migrationId) rolledBackOf=\(reverse.originalMigrationId) state=\(pipelineResult.state.rawValue)",
                category: .writer
            )
            return mapPipelineResult(pipelineResult, suggestion: nil)
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
            "projectMoveBatch requested bytes=\(request.yaml.utf8.count) force=\(request.force)",
            category: .writer
        )
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
            let result = await Batch.run(
                document,
                writer: writer,
                overrides: BatchOverrides(force: request.force)
            )
            ServiceLogger.notice(
                "projectMoveBatch finished completed=\(result.completed.count) failed=\(result.failed.count) skipped=\(result.skipped.count)",
                category: .writer
            )
            return encodeBatchResult(result)
        } catch {
            ServiceLogger.error("projectMoveBatch failed", category: .writer, error: error)
            throw error
        }
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
            own: result.review.own,
            other: result.review.other
        )
        let manifest = result.manifest.map { entry in
            EngramServiceProjectMoveResult.ManifestEntry(
                path: entry.path,
                occurrences: entry.occurrences
            )
        }
        let perSource = result.perSource.map { stats in
            EngramServiceProjectMoveResult.PerSource(
                id: stats.id,
                root: stats.root,
                filesPatched: stats.filesPatched,
                occurrences: stats.occurrences,
                issues: stats.issues.isEmpty ? nil : stats.issues.map { issue in
                    EngramServiceProjectMoveResult.PerSource.WalkIssue(
                        path: issue.path,
                        reason: issue.reason.rawValue,
                        detail: issue.detail
                    )
                }
            )
        }
        let skipped = result.skippedDirs.map { entry in
            EngramServiceProjectMoveResult.SkippedDir(
                sourceId: entry.sourceId.rawValue,
                reason: entry.reason.rawValue,
                dir: nil
            )
        }
        let archive = suggestion.map { s in
            EngramServiceProjectMoveResult.ArchiveSuggestion(
                category: s.category.rawValue,
                dst: s.dst,
                reason: s.reason
            )
        }
        let git = EngramServiceProjectMoveResult.GitStatus(
            isGitRepo: result.git.isGitRepo,
            dirty: result.git.dirty,
            untrackedOnly: result.git.untrackedOnly,
            porcelain: result.git.porcelain
        )
        return EngramServiceProjectMoveResult(
            migrationId: result.migrationId,
            state: result.state.rawValue,
            moveStrategy: result.moveStrategy.rawValue,
            ccDirRenamed: result.ccDirRenamed,
            renamedDirs: result.renamedDirs.map(\.newDir),
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

    private static func encodeBatchResult(_ result: BatchResult) -> EngramServiceJSONValue {
        // Keep keys snake_case to mirror Node parity.
        let completed: [EngramServiceJSONValue] = result.completed.map { pr in
            .object([
                "migration_id": .string(pr.migrationId),
                "state": .string(pr.state.rawValue),
                "src": .string(pr.renamedDirs.first?.oldDir ?? ""),
                "dst": .string(pr.renamedDirs.first?.newDir ?? ""),
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
        return .object([
            "completed": .array(completed),
            "failed": .array(failed),
            "skipped": .array(skipped),
        ])
    }
}
