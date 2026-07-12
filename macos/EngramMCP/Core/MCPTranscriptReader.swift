import Darwin
import Foundation

struct MCPTranscriptMessage {
    let role: String
    let content: String
    let timestamp: String?
}

struct MCPTranscriptPage {
    let messages: [MCPTranscriptMessage]
    let totalPages: Int
    let currentPage: Int
    let pageSize: Int
    let totalKnownComplete: Bool
    let truncatedAt: Int?
    let responseBudgetTruncated: Bool

    var truncated: Bool { truncatedAt != nil || !totalKnownComplete }
}

enum MCPTranscriptReadError: LocalizedError {
    case definitiveLocalExactSourceUnavailable(path: String, code: Int32)
    case unsafeLocalExactSource(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .definitiveLocalExactSourceUnavailable(_, let code):
            return "Exact transcript source is unavailable (errno \(code))"
        case .unsafeLocalExactSource(_, let reason):
            return "Exact transcript source is unsafe (\(reason))"
        }
    }
}

private struct MCPTranscriptPageBuilder {
    private static let maxMessageContentCharacters = 8_192

    private let currentPage: Int
    private let pageSize: Int
    private let offset: Int
    private var messages: [MCPTranscriptMessage] = []
    private var totalMessages = 0

    init(currentPage: Int, pageSize: Int) {
        self.currentPage = currentPage
        self.pageSize = pageSize
        self.offset = (currentPage - 1) * pageSize
    }

    mutating func append(_ message: MCPTranscriptMessage) {
        if totalMessages >= offset && messages.count < pageSize {
            messages.append(Self.capped(message))
        }
        totalMessages += 1
    }

    // Exact count of visible messages appended so far. After a full scan this is
    // the transcript's true visible-message total (the basis for `totalPages`).
    var visibleMessageCount: Int { totalMessages }

    func build(totalKnownComplete: Bool = true, truncatedAt: Int? = nil) -> MCPTranscriptPage {
        MCPTranscriptPage(
            messages: messages,
            totalPages: max(1, Int(ceil(Double(totalMessages) / Double(pageSize)))),
            currentPage: currentPage,
            pageSize: pageSize,
            totalKnownComplete: totalKnownComplete,
            truncatedAt: truncatedAt,
            responseBudgetTruncated: false
        )
    }

    private static func capped(_ message: MCPTranscriptMessage) -> MCPTranscriptMessage {
        guard message.content.count > maxMessageContentCharacters else {
            return message
        }
        let omitted = message.content.count - maxMessageContentCharacters
        return MCPTranscriptMessage(
            role: message.role,
            content: String(message.content.prefix(maxMessageContentCharacters))
                + "\n[truncated \(omitted) characters]",
            timestamp: message.timestamp
        )
    }
}

// Process-lifetime cache of a transcript's exact visible-message total, keyed by
// the file's identity VALUES (locator + size + mtime), never a `hashValue`. A
// change to size or mtime yields a different key, so a rewritten transcript is
// never served a stale total. The first `get_session` request for a transcript
// counts the visible total to EOF and stores it here; later pages of the same
// transcript read it back and skip the recount.
private struct TranscriptVisibleCountKey: Hashable {
    let locator: String
    let source: String
    let sizeBytes: Int64
    let mtimeNanos: Int64
}

private final class TranscriptVisibleCountCache: @unchecked Sendable {
    static let shared = TranscriptVisibleCountCache()
    struct Value {
        let visibleTotal: Int
        let totalKnownComplete: Bool
        let truncatedAt: Int?
    }

    private let lock = NSLock()
    private var storage: [TranscriptVisibleCountKey: Value] = [:]

    func value(for key: TranscriptVisibleCountKey) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: Value, for key: TranscriptVisibleCountKey) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

enum MCPTranscriptReader {
    private static let maxPage = 100_000
    private static let maxPageSize = 500

