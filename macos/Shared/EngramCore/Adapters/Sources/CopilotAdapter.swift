import Darwin
import Foundation

struct CopilotAdapterTestHooks: Sendable {
    var beforeCompositeIdentityValidation: @Sendable () -> Void
    var beforeCheckpointBodyIdentityValidation: @Sendable (Int) -> Void
    var beforeEventsWorkspaceIdentityValidation: @Sendable () -> Void

    init(
        beforeCompositeIdentityValidation: @escaping @Sendable () -> Void = {},
        beforeCheckpointBodyIdentityValidation: @escaping @Sendable (Int) -> Void = { _ in },
        beforeEventsWorkspaceIdentityValidation: @escaping @Sendable () -> Void = {}
    ) {
        self.beforeCompositeIdentityValidation = beforeCompositeIdentityValidation
        self.beforeCheckpointBodyIdentityValidation = beforeCheckpointBodyIdentityValidation
        self.beforeEventsWorkspaceIdentityValidation = beforeEventsWorkspaceIdentityValidation
    }
}

final class CopilotAdapter: SessionAdapter, ModificationFilteredSessionAdapter, Sendable {
    let source: SourceName = .copilot
    private static let maxCheckpointBodyLength = 4_000
    private let sessionRoot: URL
    private let limits: ParserLimits
    private let testHooks: CopilotAdapterTestHooks

    init(
        sessionRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")
            .path,
        limits: ParserLimits = .default,
        testHooks: CopilotAdapterTestHooks = CopilotAdapterTestHooks()
    ) {
        self.sessionRoot = URL(fileURLWithPath: sessionRoot)
        self.limits = limits
        self.testHooks = testHooks
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

    func indexingInputIdentity(locator: String) -> IndexingInputIdentity? {
        Self.compositeInputIdentity(locator: locator)
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        if Self.isCheckpointIndex(locator) {
            return parseCheckpointSessionInfo(locator: locator)
        }

        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            let messages = Self.messages(from: objects)
            if let failure {
                guard failure == .fileModifiedDuringParse, !messages.isEmpty else {
                    return .failure(failure)
                }
            }
            let workspace: [String: String]
            do {
                workspace = try readEventsWorkspace(locator: locator)
            } catch ParserFailure.fileModifiedDuringParse where !messages.isEmpty {
                workspace = [:]
            }
            return parseEventsSessionInfo(locator: locator, objects: objects, workspace: workspace)
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        let initialIdentity = indexingInputIdentity(locator: locator)
        if Self.isCheckpointIndex(locator) {
            do {
                let snapshot = try Self.checkpointSnapshot(locator: locator,
                    limits: limits,
                    beforeBodyIdentityValidation: testHooks.beforeCheckpointBodyIdentityValidation
                )
                let hasMoreMessages = snapshot.entries.count > max(limits.maxMessages, 0)
                let visibleSnapshot = CheckpointSnapshot(
                    workspace: snapshot.workspace,
                    entries: Array(snapshot.entries.prefix(max(limits.maxMessages, 0))),
                    messages: snapshot.messages
                )
                switch checkpointSessionInfo(locator: locator, snapshot: visibleSnapshot) {
                case .failure(let failure):
                    return .failure(failure)
                case .success(let info):
                    return validatedIndexingScan(
                        IndexingScan(
                            info: info,
                            messages: snapshot.messages,
                            parseFailure: hasMoreMessages ? .messageLimitExceeded : nil
                        ),
                        locator: locator,
                        initialIdentity: initialIdentity
                    )
                }
            } catch let failure as ParserFailure {
                return .failure(failure)
            } catch {
                return .failure(.malformedJSON)
            }
        }

        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            let messages = Self.messages(from: objects)
            if failure != nil, messages.isEmpty { return .failure(failure!) }
            var parseFailure = failure
            let workspace: [String: String]
            do {
                workspace = try readEventsWorkspace(locator: locator)
            } catch let failure as ParserFailure where !messages.isEmpty {
                workspace = [:]
                parseFailure = failure
            }
            switch parseEventsSessionInfo(locator: locator, objects: objects, workspace: workspace) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let info):
                return validatedIndexingScan(
                    IndexingScan(info: info, messages: messages, parseFailure: parseFailure),
                    locator: locator,
                    initialIdentity: initialIdentity
                )
            }
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private func validatedIndexingScan(
        _ scan: IndexingScan,
        locator: String,
        initialIdentity: IndexingInputIdentity?
    ) -> AdapterParseResult<IndexingScan> {
        testHooks.beforeCompositeIdentityValidation()
        guard let initialIdentity,
              initialIdentity == indexingInputIdentity(locator: locator)
        else {
            if !Self.isCheckpointIndex(locator), !scan.messages.isEmpty {
                var prefix = scan
                prefix.parseFailure = .fileModifiedDuringParse
                return .success(prefix)
            }
            return .failure(.fileModifiedDuringParse)
        }
        return .success(scan)
    }

