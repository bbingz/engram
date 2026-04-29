import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

final class EngramServiceCommandHandler: @unchecked Sendable {
    private let writerGate: ServiceWriterGate
    private let readProvider: any EngramServiceReadProvider

    init(
        writerGate: ServiceWriterGate,
        readProvider: any EngramServiceReadProvider = EmptyEngramServiceReadProvider()
    ) {
        self.writerGate = writerGate
        self.readProvider = readProvider
    }

    func handle(_ request: EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope {
        do {
            switch request.command {
            case "status":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(EngramServiceStatus.running(total: 0, todayParents: 0))
                )
            case "search":
                let payload = try decodePayload(EngramServiceSearchRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.search(payload))
                )
            case "health":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.health())
                )
            case "liveSessions":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.liveSessions())
                )
            case "sources":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.sources())
                )
            case "skills":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.skills())
                )
            case "memoryFiles":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.memoryFiles())
                )
            case "hooks":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.hooks())
                )
            case "hygiene":
                let payload = try decodePayload(EngramServiceHygieneRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try Self.hygiene(payload))
                )
            case "handoff":
                let payload = try decodePayload(EngramServiceHandoffRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try Self.handoff(payload, databasePath: writerGate.databasePath))
                )
            case "replayTimeline":
                let payload = try decodePayload(EngramServiceReplayTimelineRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.replayTimeline(payload))
                )
            case "embeddingStatus":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.embeddingStatus())
                )
            case "generateSummary":
                let payload = try decodePayload(EngramServiceGenerateSummaryRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.generateSummary(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "saveInsight":
                let payload = try decodePayload(EngramServiceSaveInsightRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.saveInsight(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "manageProjectAlias":
                let payload = try decodePayload(EngramServiceProjectAliasRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.manageProjectAlias(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "resumeCommand":
                let payload = try decodePayload(EngramServiceResumeCommandRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.resumeCommand(payload))
                )
            case "confirmSuggestion":
                let payload = try decodePayload(EngramServiceConfirmSuggestionRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.confirmSuggestion(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "dismissSuggestion":
                let payload = try decodePayload(EngramServiceDismissSuggestionRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.dismissSuggestion(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "projectMigrations":
                let payload = try decodePayload(EngramServiceProjectMigrationsRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.projectMigrations(payload))
                )
            case "projectCwds":
                let payload = try decodePayload(EngramServiceProjectCwdsRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.projectCwds(payload))
                )
            case "triggerSync":
                let payload = try decodePayload(EngramServiceTriggerSyncRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { _ in
                    try Self.triggerSync(payload)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "regenerateAllTitles":
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.regenerateAllTitles(writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "projectMove":
                let payload = try decodePayload(EngramServiceProjectMoveRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try await Self.projectMove(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "projectArchive":
                let payload = try decodePayload(EngramServiceProjectArchiveRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try await Self.projectArchive(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "projectUndo":
                let payload = try decodePayload(EngramServiceProjectUndoRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try await Self.projectUndo(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "projectMoveBatch":
                let payload = try decodePayload(EngramServiceProjectMoveBatchRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try await Self.projectMoveBatch(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "setFavorite":
                let payload = try decodePayload(EngramServiceFavoriteRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.setFavorite(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "setSessionHidden":
                let payload = try decodePayload(EngramServiceSessionHiddenRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.setSessionHidden(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "renameSession":
                let payload = try decodePayload(EngramServiceRenameSessionRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.renameSession(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "hideEmptySessions":
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.hideEmptySessions(writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "linkSessions":
                let payload = try decodePayload(EngramServiceLinkSessionsRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { _ in
                    try Self.linkSessions(payload, databasePath: writerGate.databasePath)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "exportSession":
                let payload = try decodePayload(EngramServiceExportSessionRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { _ in
                    try TranscriptExportService.exportSession(payload, databasePath: writerGate.databasePath)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "test.write_intent":
                let result = try await writerGate.performWriteCommand(name: request.command) { _ in
                    WriteIntentAck(ok: true)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            default:
                return .failure(
                    requestId: request.requestId,
                    error: EngramServiceErrorEnvelope(
                        name: "UnsupportedCommand",
                        message: "Unsupported service command: \(request.command)",
                        retryPolicy: "none",
                        details: ["command": .string(request.command)]
                    )
                )
            }
        } catch let error as EngramServiceError {
            return .failure(
                requestId: request.requestId,
                error: Self.errorEnvelope(error)
            )
        } catch {
            return .failure(
                requestId: request.requestId,
                error: EngramServiceErrorEnvelope(
                    name: "CommandFailed",
                    message: error.localizedDescription,
                    retryPolicy: "safe"
                )
            )
        }
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from request: EngramServiceRequestEnvelope) throws -> T {
        guard let payload = request.payload else {
            throw EngramServiceError.invalidRequest(message: "Missing payload for \(request.command)")
        }
        return try JSONDecoder().decode(type, from: payload)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func errorEnvelope(_ error: EngramServiceError) -> EngramServiceErrorEnvelope {
        switch error {
        case .serviceUnavailable(let message):
            return EngramServiceErrorEnvelope(name: "ServiceUnavailable", message: message, retryPolicy: "safe")
        case .transportClosed(let message):
            return EngramServiceErrorEnvelope(name: "TransportClosed", message: message, retryPolicy: "safe")
        case .invalidRequest(let message):
            return EngramServiceErrorEnvelope(name: "InvalidRequest", message: message, retryPolicy: "never")
        case .unauthorized(let message):
            return EngramServiceErrorEnvelope(name: "Unauthorized", message: message, retryPolicy: "never")
        case .writerBusy(let message):
            return EngramServiceErrorEnvelope(name: "WriterBusy", message: message, retryPolicy: "safe")
        case .unsupportedProvider(let provider):
            return EngramServiceErrorEnvelope(
                name: "UnsupportedProvider",
                message: "Unsupported provider: \(provider)",
                retryPolicy: "none",
                details: ["provider": .string(provider)]
            )
        case .commandFailed(let name, let message, let retryPolicy, let details):
            return EngramServiceErrorEnvelope(
                name: name,
                message: message,
                retryPolicy: retryPolicy,
                details: details
            )
        }
    }

    private static func confirmSuggestion(
        _ request: EngramServiceConfirmSuggestionRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceLinkResponse {
        try writer.write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT suggested_parent_id FROM sessions WHERE id = ?",
                arguments: [request.sessionId]
            )
            guard let row else {
                return EngramServiceLinkResponse(ok: false, error: "session-not-found")
            }
            guard let suggestedParentId = row["suggested_parent_id"] as String?, !suggestedParentId.isEmpty else {
                return EngramServiceLinkResponse(ok: false, error: "no suggestion exists for this session")
            }
            let validation = try validateParentLink(
                db,
                sessionId: request.sessionId,
                parentId: suggestedParentId
            )
            guard validation == "ok" else {
                return EngramServiceLinkResponse(ok: false, error: validation)
            }

            try db.execute(
                sql: """
                    UPDATE sessions
                    SET parent_session_id = ?,
                        link_source = 'manual',
                        suggested_parent_id = NULL
                    WHERE id = ?
                """,
                arguments: [suggestedParentId, request.sessionId]
            )
            return EngramServiceLinkResponse(ok: true, error: nil)
        }
    }

    private static func dismissSuggestion(
        _ request: EngramServiceDismissSuggestionRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET suggested_parent_id = NULL,
                        link_checked_at = datetime('now')
                    WHERE id = ?
                      AND suggested_parent_id = ?
                """,
                arguments: [request.sessionId, request.suggestedParentId]
            )
        }
        return EmptyEncodableResult()
    }

    private static func setFavorite(
        _ request: EngramServiceFavoriteRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        try writer.write { db in
            try ensureAppMetadataTables(db)
            if request.favorite {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO favorites (session_id) VALUES (?)",
                    arguments: [request.sessionId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM favorites WHERE session_id = ?",
                    arguments: [request.sessionId]
                )
            }
        }
        return EmptyEncodableResult()
    }

    private static func setSessionHidden(
        _ request: EngramServiceSessionHiddenRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET hidden_at = \(request.hidden ? "datetime('now')" : "NULL") WHERE id = ?",
                arguments: [request.sessionId]
            )
        }
        return EmptyEncodableResult()
    }

    private static func renameSession(
        _ request: EngramServiceRenameSessionRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        let normalizedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sessions SET custom_name = ? WHERE id = ?",
                arguments: [(normalizedName?.isEmpty == true ? nil : normalizedName), request.sessionId]
            )
        }
        return EmptyEncodableResult()
    }

    private static func hideEmptySessions(writer: EngramDatabaseWriter) throws -> EngramServiceHideEmptySessionsResponse {
        try writer.write { db in
            let before = db.totalChangesCount
            try db.execute(sql: """
                UPDATE sessions
                SET hidden_at = datetime('now')
                WHERE message_count = 0
                  AND size_bytes < 1024
                  AND hidden_at IS NULL
            """)
            return EngramServiceHideEmptySessionsResponse(hiddenCount: db.totalChangesCount - before)
        }
    }

    private static func ensureAppMetadataTables(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS favorites (
                session_id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS tags (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                UNIQUE(session_id, tag)
            );
        """)
    }

    private static func ensureInsightTables(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS insights (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER DEFAULT 5,
              has_embedding INTEGER DEFAULT 0,
              created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_insights_wing ON insights(wing);
            CREATE VIRTUAL TABLE IF NOT EXISTS insights_fts USING fts5(
              insight_id UNINDEXED,
              content
            );
        """)
    }

    private static func ensureProjectAliasTable(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS project_aliases (
              alias TEXT NOT NULL,
              canonical TEXT NOT NULL,
              created_at TEXT NOT NULL DEFAULT (datetime('now')),
              PRIMARY KEY (alias, canonical)
            );
        """)
    }

    private static func validateParentLink(
        _ db: GRDB.Database,
        sessionId: String,
        parentId: String
    ) throws -> String {
        if sessionId == parentId { return "self-link" }

        let parent = try Row.fetchOne(
            db,
            sql: "SELECT id, parent_session_id FROM sessions WHERE id = ?",
            arguments: [parentId]
        )
        guard let parent else { return "parent-not-found" }
        if let existingParent = parent["parent_session_id"] as String?, !existingParent.isEmpty {
            return "depth-exceeded"
        }
        return "ok"
    }

    private static func triggerSync(
        _ request: EngramServiceTriggerSyncRequest
    ) throws -> EngramServiceTriggerSyncResponse {
        EngramServiceTriggerSyncResponse(results: [
            EngramServiceTriggerSyncResponse.ResultItem(
                peer: request.peer,
                ok: false,
                pulled: 0,
                pushed: 0,
                error: "Sync is not implemented in the Swift service"
            )
        ])
    }

    private static func hygiene(
        _ request: EngramServiceHygieneRequest
    ) throws -> EngramServiceHygieneResponse {
        let issues: [EngramServiceHygieneIssue] = []
        return EngramServiceHygieneResponse(
            issues: issues,
            score: issues.isEmpty ? 100 : 80,
            checkedAt: currentTimestamp()
        )
    }

    private static func handoff(
        _ request: EngramServiceHandoffRequest,
        databasePath: String
    ) throws -> EngramServiceHandoffResponse {
        let queue = try DatabaseQueue(path: databasePath, configuration: SQLiteConnectionPolicy.readerConfiguration())
        let normalizedCwd = trimTrailingSlash(request.cwd)
        let projectName = URL(fileURLWithPath: normalizedCwd, isDirectory: true).lastPathComponent

        let rows = try queue.read { db in
            let clauses: String
            let arguments: StatementArguments
            if let sessionId = normalizedOptionalText(request.sessionId, maxLength: 500) {
                clauses = "id = ?"
                arguments = [sessionId]
            } else {
                clauses = "project = ? OR cwd = ?"
                arguments = [projectName, normalizedCwd]
            }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source, start_time, cwd, project, custom_name, generated_title, summary, message_count
                    FROM sessions
                    WHERE \(clauses)
                    ORDER BY start_time DESC
                    LIMIT 20
                """,
                arguments: arguments
            )
        }

        let format = normalizedOptionalText(request.format, maxLength: 20) ?? "markdown"
        let brief: String
        if format == "plain" {
            brief = handoffPlainBrief(projectName: projectName, cwd: normalizedCwd, rows: rows)
        } else {
            brief = handoffMarkdownBrief(projectName: projectName, cwd: normalizedCwd, rows: rows)
        }
        return EngramServiceHandoffResponse(brief: brief, sessionCount: rows.count)
    }

    private static func generateSummary(
        _ request: EngramServiceGenerateSummaryRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceGenerateSummaryResponse {
        try writer.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source, project, cwd, generated_title, custom_name, summary, message_count, start_time
                    FROM sessions
                    WHERE id = ?
                """,
                arguments: [request.sessionId]
            ) else {
                throw EngramServiceError.invalidRequest(message: "Session not found: \(request.sessionId)")
            }

            let summary = nativeSummary(row)
            try db.execute(
                sql: "UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?",
                arguments: [
                    summary,
                    row["message_count"] as Int? ?? 0,
                    request.sessionId
                ]
            )
            return EngramServiceGenerateSummaryResponse(summary: summary)
        }
    }

    private static func saveInsight(
        _ request: EngramServiceSaveInsightRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceJSONValue {
        try writer.write { db in
            try ensureInsightTables(db)

            let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw EngramServiceError.invalidRequest(message: "content is required")
            }
            guard content.count >= 10 else {
                throw EngramServiceError.invalidRequest(message: "content must be at least 10 characters")
            }
            guard content.count <= 50_000 else {
                throw EngramServiceError.invalidRequest(message: "content must be at most 50000 characters")
            }

            let wing = normalizedOptionalText(request.wing, maxLength: 200)
            let room = normalizedOptionalText(request.room, maxLength: 200)
            let importance = try normalizedImportance(request.importance)
            if let duplicate = try findDuplicateInsight(content: content, wing: wing, db: db) {
                return insightJSON(
                    id: duplicate.id,
                    content: duplicate.content,
                    wing: duplicate.wing,
                    room: duplicate.room,
                    importance: duplicate.importance,
                    warning: "Similar insight already exists; returning existing insight"
                )
            }

            let id = UUID().uuidString
            let sourceSessionId = normalizedOptionalText(request.sourceSessionId, maxLength: 500)
            let arguments: [DatabaseValueConvertible?] = [
                id,
                content,
                wing,
                room,
                importance,
                sourceSessionId
            ]
            try db.execute(
                sql: """
                    INSERT INTO insights (id, content, wing, room, importance, source_session_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      content = excluded.content,
                      wing = excluded.wing,
                      room = excluded.room,
                      importance = excluded.importance,
                      source_session_id = excluded.source_session_id
                """,
                arguments: StatementArguments(arguments)
            )
            try db.execute(sql: "DELETE FROM insights_fts WHERE insight_id = ?", arguments: [id])
            try db.execute(
                sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                arguments: [id, content]
            )

            return insightJSON(
                id: id,
                content: content,
                wing: wing,
                room: room,
                importance: importance,
                warning: "Saved without embedding; keyword search is available immediately"
            )
        }
    }

    private static func manageProjectAlias(
        _ request: EngramServiceProjectAliasRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceJSONValue {
        try writer.write { db in
            try ensureProjectAliasTable(db)

            let action = request.action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard action == "add" || action == "remove" else {
                throw EngramServiceError.invalidRequest(message: "Unsupported project alias action: \(request.action)")
            }
            guard let alias = normalizedOptionalText(request.oldProject, maxLength: 1_000),
                  let canonical = normalizedOptionalText(request.newProject, maxLength: 1_000) else {
                throw EngramServiceError.invalidRequest(message: "old_project and new_project are required")
            }

            if action == "add" {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO project_aliases (alias, canonical) VALUES (?, ?)",
                    arguments: [alias, canonical]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM project_aliases WHERE alias = ? AND canonical = ?",
                    arguments: [alias, canonical]
                )
            }

            return .object([
                "ok": .bool(true),
                "action": .string(action),
                "alias": .string(alias),
                "canonical": .string(canonical),
                "actor": .string(normalizedActor(request.actor, defaultActor: "mcp"))
            ])
        }
    }

    private struct ExistingInsight {
        let id: String
        let content: String
        let wing: String?
        let room: String?
        let importance: Int
    }

    private static func findDuplicateInsight(
        content: String,
        wing: String?,
        db: GRDB.Database
    ) throws -> ExistingInsight? {
        let rows: [Row]
        if let wing {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, content, wing, room, importance
                    FROM insights
                    WHERE wing = ?
                    ORDER BY created_at DESC
                    LIMIT 200
                """,
                arguments: [wing]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, content, wing, room, importance
                    FROM insights
                    WHERE wing IS NULL
                    ORDER BY created_at DESC
                    LIMIT 200
                """
            )
        }

        let normalized = normalizeForDedup(content)
        for row in rows where normalizeForDedup(row["content"] as String? ?? "") == normalized {
            return ExistingInsight(
                id: row["id"] as String? ?? "",
                content: row["content"] as String? ?? "",
                wing: row["wing"] as String?,
                room: row["room"] as String?,
                importance: row["importance"] as Int? ?? 5
            )
        }
        return nil
    }

    private static func regenerateAllTitles(
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceRegenerateTitlesResponse {
        try writer.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, custom_name, summary, project, cwd, start_time
                    FROM sessions
                    WHERE generated_title IS NULL OR TRIM(generated_title) = ''
                """
            )
            for row in rows {
                try db.execute(
                    sql: "UPDATE sessions SET generated_title = ? WHERE id = ?",
                    arguments: [nativeTitle(row), row["id"] as String? ?? ""]
                )
            }
            return EngramServiceRegenerateTitlesResponse(status: "completed", total: rows.count, message: nil)
        }
    }

    private static func projectMove(
        _ request: EngramServiceProjectMoveRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
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
        return mapPipelineResult(result, suggestion: nil)
    }

    private static func projectArchive(
        _ request: EngramServiceProjectArchiveRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        // 1. Resolve the archive target. Errors here surface as
        //    ArchiveError.* (LocalizedError) so the IPC payload's `error`
        //    column captures the human-readable message rather than a
        //    generic Cocoa fallback.
        let suggestion = try Archive.suggestTarget(
            src: request.src,
            options: ArchiveOptions(
                archiveRoot: nil,
                skipProbe: request.dryRun,
                forceCategory: request.archiveTo
            )
        )
        // 2. Make sure _archive/<category>/ exists before SafeMoveDir runs;
        //    rename(2) refuses to create intermediate parents.
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
        return mapPipelineResult(pipelineResult, suggestion: suggestion)
    }

    private static func projectUndo(
        _ request: EngramServiceProjectUndoRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceProjectMoveResult {
        // Pre-flight: validate state + compute the swapped src/dst. Throws
        // UndoNotAllowedError / UndoStaleError / .notFound on rejection;
        // those error types stay intact at the IPC boundary.
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
        return mapPipelineResult(pipelineResult, suggestion: nil)
    }

    private static func projectMoveBatch(
        _ request: EngramServiceProjectMoveBatchRequest,
        writer: EngramDatabaseWriter
    ) async throws -> EngramServiceJSONValue {
        // Despite the field name `yaml` (kept for IPC backwards-compat),
        // the Swift batch driver accepts JSON only. The MCP layer is
        // responsible for serialising the payload as JSON.
        let payloadData = Data(request.yaml.utf8)
        let document = try Batch.parseJSON(payloadData)
        let result = await Batch.run(
            document,
            writer: writer,
            overrides: BatchOverrides(force: request.force)
        )
        return encodeBatchResult(result)
    }

    // MARK: - mapping helpers

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
        // Build a JSON document that the MCP layer can pass through to its
        // tool result without further translation. Keep keys snake_case to
        // mirror Node parity (tools/project.ts emits the same shape).
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

    private static func linkSessions(
        _ request: EngramServiceLinkSessionsRequest,
        databasePath: String
    ) throws -> EngramServiceLinkSessionsResponse {
        let normalizedTargetDir = trimTrailingSlash(request.targetDir)
        guard normalizedTargetDir.hasPrefix("/") else {
            return EngramServiceLinkSessionsResponse(
                created: 0,
                skipped: 0,
                errors: ["targetDir must be an absolute path"],
                targetDir: normalizedTargetDir,
                projectNames: [],
                truncated: nil
            )
        }

        let projectName = URL(fileURLWithPath: normalizedTargetDir).lastPathComponent
        let fileManager = FileManager.default
        var configuration = GRDB.Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        let projectNames = try resolveProjectAliases(projectName, queue: queue)
        let cappedProjectNames = projectNames.isEmpty ? [projectName] : projectNames
        let rows = try queue.read { db in
            let placeholders = Array(repeating: "?", count: cappedProjectNames.count).joined(separator: ",")
            let sql = """
            SELECT s.source, COALESCE(ls.local_readable_path, s.file_path) AS file_path
            FROM sessions s
            LEFT JOIN session_local_state ls ON ls.session_id = s.id
            WHERE s.hidden_at IS NULL
              AND s.orphan_status IS NULL
              AND s.project IN (\(placeholders))
            ORDER BY s.start_time DESC
            LIMIT ?
            """
            let values: [DatabaseValueConvertible?] = cappedProjectNames + [10_000]
            let arguments = StatementArguments(values)
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
        }

        var created = 0
        var skipped = 0
        var errors: [String] = []
        var createdDirs = Set<String>()

        for row in rows {
            let source = row["source"] as String? ?? "unknown"
            let filePath = row["file_path"] as String? ?? ""
            guard isAllowedSessionFilePath(filePath, source: source) else {
                errors.append("\(filePath): refusing to link path outside known session roots")
                continue
            }
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            let linkDir = URL(fileURLWithPath: normalizedTargetDir)
                .appendingPathComponent("conversation_log")
                .appendingPathComponent(source)
                .path
            let linkPath = URL(fileURLWithPath: linkDir).appendingPathComponent(fileName).path

            do {
                if let existing = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
                    if existing == filePath {
                        skipped += 1
                        continue
                    }
                    try fileManager.removeItem(atPath: linkPath)
                }

                if !createdDirs.contains(linkDir) {
                    try fileManager.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
                    createdDirs.insert(linkDir)
                }
                try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: filePath)
                created += 1
            } catch {
                errors.append("\(linkPath): \(error.localizedDescription)")
            }
        }

        return EngramServiceLinkSessionsResponse(
            created: created,
            skipped: skipped,
            errors: errors,
            targetDir: normalizedTargetDir,
            projectNames: projectNames,
            truncated: rows.count == 10_000 ? true : nil
        )
    }

    private static func isAllowedSessionFilePath(_ path: String, source: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL.path
        guard standardizedPath == home || standardizedPath.hasPrefix(home + "/") else {
            return false
        }

        if containsSensitivePathComponent(standardizedPath, home: home) {
            return false
        }

        let suffixesBySource: [String: [String]] = [
            "codex": [".codex/sessions", ".codex/logs"],
            "claude-code": [".claude/projects"],
            "pi": [".pi/agent/sessions"],
            "qwen": [".qwen"],
            "iflow": [".iflow"],
            "gemini-cli": [".gemini"],
            "cursor": [
                ".cursor",
                "Library/Application Support/Cursor",
                ".config/Cursor",
            ],
            "windsurf": [
                ".windsurf",
                "Library/Application Support/Windsurf",
                ".config/Windsurf",
            ],
            "vscode": [
                "Library/Application Support/Code/User/globalStorage",
                ".config/Code/User/globalStorage",
            ],
            "cline": [
                "Library/Application Support/Code/User/globalStorage",
                ".config/Code/User/globalStorage",
            ],
            "copilot": [
                "Library/Application Support/Code/User/globalStorage",
                ".config/Code/User/globalStorage",
            ],
            "opencode": [".opencode"],
            "antigravity": [".antigravity"],
            "kimi": [".kimi"],
            "minimax": [".claude/projects", ".minimax"],
            "lobsterai": [".claude/projects", ".lobsterai"],
        ]

        let suffixes = suffixesBySource[source] ?? []
        return suffixes.contains { suffix in
            let allowedRoot = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix)
                .standardizedFileURL
                .path
            return standardizedPath == allowedRoot || standardizedPath.hasPrefix(allowedRoot + "/")
        }
    }

    private static func containsSensitivePathComponent(_ path: String, home: String) -> Bool {
        let relative = path.dropFirst(home.count).split(separator: "/").map(String.init)
        let sensitive = Set([".ssh", ".aws", ".gnupg", ".kube", ".docker", ".1password", "Library/Keychains"])
        return relative.contains { sensitive.contains($0) }
    }

    private static func handoffMarkdownBrief(projectName: String, cwd: String, rows: [Row]) -> String {
        var lines = [
            "## Handoff - \(projectName)",
            "",
            "- CWD: \(cwd)",
            "- Sessions: \(rows.count)"
        ]
        if rows.isEmpty {
            lines.append("- No indexed sessions found.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("### Recent Sessions")
        for row in rows {
            lines.append(
                "- \(nativeTitle(row)) (\(row["source"] as String? ?? "unknown"), \(row["start_time"] as String? ?? "unknown"), messages: \(row["message_count"] as Int? ?? 0))"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func handoffPlainBrief(projectName: String, cwd: String, rows: [Row]) -> String {
        var lines = [
            "Handoff - \(projectName)",
            "CWD: \(cwd)",
            "Sessions: \(rows.count)"
        ]
        for row in rows {
            lines.append(
                "\(nativeTitle(row)) | \(row["source"] as String? ?? "unknown") | \(row["start_time"] as String? ?? "unknown")"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func nativeSummary(_ row: Row) -> String {
        let title = nativeTitle(row)
        let project = row["project"] as String? ?? URL(fileURLWithPath: row["cwd"] as String? ?? "").lastPathComponent
        let source = row["source"] as String? ?? "unknown"
        let messages = row["message_count"] as Int? ?? 0
        let started = row["start_time"] as String? ?? "unknown time"
        return "\(title)\n\nSource: \(source). Project: \(project). Started: \(started). Messages: \(messages)."
    }

    private static func nativeTitle(_ row: Row) -> String {
        if let title = normalizedOptionalText(row["custom_name"] as String?, maxLength: 120) {
            return title
        }
        if let title = normalizedOptionalText(row["generated_title"] as String?, maxLength: 120) {
            return title
        }
        if let summary = normalizedOptionalText(row["summary"] as String?, maxLength: 120) {
            return summary.components(separatedBy: .newlines).first ?? summary
        }
        let project = normalizedOptionalText(row["project"] as String?, maxLength: 80)
            ?? URL(fileURLWithPath: row["cwd"] as String? ?? "").lastPathComponent
        if let started = normalizedOptionalText(row["start_time"] as String?, maxLength: 10) {
            return "\(project) \(started)"
        }
        return row["id"] as String? ?? "Untitled Session"
    }

    private static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func unsupportedNativeCommand(_ command: String) throws -> Never {
        throw EngramServiceError.commandFailed(
            name: "UnsupportedNativeCommand",
            message: "\(command) is not implemented in the Swift service; the legacy daemon bridge has been removed",
            retryPolicy: "never",
            details: ["command": .string(command)]
        )
    }

    private static func normalizedActor(_ actor: String?, defaultActor: String) -> String {
        guard let actor, !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultActor
        }
        return actor
    }

    private static func normalizedOptionalText(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private static func normalizedImportance(_ value: Double?) throws -> Int {
        let rawValue = value ?? 5
        guard rawValue.isFinite else {
            throw EngramServiceError.invalidRequest(message: "importance must be a finite number")
        }
        let importance = Int(rawValue.rounded())
        guard (0...5).contains(importance) else {
            throw EngramServiceError.invalidRequest(message: "importance must be between 0 and 5")
        }
        return importance
    }

    private static func normalizeForDedup(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func insightJSON(
        id: String,
        content: String,
        wing: String?,
        room: String?,
        importance: Int,
        warning: String?
    ) -> EngramServiceJSONValue {
        var object: [String: EngramServiceJSONValue] = [
            "id": .string(id),
            "content": .string(content),
            "importance": .number(Double(importance))
        ]
        if let wing { object["wing"] = .string(wing) }
        if let room { object["room"] = .string(room) }
        if let warning { object["warning"] = .string(warning) }
        return .object(object)
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        if path == "/" { return path }
        return path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    private static func resolveProjectAliases(_ project: String, queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            var queue: [String] = [project]
            var index = 0
            var seen: Set<String> = []
            while index < queue.count {
                let canonical = queue[index]
                index += 1
                guard seen.insert(canonical).inserted else { continue }

                let aliases = try String.fetchAll(
                    db,
                    sql: "SELECT alias FROM project_aliases WHERE canonical = ? ORDER BY alias",
                    arguments: [canonical]
                )
                for alias in aliases where !queue.contains(alias) {
                    queue.append(alias)
                }
            }
            return queue
        }
    }
}

private struct WriteIntentAck: Encodable, Sendable {
    let ok: Bool
}

private struct EmptyEncodableResult: Encodable, Sendable {}
