import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import Logging
import NIOCore
@testable import EngramRemoteServerCore
import XCTest

final class WebAuthRouteTests: XCTestCase {
    private let viewer = "test-only-viewer-credential"
    private let origin = "https://viewer.example"

    private func request(
        _ method: HTTPRequest.Method = .get,
        path: String = "/web/api/overview",
        scheme: String = "https",
        authority: String? = "viewer.example",
        headers: [(String, String)] = [],
        body: String = ""
    ) -> Request {
        var fields = HTTPFields()
        for (name, value) in headers { fields.append(HTTPField(name: HTTPField.Name(name)!, value: value)) }
        return Request(
            head: HTTPRequest(method: method, scheme: scheme, authority: authority, path: path, headerFields: fields),
            body: RequestBody(buffer: ByteBuffer(string: body))
        )
    }

    private var originHeaders: [(String, String)] { [("X-Engram-Web", "1"), ("Origin", origin)] }
    private var metadataHeaders: [(String, String)] {
        [("X-Engram-Web", "1"), ("Sec-Fetch-Site", "same-origin"), ("Sec-Fetch-Mode", "cors"), ("Sec-Fetch-Dest", "empty")]
    }
    private var loginHeaders: [(String, String)] { originHeaders + [("Content-Type", "application/json")] }
    private var loginBody: String { "{\"credential\":\"\(viewer)\"}" }

    private func configuration() throws -> EngramRemoteWebConfig {
        try EngramRemoteWebConfig(origin: origin, viewerCredential: viewer, serverBearerCredentials: ["test-v1-bearer", "test-archive-bearer", "test-mcp-bearer"])
    }

    private func issuedToken(_ harness: WebRouteHarness, file: StaticString = #filePath, line: UInt = #line) async -> String? {
        let result = await harness.sessions.login(credential: viewer)
        guard case let .authenticated(token) = result else {
            XCTFail("Expected issued session for route test, got \(result)", file: file, line: line)
            return nil
        }
        return token
    }

