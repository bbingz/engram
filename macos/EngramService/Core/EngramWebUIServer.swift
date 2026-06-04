import Foundation
import GRDB
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import EngramCoreRead

enum WebUIServerError: Error, CustomStringConvertible {
    case missingAuthToken
    case databaseClosed

    var description: String {
        switch self {
        case .missingAuthToken:
            return "Web UI requires a per-launch auth token; none was provisioned"
        case .databaseClosed:
            return "The Web UI database handle was released during shutdown."
        }
    }
}

final class EngramWebUIServer: @unchecked Sendable {
    private let databasePath: String
    private let host: String
    private let port: Int
    // Read-only DB handle: the Web UI never writes, and only EngramService's
    // ServiceWriterGate is allowed to open the DB read-write. Mirrors
    // MCPDatabase. Optional so teardown can release the GRDB pool
    // deterministically rather than relying on ARC timing.
    private var databaseQueue: DatabaseQueue?
    private let adapters: [SourceName: any SessionAdapter]
    private let authToken: String

    /// `authToken` is required (SEC-C1): every request must present it as a
    /// Bearer token (or `?token=` query). Constructing without one fails closed.
    init(databasePath: String, authToken: String?, host: String = "127.0.0.1", port: Int = 3457) throws {
        guard let authToken, !authToken.isEmpty else {
            throw WebUIServerError.missingAuthToken
        }
        self.databasePath = databasePath
        self.authToken = authToken
        self.host = host
        self.port = port
        var configuration = Configuration()
        configuration.readonly = true
        self.databaseQueue = try DatabaseQueue(path: databasePath, configuration: configuration)
        // First registration wins; a duplicate source must not crash the
        // service at init (same hardening as AdapterRegistry).
        var adapterMap: [SourceName: any SessionAdapter] = [:]
        for adapter in SessionAdapterFactory.defaultAdapters() where adapterMap[adapter.source] == nil {
            adapterMap[adapter.source] = adapter
        }
        self.adapters = adapterMap
    }

