import Foundation
import GRDB
import EngramCoreRead
import EngramCoreWrite

extension EngramServiceCommandHandler {
    static let webGenerationSnapshotBudget: Duration = .seconds(2)

    static func webGenerateSummary(
        _ request: EngramServiceWebGenerateSummaryRequest,
        writerGate: ServiceWriterGate,
        snapshotProvider: any ServiceWebTranscriptSnapshotProviding,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        ),
        summaryConfig: ServiceAISettings.ChatConfig? = nil,
        summarize: (@Sendable (AIContext, ServiceAISettings.ChatConfig) async throws -> String)? = nil,
        urlSession: URLSession = .shared
    ) async throws -> ServiceWriterGateResult<EngramServiceWebGenerateSummaryResponse> {
        let prepared = try await prepareWebGeneration(
            sessionId: request.sessionId,
            generation: request.generation,
            writerGate: writerGate,
            snapshotProvider: snapshotProvider,
            settingsURL: settingsURL
        )
        let config = try requiredConfig(
            summaryConfig ?? ServiceAISettings.read(settingsPath: settingsURL).summaryConfig
        )
        let summarize = summarize ?? { context, config in
            try await ServiceAIClient.summarize(
                context: context,
                config: config,
                urlSession: urlSession,
                audit: ServiceAIAuditRecorder(writerGate: writerGate)
            )
        }
        let summary = try persistedSummary(try await summarize(prepared.context, config))
        return try await writerGate.performWriteCommand(name: "webGenerateSummary") { writer in
            try persistWebSummary(
                sessionId: request.sessionId,
                generation: request.generation,
                summary: summary,
                messageCount: prepared.context.messageCount,
                writer: writer,
                settingsURL: settingsURL
            )
        }
    }

    static func webGenerateTitle(
        _ request: EngramServiceWebGenerateTitleRequest,
        writerGate: ServiceWriterGate,
        snapshotProvider: any ServiceWebTranscriptSnapshotProviding,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        ),
        titleConfig: ServiceAISettings.ChatConfig? = nil,
        titleProvider: (@Sendable (AIContext, ServiceAISettings.ChatConfig) async throws -> String)? = nil,
        urlSession: URLSession = .shared
    ) async throws -> ServiceWriterGateResult<EngramServiceWebGenerateTitleResponse> {
        let prepared = try await prepareWebGeneration(
            sessionId: request.sessionId,
            generation: request.generation,
            writerGate: writerGate,
            snapshotProvider: snapshotProvider,
            settingsURL: settingsURL
        )
        let config = try requiredConfig(
            titleConfig ?? ServiceAISettings.read(settingsPath: settingsURL).titleConfig
        )
        let titleProvider = titleProvider ?? { context, config in
            try await ServiceAIClient.title(
                context: context,
                config: config,
                urlSession: urlSession,
                audit: ServiceAIAuditRecorder(writerGate: writerGate)
            )
        }
        let title = try persistedTitle(try await titleProvider(prepared.context, config))
        return try await writerGate.performWriteCommand(name: "webGenerateTitle") { writer in
            try persistWebTitle(
                sessionId: request.sessionId,
                generation: request.generation,
                title: title,
                writer: writer,
                settingsURL: settingsURL
            )
        }
    }

    static func webRegenerateTitles(
        writerGate: ServiceWriterGate,
        snapshotProvider: any ServiceWebTranscriptSnapshotProviding,
        settingsURL: URL = EngramServiceRunner.engramSettingsURL(
            environment: ProcessInfo.processInfo.environment
        ),
        titleConfig: ServiceAISettings.ChatConfig? = nil,
        titleProvider: (@Sendable (AIContext, ServiceAISettings.ChatConfig) async throws -> String)? = nil,
        urlSession: URLSession = .shared
    ) async throws -> EngramServiceWebRegenerateTitlesResponse {
        let config = try requiredConfig(
            titleConfig ?? ServiceAISettings.read(settingsPath: settingsURL).titleConfig
        )
        let candidates = try webMissingTitleCandidates(
            databasePath: writerGate.databasePath,
            settingsURL: settingsURL
        )
        let titleProvider = titleProvider ?? { context, config in
            try await ServiceAIClient.title(
                context: context,
                config: config,
                urlSession: urlSession,
                audit: ServiceAIAuditRecorder(writerGate: writerGate)
            )
        }
        let started = await startTitleRegeneration {
            await webRegenerateTitlesInBackground(
                candidates: candidates,
                config: config,
                writerGate: writerGate,
                snapshotProvider: snapshotProvider,
                settingsURL: settingsURL,
                titleProvider: titleProvider
            )
        }
        if started {
            return try EngramServiceWebRegenerateTitlesResponse(status: "started", total: candidates.count)
        }
        return try EngramServiceWebRegenerateTitlesResponse(status: "running")
    }

    private static func webRegenerateTitlesInBackground(
        candidates: [WebTitleCandidate],
        config: ServiceAISettings.ChatConfig,
        writerGate: ServiceWriterGate,
        snapshotProvider: any ServiceWebTranscriptSnapshotProviding,
        settingsURL: URL,
        titleProvider: @escaping @Sendable (AIContext, ServiceAISettings.ChatConfig) async throws -> String
    ) async {
        for candidate in candidates {
            do {
                try Task.checkCancellation()
                let prepared = try await prepareWebGeneration(
                    sessionId: candidate.sessionId,
                    generation: candidate.generation,
                    writerGate: writerGate,
                    snapshotProvider: snapshotProvider,
                    settingsURL: settingsURL,
                    requireMissingTitle: true
                )
                let title = try persistedTitle(try await titleProvider(prepared.context, config))
                try Task.checkCancellation()
                _ = try await writerGate.performWriteCommand(name: "webRegenerateTitles") { writer in
                    try persistWebTitle(
                        sessionId: candidate.sessionId,
                        generation: candidate.generation,
                        title: title,
                        writer: writer,
                        settingsURL: settingsURL,
                        requireMissingTitle: true
                    )
                }
            } catch is CancellationError {
                ServiceLogger.notice("webRegenerateTitles cancelled", category: .ai)
                return
            } catch {
                ServiceLogger.error(
                    "webRegenerateTitles skipped session=\(candidate.sessionId)",
                    category: .ai,
                    error: error
                )
            }
        }
    }

    private static func prepareWebGeneration(
        sessionId: String,
        generation: String,
        writerGate: ServiceWriterGate,
        snapshotProvider: any ServiceWebTranscriptSnapshotProviding,
        settingsURL: URL,
        requireMissingTitle: Bool = false
    ) async throws -> PreparedWebGeneration {
        let admitted = try currentWebGeneration(
            databasePath: writerGate.databasePath,
            sessionId: sessionId,
            generation: generation,
            settingsURL: settingsURL,
            requireMissingTitle: requireMissingTitle
        )
        let deadline = ContinuousClock.now.advanced(by: webGenerationSnapshotBudget)
        let snapshot: ServiceTranscriptContinuation.Snapshot
        do {
            guard let loaded = try await snapshotProvider.snapshot(
                sessionID: sessionId,
                generation: generation,
                deadline: deadline
            ),
                  loaded.sessionId.utf8.elementsEqual(sessionId.utf8),
                  loaded.generation.utf8.elementsEqual(generation.utf8) else {
                throw webGenerationStale
            }
            snapshot = loaded
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EngramServiceError {
            throw error
        } catch {
            throw webGenerationStale
        }
        let transcript = snapshot.messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngramServiceError.invalidRequest(message: "Cannot summarize a session without transcript content")
        }
        var context = AIContext(
            id: sessionId,
            source: admitted.source,
            project: admitted.project,
            cwd: admitted.cwd,
            messageCount: admitted.messageCount,
            startTime: admitted.startTime,
            nativeTitle: EngramServiceWebWriteValidation.displayTitle(
                customName: admitted.customName,
                generatedTitle: admitted.generatedTitle
            ) ?? "Untitled",
            nativeSummary: "",
            transcript: transcript
        )
        context.tier = admitted.tier
        return PreparedWebGeneration(context: context)
    }

    private static func persistWebSummary(
        sessionId: String,
        generation: String,
        summary: String,
        messageCount: Int,
        writer: EngramDatabaseWriter,
        settingsURL: URL
    ) throws -> EngramServiceWebGenerateSummaryResponse {
        let sources = try enabledSources(at: settingsURL)
        return try writer.write { db in
            _ = try admitWebGeneration(
                db,
                sessionId: sessionId,
                generation: generation,
                enabledSources: sources
            )
            try db.execute(
                sql: "UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ? COLLATE BINARY",
                arguments: [summary, messageCount, sessionId]
            )
            return try EngramServiceWebGenerateSummaryResponse(
                sessionId: sessionId,
                generation: generation,
                summary: summary
            )
        }
    }

    private static func persistWebTitle(
        sessionId: String,
        generation: String,
        title: String,
        writer: EngramDatabaseWriter,
        settingsURL: URL,
        requireMissingTitle: Bool = false
    ) throws -> EngramServiceWebGenerateTitleResponse {
        let sources = try enabledSources(at: settingsURL)
        return try writer.write { db in
            let admitted = try admitWebGeneration(
                db,
                sessionId: sessionId,
                generation: generation,
                enabledSources: sources,
                requireMissingTitle: requireMissingTitle
            )
            try db.execute(
                sql: "UPDATE sessions SET generated_title = ? WHERE id = ? COLLATE BINARY",
                arguments: [title, sessionId]
            )
            let display = EngramServiceWebWriteValidation.displayTitle(
                customName: admitted.customName,
                generatedTitle: title
            )
            return try EngramServiceWebGenerateTitleResponse(
                sessionId: sessionId,
                generation: generation,
                title: title,
                displayTitle: display
            )
        }
    }

    static func webMissingTitleCandidates(
        databasePath: String,
        settingsURL: URL
    ) throws -> [WebTitleCandidate] {
        let sources = try enabledSources(at: settingsURL)
        let keys = sources.map(\.rawValue).sorted()
        guard !keys.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let arguments: [DatabaseValueConvertible] = keys
        return try readOnlyPool(path: databasePath).read { db in
            guard try db.tableExists("capture_ingest_identity_bindings"),
                  try db.tableExists("capture_ingest_source_registry"),
                  try db.tableExists("capture_ingest_epoch_history") else {
                return []
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, i.last_ready_generation_id
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
                  AND s.hidden_at IS NULL
                  AND (s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))
                  AND (s.generated_title IS NULL OR TRIM(s.generated_title) = '')
                  AND COALESCE(s.message_count, 0) >= 2
                  AND i.last_ready_generation_id IS NOT NULL
                  AND s.source = i.source COLLATE BINARY
                  AND s.authoritative_node = ('capture-v1.' || i.machine_id || '.' || i.source_instance_id) COLLATE BINARY
                ORDER BY s.start_time DESC
                LIMIT 500
                """, arguments: StatementArguments(arguments))
            return try rows.compactMap { row in
                let sessionId: String = row["id"]
                let generation: String = row["last_ready_generation_id"]
                do {
                    _ = try authorizeWebSession(db, sessionId: sessionId, enabledSources: sources)
                    return WebTitleCandidate(sessionId: sessionId, generation: generation)
                } catch {
                    return nil
                }
            }
        }
    }

    private static func currentWebGeneration(
        databasePath: String,
        sessionId: String,
        generation: String,
        settingsURL: URL,
        requireMissingTitle: Bool
    ) throws -> AdmittedWebGeneration {
        let sources = try enabledSources(at: settingsURL)
        return try readOnlyPool(path: databasePath).read { db in
            try admitWebGeneration(
                db,
                sessionId: sessionId,
                generation: generation,
                enabledSources: sources,
                requireMissingTitle: requireMissingTitle
            )
        }
    }

    private static func admitWebGeneration(
        _ db: Database,
        sessionId: String,
        generation: String,
        enabledSources: Set<SourceName>,
        requireMissingTitle: Bool = false
    ) throws -> AdmittedWebGeneration {
        do {
            _ = try authorizeWebSession(db, sessionId: sessionId, enabledSources: enabledSources)
        } catch {
            throw webGenerationStale
        }
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.source, s.project, s.cwd, s.start_time, s.message_count, s.custom_name,
                   s.generated_title, s.tier, i.last_ready_generation_id
            FROM sessions s
            JOIN capture_ingest_identity_bindings i ON s.id = i.stored_session_id COLLATE BINARY
            WHERE s.id = ? COLLATE BINARY
            """, arguments: [sessionId]) else {
            throw webGenerationStale
        }
        let ready = (row["last_ready_generation_id"] as String?) ?? ""
        guard ready.utf8.elementsEqual(generation.utf8) else { throw webGenerationStale }
        let generatedTitle = optionalText(row["generated_title"])
        let messageCount = row["message_count"] as Int? ?? 0
        let tier = optionalText(row["tier"])
        if requireMissingTitle {
            if generatedTitle != nil || tier == "lite" || messageCount < 2 {
                throw webGenerationStale
            }
        }
        return AdmittedWebGeneration(
            source: (row["source"] as String?) ?? "unknown",
            project: (row["project"] as String?)
                ?? URL(fileURLWithPath: (row["cwd"] as String?) ?? "").lastPathComponent,
            cwd: (row["cwd"] as String?) ?? "",
            startTime: (row["start_time"] as String?) ?? "unknown time",
            messageCount: messageCount,
            customName: optionalText(row["custom_name"]),
            generatedTitle: generatedTitle,
            tier: tier
        )
    }

    private static func enabledSources(at settingsURL: URL) throws -> Set<SourceName> {
        guard let policy = ServiceCaptureIngestRuntime.policy(at: settingsURL),
              !policy.enabledSources.isEmpty else {
            throw EngramServiceError.serviceUnavailable(message: "Web generation is unavailable.")
        }
        return policy.enabledSources
    }

    private static func requiredConfig(
        _ config: ServiceAISettings.ChatConfig?
    ) throws -> ServiceAISettings.ChatConfig {
        guard let config else {
            throw EngramServiceError.serviceUnavailable(message: "AI provider is not configured.")
        }
        return config
    }

    static func persistedSummary(_ value: String) throws -> String {
        let text = TranscriptRedactionPolicy.redact(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.utf8.contains(0) else {
            throw EngramServiceError.invalidRequest(message: "Generation returned empty result.")
        }
        guard text.utf8.count <= EngramServiceWebReadLimits.maximumSessionSummaryBytes else {
            throw EngramServiceError.invalidRequest(message: "Generated summary exceeds the allowed response size.")
        }
        return text
    }

    private static func persistedTitle(_ value: String) throws -> String {
        let text = TranscriptRedactionPolicy.redact(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.utf8.contains(0), text.utf8.count <= 120 else {
            throw EngramServiceError.invalidRequest(message: "Generation returned empty result.")
        }
        return text
    }

    private static func optionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let webGenerationStale = EngramServiceError.commandFailed(
        name: "StaleCursor",
        message: "Session generation is no longer admitted.",
        retryPolicy: "never",
        details: nil
    )

    private struct PreparedWebGeneration: Sendable {
        let context: AIContext
    }

    private struct AdmittedWebGeneration: Sendable {
        let source: String
        let project: String
        let cwd: String
        let startTime: String
        let messageCount: Int
        let customName: String?
        let generatedTitle: String?
        let tier: String?
    }

    struct WebTitleCandidate: Sendable, Equatable {
        let sessionId: String
        let generation: String
    }
}
