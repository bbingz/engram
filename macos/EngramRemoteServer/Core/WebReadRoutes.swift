import Foundation
import Hummingbird

/// Typed messages-only seam. No arbitrary command or capability surface is exposed.
enum WebReadRoutes {
    typealias MessagesReader = @Sendable (EngramServiceWebMessagesRequest) async throws -> EngramServiceWebMessagesResponse
    typealias ClientFactory = @Sendable (String) throws -> MessagesReader
    private static let maximumQueryBytes = 4096
    private static let queryNames: Set<String> = ["generation", "roles", "cursor", "maxFragments"]

    static func makeReader(socketPath: String) throws -> MessagesReader {
        let client = try EngramServiceWebReadClient(socketPath: socketPath)
        return { request in try await client.messages(request) }
    }

    static func mount<Context: RequestContext>(on router: Router<Context>, readMessages: @escaping MessagesReader) {
        router.get("/web/api/sessions/:id/messages") { request, context in
            let input: EngramServiceWebMessagesRequest
            do {
                input = try messagesRequest(request, rawSessionID: context.parameters.get("id"))
            } catch {
                return Response(status: .badRequest)
            }
            do {
                try Task.checkCancellation()
                let page = try await readMessages(input)
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
    }

    private static func messagesRequest(_ request: Request, rawSessionID: String?) throws -> EngramServiceWebMessagesRequest {
        guard let rawSessionID, rawSessionID.utf8.count <= EngramServiceWebReadLimits.maximumSessionIDBytes * 3,
              !request.uri.string.contains("#"), let query = request.uri.query,
              !query.isEmpty, query.utf8.count <= maximumQueryBytes else {
            throw EngramServiceWebReadError.invalidField("query")
        }
        let sessionID = try decodedComponent(rawSessionID)
        var fields: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw EngramServiceWebReadError.invalidField("query") }
            let name = try decodedComponent(String(pair[0]))
            guard queryNames.contains(name), fields[name] == nil else {
                throw EngramServiceWebReadError.invalidField("query")
            }
            fields[name] = try decodedComponent(String(pair[1]))
        }
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
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(value), String(parsed) == value else {
                throw EngramServiceWebReadError.invalidField("maxFragments")
            }
            maxFragments = parsed
        } else {
            maxFragments = 50
        }
        return try EngramServiceWebMessagesRequest(sessionId: sessionID, generation: generation, roles: roles,
                                                   cursor: fields["cursor"], maxFragments: maxFragments)
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
