import Darwin
import CryptoKit
import Foundation

struct JSONLIdentityTestHooks: Sendable {
    var beforeFinalIdentityValidation: @Sendable () -> Void

    init(beforeFinalIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeFinalIdentityValidation = beforeFinalIdentityValidation
    }
}

enum JSONLAdapterSupport {
    typealias JSONObject = [String: Any]
    private static let checkpointBoundaryBytes = 4 * 1024

    struct JSONLCheckpoint {
        let parsedOffset: Int64
        let boundaryHash: String
    }

    struct TailObjectsResult {
        let objects: [JSONObject]
        let parsedOffset: Int64
        let boundaryHash: String
        let failure: ParserFailure?
    }

    struct WindowedMessagesResult {
        let messages: [NormalizedMessage]
        let totalKnownComplete: Bool
        let truncatedAt: Int?
        let maxRawMessages: Int?
        let parseFailure: ParserFailure?

        init(
            messages: [NormalizedMessage],
            totalKnownComplete: Bool,
            truncatedAt: Int?,
            maxRawMessages: Int? = nil,
            parseFailure: ParserFailure? = nil
        ) {
            self.messages = messages
            self.totalKnownComplete = totalKnownComplete
            self.truncatedAt = truncatedAt
            self.maxRawMessages = maxRawMessages
            self.parseFailure = parseFailure
        }

        var truncated: Bool { truncatedAt != nil || !totalKnownComplete }
    }

    static func fileExists(_ path: String) -> Bool {
        statMode(path) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        statMode(url.path) == S_IFDIR
    }

