import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore

enum WebAuthRoutes {
    static func mount<Context: RequestContext>(
        on router: Router<Context>,
        boundary: WebRequestBoundary,
        sessions: WebAuthSessionStore
    ) {
        router.post("/web/api/auth") { request, _ in
            await login(request, boundary: boundary, sessions: sessions)
        }
        router.delete("/web/api/auth") { request, _ in
            await logout(request, boundary: boundary, sessions: sessions)
        }
    }

    private static func login(
        _ request: Request,
        boundary: WebRequestBoundary,
        sessions: WebAuthSessionStore
    ) async -> Response {
        guard boundary.validateAPI(request, requiresOrigin: true) else { return boundary.decorate(Response(status: .forbidden)) }
        let data: Data
        do { data = try await readJSONBody(request) } catch {
            return boundary.decorate(Response(status: (error as? AuthBodyError)?.status ?? .badRequest))
        }
        guard let credential = loginCredential(in: data) else { return boundary.decorate(Response(status: .badRequest)) }
        switch await sessions.login(credential: credential) {
        case let .authenticated(token):
            return boundary.decorate(Response(status: .noContent, headers: [.setCookie: cookie(token, boundary: boundary, maxAge: WebAuthSessionStore.lifetimeSeconds)]))
        case .unauthorized:
            return boundary.decorate(Response(status: .unauthorized))
        case let .throttled(retryAfterSeconds):
            return boundary.decorate(Response(status: .tooManyRequests, headers: [.retryAfter: String(retryAfterSeconds)]))
        case .unavailable:
            return boundary.decorate(Response(status: .serviceUnavailable))
        }
    }

    private static func logout(
        _ request: Request,
        boundary: WebRequestBoundary,
        sessions: WebAuthSessionStore
    ) async -> Response {
        guard boundary.validateAPI(request, requiresOrigin: true) else { return boundary.decorate(Response(status: .forbidden)) }
        let data: Data
        do { data = try await readJSONBody(request) } catch {
            return boundary.decorate(Response(status: (error as? AuthBodyError)?.status ?? .badRequest))
        }
        guard data.filter({ !isJSONWhitespace($0) }) == Data([123, 125]) else {
            return boundary.decorate(Response(status: .badRequest))
        }
        guard let token = boundary.sessionToken(in: request), await sessions.isAuthenticated(sessionToken: token) else {
            return boundary.decorate(Response(status: .unauthorized))
        }
        await sessions.logout(sessionToken: token)
        return boundary.decorate(Response(status: .noContent, headers: [.setCookie: cookie("", boundary: boundary, maxAge: 0)]))
    }

    private enum AuthBodyError: Error {
        case unsupportedMediaType
        case tooLarge
        case malformed

        var status: HTTPResponse.Status {
            switch self {
            case .unsupportedMediaType: .unsupportedMediaType
            case .tooLarge: .contentTooLarge
            case .malformed: .badRequest
            }
        }
    }

    private static func readJSONBody(_ request: Request) async throws -> Data {
        let values = request.headers[values: .contentType]
        guard values.count == 1 else { throw AuthBodyError.unsupportedMediaType }
        let parts = values[0].lowercased().split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts == ["application/json"] || parts == ["application/json", "charset=utf-8"] else {
            throw AuthBodyError.unsupportedMediaType
        }
        do {
            let buffer = try await request.body.collect(upTo: 4096)
            return Data(buffer.readableBytesView)
        } catch is NIOTooManyBytesError {
            throw AuthBodyError.tooLarge
        } catch {
            throw AuthBodyError.malformed
        }
    }

    private static func loginCredential(in data: Data) -> String? {
        // This schema has exactly one member and a string value. An unquoted
        // comma can therefore only introduce an invalid extra/duplicate member.
        // Check before Foundation collapses duplicate keys, including escaped keys.
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
            } else if byte == 44 {
                return nil
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let credential = object["credential"] as? String else { return nil }
        return credential
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func cookie(_ token: String, boundary: WebRequestBoundary, maxAge: Int) -> String {
        var value = "\(boundary.configuration.cookieName)=\(token); Max-Age=\(maxAge); Path=/; HttpOnly; SameSite=Strict"
        if boundary.configuration.isSecure { value += "; Secure" }
        return value
    }
}
