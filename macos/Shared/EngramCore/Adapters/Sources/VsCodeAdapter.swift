import Darwin
import Foundation

final class VsCodeAdapter: SessionAdapter, Sendable {
    let source: SourceName = .vscode
    private static let maxMutationPathDepth = 64
    private static let maxMutationArrayIndex = 1_000_000
    private let workspaceStorageDir: URL
    private let limits: ParserLimits
    private let messageCache = ParsedTranscriptCache()
    private struct CapturedReplay: Sendable {
        let logicalLocator: String
        let workspaceData: Data?
        let configurationData: Data?
    }
    private let capturedReplay: CapturedReplay?

    init(
        workspaceStorageDir: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/workspaceStorage")
            .path,
        limits: ParserLimits = .default
    ) {
        self.workspaceStorageDir = URL(fileURLWithPath: workspaceStorageDir)
        self.limits = limits
        self.capturedReplay = nil
    }

    private init(physicalLocator: String, capturedReplay: CapturedReplay) {
        self.workspaceStorageDir = URL(fileURLWithPath: physicalLocator)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        self.limits = .default
        self.capturedReplay = capturedReplay
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
                  let creationDate = Phase4AdapterSupport.double(session["creationDate"])
            else {
                return .failure(.malformedJSON)
            }
            guard !requests.isEmpty else { return .failure(.noVisibleMessages) }
            // VS Code may persist a stable non-object entry beside valid
            // requests. Match buildMessages' per-entry tolerance so one bad
            // sibling does not poison the unchanged locator's retry state.
            let requestObjects = requests.compactMap { JSONLAdapterSupport.object($0) }
            let userTexts = requestObjects.map(Self.extractUserText).filter { !$0.isEmpty }
            let assistantTexts = requestObjects.map(Self.extractAssistantText).filter { !$0.isEmpty }
            guard !userTexts.isEmpty || !assistantTexts.isEmpty else {
                return .failure(.noVisibleMessages)
            }
            if userTexts.count + assistantTexts.count > limits.maxMessages {
                return .failure(.messageLimitExceeded)
            }
            let lastTimestamp = Phase4AdapterSupport.double(requestObjects.last?["timestamp"])
            let sessionId = JSONLAdapterSupport.string(session["sessionId"]) ??
                URL(fileURLWithPath: capturedReplay?.logicalLocator ?? locator).deletingPathExtension().lastPathComponent
            let cwd: String
            if let capturedReplay {
                cwd = Self.workspaceCwd(workspaceData: capturedReplay.workspaceData) { _ in
                    capturedReplay.configurationData
                }
            } else {
                cwd = Self.readWorkspaceCwd(for: locator)
            }

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
        let result = try await streamMessagesWithMetadata(locator: locator, options: options)
        if options.limit == nil, result.truncatedAt != nil {
            throw ParserFailure.messageLimitExceeded
        }
        return result.messages
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let signature = ParsedTranscriptCache.Signature.forFile(locator)
        let messages: [NormalizedMessage]
        var parseFailure: ParserFailure? = nil
        if let cached = await messageCache.cached(locator: locator, signature: signature) {
            messages = cached
        } else {
            let prefix = try Self.buildMessagesWithMetadata(
                locator: locator,
                limits: limits
            )
            messages = prefix.messages
            parseFailure = prefix.parseFailure
            if parseFailure == nil, messages.count <= limits.maxMessages {
                await messageCache.store(locator: locator, signature: signature, messages: messages)
            }
        }
        return JSONLAdapterSupport.stream(
            JSONLAdapterSupport.boundedWindowWithMetadata(
                messages,
                options: options,
                maxMessages: limits.maxMessages,
                parseFailure: parseFailure
            )
        )
    }

    private static func buildMessagesWithMetadata(
        locator: String,
        limits: ParserLimits
    ) throws -> (messages: [NormalizedMessage], parseFailure: ParserFailure?) {
        let prefix = try readSessionPrefix(locator: locator, limits: limits)
        return (buildMessages(from: prefix.session), prefix.parseFailure)
    }

    private static func buildMessages(
        locator: String,
        limits: ParserLimits,
        meterMutationObjects: Bool = true
    ) throws -> [NormalizedMessage] {
        let session = try readSession(
            locator: locator,
            limits: limits,
            meterMutationObjects: meterMutationObjects
        )
        return buildMessages(from: session)
    }