    static func directChildren(of url: URL, includingHidden: Bool = false) -> [URL] {
        guard isDirectory(url) else { return [] }
        let root = url.resolvingSymlinksInPath()
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        return (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ))?
            .filter { !isSymlink($0) }
            .sorted { $0.path < $1.path } ?? []
    }

    static func requiredDirectChildren(of url: URL, includingHidden: Bool = false) throws -> [URL] {
        try Task.checkCancellation()
        // Keep this helper safe for non-canonical callers even though Claude
        // profile roots are already resolved before enumeration. Match
        // `directChildren`: a symlinked root is supported, but symlink children
        // are not traversed as source content.
        let root = url.resolvingSymlinksInPath()
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        )
        try Task.checkCancellation()
        return children
            .filter { !isSymlink($0) }
            .sorted { $0.path < $1.path }
    }

    static func recursiveFiles(under root: URL, matching predicate: (URL) -> Bool) throws -> [String] {
        try Task.checkCancellation()
        guard isDirectory(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []
        for case let url as URL in enumerator where isRegularFile(url) && predicate(url) {
            try Task.checkCancellation()
            files.append(url.path)
        }
        try Task.checkCancellation()
        return files.sorted()
    }

    static func prepareFile(locator: String, limits: ParserLimits) throws -> (URL, FileIdentity) {
        let url = URL(fileURLWithPath: locator)
        guard isRegularFile(url) else {
            throw ParserFailure.fileMissing
        }
        let identity = try limits.fileIdentity(for: url)
        if let failure = limits.validateFileSize(identity) {
            throw failure
        }
        return (url, identity)
    }

    static func readString(
        locator: String,
        limits: ParserLimits,
        encoding: String.Encoding = .utf8,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> String {
        let (url, before) = try prepareFile(locator: locator, limits: limits)
        let content = try String(contentsOf: url, encoding: encoding)
        beforeIdentityValidation()
        let after: FileIdentity
        do {
            after = try limits.fileIdentity(for: url)
        } catch {
            throw ParserFailure.fileModifiedDuringParse
        }
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return content
    }

    static func readObjects(
        locator: String,
        limits: ParserLimits,
        reportFailures: Bool = false,
        countsTowardMessageLimit: ((JSONObject) -> Bool)? = nil,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> ([JSONObject], ParserFailure?) {
        try autoreleasepool {
            let (url, before) = try prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var objects: [JSONObject] = []
            var messageCount = 0
            var exceededMessageLimit = false

            for line in try reader.readLines() {
                guard let object = parseObject(line) else { continue }
                if countsTowardMessageLimit?(object) ?? true {
                    guard messageCount < limits.maxMessages else {
                        exceededMessageLimit = true
                        break
                    }
                    messageCount += 1
                }
                objects.append(object)
            }

            beforeIdentityValidation()
            let capFailure: ParserFailure? = reportFailures && exceededMessageLimit
                ? .messageLimitExceeded
                : nil
            let after: FileIdentity
            do {
                after = try limits.fileIdentity(for: url)
            } catch {
                return (objects, capFailure ?? .fileModifiedDuringParse)
            }
            guard limits.isSameFileIdentity(before, after) else {
                return (objects, capFailure ?? .fileModifiedDuringParse)
            }
            if let capFailure { return (objects, capFailure) }
            if reportFailures, let failure = reader.failures.first {
                return (objects, failure)
            }
            return (objects, nil)
        }
    }

    static func checkpoint(locator: String, limits: ParserLimits) throws -> JSONLCheckpoint {
        let (url, before) = try prepareFile(locator: locator, limits: limits)
        let parsedOffset = try completeLineOffset(fileURL: url, fileSize: before.sizeBytes)
        let boundaryHash = try boundaryHash(fileURL: url, offset: parsedOffset)
        let after = try limits.fileIdentity(for: url)
        guard limits.isSameFileIdentity(before, after) else {
            throw ParserFailure.fileModifiedDuringParse
        }
        return JSONLCheckpoint(parsedOffset: parsedOffset, boundaryHash: boundaryHash)
    }

    static func readTailObjects(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String,
        limits: ParserLimits,
        countsTowardMessageLimit: (JSONObject) -> Bool = { _ in true }
    ) throws -> TailObjectsResult {
        try autoreleasepool {
            let (url, before) = try prepareFile(locator: locator, limits: limits)
            guard parsedOffset >= 0, parsedOffset <= before.sizeBytes else {
                return TailObjectsResult(objects: [], parsedOffset: parsedOffset, boundaryHash: "", failure: nil)
            }
            guard try boundaryHash(fileURL: url, offset: parsedOffset) == expectedBoundaryHash else {
                return TailObjectsResult(objects: [], parsedOffset: parsedOffset, boundaryHash: "", failure: nil)
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(parsedOffset))
            let tail = try handle.readToEnd() ?? Data()
            let completeLength = completePrefixLength(tail)
            let completeData = tail.prefix(completeLength)
            var objects: [JSONObject] = []
            var producedMessageCount = 0

            for lineData in completeData.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                if lineData.isEmpty { continue }
                guard lineData.count <= limits.maxLineBytes else {
                    return TailObjectsResult(
                        objects: objects,
                        parsedOffset: parsedOffset + Int64(completeLength),
                        boundaryHash: try boundaryHash(fileURL: url, offset: parsedOffset + Int64(completeLength)),
                        failure: .lineTooLarge
                    )
                }
                guard let line = String(data: Data(lineData), encoding: .utf8) else {
                    return TailObjectsResult(
                        objects: objects,
                        parsedOffset: parsedOffset + Int64(completeLength),
                        boundaryHash: try boundaryHash(fileURL: url, offset: parsedOffset + Int64(completeLength)),
                        failure: .invalidUtf8
                    )
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let object = parseObject(trimmed) else { continue }
                if countsTowardMessageLimit(object) {
                    guard producedMessageCount < limits.maxMessages else {
                        return TailObjectsResult(
                            objects: objects,
                            parsedOffset: parsedOffset + Int64(completeLength),
                            boundaryHash: try boundaryHash(fileURL: url, offset: parsedOffset + Int64(completeLength)),
                            failure: .messageLimitExceeded
                        )
                    }
                    producedMessageCount += 1
                }
                objects.append(object)
            }

            let newParsedOffset = parsedOffset + Int64(completeLength)
            let newBoundaryHash = try boundaryHash(fileURL: url, offset: newParsedOffset)
            let after = try limits.fileIdentity(for: url)
            guard limits.isSameFileIdentity(before, after) else {
                return TailObjectsResult(
                    objects: objects,
                    parsedOffset: newParsedOffset,
                    boundaryHash: newBoundaryHash,
                    failure: .fileModifiedDuringParse
                )
            }
            return TailObjectsResult(
                objects: objects,
                parsedOffset: newParsedOffset,
                boundaryHash: newBoundaryHash,
                failure: nil
            )
        }
    }

    static func parseObject(_ line: String) -> JSONObject? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    private static func completePrefixLength(_ data: Data) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        return data.distance(from: data.startIndex, to: data.index(after: lastNewline))
    }

    private static func completeLineOffset(fileURL: URL, fileSize: Int64) throws -> Int64 {
        guard fileSize > 0 else { return 0 }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var searchEnd = fileSize
        while searchEnd > 0 {
            let length = min(Int64(64 * 1024), searchEnd)
            let start = searchEnd - length
            try handle.seek(toOffset: UInt64(start))
            let chunk = handle.readData(ofLength: Int(length))
            if let newline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
                let distance = chunk.distance(from: chunk.startIndex, to: chunk.index(after: newline))
                return start + Int64(distance)
            }
            searchEnd = start
        }
        return 0
    }

    private static func boundaryHash(fileURL: URL, offset: Int64) throws -> String {
        let safeOffset = max(0, offset)
        let length = min(Int64(checkpointBoundaryBytes), safeOffset)
        guard length > 0 else {
            return sha256Hex(Data())
        }
        let start = safeOffset - length
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        return sha256Hex(handle.readData(ofLength: Int(length)))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func object(_ value: Any?) -> JSONObject? {
        value as? JSONObject
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func jsonString(_ value: Any, limit: Int? = nil) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        guard let limit else { return string }
        return String(string.prefix(limit))
    }

    static func fileSize(locator: String) -> Int64 {
        var info = stat()
        guard lstat(locator, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return 0
        }
        return Int64(info.st_size)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        lstatMode(url.path) == S_IFLNK
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        lstatMode(url.path) == S_IFREG
    }

    private static func lstatMode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    private static func statMode(_ path: String) -> mode_t? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func stream(_ messages: [NormalizedMessage]) -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            for message in messages {
                continuation.yield(message)
            }
            continuation.finish()
        }
    }

    static func stream(_ result: WindowedMessagesResult) -> StreamMessagesResult {
        StreamMessagesResult(
            messages: stream(result.messages),
            totalKnownComplete: result.totalKnownComplete,
            truncatedAt: result.truncatedAt,
            maxRawMessages: result.maxRawMessages,
            parseFailure: result.parseFailure
        )
    }

    static func applyWindow(
        _ messages: [NormalizedMessage],
        options: StreamMessagesOptions
    ) -> [NormalizedMessage] {
        let offset = max(options.offset ?? 0, 0)
        let suffix = offset >= messages.count ? [] : Array(messages.dropFirst(offset))
        guard let limit = options.limit else { return suffix }
        return Array(suffix.prefix(max(limit, 0)))
    }

    static func boundedWindowWithMetadata(
        _ messages: [NormalizedMessage],
        options: StreamMessagesOptions,
        maxMessages: Int,
        hasMoreMessages: Bool = false,
        parseFailure: ParserFailure? = nil
    ) -> WindowedMessagesResult {
        let cap = max(maxMessages, 0)
        let bounded = Array(messages.prefix(cap))
        let window = applyWindow(bounded, options: options)
        let offset = max(options.offset ?? 0, 0)
        let reachedCap = (hasMoreMessages || messages.count > cap)
            && (offset >= cap || offset + window.count >= cap)
        let truncatedAt = reachedCap ? cap : nil
        let filledRequestedWindow = options.limit.map { window.count >= max($0, 0) } ?? false
        let windowParseFailure = filledRequestedWindow ? nil : parseFailure
        return WindowedMessagesResult(
            messages: window,
            totalKnownComplete: truncatedAt == nil && windowParseFailure == nil,
            truncatedAt: truncatedAt,
            maxRawMessages: reachedCap ? bounded.count : nil,
            parseFailure: windowParseFailure
        )
    }

    static func wholeDocumentMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits,
        transform: ([JSONObject]) -> [NormalizedMessage],
        countsTowardMessageLimit: ((JSONObject) -> Bool)? = nil,
        countsProducedMessageTowardLimit: ((NormalizedMessage) -> Bool)? = nil,
        beforeIdentityValidation: () -> Void = {}
    ) throws -> WindowedMessagesResult {
        let (objects, failure) = try readObjects(
            locator: locator,
            limits: limits,
            reportFailures: true,
            countsTowardMessageLimit: countsTowardMessageLimit,
            beforeIdentityValidation: beforeIdentityValidation
        )
        let produced = transform(objects)
        var capped: [NormalizedMessage] = []
        var billedMessages = 0
        var producedExceededLimit = false
        for message in produced {
            if countsProducedMessageTowardLimit?(message) ?? true {
                guard billedMessages < limits.maxMessages else {
                    producedExceededLimit = true
                    break
                }
                billedMessages += 1
            }
            capped.append(message)
        }
        let window = applyWindow(capped, options: options)
        let offset = max(options.offset ?? 0, 0)
        let reachedCap = (failure == .messageLimitExceeded || producedExceededLimit)
            && offset + window.count >= capped.count
        let truncatedAt = reachedCap ? limits.maxMessages : nil
        let fileFailure = failure == .messageLimitExceeded ? nil : failure
        let filledRequestedWindow = options.limit.map { window.count >= max($0, 0) } ?? false
        // A later malformed/oversized line does not poison an earlier full
        // page. Surface the file-level failure only on the window that reaches
        // the end of the successfully parsed prefix so Load all can keep going.
        let parseFailure = filledRequestedWindow ? nil : fileFailure
        return WindowedMessagesResult(
            messages: window,
            totalKnownComplete: truncatedAt == nil && parseFailure == nil,
            truncatedAt: truncatedAt,
            maxRawMessages: reachedCap ? capped.count : nil,
            parseFailure: parseFailure
        )
    }

    /// Window a per-line JSONL transcript with offset/limit, mapping each line
    /// through `transform`.
    ///
    /// When `options.limit` is set, this reads line by line through EOF or the
    /// first billable message beyond `maxMessages`. The extra observation is
    /// required to distinguish an exact cap from a truncated transcript. When
    /// `limit` is nil (whole-transcript request) it falls back to `readObjects`
    /// and windows in memory.
    ///
    /// `offset`/`limit` count PRODUCED messages (post-`transform`, nils skipped),
    /// matching `applyWindow` exactly. `transform` must be a pure per-line mapping
    /// with no cross-line state; adapters that carry state across lines (Kimi) or
    /// parse the whole document at once (VS Code / Gemini / Cline / SQLite) must
    /// not use this helper.
    static func windowedMessages(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits,
        countsTowardMessageLimit: ((NormalizedMessage) -> Bool)? = nil,
        transform: (JSONObject) -> NormalizedMessage?
    ) throws -> [NormalizedMessage] {
        try windowedMessagesWithMetadata(
            locator: locator,
            options: options,
            limits: limits,
            countsTowardMessageLimit: countsTowardMessageLimit,
            transform: transform
        ).messages
    }

    static func windowedMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits,
        countsTowardMessageLimit: ((NormalizedMessage) -> Bool)? = nil,
        transform: (JSONObject) -> NormalizedMessage?
    ) throws -> WindowedMessagesResult {
        guard let limit = options.limit else {
            return try autoreleasepool {
                let (url, before) = try prepareFile(locator: locator, limits: limits)
                let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
                var messages: [NormalizedMessage] = []
                var billedMessages = 0
                var truncatedAt: Int?

                for line in try reader.readLines() {
                    guard let object = parseObject(line), let message = transform(object) else { continue }
                    if countsTowardMessageLimit?(message) ?? true {
                        guard billedMessages < limits.maxMessages else {
                            truncatedAt = limits.maxMessages
                            break
                        }
                        billedMessages += 1
                    }
                    messages.append(message)
                }

                let after: FileIdentity
                do {
                    after = try limits.fileIdentity(for: url)
                } catch {
                    guard !messages.isEmpty else { throw error }
                    return WindowedMessagesResult(
                        messages: applyWindow(messages, options: options),
                        totalKnownComplete: false,
                        truncatedAt: truncatedAt,
                        maxRawMessages: truncatedAt == nil ? nil : messages.count,
                        parseFailure: truncatedAt == nil ? .fileModifiedDuringParse : .messageLimitExceeded
                    )
                }
                if !limits.isSameFileIdentity(before, after) {
                    return WindowedMessagesResult(
                        messages: applyWindow(messages, options: options),
                        totalKnownComplete: false,
                        truncatedAt: truncatedAt,
                        maxRawMessages: truncatedAt == nil ? nil : messages.count,
                        parseFailure: truncatedAt == nil ? .fileModifiedDuringParse : .messageLimitExceeded
                    )
                }
                if truncatedAt == nil, let failure = reader.failures.first {
                    return WindowedMessagesResult(
                        messages: applyWindow(messages, options: options),
                        totalKnownComplete: false,
                        truncatedAt: nil,
                        parseFailure: failure
                    )
                }
                return WindowedMessagesResult(
                    messages: applyWindow(messages, options: options),
                    totalKnownComplete: truncatedAt == nil,
                    truncatedAt: truncatedAt,
                    maxRawMessages: truncatedAt == nil ? nil : messages.count
                )
            }
        }

        let cappedLimit = max(limit, 0)
        guard cappedLimit > 0 else {
            return WindowedMessagesResult(messages: [], totalKnownComplete: true, truncatedAt: nil)
        }
        let offset = max(options.offset ?? 0, 0)

        return try autoreleasepool {
            let (url, before) = try prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var produced = 0
            var billedMessages = 0
            var messages: [NormalizedMessage] = []
            var stoppedAtFilledWindow = false

            var exceededMessageLimit = false
            var producedAtMessageLimit: Int?
            for line in try reader.readLines() {
                guard let object = parseObject(line), let message = transform(object) else { continue }
                if countsTowardMessageLimit?(message) ?? true {
                    if billedMessages >= limits.maxMessages {
                        exceededMessageLimit = true
                        producedAtMessageLimit = produced
                        break
                    }
                    billedMessages += 1
                }
                produced += 1
                if produced <= offset {
                    continue
                }
                if messages.count < cappedLimit {
                    messages.append(message)
                }
                if messages.count == cappedLimit {
                    stoppedAtFilledWindow = true
                    break
                }
            }

            if !exceededMessageLimit, let failure = reader.failures.first, messages.count < cappedLimit {
                return WindowedMessagesResult(
                    messages: messages,
                    totalKnownComplete: false,
                    truncatedAt: nil,
                    maxRawMessages: producedAtMessageLimit,
                    parseFailure: failure
                )
            }
            let truncatedAt = exceededMessageLimit
                && offset + messages.count >= (producedAtMessageLimit ?? produced)
                ? limits.maxMessages
                : nil
            let after: FileIdentity
            do {
                after = try limits.fileIdentity(for: url)
            } catch {
                guard !messages.isEmpty else { throw error }
                return WindowedMessagesResult(
                    messages: messages,
                    totalKnownComplete: false,
                    truncatedAt: truncatedAt,
                    maxRawMessages: exceededMessageLimit ? producedAtMessageLimit : nil,
                    parseFailure: exceededMessageLimit ? .messageLimitExceeded : .fileModifiedDuringParse
                )
            }
            if !limits.isSameFileIdentity(before, after) {
                return WindowedMessagesResult(
                    messages: messages,
                    totalKnownComplete: false,
                    truncatedAt: truncatedAt,
                    maxRawMessages: exceededMessageLimit ? producedAtMessageLimit : nil,
                    parseFailure: exceededMessageLimit ? .messageLimitExceeded : .fileModifiedDuringParse
                )
            }
            return WindowedMessagesResult(
                messages: messages,
                totalKnownComplete: truncatedAt == nil && !stoppedAtFilledWindow,
                truncatedAt: truncatedAt,
                maxRawMessages: exceededMessageLimit ? producedAtMessageLimit : nil
            )
        }
    }

    static func usage(from rawUsage: JSONObject?) -> TokenUsage? {
        guard let rawUsage else { return nil }
        return TokenUsage(
            inputTokens: rawUsage["input_tokens"] as? Int ?? 0,
            outputTokens: rawUsage["output_tokens"] as? Int ?? 0,
            cacheReadTokens: rawUsage["cache_read_input_tokens"] as? Int,
            cacheCreationTokens: rawUsage["cache_creation_input_tokens"] as? Int
        )
    }
}

