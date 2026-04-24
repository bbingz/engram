import Foundation

final class MockEngramServiceClient: EngramServiceClientProtocol, @unchecked Sendable {
    var statusResult: Result<EngramServiceStatus, Error>
    var searchResult: Result<EngramServiceSearchResponse, Error>
    var healthResult: Result<EngramServiceHealthResponse, Error>
    var liveSessionsResult: Result<EngramServiceLiveSessionsResponse, Error>
    var sourcesResult: Result<[EngramServiceSourceInfo], Error>
    var skillsResult: Result<[EngramServiceSkillInfo], Error>
    var memoryFilesResult: Result<[EngramServiceMemoryFile], Error>
    var hooksResult: Result<[EngramServiceHookInfo], Error>
    var hygieneResult: Result<EngramServiceHygieneResponse, Error>
    var handoffResult: Result<EngramServiceHandoffResponse, Error>
    var replayTimelineResult: Result<EngramServiceReplayTimelineResponse, Error>
    var embeddingStatusResult: Result<EngramServiceEmbeddingStatusResponse, Error>
    var generateSummaryResult: Result<EngramServiceGenerateSummaryResponse, Error>
    var saveInsightResult: Result<EngramServiceJSONValue, Error>
    var manageProjectAliasResult: Result<EngramServiceJSONValue, Error>
    var resumeCommandResult: Result<EngramServiceResumeCommandResponse, Error>
    var confirmSuggestionResult: Result<EngramServiceLinkResponse, Error>
    var dismissSuggestionResult: Result<Void, Error>
    var triggerSyncResult: Result<EngramServiceTriggerSyncResponse, Error>
    var regenerateAllTitlesResult: Result<EngramServiceRegenerateTitlesResponse, Error>
    var projectMigrationsResult: Result<EngramServiceProjectMigrationsResponse, Error>
    var projectCwdsResult: Result<EngramServiceProjectCwdsResponse, Error>
    var projectMoveResult: Result<EngramServiceProjectMoveResult, Error>
    var projectArchiveResult: Result<EngramServiceProjectMoveResult, Error>
    var projectUndoResult: Result<EngramServiceProjectMoveResult, Error>
    var setFavoriteResult: Result<Void, Error>
    var setSessionHiddenResult: Result<Void, Error>
    var renameSessionResult: Result<Void, Error>
    var hideEmptySessionsResult: Result<EngramServiceHideEmptySessionsResponse, Error>
    var exportSessionResult: Result<EngramServiceExportSessionResponse, Error>
    private let eventStream: AsyncThrowingStream<EngramServiceEvent, Error>

    init(
        status: EngramServiceStatus = .stopped,
        search: EngramServiceSearchResponse = EngramServiceSearchResponse(items: []),
        health: EngramServiceHealthResponse = EngramServiceHealthResponse(ok: true, status: "healthy", message: "mock"),
        liveSessions: EngramServiceLiveSessionsResponse = EngramServiceLiveSessionsResponse(sessions: [], count: 0),
        sources: [EngramServiceSourceInfo] = [],
        skills: [EngramServiceSkillInfo] = [],
        memoryFiles: [EngramServiceMemoryFile] = [],
        hooks: [EngramServiceHookInfo] = [],
        hygiene: EngramServiceHygieneResponse = EngramServiceHygieneResponse(issues: [], score: 100, checkedAt: "2026-01-01T00:00:00Z"),
        handoff: EngramServiceHandoffResponse = EngramServiceHandoffResponse(brief: "## Handoff\n\nNo recent sessions found.", sessionCount: 0),
        replayTimeline: EngramServiceReplayTimelineResponse = EngramServiceReplayTimelineResponse(sessionId: nil, source: nil, entries: [], totalEntries: 0, hasMore: false, offset: nil, limit: nil),
        embeddingStatus: EngramServiceEmbeddingStatusResponse = EngramServiceEmbeddingStatusResponse(available: false, model: nil, embeddedCount: 0, totalSessions: 0, progress: 0),
        generateSummary: EngramServiceGenerateSummaryResponse = EngramServiceGenerateSummaryResponse(summary: "Mock summary"),
        saveInsight: EngramServiceJSONValue = .object(["id": .string("mock-insight")]),
        manageProjectAlias: EngramServiceJSONValue = .object(["ok": .bool(true)]),
        resumeCommand: EngramServiceResumeCommandResponse = EngramServiceResumeCommandResponse(
            tool: "codex",
            command: "/usr/local/bin/codex",
            args: ["--resume", "mock-session"],
            cwd: "/tmp/mock-session"
        ),
        confirmSuggestion: EngramServiceLinkResponse = EngramServiceLinkResponse(ok: true, error: nil),
        triggerSync: EngramServiceTriggerSyncResponse = EngramServiceTriggerSyncResponse(results: []),
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
        events: AsyncThrowingStream<EngramServiceEvent, Error> = AsyncThrowingStream { $0.finish() }
    ) {
        self.statusResult = .success(status)
        self.searchResult = .success(search)
        self.healthResult = .success(health)
        self.liveSessionsResult = .success(liveSessions)
        self.sourcesResult = .success(sources)
        self.skillsResult = .success(skills)
        self.memoryFilesResult = .success(memoryFiles)
        self.hooksResult = .success(hooks)
        self.hygieneResult = .success(hygiene)
        self.handoffResult = .success(handoff)
        self.replayTimelineResult = .success(replayTimeline)
        self.embeddingStatusResult = .success(embeddingStatus)
        self.generateSummaryResult = .success(generateSummary)
        self.saveInsightResult = .success(saveInsight)
        self.manageProjectAliasResult = .success(manageProjectAlias)
        self.resumeCommandResult = .success(resumeCommand)
        self.confirmSuggestionResult = .success(confirmSuggestion)
        self.dismissSuggestionResult = .success(())
        self.triggerSyncResult = .success(triggerSync)
        self.regenerateAllTitlesResult = .success(regenerateAllTitles)
        self.projectMigrationsResult = .success(projectMigrations)
        self.projectCwdsResult = .success(projectCwds)
        self.projectMoveResult = .success(projectMove)
        self.projectArchiveResult = .success(projectArchive)
        self.projectUndoResult = .success(projectUndo)
        self.setFavoriteResult = .success(())
        self.setSessionHiddenResult = .success(())
        self.renameSessionResult = .success(())
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

    func skills() async throws -> [EngramServiceSkillInfo] { try skillsResult.get() }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] { try memoryFilesResult.get() }

    func hooks() async throws -> [EngramServiceHookInfo] { try hooksResult.get() }

    func hygiene(force: Bool) async throws -> EngramServiceHygieneResponse { try hygieneResult.get() }

    func handoff(_ request: EngramServiceHandoffRequest) async throws -> EngramServiceHandoffResponse {
        try handoffResult.get()
    }

    func replayTimeline(sessionId: String, limit: Int?) async throws -> EngramServiceReplayTimelineResponse {
        try replayTimelineResult.get()
    }

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        try embeddingStatusResult.get()
    }

    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse {
        try generateSummaryResult.get()
    }

    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue {
        try saveInsightResult.get()
    }

    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue {
        try manageProjectAliasResult.get()
    }

    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse {
        try resumeCommandResult.get()
    }

    func confirmSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse {
        try confirmSuggestionResult.get()
    }

    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws {
        _ = try dismissSuggestionResult.get()
    }

    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse {
        try triggerSyncResult.get()
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

    func renameSession(sessionId: String, name: String?) async throws {
        _ = try renameSessionResult.get()
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

    func close() async {}

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
