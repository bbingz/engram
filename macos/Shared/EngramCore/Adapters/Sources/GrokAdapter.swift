import Foundation

final class GrokAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .grok

    private let sessionsRoot: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot, isDirectory: true)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        sessionTranscriptLocators(under: sessionsRoot)
    }

    func listSessionLocators(modifiedSince: Date, fileManager: FileManager) async throws -> [String] {
        try sessionTranscriptLocators(under: sessionsRoot).filter { locator in
            guard let modifiedAt = try fileManager.attributesOfItem(atPath: locator)[.modificationDate] as? Date else {
                return false
            }
            return modifiedAt >= modifiedSince
        }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        switch try Self.scanSession(
            transcriptLocator: Self.primaryTranscriptURL(
                in: Self.sessionDirectory(for: locator), locator: locator
            ).path,
            sessionDir: Self.sessionDirectory(for: locator),
            infoFilePath: locator,
            allowedMetadata: nil,
            limits: limits,
            strictRecords: false
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let captured): return .success(captured.scan.info)
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        switch try Self.scanSession(
            transcriptLocator: Self.primaryTranscriptURL(
                in: Self.sessionDirectory(for: locator), locator: locator
            ).path,
            sessionDir: Self.sessionDirectory(for: locator),
            infoFilePath: locator,
            allowedMetadata: nil,
            limits: limits,
            strictRecords: false
        ) {
        case .failure(let failure): return .failure(failure)
        case .success(let captured): return .success(captured.scan)
        }
    }

    /// Captured file-set only. Metadata siblings are read from the physical
    /// session directory; the original logical root is never opened.
    static func scanCapturedSource(
        physicalLocator: String,
        logicalLocator: String,
        replayLayout: ArchiveReplayLayout,
        capturedModificationNanoseconds: Int64? = nil
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        guard replayLayout.strategy == .fileSet,
              JSONLAdapterSupport.fileExists(physicalLocator)
        else {
            return .failure(.malformedJSON)
        }
        let physical = URL(fileURLWithPath: physicalLocator)
        let entrypoint = replayLayout.entrypointRelativePath ?? replayLayout.relativePaths.first
        guard let entrypoint,
              physical.lastPathComponent.utf8.elementsEqual(
                  URL(fileURLWithPath: entrypoint).lastPathComponent.utf8
              ),
              ["chat_history.jsonl", "updates.jsonl"].contains(physical.lastPathComponent)
        else {
            return .failure(.malformedJSON)
        }
        // Present members only. absentRelativePaths must never authorize a read.
        let present = Set(replayLayout.relativePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        guard present.contains(physical.lastPathComponent) else {
            return .failure(.malformedJSON)
        }
        return try Self.scanSession(
            transcriptLocator: physicalLocator,
            sessionDir: physical.deletingLastPathComponent(),
            infoFilePath: logicalLocator,
            allowedMetadata: present,
            declaredRelativePaths: replayLayout.relativePaths,
            limits: .capturedJSONL,
            strictRecords: true,
            capturedModificationNanoseconds: capturedModificationNanoseconds
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        let transcript = Self.primaryTranscriptURL(in: Self.sessionDirectory(for: locator), locator: locator)
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: transcript.path,
            options: options,
            limits: limits,
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func sessionTranscriptLocators(under root: URL) -> [String] {
        JSONLAdapterSupport.directChildren(of: root, includingHidden: true)
            .flatMap { projectDir in
                JSONLAdapterSupport.directChildren(of: projectDir, includingHidden: true)
            }
            .compactMap(Self.preferredLocator(in:))
            .sorted()
    }

    private static func scanSession(
        transcriptLocator: String,
        sessionDir: URL,
        infoFilePath: String,
        allowedMetadata: Set<String>?,
        declaredRelativePaths: [String]? = nil,
        limits: ParserLimits,
        strictRecords: Bool,
        capturedModificationNanoseconds: Int64? = nil
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        do {
            let summary = readDeclaredJSONObject(
                sessionDir.appendingPathComponent("summary.json"),
                allowedMetadata: allowedMetadata
            )
            let promptContext = readDeclaredJSONObject(
                sessionDir.appendingPathComponent("prompt_context.json"),
                allowedMetadata: allowedMetadata
            )
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: transcriptLocator,
                limits: limits,
                reportFailures: true,
                strictRecords: strictRecords
            )
            if let failure, failure != .fileModifiedDuringParse { return .failure(failure) }
            let chatMessages = Self.messages(from: objects)
            let archives = try Self.capturedCompactionArchives(
                sessionDir: sessionDir,
                declaredRelativePaths: declaredRelativePaths
            )
            let messages = archives + chatMessages
            if failure == .fileModifiedDuringParse, messages.isEmpty {
                return .failure(.fileModifiedDuringParse)
            }
            let systemCount = Self.systemMessageCount(from: objects) + archives.count
            let counts = Self.counts(for: messages)
            let info = JSONLAdapterSupport.object(summary?["info"])
            let logicalSessionDir = sessionDirectory(for: infoFilePath)
            let id = JSONLAdapterSupport.string(info?["id"]) ?? logicalSessionDir.lastPathComponent
            guard !id.isEmpty else { return .failure(.malformedJSON) }

            let startTime = JSONLAdapterSupport.string(summary?["created_at"])
                ?? Self.firstTimestamp(in: objects)
                ?? Self.fallbackStartTime(
                    capturedModificationNanoseconds: capturedModificationNanoseconds,
                    transcriptLocator: transcriptLocator,
                    sessionDir: sessionDir,
                    isCaptured: allowedMetadata != nil
                )
                ?? ""
            let endTime = JSONLAdapterSupport.string(summary?["updated_at"])
                ?? Self.lastTimestamp(in: objects)
            let cwd = JSONLAdapterSupport.string(info?["cwd"])
                ?? JSONLAdapterSupport.string(promptContext?["working_directory"])
                ?? Self.decodedProjectDirectory(for: logicalSessionDir)
                ?? ""
            let firstUserText = messages.first { $0.role == .user }?.content
            let summaryText = firstUserText
                ?? JSONLAdapterSupport.string(summary?["session_summary"])
                ?? JSONLAdapterSupport.string(summary?["generated_title"])
            let model = JSONLAdapterSupport.string(summary?["current_model_id"])
                ?? Self.firstModel(in: objects)
            let sessionInfo = NormalizedSessionInfo(
                id: id,
                source: .grok,
                startTime: startTime,
                endTime: endTime,
                cwd: cwd,
                project: nil,
                model: model,
                messageCount: counts.user + counts.assistant + counts.tool,
                userMessageCount: counts.user,
                assistantMessageCount: counts.assistant,
                toolMessageCount: counts.tool,
                systemMessageCount: systemCount,
                summary: summaryText.map { String($0.prefix(200)) },
                filePath: infoFilePath,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: transcriptLocator)
            )
            return .success(
                CapturedSourceScan(
                    scan: IndexingScan(info: sessionInfo, messages: messages, parseFailure: failure),
                    rawSourceSessionID: sessionInfo.id
                )
            )
        } catch is CancellationError where strictRecords {
            throw CancellationError()
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private static func preferredLocator(in sessionDir: URL) -> String? {
        guard JSONLAdapterSupport.isDirectory(sessionDir) else { return nil }
        for name in ["chat_history.jsonl", "updates.jsonl", "summary.json"] {
            let candidate = sessionDir.appendingPathComponent(name)
            if JSONLAdapterSupport.fileExists(candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func sessionDirectory(for locator: String) -> URL {
        let url = URL(fileURLWithPath: locator)
        if JSONLAdapterSupport.isDirectory(url) {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func primaryTranscriptURL(in sessionDir: URL, locator: String) -> URL {
        let locatorURL = URL(fileURLWithPath: locator)
        if ["chat_history.jsonl", "updates.jsonl"].contains(locatorURL.lastPathComponent) {
            return locatorURL
        }
        for name in ["chat_history.jsonl", "updates.jsonl"] {
            let candidate = sessionDir.appendingPathComponent(name)
            if JSONLAdapterSupport.fileExists(candidate.path) {
                return candidate
            }
        }
        return locatorURL
    }

    private static func readDeclaredJSONObject(
        _ url: URL,
        allowedMetadata: Set<String>?
    ) -> JSONLAdapterSupport.JSONObject? {
        if let allowedMetadata, !allowedMetadata.contains(url.lastPathComponent) {
            return nil
        }
        return readJSONObject(url)
    }

    private static func readJSONObject(_ url: URL) -> JSONLAdapterSupport.JSONObject? {
        guard JSONLAdapterSupport.fileExists(url.path),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONLAdapterSupport.JSONObject
        else {
            return nil
        }
        return object
    }

    /// Captured present members only. Live scans pass `declaredRelativePaths`
    /// as nil and never open `compaction/`. Absent or undeclared names are
    /// not read even when those files exist beside the transcript.
    ///
    /// Each declared `compaction/segment_*.md` becomes one labeled `.system`
    /// message with the original Markdown bytes unaltered. Headings are not
    /// mapped to user/assistant. Capture-owned HQ FTS admission for these
    /// labeled bodies is Grok-only in `CaptureIngestReadiness` and must be
    /// proven later by `commit` + `sessions_fts` after parse-format/registry
    /// wiring. A declared segment that is missing, unreadable, or not UTF-8
    /// fails the parse instead of dropping history.
    private static func capturedCompactionArchives(
        sessionDir: URL,
        declaredRelativePaths: [String]?
    ) throws -> [NormalizedMessage] {
        guard let declaredRelativePaths else { return [] }
        let segments = declaredRelativePaths.filter(isDeclaredCompactionSegment(relative:))
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var archives: [NormalizedMessage] = []
        for relative in segments {
            let name = URL(fileURLWithPath: relative).lastPathComponent
            let url = sessionDir.appendingPathComponent("compaction", isDirectory: true)
                .appendingPathComponent(name)
            guard JSONLAdapterSupport.fileExists(url.path) else {
                throw ParserFailure.malformedJSON
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ParserFailure.malformedJSON
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ParserFailure.malformedJSON
            }
            archives.append(
                NormalizedMessage(
                    role: .system,
                    content: Self.compactionArchiveLabel(name: name) + text
                )
            )
        }
        return archives
    }

    private static func compactionArchiveLabel(name: String) -> String {
        "Grok compaction archive\n" + name + "\n\n"
    }

    private static func isDeclaredCompactionSegment(relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy(isSafeRelativeComponent),
              parts[parts.count - 2] == "compaction" else {
            return false
        }
        return isCompactionSegmentName(parts[parts.count - 1])
    }

    private static func isCompactionSegmentName(_ name: String) -> Bool {
        guard name.hasPrefix("segment_"), name.hasSuffix(".md"), isSafeRelativeComponent(name) else {
            return false
        }
        let stem = String(name.dropFirst("segment_".count).dropLast(".md".count))
        return !stem.isEmpty && isSafeRelativeComponent(stem)
    }

    private static func isSafeRelativeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
    }

    private static func messages(from objects: [JSONLAdapterSupport.JSONObject]) -> [NormalizedMessage] {
        objects.compactMap(message(from:))
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        let type = JSONLAdapterSupport.string(object["type"])
        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
            ?? JSONLAdapterSupport.string(object["created_at"])
            ?? JSONLAdapterSupport.string(object["createdAt"])

        switch type {
        case "user":
            let rawText = extractContent(object["content"])
            guard let userText = normalizeUserText(rawText) else { return nil }
            return NormalizedMessage(role: .user, content: userText, timestamp: timestamp)
        case "assistant":
            let content = extractContent(object["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let toolCalls = toolCalls(from: object["tool_calls"])
            guard !content.isEmpty || !toolCalls.isEmpty else { return nil }
            return NormalizedMessage(
                role: .assistant,
                content: content,
                timestamp: timestamp,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                usage: usage(from: JSONLAdapterSupport.object(object["usage"]))
            )
        case "tool_result":
            let content = extractContent(object["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func counts(for messages: [NormalizedMessage]) -> (user: Int, assistant: Int, tool: Int) {
        var user = 0
        var assistant = 0
        var tool = 0
        for message in messages {
            switch message.role {
            case .user: user += 1
            case .assistant: assistant += 1
            case .tool: tool += 1
            case .system: break
            }
        }
        return (user, assistant, tool)
    }

    private static func systemMessageCount(from objects: [JSONLAdapterSupport.JSONObject]) -> Int {
        var count = 0
        for object in objects {
            switch JSONLAdapterSupport.string(object["type"]) {
            case "system":
                count += 1
            case "user":
                if isSystemInjection(extractContent(object["content"])) {
                    count += 1
                }
            default:
                continue
            }
        }
        return count
    }

    private static func normalizeUserText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSystemInjection(trimmed) else { return nil }
        guard trimmed.hasPrefix("<user_query>") else { return trimmed }
        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: "<user_query>".count)
        let body = String(trimmed[bodyStart...])
        if let close = body.range(of: "</user_query>", options: .backwards) {
            return String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<user_info>")
            || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<codex_internal_context")
            || trimmed.hasPrefix("# AGENTS.md instructions for ")
            || trimmed.hasPrefix("<INSTRUCTIONS>")
            || trimmed.hasPrefix("<environment_context>")
    }

    private static func extractContent(_ value: Any?) -> String {
        if let string = JSONLAdapterSupport.string(value) {
            return string
        }
        if let object = JSONLAdapterSupport.object(value) {
            return extractText(from: object)
                ?? JSONLAdapterSupport.jsonString(object, limit: 2_000)
                ?? ""
        }
        guard let array = JSONLAdapterSupport.array(value) else { return "" }
        var parts: [String] = []
        for item in array {
            if let string = JSONLAdapterSupport.string(item), !string.isEmpty {
                parts.append(string)
            } else if let object = JSONLAdapterSupport.object(item),
                      let text = extractText(from: object),
                      !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractText(from object: JSONLAdapterSupport.JSONObject) -> String? {
        for key in ["text", "input_text", "output_text", "content", "message"] {
            if let text = JSONLAdapterSupport.string(object[key]), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func toolCalls(from value: Any?) -> [NormalizedToolCall] {
        guard let rawCalls = JSONLAdapterSupport.array(value) else { return [] }
        return rawCalls.compactMap { raw in
            guard let object = JSONLAdapterSupport.object(raw) else { return nil }
            let function = JSONLAdapterSupport.object(object["function"])
            guard let name = JSONLAdapterSupport.string(object["name"])
                    ?? JSONLAdapterSupport.string(function?["name"])
            else {
                return nil
            }
            let input = stringOrJSONString(object["arguments"])
                ?? stringOrJSONString(function?["arguments"])
                ?? stringOrJSONString(object["rawInput"])
                ?? stringOrJSONString(object["input"])
                ?? stringOrJSONString(object["args"])
            return NormalizedToolCall(name: name, input: input)
        }
    }

    private static func stringOrJSONString(_ value: Any?) -> String? {
        if let string = JSONLAdapterSupport.string(value) {
            return string.isEmpty ? nil : String(string.prefix(500))
        }
        guard let value else { return nil }
        return JSONLAdapterSupport.jsonString(value, limit: 500)
    }

    private static func usage(from rawUsage: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let rawUsage else { return nil }
        return TokenUsage(
            inputTokens: int(rawUsage["input_tokens"]),
            outputTokens: int(rawUsage["output_tokens"]),
            cacheReadTokens: optionalInt(rawUsage["cache_read_input_tokens"]),
            cacheCreationTokens: optionalInt(rawUsage["cache_creation_input_tokens"])
        )
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        guard value != nil else { return nil }
        return int(value)
    }

    private static func firstTimestamp(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.lazy.compactMap { object in
            JSONLAdapterSupport.string(object["timestamp"])
                ?? JSONLAdapterSupport.string(object["created_at"])
                ?? JSONLAdapterSupport.string(object["createdAt"])
        }.first
    }

    private static func lastTimestamp(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.reversed().lazy.compactMap { object in
            JSONLAdapterSupport.string(object["timestamp"])
                ?? JSONLAdapterSupport.string(object["created_at"])
                ?? JSONLAdapterSupport.string(object["createdAt"])
        }.first
    }

    private static func firstModel(in objects: [JSONLAdapterSupport.JSONObject]) -> String? {
        objects.lazy.compactMap { object in
            JSONLAdapterSupport.string(object["model_id"])
                ?? JSONLAdapterSupport.string(object["model"])
        }.first
    }

    private static func decodedProjectDirectory(for sessionDir: URL) -> String? {
        let encoded = sessionDir.deletingLastPathComponent().lastPathComponent
        return encoded.removingPercentEncoding
    }

    private static func fallbackStartTime(
        capturedModificationNanoseconds: Int64?,
        transcriptLocator: String,
        sessionDir: URL,
        isCaptured: Bool
    ) -> String? {
        if let capturedModificationNanoseconds {
            return isoFromModificationNanoseconds(capturedModificationNanoseconds)
        }
        guard !isCaptured else { return nil }
        return fileModifiedAt(URL(fileURLWithPath: transcriptLocator)) ?? fileModifiedAt(sessionDir)
    }

    private static func isoFromModificationNanoseconds(_ nanoseconds: Int64) -> String {
        Phase4AdapterSupport.isoFromSeconds(Double(nanoseconds) / 1_000_000_000)
    }

    private static func fileModifiedAt(_ url: URL) -> String? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else {
            return nil
        }
        return Phase4AdapterSupport.isoFromSeconds(date.timeIntervalSince1970)
    }
}
