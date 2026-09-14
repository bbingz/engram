import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import Logging
import NIOCore
@testable import EngramRemoteServerCore
import XCTest

final class WebUIRoutesTests: XCTestCase {
    private let viewer = "test-only-viewer-credential"
    private let origin = "https://viewer.example"

    func testUnauthenticatedGetWebHTMLUsesExternalAssetsWithoutInlineCode() async throws {
        let harness = try UIHarness(configuration: configuration())
        for path in ["/web", "/web/"] {
            let response = try await harness.respond(request(path: path, headers: [("Host", "viewer.example")]))
            XCTAssertEqual(response.status, .ok, path)
            XCTAssertEqual(response.headers[.cacheControl], "no-store", path)
            XCTAssertEqual(response.headers[HTTPField.Name("X-Content-Type-Options")!], "nosniff", path)
            let type = response.headers[.contentType] ?? ""
            XCTAssertTrue(type.hasPrefix("text/html"), "\(path) \(type)")
            assertUnchangedCSP(response)
            let html = try await bodyText(response)
            XCTAssertTrue(html.localizedCaseInsensitiveContains("<!doctype html>"), path)
            XCTAssertTrue(html.contains("src=\"/web/app.js\""), path)
            XCTAssertTrue(html.contains("href=\"/web/app.css\""), path)
            XCTAssertFalse(containsInlineScript(html), path)
            XCTAssertFalse(containsInlineStyle(html), path)
            XCTAssertFalse(html.contains(viewer), path)
            for hook in ["login", "logout", "overview", "sessions", "search", "detail", "messages", "more",
                         "workspace", "signed-out", "query", "source-picker", "machineId", "project-picker", "back",
                         "nav-settings", "settings-page", "settings-content", "settings-refresh", "settings-more",
                         "since", "until", "hide-tools", "session-previous", "session-page-status",
                         "search-options", "search-mode", "search-limit", "search-capabilities", "search-result-status",
                         "stats-view-costs", "costs-content", "costs-form", "costs-totals", "costs-rows", "costs-sessions", "costs-more"] {
                XCTAssertTrue(html.contains(hook), "\(path) missing \(hook)")
            }
            XCTAssertTrue(html.contains(">Search<") || html.contains(">Search "), path)
            XCTAssertTrue(html.contains("id=\"source-options\""), path)
            XCTAssertTrue(html.contains("All sources"), path)
            XCTAssertTrue(html.contains("Machine ID"), path)
            XCTAssertTrue(html.contains("All projects"), path)
            XCTAssertTrue(html.contains("for=\"project-query\""), path)
            XCTAssertFalse(html.localizedCaseInsensitiveContains("replica"), path)
            XCTAssertFalse(html.localizedCaseInsensitiveContains("publication"), path)
        }
    }

