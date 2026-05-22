import Foundation
import GRDB
import Hummingbird
import Logging
import NIOCore
import EngramCoreRead

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

    init(databasePath: String, host: String = "127.0.0.1", port: Int = 3457) throws {
        self.databasePath = databasePath
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
        router.get("/") { [self] _, _ in
            try htmlResponse(indexPage())
        }
        router.get("/session/:id") { [self] request, context in
            guard let id = context.parameters.get("id")?.removingPercentEncoding else {
                return try htmlResponse(layout(title: "Not Found", body: "<p>Session not found.</p>"), status: .notFound)
            }
            return try await htmlResponse(sessionPage(id: id, request: request))
        }
        router.get("/health") { _, _ in
            try textResponse("ok\n")
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

    private func sessionPage(id: String, request: Request) async throws -> String {
        guard let session = try readSession(id: id) else {
            return layout(title: "Not Found", body: "<p>Session not found.</p>")
        }

        let offset = max(0, Int(String(request.uri.queryParameters["offset"] ?? "0")) ?? 0)
        let limit = min(200, max(1, Int(String(request.uri.queryParameters["limit"] ?? "50")) ?? 50))
        let messageHTML: String
        let pager: String
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
              <span>Showing \(offset + 1)-\(offset + page.messages.count)</span>
              \(nextLink)
            </nav>
            """
        } catch {
            messageHTML = Self.transcriptErrorHTML(error)
            pager = ""
        }

        return layout(
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
        )
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

        let stream = try await adapter.streamMessages(
            locator: locator,
            options: StreamMessagesOptions(offset: offset, limit: limit + 1)
        )
        var messages: [NormalizedMessage] = []
        for try await message in stream where Self.shouldDisplayTranscriptMessage(message) {
            messages.append(message)
        }
        let hasMore = messages.count > limit
        if hasMore {
            messages.removeLast(messages.count - limit)
        }
        return (messages, hasMore, offset + messages.count)
    }

    static func shouldDisplayTranscriptMessage(_ message: NormalizedMessage) -> Bool {
        guard message.role == .user || message.role == .assistant else { return false }
        return !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

private enum WebUIServerError: LocalizedError {
    case databaseClosed

    var errorDescription: String? {
        switch self {
        case .databaseClosed:
            return "The Web UI database handle was released during shutdown."
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
