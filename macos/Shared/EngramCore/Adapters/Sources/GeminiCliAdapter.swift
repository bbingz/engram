import Foundation

enum Phase4AdapterSupport {
    typealias JSONObject = [String: Any]

    static func readJSONObject(locator: String, limits: ParserLimits) throws -> JSONObject {
        let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw ParserFailure.malformedJSON
        }
        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return object
    }

    static func readJSONArray(locator: String, limits: ParserLimits) throws -> [JSONObject] {
        let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [JSONObject] else {
            throw ParserFailure.malformedJSON
        }
        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return array
    }

    static func jsonObject(from string: String) -> JSONObject? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func isoFromMilliseconds(_ milliseconds: Double) -> String {
        isoFromSeconds(milliseconds / 1000.0)
    }

    static func isoFromSeconds(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func fileSize(_ path: String) -> Int64 {
        JSONLAdapterSupport.fileSize(locator: path)
    }
}

final class GeminiCliAdapter: SessionAdapter, Sendable {
    let source: SourceName = .geminiCli
    private let tmpRoot: URL
    private let projectsFile: URL
    private let limits: ParserLimits

    init(
        tmpRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")
            .path,
        projectsFile: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/projects.json")
            .path,
        limits: ParserLimits = .default
    ) {
        self.tmpRoot = URL(fileURLWithPath: tmpRoot)
        self.projectsFile = URL(fileURLWithPath: projectsFile)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(tmpRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for projectURL in JSONLAdapterSupport.directChildren(of: tmpRoot)
            where JSONLAdapterSupport.isDirectory(projectURL)
        {
            let chatsURL = projectURL.appendingPathComponent("chats")
            guard JSONLAdapterSupport.isDirectory(chatsURL) else { continue }
            locators.append(contentsOf: JSONLAdapterSupport.recursiveFiles(under: chatsURL) { fileURL in
                !fileURL.lastPathComponent.hasSuffix(".engram.json") &&
                    (fileURL.pathExtension == "json" || fileURL.pathExtension == "jsonl")
            })
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let object = try Self.readSession(locator: locator, limits: limits)
            guard let sessionId = JSONLAdapterSupport.string(object["sessionId"]),
                  let startTime = JSONLAdapterSupport.string(object["startTime"]),
                  let messages = JSONLAdapterSupport.array(object["messages"])
            else {
                return .failure(.malformedJSON)
            }

            let messageObjects = messages.compactMap { JSONLAdapterSupport.object($0) }
                .filter { !Self.extractText($0["content"]).isEmpty }
            let userMessages = messageObjects
                .filter { JSONLAdapterSupport.string($0["type"]) == "user" }
            let assistantMessages = messageObjects
                .filter {
                    let type = JSONLAdapterSupport.string($0["type"])
                    return type == "gemini" || type == "model"
                }
            let projectName = Self.projectName(from: locator)
            let cwd = resolveProjectRoot(projectName: projectName) ??
                resolveProject(projectName: projectName) ??
                projectName
            let firstUserText = userMessages.first.map { Self.extractText($0["content"]) } ?? ""
            let sidecar = Self.readSidecar(locator: locator, sessionId: sessionId, limits: limits)
            let originator = JSONLAdapterSupport.string(sidecar?["originator"])
            let nativeParentSessionId = Self.nativeParentSessionId(from: locator)

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .geminiCli,
                    startTime: startTime,
                    endTime: JSONLAdapterSupport.string(object["lastUpdated"]),
                    cwd: cwd,
                    project: projectName,
                    model: nil,
                    messageCount: userMessages.count + assistantMessages.count,
                    userMessageCount: userMessages.count,
                    assistantMessageCount: assistantMessages.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: firstUserText.isEmpty ? nil : String(firstUserText.prefix(200)),
                    filePath: locator,
                    sizeBytes: Phase4AdapterSupport.fileSize(locator),
                    indexedAt: nil,
                    agentRole: nativeParentSessionId != nil
                        ? "subagent"
                        : (OriginatorClassifier.isClaudeCode(originator) ? "dispatched" : nil),
                    originator: originator,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: JSONLAdapterSupport.string(sidecar?["parentSessionId"]) ?? nativeParentSessionId,
                    suggestedParentId: nil
                )
            )
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
        let object = try Self.readSession(locator: locator, limits: limits)
        let messages = JSONLAdapterSupport.array(object["messages"])?
            .compactMap { JSONLAdapterSupport.object($0) }
            .compactMap(Self.message(from:)) ?? []
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func resolveProject(projectName: String) -> String? {
        guard let data = try? Data(contentsOf: projectsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject
        else {
            return nil
        }
        let rawProjects = JSONLAdapterSupport.object(object["projects"]) ?? object
        for (cwd, value) in rawProjects {
            if JSONLAdapterSupport.string(value) == projectName {
                return cwd
            }
        }
        return nil
    }

    private func resolveProjectRoot(projectName: String) -> String? {
        let rootURL = tmpRoot
            .appendingPathComponent(projectName, isDirectory: true)
            .appendingPathComponent(".project_root")
        guard let content = try? String(contentsOf: rootURL, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func projectName(from locator: String) -> String {
        let components = URL(fileURLWithPath: locator).pathComponents
        guard let chatsIndex = components.firstIndex(of: "chats"), chatsIndex > 0 else {
            return ""
        }
        return components[chatsIndex - 1]
    }

    private static func nativeParentSessionId(from locator: String) -> String? {
        let components = URL(fileURLWithPath: locator).pathComponents
        guard let chatsIndex = components.firstIndex(of: "chats"),
              components.count > chatsIndex + 2
        else {
            return nil
        }
        return components[chatsIndex + 1]
    }

    private static func readSidecar(
        locator: String,
        sessionId: String,
        limits: ParserLimits
    ) -> Phase4AdapterSupport.JSONObject? {
        let sidecarURL = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionId).engram.json")
        return try? Phase4AdapterSupport.readJSONObject(locator: sidecarURL.path, limits: limits)
    }

    private static func readSession(locator: String, limits: ParserLimits) throws -> Phase4AdapterSupport.JSONObject {
        if URL(fileURLWithPath: locator).pathExtension == "jsonl" {
            return try readJSONLSession(locator: locator, limits: limits)
        }
        return try Phase4AdapterSupport.readJSONObject(locator: locator, limits: limits)
    }

    private static func readJSONLSession(locator: String, limits: ParserLimits) throws -> Phase4AdapterSupport.JSONObject {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits, reportFailures: true)
        if let failure { throw failure }

        var metadata: Phase4AdapterSupport.JSONObject = [:]
        var messages: [Phase4AdapterSupport.JSONObject] = []
        for object in objects {
            if let update = JSONLAdapterSupport.object(object["$set"]) {
                for (key, value) in update { metadata[key] = value }
                if let updatedMessages = JSONLAdapterSupport.array(update["messages"]) {
                    messages = updatedMessages.compactMap { JSONLAdapterSupport.object($0) }
                }
                continue
            }
            if let rewindTo = JSONLAdapterSupport.string(object["$rewindTo"]) {
                if let index = messages.firstIndex(where: { JSONLAdapterSupport.string($0["id"]) == rewindTo }) {
                    messages = Array(messages.prefix(index + 1))
                }
                continue
            }
            if JSONLAdapterSupport.string(object["type"]) != nil {
                messages.append(object)
                continue
            }
            for (key, value) in object { metadata[key] = value }
            if let initialMessages = JSONLAdapterSupport.array(object["messages"]) {
                messages = initialMessages.compactMap { JSONLAdapterSupport.object($0) }
            }
        }
        metadata["messages"] = messages
        return metadata
    }

    private static func message(from object: Phase4AdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user" || type == "gemini" || type == "model"
        else {
            return nil
        }
        let content = extractText(object["content"])
        guard !content.isEmpty else { return nil }
        return NormalizedMessage(
            role: type == "user" ? .user : .assistant,
            content: content,
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: type == "user" ? nil : usage(from: JSONLAdapterSupport.object(object["tokens"]))
        )
    }

    private static func usage(from tokens: Phase4AdapterSupport.JSONObject?) -> TokenUsage? {
        guard let tokens else { return nil }
        let input = int(tokens["input"])
        let cached = int(tokens["cached"])
        let output = int(tokens["output"]) + int(tokens["thoughts"]) + int(tokens["tool"])
        let usage = TokenUsage(
            inputTokens: max(input - cached, 0),
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0
        )
        guard usage.inputTokens > 0
            || usage.outputTokens > 0
            || (usage.cacheReadTokens ?? 0) > 0
        else {
            return nil
        }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        Int(Phase4AdapterSupport.int64(value) ?? 0)
    }

    private static func extractText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = JSONLAdapterSupport.array(content) else { return "" }
        return parts.compactMap { item in
            JSONLAdapterSupport.string(JSONLAdapterSupport.object(item)?["text"])
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
