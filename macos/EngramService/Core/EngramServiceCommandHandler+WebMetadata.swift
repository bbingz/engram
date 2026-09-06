import Foundation

extension EngramServiceCommandHandler {
    func webMetadataResponse(
        _ request: EngramServiceRequestEnvelope,
        deadline: ContinuousClock.Instant
    ) async -> EngramServiceResponseEnvelope {
        func failure(_ name: String, _ message: String, retryPolicy: String) -> EngramServiceResponseEnvelope {
            .failure(requestId: request.requestId, error: .init(name: name, message: message, retryPolicy: retryPolicy))
        }
        do {
            try Self.webMetadataCheckpoint(deadline)
            switch request.command {
            case "webOverview":
                let input = try Self.webMetadataInput(EngramServiceWebOverviewRequest.self, from: request,
                    allowedKeys: ["limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                var value = try await webMetadataProducer.overview(input, requestId: request.requestId, deadline: deadline)
                if webTranscriptSnapshotProvider.supportsNormalizedTranscripts {
                    value = .init(snapshotId: value.snapshotId, observedAt: value.observedAt,
                        capabilities: .init(keywordSearch: value.capabilities.keywordSearch, transcriptRead: .available),
                        streams: value.streams, nextCursor: value.nextCursor)
                }
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webSessions":
                let input = try Self.webMetadataInput(EngramServiceWebSessionsRequest.self, from: request,
                    allowedKeys: ["query", "source", "machineId", "sourceInstanceId", "projectKey", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.sessions(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webSessionDetail":
                let input = try Self.webMetadataInput(EngramServiceWebSessionDetailRequest.self, from: request,
                    allowedKeys: ["sessionId"])
                try Self.webMetadataCheckpoint(deadline)
                var value = try await webMetadataProducer.sessionDetail(input, requestId: request.requestId, deadline: deadline)
                if webTranscriptSnapshotProvider.supportsNormalizedTranscripts, let detail = value.detail {
                    var admittedGeneration: String?
                    if let generation = detail.lastReady?.generationId {
                        do {
                            if let snapshot = try await webTranscriptSnapshotProvider.snapshot(
                                sessionID: input.sessionId, generation: generation, deadline: deadline),
                               snapshot.sessionId.utf8.elementsEqual(input.sessionId.utf8),
                               snapshot.sessionId.utf8.elementsEqual(detail.session.sessionId.utf8),
                               snapshot.generation == generation {
                                admittedGeneration = generation
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Metadata may remain useful when transcript authority is unavailable.
                            // Every messages request revalidates independently of this observation.
                        }
                    }
                    value = .init(observedAt: value.observedAt,
                        detail: .init(session: detail.session, lastParsed: detail.lastParsed, lastReady: detail.lastReady,
                            transcriptAvailability: admittedGeneration == nil ? .unavailable : .available,
                            transcriptGeneration: admittedGeneration, currentAttempt: detail.currentAttempt))
                }
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            default:
                throw ServiceWebMetadataError.unavailable
            }
        } catch {
            // Any entered producer has exited before an error response. Caller
            // cancellation and the original handler deadline also fence errors.
            if Task.isCancelled || error is CancellationError {
                return failure("Cancelled", "Web metadata read was cancelled.", retryPolicy: "never")
            }
            if ContinuousClock.now < deadline, let metadataError = error as? ServiceWebMetadataError {
                switch metadataError {
                case .invalidRequest:
                    return failure("InvalidRequest", "Web metadata request is invalid.", retryPolicy: "never")
                case .stale:
                    return failure("StaleCursor", "Web metadata continuation is stale.", retryPolicy: "never")
                case .notImplemented, .unavailable, .responseTooLarge:
                    break
                }
            }
            // Never expose provider, database, decoder or encoding diagnostics.
            return failure("ServiceUnavailable", "Web metadata service is unavailable.", retryPolicy: "safe")
        }
    }

    private static func webMetadataInput<Value: Decodable>(
        _ type: Value.Type,
        from request: EngramServiceRequestEnvelope,
        allowedKeys: Set<String>
    ) throws -> Value {
        do {
            guard let payload = request.payload,
                  let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  Set(object.keys).isSubset(of: allowedKeys) else {
                throw ServiceWebMetadataError.invalidRequest
            }
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw ServiceWebMetadataError.invalidRequest
        }
    }

    private static func webMetadataSuccess<Value: Codable>(
        _ value: Value,
        requestId: String,
        deadline: ContinuousClock.Instant
    ) throws -> EngramServiceResponseEnvelope {
        try webMetadataCheckpoint(deadline)
        let result = try JSONEncoder().encode(value)
        try webMetadataCheckpoint(deadline)
        _ = try JSONDecoder().decode(Value.self, from: result)
        try webMetadataCheckpoint(deadline)
        let envelope = EngramServiceResponseEnvelope.success(requestId: requestId, result: result)
        let frame = try JSONEncoder().encode(envelope)
        try webMetadataCheckpoint(deadline)
        guard frame.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
            throw ServiceWebMetadataError.responseTooLarge
        }
        return envelope
    }

    /// Bound result acceptance without detaching or abandoning producer work.
    private static func webMetadataCheckpoint(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ServiceWebMetadataError.unavailable }
    }
}
