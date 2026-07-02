import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Regression coverage for the "empty transcript → retryable failure churn" fix.
///
/// A *valid* transcript that happens to contain zero visible messages (only
/// system-injected turns, or an empty composer) used to return `.malformedJSON`,
/// which `IndexingWriteSink.isTerminalFailure` classifies as NON-terminal. That
/// recorded `parse_status = .retry` and re-parsed the same bytes forever on a
/// backoff cadence, never converging. Such sessions now return the terminal
/// `.noVisibleMessages`, while genuinely malformed input keeps returning the
/// retryable `.malformedJSON`.
final class EmptyTranscriptFailureTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-empty-transcript-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        try objects.map { try jsonLine($0) }.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func failure<T>(_ result: AdapterParseResult<T>) throws -> ParserFailure {
        switch result {
        case .success:
            throw XCTSkip("expected a parse failure but got success")
        case .failure(let failure):
            return failure
        }
    }

    private func syntheticStat() -> FileIndexStat {
        FileIndexStat(sizeBytes: 128, modifiedAtNanos: 1_000_000_000, inode: 42, device: 7)
    }

    /// Raw value must stay in sync with the TS `noVisibleMessages` failure kind.
    func testNoVisibleMessagesRawValueMatchesTSParity() {
        XCTAssertEqual(ParserFailure.noVisibleMessages.rawValue, "noVisibleMessages")
    }

    // (a) A claude-code transcript with only system/summary records yields
    // `.noVisibleMessages`, and the recorded FileIndexState is terminal (no retry).
    func testEmptyClaudeCodeTranscriptIsTerminalNoVisibleMessages() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("system-only.jsonl")
        try writeJSONL(
            [
                // Skipped entirely (not a user/assistant record).
                ["type": "summary", "summary": "Prior session title", "leafUuid": "prev"],
                // Carries a sessionId (so it is NOT "missing session" malformed),
                // but its content is a system injection, so it counts as a system
                // turn only → zero visible messages.
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
            ],
            to: transcript
        )

        let adapter = ClaudeCodeAdapter(source: .claudeCode, projectsRoot: root.path)
        let failure = try failure(await adapter.parseSessionInfo(locator: transcript.path))
        XCTAssertEqual(failure, .noVisibleMessages)

        let now = Date(timeIntervalSince1970: 2_000)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: transcript.path,
            stat: syntheticStat(),
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .terminal)
        XCTAssertNil(state.retryAfterEpochSeconds)
        XCTAssertEqual(state.retryCount, 0)

        // A terminal failure must be skipped on the next scan of the same file,
        // i.e. it converges instead of churning.
        XCTAssertEqual(
            FileIndexDecision.decide(stat: syntheticStat(), state: state, now: now),
            .skip
        )
    }

    // (b) A genuinely malformed file (unparseable JSON, no session record) keeps
    // returning the retryable `.malformedJSON` and a retry-scheduled state.
    func testGenuinelyMalformedClaudeCodeTranscriptStaysRetryable() async throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let badFile = root.appendingPathComponent("garbage.jsonl")
        try "this is not json at all\n{ broken\n".write(to: badFile, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(source: .claudeCode, projectsRoot: root.path)
        let failure = try failure(await adapter.parseSessionInfo(locator: badFile.path))
        XCTAssertEqual(failure, .malformedJSON)

        let now = Date(timeIntervalSince1970: 2_000)
        let state = FileIndexState.failure(
            source: .claudeCode,
            locator: badFile.path,
            stat: syntheticStat(),
            failure: failure,
            previous: nil,
            now: now
        )
        XCTAssertEqual(state.parseStatus, .retry)
        XCTAssertNotNil(state.retryAfterEpochSeconds)
        XCTAssertGreaterThan(state.retryCount, 0)
    }
}