    static func readMessagePage(
        filePath: String,
        source: String,
        page: Int,
        pageSize: Int,
        roles: [String]?
    ) async throws -> MCPTranscriptPage {
        try Task.checkCancellation()
        try validateExactLocalSource(filePath: filePath, source: source)
        let currentPage = max(1, min(page, maxPage))
        let effectivePageSize = max(1, min(pageSize, maxPageSize))
        let roleFilter = normalizeRoles(roles)
        var builder = MCPTranscriptPageBuilder(
            currentPage: currentPage,
            pageSize: effectivePageSize
        )

        let guardBeforeAdapter = requiresFullJSONTranscriptGuard(source: source)
        if guardBeforeAdapter {
            try TranscriptSizeGuard.validateFullJSONTranscript(filePath: filePath, source: source)
        }

        if let adapterPage = try await readPageWithAdapterRegistry(
            filePath: filePath,
            source: source,
            currentPage: currentPage,
            pageSize: effectivePageSize,
            roles: roleFilter
        ) {
            return adapterPage
        }

        if !guardBeforeAdapter {
            try TranscriptSizeGuard.validateFullJSONTranscript(filePath: filePath, source: source)
        }

        switch source {
        case "claude-code", "qwen", "qoder", "iflow", "lobsterai", "minimax":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseTypeMessageObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "kimi", "antigravity", "windsurf":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseRoleDirectObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "commandcode":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseCommandCodeObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "codex":
            collectJSONLines(filePath: filePath) { obj in
                appendIfVisible(parseCodexObject(obj), to: &builder, source: source, roles: roleFilter)
            }
        case "gemini-cli":
            for message in parseGeminiFormat(filePath: filePath) {
                appendIfVisible(message, to: &builder, source: source, roles: roleFilter)
            }
        default:
            break
        }

        return builder.build()
    }

    static func readMessages(filePath: String, source: String) async throws -> [MCPTranscriptMessage] {
        let guardBeforeAdapter = requiresFullJSONTranscriptGuard(source: source)
        if guardBeforeAdapter {
            try TranscriptSizeGuard.validateFullJSONTranscript(filePath: filePath, source: source)
        }

        if let adapterMessages = try await readWithAdapterRegistry(filePath: filePath, source: source) {
            return adapterMessages
        }

        if !guardBeforeAdapter {
            try TranscriptSizeGuard.validateFullJSONTranscript(filePath: filePath, source: source)
        }

        switch source {
        case "claude-code", "qwen", "qoder", "iflow", "lobsterai", "minimax":
            return visibleMessages(parseTypeMessageFormat(filePath: filePath), source: source)
        case "kimi", "antigravity", "windsurf":
            return visibleMessages(parseRoleDirectFormat(filePath: filePath), source: source)
        case "commandcode":
            return visibleMessages(parseCommandCodeFormat(filePath: filePath), source: source)
        case "codex":
            return visibleMessages(parseCodexFormat(filePath: filePath), source: source)
        case "gemini-cli":
            return visibleMessages(parseGeminiFormat(filePath: filePath), source: source)
        default:
            return []
        }
    }

    private static func requiresFullJSONTranscriptGuard(source: String) -> Bool {
        switch source {
        case "gemini-cli", "cline", "cursor", "vscode":
            return true
        default:
            return false
        }
    }

    private static func normalizeRoles(_ roles: [String]?) -> [String]? {
        let roleFilter = roles?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (roleFilter?.isEmpty == false) ? roleFilter : nil
    }

    private static func appendIfVisible(
        _ message: MCPTranscriptMessage?,
        to builder: inout MCPTranscriptPageBuilder,
        source: String,
        roles: [String]?
    ) {
        guard let message else { return }
        guard roles == nil || roles!.contains(message.role) else { return }
        guard isDefaultVisibleMessage(role: message.role, content: message.content, source: source) else { return }
        builder.append(message)
    }