    private func assertSecurityHeaders(_ response: Response, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.headers[.cacheControl], "no-store", file: file, line: line)
        XCTAssertEqual(response.headers[HTTPField.Name("X-Content-Type-Options")!], "nosniff", file: file, line: line)
        let csp = response.headers[HTTPField.Name("Content-Security-Policy")!] ?? ""
        for directive in ["default-src 'none'", "script-src 'self'", "connect-src 'self'", "base-uri 'none'", "frame-ancestors 'none'"] {
            XCTAssertTrue(csp.contains(directive), directive, file: file, line: line)
        }
        for forbidden in ["'unsafe-inline'", "'unsafe-eval'", "https:", "http:", "*"] {
            XCTAssertFalse(csp.contains(forbidden), forbidden, file: file, line: line)
        }
        for name in ["Access-Control-Allow-Origin", "Access-Control-Allow-Credentials", "Access-Control-Allow-Methods", "Access-Control-Allow-Headers"] {
            XCTAssertNil(response.headers[HTTPField.Name(name)!], file: file, line: line)
        }
    }

    func testExactAuthorityAndOptionalMatchingRawHostAreAccepted() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        XCTAssertTrue(boundary.validateHost(request()))
        XCTAssertTrue(boundary.validateHost(request(headers: [("Host", "viewer.example")])))
        let portConfig = try EngramRemoteWebConfig(origin: "https://viewer.example:9443", viewerCredential: viewer, serverBearerCredentials: [])
        XCTAssertTrue(WebRequestBoundary(configuration: portConfig).validateHost(request(authority: "viewer.example:9443")))
        XCTAssertFalse(WebRequestBoundary(configuration: portConfig).validateHost(request()))
    }

    func testAuthorityMismatchDuplicateHostAndForwardedSpoofingFailClosed() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        for authority in [nil, "evil.example", "VIEWER.example", "viewer.example.", "viewer.example:443", "viewer.example:9443", "viewer.example@evil.example", "viewer.example,evil.example"] as [String?] {
            XCTAssertFalse(boundary.validateHost(request(authority: authority, headers: [("Host", "viewer.example"), ("Forwarded", "host=viewer.example;proto=https"), ("X-Forwarded-Host", "viewer.example")])))
        }
        for fields in [
            [("Host", "evil.example")],
            [("Host", "viewer.example"), ("Host", "viewer.example")],
            [("Host", "viewer.example,evil.example")],
            [("Host", "")],
        ] {
            XCTAssertFalse(boundary.validateHost(request(headers: fields)))
        }
    }

    func testAPIMarkerMustBeSingleExactOneForEveryAPIRequest() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        XCTAssertTrue(boundary.validateAPI(request(headers: originHeaders), requiresOrigin: false))
        for values in [[], [""], ["0"], ["true"], ["1,1"], ["1 ", "1"], ["1", "1"]] as [[String]] {
            let headers = [("Origin", origin)] + values.map { ("X-Engram-Web", $0) }
            XCTAssertFalse(boundary.validateAPI(request(headers: headers), requiresOrigin: false))
        }
    }

    func testPresentInvalidOriginNeverFallsBackToValidFetchMetadata() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        for values in [[""], ["null"], ["https://evil.example"], ["https://viewer.example/"], ["HTTPS://viewer.example"], ["https://viewer.example:443"], [origin + "," + origin], [origin, origin], ["not a URL"]] {
            let headers = metadataHeaders + values.map { ("Origin", $0) }
            XCTAssertFalse(boundary.validateAPI(request(headers: headers), requiresOrigin: false))
        }
        XCTAssertTrue(boundary.validateAPI(request(headers: originHeaders), requiresOrigin: false))
    }

    func testAbsentOriginGETRequiresAllThreeSingleExactFetchMetadataValues() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        XCTAssertTrue(boundary.validateAPI(request(headers: metadataHeaders), requiresOrigin: false))
        let sameOriginMode = metadataHeaders.map { $0.0 == "Sec-Fetch-Mode" ? ($0.0, "same-origin") : $0 }
        XCTAssertTrue(boundary.validateAPI(request(headers: sameOriginMode), requiresOrigin: false))
        for name in ["Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest"] {
            XCTAssertFalse(boundary.validateAPI(request(headers: metadataHeaders.filter { $0.0 != name }), requiresOrigin: false))
            let value = metadataHeaders.first { $0.0 == name }!.1
            XCTAssertFalse(boundary.validateAPI(request(headers: metadataHeaders + [(name, value)]), requiresOrigin: false))
        }
        for (name, values) in [
            ("Sec-Fetch-Site", ["same-site", "cross-site", "none", "same-origin,cross-site", "Same-Origin", ""]),
            ("Sec-Fetch-Mode", ["no-cors", "navigate", "websocket", "cors,same-origin", ""]),
            ("Sec-Fetch-Dest", ["", "document", "script", "image", "empty,empty"]),
        ] {
            for value in values {
                let headers = metadataHeaders.map { $0.0 == name ? (name, value) : $0 }
                XCTAssertFalse(boundary.validateAPI(request(headers: headers), requiresOrigin: false), "\(name)=\(value)")
            }
        }
        XCTAssertFalse(boundary.validateAPI(request(headers: [("X-Engram-Web", "1"), ("Referer", origin + "/web"), ("Forwarded", "host=viewer.example;proto=https")]), requiresOrigin: false))
    }

    func testLoginAndLogoutCannotUseFetchMetadataInPlaceOfOrigin() throws {
        let boundary = WebRequestBoundary(configuration: try configuration())
        for method in [HTTPRequest.Method.post, .delete] {
            XCTAssertFalse(boundary.validateAPI(request(method, path: "/web/api/auth", headers: metadataHeaders), requiresOrigin: true))
            XCTAssertTrue(boundary.validateAPI(request(method, path: "/web/api/auth", headers: originHeaders), requiresOrigin: true))
        }
    }

    func testCookieParserRejectsDuplicateSessionAmbiguity() throws {
        let config = try configuration()
        let boundary = WebRequestBoundary(configuration: config)
        let token = String(repeating: "A", count: 43)
        let pair = "\(config.cookieName)=\(token)"
        XCTAssertEqual(boundary.sessionToken(in: request(headers: [("Cookie", pair)])), token)
        XCTAssertEqual(boundary.sessionToken(in: request(headers: [("Cookie", "other=1; " + pair)])), token)
        for headers in [
            [], [("Cookie", "")], [("Cookie", "\(config.cookieName)=")],
            [("Cookie", pair + "; " + pair)], [("Cookie", pair), ("Cookie", pair)],
            [("Cookie", pair + ", " + pair)], [("Cookie", "\(config.cookieName)=\"\(token)\"")],
            [("Cookie", "\(config.cookieName)=\(token)=")], [("Cookie", "other=\(token)")],
        ] as [[(String, String)]] {
            XCTAssertNil(boundary.sessionToken(in: request(headers: headers)))
        }
    }

    func testRealResponderLoginSetsHardenedCookieWithoutCredentialOrSessionInBody() async throws {
        let harness = try WebRouteHarness(configuration: configuration())
        let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders, body: loginBody))
        XCTAssertEqual(response.status, .noContent)
        assertSecurityHeaders(response)
        let cookie = response.headers[.setCookie] ?? ""
        for attribute in ["__Host-engram_web=", "Secure", "HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=900"] { XCTAssertTrue(cookie.contains(attribute), attribute) }
        XCTAssertFalse(cookie.lowercased().contains("domain="))
        XCTAssertFalse(cookie.contains(viewer))
        let body = try await webResponseText(response)
        XCTAssertEqual(body, "")
        let token = cookie.split(separator: ";").first?.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
        XCTAssertEqual(token.count, 43)
        let valid = await harness.sessions.isAuthenticated(sessionToken: token)
        XCTAssertTrue(valid)
        let reads = await harness.reads.count
        XCTAssertEqual(reads, 0)
    }

    func testLoginAcceptsOnlyCredentialObjectAndFourKiBBoundedJSON() async throws {
        for body in ["", "[]", "null", "{}", "{\"credential\":1}", "{\"credential\":null}", "{\"credential\":\"\(viewer)\",\"command\":\"shutdown\"}", "{\"credential\":\"\(viewer)\",\"credential\":\"\(viewer)\"}", "{\"credential\":\"\(viewer)\",\"\\u0063redential\":\"\(viewer)\"}", "{not-json}"] {
            let harness = try WebRouteHarness(configuration: configuration())
            let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders, body: body))
            XCTAssertEqual(response.status, .badRequest, body)
            XCTAssertNil(response.headers[.setCookie])
            assertSecurityHeaders(response)
        }
        let harness = try WebRouteHarness(configuration: configuration())
        let oversized = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders, body: String(repeating: " ", count: 4097)))
        XCTAssertEqual(oversized.status.code, 413)
        for type in [nil, "text/plain", "application/json,application/json"] as [String?] {
            let headers = originHeaders + (type.map { [("Content-Type", $0)] } ?? [])
            let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: headers, body: loginBody))
            XCTAssertEqual(response.status.code, 415)
        }
        let duplicateType = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders + [("Content-Type", "application/json")], body: loginBody))
        XCTAssertEqual(duplicateType.status.code, 415)
        let reads = await harness.reads.count
        XCTAssertEqual(reads, 0)
        let exactHarness = try WebRouteHarness(configuration: configuration())
        let exactBody = loginBody + String(repeating: " ", count: 4096 - loginBody.utf8.count)
        let exactLimit = try await exactHarness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders, body: exactBody))
        XCTAssertEqual(exactLimit.status, .noContent)
    }

    func testInternalLoopbackHTTPRouteUsesOnlyTheExplicitTestCookieVariant() async throws {
        let testOrigin = "http://127.0.0.1:8787"
        let config = try EngramRemoteWebConfig.forLoopbackHTTPTesting(origin: testOrigin, viewerCredential: viewer, serverBearerCredentials: [])
        let harness = try WebRouteHarness(configuration: config)
        let headers = [("X-Engram-Web", "1"), ("Origin", testOrigin), ("Content-Type", "application/json")]
        let response = try await harness.respond(request(.post, path: "/web/api/auth", scheme: "http", authority: "127.0.0.1:8787", headers: headers, body: loginBody))
        XCTAssertEqual(response.status, .noContent)
        let cookie = response.headers[.setCookie] ?? ""
        XCTAssertTrue(cookie.hasPrefix("engram_web_test="))
        XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("SameSite=Strict"))
        XCTAssertFalse(cookie.contains("Secure"))
        XCTAssertFalse(cookie.contains("__Host-"))
        assertSecurityHeaders(response)
    }

    func testRouteRejectsServerBearerLoginAndNeverEchoesSecrets() async throws {
        for credential in ["wrong", "test-v1-bearer", "test-archive-bearer", "test-mcp-bearer"] {
            let harness = try WebRouteHarness(configuration: configuration())
            let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders, body: "{\"credential\":\"\(credential)\"}"))
            XCTAssertEqual(response.status, .unauthorized)
            XCTAssertNil(response.headers[.setCookie])
            let body = try await webResponseText(response)
            XCTAssertFalse(body.contains(credential))
            XCTAssertFalse(body.contains(viewer))
            assertSecurityHeaders(response)
        }
    }

    func testGlobalRouteThrottleReturns429AndRetryAfterWithoutIPTrust() async throws {
        let harness = try WebRouteHarness(configuration: configuration())
        for index in 0..<5 {
            let headers = loginHeaders + [("X-Forwarded-For", "203.0.113.\(index)")]
            let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: headers, body: "{\"credential\":\"wrong\"}"))
            XCTAssertEqual(response.status, .unauthorized)
        }
        let response = try await harness.respond(request(.post, path: "/web/api/auth", headers: loginHeaders + [("Forwarded", "for=192.0.2.100")], body: loginBody))
        XCTAssertEqual(response.status.code, 429)
        XCTAssertEqual(response.headers[.retryAfter], "60")
        XCTAssertNil(response.headers[.setCookie])
        assertSecurityHeaders(response)
    }

    func testAuthenticatedGETWithOriginOrAbsentOriginMetadataReachesReadExactlyOnce() async throws {
        for headers in [originHeaders, metadataHeaders] {
            let harness = try WebRouteHarness(configuration: configuration())
            guard let token = await issuedToken(harness) else { return }
            let response = try await harness.respond(request(headers: headers + [("Cookie", "__Host-engram_web=\(token)")]))
            XCTAssertEqual(response.status, .ok)
            assertSecurityHeaders(response)
            let body = try await webResponseText(response)
            XCTAssertEqual(body, "test-protected-data")
            let reads = await harness.reads.count
            XCTAssertEqual(reads, 1)
        }
    }

    func testOnlyDocumentedGETShapesReachProtectedReadSentinels() async throws {
        for path in ["/web/api/overview", "/web/api/sessions?q=keyword", "/web/api/sessions/central-session-id", "/web/api/sessions/central-session-id/messages"] {
            let harness = try WebRouteHarness(configuration: configuration())
            guard let token = await issuedToken(harness) else { return }
            let response = try await harness.respond(request(path: path, headers: metadataHeaders + [("Cookie", "__Host-engram_web=\(token)")]))
            XCTAssertEqual(response.status, .ok, path)
            let reads = await harness.reads.count
            XCTAssertEqual(reads, 1)
        }
    }

    func testForgedMetadataOrBearerWithoutSessionNeverReachesRead() async throws {
        for headers in [originHeaders, metadataHeaders, metadataHeaders + [("Authorization", "Bearer test-v1-bearer")], originHeaders + [("Cookie", "__Host-engram_web=not-a-session")]] {
            let harness = try WebRouteHarness(configuration: configuration())
            let response = try await harness.respond(request(headers: headers))
            XCTAssertEqual(response.status, .unauthorized)
            assertSecurityHeaders(response)
            let reads = await harness.reads.count
            XCTAssertEqual(reads, 0)
        }
    }

    func testBadHostOriginAndAPIMarkerRejectBeforeAnyRouterOrReadInvocation() async throws {
        let cases: [(String?, [(String, String)])] = [
            ("evil.example", originHeaders),
            ("viewer.example", metadataHeaders + [("Origin", "null")]),
            ("viewer.example", metadataHeaders + [("Origin", origin), ("Origin", origin)]),
            ("viewer.example", [("Origin", origin)]),
            ("viewer.example", metadataHeaders.map { $0.0 == "Sec-Fetch-Site" ? ($0.0, "same-site") : $0 }),
        ]
        for (authority, headers) in cases {
            let harness = try WebRouteHarness(configuration: configuration())
            let response = try await harness.respond(request(authority: authority, headers: headers))
            XCTAssertEqual(response.status, .forbidden)
            assertSecurityHeaders(response)
            let routes = await harness.routingCalls.count
            let reads = await harness.reads.count
            XCTAssertEqual(routes, 0)
            XCTAssertEqual(reads, 0)
        }
    }

    func testUnknownWriteHEADOPTIONSAndCustomMethodsAreRejectedBeforeRouterOrRead() async throws {
        let attempts: [(HTTPRequest.Method, String)] = [
            (.head, "/web/api/overview"), (.options, "/web/api/overview"), (.post, "/web/api/overview"),
            (.put, "/web/api/sessions/id"), (.patch, "/web/api/sessions/id"), (.delete, "/web/api/sessions/id"),
            (HTTPRequest.Method(rawValue: "TRACE")!, "/web/api/overview"),
            (.get, "/web/api/resumeCommand"), (.get, "/web/api/memoryFileContent"), (.get, "/web/api/exportSession"),
            (.get, "/web/api/shutdown"), (.get, "/web/api/unknown"), (.get, "/web/api/auth"),
            (.get, "/web/api/sessions/id/resumeCommand"), (.get, "/web/api/%6fverview"),
            (.get, "/web/api/sessions/../overview"),
            (.head, "/web"), (.options, "/web/assets/app.js"),
        ]
        for (method, path) in attempts {
            let harness = try WebRouteHarness(configuration: configuration())
            guard let token = await issuedToken(harness) else { return }
            let headers = loginHeaders + [("Cookie", "__Host-engram_web=\(token)")]
            let response = try await harness.respond(request(method, path: path, headers: headers, body: "{}"))
            XCTAssertTrue((400..<500).contains(response.status.code), "\(method) \(path)")
            assertSecurityHeaders(response)
            let routes = await harness.routingCalls.count
            let reads = await harness.reads.count
            XCTAssertEqual(routes, 0)
            XCTAssertEqual(reads, 0)
        }
    }

    func testLogoutRequiresJSONOriginAndSessionThenRevokesAndClearsCookie() async throws {
        let harness = try WebRouteHarness(configuration: configuration())
        guard let token = await issuedToken(harness) else { return }
        let cookie = ("Cookie", "__Host-engram_web=\(token)")
        let badOrigin = try await harness.respond(request(.delete, path: "/web/api/auth", headers: metadataHeaders + [("Content-Type", "application/json"), cookie], body: "{}"))
        XCTAssertEqual(badOrigin.status, .forbidden)
        let stillValid = await harness.sessions.isAuthenticated(sessionToken: token)
        XCTAssertTrue(stillValid)
        let noJSON = try await harness.respond(request(.delete, path: "/web/api/auth", headers: originHeaders + [cookie], body: "{}"))
        XCTAssertEqual(noJSON.status.code, 415)
        let malformed = try await harness.respond(request(.delete, path: "/web/api/auth", headers: loginHeaders + [cookie], body: "{\"command\":\"shutdown\"}"))
        XCTAssertEqual(malformed.status, .badRequest)
        let oversized = try await harness.respond(request(.delete, path: "/web/api/auth", headers: loginHeaders + [cookie], body: String(repeating: " ", count: 4097)))
        XCTAssertEqual(oversized.status.code, 413)
        let response = try await harness.respond(request(.delete, path: "/web/api/auth", headers: loginHeaders + [cookie], body: "{}"))
        XCTAssertEqual(response.status, .noContent)
        assertSecurityHeaders(response)
        let cleared = response.headers[.setCookie] ?? ""
        for attribute in ["__Host-engram_web=", "Max-Age=0", "Secure", "HttpOnly", "SameSite=Strict", "Path=/"] { XCTAssertTrue(cleared.contains(attribute)) }
        XCTAssertFalse(cleared.contains(token))
        let valid = await harness.sessions.isAuthenticated(sessionToken: token)
        XCTAssertFalse(valid)
        let replay = try await harness.respond(request(headers: originHeaders + [cookie]))
        XCTAssertEqual(replay.status, .unauthorized)
        let reads = await harness.reads.count
        XCTAssertEqual(reads, 0)
    }

    func testLogoutWithoutSessionOrWithAmbiguousCookieDoesNotRevokeAnotherSession() async throws {
        let harness = try WebRouteHarness(configuration: configuration())
        let missing = try await harness.respond(request(.delete, path: "/web/api/auth", headers: loginHeaders, body: "{}"))
        XCTAssertEqual(missing.status, .unauthorized)
        guard let token = await issuedToken(harness) else { return }
        let pair = "__Host-engram_web=\(token)"
        let duplicate = try await harness.respond(request(.delete, path: "/web/api/auth", headers: loginHeaders + [("Cookie", pair + "; " + pair)], body: "{}"))
        XCTAssertEqual(duplicate.status, .unauthorized)
        let stillValid = await harness.sessions.isAuthenticated(sessionToken: token)
        XCTAssertTrue(stillValid)
        XCTAssertNil(duplicate.headers[.setCookie])
        assertSecurityHeaders(duplicate)
    }

    func testStaticNavigationMayOmitOriginButStillRequiresHostAndHasNoDataOrCookie() async throws {
        for path in ["/web", "/web/assets/app.js"] {
            let harness = try WebRouteHarness(configuration: configuration())
            let response = try await harness.respond(request(path: path))
            XCTAssertEqual(response.status, .ok)
            assertSecurityHeaders(response)
            XCTAssertNil(response.headers[.setCookie])
            let body = try await webResponseText(response)
            XCTAssertFalse(body.contains("test-protected-data"))
            XCTAssertFalse(body.contains(viewer))
            let badHost = try await harness.respond(request(path: path, authority: "evil.example"))
            XCTAssertEqual(badHost.status, .forbidden)
            assertSecurityHeaders(badHost)
            let reads = await harness.reads.count
            XCTAssertEqual(reads, 0)
        }
    }

    func testUnknownWebFailuresAreDecoratedAndAuthOnlyRouterHasNoSuccessfulReadPlaceholder() async throws {
        let harness = try WebRouteHarness(configuration: configuration(), includeReadSentinel: false)
        guard let token = await issuedToken(harness) else { return }
        for path in ["/web/api/overview", "/web/missing"] {
            let response = try await harness.respond(request(path: path, headers: originHeaders + [("Cookie", "__Host-engram_web=\(token)")]))
            XCTAssertEqual(response.status, .notFound)
            assertSecurityHeaders(response)
        }
        let reads = await harness.reads.count
        XCTAssertEqual(reads, 0)
    }

    func testWebBoundaryDoesNotChangeLegacyNonWebRouteOrPrefixLookalike() async throws {
        let harness = try WebRouteHarness(configuration: configuration())
        for path in ["/legacy", "/webhook"] {
            let response = try await harness.respond(request(path: path, authority: "legacy.example", headers: [("Origin", "https://legacy-client.example")]))
            XCTAssertEqual(response.status, .accepted)
            XCTAssertEqual(response.headers[HTTPField.Name("X-Legacy-Test")!], "unchanged")
            XCTAssertNil(response.headers[.cacheControl])
            XCTAssertNil(response.headers[HTTPField.Name("Content-Security-Policy")!])
        }
    }
}

