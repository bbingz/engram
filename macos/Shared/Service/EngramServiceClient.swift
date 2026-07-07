import Foundation
import Observation

// All stored properties are immutable `@ObservationIgnored let`s holding
// `Sendable` values, so the compiler can verify `Sendable` without `@unchecked`.
@Observable
final class EngramServiceClient: EngramServiceClientProtocol, Sendable {
    private static let migrationCommandTimeout: TimeInterval = 10 * 60
    private static let bulkAICommandTimeout: TimeInterval = 10 * 60
    private static let frameBoundCommandTimeout: TimeInterval = 25

    @ObservationIgnored
    private let transport: any EngramServiceTransport
    @ObservationIgnored
    private let defaultTimeout: TimeInterval

    init(
        transport: any EngramServiceTransport,
        defaultTimeout: TimeInterval = 30
    ) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
    }

    func status() async throws -> EngramServiceStatus {
        try await command("status", payload: EmptyServicePayload())
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        try await command("search", payload: request)
    }

    func health() async throws -> EngramServiceHealthResponse {
        try await command("health")
    }

    func liveSessions() async throws -> EngramServiceLiveSessionsResponse {
        try await command("liveSessions")
    }

    func sources() async throws -> [EngramServiceSourceInfo] {
        try await command("sources")
    }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        try await command("memoryFiles")
    }

    func memoryFileContent(path: String) async throws -> EngramServiceMemoryFileContentResponse {
        try await command(
            "memoryFileContent",
            payload: EngramServiceMemoryFileContentRequest(path: path)
        )
    }

    func insights() async throws -> [EngramServiceInsightInfo] {
        try await command("insights")
    }

    func insightDetail(id: String) async throws -> EngramServiceInsightInfo? {
        try await command(
            "insightDetail",
            payload: EngramServiceInsightDetailRequest(id: id)
        )
    }

    func costs() async throws -> EngramServiceCostsResponse {
        try await command("costs")
    }

    func telemetry() async throws -> ServiceTelemetrySnapshot {
        try await command("telemetry")
    }

    func serviceLogs(level: String?, category: String?, limit: Int?) async throws -> ServiceLogSnapshot {
        try await command(
            "serviceLogs",
            payload: EngramServiceServiceLogsRequest(level: level, category: category, limit: limit)
        )
    }

    func hygiene(force: Bool) async throws -> EngramServiceHygieneResponse {
        try await command("hygiene", payload: EngramServiceHygieneRequest(force: force))
    }

    func handoff(_ request: EngramServiceHandoffRequest) async throws -> EngramServiceHandoffResponse {
        try await command("handoff", payload: request)
    }

    func replayTimeline(sessionId: String, limit: Int?) async throws -> EngramServiceReplayTimelineResponse {
        try await command(
            "replayTimeline",
            payload: EngramServiceReplayTimelineRequest(sessionId: sessionId, limit: limit)
        )
    }

    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse {
        try await command("generateSummary", payload: request, timeout: Self.frameBoundCommandTimeout)
    }

    func generateProjectWorkTitles(_ request: EngramServiceGenerateProjectWorkTitlesRequest) async throws -> EngramServiceGenerateProjectWorkTitlesResponse {
        try await command("generateProjectWorkTitles", payload: request, timeout: Self.bulkAICommandTimeout)
    }

    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue {
        try await command("saveInsight", payload: request)
    }

    func deleteInsight(_ request: EngramServiceDeleteInsightRequest) async throws -> EngramServiceJSONValue {
        try await command("deleteInsight", payload: request)
    }

    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue {
        try await command("manageProjectAlias", payload: request)
    }

    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse {
        try await command("resumeCommand", payload: EngramServiceResumeCommandRequest(sessionId: sessionId))
    }

    func setParentSession(sessionId: String, parentId: String) async throws -> EngramServiceLinkResponse {
        try await command("setParentSession", payload: EngramServiceLinkRequest(sessionId: sessionId, parentId: parentId))
    }

    func clearParentSession(sessionId: String) async throws -> EngramServiceLinkResponse {
        try await command("clearParentSession", payload: EngramServiceUnlinkRequest(sessionId: sessionId))
    }

    func confirmSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse {
        try await command(
            "confirmSuggestion",
            payload: EngramServiceConfirmSuggestionRequest(sessionId: sessionId)
        )
    }

    func dismissSuggestion(sessionId: String, suggestedParentId: String) async throws {
        let _: EmptyServiceResult = try await command(
            "dismissSuggestion",
            payload: EngramServiceDismissSuggestionRequest(
                sessionId: sessionId,
                suggestedParentId: suggestedParentId
            )
        )
    }

    func dismissAmbiguousSuggestion(sessionId: String) async throws -> EngramServiceLinkResponse {
        try await command(
            "dismissAmbiguousSuggestion",
            payload: EngramServiceDismissAmbiguousSuggestionRequest(sessionId: sessionId)
        )
    }

    func addSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse {
        try await command("addSessionRelation", payload: EngramServiceRelationRequest(aId: aId, bId: bId))
    }

    func removeSessionRelation(aId: String, bId: String) async throws -> EngramServiceLinkResponse {
        try await command("removeSessionRelation", payload: EngramServiceRelationRequest(aId: aId, bId: bId))
    }

    func relatedSessions(sessionId: String) async throws -> [String] {
        let response: EngramServiceRelatedSessionsResponse = try await command(
            "relatedSessions",
            payload: EngramServiceRelatedSessionsRequest(sessionId: sessionId)
        )
        return response.ids
    }

    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse {
        try await command("triggerSync", payload: request)
    }

    func refreshUsage() async throws -> EngramServiceRefreshUsageResponse {
        try await command("refreshUsage")
    }

    func regenerateAllTitles() async throws -> EngramServiceRegenerateTitlesResponse {
        try await command("regenerateAllTitles", timeout: Self.bulkAICommandTimeout)
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        try await command("projectMigrations", payload: request)
    }

    func projectCwds(project: String) async throws -> EngramServiceProjectCwdsResponse {
        try await command("projectCwds", payload: EngramServiceProjectCwdsRequest(project: project))
    }

    func projectMove(_ request: EngramServiceProjectMoveRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectMove", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func projectArchive(_ request: EngramServiceProjectArchiveRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectArchive", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func projectUndo(_ request: EngramServiceProjectUndoRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectUndo", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func projectMoveBatch(_ request: EngramServiceProjectMoveBatchRequest) async throws -> EngramServiceJSONValue {
        try await command("projectMoveBatch", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func linkSessions(_ request: EngramServiceLinkSessionsRequest) async throws -> EngramServiceLinkSessionsResponse {
        try await command("linkSessions", payload: request, timeout: Self.frameBoundCommandTimeout)
    }

    func setFavorite(sessionId: String, favorite: Bool) async throws {
        let _: EmptyServiceResult = try await command(
            "setFavorite",
            payload: EngramServiceFavoriteRequest(sessionId: sessionId, favorite: favorite)
        )
    }

    func setSessionHidden(sessionId: String, hidden: Bool) async throws {
        let _: EmptyServiceResult = try await command(
            "setSessionHidden",
            payload: EngramServiceSessionHiddenRequest(sessionId: sessionId, hidden: hidden)
        )
    }

    func setSourceEnabled(source: String, enabled: Bool) async throws {
        let _: EmptyServiceResult = try await command(
            "setSourceEnabled",
            payload: EngramServiceSetSourceEnabledRequest(source: source, enabled: enabled)
        )
    }

    func disabledSources() async throws -> [String] {
        let response: EngramServiceDisabledSourcesResponse = try await command("disabledSources")
        return response.sources
    }

    func renameSession(sessionId: String, name: String?) async throws {
        let _: EmptyServiceResult = try await command(
            "renameSession",
            payload: EngramServiceRenameSessionRequest(sessionId: sessionId, name: name)
        )
    }

    func recordSessionAccess(sessionId: String) async throws {
        let _: EmptyServiceResult = try await command(
            "recordSessionAccess",
            payload: EngramServiceSessionAccessRequest(sessionId: sessionId)
        )
    }

    func recordInsightAccess(ids: [String]) async throws {
        let _: EmptyServiceResult = try await command(
            "recordInsightAccess",
            payload: EngramServiceInsightAccessRequest(ids: ids)
        )
    }

    func hideEmptySessions() async throws -> EngramServiceHideEmptySessionsResponse {
        try await command("hideEmptySessions")
    }

    func exportSession(_ request: EngramServiceExportSessionRequest) async throws -> EngramServiceExportSessionResponse {
        try await command("exportSession", payload: request)
    }

    func remoteProjectSyncPreview(
        _ request: EngramServiceRemoteProjectSyncRequest
    ) async throws -> EngramServiceRemoteProjectSyncPreviewResponse {
        try await command("remoteProjectSyncPreview", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func remotePushProject(
        _ request: EngramServiceRemoteProjectSyncRequest
    ) async throws -> EngramServiceRemotePushProjectResponse {
        try await command("remotePushProject", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func remotePullProject(
        _ request: EngramServiceRemoteProjectSyncRequest
    ) async throws -> EngramServiceRemotePullProjectResponse {
        try await command("remotePullProject", payload: request, timeout: Self.migrationCommandTimeout)
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        transport.events()
    }

    func close() {
        transport.close()
    }

    private func command<Response: Decodable>(
        _ name: String,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        try await command(name, payload: EmptyServicePayload(), timeout: timeout)
    }

    private func command<Response: Decodable, Payload: Encodable>(
        _ name: String,
        payload: Payload,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let request = try EngramServiceRequestEnvelope(
            command: name,
            payload: JSONEncoder().encode(payload)
        )
        let response = try await transport.send(request, timeout: timeout ?? defaultTimeout)
        guard response.requestId == request.requestId else {
            throw EngramServiceError.invalidRequest(
                message: "Response request id \(response.requestId) did not match \(request.requestId)"
            )
        }

        switch response {
        case .success(_, let result, _):
            // `databaseGeneration` (3rd element) is intentionally ignored here:
            // it exists for the MCP read-consistency path (EngramMCP), not the
            // app, which polls status separately and has no generation gate.
            return try JSONDecoder().decode(Response.self, from: result)
        case .failure(_, let error):
            throw error.asError()
        }
    }
}

private struct EmptyServicePayload: Encodable {}
private struct EmptyServiceResult: Decodable {}