    func run() async throws {
        var logger = Logger(label: "engram.web")
        logger.logLevel = .warning

        let router = Router()
        router.get("/") { [self] request, _ in
            if let denied = guardRequest(request) { return denied }
            return try htmlResponse(indexPage())
        }
        router.get("/session/:id") { [self] request, context in
            if let denied = guardRequest(request) { return denied }
            guard let id = context.parameters.get("id")?.removingPercentEncoding else {
                return try htmlResponse(layout(title: "Not Found", body: "<p>Session not found.</p>"), status: .notFound)
            }
            let page = try await sessionPage(id: id, request: request)
            return try htmlResponse(page.html, status: page.status)
        }
        // /health is intentionally unauthenticated so the launcher's loopback
        // readiness probe can confirm the server is up. It exposes no data.
        router.get("/health") { [self] request, _ in
            if let denied = guardHostOnly(request) { return denied }
            return try textResponse("ok\n")
        }

        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname(host, port: port)),
            logger: logger
        )
        // Release the GRDB read pool deterministically when the HTTP server
        // stops (cancellation or error), instead of waiting for ARC to drop
        // the last reference. The defer runs on the same path the runner's
        // webTask cancellation triggers.
        defer { close() }
        try await app.run()
    }

    /// Tear down the read pool eagerly. Idempotent.
    func close() {
        databaseQueue = nil
    }

    #if DEBUG
    /// Test-only: whether the read pool has been released.
    var isClosedForTesting: Bool { databaseQueue == nil }

    /// Test-only: attempt a write to confirm the handle is opened read-only.
    /// Returns true iff the write was rejected (read-only enforced).
    func writeIsRejectedForTesting() throws -> Bool {
        do {
            try requireQueue().write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS web_write_probe(id INTEGER)")
            }
            return false
        } catch let dbError as DatabaseError where dbError.resultCode == .SQLITE_READONLY {
            return true
        }
    }
    #endif

    private func requireQueue() throws -> DatabaseQueue {
        guard let databaseQueue else {
            throw WebUIServerError.databaseClosed
        }
        return databaseQueue
    }

    // MARK: - Request gating (SEC-C1)

    /// Validates Host/Origin then the bearer token. Returns a denial `Response`
    /// when the request must be rejected, or nil when it may proceed.
    private func guardRequest(_ request: Request) -> Response? {
        if let hostDenied = guardHostOnly(request) { return hostDenied }
        guard isAuthorized(request) else {
            return Self.unauthorizedResponse()
        }
        return nil
    }

    /// Rejects requests whose Host header is not loopback, or whose Origin is
    /// cross-origin (DNS-rebinding / cross-site protection). Returns nil to allow.
    private func guardHostOnly(_ request: Request) -> Response? {
        if let hostName = HTTPField.Name("Host"),
           let hostHeader = request.headers[hostName],
           !Self.isLoopbackHost(hostHeader, expectedPort: port) {
            return Self.forbiddenResponse("Invalid Host header")
        }
        if let origin = request.headers[.origin], !origin.isEmpty {
            if !Self.isLoopbackOrigin(origin, expectedPort: port) {
                return Self.forbiddenResponse("Cross-origin request rejected")
            }
        }
        return nil
    }

    private func isAuthorized(_ request: Request) -> Bool {
        if let authHeader = request.headers[.authorization] {
            let prefix = "Bearer "
            if authHeader.hasPrefix(prefix) {
                let presented = String(authHeader.dropFirst(prefix.count))
                if Self.constantTimeEquals(presented, authToken) { return true }
            }
        }
        // Allow the token via query param for browser convenience over loopback.
        if let queryToken = request.uri.queryParameters["token"].map(String.init),
           Self.constantTimeEquals(queryToken, authToken) {
            return true
        }
        return false
    }

    static func isLoopbackHost(_ host: String, expectedPort: Int) -> Bool {
        if host == "::1" { return true }
        if host == "[::1]" { return true }
        if host.hasPrefix("[::1]:") {
            let rawPort = String(host.dropFirst("[::1]:".count))
            guard let port = Int(rawPort), String(port) == rawPort else { return false }
            return port == expectedPort
        }
        if host.hasPrefix("[::1]") {
            return false
        }

        let parts = host.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        let hostname = String(parts[0])
        guard hostname == "127.0.0.1" || hostname == "localhost" else { return false }
        if parts.count == 1 { return true }
        guard let port = Int(parts[1]), String(port) == String(parts[1]) else { return false }
        return port == expectedPort
    }

    static func isLoopbackOrigin(_ origin: String, expectedPort: Int) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else { return false }
        // A cross-port Origin (e.g. another local service) must be rejected too.
        if let port = url.port {
            return port == expectedPort
        }
        return true
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private static func unauthorizedResponse() -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        headers[.wwwAuthenticate] = "Bearer"
        let data = Data("401 Unauthorized\n".utf8)
        headers[.contentLength] = "\(data.count)"
        return Response(status: .unauthorized, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }

    private static func forbiddenResponse(_ message: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        let data = Data("403 Forbidden: \(message)\n".utf8)
        headers[.contentLength] = "\(data.count)"
        return Response(status: .forbidden, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
    }

    private func indexPage() throws -> String {
        let sessions = try readSessions(limit: 200)
        let rows: String = sessions.map { session -> String in
            """
            <a class="session" href="/session/\(urlPath(session.id))">
              <div class="title">\(escape(session.displayTitle))</div>
              <div class="meta">
                <span class="badge">\(escape(sourceLabel(session.source)))</span>
                \(escape(session.project ?? "(no project)"))
                <span>·</span>
                \(escape(String(session.startTime.prefix(16))))
                <span>·</span>
                \(session.messageCount) messages
              </div>
            </a>
            """
        }.joined(separator: "\n")

        return layout(
            title: "Engram Sessions",
            body: """
            <header>
              <h1>Sessions</h1>
              <p>\(sessions.count) recent sessions · \(escape(databasePath))</p>
            </header>
            <main class="list">
              \(rows.isEmpty ? "<p class=\"empty\">No indexed sessions found.</p>" : rows)
            </main>
            """
        )
    }

    private func sessionPage(id: String, request: Request) async throws -> (html: String, status: HTTPResponse.Status) {
        guard let session = try readSession(id: id) else {
            // Mirror the percent-decode-failure branch: a missing session is a
            // 404, not a 200 that happens to render not-found HTML.
            return (layout(title: "Not Found", body: "<p>Session not found.</p>"), .notFound)
        }

        // `offset`/`limit` are both raw message indices into the unfiltered
        // stream so Previous, Next, and the range label stay in ONE unit. A
        // page covers raw indices [offset, offset + limit); the displayable
        // subset is what actually renders. Previous = offset - limit and
        // Next = offset + (raw consumed) are exact inverses of this stride.
        let offset = max(0, Int(String(request.uri.queryParameters["offset"] ?? "0")) ?? 0)
        let limit = min(200, max(1, Int(String(request.uri.queryParameters["limit"] ?? "50")) ?? 50))
        let messageHTML: String
        let pager: String
        let status: HTTPResponse.Status
        do {
            let page = try await readMessages(for: session, offset: offset, limit: limit)
            messageHTML = page.messages.map { message in
                Self.renderMessageHTML(message, source: session.source)
            }.joined(separator: "\n")

            let previousOffset = max(0, offset - limit)
            let previousLink = offset > 0
                ? "<a class=\"button\" href=\"/session/\(urlPath(session.id))?offset=\(previousOffset)&limit=\(limit)\">Previous</a>"
                : ""
            let nextLink = page.hasMore
                ? "<a class=\"button\" href=\"/session/\(urlPath(session.id))?offset=\(page.nextOffset)&limit=\(limit)\">Next</a>"
                : ""
            pager = """
            <nav class="pager">
              \(previousLink)
              <span>Showing messages \(offset + 1)-\(page.nextOffset)</span>
              \(nextLink)
            </nav>
            """
            status = .ok
        } catch {
            messageHTML = Self.transcriptErrorHTML(error)
            pager = ""
            status = Self.transcriptErrorStatus(error)
        }

        return (layout(
            title: session.displayTitle,
            body: """
            <a class="back" href="/">← Sessions</a>
            <header class="sticky">
              <h1>\(escape(session.displayTitle))</h1>
              <p>
                <span class="badge">\(escape(sourceLabel(session.source)))</span>
                \(escape(session.project ?? "(no project)"))
                · \(escape(String(session.startTime.prefix(16))))
                · \(session.messageCount) messages
              </p>
            </header>
            \(pager)
            <main class="chat">
              \(messageHTML.isEmpty ? "<p class=\"empty\">No transcript messages found.</p>" : messageHTML)
            </main>
            \(pager)
            """
        ), status)
    }

    private func readSessions(limit: Int) throws -> [WebSession] {
        try requireQueue().read { db in
            try Row.fetchAll(db, sql: """
                SELECT
                  s.id, s.source, s.start_time, s.project, s.summary, s.generated_title,
                  s.custom_name, s.message_count,
                  COALESCE(NULLIF(ls.local_readable_path, ''), NULLIF(s.file_path, ''), s.source_locator) AS readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE COALESCE(ls.hidden_at, s.hidden_at) IS NULL
                ORDER BY COALESCE(s.end_time, s.start_time) DESC
                LIMIT ?
            """, arguments: [limit]).map(WebSession.init(row:))
        }
    }

    private func readSession(id: String) throws -> WebSession? {
        try requireQueue().read { db in
            try Row.fetchOne(db, sql: """
                SELECT
                  s.id, s.source, s.start_time, s.project, s.summary, s.generated_title,
                  s.custom_name, s.message_count,
                  COALESCE(NULLIF(ls.local_readable_path, ''), NULLIF(s.file_path, ''), s.source_locator) AS readable_path
                FROM sessions s
                LEFT JOIN session_local_state ls ON ls.session_id = s.id
                WHERE s.id = ?
            """, arguments: [id]).map(WebSession.init(row:))
        }
    }

    private func readMessages(
        for session: WebSession,
        offset: Int,
        limit: Int
    ) async throws -> (messages: [NormalizedMessage], hasMore: Bool, nextOffset: Int) {
        guard let source = SourceName(rawValue: session.source),
              let adapter = adapters[source],
              let locator = session.readablePath,
              !locator.isEmpty
        else {
            return ([], false, offset)
        }

        // Page stride is `limit` RAW messages: cap the materialized suffix at
        // `limit` (+1 probe) instead of passing `limit: nil`, which forced the
        // adapter to materialize the entire post-offset suffix every page.
        let stream = try await adapter.streamMessages(
            locator: locator,
            options: StreamMessagesOptions(offset: offset, limit: limit + 1)
        )
        var raw: [NormalizedMessage] = []
        for try await message in stream {
            raw.append(message)
            if raw.count > limit { break }
        }
        return Self.windowDisplayable(raw, source: session.source, offset: offset, limit: limit)
    }

    /// Pure windowing/filtering over an already-offset raw message slice.
    /// `raw` is at most `limit + 1` messages (the +1 is a look-ahead probe for
    /// `hasMore`). Returns the displayable subset within the raw window plus a
    /// `nextOffset` in the same RAW message-index unit as `offset`, so the
    /// pager's Previous (`offset - limit`) and Next (`nextOffset`) stay
    /// consistent. Static so it is unit-testable without disk/adapters.
    static func windowDisplayable(
        _ raw: [NormalizedMessage],
        source: String,
        offset: Int,
        limit: Int
    ) -> (messages: [NormalizedMessage], hasMore: Bool, nextOffset: Int) {
        let hasMore = raw.count > limit
        let window = hasMore ? Array(raw.prefix(limit)) : raw
        // Filter on the ORIGINAL content (classification is content-sensitive),
        // then redact the survivors before they reach the rendered page.
        let messages = window
            .filter { Self.shouldDisplayTranscriptMessage($0, source: source) }
            .map { message -> NormalizedMessage in
                var redacted = message
                // SEC-C1: redact secrets, matching the export path's behavior.
                redacted.content = Self.redactSensitiveContent(message.content)
                return redacted
            }
        return (messages, hasMore, offset + window.count)
    }

    static func redactSensitiveContent(_ content: String) -> String {
        TranscriptExportService.redactSensitiveContent(content)
    }

    static func shouldDisplayTranscriptMessage(_ message: NormalizedMessage, source: String) -> Bool {
        guard message.role == .user || message.role == .assistant else { return false }
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if message.role == .user, WebSystemMessageCategory(content: message.content, source: source) != nil {
            return false
        }
        return true
    }

    static func renderMessageHTML(_ message: NormalizedMessage, source: String) -> String {
        if message.role == .user, let category = WebSystemMessageCategory(content: message.content, source: source) {
            return """
            <article class="message system \(category.cssClass)">
              <div class="role">\(category.label)</div>
              <pre>\(escape(message.content))</pre>
            </article>
            """
        }

        let role = message.role.rawValue
        return """
        <article class="message \(escape(role))">
          <div class="role">\(role == "user" ? "You" : escape(sourceLabel(source)))</div>
          <pre>\(escape(message.content))</pre>
        </article>
        """
    }

    static func transcriptErrorHTML(_ error: Error) -> String {
        """
        <article class="message system transcript-error">
          <div class="role">Transcript unavailable</div>
          <pre>\(escape(transcriptErrorMessage(error)))</pre>
        </article>
        """
    }

    static func transcriptErrorStatus(_ error: Error) -> HTTPResponse.Status {
        guard let failure = error as? ParserFailure else {
            return .internalServerError
        }
        switch failure {
        case .fileMissing, .fileModifiedDuringParse:
            return .notFound
        case .fileTooLarge, .messageLimitExceeded:
            return .init(code: 413, reasonPhrase: "Payload Too Large")
        default:
            return .internalServerError
        }
    }

    private static func transcriptErrorMessage(_ error: Error) -> String {
        guard let failure = error as? ParserFailure else {
            return error.localizedDescription
        }

        switch failure {
        case .messageLimitExceeded:
            return "The transcript hit the adapter message limit. Re-index or open a smaller transcript window after indexing catches up."
        case .fileTooLarge:
            return "The transcript file is too large for the current parser limit."
        case .fileMissing:
            return "The transcript file is missing from disk."
        case .fileModifiedDuringParse:
            return "The transcript changed while Engram was reading it. Refresh the page to retry."
        default:
            return "The transcript could not be parsed: \(failure.rawValue)."
        }
    }
}

