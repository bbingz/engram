import Foundation
import Observation

@Observable
final class EngramServiceClient: EngramServiceClientProtocol, @unchecked Sendable {
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

    func skills() async throws -> [EngramServiceSkillInfo] {
        try await command("skills")
    }

    func memoryFiles() async throws -> [EngramServiceMemoryFile] {
        try await command("memoryFiles")
    }

    func hooks() async throws -> [EngramServiceHookInfo] {
        try await command("hooks")
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

    func embeddingStatus() async throws -> EngramServiceEmbeddingStatusResponse {
        try await command("embeddingStatus")
    }

    func generateSummary(_ request: EngramServiceGenerateSummaryRequest) async throws -> EngramServiceGenerateSummaryResponse {
        try await command("generateSummary", payload: request)
    }

    func saveInsight(_ request: EngramServiceSaveInsightRequest) async throws -> EngramServiceJSONValue {
        try await command("saveInsight", payload: request)
    }

    func manageProjectAlias(_ request: EngramServiceProjectAliasRequest) async throws -> EngramServiceJSONValue {
        try await command("manageProjectAlias", payload: request)
    }

    func resumeCommand(sessionId: String) async throws -> EngramServiceResumeCommandResponse {
        try await command("resumeCommand", payload: EngramServiceResumeCommandRequest(sessionId: sessionId))
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

    func triggerSync(_ request: EngramServiceTriggerSyncRequest) async throws -> EngramServiceTriggerSyncResponse {
        try await command("triggerSync", payload: request)
    }

    func regenerateAllTitles() async throws -> EngramServiceRegenerateTitlesResponse {
        try await command("regenerateAllTitles")
    }

    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        try await command("projectMigrations", payload: request)
    }

    func projectCwds(project: String) async throws -> EngramServiceProjectCwdsResponse {
        try await command("projectCwds", payload: EngramServiceProjectCwdsRequest(project: project))
    }

    func projectMove(_ request: EngramServiceProjectMoveRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectMove", payload: request)
    }

    func projectArchive(_ request: EngramServiceProjectArchiveRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectArchive", payload: request)
    }

    func projectUndo(_ request: EngramServiceProjectUndoRequest) async throws -> EngramServiceProjectMoveResult {
        try await command("projectUndo", payload: request)
    }

    func projectMoveBatch(_ request: EngramServiceProjectMoveBatchRequest) async throws -> EngramServiceJSONValue {
        try await command("projectMoveBatch", payload: request)
    }

    func linkSessions(_ request: EngramServiceLinkSessionsRequest) async throws -> EngramServiceLinkSessionsResponse {
        try await command("linkSessions", payload: request)
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

    func renameSession(sessionId: String, name: String?) async throws {
        let _: EmptyServiceResult = try await command(
            "renameSession",
            payload: EngramServiceRenameSessionRequest(sessionId: sessionId, name: name)
        )
    }

    func hideEmptySessions() async throws -> EngramServiceHideEmptySessionsResponse {
        try await command("hideEmptySessions")
    }

    func exportSession(_ request: EngramServiceExportSessionRequest) async throws -> EngramServiceExportSessionResponse {
        try await command("exportSession", payload: request)
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        transport.events()
    }

    func close() async {
        await transport.close()
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
            return try JSONDecoder().decode(Response.self, from: result)
        case .failure(_, let error):
            throw error.asError()
        }
    }
}

private struct EmptyServicePayload: Encodable {}
private struct EmptyServiceResult: Decodable {}