struct CodexAdapterTestHooks: Sendable {
    var beforeFinalIdentityValidation: @Sendable () -> Void

    init(beforeFinalIdentityValidation: @escaping @Sendable () -> Void = {}) {
        self.beforeFinalIdentityValidation = beforeFinalIdentityValidation
    }
}

final class CodexAdapter: SessionAdapter, TailIndexingSessionAdapter, ExactArchiveSourceAdapter, Sendable {
    let source: SourceName = .codex
    private let sessionRoots: [URL]
    private let archiveReplayUsesNamedRoots: Bool
    private let limits: ParserLimits
    private let testHooks: CodexAdapterTestHooks

    init(
        sessionsRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
            .path,
        limits: ParserLimits = .default,
        testHooks: CodexAdapterTestHooks = CodexAdapterTestHooks()
    ) {
        let requestedRoot = URL(fileURLWithPath: sessionsRoot)
        self.sessionRoots = Self.expandSessionRoots(requestedRoot)
        self.archiveReplayUsesNamedRoots = requestedRoot.lastPathComponent == "sessions"
        self.limits = limits
        self.testHooks = testHooks
    }

    func detect() async -> Bool {
        sessionRoots.contains { JSONLAdapterSupport.isDirectory($0) }
    }

    func listSessionLocators() async throws -> [String] {
        try Task.checkCancellation()
        var locators: [String] = []
        for root in sessionRoots {
            try Task.checkCancellation()
            locators.append(contentsOf: try JSONLAdapterSupport.recursiveFiles(under: root) { url in
                url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
            })
            try Task.checkCancellation()
        }
        return locators.sorted()
    }

