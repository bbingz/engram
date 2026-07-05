import Foundation
import XCTest
@testable import EngramCoreRead

/// Coverage for the adapter windowed-read performance fixes:
/// - #39 truncate-and-succeed instead of the uncapped legacy fallback
/// - #29 bounded parse cache for whole-document sources
/// - #21 persisted derived-source signature cache
final class AdapterWindowedReadTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-windowed-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - #39 truncate-and-succeed

    func testClaudeCodeUnwindowedReadTruncatesInsteadOfThrowing() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let lines = (0..<12).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"message\":{\"content\":\"m\(index)\"}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(limits: ParserLimits(maxMessages: 10))
        var contents: [String] = []
        // A full (limit == nil) read must NOT throw .messageLimitExceeded; it
        // returns the first `maxMessages` messages so MessageParser never falls
        // back to its uncapped legacy parser.
        for try await message in try await adapter.streamMessages(
            locator: file.path, options: StreamMessagesOptions()
        ) {
            contents.append(message.content)
        }
        XCTAssertEqual(contents, (0..<10).map { "m\($0)" })
    }

    func testCodexUnwindowedReadTruncatesInsteadOfThrowing() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\",\"content\":[{\"text\":\"m\(index)\"}]}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(limits: ParserLimits(maxMessages: 3))
        var count = 0
        // Must complete without throwing; the CodexAdapter streaming path breaks
        // at the cap rather than throwing .messageLimitExceeded.
        for try await _ in try await adapter.streamMessages(
            locator: file.path, options: StreamMessagesOptions()
        ) {
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 8, "the cap must truncate the transcript")
    }

    func testClaudeCodeUnwindowedReadReportsTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let lines = (0..<12).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"message\":{\"content\":\"m\(index)\"}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(limits: ParserLimits(maxMessages: 10))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, (0..<10).map { "m\($0)" })
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 10)
    }

    func testCodexUnwindowedReadReportsTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\",\"content\":[{\"text\":\"m\(index)\"}]}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertGreaterThan(contents.count, 0)
        XCTAssertLessThan(contents.count, 8, "the cap must truncate the transcript")
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 3)
    }

    func testJSONLHelperAdapterReportsUnwindowedTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("qoder.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"message\":{\"content\":\"m\(index)\"}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = QoderAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1", "m2"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 3)
    }

    func testWholeDocumentJSONLAdapterReportsUnwindowedTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("qwen.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"sessionId\":\"s1\",\"cwd\":\"/tmp\",\"timestamp\":\"2026-01-01T00:00:0\(index)Z\",\"message\":{\"parts\":[{\"text\":\"m\(index)\"}]}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1", "m2"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 3)
    }

    func testCopilotAdapterReportsUnwindowedTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl")
        let lines = (0..<8).map { index -> String in
            let type = index % 2 == 0 ? "user.message" : "assistant.message"
            return "{\"type\":\"\(type)\",\"timestamp\":\"2026-01-01T00:00:0\(index)Z\",\"data\":{\"content\":\"m\(index)\"}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1", "m2"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 3)
    }

    func testCascadeCacheAdapterReportsUnwindowedTruncationMetadata() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("windsurf.jsonl")
        var lines = [
            #"{"id":"w1","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#
        ]
        lines += (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"role\":\"\(role)\",\"content\":\"m\(index)\"}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(limits: ParserLimits(maxMessages: 4), enableLiveSync: false)
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1", "m2"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertEqual(result.truncatedAt, 4)
    }

    func testClaudeCodeWindowedMetadataReadStopsBeforeTruncationProbe() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"\(role)\",\"message\":{\"content\":\"m\(index)\"}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 0, limit: 2)
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1"])
        XCTAssertFalse(result.truncated, "windowed page reads must stop at the page window, not scan forward to maxMessages")
        XCTAssertNil(result.truncatedAt)
    }

    func testCodexWindowedMetadataReadStopsBeforeTruncationProbe() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout.jsonl")
        let lines = (0..<8).map { index -> String in
            let role = index % 2 == 0 ? "user" : "assistant"
            return "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"\(role)\",\"content\":[{\"text\":\"m\(index)\"}]}}"
        }
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 0, limit: 2)
        )
        var contents: [String] = []
        for try await message in result.messages {
            contents.append(message.content)
        }

        XCTAssertEqual(contents, ["m0", "m1"])
        XCTAssertFalse(result.truncated, "windowed page reads must stop at the page window, not scan forward to maxMessages")
        XCTAssertNil(result.truncatedAt)
    }

    // MARK: - #29 parse cache

    func testParsedTranscriptCacheHitMissAndSignatureInvalidation() async {
        let cache = ParsedTranscriptCache(capacity: 2)
        let sigA = ParsedTranscriptCache.Signature(mtime: 100, size: 10)
        let sigB = ParsedTranscriptCache.Signature(mtime: 200, size: 10)
        let messages = [
            NormalizedMessage(role: .user, content: "hi", timestamp: nil, toolCalls: nil, usage: nil)
        ]

        await cache.store(locator: "a", signature: sigA, messages: messages)
        let hit = await cache.cached(locator: "a", signature: sigA)
        XCTAssertEqual(hit?.map(\.content), ["hi"])

        // A changed signature (mtime bump) invalidates the entry.
        let stale = await cache.cached(locator: "a", signature: sigB)
        XCTAssertNil(stale)

        // A nil signature (stat failed) is never cached and never hits.
        await cache.store(locator: "b", signature: nil, messages: messages)
        let uncacheable = await cache.cached(locator: "b", signature: nil)
        XCTAssertNil(uncacheable)
    }

    func testParsedTranscriptCacheEvictsLeastRecentlyUsed() async {
        let cache = ParsedTranscriptCache(capacity: 2)
        func sig(_ n: Double) -> ParsedTranscriptCache.Signature { .init(mtime: n, size: 1) }
        let msg = [NormalizedMessage(role: .user, content: "x", timestamp: nil, toolCalls: nil, usage: nil)]

        await cache.store(locator: "a", signature: sig(1), messages: msg)
        await cache.store(locator: "b", signature: sig(2), messages: msg)
        _ = await cache.cached(locator: "a", signature: sig(1))  // touch a → b is now LRU
        await cache.store(locator: "c", signature: sig(3), messages: msg)  // evicts b

        let a = await cache.cached(locator: "a", signature: sig(1))
        let b = await cache.cached(locator: "b", signature: sig(2))
        let c = await cache.cached(locator: "c", signature: sig(3))
        XCTAssertNotNil(a)
        XCTAssertNil(b)
        XCTAssertNotNil(c)
    }

    func testParsedTranscriptSignatureIncludesSQLiteWalSidecars() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("state.vscdb")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let shm = URL(fileURLWithPath: database.path + "-shm")
        try "main".write(to: database, atomically: true, encoding: .utf8)

        let base = ParsedTranscriptCache.Signature.forFile(database.path)
        XCTAssertNotNil(base)

        try "wal".write(to: wal, atomically: true, encoding: .utf8)
        let withWal = ParsedTranscriptCache.Signature.forFile(database.path)
        XCTAssertNotEqual(base, withWal)

        try "wal-changed".write(to: wal, atomically: true, encoding: .utf8)
        let changedWal = ParsedTranscriptCache.Signature.forFile(database.path)
        XCTAssertNotEqual(withWal, changedWal)

        try "shm".write(to: shm, atomically: true, encoding: .utf8)
        let withShm = ParsedTranscriptCache.Signature.forFile(database.path)
        XCTAssertNotEqual(changedWal, withShm)
    }

    func testClineAdapterServesCachedParseAndReparsesOnChange() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ui_messages.json")
        let adapter = ClineAdapter()

        // Pin an explicit mtime on every write so the (mtime, size) signature is
        // driven only by content length; this makes the cache-hit assertion
        // robust against filesystem mtime-precision rounding.
        let pinnedMtime = Date(timeIntervalSince1970: 1_600_000_000)
        func write(_ text: String) throws {
            try "[{\"say\":\"task\",\"ts\":1000,\"text\":\"\(text)\"}]".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: pinnedMtime], ofItemAtPath: file.path)
        }
        func stream() async throws -> [String] {
            var out: [String] = []
            for try await m in try await adapter.streamMessages(locator: file.path, options: StreamMessagesOptions()) {
                out.append(m.content)
            }
            return out
        }

        try write("AAAA")
        let first = try await stream()
        XCTAssertEqual(first, ["AAAA"])

        // Same byte length + same pinned mtime → identical signature: a correct
        // cache returns the previously parsed content, not the mutated bytes.
        try write("BBBB")
        let cachedRead = try await stream()
        XCTAssertEqual(cachedRead, ["AAAA"], "unchanged signature must hit the cache")

        // A different length changes the size, invalidating the entry.
        try write("CCCCCCCC")
        let reparsed = try await stream()
        XCTAssertEqual(reparsed, ["CCCCCCCC"], "changed signature must re-parse")
    }

    // MARK: - #21 persisted source-hint cache

    private func minimaxFixture() -> String {
        let lines = [
            "{\"type\":\"user\",\"sessionId\":\"s\",\"cwd\":\"/repo\",\"timestamp\":\"2026-05-25T01:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}",
            "{\"type\":\"assistant\",\"sessionId\":\"s\",\"cwd\":\"/repo\",\"timestamp\":\"2026-05-25T01:00:01Z\",\"message\":{\"role\":\"assistant\",\"model\":\"minimax-text-01\",\"content\":\"ok\"}}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    func testSourceHintCachePersistsRoundTripsAndInvalidates() async throws {
        let projectsRoot = makeTempDir()
        let cacheDir = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: projectsRoot)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let projectDir = projectsRoot.appendingPathComponent("-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionFile = projectDir.appendingPathComponent("session.jsonl")
        try minimaxFixture().write(to: sessionFile, atomically: true, encoding: .utf8)

        let adapter1 = ClaudeCodeDerivedSourceAdapter(
            source: .minimax, projectsRoot: projectsRoot.path, sourceHintCacheDirectory: cacheDir
        )
        let detected = try await adapter1.listSessionLocators()
        XCTAssertEqual(detected.count, 1, "minimax fixture should be detected on the cold scan")

        // The signature cache was flushed to disk.
        let cacheFile = cacheDir.appendingPathComponent("claude-source-hints.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path), "cache should persist to disk")
        var disk = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any]
        XCTAssertEqual(disk?["version"] as? Int, 1)
        var entries = disk?["entries"] as? [String: [String: Any]]
        let key = try XCTUnwrap(entries?.keys.first)
        XCTAssertEqual(entries?[key]?["source"] as? String, "minimax")

        // Poison the persisted entry with a WRONG source but a MATCHING signature.
        // A second adapter that consults the cache will trust it and drop the
        // locator from the minimax result — proving the cache hit is honored.
        entries?[key]?["source"] = "claude-code"
        disk?["entries"] = entries
        try JSONSerialization.data(withJSONObject: disk as Any).write(to: cacheFile)

        let adapter2 = ClaudeCodeDerivedSourceAdapter(
            source: .minimax, projectsRoot: projectsRoot.path, sourceHintCacheDirectory: cacheDir
        )
        let afterPoison = try await adapter2.listSessionLocators()
        XCTAssertTrue(afterPoison.isEmpty, "a matching-signature cache entry must be honored without re-sniffing")

        // Changing the file (size) invalidates the stale poisoned signature, so
        // the next scan re-sniffs and correctly detects minimax again.
        try (minimaxFixture() + "{\"type\":\"user\",\"message\":{\"content\":\"more\"}}\n")
            .write(to: sessionFile, atomically: true, encoding: .utf8)
        let adapter3 = ClaudeCodeDerivedSourceAdapter(
            source: .minimax, projectsRoot: projectsRoot.path, sourceHintCacheDirectory: cacheDir
        )
        let afterChange = try await adapter3.listSessionLocators()
        XCTAssertEqual(afterChange.count, 1, "changed signature must re-sniff and re-detect minimax")
    }

    func testSourceHintCacheIgnoresMismatchedVersion() async throws {
        let projectsRoot = makeTempDir()
        let cacheDir = makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: projectsRoot)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let projectDir = projectsRoot.appendingPathComponent("-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionFile = projectDir.appendingPathComponent("session.jsonl")
        try minimaxFixture().write(to: sessionFile, atomically: true, encoding: .utf8)

        // Pre-seed a cache file with a future version and a poisoned source. It
        // must be ignored (re-sniff), proving format versioning invalidates.
        let sig = try FileManager.default.attributesOfItem(atPath: sessionFile.path)
        let mtime = (sig[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (sig[.size] as? NSNumber)?.int64Value ?? 0
        let cacheFile = cacheDir.appendingPathComponent("claude-source-hints.json")
        let payload: [String: Any] = [
            "version": 999,
            "entries": [sessionFile.path: ["modifiedAt": mtime, "size": size, "source": "claude-code"]],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: cacheFile)

        let adapter = ClaudeCodeDerivedSourceAdapter(
            source: .minimax, projectsRoot: projectsRoot.path, sourceHintCacheDirectory: cacheDir
        )
        let detected = try await adapter.listSessionLocators()
        XCTAssertEqual(detected.count, 1, "a version mismatch must invalidate the persisted cache")
    }
}