private actor WebRouteCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}

private struct WebRouteTestSource: RequestContextSource {
    let logger = Logger(label: "web-route-boundary-test")
}

private struct WebRouteTestContext: RequestContext {
    typealias Source = WebRouteTestSource
    var coreContext: CoreRequestContextStorage
    init(source: Source) { coreContext = CoreRequestContextStorage(source: source) }
}

/// Uses a real HTTPRequest/Request/RouterResponder; no .test(.router) authority substitution.
private struct WebRouteHarness: Sendable {
    let boundary: WebRequestBoundary
    let sessions: WebAuthSessionStore
    let reads = WebRouteCounter()
    let routingCalls = WebRouteCounter()
    let includeReadSentinel: Bool

    init(configuration: EngramRemoteWebConfig, includeReadSentinel: Bool = true) throws {
        self.boundary = WebRequestBoundary(configuration: configuration)
        let clock = WebTestClock()
        let random = WebTestRandom()
        self.sessions = WebAuthSessionStore(configuration: configuration, now: { clock.now }, randomBytes: { try random.next() })
        self.includeReadSentinel = includeReadSentinel
    }

    func respond(_ request: Request) async throws -> Response {
        let router = Router(context: WebRouteTestContext.self)
        WebAuthRoutes.mount(on: router, boundary: boundary, sessions: sessions)
        if includeReadSentinel {
            for path in ["/web/api/overview", "/web/api/sessions", "/web/api/sessions/:id", "/web/api/sessions/:id/messages"] {
                router.get(RouterPath(path)) { _, _ in
                    await reads.hit()
                    return Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(string: "test-protected-data")))
                }
            }
        }
        router.get("/web") { _, _ in Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(string: "static-shell"))) }
        router.get("/web/assets/app.js") { _, _ in Response(status: .ok, body: ResponseBody(byteBuffer: ByteBuffer(string: "static-asset"))) }
        for path in ["/legacy", "/webhook"] {
            router.get(RouterPath(path)) { _, _ in Response(status: .accepted, headers: [HTTPField.Name("X-Legacy-Test")!: "unchanged"]) }
        }
        let responder = router.buildResponder()
        return try await WebRequestBoundary.Middleware<WebRouteTestContext>(boundary: boundary, sessions: sessions).handle(
            request, context: WebRouteTestContext(source: WebRouteTestSource())
        ) { request, context in
            await routingCalls.hit()
            return try await responder.respond(to: request, context: context)
        }
    }
}

private actor WebResponseBytes {
    private var bytes: [UInt8] = []
    func append(_ buffer: ByteBuffer) { bytes.append(contentsOf: buffer.readableBytesView) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

private struct WebResponseWriter: ResponseBodyWriter {
    let storage: WebResponseBytes
    mutating func write(_ buffer: ByteBuffer) async throws { await storage.append(buffer) }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

private func webResponseText(_ response: Response) async throws -> String {
    let storage = WebResponseBytes()
    try await response.body.write(WebResponseWriter(storage: storage))
    return await storage.text
}
