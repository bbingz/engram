import Foundation

extension EngramServiceCommandHandler {
    func webMetadataResponse(
        _ request: EngramServiceRequestEnvelope,
        deadline: ContinuousClock.Instant
    ) async -> EngramServiceResponseEnvelope {
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
                    allowedKeys: ["query", "source", "sources", "machineId", "sourceInstanceId",
                                  "projectKey", "projectKeys", "sessionId", "agents", "since", "until",
                                  "tools", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.sessions(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webFacets":
                let input = try Self.webMetadataInput(EngramServiceWebFacetsRequest.self, from: request,
                    allowedKeys: ["kind", "query", "agents", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.facets(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webStats":
                let input = try Self.webMetadataInput(EngramServiceWebStatsRequest.self, from: request,
                    allowedKeys: ["groupBy", "since", "until", "excludeNoise", "agents", "limit",
                                  "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.stats(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webSettings":
                let input = try Self.webMetadataInput(EngramServiceWebSettingsRequest.self, from: request,
                    allowedKeys: ["limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.settings(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webSearchStatus":
                let input = try Self.webMetadataInput(EngramServiceWebSearchStatusRequest.self, from: request,
                    allowedKeys: ["source", "sources", "machineId", "sourceInstanceId", "projectKey",
                                  "projectKeys", "sessionId", "agents", "since", "until", "tools"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.searchStatus(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webUsage":
                let input = try Self.webMetadataInput(EngramServiceWebUsageRequest.self, from: request, allowedKeys: [])
                let value = try await webMetadataProducer.usage(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webToolAnalytics":
                let input = try Self.webMetadataInput(EngramServiceWebToolAnalyticsRequest.self, from: request,
                    allowedKeys: ["project", "since", "until", "agents", "groupBy", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.toolAnalytics(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webFileActivity":
                let input = try Self.webMetadataInput(EngramServiceWebFileActivityRequest.self, from: request,
                    allowedKeys: ["project", "since", "until", "agents", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.fileActivity(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webRepos":
                let input = try Self.webMetadataInput(EngramServiceWebReposRequest.self, from: request,
                    allowedKeys: ["limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.repos(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webProjectCwds":
                let input = try Self.webMetadataInput(EngramServiceWebProjectCwdsRequest.self, from: request,
                    allowedKeys: ["projectKey", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.projectCwds(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webAiAudit":
                let input = try Self.webMetadataInput(EngramServiceWebAiAuditRequest.self, from: request,
                    allowedKeys: ["caller", "model", "sessionId", "from", "to", "hasError",
                                  "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.aiAudit(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webAiAuditDetail":
                let input = try Self.webMetadataInput(EngramServiceWebAiAuditDetailRequest.self, from: request,
                    allowedKeys: ["id"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.aiAuditDetail(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webAiStats":
                let input = try Self.webMetadataInput(EngramServiceWebAiStatsRequest.self, from: request,
                    allowedKeys: ["from", "to"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.aiStats(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webInsightDetail":
                let input = try Self.webMetadataInput(EngramServiceWebInsightDetailRequest.self, from: request,
                    allowedKeys: ["id", "offset", "limit", "revision"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.insightDetail(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webCosts":
                let input = try Self.webMetadataInput(EngramServiceWebCostsRequest.self, from: request,
                    allowedKeys: ["source", "sources", "machineId", "sourceInstanceId", "projectKey",
                                  "projectKeys", "sessionId", "agents", "since", "until", "tools",
                                  "groupBy", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.costs(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webCostSessions":
                let input = try Self.webMetadataInput(EngramServiceWebCostSessionsRequest.self, from: request,
                    allowedKeys: ["source", "sources", "machineId", "sourceInstanceId", "projectKey",
                                  "projectKeys", "sessionId", "agents", "since", "until", "tools", "limit"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.costSessions(input, requestId: request.requestId, deadline: deadline)
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            case "webChildren":
                let input = try Self.webMetadataInput(EngramServiceWebChildrenRequest.self, from: request,
                    allowedKeys: ["sessionId", "limit", "snapshotId", "cursor"])
                try Self.webMetadataCheckpoint(deadline)
                let value = try await webMetadataProducer.children(input, requestId: request.requestId, deadline: deadline)
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
                            transcriptGeneration: admittedGeneration, currentAttempt: detail.currentAttempt,
                            summary: detail.summary))
                }
                return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
            default:
                throw ServiceWebMetadataError.unavailable
            }
        } catch {
            return webMetadataFailure(request, error: error, deadline: deadline)
        }
    }

    func webSearchResponse(
        _ request: EngramServiceRequestEnvelope,
        deadline: ContinuousClock.Instant
    ) async -> EngramServiceResponseEnvelope {
        do {
            try Self.webMetadataCheckpoint(deadline)
            let input = try Self.webMetadataInput(EngramServiceWebSearchRequest.self, from: request,
                allowedKeys: ["query", "source", "sources", "machineId", "sourceInstanceId",
                              "projectKey", "projectKeys", "sessionId", "agents", "since", "until",
                              "tools", "mode", "limit"])
            try Self.webMetadataCheckpoint(deadline)
            let scope = try await webMetadataProducer.searchScope(
                input, requestId: request.requestId, deadline: deadline)
            try Self.webMetadataCheckpoint(deadline)
            let ranked = try await ServiceWebMetadataClock.live.run(until: deadline) {
                try await self.readProvider.search(
                    EngramServiceSearchRequest(
                        query: input.query, mode: input.mode.rawValue, limit: input.limit
                    ),
                    scope: scope
                )
            }
            try Self.webMetadataCheckpoint(deadline)
            let value = try await webMetadataProducer.admitSearch(
                input, ranked: ranked, requestId: request.requestId, deadline: deadline)
            return try Self.webMetadataSuccess(value, requestId: request.requestId, deadline: deadline)
        } catch {
            return webMetadataFailure(request, error: error, deadline: deadline)
        }
    }

    private func webMetadataFailure(
        _ request: EngramServiceRequestEnvelope,
        error: Error,
        deadline: ContinuousClock.Instant
    ) -> EngramServiceResponseEnvelope {
        func failure(_ name: String, _ message: String, retryPolicy: String) -> EngramServiceResponseEnvelope {
            .failure(requestId: request.requestId, error: .init(name: name, message: message, retryPolicy: retryPolicy))
        }
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
            case .notFound:
                return failure("NotFound", "Web metadata resource was not found.", retryPolicy: "never")
            case .notImplemented, .unavailable, .responseTooLarge:
                break
            }
        }
        // Never expose provider, database, decoder or encoding diagnostics.
        return failure("ServiceUnavailable", "Web metadata service is unavailable.", retryPolicy: "safe")
    }

    private static func webMetadataInput<Value: Decodable>(
        _ type: Value.Type,
        from request: EngramServiceRequestEnvelope,
        allowedKeys: Set<String>
    ) throws -> Value {
        guard let payload = request.payload else {
            throw ServiceWebMetadataError.invalidRequest
        }
        let keys: Set<String>
        do {
            let object = try JSONSerialization.jsonObject(with: payload)
            guard let dictionary = object as? NSDictionary else {
                throw ServiceWebMetadataError.invalidRequest
            }
            var parsed: Set<String> = []
            parsed.reserveCapacity(dictionary.count)
            for key in dictionary.allKeys {
                guard let name = key as? String, parsed.insert(name).inserted else {
                    throw ServiceWebMetadataError.invalidRequest
                }
            }
            keys = parsed
        } catch {
            throw ServiceWebMetadataError.invalidRequest
        }
        // Codable ignores unknown keys; reject them here so the producer never runs.
        guard keys.subtracting(allowedKeys).isEmpty else {
            throw ServiceWebMetadataError.invalidRequest
        }
        do {
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
