import Foundation

/// Typed Web alias write surface. Loads the socket-adjacent capability token
/// locally; callers cannot supply it, and HTTP never sees it.
struct EngramServiceWebWriteClient: Sendable {
    static let maximumTotalTimeout: TimeInterval = 2
    static let generationCommandTimeout: TimeInterval = 25
    static let allowedCommands: Set<String> = [
        "webAddProjectAlias", "webRemoveProjectAlias", "webSetSourceEnabled",
        "webLinkSession", "webUnlinkSession", "webConfirmSuggestion", "webDismissSuggestion",
        "webSaveInsight", "webGenerateSummary", "webGenerateTitle", "webRegenerateTitles",
        "webPatchAiSettings",
        "webProjectMigrations", "webProjectMove", "webProjectArchive",
        "webProjectUndo", "webProjectMoveBatch", "webCancelProjectMoveBatch",
    ]

    private let socketPath: String
    private let totalTimeout: TimeInterval

    init(
        socketPath: String,
        totalTimeout: TimeInterval = EngramServiceWebWriteClient.maximumTotalTimeout
    ) throws {
        guard totalTimeout.isFinite, totalTimeout > 0, totalTimeout <= Self.maximumTotalTimeout else {
            throw EngramServiceWebWriteClientError.malformed
        }
        self.socketPath = socketPath
        self.totalTimeout = totalTimeout
    }

    static func validateCommand(_ command: String) throws {
        guard allowedCommands.contains(command) else { throw EngramServiceWebWriteClientError.unsupported }
    }

