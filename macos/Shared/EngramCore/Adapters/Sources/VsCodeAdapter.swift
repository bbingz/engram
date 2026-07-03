import Foundation

final class VsCodeAdapter: SessionAdapter, Sendable {
    let source: SourceName = .vscode
    private static let maxMutationPathDepth = 64
    private static let maxMutationArrayIndex = 1_000_000
    private let workspaceStorageDir: URL
    private let limits: ParserLimits
    private let messageCache = ParsedTranscriptCache()

    init(
        workspaceStorageDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
            .path,
        limits: ParserLimits = .default
    ) {
        self.workspaceStorageDir = URL(fileURLWithPath: workspaceStorageDir)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(workspaceStorageDir)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for workspaceURL in JSONLAdapterSupport.directChildren(of: workspaceStorageDir)
            where JSONLAdapterSupport.isDirectory(workspaceURL)
        {
            let chatSessionsURL = workspaceURL.appendingPathComponent("chatSessions")
            guard JSONLAdapterSupport.isDirectory(chatSessionsURL) else { continue }
            for fileURL in JSONLAdapterSupport.directChildren(of: chatSessionsURL)
                where fileURL.pathExtension == "jsonl"
            {
                locators.append(fileURL.path)
            }
        }
        return locators.sorted()
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            guard let session = try Self.readSession(locator: locator, limits: limits),
                  let requests = JSONLAdapterSupport.array(session["requests"]),
                  !requests.isEmpty,
                  let creationDate = Phase4AdapterSupport.double(session["creationDate"])
            else {
                return .failure(.malformedJSON)
            }
            let requestObjects = requests.compactMap { JSONLAdapterSupport.object($0) }
            let userTexts = requestObjects.map(Self.extractUserText).filter { !$0.isEmpty }
            let assistantTexts = requestObjects.map(Self.extractAssistantText).filter { !$0.isEmpty }
            let lastTimestamp = Phase4AdapterSupport.double(requestObjects.last?["timestamp"])
            let sessionId = JSONLAdapterSupport.string(session["sessionId"]) ??
                URL(fileURLWithPath: locator).deletingPathExtension().lastPathComponent
            let cwd = Self.readWorkspaceCwd(for: locator)

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .vscode,
                    startTime: Phase4AdapterSupport.isoFromMilliseconds(creationDate),
                    endTime: lastTimestamp != nil && lastTimestamp != creationDate
                        ? Phase4AdapterSupport.isoFromMilliseconds(lastTimestamp!)
                        : nil,
                    cwd: cwd,
                    project: nil,
                    model: nil,
                    messageCount: userTexts.count + assistantTexts.count,
                    userMessageCount: userTexts.count,
                    assistantMessageCount: assistantTexts.count,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: userTexts.first.map { String($0.prefix(200)) },
                    filePath: locator,
                    sizeBytes: Phase4AdapterSupport.fileSize(locator),
                    indexedAt: nil,
                    agentRole: nil,
                    originator: nil,
                    origin: nil,
                    summaryMessageCount: nil,
                    tier: nil,
                    qualityScore: nil,
                    parentSessionId: nil,
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
        let signature = ParsedTranscriptCache.Signature.forFile(locator)
        let messages: [NormalizedMessage]
        if let cached = await messageCache.cached(locator: locator, signature: signature) {
            messages = cached
        } else {
            messages = try Self.buildMessages(locator: locator, limits: limits)
            await messageCache.store(locator: locator, signature: signature, messages: messages)
        }
        return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
    }

