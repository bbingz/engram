import Foundation

final class CopilotAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .copilot
    private static let maxCheckpointBodyLength = 4_000
    private let sessionRoot: URL
    private let limits: ParserLimits

    init(
        sessionRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")
            .path,
        limits: ParserLimits = .default
    ) {
        self.sessionRoot = URL(fileURLWithPath: sessionRoot)
        self.limits = limits
    }

    func detect() async -> Bool {
        JSONLAdapterSupport.isDirectory(sessionRoot)
    }

    func listSessionLocators() async throws -> [String] {
        var locators: [String] = []
        for sessionURL in JSONLAdapterSupport.directChildren(of: sessionRoot)
            where JSONLAdapterSupport.isDirectory(sessionURL)
        {
            let eventsURL = sessionURL.appendingPathComponent("events.jsonl")
            // Prefer events only when they contain indexable conversation turns.
            // Bare session.start (or empty) files must not hide a valid checkpoint.
            if JSONLAdapterSupport.fileExists(eventsURL.path),
               Self.eventsHaveConversation(eventsURL.path, limits: limits)
            {
                locators.append(eventsURL.path)
                continue
            }
            let checkpointIndexURL = sessionURL
                .appendingPathComponent("checkpoints", isDirectory: true)
                .appendingPathComponent("index.md")
            if Self.hasCheckpointEntries(checkpointIndexURL, limits: limits) {
                locators.append(checkpointIndexURL.path)
            }
        }
        return locators.sorted()
    }

    // Audit COPILOT-AUX-001: workspace.yaml / checkpoint body mtimes must keep
    // the session in the recent set even when the main locator is stale.
    func listSessionLocators(
        modifiedSince: Date,
        fileManager: FileManager
    ) async throws -> [String] {
        try await listSessionLocators().filter { locator in
            Self.compositeModificationDate(locator: locator, fileManager: fileManager, limits: limits)
                .map { $0 >= modifiedSince } ?? false
        }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        if Self.isCheckpointIndex(locator) {
            return parseCheckpointSessionInfo(locator: locator)
        }

        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { return .failure(failure) }

            let sessionDirectory = URL(fileURLWithPath: locator).deletingLastPathComponent()
            let workspace = Self.readWorkspace(sessionDirectory.appendingPathComponent("workspace.yaml"), limits: limits)
            let sessionId = workspace["id"] ?? sessionDirectory.lastPathComponent
            var startTime = workspace["created_at"] ?? ""
            var endTime = workspace["updated_at"] ?? ""
            var cwd = workspace["cwd"] ?? ""
            var userCount = 0
            var assistantCount = 0
            var firstUserText = ""

            for object in objects {
                guard let type = JSONLAdapterSupport.string(object["type"]) else { continue }
                let data = JSONLAdapterSupport.object(object["data"])
                let timestamp = JSONLAdapterSupport.string(object["timestamp"])

                if type == "session.start" {
                    let context = JSONLAdapterSupport.object(data?["context"])
                    if startTime.isEmpty, let value = JSONLAdapterSupport.string(data?["startTime"]) {
                        startTime = value
                    }
                    if cwd.isEmpty, let value = JSONLAdapterSupport.string(context?["cwd"]) {
                        cwd = value
                    }
                } else if type == "user.message" {
                    userCount += 1
                    if firstUserText.isEmpty, let content = JSONLAdapterSupport.string(data?["content"]) {
                        firstUserText = String(content.prefix(200))
                    }
                    if let timestamp {
                        if startTime.isEmpty || timestamp < startTime { startTime = timestamp }
                        if timestamp > endTime { endTime = timestamp }
                    }
                } else if type == "assistant.message" {
                    assistantCount += 1
                    if let timestamp, timestamp > endTime {
                        endTime = timestamp
                    }
                }
            }

            guard !sessionId.isEmpty, userCount + assistantCount > 0 else {
                return .failure(.malformedJSON)
            }

            return .success(
                NormalizedSessionInfo(
                    id: sessionId,
                    source: .copilot,
                    startTime: startTime,
                    endTime: endTime != startTime ? endTime : nil,
                    cwd: cwd,
                    project: nil,
                    model: nil,
                    messageCount: userCount + assistantCount,
                    userMessageCount: userCount,
                    assistantMessageCount: assistantCount,
                    toolMessageCount: 0,
                    systemMessageCount: 0,
                    summary: workspace["summary"] ?? (firstUserText.isEmpty ? nil : firstUserText),
                    filePath: locator,
                    sizeBytes: Self.compositeSizeBytes(locator: locator, limits: limits),
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
        if Self.isCheckpointIndex(locator) {
            let checkpointIndexURL = URL(fileURLWithPath: locator)
            let messages = Self.checkpointEntries(checkpointIndexURL, limits: limits).map { entry in
                NormalizedMessage(
                    role: .system,
                    content: Self.checkpointMessageContent(entry, checkpointIndexURL: checkpointIndexURL, limits: limits),
                    timestamp: nil
                )
            }
            return JSONLAdapterSupport.stream(JSONLAdapterSupport.applyWindow(messages, options: options))
        }

        if options.limit == nil {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(locator: locator, limits: limits)
            if let failure { throw failure }
            return JSONLAdapterSupport.stream(
                JSONLAdapterSupport.applyWindow(Self.messages(from: objects), options: options)
            )
        }

        let messages = try JSONLAdapterSupport.windowedMessages(
            locator: locator,
            options: options,
            limits: limits,
            transform: Self.message(from:)
        )
        return JSONLAdapterSupport.stream(messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        if Self.isCheckpointIndex(locator) || options.limit != nil {
            return StreamMessagesResult(messages: try await streamMessages(locator: locator, options: options))
        }
        let result = try JSONLAdapterSupport.wholeDocumentMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            transform: Self.messages(from:)
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func parseCheckpointSessionInfo(locator: String) -> AdapterParseResult<NormalizedSessionInfo> {
        let checkpointIndexURL = URL(fileURLWithPath: locator)
        let sessionDirectory = checkpointIndexURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = Self.readWorkspace(sessionDirectory.appendingPathComponent("workspace.yaml"), limits: limits)
        let entries = Self.checkpointEntries(checkpointIndexURL, limits: limits)
        guard !entries.isEmpty else {
            return .failure(.malformedJSON)
        }

        let sessionId = workspace["id"] ?? sessionDirectory.lastPathComponent
        return .success(
            NormalizedSessionInfo(
                id: sessionId,
                source: .copilot,
                startTime: workspace["created_at"] ?? "",
                endTime: workspace["updated_at"],
                cwd: workspace["cwd"] ?? "",
                project: nil,
                model: nil,
                messageCount: entries.count,
                userMessageCount: 0,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: entries.count,
                summary: entries.first?.title,
                filePath: locator,
                sizeBytes: Self.compositeSizeBytes(locator: locator, limits: limits),
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
    }

    /// Early-exit streaming sniff: stop at the first user/assistant turn so
    /// discovery does not materialize entire histories (or fail solely because
    /// the active file grew mid-read).
    private static func eventsHaveConversation(_ locator: String, limits: ParserLimits) -> Bool {
        let url = URL(fileURLWithPath: locator)
        guard FileManager.default.fileExists(atPath: locator) else { return false }
        do {
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            for line in try reader.readLines() {
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let type = JSONLAdapterSupport.string(object["type"])
                if type == "user.message" || type == "assistant.message" {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    private static func sessionDirectory(for locator: String) -> URL {
        let url = URL(fileURLWithPath: locator)
        if isCheckpointIndex(locator) {
            return url.deletingLastPathComponent().deletingLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    private static func compositeInputPaths(locator: String, limits: ParserLimits) -> [String] {
        var paths = [locator]
        let sessionDir = sessionDirectory(for: locator)
        paths.append(sessionDir.appendingPathComponent("workspace.yaml").path)
        paths.append(sessionDir.path)
        // Always watch events.jsonl so conversation appear/disappear transitions
        // re-enter the recent set even when the selected locator is the checkpoint.
        paths.append(sessionDir.appendingPathComponent("events.jsonl").path)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        // Directory mtime covers body create/delete when index.md itself is stale.
        paths.append(checkpointsDir.path)
        if isCheckpointIndex(locator) {
            let checkpointIndexURL = URL(fileURLWithPath: locator)
            for entry in checkpointEntries(checkpointIndexURL, limits: limits) {
                guard let fileName = entry.fileName,
                      fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                      fileName.hasSuffix(".md")
                else { continue }
                paths.append(
                    checkpointIndexURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(fileName)
                        .path
                )
            }
        }
        return paths
    }

    private static func compositeModificationDate(
        locator: String,
        fileManager: FileManager,
        limits: ParserLimits
    ) -> Date? {
        compositeInputPaths(locator: locator, limits: limits).compactMap { path in
            guard fileManager.fileExists(atPath: path) else { return nil }
            return try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
        }
        .max()
    }

    private static func compositeSizeBytes(locator: String, limits: ParserLimits) -> Int64 {
        // Count every file the adapter actually consumes so aux-only rewrites
        // change sizeBytes and force snapshot re-merge. Directories are mtime-only.
        let fileManager = FileManager.default
        return Set(compositeInputPaths(locator: locator, limits: limits))
            .filter { path in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    return false
                }
                return !isDirectory.boolValue
            }
            .reduce(Int64(0)) { partial, path in
                partial + Phase4AdapterSupport.fileSize(path)
            }
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user.message" || type == "assistant.message"
        else {
            return nil
        }
        let data = JSONLAdapterSupport.object(object["data"])
        return NormalizedMessage(
            role: type == "user.message" ? .user : .assistant,
            content: JSONLAdapterSupport.string(data?["content"]) ?? "",
            timestamp: JSONLAdapterSupport.string(object["timestamp"]),
            toolCalls: nil,
            usage: nil
        )
    }

    private static func messages(from objects: [JSONLAdapterSupport.JSONObject]) -> [NormalizedMessage] {
        var messages = objects.compactMap(Self.message(from:))
        guard let usage = shutdownUsage(from: objects),
              let index = messages.lastIndex(where: { $0.role == .assistant })
        else {
            return messages
        }
        messages[index].usage = usage
        return messages
    }

    private static func shutdownUsage(from objects: [JSONLAdapterSupport.JSONObject]) -> TokenUsage? {
        var total = TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)

        for object in objects {
            guard JSONLAdapterSupport.string(object["type"]) == "session.shutdown",
                  let data = JSONLAdapterSupport.object(object["data"]),
                  let modelMetrics = JSONLAdapterSupport.object(data["modelMetrics"])
            else {
                continue
            }

            for metricValue in modelMetrics.values {
                guard let metric = JSONLAdapterSupport.object(metricValue),
                      let usage = JSONLAdapterSupport.object(metric["usage"])
                else {
                    continue
                }
                total.inputTokens += int(usage["inputTokens"])
                total.outputTokens += int(usage["outputTokens"])
                total.cacheReadTokens = (total.cacheReadTokens ?? 0) + int(usage["cacheReadTokens"])
                total.cacheCreationTokens = (total.cacheCreationTokens ?? 0) + int(usage["cacheWriteTokens"])
            }
        }

        guard total.inputTokens > 0
            || total.outputTokens > 0
            || (total.cacheReadTokens ?? 0) > 0
            || (total.cacheCreationTokens ?? 0) > 0
        else {
            return nil
        }
        return total
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value) ?? 0
        default:
            return 0
        }
    }

    private struct CheckpointEntry: Equatable {
        let number: Int
        let title: String
        let fileName: String?
    }

    private static func isCheckpointIndex(_ locator: String) -> Bool {
        let url = URL(fileURLWithPath: locator)
        return url.lastPathComponent == "index.md"
            && url.deletingLastPathComponent().lastPathComponent == "checkpoints"
    }

    private static func hasCheckpointEntries(_ url: URL, limits: ParserLimits) -> Bool {
        !checkpointEntries(url, limits: limits).isEmpty
    }

    private static func checkpointEntries(_ url: URL, limits: ParserLimits) -> [CheckpointEntry] {
        guard let content = try? JSONLAdapterSupport.readString(locator: url.path, limits: limits) else {
            return []
        }

        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> CheckpointEntry? in
                let columns = line
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard columns.count >= 4,
                      let number = Int(columns[1]),
                      !columns[2].isEmpty
                else {
                    return nil
                }
                return CheckpointEntry(
                    number: number,
                    title: columns[2],
                    fileName: columns[3].isEmpty ? nil : columns[3]
                )
            }
    }

    private static func checkpointMessageContent(
        _ entry: CheckpointEntry,
        checkpointIndexURL: URL,
        limits: ParserLimits
    ) -> String {
        let title = "Checkpoint \(entry.number): \(entry.title)"
        guard let body = checkpointBody(entry, checkpointIndexURL: checkpointIndexURL, limits: limits) else {
            return title
        }
        return "\(title)\n\n\(body)"
    }

    private static func checkpointBody(
        _ entry: CheckpointEntry,
        checkpointIndexURL: URL,
        limits: ParserLimits
    ) -> String? {
        guard let fileName = entry.fileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.hasSuffix(".md")
        else {
            return nil
        }
        let bodyURL = checkpointIndexURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
        guard let content = try? JSONLAdapterSupport.readString(locator: bodyURL.path, limits: limits) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maxCheckpointBodyLength))
    }

    private static func readWorkspace(_ url: URL, limits: ParserLimits) -> [String: String] {
        guard let content = try? JSONLAdapterSupport.readString(locator: url.path, limits: limits) else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex])
            guard key.range(of: #"^\w+$"#, options: .regularExpression) != nil else { continue }
            let valueStart = line.index(after: separatorIndex)
            result[key] = stripYAMLQuotes(String(line[valueStart...]).trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func stripYAMLQuotes(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" || first == "'"),
              first == last
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
