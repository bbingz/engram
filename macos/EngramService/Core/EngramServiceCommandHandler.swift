import Foundation
import GRDB
import CryptoKit
import EngramCoreRead
import EngramCoreWrite
import Security

final class EngramServiceCommandHandler: @unchecked Sendable {
    private static let titleRegenerationCoordinator = ServiceTitleRegenerationCoordinator()

    private let writerGate: ServiceWriterGate
    private let readProvider: any EngramServiceReadProvider
    private let statusMonitor: ServiceStatusMonitor
    private let telemetry: ServiceTelemetryCollector?
    private let logRing: ServiceLogRing?
    private let usageNow: @Sendable () -> Date
    private let usageTokenLimitsProvider: @Sendable () -> [String: StartupUsageTokenLimits]
    private let usageEmitter: @Sendable ([StartupUsageSnapshot]) -> Void

    /// Commands excluded from telemetry span recording: `status` is a poll the
    /// app/launcher fires continuously (would drown out real signal), `telemetry`
    /// reads the collector itself (self-noise), `costs` is the menu-bar budget
    /// poll that fires on a timer (would fill the 200-span ring buffer), and
    /// `serviceLogs` reads the log ring (self-noise + Observability polls it).
    private static let telemetryExcludedCommands: Set<String> = ["status", "telemetry", "costs", "serviceLogs"]

    private static let emptyTelemetrySnapshot = ServiceTelemetrySnapshot(
        lastScanDurationMs: nil,
        lastScanIndexed: 0,
        lastScanTotal: 0,
        scanCount: 0,
        lastScanAt: nil,
        commands: [],
        spans: []
    )

    private static let emptyLogSnapshot = ServiceLogSnapshot(lines: [])

    init(
        writerGate: ServiceWriterGate,
        readProvider: any EngramServiceReadProvider = EmptyEngramServiceReadProvider(),
        statusMonitor: ServiceStatusMonitor = ServiceStatusMonitor(),
        telemetry: ServiceTelemetryCollector? = nil,
        logRing: ServiceLogRing? = nil,
        usageNow: @escaping @Sendable () -> Date = { Date() },
        usageTokenLimitsProvider: @escaping @Sendable () -> [String: StartupUsageTokenLimits] = {
            EngramServiceRunner.readUsageTokenLimits(environment: ProcessInfo.processInfo.environment)
        },
        usageEmitter: @escaping @Sendable ([StartupUsageSnapshot]) -> Void = { snapshots in
            EngramServiceRunner.emitUsageSnapshots(snapshots)
        }
    ) {
        self.writerGate = writerGate
        self.readProvider = readProvider
        self.statusMonitor = statusMonitor
        self.telemetry = telemetry
        self.logRing = logRing
        self.usageNow = usageNow
        self.usageTokenLimitsProvider = usageTokenLimitsProvider
        self.usageEmitter = usageEmitter
    }

