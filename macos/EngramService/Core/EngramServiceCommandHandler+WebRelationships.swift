import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static func webLinkSession(
        _ request: EngramServiceWebLinkRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebRelationshipMutationResponse {
        try mutateRelationship(writer: writer, settingsURL: settingsURL) { db, sources in
            let child = try authorizeWebSession(db, sessionId: request.sessionId, enabledSources: sources)
            try authorizeWebSession(db, sessionId: request.parentId, enabledSources: sources)
            try authorizeReplacedParents(
                db, child: child, besides: request.parentId, enabledSources: sources
            )
            try applyParentValidation(
                db, sessionId: request.sessionId, parentId: request.parentId
            )
            _ = try applySetParentSession(
                db, sessionId: request.sessionId, parentId: request.parentId
            )
            return try EngramServiceWebRelationshipMutationResponse(
                sessionId: request.sessionId, action: "link", ok: true
            )
        }
    }

    static func webUnlinkSession(
        _ request: EngramServiceWebUnlinkRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebRelationshipMutationResponse {
        try mutateRelationship(writer: writer, settingsURL: settingsURL) { db, sources in
            let child = try authorizeWebSession(db, sessionId: request.sessionId, enabledSources: sources)
            guard let parentId = child.parentId else { throw WebRelationshipFailure.stale }
            try authorizeWebSession(db, sessionId: parentId, enabledSources: sources)
            _ = try applyClearParentSession(db, sessionId: request.sessionId)
            return try EngramServiceWebRelationshipMutationResponse(
                sessionId: request.sessionId, action: "unlink", ok: true
            )
        }
    }

    static func webConfirmSuggestion(
        _ request: EngramServiceWebConfirmSuggestionRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebRelationshipMutationResponse {
        try mutateRelationship(writer: writer, settingsURL: settingsURL) { db, sources in
            let child = try authorizeWebSession(db, sessionId: request.sessionId, enabledSources: sources)
            guard let suggested = child.suggestedParentId,
                  suggested.utf8.elementsEqual(request.suggestedParentId.utf8) else {
                throw WebRelationshipFailure.stale
            }
            try authorizeWebSession(db, sessionId: suggested, enabledSources: sources)
            try authorizeReplacedParents(
                db, child: child, besides: suggested, enabledSources: sources
            )
            try applyParentValidation(db, sessionId: request.sessionId, parentId: suggested)
            guard try applySetParentSession(
                db, sessionId: request.sessionId, parentId: suggested, requiredSuggestedParentId: suggested
            ) > 0 else {
                throw WebRelationshipFailure.stale
            }
            return try EngramServiceWebRelationshipMutationResponse(
                sessionId: request.sessionId, action: "confirmSuggestion", ok: true
            )
        }
    }

    static func webDismissSuggestion(
        _ request: EngramServiceWebDismissSuggestionRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceWebRelationshipMutationResponse {
        try mutateRelationship(writer: writer, settingsURL: settingsURL) { db, sources in
            let child = try authorizeWebSession(db, sessionId: request.sessionId, enabledSources: sources)
            guard let suggested = child.suggestedParentId,
                  suggested.utf8.elementsEqual(request.suggestedParentId.utf8) else {
                throw WebRelationshipFailure.stale
            }
            try authorizeWebSession(db, sessionId: suggested, enabledSources: sources)
            guard try applyDismissSuggestion(
                db, sessionId: request.sessionId, suggestedParentId: suggested
            ) > 0 else {
                throw WebRelationshipFailure.stale
            }
            return try EngramServiceWebRelationshipMutationResponse(
                sessionId: request.sessionId, action: "dismissSuggestion", ok: true
            )
        }
    }

    private static func mutateRelationship(
        writer: EngramDatabaseWriter,
        settingsURL: URL,
        operation: (Database, Set<SourceName>) throws -> EngramServiceWebRelationshipMutationResponse
    ) throws -> EngramServiceWebRelationshipMutationResponse {
        do {
            guard let policy = ServiceCaptureIngestRuntime.policy(at: settingsURL),
                  !policy.enabledSources.isEmpty else {
                throw WebRelationshipFailure.unavailable
            }
            return try writer.write { db in
                try operation(db, policy.enabledSources)
            }
        } catch {
            throw webRelationshipError(error)
        }
    }

    static func authorizeWebSession(
        _ db: Database, sessionId: String, enabledSources: Set<SourceName>
    ) throws -> AuthorizedWebSession {
        let sources = enabledSources.map(\.rawValue).sorted()
        guard !sources.isEmpty,
              try db.tableExists("capture_ingest_identity_bindings"),
              try db.tableExists("capture_ingest_source_registry"),
              try db.tableExists("capture_ingest_epoch_history") else {
            throw WebRelationshipFailure.unavailable
        }
        let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = sources
        arguments.append(sessionId)
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.parent_session_id, s.suggested_parent_id, s.source,
                   i.machine_id, i.source_instance_id
            FROM capture_ingest_identity_bindings i
            JOIN sessions s ON s.id = i.stored_session_id COLLATE BINARY
            JOIN capture_ingest_source_registry r
              ON r.machine_id = i.machine_id COLLATE BINARY
              AND r.source_instance_id = i.source_instance_id COLLATE BINARY
              AND r.source = i.source COLLATE BINARY
            JOIN capture_ingest_epoch_history h
              ON h.machine_id = r.machine_id COLLATE BINARY
              AND h.source_instance_id = r.source_instance_id COLLATE BINARY
              AND h.authority_generation = r.authority_generation
              AND h.approved_epoch = r.approved_epoch COLLATE BINARY
            WHERE i.source IN (\(placeholders))
              AND s.id = ? COLLATE BINARY
              AND s.hidden_at IS NULL
              AND (s.tier IS NULL OR s.tier != 'skip')
              AND s.source = i.source COLLATE BINARY
              AND s.authoritative_node = ('capture-v1.' || i.machine_id || '.' || i.source_instance_id) COLLATE BINARY
            """, arguments: StatementArguments(arguments)) else {
            throw WebRelationshipFailure.unavailable
        }
        let machineID: String = row["machine_id"]
        let instanceID: String = row["source_instance_id"]
        let binding: CaptureIngestSourceBinding
        do {
            guard let value = try CaptureIngestSourceRegistry.binding(
                db, machineID: machineID, sourceInstanceID: instanceID
            ), enabledSources.contains(value.source) else {
                throw WebRelationshipFailure.unavailable
            }
            binding = value
        } catch let failure as WebRelationshipFailure {
            throw failure
        } catch is CaptureIngestSourceRegistryError {
            throw WebRelationshipFailure.unavailable
        }
        guard let sessionSource = optionalText(row["source"]),
              sessionSource.utf8.elementsEqual(binding.source.rawValue.utf8) else {
            throw WebRelationshipFailure.unavailable
        }
        return AuthorizedWebSession(
            parentId: optionalText(row["parent_session_id"]),
            suggestedParentId: optionalText(row["suggested_parent_id"])
        )
    }

    private static func authorizeReplacedParents(
        _ db: Database,
        child: AuthorizedWebSession,
        besides: String,
        enabledSources: Set<SourceName>
    ) throws {
        var seen = Set<String>([besides])
        for id in [child.parentId, child.suggestedParentId].compactMap({ $0 }) {
            if seen.insert(id).inserted {
                try authorizeWebSession(db, sessionId: id, enabledSources: enabledSources)
            }
        }
    }

    private static func applyParentValidation(
        _ db: Database, sessionId: String, parentId: String
    ) throws {
        let validation = try validateParentLink(db, sessionId: sessionId, parentId: parentId)
        switch validation {
        case "ok":
            return
        case "self-link", "depth-exceeded":
            throw WebRelationshipFailure.invalid
        default:
            throw WebRelationshipFailure.unavailable
        }
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func webRelationshipError(_ error: Error) -> EngramServiceError {
        if let service = error as? EngramServiceError { return service }
        switch error as? WebRelationshipFailure {
        case .invalid:
            return .invalidRequest(message: "Web relationship request is invalid.")
        case .stale:
            return .commandFailed(
                name: "StaleCursor",
                message: "Web relationship authorization is stale.",
                retryPolicy: "never",
                details: nil
            )
        case .unavailable, .none:
            return .serviceUnavailable(message: "Web relationship service is unavailable.")
        }
    }

    struct AuthorizedWebSession {
        let parentId: String?
        let suggestedParentId: String?
    }

    private enum WebRelationshipFailure: Error {
        case invalid
        case stale
        case unavailable
    }
}
