import Foundation
import GRDB
import SQLite3
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

private struct AdapterNoopIndexingWriteSink: IndexingWriteSink {
    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        SessionBatchUpsertResult(reason: reason, results: [])
    }
}

/// Coverage for the adapter message-count fixes (data-integrity review pass):
/// parseSessionInfo counts must reflect only the turns that streamMessages
/// actually emits — empty / tool-only / function-call-only turns must not
/// inflate the counts. Also covers the generic (non-personal) Antigravity CLI
/// cwd inference.
final class AdapterMessageCountTests: XCTestCase {
    // MARK: - Helpers

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-adapter-count-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sessionInfo<T>(_ result: AdapterParseResult<T>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
            throw failure
        }
    }

    private func parseFailure<T>(_ result: AdapterParseResult<T>) throws -> ParserFailure {
        switch result {
        case .success:
            XCTFail("expected adapter failure")
            throw ParserFailure.malformedJSON
        case .failure(let failure):
            return failure
        }
    }

    private func drain(_ adapter: SessionAdapter, locator: String) async throws -> [NormalizedMessage] {
        let stream = try await adapter.streamMessages(locator: locator, options: StreamMessagesOptions())
        var messages: [NormalizedMessage] = []
        for try await message in stream {
            messages.append(message)
        }
        return messages
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func testBoundedWindowDefersLaterParseFailureUntilShortPage_repro() {
        let messages = (0..<600).map {
            NormalizedMessage(role: .user, content: "m\($0)")
        }

        let first = JSONLAdapterSupport.boundedWindowWithMetadata(
            messages,
            options: StreamMessagesOptions(offset: 0, limit: 500),
            maxMessages: 10_000,
            parseFailure: .lineTooLarge
        )
        XCTAssertEqual(first.messages.count, 500)
        XCTAssertNil(first.parseFailure, "a filled page must not expose a later file-level failure")

        let last = JSONLAdapterSupport.boundedWindowWithMetadata(
            messages,
            options: StreamMessagesOptions(offset: 500, limit: 500),
            maxMessages: 10_000,
            parseFailure: .lineTooLarge
        )
        XCTAssertEqual(last.messages.count, 100)
        XCTAssertEqual(last.parseFailure, .lineTooLarge)
    }

    private func assertLoadAllCollectsProducedCap(
        _ adapter: SessionAdapter,
        locator: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var offset = 0
        var collected: [NormalizedMessage] = []
        var pageLimit = 2
        var sawTruncation = false
        while true {
            let result = try await adapter.streamMessagesWithMetadata(
                locator: locator,
                options: StreamMessagesOptions(offset: offset, limit: pageLimit)
            )
            var page: [NormalizedMessage] = []
            for try await message in result.messages { page.append(message) }
            collected += page
            offset += page.count
            sawTruncation = result.truncated
            if result.truncated || page.count < pageLimit { break }
            pageLimit = 500
        }
        XCTAssertEqual(collected.count, 3, file: file, line: line)
        XCTAssertEqual(offset, 3, file: file, line: line)
        XCTAssertTrue(sawTruncation, file: file, line: line)
    }

    func testClineLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("load-all-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let locator = taskDir.appendingPathComponent("ui_messages.json")
        let rows: [[String: Any]] = (0..<8).map { index in
            ["ts": 1_771_392_000_000 + index * 1_000, "type": "say",
             "say": index.isMultiple(of: 2) ? "task" : "text", "text": "cline \(index)"]
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: locator)
        try await assertLoadAllCollectsProducedCap(
            ClineAdapter(tasksRoot: root.path, limits: ParserLimits(maxMessages: 3)),
            locator: locator.path
        )
    }

    func testClineUnclosedArrayKeepsParsedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("cline-unclosed-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let locator = taskDir.appendingPathComponent("ui_messages.json")
        try #"[{"ts":1771392000000,"type":"say","say":"task","text":"cline prefix"}"#
            .write(to: locator, atomically: true, encoding: .utf8)

        let result = try await ClineAdapter(tasksRoot: root.path)
            .streamMessagesWithMetadata(
                locator: locator.path,
                options: StreamMessagesOptions(offset: 0, limit: 500)
            )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertEqual(messages.map(\.content), ["cline prefix"])
        XCTAssertEqual(result.parseFailure, .malformedJSON)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertNil(result.truncatedAt)
    }

    func testClineUnclosedArrayScanKeepsParsedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("cline-unclosed-scan", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let locator = taskDir.appendingPathComponent("ui_messages.json")
        try #"[{"ts":1771392000000,"type":"say","say":"task","text":"scan prefix"},{"ts":1771392001000,"type":"say","say":"text","text":"scan reply"}"#
            .write(to: locator, atomically: true, encoding: .utf8)

        guard case .success(let scan) = try await ClineAdapter(tasksRoot: root.path)
            .scanForIndexing(locator: locator.path)
        else {
            return XCTFail("an unclosed array with messages must keep its indexing prefix")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["scan prefix", "scan reply"])
        XCTAssertEqual(scan.parseFailure, .malformedJSON)
    }

    func testCodexFilledPageStillRunsAfterIdentityValidation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("rollout-filled-page.jsonl")
        let valid = try jsonLine([
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "filled page"]],
            ],
        ])
        try valid.appending("\n").write(to: locator, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(
            sessionsRoot: root.path,
            testHooks: CodexAdapterTestHooks(beforeFinalIdentityValidation: {
                try? FileManager.default.removeItem(at: locator)
            })
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions(offset: 0, limit: 1)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["filled page"])
        XCTAssertEqual(result.parseFailure, .fileModifiedDuringParse)
    }

    func testCodexAfterIdentityFailureKeepsNonemptyWindow_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("rollout-unlimited-prefix.jsonl")
        let valid = try jsonLine([
            "type": "response_item",
            "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "unlimited prefix"]],
            ],
        ])
        try valid.appending("\n").write(to: locator, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(
            sessionsRoot: root.path,
            testHooks: CodexAdapterTestHooks(beforeFinalIdentityValidation: {
                try? FileManager.default.removeItem(at: locator)
            })
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["unlimited prefix"])
        XCTAssertEqual(result.parseFailure, .fileModifiedDuringParse)
    }

    func testCopilotCheckpointBodyMutationKeepsEarlierPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("checkpoint-stream-prefix", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try "id: checkpoint-stream-prefix\ncwd: /tmp/copilot\n"
            .write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let index = checkpointsDir.appendingPathComponent("index.md")
        try "| 1 | First | 001.md |\n| 2 | Second | 002.md |\n"
            .write(to: index, atomically: true, encoding: .utf8)
        try "first body".write(to: checkpointsDir.appendingPathComponent("001.md"), atomically: true, encoding: .utf8)
        let second = checkpointsDir.appendingPathComponent("002.md")
        try "second body".write(to: second, atomically: true, encoding: .utf8)
        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeCheckpointBodyIdentityValidation: { number in
                if number == 2 { try? FileManager.default.removeItem(at: second) }
            })
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: index.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["Checkpoint 1: First\n\nfirst body"])
        XCTAssertEqual(result.parseFailure, .fileModifiedDuringParse)
    }

    func testCopilotPlainStreamsKeepCheckpointAndEventsPrefixes_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let checkpointSession = root.appendingPathComponent("checkpoint-plain-prefix", isDirectory: true)
        let checkpoints = checkpointSession.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try "id: checkpoint-plain-prefix\ncwd: /tmp/copilot\n"
            .write(to: checkpointSession.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let index = checkpoints.appendingPathComponent("index.md")
        try "| 1 | First | 001.md |\n| 2 | Second | 002.md |\n"
            .write(to: index, atomically: true, encoding: .utf8)
        try "first body".write(to: checkpoints.appendingPathComponent("001.md"), atomically: true, encoding: .utf8)
        let secondBody = checkpoints.appendingPathComponent("002.md")
        try "second body".write(to: secondBody, atomically: true, encoding: .utf8)
        let checkpointAdapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeCheckpointBodyIdentityValidation: { number in
                if number == 2 { try? FileManager.default.removeItem(at: secondBody) }
            })
        )
        let checkpointMessages = try await drain(checkpointAdapter, locator: index.path)
        XCTAssertEqual(checkpointMessages.map(\.content), ["Checkpoint 1: First\n\nfirst body"])

        let eventsSession = root.appendingPathComponent("events-plain-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsSession, withIntermediateDirectories: true)
        try "id: events-plain-prefix\ncwd: /tmp/copilot\n"
            .write(to: eventsSession.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = eventsSession.appendingPathComponent("events.jsonl")
        let valid = try jsonLine(["type": "user.message", "data": ["content": "events prefix"]])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: events, atomically: true, encoding: .utf8)
        let eventMessages = try await drain(
            CopilotAdapter(sessionRoot: root.path, limits: ParserLimits(maxLineBytes: 256)),
            locator: events.path
        )
        XCTAssertEqual(eventMessages.map(\.content), ["events prefix"])
    }

    func testCopilotParseInfoKeepsEventsWhenWorkspaceChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("events-info-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let workspace = session.appendingPathComponent("workspace.yaml")
        try "id: events-info-prefix\ncwd: /tmp/copilot\n"
            .write(to: workspace, atomically: true, encoding: .utf8)
        let events = session.appendingPathComponent("events.jsonl")
        try jsonLine(["type": "user.message", "data": ["content": "retained info"]])
            .appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)
        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeEventsWorkspaceIdentityValidation: {
                try? FileManager.default.removeItem(at: workspace)
            })
        )

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: events.path))
        XCTAssertEqual(info.messageCount, 1)
        XCTAssertEqual(info.summary, "retained info")
    }

    func testKimiWireFailureKeepsContextPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("workspace/session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let context = session.appendingPathComponent("context.jsonl")
        try jsonLine(["role": "user", "content": "kimi prefix"])
            .appending("\n")
            .write(to: context, atomically: true, encoding: .utf8)
        let wire = session.appendingPathComponent("wire.jsonl")
        let turn = try jsonLine(["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]])
        try (turn + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: wire, atomically: true, encoding: .utf8)
        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxLineBytes: 256)
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: context.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["kimi prefix"])
        XCTAssertEqual(result.parseFailure, .lineTooLarge)
    }

    func testCopilotEventsReadFailureKeepsProducedIndexingPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("events-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "id: events-prefix\ncwd: /tmp/copilot\n"
            .write(to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = session.appendingPathComponent("events.jsonl")
        let valid = try jsonLine(["type": "user.message", "data": ["content": "events prefix"]])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let result = try await CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxLineBytes: 256)
        ).scanForIndexing(locator: events.path)
        guard case .success(let scan) = result else {
            return XCTFail("a non-cap events read failure must retain produced messages")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["events prefix"])
        XCTAssertEqual(scan.parseFailure, .lineTooLarge)
    }

    func testCopilotWorkspaceIdentityFailureKeepsProducedIndexingPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("workspace-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let workspace = session.appendingPathComponent("workspace.yaml")
        try "id: workspace-prefix\ncwd: /tmp/copilot\n"
            .write(to: workspace, atomically: true, encoding: .utf8)
        let events = session.appendingPathComponent("events.jsonl")
        try (try jsonLine(["type": "user.message", "data": ["content": "workspace prefix"]]) + "\n")
            .write(to: events, atomically: true, encoding: .utf8)
        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeEventsWorkspaceIdentityValidation: {
                try? FileManager.default.removeItem(at: workspace)
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: events.path) else {
            return XCTFail("a workspace identity tick must retain produced events")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["workspace prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testCopilotEventsMessageLimitKeepsCompositePrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("events-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "id: events-cap\ncwd: /tmp/copilot\n"
            .write(to: session.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = session.appendingPathComponent("events.jsonl")
        let lines = try (0..<3).map { index in
            try jsonLine(["type": "user.message", "data": ["content": "m\(index)"]])
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let result = try await CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 2)
        ).scanForIndexing(locator: events.path)
        guard case .success(let scan) = result else {
            return XCTFail("a capped events prefix must still read workspace metadata and index")
        }
        XCTAssertEqual(scan.info.id, "events-cap")
        XCTAssertEqual(scan.info.cwd, "/tmp/copilot")
        XCTAssertEqual(scan.messages.map(\.content), ["m0", "m1"])
        XCTAssertEqual(scan.parseFailure, .messageLimitExceeded)
    }

    func testGeminiJSONThreadsSnapshotIdentityFailure_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = root.appendingPathComponent("tmp/project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let locator = chats.appendingPathComponent("gemini-live.json")
        let session: [String: Any] = [
            "sessionId": "gemini-live", "startTime": "2026-08-23T00:00:00Z",
            "messages": [["type": "user", "content": "gemini snapshot"]],
        ]
        try JSONSerialization.data(withJSONObject: session).write(to: locator)
        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            testHooks: GeminiCliAdapterTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" ".utf8))
                    try? handle.close()
                }
            })
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["gemini snapshot"])
        XCTAssertEqual(result.parseFailure, .fileModifiedDuringParse)
    }

    func testGeminiScanKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chats = root.appendingPathComponent("tmp/project/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let locator = chats.appendingPathComponent("gemini-scan-live.json")
        let session: [String: Any] = [
            "sessionId": "gemini-scan-live", "startTime": "2026-08-24T00:00:00Z",
            "messages": [["type": "user", "content": "gemini scan prefix"]],
        ]
        try JSONSerialization.data(withJSONObject: session).write(to: locator)
        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            testHooks: GeminiCliAdapterTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" ".utf8))
                    try? handle.close()
                }
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator.path) else {
            return XCTFail("a Gemini file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["gemini scan prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testCursorModernTruncatedJSONLKeepsParsedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "modern-prefix"
        try Self.buildModernCursorFixture(cursorRoot: cursorRoot, sessionID: sessionID, name: "Prefix")
        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing.vscdb").path,
            cursorDataRoot: cursorRoot,
            limits: ParserLimits(maxLineBytes: 256)
        )
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)
        let transcript = cursorRoot
            .appendingPathComponent("projects/Users-test-project/agent-transcripts/\(sessionID)/\(sessionID).jsonl")
        if let handle = try? FileHandle(forWritingTo: transcript) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + String(repeating: "x", count: 300) + "\n").utf8))
            try handle.close()
        }

        let result = try await adapter.streamMessagesWithMetadata(
            locator: locator,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["Modern first user prompt", "Modern assistant reply"])
        XCTAssertEqual(result.parseFailure, .lineTooLarge)
    }

    func testCursorModernScanKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "modern-scan-prefix"
        try Self.buildModernCursorFixture(cursorRoot: cursorRoot, sessionID: sessionID, name: "Prefix")
        let transcript = cursorRoot
            .appendingPathComponent("projects/Users-test-project/agent-transcripts/\(sessionID)/\(sessionID).jsonl")
        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing.vscdb").path,
            cursorDataRoot: cursorRoot,
            testHooks: CursorAdapterTestHooks(beforeModernIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: transcript) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator) else {
            return XCTFail("a Cursor file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["Modern first user prompt", "Modern assistant reply"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testCursorLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOversizedFixture(dbPath: dbPath)
        try await assertLoadAllCollectsProducedCap(
            CursorAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 3)),
            locator: "\(dbPath)?composer=cmp_oversize"
        )
    }

    func testOpenCodeLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeOversizedFixture(dbPath: dbPath)
        try await assertLoadAllCollectsProducedCap(
            OpenCodeAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 3)),
            locator: "\(dbPath)::ses_oversize"
        )
    }

    func testCopilotCheckpointLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-load-all-checkpoint", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try "id: session-load-all-checkpoint\ncwd: /tmp/copilot\n"
            .write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        var table = "# Checkpoint History\n\n| # | Title | File |\n|---|-------|------|"
        for index in 1...8 { table += "\n| \(index) | checkpoint \(index) | |" }
        let locator = checkpointsDir.appendingPathComponent("index.md")
        try table.write(to: locator, atomically: true, encoding: .utf8)
        try await assertLoadAllCollectsProducedCap(
            CopilotAdapter(sessionRoot: root.path, limits: ParserLimits(maxMessages: 3)),
            locator: locator.path
        )
    }

    func testGeminiCliJSONLLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let locator = chatsDir.appendingPathComponent("session-jsonl-load-all.jsonl")
        let lines: [[String: Any]] = (0..<8).map { index in
            ["type": index.isMultiple(of: 2) ? "user" : "gemini",
             "sessionId": "g-jsonl-load-all", "content": "gemini \(index)"]
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertLoadAllCollectsProducedCap(
            GeminiCliAdapter(
                tmpRoot: root.appendingPathComponent("tmp").path,
                projectsFile: root.appendingPathComponent("projects.json").path,
                limits: ParserLimits(maxMessages: 3)
            ),
            locator: locator.path
        )
    }

    func testKimiLoadAllCollectsProducedPrefixCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace/session-load-all", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let locator = sessionDir.appendingPathComponent("context.jsonl")
        let rows: [[String: Any]] = (0..<8).map { index in
            ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "kimi \(index)"]
        }
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertLoadAllCollectsProducedCap(
            KimiAdapter(
                sessionsRoot: root.path,
                kimiJsonPath: root.appendingPathComponent("kimi.json").path,
                limits: ParserLimits(maxMessages: 3)
            ),
            locator: locator.path
        )
    }

    func testCodexKeepsPrefixWhenLaterLineIsOversized_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("rollout-prefix.jsonl")
        let valid = try jsonLine([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "codex prefix"]],
            ],
        ])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertMetadataKeepsParseFailurePrefix(
            CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxLineBytes: 256)),
            locator: locator.path,
            expected: "codex prefix"
        )
    }

    func testGeminiJSONLKeepsPrefixWhenLaterLineIsOversized_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("gemini-prefix.jsonl")
        let valid = try jsonLine([
            "type": "user", "sessionId": "gemini-prefix", "content": "gemini prefix",
        ])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertMetadataKeepsParseFailurePrefix(
            GeminiCliAdapter(
                tmpRoot: root.path,
                projectsFile: root.appendingPathComponent("projects.json").path,
                limits: ParserLimits(maxLineBytes: 256)
            ),
            locator: locator.path,
            expected: "gemini prefix"
        )
    }

    func testQwenKeepsPrefixWhenLaterLineIsOversized_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("qwen-prefix.jsonl")
        let valid = try jsonLine([
            "type": "user",
            "sessionId": "qwen-prefix",
            "message": ["role": "user", "parts": [["text": "qwen prefix"]]],
        ])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertMetadataKeepsParseFailurePrefix(
            QwenAdapter(projectsRoot: root.path, limits: ParserLimits(maxLineBytes: 256)),
            locator: locator.path,
            expected: "qwen prefix"
        )
    }

    func testQwenScanAndPlainStreamKeepPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("qwen-changing-prefix.jsonl")
        let valid = try jsonLine([
            "type": "user",
            "sessionId": "qwen-changing-prefix",
            "message": ["role": "user", "parts": [["text": "qwen changing prefix"]]],
        ])
        try valid.appending("\n").write(to: locator, atomically: true, encoding: .utf8)
        let adapter = QwenAdapter(
            projectsRoot: root.path,
            testHooks: QwenAdapterTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator.path) else {
            return XCTFail("a Qwen file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["qwen changing prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)

        var streamed: [NormalizedMessage] = []
        for try await message in try await adapter.streamMessages(
            locator: locator.path,
            options: StreamMessagesOptions()
        ) {
            streamed.append(message)
        }
        XCTAssertEqual(streamed.map(\.content), ["qwen changing prefix"])
    }

    func testCommandCodeScanKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locator = project.appendingPathComponent("commandcode-changing.jsonl")
        try jsonLine([
            "role": "user",
            "sessionId": "commandcode-changing",
            "cwd": "/tmp/commandcode",
            "content": "commandcode prefix",
        ]).appending("\n").write(to: locator, atomically: true, encoding: .utf8)
        let adapter = CommandCodeAdapter(
            projectsRoot: root.path,
            testHooks: JSONLIdentityTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator.path) else {
            return XCTFail("a CommandCode file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["commandcode prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testQoderScanKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locator = project.appendingPathComponent("qoder-changing.jsonl")
        try jsonLine([
            "type": "user",
            "sessionId": "qoder-changing",
            "cwd": "/tmp/qoder",
            "message": ["role": "user", "content": "qoder prefix"],
        ]).appending("\n").write(to: locator, atomically: true, encoding: .utf8)
        let adapter = QoderAdapter(
            projectsRoot: root.path,
            testHooks: JSONLIdentityTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator.path) else {
            return XCTFail("a Qoder file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["qoder prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testKimiScanKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("workspace/kimi-changing", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let locator = session.appendingPathComponent("context.jsonl")
        try jsonLine(["role": "user", "content": "kimi changing prefix"])
            .appending("\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            testHooks: JSONLIdentityTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: locator) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: locator.path) else {
            return XCTFail("a Kimi file change after a produced prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["kimi changing prefix"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    func testWholeDocumentFailureIsReportedOnlyWhenWindowReachesPrefixEnd_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("qwen-window-scoped-failure.jsonl")
        let valid = try (0..<3).map { index in
            try jsonLine([
                "type": index.isMultiple(of: 2) ? "user" : "assistant",
                "sessionId": "qwen-window-failure",
                "message": ["role": "user", "parts": [["text": "qwen \(index)"]]],
            ])
        }
        try (valid.joined(separator: "\n") + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        let adapter = QwenAdapter(projectsRoot: root.path, limits: ParserLimits(maxLineBytes: 256))

        let first = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions(offset: 0, limit: 2)
        )
        var firstMessages: [NormalizedMessage] = []
        for try await message in first.messages { firstMessages.append(message) }
        XCTAssertEqual(firstMessages.count, 2)
        XCTAssertNil(first.parseFailure)
        XCTAssertTrue(first.totalKnownComplete)

        let second = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions(offset: 2, limit: 500)
        )
        var secondMessages: [NormalizedMessage] = []
        for try await message in second.messages { secondMessages.append(message) }
        XCTAssertEqual(secondMessages.map(\.content), ["qwen 2"])
        XCTAssertEqual(second.parseFailure, .lineTooLarge)
        XCTAssertFalse(second.totalKnownComplete)
    }

    func testClaudeKeepsPrefixWhenLaterLineIsOversized_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = root.appendingPathComponent("claude-prefix.jsonl")
        let valid = try jsonLine([
            "type": "user",
            "sessionId": "claude-prefix",
            "message": ["role": "user", "content": "claude prefix"],
        ])
        try (valid + "\n" + String(repeating: "x", count: 300) + "\n")
            .write(to: locator, atomically: true, encoding: .utf8)
        try await assertMetadataKeepsParseFailurePrefix(
            ClaudeCodeAdapter(projectsRoot: root.path, limits: ParserLimits(maxLineBytes: 256)),
            locator: locator.path,
            expected: "claude prefix"
        )
    }

    private func assertMetadataKeepsParseFailurePrefix(
        _ adapter: SessionAdapter,
        locator: String,
        expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try await adapter.streamMessagesWithMetadata(
            locator: locator,
            options: StreamMessagesOptions(offset: 0, limit: 500)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), [expected], file: file, line: line)
        XCTAssertEqual(result.parseFailure, .lineTooLarge, file: file, line: line)
        XCTAssertFalse(result.totalKnownComplete, file: file, line: line)
        XCTAssertNil(result.truncatedAt, file: file, line: line)
    }

    func testAdapterAssertionHelpersNeverSkipOppositeResults_repro() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let helpers = try XCTUnwrap(source.range(of: "private func sessionInfo<T>")?.lowerBound)
        let helperEnd = try XCTUnwrap(source.range(of: "private func drain(_ adapter", range: helpers..<source.endIndex)?.lowerBound)
        let helperSource = source[helpers..<helperEnd]
        XCTAssertFalse(
            helperSource.contains("XCTSkip"),
            "opposite adapter results are assertion failures, never green skips"
        )
    }

    private func assertStreamInjectionParity(
        _ adapter: SessionAdapter,
        locator: String,
        firstUserText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        let streamed = try await drain(adapter, locator: locator)

        XCTAssertEqual(info.userMessageCount, 1, file: file, line: line)
        XCTAssertEqual(info.assistantMessageCount, 1, file: file, line: line)
        XCTAssertEqual(info.systemMessageCount, 1, file: file, line: line)
        XCTAssertEqual(info.messageCount, 2, file: file, line: line)
        XCTAssertEqual(info.summary, firstUserText, file: file, line: line)
        XCTAssertEqual(streamed.map(\.role), [.system, .user, .assistant], file: file, line: line)
        XCTAssertEqual(
            streamed.filter { $0.role != .system }.count,
            info.messageCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            streamed.filter { $0.role == .user }.count,
            info.userMessageCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            streamed.filter { $0.role == .system }.count,
            info.systemMessageCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            streamed.first { $0.role == .user }?.content,
            firstUserText,
            file: file,
            line: line
        )
    }

    // MARK: - VsCode

    // Runtime-debt repro: VS Code persists valid empty draft sessions that are
    // not malformed transcripts and must not enter the retry loop.
    func testVsCodeEmptyDraftIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-empty/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-empty-draft",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let file = chatDir.appendingPathComponent("empty.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    /// VS Code inherits SessionAdapter's default streamMessagesWithMetadata, so
    /// an oversized whole-transcript read is capped without a truncation marker.
    func testVsCodeOversizedTranscriptReportsTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-oversized/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let requests: [[String: Any]] = (0..<4).map { index in
            [
                "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["text": "vs question \(index)"],
                "response": [
                    ["value": ["kind": "markdownContent", "content": ["value": "vs answer \(index)"]]],
                ],
            ]
        }
        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-oversized",
                "creationDate": 1_700_000_000_000,
                "requests": requests,
            ],
        ]
        let file = chatDir.appendingPathComponent("oversized.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(
            workspaceStorageDir: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    /// parseSessionInfo counted every request without the produced-message cap,
    /// so an oversized VS Code session returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001L
    func testVsCodeOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-oversized-info/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let requests: [[String: Any]] = (0..<4).map { index in
            [
                "timestamp": 1_700_000_000_000 + index * 1_000,
                "message": ["text": "vs info question \(index)"],
                "response": [
                    ["value": ["kind": "markdownContent", "content": ["value": "vs info answer \(index)"]]],
                ],
            ]
        }
        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-oversized-info",
                "creationDate": 1_700_000_000_000,
                "requests": requests,
            ],
        ]
        let file = chatDir.appendingPathComponent("oversized-info.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(
            workspaceStorageDir: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    // Audit L24: one stable corrupt request must not poison the valid requests
    // and leave the unchanged locator on the malformed-JSON retry schedule.
    func testVsCodePartiallyCorruptRequestsDoNotEnterRetryLoop_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-partial/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let validRequest: [String: Any] = [
            "timestamp": 1_700_000_005_000,
            "message": ["text": "keep this request"],
            "response": [
                ["value": ["kind": "markdownContent", "content": ["value": "keep this answer"]]],
            ],
        ]
        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-partial-corruption",
                "creationDate": 1_700_000_000_000,
                "requests": ["stable-corrupt-record", validRequest],
            ],
        ]
        let file = chatDir.appendingPathComponent("partial.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            let streamed = try await drain(adapter, locator: file.path)
            XCTAssertEqual(info.userMessageCount, 1)
            XCTAssertEqual(info.assistantMessageCount, 1)
            XCTAssertEqual(info.summary, "keep this request")
            XCTAssertEqual(streamed.map(\.content), [
                "keep this request",
                "keep this answer",
            ])
        case .failure(let failure):
            XCTFail("valid VS Code requests must survive corrupt siblings; got \(failure)")
        }
    }

    func testVsCodeCountsOnlyNonEmptyTurns() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        // Request 1: normal user + markdown assistant.
        // Request 2: user text present, but assistant response is non-markdown
        //            (tool output only) → extractAssistantText returns "".
        let session: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-1",
                "creationDate": 1_700_000_000_000,
                "requests": [
                    [
                        "timestamp": 1_700_000_000_000,
                        "message": ["text": "first question"],
                        "response": [
                            ["value": ["kind": "markdownContent", "content": ["value": "answer one"]]]
                        ],
                    ],
                    [
                        "timestamp": 1_700_000_010_000,
                        "message": ["text": "second question"],
                        "response": [
                            ["value": ["kind": "toolInvocationSerialized", "content": ["value": "n/a"]]]
                        ],
                    ],
                ],
            ],
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try (try jsonLine(session) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 1, "non-markdown assistant turn must not be counted")
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.filter { $0.role == .assistant }.count, info.assistantMessageCount)
        XCTAssertEqual(streamed.filter { $0.role == .user }.count, info.userMessageCount)
    }

    func testVsCodeReplaysAppendMutationLog() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-replay",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let request: [String: Any] = [
            "requestId": "r1",
            "timestamp": 1_700_000_005_000,
            "message": ["text": "request from mutation log"],
            "response": [
                ["value": ["kind": "markdownContent", "content": ["value": "answer from mutation log"]]]
            ],
        ]
        let push: [String: Any] = [
            "kind": 2,
            "k": ["requests"],
            "v": [request],
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(push)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.summary, "request from mutation log")
        XCTAssertEqual(streamed.map(\.content), ["request from mutation log", "answer from mutation log"])
    }

    func testVsCodeRejectsDeepMutationPaths() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-1/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-deep-path",
                "creationDate": 1_700_000_000_000,
                "requests": [
                    [
                        "timestamp": 1_700_000_000_000,
                        "message": ["text": "kept valid"],
                        "response": [
                            ["value": ["kind": "markdownContent", "content": ["value": "valid answer"]]]
                        ],
                    ],
                ],
            ],
        ]
        let deepMutation: [String: Any] = [
            "kind": 1,
            "k": Array(repeating: "nested", count: 65),
            "v": "too deep",
        ]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(deepMutation)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(workspaceStorageDir: root.path)
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .failure(.malformedJSON):
            break
        case .failure(let failure):
            XCTFail("expected malformedJSON for over-deep mutation path, got \(failure)")
        case .success:
            XCTFail("over-deep VS Code mutation paths must be rejected before recursive replay")
        }
    }

    // Audit VSCODE-INCR-001: mutation logs depend on a complete op sequence;
    // exceeding maxMessages must fail, not succeed on a truncated prefix.
    func testVsCodeMutationLogOverObjectLimitIsRejected_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-limit/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-limit",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let firstRequest: [String: Any] = [
            "requestId": "r1",
            "timestamp": 1_700_000_005_000,
            "message": ["text": "first request"],
            "response": [
                ["value": ["kind": "markdownContent", "content": ["value": "first answer"]]],
            ],
        ]
        let secondRequest: [String: Any] = [
            "requestId": "r2",
            "timestamp": 1_700_000_006_000,
            "message": ["text": "second request"],
            "response": [
                ["value": ["kind": "markdownContent", "content": ["value": "second answer"]]],
            ],
        ]
        let push1: [String: Any] = ["kind": 2, "k": ["requests"], "v": [firstRequest]]
        let push2: [String: Any] = ["kind": 2, "k": ["requests"], "v": [secondRequest]]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(push1), try jsonLine(push2)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = VsCodeAdapter(
            workspaceStorageDir: root.path,
            limits: ParserLimits(maxMessages: 2)
        )
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        case .success(let info):
            XCTFail("expected messageLimitExceeded for truncated mutation log, got success id=\(info.id) messages=\(info.messageCount)")
        }
    }

    func testVsCodeMutationLogMetadataCapsVisibleMessagesNotMutationObjects_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-metadata-limit/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-metadata-limit",
                "creationDate": 1_700_000_000_000,
                "requests": [],
            ],
        ]
        let request: [String: Any] = [
            "timestamp": 1_700_000_000_000,
            "message": ["text": "question"],
            "response": [["value": ["kind": "markdownContent", "content": ["value": "answer"]]]],
        ]
        let push: [String: Any] = ["kind": 2, "k": ["requests"], "v": [request]]
        let file = chatDir.appendingPathComponent("sess.jsonl")
        try ([try jsonLine(initial), try jsonLine(push), try jsonLine(push)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = VsCodeAdapter(
            workspaceStorageDir: root.path,
            limits: ParserLimits(maxMessages: 2)
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 0, limit: 1)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["question"])
        XCTAssertNil(result.truncatedAt, "the first page has not reached the produced-message cap")
    }

    func testVsCodeMetadataKeepsMutationPrefixOnLaterLineFailure_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatDir = root.appendingPathComponent("ws-prefix/chatSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        let initial: [String: Any] = [
            "kind": 0,
            "v": [
                "sessionId": "vs-prefix",
                "creationDate": 1_700_000_000_000,
                "requests": [[
                    "timestamp": 1_700_000_001_000,
                    "message": ["text": "kept question"],
                    "response": [["value": ["kind": "markdownContent", "content": ["value": "kept answer"]]]],
                ]],
            ],
        ]
        let file = chatDir.appendingPathComponent("prefix.jsonl")
        try (try jsonLine(initial) + "\n" + String(repeating: "x", count: 2_000) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = VsCodeAdapter(
            workspaceStorageDir: root.path,
            limits: ParserLimits(maxLineBytes: 1_000)
        )

        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 0, limit: 500)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["kept question", "kept answer"])
        XCTAssertEqual(result.parseFailure, .lineTooLarge)
        XCTAssertFalse(result.totalKnownComplete)
    }

    // MARK: - Gemini CLI

    // Audit L-b: a function-call-only model turn is a tool event, not an empty
    // assistant turn. It must contribute one streamed tool message and count.
    func testGeminiCountsFunctionOnlyTurnAsTool_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-1",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:10:00.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": "hello"]]],
                ["type": "gemini", "timestamp": "2026-01-01T00:00:02.000Z", "content": "hi there"],
                [
                    "type": "model",
                    "timestamp": "2026-01-01T00:00:03.000Z",
                    "content": [["functionCall": ["name": "read", "args": ["path": "/tmp/a.swift"]]]],
                ],
                // empty-text user turn → dropped.
                ["type": "user", "timestamp": "2026-01-01T00:00:04.000Z", "content": [["text": ""]]],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-g.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1, "empty-text user turn must not be counted")
        XCTAssertEqual(info.assistantMessageCount, 1, "function-only model turn must not inflate assistant count")
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(streamed.last?.toolCalls?.first?.name, "read")
    }

    func testGeminiLeavesCwdEmptyForAmbiguousOrUnresolvedProjectHash_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tmpRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let projectsFile = root.appendingPathComponent("projects.json")
        try JSONSerialization.data(withJSONObject: [
            "projects": [
                "/repo/one": "duplicate-hash",
                "/repo/two": "duplicate-hash",
            ],
        ]).write(to: projectsFile)

        for projectHash in ["duplicate-hash", "unknown-sha-leaf"] {
            let chatsDir = tmpRoot
                .appendingPathComponent(projectHash, isDirectory: true)
                .appendingPathComponent("chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let file = chatsDir.appendingPathComponent("session.json")
            let session: [String: Any] = [
                "sessionId": "session-\(projectHash)",
                "startTime": "2026-08-21T00:00:00Z",
                "messages": [["type": "user", "content": "hello"]],
            ]
            try JSONSerialization.data(withJSONObject: session).write(to: file)

            let adapter = GeminiCliAdapter(tmpRoot: tmpRoot.path, projectsFile: projectsFile.path)
            let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
            XCTAssertEqual(info.cwd, "", "unverified project hashes must not become cwd values")
        }
    }

    // Audit L-b: current Gemini CLI stores calls/results in a gemini record's
    // toolCalls array. The retained fixture also carries the legacy info event.
    func testGeminiCountsAndStreamsPersistedToolEvents_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-tools-1",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:10:00.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": "inspect it"]]],
                [
                    "type": "gemini",
                    "timestamp": "2026-01-01T00:00:02.000Z",
                    "content": "checking",
                    "toolCalls": [[
                        "id": "read-file-1",
                        "name": "read_file",
                        "args": ["file_path": "/tmp/a.swift"],
                        "status": "success",
                        "timestamp": "2026-01-01T00:00:02.500Z",
                        "resultDisplay": "file body",
                        "result": [[
                            "functionResponse": [
                                "id": "read-file-1",
                                "name": "read_file",
                                "response": ["output": "file body"],
                            ],
                        ]],
                    ]],
                ],
                [
                    "type": "info",
                    "timestamp": "2026-01-01T00:00:03.000Z",
                    "content": "Tool call: list_directory",
                ],
                [
                    "type": "info",
                    "timestamp": "2026-01-01T00:00:04.000Z",
                    "content": "MCP issues detected. Run /mcp list for status.",
                ],
                ["type": "model", "timestamp": "2026-01-01T00:00:05.000Z", "content": "done"],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-g-tools.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 2)
        XCTAssertEqual(info.toolMessageCount, 2)
        XCTAssertEqual(info.messageCount, 5)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool, .tool, .assistant])
        XCTAssertEqual(streamed.map(\.content), [
            "inspect it",
            "checking",
            "file body",
            "Tool call: list_directory",
            "done",
        ])
        XCTAssertEqual(streamed.compactMap { $0.toolCalls?.first?.name }, ["read_file", "list_directory"])
        XCTAssertTrue(streamed[2].toolCalls?.first?.input?.contains("file_path") == true)
        XCTAssertEqual(streamed[2].toolCalls?.first?.output, "file body")
    }

    func testGeminiAttachesAssistantTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-usage-1",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:10:00.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": "track usage"]]],
                [
                    "type": "gemini",
                    "timestamp": "2026-01-01T00:00:02.000Z",
                    "content": "usage tracked",
                    "tokens": [
                        "input": 800,
                        "output": 40,
                        "cached": 300,
                        "thoughts": 9,
                        "tool": 1,
                        "total": 850,
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-g-usage.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 500, outputTokens: 50, cacheReadTokens: 300, cacheCreationTokens: 0)
        )
    }

    func testGeminiParsesCurrentJsonlEventLogAndProjectRoot() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("tmp/hash-001", isDirectory: true)
        let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        try "/Users/test/gemini-jsonl".write(
            to: projectDir.appendingPathComponent(".project_root"),
            atomically: true,
            encoding: .utf8
        )

        let lines: [[String: Any]] = [
            [
                "kind": "main",
                "sessionId": "gemini-jsonl-1",
                "projectHash": "hash-001",
                "startTime": "2026-06-21T01:33:00.000Z",
                "lastUpdated": "2026-06-21T01:33:00.000Z",
            ],
            [
                "id": "m1",
                "timestamp": "2026-06-21T01:33:05.000Z",
                "type": "user",
                "content": [["text": "jsonl prompt"]],
            ],
            [
                "id": "m2",
                "timestamp": "2026-06-21T01:33:09.000Z",
                "type": "gemini",
                "content": "jsonl answer",
            ],
            [
                "$set": [
                    "lastUpdated": "2026-06-21T01:33:09.000Z",
                    "summary": "derived jsonl title",
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("jsonl-session-1.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try jsonLine(["originator": "claude-code"])
            .write(
                to: chatsDir.appendingPathComponent("jsonl-session-1.engram.json"),
                atomically: true,
                encoding: .utf8
            )

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            [file.standardizedFileURL.path]
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.id, "gemini-jsonl-1")
        XCTAssertEqual(info.cwd, "/Users/test/gemini-jsonl")
        XCTAssertEqual(info.endTime, "2026-06-21T01:33:09.000Z")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(streamed.map(\.content), ["jsonl prompt", "jsonl answer"])
    }

    func testGeminiIgnoresOversizedSidecar() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "gemini-sidecar-cap",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:01.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:00.000Z", "content": "hello"],
            ],
        ]
        let file = chatsDir.appendingPathComponent("gemini-sidecar-cap.json")
        try jsonLine(session).write(to: file, atomically: true, encoding: .utf8)
        try """
        {"originator":"claude-code","parentSessionId":"\(String(repeating: "x", count: 600))"}
        """.write(
            to: chatsDir.appendingPathComponent("gemini-sidecar-cap.engram.json"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            limits: ParserLimits(maxFileBytes: 512)
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertNil(info.agentRole)
        XCTAssertNil(info.parentSessionId)
    }

    // Audit ADAPTER-GEMINI-001: sidecar-only mtime must keep the locator in the
    // recent set even when the transcript file itself is older than the cutoff.
    func testGeminiSidecarOnlyChangeKeepsRecentLocator_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        // Transcript stem differs from sessionId (parity fixture shape).
        let session: [String: Any] = [
            "sessionId": "gemini-session-001",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:01.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:00.000Z", "content": "hello"],
                ["type": "gemini", "timestamp": "2026-01-01T00:00:01.000Z", "content": "hi"],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-sample.json")
        try jsonLine(session).write(to: file, atomically: true, encoding: .utf8)
        let baseline = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: chatsDir.path)

        // Sidecar is named by sessionId, not transcript stem.
        let sidecar = chatsDir.appendingPathComponent("gemini-session-001.engram.json")
        try """
        {"originator":"claude-code","parentSessionId":"cc-parent"}
        """.write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: sidecar.path
        )
        // Freeze transcript + parent dir so only the sessionId-named sidecar is recent.
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: chatsDir.path)

        let gemini = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let adapter = RecentlyModifiedSessionAdapter(
            base: gemini,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [file.resolvingSymlinksInPath().path]
        )
        switch try await gemini.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTAssertEqual(info.id, "gemini-session-001")
            XCTAssertEqual(info.parentSessionId, "cc-parent")
            XCTAssertEqual(info.agentRole, "dispatched")
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    // Audit ADAPTER-GEMINI-001: peekSessionId must survive an 8 KiB cutoff that
    // lands mid multibyte UTF-8 scalar (stem≠id sidecar still tracked).
    func testGeminiSidecarRecentSurvivesUtf8PrefixBoundary_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        // sessionId must lead the file so the 8 KiB peek can see it; pad AFTER with
        // 3-byte CJK so byte 8192 lands mid-codepoint under strict UTF-8 decode.
        // (JSONSerialization key order is not stable — do not use it here.)
        let pad = String(repeating: "你", count: 4_000)
        let body = """
        {"sessionId":"gemini-utf8-boundary","startTime":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:02.000Z","messages":[{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","content":"\(pad)"},{"type":"gemini","timestamp":"2026-01-01T00:00:01.000Z","content":"ok"}]}
        """
        let file = chatsDir.appendingPathComponent("session-sample.json")
        try body.write(to: file, atomically: true, encoding: .utf8)
        let fileBytes = try Data(contentsOf: file).count
        XCTAssertGreaterThan(fileBytes, 8_192, "fixture must exceed the peek prefix")

        // Prove the naive 8 KiB strict decode fails so the repro is meaningful.
        var rawPrefix = Data(try Data(contentsOf: file).prefix(8_192))
        XCTAssertNil(
            String(data: rawPrefix, encoding: .utf8),
            "prefix must land mid multibyte scalar for this repro"
        )
        // Match production: drop at most 3 trailing bytes until UTF-8 is valid.
        // (Hard dropLast(3) can land mid-scalar again when pad mod 3 is unlucky.)
        for _ in 0..<3 where String(data: rawPrefix, encoding: .utf8) == nil {
            rawPrefix.removeLast()
        }
        XCTAssertTrue(
            String(data: rawPrefix, encoding: .utf8)?
                .contains("\"sessionId\":\"gemini-utf8-boundary\"") == true,
            "repro requires sessionId inside a recoverable UTF-8 prefix"
        )

        let baseline = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: chatsDir.path)

        let sidecar = chatsDir.appendingPathComponent("gemini-utf8-boundary.engram.json")
        try """
        {"originator":"claude-code","parentSessionId":"cc-utf8-parent"}
        """.write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: sidecar.path
        )
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: chatsDir.path)

        let gemini = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let recent = RecentlyModifiedSessionAdapter(
            base: gemini,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await recent.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [file.resolvingSymlinksInPath().path],
            "sessionId-named sidecar must still advance composite mtime after UTF-8 trim"
        )
        switch try await gemini.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTAssertEqual(info.id, "gemini-utf8-boundary")
            XCTAssertEqual(info.parentSessionId, "cc-utf8-parent")
            XCTAssertEqual(info.agentRole, "dispatched")
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    /// R184-3: a valid Gemini session with no visible user/assistant/tool
    /// turns must be terminal, not a zero-count browsable session.
    func testGeminiEmptyMessagesSessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let session: [String: Any] = [
            "sessionId": "g-empty",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:01.000Z",
            "messages": [
                ["type": "user", "timestamp": "2026-01-01T00:00:01.000Z", "content": [["text": ""]]],
                ["type": "info", "timestamp": "2026-01-01T00:00:02.000Z", "content": "MCP issues detected."],
            ],
        ]
        let file = chatsDir.appendingPathComponent("session-empty.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    /// Gemini CLI inherits SessionAdapter's default streamMessagesWithMetadata, so
    /// an oversized whole-transcript read is capped without a truncation marker.
    func testGeminiCliOversizedTranscriptReportsTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let turns: [[String: Any]] = (0..<4).map { index in
            [
                "type": index % 2 == 0 ? "user" : "gemini",
                "timestamp": "2026-01-01T00:00:0\(index).000Z",
                "content": "gemini turn \(index)",
            ]
        }
        let session: [String: Any] = [
            "sessionId": "g-oversized",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:04.000Z",
            "messages": turns,
        ]
        let file = chatsDir.appendingPathComponent("session-oversized.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    func testGeminiCliJSONLMetadataReplaysCappedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let file = chatsDir.appendingPathComponent("session-jsonl-cap.jsonl")
        let metadata: [String: Any] = [
            "kind": "main",
            "sessionId": "g-jsonl-cap",
            "startTime": "2026-08-21T00:00:00Z",
        ]
        let seedMessages: [[String: Any]] = (0..<4).map { index in
            [
                "type": index % 2 == 0 ? "user" : "gemini",
                "sessionId": "g-jsonl-cap",
                "timestamp": "2026-08-21T00:00:0\(index)Z",
                "content": "gemini jsonl turn \(index)",
            ]
        }
        let lines = [metadata] + seedMessages
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let parseFailure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(parseFailure, .messageLimitExceeded)

        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), (0..<3).map { "gemini jsonl turn \($0)" })
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
    }

    /// parseSessionInfo counted every flattened message without the produced
    /// cap, so an oversized Gemini session returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001M
    func testGeminiCliOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("tmp/proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let turns: [[String: Any]] = (0..<4).map { index in
            [
                "type": index % 2 == 0 ? "user" : "gemini",
                "timestamp": "2026-01-01T00:00:0\(index).000Z",
                "content": "gemini info turn \(index)",
            ]
        }
        let session: [String: Any] = [
            "sessionId": "g-oversized-info",
            "startTime": "2026-01-01T00:00:00.000Z",
            "lastUpdated": "2026-01-01T00:00:04.000Z",
            "messages": turns,
        ]
        let file = chatsDir.appendingPathComponent("session-oversized-info.json")
        try (try jsonLine(session)).write(to: file, atomically: true, encoding: .utf8)

        let adapter = GeminiCliAdapter(
            tmpRoot: root.appendingPathComponent("tmp").path,
            projectsFile: root.appendingPathComponent("projects.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    // MARK: - Iflow

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized Iflow transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001D
    func testIflowOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "uuid": "iflow-oversized-\(index)",
                "sessionId": "iflow-oversized-info",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "type": isUser ? "user" : "assistant",
                "message": [
                    "role": isUser ? "user" : "assistant",
                    "content": "iflow info turn \(index)",
                ],
                "cwd": "/tmp/iflow-oversized",
            ])
        }
        let file = projectDir.appendingPathComponent("session-oversized-info.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(
            projectsRoot: root.appendingPathComponent("projects").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    func testIflowParseSessionInfoKeepsPrefixWhenFileChanges_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-changing.jsonl")
        try jsonLine([
            "sessionId": "iflow-changing",
            "timestamp": "2026-08-24T00:00:00Z",
            "type": "user",
            "message": ["role": "user", "content": "retained task"],
            "cwd": "/tmp/iflow-changing",
        ]).appending("\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(
            projectsRoot: root.appendingPathComponent("projects").path,
            testHooks: JSONLIdentityTestHooks(beforeFinalIdentityValidation: {
                if let handle = try? FileHandle(forWritingTo: file) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(" \n".utf8))
                    try? handle.close()
                }
            })
        )

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(info.messageCount, 1)
        XCTAssertEqual(info.summary, "retained task")
    }

    /// streamMessages used windowedMessages, which swallows messageLimitExceeded
    /// and streams a prefix as complete when limit is nil.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001E
    func testIflowOversizedTranscriptStreamMessagesKeepsProducedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-oversized-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "uuid": "iflow-oversized-stream-\(index)",
                "sessionId": "iflow-oversized-stream",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "type": isUser ? "user" : "assistant",
                "message": [
                    "role": isUser ? "user" : "assistant",
                    "content": "iflow stream turn \(index)",
                ],
                "cwd": "/tmp/iflow-oversized-stream",
            ])
        }
        let file = projectDir.appendingPathComponent("session-oversized-stream.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(
            projectsRoot: root.appendingPathComponent("projects").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(messages.map(\.content), [
            "iflow stream turn 0", "iflow stream turn 1", "iflow stream turn 2",
        ])
    }

    // Audit L10: the batch parser already excludes injected wrappers from user
    // counts, so the stream must expose the same record as system rather than user.
    func testIflowStreamClassifiesInjectedWrapperAsSystem_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-system", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-system-1",
                "sessionId": "iflow-system",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /tmp/iflow\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ],
                "cwd": "/tmp/iflow",
            ],
            [
                "uuid": "iflow-system-2",
                "sessionId": "iflow-system",
                "timestamp": "2026-08-13T00:00:01.000Z",
                "type": "user",
                "message": ["role": "user", "content": "real Iflow task"],
                "cwd": "/tmp/iflow",
            ],
            [
                "uuid": "iflow-system-3",
                "sessionId": "iflow-system",
                "timestamp": "2026-08-13T00:00:02.000Z",
                "type": "assistant",
                "message": ["role": "assistant", "content": "done"],
                "cwd": "/tmp/iflow",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        try await assertStreamInjectionParity(adapter, locator: file.path, firstUserText: "real Iflow task")
    }

    func testIflowProducedCapIgnoresToolMetaAndCompactionRows_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-tmp-iflow-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-produced-cap.jsonl")
        let rows: [[String: Any]] = [
            ["type": "user", "sessionId": "iflow-cap", "cwd": "/tmp/iflow-cap",
             "message": ["role": "user", "content": "real task"]],
            ["type": "user", "sessionId": "iflow-cap", "isMeta": true,
             "message": ["role": "user", "content": ""]],
            ["type": "user", "sessionId": "iflow-cap", "isCompactSummary": true,
             "message": ["role": "user", "content": ""]],
            ["type": "user", "sessionId": "iflow-cap",
             "message": ["role": "user", "content": [["type": "tool_result", "content": ""]]]],
            ["type": "assistant", "sessionId": "iflow-cap",
             "message": ["role": "assistant", "content": "done"]],
        ]
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = IflowAdapter(
            projectsRoot: root.appendingPathComponent("projects").path,
            limits: ParserLimits(maxMessages: 2)
        )

        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(scan.messages.map(\.content), ["real task", "done"])
    }

    func testIflowProducedCapIgnoresInjectedSystemWrappersInScan_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-tmp-iflow-wrapper-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session-wrapper-cap.jsonl")
        let wrappers = [
            "# AGENTS.md instructions for /tmp/iflow\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
            "<INSTRUCTIONS>workspace bootstrap</INSTRUCTIONS>",
            "<INSTRUCTIONS><local-command-caveat>ignore this wrapper</local-command-caveat></INSTRUCTIONS>",
            "You are Qwen Code.\n<INSTRUCTIONS>compatibility wrapper</INSTRUCTIONS>",
            "<system-reminder>generated reminder</system-reminder>",
            "<environment_context><cwd>/tmp/iflow</cwd></environment_context>",
        ]
        var rows = wrappers.map { content in
            [
                "type": "user",
                "sessionId": "iflow-wrapper-cap",
                "cwd": "/tmp/iflow-wrapper-cap",
                "message": ["role": "user", "content": content],
            ] as [String: Any]
        }
        rows += [
            ["type": "user", "sessionId": "iflow-wrapper-cap",
             "message": ["role": "user", "content": "real task"]],
            ["type": "assistant", "sessionId": "iflow-wrapper-cap",
             "message": ["role": "assistant", "content": "done"]],
        ]
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(
            projectsRoot: root.appendingPathComponent("projects").path,
            limits: ParserLimits(maxMessages: 2)
        )
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(
            scan.messages.map(\.role),
            [.system, .system, .system, .system, .system, .system, .user, .assistant]
        )
        XCTAssertEqual(scan.messages.suffix(2).map(\.content), ["real task", "done"])
    }

    /// R184-3: injection-only Iflow files must be terminal, not zero-count sessions.
    func testIflowInjectionOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-empty-1",
                "sessionId": "iflow-empty",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /tmp/iflow\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ],
                "cwd": "/tmp/iflow",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-empty.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    func testIflowAttachesAssistantUsageMetadata() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-1",
                "sessionId": "iflow-usage-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "user",
                "message": [
                    "role": "user",
                    "content": "Track Iflow usage",
                ],
                "cwd": "/tmp/iflow-project",
            ],
            [
                "uuid": "iflow-2",
                "sessionId": "iflow-usage-1",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "Iflow usage tracked."],
                    ],
                    "usage": [
                        "input_tokens": 321,
                        "output_tokens": 65,
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-usage.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(streamed.last?.usage, TokenUsage(inputTokens: 321, outputTokens: 65))
    }

    func testIflowCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("projects/-Users-test-iflow-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "uuid": "iflow-multipart-1",
                "sessionId": "iflow-multipart-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "first"],
                        ["type": "text", "text": "second"],
                    ],
                ],
                "cwd": "/tmp/iflow-project",
            ],
        ]
        let file = projectDir.appendingPathComponent("session-multipart.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = IflowAdapter(projectsRoot: root.appendingPathComponent("projects").path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    // MARK: - Kimi

    func testKimiAttachesWireTokenUsageToAssistantTurn() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextLines: [[String: Any]] = [
            ["role": "user", "content": "Track Kimi usage"],
            ["role": "assistant", "content": "Kimi usage tracked."],
        ]
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)

        let wireLines: [[String: Any]] = [
            ["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_001.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": 123,
                            "output": 45,
                            "input_cache_read": 67,
                            "input_cache_creation": 8,
                        ],
                    ],
                ],
            ],
            [
                "timestamp": 1_700_000_001.5,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": 10,
                            "output": 5,
                            "input_cache_read": 3,
                            "input_cache_creation": 2,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_002.0, "message": ["type": "TurnEnd"]],
        ]
        let wireFile = sessionDir.appendingPathComponent("wire.jsonl")
        try wireLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: wireFile, atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 133, outputTokens: 50, cacheReadTokens: 70, cacheCreationTokens: 10)
        )
    }

    func testKimiReadsCurrentContextRotationAndArrayTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-session-rotation", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try (try jsonLine(["role": "user", "content": "main question"]) + "\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)
        let shardLines: [[String: Any]] = [
            [
                "role": "assistant",
                "content": [
                    ["type": "think", "think": "private reasoning", "encrypted": NSNull()],
                    ["type": "text", "text": "visible answer"],
                ],
            ],
            [
                "role": "user",
                "content": [["type": "text", "text": "follow-up from shard"]],
            ],
        ]
        try shardLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("context_1.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(streamed.map(\.content), ["main question", "visible answer", "follow-up from shard"])
    }

    // Audit KIMI-001: agentic turns must preserve tools and bind one wire turn per user turn.
    func testKimiPreservesAgenticTurnToolsAndTimestamps_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-agentic", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextLines: [[String: Any]] = [
            ["role": "user", "content": "Read the file"],
            [
                "role": "assistant",
                "content": "",
                "tool_calls": [[
                    "id": "call-1",
                    "type": "function",
                    "function": [
                        "name": "read_file",
                        "arguments": #"{"path":"README.md"}"#,
                    ],
                ]],
            ],
            ["role": "tool", "tool_call_id": "call-1", "content": "README contents"],
            ["role": "assistant", "content": "The file is ready."],
            ["role": "user", "content": "Summarize it"],
            ["role": "assistant", "content": "Short summary."],
        ]
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try contextLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)

        let firstUsage = TokenUsage(inputTokens: 10, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4)
        let secondUsage = TokenUsage(inputTokens: 20, outputTokens: 5, cacheReadTokens: 6, cacheCreationTokens: 7)
        let wireLines: [[String: Any]] = [
            ["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_001.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": firstUsage.inputTokens,
                            "output": firstUsage.outputTokens,
                            "input_cache_read": firstUsage.cacheReadTokens ?? 0,
                            "input_cache_creation": firstUsage.cacheCreationTokens ?? 0,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_002.0, "message": ["type": "TurnEnd"]],
            ["timestamp": 1_700_000_010.0, "message": ["type": "TurnBegin"]],
            [
                "timestamp": 1_700_000_011.0,
                "message": [
                    "type": "StatusUpdate",
                    "payload": [
                        "token_usage": [
                            "input_other": secondUsage.inputTokens,
                            "output": secondUsage.outputTokens,
                            "input_cache_read": secondUsage.cacheReadTokens ?? 0,
                            "input_cache_creation": secondUsage.cacheCreationTokens ?? 0,
                        ],
                    ],
                ],
            ],
            ["timestamp": 1_700_000_012.0, "message": ["type": "TurnEnd"]],
        ]
        try wireLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: contextFile.path))
        let streamed = try await drain(adapter, locator: contextFile.path)

        XCTAssertEqual(info.messageCount, 6)
        XCTAssertEqual(info.userMessageCount, 2)
        XCTAssertEqual(info.assistantMessageCount, 3)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool, .assistant, .user, .assistant])
        guard streamed.count == 6 else { return }
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "read_file", input: #"{"path":"README.md"}"#)]
        )
        XCTAssertEqual(streamed[2].content, "README contents")
        XCTAssertEqual(
            streamed.map(\.timestamp),
            [
                Phase4AdapterSupport.isoFromSeconds(1_700_000_000),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_002),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_010),
                Phase4AdapterSupport.isoFromSeconds(1_700_000_012),
            ]
        )
        XCTAssertNil(streamed[1].usage)
        XCTAssertNil(streamed[2].usage)
        XCTAssertEqual(streamed[3].usage, firstUsage)
        XCTAssertEqual(streamed[5].usage, secondUsage)
    }

    // Audit KIMI-002: historical sessions must resolve cwd from the workspace directory hash.
    func testKimiResolvesHistoricalSessionCwdFromWorkspaceHash_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases = [
            (workspace: "6530f9eb448d96e7552a3c3a29b6cd2b", session: "old-local", cwd: "/repo"),
            (workspace: "ssh_3e8bdf0b7c3f317d367df8cc16095151", session: "old-remote", cwd: "/repo/remote"),
        ]
        for item in cases {
            let sessionDir = root.appendingPathComponent("\(item.workspace)/\(item.session)", isDirectory: true)
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try (try jsonLine(["role": "user", "content": "Historical session"]) + "\n")
                .write(to: sessionDir.appendingPathComponent("context.jsonl"), atomically: true, encoding: .utf8)
        }
        let kimiJSON: [String: Any] = [
            "work_dirs": [
                ["path": "/repo", "kaos": "local", "last_session_id": "new-local"],
                ["path": "/repo/remote", "kaos": "ssh", "last_session_id": "new-remote"],
            ],
        ]
        let kimiJsonURL = root.appendingPathComponent("kimi.json")
        try JSONSerialization.data(withJSONObject: kimiJSON)
            .write(to: kimiJsonURL)

        let adapter = KimiAdapter(sessionsRoot: root.path, kimiJsonPath: kimiJsonURL.path)
        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(locators.count, 2)
        for locator in locators {
            let workspace = URL(fileURLWithPath: locator)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            let expected = try XCTUnwrap(cases.first { $0.workspace == workspace })
            let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
            XCTAssertEqual(info.cwd, expected.cwd)
        }
    }

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized context.jsonl returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001J
    func testKimiOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-oversized-info", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "content": "kimi info turn \(index)",
            ])
        }
        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: contextFile, atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: contextFile.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    func testKimiCombinedContextShardsEnforceMessageLimit_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-combined-limit", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        for (name, prefix) in [("context.jsonl", "primary"), ("context_1.jsonl", "shard")] {
            let records: [[String: Any]] = [
                ["role": "user", "content": "\(prefix) user"],
                ["role": "assistant", "content": "\(prefix) assistant"],
            ]
            try records.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
                .write(to: sessionDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let context = sessionDir.appendingPathComponent("context.jsonl")
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: context.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    func testKimiPagedReadReportsGlobalMessageCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-paged-limit", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let context = sessionDir.appendingPathComponent("context.jsonl")
        let rows: [[String: Any]] = (0..<4).map { index in
            ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": "turn \(index)"]
        }
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: context, atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: context.path,
            options: StreamMessagesOptions(offset: 3, limit: 2)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
    }

    func testKimiContextTelemetryDoesNotHideProducedTurn_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace/session-telemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let context = sessionDir.appendingPathComponent("context.jsonl")
        var lines = Array(repeating: #"{"type":"progress","content":"working"}"#, count: 10_000)
        lines.append(#"{"role":"user","content":"real produced turn"}"#)
        try lines.joined(separator: "\n").appending("\n")
            .write(to: context, atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: context.path,
            options: StreamMessagesOptions()
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertEqual(messages.map(\.content), ["real produced turn"])
        XCTAssertNil(result.truncatedAt)
    }

    /// R184-3: a Kimi session directory with only wire metadata and no
    /// conversation turns must be terminal, not a zero-count session.
    func testKimiWireOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("workspace-1/kimi-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let contextFile = sessionDir.appendingPathComponent("context.jsonl")
        try "".write(to: contextFile, atomically: true, encoding: .utf8)

        let wireLines: [[String: Any]] = [
            ["timestamp": 1_700_000_000.0, "message": ["type": "TurnBegin"]],
            ["timestamp": 1_700_000_001.0, "message": ["type": "TurnEnd"]],
        ]
        try wireLines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

        let adapter = KimiAdapter(
            sessionsRoot: root.path,
            kimiJsonPath: root.appendingPathComponent("kimi.json").path
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: contextFile.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // MARK: - Qwen

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized Qwen transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001C
    func testQwenOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-oversized/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user" : "assistant",
                "sessionId": "qwen-oversized-info",
                "cwd": "/tmp/qwen-oversized",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "model",
                    "parts": [["text": "qwen info turn \(index)"]],
                ],
            ])
        }
        let file = chatsDir.appendingPathComponent("qwen-oversized-info.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// The JSONL safety cap counts normalized messages, not telemetry or other
    /// sidecar records that `message(from:)` intentionally ignores.
    func testQwenProducedMessageLimitIgnoresTelemetryForParseAndScan_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-produced-cap/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let file = chatsDir.appendingPathComponent("qwen-produced-cap.jsonl")

        func message(_ index: Int) -> [String: Any] {
            let isUser = index % 2 == 0
            return [
                "type": isUser ? "user" : "assistant",
                "sessionId": "qwen-produced-cap",
                "cwd": "/tmp/qwen-produced-cap",
                "timestamp": "2026-08-22T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "model",
                    "parts": [["text": "produced turn \(index)"]],
                ],
            ]
        }
        var lines: [[String: Any]] = [
            message(0), ["type": "telemetry", "event": "one"],
            message(1), ["type": "telemetry", "event": "two"],
            message(2), ["type": "telemetry", "event": "three"],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(info.messageCount, 3)
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.messages.count, 3)

        lines.append(message(3))
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let parseLimitFailure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(parseLimitFailure, .messageLimitExceeded)
        let scanLimitFailure = try parseFailure(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scanLimitFailure, .messageLimitExceeded)
    }

    func testQwenProducedCapIgnoresInjectedSystemWrappersInScan_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-wrapper-cap/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let file = chatsDir.appendingPathComponent("qwen-wrapper-cap.jsonl")
        let wrappers = [
            "# AGENTS.md instructions for /tmp/qwen\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
            "<INSTRUCTIONS>workspace bootstrap</INSTRUCTIONS>",
            "<INSTRUCTIONS><local-command-caveat>ignore this wrapper</local-command-caveat></INSTRUCTIONS>",
            "You are Qwen Code.\n<INSTRUCTIONS>compatibility wrapper</INSTRUCTIONS>",
            "<system-reminder>generated reminder</system-reminder>",
            "<environment_context><cwd>/tmp/qwen</cwd></environment_context>",
        ]
        var rows = wrappers.map { content in
            [
                "type": "user",
                "sessionId": "qwen-wrapper-cap",
                "cwd": "/tmp/qwen-wrapper-cap",
                "message": ["role": "user", "parts": [["text": content]]],
            ] as [String: Any]
        }
        rows += [
            ["type": "user", "sessionId": "qwen-wrapper-cap",
             "message": ["role": "user", "parts": [["text": "real task"]]]],
            ["type": "assistant", "sessionId": "qwen-wrapper-cap",
             "message": ["role": "model", "parts": [["text": "done"]]]],
        ]
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 2))
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(
            scan.messages.map(\.role),
            Array(repeating: .system, count: wrappers.count) + [.user, .assistant]
        )
        XCTAssertEqual(scan.messages.suffix(2).map(\.content), ["real task", "done"])
    }

    func testQwenOversizedTranscriptStreamMessagesKeepsProducedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-oversized-stream/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user" : "assistant",
                "sessionId": "qwen-oversized-stream",
                "cwd": "/tmp/qwen-oversized-stream",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "model",
                    "parts": [["text": "qwen stream turn \(index)"]],
                ],
            ])
        }
        let file = chatsDir.appendingPathComponent("qwen-oversized-stream.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(messages.map(\.content), [
            "qwen stream turn 0", "qwen stream turn 1", "qwen stream turn 2",
        ])
    }

    // Audit L10: Qwen's injected bootstrap prompt is system metadata on both
    // batch and stream paths; the real request remains the first user message.
    func testQwenStreamClassifiesInjectedWrapperAsSystem_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-system/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-system",
                "cwd": "/tmp/qwen",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "You are Qwen Code.\n<INSTRUCTIONS>noise</INSTRUCTIONS>"]],
                ],
            ],
            [
                "type": "user",
                "sessionId": "qwen-system",
                "cwd": "/tmp/qwen",
                "timestamp": "2026-08-13T00:00:01.000Z",
                "message": ["role": "user", "parts": [["text": "real Qwen task"]]],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-system",
                "cwd": "/tmp/qwen",
                "timestamp": "2026-08-13T00:00:02.000Z",
                "message": ["role": "model", "parts": [["text": "done"]]],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        try await assertStreamInjectionParity(adapter, locator: file.path, firstUserText: "real Qwen task")
    }

    // MARK: - Qoder

    // Audit L10: Qoder uses the same injected AGENTS wrapper convention as the
    // batch parser, so streaming must not count or render it as a user request.
    func testQoderStreamClassifiesInjectedWrapperAsSystem_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project-system", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qoder-system",
                "cwd": "/tmp/qoder",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /tmp/qoder\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ],
            ],
            [
                "type": "user",
                "sessionId": "qoder-system",
                "cwd": "/tmp/qoder",
                "timestamp": "2026-08-13T00:00:01.000Z",
                "message": ["role": "user", "content": "real Qoder task"],
            ],
            [
                "type": "assistant",
                "sessionId": "qoder-system",
                "cwd": "/tmp/qoder",
                "timestamp": "2026-08-13T00:00:02.000Z",
                "message": ["role": "assistant", "content": "done"],
            ],
        ]
        let file = projectDir.appendingPathComponent("qoder-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QoderAdapter(projectsRoot: root.path)
        try await assertStreamInjectionParity(adapter, locator: file.path, firstUserText: "real Qoder task")
    }

    func testQoderProducedCapBillsOnlyUserAssistantAndTool_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project-produced-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("qoder-produced-cap.jsonl")
        let wrappers = [
            "<local-command-caveat>generated shell context</local-command-caveat>",
            "<local-command-stdout>generated output</local-command-stdout>",
            "<command-name>generated-command</command-name>",
            "Base directory for this skill: /tmp/generated",
        ]
        var rows: [[String: Any]] = wrappers.map { wrapper in
            ["type": "user", "sessionId": "qoder-cap", "cwd": "/tmp/qoder-cap",
             "message": [
                 "role": "user",
                 "content": wrapper,
             ]]
        }
        rows.append([
            "type": "user", "sessionId": "qoder-cap", "cwd": "/tmp/qoder-cap",
            "message": ["role": "user", "content": "real task"],
        ])
        rows.append([
            "type": "assistant", "sessionId": "qoder-cap", "cwd": "/tmp/qoder-cap",
            "message": ["role": "assistant", "content": "done"],
        ])
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = QoderAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 2))

        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(scan.info.systemMessageCount, 4)
        XCTAssertEqual(scan.messages.filter { $0.role != .system }.map(\.content), ["real task", "done"])
    }

    func testQoderProjectLevelSubagentKeepsDistinctSkipIdentity_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("encoded-project", isDirectory: true)
        let subagentsDir = projectDir.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        let sessionID = "11111111-2222-3333-4444-555555555555"

        func writeTranscript(_ url: URL, text: String) throws {
            let records: [[String: Any]] = [
                [
                    "type": "user", "sessionId": sessionID, "cwd": "/tmp/qoder",
                    "timestamp": "2026-08-23T00:00:00Z",
                    "message": ["role": "user", "content": text],
                ],
                [
                    "type": "assistant", "sessionId": sessionID, "cwd": "/tmp/qoder",
                    "timestamp": "2026-08-23T00:00:01Z",
                    "message": ["role": "assistant", "content": "done"],
                ],
            ]
            try records.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let parentURL = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let childURL = subagentsDir.appendingPathComponent("agent-worker.jsonl")
        try writeTranscript(parentURL, text: "parent task")
        try writeTranscript(childURL, text: "child task")
        let adapter = QoderAdapter(projectsRoot: root.path)

        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(locators.count, 2)
        XCTAssertTrue(locators.contains { $0.hasSuffix("/encoded-project/\(sessionID).jsonl") })
        XCTAssertTrue(locators.contains { $0.hasSuffix("/encoded-project/subagents/agent-worker.jsonl") })
        let parent = try sessionInfo(await adapter.parseSessionInfo(locator: parentURL.path))
        let child = try sessionInfo(await adapter.parseSessionInfo(locator: childURL.path))

        XCTAssertEqual(parent.id, sessionID)
        XCTAssertNil(parent.agentRole)
        XCTAssertEqual(child.id, "sub:\(sessionID):subagents/agent-worker.jsonl")
        XCTAssertEqual(child.agentRole, "subagent")
        XCTAssertEqual(child.parentSessionId, sessionID)
        XCTAssertEqual(
            SessionTier.compute(
                TierInput(
                    messageCount: child.messageCount,
                    agentRole: child.agentRole,
                    filePath: child.filePath,
                    source: child.source.rawValue,
                    assistantCount: child.assistantMessageCount,
                    toolCount: child.toolMessageCount
                )
            ),
            .skip
        )
    }

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized Qoder transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001F
    func testQoderOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project-oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user" : "assistant",
                "sessionId": "qoder-oversized-info",
                "cwd": "/tmp/qoder-oversized",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "assistant",
                    "content": "qoder info turn \(index)",
                ],
            ])
        }
        let file = projectDir.appendingPathComponent("qoder-oversized-info.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QoderAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// streamMessages used windowedMessages, which swallows messageLimitExceeded
    /// and streams a prefix as complete when limit is nil.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001G
    func testQoderOversizedTranscriptStreamMessagesKeepsProducedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project-oversized-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user" : "assistant",
                "sessionId": "qoder-oversized-stream",
                "cwd": "/tmp/qoder-oversized-stream",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "assistant",
                    "content": "qoder stream turn \(index)",
                ],
            ])
        }
        let file = projectDir.appendingPathComponent("qoder-oversized-stream.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QoderAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(messages.count, 3)
    }

    /// R184-3: injection-only Qoder files must be terminal, not zero-count sessions.
    func testQoderInjectionOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qoder-empty",
                "cwd": "/tmp/qoder",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /tmp/qoder\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ],
            ],
        ]
        let file = projectDir.appendingPathComponent("qoder-empty.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QoderAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // MARK: - Qwen

    // Runtime-debt repro: Qwen slash-command telemetry carries a session ID but
    // no visible conversation and must terminate cleanly instead of retrying.
    func testQwenSlashCommandOnlyIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-empty/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "system",
                "subtype": "slash_command",
                "sessionId": "qwen-slash-only",
                "timestamp": "2026-07-17T00:00:00.000Z",
            ],
            [
                "type": "system",
                "subtype": "slash_command",
                "sessionId": "qwen-slash-only",
                "timestamp": "2026-07-17T00:00:01.000Z",
            ],
        ]
        let file = chatsDir.appendingPathComponent("slash-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    func testQwenAttachesAssistantUsageMetadata() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-usage-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "Summarize token accounting"]],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-usage-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "message": [
                    "role": "model",
                    "parts": [["text": "Token accounting summarized."]],
                ],
                "usageMetadata": [
                    "promptTokenCount": 17_761,
                    "candidatesTokenCount": 2_473,
                    "cachedContentTokenCount": 16_627,
                    "totalTokenCount": 20_234,
                    "thoughtsTokenCount": 22,
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-usage.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 17_761, outputTokens: 2_473, cacheReadTokens: 16_627, cacheCreationTokens: 0)
        )
    }

    func testQwenUsesTelemetryUsageWhenAssistantUsageMetadataIsMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "Use telemetry token accounting"]],
                ],
            ],
            [
                "type": "system",
                "subtype": "ui_telemetry",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:01.000Z",
                "systemPayload": [
                    "uiEvent": [
                        "event.name": "qwen-code.api_response",
                        "input_token_count": 1_111,
                        "output_token_count": 222,
                        "cached_content_token_count": 333,
                        "total_token_count": 1_333,
                    ],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-telemetry-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:02.000Z",
                "message": [
                    "role": "model",
                    "parts": [["text": "Telemetry token accounting used."]],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-telemetry.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 1_111, outputTokens: 222, cacheReadTokens: 333, cacheCreationTokens: 0)
        )
    }

    func testQwenCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "assistant",
                "sessionId": "qwen-multipart-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "first"],
                        ["text": "second"],
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-multipart.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    func testQwenSkipsThoughtTextParts() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "assistant",
                "sessionId": "qwen-thought-1",
                "cwd": "/tmp/qwen-project",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "private reasoning", "thought": true],
                        ["text": "final answer"],
                    ],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-thought.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["final answer"])
    }

    // Audit SRC-QWEN-001: functionCall/tool_result must surface as assistant toolCalls + tool messages.
    func testQwenPreservesFunctionCallsAndToolResults_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let chatsDir = root.appendingPathComponent("project-tools/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "parts": [["text": "List the directory"]],
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:01.000Z",
                "model": "qwen3.5-plus",
                "message": [
                    "role": "model",
                    "parts": [
                        ["text": "Checking the directory."],
                        [
                            "functionCall": [
                                "id": "call_list_1",
                                "name": "list_directory",
                                "args": ["path": "/tmp/qwen-tools"],
                            ],
                        ],
                    ],
                ],
            ],
            [
                "type": "tool_result",
                "sessionId": "qwen-tools-1",
                "cwd": "/tmp/qwen-tools",
                "timestamp": "2026-07-19T10:00:02.000Z",
                "toolCallResult": [
                    "callId": "call_list_1",
                    "status": "success",
                    "resultDisplay": "main.swift\nREADME.md",
                ],
                "message": [
                    "role": "user",
                    "parts": [[
                        "functionResponse": [
                            "id": "call_list_1",
                            "name": "list_directory",
                            "response": ["output": "main.swift\nREADME.md"],
                        ],
                    ]],
                ],
            ],
        ]
        let file = chatsDir.appendingPathComponent("qwen-tools.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = QwenAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(streamed[0].content, "List the directory")
        XCTAssertEqual(streamed[1].content, "Checking the directory.")
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "list_directory", input: "{\"path\":\"/tmp/qwen-tools\"}")]
        )
        XCTAssertEqual(streamed[2].content, "main.swift\nREADME.md")
        XCTAssertEqual(streamed[2].timestamp, "2026-07-19T10:00:02.000Z")
    }

    // MARK: - Cline

    func testClineIgnoresUntimestampedVisibleRowsInSessionCounts_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("timestamped-count", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let rows: [[String: Any]] = [
            ["ts": 1_771_392_000_000, "say": "task", "text": "counted"],
            ["say": "text", "text": "missing timestamp"],
        ]
        try JSONSerialization.data(withJSONObject: rows).write(to: file)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let messages = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.messageCount, messages.count)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 0)
    }

    func testClineListsLegacyClaudeMessagesWhenUiMessagesMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("legacy-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let legacyFile = taskDir.appendingPathComponent("claude_messages.json")
        let messages: [[String: Any]] = [
            [
                "ts": 1_771_392_000_000,
                "type": "say",
                "say": "task",
                "text": "legacy task",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes])
        try data.write(to: legacyFile)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            [legacyFile.standardizedFileURL.path]
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: legacyFile.path))

        XCTAssertEqual(info.id, "legacy-task")
        XCTAssertEqual(info.summary, "legacy task")
    }

    func testClineRejectsPrimaryWorkspaceLabelAsCwd() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("primary-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let messages: [[String: Any]] = [
            [
                "ts": 1_771_392_000_000,
                "type": "say",
                "say": "api_req_started",
                "text": ##"{"request":"# Current Working Directory (Primary: workspace-a) Files\n- file.ts"}"##,
            ],
            [
                "ts": 1_771_392_001_000,
                "type": "say",
                "say": "task",
                "text": "hello",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes])
        try data.write(to: file)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.cwd, "")
    }

    /// R184-3: a timestamped Cline file with only api_req_started events must
    /// be terminal, not a zero-count browsable session.
    func testClineMetadataOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("empty-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let messages: [[String: Any]] = [
            [
                "ts": 1_771_392_000_000,
                "type": "say",
                "say": "api_req_started",
                "text": ##"{"request":"probe"}"##,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.withoutEscapingSlashes])
        try data.write(to: file)

        let adapter = ClineAdapter(tasksRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    /// Cline inherits SessionAdapter's default streamMessagesWithMetadata, so
    /// an oversized whole-transcript read is capped without a truncation marker.
    func testClineOversizedTranscriptReportsTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("oversized-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            rows.append([
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline turn \(index)",
            ])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = ClineAdapter(
            tasksRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    func testClinePagedReadNeverCrossesGlobalMessageCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("paged-cap-task", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let rows: [[String: Any]] = (0..<4).map { index in
            [
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline paged turn \(index)",
            ]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = ClineAdapter(tasksRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 2, limit: 500)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertEqual(messages.map(\.content), ["cline paged turn 2"])
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
    }

    func testClineMalformedObjectAfterPrefixReturnsPrefixMetadata_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("malformed-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        let valid = try jsonLine([
            "ts": 1_771_392_000_000,
            "type": "say",
            "say": "task",
            "text": "kept prefix",
        ])
        try "[\(valid),{\"ts\":1771392001000,\"type\":\"say\",\"text\":}]"
            .write(to: file, atomically: true, encoding: .utf8)

        let result = try await ClineAdapter(tasksRoot: root.path)
            .streamMessagesWithMetadata(
                locator: file.path,
                options: StreamMessagesOptions(offset: 0, limit: 500)
            )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }
        XCTAssertEqual(messages.map(\.content), ["kept prefix"])
        XCTAssertEqual(result.parseFailure, .malformedJSON)
    }

    /// streamMessages used applyWindow on the produced list, so an oversized
    /// Cline transcript streamed a prefix as complete when limit == nil.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001H
    func testClineOversizedTranscriptStreamMessagesFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("oversized-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            rows.append([
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline stream turn \(index)",
            ])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = ClineAdapter(
            tasksRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        do {
            _ = try await drain(adapter, locator: file.path)
            XCTFail("oversized whole-transcript stream must fail closed")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    /// parseSessionInfo used the uncapped JSON array, so an oversized Cline
    /// transcript returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001K
    func testClineOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("oversized-info", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            rows.append([
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline info turn \(index)",
            ])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = ClineAdapter(
            tasksRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    /// Default scanForIndexing streamed uncapped messages, so an oversized
    /// Cline session indexed a prefix as if the transcript were complete.
    func testClineOversizedTranscriptScanForIndexingFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("oversized-scan", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            rows.append([
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline scan turn \(index)",
            ])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = ClineAdapter(
            tasksRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// RecentlyModifiedSessionAdapter inherited SessionAdapter's default
    /// streamMessagesWithMetadata, so a recent-scan wrap dropped the base
    /// adapter's truncatedAt marker.
    func testRecentWrapperForwardsOversizedTranscriptTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("oversized-recent", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let file = taskDir.appendingPathComponent("ui_messages.json")
        var rows: [[String: Any]] = []
        for index in 0..<4 {
            rows.append([
                "ts": 1_771_392_000_000 + index * 1_000,
                "type": "say",
                "say": index % 2 == 0 ? "task" : "text",
                "text": "cline recent turn \(index)",
            ])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
            .write(to: file)

        let adapter = RecentlyModifiedSessionAdapter(
            base: ClineAdapter(
                tasksRoot: root.path,
                limits: ParserLimits(maxMessages: 3)
            ),
            modifiedSince: .distantPast
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    // MARK: - Codex

    func testCodexMessageCapIgnoresEnvelopeRecords_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-envelope-cap.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-08-21T00:00:00Z", "type": "session_meta",
             "payload": ["id": "codex-envelope-cap", "timestamp": "2026-08-21T00:00:00Z", "cwd": "/tmp/codex"]],
            ["timestamp": "2026-08-21T00:00:01Z", "type": "turn_context", "payload": ["model": "gpt-5"]],
            ["timestamp": "2026-08-21T00:00:02Z", "type": "event_msg", "payload": ["type": "token_count"]],
            ["timestamp": "2026-08-21T00:00:03Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "request"]]]],
            ["timestamp": "2026-08-21T00:00:04Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "reply"]]]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxMessages: 2))
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: file.path) else {
            return XCTFail("envelope records must not consume the Codex message cap")
        }
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(messages.count, 2)
    }

    func testCodexMessageCapIgnoresClassifierSystemRows_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-system-cap.jsonl")
        let texts = [
            "<system-reminder>generated reminder</system-reminder>",
            "<environment_context><cwd>/tmp/codex</cwd></environment_context>",
            "real Codex task",
        ]
        var lines: [[String: Any]] = [[
            "timestamp": "2026-08-24T00:00:00Z", "type": "session_meta",
            "payload": ["id": "codex-system-cap", "timestamp": "2026-08-24T00:00:00Z", "cwd": "/tmp/codex"],
        ]]
        for (index, text) in texts.enumerated() {
            lines.append([
                "timestamp": "2026-08-24T00:00:0\(index + 1)Z", "type": "response_item",
                "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]],
            ])
        }
        lines.append([
            "timestamp": "2026-08-24T00:00:04Z", "type": "response_item",
            "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "done"]]],
        ])
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let scan = try sessionInfo(await CodexAdapter(
            sessionsRoot: root.path,
            limits: ParserLimits(maxMessages: 2)
        ).scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(scan.messages.map(\.content), ["real Codex task", "done"])
    }

    func testCodexPagedReadNeverCrossesGlobalMessageCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-paged-cap.jsonl")
        var lines: [[String: Any]] = [
            [
                "timestamp": "2026-08-21T00:00:00Z",
                "type": "session_meta",
                "payload": ["id": "codex-paged-cap", "timestamp": "2026-08-21T00:00:00Z", "cwd": "/tmp/codex"],
            ],
        ]
        for index in 0..<4 {
            lines.append([
                "timestamp": "2026-08-21T00:00:0\(index + 1)Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": index.isMultiple(of: 2) ? "user" : "assistant",
                    "content": [["type": index.isMultiple(of: 2) ? "input_text" : "output_text", "text": "codex turn \(index)"]],
                ],
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: file.path,
            options: StreamMessagesOptions(offset: 2, limit: 500)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertEqual(messages.map(\.content), ["codex turn 2"])
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
    }

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized Codex transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001B
    func testCodexOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-oversized-info.jsonl")
        var lines: [[String: Any]] = [
            [
                "timestamp": "2026-08-14T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-oversized-info",
                    "timestamp": "2026-08-14T10:00:00.000Z",
                    "cwd": "/tmp/codex-oversized",
                    "originator": "codex",
                ],
            ],
        ]
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "timestamp": "2026-08-14T10:00:0\(index + 1).000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": isUser ? "user" : "assistant",
                    "content": [[
                        "type": isUser ? "input_text" : "output_text",
                        "text": "codex info turn \(index)",
                    ]],
                ],
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(
            sessionsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// R184-3: a session_meta-only Codex file must be terminal, not a
    /// zero-count browsable session.
    func testCodexMetadataOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-meta-only.jsonl")
        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-meta-only",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-empty",
                    "originator": "codex",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "event_msg",
                "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 0]]],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    func testCodexMessageCountIncludesFunctionCallOutput_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-fco.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-fco-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/x", "originator": "codex"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Read a.ts"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Reading."]]]],
            ["timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "function_call", "name": "read_file", "arguments": "{\"path\":\"a.ts\"}"]],
            ["timestamp": "2026-06-01T10:00:04.000Z", "type": "response_item",
             "payload": ["type": "function_call_output", "output": "contents of a.ts"]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)
        XCTAssertEqual(streamed.filter { $0.role == .tool }.count, 2)
        XCTAssertEqual(info.toolMessageCount, 2)
        XCTAssertEqual(info.messageCount, 4)
        XCTAssertEqual(info.messageCount, streamed.count)
    }

    // Audit ADAPTER-CODEX-001: custom tool records must stream and count as tool messages.
    func testCodexCustomToolCallAndOutputAreStreamedAndCounted_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-custom-tool.jsonl")
        let lines: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-custom-tool-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/x"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Apply the patch"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": [
                 "type": "custom_tool_call",
                 "call_id": "call-1",
                 "name": "apply_patch",
                 "status": "completed",
                 "input": "*** Begin Patch\n*** End Patch",
             ]],
            ["timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
             "payload": ["type": "custom_tool_call_output", "call_id": "call-1", "output": "Success."]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .tool, .tool])
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 0)
        XCTAssertEqual(info.toolMessageCount, 2)
        XCTAssertEqual(info.systemMessageCount, 0)
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count)
        guard streamed.count == 3 else { return }
        XCTAssertTrue(streamed[1].content.contains("apply_patch"))
        XCTAssertTrue(streamed[1].content.contains("*** Begin Patch\n*** End Patch"))
        XCTAssertEqual(
            streamed[1].toolCalls,
            [NormalizedToolCall(name: "apply_patch", input: "*** Begin Patch\n*** End Patch")]
        )
        XCTAssertEqual(streamed[2].content, "Success.")
    }

    // Audit ADAPTER-CODEX-002: duplicate adjacent token snapshots must not inflate usage.
    func testCodexDuplicateTokenCountSnapshotIsNotDoubleCounted_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-duplicate-usage.jsonl")
        let sessionMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": "codex-duplicate-usage-1",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "cwd": "/tmp/codex-usage",
            ],
        ]
        let user: [String: Any] = [
            "timestamp": "2026-06-01T10:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "Track Codex usage"]],
            ],
        ]
        let assistant: [String: Any] = [
            "timestamp": "2026-06-01T10:00:02.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Codex usage tracked."]],
            ],
        ]
        let usageA: [String: Int] = [
            "input_tokens": 1_000,
            "cached_input_tokens": 400,
            "output_tokens": 25,
            "reasoning_output_tokens": 5,
            "total_tokens": 1_025,
        ]
        let totalA: [String: Int] = usageA
        var totalAWithDifferentReasoning = totalA
        totalAWithDifferentReasoning["reasoning_output_tokens"] = 6

        func tokenCount(
            timestamp: String,
            last: [String: Int],
            total: [String: Int]?
        ) -> [String: Any] {
            var info: [String: Any] = ["last_token_usage": last]
            if let total {
                info["total_token_usage"] = total
            }
            return [
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": ["type": "token_count", "info": info],
            ]
        }

        let snapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:03.000Z",
            last: usageA,
            total: totalA
        )
        let duplicateSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:04.000Z",
            last: usageA,
            total: totalA
        )
        let changedTotalSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:05.000Z",
            last: usageA,
            total: totalAWithDifferentReasoning
        )
        let noTotalSnapshotA = tokenCount(
            timestamp: "2026-06-01T10:00:06.000Z",
            last: usageA,
            total: nil
        )
        let unsupportedResponseItem: [String: Any] = [
            "timestamp": "2026-06-01T10:00:07.000Z",
            "type": "response_item",
            "payload": ["type": "reasoning", "summary": []],
        ]
        let noTotalSnapshotAfterBoundary = tokenCount(
            timestamp: "2026-06-01T10:00:08.000Z",
            last: usageA,
            total: nil
        )
        let snapshotB = tokenCount(
            timestamp: "2026-06-01T10:00:09.000Z",
            last: [
                "input_tokens": 300,
                "cached_input_tokens": 100,
                "output_tokens": 7,
                "reasoning_output_tokens": 2,
                "total_tokens": 307,
            ],
            total: [
                "input_tokens": 1_300,
                "cached_input_tokens": 500,
                "output_tokens": 32,
                "reasoning_output_tokens": 7,
                "total_tokens": 1_332,
            ]
        )
        try [
            sessionMeta,
            user,
            assistant,
            snapshotA,
            duplicateSnapshotA,
            changedTotalSnapshotA,
            noTotalSnapshotA,
            unsupportedResponseItem,
            noTotalSnapshotAfterBoundary,
            snapshotB,
        ]
        .map { try jsonLine($0) }
        .joined(separator: "\n")
        .appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 2_600, outputTokens: 107, cacheReadTokens: 1_700, cacheCreationTokens: 0)
        )
    }

    // Audit ADAPTER-CODEX-002: token snapshot deduplication must be scoped to one read.
    func testCodexTokenCountSnapshotDeduplicationIsInvocationLocal_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("rollout-codex-usage-first.jsonl")
        let secondFile = root.appendingPathComponent("rollout-codex-usage-second.jsonl")
        let snapshot: [String: Any] = [
            "timestamp": "2026-06-01T10:00:02.000Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 1_000,
                        "cached_input_tokens": 400,
                        "output_tokens": 25,
                        "reasoning_output_tokens": 5,
                        "total_tokens": 1_025,
                    ],
                    "total_token_usage": [
                        "input_tokens": 1_000,
                        "cached_input_tokens": 400,
                        "output_tokens": 25,
                        "reasoning_output_tokens": 5,
                        "total_tokens": 1_025,
                    ],
                ],
            ],
        ]
        let assistant: [String: Any] = [
            "timestamp": "2026-06-01T10:00:01.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "Codex usage tracked."]],
            ],
        ]
        let firstMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": ["id": "codex-usage-first", "cwd": "/tmp/codex-usage"],
        ]
        let secondMeta: [String: Any] = [
            "timestamp": "2026-06-01T10:00:00.000Z",
            "type": "session_meta",
            "payload": ["id": "codex-usage-second", "cwd": "/tmp/codex-usage"],
        ]
        try [firstMeta, assistant, snapshot]
            .map { try jsonLine($0) }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: firstFile, atomically: true, encoding: .utf8)
        try [secondMeta, snapshot, assistant]
            .map { try jsonLine($0) }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: secondFile, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let expected = TokenUsage(
            inputTokens: 600,
            outputTokens: 25,
            cacheReadTokens: 400,
            cacheCreationTokens: 0
        )
        let firstStreamed = try await drain(adapter, locator: firstFile.path)
        let secondStreamed = try await drain(adapter, locator: secondFile.path)

        XCTAssertEqual(firstStreamed.map(\.usage), [expected])
        XCTAssertEqual(secondStreamed.map(\.usage), [expected])
    }

    func testCodexTailIndexingConformance_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-tail.jsonl")
        let initial: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-tail-1", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/t"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hello"]]]],
            ["timestamp": "2026-06-01T10:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "hi"]]]],
        ]
        try initial.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(sessionsRoot: root.path)
        XCTAssertTrue(adapter is any TailIndexingSessionAdapter)
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        XCTAssertEqual(scan.messages.count, 2)
        let offset = try XCTUnwrap(scan.checkpointParsedOffset)
        let boundary = try XCTUnwrap(scan.checkpointBoundaryHash)
        let tailLine: [String: Any] = [
            "timestamp": "2026-06-01T10:00:03.000Z", "type": "response_item",
            "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "follow-up"]]],
        ]
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try jsonLine(tailLine) + "\n").utf8))
        switch try await adapter.scanTailForIndexing(locator: file.path, from: offset, expectedBoundaryHash: boundary) {
        case .success(let tail):
            XCTAssertEqual(tail.messages.count, 1)
            XCTAssertEqual(tail.messages.first?.content, "follow-up")
        case .fallback: XCTFail("expected success")
        case .failure(let f): XCTFail("\(f)")
        }
    }

    func testCodexTailMessageCapIgnoresSidecarEvents_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-tail-sidecars.jsonl")
        let initial: [[String: Any]] = [
            ["timestamp": "2026-06-01T10:00:00.000Z", "type": "session_meta",
             "payload": ["id": "codex-tail-sidecars", "timestamp": "2026-06-01T10:00:00.000Z", "cwd": "/tmp/t"]],
            ["timestamp": "2026-06-01T10:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "initial"]]]],
        ]
        try initial.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(sessionsRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        let offset = try XCTUnwrap(scan.checkpointParsedOffset)
        let boundary = try XCTUnwrap(scan.checkpointBoundaryHash)
        var tail: [[String: Any]] = (0..<10).map { index in
            ["timestamp": "2026-06-01T10:00:\(10 + index).000Z", "type": "event_msg",
             "payload": ["type": "task_progress", "message": "progress \(index)"]]
        }
        tail.append([
            "timestamp": "2026-06-01T10:00:30.000Z", "type": "response_item",
            "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "real tail turn"]]],
        ])
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try tail.map(jsonLine).joined(separator: "\n") + "\n").utf8))

        switch try await adapter.scanTailForIndexing(locator: file.path, from: offset, expectedBoundaryHash: boundary) {
        case .success(let result):
            XCTAssertEqual(result.messages.map(\.content), ["real tail turn"])
        case .fallback:
            XCTFail("expected produced-message tail success")
        case .failure(let failure):
            XCTFail("sidecar records must not exhaust the produced-message cap: \(failure)")
        }
    }

    func testCodexAttachesTokenCountEventUsageToPreviousAssistantMessage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-usage.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-token-count-1",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-usage",
                    "originator": "codex",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Track Codex usage"]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Codex usage tracked."]],
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:03.000Z",
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": 1_000,
                            "cached_input_tokens": 400,
                            "output_tokens": 25,
                            "reasoning_output_tokens": 5,
                            "total_tokens": 1_025,
                        ],
                    ],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 600, outputTokens: 25, cacheReadTokens: 400, cacheCreationTokens: 0)
        )
    }

    func testCodexCombinesMultipartTextContent() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-multipart.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-06-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-multipart-1",
                    "timestamp": "2026-06-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-multipart",
                ],
            ],
            [
                "timestamp": "2026-06-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "first"],
                        ["type": "output_text", "text": "second"],
                    ],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(streamed.map(\.content), ["first\n\nsecond"])
    }

    func testCodexUsesTurnContextModelWhenResponseItemModelMissing() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-turn-context-model.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-turn-context-model",
                    "timestamp": "2026-07-01T10:00:00.000Z",
                    "cwd": "/tmp/codex-turn-context-model",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:00.100Z",
                "type": "turn_context",
                "payload": [
                    "model": "gpt-5.5",
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "Use turn_context model"]],
                ],
            ],
            [
                "timestamp": "2026-07-01T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Using turn_context model."]],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(info.model, "gpt-5.5")
    }

    func testCodexDoesNotUseModelProviderAsFallbackModel() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-codex-model-provider-only.jsonl")

        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-01T11:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "codex-model-provider-only",
                    "timestamp": "2026-07-01T11:00:00.000Z",
                    "cwd": "/tmp/codex-model-provider-only",
                    "model_provider": "openai",
                ],
            ],
            [
                "timestamp": "2026-07-01T11:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "No model label here"]],
                ],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertNil(info.model)
    }

    // MARK: - Claude Code

    func testClaudeCodeMessageCapIgnoresProgressRecords_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-tmp-claude-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("claude-cap.jsonl")
        let lines: [[String: Any]] = [
            ["type": "progress", "sessionId": "claude-cap", "timestamp": "2026-08-21T00:00:00Z"],
            ["type": "file-history-snapshot", "sessionId": "claude-cap", "timestamp": "2026-08-21T00:00:01Z"],
            ["type": "user", "sessionId": "claude-cap", "cwd": "/tmp/claude", "timestamp": "2026-08-21T00:00:02Z",
             "message": ["role": "user", "content": "request"]],
            ["type": "assistant", "sessionId": "claude-cap", "timestamp": "2026-08-21T00:00:03Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "reply"]]]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 2))
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: file.path) else {
            return XCTFail("progress records must not consume the Claude Code message cap")
        }
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(messages.count, 2)
    }

    func testClaudeCodeTailMessageCapIgnoresSidecarsAndFallsBackWithoutProducedMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-tmp-claude-tail-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("claude-tail-cap.jsonl")
        let initial: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "claude-tail-cap",
                "cwd": "/tmp/claude",
                "timestamp": "2026-08-21T00:00:00Z",
                "message": ["role": "user", "content": "request"],
            ],
        ]
        try initial.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))
        let offset = try XCTUnwrap(scan.checkpointParsedOffset)
        let boundary = try XCTUnwrap(scan.checkpointBoundaryHash)
        let sidecars: [[String: Any]] = (0..<10).map { index in
            [
                "type": "progress",
                "sessionId": "claude-tail-cap",
                "timestamp": "2026-08-21T00:00:\(10 + index)Z",
                "data": ["message": "progress \(index)"],
            ]
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try sidecars.map(jsonLine).joined(separator: "\n") + "\n").utf8))

        switch try await adapter.scanTailForIndexing(
            locator: file.path,
            from: offset,
            expectedBoundaryHash: boundary
        ) {
        case .fallback:
            break
        case .success:
            XCTFail("a sidecar-only Claude tail must fall back instead of advancing an empty delta")
        case .failure(let failure):
            XCTFail("sidecars must not consume the produced-message cap: \(failure)")
        }
    }

    // Audit ADAPTER-CC-001: shared non-empty message.id must not double-count
    // response-level usage while still streaming every content block.
    func testClaudeCodeRepeatedAssistantMessageIdCountsUsageOnce_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-usage-dedupe", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sharedUsage: [String: Any] = [
            "input_tokens": 100,
            "output_tokens": 20,
            "cache_read_input_tokens": 10,
            "cache_creation_input_tokens": 5,
        ]
        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-usage-dedupe",
                "cwd": "/Users/test/usage-dedupe",
                "timestamp": "2026-07-19T12:00:00.000Z",
                "message": ["role": "user", "content": "split this answer"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-usage-dedupe",
                "timestamp": "2026-07-19T12:00:01.000Z",
                "message": [
                    "id": "msg_shared_1",
                    "role": "assistant",
                    "model": "claude-x",
                    "content": [["type": "text", "text": "part one"]],
                    "usage": sharedUsage,
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-usage-dedupe",
                "timestamp": "2026-07-19T12:00:02.000Z",
                "message": [
                    "id": "msg_shared_1",
                    "role": "assistant",
                    "model": "claude-x",
                    "content": [["type": "text", "text": "part two"]],
                    "usage": sharedUsage,
                ],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-usage-dedupe",
                "timestamp": "2026-07-19T12:00:03.000Z",
                "message": [
                    "id": "msg_other_2",
                    "role": "assistant",
                    "model": "claude-x",
                    "content": [["type": "text", "text": "next response"]],
                    "usage": [
                        "input_tokens": 40,
                        "output_tokens": 8,
                    ],
                ],
            ],
        ]
        let file = projectDir.appendingPathComponent("usage-dedupe.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let streamed = try await drain(adapter, locator: file.path)
        let assistants = streamed.filter { $0.role == .assistant }
        let totals = streamed.compactMap(\.usage).reduce(
            TokenUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0)
        ) { partial, usage in
            TokenUsage(
                inputTokens: partial.inputTokens + usage.inputTokens,
                outputTokens: partial.outputTokens + usage.outputTokens,
                cacheReadTokens: (partial.cacheReadTokens ?? 0) + (usage.cacheReadTokens ?? 0),
                cacheCreationTokens: (partial.cacheCreationTokens ?? 0) + (usage.cacheCreationTokens ?? 0)
            )
        }

        XCTAssertEqual(assistants.map(\.content), ["part one", "part two", "next response"])
        XCTAssertEqual(
            assistants[0].usage,
            TokenUsage(inputTokens: 100, outputTokens: 20, cacheReadTokens: 10, cacheCreationTokens: 5)
        )
        XCTAssertNil(assistants[1].usage)
        XCTAssertEqual(assistants[2].usage, TokenUsage(inputTokens: 40, outputTokens: 8))
        XCTAssertEqual(
            totals,
            TokenUsage(inputTokens: 140, outputTokens: 28, cacheReadTokens: 10, cacheCreationTokens: 5)
        )
    }

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized Claude transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001
    func testClaudeCodeOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-oversized-info", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user" : "assistant",
                "sessionId": "cc-oversized-info",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "message": [
                    "role": isUser ? "user" : "assistant",
                    "content": [["type": "text", "text": "claude info turn \(index)"]],
                ],
            ])
        }
        let file = projectDir.appendingPathComponent("oversized-info.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    // Runtime-debt repro: Claude metadata-only JSONL is valid session state and
    // must use the existing terminal no-visible contract rather than malformed.
    func testClaudeCodeMetadataOnlyIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "system", "sessionId": "cc-metadata-only", "timestamp": "2026-07-17T00:00:00Z"],
            ["type": "mode", "sessionId": "cc-metadata-only", "mode": "default"],
            ["type": "permission-mode", "sessionId": "cc-metadata-only", "mode": "acceptEdits"],
            ["type": "last-prompt", "sessionId": "cc-metadata-only", "prompt": ""],
        ]
        let file = projectDir.appendingPathComponent("metadata-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // Claude can leave standalone file-history snapshots that are valid JSONL
    // but have neither a session ID nor any visible messages. They are not a
    // damaged transcript and should use the terminal no-visible contract.
    func testClaudeCodeFileHistorySnapshotsWithoutSessionIdAreTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-file-history", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "file-history-snapshot", "snapshot": ["trackedFileBackups": [:]]],
            ["type": "file-history-snapshot", "snapshot": ["trackedFileBackups": [:]]],
        ]
        let file = projectDir.appendingPathComponent("file-history-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
    }

    func testClaudeCodeToolResultCountMatchesStream() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-1",
                "cwd": "/Users/test/proj",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": ["role": "user", "content": "do the thing"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:01Z",
                "message": ["role": "assistant", "model": "claude-x", "content": "on it"],
            ],
            // tool_result-only user record with no surfaced text → must be
            // dropped from stream AND not counted.
            [
                "type": "user",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:02Z",
                "message": ["role": "user", "content": [["type": "tool_result", "content": "raw output"]]],
            ],
            // tool_result that surfaces "User has answered" → counted as tool
            // and streamed with role .tool.
            [
                "type": "user",
                "sessionId": "cc-1",
                "timestamp": "2026-01-01T00:00:03Z",
                "message": ["role": "user", "content": [["type": "tool_result", "content": "User has answered: yes"]]],
            ],
        ]
        let file = projectDir.appendingPathComponent("sample.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)

        XCTAssertEqual(info.project, "proj")
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.toolMessageCount, 1, "only the content-bearing tool_result is counted")
        XCTAssertEqual(info.messageCount, 3)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.filter { $0.role == .tool }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(streamed.filter { $0.role == .assistant }.count, 1)
    }

    func testClaudeCodeSystemOnlyTranscriptIsTerminalNoVisibleMessages() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            ["type": "summary", "summary": "Prior session title", "leafUuid": "prev"],
            [
                "type": "user",
                "sessionId": "system-only-session",
                "cwd": "/Users/test/empty",
                "timestamp": "2026-04-29T10:00:00.000Z",
                "message": [
                    "role": "user",
                    "content": "<command-message>compact</command-message>\n<command-name>/compact</command-name>",
                ],
            ],
        ]
        let file = projectDir.appendingPathComponent("system-only.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))

        XCTAssertEqual(failure, .noVisibleMessages)
        XCTAssertEqual(ParserFailure.noVisibleMessages.rawValue, "noVisibleMessages")

        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(sizeBytes: 128, modifiedAtNanos: 1_000_000_000, inode: 42, device: 7)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: file.path,
            stat: stat,
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .terminal)
        XCTAssertNil(state.retryAfterEpochSeconds)
        XCTAssertEqual(state.retryCount, 0)
        XCTAssertEqual(FileIndexDecision.decide(stat: stat, state: state, now: now), .skip)
    }

    func testClaudeCodeMalformedTranscriptStaysRetryable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let badFile = root.appendingPathComponent("garbage.jsonl")
        try "this is not json at all\n{ broken\n".write(to: badFile, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: badFile.path))

        XCTAssertEqual(failure, .malformedJSON)
        let now = Date(timeIntervalSince1970: 2_000)
        let stat = FileIndexStat(sizeBytes: 128, modifiedAtNanos: 1_000_000_000, inode: 42, device: 7)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: badFile.path,
            stat: stat,
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .retry)
        XCTAssertNotNil(state.retryAfterEpochSeconds)
        XCTAssertGreaterThan(state.retryCount, 0)
    }

    func testClaudeCodeRenderStreamIncludesSystemInjectionButIndexScanExcludes_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-system-mixed", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "cwd": "/Users/test/system-mixed",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": [
                    "role": "user",
                    "content": "# AGENTS.md instructions for /Users/test/system-mixed\n<INSTRUCTIONS>...</INSTRUCTIONS>",
                ],
            ],
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:01Z",
                "message": ["role": "user", "content": "<system-reminder>generated reminder</system-reminder>"],
            ],
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:01.500Z",
                "message": ["role": "user", "content": "<environment_context><cwd>/tmp/claude</cwd></environment_context>"],
            ],
            [
                "type": "user",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:01.750Z",
                "message": ["role": "user", "content": "real task"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-system-mixed",
                "timestamp": "2026-01-01T00:00:02Z",
                "message": ["role": "assistant", "model": "claude-x", "content": "done"],
            ],
        ]
        let file = projectDir.appendingPathComponent("mixed.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: file.path))
        let streamed = try await drain(adapter, locator: file.path)
        let indexingScan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
        XCTAssertEqual(info.systemMessageCount, 3)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(
            streamed.map(\.role),
            [.system, .system, .system, .user, .assistant]
        )
        XCTAssertEqual(
            streamed.map(\.content),
            [
                "# AGENTS.md instructions for /Users/test/system-mixed\n<INSTRUCTIONS>...</INSTRUCTIONS>",
                "<system-reminder>generated reminder</system-reminder>",
                "<environment_context><cwd>/tmp/claude</cwd></environment_context>",
                "real task",
                "done",
            ]
        )
        XCTAssertEqual(indexingScan.messages.map(\.content), ["real task", "done"])
    }

    func testClaudeCodeMultiRootIndexingScanForcesNonDefaultSourceAndOriginator() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let projectsRoot = home
            .appendingPathComponent(".claude-minimax", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent("-Users-test-minimax", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let settingsURL = home.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let settings = try JSONSerialization.data(
            withJSONObject: [
                "claudeCodeProfiles": [
                    "autoDiscover": true,
                    "customProjectsRoots": [],
                ],
            ],
            options: [.sortedKeys]
        )
        try settings.write(to: settingsURL)
        let file = projectDir.appendingPathComponent("minimax.jsonl")
        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-minimax-profile",
                "cwd": "/Users/test/minimax",
                "timestamp": "2026-07-13T00:00:00Z",
                "message": ["role": "user", "content": "request"],
            ],
            [
                "type": "assistant",
                "sessionId": "cc-minimax-profile",
                "timestamp": "2026-07-13T00:00:01Z",
                "message": ["role": "assistant", "model": "MiniMax-M2.1", "content": "response"],
            ],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let resolver = ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settingsURL)
        let adapter = ClaudeCodeAdapter(profileResolver: resolver)

        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.source, .claudeCode)
        XCTAssertEqual(scan.info.originator, "claude-code")
        XCTAssertEqual(scan.info.model, "MiniMax-M2.1")
        XCTAssertEqual(scan.messages.count, 2)
    }

    // MARK: - Copilot

    func testCopilotMessageCapIgnoresLifecycleRecords_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("copilot-envelope-cap", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "id: copilot-envelope-cap\ncwd: /tmp/copilot\ncreated_at: 2026-08-21T00:00:00Z\n"
            .write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session.start", "timestamp": "2026-08-21T00:00:00Z", "data": ["context": ["cwd": "/tmp/copilot"]]],
            ["type": "tool.execution_start", "timestamp": "2026-08-21T00:00:01Z", "data": [:]],
            ["type": "user.message", "timestamp": "2026-08-21T00:00:02Z", "data": ["content": "request"]],
            ["type": "assistant.message", "timestamp": "2026-08-21T00:00:03Z", "data": ["content": "reply"]],
        ]
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path, limits: ParserLimits(maxMessages: 2))
        guard case .success(let info) = try await adapter.parseSessionInfo(locator: events.path) else {
            return XCTFail("lifecycle records must not consume the Copilot message cap")
        }
        let messages = try await drain(adapter, locator: events.path)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(messages.count, 2)
        switch try await adapter.scanForIndexing(locator: events.path) {
        case .success(let scan):
            XCTAssertEqual(scan.messages.count, 2)
        case .failure(let failure):
            XCTFail("indexing scan must preserve the Copilot message cap: \(failure)")
        }
    }

    func testCopilotAttachesShutdownModelMetricsToLastAssistantMessage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-with-usage", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: session-with-usage
        cwd: /tmp/copilot-usage-project
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine([
                "type": "session.start",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "data": [
                    "startTime": "2026-06-01T10:00:00.000Z",
                    "context": ["cwd": "/tmp/copilot-usage-project"],
                ],
            ]),
            jsonLine([
                "type": "user.message",
                "timestamp": "2026-06-01T10:01:00.000Z",
                "data": ["content": "Check the usage monitor"],
            ]),
            jsonLine([
                "type": "assistant.message",
                "timestamp": "2026-06-01T10:02:00.000Z",
                "data": ["content": "Usage monitor reviewed."],
            ]),
            jsonLine([
                "type": "session.shutdown",
                "timestamp": "2026-06-01T10:05:00.000Z",
                "data": [
                    "modelMetrics": [
                        "gpt-5.4": [
                            "usage": [
                                "inputTokens": 1_200,
                                "outputTokens": 80,
                                "cacheReadTokens": 900,
                                "cacheWriteTokens": 40,
                            ],
                        ],
                    ],
                ],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let streamed = try await drain(adapter, locator: events.path)

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 1_200, outputTokens: 80, cacheReadTokens: 900, cacheCreationTokens: 40)
        )
    }

    func testCopilotFallsBackToCheckpointIndexWhenEventsAreMissing_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-no-events", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-no-events
        cwd: /tmp/copilot-project
        summary_count: 2
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Initial production deploy audit | 001-initial-production-deploy.md |
        | 2 | Follow-up verifier and rollback notes | 002-follow-up-verifier.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try """
        <overview>
        Production deploy reached the smoke-test phase and needs database checks.
        </overview>
        """.write(
            to: checkpointsDir.appendingPathComponent("001-initial-production-deploy.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        <work_done>
        Rollback notes were captured and the verifier command is ready.
        </work_done>
        """.write(
            to: checkpointsDir.appendingPathComponent("002-follow-up-verifier.md"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        func standardize(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }

        XCTAssertEqual(locators.map(standardize), [standardize(checkpointIndex.path)])

        let info = try sessionInfo(await adapter.parseSessionInfo(locator: checkpointIndex.path))
        let streamed = try await drain(adapter, locator: checkpointIndex.path)

        XCTAssertEqual(info.id, "session-no-events")
        XCTAssertEqual(info.cwd, "/tmp/copilot-project")
        XCTAssertEqual(info.startTime, "2026-06-01T10:00:00.000Z")
        XCTAssertEqual(info.endTime, "2026-06-01T10:05:00.000Z")
        XCTAssertEqual(info.summary, "Initial production deploy audit")
        XCTAssertEqual(info.assistantMessageCount, 2)
        XCTAssertEqual(info.systemMessageCount, 0)
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.map(\.role), [.assistant, .assistant])
        XCTAssertEqual(streamed.map(\.content), [
            """
            Checkpoint 1: Initial production deploy audit

            <overview>
            Production deploy reached the smoke-test phase and needs database checks.
            </overview>
            """,
            """
            Checkpoint 2: Follow-up verifier and rollback notes

            <work_done>
            Rollback notes were captured and the verifier command is ready.
            </work_done>
            """
        ])
    }

    // Audit COPILOT-DISCOVERY-001: events with only session.start must not hide
    // a valid checkpoint index.
    func testCopilotFallsBackToCheckpointWhenEventsHaveNoConversation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-start-only", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-start-only
        cwd: /tmp/copilot-checkpoint-fallback
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        try [
            try jsonLine([
                "type": "session.start",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "data": [
                    "startTime": "2026-06-01T10:00:00.000Z",
                    "context": ["cwd": "/tmp/copilot-checkpoint-fallback"],
                ],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: sessionDir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Recovered from checkpoint | 001-recovered.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try "<overview>Recovered body</overview>\n"
            .write(
                to: checkpointsDir.appendingPathComponent("001-recovered.md"),
                atomically: true,
                encoding: .utf8
            )

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [checkpointIndex.resolvingSymlinksInPath().path]
        )
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let info):
            XCTAssertEqual(info.id, "session-start-only")
            XCTAssertEqual(info.assistantMessageCount, 1)
            XCTAssertEqual(info.systemMessageCount, 0)
            XCTAssertEqual(info.messageCount, 1)
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    func testCopilotConversationSniffSkipsMalformedLines_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-malformed-sniff", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        let valid = try jsonLine([
            "type": "user.message",
            "timestamp": "2026-06-01T10:00:00.000Z",
            "data": ["content": "real conversation"],
        ])
        try ("{ malformed\n" + valid + "\n").write(
            to: events,
            atomically: true,
            encoding: .utf8
        )
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try "| # | Title | File |\n| 1 | stale checkpoint | |\n"
            .write(to: checkpointIndex, atomically: true, encoding: .utf8)

        let locators = try await CopilotAdapter(sessionRoot: root.path).listSessionLocators()

        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            [events.standardizedFileURL.path]
        )
    }

    /// R184-3 / ADAPTER-EMPTY-SESSION-001J: a valid Copilot session whose
    /// events contain only session metadata is terminal, not malformed JSON.
    func testCopilotSessionStartOnlyEventsAreTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-start-only-direct", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: session-start-only-direct
        cwd: /tmp/copilot-start-only
        created_at: 2026-08-14T00:00:00.000Z
        updated_at: 2026-08-14T00:00:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            try jsonLine([
                "type": "session.start",
                "timestamp": "2026-08-14T00:00:00.000Z",
                "data": [
                    "startTime": "2026-08-14T00:00:00.000Z",
                    "context": ["cwd": "/tmp/copilot-start-only"],
                ],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        switch try await adapter.parseSessionInfo(locator: events.path) {
        case .success(let info):
            XCTFail("session.start-only events must not index zero-count session \(info.id)")
        case .failure(let failure):
            XCTAssertEqual(failure, .noVisibleMessages)
        }
    }

    /// parseSessionInfo called readObjects without reportFailures, so an
    /// oversized events.jsonl returned prefix counts as complete.
    func testCopilotOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-info", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: session-oversized-info
        cwd: /tmp/copilot-oversized
        created_at: 2026-08-14T00:00:00.000Z
        updated_at: 2026-08-14T00:00:03.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user.message" : "assistant.message",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "data": ["content": "copilot info turn \(index)"],
            ])
        }
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: events.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// Plain streams preserve the produced prefix for pagination/export even
    /// when a later event crosses the configured message cap. Metadata and
    /// parseSessionInfo retain the fail-closed truncation signal.
    func testCopilotOversizedTranscriptStreamMessagesKeepsPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: session-oversized-stream
        cwd: /tmp/copilot-oversized-stream
        created_at: 2026-08-14T00:00:00.000Z
        updated_at: 2026-08-14T00:00:03.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "user.message" : "assistant.message",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "data": ["content": "copilot stream turn \(index)"],
            ])
        }
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let messages = try await drain(adapter, locator: events.path)
        XCTAssertEqual(messages.map(\.content), [
            "copilot stream turn 0",
            "copilot stream turn 1",
            "copilot stream turn 2",
        ])
    }

    /// Copilot checkpoint indexes inherit SessionAdapter's default
    /// streamMessagesWithMetadata, so an oversized whole-transcript read is
    /// capped without a truncation marker.
    func testCopilotOversizedCheckpointReportsTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversize-cp", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-oversize-cp
        cwd: /tmp/copilot-oversize
        created_at: 2026-08-14T00:00:00.000Z
        updated_at: 2026-08-14T00:00:04.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        var table = """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        """
        for index in 1...4 {
            table += "\n| \(index) | copilot checkpoint \(index) | |"
        }
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try table.write(to: checkpointIndex, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let result = try await adapter.streamMessagesWithMetadata(
            locator: checkpointIndex.path,
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    func testCopilotPagedEventsNeverCrossGlobalMessageCap_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-paged-events", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try "id: session-paged-events\ncwd: /tmp/copilot\n"
            .write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        let rows: [[String: Any]] = (0..<4).map { index in
            [
                "type": index.isMultiple(of: 2) ? "user.message" : "assistant.message",
                "data": ["content": "copilot paged turn \(index)"],
            ]
        }
        try rows.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path, limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: events.path,
            options: StreamMessagesOptions(offset: 2, limit: 500)
        )
        var messages: [NormalizedMessage] = []
        for try await message in result.messages { messages.append(message) }

        XCTAssertEqual(messages.map(\.content), ["copilot paged turn 2"])
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
    }

    /// parseCheckpointSessionInfo counted every index.md row without the
    /// produced cap, so an oversized checkpoint returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001P
    func testCopilotOversizedCheckpointParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversize-cp-info", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-oversize-cp-info
        cwd: /tmp/copilot-oversize-info
        created_at: 2026-08-14T00:00:00.000Z
        updated_at: 2026-08-14T00:00:04.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        var table = """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        """
        for index in 1...4 {
            table += "\n| \(index) | copilot checkpoint info \(index) | |"
        }
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try table.write(to: checkpointIndex, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    // Audit COPILOT-AUX-001: workspace.yaml mtime must keep the session in the
    // recent set when the main locator and session-directory mtimes are stale.
    func testCopilotRecentScanTracksAuxiliaryFiles_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-aux", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try """
        id: session-aux
        cwd: /tmp/old-cwd
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: workspace, atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            try jsonLine([
                "type": "user.message",
                "timestamp": "2026-06-01T10:01:00.000Z",
                "data": ["content": "hello"],
            ]),
            try jsonLine([
                "type": "assistant.message",
                "timestamp": "2026-06-01T10:02:00.000Z",
                "data": ["content": "world"],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let baseline = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: events.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: workspace.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: sessionDir.path)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let beforeSize: Int64
        switch try await adapter.parseSessionInfo(locator: events.path) {
        case .success(let before):
            XCTAssertEqual(before.cwd, "/tmp/old-cwd")
            beforeSize = before.sizeBytes
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
            return
        }

        try """
        id: session-aux
        cwd: /tmp/new-cwd
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: workspace, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: workspace.path
        )
        // Freeze events + session dir so only workspace.yaml is recent.
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: events.path)
        try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: sessionDir.path)

        let recent = RecentlyModifiedSessionAdapter(
            base: adapter,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await recent.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [events.resolvingSymlinksInPath().path]
        )
        switch try await adapter.parseSessionInfo(locator: events.path) {
        case .success(let after):
            XCTAssertEqual(after.cwd, "/tmp/new-cwd")
            XCTAssertGreaterThan(after.sizeBytes, beforeSize == 0 ? -1 : 0)
            // composite size includes workspace.yaml + events
            XCTAssertGreaterThan(
                after.sizeBytes,
                JSONLAdapterSupport.fileSize(locator: events.path)
            )
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    // Audit COPILOT-AUX-001: checkpoint body rewrites must advance composite
    // mtime/size even when index.md, workspace.yaml, and session dir stay stale.
    func testCopilotRecentScanTracksCheckpointBody_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-checkpoint-body", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try """
        id: session-checkpoint-body
        cwd: /tmp/checkpoint-cwd
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: workspace, atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Body rewrite | 001-body.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        let body = checkpointsDir.appendingPathComponent("001-body.md")
        try "<overview>old body</overview>\n".write(to: body, atomically: true, encoding: .utf8)

        let baseline = Date(timeIntervalSince1970: 1_000)
        for path in [workspace.path, checkpointIndex.path, body.path, sessionDir.path, checkpointsDir.path] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let beforeSize: Int64
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let before):
            XCTAssertEqual(before.assistantMessageCount, 1)
            XCTAssertEqual(before.systemMessageCount, 0)
            beforeSize = before.sizeBytes
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
            return
        }

        try "<overview>new much longer checkpoint body content for size</overview>\n"
            .write(to: body, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: body.path
        )
        for path in [workspace.path, checkpointIndex.path, sessionDir.path, checkpointsDir.path] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let recent = RecentlyModifiedSessionAdapter(
            base: adapter,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await recent.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [checkpointIndex.resolvingSymlinksInPath().path]
        )
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let after):
            XCTAssertGreaterThan(after.sizeBytes, beforeSize)
            XCTAssertGreaterThan(
                after.sizeBytes,
                JSONLAdapterSupport.fileSize(locator: checkpointIndex.path)
            )
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    func testCopilotCheckpointScanRejectsWorkspaceMutation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-workspace-race", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try "id: session-workspace-race\ncwd: /tmp/original\n"
            .write(to: workspace, atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try "| 1 | Race | 001-race.md |\n"
            .write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try "<overview>stable body</overview>\n"
            .write(to: checkpointsDir.appendingPathComponent("001-race.md"), atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeCompositeIdentityValidation: {
                try? "id: session-workspace-race\ncwd: /tmp/changed\n"
                    .write(to: workspace, atomically: true, encoding: .utf8)
            })
        )
        guard case .failure(let failure) = try await adapter.scanForIndexing(locator: checkpointIndex.path) else {
            return XCTFail("a workspace rewrite during the composite scan must fail closed")
        }
        XCTAssertEqual(failure, .fileModifiedDuringParse)
    }

    func testCopilotCheckpointScanRejectsBodyMutation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-body-race", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try "id: session-body-race\ncwd: /tmp/project\n"
            .write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try "| 1 | Race | 001-race.md |\n"
            .write(to: checkpointIndex, atomically: true, encoding: .utf8)
        let body = checkpointsDir.appendingPathComponent("001-race.md")
        try "<overview>original body</overview>\n".write(to: body, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeCompositeIdentityValidation: {
                try? "<overview>changed checkpoint body</overview>\n"
                    .write(to: body, atomically: true, encoding: .utf8)
            })
        )
        guard case .failure(let failure) = try await adapter.scanForIndexing(locator: checkpointIndex.path) else {
            return XCTFail("a checkpoint rewrite during the composite scan must fail closed")
        }
        XCTAssertEqual(failure, .fileModifiedDuringParse)
    }

    func testCopilotEventsMutationYieldsProducedPrefixWithoutCleanIdentity_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-events-prefix-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("session-events-prefix", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try "id: session-events-prefix\ncwd: /tmp/old\n"
            .write(to: workspace, atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            #"{"type":"user.message","data":{"content":"produced user"}}"#,
            #"{"type":"assistant.message","data":{"content":"produced assistant"}}"#,
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)
        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            testHooks: CopilotAdapterTestHooks(beforeCompositeIdentityValidation: {
                try? "id: session-events-prefix\ncwd: /tmp/new\n"
                    .write(to: workspace, atomically: true, encoding: .utf8)
            })
        )

        guard case .success(let scan) = try await adapter.scanForIndexing(locator: events.path) else {
            return XCTFail("a produced events prefix must remain indexable")
        }
        XCTAssertEqual(scan.messages.map(\.content), ["produced user", "produced assistant"])
        XCTAssertEqual(scan.parseFailure, .fileModifiedDuringParse)
    }

    // Audit COPILOT-AUX/DISCOVERY transition: conversation stripped from events
    // must re-enter recent via events mtime and fall back to checkpoint.
    func testCopilotEventsConversationRemovedFallsBackToCheckpoint_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-events-to-checkpoint", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try """
        id: session-events-to-checkpoint
        cwd: /tmp/transition-cwd
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: workspace, atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            try jsonLine([
                "type": "user.message",
                "timestamp": "2026-06-01T10:01:00.000Z",
                "data": ["content": "hello"],
            ]),
            try jsonLine([
                "type": "assistant.message",
                "timestamp": "2026-06-01T10:02:00.000Z",
                "data": ["content": "world"],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Fallback body | 001-fallback.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try "<overview>fallback</overview>\n"
            .write(to: checkpointsDir.appendingPathComponent("001-fallback.md"), atomically: true, encoding: .utf8)

        let baseline = Date(timeIntervalSince1970: 1_000)
        for path in [
            workspace.path, events.path, checkpointIndex.path, sessionDir.path, checkpointsDir.path,
            checkpointsDir.appendingPathComponent("001-fallback.md").path,
        ] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let initialLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            initialLocators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [events.resolvingSymlinksInPath().path]
        )

        // Strip conversation so discovery must prefer the still-valid checkpoint.
        try [
            try jsonLine([
                "type": "session.start",
                "timestamp": "2026-06-01T10:00:00.000Z",
                "data": [
                    "startTime": "2026-06-01T10:00:00.000Z",
                    "context": ["cwd": "/tmp/transition-cwd"],
                ],
            ]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: events.path
        )
        for path in [
            workspace.path, checkpointIndex.path, sessionDir.path, checkpointsDir.path,
            checkpointsDir.appendingPathComponent("001-fallback.md").path,
        ] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let recent = RecentlyModifiedSessionAdapter(
            base: adapter,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await recent.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [checkpointIndex.resolvingSymlinksInPath().path]
        )
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let info):
            XCTAssertEqual(info.id, "session-events-to-checkpoint")
            XCTAssertEqual(info.assistantMessageCount, 1)
            XCTAssertEqual(info.systemMessageCount, 0)
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    // Audit COPILOT-AUX-001: deleting a referenced checkpoint body advances the
    // checkpoints/ directory mtime and must keep the session in the recent set.
    func testCopilotCheckpointBodyDeletionKeepsRecentLocator_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-body-delete", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        let workspace = sessionDir.appendingPathComponent("workspace.yaml")
        try """
        id: session-body-delete
        cwd: /tmp/delete-cwd
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: workspace, atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Deletable body | 001-delete.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        let body = checkpointsDir.appendingPathComponent("001-delete.md")
        try "<overview>will delete</overview>\n".write(to: body, atomically: true, encoding: .utf8)

        let baseline = Date(timeIntervalSince1970: 1_000)
        for path in [workspace.path, checkpointIndex.path, body.path, sessionDir.path, checkpointsDir.path] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let initialLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            initialLocators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [checkpointIndex.resolvingSymlinksInPath().path]
        )

        try FileManager.default.removeItem(at: body)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: checkpointsDir.path
        )
        for path in [workspace.path, checkpointIndex.path, sessionDir.path] {
            try FileManager.default.setAttributes([.modificationDate: baseline], ofItemAtPath: path)
        }

        let recent = RecentlyModifiedSessionAdapter(
            base: adapter,
            modifiedSince: Date(timeIntervalSince1970: 1_500)
        )
        let locators = try await recent.listSessionLocators()
        XCTAssertEqual(
            locators.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [checkpointIndex.resolvingSymlinksInPath().path]
        )
        switch try await adapter.parseSessionInfo(locator: checkpointIndex.path) {
        case .success(let info):
            XCTAssertEqual(info.assistantMessageCount, 1)
            XCTAssertEqual(info.systemMessageCount, 0)
            // Title remains even when body file is gone.
            XCTAssertTrue(info.summary?.contains("Deletable body") == true)
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    func testCopilotIgnoresOversizedWorkspaceYaml() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: injected-id
        cwd: /tmp/\(String(repeating: "x", count: 1_000))
        created_at: 2026-01-01T00:00:00Z
        updated_at: 2026-01-01T00:05:00Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine(["type": "user.message", "timestamp": "2026-01-01T00:01:00Z", "data": ["content": "hi"]]),
            jsonLine(["type": "assistant.message", "timestamp": "2026-01-01T00:02:00Z", "data": ["content": "ok"]]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxFileBytes: 512)
        )
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: events.path))

        XCTAssertEqual(info.id, "session-oversized-workspace")
        XCTAssertEqual(info.cwd, "")
    }

    func testCopilotSkipsOversizedCheckpointBody() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-oversized-checkpoint", isDirectory: true)
        let checkpointsDir = sessionDir.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
        try """
        id: session-oversized-checkpoint
        cwd: /tmp/copilot-project
        created_at: 2026-06-01T10:00:00.000Z
        updated_at: 2026-06-01T10:05:00.000Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let checkpointIndex = checkpointsDir.appendingPathComponent("index.md")
        try """
        # Checkpoint History

        | # | Title | File |
        |---|-------|------|
        | 1 | Large checkpoint | 001-large.md |
        """.write(to: checkpointIndex, atomically: true, encoding: .utf8)
        try "<overview>\(String(repeating: "x", count: 200))</overview>"
            .write(
                to: checkpointsDir.appendingPathComponent("001-large.md"),
                atomically: true,
                encoding: .utf8
            )

        let adapter = CopilotAdapter(
            sessionRoot: root.path,
            limits: ParserLimits(maxFileBytes: 180)
        )
        let streamed = try await drain(adapter, locator: checkpointIndex.path)

        XCTAssertEqual(streamed.map(\.content), ["Checkpoint 1: Large checkpoint"])
    }

    func testCopilotStripsMatchedYamlQuotePairs() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("session-quoted", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try """
        id: "quoted-id"
        cwd: "/tmp/path with space"
        created_at: '2026-01-01T00:00:00Z'
        updated_at: 2026-01-01T00:05:00Z
        """.write(to: sessionDir.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        let events = sessionDir.appendingPathComponent("events.jsonl")
        try [
            jsonLine(["type": "user.message", "timestamp": "2026-01-01T00:01:00Z", "data": ["content": "hi"]]),
            jsonLine(["type": "assistant.message", "timestamp": "2026-01-01T00:02:00Z", "data": ["content": "ok"]]),
        ].joined(separator: "\n").appending("\n")
            .write(to: events, atomically: true, encoding: .utf8)

        let adapter = CopilotAdapter(sessionRoot: root.path)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: events.path))

        XCTAssertEqual(info.id, "quoted-id")
        XCTAssertEqual(info.cwd, "/tmp/path with space")
        XCTAssertEqual(info.startTime, "2026-01-01T00:00:00Z")
    }

    // MARK: - OpenCode

    // Audit ADAPTER-OPENCODE-001: soft-archived sessions must be inaccessible so
    // previously indexed Engram rows can enter the orphan lifecycle.
    func testOpenCodeArchivedSessionIsInaccessible_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let before = OpenCodeAdapter(dbPath: dbPath)
        let locator = "\(dbPath)::ses_1"
        let beforeAccessible = await before.isAccessible(locator: locator)
        XCTAssertTrue(beforeAccessible)
        switch try await before.parseSessionInfo(locator: locator) {
        case .success:
            break
        case .failure(let failure):
            XCTFail("active session must parse before archive: \(failure)")
        }

        try Self.archiveOpenCodeSession(dbPath: dbPath, id: "ses_1", archivedAt: 1_700_000_020_000)

        // Fresh adapter = next orphan-scan cycle (avoids process-local accessibility cache).
        let after = OpenCodeAdapter(dbPath: dbPath)
        let afterAccessible = await after.isAccessible(locator: locator)
        XCTAssertFalse(
            afterAccessible,
            "archived OpenCode sessions must not remain accessible forever"
        )
        let locators = try await after.listSessionLocators()
        XCTAssertFalse(locators.contains(locator))
        switch try await after.parseSessionInfo(locator: locator) {
        case .success(let info):
            XCTFail("archived session must not parse successfully, got id=\(info.id)")
        case .failure:
            break
        }
        // Unarchived peer still works.
        let peerAccessible = await after.isAccessible(locator: "\(dbPath)::ses_2")
        XCTAssertTrue(peerAccessible)
    }

    // Audit ADAPTER-OPENCODE-002: sizeBytes must sum UTF-8 bytes, not TEXT char length.
    func testOpenCodeSessionPayloadSizeUsesUTF8Bytes_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeCJKSizeFixture(dbPath: dbPath)

        let messageJSON = #"{"role":"user"}"#
        let partJSON = #"{"type":"text","text":"你好世界"}"#
        let expected =
            Data(messageJSON.utf8).count + Data(partJSON.utf8).count
        // Character length under-counts CJK (4 chars vs 12 UTF-8 bytes in text alone).
        XCTAssertLessThan(
            messageJSON.count + partJSON.count,
            expected,
            "fixture must exercise multi-byte vs character-length divergence"
        )

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        switch try await adapter.parseSessionInfo(locator: "\(dbPath)::ses_cjk") {
        case .success(let info):
            XCTAssertEqual(
                info.sizeBytes,
                Int64(expected),
                "sizeBytes must use length(CAST(data AS BLOB)) UTF-8 totals"
            )
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
    }

    func testOpenCodeRecentListingFiltersBySessionUpdateTime() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = RecentlyModifiedSessionAdapter(
            base: OpenCodeAdapter(dbPath: dbPath),
            modifiedSince: Date(timeIntervalSince1970: 1_695_000_000)
        )

        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(locators, ["\(dbPath)::ses_1"])
    }

    func testOpenCodeCountsOnlyMessagesWithTextParts() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let locator = "\(dbPath)::ses_1"
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        let streamed = try await drain(adapter, locator: locator)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1, "assistant message without a text part must not be counted")
        XCTAssertEqual(info.messageCount, 2)
        XCTAssertEqual(info.messageCount, streamed.count, "count must match streamed message count")
        XCTAssertEqual(streamed.map(\.content), ["question", "answer\nfollow-up"])
    }

    func testOpenCodeLinksParentsWithoutSkipHidingContinuedForks_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeParentFixture(dbPath: dbPath)
        let adapter = OpenCodeAdapter(dbPath: dbPath)

        let fork = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)::fork"))
        let task = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)::task"))

        XCTAssertEqual(fork.parentSessionId, "parent")
        XCTAssertNil(fork.agentRole, "a continued fork must remain visible")
        XCTAssertEqual(task.parentSessionId, "parent")
        XCTAssertEqual(task.agentRole, "dispatched", "a non-primary TaskTool agent is dispatched even without a title suffix")
    }

    /// R184-3: a live OpenCode session with no contentful text parts must be
    /// terminal, not a zero-count browsable session.
    func testOpenCodeSessionWithNoTextPartsIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeEmptySessionFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: "\(dbPath)::ses_empty"))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    /// parseSessionInfo counted every contentful message without the produced
    /// cap, so an oversized OpenCode session returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001O
    func testOpenCodeOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeOversizedFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 3))
        switch try await adapter.parseSessionInfo(locator: "\(dbPath)::ses_oversize") {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    func testOpenCodeAttachesAssistantMessageTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let streamed = try await drain(adapter, locator: "\(dbPath)::ses_1")

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 123, outputTokens: 50, cacheReadTokens: 67, cacheCreationTokens: 8)
        )
    }

    func testOpenCodeNormalizesTextPartTypeCaseAndWhitespace() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)
        try Self.updateOpenCodePart(dbPath: dbPath, id: "p1", data: #"{"type":" Text ","text":"question"}"#)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let locator = "\(dbPath)::ses_1"
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        let streamed = try await drain(adapter, locator: locator)

        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.messageCount, streamed.count)
        XCTAssertEqual(streamed.first?.content, "question")
    }

    func testOpenCodeAccessibilityReusesSharedDatabaseConnection() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildOpenCodeFixture(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)
        let first = await adapter.isAccessible(locator: "\(dbPath)::ses_1")
        XCTAssertTrue(first)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath) }

        let second = await adapter.isAccessible(locator: "\(dbPath)::ses_2")
        XCTAssertTrue(
            second,
            "orphan scanning must not reopen the same OpenCode sqlite database for every session"
        )
    }

    func testOpenCodeListingThrowsWhenSQLiteSchemaIsUnreadable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("opencode.db").path
        try Self.buildEmptySQLiteFile(dbPath: dbPath)

        let adapter = OpenCodeAdapter(dbPath: dbPath)

        do {
            _ = try await adapter.listSessionLocators()
            XCTFail("Malformed SQLite-backed sources must surface listing errors instead of appearing empty.")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .sqliteUnreadable)
        }
    }

    func testCursorAccessibilityReusesSharedDatabaseConnection() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let first = await adapter.isAccessible(locator: "\(dbPath)?composer=cmp_1")
        XCTAssertTrue(first)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath) }

        let second = await adapter.isAccessible(locator: "\(dbPath)?composer=cmp_2")
        XCTAssertTrue(
            second,
            "orphan scanning must not reopen the same Cursor sqlite database for every composer"
        )
    }

    func testCursorListingThrowsWhenSQLiteSchemaIsUnreadable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildEmptySQLiteFile(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)

        do {
            _ = try await adapter.listSessionLocators()
            XCTFail("Malformed SQLite-backed sources must surface listing errors instead of appearing empty.")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .sqliteUnreadable)
        }
    }

    func testCursorAttachesAssistantTokenUsage() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorUsageFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let streamed = try await drain(adapter, locator: "\(dbPath)?composer=cmp_usage")

        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertNil(streamed.first?.usage)
        XCTAssertEqual(
            streamed.last?.usage,
            TokenUsage(inputTokens: 123, outputTokens: 45, cacheReadTokens: 0, cacheCreationTokens: 0)
        )
    }

    func testCursorComposerMissingCreatedAtUsesFirstBubbleTimestamp() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorMissingCreatedAtFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_missing_created"))

        XCTAssertEqual(info.startTime, "2023-11-14T22:13:21.000Z")
        XCTAssertEqual(info.endTime, "2023-11-14T22:13:22.000Z")
    }

    func testCursorUnwrapsNestedConversationSummaryAndCapsIt_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        let summary = String(repeating: "nested summary ", count: 20)
        try Self.buildCursorNestedSummaryFixture(dbPath: dbPath, summary: summary)

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(
            await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_nested_summary")
        )

        XCTAssertEqual(info.summary, String(summary.prefix(200)))
        XCTAssertEqual(info.summary?.count, 200)
    }

    func testCursorFallsBackToFirstUserTextForSummaryButNotOfficialTitle_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOwnershipComposerFixture(
            dbPath: dbPath,
            composerId: "cmp_first_user",
            selectedFile: "/tmp/ignored.swift"
        )

        let info = try sessionInfo(
            await CursorAdapter(dbPath: dbPath).parseSessionInfo(
                locator: "\(dbPath)?composer=cmp_first_user"
            )
        )

        XCTAssertEqual(info.summary, "ownership probe")
        XCTAssertNil(info.displayTitle)
    }

    func testCursorDiscoversModernStoreAndTranscriptAsOneNamedSession_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "modern-cursor-session"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: "Modern Cursor Chat"
        )

        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let locators = try await adapter.listSessionLocators()

        XCTAssertEqual(locators.count, 1)
        let locator = try XCTUnwrap(locators.first)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        XCTAssertEqual(info.id, sessionID)
        XCTAssertEqual(info.displayTitle, "Modern Cursor Chat")
        XCTAssertEqual(info.summary, "Modern first user prompt")
        let roles = try await drain(adapter, locator: locator).map(\.role)
        XCTAssertEqual(roles, [.user, .assistant])
    }

    func testCursorModernSummaryUsesConversationDigestWithoutInventingOfficialTitle_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "modern-cursor-summary"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: nil,
            conversationSummary: "Modern conversation digest"
        )

        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))

        XCTAssertEqual(info.summary, "Modern conversation digest")
        XCTAssertNil(info.displayTitle)
    }

    func testCursorModernMetaJSONProvidesOfficialTitleCwdAndCreatedTime_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "modern-cursor-meta"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: nil
        )
        let sessionRoot = cursorRoot
            .appendingPathComponent("chats/workspace", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let meta: [String: Any] = [
            "title": "Live Cursor Meta Title",
            "cwd": "/Users/test/live-project",
            "createdAtMs": 1_710_000_000_000,
        ]
        try JSONSerialization.data(withJSONObject: meta).write(
            to: sessionRoot.appendingPathComponent("meta.json")
        )

        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))

        XCTAssertEqual(info.displayTitle, "Live Cursor Meta Title")
        XCTAssertEqual(info.cwd, "/Users/test/live-project")
        XCTAssertEqual(info.project, "live-project")
        XCTAssertEqual(info.startTime, Phase4AdapterSupport.isoFromMilliseconds(1_710_000_000_000))
    }

    func testCursorSwiftIndexerRefreshesSummaryAtSameCountAndUsesFirstNonemptyOfficialName_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "cursor-live-summary-version"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: nil,
            conversationSummary: "Initial Cursor conversation digest"
        )
        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let databaseURL = root.appendingPathComponent("engram.sqlite")
        let writer = try EngramDatabaseWriter(path: databaseURL.path)
        try writer.migrate()

        let first = try await SwiftIndexer(
            sink: AdapterNoopIndexingWriteSink(),
            adapters: [adapter]
        ).collectSnapshots()
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch(first, reason: .initialScan)
        }

        let sessionRoot = cursorRoot
            .appendingPathComponent("chats/workspace", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let updatedMetadata: [String: Any] = [
            "title": "   ",
            "name": "Official Cursor Name",
            "latestConversationSummary": [
                "summary": ["summary": "Updated Cursor conversation digest"],
            ],
        ]
        let updatedData = try JSONSerialization.data(withJSONObject: updatedMetadata)
        try updatedData.write(to: sessionRoot.appendingPathComponent("meta.json"))

        let second = try await SwiftIndexer(
            sink: AdapterNoopIndexingWriteSink(),
            adapters: [adapter]
        ).collectSnapshots()
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch(second, reason: .initialScan)
        }

        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT summary, summary_message_count, generated_title FROM sessions WHERE id = ?",
                arguments: [sessionID]
            ))
            XCTAssertEqual(row["summary"] as String?, "Updated Cursor conversation digest")
            XCTAssertNil(row["summary_message_count"] as Int?)
            XCTAssertEqual(row["generated_title"] as String?, "Official Cursor Name")
        }
    }

    func testCursorEmptyLiveConversationSummaryDoesNotInventFirstUserDigest_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "cursor-empty-live-summary"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: nil,
            conversationSummary: "Stored Cursor digest"
        )
        let sessionRoot = cursorRoot
            .appendingPathComponent("chats/workspace", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try JSONSerialization.data(withJSONObject: [
            "latestConversationSummary": ["summary": ["summary": "   "]],
        ]).write(to: sessionRoot.appendingPathComponent("meta.json"))

        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let locators = try await adapter.listSessionLocators()
        let locator = try XCTUnwrap(locators.first)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: locator))
        XCTAssertNil(info.summary)
    }

    func testCursorIndexerReplacesDriftedMechanicalPreviewWithNewDigest_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cursorRoot = root.appendingPathComponent(".cursor", isDirectory: true)
        let sessionID = "cursor-drifted-preview"
        try Self.buildModernCursorFixture(
            cursorRoot: cursorRoot,
            sessionID: sessionID,
            name: nil,
            conversationSummary: "Stored Cursor digest"
        )
        let adapter = CursorAdapter(
            dbPath: root.appendingPathComponent("missing-state.vscdb").path,
            cursorDataRoot: cursorRoot
        )
        let writer = try EngramDatabaseWriter(path: root.appendingPathComponent("engram.sqlite").path)
        try writer.migrate()
        let first = try await SwiftIndexer(
            sink: AdapterNoopIndexingWriteSink(),
            adapters: [adapter]
        ).collectSnapshots()
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch(first, reason: .initialScan)
            try db.execute(
                sql: "UPDATE sessions SET generated_title = ? WHERE id = ?",
                arguments: ["Modern first user prompt", sessionID]
            )
        }

        let sessionRoot = cursorRoot
            .appendingPathComponent("chats/workspace", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try JSONSerialization.data(withJSONObject: [
            "latestConversationSummary": ["summary": ["summary": "New Cursor digest"]],
        ]).write(to: sessionRoot.appendingPathComponent("meta.json"))
        let second = try await SwiftIndexer(
            sink: AdapterNoopIndexingWriteSink(),
            adapters: [adapter]
        ).collectSnapshots()
        try writer.write { db in
            _ = try SessionBatchUpsert(db: db).upsertBatch(second, reason: .initialScan)
        }
        try writer.read { db in
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT generated_title FROM sessions WHERE id = ?", arguments: [sessionID]),
                "New Cursor digest"
            )
        }
    }

    func testCursorMigratedWorkspaceHeaderSetsUniqueOwnershipAndOfficialTitle_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)
        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        let composerId = "cmp_migrated_header"
        let officialName = "  Official migrated Cursor title  "
        try Self.buildCursorMigratedHeaderFixture(
            globalDBPath: dbPath,
            workspaceStorage: workspaceStorage,
            workspaceName: "migrated-workspace",
            composerId: composerId,
            officialName: officialName
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=\(composerId)"))

        XCTAssertEqual(info.cwd, "/Users/test/migrated-project")
        XCTAssertEqual(info.project, "migrated-project")
        XCTAssertEqual(info.displayTitle, "Official migrated Cursor title")
        XCTAssertEqual(info.summary, "Nested migrated digest")
    }

    func testCursorOfficialTitleUsesSwiftCharacterBoundary_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)
        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        let expectedTitle = String(repeating: "a", count: 119) + "👩🏽‍💻"
        try Self.buildCursorMigratedHeaderFixture(
            globalDBPath: dbPath,
            workspaceStorage: workspaceStorage,
            workspaceName: "emoji-workspace",
            composerId: "cmp_emoji_title",
            officialName: expectedTitle + " tail"
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_emoji_title"))

        XCTAssertEqual(info.displayTitle, expectedTitle)
        XCTAssertEqual(info.displayTitle?.count, 120)
    }

    func testCursorConflictingGlobalHeaderOwnershipFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)
        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        let composerId = "cmp_conflicting_headers"
        try Self.buildCursorMigratedHeaderFixture(
            globalDBPath: dbPath,
            workspaceStorage: workspaceStorage,
            workspaceName: "first-header-workspace",
            composerId: composerId,
            officialName: "Official title",
            additionalWorkspace: ("second-header-workspace", "/Users/test/second-project")
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=\(composerId)"))

        XCTAssertEqual(info.cwd, "")
        XCTAssertNil(info.project)
    }

    // CURSOR-CWD-001 (P2): only Cursor's composer-to-workspace index may
    // establish ownership; an attached/selected file is never authoritative.
    func testCursorUsesUniqueWorkspaceIndexInsteadOfUnrelatedFileSelection_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)

        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOwnershipComposerFixture(
            dbPath: dbPath,
            composerId: "cmp_owned",
            selectedFile: "/Users/test/unrelated-repo/README.md"
        )
        try Self.buildCursorWorkspaceIndexFixture(
            workspaceStorage: workspaceStorage,
            workspaceName: "workspace-owned",
            folderURI: "file:///Users/test/owned%20project",
            composerIds: ["cmp_owned"]
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_owned"))

        XCTAssertEqual(info.cwd, "/Users/test/owned project")
        XCTAssertEqual(info.project, "owned project")
        XCTAssertNotEqual(info.cwd, "/Users/test/unrelated-repo")
    }

    // CURSOR-CWD-001 (P2): a selected editor file without a workspace-owned
    // composer index must fail closed rather than invent project ownership.
    func testCursorFileSelectionAloneDoesNotSetWorkspaceOwnership_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOwnershipComposerFixture(
            dbPath: dbPath,
            composerId: "cmp_selection_only",
            selectedFile: "/Users/test/unrelated-repo/Sources/App.swift"
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(
            await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_selection_only")
        )

        XCTAssertEqual(info.cwd, "")
        XCTAssertNil(info.project)
    }

    // CURSOR-CWD-001 (P2): stale pointer rows can reference one composer from
    // more than one workspace. Conflicting folder ownership must remain empty.
    func testCursorConflictingWorkspaceIndexesFailClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)

        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOwnershipComposerFixture(
            dbPath: dbPath,
            composerId: "cmp_ambiguous",
            selectedFile: "/Users/test/selection-only/file.swift"
        )
        try Self.buildCursorWorkspaceIndexFixture(
            workspaceStorage: workspaceStorage,
            workspaceName: "workspace-a",
            folderURI: "file:///Users/test/project-a",
            composerIds: ["cmp_ambiguous"]
        )
        try Self.buildCursorWorkspaceIndexFixture(
            workspaceStorage: workspaceStorage,
            workspaceName: "workspace-b",
            folderURI: "file:///Users/test/project-b",
            composerIds: ["cmp_ambiguous"]
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_ambiguous"))

        XCTAssertEqual(info.cwd, "")
        XCTAssertNil(info.project)
    }

    // CURSOR-CWD-001 (P2): multi-root .code-workspace mappings must not invent a
    // primary folder. Presence of workspace.json `configuration` fails closed.
    func testCursorMultiRootWorkspaceConfigurationFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspaceStorage = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: globalStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceStorage, withIntermediateDirectories: true)

        let dbPath = globalStorage.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOwnershipComposerFixture(
            dbPath: dbPath,
            composerId: "cmp_multiroot",
            selectedFile: "/Users/test/selection-only/file.swift"
        )
        try Self.buildCursorWorkspaceIndexFixture(
            workspaceStorage: workspaceStorage,
            workspaceName: "workspace-multi",
            folderURI: "file:///Users/test/would-be-primary",
            composerIds: ["cmp_multiroot"],
            configurationURI: "file:///Users/test/owned.code-workspace"
        )

        let adapter = CursorAdapter(dbPath: dbPath)
        let info = try sessionInfo(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_multiroot"))

        XCTAssertEqual(info.cwd, "")
        XCTAssertNil(info.project)
    }

    /// R184-3: a valid composer with no visible bubbles must be terminal,
    /// not a zero-count browsable session.
    func testCursorComposerWithNoVisibleBubblesIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_1"))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    /// Cursor inherits SessionAdapter's default streamMessagesWithMetadata, so
    /// an oversized whole-transcript read is capped without a truncation marker.
    func testCursorOversizedTranscriptReportsTruncation_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOversizedFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 3))
        let result = try await adapter.streamMessagesWithMetadata(
            locator: "\(dbPath)?composer=cmp_oversize",
            options: StreamMessagesOptions()
        )
        var streamed: [NormalizedMessage] = []
        for try await message in result.messages {
            streamed.append(message)
        }

        XCTAssertEqual(streamed.count, 3)
        XCTAssertEqual(result.truncatedAt, 3)
        XCTAssertFalse(result.totalKnownComplete)
        XCTAssertTrue(result.truncated)
    }

    /// parseSessionInfo counted every visible bubble without the produced cap,
    /// so an oversized Cursor composer returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001N
    func testCursorOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorOversizedFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath, limits: ParserLimits(maxMessages: 3))
        switch try await adapter.parseSessionInfo(locator: "\(dbPath)?composer=cmp_oversize") {
        case .success(let info):
            XCTFail("oversized parseSessionInfo must fail closed, got counts=\(info.messageCount)")
        case .failure(let failure):
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    // Audit CURSOR-CONTENT-001: empty/whitespace text must not shadow non-empty rawText.
    func testCursorFallsBackToRawTextWhenTextIsEmpty_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("state.vscdb").path
        try Self.buildCursorEmptyTextRawTextFixture(dbPath: dbPath)

        let adapter = CursorAdapter(dbPath: dbPath)
        let locator = "\(dbPath)?composer=cmp_rawtext"
        switch try await adapter.parseSessionInfo(locator: locator) {
        case .success(let info):
            XCTAssertEqual(info.userMessageCount, 1)
            XCTAssertEqual(info.assistantMessageCount, 1)
            XCTAssertEqual(info.messageCount, 2)
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
        }
        let streamed = try await drain(adapter, locator: locator)
        XCTAssertEqual(streamed.map(\.role), [.user, .assistant])
        XCTAssertEqual(
            streamed.map(\.content),
            ["restored user prompt", "restored assistant reply"]
        )
    }

    /// Minimal OpenCode schema with: 1 user msg (text part), 1 assistant msg
    /// (multiple text parts), and 1 assistant msg whose only part is a non-text
    /// tool part (must be excluded from counts and the stream).
    private static func buildOpenCodeFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")

        try exec("INSERT INTO session VALUES ('ses_1', '/Users/test/proj', 'Title', 1700000000000, 1700000010000, NULL)")
        try exec("INSERT INTO session VALUES ('ses_2', '/Users/test/proj', 'Second', 1690000000000, 1690000010000, NULL)")
        try exec("INSERT INTO message VALUES ('m1', 'ses_1', 1700000001000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO message VALUES ('m2', 'ses_1', 1700000002000, '{\"role\":\"assistant\",\"tokens\":{\"input\":123,\"output\":45,\"reasoning\":5,\"cache\":{\"read\":67,\"write\":8}}}')")
        try exec("INSERT INTO message VALUES ('m3', 'ses_1', 1700000003000, '{\"role\":\"assistant\"}')")
        try exec("INSERT INTO message VALUES ('m4', 'ses_2', 1700000004000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO part VALUES ('p1', 'm1', 1700000001000, '{\"type\":\"text\",\"text\":\"question\"}')")
        try exec("INSERT INTO part VALUES ('p2', 'm2', 1700000002000, '{\"type\":\"text\",\"text\":\"answer\"}')")
        try exec("INSERT INTO part VALUES ('p2b', 'm2', 1700000002001, '{\"type\":\"text\",\"text\":\"follow-up\"}')")
        // m3 has only a tool part (no text) → must be dropped.
        try exec("INSERT INTO part VALUES ('p3', 'm3', 1700000003000, '{\"type\":\"tool\",\"tool\":\"read\"}')")
        try exec("INSERT INTO part VALUES ('p4', 'm4', 1700000004000, '{\"type\":\"text\",\"text\":\"second\"}')")
    }

    private static func buildOpenCodeParentFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, parent_id TEXT, slug TEXT, agent TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
        try exec("INSERT INTO session VALUES ('parent', NULL, 'root-session', 'build', '/tmp/project', 'Parent', 1700000000000, 1700000001000, NULL)")
        try exec("INSERT INTO session VALUES ('fork', 'parent', 'continued-fork', NULL, '/tmp/project', 'Fork', 1700000002000, 1700000003000, NULL)")
        try exec("INSERT INTO session VALUES ('task', 'parent', 'task-child', 'explore', '/tmp/project', 'Task work', 1700000004000, 1700000005000, NULL)")
        for (index, sessionID) in ["fork", "task"].enumerated() {
            try exec("INSERT INTO message VALUES ('m\(index)', '\(sessionID)', 170000000\(index + 2)000, '{\"role\":\"user\"}')")
            try exec("INSERT INTO part VALUES ('p\(index)', 'm\(index)', 170000000\(index + 2)000, '{\"type\":\"text\",\"text\":\"question\"}')")
        }
    }

    private static func buildOpenCodeOversizedFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
        try exec("INSERT INTO session VALUES ('ses_oversize', '/tmp/opencode-oversized', 'Oversized', 1700000000000, 1700000008000, NULL)")
        for index in 0..<8 {
            let role = index % 2 == 0 ? "user" : "assistant"
            try exec("INSERT INTO message VALUES ('m\(index)', 'ses_oversize', \(1_700_000_001_000 + index * 1_000), '{\"role\":\"\(role)\"}')")
            try exec("INSERT INTO part VALUES ('p\(index)', 'm\(index)', \(1_700_000_001_000 + index * 1_000), '{\"type\":\"text\",\"text\":\"opencode info turn \(index)\"}')")
        }
    }

    /// Live session row whose only part is a non-text tool event.
    private static func buildOpenCodeEmptySessionFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
        try exec("INSERT INTO session VALUES ('ses_empty', '/tmp/empty', 'Empty', 1700000000000, 1700000001000, NULL)")
        try exec("INSERT INTO message VALUES ('m-empty', 'ses_empty', 1700000001000, '{\"role\":\"assistant\"}')")
        try exec("INSERT INTO part VALUES ('p-empty', 'm-empty', 1700000001000, '{\"type\":\"tool\",\"tool\":\"read\"}')")
    }

    private static func updateOpenCodePart(dbPath: String, id: String, data: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE part SET data = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, data, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 3)
        }
    }

    private static func archiveOpenCodeSession(dbPath: String, id: String, archivedAt: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "UPDATE session SET time_archived = ? WHERE id = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, archivedAt)
        sqlite3_bind_text(statement, 2, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 3)
        }
    }

    /// Single-session fixture whose TEXT payloads contain multi-byte CJK so
    /// character-length and UTF-8 byte-length diverge.
    private static func buildOpenCodeCJKSizeFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE session (id TEXT, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        try exec("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT)")
        try exec("INSERT INTO session VALUES ('ses_cjk', '/Users/test/cjk', 'CJK', 1700000000000, 1700000010000, NULL)")
        try exec("INSERT INTO message VALUES ('m_cjk', 'ses_cjk', 1700000001000, '{\"role\":\"user\"}')")
        try exec("INSERT INTO part VALUES ('p_cjk', 'm_cjk', 1700000001000, '{\"type\":\"text\",\"text\":\"你好世界\"}')")
    }

    private static func buildEmptySQLiteFile(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        sqlite3_close(db)
    }

    private static func buildCursorFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_1', '{\"composerId\":\"cmp_1\"}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_2', '{\"composerId\":\"cmp_2\"}')")
    }

    private static func buildCursorUsageFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_usage', '{\"composerId\":\"cmp_usage\"}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_usage:u1', '{\"type\":1,\"text\":\"Track Cursor usage\",\"timingInfo\":{\"clientStartTime\":1700000001000},\"tokenCount\":{\"inputTokens\":77,\"outputTokens\":0}}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_usage:a1', '{\"type\":2,\"text\":\"Cursor usage tracked.\",\"timingInfo\":{\"clientStartTime\":1700000002000},\"tokenCount\":{\"inputTokens\":123,\"outputTokens\":45}}')")
    }

    private static func buildCursorNestedSummaryFixture(dbPath: String, summary: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        let composer: [String: Any] = [
            "composerId": "cmp_nested_summary",
            "latestConversationSummary": ["summary": ["summary": summary]],
        ]
        let composerJSON = try JSONSerialization.data(withJSONObject: composer)
        let composerValue = try XCTUnwrap(String(data: composerJSON, encoding: .utf8))
            .replacingOccurrences(of: "'", with: "''")

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_nested_summary', '\(composerValue)')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_nested_summary:u1', '{\"type\":1,\"text\":\"summarize this\",\"timingInfo\":{\"clientStartTime\":1700000001000}}')")
    }

    private static func buildCursorOversizedFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_oversize', '{\"composerId\":\"cmp_oversize\"}')")
        for index in 0..<8 {
            let type = index.isMultiple(of: 2) ? 1 : 2
            try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_oversize:b\(index)', '{\"type\":\(type),\"text\":\"cursor turn \(index)\",\"timingInfo\":{\"clientStartTime\":\(1_700_000_001_000 + index * 1_000)}}')")
        }
    }

    private static func buildCursorMissingCreatedAtFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_missing_created', '{\"composerId\":\"cmp_missing_created\",\"lastUpdatedAt\":1700000002000}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_missing_created:u1', '{\"type\":1,\"text\":\"Track Cursor timestamps\",\"timingInfo\":{\"clientStartTime\":1700000001000}}')")
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_missing_created:a1', '{\"type\":2,\"text\":\"Cursor timestamps tracked.\",\"timingInfo\":{\"clientStartTime\":1700000002000}}')")
    }

    private static func buildCursorOwnershipComposerFixture(
        dbPath: String,
        composerId: String,
        selectedFile: String
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(dbPath, &database) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(
            database,
            "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        let composer: [String: Any] = [
            "composerId": composerId,
            "createdAt": 1_700_000_000_000,
            // Ownership fixtures must remain parseable after R184-3 fail-closed
            // on empty composers. One visible user bubble is enough.
            "conversation": [
                ["type": 1, "text": "ownership probe"],
            ],
            "context": [
                "fileSelections": [["uri": ["fsPath": selectedFile]]],
            ],
        ]
        let value = String(
            decoding: try JSONSerialization.data(withJSONObject: composer),
            as: UTF8.self
        )
        try insertSQLiteKeyValue(
            database: database,
            table: "cursorDiskKV",
            key: "composerData:\(composerId)",
            value: value
        )
    }

    private static func buildModernCursorFixture(
        cursorRoot: URL,
        sessionID: String,
        name: String?,
        conversationSummary: String? = nil
    ) throws {
        let sessionRoot = cursorRoot
            .appendingPathComponent("chats/workspace", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let transcriptRoot = cursorRoot
            .appendingPathComponent("projects/Users-test-project/agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptRoot, withIntermediateDirectories: true)

        let storePath = sessionRoot.appendingPathComponent("store.db").path
        var database: OpaquePointer?
        guard sqlite3_open(storePath, &database) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        var metadataObject: [String: Any] = ["createdAt": 1_700_000_000_000]
        if let name { metadataObject["name"] = name }
        if let conversationSummary {
            metadataObject["latestConversationSummary"] = [
                "summary": ["summary": conversationSummary],
            ]
        }
        let metadata = try JSONSerialization.data(withJSONObject: metadataObject)
        let metadataHex = metadata.map { String(format: "%02x", $0) }.joined()
        try insertSQLiteKeyValue(database: database, table: "meta", key: "0", value: metadataHex)

        let transcript = """
        {"role":"user","message":{"content":[{"type":"text","text":"Modern first user prompt"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Modern assistant reply"}]}}
        """
        try transcript.write(
            to: transcriptRoot.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func buildCursorWorkspaceIndexFixture(
        workspaceStorage: URL,
        workspaceName: String,
        folderURI: String,
        composerIds: [String],
        configurationURI: String? = nil
    ) throws {
        let workspace = workspaceStorage.appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var metadataObject: [String: Any] = ["folder": folderURI]
        if let configurationURI {
            metadataObject["configuration"] = configurationURI
        }
        let metadata = try JSONSerialization.data(
            withJSONObject: metadataObject,
            options: [.sortedKeys]
        )
        try metadata.write(to: workspace.appendingPathComponent("workspace.json"), options: .atomic)

        let dbPath = workspace.appendingPathComponent("state.vscdb").path
        var database: OpaquePointer?
        guard sqlite3_open(dbPath, &database) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        let index: [String: Any] = [
            "allComposers": composerIds.map { ["composerId": $0] },
        ]
        let value = String(
            decoding: try JSONSerialization.data(withJSONObject: index),
            as: UTF8.self
        )
        try insertSQLiteKeyValue(
            database: database,
            table: "ItemTable",
            key: "composer.composerData",
            value: value
        )
    }

    private static func buildCursorMigratedHeaderFixture(
        globalDBPath: String,
        workspaceStorage: URL,
        workspaceName: String,
        composerId: String,
        officialName: String,
        additionalWorkspace: (String, String)? = nil
    ) throws {
        var globalDatabase: OpaquePointer?
        guard sqlite3_open(globalDBPath, &globalDatabase) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(globalDatabase) }
        guard sqlite3_exec(
            globalDatabase,
            "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT); CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        let composer: [String: Any] = [
            "composerId": composerId,
            "name": officialName,
            "createdAt": 1_700_000_000_000,
            "latestConversationSummary": ["summary": ["summary": "Nested migrated digest"]],
            "conversation": [["type": 1, "text": "ownership probe"]],
        ]
        var workspaces = [(workspaceName, "/Users/test/migrated-project")]
        if let additionalWorkspace { workspaces.append(additionalWorkspace) }
        let headers: [String: Any] = [
            "allComposers": workspaces.map { workspace in
                [
                    "composerId": composerId,
                    "workspaceIdentifier": ["id": workspace.0],
                ]
            },
        ]
        try insertSQLiteKeyValue(
            database: globalDatabase,
            table: "cursorDiskKV",
            key: "composerData:\(composerId)",
            value: String(decoding: try JSONSerialization.data(withJSONObject: composer), as: UTF8.self)
        )
        try insertSQLiteKeyValue(
            database: globalDatabase,
            table: "ItemTable",
            key: "composer.composerHeaders",
            value: String(decoding: try JSONSerialization.data(withJSONObject: headers), as: UTF8.self)
        )

        for workspaceEntry in workspaces {
            let workspace = workspaceStorage.appendingPathComponent(workspaceEntry.0, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["folder": "file://\(workspaceEntry.1)"])
                .write(to: workspace.appendingPathComponent("workspace.json"), options: .atomic)
            var workspaceDatabase: OpaquePointer?
            guard sqlite3_open(workspace.appendingPathComponent("state.vscdb").path, &workspaceDatabase) == SQLITE_OK else {
                throw NSError(domain: "test", code: 3)
            }
            defer { sqlite3_close(workspaceDatabase) }
            guard sqlite3_exec(
                workspaceDatabase,
                "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw NSError(domain: "test", code: 4)
            }
            try insertSQLiteKeyValue(
                database: workspaceDatabase,
                table: "ItemTable",
                key: "composer.composerData",
                value: "{\"selectedComposerId\":\"\(composerId)\"}"
            )
        }
    }

    private static func insertSQLiteKeyValue(
        database: OpaquePointer?,
        table: String,
        key: String,
        value: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO \(table) (key, value) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "test", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "test", code: 3)
        }
    }

    /// Bubbles with empty / whitespace `text` and non-empty `rawText` (restored).
    private static func buildCursorEmptyTextRawTextFixture(dbPath: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw NSError(domain: "test", code: 1)
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        try exec("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT INTO cursorDiskKV VALUES ('composerData:cmp_rawtext', '{\"composerId\":\"cmp_rawtext\",\"createdAt\":1700000000000,\"lastUpdatedAt\":1700000002000}')")
        // Empty string text shadows rawText under nil-coalescing.
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_rawtext:u1', '{\"type\":1,\"text\":\"\",\"rawText\":\"restored user prompt\",\"timingInfo\":{\"clientStartTime\":1700000001000}}')")
        // Whitespace-only text must also fall through.
        try exec("INSERT INTO cursorDiskKV VALUES ('bubbleId:cmp_rawtext:a1', '{\"type\":2,\"text\":\"   \",\"rawText\":\"restored assistant reply\",\"timingInfo\":{\"clientStartTime\":1700000002000}}')")
    }

    // MARK: - CommandCode

    /// parseSessionInfo used readObjects without reportFailures, so an
    /// oversized CommandCode transcript returned prefix counts as if complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001E
    func testCommandCodeOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-commandcode-oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "sessionId": "commandcode-oversized-info",
                "cwd": "/tmp/commandcode-oversized",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "content": [["type": "text", "text": "commandcode info turn \(index)"]],
            ])
        }
        let file = projectDir.appendingPathComponent("commandcode-oversized-info.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// streamMessages used windowedMessages, which swallows messageLimitExceeded
    /// and streams a prefix as complete when limit is nil.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001F
    func testCommandCodeOversizedTranscriptStreamMessagesKeepsProducedPrefix_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-commandcode-oversized-stream", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "sessionId": "commandcode-oversized-stream",
                "cwd": "/tmp/commandcode-oversized-stream",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
                "content": [["type": "text", "text": "commandcode stream turn \(index)"]],
            ])
        }
        let file = projectDir.appendingPathComponent("commandcode-oversized-stream.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(
            projectsRoot: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let messages = try await drain(adapter, locator: file.path)
        XCTAssertEqual(messages.count, 3)
    }

    // Audit L10: CommandCode's batch parser classifies injected wrappers as
    // system, and the streamed role must preserve that classification.
    func testCommandCodeStreamClassifiesInjectedWrapperAsSystem_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-commandcode-system", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "role": "user",
                "sessionId": "commandcode-system",
                "cwd": "/tmp/commandcode",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "content": [[
                    "type": "text",
                    "text": "# AGENTS.md instructions for /tmp/commandcode\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ]],
            ],
            [
                "role": "user",
                "sessionId": "commandcode-system",
                "cwd": "/tmp/commandcode",
                "timestamp": "2026-08-13T00:00:01.000Z",
                "content": [["type": "text", "text": "real CommandCode task"]],
            ],
            [
                "role": "assistant",
                "sessionId": "commandcode-system",
                "cwd": "/tmp/commandcode",
                "timestamp": "2026-08-13T00:00:02.000Z",
                "content": [["type": "text", "text": "done"]],
            ],
        ]
        let file = projectDir.appendingPathComponent("commandcode-system.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(projectsRoot: root.path)
        try await assertStreamInjectionParity(adapter, locator: file.path, firstUserText: "real CommandCode task")
    }

    func testCommandCodeProducedCapDoesNotBillSystemWrappers_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        var lines: [[String: Any]] = (0..<4).map { index in
            [
                "role": "user",
                "sessionId": "commandcode-produced-cap",
                "cwd": "/tmp/commandcode",
                "timestamp": "2026-08-23T00:00:0\(index).000Z",
                "content": [[
                    "type": "text",
                    "text": "# AGENTS.md instructions for /tmp/commandcode/\(index)\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ]],
            ]
        }
        lines.append([
            "role": "user", "sessionId": "commandcode-produced-cap", "cwd": "/tmp/commandcode",
            "timestamp": "2026-08-23T00:00:04.000Z",
            "content": [["type": "text", "text": "real task"]],
        ])
        lines.append([
            "role": "assistant", "sessionId": "commandcode-produced-cap", "cwd": "/tmp/commandcode",
            "timestamp": "2026-08-23T00:00:05.000Z",
            "content": [["type": "text", "text": "done"]],
        ])
        let file = projectDir.appendingPathComponent("session.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(projectsRoot: root.path, limits: ParserLimits(maxMessages: 2))
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.messageCount, 2)
        XCTAssertEqual(scan.info.systemMessageCount, 4)
        XCTAssertEqual(scan.messages.filter { $0.role != .system }.map(\.content), ["real task", "done"])
    }

    /// R184-3: injection-only CommandCode files must be terminal, not zero-count sessions.
    func testCommandCodeInjectionOnlySessionIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-commandcode-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "role": "user",
                "sessionId": "commandcode-empty",
                "cwd": "/tmp/commandcode",
                "timestamp": "2026-08-13T00:00:00.000Z",
                "content": [[
                    "type": "text",
                    "text": "# AGENTS.md instructions for /tmp/commandcode\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
                ]],
            ],
        ]
        let file = projectDir.appendingPathComponent("commandcode-empty.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CommandCodeAdapter(projectsRoot: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // Audit SRC-COMMANDCODE-001: missing timestamps must not index with empty startTime.
    func testCommandCodeMissingTimestampFallsBackToFileMtime_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectDir = root.appendingPathComponent("-Users-test-commandcode", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "role": "user",
                "sessionId": "ccode-no-ts",
                "cwd": "/Users/test/commandcode",
                "content": [["type": "text", "text": "hello without timestamps"]],
            ],
            [
                "role": "assistant",
                "sessionId": "ccode-no-ts",
                "cwd": "/Users/test/commandcode",
                "content": [["type": "text", "text": "reply without timestamps"]],
            ],
        ]
        let file = projectDir.appendingPathComponent("no-ts.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let fixedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedMtime],
            ofItemAtPath: file.path
        )
        let expectedStart = Phase4AdapterSupport.isoFromSeconds(fixedMtime.timeIntervalSince1970)

        let adapter = CommandCodeAdapter(projectsRoot: root.path)
        let info: NormalizedSessionInfo
        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let value):
            info = value
        case .failure(let failure):
            XCTFail("unexpected adapter failure: \(failure)")
            return
        }

        XCTAssertEqual(info.id, "ccode-no-ts")
        XCTAssertEqual(info.startTime, expectedStart)
        XCTAssertNil(info.endTime)
        XCTAssertFalse(info.startTime.isEmpty)
        XCTAssertEqual(info.userMessageCount, 1)
        XCTAssertEqual(info.assistantMessageCount, 1)
    }

    // MARK: - Windsurf

    /// parseSessionInfo called readCache without reportFailures, so an
    /// oversized Cascade cache returned prefix counts as complete.
    func testWindsurfOversizedTranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conv-oversized-info.jsonl")
        var lines: [[String: Any]] = [
            [
                "id": "conv-oversized-info",
                "title": "Oversized",
                "createdAt": "2026-08-14T00:00:00.000Z",
                "updatedAt": "2026-08-14T00:00:04.000Z",
                "cwd": "/tmp/windsurf-oversized",
            ],
        ]
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "content": "windsurf info turn \(index)",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(
            cacheDir: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// streamMessages called readCache without reportFailures, so an
    /// oversized Cascade cache streamed a prefix as complete.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001C
    func testWindsurfOversizedTranscriptStreamMessagesFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conv-oversized-stream.jsonl")
        var lines: [[String: Any]] = [
            [
                "id": "conv-oversized-stream",
                "title": "Oversized",
                "createdAt": "2026-08-14T00:00:00.000Z",
                "updatedAt": "2026-08-14T00:00:04.000Z",
                "cwd": "/tmp/windsurf-oversized-stream",
            ],
        ]
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "content": "windsurf stream turn \(index)",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(
            cacheDir: root.path,
            limits: ParserLimits(maxMessages: 3)
        )
        do {
            _ = try await drain(adapter, locator: file.path)
            XCTFail("oversized whole-transcript stream must fail closed")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    /// R184-3: a valid Windsurf cache header with no user/assistant turns
    /// must be terminal, not a zero-count browsable session.
    func testWindsurfMetadataOnlyCacheIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conv-empty.jsonl")
        try #"{"id":"conv-empty","title":"Empty","createdAt":"2026-02-18T09:00:00.000Z","updatedAt":"2026-02-18T09:00:01.000Z"}"#
            .appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = WindsurfAdapter(cacheDir: root.path)
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .noVisibleMessages)
    }

    // MARK: - Antigravity

    func testAntigravityAdapterListsEveryDocumentedBrainRoot_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let geminiRoot = root.appendingPathComponent(".gemini", isDirectory: true)
        let brainRoots = ["antigravity-cli", "antigravity", "antigravity-ide"].map {
            geminiRoot.appendingPathComponent("\($0)/brain", isDirectory: true)
        }
        var expected: [String] = []
        for (index, brainRoot) in brainRoots.enumerated() {
            let transcript = brainRoot
                .appendingPathComponent("brain-\(index)/.system_generated/logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl")
            try FileManager.default.createDirectory(
                at: transcript.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)
            expected.append(FileSystemPathIdentity.realpathPath(transcript.path))
        }

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("cache").path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: brainRoots[0].path
        )

        let locators = try await adapter.listSessionLocators()
        XCTAssertEqual(
            Set(locators.map(FileSystemPathIdentity.realpathPath)),
            Set(expected)
        )
    }

    /// parseSessionInfo called readCache without reportFailures, so an
    /// oversized Cascade cache returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001H
    func testAntigravityOversizedCacheParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("conv-oversized-info.jsonl")
        var lines: [[String: Any]] = [
            [
                "id": "conv-oversized-info",
                "title": "Oversized",
                "createdAt": "2026-08-14T00:00:00.000Z",
                "updatedAt": "2026-08-14T00:00:04.000Z",
                "cwd": "/tmp/antigravity-oversized",
            ],
        ]
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "content": "antigravity info turn \(index)",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: cacheDir.path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: root.appendingPathComponent("brain").path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// parseSessionInfo called readObjects without reportFailures, so an
    /// oversized CLI transcript returned prefix counts as complete.
    /// invariant: ADAPTER-PARSEINFO-CAP-001H
    func testAntigravityOversizedCLITranscriptParseSessionInfoFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brainDir = root.appendingPathComponent("brain", isDirectory: true)
        let logsDir = brainDir
            .appendingPathComponent("antigravity-cli-oversized", isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let file = logsDir.appendingPathComponent("transcript.jsonl")
        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "USER_INPUT" : "PLANNER_RESPONSE",
                "created_at": "2026-08-14T00:00:0\(index).000Z",
                "content": "antigravity cli info turn \(index)",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("cache").path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: brainDir.path,
            limits: ParserLimits(maxMessages: 3)
        )
        let failure = try parseFailure(await adapter.parseSessionInfo(locator: file.path))
        XCTAssertEqual(failure, .messageLimitExceeded)
    }

    /// streamMessages called readCache without reportFailures, so an
    /// oversized Cascade cache streamed a prefix as complete.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001D
    func testAntigravityOversizedCacheStreamMessagesFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("conv-oversized-stream.jsonl")
        var lines: [[String: Any]] = [
            [
                "id": "conv-oversized-stream",
                "title": "Oversized",
                "createdAt": "2026-08-14T00:00:00.000Z",
                "updatedAt": "2026-08-14T00:00:04.000Z",
                "cwd": "/tmp/antigravity-oversized-stream",
            ],
        ]
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "role": isUser ? "user" : "assistant",
                "content": "antigravity stream turn \(index)",
                "timestamp": "2026-08-14T00:00:0\(index).000Z",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: cacheDir.path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: root.appendingPathComponent("brain").path,
            limits: ParserLimits(maxMessages: 3)
        )
        do {
            _ = try await drain(adapter, locator: file.path)
            XCTFail("oversized whole-transcript stream must fail closed")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    /// streamMessages used windowedMessages, which swallows messageLimitExceeded
    /// and streams a prefix as complete when limit is nil.
    /// invariant: ADAPTER-STREAM-WHOLE-CAP-001D
    func testAntigravityOversizedCLITranscriptStreamMessagesFailsClosed_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brainDir = root.appendingPathComponent("brain", isDirectory: true)
        let logsDir = brainDir
            .appendingPathComponent("antigravity-cli-oversized-stream", isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let file = logsDir.appendingPathComponent("transcript.jsonl")
        var lines: [[String: Any]] = []
        for index in 0..<4 {
            let isUser = index % 2 == 0
            lines.append([
                "type": isUser ? "USER_INPUT" : "PLANNER_RESPONSE",
                "created_at": "2026-08-14T00:00:0\(index).000Z",
                "content": "antigravity cli stream turn \(index)",
            ])
        }
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("cache").path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: brainDir.path,
            limits: ParserLimits(maxMessages: 3)
        )
        do {
            _ = try await drain(adapter, locator: file.path)
            XCTFail("oversized whole-transcript stream must fail closed")
        } catch let failure as ParserFailure {
            XCTAssertEqual(failure, .messageLimitExceeded)
        }
    }

    /// R184-3 / ADAPTER-EMPTY-SESSION-001I: a valid Cascade cache header with
    /// no visible turns is terminal rather than a browsable zero-count session.
    func testAntigravityMetadataOnlyCacheIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appendingPathComponent("antigravity-metadata-only.jsonl")
        let metadata: [String: Any] = [
            "id": "antigravity-metadata-only",
            "createdAt": "2026-08-14T00:00:00.000Z",
            "updatedAt": "2026-08-14T00:00:00.000Z",
            "title": "Metadata only",
        ]
        try (try jsonLine(metadata) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: cacheDir.path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: root.appendingPathComponent("brain").path
        )

        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTFail("metadata-only cache must not index zero-count session \(info.id)")
        case .failure(let failure):
            XCTAssertEqual(failure, .noVisibleMessages)
        }
    }

    /// R184-3: a CLI transcript whose directory supplies a valid session id but
    /// whose records yield no user/assistant/tool messages is terminal as well.
    func testAntigravityEmptyCLITranscriptIsTerminalNoVisibleMessages_repro() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brainDir = root.appendingPathComponent("brain", isDirectory: true)
        let logsDir = brainDir
            .appendingPathComponent("antigravity-cli-empty", isDirectory: true)
            .appendingPathComponent(".system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let file = logsDir.appendingPathComponent("transcript.jsonl")
        let metadata: [String: Any] = [
            "type": "SESSION_START",
            "created_at": "2026-08-14T00:00:00.000Z",
        ]
        try (try jsonLine(metadata) + "\n").write(to: file, atomically: true, encoding: .utf8)

        let adapter = AntigravityAdapter(
            cacheDir: root.appendingPathComponent("cache").path,
            conversationsDir: root.appendingPathComponent("conversations").path,
            cliBrainDir: brainDir.path
        )

        switch try await adapter.parseSessionInfo(locator: file.path) {
        case .success(let info):
            XCTFail("empty CLI transcript must not index zero-count session \(info.id)")
        case .failure(let failure):
            XCTAssertEqual(failure, .noVisibleMessages)
        }
    }

    // MARK: - Antigravity generic cwd inference

    func testAntigravityCWDInferenceIsGenericAndNonPersonal() {
        // Most-frequent directory wins; no '-Code-' literal required.
        let text = """
        {"tool_calls":[{"name":"Read","args":{"path":"/home/alice/work/app/src/main.go"}}]}
        also touched /home/alice/work/app/src/util.go and /opt/other/x.go
        """
        XCTAssertEqual(
            AntigravityAdapter.inferCWDFromAbsolutePaths(in: text),
            "/home/alice/work/app/src"
        )
    }

    func testAntigravityCWDInferenceReturnsEmptyWithoutPaths() {
        XCTAssertEqual(AntigravityAdapter.inferCWDFromAbsolutePaths(in: "no absolute paths in auth.ts here"), "")
    }

    func testAntigravityCWDInferenceReadsOnlyBoundedPrefix_repro() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterURL = macosRoot.appendingPathComponent(
            "Shared/EngramCore/Adapters/Sources/AntigravityAdapter.swift"
        )
        let source = try String(contentsOf: adapterURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func inferredCWD("))
        let end = try XCTUnwrap(
            source.range(
                of: "// Derive a working directory",
                options: [],
                range: start.lowerBound..<source.endIndex
            )
        )
        let inferredCWD = String(source[start.lowerBound..<end.lowerBound])

        // L34: the second CWD pass must not materialize the full transcript.
        XCTAssertTrue(source.contains("private static let cwdInferenceByteLimit = 50_000"))
        XCTAssertFalse(inferredCWD.contains("String(contentsOfFile:"))
        XCTAssertTrue(inferredCWD.contains("FileHandle(forReadingFrom:"))
        XCTAssertTrue(inferredCWD.contains("read(upToCount: Self.cwdInferenceByteLimit)"))
    }
}
