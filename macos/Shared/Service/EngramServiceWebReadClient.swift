import Foundation

enum EngramServiceWebReadClientError: String, Error, Equatable, LocalizedError, Sendable {
    case stale
    case unsupported
    case unavailable
    case notFound
    case malformed

    var errorDescription: String? {
        switch self {
        case .stale: return "Web transcript continuation is stale."
        case .unsupported: return "Web transcript reads are unsupported."
        case .unavailable: return "Web transcript service is unavailable."
        case .notFound: return "Web metadata resource was not found."
        case .malformed: return "Web transcript response is invalid."
        }
    }
}

/// Dedicated, typed read surface. The cursor remains opaque to this client;
/// cross-page reconstruction and payload SHA verification belong to its caller.
struct EngramServiceWebReadClient: Sendable {
    static let maximumTotalTimeout: TimeInterval = 2
    static let maximumSearchTimeout: TimeInterval = 8
    static let allowedCommands: Set<String> = [
        "webMessages", "webOverview", "webSessions", "webSessionDetail", "webFacets", "webStats",
        "webSettings", "webSearch", "webSearchStatus", "webCosts", "webCostSessions",
        "webSourceSettings", "webChildren", "webTimeline", "webToolAnalytics",
        "webFileActivity", "webRepos", "webUsage",
        "webAiAudit", "webAiAuditDetail", "webAiStats", "webInsightDetail",
        "webAiSettings", "webProjectCwds",
    ]

    private let socketPath: String
    private let totalTimeout: TimeInterval
    private let searchTimeout: TimeInterval

    init(
        socketPath: String,
        totalTimeout: TimeInterval = EngramServiceWebReadClient.maximumTotalTimeout,
        searchTimeout: TimeInterval = EngramServiceWebReadClient.maximumSearchTimeout
    ) throws {
        guard totalTimeout.isFinite, totalTimeout > 0, totalTimeout <= Self.maximumTotalTimeout else {
            throw EngramServiceWebReadClientError.malformed
        }
        guard searchTimeout.isFinite, searchTimeout > 0, searchTimeout <= Self.maximumSearchTimeout else {
            throw EngramServiceWebReadClientError.malformed
        }
        self.socketPath = socketPath
        self.totalTimeout = totalTimeout
        self.searchTimeout = searchTimeout
    }

    /// A pure preflight policy, not a command-forwarding entry point.
    static func validateCommand(_ command: String) throws {
        guard allowedCommands.contains(command) else { throw EngramServiceWebReadClientError.unsupported }
    }