private enum WebSystemMessageCategory {
    case systemPrompt
    case agentComm

    init?(content: String, source: String) {
        switch SystemMessageClassifier.classify(content: content, source: source) {
        case .systemPrompt:
            self = .systemPrompt
        case .agentComm:
            self = .agentComm
        case .none:
            return nil
        }
    }

    var label: String {
        switch self {
        case .systemPrompt: return "System Prompt"
        case .agentComm: return "Agent Communication"
        }
    }

    var cssClass: String {
        switch self {
        case .systemPrompt: return "system-prompt"
        case .agentComm: return "agent-comm"
        }
    }
}

private struct WebSession {
    let id: String
    let source: String
    let startTime: String
    let project: String?
    let summary: String?
    let generatedTitle: String?
    let customName: String?
    let messageCount: Int
    let readablePath: String?

    init(row: Row) {
        id = row["id"]
        source = row["source"]
        startTime = row["start_time"]
        project = row["project"]
        summary = row["summary"]
        generatedTitle = row["generated_title"]
        customName = row["custom_name"]
        messageCount = row["message_count"]
        readablePath = row["readable_path"]
    }

    var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        if let generatedTitle, !generatedTitle.isEmpty { return generatedTitle }
        if let summary, !summary.isEmpty { return summary }
        return id
    }
}