    func testSameOriginJavaScriptAndCSSAreServedSeparately() async throws {
        let harness = try UIHarness(configuration: configuration())
        let script = try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(script.status, .ok)
        XCTAssertTrue((script.headers[.contentType] ?? "").hasPrefix("text/javascript")
            || (script.headers[.contentType] ?? "").hasPrefix("application/javascript"))
        assertUnchangedCSP(script)
        let css = try await harness.respond(request(path: "/web/app.css", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(css.status, .ok)
        XCTAssertTrue((css.headers[.contentType] ?? "").hasPrefix("text/css"))
        assertUnchangedCSP(css)
        let cssText = try await bodyText(css)
        XCTAssertFalse(containsInlineScript(cssText))
        XCTAssertTrue(cssText.contains("overflow-wrap: anywhere"))
        XCTAssertTrue(cssText.contains("--bg:#0f172a"))
        XCTAssertTrue(cssText.contains("--accent:#22c55e"))
        XCTAssertTrue(cssText.contains(".session"))
        XCTAssertTrue(cssText.contains(".badge"))
        XCTAssertTrue(cssText.contains(".message .body"))
        XCTAssertTrue(cssText.contains("font: inherit"))
        XCTAssertTrue(cssText.contains("[hidden]"))
        XCTAssertTrue(cssText.contains("display: none !important"))
        XCTAssertTrue(cssText.contains("showing-detail"))
    }

    func testJavaScriptUsesTextContentAndExistingAPIsForLoginLogoutAndPaging() async throws {
        let harness = try UIHarness(configuration: configuration())
        let js = try await bodyText(try await harness.respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertFalse(js.contains("innerHTML"))
        XCTAssertFalse(js.contains("eval("))
        XCTAssertFalse(js.contains("document.write"))
        for path in ["/web/api/auth", "/web/api/overview", "/web/api/sessions", "/web/api/settings", "/web/api/search/status", "/web/api/search", "/messages"] {
            XCTAssertTrue(js.contains(path), path)
        }
        for word in ["credential", "logout", "cursor", "more"] {
            XCTAssertTrue(js.contains(word), word)
        }
        XCTAssertTrue(js.contains("X-Engram-Web"))
        XCTAssertFalse(js.contains(viewer))
        XCTAssertTrue(js.contains("sessionSnapshotId"))
        XCTAssertTrue(js.contains("sessionCursor"))
        XCTAssertTrue(js.contains("sessionFilters"))
        XCTAssertTrue(js.contains("sessionQuery(more)"))
        XCTAssertTrue(js.contains("Network unavailable"))
        XCTAssertTrue(js.contains("messageRequest"))
        XCTAssertTrue(js.contains("No sessions found"))
        // Ready/parsed metadata may label counts; only the admitted generation authorizes reads.
        XCTAssertTrue(js.contains("const generation = detail.transcriptGeneration;"))
        XCTAssertTrue(js.contains("await loadMessages(token, session.sessionId, generation, \"\");"))
        XCTAssertFalse(js.contains("const generation = detail.lastReady"))
        XCTAssertTrue(js.contains("TextEncoder"))
        XCTAssertTrue(js.contains("utf8Offset"))
        XCTAssertTrue(js.contains("isLastFragment"))
        XCTAssertTrue(js.contains("JSON.parse"))
        XCTAssertTrue(js.contains("toolCalls"))
        XCTAssertTrue(js.contains("payloadSHA256"))
        XCTAssertTrue(js.contains("more-messages"))
        XCTAssertTrue(js.contains("requestEpoch"))
        XCTAssertTrue(js.contains("openDetail(item.sessionId).catch"))
        XCTAssertTrue(js.contains("projectLabel"))
        XCTAssertTrue(js.contains("createElement(\"details\")"))
        XCTAssertTrue(js.contains("signed-out"))
        XCTAssertTrue(js.contains("showSessionList"))
        XCTAssertTrue(js.contains("Select a session"))
        XCTAssertTrue(js.contains("Session expired"))
        XCTAssertTrue(js.contains("expireSession"))
        XCTAssertFalse(js.contains("machine + \" \" + instance"))
    }

    func testJavaScriptExpiresCurrentAuthenticatedRead401WithoutTreatingLogin401AsExpiry() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("function expireSession()"))
        XCTAssertTrue(js.contains("Session expired"))
        XCTAssertTrue(js.contains("response.status === 401 && method === \"GET\""))
        XCTAssertTrue(js.contains("token === requestEpoch"))
        XCTAssertFalse(js.contains("method === \"POST\" && response.status === 401"))
    }

    func testSessionsQuerySendsSnapshotCursorPairOnlyWhenLoadingMore() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("if (more && sessionSnapshotId && sessionCursor)"))
        XCTAssertTrue(js.contains("params.set(\"snapshotId\", sessionSnapshotId)"))
        XCTAssertTrue(js.contains("params.set(\"cursor\", sessionCursor)"))
        XCTAssertTrue(js.contains("new URLSearchParams(more ? sessionFilters : \"\")"))
        XCTAssertTrue(js.contains("clearSessionPaging"))
        XCTAssertTrue(js.contains("async function loadOverview()"))
        XCTAssertTrue(js.contains("Overview is temporarily unavailable."))
        XCTAssertFalse(js.contains("if (overviewEpoch !== requestEpoch) return"))
        XCTAssertFalse(js.contains("let snapshotId"))
        XCTAssertFalse(js.contains("sessionSnapshotId = page.snapshotId || sessionSnapshotId"))
    }

    func testMessagesReassembleCanonicalJSONAndKeepPartialBuffer() async throws {
        let html = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(html.contains("id=\"more-messages\""))
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("acceptFragment"))
        XCTAssertTrue(js.contains("encoder.encode(fragment.payloadFragment"))
        XCTAssertTrue(js.contains("fragment.utf8Offset !== messageBuf.bytes"))
        XCTAssertTrue(js.contains("chunks"))
        let fragmentCode = js.components(separatedBy: "function acceptFragment").last?
            .components(separatedBy: "async function loadMessages").first ?? ""
        XCTAssertFalse(fragmentCode.isEmpty)
        XCTAssertFalse(fragmentCode.contains("Array.from("))
        XCTAssertTrue(js.contains("JSON.parse(text)"))
        XCTAssertTrue(js.contains("payload.content"))
        XCTAssertTrue(js.contains("className = \"body\""))
        XCTAssertTrue(js.contains("role === \"tool\"") || js.contains("role === \"system\""))
        XCTAssertTrue(js.contains("incomplete message"))
        XCTAssertFalse(js.contains("setText(line, (fragment.role || \"\") + \" \" + (fragment.payloadFragment"))
        XCTAssertTrue(js.contains("messageCursor"))
        XCTAssertTrue(js.contains("loadMessages(requestEpoch, messageSessionId, messageGeneration, messageCursor)"))
        XCTAssertTrue(js.contains("if (messageRequest && messageRequest.token === token"))
    }

    func testOpenDetailUsesEpochToDropStalePaints() async throws {
        let js = try await bodyText(try await UIHarness(configuration: configuration())
            .respond(request(path: "/web/app.js", headers: [("Host", "viewer.example")])))
        XCTAssertTrue(js.contains("if (token !== requestEpoch) return"))
        XCTAssertTrue(js.contains("bumpEpoch()"))
        XCTAssertTrue(js.contains("openDetail(item.sessionId).catch(function () {})"))
        XCTAssertTrue(js.contains("const generation = detail.transcriptGeneration;"))
        XCTAssertTrue(js.contains("value.generationId === detail.transcriptGeneration"))
        XCTAssertFalse(js.contains("const generation = detail.lastParsed"))
    }

    func testWrongHostIsForbiddenAndNonGetWebUIIsRejectedWithoutWeakeningCSP() async throws {
        let harness = try UIHarness(configuration: configuration())
        let forbidden = try await harness.respond(request(path: "/web", authority: "evil.example", headers: [("Host", "evil.example")]))
        XCTAssertEqual(forbidden.status, .forbidden)
        assertUnchangedCSP(forbidden)
        let posted = try await harness.respond(request(.post, path: "/web", headers: [("Host", "viewer.example")]))
        XCTAssertEqual(posted.status, .methodNotAllowed)
        assertUnchangedCSP(posted)
        let api = try await harness.respond(request(path: "/web/api/overview", headers: [
            ("Host", "viewer.example"), ("X-Engram-Web", "1"), ("Origin", "https://viewer.example"),
        ]))
        XCTAssertEqual(api.status, .unauthorized)
        assertUnchangedCSP(api)
    }

    private func configuration() throws -> EngramRemoteWebConfig {
        try EngramRemoteWebConfig(
            origin: origin, viewerCredential: viewer,
            serverBearerCredentials: ["test-v1-bearer"]
        )
    }

    private func request(
        _ method: HTTPRequest.Method = .get,
        path: String,
        scheme: String = "https",
        authority: String? = "viewer.example",
        headers: [(String, String)] = []
    ) -> Request {
        var fields = HTTPFields()
        for (name, value) in headers { fields.append(HTTPField(name: HTTPField.Name(name)!, value: value)) }
        return Request(
            head: HTTPRequest(method: method, scheme: scheme, authority: authority, path: path, headerFields: fields),
            body: RequestBody(buffer: ByteBuffer())
        )
    }

    private func assertUnchangedCSP(_ response: Response, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.headers[.cacheControl], "no-store", file: file, line: line)
        let csp = response.headers[HTTPField.Name("Content-Security-Policy")!] ?? ""
        for directive in ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'self'"] {
            XCTAssertTrue(csp.contains(directive), directive, file: file, line: line)
        }
        for forbidden in ["'unsafe-inline'", "'unsafe-eval'"] {
            XCTAssertFalse(csp.contains(forbidden), forbidden, file: file, line: line)
        }
    }

    private func containsInlineScript(_ html: String) -> Bool {
        html.range(of: #"<script(?![^>]*\bsrc=)[^>]*>"#, options: .regularExpression) != nil
    }

    private func containsInlineStyle(_ html: String) -> Bool {
        html.localizedCaseInsensitiveContains("<style") || html.localizedCaseInsensitiveContains(" style=")
    }
}