    func addAlias(_ request: EngramServiceWebAddAliasRequest) async throws -> EngramServiceWebAliasMutationResponse {
        let response: EngramServiceWebAliasMutationResponse = try await typedResponse("webAddProjectAlias", request: request)
        guard response.action == "add",
              response.canonical.utf8.elementsEqual(request.canonical.utf8),
              let published = EngramServiceWebWriteValidation.publishedProjectKey(request.alias),
              response.alias.utf8.elementsEqual(published.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func removeAlias(_ request: EngramServiceWebRemoveAliasRequest) async throws -> EngramServiceWebAliasMutationResponse {
        let response: EngramServiceWebAliasMutationResponse = try await typedResponse("webRemoveProjectAlias", request: request)
        guard response.action == "remove",
              response.alias.utf8.elementsEqual(request.alias.utf8),
              response.canonical.utf8.elementsEqual(request.canonical.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func setSourceEnabled(
        _ request: EngramServiceWebSetSourceEnabledRequest
    ) async throws -> EngramServiceWebSetSourceEnabledResponse {
        let response: EngramServiceWebSetSourceEnabledResponse = try await typedResponse(
            "webSetSourceEnabled", request: request
        )
        guard response.source.utf8.elementsEqual(request.source.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func link(_ request: EngramServiceWebLinkRequest) async throws -> EngramServiceWebRelationshipMutationResponse {
        try await relationship("webLinkSession", action: "link", sessionId: request.sessionId, request: request)
    }

    func unlink(_ request: EngramServiceWebUnlinkRequest) async throws -> EngramServiceWebRelationshipMutationResponse {
        try await relationship("webUnlinkSession", action: "unlink", sessionId: request.sessionId, request: request)
    }

    func confirmSuggestion(
        _ request: EngramServiceWebConfirmSuggestionRequest
    ) async throws -> EngramServiceWebRelationshipMutationResponse {
        try await relationship(
            "webConfirmSuggestion", action: "confirmSuggestion", sessionId: request.sessionId, request: request
        )
    }

    func dismissSuggestion(
        _ request: EngramServiceWebDismissSuggestionRequest
    ) async throws -> EngramServiceWebRelationshipMutationResponse {
        try await relationship(
            "webDismissSuggestion", action: "dismissSuggestion", sessionId: request.sessionId, request: request
        )
    }

    func saveInsight(
        _ request: EngramServiceWebSaveInsightRequest
    ) async throws -> EngramServiceWebSaveInsightResponse {
        let response: EngramServiceWebSaveInsightResponse = try await typedResponse("webSaveInsight", request: request)
        guard !response.id.isEmpty else { throw EngramServiceWebWriteClientError.malformed }
        return response
    }

    func generateSummary(
        _ request: EngramServiceWebGenerateSummaryRequest
    ) async throws -> EngramServiceWebGenerateSummaryResponse {
        let response: EngramServiceWebGenerateSummaryResponse = try await typedResponse(
            "webGenerateSummary", request: request, timeout: Self.generationCommandTimeout
        )
        guard response.sessionId.utf8.elementsEqual(request.sessionId.utf8),
              response.generation.utf8.elementsEqual(request.generation.utf8),
              let summary = response.summary, !summary.isEmpty else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func generateTitle(
        _ request: EngramServiceWebGenerateTitleRequest
    ) async throws -> EngramServiceWebGenerateTitleResponse {
        let response: EngramServiceWebGenerateTitleResponse = try await typedResponse(
            "webGenerateTitle", request: request, timeout: Self.generationCommandTimeout
        )
        guard response.sessionId.utf8.elementsEqual(request.sessionId.utf8),
              response.generation.utf8.elementsEqual(request.generation.utf8),
              let title = response.title, !title.isEmpty else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func regenerateTitles(
        _ request: EngramServiceWebRegenerateTitlesRequest = EngramServiceWebRegenerateTitlesRequest()
    ) async throws -> EngramServiceWebRegenerateTitlesResponse {
        let response: EngramServiceWebRegenerateTitlesResponse = try await typedResponse(
            "webRegenerateTitles", request: request
        )
        guard response.status == "started" || response.status == "running" else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func patchAiSettings(
        _ request: EngramServiceWebPatchAiSettingsRequest
    ) async throws -> EngramServiceWebAiSettingsResponse {
        try await typedResponse("webPatchAiSettings", request: request)
    }

    func projectMigrations(
        _ request: EngramServiceWebProjectMigrationsRequest
    ) async throws -> EngramServiceWebProjectMigrationsResponse {
        let response: EngramServiceWebProjectMigrationsResponse = try await typedResponse(
            "webProjectMigrations", request: request
        )
        guard response.scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func projectMove(
        _ request: EngramServiceWebProjectMoveRequest
    ) async throws -> EngramServiceWebProjectMoveResponse {
        try await typedProjectMove("webProjectMove", request: request, operationId: request.operationId)
    }

    func projectArchive(
        _ request: EngramServiceWebProjectArchiveRequest
    ) async throws -> EngramServiceWebProjectMoveResponse {
        try await typedProjectMove("webProjectArchive", request: request, operationId: request.operationId)
    }

    func projectUndo(
        _ request: EngramServiceWebProjectUndoRequest
    ) async throws -> EngramServiceWebProjectMoveResponse {
        try await typedProjectMove("webProjectUndo", request: request, operationId: request.operationId)
    }

    func projectMoveBatch(
        _ request: EngramServiceWebProjectMoveBatchRequest
    ) async throws -> EngramServiceWebProjectMoveBatchResponse {
        let response: EngramServiceWebProjectMoveBatchResponse = try await typedResponse(
            "webProjectMoveBatch", request: request, timeout: Self.generationCommandTimeout
        )
        guard response.scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8),
              response.operationId.utf8.elementsEqual(request.operationId.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    func cancelProjectMoveBatch(
        _ request: EngramServiceWebCancelProjectMoveBatchRequest
    ) async throws -> EngramServiceWebCancelProjectMoveBatchResponse {
        let response: EngramServiceWebCancelProjectMoveBatchResponse = try await typedResponse(
            "webCancelProjectMoveBatch", request: request
        )
        guard response.operationId.utf8.elementsEqual(request.operationId.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    private func typedProjectMove<Request: Encodable>(
        _ command: String, request: Request, operationId: String
    ) async throws -> EngramServiceWebProjectMoveResponse {
        let response: EngramServiceWebProjectMoveResponse = try await typedResponse(
            command, request: request, timeout: Self.generationCommandTimeout
        )
        guard response.scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8),
              response.operationId.utf8.elementsEqual(operationId.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    private func relationship<Request: Encodable>(
        _ command: String, action: String, sessionId: String, request: Request
    ) async throws -> EngramServiceWebRelationshipMutationResponse {
        let response: EngramServiceWebRelationshipMutationResponse = try await typedResponse(command, request: request)
        guard response.ok,
              response.action.utf8.elementsEqual(action.utf8),
              response.sessionId.utf8.elementsEqual(sessionId.utf8) else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return response
    }

    private func typedResponse<Request: Encodable, Response: Decodable>(
        _ command: String, request: Request, timeout: TimeInterval? = nil
    ) async throws -> Response {
        do {
            try Task.checkCancellation()
            try Self.validateCommand(command)
            let timeout = try commandTimeout(timeout)
            guard let token = ServiceCapabilityToken.load(
                fromPath: ServiceCapabilityToken.path(forSocketPath: socketPath)
            ) else {
                throw EngramServiceWebWriteClientError.unavailable
            }
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(
                requestId: requestID, command: command,
                payload: try JSONEncoder().encode(request), capabilityToken: token
            )
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: timeout)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw EngramServiceWebWriteClientError.unavailable
            }
            try Task.checkCancellation()
            let frame = try JSONDecoder().decode(ResponseFrame.self, from: bytes)
            guard frame.kind == "response", frame.requestID.utf8.elementsEqual(requestID.utf8) else {
                throw EngramServiceWebWriteClientError.malformed
            }
            if let name = frame.failureName {
                if let project = EngramServiceWebProjectFailure.parse(
                    name: name, message: frame.failureMessage ?? name, retryPolicy: frame.retryPolicy
                ) {
                    throw EngramServiceWebWriteClientError.project(project)
                }
                throw Self.failure(name)
            }
            guard let payload = frame.result else { throw EngramServiceWebWriteClientError.malformed }
            let response = try JSONDecoder().decode(Response.self, from: payload)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? EngramServiceWebWriteClientError { throw safe }
            throw EngramServiceWebWriteClientError.malformed
        }
    }

    private func commandTimeout(_ override: TimeInterval?) throws -> TimeInterval {
        guard let override else { return totalTimeout }
        guard override.isFinite, override > 0, override <= Self.generationCommandTimeout else {
            throw EngramServiceWebWriteClientError.malformed
        }
        return override
    }

    private static func failure(_ name: String) -> EngramServiceWebWriteClientError {
        switch name {
        case "InvalidRequest", "invalidRequest": return .invalid
        case "StaleCursor", "staleCursor": return .stale
        case "UnsupportedCommand", "unsupportedCommand": return .unsupported
        case "NotFound", "notFound": return .notFound
        case "ServiceUnavailable", "serviceUnavailable", "WriterBusy", "writerBusy",
             "Unauthorized", "unauthorized":
            return .unavailable
        default: return .malformed
        }
    }

    private struct ResponseFrame: Decodable {
        let requestID: String
        let kind: String
        let result: Data?
        let failureName: String?
        let failureMessage: String?
        let retryPolicy: String?

        private enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case kind, ok, result, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try container.decode(String.self, forKey: .requestID)
            kind = try container.decode(String.self, forKey: .kind)
            if try container.decode(Bool.self, forKey: .ok) {
                guard !container.contains(.error) else { throw EngramServiceWebWriteClientError.malformed }
                result = try container.decode(Data.self, forKey: .result)
                failureName = nil
                failureMessage = nil
                retryPolicy = nil
            } else {
                guard !container.contains(.result) else { throw EngramServiceWebWriteClientError.malformed }
                let failure = try container.decode(FailureBody.self, forKey: .error)
                failureName = failure.name
                failureMessage = failure.message
                retryPolicy = failure.retryPolicy
                result = nil
            }
        }

        private struct FailureBody: Decodable {
            let name: String
            let message: String?
            let retryPolicy: String?

            enum CodingKeys: String, CodingKey {
                case name, message
                case retryPolicy = "retry_policy"
            }
        }
    }
}