private func htmlResponse(_ html: String, status: HTTPResponse.Status = .ok) throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "text/html; charset=utf-8"
    headers[.contentSecurityPolicy] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    let data = Data(html.utf8)
    headers[.contentLength] = "\(data.count)"
    return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
}

private func textResponse(_ text: String, status: HTTPResponse.Status = .ok) throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "text/plain; charset=utf-8"
    let data = Data(text.utf8)
    headers[.contentLength] = "\(data.count)"
    return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(data: data)))
}

private func layout(title: String, body: String) -> String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(escape(title)) - Engram</title>
      <style>
        :root { color-scheme: light dark; --bg:#0f172a; --panel:#172033; --text:#f8fafc; --muted:#94a3b8; --line:#334155; --accent:#22c55e; }
        @media (prefers-color-scheme: light) { :root { --bg:#f8fafc; --panel:#ffffff; --text:#0f172a; --muted:#64748b; --line:#e2e8f0; --accent:#16a34a; } }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--text); font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
        a { color:inherit; text-decoration:none; }
        header, .list, .chat, .pager, .back { max-width:960px; margin:0 auto; }
        header { padding:22px 20px 14px; }
        h1 { margin:0 0 4px; font-size:22px; line-height:1.25; }
        p { margin:0; color:var(--muted); }
        .list { padding:0 20px 40px; }
        .session { display:block; border:1px solid var(--line); border-radius:8px; padding:12px 14px; margin:8px 0; background:color-mix(in srgb, var(--panel) 88%, transparent); }
        .session:hover { border-color:var(--accent); }
        .title { font-weight:650; margin-bottom:4px; }
        .meta { color:var(--muted); display:flex; gap:8px; flex-wrap:wrap; font-size:12px; }
        .badge { display:inline-block; color:white; background:var(--accent); border-radius:4px; padding:1px 6px; font-size:12px; font-weight:650; }
        .back { display:block; padding:18px 20px 0; color:var(--muted); }
        .sticky { position:sticky; top:0; background:var(--bg); border-bottom:1px solid var(--line); z-index:2; }
        .chat { padding:8px 20px 24px; display:flex; flex-direction:column; gap:10px; }
        .message { max-width:86%; }
        .message.user { align-self:flex-end; }
        .message.assistant, .message.tool, .message.system { align-self:flex-start; }
        .role { color:var(--muted); font-size:12px; font-weight:700; margin:0 8px 3px; }
        .user .role { text-align:right; }
        pre { white-space:pre-wrap; overflow-wrap:anywhere; margin:0; padding:10px 12px; border:1px solid var(--line); border-radius:8px; background:var(--panel); font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace; }
        .user pre { border-color:color-mix(in srgb, var(--accent) 45%, var(--line)); background:color-mix(in srgb, var(--accent) 10%, var(--panel)); }
        .pager { padding:10px 20px; display:flex; justify-content:center; gap:12px; align-items:center; color:var(--muted); }
        .button { border:1px solid var(--line); border-radius:6px; padding:4px 10px; color:var(--text); }
        .button:hover { border-color:var(--accent); color:var(--accent); }
        .empty { max-width:960px; margin:40px auto; padding:0 20px; color:var(--muted); }
      </style>
    </head>
    <body>\(body)</body>
    </html>
    """
}

private func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func urlPath(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}

private func sourceLabel(_ source: String) -> String {
    switch source {
    case "claude-code": return "Claude"
    case "gemini-cli": return "Gemini"
    case "opencode": return "OpenCode"
    case "iflow": return "iFlow"
    case "qoder": return "Qoder"
    case "commandcode": return "Command Code"
    case "vscode": return "VS Code"
    default: return source
    }
}
