import Foundation
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static func webProjectMigrations(
        _ request: EngramServiceWebProjectMigrationsRequest,
        readProvider: any EngramServiceReadProvider
    ) async throws -> EngramServiceWebProjectMigrationsResponse {
        let native = try await readProvider.projectMigrations(
            EngramServiceProjectMigrationsRequest(state: request.state, limit: request.limit)
        )
        do {
            return try EngramServiceWebProjectMigrationsResponse(migrations: native.migrations)
        } catch {
            throw EngramServiceError.serviceUnavailable(message: "Web project migrations are unavailable.")
        }
    }

    static func webProjectMove(
        _ request: EngramServiceWebProjectMoveRequest,
        writerGate: ServiceWriterGate
    ) async throws -> ServiceWriterGateResult<EngramServiceWebProjectMoveResponse> {
        try await runWebProjectMove(operationId: request.operationId) {
            try await projectMove(
                EngramServiceProjectMoveRequest(
                    src: request.src,
                    dst: request.dst,
                    dryRun: request.dryRun,
                    force: request.force,
                    auditNote: request.auditNote,
                    actor: "mcp",
                    operationId: try EngramServiceWebProjectValidation.namespacedOperationId(request.operationId)
                ),
                writerGate: writerGate
            )
        }
    }

    static func webProjectArchive(
        _ request: EngramServiceWebProjectArchiveRequest,
        writerGate: ServiceWriterGate
    ) async throws -> ServiceWriterGateResult<EngramServiceWebProjectMoveResponse> {
        try await runWebProjectMove(operationId: request.operationId) {
            try await projectArchive(
                EngramServiceProjectArchiveRequest(
                    src: request.src,
                    archiveTo: request.archiveTo,
                    dryRun: request.dryRun,
                    force: request.force,
                    auditNote: request.auditNote,
                    actor: "mcp",
                    operationId: try EngramServiceWebProjectValidation.namespacedOperationId(request.operationId)
                ),
                writerGate: writerGate
            )
        }
    }

    static func webProjectUndo(
        _ request: EngramServiceWebProjectUndoRequest,
        writerGate: ServiceWriterGate
    ) async throws -> ServiceWriterGateResult<EngramServiceWebProjectMoveResponse> {
        try await runWebProjectMove(operationId: request.operationId) {
            try await projectUndo(
                EngramServiceProjectUndoRequest(
                    migrationId: request.migrationId,
                    force: request.force,
                    actor: "mcp",
                    operationId: try EngramServiceWebProjectValidation.namespacedOperationId(request.operationId)
                ),
                writerGate: writerGate
            )
        }
    }

    static func webProjectMoveBatch(
        _ request: EngramServiceWebProjectMoveBatchRequest,
        writerGate: ServiceWriterGate
    ) async throws -> ServiceWriterGateResult<EngramServiceWebProjectMoveBatchResponse> {
        do {
            let document = try Batch.parseJSON(Data(request.yaml.utf8))
            guard !document.operations.isEmpty,
                  document.operations.count <= EngramServiceWebProjectValidation.maximumBatchOperations else {
                throw EngramServiceError.invalidRequest(message: "batch operations must be between 1 and 100")
            }
        } catch let error as EngramServiceError {
            throw mapWebProjectError(error)
        } catch {
            throw mapWebProjectError(
                EngramServiceError.invalidRequest(message: "batch document is not a bounded native JSON payload")
            )
        }
        do {
            let native = try await projectMoveBatch(
                EngramServiceProjectMoveBatchRequest(
                    yaml: request.yaml,
                    dryRun: request.dryRun,
                    force: request.force,
                    actor: "mcp",
                    operationId: try EngramServiceWebProjectValidation.namespacedOperationId(request.operationId)
                ),
                writerGate: writerGate
            )
            let wrapped = try EngramServiceWebProjectMoveBatchResponse(
                operationId: request.operationId,
                result: native.value
            )
            return ServiceWriterGateResult(value: wrapped, databaseGeneration: native.databaseGeneration)
        } catch {
            throw mapWebProjectError(error)
        }
    }

    static func webCancelProjectMoveBatch(
        _ request: EngramServiceWebCancelProjectMoveBatchRequest
    ) throws -> EngramServiceWebCancelProjectMoveBatchResponse {
        do {
            let namespaced = try EngramServiceWebProjectValidation.namespacedOperationId(request.operationId)
            ProjectMoveBatchCancelRegistry.shared.requestCancel(operationId: namespaced)
            return try EngramServiceWebCancelProjectMoveBatchResponse(
                accepted: true,
                operationId: request.operationId
            )
        } catch {
            throw mapWebProjectError(
                EngramServiceError.invalidRequest(message: "operation_id must be a Web UUID")
            )
        }
    }

    private static func runWebProjectMove(
        operationId: String,
        body: () async throws -> ServiceWriterGateResult<EngramServiceProjectMoveResult>
    ) async throws -> ServiceWriterGateResult<EngramServiceWebProjectMoveResponse> {
        do {
            let native = try await body()
            let wrapped = try EngramServiceWebProjectMoveResponse(
                operationId: operationId,
                result: native.value
            )
            return ServiceWriterGateResult(value: wrapped, databaseGeneration: native.databaseGeneration)
        } catch {
            throw mapWebProjectError(error)
        }
    }

    static func mapWebProjectError(_ error: Error) -> EngramServiceError {
        if let service = error as? EngramServiceError {
            switch service {
            case .commandFailed(let name, _, _, _) where name.hasPrefix("WebProject"):
                return service
            case .invalidRequest(let message):
                return invalidWebProject(message)
            case .commandFailed(let name, let message, _, _) where name == "InvalidRequest":
                return invalidWebProject(message)
            case .serviceUnavailable(let message):
                let capacity = message.contains("capacity")
                return .commandFailed(
                    name: capacity ? "WebProjectCapacity" : "WebProjectUnavailable",
                    message: message,
                    retryPolicy: "later",
                    details: ["category": .string(capacity ? "capacity" : "unavailable")]
                )
            case .writerBusy(let message):
                return .commandFailed(
                    name: "WebProjectCapacity",
                    message: message,
                    retryPolicy: "later",
                    details: ["category": .string("capacity")]
                )
            case .commandFailed(let name, let message, let retry, let details)
                where name == "Cancelled" || message.contains("cancel"):
                return .commandFailed(
                    name: "WebProjectCancelled",
                    message: message,
                    retryPolicy: retry,
                    details: details
                )
            default:
                return .commandFailed(
                    name: "WebProjectUnavailable",
                    message: service.errorDescription ?? "Web project operation failed.",
                    retryPolicy: "later",
                    details: ["category": .string("unavailable")]
                )
            }
        }
        if error is ProjectMoveCancelledError {
            return .commandFailed(
                name: "WebProjectCancelled",
                message: error.localizedDescription,
                retryPolicy: "never",
                details: ["category": .string("cancelled")]
            )
        }
        return .commandFailed(
            name: "WebProjectUnavailable",
            message: "Web project operation failed.",
            retryPolicy: "later",
            details: ["category": .string("unavailable")]
        )
    }

    private static func invalidWebProject(_ message: String) -> EngramServiceError {
        let category: String
        if message.contains("home directory") || message.contains("protected location") {
            category = "Confinement"
        } else if message.contains("operation_id already used") {
            category = "Conflict"
        } else {
            category = "Invalid"
        }
        return .commandFailed(
            name: "WebProject\(category)",
            message: message,
            retryPolicy: "never",
            details: ["category": .string(category.lowercased())]
        )
    }
}