    private static func buildMessages(from session: Phase4AdapterSupport.JSONObject?) -> [NormalizedMessage] {
        guard let session, let requests = JSONLAdapterSupport.array(session["requests"]) else { return [] }

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

    static func scanCapturedSource(
        physicalLocator: String, stagingRoot: String, logicalLocator: String, replayLayout: ArchiveReplayLayout
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        do {
            guard replayLayout.strategy == .fileSet, let context = replayLayout.vscodeWorkspaceContext,
                  let primary = replayLayout.entrypointRelativePath,
                  physicalLocator.utf8.elementsEqual((stagingRoot + "/" + primary).utf8),
                  logicalLocator.utf8.suffix(primary.utf8.count + 1).elementsEqual(("/" + primary).utf8),
                  let workspace = primary.split(separator: "/").first.map({ String($0) + "/workspace.json" }) else {
                return .failure(.malformedJSON)
            }
            let member = replayLayout.files?.first { $0.relativePath.utf8.elementsEqual(workspace.utf8) }
            let workspaceData = try member.map { try readCapturedWorkspace(root: stagingRoot, member: $0) }
            try context.validateWorkspaceData(workspaceData)
            return try await scanCapturedSource(physicalLocator: physicalLocator, logicalLocator: logicalLocator,
                workspaceData: workspaceData, configurationData: context.configurationData)
        } catch is CancellationError { throw CancellationError() }
        catch { return .failure(.malformedJSON) }
    }

    private static func readCapturedWorkspace(root: String, member: ArchiveFileSetEntry) throws -> Data {
        guard member.rawByteCount <= ArchiveVSCodeWorkspaceContext.maximumContextBytes else {
            throw ParserFailure.fileTooLarge
        }
        var directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ParserFailure.malformedJSON }
        defer { Darwin.close(directory) }
        let parts = member.relativePath.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let child = Darwin.openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ParserFailure.malformedJSON }
            Darwin.close(directory)
            directory = child
        }
        guard let leaf = parts.last else { throw ParserFailure.malformedJSON }
        let file = Darwin.openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw ParserFailure.malformedJSON }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == member.rawByteCount else { throw ParserFailure.malformedJSON }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ParserFailure.malformedJSON }
            if count == 0 { break }
            guard Int64(bytes.count + count) <= member.rawByteCount else { throw ParserFailure.malformedJSON }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard Int64(bytes.count) == member.rawByteCount,
              ArchiveV2Hash.sha256(bytes) == member.wholeSourceSHA256 else { throw ParserFailure.malformedJSON }
        return bytes
    }

    static func scanCapturedSource(
        physicalLocator: String, logicalLocator: String,
        workspaceData: Data?, configurationData: Data?
    ) async throws -> AdapterParseResult<CapturedSourceScan> {
        // Archive replay must not silently skip malformed records or consult
        // workspace files on the replay host. Missing frozen bytes stay missing.
        let (_, failure) = try JSONLAdapterSupport.readObjects(
            locator: physicalLocator, limits: .default, reportFailures: true, strictRecords: true)
        if let failure { return .failure(failure) }
        let adapter = VsCodeAdapter(physicalLocator: physicalLocator, capturedReplay: CapturedReplay(
            logicalLocator: logicalLocator, workspaceData: workspaceData, configurationData: configurationData))
        switch try await adapter.scanForIndexing(locator: physicalLocator) {
        case .failure(let failure): return .failure(failure)
        case .success(var scan):
            if let failure = scan.parseFailure { return .failure(failure) }
            scan.info.filePath = logicalLocator
            return .success(CapturedSourceScan(scan: scan, rawSourceSessionID: scan.info.id))
        }
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func readSession(
        locator: String,
        limits: ParserLimits,
        meterMutationObjects: Bool = true
    ) throws -> Phase4AdapterSupport.JSONObject? {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: locator, limits: limits, reportFailures: true,
            countsTowardMessageLimit: meterMutationObjects ? nil : { _ in false }
        )
        if let failure { throw failure }
        return try replayMutationLog(objects)
    }

    private static func readSessionPrefix(
        locator: String,
        limits: ParserLimits
    ) throws -> (session: Phase4AdapterSupport.JSONObject?, parseFailure: ParserFailure?) {
        let (objects, failure) = try JSONLAdapterSupport.readObjects(
            locator: locator,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: { _ in false }
        )
        return (try replayMutationLog(objects), failure)
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
        return workspaceCwd(workspaceData: try? Data(contentsOf: workspaceURL)) { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    }

    private static func workspaceCwd(workspaceData: Data?, configurationData: (String) -> Data?) -> String {
        guard let data = workspaceData,
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
            return readCodeWorkspaceFirstFolder(workspacePath, data: configurationData(workspacePath))
        }
        return ""
    }

    private static func readCodeWorkspaceFirstFolder(_ workspacePath: String, data: Data?) -> String {
        guard let data,
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
