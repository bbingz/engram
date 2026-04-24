import Foundation

protocol EngramServiceClientProtocol: AnyObject, Sendable {
    func status() async throws -> EngramServiceStatus
    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse
    func health() async throws -> EngramServiceHealthResponse
    func liveSessions() async throws -> EngramServiceLiveSessionsResponse
    func sources() async throws -> [EngramServiceSourceInfo]
    func skills() async throws -> [EngramServiceSkillInfo]
    func memoryFiles() async throws -> [EngramServiceMemoryFile]
    func hooks() async throws -> [EngramServiceHookInfo]
    func hygiene(force: Bool) async throws -> EngramServiceHygieneResponse
    func handoff(_ request: EngramServiceHandoffRequest) async throws -> EngramServiceHandoffResponse
    func replayTimeline(sessionId: String, limit: Int?) async throws -> EngramServiceReplayTimelineResponse
    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse
    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse
    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue
    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue
    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse
    func confirmSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse
    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws
    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse
    func regenerateAllTitles() async throws -> EngramServiceRegenerateTitlesResponse
    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse
    func projectCwds(project: String) async throws -> EngramServiceProjectCwdsResponse
    func projectMove(_ request: EngramServiceProjectMoveRequest) async throws -> EngramServiceProjectMoveResult
    func projectArchive(_ request: EngramServiceProjectArchiveRequest) async throws -> EngramServiceProjectMoveResult
    func projectUndo(_ request: EngramServiceProjectUndoRequest) async throws -> EngramServiceProjectMoveResult
    func setFavorite(sessionId: String, favorite: Bool) async throws
    func setSessionHidden(sessionId: String, hidden: Bool) async throws
    func renameSession(sessionId: String, name: String?) async throws
    func hideEmptySessions() async throws -> EngramServiceHideEmptySessionsResponse
    func exportSession(_ request: EngramServiceExportSessionRequest) async throws -> EngramServiceExportSessionResponse
    func events() -> AsyncThrowingStream<EngramServiceEvent, Error>
    func close() async
}