    func handle(_ request: EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope {
        guard let telemetry, !Self.telemetryExcludedCommands.contains(request.command) else {
            return await dispatch(request)
        }
        let clock = ContinuousClock()
        let started = clock.now
        // Capture the wall-clock start BEFORE dispatch so the span's `startedAt`
        // reflects when the command began, not when telemetry recorded it.
        let startedAt = Self.currentTimestamp()
        let response = await dispatch(request)
        let elapsed = started.duration(to: clock.now).components
        let durationMs = Double(elapsed.seconds) * 1000
            + Double(elapsed.attoseconds) / 1e15
        let (ok, errorName): (Bool, String?)
        switch response {
        case .success:
            (ok, errorName) = (true, nil)
        case .failure(_, let error):
            (ok, errorName) = (false, error.name)
        }
        await telemetry.record(
            span: ServiceSpan(
                command: request.command,
                startedAt: startedAt,
                durationMs: durationMs,
                ok: ok,
                errorName: errorName
            )
        )
        return response
    }

    private func dispatch(_ request: EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope {
        do {
            switch request.command {
            case "status":
                let status = try await writerGate.indexStatus()
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(await statusMonitor.status(indexStatus: status))
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
            case "memoryFileContent":
                let payload = try decodePayload(EngramServiceMemoryFileContentRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.memoryFileContent(payload))
                )
            case "hooks":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.hooks())
                )
            case "insights":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.insights())
                )
            case "insightDetail":
                let payload = try decodePayload(EngramServiceInsightDetailRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.insightDetail(payload))
                )
            case "costs":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try await readProvider.costs())
                )
            case "telemetry":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(await (telemetry?.snapshot() ?? Self.emptyTelemetrySnapshot))
                )
            case "serviceLogs":
                // READ command: returns the sanitized in-process log ring. No
                // capability token (it never mutates state); the ring sanitizes
                // every line before storage so this surfaces no raw paths/ids.
                let payload = try? decodePayload(EngramServiceServiceLogsRequest.self, from: request)
                let snapshot = await logRing?.snapshot(
                    level: payload?.level,
                    category: payload?.category,
                    limit: payload?.limit
                ) ?? Self.emptyLogSnapshot
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(snapshot)
                )
            case "hygiene":
                let payload = try decodePayload(EngramServiceHygieneRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(try Self.hygiene(payload, databasePath: writerGate.databasePath))
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
            case "generateSummary":
                let payload = try decodePayload(EngramServiceGenerateSummaryRequest.self, from: request)
                let result = try await Self.generateSummary(payload, writerGate: writerGate)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "generateProjectWorkTitles":
                let payload = try decodePayload(EngramServiceGenerateProjectWorkTitlesRequest.self, from: request)
                let result = try await Self.generateProjectWorkTitles(payload, writerGate: writerGate)
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
            case "deleteInsight":
                let payload = try decodePayload(EngramServiceDeleteInsightRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.deleteInsight(payload, writer: writer)
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
            case "setParentSession":
                let payload = try decodePayload(EngramServiceLinkRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.setParentSession(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "clearParentSession":
                let payload = try decodePayload(EngramServiceUnlinkRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.clearParentSession(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
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
            case "addSessionRelation":
                let payload = try decodePayload(EngramServiceRelationRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.addSessionRelation(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "removeSessionRelation":
                let payload = try decodePayload(EngramServiceRelationRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.removeSessionRelation(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "relatedSessions":
                let payload = try decodePayload(EngramServiceRelatedSessionsRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(
                        try Self.relatedSessions(payload, databasePath: writerGate.databasePath)
                    )
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
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(Self.triggerSync(payload))
                )
            case "refreshUsage":
                let result = try await EngramServiceRunner.collectUsageResult(
                    gate: writerGate,
                    now: usageNow,
                    tokenLimits: usageTokenLimitsProvider(),
                    emit: usageEmitter
                )
                let sources = Array(Set(result.value.map(\.source))).sorted()
                let pressure = result.value
                    .filter(Self.isUsagePressureAlert)
                    .map(Self.serviceUsageItem)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(
                        EngramServiceRefreshUsageResponse(
                            snapshotCount: result.value.count,
                            sources: sources,
                            pressure: pressure
                        )
                    ),
                    databaseGeneration: result.databaseGeneration
                )
            case "regenerateAllTitles":
                let result = try await Self.regenerateAllTitles(writerGate: writerGate)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result)
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
            case "setSourceEnabled":
                let payload = try decodePayload(EngramServiceSetSourceEnabledRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.setSourceEnabled(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "disabledSources":
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(Self.disabledSources())
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
            case "recordSessionAccess":
                let payload = try decodePayload(EngramServiceSessionAccessRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.recordSessionAccess(payload, writer: writer)
                }
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(result.value),
                    databaseGeneration: result.databaseGeneration
                )
            case "recordInsightAccess":
                let payload = try decodePayload(EngramServiceInsightAccessRequest.self, from: request)
                let result = try await writerGate.performWriteCommand(name: request.command) { writer in
                    try Self.recordInsightAccess(payload, writer: writer)
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
                // linkSessions only reads through an independent read-only
                // DatabaseQueue and then creates filesystem symlinks; it never
                // writes the database. Running it through the single write gate
                // held that gate for up to 10k filesystem symlink operations,
                // blocking every real DB write behind pure FS work. Run it
                // outside the gate. The per-path symlink logic is idempotent
                // (createDirectory withIntermediateDirectories + remove-then-
                // recreate per file), so concurrent calls are self-correcting.
                let payload = try decodePayload(EngramServiceLinkSessionsRequest.self, from: request)
                let value = try Self.linkSessions(payload, databasePath: writerGate.databasePath)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(value)
                )
            case "exportSession":
                let payload = try decodePayload(EngramServiceExportSessionRequest.self, from: request)
                return .success(
                    requestId: request.requestId,
                    result: try Self.encode(
                        try await TranscriptExportService.exportSession(payload, databasePath: writerGate.databasePath)
                    )
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
            case "remoteOffload":
                let result = try await Self.remoteOffloadNow(writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
            case "remoteRehydrate":
                let payload = try decodePayload(EngramServiceRemoteRehydrateRequest.self, from: request)
                let result = try await Self.remoteRehydrateNow(payload, writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
            case "remoteSyncStatus":
                let result = try await Self.remoteSyncStatus(writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
            case "remoteProjectSyncPreview":
                let payload = try decodePayload(EngramServiceRemoteProjectSyncRequest.self, from: request)
                let result = try await Self.remoteProjectSyncPreview(payload, writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
            case "remotePushProject":
                let payload = try decodePayload(EngramServiceRemoteProjectSyncRequest.self, from: request)
                let result = try await Self.remotePushProject(payload, writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
            case "remotePullProject":
                let payload = try decodePayload(EngramServiceRemoteProjectSyncRequest.self, from: request)
                let result = try await Self.remotePullProject(payload, writerGate: writerGate)
                return .success(requestId: request.requestId, result: try Self.encode(result))
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
                error: Self.genericErrorEnvelope(error)
            )
        }
    }

    /// Map an otherwise-unclassified thrown error to an envelope. A FTS5/SQL
    /// syntax error (e.g. a malformed `MATCH` query) is deterministic: the same
    /// input always fails, so retrying is futile — tag it `"never"`. All other
    /// failures keep the conservative `"safe"` default so transient I/O can be
    /// retried.
    static func genericErrorEnvelope(_ error: Error) -> EngramServiceErrorEnvelope {
        if isSyntaxError(error) {
            return EngramServiceErrorEnvelope(
                name: "QuerySyntaxError",
                message: error.localizedDescription,
                retryPolicy: "never"
            )
        }
        return EngramServiceErrorEnvelope(
            name: "CommandFailed",
            message: error.localizedDescription,
            retryPolicy: "safe"
        )
    }

    static func isSyntaxError(_ error: Error) -> Bool {
        guard let dbError = error as? DatabaseError else { return false }
        // SQLITE_ERROR covers both generic SQL syntax errors and FTS5 query
        // syntax errors ("fts5: syntax error near ..."). Both are caused by the
        // query string itself, not by transient state.
        guard dbError.resultCode == .SQLITE_ERROR else { return false }
        let message = (dbError.message ?? "").lowercased()
        // FTS5/SQL query errors are all deterministic — the same query string
        // always fails — so retrying is futile. SQLite phrases them several ways:
        //   "fts5: syntax error near ..."   (malformed MATCH operators)
        //   "unterminated string"           (unbalanced quote in MATCH)
        //   "no such column: x"             (column filter on a missing column)
        //   "unrecognized token: ..."       (illegal characters)
        return message.contains("syntax error")
            || message.contains("fts5")
            || message.contains("unterminated")
            || message.contains("no such column")
            || message.contains("unrecognized token")
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

    private static func isUsagePressureAlert(_ snapshot: StartupUsageSnapshot) -> Bool {
        switch snapshot.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "attention", "critical":
            return true
        default:
            return false
        }
    }

    private static func serviceUsageItem(_ snapshot: StartupUsageSnapshot) -> EngramServiceUsageItem {
        EngramServiceUsageItem(
            source: snapshot.source,
            metric: snapshot.metric,
            value: snapshot.value,
            unit: snapshot.unit,
            limit: snapshot.limit,
            resetAt: snapshot.resetAt,
            status: snapshot.status
        )
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
                        link_checked_at = datetime('now'),
                        suggested_parent_id = NULL
                    WHERE id = ?
                """,
                arguments: [suggestedParentId, request.sessionId]
            )
            return EngramServiceLinkResponse(ok: true, error: nil)
        }
    }

    private static func setParentSession(
        _ request: EngramServiceLinkRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceLinkResponse {
        try writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?", arguments: [request.sessionId]) != nil else {
                return EngramServiceLinkResponse(ok: false, error: "session-not-found")
            }
            let validation = try validateParentLink(db, sessionId: request.sessionId, parentId: request.parentId)
            guard validation == "ok" else {
                return EngramServiceLinkResponse(ok: false, error: validation)
            }
            try db.execute(
                sql: """
                    UPDATE sessions
                    SET parent_session_id = ?,
                        link_source = 'manual',
                        suggested_parent_id = NULL,
                        link_checked_at = datetime('now')
                    WHERE id = ?
                """,
                arguments: [request.parentId, request.sessionId]
            )
            return EngramServiceLinkResponse(ok: true, error: nil)
        }
    }

    private static func clearParentSession(
        _ request: EngramServiceUnlinkRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceLinkResponse {
        try writer.write { db in
            let changed = try db.executeAndCountChanges(
                sql: """
                    UPDATE sessions
                    SET parent_session_id = NULL,
                        link_source = 'manual',
                        link_checked_at = datetime('now'),
                        tier = CASE
                            WHEN agent_role = 'subagent' THEN 'skip'
                            ELSE NULL
                        END
                    WHERE id = ?
                """,
                arguments: [request.sessionId]
            )
            return EngramServiceLinkResponse(ok: changed > 0, error: changed > 0 ? nil : "session-not-found")
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

    /// Symmetric, untyped "related" link. Normalizes the pair to a_id < b_id so
    /// either order maps to one row (dedup-safe). Validates both sessions exist
    /// and rejects self-links. Navigational only — no tier/grouping/count impact.
    private static func addSessionRelation(
        _ request: EngramServiceRelationRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceLinkResponse {
        guard request.aId != request.bId else {
            return EngramServiceLinkResponse(ok: false, error: "self-link")
        }
        let (low, high) = request.aId < request.bId
            ? (request.aId, request.bId)
            : (request.bId, request.aId)
        return try writer.write { db in
            try ensureSessionRelationsTable(db)
            for id in [low, high] {
                guard try Row.fetchOne(db, sql: "SELECT id FROM sessions WHERE id = ?", arguments: [id]) != nil else {
                    return EngramServiceLinkResponse(ok: false, error: "session-not-found")
                }
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO session_relations (a_id, b_id) VALUES (?, ?)",
                arguments: [low, high]
            )
            return EngramServiceLinkResponse(ok: true, error: nil)
        }
    }

    private static func removeSessionRelation(
        _ request: EngramServiceRelationRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceLinkResponse {
        let (low, high) = request.aId < request.bId
            ? (request.aId, request.bId)
            : (request.bId, request.aId)
        return try writer.write { db in
            try ensureSessionRelationsTable(db)
            try db.execute(
                sql: "DELETE FROM session_relations WHERE a_id = ? AND b_id = ?",
                arguments: [low, high]
            )
            return EngramServiceLinkResponse(ok: true, error: nil)
        }
    }

    /// Read-only: ids related to `sessionId` in either direction. The IN-join is
    /// against `sessions` at read time on the app side, so dangling rows (where a
    /// peer no longer exists) are filtered out naturally there; here we just
    /// return the stored peer ids. Returns [] if the table was never created.
    static func relatedSessions(
        _ request: EngramServiceRelatedSessionsRequest,
        databasePath: String
    ) throws -> EngramServiceRelatedSessionsResponse {
        let pool = try readOnlyPool(path: databasePath)
        let ids = try pool.read { db -> [String] in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_relations'"
            ) ?? false
            guard exists else { return [] }
            return try String.fetchAll(
                db,
                sql: """
                    SELECT b_id FROM session_relations WHERE a_id = ?
                    UNION
                    SELECT a_id FROM session_relations WHERE b_id = ?
                """,
                arguments: [request.sessionId, request.sessionId]
            )
        }
        return EngramServiceRelatedSessionsResponse(ids: ids)
    }

    private static func ensureSessionRelationsTable(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_relations (
                a_id TEXT NOT NULL,
                b_id TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (a_id, b_id)
            );
        """)
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
            try ensureSessionLocalStateTable(db)
            let changed = try db.executeAndCountChanges(
                sql: "UPDATE sessions SET hidden_at = \(request.hidden ? "datetime('now')" : "NULL") WHERE id = ?",
                arguments: [request.sessionId]
            )
            guard changed > 0 else {
                throw EngramServiceError.commandFailed(
                    name: "SessionNotFound",
                    message: "session-not-found",
                    retryPolicy: "never",
                    details: ["session_id": .string(request.sessionId)]
                )
            }
            let hiddenAt = try String.fetchOne(
                db,
                sql: "SELECT hidden_at FROM sessions WHERE id = ?",
                arguments: [request.sessionId]
            )
            try db.execute(
                sql: """
                    INSERT INTO session_local_state (session_id, hidden_at)
                    VALUES (?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET hidden_at = excluded.hidden_at
                """,
                arguments: [request.sessionId, hiddenAt]
            )
        }
        return EmptyEncodableResult()
    }

    /// Feature #2 slice B — per-source ingest control (TRUE stop-indexing).
    ///
    /// Disabling a source (`enabled == false`) adds it to the `disabledSources`
    /// array in `~/.engram/settings.json` AND hides its already-indexed sessions.
    /// Enabling removes it from the array AND unhides its sessions. Re-ingesting
    /// of NEW sessions resumes on the next service scan, because the adapter
    /// filter is read at scan time (`EngramServiceRunner.readDisabledSources`),
    /// not here. Settings are updated read-modify-write so all other keys are
    /// preserved; the file is created with a minimal object when absent.
    private static func setSourceEnabled(
        _ request: EngramServiceSetSourceEnabledRequest,
        writer: EngramDatabaseWriter,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        )
    ) throws -> EngramServiceLinkResponse {
        let source = request.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw EngramServiceError.commandFailed(
                name: "InvalidSource",
                message: "source-required",
                retryPolicy: "never",
                details: nil
            )
        }
        try updateDisabledSourcesSetting(source: source, enabled: request.enabled, settingsURL: settingsURL)
        try writer.write { db in
            if request.enabled {
                try db.execute(
                    sql: "UPDATE sessions SET hidden_at = NULL WHERE source = ?",
                    arguments: [source]
                )
            } else {
                try db.execute(
                    sql: "UPDATE sessions SET hidden_at = datetime('now') WHERE source = ? AND hidden_at IS NULL",
                    arguments: [source]
                )
            }
        }
        return EngramServiceLinkResponse(ok: true, error: nil)
    }

    /// Read-modify-write the `disabledSources` array, preserving every other key.
    private static func updateDisabledSourcesSetting(
        source: String,
        enabled: Bool,
        settingsURL: URL
    ) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        var disabled = (object["disabledSources"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        if enabled {
            disabled.removeAll { $0 == source }
        } else if !disabled.contains(source) {
            disabled.append(source)
        }
        object["disabledSources"] = disabled
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: [.atomic])
    }

    /// Current per-source ingest opt-out set (read path, no token required).
    private static func disabledSources(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EngramServiceDisabledSourcesResponse {
        let sources = EngramServiceRunner.readDisabledSources(environment: environment)
        return EngramServiceDisabledSourcesResponse(sources: sources.sorted())
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

    private static func recordSessionAccess(
        _ request: EngramServiceSessionAccessRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        try writer.write { db in
            let changed = try db.executeAndCountChanges(
                sql: """
                    UPDATE sessions
                    SET last_accessed_at = datetime('now'),
                        access_count = COALESCE(access_count, 0) + 1
                    WHERE id = ?
                """,
                arguments: [request.sessionId]
            )
            guard changed > 0 else {
                throw EngramServiceError.commandFailed(
                    name: "SessionNotFound",
                    message: "session-not-found",
                    retryPolicy: "never",
                    details: ["session_id": .string(request.sessionId)]
                )
            }
            // Read-path lazy rehydrate: accessing (opening) an offloaded session
            // queues it to be pulled back so its full keyword search is restored.
            // No-op unless the session is currently offloaded. The raw transcript
            // is still on disk, so the detail view is never blocked on this.
            _ = try OffloadRepo.enqueueRehydrate(db, sessionId: request.sessionId)
        }
        return EmptyEncodableResult()
    }

    private static func recordInsightAccess(
        _ request: EngramServiceInsightAccessRequest,
        writer: EngramDatabaseWriter
    ) throws -> EmptyEncodableResult {
        let ids = Array(Set(request.ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return EmptyEncodableResult() }

        try writer.write { db in
            try ensureInsightTables(db)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: """
                    UPDATE insights
                    SET last_accessed_at = datetime('now'),
                        access_count = COALESCE(access_count, 0) + 1
                    WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(ids)
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

    private static func ensureSessionLocalStateTable(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_local_state (
                session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                hidden_at TEXT,
                custom_name TEXT,
                local_readable_path TEXT
            );
        """)
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(session_local_state)")
        let columns = Set(rows.compactMap { $0["name"] as String? })
        if !columns.contains("hidden_at") {
            try db.execute(sql: "ALTER TABLE session_local_state ADD COLUMN hidden_at TEXT")
        }
        if !columns.contains("custom_name") {
            try db.execute(sql: "ALTER TABLE session_local_state ADD COLUMN custom_name TEXT")
        }
        if !columns.contains("local_readable_path") {
            try db.execute(sql: "ALTER TABLE session_local_state ADD COLUMN local_readable_path TEXT")
        }
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
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(insights)")
        let columns = Set(rows.compactMap { $0["name"] as String? })
        if !columns.contains("insight_type") {
            try db.execute(sql: "ALTER TABLE insights ADD COLUMN insight_type TEXT DEFAULT 'semantic'")
        }
        if !columns.contains("superseded_by") {
            try db.execute(sql: "ALTER TABLE insights ADD COLUMN superseded_by TEXT")
        }
        if !columns.contains("last_accessed_at") {
            try db.execute(sql: "ALTER TABLE insights ADD COLUMN last_accessed_at TEXT")
        }
        if !columns.contains("access_count") {
            try db.execute(sql: "ALTER TABLE insights ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_insights_superseded ON insights(superseded_by)")
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
        let childCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions WHERE parent_session_id = ? LIMIT 1",
            arguments: [sessionId]
        ) ?? 0
        if childCount > 0 {
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

    // `internal` (not `private`) so HygieneChecksTests can call it directly
    // under @testable import, mirroring readAIContext's access level.
    static func hygiene(
        _ request: EngramServiceHygieneRequest,
        databasePath: String
    ) throws -> EngramServiceHygieneResponse {
        // Real read-only DB scan. `force` no longer branches behavior — every
        // call re-scans live state. On a read failure return a single
        // severity:"error" issue rather than throwing, so the page degrades
        // gracefully (HygieneView renders error issues through its red-card path).
        do {
            let queue = try DatabaseQueue(
                path: databasePath,
                configuration: ServiceSQLiteConnectionPolicy.readerConfiguration()
            )
            let counts = try queue.read { db -> (empty: Int, suggestions: Int, orphans: Int) in
                let empty = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sessions
                    WHERE message_count = 0 AND size_bytes < 1024 AND hidden_at IS NULL
                """) ?? 0
                let suggestions = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sessions
                    WHERE suggested_parent_id IS NOT NULL
                      AND parent_session_id IS NULL
                      AND hidden_at IS NULL
                """) ?? 0
                let orphans = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM sessions
                    WHERE orphan_status IS NOT NULL AND orphan_status != ''
                      AND hidden_at IS NULL
                """) ?? 0
                return (empty, suggestions, orphans)
            }

            var issues: [EngramServiceHygieneIssue] = []
            if counts.empty > 0 {
                issues.append(
                    EngramServiceHygieneIssue(
                        kind: "empty-sessions",
                        severity: "warning",
                        message: "\(counts.empty) empty session(s) clutter the index",
                        detail: "Sessions with no messages and a tiny payload. Hide them to keep search results clean.",
                        repo: nil,
                        action: nil
                    )
                )
            }
            if counts.suggestions > 0 {
                issues.append(
                    EngramServiceHygieneIssue(
                        kind: "pending-suggestions",
                        severity: "info",
                        message: "\(counts.suggestions) suggested parent link(s) awaiting review",
                        detail: "Advisory groupings detected heuristically. Confirm or dismiss them from the session view.",
                        repo: nil,
                        action: nil
                    )
                )
            }
            if counts.orphans > 0 {
                issues.append(
                    EngramServiceHygieneIssue(
                        kind: "orphans",
                        severity: "warning",
                        message: "\(counts.orphans) orphaned session(s)",
                        detail: "Sessions whose parent or source link could not be resolved.",
                        repo: nil,
                        action: nil
                    )
                )
            }

            let score = max(0, min(100, 100 - 2 * counts.empty - counts.suggestions - 5 * counts.orphans))
            return EngramServiceHygieneResponse(
                issues: issues,
                score: score,
                checkedAt: currentTimestamp()
            )
        } catch {
            return EngramServiceHygieneResponse(
                issues: [
                    EngramServiceHygieneIssue(
                        kind: "hygiene-error",
                        severity: "error",
                        message: "Could not read the index for hygiene checks",
                        detail: error.localizedDescription,
                        repo: nil,
                        action: nil
                    )
                ],
                score: 0,
                checkedAt: currentTimestamp()
            )
        }
    }

    private static func handoff(
        _ request: EngramServiceHandoffRequest,
        databasePath: String
    ) throws -> EngramServiceHandoffResponse {
        let queue = try DatabaseQueue(path: databasePath, configuration: ServiceSQLiteConnectionPolicy.readerConfiguration())
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
        writerGate: ServiceWriterGate
    ) async throws -> ServiceWriterGateResult<EngramServiceGenerateSummaryResponse> {
        let context = try readAIContext(sessionId: request.sessionId, databasePath: writerGate.databasePath)
        let settings = ServiceAISettings.read()
        let summary: String
        if let config = settings.summaryConfig {
            summary = try await ServiceAIClient.summarize(context: context, config: config)
        } else {
            summary = context.nativeSummary
        }
        return try await writerGate.performWriteCommand(name: "generateSummary") { writer in
            try writer.write { db in
                try db.execute(
                    sql: "UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?",
                    arguments: [
                        summary,
                        context.messageCount,
                        request.sessionId
                    ]
                )
            }
            return EngramServiceGenerateSummaryResponse(summary: summary)
        }
    }

    /// Lowercase hex SHA256 of (intent + U+0001 + outcome). Stable cache key for
    /// a work item's semantic title; regenerate only when the underlying
    /// intent/outcome text changes. NEVER use Swift `hashValue` for this.
    private static func intentHash(intent: String, outcome: String) -> String {
        let digest = SHA256.hash(data: Data((intent + "\u{1}" + outcome).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// On-demand per-project work-item semantic titles. Mirrors `generateSummary`:
    /// AI/network calls happen OUTSIDE the writer gate; only the short upsert
    /// runs inside it. With no title AI config the command is a no-op (it does
    /// NOT persist heuristic titles) so the app keeps its heuristic fallback.
    /// - Parameters injected for testing (production defaults read the real
    ///   settings + call the real model): `titleConfig` nil means no AI config
    ///   (no-op, no persistence); `generateTitle` produces a title from an
    ///   item's intent+outcome.
    static func generateProjectWorkTitles(
        _ request: EngramServiceGenerateProjectWorkTitlesRequest,
        writerGate: ServiceWriterGate,
        titleConfig: ServiceAISettings.ChatConfig? = ServiceAISettings.read().titleConfig,
        generateTitle: @escaping @Sendable (String, String, ServiceAISettings.ChatConfig) async throws -> String
            = ServiceAIClient.workItemTitle(intent:outcome:config:)
    ) async throws -> ServiceWriterGateResult<EngramServiceGenerateProjectWorkTitlesResponse> {
        let project = request.project
        let items = try readProjectWorkItems(project: project, databasePath: writerGate.databasePath)
        let persisted = try readPersistedWorkItemTitles(project: project, databasePath: writerGate.databasePath)

        // Aggregate beats by work_key; a work_key can span multiple batch items,
        // but the title table is keyed by (project, work_key), so one title per key.
        var beatsByWorkKey: [String: [SessionImplementationBeat]] = [:]
        var orderedWorkKeys: [String] = []
        for item in items {
            if beatsByWorkKey[item.workKey] == nil { orderedWorkKeys.append(item.workKey) }
            beatsByWorkKey[item.workKey, default: []].append(contentsOf: item.beats)
        }

        struct WorkItemInput: Sendable {
            let workKey: String
            let intent: String
            let outcome: String
            let intentHash: String
        }

        // Select work items whose stored hash differs from the freshly computed
        // one (missing or stale).
        var pending: [WorkItemInput] = []
        for workKey in orderedWorkKeys {
            let beats = beatsByWorkKey[workKey] ?? []
            let intent = beats.map(\.humanIntent).joined(separator: "\n")
            let outcome = beats.map(\.assistantOutcome).joined(separator: "\n")
            let hash = intentHash(intent: intent, outcome: outcome)
            if persisted[workKey]?.intentHash == hash { continue }
            pending.append(WorkItemInput(workKey: workKey, intent: intent, outcome: outcome, intentHash: hash))
        }

        guard let titleConfig else {
            // No AI config: keep the app's heuristic. Persist nothing; echo the
            // already-persisted titles (likely empty) so the app reload is a no-op.
            let titles = persisted.map { workKey, value in
                EngramServiceWorkItemTitle(project: project, workKey: workKey, title: value.title)
            }
            return ServiceWriterGateResult(
                value: EngramServiceGenerateProjectWorkTitlesResponse(titles: titles),
                databaseGeneration: 0
            )
        }

        // Generate missing/stale titles concurrently (AI calls OUTSIDE the gate).
        struct GeneratedTitle: Sendable {
            let workKey: String
            let title: String
            let intentHash: String
        }
        var generated: [GeneratedTitle] = []
        let maxConcurrency = 4
        if !pending.isEmpty {
            // Sliding-window concurrency mirroring generateTitlesForContexts: at
            // most `maxConcurrency` in flight, per-item failures skipped, but a
            // CancellationError aborts the whole batch.
            let effectiveConcurrency = max(1, min(maxConcurrency, pending.count))
            var nextIndex = 0
            try await withThrowingTaskGroup(of: GeneratedTitle?.self) { group in
                for _ in 0..<effectiveConcurrency {
                    let input = pending[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let title = try await generateTitle(input.intent, input.outcome, titleConfig)
                            try Task.checkCancellation()
                            return GeneratedTitle(workKey: input.workKey, title: title, intentHash: input.intentHash)
                        } catch let error as CancellationError {
                            throw error
                        } catch {
                            ServiceLogger.error(
                                "generateProjectWorkTitles skipped project=\(project) workKey=\(input.workKey)",
                                category: .ai,
                                error: error
                            )
                            return nil
                        }
                    }
                }
                while let result = try await group.next() {
                    if let result { generated.append(result) }
                    try Task.checkCancellation()
                    if nextIndex < pending.count {
                        let input = pending[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try Task.checkCancellation()
                            do {
                                let title = try await generateTitle(input.intent, input.outcome, titleConfig)
                                try Task.checkCancellation()
                                return GeneratedTitle(workKey: input.workKey, title: title, intentHash: input.intentHash)
                            } catch let error as CancellationError {
                                throw error
                            } catch {
                                ServiceLogger.error(
                                    "generateProjectWorkTitles skipped project=\(project) workKey=\(input.workKey)",
                                    category: .ai,
                                    error: error
                                )
                                return nil
                            }
                        }
                    }
                }
            }
        }

        let model = titleConfig.model
        let generatedToWrite = generated
        return try await writerGate.performWriteCommand(name: "generateProjectWorkTitles") { writer in
            try writer.write { db in
                for entry in generatedToWrite {
                    try db.execute(
                        sql: """
                        INSERT INTO work_item_titles (project, work_key, title, intent_hash, model, updated_at)
                        VALUES (?, ?, ?, ?, ?, datetime('now'))
                        ON CONFLICT(project, work_key) DO UPDATE SET
                            title = excluded.title,
                            intent_hash = excluded.intent_hash,
                            model = excluded.model,
                            updated_at = datetime('now')
                        """,
                        arguments: [project, entry.workKey, entry.title, entry.intentHash, model]
                    )
                }
            }
            // Return only what we just generated. The app ignores this response
            // and reloads titles from the DB, so we avoid a fragile read-after-
            // write of work_item_titles (which would touch the table even when
            // nothing was generated). When `generatedToWrite` is empty, the write
            // block accesses no table at all.
            return EngramServiceGenerateProjectWorkTitlesResponse(
                titles: generatedToWrite.map { entry in
                    EngramServiceWorkItemTitle(project: project, workKey: entry.workKey, title: entry.title)
                }
            )
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
            let insightType = try normalizedInsightType(request.type)
            let superseded = try findDuplicateInsight(content: content, wing: wing, room: room, db: db)

            let id = UUID().uuidString
            let sourceSessionId = normalizedOptionalText(request.sourceSessionId, maxLength: 500)
            let arguments: [DatabaseValueConvertible?] = [
                id,
                content,
                wing,
                room,
                importance,
                sourceSessionId,
                insightType
            ]
            try db.execute(
                sql: """
                    INSERT INTO insights (id, content, wing, room, importance, source_session_id, insight_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      content = excluded.content,
                      wing = excluded.wing,
                      room = excluded.room,
                      importance = excluded.importance,
                      source_session_id = excluded.source_session_id,
                      insight_type = excluded.insight_type
                """,
                arguments: StatementArguments(arguments)
            )
            if let superseded {
                try db.execute(
                    sql: """
                    UPDATE insights
                    SET superseded_by = ?
                    WHERE id = ? AND superseded_by IS NULL
                    """,
                    arguments: [id, superseded.id]
                )
            }
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
                type: insightType,
                supersededId: superseded?.id,
                warning: superseded == nil
                    ? "Saved without embedding; keyword search is available immediately"
                    : "Saved and superseded a matching active insight; keyword search is available immediately"
            )
        }
    }

    private static func deleteInsight(
        _ request: EngramServiceDeleteInsightRequest,
        writer: EngramDatabaseWriter
    ) throws -> EngramServiceJSONValue {
        try writer.write { db in
            try ensureInsightTables(db)
            let id = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw EngramServiceError.invalidRequest(message: "id is required")
            }

            try db.execute(sql: "DELETE FROM insights_fts WHERE insight_id = ?", arguments: [id])
            let before = db.totalChangesCount
            try db.execute(sql: "DELETE FROM insights WHERE id = ?", arguments: [id])
            return .object([
                "id": .string(id),
                "deleted": .bool(db.totalChangesCount > before),
            ])
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
        room: String?,
        db: GRDB.Database
    ) throws -> ExistingInsight? {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, content, wing, room, importance
                FROM insights
                WHERE ((? IS NULL AND wing IS NULL) OR wing = ?)
                  AND ((? IS NULL AND room IS NULL) OR room = ?)
                  AND superseded_by IS NULL
                ORDER BY created_at DESC
                LIMIT 200
            """,
            arguments: [wing, wing, room, room]
        )

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
        writerGate: ServiceWriterGate
    ) async throws -> EngramServiceRegenerateTitlesResponse {
        let started = await titleRegenerationCoordinator.start {
            await regenerateAllTitlesInBackground(writerGate: writerGate)
        }
        if started {
            return EngramServiceRegenerateTitlesResponse(
                status: "started",
                total: nil,
                message: "Regenerating titles in background"
            )
        }
        return EngramServiceRegenerateTitlesResponse(
            status: "running",
            total: nil,
            message: "Title regeneration is already running"
        )
    }

    private static func regenerateAllTitlesInBackground(writerGate: ServiceWriterGate) async {
        do {
            let contexts = try readTitleContexts(databasePath: writerGate.databasePath)
            let settings = ServiceAISettings.read()
            let titleConfig = settings.titleConfig
            ServiceLogger.notice(
                "regenerateAllTitles started total=\(contexts.count) mode=\(titleConfig == nil ? "native" : "ai")",
                category: .ai
            )
            let generatedTitles = try await generateTitlesForContexts(
                contexts: contexts,
                titleConfig: titleConfig,
                progress: { completed, total in
                    if completed == total || completed % 10 == 0 {
                        ServiceLogger.notice(
                            "regenerateAllTitles progress completed=\(completed) total=\(total)",
                            category: .ai
                        )
                    }
                }
            )
            try Task.checkCancellation()
            _ = try await writerGate.performWriteCommand(name: "regenerateAllTitles") { writer in
                try writer.write { db in
                    for item in generatedTitles {
                        try db.execute(
                            sql: "UPDATE sessions SET generated_title = ? WHERE id = ?",
                            arguments: [item.title, item.id]
                        )
                    }
                }
                ServiceLogger.notice("regenerateAllTitles completed total=\(generatedTitles.count)", category: .ai)
                return generatedTitles.count
            }
        } catch is CancellationError {
            ServiceLogger.notice("regenerateAllTitles cancelled", category: .ai)
        } catch {
            ServiceLogger.error("regenerateAllTitles failed", category: .ai, error: error)
        }
    }

    static func generateTitlesForContexts(
        contexts: [AIContext],
        titleConfig: ServiceAISettings.ChatConfig?,
        maxConcurrency: Int = 4,
        titleProvider: @escaping @Sendable (AIContext, ServiceAISettings.ChatConfig) async throws -> String = { context, config in
            try await ServiceAIClient.title(context: context, config: config)
        },
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [(id: String, title: String)] {
        var generated: [(id: String, title: String)] = []
        generated.reserveCapacity(contexts.count)
        let total = contexts.count
        guard let config = titleConfig else {
            for context in contexts {
                try Task.checkCancellation()
                generated.append((id: context.id, title: context.nativeTitle))
                progress?(generated.count, total)
            }
            return generated
        }

        let effectiveConcurrency = max(1, min(maxConcurrency, contexts.count))
        var nextIndex = 0
        var completed = 0

        try await withThrowingTaskGroup(of: (id: String, title: String)?.self) { group in
            let initialCount = min(effectiveConcurrency, contexts.count)
            for _ in 0..<initialCount {
                let context = contexts[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let title = try await titleProvider(context, config)
                        try Task.checkCancellation()
                        return (id: context.id, title: title)
                    } catch let error as CancellationError {
                        throw error
                    } catch {
                        ServiceLogger.error(
                            "regenerateAllTitles skipped session=\(context.id)",
                            category: .ai,
                            error: error
                        )
                        return nil
                    }
                }
            }

            while let item = try await group.next() {
                completed += 1
                if let item {
                    generated.append(item)
                }
                progress?(completed, total)
                try Task.checkCancellation()
                if nextIndex < contexts.count {
                    let context = contexts[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            let title = try await titleProvider(context, config)
                            try Task.checkCancellation()
                            return (id: context.id, title: title)
                        } catch let error as CancellationError {
                            throw error
                        } catch {
                            ServiceLogger.error(
                                "regenerateAllTitles skipped session=\(context.id)",
                                category: .ai,
                                error: error
                            )
                            return nil
                        }
                    }
                }
            }
        }

        return generated
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
        try validateProjectPathConfined(normalizedTargetDir, label: "targetDir")

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
                    errors.append("\(linkPath): refusing to replace existing symlink")
                    continue
                }
                if fileManager.fileExists(atPath: linkPath) {
                    errors.append("\(linkPath): refusing to overwrite existing non-symlink")
                    continue
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

    /// SEC-C2: Confine project move/archive/batch operations to paths that
    /// canonicalize under $HOME and are not inside a sensitive subtree. This
    /// runs at the IPC command boundary, BEFORE the orchestrator touches the
    /// filesystem, so a malicious or buggy caller cannot rename/move arbitrary
    /// directories (e.g. /etc, ~/.ssh) by supplying an out-of-root src/dst.
    ///
    /// `force` only relaxes the orchestrator's git-dirty guard; it never
    /// relaxes this path confinement.
    static func validateProjectPathConfined(_ rawPath: String, label: String) throws {
        let home = homeDirectoryPath()
        let resolvedHome = URL(fileURLWithPath: home, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let expanded = ProjectPath.expandHome(rawPath)
        guard expanded.hasPrefix("/") else {
            throw EngramServiceError.invalidRequest(
                message: "\(label) path must be absolute and under the home directory"
            )
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard standardized == home || standardized.hasPrefix(home + "/") else {
            throw EngramServiceError.invalidRequest(
                message: "\(label) path resolves outside the home directory and is refused"
            )
        }
        let resolved = URL(fileURLWithPath: standardized)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard resolved == resolvedHome || resolved.hasPrefix(resolvedHome + "/") else {
            throw EngramServiceError.invalidRequest(
                message: "\(label) path resolves outside the home directory and is refused"
            )
        }
        if containsSensitivePathComponent(standardized, home: home)
            || containsSensitivePathComponent(resolved, home: resolvedHome) {
            throw EngramServiceError.invalidRequest(
                message: "\(label) path targets a protected location and is refused"
            )
        }
    }

    static func validateProjectMovePaths(src: String, dst: String?) throws {
        try validateProjectPathConfined(src, label: "source")
        if let dst, !dst.isEmpty {
            try validateProjectPathConfined(dst, label: "destination")
        }
    }

    private static func homeDirectoryPath() -> String {
        URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL.path
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
            "qwen": [".qwen"],
            "qoder": [".qoder"],
            "commandcode": [".commandcode"],
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
            "antigravity": [".gemini/antigravity-cli/brain", ".gemini/antigravity", ".antigravity"],
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
        // Single-component sensitive directories anywhere under $HOME.
        let sensitiveSingle: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".1password"]
        if relative.contains(where: { sensitiveSingle.contains($0) }) {
            return true
        }
        // Multi-component sensitive sequences, e.g. ~/Library/Keychains. The
        // previous code matched single components against the compound string
        // "Library/Keychains", which never matched and left keychains exposed.
        let sensitiveSequences: [[String]] = [
            ["Library", "Keychains"],
        ]
        for sequence in sensitiveSequences where relative.count >= sequence.count {
            for start in 0...(relative.count - sequence.count) {
                if Array(relative[start..<(start + sequence.count)]) == sequence {
                    return true
                }
            }
        }
        return false
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

    struct AIContext: Sendable {
        let id: String
        let source: String
        let project: String
        let cwd: String
        let messageCount: Int
        let startTime: String
        let nativeTitle: String
        let nativeSummary: String
        let transcript: String
    }

    static func readAIContext(sessionId: String, databasePath: String) throws -> AIContext {
        let pool = try readOnlyPool(path: databasePath)
        return try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, source, project, cwd, generated_title, custom_name, summary, message_count, start_time
                    FROM sessions
                    WHERE id = ?
                """,
                arguments: [sessionId]
            ) else {
                throw EngramServiceError.invalidRequest(message: "Session not found: \(sessionId)")
            }
            return try aiContext(from: row, db: db)
        }
    }

    static func readTitleContexts(databasePath: String) throws -> [AIContext] {
        let pool = try readOnlyPool(path: databasePath)
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source, project, cwd, generated_title, custom_name, summary, message_count, start_time
                    FROM sessions
                    WHERE COALESCE(tier, 'normal') != 'skip'
                    ORDER BY start_time DESC
                """
            )
            return try rows.map { try aiContext(from: $0, db: db) }
        }
    }

    private static func readOnlyPool(path: String) throws -> DatabasePool {
        // Use the hardened reader policy (busy_timeout, cache_size, WAL/FK guards)
        // shared with the main service read pool, not a bare Configuration.
        try DatabasePool(path: path, configuration: ServiceSQLiteConnectionPolicy.readerConfiguration())
    }

    /// Service-side mirror of `DatabaseManager.implementationTimeline`, forced to
    /// a single project and the human-driven filter (matching ProjectWorkTimeline
    /// `humanDriven: true`). Used to feed per-work-item semantic-title prompts.
    static func readProjectWorkItems(
        project: String,
        days: Int = 90,
        databasePath: String
    ) throws -> [ImplementationTimelineItem] {
        let pool = try readOnlyPool(path: databasePath)
        return try pool.read { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_work_beats'"
            ) ?? false
            guard exists else { return [] }
            var parts = ["""
                SELECT b.session_id, b.beat_index, b.action_date, b.action_timestamp,
                       b.work_key, b.work_title, b.human_intent, b.assistant_outcome,
                       b.kind, b.status, b.operation_events, b.confidence
                FROM session_work_beats b
                JOIN sessions s ON s.id = b.session_id
                WHERE s.hidden_at IS NULL
                  AND s.parent_session_id IS NULL
                  AND s.suggested_parent_id IS NULL
                  AND (s.tier IS NULL OR s.tier != 'skip')
                  AND s.project = ?
                  AND \(HumanDrivenFilter.sqlPredicate(alias: "s"))
            """]
            var args: [DatabaseValueConvertible] = [project]
            if days < 100_000,
               let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                parts.append("AND b.action_date >= ?")
                args.append(formatter.string(from: cutoff))
            }
            parts.append("ORDER BY b.action_date ASC, b.action_timestamp ASC, b.session_id ASC, b.beat_index ASC")
            let rows = try Row.fetchAll(db, sql: parts.joined(separator: " "), arguments: StatementArguments(args))
            let beats = rows.map(decodeWorkBeat(row:))
            return ImplementationTimelineBuilder.build(beats: beats)
        }
    }

    /// Service-local copy of `DatabaseManager.sessionImplementationBeat`; the
    /// app decoder is private, so the service decodes the same columns
    /// (including the operation_events JSON array) itself.
    private static func decodeWorkBeat(row: Row) -> SessionImplementationBeat {
        let eventsJSON: String = row["operation_events"] ?? "[]"
        let events: [SessionOperationEvent]
        if let data = eventsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SessionOperationEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
        return SessionImplementationBeat(
            sessionId: row["session_id"],
            beatIndex: row["beat_index"],
            actionDate: row["action_date"],
            actionTimestamp: row["action_timestamp"],
            workKey: row["work_key"],
            workTitle: row["work_title"],
            humanIntent: row["human_intent"],
            assistantOutcome: row["assistant_outcome"],
            kind: SessionImplementationKind(rawValue: row["kind"]) ?? .implementation,
            status: SessionImplementationStatus(rawValue: row["status"]) ?? .partial,
            operationEvents: events,
            confidence: row["confidence"]
        )
    }

    private struct PersistedWorkItemTitle: Sendable {
        let title: String
        let intentHash: String
    }

    /// Read the project's already-persisted work-item titles, keyed by work_key.
    /// Returns an empty map when the (service-owned) table has not been created
    /// yet so the read-only pool never throws "no such table".
    private static func readPersistedWorkItemTitles(
        project: String,
        databasePath: String
    ) throws -> [String: PersistedWorkItemTitle] {
        let pool = try readOnlyPool(path: databasePath)
        return try pool.read { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='work_item_titles'"
            ) ?? false
            guard exists else { return [:] }
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT work_key, title, intent_hash FROM work_item_titles WHERE project = ?",
                arguments: [project]
            )
            var result: [String: PersistedWorkItemTitle] = [:]
            for row in rows {
                let workKey: String = row["work_key"]
                result[workKey] = PersistedWorkItemTitle(
                    title: row["title"],
                    intentHash: row["intent_hash"]
                )
            }
            return result
        }
    }

    static func aiContext(from row: Row, db: Database) throws -> AIContext {
        let id = row["id"] as String? ?? ""
        // FTS stores one row per message; aggregate them in order so the AI
        // sees the whole conversation, not just the first message.
        let transcript = ((try? String.fetchAll(
            db,
            sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY rowid",
            arguments: [id]
        )) ?? []).joined(separator: "\n")
        let cwd = row["cwd"] as String? ?? ""
        let project = row["project"] as String? ?? URL(fileURLWithPath: cwd).lastPathComponent
        return AIContext(
            id: id,
            source: row["source"] as String? ?? "unknown",
            project: project,
            cwd: cwd,
            messageCount: row["message_count"] as Int? ?? 0,
            startTime: row["start_time"] as String? ?? "unknown time",
            nativeTitle: nativeTitle(row),
            nativeSummary: nativeSummary(row),
            transcript: transcript
        )
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

    private static let isoFormatter = ISO8601DateFormatter()

    private static func currentTimestamp() -> String {
        isoFormatter.string(from: Date())
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

    private static func normalizedInsightType(_ value: String?) throws -> String {
        let type = normalizedOptionalText(value, maxLength: 32) ?? "semantic"
        guard ["episodic", "semantic", "procedural"].contains(type) else {
            throw EngramServiceError.invalidRequest(
                message: "type must be one of episodic, semantic, or procedural"
            )
        }
        return type
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
        type: String = "semantic",
        supersededId: String? = nil,
        warning: String?
    ) -> EngramServiceJSONValue {
        var object: [String: EngramServiceJSONValue] = [
            "id": .string(id),
            "content": .string(content),
            "importance": .number(Double(importance)),
            "type": .string(type)
        ]
        if let wing { object["wing"] = .string(wing) }
        if let room { object["room"] = .string(room) }
        if let supersededId { object["superseded_id"] = .string(supersededId) }
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

    struct ServiceAISettings: Sendable {
        typealias KeychainReader = @Sendable (String) -> String?

        struct ChatConfig: Sendable {
            let provider: String
            let baseURL: String
            let apiKey: String
            let model: String
            let maxTokens: Int
            let temperature: Double
            // Summary-only tuning (ignored by the title path).
            var summaryLanguage: String = "中文"
            var summaryMaxSentences: Int = 3
            var summaryStyle: String = ""
            var summaryPrompt: String = ""
            var summarySampleFirst: Int = 20
            var summarySampleLast: Int = 30
            var summaryTruncateChars: Int = 500
        }

        let summaryConfig: ChatConfig?
        let titleConfig: ChatConfig?

        static func read(
            settingsPath: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".engram/settings.json"),
            environment: [String: String] = ProcessInfo.processInfo.environment,
            keychainReader: KeychainReader = { account in ServiceKeychainReader.get(account) }
        ) -> ServiceAISettings {
            guard let data = try? Data(contentsOf: settingsPath),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return ServiceAISettings(summaryConfig: nil, titleConfig: nil)
            }
            let runtimeSecrets = RuntimeAISecretReader.read(environment: environment)
            let secretReader: KeychainReader = { account in
                runtimeSecrets[account] ?? keychainReader(account)
            }
            return ServiceAISettings(
                summaryConfig: summaryConfig(from: object, keychainReader: secretReader),
                titleConfig: titleConfig(from: object, keychainReader: secretReader)
            )
        }

        private static func summaryConfig(
            from object: [String: Any],
            keychainReader: KeychainReader
        ) -> ChatConfig? {
            let provider = string(object["aiProtocol"]) ?? "openai"
            guard provider == "openai" else { return nil }
            guard let apiKey = apiKey(from: object["aiApiKey"], account: "aiApiKey", keychainReader: keychainReader) else {
                return nil
            }
            let baseURL = string(object["aiBaseURL"]) ?? "https://api.openai.com"
            return ChatConfig(
                provider: provider,
                baseURL: baseURL,
                apiKey: apiKey,
                model: normalizeOpenAICompatibleModel(string(object["aiModel"]) ?? "gpt-4o-mini", baseURL: baseURL),
                maxTokens: int(object["summaryMaxTokens"]) ?? maxTokens(for: string(object["summaryPreset"])),
                temperature: double(object["summaryTemperature"]) ?? temperature(for: string(object["summaryPreset"])),
                summaryLanguage: string(object["summaryLanguage"]) ?? "中文",
                summaryMaxSentences: int(object["summaryMaxSentences"]) ?? 3,
                summaryStyle: string(object["summaryStyle"]) ?? "",
                summaryPrompt: string(object["summaryPrompt"]) ?? "",
                summarySampleFirst: int(object["summarySampleFirst"]) ?? 20,
                summarySampleLast: int(object["summarySampleLast"]) ?? 30,
                summaryTruncateChars: int(object["summaryTruncateChars"]) ?? 500
            )
        }

        private static func titleConfig(
            from object: [String: Any],
            keychainReader: KeychainReader
        ) -> ChatConfig? {
            let provider = string(object["titleProvider"]) ?? "ollama"
            guard provider == "ollama" || provider == "custom" || provider == "openai" else {
                return nil
            }
            let defaultBaseURL = provider == "ollama" ? "http://localhost:11434" : "https://api.openai.com"
            let baseURL = string(object["titleBaseUrl"]) ?? string(object["titleBaseURL"]) ?? defaultBaseURL
            let apiKey = provider == "ollama"
                ? ""
                : apiKey(from: object["titleApiKey"], account: "titleApiKey", keychainReader: keychainReader) ?? ""
            return ChatConfig(
                provider: provider,
                baseURL: baseURL,
                apiKey: apiKey,
                model: normalizeOpenAICompatibleModel(string(object["titleModel"]) ?? "gpt-4o-mini", baseURL: baseURL),
                maxTokens: 120,
                temperature: 0.3
            )
        }

        private static func apiKey(
            from value: Any?,
            account: String,
            keychainReader: KeychainReader
        ) -> String? {
            if let key = string(value), !key.isEmpty, key != "@keychain" { return key }
            if let key = keychainReader(account), !key.isEmpty { return key }
            return nil
        }

        private enum ServiceKeychainReader {
            private static let service = "com.engram.app"

            static func get(_ account: String) -> String? {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                guard status == errSecSuccess, let data = result as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }

        private enum RuntimeAISecretReader {
            private static let pathEnvironmentKey = "ENGRAM_RUNTIME_AI_SECRETS_PATH"
            private static let allowedAccounts: Set<String> = ["aiApiKey", "titleApiKey"]

            static func read(environment: [String: String]) -> [String: String] {
                guard let path = environment[pathEnvironmentKey],
                      !path.isEmpty,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return [:]
                }
                return object.reduce(into: [:]) { result, pair in
                    guard allowedAccounts.contains(pair.key),
                          let value = pair.value as? String,
                          !value.isEmpty
                    else {
                        return
                    }
                    result[pair.key] = value
                }
            }
        }

        private static func normalizeOpenAICompatibleModel(_ model: String, baseURL: String) -> String {
            guard baseURL.range(of: #"xiaomimimo\.com|mimo-v2\.com"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                return model.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.range(of: #"^mimo-\d"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return trimmed.replacingOccurrences(
                    of: #"^mimo-"#,
                    with: "mimo-v",
                    options: [.regularExpression, .caseInsensitive]
                )
            }
            return trimmed
        }

        private static func string(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func int(_ value: Any?) -> Int? {
            if let value = value as? Int { return value }
            if let value = value as? Double { return Int(value) }
            return nil
        }

        private static func double(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            return nil
        }

        private static func maxTokens(for preset: String?) -> Int {
            switch preset {
            case "concise": return 100
            case "detailed": return 400
            default: return 200
            }
        }

        private static func temperature(for preset: String?) -> Double {
            switch preset {
            case "concise": return 0.2
            case "detailed": return 0.4
            default: return 0.3
            }
        }
    }

    enum ServiceAIClient {
        private static let aiChatTimeoutSeconds: TimeInterval = 25

        static let defaultSummaryTemplate = """
        请用不超过 {{maxSentences}} 句话，以 {{language}} 总结以下 AI 编程对话的核心内容。
        总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果
        {{style}}
        保持简洁。
        """

        /// Mirrors `renderPromptTemplate` in src/core/ai-client.ts so the Swift
        /// service honors the same summaryLanguage / summaryMaxSentences /
        /// summaryStyle / summaryPrompt settings as the TypeScript reference.
        static func renderSummaryPrompt(
            language: String,
            maxSentences: Int,
            style: String,
            template: String
        ) -> String {
            let base = template.isEmpty ? defaultSummaryTemplate : template
            let styleLine = style.isEmpty ? "" : "风格要求：\(style)"
            let rendered = base
                .replacingOccurrences(of: "{{language}}", with: language)
                .replacingOccurrences(of: "{{maxSentences}}", with: String(maxSentences))
                .replacingOccurrences(of: "{{style}}", with: styleLine)
            return rendered
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
        }

        static func summarize(context: AIContext, config: ServiceAISettings.ChatConfig) async throws -> String {
            let source = boundedTranscript(context, config: config)
            let system = renderSummaryPrompt(
                language: config.summaryLanguage,
                maxSentences: config.summaryMaxSentences,
                style: config.summaryStyle,
                template: config.summaryPrompt
            )
            let user = "会话元数据：source=\(context.source), project=\(context.project), messages=\(context.messageCount)\n\n会话内容：\n\(source)"
            return try await chat(purpose: "summary", sessionID: context.id, config: config, messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ])
        }

        static func title(context: AIContext, config: ServiceAISettings.ChatConfig) async throws -> String {
            let source = boundedTranscript(context, limit: 4_000)
            let prompt = """
            Generate a concise title (30 characters or fewer) for this AI coding conversation.
            Match the conversation language. Return only the title, no quotes, no prefix.

            Metadata: source=\(context.source), project=\(context.project)
            Conversation:
            \(source)
            """
            let raw = try await chat(purpose: "title", sessionID: context.id, config: config, messages: [["role": "user", "content": prompt]])
            return cleanTitle(raw)
        }

        /// Generate a concise semantic title for a single implementation work
        /// item from its aggregated human intent + assistant outcome. Reuses
        /// chat() + cleanTitle() exactly like title(context:). Inputs are
        /// bounded before prompting because titleConfig caps output tokens but
        /// not the request body size.
        static func workItemTitle(
            intent: String,
            outcome: String,
            config: ServiceAISettings.ChatConfig
        ) async throws -> String {
            let boundedIntent = String(intent.prefix(600))
            let boundedOutcome = String(outcome.prefix(1200))
            // Generate a concise title for what was built or fixed, matching input language.
            let prompt = """
            Generate a concise title (30 characters or fewer) describing what was
            built or fixed in this unit of engineering work. Match the input
            language, including Chinese for Chinese input. Return only the title, no quotes, no prefix.

            Intent: \(boundedIntent)
            Outcome: \(boundedOutcome)
            """
            let raw = try await chat(
                purpose: "workItemTitle",
                sessionID: "workItem",
                config: config,
                messages: [["role": "user", "content": prompt]]
            )
            return cleanTitle(raw)
        }

        static func chat(
            purpose: String,
            sessionID: String,
            config: ServiceAISettings.ChatConfig,
            messages: [[String: String]]
        ) async throws -> String {
            let url = try chatCompletionsURL(baseURL: config.baseURL)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = aiChatTimeoutSeconds
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = [
                "model": config.model,
                "messages": messages,
                "temperature": config.temperature
            ]
            if usesMiMoAPI(baseURL: config.baseURL) {
                body["max_completion_tokens"] = config.maxTokens
                body["thinking"] = ["type": "disabled"]
            } else {
                body["max_tokens"] = config.maxTokens
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            ServiceLogger.notice(
                "LLM request started purpose=\(purpose) session=\(sessionID) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL)) maxTokens=\(config.maxTokens) temperature=\(config.temperature)",
                category: .ai
            )
            let started = Date()
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                ServiceLogger.error(
                    "LLM request failed purpose=\(purpose) session=\(sessionID) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL))",
                    category: .ai,
                    error: error
                )
                throw error
            }
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                ServiceLogger.error(
                    "LLM request failed purpose=\(purpose) session=\(sessionID) status=\(status) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL)) durationMs=\(durationMs)",
                    category: .ai
                )
                throw EngramServiceError.commandFailed(
                    name: "AIRequestFailed",
                    message: "AI request failed with status \(status)",
                    retryPolicy: status == 429 || status >= 500 ? "safe" : "never",
                    details: [
                        "status": .number(Double(status)),
                        "provider": .string(config.provider),
                        "model": .string(config.model),
                        "url": .string(redactedHost(config.baseURL))
                    ]
                )
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                ServiceLogger.error(
                    "LLM request failed purpose=\(purpose) session=\(sessionID) status=\(status) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL)) durationMs=\(durationMs) reason=invalid-response",
                    category: .ai
                )
                throw EngramServiceError.commandFailed(
                    name: "AIResponseInvalid",
                    message: "AI response did not contain choices[0].message.content",
                    retryPolicy: "safe",
                    details: ["provider": .string(config.provider), "model": .string(config.model)]
                )
            }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                ServiceLogger.error(
                    "LLM request failed purpose=\(purpose) session=\(sessionID) status=\(status) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL)) durationMs=\(durationMs) reason=empty-content",
                    category: .ai
                )
                throw EngramServiceError.commandFailed(
                    name: "AIResponseEmpty",
                    message: "AI response content was empty",
                    retryPolicy: "safe",
                    details: ["provider": .string(config.provider), "model": .string(config.model)]
                )
            }
            ServiceLogger.notice(
                "LLM request succeeded purpose=\(purpose) session=\(sessionID) status=\(status) provider=\(config.provider) model=\(config.model) url=\(redactedHost(config.baseURL)) durationMs=\(durationMs) outputChars=\(trimmed.count)",
                category: .ai
            )
            return trimmed
        }

        static func chatCompletionsURL(baseURL: String) throws -> URL {
            let base = baseURL.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            let value = base.hasSuffix("/v1") ? "\(base)/chat/completions" : "\(base)/v1/chat/completions"
            guard let url = URL(string: value) else {
                throw EngramServiceError.invalidRequest(message: "Invalid AI base URL")
            }
            return url
        }

        private static func usesMiMoAPI(baseURL: String) -> Bool {
            baseURL.range(
                of: #"xiaomimimo\.com|mimo-v2\.com"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }

        static func redactedHost(_ url: String) -> String {
            guard let parsed = URL(string: url), let host = parsed.host else { return "<invalid-url>" }
            return "\(parsed.scheme ?? "https")://\(host)\(parsed.path)"
        }

        static func boundedTranscript(
            _ context: AIContext,
            config: ServiceAISettings.ChatConfig? = nil,
            limit: Int = 12_000
        ) -> String {
            var text = context.transcript.isEmpty ? context.nativeSummary : context.transcript
            if let config {
                text = sampledTranscript(
                    text,
                    sampleFirst: config.summarySampleFirst,
                    sampleLast: config.summarySampleLast,
                    truncateChars: config.summaryTruncateChars
                )
            }
            if text.count <= limit { return text }
            let head = text.prefix(limit / 2)
            let tail = text.suffix(limit / 2)
            return "\(head)\n\n...[truncated]...\n\n\(tail)"
        }

        private static func sampledTranscript(
            _ text: String,
            sampleFirst: Int,
            sampleLast: Int,
            truncateChars: Int
        ) -> String {
            let firstCount = max(0, sampleFirst)
            let lastCount = max(0, sampleLast)
            guard firstCount + lastCount > 0 else { return text }

            let lineLimit = max(1, truncateChars)
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let value = String(line)
                    return value.count > lineLimit ? String(value.prefix(lineLimit)) : value
                }
            guard lines.count > firstCount + lastCount else {
                return lines.joined(separator: "\n")
            }

            let omitted = lines.count - firstCount - lastCount
            var sampled = Array(lines.prefix(firstCount))
            sampled.append("...[\(omitted) messages omitted]...")
            sampled.append(contentsOf: lines.suffix(lastCount))
            return sampled.joined(separator: "\n")
        }

        private static func cleanTitle(_ raw: String) -> String {
            var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["Title:", "title:", "标题:", "标题："] where title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」"))
            if title.count > 30 {
                title = String(title.prefix(30))
            }
            return title
        }
    }
}

private actor ServiceTitleRegenerationCoordinator {
    private var running = false

    func start(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        guard !running else { return false }
        running = true
        Task {
            await operation()
            finish()
        }
        return true
    }

    private func finish() {
        running = false
    }
}

private struct WriteIntentAck: Encodable, Sendable {
    let ok: Bool
}

private struct EmptyEncodableResult: Encodable, Sendable {}

private enum ServiceSQLiteConnectionPolicy {
    static func readerConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try applyCommonPragmas(db)
            let timeout = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
            guard timeout >= SQLiteConnectionPolicy.minimumBusyTimeoutMilliseconds else {
                throw SQLiteConnectionPolicyError.busyTimeoutTooLow(timeout)
            }
            let journalMode = (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased()
            guard journalMode == "wal" else {
                throw SQLiteConnectionPolicyError.journalModeNotWAL(journalMode)
            }
        }
        return configuration
    }

    private static func applyCommonPragmas(_ db: GRDB.Database) throws {
        try db.execute(sql: "PRAGMA busy_timeout = \(SQLiteConnectionPolicy.busyTimeoutMilliseconds)")
        try db.execute(sql: "PRAGMA foreign_keys = ON")
        try db.execute(sql: "PRAGMA synchronous = NORMAL")
        try db.execute(sql: "PRAGMA wal_autocheckpoint = \(SQLiteConnectionPolicy.walAutocheckpointPages)")
        try db.execute(sql: "PRAGMA cache_size = -\(SQLiteConnectionPolicy.cacheSizeKiB)")
    }
}

private extension GRDB.Database {
    func executeAndCountChanges(sql: String, arguments: StatementArguments = StatementArguments()) throws -> Int {
        try execute(sql: sql, arguments: arguments)
        return changesCount
    }
}