    private func parseEventsSessionInfo(
        locator: String,
        objects: [JSONLAdapterSupport.JSONObject],
        workspace: [String: String]
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        let sessionDirectory = URL(fileURLWithPath: locator).deletingLastPathComponent()
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

            if type == "session.start" {
                let context = JSONLAdapterSupport.object(data?["context"])
                if startTime.isEmpty, let value = JSONLAdapterSupport.string(data?["startTime"]) {
                    startTime = value
                }
                if cwd.isEmpty, let value = JSONLAdapterSupport.string(context?["cwd"]) {
                    cwd = value
                }
            } else if let message = Self.message(from: object) {
                if message.role == .user {
                    userCount += 1
                    if firstUserText.isEmpty { firstUserText = String(message.content.prefix(200)) }
                } else {
                    assistantCount += 1
                }
                if let timestamp = message.timestamp {
                    if startTime.isEmpty || timestamp < startTime { startTime = timestamp }
                    if timestamp > endTime { endTime = timestamp }
                }
            }
        }

        guard !sessionId.isEmpty else { return .failure(.malformedJSON) }
        guard userCount + assistantCount > 0 else { return .failure(.noVisibleMessages) }

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
                sizeBytes: Self.compositeSizeBytes(locator: locator),
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

    private func readEventsWorkspace(locator: String) throws -> [String: String] {
        let sessionDirectory = URL(fileURLWithPath: locator).deletingLastPathComponent()
        return try Self.readWorkspace(
            sessionDirectory.appendingPathComponent("workspace.yaml"),
            limits: limits,
            beforeIdentityValidation: testHooks.beforeEventsWorkspaceIdentityValidation
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        if Self.isCheckpointIndex(locator) {
            let result = try Self.checkpointMessagesWithMetadata(
                locator: locator,
                limits: limits,
                options: options,
                beforeBodyIdentityValidation: testHooks.beforeCheckpointBodyIdentityValidation
            )
            return JSONLAdapterSupport.stream(result.messages)
        }

        if options.limit == nil {
            let result = try JSONLAdapterSupport.wholeDocumentMessagesWithMetadata(
                locator: locator,
                options: options,
                limits: limits,
                transform: Self.messages(from:),
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            return JSONLAdapterSupport.stream(result.messages)
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
        if Self.isCheckpointIndex(locator) {
            let result = try Self.checkpointMessagesWithMetadata(
                locator: locator,
                limits: limits,
                options: options,
                beforeBodyIdentityValidation: testHooks.beforeCheckpointBodyIdentityValidation
            )
            return JSONLAdapterSupport.stream(result)
        }
        let result = try JSONLAdapterSupport.wholeDocumentMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            transform: Self.messages(from:),
            countsTowardMessageLimit: { Self.message(from: $0) != nil }
        )
        return JSONLAdapterSupport.stream(result)
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private func parseCheckpointSessionInfo(locator: String) -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let snapshot = try Self.checkpointMetadata(locator: locator, limits: limits)
            return checkpointSessionInfo(locator: locator, snapshot: snapshot)
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    private func checkpointSessionInfo(
        locator: String,
        snapshot: CheckpointSnapshot
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        let checkpointIndexURL = URL(fileURLWithPath: locator)
        let sessionDirectory = checkpointIndexURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = snapshot.workspace
        let entries = snapshot.entries
        guard !entries.isEmpty else {
            return .failure(.malformedJSON)
        }
        if entries.count > limits.maxMessages {
            return .failure(.messageLimitExceeded)
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
                assistantMessageCount: entries.count,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: entries.first?.title,
                filePath: locator,
                sizeBytes: Self.compositeSizeBytes(locator: locator),
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
        do {
            var sniffLimits = limits
            sniffLimits.maxFileBytes = .max
            let (url, _) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: sniffLimits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            for line in try reader.readLines() {
                guard let object = JSONLAdapterSupport.parseObject(line) else { continue }
                if message(from: object) != nil {
                    return true
                }
            }
            return !reader.failures.isEmpty
        } catch {
            // The caller already observed events.jsonl. Keep it selected when a
            // read race or parser limit prevents sniffing so the real parse can
            // record the failure instead of silently falling back to checkpoints.
            return true
        }
    }

    private static func sessionDirectory(for locator: String) -> URL {
        let url = URL(fileURLWithPath: locator)
        if isCheckpointIndex(locator) {
            return url.deletingLastPathComponent().deletingLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    private static func compositeInputPaths(locator: String) -> [String] {
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
        paths.append(contentsOf: JSONLAdapterSupport.directChildren(of: checkpointsDir, includingHidden: true)
            .filter { url in
                guard url.pathExtension.lowercased() == "md" else { return false }
                var info = stat()
                return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
            }
            .map(\.path))
        return paths
    }

    private static func compositeModificationDate(
        locator: String,
        fileManager: FileManager,
        limits _: ParserLimits
    ) -> Date? {
        _ = fileManager
        guard let identity = compositeInputIdentity(locator: locator) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(identity.modifiedAtNanos) / 1_000_000_000)
    }

    private static func compositeSizeBytes(locator: String) -> Int64 {
        compositeInputIdentity(locator: locator)?.sizeBytes ?? 0
    }

    private static func compositeInputIdentity(locator: String) -> IndexingInputIdentity? {
        var totalSize: Int64 = 0
        var newestNanos: Int64 = 0
        var locatorInode: Int64?
        var locatorDevice: Int64?
        var foundLocator = false

        for path in Set(compositeInputPaths(locator: locator)) {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else { continue }
            if kind == S_IFREG {
                totalSize += Int64(info.st_size)
            }
            let modifiedNanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec)
            newestNanos = max(newestNanos, modifiedNanos)
            if path == locator {
                foundLocator = true
                locatorInode = Int64(info.st_ino)
                locatorDevice = Int64(info.st_dev)
            }
        }

        guard foundLocator else { return nil }
        return IndexingInputIdentity(
            sizeBytes: totalSize,
            modifiedAtNanos: newestNanos,
            locatorInode: locatorInode,
            locatorDevice: locatorDevice
        )
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard let type = JSONLAdapterSupport.string(object["type"]),
              type == "user.message" || type == "assistant.message"
        else {
            return nil
        }
        let data = JSONLAdapterSupport.object(object["data"])
        let content = JSONLAdapterSupport.string(data?["content"]) ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return NormalizedMessage(
            role: type == "user.message" ? .user : .assistant,
            content: content,
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

    private struct CheckpointSnapshot {
        let workspace: [String: String]
        let entries: [CheckpointEntry]
        let messages: [NormalizedMessage]
    }

    private static func checkpointSnapshot(
        locator: String,
        limits: ParserLimits,
        beforeBodyIdentityValidation: (Int) -> Void = { _ in }
    ) throws -> CheckpointSnapshot {
        let metadata = try checkpointMetadata(locator: locator, limits: limits)
        let indexURL = URL(fileURLWithPath: locator)
        return CheckpointSnapshot(
            workspace: metadata.workspace,
            entries: metadata.entries,
            messages: try metadata.entries.prefix(max(limits.maxMessages, 0)).map { entry in
                NormalizedMessage(
                    role: .assistant,
                    content: try checkpointMessageContent(
                        entry,
                        checkpointIndexURL: indexURL,
                        limits: limits,
                        beforeIdentityValidation: beforeBodyIdentityValidation
                    ),
                    timestamp: nil
                )
            }
        )
    }

    private static func checkpointMetadata(
        locator: String,
        limits: ParserLimits
    ) throws -> CheckpointSnapshot {
        let indexURL = URL(fileURLWithPath: locator)
        let sessionDirectory = indexURL.deletingLastPathComponent().deletingLastPathComponent()
        let workspaceURL = sessionDirectory.appendingPathComponent("workspace.yaml")
        let workspaceContent = JSONLAdapterSupport.fileExists(workspaceURL.path)
            ? try JSONLAdapterSupport.readString(locator: workspaceURL.path, limits: limits)
            : ""
        let indexContent = try JSONLAdapterSupport.readString(locator: locator, limits: limits)
        let entries = checkpointEntries(content: indexContent)
        return CheckpointSnapshot(
            workspace: parseWorkspace(content: workspaceContent),
            entries: entries,
            messages: []
        )
    }

    private static func checkpointMessagesWithMetadata(
        locator: String,
        limits: ParserLimits,
        options: StreamMessagesOptions,
        beforeBodyIdentityValidation: (Int) -> Void
    ) throws -> JSONLAdapterSupport.WindowedMessagesResult {
        let indexURL = URL(fileURLWithPath: locator)
        let indexContent = try JSONLAdapterSupport.readString(locator: locator, limits: limits)
        let entries = checkpointEntries(content: indexContent)
        var messages: [NormalizedMessage] = []
        var parseFailure: ParserFailure?

        for entry in entries.prefix(max(limits.maxMessages, 0)) {
            do {
                messages.append(NormalizedMessage(
                    role: .assistant,
                    content: try checkpointMessageContent(
                        entry,
                        checkpointIndexURL: indexURL,
                        limits: limits,
                        beforeIdentityValidation: beforeBodyIdentityValidation
                    ),
                    timestamp: nil
                ))
            } catch let failure as ParserFailure where failure == .fileModifiedDuringParse && !messages.isEmpty {
                parseFailure = failure
                break
            }
        }

        return JSONLAdapterSupport.boundedWindowWithMetadata(
            messages,
            options: options,
            maxMessages: limits.maxMessages,
            hasMoreMessages: entries.count > messages.count && parseFailure == nil,
            parseFailure: parseFailure
        )
    }

    private static func isCheckpointIndex(_ locator: String) -> Bool {
        let url = URL(fileURLWithPath: locator)
        return url.lastPathComponent == "index.md"
            && url.deletingLastPathComponent().lastPathComponent == "checkpoints"
    }

    private static func checkpointMessages(
        locator: String,
        limits: ParserLimits
    ) throws -> [NormalizedMessage] {
        let checkpointIndexURL = URL(fileURLWithPath: locator)
        return try checkpointEntries(checkpointIndexURL, limits: limits).map { entry in
            NormalizedMessage(
                role: .assistant,
                content: try checkpointMessageContent(
                    entry,
                    checkpointIndexURL: checkpointIndexURL,
                    limits: limits
                ),
                timestamp: nil
            )
        }
    }

    private static func hasCheckpointEntries(_ url: URL, limits: ParserLimits) -> Bool {
        !checkpointEntries(url, limits: limits).isEmpty
    }

    private static func checkpointEntries(_ url: URL, limits: ParserLimits) -> [CheckpointEntry] {
        guard let content = try? JSONLAdapterSupport.readString(locator: url.path, limits: limits) else {
            return []
        }

        return checkpointEntries(content: content)
    }

    private static func checkpointEntries(content: String) -> [CheckpointEntry] {
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
        limits: ParserLimits,
        beforeIdentityValidation: (Int) -> Void = { _ in }
    ) throws -> String {
        let title = "Checkpoint \(entry.number): \(entry.title)"
        guard let body = try checkpointBody(
            entry,
            checkpointIndexURL: checkpointIndexURL,
            limits: limits,
            beforeIdentityValidation: beforeIdentityValidation
        ) else {
            return title
        }
        return "\(title)\n\n\(body)"
    }

    private static func checkpointBody(
        _ entry: CheckpointEntry,
        checkpointIndexURL: URL,
        limits: ParserLimits,
        beforeIdentityValidation: (Int) -> Void = { _ in }
    ) throws -> String? {
        guard let fileName = entry.fileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.hasSuffix(".md")
        else {
            return nil
        }
        let bodyURL = checkpointIndexURL
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
        let content: String
        do {
            let (url, before) = try JSONLAdapterSupport.prepareFile(locator: bodyURL.path, limits: limits)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: maxCheckpointBodyLength) ?? Data()
            beforeIdentityValidation(entry.number)
            let after: FileIdentity
            do {
                after = try limits.fileIdentity(for: url)
            } catch {
                throw ParserFailure.fileModifiedDuringParse
            }
            guard limits.isSameFileIdentity(before, after) else {
                throw ParserFailure.fileModifiedDuringParse
            }
            if let decoded = String(data: prefix, encoding: .utf8) {
                content = decoded
            } else if before.sizeBytes > Int64(prefix.count) {
                var boundarySafePrefix = prefix
                var decoded: String?
                for _ in 0..<3 where !boundarySafePrefix.isEmpty {
                    boundarySafePrefix.removeLast()
                    if let candidate = String(data: boundarySafePrefix, encoding: .utf8) {
                        decoded = candidate
                        break
                    }
                }
                guard let decoded else { return nil }
                content = decoded
            } else {
                return nil
            }
        } catch let failure as ParserFailure {
            if failure == .fileModifiedDuringParse { throw failure }
            return nil
        } catch {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func readWorkspace(
        _ url: URL,
        limits: ParserLimits,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> [String: String] {
        let content: String
        do {
            content = try JSONLAdapterSupport.readString(
                locator: url.path,
                limits: limits,
                beforeIdentityValidation: beforeIdentityValidation
            )
        } catch let failure as ParserFailure {
            if failure == .fileModifiedDuringParse { throw failure }
            return [:]
        } catch {
            return [:]
        }

        return parseWorkspace(content: content)
    }

    private static func parseWorkspace(content: String) -> [String: String] {
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