    func archiveSourceDescriptor(locator: String) async throws -> ArchiveSourceDescriptor {
        let sourceURL = URL(fileURLWithPath: locator).standardizedFileURL
        for declaredRoot in sessionRoots {
            let physicalRoot = declaredRoot.resolvingSymlinksInPath().standardizedFileURL
            guard let relative = try? ArchiveSourceDescriptor.relativePath(
                path: sourceURL,
                under: physicalRoot
            ) else {
                continue
            }
            let replayRelativePath = archiveReplayUsesNamedRoots
                ? "\(declaredRoot.lastPathComponent)/\(relative)"
                : relative
            return try ArchiveSourceDescriptor.singleFile(
                locator: locator,
                sourceURL: sourceURL,
                replayRelativePath: replayRelativePath
            )
        }
        throw ArchiveSourceDescriptorError.pathOutsideRoot(
            path: sourceURL.path,
            root: sessionRoots.map(\.path).joined(separator: ":")
        )
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            if let failure { return .failure(failure) }
            return Self.sessionInfo(from: objects, locator: locator)
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
        let result = try Self.messages(
            locator: locator,
            options: options,
            limits: limits,
            testHooks: testHooks
        )
        return JSONLAdapterSupport.stream(result.messages)
    }

    func streamMessagesWithMetadata(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> StreamMessagesResult {
        let result = try Self.messages(
            locator: locator,
            options: options,
            limits: limits,
            testHooks: testHooks
        )
        return StreamMessagesResult(
            messages: JSONLAdapterSupport.stream(result.messages),
            totalKnownComplete: result.truncatedAt == nil && result.parseFailure == nil,
            truncatedAt: result.truncatedAt,
            parseFailure: result.parseFailure
        )
    }

    /// Single-pass info + messages for the indexer (M7 tail-resume prep).
    func scanForIndexing(locator: String) async throws -> AdapterParseResult<IndexingScan> {
        do {
            let (objects, failure) = try JSONLAdapterSupport.readObjects(
                locator: locator,
                limits: limits,
                reportFailures: true,
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            if let failure, failure != .fileModifiedDuringParse { return .failure(failure) }
            let messages = Self.messages(from: objects)
            if failure == .fileModifiedDuringParse, messages.isEmpty {
                return .failure(.fileModifiedDuringParse)
            }
            let info: NormalizedSessionInfo
            switch Self.sessionInfo(from: objects, locator: locator) {
            case .failure(let reason): return .failure(reason)
            case .success(let value): info = value
            }
            let checkpoint = failure == nil
                ? try JSONLAdapterSupport.checkpoint(locator: locator, limits: limits)
                : nil
            let checkpointBoundaryHash = checkpoint?.parsedOffset == info.sizeBytes
                ? checkpoint?.boundaryHash
                : nil
            return .success(
                IndexingScan(
                    info: info,
                    messages: messages,
                    parseFailure: failure,
                    checkpointParsedOffset: checkpoint?.parsedOffset,
                    checkpointBoundaryHash: checkpointBoundaryHash
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func scanTailForIndexing(
        locator: String,
        from parsedOffset: Int64,
        expectedBoundaryHash: String
    ) async throws -> IndexingTailScanResult {
        do {
            let result = try JSONLAdapterSupport.readTailObjects(
                locator: locator,
                from: parsedOffset,
                expectedBoundaryHash: expectedBoundaryHash,
                limits: limits,
                countsTowardMessageLimit: { Self.message(from: $0) != nil }
            )
            guard !result.boundaryHash.isEmpty else { return .fallback }
            if let failure = result.failure { return .failure(failure) }

            var messages: [NormalizedMessage] = []
            var userCount = 0
            var assistantCount = 0
            var toolCount = 0
            var systemCount = 0
            var endTime: String?
            var detectedModel: String?

            for object in result.objects {
                if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                    endTime = timestamp
                }
                if JSONLAdapterSupport.string(object["type"]) == "response_item",
                   let payload = JSONLAdapterSupport.object(object["payload"]),
                   detectedModel == nil,
                   let model = JSONLAdapterSupport.string(payload["model"]) {
                    detectedModel = model
                }
                guard let message = Self.message(from: object) else { continue }
                messages.append(message)
                switch message.role {
                case .user: userCount += 1
                case .assistant: assistantCount += 1
                case .tool: toolCount += 1
                case .system: systemCount += 1
                }
            }

            return .success(
                IndexingTailScan(
                    infoDelta: IndexingTailInfoDelta(
                        id: nil,
                        source: .codex,
                        endTime: endTime,
                        model: detectedModel,
                        messageCount: userCount + assistantCount + toolCount,
                        userMessageCount: userCount,
                        assistantMessageCount: assistantCount,
                        toolMessageCount: toolCount,
                        systemMessageCount: systemCount,
                        firstVisibleRole: messages.first?.role
                    ),
                    messages: messages,
                    parsedOffset: result.parsedOffset,
                    boundaryHash: result.boundaryHash
                )
            )
        } catch let failure as ParserFailure {
            return .failure(failure)
        } catch {
            return .failure(.malformedJSON)
        }
    }

    func isAccessible(locator: String) async -> Bool {
        JSONLAdapterSupport.fileExists(locator)
    }

    private static func sessionInfo(
        from objects: [JSONLAdapterSupport.JSONObject],
        locator: String
    ) -> AdapterParseResult<NormalizedSessionInfo> {
        var meta: JSONLAdapterSupport.JSONObject?
        var metadata = SourceMetadataProjection(format: .codex, locator: locator)
        var userCount = 0
        var assistantCount = 0
        var toolCount = 0
        var systemCount = 0
        var firstUserText = ""
        var lastTimestamp = ""
        var detectedModel: String?
        var turnContextModel: String?

        for object in objects {
            if let timestamp = JSONLAdapterSupport.string(object["timestamp"]) {
                lastTimestamp = timestamp
            }
            if metadata.consume(object) == .codexMetadata {
                meta = JSONLAdapterSupport.object(object["payload"])
            }
            if JSONLAdapterSupport.string(object["type"]) == "turn_context",
               turnContextModel == nil,
               let payload = JSONLAdapterSupport.object(object["payload"]),
               let model = JSONLAdapterSupport.string(payload["model"]) {
                turnContextModel = model
            }
            guard JSONLAdapterSupport.string(object["type"]) == "response_item",
                  let payload = JSONLAdapterSupport.object(object["payload"])
            else { continue }
            if detectedModel == nil, let model = JSONLAdapterSupport.string(payload["model"]) {
                detectedModel = model
            }
            let payloadType = JSONLAdapterSupport.string(payload["type"])
            if payloadType == "message", JSONLAdapterSupport.string(payload["role"]) == "user" {
                let rawText = extractText(JSONLAdapterSupport.array(payload["content"]))
                let normalized = normalizeUserText(rawText)
                if normalized.strippedSystemContent { systemCount += 1 }
                if let text = normalized.userText {
                    userCount += 1
                    if firstUserText.isEmpty { firstUserText = text }
                } else if !normalized.strippedSystemContent, isSystemInjection(rawText) {
                    systemCount += 1
                }
            } else if payloadType == "message", JSONLAdapterSupport.string(payload["role"]) == "assistant" {
                assistantCount += 1
            } else if payloadType == "function_call"
                || payloadType == "function_call_output"
                || payloadType == "custom_tool_call"
                || payloadType == "custom_tool_call_output" {
                toolCount += 1
            }
        }

        guard let meta,
              let id = metadata.nativeSessionID,
              let startTime = JSONLAdapterSupport.string(meta["timestamp"])
        else { return .failure(.malformedJSON) }
        guard userCount + assistantCount + toolCount > 0 else {
            return .failure(.noVisibleMessages)
        }
        let explicitRole = JSONLAdapterSupport.string(meta["agent_role"])
        let originator = JSONLAdapterSupport.string(meta["originator"])
        let effectiveRole = explicitRole ?? (OriginatorClassifier.isClaudeCode(originator) ? "dispatched" : nil)
        return .success(
            NormalizedSessionInfo(
                id: id,
                source: .codex,
                startTime: startTime,
                endTime: lastTimestamp.isEmpty ? nil : lastTimestamp,
                cwd: metadata.cwd ?? "",
                project: nil,
                model: detectedModel ?? turnContextModel ?? JSONLAdapterSupport.string(meta["model"]),
                messageCount: userCount + assistantCount + toolCount,
                userMessageCount: userCount,
                assistantMessageCount: assistantCount,
                toolMessageCount: toolCount,
                systemMessageCount: systemCount,
                summary: firstUserText.isEmpty ? nil : firstUserText,
                filePath: locator,
                sizeBytes: JSONLAdapterSupport.fileSize(locator: locator),
                indexedAt: nil,
                agentRole: effectiveRole,
                originator: originator,
                origin: nil,
                summaryMessageCount: nil,
                tier: nil,
                qualityScore: nil,
                parentSessionId: nil,
                suggestedParentId: nil
            )
        )
    }

    private static func messages(
        from objects: [JSONLAdapterSupport.JSONObject]
    ) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = []
        var pendingMessage: NormalizedMessage?
        var pendingUsageCameFromTokenCount = false
        var pendingUsage: TokenUsage?
        var lastTokenCountSnapshot: [Int?]?

        func flushPendingMessage() {
            guard let message = pendingMessage else { return }
            messages.append(message)
            pendingMessage = nil
            pendingUsageCameFromTokenCount = false
        }

        for object in objects {
            if JSONLAdapterSupport.string(object["type"]) == "response_item" {
                lastTokenCountSnapshot = nil
            }
            if let tokenCount = tokenCountUsage(from: object) {
                if tokenCount.snapshot == lastTokenCountSnapshot { continue }
                lastTokenCountSnapshot = tokenCount.snapshot
                if var message = pendingMessage, message.role != .user {
                    if pendingUsageCameFromTokenCount || message.usage == nil {
                        message.usage = mergeUsage(message.usage, tokenCount.usage)
                        pendingUsageCameFromTokenCount = true
                        pendingMessage = message
                    }
                } else {
                    pendingUsage = mergeUsage(pendingUsage, tokenCount.usage)
                }
                continue
            }
            guard var message = message(from: object) else { continue }
            flushPendingMessage()
            if message.role != .user, let usage = pendingUsage {
                if message.usage == nil { message.usage = usage }
                pendingUsage = nil
            }
            pendingMessage = message
            pendingUsageCameFromTokenCount = false
        }
        flushPendingMessage()
        return messages
    }

    private static func expandSessionRoots(_ root: URL) -> [URL] {
        guard root.lastPathComponent == "sessions" else { return [root] }
        return [
            root,
            root.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }

    private struct MessageReadResult {
        let messages: [NormalizedMessage]
        let truncatedAt: Int?
        let parseFailure: ParserFailure?
    }

    private static func messages(
        locator: String,
        options: StreamMessagesOptions,
        limits: ParserLimits,
        testHooks: CodexAdapterTestHooks
    ) throws -> MessageReadResult {
        let cappedLimit = options.limit.map { max($0, 0) } ?? Int.max
        guard cappedLimit > 0 else {
            return MessageReadResult(messages: [], truncatedAt: nil, parseFailure: nil)
        }
        let offset = max(options.offset ?? 0, 0)
        return try autoreleasepool {
            let (url, before) = try JSONLAdapterSupport.prepareFile(locator: locator, limits: limits)
            let reader = try StreamingLineReader(fileURL: url, maxLineBytes: limits.maxLineBytes)
            var producedMessages = 0
            var skipped = 0
            var messages: [NormalizedMessage] = []
            var pendingMessage: NormalizedMessage?
            var pendingUsageCameFromTokenCount = false
            var pendingUsage: TokenUsage?
            var lastTokenCountSnapshot: [Int?]?
            var truncatedAt: Int?

            func appendWindowed(_ message: NormalizedMessage) -> Bool {
                if skipped < offset {
                    skipped += 1
                    return false
                }
                if messages.count < cappedLimit {
                    messages.append(message)
                }
                return messages.count >= cappedLimit
            }

            func flushPendingMessage() -> Bool {
                guard let message = pendingMessage else { return false }
                pendingMessage = nil
                pendingUsageCameFromTokenCount = false
                return appendWindowed(message)
            }

            for line in try reader.readLines() {
                guard let object = JSONLAdapterSupport.parseObject(line) else { continue }

                if JSONLAdapterSupport.string(object["type"]) == "response_item" {
                    lastTokenCountSnapshot = nil
                }

                if let tokenCount = tokenCountUsage(from: object) {
                    if tokenCount.snapshot == lastTokenCountSnapshot {
                        continue
                    }
                    lastTokenCountSnapshot = tokenCount.snapshot
                    if var message = pendingMessage, message.role != .user {
                        if pendingUsageCameFromTokenCount || message.usage == nil {
                            message.usage = mergeUsage(message.usage, tokenCount.usage)
                            pendingUsageCameFromTokenCount = true
                            pendingMessage = message
                        }
                    } else {
                        pendingUsage = mergeUsage(pendingUsage, tokenCount.usage)
                    }
                    continue
                }

                guard var message = message(from: object) else { continue }
                if producedMessages >= limits.maxMessages {
                    // Truncate-and-succeed at the produced-message cap. Envelope
                    // and token-accounting records never consume this budget.
                    truncatedAt = limits.maxMessages
                    break
                }
                producedMessages += 1
                if flushPendingMessage() { break }
                if message.role != .user, let usage = pendingUsage {
                    if message.usage == nil {
                        message.usage = usage
                    }
                    pendingUsage = nil
                }
                pendingMessage = message
                pendingUsageCameFromTokenCount = false
            }

            if messages.count < cappedLimit {
                _ = flushPendingMessage()
            }

            let parseFailure: ParserFailure?
            testHooks.beforeFinalIdentityValidation()
            do {
                let after = try limits.fileIdentity(for: url)
                parseFailure = limits.isSameFileIdentity(before, after)
                    ? reader.failures.first
                    : .fileModifiedDuringParse
            } catch {
                guard !messages.isEmpty else { throw error }
                parseFailure = .fileModifiedDuringParse
            }
            return MessageReadResult(
                messages: messages,
                truncatedAt: truncatedAt,
                parseFailure: parseFailure
            )
        }
    }

    private static func message(from object: JSONLAdapterSupport.JSONObject) -> NormalizedMessage? {
        guard JSONLAdapterSupport.string(object["type"]) == "response_item",
              let payload = JSONLAdapterSupport.object(object["payload"])
        else { return nil }

        let timestamp = JSONLAdapterSupport.string(object["timestamp"])
        switch JSONLAdapterSupport.string(payload["type"]) {
        case "message":
            guard let rawRole = JSONLAdapterSupport.string(payload["role"]),
                  rawRole == "user" || rawRole == "assistant"
            else { return nil }
            let role: NormalizedMessageRole = rawRole == "user" ? .user : .assistant
            let rawText = extractText(JSONLAdapterSupport.array(payload["content"]))
            let content: String
            if role == .user {
                guard let userText = normalizeUserText(rawText).userText else { return nil }
                content = userText
            } else {
                content = rawText
            }
            return NormalizedMessage(
                role: role,
                content: content,
                timestamp: timestamp,
                toolCalls: nil,
                usage: role == .assistant ? JSONLAdapterSupport.usage(from: JSONLAdapterSupport.object(payload["usage"])) : nil
            )
        case "function_call", "custom_tool_call":
            let name = JSONLAdapterSupport.string(payload["name"]) ?? ""
            let isCustomToolCall = JSONLAdapterSupport.string(payload["type"]) == "custom_tool_call"
            let inputValue = payload[isCustomToolCall ? "input" : "arguments"]
            let input: String
            if let string = JSONLAdapterSupport.string(inputValue) {
                input = String(string.prefix(500))
            } else if let inputValue {
                input = JSONLAdapterSupport.jsonString(inputValue, limit: 500) ?? ""
            } else {
                input = ""
            }
            return NormalizedMessage(
                role: .tool,
                content: input.isEmpty ? name : "\(name) \(input)",
                timestamp: timestamp,
                toolCalls: [NormalizedToolCall(name: name, input: input.isEmpty ? nil : input)]
            )
        case "function_call_output", "custom_tool_call_output":
            let content: String
            if let output = JSONLAdapterSupport.string(payload["output"]) {
                content = output
            } else if let output = payload["output"],
                      let json = JSONLAdapterSupport.jsonString(output, limit: 2000) {
                content = json
            } else {
                content = ""
            }
            return NormalizedMessage(role: .tool, content: content, timestamp: timestamp)
        default:
            return nil
        }
    }

    private static func tokenCountUsage(
        from object: JSONLAdapterSupport.JSONObject
    ) -> (usage: TokenUsage, snapshot: [Int?])? {
        guard JSONLAdapterSupport.string(object["type"]) == "event_msg",
              let payload = JSONLAdapterSupport.object(object["payload"]),
              JSONLAdapterSupport.string(payload["type"]) == "token_count",
              let info = JSONLAdapterSupport.object(payload["info"]),
              let usage = JSONLAdapterSupport.object(info["last_token_usage"])
        else {
            return nil
        }

        let inputTokens = int(usage["input_tokens"])
        let cachedInputTokens = int(usage["cached_input_tokens"])
        let outputTokens = int(usage["output_tokens"])
        let tokenUsage = TokenUsage(
            inputTokens: max(inputTokens - cachedInputTokens, 0),
            outputTokens: outputTokens,
            cacheReadTokens: cachedInputTokens,
            cacheCreationTokens: 0
        )
        guard tokenUsage.inputTokens > 0
            || tokenUsage.outputTokens > 0
            || (tokenUsage.cacheReadTokens ?? 0) > 0
            || (tokenUsage.cacheCreationTokens ?? 0) > 0
        else {
            return nil
        }

        let totalUsage = JSONLAdapterSupport.object(info["total_token_usage"])
        let snapshot = [
            optionalInt(usage["input_tokens"]),
            optionalInt(usage["cached_input_tokens"]),
            optionalInt(usage["output_tokens"]),
            optionalInt(usage["reasoning_output_tokens"]),
            optionalInt(usage["total_tokens"]),
            totalUsage == nil ? 0 : 1,
            optionalInt(totalUsage?["input_tokens"]),
            optionalInt(totalUsage?["cached_input_tokens"]),
            optionalInt(totalUsage?["output_tokens"]),
            optionalInt(totalUsage?["reasoning_output_tokens"]),
            optionalInt(totalUsage?["total_tokens"]),
        ]
        return (tokenUsage, snapshot)
    }

    private static func mergeUsage(_ lhs: TokenUsage?, _ rhs: TokenUsage) -> TokenUsage {
        guard let lhs else { return rhs }
        return TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: (lhs.cacheReadTokens ?? 0) + (rhs.cacheReadTokens ?? 0),
            cacheCreationTokens: (lhs.cacheCreationTokens ?? 0) + (rhs.cacheCreationTokens ?? 0)
        )
    }

    private static func int(_ value: Any?) -> Int {
        optionalInt(value) ?? 0
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func isSystemInjection(_ text: String) -> Bool {
        SystemMessageClassifier.classify(content: text, source: "codex") != .none
    }

    private static func normalizeUserText(_ text: String) -> (userText: String?, strippedSystemContent: Bool) {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = false

        if remaining.hasPrefix("# AGENTS.md instructions for ") || remaining.hasPrefix("<INSTRUCTIONS>") {
            if let end = remaining.range(of: "</INSTRUCTIONS>") {
                remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }

        var removedBlock = true
        while removedBlock {
            removedBlock = false
            for tag in ["local-command-caveat", "environment_context", "skills_instructions", "plugins_instructions"] {
                let open = "<\(tag)>"
                let close = "</\(tag)>"
                if remaining.hasPrefix(open), let end = remaining.range(of: close) {
                    remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    stripped = true
                    removedBlock = true
                }
            }
        }

        guard !remaining.isEmpty else {
            return (nil, stripped || isSystemInjection(text))
        }
        if !stripped, isSystemInjection(remaining) {
            return (nil, true)
        }
        return (remaining, stripped)
    }

    private static func extractText(_ content: [Any]?) -> String {
        guard let content else { return "" }
        var parts: [String] = []
        for item in content {
            guard let object = JSONLAdapterSupport.object(item) else { continue }
            if let text = JSONLAdapterSupport.string(object["text"]), !text.isEmpty {
                parts.append(text)
            } else if let inputText = JSONLAdapterSupport.string(object["input_text"]), !inputText.isEmpty {
                parts.append(inputText)
            } else if let outputText = JSONLAdapterSupport.string(object["output_text"]), !outputText.isEmpty {
                parts.append(outputText)
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
