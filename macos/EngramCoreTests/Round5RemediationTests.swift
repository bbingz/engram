import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

// Round-5 remediation coverage: adapter parser-output changes (Part B) plus the
// concurrency-safety fixes (Part A) that aren't already exercised by the shared
// adapter-parity goldens.
final class Round5RemediationTests: XCTestCase {
    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round5-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        try data.write(to: url)
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8)!
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // Part B — Cline cwd extraction must anchor on ") Files" so a path that
    // itself contains ')' is not truncated at the first ')'.
    func testClineCwdAnchorsOnFilesSuffixForPathContainingParen() async throws {
        let tasksRoot = try makeTempDir("cline")
        defer { try? FileManager.default.removeItem(at: tasksRoot) }
        let taskDir = tasksRoot.appendingPathComponent("task-1", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)

        let parenPath = "/Users/test/proj (work)/repo"
        let requestText = "Current Working Directory (\(parenPath)) Files\nfoo.swift"
        let innerRequest = try JSONSerialization.data(withJSONObject: ["request": requestText])
        let requestString = String(data: innerRequest, encoding: .utf8)!

        let messages: [[String: Any]] = [
            ["ts": 1_000, "say": "task", "text": "do the thing"],
            ["ts": 1_001, "say": "api_req_started", "text": requestString],
            ["ts": 1_002, "say": "text", "text": "done"]
        ]
        try writeJSON(messages, to: taskDir.appendingPathComponent("ui_messages.json"))

        let adapter = ClineAdapter(tasksRoot: tasksRoot.path)
        let locators = try await adapter.listSessionLocators()
        guard let locator = locators.first,
              case let .success(info) = try await adapter.parseSessionInfo(locator: locator)
        else {
            XCTFail("Cline fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, parenPath)
    }

    // Falls back to the loose pattern for caches that lack the " Files" trailer.
    func testClineCwdFallsBackWhenNoFilesSuffix() async throws {
        let tasksRoot = try makeTempDir("cline-fallback")
        defer { try? FileManager.default.removeItem(at: tasksRoot) }
        let taskDir = tasksRoot.appendingPathComponent("task-2", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)

        let requestText = "Current Working Directory (/Users/test/plain)"
        let innerRequest = try JSONSerialization.data(withJSONObject: ["request": requestText])
        let requestString = String(data: innerRequest, encoding: .utf8)!
        let messages: [[String: Any]] = [
            ["ts": 1_000, "say": "task", "text": "do the thing"],
            ["ts": 1_001, "say": "api_req_started", "text": requestString]
        ]
        try writeJSON(messages, to: taskDir.appendingPathComponent("ui_messages.json"))

        let adapter = ClineAdapter(tasksRoot: tasksRoot.path)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Cline fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "/Users/test/plain")
    }

    // Part B — Windsurf must surface cwd from the Cascade conversation summary
    // when the cache metadata carries it.
    func testWindsurfSurfacesCwdFromCacheMetadata() async throws {
        let cacheDir = try makeTempDir("windsurf")
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let lines = [
            #"{"id":"conv-1","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z","cwd":"/Users/test/ws-project"}"#,
            #"{"role":"user","content":"hi","timestamp":"2026-02-18T09:00:00.000Z"}"#
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: cacheDir.appendingPathComponent("conv-1.jsonl"), atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(cacheDir: cacheDir.path, enableLiveSync: false)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Windsurf fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "/Users/test/ws-project")
    }

    // Empty cwd remains empty when metadata lacks the field (backward compatible).
    func testWindsurfCwdEmptyWhenMetadataMissing() async throws {
        let cacheDir = try makeTempDir("windsurf-empty")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let lines = [
            #"{"id":"conv-2","title":"T","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:20:00.000Z"}"#,
            #"{"role":"user","content":"hi","timestamp":"2026-02-18T09:00:00.000Z"}"#
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: cacheDir.appendingPathComponent("conv-2.jsonl"), atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(cacheDir: cacheDir.path, enableLiveSync: false)
        let locator = try await adapter.listSessionLocators().first!
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: locator) else {
            XCTFail("Windsurf fixture should parse")
            return
        }
        XCTAssertEqual(info.cwd, "")
    }

    // Part B — Codex counts a tool invocation once (function_call only), not both
    // the function_call and its paired function_call_output.
    func testCodexCountsToolUseOncePerFunctionCall() async throws {
        let root = try makeTempDir("codex")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-sample.jsonl")
        try writeJSONL(
            [
                ["type": "session_meta", "timestamp": "2026-01-15T10:00:00Z", "payload": ["id": "s1", "timestamp": "2026-01-15T10:00:00Z", "cwd": "/repo"]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:01Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "fix it"]]]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:02Z", "payload": ["type": "function_call", "name": "read_file", "arguments": ["path": "a.ts"]]],
                ["type": "response_item", "timestamp": "2026-01-15T10:00:03Z", "payload": ["type": "function_call_output", "output": "contents"]]
            ],
            to: file
        )

        let adapter = CodexAdapter(sessionsRoot: root.path)
        guard case let .success(info) = try await adapter.parseSessionInfo(locator: file.path) else {
            XCTFail("Codex fixture should parse")
            return
        }
        // 1 user + 0 assistant + 1 tool (function_call only).
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 2)
    }

    // Part A R5-17 — concurrent observe()/drainReady() must not corrupt the
    // pending queue. Each unique path should be indexed exactly once.
    func testSessionWatcherHandlesConcurrentObserveAndDrain() async throws {
        let home = "/tmp/engram-home"
        let clock = FixedWatcherClock(value: 10_000)
        let indexer = CountingWatchIndexer()
        let watcher = SessionWatcher(
            home: home,
            indexer: indexer,
            orphanMarker: NoopWatchOrphanMarker(),
            clock: clock,
            config: WatchBatchConfig(writeStabilityMilliseconds: 0, pollMilliseconds: 1, maxDrainBatchSize: 1_000)
        )

        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<200 {
                group.addTask {
                    _ = try? await watcher.observe(
                        .added(path: "\(home)/.codex/sessions/file-\(idx).jsonl", sizeBytes: 1, modifiedAtMilliseconds: 1)
                    )
                }
            }
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await watcher.drainReady()
                }
            }
        }
        _ = try await watcher.drainReady()

        let counts = await indexer.pathCounts()
        XCTAssertEqual(counts.count, 200, "every distinct path should be indexed")
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 }, "no path should be indexed twice")
    }

    // Part A R5-50 — StreamingLineReader.failures reads are race-free; an
    // oversized line is reported as a failure without crashing.
    func testStreamingLineReaderReportsOversizedLineSafely() throws {
        let dir = try makeTempDir("reader")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.jsonl")
        let big = String(repeating: "x", count: 64) + "\nok\n"
        try big.write(to: file, atomically: true, encoding: .utf8)

        let reader = try StreamingLineReader(fileURL: file, maxLineBytes: 8)
        var lines: [String] = []
        for line in try reader.readLines() {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(reader.failures, [.lineTooLarge])
    }
}

private final class FixedWatcherClock: WatcherClock {
    private let value: Int
    init(value: Int) { self.value = value }
    var nowMilliseconds: Int { value }
}

private actor PathCounter {
    private var counts: [String: Int] = [:]
    func increment(_ path: String) { counts[path, default: 0] += 1 }
    func snapshot() -> [String: Int] { counts }
}

private final class CountingWatchIndexer: SessionWatchIndexing, @unchecked Sendable {
    private let counter = PathCounter()

    func indexFile(source: SourceName, path: String) async throws -> SessionWatchIndexResult {
        await counter.increment(path)
        return SessionWatchIndexResult(indexed: true, sessionId: path)
    }

    func rescanSubtree(source: SourceName, root: String) async throws {}

    func pathCounts() async -> [String: Int] {
        await counter.snapshot()
    }
}

private final class NoopWatchOrphanMarker: SessionWatchOrphanMarking, @unchecked Sendable {
    func markOrphanByPath(_ path: String, reason: SessionWatchOrphanReason) throws -> Int { 0 }
}
