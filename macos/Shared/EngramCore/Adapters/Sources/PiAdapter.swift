import Foundation

final class PiAdapter: SessionAdapter, Sendable {
    let source: SourceName = .pi
    private let sessionsRoot: URL
    private let limits: ParserLimits

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionsRoot = URL(fileURLWithPath: sessionsRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionsRoot)
    }

    func listSessionLocators() async throws -> [String] {
        try JSONLAdapterSupport.recursiveFiles(under: sessionsRoot) { $0.pathExtension == "jsonl" }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.countsTowardMessageLimit
            )
            let messages = objects.compactMap(Self.message(from:))
            if let failure,
               failure != .fileModifiedDuringParse || messages.isEmpty {
                return .failure(failure)
            }
            return Self.sessionInfo(from: objects, locator: locator)
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    static func scanCapturedSource(
        physicalLocator: String,
        logicalLocator: String,
        capturedModificationNanoseconds: Int64? = nil
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        try scanFileForIndexing(
            physicalLocator: physicalLocator,
            logicalLocator: logicalLocator,
            limits: .capturedJSONL,
            strictRecords: true,
            capturedModificationNanoseconds: capturedModificationNanoseconds
        )
    }

    private static func scanFileForIndexing(
        physicalLocator: String,
        logicalLocator: String,
        limits: ParserLimits,
        strictRecords: Bool,
        capturedModificationNanoseconds: Int64?
    ) throws -> AdapterParseResult<CapturedSourceScan> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: physicalLocator,
                limits: limits,
                reportFailures: true,
                strictRecords: strictRecords,
                countsTowardMessageLimit: Self.countsTowardMessageLimit
            )
            if let failure, failure != .fileModifiedDuringParse { return .failure(failure) }
            let messages = objects.compactMap(Self.message(from:))
            if failure == .fileModifiedDuringParse, messages.isEmpty {
                return .failure(.fileModifiedDuringParse)
            }
            let info: NormalizedSessionInfo
            switch Self.sessionInfo(
                from: objects,
                locator: logicalLocator,
                physicalLocator: physicalLocator,
                capturedModificationNanoseconds: capturedModificationNanoseconds
            ) {
            case .failure(let reason): return .failure(reason)
            case .success(let value): info = value
            }
            let checkpoint = failure == nil
                ? try JSONLAdapterSupport.checkpoint(locator: physicalLocator, limits: limits)
                : nil
            let checkpointBoundaryHash = checkpoint?.parsedOffset == info.sizeBytes
                ? checkpoint?.boundaryHash
                : nil
            return .success(
                CapturedSourceScan(
                    scan: IndexingScan(
                        info: info,
                        messages: messages,
                        parseFailure: failure,
                        checkpointParsedOffset: checkpoint?.parsedOffset,
                        checkpointBoundaryHash: checkpointBoundaryHash
                    ),
                    rawSourceSessionID: info.id
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

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.countsTowardMessageLimit
            )
            let messages = objects.compactMap(Self.message(from:))
            if let failure,
               failure != .fileModifiedDuringParse || messages.isEmpty {
                return .failure(failure)
            }
            let info: NormalizedSessionInfo
            switch Self.sessionInfo(from: objects, locator: locator) {
            case .success(let value): info = value
            case .failure(let failure): return .failure(failure)
            }
            return .success(IndexingScan(info: info, messages: messages, parseFailure: failure))
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        if options.limit == nil {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: Self.countsTowardMessageLimit
            )
            let messages = objects.compactMap(Self.message(from:))
            if let failure, messages.isEmpty { throw failure }
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        }
        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: { $0.role != .system },
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let result = try JSONLAdapterSupport.windowedMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: { $0.role != .system },
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func sessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        locator: String,
        physicalLocator: String? = nil,
        capturedModificationNanoseconds: Int64? = nil
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        var sessionId = ""
        var cwd = ""
        var model: String?
        var startTime = ""
        var endTime = ""
        var userCount = 0
        var assistantCount = 0
        var toolCount = 0
        var systemCount = 0
        var firstUserText = ""

        for object in objects {
            if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                if startTime.isEmpty { startTime = timestamp }
                endTime = timestamp
            }

            guard let type = JSONLAdapterSupport.string(object["type"]) else { continue }
            if type == "session" {
                sessionId = JSONLAdapterSupport.string(object["id"]) ?? sessionId
                cwd = JSONLAdapterSupport.string(object["cwd"]) ?? cwd
                startTime = JSONLAdapterSupport.string(object["timestamp"]) ?? startTime
                continue
            }
            if type == "model_change" {
                model = JSONLAdapterSupport.string(object["modelId"]) ?? model
                continue
            }
            guard type == "message",
                  let message = JSONLAdapterSupport.object(object["message"]),
                  let role = JSONLAdapterSupport.string(message["role"])
            else {
                continue
            }

            if model == nil, let value = JSONLAdapterSupport.string(message["model"]) {
                model = value
            }

            switch role {
            case "user":
                let text = extractText(message["content"])
                if isSystemInjection(text) {
                    systemCount += 1
                } else {
                    userCount += 1
                    if firstUserText.isEmpty { firstUserText = text }
                }
            case "assistant":
                assistantCount += 1
            case "toolResult":
                toolCount += 1
            case "system":
                systemCount += 1
            default:
                continue
            }
        }

        if sessionId.isEmpty { sessionId = idFromFileName(locator) }
        if startTime.isEmpty, let capturedModificationNanoseconds {
            startTime = Phase4AdapterSupport.isoFromSeconds(
                Double(capturedModificationNanoseconds) / 1_000_000_000
            )
        }
        guard !sessionId.isEmpty, !startTime.isEmpty else { return .failure(.malformedJSON) }

        return .success(
            NormalizedSessionInfo(
                id: sessionId,
                source: .pi,
                startTime: startTime,
                endTime: endTime != startTime && !endTime.isEmpty ? endTime : nil,
                cwd: cwd,
                project: nil,
                model: model,
                messageCount: userCount + assistantCount + toolCount,
                userMessageCount: userCount,
                assistantMessageCount: assistantCount,
                toolMessageCount: toolCount,
                systemMessageCount: systemCount,
                summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                filePath: locator,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: physicalLocator ?? locator)
            )
        )
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard JSONLAdapterSupport.string(object["type"]) == "message",
              let message = JSONLAdapterSupport.object(object["message"]),
              let rawRole = JSONLAdapterSupport.string(message["role"])
        else {
            return nil
        }

        let content = extractText(message["content"])
        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
        switch rawRole {
        case "user":
            return NormalizedMessage(
                role: isSystemInjection(content) ? .system : .user,
                content: content,
                timestamp: timestamp
            )
        case "assistant":
            return NormalizedMessage(
                role: .assistant,
                content: content,
                timestamp: timestamp,
                toolCalls: extractToolCalls(message["content"]),
                usage: usage(from: JSONLAdapterSupport.object(message["usage"]))
            )
        case "toolResult":
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        case "system":
            return NormalizedMessage(role: .system, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func countsTowardMessageLimit(_ object: JSONLAdapterSupport.JSONObject) -> Bool {
        guard let message = message(from: object) else { return false }
        return message.role != .system
    }

    private static func idFromFileName(_ locator: String) -> String {
        let name = URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
        guard let idx = name.firstIndex(of: "_") else { return name }
        return String(name[name.index(after: idx)...])
    }

    private static func extractText(_ value: Any?) -> String {
        guard let parts = JSONLAdapterSupport.array(value) else { return "" }
        return parts.compactMap { part -> String? in
            guard let object = JSONLAdapterSupport.object(part),
                  JSONLAdapterSupport.string(object["type"]) == "text"
            else {
                return nil
            }
            return JSONLAdapterSupport.string(object["text"])
        }.joined(separator: "\n")
    }

    private static func extractToolCalls(_ value: Any?) -> [NormalizedToolCall]? {
        guard let parts = JSONLAdapterSupport.array(value) else { return nil }
        let calls = parts.compactMap { part -> NormalizedToolCall? in
            guard let object = JSONLAdapterSupport.object(part),
                  JSONLAdapterSupport.string(object["type"]) == "toolCall",
                  let name = JSONLAdapterSupport.string(object["name"])
            else {
                return nil
            }
            let input = object["arguments"].flatMap { JSONLAdapterSupport.jsonString($0) }
            return NormalizedToolCall(name: name, input: input)
        }
        return calls.isEmpty ? nil : calls
    }

    private static func usage(from rawUsage: JSONLAdapterSupport.JSONObject?) -> TokenUsage? {
        guard let rawUsage else { return nil }
        return TokenUsage(
            inputTokens: int(rawUsage["input"]),
            outputTokens: int(rawUsage["output"]),
            cacheReadTokens: optionalInt(rawUsage["cacheRead"]),
            cacheCreationTokens: optionalInt(rawUsage["cacheWrite"])
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

    private static func isSystemInjection(_ text: String) -> Bool {
        text.hasPrefix("# AGENTS.md instructions for ") ||
            text.contains("<INSTRUCTIONS>") ||
            text.hasPrefix("<local-command-caveat>") ||
            text.hasPrefix("<environment_context>")
    }
}
