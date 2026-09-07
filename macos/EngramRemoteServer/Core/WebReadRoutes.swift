import Foundation
import Hummingbird

/// Typed read seam. Metadata GET routes map onto one stored Surface.
enum WebReadRoutes {
    typealias MessagesReader = @Sendable (EngramServiceWebMessagesRequest) async throws -> EngramServiceWebMessagesResponse
    typealias OverviewReader = @Sendable (EngramServiceWebOverviewRequest) async throws -> EngramServiceWebOverviewResponse
    typealias SessionsReader = @Sendable (EngramServiceWebSessionsRequest) async throws -> EngramServiceWebSessionsResponse
    typealias DetailReader = @Sendable (EngramServiceWebSessionDetailRequest) async throws -> EngramServiceWebSessionDetailResponse

    struct Surface: Sendable {
        var messages: MessagesReader
        var overview: OverviewReader
        var sessions: SessionsReader
        var detail: DetailReader
    }

    typealias ClientFactory = @Sendable (String) throws -> Surface
    private static let maximumQueryBytes = 4096
    private static let messageQueryNames: Set<String> = ["generation", "roles", "cursor", "maxFragments"]
    private static let overviewQueryNames: Set<String> = ["limit", "snapshotId", "cursor"]
    private static let sessionsQueryNames: Set<String> = [
        "query", "source", "machineId", "sourceInstanceId", "projectKey", "limit", "snapshotId", "cursor",
    ]

    static func makeSurface(socketPath: String) throws -> Surface {
        let client = try EngramServiceWebReadClient(socketPath: socketPath)
        return Surface(
            messages: { request in try await client.messages(request) },
            overview: { request in try await client.overview(request) },
            sessions: { request in try await client.sessions(request) },
            detail: { request in try await client.sessionDetail(request) }
        )
    }

    static func messagesOnly(_ reader: @escaping MessagesReader) -> Surface {
        Surface(
            messages: reader,
            overview: { _ in throw EngramServiceWebReadClientError.unsupported },
            sessions: { _ in throw EngramServiceWebReadClientError.unsupported },
            detail: { _ in throw EngramServiceWebReadClientError.unsupported }
        )
    }

    static func makeReader(socketPath: String) throws -> MessagesReader {
        try makeSurface(socketPath: socketPath).messages
    }

    static func mount<Context: RequestContext>(on router: Router<Context>, surface: Surface) {
        router.get("/web/api/sessions/:id/messages") { request, context in
            let input: EngramServiceWebMessagesRequest
            do {
                input = try messagesRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.messages, input)
        }
        router.get("/web/api/overview") { request, _ in
            let input: EngramServiceWebOverviewRequest
            do {
                input = try overviewRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.overview, input)
        }
        router.get("/web/api/sessions") { request, _ in
            let input: EngramServiceWebSessionsRequest
            do {
                input = try sessionsRequest(request)
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.sessions, input)
        }
        router.get("/web/api/sessions/:id") { request, context in
            let input: EngramServiceWebSessionDetailRequest
            do {
                input = try detailRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            return try await respond(surface.detail, input)
        }
    }

    private static func respond<Input: Sendable, Output: Encodable>(
        _ reader: @escaping @Sendable (Input) async throws -> Output,
        _ input: Input
    ) async throws -> Response {
        do {
            try Task.checkCancellation()
            let page = try await reader(input)
            try Task.checkCancellation()
            let encoded = try JSONEncoder().encode(page)
            guard encoded.count <= EngramServiceWebReadLimits.maximumPageEnvelopeBytes else {
                return Response(status: .badGateway)
            }
            return EngramRemoteServerApp.json(encoded)
        } catch let error as EngramServiceWebReadClientError {
            switch error {
            case .stale: return Response(status: .conflict)
            case .unsupported, .unavailable: return Response(status: .serviceUnavailable)
            case .malformed: return Response(status: .badGateway)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Response(status: .serviceUnavailable)
        }
    }

    private static func overviewRequest(_ request: Request) throws -> EngramServiceWebOverviewRequest {
        let fields = try queryFields(request, names: overviewQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebOverviewRequest(
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func sessionsRequest(_ request: Request) throws -> EngramServiceWebSessionsRequest {
        let fields = try queryFields(request, names: sessionsQueryNames)
        let limit = try fields["limit"].map { try integer($0, name: "limit") } ?? 50
        return try EngramServiceWebSessionsRequest(
            query: fields["query"], source: fields["source"], machineId: fields["machineId"],
            sourceInstanceId: fields["sourceInstanceId"], projectKey: fields["projectKey"],
            limit: limit, snapshotId: fields["snapshotId"], cursor: fields["cursor"]
        )
    }

    private static func detailRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebSessionDetailRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#") else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        if let query = request.uri.query {
            guard query.utf8.count <= maximumQueryBytes, query.isEmpty else {
                throw EngramServiceWebReadError.invalidField("query")
            }
        }
        return try EngramServiceWebSessionDetailRequest(sessionId: try decodedComponent(rawSessionID))
    }

    private static func messagesRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebMessagesRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#"), let query = request.uri.query,
              !query.isEmpty, query.utf8.count <= maximumQueryBytes else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        let sessionID = try decodedComponent(rawSessionID)
        let fields = try decodeFields(query, names: messageQueryNames)
        guard let generation = fields["generation"] else { throw EngramServiceWebReadError.invalidField("generation") }
        let roles: [EngramServiceWebMessageRole]
        if let value = fields["roles"] {
            roles = try value.split(separator: ",", omittingEmptySubsequences: false).map {
                guard let role = EngramServiceWebMessageRole(rawValue: String($0)) else {
                    throw EngramServiceWebReadError.invalidField("roles")
                }
                return role
            }
        } else {
            roles = EngramServiceWebMessageRole.allCases
        }
        let maxFragments: Int
        if let value = fields["maxFragments"] {
            maxFragments = try integer(value, name: "maxFragments")
        } else {
            maxFragments = 50
        }
        return try EngramServiceWebMessagesRequest(sessionId: sessionID, generation: generation, roles: roles,
                                                   cursor: fields["cursor"], maxFragments: maxFragments)
    }

    private static func queryFields(_ request: Request, names: Set<String>) throws -> [String: String] {
        guard !request.uri.string.contains("#") else { throw EngramServiceWebReadError.invalidField("query") }
        guard let query = request.uri.query else { return [:] }
        guard query.utf8.count <= maximumQueryBytes else { throw EngramServiceWebReadError.invalidField("query") }
        if query.isEmpty { return [:] }
        return try decodeFields(query, names: names)
    }

    private static func decodeFields(_ query: String, names: Set<String>) throws -> [String: String] {
        var fields: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw EngramServiceWebReadError.invalidField("query") }
            let name = try decodedComponent(String(pair[0]))
            guard names.contains(name), fields[name] == nil else {
                throw EngramServiceWebReadError.invalidField("query")
            }
            fields[name] = try decodedComponent(String(pair[1]))
        }
        return fields
    }

    private static func integer(_ value: String, name: String) throws -> Int {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = Int(value), String(parsed) == value else {
            throw EngramServiceWebReadError.invalidField(name)
        }
        return parsed
    }

    private static func decodedComponent(_ value: String) throws -> String {
        // URL components preserve literal '+'. This is not application/x-www-form-urlencoded.
        guard let decoded = value.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        return decoded
    }
}