    // Async by design: the adapter stream is async, so we await it directly
    // instead of bridging back to sync with a DispatchSemaphore. Blocking a
    // cooperative-pool thread on a semaphore can starve/deadlock the pool when
    // several reads run concurrently.
    private static func readWithAdapterRegistry(filePath: String, source: String) async throws -> [MCPTranscriptMessage]? {
        guard let sourceName = adapterSourceName(for: source),
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName })
        else {
            return nil
        }

        do {
            let result = try await adapter.streamMessagesWithMetadata(
                locator: filePath,
                options: StreamMessagesOptions()
            )
            let stream = result.messages
            var messages: [MCPTranscriptMessage] = []
            for try await message in stream {
                guard isDefaultVisibleMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    source: source
                ) else { continue }
                messages.append(
                    MCPTranscriptMessage(
                        role: message.role.rawValue,
                        content: message.content,
                        timestamp: message.timestamp
                    )
                )
            }
            return messages
        } catch let failure as ParserFailure where isFallbackUnsafeParserFailure(failure) {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ParserFailure where failure == .fileMissing {
            try validateExactLocalSource(filePath: filePath, source: source)
            return nil
        } catch let error as MCPTranscriptReadError {
            throw error
        } catch {
            return nil
        }
    }

    private static func readPageWithAdapterRegistry(
        filePath: String,
        source: String,
        currentPage: Int,
        pageSize: Int,
        roles: [String]?
    ) async throws -> MCPTranscriptPage? {
        guard let sourceName = adapterSourceName(for: source),
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName })
        else {
            return nil
        }

        do {
            // Default (no role filter) fast path. Preserves origin/main's exact
            // pagination contract — dense VISIBLE-unit pages (offset counted in
            // visible messages, up to pageSize visible per page) and a `totalPages`
            // that is the true visible page count — for ALL transcripts, including
            // those whose adapter stream carries hidden tool_result /
            // system-injection records. `offset`/`limit` on the adapter index the
            // RAW (post-transform) stream, so they can NEVER stand in for a visible
            // page boundary; instead we filter to visible in this layer.
            //
            // The perf win comes from a process-lifetime cache of the exact visible
            // total. The FIRST request for a transcript scans to EOF (bounded
            // memory: the builder keeps only the page window, not an array of the
            // whole transcript) to serve the page AND record the total. LATER pages
            // read the cached total and serve their window via early-stopped
            // streaming — O(offset + limit) raw records, stopping as soon as the
            // page window is filled, so page 1 of a 39k-message transcript never
            // parses 39k records.
            if roles == nil, let identity = transcriptIdentity(filePath) {
                let key = TranscriptVisibleCountKey(
                    locator: filePath,
                    source: source,
                    sizeBytes: identity.size,
                    mtimeNanos: identity.mtimeNanos
                )
                if let cachedTotal = TranscriptVisibleCountCache.shared.value(for: key) {
                    let windowMessages = try await collectVisiblePageWindow(
                        adapter: adapter,
                        filePath: filePath,
                        source: source,
                        currentPage: currentPage,
                        pageSize: pageSize,
                        maxRawMessages: cachedTotal.truncatedAt
                    )
                    return MCPTranscriptPage(
                        messages: windowMessages,
                        totalPages: max(1, Int(ceil(Double(cachedTotal.visibleTotal) / Double(pageSize)))),
                        currentPage: currentPage,
                        pageSize: pageSize,
                        totalKnownComplete: cachedTotal.totalKnownComplete,
                        truncatedAt: cachedTotal.truncatedAt,
                        responseBudgetTruncated: false
                    )
                }

                let page = try await fullScanPage(
                    adapter: adapter,
                    filePath: filePath,
                    source: source,
                    currentPage: currentPage,
                    pageSize: pageSize,
                    roles: nil
                )
                TranscriptVisibleCountCache.shared.set(
                    TranscriptVisibleCountCache.Value(
                        visibleTotal: page.visibleTotal,
                        totalKnownComplete: page.page.totalKnownComplete,
                        truncatedAt: page.page.truncatedAt
                    ),
                    for: key
                )
                return page.page
            }

            // Role-filtered request (or a transcript we can't stat): the visible
            // total depends on the role filter, so it is not cacheable against the
            // unfiltered key. Fall back to the exact dense full scan.
            return try await fullScanPage(
                adapter: adapter,
                filePath: filePath,
                source: source,
                currentPage: currentPage,
                pageSize: pageSize,
                roles: roles
            ).page
        } catch let failure as ParserFailure where isFallbackUnsafeParserFailure(failure) {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ParserFailure where failure == .fileMissing {
            try validateExactLocalSource(filePath: filePath, source: source)
            return nil
        } catch let error as MCPTranscriptReadError {
            throw error
        } catch {
            return nil
        }
    }

    private static func validateExactLocalSource(filePath: String, source: String) throws {
        guard !isVirtualLocator(filePath),
              let sourceName = adapterSourceName(for: source),
              let adapter = SessionAdapterFactory.defaultAdapters().first(where: { $0.source == sourceName }),
              adapter is any ExactArchiveSourceAdapter
        else {
            return
        }

        var info = stat()
        guard lstat(filePath, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw MCPTranscriptReadError.definitiveLocalExactSourceUnavailable(
                    path: filePath,
                    code: code
                )
            }
            throw MCPTranscriptReadError.unsafeLocalExactSource(
                path: filePath,
                reason: "lstat failed with errno \(code)"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MCPTranscriptReadError.unsafeLocalExactSource(
                path: filePath,
                reason: "locator is not a regular file"
            )
        }
    }

    private static func isVirtualLocator(_ locator: String) -> Bool {
        locator.contains("::") || locator.contains("?composer=")
    }

    // Full visible scan of the adapter stream: dense visible-unit page window plus
    // the exact visible-message total. Memory stays O(pageSize) at this layer — the
    // builder retains only the requested window, never the whole transcript.
    private static func fullScanPage(
        adapter: any SessionAdapter,
        filePath: String,
        source: String,
        currentPage: Int,
        pageSize: Int,
        roles: [String]?
    ) async throws -> (page: MCPTranscriptPage, visibleTotal: Int) {
        let result = try await adapter.streamMessagesWithMetadata(
            locator: filePath,
            options: StreamMessagesOptions()
        )
        let stream = result.messages
        var builder = MCPTranscriptPageBuilder(
            currentPage: currentPage,
            pageSize: pageSize
        )
        for try await message in stream {
            appendIfVisible(
                MCPTranscriptMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp
                ),
                to: &builder,
                source: source,
                roles: roles
            )
        }
        return (
            builder.build(
                totalKnownComplete: result.totalKnownComplete,
                truncatedAt: result.truncatedAt
            ),
            builder.visibleMessageCount
        )
    }

    // Collect only the visible window `[(currentPage-1)*pageSize, currentPage*pageSize)`
    // by streaming the adapter's RAW records in file order and filtering to visible
    // incrementally, stopping as soon as the window is complete. `offset`/`limit`
    // count RAW records, so we widen the raw request (doubling from the visible
    // lower bound) until enough visible messages appear or the stream reaches EOF —
    // total work is O(raw prefix), never the whole file for a shallow page.
    private static func collectVisiblePageWindow(
        adapter: any SessionAdapter,
        filePath: String,
        source: String,
        currentPage: Int,
        pageSize: Int,
        maxRawMessages: Int?
    ) async throws -> [MCPTranscriptMessage] {
        let visibleStart = (currentPage - 1) * pageSize
        if let maxRawMessages, visibleStart >= maxRawMessages {
            return []
        }
        let visibleNeeded = currentPage * pageSize
        var rawLimit = max(visibleNeeded, pageSize)
        if let maxRawMessages {
            rawLimit = min(rawLimit, maxRawMessages)
        }
        while true {
            let stream = try await adapter.streamMessages(
                locator: filePath,
                options: StreamMessagesOptions(offset: 0, limit: rawLimit)
            )
            var builder = MCPTranscriptPageBuilder(currentPage: currentPage, pageSize: pageSize)
            var rawCount = 0
            var visibleCount = 0
            for try await message in stream {
                rawCount += 1
                let transcriptMessage = MCPTranscriptMessage(
                    role: message.role.rawValue,
                    content: message.content,
                    timestamp: message.timestamp
                )
                if isDefaultVisibleMessage(
                    role: transcriptMessage.role,
                    content: transcriptMessage.content,
                    source: source
                ) {
                    visibleCount += 1
                    builder.append(transcriptMessage)
                }
                if visibleCount >= visibleNeeded { break }
            }
            // Enough visible to fill the window, or the adapter yielded fewer raw
            // records than requested (EOF): the window is as complete as it can be.
            if visibleCount >= visibleNeeded || rawCount < rawLimit {
                return builder.build().messages
            }
            if let maxRawMessages {
                let nextLimit = min(rawLimit * 2, maxRawMessages)
                if nextLimit == rawLimit {
                    return builder.build().messages
                }
                rawLimit = nextLimit
            } else {
                rawLimit *= 2
            }
        }
    }

    private static func transcriptIdentity(_ path: String) -> (size: Int64, mtimeNanos: Int64)? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = info.st_mtimespec
        return (Int64(info.st_size), Int64(mtime.tv_sec) &* 1_000_000_000 &+ Int64(mtime.tv_nsec))
    }

    private static func isFallbackUnsafeParserFailure(_ failure: ParserFailure) -> Bool {
        switch failure {
        case .fileTooLarge, .messageLimitExceeded, .lineTooLarge, .invalidUtf8, .deeplyNestedRecord:
            return true
        default:
            return false
        }
    }

    private static func adapterSourceName(for source: String) -> SourceName? {
        if source == "antigravity-legacy" { return .antigravity }
        return SourceName(rawValue: source)
    }

    private static func visibleMessages(
        _ messages: [MCPTranscriptMessage],
        source: String
    ) -> [MCPTranscriptMessage] {
        messages.filter { message in
            isDefaultVisibleMessage(role: message.role, content: message.content, source: source)
        }
    }

    private static func isDefaultVisibleMessage(role: String, content: String, source: String) -> Bool {
        guard role == "user" || role == "assistant" else { return false }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if role == "user" {
            return SystemMessageClassifier.classify(content: content, source: source) == .none
        }
        return true
    }

    private static func parseTypeMessageFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseTypeMessageObject)
    }

    private static func parseRoleDirectFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseRoleDirectObject)
    }

    private static func parseCodexFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseCodexObject)
    }

    private static func parseGeminiFormat(filePath: String) -> [MCPTranscriptMessage] {
        guard
            let data = FileManager.default.contents(atPath: filePath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = root["messages"] as? [[String: Any]]
        else {
            return []
        }

        return messages.compactMap { message in
            guard let type = message["type"] as? String else { return nil }
            let role: String
            switch type {
            case "user":
                role = "user"
            case "gemini", "model":
                role = "assistant"
            default:
                return nil
            }

            let content: String
            if let text = message["content"] as? String {
                content = text
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                return nil
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return MCPTranscriptMessage(
                role: role,
                content: content,
                timestamp: message["timestamp"] as? String
            )
        }
    }

    private static func parseCommandCodeFormat(filePath: String) -> [MCPTranscriptMessage] {
        readJSONLines(filePath: filePath).compactMap(parseCommandCodeObject)
    }

    private static func parseTypeMessageObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let type = obj["type"] as? String,
            type == "user" || type == "assistant",
            let message = obj["message"] as? [String: Any]
        else {
            return nil
        }
        var content = extractMessageContent(message["content"])
        if content.isEmpty {
            content = extractPartsContent(message["parts"])
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MCPTranscriptMessage(
            role: type,
            content: content,
            timestamp: obj["timestamp"] as? String
        )
    }

    private static func parseRoleDirectObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let role = obj["role"] as? String,
            (role == "user" || role == "assistant"),
            let content = obj["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let timestamp = (obj["timestamp"] as? String)
            ?? (obj["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0).ISO8601Format() }
            ?? (obj["timestamp"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() }

        return MCPTranscriptMessage(role: role, content: content, timestamp: timestamp)
    }

    private static func parseCodexObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            obj["type"] as? String == "response_item",
            let payload = obj["payload"] as? [String: Any],
            payload["type"] as? String == "message",
            let role = payload["role"] as? String,
            (role == "user" || role == "assistant")
        else {
            return nil
        }

        let content = extractTextArray(payload["content"])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return MCPTranscriptMessage(
            role: role,
            content: content,
            timestamp: obj["timestamp"] as? String
        )
    }

    private static func parseCommandCodeObject(_ obj: [String: Any]) -> MCPTranscriptMessage? {
        guard
            let role = obj["role"] as? String,
            role == "user" || role == "assistant"
        else {
            return nil
        }
        let content = extractCommandCodeContent(obj["content"])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let timestamp = (obj["timestamp"] as? String)
            ?? ((obj["metadata"] as? [String: Any])?["timestamp"] as? String)
        return MCPTranscriptMessage(role: role, content: content, timestamp: timestamp)
    }

    private static func readJSONLines(filePath: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }

    private static func collectJSONLines(
        filePath: String,
        _ consume: ([String: Any]) -> Void
    ) {
        guard let file = fopen(filePath, "r") else { return }
        defer { fclose(file) }

        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer {
            if let line {
                free(line)
            }
        }

        while true {
            let count = getline(&line, &capacity, file)
            if count <= 0 { break }
            guard let line else { continue }
            let data = Data(bytes: line, count: count)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            consume(obj)
        }
    }

    private static func extractMessageContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let items = content as? [[String: Any]] else { return "" }
        var textParts: [String] = []
        var thinkingFallback: String?
        for item in items {
            if item["type"] as? String == "text", let text = item["text"] as? String {
                textParts.append(text)
            } else if item["type"] as? String == "thinking",
                      let thinking = item["thinking"] as? String,
                      thinkingFallback == nil {
                thinkingFallback = thinking
            }
        }
        if !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }
        return thinkingFallback ?? ""
    }

    private static func extractPartsContent(_ parts: Any?) -> String {
        guard let items = parts as? [[String: Any]] else { return "" }
        return items.compactMap { $0["text"] as? String }.first ?? ""
    }

    private static func extractTextArray(_ content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        for item in items {
            if let text = item["text"] as? String {
                return text
            }
            if let inputText = item["input_text"] as? String {
                return inputText
            }
        }
        return ""
    }

    private static func extractCommandCodeContent(_ content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        guard let items = content as? [[String: Any]] else { return "" }
        return items.compactMap { item in
            switch item["type"] as? String {
            case "text":
                return item["text"] as? String
            case "tool-call":
                return (item["toolName"] as? String).map { "`\($0)`" }
            case "tool-result":
                if let output = item["output"] as? String {
                    return output
                }
                if let output = item["output"],
                   JSONSerialization.isValidJSONObject(output),
                   let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes]),
                   let text = String(data: data, encoding: .utf8) {
                    return String(text.prefix(2_000))
                }
                return nil
            default:
                return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }
}