    private static func buildMessages(locator: String, limits: ParserLimits) throws -> [NormalizedMessage] {
        guard let session = try readSession(locator: locator, limits: limits),
              let requests = JSONLAdapterSupport.array(session["requests"])
        else {
            return []
        }

        var messages: [NormalizedMessage] = []
        for request in requests.compactMap({ JSONLAdapterSupport.object($0) }) {
            let timestamp = Phase4AdapterSupport.double(request["timestamp"])
                .map { Phase4AdapterSupport.isoFromMilliseconds($0) }
            let userText = extractUserText(request)
            if !userText.isEmpty {
                messages.append(
                    NormalizedMessage(
                        role: .user,
                        content: userText,
                        timestamp: timestamp,
                        toolCalls: nil,
                        usage: nil
                    )
                )
            }
            let assistantText = extractAssistantText(request)
            if !assistantText.isEmpty {
                messages.append(
                    NormalizedMessage(
                        role: .assistant,
                        content: assistantText,
                        timestamp: timestamp,
                        toolCalls: nil,
                        usage: nil
                    )
                )
            }
        }
        return messages
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func readSession(
        locator: String,
        limits: ParserLimits
    ) throws -> Phase4AdapterSupport.JSONObject? {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
        if let failure { throw failure }
        return try replayMutationLog(objects)
    }

    private static func replayMutationLog(_ objects: [Phase4AdapterSupport.JSONObject]) throws -> Phase4AdapterSupport.JSONObject? {
        var state: Any?
        var sawInitial = false
        for entry in objects {
            guard let kind = Phase4AdapterSupport.int64(entry["kind"]) else { continue }
            switch kind {
            case 0:
                state = entry["v"]
                sawInitial = true
            case 1 where sawInitial:
                guard let path = JSONLAdapterSupport.array(entry["k"]) else { continue }
                try validateMutationPath(path)
                state = try setting(state, path: path, value: entry["v"])
            case 2 where sawInitial:
                guard let path = JSONLAdapterSupport.array(entry["k"]) else { continue }
                try validateMutationPath(path)
                state = try pushing(
                    state,
                    path: path,
                    values: JSONLAdapterSupport.array(entry["v"]),
                    startIndex: Phase4AdapterSupport.int64(entry["i"]).map(Int.init)
                )
            case 3 where sawInitial:
                guard let path = JSONLAdapterSupport.array(entry["k"]) else { continue }
                try validateMutationPath(path)
                state = try setting(state, path: path, value: nil)
            default:
                continue
            }
        }
        return JSONLAdapterSupport.object(state)
    }

    private static func validateMutationPath(_ path: [Any]) throws {
        guard path.count <= maxMutationPathDepth else { throw ParserFailure.malformedJSON }
        for component in path {
            if let index = pathIndex(component), index > maxMutationArrayIndex {
                throw ParserFailure.malformedJSON
            }
        }
    }

    private static func setting(_ container: Any?, path: [Any], value: Any?) throws -> Any? {
        guard let head = path.first else { return container }
        let rest = Array(path.dropFirst())
        if let key = pathKey(head) {
            var object = JSONLAdapterSupport.object(container) ?? [:]
            if rest.isEmpty {
                object[key] = value
            } else {
                object[key] = try setting(object[key], path: rest, value: value)
            }
            return object
        }
        guard let index = pathIndex(head), index >= 0 else { return container }
        guard index <= maxMutationArrayIndex else { throw ParserFailure.malformedJSON }
        var array = JSONLAdapterSupport.array(container) ?? []
        while array.count <= index { array.append([String: Any]()) }
        if rest.isEmpty {
            array[index] = value as Any
        } else {
            array[index] = try setting(array[index], path: rest, value: value) as Any
        }
        return array
    }

    private static func pushing(
        _ container: Any?,
        path: [Any],
        values: [Any]?,
        startIndex: Int?
    ) throws -> Any? {
        guard let head = path.first else { return container }
        let rest = Array(path.dropFirst())
        if let key = pathKey(head) {
            var object = JSONLAdapterSupport.object(container) ?? [:]
            if rest.isEmpty {
                var array = JSONLAdapterSupport.array(object[key]) ?? []
                if let startIndex { array = Array(array.prefix(max(startIndex, 0))) }
                if let values { array.append(contentsOf: values) }
                object[key] = array
            } else {
                object[key] = try pushing(object[key], path: rest, values: values, startIndex: startIndex)
            }
            return object
        }
        guard let index = pathIndex(head), index >= 0 else { return container }
        guard index <= maxMutationArrayIndex else { throw ParserFailure.malformedJSON }
        var array = JSONLAdapterSupport.array(container) ?? []
        while array.count <= index { array.append([String: Any]()) }
        if rest.isEmpty {
            var target = JSONLAdapterSupport.array(array[index]) ?? []
            if let startIndex { target = Array(target.prefix(max(startIndex, 0))) }
            if let values { target.append(contentsOf: values) }
            array[index] = target
        } else {
            array[index] = try pushing(array[index], path: rest, values: values, startIndex: startIndex) as Any
        }
        return array
    }

    private static func pathKey(_ value: Any) -> String? {
        JSONLAdapterSupport.string(value)
    }

    private static func pathIndex(_ value: Any) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func readWorkspaceCwd(for locator: String) -> String {
        let sessionURL = URL(fileURLWithPath: locator)
        let workspaceURL = sessionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: workspaceURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject
        else {
            return ""
        }
        if let folder = JSONLAdapterSupport.string(object["folder"]) {
            return decodeFileURI(folder)
        }
        if let configuration = JSONLAdapterSupport.string(object["configuration"]) {
            let workspacePath = decodeFileURI(configuration)
            guard !workspacePath.isEmpty else { return "" }
            return readCodeWorkspaceFirstFolder(workspacePath)
        }
        return ""
    }

    private static func readCodeWorkspaceFirstFolder(_ workspacePath: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: workspacePath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? Phase4AdapterSupport.JSONObject,
              let folders = JSONLAdapterSupport.array(object["folders"]),
              let first = folders.compactMap({ JSONLAdapterSupport.object($0) }).first
        else {
            return ""
        }
        if let uri = JSONLAdapterSupport.string(first["uri"]) {
            return decodeFileURI(uri)
        }
        guard let path = JSONLAdapterSupport.string(first["path"]), !path.isEmpty else { return "" }
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: workspacePath)
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
            .path
    }

    private static func decodeFileURI(_ uri: String) -> String {
        guard uri.hasPrefix("file://") else { return "" }
        var path = String(uri.dropFirst("file://".count))
        if path.hasPrefix("localhost/") {
            path = String(path.dropFirst("localhost".count))
        }
        return path.removingPercentEncoding ?? ""
    }

    private static func extractUserText(_ request: Phase4AdapterSupport.JSONObject) -> String {
        guard let message = JSONLAdapterSupport.object(request["message"]) else { return "" }
        if let text = JSONLAdapterSupport.string(message["text"]), !text.isEmpty {
            return text
        }
        guard let parts = JSONLAdapterSupport.array(message["parts"]) else { return "" }
        for part in parts.compactMap({ JSONLAdapterSupport.object($0) }) {
            if JSONLAdapterSupport.string(part["kind"]) == "text",
               let value = JSONLAdapterSupport.string(part["value"]),
               !value.isEmpty
            {
                return value
            }
        }
        return ""
    }

    private static func extractAssistantText(_ request: Phase4AdapterSupport.JSONObject) -> String {
        guard let responses = JSONLAdapterSupport.array(request["response"]) else { return "" }
        for response in responses.compactMap({ JSONLAdapterSupport.object($0) }) {
            let value = JSONLAdapterSupport.object(response["value"])
            let content = JSONLAdapterSupport.object(value?["content"])
            if JSONLAdapterSupport.string(value?["kind"]) == "markdownContent",
               let text = JSONLAdapterSupport.string(content?["value"]),
               !text.isEmpty
            {
                return text
            }
        }
        return ""
    }
}
