import Foundation
import XCTest
@testable import EngramCoreRead

final class SourceMetadataProjectionParityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engram-metadata-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testClaudeProjectionMatchesFirstNonemptySelectionButRemembersLaterConflicts() async throws {
        let objects: [[String: Any]] = [
            ["type": "summary", "sessionId": "native-first", "cwd": "/ignored"],
            ["type": "user", "sessionId": "native-first", "cwd": "", "timestamp": "2026-09-05T00:00:00Z", "message": ["content": "hello"]],
            ["type": "assistant", "sessionId": "native-first", "cwd": "/allowed", "message": ["model": "claude-sonnet-4", "content": "answer"]],
            ["type": "assistant", "sessionId": "native-later", "cwd": "/excluded", "message": ["model": "MiniMax-M2.1", "content": "later"]],
        ]
        let url = try fixture(objects)
        let info = try success(await ClaudeCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .claudeCode(forceClaudeCodeSource: false), locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.model, info.model)
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.cwd, "/allowed")
        XCTAssertTrue(projection.hasConflictingRoots)
        XCTAssertTrue(projection.hasConflictingIdentities)
        XCTAssertTrue(projection.hasConflictingSources)
    }

    func testCodexProjectionLocksFirstObjectMetadataAndDoesNotBackfillCwd() async throws {
        let first: [String: Any] = ["id": "native-first", "timestamp": "2026-09-05T00:00:00Z", "cwd": ""]
        let objects: [[String: Any]] = [
            ["type": "session_meta", "payload": "not-an-object"],
            ["type": "session_meta", "payload": first],
            ["type": "turn_context", "payload": ["cwd": "/turn-context"]],
            ["type": "session_meta", "payload": ["id": "native-later", "timestamp": "2026-09-05T00:00:01Z", "cwd": "/later"]],
            codexMessage,
        ]
        let url = try fixture(objects)
        let info = try success(await CodexAdapter(sessionsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .codex, locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.cwd ?? "", info.cwd)
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.cwd, "")
        XCTAssertTrue(projection.hasConflictingIdentities)

        let emptyFirst = project([["type": "session_meta", "payload": [:]], ["type": "session_meta", "payload": first]], format: .codex, locator: url.path)
        XCTAssertNil(emptyFirst.nativeSessionID)
        XCTAssertNil(emptyFirst.cwd)
        XCTAssertTrue(emptyFirst.selectedCodexMetadata)
    }

    func testClaudeDerivedSourceHelperMatchesParserIncludingProfileOverride() async throws {
        for (model, directory, expected) in [
            ("MiniMax-M2.1", "normal", SourceName.minimax),
            ("claude-sonnet-4", "lobsterai-workspace", .lobsterai),
            ("kimi-k2", "normal", .claudeCode),
        ] {
            let objects: [[String: Any]] = [["type": "assistant", "sessionId": "native", "cwd": "/allowed", "timestamp": "2026-09-05T00:00:00Z", "message": ["model": model, "content": "answer"]]]
            let url = try fixture(objects, directory: directory)
            let info = try success(await ClaudeCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
            let projection = project(objects, format: .claudeCode(forceClaudeCodeSource: false), locator: url.path)
            XCTAssertEqual(projection.source, info.source)
            XCTAssertEqual(projection.source, expected)
            XCTAssertEqual(SourceMetadataProjection.claudeSource(model: model, filePath: url.path), ClaudeCodeAdapter.detectSource(model: model, filePath: url.path))
            let forced = project(objects, format: .claudeCode(forceClaudeCodeSource: true), locator: url.path)
            let profile = ClaudeCodeProfile(
                id: "fixture-custom", displayName: "Fixture", projectsRoot: root.path,
                origin: .custom, available: true, sourceReclamationAllowed: false
            )
            let forcedAdapter = ClaudeCodeAdapter(profileResolutionProvider: { [profile] })
            let forcedInfo = try success(await forcedAdapter.parseSessionInfo(locator: url.path))
            XCTAssertEqual(forced.source, forcedInfo.source)
            XCTAssertEqual(forced.nativeSessionID, forcedInfo.id)
            XCTAssertEqual(forced.cwd, forcedInfo.cwd)
            XCTAssertEqual(forcedInfo.source, .claudeCode)
            XCTAssertFalse(forced.hasConflictingSources)
        }
    }

    func testNativeClaudeIdentityIsNotSyntheticSubagentIndexIdentity() async throws {
        let objects: [[String: Any]] = [["type": "assistant", "sessionId": "parent-native", "agentId": "agent", "cwd": "/allowed", "timestamp": "2026-09-05T00:00:00Z", "message": ["model": "claude-sonnet-4", "content": "answer"]]]
        let url = try fixture(objects, directory: "project/parent-native/subagents")
        let info = try success(await ClaudeCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .claudeCode(forceClaudeCodeSource: false), locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, "parent-native")
        XCTAssertNotEqual(projection.nativeSessionID, info.id)
        XCTAssertTrue(info.id.hasPrefix("sub:parent-native:"))
        XCTAssertEqual(projection.cwd, info.cwd)
    }

    private var codexMessage: [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "answer"]]]]
    }

    private func project(_ objects: [[String: Any]], format: SourceMetadataProjection.Format, locator: String) -> SourceMetadataProjection {
        var projection = SourceMetadataProjection(format: format, locator: locator)
        for object in objects { projection.consume(object) }
        return projection
    }

    private func fixture(_ objects: [[String: Any]], directory: String = "project") throws -> URL {
        let url = root.appendingPathComponent(directory).appendingPathComponent("\(UUID().uuidString).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = Data()
        for object in objects {
            bytes.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            bytes.append(0x0A)
        }
        try bytes.write(to: url)
        return url
    }

    private func success<T>(_ result: AdapterParseResult<T>) throws -> T {
        guard case .success(let value) = result else { throw NSError(domain: "SourceMetadataProjectionParityTests", code: 1) }
        return value
    }
}
