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

final class GeminiCliAdapter: SessionAdapter {
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
            for fileURL in JSONLAdapterSupport.directChildren(of: chatsURL)
                where fileURL.lastPathComponent.hasPrefix("session-") && fileURL.pathExtension == "json"
            {
                locators.append(fileURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let object = try Phase4AdapterSupport.readJSONObject(locator: locator, limits: limits)
            guard let sessionId = JSONLAdapterSupport.string(object["sessionId"]),
                  let startTime = JSONLAdapterSupport.string(object["startTime"]),
                  let messages = JSONLAdapterSupport.array(object["messages"])
            else {
                return .failure(.malformedJSON)
            }

            let userMessages = messages.compactMap { JSONLAdapterSupport.object($0) }
                .filter { JSONLAdapterSupport.string($0["type"]) == "user" }
            let assistantMessages = messages.compactMap { JSONLAdapterSupport.object($0) }
                .filter {
                    let type = JSONLAdapterSupport.string($0["type"])
                    return type == "gemini" || type == "model"
                }
            let projectName = Self.projectName(from: locator)
            let cwd = resolveProject(projectName: projectName) ?? projectName
            let firstUserText = userMessages.first.map { Self.extractText($0["content"]) } ?? ""
            let sidecar = Self.readSidecar(locator: locator, sessionId: sessionId)
            let originator = JSONLAdapterSupport.string(sidecar?["originator"])

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
                    agentRole: OriginatorClassifier.isClaudeCode(originator) ? "dispatched" : nil,
                    originator: originator,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: JSONLAdapterSupport.string(sidecar?["parentSessionId"]),
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
        let object = try Phase4AdapterSupport.readJSONObject(locator: locator, limits: limits)
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

    private static func projectName(from locator: String) -> String {
        let components = URL(fileURLWithPath: locator).pathComponents
        guard let chatsIndex = components.firstIndex(of: "chats"), chatsIndex > 0 else {
            return ""
        }
        return components[chatsIndex - 1]
    }

    private static func readSidecar(locator: String, sessionId: String) -> Phase4AdapterSupport.JSONObject? {
        let sidecarURL = URL(fileURLWithPath: locator)
            .deletingLastPathComponent()
            .appendingPathComponent("\(sessionId).engram.json")
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject
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
            usage: nil
        )
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
