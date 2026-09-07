import Foundation

enum EngramServiceWebReadClientError: String, Error, Equatable, LocalizedError, Sendable {
    case stale
    case unsupported
    case unavailable
    case malformed

    var errorDescription: String? {
        switch self {
        case .stale: return "Web transcript continuation is stale."
        case .unsupported: return "Web transcript reads are unsupported."
        case .unavailable: return "Web transcript service is unavailable."
        case .malformed: return "Web transcript response is invalid."
        }
    }
}

/// Dedicated, typed read surface. The cursor remains opaque to this client;
/// cross-page reconstruction and payload SHA verification belong to its caller.
struct EngramServiceWebReadClient: Sendable {
    static let maximumTotalTimeout: TimeInterval = 2
    static let allowedCommands: Set<String> = ["webMessages", "webOverview", "webSessions", "webSessionDetail"]

    private let socketPath: String
    private let totalTimeout: TimeInterval

    init(socketPath: String, totalTimeout: TimeInterval = EngramServiceWebReadClient.maximumTotalTimeout) throws {
        guard totalTimeout.isFinite, totalTimeout > 0, totalTimeout <= Self.maximumTotalTimeout else {
            throw EngramServiceWebReadClientError.malformed
        }
        self.socketPath = socketPath
        self.totalTimeout = totalTimeout
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
        for item in response.items {
            guard request.source.map({ $0 == item.source }) ?? true,
                  request.machineId.map({ $0 == item.captureIdentity?.machineId }) ?? true,
                  request.sourceInstanceId.map({ $0 == item.captureIdentity?.sourceInstanceId }) ?? true,
                  request.projectKey.map({ $0 == item.projectKey }) ?? true else {
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

    private enum MetadataCommand: String {
        case overview = "webOverview", sessions = "webSessions", detail = "webSessionDetail"
    }

    /// Only the three typed methods above can choose this private command enum.
    /// No generic caller-supplied command, capability loader or database access.
    private func metadataResponse<Request: Encodable, Response: Decodable>(
        _ command: MetadataCommand, request: Request
    ) async throws -> Response {
        do {
            try Task.checkCancellation()
            try Self.validateCommand(command.rawValue)
            let requestID = UUID().uuidString
            let envelope = EngramServiceRequestEnvelope(requestId: requestID, command: command.rawValue,
                payload: try JSONEncoder().encode(request), capabilityToken: nil)
            let encoded = try JSONEncoder().encode(envelope)
            let bytes: Data
            do {
                bytes = try await EngramServiceSocketIO.exchange(encoded, socketPath: socketPath, totalTimeout: totalTimeout)
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
