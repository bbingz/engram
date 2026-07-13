import Foundation

protocol EngramServiceClientProtocol: AnyObject, Sendable {
    func status() async throws -> EngramServiceStatus
    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse
    func health() async throws -> EngramServiceHealthResponse
    func liveSessions() async throws -> EngramServiceLiveSessionsResponse
    func sources() async throws -> [EngramServiceSourceInfo]
    func memoryFiles() async throws -> [EngramServiceMemoryFile]
    func memoryFileContent(path: String) async throws -> EngramServiceMemoryFileContentResponse
    func insights() async throws -> [EngramServiceInsightInfo]
    func insightDetail(id: String) async throws -> EngramServiceInsightInfo?
    func costs() async throws -> EngramServiceCostsResponse
    func telemetry() async throws -> ServiceTelemetrySnapshot
    func serviceLogs(level: String?, category: String?, limit: Int?) async throws -> ServiceLogSnapshot
    func hygiene(force: Bool) async throws -> EngramServiceHygieneResponse
    func handoff(_ request: EngramServiceHandoffRequest) async throws -> EngramServiceHandoffResponse
    func replayTimeline(sessionId: String, limit: Int?) async throws -> EngramServiceReplayTimelineResponse
    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse
    func generateProjectWorkTitles(_ request: EngramServiceGenerateProjectWorkTitlesRequest) async throws -> EngramServiceGenerateProjectWorkTitlesResponse
    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue
    func deleteInsight(_ request: EngramServiceDeleteInsightRequest) async throws -> EngramServiceJSONValue
    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue
    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse
    func setParentSession(sessionId: String, parentId: String) async throws -> EngramServiceLinkResponse
    func clearParentSession(sessionId: String) async throws -> EngramServiceLinkResponse
    func confirmSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse
    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws
    func dismissAmbiguousSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse
    func addSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse
    func removeSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse
    func relatedSessions(sessionId: String) async throws -> [String]
    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse
    func claudeCodeProfilesStatus() async throws -> EngramServiceClaudeCodeProfilesStatusResponse
    func configureClaudeCodeProfiles(
        _ request: EngramServiceConfigureClaudeCodeProfilesRequest
    ) async throws -> EngramServiceClaudeCodeProfilesStatusResponse
    func archiveV2Status() async throws -> EngramServiceArchiveV2StatusResponse
    func archiveV2Retry(
        _ request: EngramServiceArchiveV2RetryRequest
    ) async throws -> EngramServiceArchiveV2RetryResponse
    func archiveV2RemoteRecoveryProbe(
        _ request: EngramServiceArchiveV2RemoteRecoveryProbeRequest
    ) async throws -> EngramServiceArchiveV2RemoteRecoveryProbeResponse
    func archiveReclamationStatus() async throws -> EngramServiceArchiveReclamationStatusResponse
    func archiveReclamationPreview() async throws -> EngramServiceArchiveReclamationPreviewResponse
    func archiveReclamationUpdateSettings(
        _ request: EngramServiceArchiveReclamationUpdateSettingsRequest
    ) async throws -> EngramServiceArchiveReclamationStatusResponse
    func archiveReclamationRun() async throws -> EngramServiceArchiveReclamationRunResponse
    func archiveV2RecoveryDrill(
        _ request: EngramServiceArchiveV2RecoveryDrillRequest
    ) async throws -> EngramServiceArchiveV2RecoveryDrillResponse
    func archiveReadSessionPage(
        _ request: EngramServiceArchiveReadSessionPageRequest
    ) async throws -> EngramServiceArchiveReadSessionPageResponse
    func refreshUsage() async throws -> EngramServiceRefreshUsageResponse
    func regenerateAllTitles() async throws -> EngramServiceRegenerateTitlesResponse
    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse
    func projectCwds(project: String) async throws -> EngramServiceProjectCwdsResponse
    func projectMove(_ request: EngramServiceProjectMoveRequest) async throws -> EngramServiceProjectMoveResult
    func projectArchive(_ request: EngramServiceProjectArchiveRequest) async throws -> EngramServiceProjectMoveResult
    func projectUndo(_ request: EngramServiceProjectUndoRequest) async throws -> EngramServiceProjectMoveResult
    func setFavorite(sessionId: String, favorite: Bool) async throws
    func setSessionHidden(sessionId: String, hidden: Bool) async throws
    func setSourceEnabled(source: String, enabled: Bool) async throws
    func disabledSources() async throws -> [String]
    func renameSession(sessionId: String, name: String?) async throws
    func recordSessionAccess(sessionId: String) async throws
    func recordInsightAccess(ids: [String]) async throws
    func hideEmptySessions() async throws -> EngramServiceHideEmptySessionsResponse
    func exportSession(_ request: EngramServiceExportSessionRequest) async throws -> EngramServiceExportSessionResponse
    // remoteProjectSyncPreview / remotePushProject / remotePullProject are intentionally
    // NOT on this protocol: remote* commands are dispatched by raw command name. These
    // three are in fact the only remote* methods on the concrete EngramServiceClient —
    // the older remoteOffload/remoteRehydrate/remoteSyncStatus are invoked by name and
    // have no client method at all. Consumers that need these three hold the concrete type.
    func events() -> AsyncThrowingStream<EngramServiceEvent, Error>
    func close()
}
