import Foundation
import XCTest
@testable import EngramCoreRead

/// Guards for live vendor format drifts observed 2026-07 (mirror row 23).
/// See `docs/adapter-format-drift-design-2026-07.md`.
final class AdapterSchemaDriftTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func tempDir(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
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

    // MARK: - Slice 3: Codex world_state

    /// Guard (not `_repro`): world_state interleaved with real turns must not
    /// suppress visible message counts via CodexAdapter.scanForIndexing.
    func testCodexWorldStateRecordDoesNotSuppressVisibleMessages() async throws {
        let root = tempDir("codex-world-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let id = "019f0000-0000-7000-8000-00000000ws01"
        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-07-24T10:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": id,
                    "timestamp": "2026-07-24T10:00:00.000Z",
                    "cwd": "/tmp/engram-world-state",
                    "cli_version": "0.146.0-alpha.6",
                    "source": "cli",
                ],
            ],
            [
                "timestamp": "2026-07-24T10:00:01.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": "hello from user"]],
                ],
            ],
            // Interleaved vendor kind that CodexAdapter currently drops.
            [
                "timestamp": "2026-07-24T10:00:01.500Z",
                "type": "world_state",
                "payload": ["cwd": "/tmp/engram-world-state", "git_branch": "main"],
            ],
            [
                "timestamp": "2026-07-24T10:00:02.000Z",
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "hello from assistant"]],
                ],
            ],
        ]
        let file = sessions.appendingPathComponent("rollout-\(id).jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = CodexAdapter(sessionsRoot: sessions.path)
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.info.userMessageCount, 1, "user turn must survive world_state")
        XCTAssertEqual(scan.info.assistantMessageCount, 1, "assistant turn must survive world_state")
        XCTAssertEqual(scan.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(scan.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertFalse(
            scan.messages.contains { $0.content.contains("world_state") },
            "world_state must not surface as a transcript message"
        )
    }

    // MARK: - Slice 4: unknownRecordKinds

    /// docs/adapter-format-drift-design-2026-07.md — mirror row 23 slice 4.
    func testClaudeCodeUnknownRecordKindIsCountedNotDropped_repro() async throws {
        let root = tempDir("claude-unknown-kind")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-tmp-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let lines: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "cc-unknown-1",
                "cwd": "/tmp/proj",
                "timestamp": "2026-07-24T10:00:00.000Z",
                "message": ["role": "user", "content": "hello"],
                "uuid": "u1",
            ],
            // Not on knownIgnoredRecordKinds — must appear in unknownRecordKinds.
            [
                "type": "copilot-usage-checkpoint",
                "sessionId": "cc-unknown-1",
                "timestamp": "2026-07-24T10:00:00.500Z",
                "uuid": "ckpt-1",
            ],
            [
                "type": "assistant",
                "sessionId": "cc-unknown-1",
                "cwd": "/tmp/proj",
                "timestamp": "2026-07-24T10:00:01.000Z",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "hi"]],
                    "model": "claude-sonnet-4",
                ],
                "uuid": "a1",
            ],
        ]
        let file = project.appendingPathComponent("cc-unknown-1.jsonl")
        try lines.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let scan = try sessionInfo(await adapter.scanForIndexing(locator: file.path))

        XCTAssertEqual(scan.unknownRecordKinds, ["copilot-usage-checkpoint"])
        XCTAssertEqual(scan.info.userMessageCount, 1)
        XCTAssertEqual(scan.info.assistantMessageCount, 1)
        XCTAssertEqual(scan.messages.count, 2)
    }

    func testClaudeCodeKnownIgnoredRecordKindsCoverFixtureCorpus() async throws {
        let fixturePaths: [String] = [
            "tests/fixtures/claude-code/new-types.jsonl",
            "tests/fixtures/claude-code/schema_drift.jsonl",
            "tests/fixtures/claude-code/session-with-usage.jsonl",
            "tests/fixtures/claude-code/sample.jsonl",
            "tests/fixtures/claude-code/tool-formatting.jsonl",
            "tests/fixtures/claude-code/with-tools.jsonl",
            "tests/fixtures/adapter-parity/claude-code/input/-Users-test-my-project/sample.jsonl",
        ]

        for relative in fixturePaths {
            let source = repoRoot.appendingPathComponent(relative)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: source.path),
                "missing fixture \(relative)"
            )

            // Copy under a temp projects root so ClaudeCodeAdapter profile matches.
            let root = tempDir("claude-fixture-\(source.deletingPathExtension().lastPathComponent)")
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let dest = project.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: dest)

            let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
            let scan = try sessionInfo(await adapter.scanForIndexing(locator: dest.path))
            XCTAssertTrue(
                scan.unknownRecordKinds.isEmpty,
                "\(relative) reported unknown kinds: \(scan.unknownRecordKinds.sorted())"
            )
        }
    }

    func testFormatDriftArtifactsExistInRepo() throws {
        let matrix = repoRoot.appendingPathComponent("docs/session-formats/support-matrix.yml")
        let baseline = repoRoot.appendingPathComponent("docs/session-formats/baselines/codex.baseline.json")
        let script = repoRoot.appendingPathComponent("scripts/check-adapter-format-drift.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: matrix.path), matrix.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseline.path), baseline.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), script.path)

        let baselineJSON = try String(contentsOf: baseline, encoding: .utf8)
        XCTAssertTrue(baselineJSON.contains("\"format\": \"codex\"") || baselineJSON.contains("\"format\":\"codex\""))
        if baselineJSON.contains("\"corpusFiles\": 0") == false {
            XCTAssertTrue(
                baselineJSON.contains("world_state"),
                "live codex baseline should record the world_state bucket after seed"
            )
        }
    }
}