private struct UIHarness: Sendable {
    let boundary: WebRequestBoundary
    let sessions: WebAuthSessionStore

    init(configuration: EngramRemoteWebConfig) throws {
        boundary = WebRequestBoundary(configuration: configuration)
        sessions = WebAuthSessionStore(configuration: configuration)
    }

    func respond(_ request: Request) async throws -> Response {
        let router = Router(context: UITestContext.self)
        WebAuthRoutes.mount(on: router, boundary: boundary, sessions: sessions)
        WebUIRoutes.mount(on: router)
        let responder = router.buildResponder()
        return try await WebRequestBoundary.Middleware<UITestContext>(
            boundary: boundary, sessions: sessions
        ).handle(request, context: UITestContext(source: UITestSource())) { request, context in
            try await responder.respond(to: request, context: context)
        }
    }
}

private struct UITestSource: RequestContextSource {
    let logger = Logger(label: "web-ui-routes-test")
}

private struct UITestContext: RequestContext {
    typealias Source = UITestSource
    var coreContext: CoreRequestContextStorage
    init(source: Source) { coreContext = CoreRequestContextStorage(source: source) }
}

private actor UIBodyBytes {
    private var bytes: [UInt8] = []
    func append(_ buffer: ByteBuffer) { bytes.append(contentsOf: buffer.readableBytesView) }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

private struct UIBodyWriter: ResponseBodyWriter {
    let storage: UIBodyBytes
    mutating func write(_ buffer: ByteBuffer) async throws { await storage.append(buffer) }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

private func bodyText(_ response: Response) async throws -> String {
    let storage = UIBodyBytes()
    try await response.body.write(UIBodyWriter(storage: storage))
    return await storage.text
}