    func messages(_ request: EngramServiceWebMessagesRequest) async throws -> EngramServiceWebMessagesResponse {
        do {
            try Self.validateCommand("webMessages")
            try Task.checkCancellation()
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(
                requestId: requestID, command: "webMessages", payload: try JSONEncoder().encode(request), capabilityToken: nil
            )
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: totalTimeout)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Kernel failures, including rejected frame prefixes, share one
                // safe category. Never expose transport or filesystem detail.
                throw EngramServiceWebReadClientError.unavailable
            }
            try Task.checkCancellation()
            let frame = try JSONDecoder().decode(ResponseFrame.self, from: bytes)
            guard frame.kind == "response", Data(frame.requestID.utf8) == Data(requestID.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
            if let name = frame.failureName {
                switch name {
                case "StaleCursor", "staleCursor": throw EngramServiceWebReadClientError.stale
                case "UnsupportedCommand", "unsupportedCommand": throw EngramServiceWebReadClientError.unsupported
                case "ServiceUnavailable", "serviceUnavailable": throw EngramServiceWebReadClientError.unavailable
                default: throw EngramServiceWebReadClientError.malformed
                }
            }
            guard let payload = frame.result else { throw EngramServiceWebReadClientError.malformed }
            let response = try JSONDecoder().decode(EngramServiceWebMessagesResponse.self, from: payload)
            try Self.validate(response, for: request)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? EngramServiceWebReadClientError { throw safe }
            throw EngramServiceWebReadClientError.malformed
        }
    }

    func overview(_ request: EngramServiceWebOverviewRequest) async throws -> EngramServiceWebOverviewResponse {
        let response: EngramServiceWebOverviewResponse = try await metadataResponse(.overview, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.streams.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        for (previous, current) in zip(response.streams, response.streams.dropFirst()) {
            guard previous.machineId < current.machineId
                    || (previous.machineId == current.machineId && previous.sourceInstanceId < current.sourceInstanceId) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func sessions(_ request: EngramServiceWebSessionsRequest) async throws -> EngramServiceWebSessionsResponse {
        let response: EngramServiceWebSessionsResponse = try await metadataResponse(.sessions, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        if let totalCount = response.totalCount {
            guard (try? EngramServiceWebMetadataValidation.count(totalCount)) != nil,
                  totalCount >= Int64(response.items.count) else {
                throw EngramServiceWebReadClientError.malformed
            }
            if request.cursor == nil, response.nextCursor == nil,
               totalCount != Int64(response.items.count) {
                throw EngramServiceWebReadClientError.malformed
            }
            if response.nextCursor != nil, totalCount <= Int64(response.items.count) {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        for item in response.items {
            let sources = request.resolvedSources
            let projects = request.resolvedProjectKeys
            let sessionOK = request.sessionId.map { id in
                id.utf8.elementsEqual(item.sessionId.utf8)
                    || (item.nativeId.map { $0.utf8.elementsEqual(id.utf8) } ?? false)
            } ?? true
            let agentOK: Bool
            switch request.agents {
            case .hide: agentOK = item.isAgent != true
            case .only: agentOK = item.isAgent == true
            case .all: agentOK = true
            }
            let dateOK: Bool
            if request.since != nil || request.until != nil {
                guard let started = item.startedAt,
                      let day = try? EngramServiceWebMetadataValidation.localCalendarDate(epoch: started) else {
                    throw EngramServiceWebReadClientError.malformed
                }
                dateOK = !(request.since.map { day.utf8.lexicographicallyPrecedes($0.utf8) } ?? false)
                    && !(request.until.map { $0.utf8.lexicographicallyPrecedes(day.utf8) } ?? false)
            } else {
                dateOK = true
            }
            guard sources.map({ $0.contains(item.source) }) ?? true,
                  request.machineId.map({ $0 == item.captureIdentity?.machineId }) ?? true,
                  request.sourceInstanceId.map({ $0 == item.captureIdentity?.sourceInstanceId }) ?? true,
                  projects.map({ keys in item.projectKey.map(keys.contains) ?? false }) ?? true,
                  sessionOK, agentOK, dateOK else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            // Valid timestamps are nonnegative; unknown dates sort last. IDs
            // break ties by exact UTF-8 bytes, never Swift canonical equality.
            let previousTime = previous.startedAt ?? -1
            let currentTime = current.startedAt ?? -1
            guard previousTime > currentTime || (previousTime == currentTime
                && previous.sessionId.utf8.lexicographicallyPrecedes(current.sessionId.utf8)) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func sessionDetail(_ request: EngramServiceWebSessionDetailRequest) async throws -> EngramServiceWebSessionDetailResponse {
        let response: EngramServiceWebSessionDetailResponse = try await metadataResponse(.detail, request: request)
        if let detail = response.detail,
           !detail.session.sessionId.utf8.elementsEqual(request.sessionId.utf8) {
            throw EngramServiceWebReadClientError.malformed
        }
        try Task.checkCancellation()
        return response
    }

    func facets(_ request: EngramServiceWebFacetsRequest) async throws -> EngramServiceWebFacetsResponse {
        let response: EngramServiceWebFacetsResponse = try await metadataResponse(.facets, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        for item in response.items {
            if request.kind == .source {
                guard (try? EngramServiceWebMetadataValidation.source(item.key)) != nil else {
                    throw EngramServiceWebReadClientError.malformed
                }
            }
            if let query = request.query,
               !EngramServiceWebMetadataValidation.queryMatches(item.label, query: query),
               !EngramServiceWebMetadataValidation.queryMatches(item.key, query: query) {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            guard previous.key.utf8.lexicographicallyPrecedes(current.key.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func stats(_ request: EngramServiceWebStatsRequest) async throws -> EngramServiceWebStatsResponse {
        let response: EngramServiceWebStatsResponse = try await metadataResponse(.stats, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.groupBy == request.groupBy else { throw EngramServiceWebReadClientError.malformed }
        for item in response.items {
            guard (try? EngramServiceWebMetadataValidation.statsKey(item.key, groupBy: request.groupBy)) != nil else {
                throw EngramServiceWebReadClientError.malformed
            }
            if request.groupBy == .day,
               !item.key.utf8.elementsEqual(EngramServiceWebMetadataValidation.unknownDateKey.utf8) {
                if let since = request.since, item.key.utf8.lexicographicallyPrecedes(since.utf8) {
                    throw EngramServiceWebReadClientError.malformed
                }
                if let until = request.until, until.utf8.lexicographicallyPrecedes(item.key.utf8) {
                    throw EngramServiceWebReadClientError.malformed
                }
            }
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            guard previous.key.utf8.lexicographicallyPrecedes(current.key.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func settings(_ request: EngramServiceWebSettingsRequest) async throws -> EngramServiceWebSettingsResponse {
        let response: EngramServiceWebSettingsResponse = try await metadataResponse(.settings, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.aliases.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.nodeName.availability == .unavailable,
              response.peers.availability == .unavailable,
              response.port.availability == .unavailable else {
            throw EngramServiceWebReadClientError.malformed
        }
        for (previous, current) in zip(response.sources, response.sources.dropFirst()) {
            guard previous.key.utf8.lexicographicallyPrecedes(current.key.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        for (previous, current) in zip(response.aliases, response.aliases.dropFirst()) {
            let before = previous.canonical.utf8.lexicographicallyPrecedes(current.canonical.utf8)
                || (previous.canonical.utf8.elementsEqual(current.canonical.utf8)
                    && previous.alias.utf8.lexicographicallyPrecedes(current.alias.utf8))
            guard before else { throw EngramServiceWebReadClientError.malformed }
        }
        try Task.checkCancellation()
        return response
    }

    func searchStatus(_ request: EngramServiceWebSearchStatusRequest) async throws -> EngramServiceWebSearchStatusResponse {
        let response: EngramServiceWebSearchStatusResponse = try await metadataResponse(.searchStatus, request: request)
        if let eligible = response.eligibleSessionCount, let embedded = response.embeddedSessionCount {
            let expected = eligible == 0 ? 0 : min(100, Int((Double(embedded) / Double(eligible) * 100).rounded()))
            guard response.progressPercent == expected else {
                throw EngramServiceWebReadClientError.malformed
            }
        } else if response.progressPercent != nil {
            throw EngramServiceWebReadClientError.malformed
        }
        try Task.checkCancellation()
        return response
    }

    func search(_ request: EngramServiceWebSearchRequest) async throws -> EngramServiceWebSearchResponse {
        let response: EngramServiceWebSearchResponse = try await typedResponse(
            "webSearch", request: request, timeout: searchTimeout
        )
        guard response.query.utf8.elementsEqual(request.query.utf8),
              response.items.count <= request.limit,
              Set(response.items.map { Data($0.session.sessionId.utf8) }).count == response.items.count else {
            throw EngramServiceWebReadClientError.malformed
        }
        for hit in response.items {
            guard hit.matchType == "keyword" || hit.matchType == "semantic" else {
                throw EngramServiceWebReadClientError.malformed
            }
            try Self.validateSessionFilters(hit.session, request: request)
        }
        guard response.insightResults.count <= 5,
              Set(response.insightResults.map { Data($0.id.utf8) }).count == response.insightResults.count else {
            throw EngramServiceWebReadClientError.malformed
        }
        for insight in response.insightResults {
            guard insight.matchType == "keyword" || insight.matchType == "semantic",
                  insight.content.unicodeScalars.count <= 600 else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func insightDetail(_ request: EngramServiceWebInsightDetailRequest) async throws -> EngramServiceWebInsightDetailResponse {
        let response: EngramServiceWebInsightDetailResponse = try await metadataResponse(.insightDetail, request: request)
        guard response.id.utf8.elementsEqual(request.id.utf8),
              response.offset == request.offset,
              response.content.unicodeScalars.count <= request.limit else {
            throw EngramServiceWebReadClientError.malformed
        }
        if let revision = request.revision, revision != response.revision {
            throw EngramServiceWebReadClientError.malformed
        }
        try Task.checkCancellation()
        return response
    }

    func usage() async throws -> EngramServiceWebUsageResponse {
        try await metadataResponse(.usage, request: EngramServiceWebUsageRequest())
    }

    func toolAnalytics(_ request: EngramServiceWebToolAnalyticsRequest) async throws -> EngramServiceWebToolAnalyticsResponse {
        let response: EngramServiceWebToolAnalyticsResponse = try await metadataResponse(.toolAnalytics, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.groupBy == request.groupBy else { throw EngramServiceWebReadClientError.malformed }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            guard previous.callCount > current.callCount || (previous.callCount == current.callCount &&
                previous.key.utf8.lexicographicallyPrecedes(current.key.utf8)) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        return response
    }

    func fileActivity(_ request: EngramServiceWebFileActivityRequest) async throws -> EngramServiceWebFileActivityResponse {
        let response: EngramServiceWebFileActivityResponse = try await metadataResponse(.fileActivity, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let previousOperations = previous.readCount + previous.editCount + previous.writeCount
            let currentOperations = current.readCount + current.editCount + current.writeCount
            guard previousOperations > currentOperations || (previousOperations == currentOperations &&
                previous.key.utf8.lexicographicallyPrecedes(current.key.utf8)) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        return response
    }

    func repos(_ request: EngramServiceWebReposRequest) async throws -> EngramServiceWebReposResponse {
        let response: EngramServiceWebReposResponse = try await metadataResponse(.repos, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.scope.utf8.elementsEqual("serverFilesystem".utf8) else {
            throw EngramServiceWebReadClientError.malformed
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let previousTime = previous.lastCommitAt ?? -1
            let currentTime = current.lastCommitAt ?? -1
            guard previousTime > currentTime || previousTime == currentTime else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        return response
    }

    func projectCwds(_ request: EngramServiceWebProjectCwdsRequest) async throws -> EngramServiceWebProjectCwdsResponse {
        let response: EngramServiceWebProjectCwdsResponse = try await metadataResponse(.projectCwds, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.scope.utf8.elementsEqual(EngramServiceWebProjectValidation.capturedScope.utf8),
              response.projectKey.utf8.elementsEqual(request.projectKey.utf8),
              response.totalCount >= response.items.count else {
            throw EngramServiceWebReadClientError.malformed
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            guard previous.key.utf8.lexicographicallyPrecedes(current.key.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        return response
    }

    func aiAudit(_ request: EngramServiceWebAiAuditRequest) async throws -> EngramServiceWebAiAuditResponse {
        let response: EngramServiceWebAiAuditResponse = try await metadataResponse(.aiAudit, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.total >= response.items.count else { throw EngramServiceWebReadClientError.malformed }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let previousID = Int64(previous.id) ?? 0
            let currentID = Int64(current.id) ?? 0
            guard previous.at > current.at || (previous.at == current.at && previousID > currentID) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        return response
    }

    func aiAuditDetail(_ request: EngramServiceWebAiAuditDetailRequest) async throws -> EngramServiceWebAiAuditDetailResponse {
        let response: EngramServiceWebAiAuditDetailResponse = try await metadataResponse(.aiAuditDetail, request: request)
        guard response.item.id.utf8.elementsEqual(request.id.utf8) else {
            throw EngramServiceWebReadClientError.malformed
        }
        return response
    }

    func aiStats(_ request: EngramServiceWebAiStatsRequest) async throws -> EngramServiceWebAiStatsResponse {
        try await metadataResponse(.aiStats, request: request)
    }

    func costs(_ request: EngramServiceWebCostsRequest) async throws -> EngramServiceWebCostsResponse {
        let response: EngramServiceWebCostsResponse = try await metadataResponse(.costs, request: request)
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        guard response.groupBy == request.groupBy else { throw EngramServiceWebReadClientError.malformed }
        for item in response.items {
            guard (try? EngramServiceWebMetadataValidation.costsKey(item.key, groupBy: request.groupBy)) != nil else {
                throw EngramServiceWebReadClientError.malformed
            }
            if request.groupBy == .day,
               !item.key.utf8.elementsEqual(EngramServiceWebMetadataValidation.unknownDateKey.utf8) {
                if let since = request.since, item.key.utf8.lexicographicallyPrecedes(since.utf8) {
                    throw EngramServiceWebReadClientError.malformed
                }
                if let until = request.until, until.utf8.lexicographicallyPrecedes(item.key.utf8) {
                    throw EngramServiceWebReadClientError.malformed
                }
            }
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let descendingCost = previous.costUsd > current.costUsd
                || (previous.costUsd == current.costUsd
                    && previous.key.utf8.lexicographicallyPrecedes(current.key.utf8))
            guard descendingCost else { throw EngramServiceWebReadClientError.malformed }
        }
        try Task.checkCancellation()
        return response
    }

    func costSessions(_ request: EngramServiceWebCostSessionsRequest) async throws -> EngramServiceWebCostSessionsResponse {
        let response: EngramServiceWebCostSessionsResponse = try await metadataResponse(.costSessions, request: request)
        guard response.items.count <= request.limit,
              Set(response.items.map { Data($0.session.sessionId.utf8) }).count == response.items.count else {
            throw EngramServiceWebReadClientError.malformed
        }
        for item in response.items {
            try Self.validateSessionFilters(item.session, request: request)
        }
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let descendingCost = previous.costUsd > current.costUsd
                || (previous.costUsd == current.costUsd
                    && previous.session.sessionId.utf8.lexicographicallyPrecedes(current.session.sessionId.utf8))
            guard descendingCost else { throw EngramServiceWebReadClientError.malformed }
        }
        try Task.checkCancellation()
        return response
    }

    func children(_ request: EngramServiceWebChildrenRequest) async throws -> EngramServiceWebChildrenResponse {
        let response: EngramServiceWebChildrenResponse = try await metadataResponse(.children, request: request)
        guard Data(response.sessionId.utf8) == Data(request.sessionId.utf8) else {
            throw EngramServiceWebReadClientError.malformed
        }
        try Self.validatePage(snapshot: response.snapshotId, nextCursor: response.nextCursor,
            count: response.items.count, limit: request.limit, requestedSnapshot: request.snapshotId, cursor: request.cursor)
        for (previous, current) in zip(response.items, response.items.dropFirst()) {
            let previousTime = previous.session.startedAt ?? -1
            let currentTime = current.session.startedAt ?? -1
            guard previousTime > currentTime || (previousTime == currentTime
                && previous.session.sessionId.utf8.lexicographicallyPrecedes(current.session.sessionId.utf8)) else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func timeline(_ request: EngramServiceWebTimelineRequest) async throws -> EngramServiceWebTimelineResponse {
        let response: EngramServiceWebTimelineResponse = try await typedResponse(
            "webTimeline", request: request, timeout: totalTimeout
        )
        guard Data(response.sessionId.utf8) == Data(request.sessionId.utf8),
              response.generation == request.generation,
              response.entries.count <= request.limit,
              response.totalEntries >= response.entries.count,
              response.nextOffset == nil || response.nextOffset != request.offset else {
            throw EngramServiceWebReadClientError.malformed
        }
        if let next = response.nextOffset {
            guard !response.entries.isEmpty, next <= response.totalEntries else {
                throw EngramServiceWebReadClientError.malformed
            }
        }
        try Task.checkCancellation()
        return response
    }

    func sourceSettings() async throws -> EngramServiceWebSourceSettingsResponse {
        do {
            try Task.checkCancellation()
            try Self.validateCommand("webSourceSettings")
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(
                requestId: requestID, command: "webSourceSettings", payload: nil, capabilityToken: nil
            )
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: totalTimeout)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw EngramServiceWebReadClientError.unavailable
            }
            try Task.checkCancellation()
            guard bytes.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                throw EngramServiceWebReadClientError.malformed
            }
            let frame = try JSONDecoder().decode(ResponseFrame.self, from: bytes)
            guard frame.kind == "response", frame.requestID.utf8.elementsEqual(requestID.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
            if let name = frame.failureName {
                switch name {
                case "StaleCursor", "staleCursor": throw EngramServiceWebReadClientError.stale
                case "UnsupportedCommand", "unsupportedCommand": throw EngramServiceWebReadClientError.unsupported
                case "ServiceUnavailable", "serviceUnavailable": throw EngramServiceWebReadClientError.unavailable
                case "NotFound", "notFound": throw EngramServiceWebReadClientError.notFound
                default: throw EngramServiceWebReadClientError.malformed
                }
            }
            guard let payload = frame.result else { throw EngramServiceWebReadClientError.malformed }
            let response = try JSONDecoder().decode(EngramServiceWebSourceSettingsResponse.self, from: payload)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? EngramServiceWebReadClientError { throw safe }
            throw EngramServiceWebReadClientError.malformed
        }
    }

    func aiSettings() async throws -> EngramServiceWebAiSettingsResponse {
        do {
            try Task.checkCancellation()
            try Self.validateCommand("webAiSettings")
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(
                requestId: requestID, command: "webAiSettings", payload: nil, capabilityToken: nil
            )
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: totalTimeout)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw EngramServiceWebReadClientError.unavailable
            }
            try Task.checkCancellation()
            guard bytes.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                throw EngramServiceWebReadClientError.malformed
            }
            let frame = try JSONDecoder().decode(ResponseFrame.self, from: bytes)
            guard frame.kind == "response", frame.requestID.utf8.elementsEqual(requestID.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
            if let name = frame.failureName {
                switch name {
                case "StaleCursor", "staleCursor": throw EngramServiceWebReadClientError.stale
                case "UnsupportedCommand", "unsupportedCommand": throw EngramServiceWebReadClientError.unsupported
                case "ServiceUnavailable", "serviceUnavailable": throw EngramServiceWebReadClientError.unavailable
                case "NotFound", "notFound": throw EngramServiceWebReadClientError.notFound
                default: throw EngramServiceWebReadClientError.malformed
                }
            }
            guard let payload = frame.result else { throw EngramServiceWebReadClientError.malformed }
            let response = try JSONDecoder().decode(EngramServiceWebAiSettingsResponse.self, from: payload)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? EngramServiceWebReadClientError { throw safe }
            throw EngramServiceWebReadClientError.malformed
        }
    }

    private enum MetadataCommand: String {
        case overview = "webOverview", sessions = "webSessions", detail = "webSessionDetail",
             facets = "webFacets", stats = "webStats", settings = "webSettings",
             searchStatus = "webSearchStatus", costs = "webCosts", costSessions = "webCostSessions",
             children = "webChildren", toolAnalytics = "webToolAnalytics",
             fileActivity = "webFileActivity", repos = "webRepos", projectCwds = "webProjectCwds",
             usage = "webUsage",
             aiAudit = "webAiAudit", aiAuditDetail = "webAiAuditDetail", aiStats = "webAiStats",
             insightDetail = "webInsightDetail"
    }

    /// Only the three typed methods above can choose this private command enum.
    /// No generic caller-supplied command, capability loader or database access.
    private func metadataResponse<Request: Encodable, Response: Decodable>(
        _ command: MetadataCommand, request: Request
    ) async throws -> Response {
        try await typedResponse(command.rawValue, request: request, timeout: totalTimeout)
    }

    /// Only typed methods above choose the command string. Search uses the
    /// dedicated 8s budget; every other metadata command stays on 2s.
    private func typedResponse<Request: Encodable, Response: Decodable>(
        _ command: String, request: Request, timeout: TimeInterval
    ) async throws -> Response {
        do {
            try Task.checkCancellation()
            try Self.validateCommand(command)
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(requestId: requestID, command: command,
                payload: try JSONEncoder().encode(request), capabilityToken: nil)
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: timeout)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw EngramServiceWebReadClientError.unavailable
            }
            try Task.checkCancellation()
            // Count the entire encoded envelope, including Data/base64 and
            // legal outer metadata. Legacy message reads retain their own cap.
            guard bytes.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                throw EngramServiceWebReadClientError.malformed
            }
            let frame = try JSONDecoder().decode(ResponseFrame.self, from: bytes)
            guard frame.kind == "response", frame.requestID.utf8.elementsEqual(requestID.utf8) else {
                throw EngramServiceWebReadClientError.malformed
            }
            if let name = frame.failureName {
                switch name {
                case "StaleCursor", "staleCursor": throw EngramServiceWebReadClientError.stale
                case "UnsupportedCommand", "unsupportedCommand": throw EngramServiceWebReadClientError.unsupported
                case "ServiceUnavailable", "serviceUnavailable": throw EngramServiceWebReadClientError.unavailable
                case "NotFound", "notFound": throw EngramServiceWebReadClientError.notFound
                default: throw EngramServiceWebReadClientError.malformed
                }
            }
            guard let payload = frame.result else { throw EngramServiceWebReadClientError.malformed }
            let response = try JSONDecoder().decode(Response.self, from: payload)
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let safe = error as? EngramServiceWebReadClientError { throw safe }
            throw EngramServiceWebReadClientError.malformed
        }
    }

    private static func validateSessionFilters(
        _ item: EngramServiceWebSessionSummary, request: EngramServiceWebSearchRequest
    ) throws {
        try validateSessionFilters(item, fields: SessionFilterFields(request))
    }

    private static func validateSessionFilters(
        _ item: EngramServiceWebSessionSummary, request: EngramServiceWebCostSessionsRequest
    ) throws {
        try validateSessionFilters(item, fields: SessionFilterFields(request))
    }

    private struct SessionFilterFields {
        let resolvedSources: [String]?
        let resolvedProjectKeys: [String]?
        let machineId: String?
        let sourceInstanceId: String?
        let sessionId: String?
        let agents: EngramServiceWebAgentFilter
        let since: String?
        let until: String?

        init(_ request: EngramServiceWebSearchRequest) {
            resolvedSources = request.resolvedSources
            resolvedProjectKeys = request.resolvedProjectKeys
            machineId = request.machineId
            sourceInstanceId = request.sourceInstanceId
            sessionId = request.sessionId
            agents = request.agents
            since = request.since
            until = request.until
        }

        init(_ request: EngramServiceWebCostSessionsRequest) {
            resolvedSources = request.resolvedSources
            resolvedProjectKeys = request.resolvedProjectKeys
            machineId = request.machineId
            sourceInstanceId = request.sourceInstanceId
            sessionId = request.sessionId
            agents = request.agents
            since = request.since
            until = request.until
        }
    }

    private static func validateSessionFilters(
        _ item: EngramServiceWebSessionSummary, fields: SessionFilterFields
    ) throws {
        let sources = fields.resolvedSources
        let projects = fields.resolvedProjectKeys
        let sessionOK = fields.sessionId.map { id in
            id.utf8.elementsEqual(item.sessionId.utf8)
                || (item.nativeId.map { $0.utf8.elementsEqual(id.utf8) } ?? false)
        } ?? true
        let agentOK: Bool
        switch fields.agents {
        case .hide: agentOK = item.isAgent != true
        case .only: agentOK = item.isAgent == true
        case .all: agentOK = true
        }
        let dateOK: Bool
        if fields.since != nil || fields.until != nil {
            guard let started = item.startedAt,
                  let day = try? EngramServiceWebMetadataValidation.localCalendarDate(epoch: started) else {
                throw EngramServiceWebReadClientError.malformed
            }
            dateOK = !(fields.since.map { day.utf8.lexicographicallyPrecedes($0.utf8) } ?? false)
                && !(fields.until.map { $0.utf8.lexicographicallyPrecedes(day.utf8) } ?? false)
        } else {
            dateOK = true
        }
        guard sources.map({ $0.contains(item.source) }) ?? true,
              fields.machineId.map({ $0 == item.captureIdentity?.machineId }) ?? true,
              fields.sourceInstanceId.map({ $0 == item.captureIdentity?.sourceInstanceId }) ?? true,
              projects.map({ keys in item.projectKey.map(keys.contains) ?? false }) ?? true,
              sessionOK, agentOK, dateOK else {
            throw EngramServiceWebReadClientError.malformed
        }
    }

    private static func validatePage(
        snapshot: String, nextCursor: String?, count: Int, limit: Int, requestedSnapshot: String?, cursor: String?
    ) throws {
        guard requestedSnapshot.map({ $0 == snapshot }) ?? true,
              count <= limit, nextCursor == nil || nextCursor != cursor else {
            throw EngramServiceWebReadClientError.malformed
        }
    }

    private static func validate(_ response: EngramServiceWebMessagesResponse, for request: EngramServiceWebMessagesRequest) throws {
        guard Data(response.sessionId.utf8) == Data(request.sessionId.utf8),
              response.generation == request.generation,
              response.roles == request.roles,
              response.projection == EngramServiceWebReadLimits.projection,
              response.redactionRevision == EngramServiceWebReadLimits.redactionRevision,
              response.fragments.count <= request.maxFragments,
              response.nextCursor == nil || response.nextCursor != request.cursor else {
            throw EngramServiceWebReadClientError.malformed
        }
        let includesAllRoles = request.roles.count == EngramServiceWebMessageRole.allCases.count
        var previous: EngramServiceWebMessageFragment?
        for fragment in response.fragments {
            if let previous {
                if fragment.messageOrdinal == previous.messageOrdinal {
                    guard !previous.isLastFragment,
                          fragment.role == previous.role,
                          fragment.payloadSHA256 == previous.payloadSHA256,
                          fragment.utf8Offset == previous.utf8Offset + previous.payloadFragment.utf8.count else {
                        throw EngramServiceWebReadClientError.malformed
                    }
                } else {
                    // Only role filters may skip source ordinals; every page
                    // must preserve order and finish each message before the next.
                    guard fragment.messageOrdinal > previous.messageOrdinal, previous.isLastFragment,
                          !includesAllRoles || fragment.messageOrdinal == previous.messageOrdinal + 1,
                          fragment.utf8Offset == 0 else {
                        throw EngramServiceWebReadClientError.malformed
                    }
                }
            } else if request.cursor == nil,
                      fragment.utf8Offset != 0 || (includesAllRoles && fragment.messageOrdinal != 0) {
                throw EngramServiceWebReadClientError.malformed
            }
            previous = fragment
        }
    }

    /// The general envelope decoder intentionally retains legacy behavior and
    /// does not validate kind. This reader also rejects ambiguous success/error
    /// bodies and decodes only the error name, never its free-form diagnostics.
    private struct ResponseFrame: Decodable {
        let requestID: String
        let kind: String
        let result: Data?
        let failureName: String?

        private enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case kind, ok, result, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try container.decode(String.self, forKey: .requestID)
            kind = try container.decode(String.self, forKey: .kind)
            if try container.decode(Bool.self, forKey: .ok) {
                guard !container.contains(.error) else { throw EngramServiceWebReadClientError.malformed }
                result = try container.decode(Data.self, forKey: .result)
                failureName = nil
            } else {
                guard !container.contains(.result) else { throw EngramServiceWebReadClientError.malformed }
                failureName = try container.decode(FailureName.self, forKey: .error).name
                result = nil
            }
        }

        private struct FailureName: Decodable { let name: String }
    }
}
