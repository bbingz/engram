import Foundation

// Result properties are immutable `let`s set once at init so the mock is a
// genuine `Sendable` (no `@unchecked`) and free of data races under TSAN. Tests
// configure behavior through the initializer, not by mutating fields.
final class MockEngramServiceClient: EngramServiceClientProtocol, Sendable {
    let statusResult: Result<EngramServiceStatus, Error>
    let searchResult: Result<EngramServiceSearchResponse, Error>
    let healthResult: Result<EngramServiceHealthResponse, Error>
    let liveSessionsResult: Result<EngramServiceLiveSessionsResponse, Error>
    let sourcesResult: Result<[EngramServiceSourceInfo], Error>
    let memoryFilesResult: Result<[EngramServiceMemoryFile], Error>
    let memoryFileContentResult: Result<EngramServiceMemoryFileContentResponse, Error>
    let insightsResult: Result<[EngramServiceInsightInfo], Error>
    let insightDetailResult: Result<EngramServiceInsightInfo?, Error>
    let costsResult: Result<EngramServiceCostsResponse, Error>
    let telemetryResult: Result<ServiceTelemetrySnapshot, Error>
    let serviceLogsResult: Result<ServiceLogSnapshot, Error>
    let hygieneResult: Result<EngramServiceHygieneResponse, Error>
    let handoffResult: Result<EngramServiceHandoffResponse, Error>
    let replayTimelineResult: Result<EngramServiceReplayTimelineResponse, Error>
    let generateSummaryResult: Result<EngramServiceGenerateSummaryResponse, Error>
    let generateProjectWorkTitlesResult: Result<EngramServiceGenerateProjectWorkTitlesResponse, Error>
    let saveInsightResult: Result<EngramServiceJSONValue, Error>
    let deleteInsightResult: Result<EngramServiceJSONValue, Error>
    let manageProjectAliasResult: Result<EngramServiceJSONValue, Error>
    let resumeCommandResult: Result<EngramServiceResumeCommandResponse, Error>
    let setParentSessionResult: Result<EngramServiceLinkResponse, Error>
    let clearParentSessionResult: Result<EngramServiceLinkResponse, Error>
    let confirmSuggestionResult: Result<EngramServiceLinkResponse, Error>
    let dismissSuggestionResult: Result<Void, Error>
    let dismissAmbiguousSuggestionResult: Result<EngramServiceLinkResponse, Error>
    let addSessionRelationResult: Result<EngramServiceLinkResponse, Error>
    let removeSessionRelationResult: Result<EngramServiceLinkResponse, Error>
    let relatedSessionsResult: Result<[String], Error>
    let triggerSyncResult: Result<EngramServiceTriggerSyncResponse, Error>
    let archiveV2StatusResult: Result<EngramServiceArchiveV2StatusResponse, Error>
    let archiveV2RetryResult: Result<EngramServiceArchiveV2RetryResponse, Error>
    let archiveV2RemoteRecoveryProbeResult: Result<EngramServiceArchiveV2RemoteRecoveryProbeResponse, Error>
    let archiveReclamationStatusResult: Result<EngramServiceArchiveReclamationStatusResponse, Error>
    let archiveReclamationPreviewResult: Result<EngramServiceArchiveReclamationPreviewResponse, Error>
    let archiveReclamationRunResult: Result<EngramServiceArchiveReclamationRunResponse, Error>
    let archiveV2RecoveryDrillResult: Result<EngramServiceArchiveV2RecoveryDrillResponse, Error>
    let archiveReadSessionPageResult: Result<EngramServiceArchiveReadSessionPageResponse, Error>
    let refreshUsageResult: Result<EngramServiceRefreshUsageResponse, Error>
    let regenerateAllTitlesResult: Result<EngramServiceRegenerateTitlesResponse, Error>
    let projectMigrationsResult: Result<EngramServiceProjectMigrationsResponse, Error>
    let projectCwdsResult: Result<EngramServiceProjectCwdsResponse, Error>
    let projectMoveResult: Result<EngramServiceProjectMoveResult, Error>
    let projectArchiveResult: Result<EngramServiceProjectMoveResult, Error>
    let projectUndoResult: Result<EngramServiceProjectMoveResult, Error>
    let setFavoriteResult: Result<Void, Error>
    let setSessionHiddenResult: Result<Void, Error>
    let setSourceEnabledResult: Result<Void, Error>
    let disabledSourcesResult: Result<[String], Error>
    let renameSessionResult: Result<Void, Error>
    let recordSessionAccessResult: Result<Void, Error>
    let recordInsightAccessResult: Result<Void, Error>
    let hideEmptySessionsResult: Result<EngramServiceHideEmptySessionsResponse, Error>
    let exportSessionResult: Result<EngramServiceExportSessionResponse, Error>
    private let eventStream: AsyncThrowingStream<EngramServiceEvent, Error>

