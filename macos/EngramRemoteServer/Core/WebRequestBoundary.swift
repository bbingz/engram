import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes

/// Web-only request policy. Fetch metadata is a CSRF signal, not authentication.
struct WebRequestBoundary: Sendable {
    let configuration: EngramRemoteWebConfig

    func validateHost(_ request: Request) -> Bool {
        guard request.head.authority == configuration.authority else { return false }
        let hosts = request.headers[values: HTTPField.Name("Host")!]
        return hosts.isEmpty || (hosts.count == 1 && hosts[0] == configuration.authority)
    }

    func validateAPI(_ request: Request, requiresOrigin: Bool) -> Bool {
        guard validateHost(request), Self.singleHeader("X-Engram-Web", in: request) == "1" else { return false }
        let origins = request.headers[values: .origin]
        if !origins.isEmpty {
            return origins.count == 1 && origins[0] == configuration.origin
        }
        guard !requiresOrigin, request.method == .get,
              Self.singleHeader("Sec-Fetch-Site", in: request) == "same-origin",
              Self.singleHeader("Sec-Fetch-Dest", in: request) == "empty",
              let mode = Self.singleHeader("Sec-Fetch-Mode", in: request) else { return false }
        return mode == "cors" || mode == "same-origin"
    }

    func sessionToken(in request: Request) -> String? {
        let cookies = request.headers[values: .cookie]
        guard cookies.count == 1, let cookie = cookies.first, cookie.utf8.count <= 4096,
              !cookie.contains(","), cookie.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return nil }
        var session: String?
        for part in cookie.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = part.trimmingCharacters(in: .whitespaces)
                .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, HTTPField.Name(String(pair[0])) != nil else { return nil }
            if pair[0] == configuration.cookieName {
                let value = String(pair[1])
                guard session == nil, WebAuthSessionStore.isWellFormedToken(value) else { return nil }
                session = value
            }
        }
        return session
    }

    func decorate(_ response: Response) -> Response {
        var response = response
        response.headers[.cacheControl] = "no-store"
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        response.headers[HTTPField.Name("Content-Security-Policy")!] =
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
        for name in ["Access-Control-Allow-Origin", "Access-Control-Allow-Credentials", "Access-Control-Allow-Methods", "Access-Control-Allow-Headers", "Access-Control-Expose-Headers", "Access-Control-Max-Age"] {
            response.headers[HTTPField.Name(name)!] = nil
        }
        return response
    }

    private static func singleHeader(_ name: String, in request: Request) -> String? {
        let values = request.headers[values: HTTPField.Name(name)!]
        return values.count == 1 ? values[0] : nil
    }

    private static func isReadPath(_ path: String) -> Bool {
        if path == "/web/api/overview" || path == "/web/api/sessions" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5 || parts.count == 6,
              parts[0].isEmpty, parts[1] == "web", parts[2] == "api", parts[3] == "sessions",
              let sessionID = String(parts[4]).removingPercentEncoding,
              !sessionID.isEmpty, sessionID != ".", sessionID != "..",
              !sessionID.contains("/"), !sessionID.contains("\\"),
              !sessionID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return parts.count == 5 || parts[5] == "messages"
    }

    struct Middleware<Context: RequestContext>: RouterMiddleware {
        let boundary: WebRequestBoundary
        let sessions: WebAuthSessionStore

        func handle(
            _ request: Request,
            context: Context,
            next: (Request, Context) async throws -> Response
        ) async throws -> Response {
            let path = request.uri.path
            guard path == "/web" || path.hasPrefix("/web/") else {
                return try await next(request, context)
            }
            guard boundary.validateHost(request) else { return boundary.decorate(Response(status: .forbidden)) }
            if path == "/web/api" || path.hasPrefix("/web/api/") {
                if path == "/web/api/auth" {
                    guard request.method == .post || request.method == .delete else {
                        return boundary.decorate(Response(status: .methodNotAllowed))
                    }
                    guard boundary.validateAPI(request, requiresOrigin: true) else {
                        return boundary.decorate(Response(status: .forbidden))
                    }
                } else {
                    guard request.method == .get else { return boundary.decorate(Response(status: .methodNotAllowed)) }
                    guard WebRequestBoundary.isReadPath(path) else { return boundary.decorate(Response(status: .notFound)) }
                    guard boundary.validateAPI(request, requiresOrigin: false) else {
                        return boundary.decorate(Response(status: .forbidden))
                    }
                    guard let token = boundary.sessionToken(in: request),
                          await sessions.isAuthenticated(sessionToken: token) else {
                        return boundary.decorate(Response(status: .unauthorized))
                    }
                }
            } else if request.method != .get {
                return boundary.decorate(Response(status: .methodNotAllowed))
            }
            do {
                return boundary.decorate(try await next(request, context))
            } catch {
                // The Web wrapper, not just a matched router group, owns failures.
                // Never expose a downstream exception or turn it into empty success.
                return boundary.decorate(Response(status: .serviceUnavailable))
            }
        }
    }
}