    init(
        status: EngramServiceStatus = .stopped,
        statusResult: Result<EngramServiceStatus, Error>? = nil,
        search: EngramServiceSearchResponse = EngramServiceSearchResponse(items: []),
        health: EngramServiceHealthResponse = EngramServiceHealthResponse(ok: true, status: "healthy", message: "mock"),
        liveSessions: EngramServiceLiveSessionsResponse = EngramServiceLiveSessionsResponse(sessions: [], count: 0),
        sources: [EngramServiceSourceInfo] = [],
        memoryFiles: [EngramServiceMemoryFile] = [],
        memoryFileContent: EngramServiceMemoryFileContentResponse = EngramServiceMemoryFileContentResponse(path: "", content: "", truncated: false),
        insights: [EngramServiceInsightInfo] = [],
        insightDetail: EngramServiceInsightInfo? = nil,
        costs: EngramServiceCostsResponse = EngramServiceCostsResponse(totalUsd: 0, perSource: [], perDay: [], monthToDateUsd: 0, todayUsd: 0),
        telemetry: ServiceTelemetrySnapshot = ServiceTelemetrySnapshot(lastScanDurationMs: nil, lastScanIndexed: 0, lastScanTotal: 0, scanCount: 0, lastScanAt: nil, commands: [], spans: []),
        serviceLogs: ServiceLogSnapshot = ServiceLogSnapshot(lines: []),
        hygiene: EngramServiceHygieneResponse = EngramServiceHygieneResponse(issues: [], score: 100, checkedAt: "2026-01-01T00:00:00Z"),
        handoff: EngramServiceHandoffResponse = EngramServiceHandoffResponse(brief: "## Handoff\n\nNo recent sessions found.", sessionCount: 0),
        replayTimeline: EngramServiceReplayTimelineResponse = EngramServiceReplayTimelineResponse(sessionId: nil, source: nil, entries: [], totalEntries: 0, hasMore: false, offset: nil, limit: nil),
        generateSummary: EngramServiceGenerateSummaryResponse = EngramServiceGenerateSummaryResponse(summary: "Mock summary"),
        generateProjectWorkTitles: EngramServiceGenerateProjectWorkTitlesResponse = EngramServiceGenerateProjectWorkTitlesResponse(titles: []),
        saveInsight: EngramServiceJSONValue = .object(["id": .string("mock-insight")]),
        deleteInsight: EngramServiceJSONValue = .object(["id": .string("mock-insight"), "deleted": .bool(true)]),
        manageProjectAlias: EngramServiceJSONValue = .object(["ok": .bool(true)]),
        resumeCommand: EngramServiceResumeCommandResponse = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "/usr/local/bin/codex",
            args: ["--resume", "mock-session"],
            cwd: "/tmp/mock-session"
        ),
        setParentSession: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        clearParentSession: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        confirmSuggestion: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        dismissAmbiguousSuggestion: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        addSessionRelation: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        removeSessionRelation: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        relatedSessions: [String] = [],
        triggerSync: EngramServiceTriggerSyncResponse = EngramServiceTriggerSyncResponse(results: []),
        archiveV2Status: EngramServiceArchiveV2StatusResponse = MockEngramServiceClient.defaultArchiveV2Status,
        archiveV2Retry: EngramServiceArchiveV2RetryResponse = MockEngramServiceClient.defaultArchiveV2Retry,
        archiveV2RemoteRecoveryProbe: EngramServiceArchiveV2RemoteRecoveryProbeResponse = try! EngramServiceArchiveV2RemoteRecoveryProbeResponse(
            tier: "hq",
            receiptSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            wholeSourceSHA256: String(repeating: "c", count: 64)
        ),
        archiveReclamationStatus: EngramServiceArchiveReclamationStatusResponse = .init(enabled: false, hotWindowDays: 30, configurationError: nil, recoveryLeaseCurrent: false, cycleRunning: false, lastError: nil),
        archiveReclamationPreview: EngramServiceArchiveReclamationPreviewResponse = .init(eligibleCount: 0, estimatedSourceBytes: 0, blockedCounts: [:]),
        archiveReclamationRun: EngramServiceArchiveReclamationRunResponse = .init(accepted: false, coalesced: false, sourceFilesReclaimed: 0, casObjectsEvicted: 0, releasedBytes: 0, error: "disabled"),
        archiveV2RecoveryDrill: EngramServiceArchiveV2RecoveryDrillResponse = .init(replicaID: "hq", manifestSHA256: String(repeating: "d", count: 64), verifiedAt: "2026-01-01T00:00:00.000Z", verifiedBytes: 0),
        archiveReadSessionPage: EngramServiceArchiveReadSessionPageResponse = MockEngramServiceClient.defaultArchiveReadSessionPage,
        refreshUsage: EngramServiceRefreshUsageResponse = EngramServiceRefreshUsageResponse(snapshotCount: 0, sources: []),
        regenerateAllTitles: EngramServiceRegenerateTitlesResponse = EngramServiceRegenerateTitlesResponse(
            status: "started",
            total: 0,
            message: nil
        ),
        projectMigrations: EngramServiceProjectMigrationsResponse = EngramServiceProjectMigrationsResponse(migrations: []),
        projectCwds: EngramServiceProjectCwdsResponse = EngramServiceProjectCwdsResponse(project: "", cwds: []),
        projectMove: EngramServiceProjectMoveResult = MockEngramServiceClient.defaultProjectMoveResult,
        projectArchive: EngramServiceProjectMoveResult = MockEngramServiceClient.defaultProjectMoveResult,
        projectUndo: EngramServiceProjectMoveResult = MockEngramServiceClient.defaultProjectMoveResult,
        hideEmptySessions: EngramServiceHideEmptySessionsResponse = EngramServiceHideEmptySessionsResponse(hiddenCount: 0),
        exportSession: EngramServiceExportSessionResponse = EngramServiceExportSessionResponse(
            outputPath: "/tmp/mock-export.md",
            format: "markdown",
            messageCount: 0
        ),
        disabledSources: [String] = [],
        events: AsyncThrowingStream<EngramServiceEvent, Error> = AsyncThrowingStream { $0.finish() }
    ) {
        self.statusResult = statusResult ?? .success(status)
        self.searchResult = .success(search)
        self.healthResult = .success(health)
        self.liveSessionsResult = .success(liveSessions)
        self.sourcesResult = .success(sources)
        self.memoryFilesResult = .success(memoryFiles)
        self.memoryFileContentResult = .success(memoryFileContent)
        self.insightsResult = .success(insights)
        self.insightDetailResult = .success(insightDetail)
        self.costsResult = .success(costs)
        self.telemetryResult = .success(telemetry)
        self.serviceLogsResult = .success(serviceLogs)
        self.hygieneResult = .success(hygiene)
        self.handoffResult = .success(handoff)
        self.replayTimelineResult = .success(replayTimeline)
        self.generateSummaryResult = .success(generateSummary)
        self.generateProjectWorkTitlesResult = .success(generateProjectWorkTitles)
        self.saveInsightResult = .success(saveInsight)
        self.deleteInsightResult = .success(deleteInsight)
        self.manageProjectAliasResult = .success(manageProjectAlias)
        self.resumeCommandResult = .success(resumeCommand)
        self.setParentSessionResult = .success(setParentSession)
        self.clearParentSessionResult = .success(clearParentSession)
        self.confirmSuggestionResult = .success(confirmSuggestion)
        self.dismissSuggestionResult = .success(())
        self.dismissAmbiguousSuggestionResult = .success(dismissAmbiguousSuggestion)
        self.addSessionRelationResult = .success(addSessionRelation)
        self.removeSessionRelationResult = .success(removeSessionRelation)
        self.relatedSessionsResult = .success(relatedSessions)
        self.triggerSyncResult = .success(triggerSync)
        self.archiveV2StatusResult = .success(archiveV2Status)
        self.archiveV2RetryResult = .success(archiveV2Retry)
        self.archiveV2RemoteRecoveryProbeResult = .success(archiveV2RemoteRecoveryProbe)
        self.archiveReclamationStatusResult = .success(archiveReclamationStatus)
        self.archiveReclamationPreviewResult = .success(archiveReclamationPreview)
        self.archiveReclamationRunResult = .success(archiveReclamationRun)
        self.archiveV2RecoveryDrillResult = .success(archiveV2RecoveryDrill)
        self.archiveReadSessionPageResult = .success(archiveReadSessionPage)
        self.refreshUsageResult = .success(refreshUsage)
        self.regenerateAllTitlesResult = .success(regenerateAllTitles)
        self.projectMigrationsResult = .success(projectMigrations)
        self.projectCwdsResult = .success(projectCwds)
        self.projectMoveResult = .success(projectMove)
        self.projectArchiveResult = .success(projectArchive)
        self.projectUndoResult = .success(projectUndo)
        self.setFavoriteResult = .success(())
        self.setSessionHiddenResult = .success(())
        self.setSourceEnabledResult = .success(())
        self.disabledSourcesResult = .success(disabledSources)
        self.renameSessionResult = .success(())
        self.recordSessionAccessResult = .success(())
        self.recordInsightAccessResult = .success(())
        self.hideEmptySessionsResult = .success(hideEmptySessions)
        self.exportSessionResult = .success(exportSession)
        self.eventStream = events
    }

    func status() async throws -> EngramServiceStatus { try statusResult.get() }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        try searchResult.get()
    }

    func health() async throws -> EngramServiceHealthResponse { try healthResult.get() }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse { try liveSessionsResult.get() }

    func sources() async throws -> [EngramServiceSourceInfo] { try sourcesResult.get() }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] { try memoryFilesResult.get() }

    func memoryFileContent(path: String) async throws -> EngramServiceMemoryFileContentResponse {
        try memoryFileContentResult.get()
    }

    func insights() async throws -> [EngramServiceInsightInfo] { try insightsResult.get() }

    func insightDetail(id: String) async throws -> EngramServiceInsightInfo? { try insightDetailResult.get() }

    func costs() async throws -> EngramServiceCostsResponse { try costsResult.get() }

    func telemetry() async throws -> ServiceTelemetrySnapshot { try telemetryResult.get() }

    func serviceLogs(level: String?, category: String?, limit: Int?) async throws -> ServiceLogSnapshot {
        try serviceLogsResult.get()
    }

    func hygiene(force: Bool) async throws -> EngramServiceHygieneResponse { try hygieneResult.get() }

    func handoff(_ request: EngramServiceHandoffRequest) async throws -> EngramServiceHandoffResponse {
        try handoffResult.get()
    }

    func replayTimeline(sessionId: String, limit: Int?) async throws -> EngramServiceReplayTimelineResponse {
        try replayTimelineResult.get()
    }

    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse {
        try generateSummaryResult.get()
    }

    func generateProjectWorkTitles(_ request: EngramServiceGenerateProjectWorkTitlesRequest) async throws -> EngramServiceGenerateProjectWorkTitlesResponse {
        try generateProjectWorkTitlesResult.get()
    }

    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue {
        try saveInsightResult.get()
    }

    func deleteInsight(_ request: EngramServiceDeleteInsightRequest) async throws -> EngramServiceJSONValue {
        try deleteInsightResult.get()
    }

    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue {
        try manageProjectAliasResult.get()
    }

    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse {
        try resumeCommandResult.get()
    }

    func setParentSession(sessionId: String, parentId: String) async throws -> EngramServiceLinkResponse {
        try setParentSessionResult.get()
    }

    func clearParentSession(sessionId: String) async throws -> EngramServiceLinkResponse {
        try clearParentSessionResult.get()
    }

    func confirmSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse {
        try confirmSuggestionResult.get()
    }

    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws {
        _ = try dismissSuggestionResult.get()
    }

    func dismissAmbiguousSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse {
        try dismissAmbiguousSuggestionResult.get()
    }

    func addSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse {
        try addSessionRelationResult.get()
    }

    func removeSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse {
        try removeSessionRelationResult.get()
    }

    func relatedSessions(sessionId: String) async throws -> [String] {
        try relatedSessionsResult.get()
    }

    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse {
        try triggerSyncResult.get()
    }

    func archiveV2Status() async throws -> EngramServiceArchiveV2StatusResponse {
        try archiveV2StatusResult.get()
    }

    func archiveV2Retry(
        _ request: EngramServiceArchiveV2RetryRequest
    ) async throws -> EngramServiceArchiveV2RetryResponse {
        try archiveV2RetryResult.get()
    }

    func archiveV2RemoteRecoveryProbe(
        _ request: EngramServiceArchiveV2RemoteRecoveryProbeRequest
    ) async throws -> EngramServiceArchiveV2RemoteRecoveryProbeResponse {
        try archiveV2RemoteRecoveryProbeResult.get()
    }

    func archiveReclamationStatus() async throws -> EngramServiceArchiveReclamationStatusResponse {
        try archiveReclamationStatusResult.get()
    }

    func archiveReclamationPreview() async throws -> EngramServiceArchiveReclamationPreviewResponse {
        try archiveReclamationPreviewResult.get()
    }

    func archiveReclamationUpdateSettings(
        _ request: EngramServiceArchiveReclamationUpdateSettingsRequest
    ) async throws -> EngramServiceArchiveReclamationStatusResponse {
        try archiveReclamationStatusResult.get()
    }

    func archiveReclamationRun() async throws -> EngramServiceArchiveReclamationRunResponse {
        try archiveReclamationRunResult.get()
    }

    func archiveV2RecoveryDrill(
        _ request: EngramServiceArchiveV2RecoveryDrillRequest
    ) async throws -> EngramServiceArchiveV2RecoveryDrillResponse {
        try archiveV2RecoveryDrillResult.get()
    }

    func archiveReadSessionPage(
        _ request: EngramServiceArchiveReadSessionPageRequest
    ) async throws -> EngramServiceArchiveReadSessionPageResponse {
        try archiveReadSessionPageResult.get()
    }

    func refreshUsage() async throws -> EngramServiceRefreshUsageResponse {
        try refreshUsageResult.get()
    }

    func regenerateAllTitles() async throws -> EngramServiceRegenerateTitlesResponse {
        try regenerateAllTitlesResult.get()
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        try projectMigrationsResult.get()
    }

    func projectCwds(project: String) async throws -> EngramServiceProjectCwdsResponse {
        try projectCwdsResult.get()
    }

    func projectMove(_ request: EngramServiceProjectMoveRequest) async throws -> EngramServiceProjectMoveResult {
        try projectMoveResult.get()
    }

    func projectArchive(_ request: EngramServiceProjectArchiveRequest) async throws -> EngramServiceProjectMoveResult {
        try projectArchiveResult.get()
    }

    func projectUndo(_ request: EngramServiceProjectUndoRequest) async throws -> EngramServiceProjectMoveResult {
        try projectUndoResult.get()
    }

    func setFavorite(sessionId: String, favorite: Bool) async throws {
        _ = try setFavoriteResult.get()
    }

    func setSessionHidden(sessionId: String, hidden: Bool) async throws {
        _ = try setSessionHiddenResult.get()
    }

    func setSourceEnabled(source: String, enabled: Bool) async throws {
        _ = try setSourceEnabledResult.get()
    }

    func disabledSources() async throws -> [String] {
        try disabledSourcesResult.get()
    }

    func renameSession(sessionId: String, name: String?) async throws {
        _ = try renameSessionResult.get()
    }

    func recordSessionAccess(sessionId: String) async throws {
        _ = try recordSessionAccessResult.get()
    }

    func recordInsightAccess(ids: [String]) async throws {
        _ = try recordInsightAccessResult.get()
    }

    func hideEmptySessions() async throws -> EngramServiceHideEmptySessionsResponse {
        try hideEmptySessionsResult.get()
    }

    func exportSession(_ request: EngramServiceExportSessionRequest) async throws -> EngramServiceExportSessionResponse {
        try exportSessionResult.get()
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        eventStream
    }

    func close() {}

    private static let defaultArchiveV2Status = try! EngramServiceArchiveV2StatusResponse(
        enabled: false,
        localCaptureEnabled: false,
        remoteReplicationEnabled: false,
        configurationError: nil,
        capturedCount: 0,
        boundCount: 0,
        unboundCount: 0,
        remotePolicyUnknownCount: 0,
        remotePolicyEligibleCount: 0,
        remotePolicyExcludedCount: 0,
        unsupportedLocatorCount: 0,
        unsafeLocatorCount: 0,
        replicas: [
            try! EngramServiceArchiveV2ReplicaStatus(
                replicaID: "hq",
                queuedCount: 0,
                retryingCount: 0,
                quarantinedCount: 0,
                verifiedCount: 0,
                remoteTelemetry: nil,
                remoteTelemetryError: nil
            ),
            try! EngramServiceArchiveV2ReplicaStatus(
                replicaID: "m1",
                queuedCount: 0,
                retryingCount: 0,
                quarantinedCount: 0,
                verifiedCount: 0,
                remoteTelemetry: nil,
                remoteTelemetryError: nil
            ),
        ],
        singleReplicaVerifiedCount: 0,
        dualReplicaVerifiedCount: 0,
        latestReceipts: [],
        lastCaptureError: nil,
        lastReplicationError: nil,
        cycleRunning: false,
        cycleCoalesced: false
    )

    private static let defaultArchiveV2Retry = try! EngramServiceArchiveV2RetryResponse(
        accepted: true,
        resetRows: 0,
        error: nil
    )

    private static let defaultArchiveReadSessionPage = try! EngramServiceArchiveReadSessionPageResponse(
        messages: [],
        totalPages: 1,
        currentPage: 1,
        totalKnownComplete: true,
        truncatedAt: nil,
        responseBudgetTruncated: false
    )

    private static let defaultProjectMoveResult = EngramServiceProjectMoveResult(
        migrationId: "mock",
        state: "dry-run",
        moveStrategy: nil,
        ccDirRenamed: false,
        renamedDirs: nil,
        totalFilesPatched: 0,
        totalOccurrences: 0,
        sessionsUpdated: 0,
        aliasCreated: false,
        review: EngramServiceProjectMoveResult.ReviewBlock(own: [], other: []),
        git: nil,
        manifest: [],
        perSource: [],
        skippedDirs: [],
        suggestion: nil
    )
}
