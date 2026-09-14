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

    func testAntigravityPrefixMatchesNativeCWDAndPreservesEveryRoot() throws {
        let text = "/allowed/project/a /private/project/b /allowed/project/c"
        let metadata = try XCTUnwrap(SourceMetadataProjection.antigravityCLIPrefixMetadata(Data(text.utf8), hasMoreBytes: false))
        XCTAssertEqual(metadata.cwd, AntigravityAdapter.inferCWDFromAbsolutePaths(in: text))
        XCTAssertEqual(metadata.cwd, "/allowed/project")
        XCTAssertEqual(metadata.observedProjectRoots, ["/allowed/project", "/private/project"])
        XCTAssertEqual(SourceMetadataProjection.antigravityCLINativeID(logicalLocator: "/brain/session/.system_generated/logs/transcript.jsonl"), "session")
        for parent in ["/private/var", "/var", "/tmp"] {
            XCTAssertEqual(SourceMetadataProjection.antigravityCLINativeID(
                logicalLocator: parent + "/absent-remote/session/.system_generated/logs/transcript.jsonl"), "session")
        }
        for locator in ["session/.system_generated/logs/transcript.jsonl", "/brain/session/cache/transcript.jsonl", "/brain//session/.system_generated/logs/transcript.jsonl"] {
            XCTAssertNil(SourceMetadataProjection.antigravityCLINativeID(logicalLocator: locator))
        }
    }

    func testAntigravityPrefixDistinguishesIncompleteScalarFromCorruption() throws {
        let cap = SourceMetadataProjection.antigravityCLIPrefixByteLimit
        for tail: [UInt8] in [[0xC2], [0xE4, 0xB8], [0xF0, 0x90, 0x80]] {
            let prefix = Data(repeating: 32, count: cap - tail.count) + Data(tail)
            XCTAssertNotNil(SourceMetadataProjection.antigravityCLIPrefixMetadata(prefix, hasMoreBytes: true))
            XCTAssertNil(SourceMetadataProjection.antigravityCLIPrefixMetadata(prefix, hasMoreBytes: false))
        }
        for tail: [UInt8] in [[0xFF], [0x80], [0xC0], [0xE0, 0x80], [0xED, 0xA0], [0xF4, 0x90]] {
            let prefix = Data(repeating: 32, count: cap - tail.count) + Data(tail)
            XCTAssertNil(SourceMetadataProjection.antigravityCLIPrefixMetadata(prefix, hasMoreBytes: true))
        }
        XCTAssertNil(SourceMetadataProjection.antigravityCLIPrefixMetadata(Data([0xFF, 0xC2]), hasMoreBytes: false))
    }

    func testVSCodeIdentityProjectionMatchesNativeMutationAndResetSemantics() async throws {
        let visible: [[String: Any]] = [["message": ["text": "visible question"]]]
        let initial: [String: Any] = ["kind": 0, "v": ["sessionId": "first", "creationDate": 1_700_000_000_000, "requests": visible]]
        let scenarios: [[[String: Any]]] = [
            [initial],
            [initial, ["kind": 1, "k": ["sessionId"], "v": "last"]],
            [initial, ["kind": 3, "k": ["sessionId"]]],
            [initial, ["kind": 2, "k": ["sessionId"], "v": ["array"]]],
            [initial, ["kind": 1, "k": ["sessionId", "nested"], "v": "object"]],
            [initial, ["kind": 1, "k": ["sessionId", -1], "v": "ignored"]],
            [initial, ["kind": 3, "k": ["sessionId", "nested"]]],
            [initial, ["kind": 1, "k": [], "v": "ignored"]],
            [initial, ["kind": "1", "k": ["sessionId"], "v": ""]],
            [["kind": 1, "k": ["sessionId"], "v": "ignored-before-reset"], initial],
            [initial, ["kind": 0, "v": ["sessionId": "reset", "creationDate": 1_700_000_000_000, "requests": visible]]],
            [initial, ["kind": 1, "k": [0], "v": "root-array"],
             ["kind": 1, "k": ["creationDate"], "v": 1_700_000_000_000],
             ["kind": 1, "k": ["requests"], "v": visible]],
        ]
        for objects in scenarios {
            let url = try fixture(objects)
            let info = try success(await VsCodeAdapter(workspaceStorageDir: root.path).parseSessionInfo(locator: url.path))
            let projection = project(objects, format: .vscode, locator: url.path)
            XCTAssertEqual(projection.nativeSessionID, info.id)
            XCTAssertEqual(projection.source, info.source)
            XCTAssertNil(projection.model)
            XCTAssertTrue(projection.sawRecognizedRecord)
            XCTAssertFalse(projection.hasConflictingIdentities, "journal identity mutation is native replacement, not mixed-source conflict")
        }
    }

    func testVSCodeIdentityProjectionRequiresInitialObjectAndFencesInvalidMutationPaths() {
        let noInitial = project([["kind": 1, "k": ["sessionId"], "v": "ignored"]], format: .vscode, locator: "/source/fallback.jsonl")
        XCTAssertNil(noInitial.nativeSessionID)
        XCTAssertFalse(noInitial.sawRecognizedRecord)
        let initial: [String: Any] = ["kind": 0, "v": ["sessionId": "first"]]
        for path in [Array(repeating: "nested", count: 65) as [Any], ["unrelated", 1_000_001] as [Any]] {
            let projection = project([initial, ["kind": 1, "k": path, "v": "invalid"], initial],
                format: .vscode, locator: "/source/fallback.jsonl")
            XCTAssertTrue(projection.hasInvalidIdentityEvidence, "native replay throws even if a later reset replaces the session")
        }
        let arrayRoot = project([initial, ["kind": 0, "v": ["array"]]], format: .vscode, locator: "/source/fallback.jsonl")
        XCTAssertNil(arrayRoot.nativeSessionID)
        XCTAssertFalse(arrayRoot.sawRecognizedRecord)
    }

    func testVSCodeFrozenWorkspaceProjectionMatchesNativeCwdAndRetainsSecondaryRoots() async throws {
        let file = try fixture([["kind": 0, "v": ["sessionId": "native", "creationDate": 1_700_000_000_000,
            "requests": [["message": ["text": "visible"]]]]]])
        let workspace = Data(#"{"configuration":"file:///frozen/work/project.code-workspace"}"#.utf8)
        for invalidSibling in [false, true] {
            var folders: [Any] = [["path": "../main"], ["uri": "file://localhost/allowed%20second", "path": "/ignored"]]
            if invalidSibling { folders.insert("invalid native-skipped sibling", at: 0) }
            let bytes = try JSONSerialization.data(withJSONObject: ["folders": folders])
            let context = try ArchiveVSCodeWorkspaceContext(configurationLocator: "/frozen/work/project.code-workspace",
                configurationGeneration: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(bytes.count),
                    mtimeNs: 3, ctimeNs: 4, mode: 0o100600), configurationData: bytes,
                configurationSHA256: ArchiveV2Hash.sha256(bytes))
            let native = try success(await VsCodeAdapter.scanCapturedSource(physicalLocator: file.path,
                logicalLocator: file.path, workspaceData: workspace, configurationData: bytes))
            let metadata = try SourceMetadataProjection.vscodeWorkspaceMetadata(workspaceData: workspace, context: context)
            XCTAssertEqual(metadata.cwd, native.scan.info.cwd)
            XCTAssertEqual(metadata.cwd, "/frozen/main")
            XCTAssertEqual(metadata.observedProjectRoots, ["/frozen/main", "/allowed second"])
            XCTAssertEqual(metadata.hasInvalidRootEvidence, invalidSibling,
                "native selection tolerates non-object folders but privacy must not treat ambiguity as authority")
        }
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

    func testCodexForkedFromIdAncestryPreservesFirstIdentity_repro() {
        let locator = "/tmp/rollout-child.jsonl"
        let linked = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": "parent", "cwd": "/allowed"]],
            ["type": "session_meta", "payload": ["id": "parent", "cwd": "/allowed"]],
            codexMessage,
        ], format: .codex, locator: locator)
        XCTAssertEqual(linked.nativeSessionID, "child")
        XCTAssertEqual(linked.cwd, "/allowed")
        XCTAssertTrue(linked.selectedCodexMetadata)
        XCTAssertFalse(linked.hasConflictingIdentities)
        XCTAssertFalse(linked.hasConflictingSources)
        XCTAssertFalse(linked.hasConflictingRoots)

        let chain = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": "parent", "cwd": "/allowed", "forked_from_id": "grand"]],
            ["type": "session_meta", "payload": ["id": "grand", "cwd": "/allowed"]],
            codexMessage,
        ], format: .codex, locator: locator)
        XCTAssertEqual(chain.nativeSessionID, "child")
        XCTAssertFalse(chain.hasConflictingIdentities)

        let unlinked = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": "other", "cwd": "/allowed"]],
        ], format: .codex, locator: locator)
        XCTAssertTrue(unlinked.hasConflictingIdentities)
        XCTAssertEqual(unlinked.nativeSessionID, "child")

        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let byteMismatch = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": composed]],
            ["type": "session_meta", "payload": ["id": decomposed, "cwd": "/allowed"]],
        ], format: .codex, locator: locator)
        XCTAssertTrue(byteMismatch.hasConflictingIdentities)

        let differingRoot = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": "parent", "cwd": "/other"]],
        ], format: .codex, locator: locator)
        XCTAssertFalse(differingRoot.hasConflictingIdentities)
        XCTAssertTrue(differingRoot.hasConflictingRoots)
        XCTAssertEqual(differingRoot.cwd, "/allowed")

        let mixed = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": "parent", "cwd": "/allowed"]],
            ["type": "user", "sessionId": "child", "cwd": "/allowed"],
        ], format: .codex, locator: locator)
        XCTAssertTrue(mixed.hasConflictingSources)
        XCTAssertFalse(mixed.hasConflictingIdentities)

        let malformedFork = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": 1]],
        ], format: .codex, locator: locator)
        XCTAssertTrue(malformedFork.hasInvalidIdentityEvidence)
        XCTAssertEqual(malformedFork.nativeSessionID, "child")

        let malformedLaterID = project([
            ["type": "session_meta", "payload": ["id": "child", "cwd": "/allowed", "forked_from_id": "parent"]],
            ["type": "session_meta", "payload": ["id": 42, "cwd": "/allowed"]],
        ], format: .codex, locator: locator)
        XCTAssertTrue(malformedLaterID.hasInvalidIdentityEvidence)
        XCTAssertEqual(malformedLaterID.nativeSessionID, "child")
    }

    func testLiteralFilesystemRootIsObservedForClaudeAndCodexPublication_repro() {
        let claude = project([
            ["type": "assistant", "sessionId": "native", "cwd": "/",
             "message": ["model": "claude-sonnet-4", "content": "answer"]],
        ], format: .claudeCode(forceClaudeCodeSource: false), locator: "/tmp/claude.jsonl")
        XCTAssertEqual(claude.cwd, "/")
        XCTAssertFalse(claude.hasInvalidRootEvidence)

        let codex = project([
            ["type": "session_meta", "payload": ["id": "native", "cwd": "/"]],
            codexMessage,
        ], format: .codex, locator: "/tmp/codex.jsonl")
        XCTAssertEqual(codex.cwd, "/")
        XCTAssertFalse(codex.hasInvalidRootEvidence)

        let qwen = project([
            ["type": "user", "sessionId": "native", "cwd": "/"],
        ], format: .qwen, locator: "/tmp/qwen.jsonl")
        XCTAssertTrue(qwen.hasInvalidRootEvidence)
    }

    /// Exact UTF-8 repeats of the first accepted root skip re-normalization only.
    /// Later different/invalid roots and every consume identity/source check still run.
    func testObserveRootRepeatsExactFirstRootThenKeepsLaterConflictAndInvalid_repro() {
        let locator = "/tmp/observe-root.jsonl"
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)

        let repeated = project([
            ["type": "user", "sessionId": "native", "cwd": "/allowed", "message": ["content": "q"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "b"]],
        ], format: format, locator: locator)
        XCTAssertEqual(repeated.cwd, "/allowed")
        XCTAssertFalse(repeated.hasConflictingRoots)
        XCTAssertFalse(repeated.hasInvalidRootEvidence)
        XCTAssertFalse(repeated.hasConflictingIdentities)
        XCTAssertFalse(repeated.hasConflictingSources)

        let identityAfterRepeat = project([
            ["type": "user", "sessionId": "native", "cwd": "/allowed", "message": ["content": "q"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "a"]],
            ["type": "assistant", "sessionId": "other", "cwd": "/allowed",
             "message": ["model": "MiniMax-M2.1", "content": "b"]],
        ], format: format, locator: locator)
        XCTAssertEqual(identityAfterRepeat.cwd, "/allowed")
        XCTAssertFalse(identityAfterRepeat.hasConflictingRoots)
        XCTAssertTrue(identityAfterRepeat.hasConflictingIdentities)
        XCTAssertTrue(identityAfterRepeat.hasConflictingSources)

        let conflictAfterRepeat = project([
            ["type": "user", "sessionId": "native", "cwd": "/allowed", "message": ["content": "q"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/other",
             "message": ["model": "claude-sonnet-4", "content": "b"]],
        ], format: format, locator: locator)
        XCTAssertEqual(conflictAfterRepeat.cwd, "/allowed")
        XCTAssertTrue(conflictAfterRepeat.hasConflictingRoots)
        XCTAssertFalse(conflictAfterRepeat.hasInvalidRootEvidence)

        let invalidAfterRepeat = project([
            ["type": "user", "sessionId": "native", "cwd": "/allowed", "message": ["content": "q"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "relative",
             "message": ["model": "claude-sonnet-4", "content": "b"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "c"]],
        ], format: format, locator: locator)
        XCTAssertEqual(invalidAfterRepeat.cwd, "/allowed")
        XCTAssertTrue(invalidAfterRepeat.hasInvalidRootEvidence)
        XCTAssertFalse(invalidAfterRepeat.hasConflictingRoots)

        let invalidFirst = project([
            ["type": "user", "sessionId": "native", "cwd": "relative", "message": ["content": "q"]],
            ["type": "assistant", "sessionId": "native", "cwd": "relative",
             "message": ["model": "claude-sonnet-4", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "b"]],
        ], format: format, locator: locator)
        XCTAssertEqual(invalidFirst.cwd, "relative")
        XCTAssertTrue(invalidFirst.hasInvalidRootEvidence)
        XCTAssertFalse(invalidFirst.hasConflictingRoots)
    }

    /// Exact "<synthetic>" is not a second provider. Selected model/source stay
    /// the first MiniMax observation; a later real Claude model still conflicts.
    func testExactSyntheticMessageModelIsNotIndependentSourceEvidence_repro() {
        let locator = "/tmp/synthetic-source.jsonl"
        let format = SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        XCTAssertEqual(SourceMetadataProjection.claudeSource(model: "<synthetic>", filePath: locator), .claudeCode)
        XCTAssertEqual(SourceMetadataProjection.claudeSource(model: "MiniMax-M2.1", filePath: locator), .minimax)

        let syntheticAfterMinimax = project([
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "MiniMax-M2.1", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "<synthetic>", "content": "b"]],
        ], format: format, locator: locator)
        XCTAssertEqual(syntheticAfterMinimax.model, "MiniMax-M2.1")
        XCTAssertEqual(syntheticAfterMinimax.source, .minimax)
        XCTAssertEqual(syntheticAfterMinimax.cwd, "/allowed")
        XCTAssertEqual(syntheticAfterMinimax.nativeSessionID, "native")
        XCTAssertFalse(syntheticAfterMinimax.hasConflictingSources)
        XCTAssertFalse(syntheticAfterMinimax.hasConflictingIdentities)
        XCTAssertFalse(syntheticAfterMinimax.hasConflictingRoots)

        let claudeAfterSynthetic = project([
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "MiniMax-M2.1", "content": "a"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "<synthetic>", "content": "b"]],
            ["type": "assistant", "sessionId": "native", "cwd": "/allowed",
             "message": ["model": "claude-sonnet-4", "content": "c"]],
        ], format: format, locator: locator)
        XCTAssertEqual(claudeAfterSynthetic.model, "MiniMax-M2.1")
        XCTAssertEqual(claudeAfterSynthetic.source, .minimax)
        XCTAssertTrue(claudeAfterSynthetic.hasConflictingSources)
        XCTAssertFalse(claudeAfterSynthetic.hasConflictingIdentities)
        XCTAssertFalse(claudeAfterSynthetic.hasConflictingRoots)
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

    func testQwenProjectionMatchesNativeTopLevelSelectionAndRemembersConflicts() async throws {
        let objects: [[String: Any]] = [
            ["type": "system", "sessionId": "native-qwen", "cwd": "/ignored", "model": "ignored"],
            ["type": "tool_result", "cwd": "/allowed", "model": "qwen3-coder",
             "timestamp": "2026-09-08T00:00:00Z", "toolCallResult": ["resultDisplay": "tool result"]],
            ["type": "assistant", "sessionId": "different-qwen", "cwd": "/later", "model": "MiniMax-M2.1",
             "message": ["model": "nested-model-must-be-ignored", "parts": [["text": "answer"]]]],
        ]
        let url = try fixture(objects)
        let info = try success(await QwenAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .qwen, locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.model, info.model)
        XCTAssertEqual(projection.source, .qwen)
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.cwd, "/allowed")
        XCTAssertEqual(projection.model, "qwen3-coder")
        XCTAssertTrue(projection.hasConflictingRoots)
        XCTAssertTrue(projection.hasConflictingIdentities)
        XCTAssertFalse(projection.hasConflictingSources, "Qwen models must not trigger Claude-derived relabeling")
    }

    func testQoderProjectionMatchesNativeRecognizedIdentityAndEmptyModelSelection() async throws {
        let objects: [[String: Any]] = [
            ["type": "summary", "sessionId": "ignored", "cwd": "/ignored"],
            ["type": "user", "sessionId": "native-qoder", "cwd": "/allowed", "timestamp": "2026-09-08T00:00:00Z",
             "message": ["model": "", "content": "request"]],
            ["type": "assistant", "sessionId": "native-qoder", "cwd": "/allowed",
             "message": ["model": "MiniMax-M2.1", "content": "reply"]],
        ]
        let url = try fixture(objects, directory: "lobsterai-project")
        let info = try success(await QoderAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .qoder, locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.nativeSessionID, "native-qoder")
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.model, info.model)
        XCTAssertEqual(projection.model, "")
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.source, .qoder)
        XCTAssertFalse(projection.hasConflictingIdentities)
        XCTAssertFalse(projection.hasConflictingSources)
    }

    func testIflowProjectionMatchesNativeRecognizedIdentityAndEmptyModelSelection() async throws {
        let objects: [[String: Any]] = [
            ["type": "summary", "sessionId": "ignored", "cwd": "/ignored"],
            ["type": "user", "sessionId": "native-iflow", "cwd": "/allowed", "timestamp": "2026-09-08T00:00:00Z",
             "message": ["model": "", "content": "request"]],
            ["type": "assistant", "sessionId": "native-iflow", "cwd": "/allowed",
             "message": ["model": "MiniMax-M2.1", "content": "reply"]],
        ]
        let url = try fixture(objects, directory: "lobsterai-project")
        let info = try success(await IflowAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .iflow, locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.nativeSessionID, "native-iflow")
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.model, info.model)
        XCTAssertEqual(projection.model, "")
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.source, .iflow)
        XCTAssertFalse(projection.hasConflictingIdentities)
        XCTAssertFalse(projection.hasConflictingSources)
    }

    func testCommandCodeLossySlugDoesNotInventProjectPath_repro() async throws {
        let objects: [[String: Any]] = [["role": "user", "sessionId": "native-command", "content": "request"]]
        let url = try fixture(objects, directory: "users-bing-code-project")
        let info = try success(await CommandCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .commandcode, locator: url.path)
        XCTAssertNil(projection.cwd)
        XCTAssertEqual(info.cwd, "")
        XCTAssertEqual(info.id, "native-command")
        XCTAssertFalse(projection.hasInvalidRootEvidence)
    }

    func testCommandCodeProjectionUsesSlugOnlyWithoutExplicitRecognizedCwd() async throws {
        let opening: [[String: Any]] = [
            ["role": "system", "sessionId": "ignored", "cwd": "/ignored"],
            ["role": "user", "sessionId": "native-command", "content": "request", "timestamp": "2026-09-08T00:00:00Z"],
        ]
        for explicit in [false, true] {
            var objects = opening
            var reply: [String: Any] = ["role": "assistant", "sessionId": "native-command", "model": "",
                "metadata": ["model": "ignored-nested"], "content": "reply"]
            if explicit { reply["cwd"] = "/explicit-project" }
            objects.append(reply)
            let url = try fixture(objects, directory: "-Users-test-my--project")
            let info = try success(await CommandCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
            let projection = project(objects, format: .commandcode, locator: url.path)
            XCTAssertEqual(projection.nativeSessionID, info.id)
            XCTAssertEqual(projection.cwd, info.cwd)
            XCTAssertEqual(projection.cwd, explicit ? "/explicit-project" : "/Users/test/my-project")
            XCTAssertEqual(projection.model, info.model)
            XCTAssertEqual(projection.model, "")
            XCTAssertEqual(projection.source, info.source)
            XCTAssertFalse(projection.hasConflictingRoots)
            XCTAssertFalse(projection.hasConflictingIdentities)
        }
    }

    func testCommandCodeProjectionKeepsFirstExplicitCwdAndFlagsLaterConflict() async throws {
        let objects: [[String: Any]] = [
            ["role": "user", "sessionId": "native-command", "cwd": "/first", "content": "request", "timestamp": "2026-09-08T00:00:00Z"],
            ["role": "assistant", "sessionId": "native-command", "cwd": "/second", "content": "reply"],
        ]
        let url = try fixture(objects, directory: "-Users-test-my--project")
        let info = try success(await CommandCodeAdapter(projectsRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .commandcode, locator: url.path)
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.cwd, "/first")
        XCTAssertTrue(projection.hasConflictingRoots)
    }

    /// Metadata inputs belong to a store. Transcript-only / no-store supplies
    /// neither input and stays native empty. Upload eligibility is not asserted:
    /// only default Claude has an explicit multi-root allowance.
    func testCursorModernMetadataHexFirstDoesNotUTF8FallbackAfterNonObjectHex() throws {
        let hexObject = hexUTF8(try jsonText([
            "cwd": "/hex-root",
            "name": "Hex title",
            "createdAt": 1_700_000_000_000,
        ]))
        let hex = SourceMetadataProjection.cursorModernMetadata(storedText: hexObject, liveText: nil)
        XCTAssertEqual(hex.cwd, "/hex-root")
        XCTAssertEqual(hex.metadata["name"] as? String, "Hex title")
        XCTAssertEqual(hex.observedRawCWDs, ["/hex-root"])
        XCTAssertFalse(hex.hasInvalidRootEvidence)
        XCTAssertFalse(hex.hasMalformedMetadata)

        let hexQuotedObject = hexUTF8("\"{\\\"cwd\\\":\\\"/quoted-object\\\"}\"")
        let quoted = SourceMetadataProjection.cursorModernMetadata(storedText: hexQuotedObject, liveText: nil)
        XCTAssertEqual(quoted.cwd, "")
        XCTAssertTrue(quoted.metadata.isEmpty)
        XCTAssertEqual(quoted.observedRawCWDs, [])
        XCTAssertTrue(quoted.hasMalformedMetadata)
        XCTAssertFalse(quoted.hasInvalidRootEvidence)

        let hexArray = hexUTF8("[{\"cwd\":\"/array-root\"}]")
        let array = SourceMetadataProjection.cursorModernMetadata(storedText: hexArray, liveText: nil)
        XCTAssertEqual(array.cwd, "")
        XCTAssertTrue(array.metadata.isEmpty)
        XCTAssertEqual(array.observedRawCWDs, [])
        XCTAssertTrue(array.hasMalformedMetadata)
    }

    func testCursorModernMetadataAcceptsPlainUTF8StoredAndObjectOnlyLive() throws {
        let utf8Stored = try jsonText(["cwd": "/utf8-root", "name": "UTF8 title"])
        let utf8 = SourceMetadataProjection.cursorModernMetadata(storedText: utf8Stored, liveText: nil)
        XCTAssertEqual(utf8.cwd, "/utf8-root")
        XCTAssertEqual(utf8.metadata["name"] as? String, "UTF8 title")
        XCTAssertEqual(utf8.observedRawCWDs, ["/utf8-root"])
        XCTAssertFalse(utf8.hasMalformedMetadata)

        let liveObject = try jsonText(["cwd": "/live-root", "name": "Live title"])
        let overlaid = SourceMetadataProjection.cursorModernMetadata(storedText: utf8Stored, liveText: liveObject)
        XCTAssertEqual(overlaid.cwd, "/live-root")
        XCTAssertEqual(overlaid.metadata["name"] as? String, "Live title")
        XCTAssertEqual(overlaid.observedRawCWDs, ["/utf8-root", "/live-root"])
        XCTAssertFalse(overlaid.hasMalformedMetadata)

        for live in ["[{\"cwd\":\"/array-live\"}]", "\"{\\\"cwd\\\":\\\"/quoted-live\\\"}\"", "{", ""] {
            let badLive = SourceMetadataProjection.cursorModernMetadata(storedText: utf8Stored, liveText: live)
            XCTAssertEqual(badLive.cwd, "/utf8-root")
            XCTAssertEqual(badLive.metadata["name"] as? String, "UTF8 title")
            XCTAssertEqual(badLive.observedRawCWDs, ["/utf8-root"])
            XCTAssertTrue(badLive.hasMalformedMetadata)
        }

        let oddHex = SourceMetadataProjection.cursorModernMetadata(storedText: "7b1", liveText: nil)
        XCTAssertTrue(oddHex.hasMalformedMetadata)
        XCTAssertTrue(oddHex.metadata.isEmpty)
        XCTAssertEqual(oddHex.cwd, "")
    }

    func testCursorModernMetadataOverlayPreservesNativeContentAndEffectiveCwd() throws {
        let stored = try jsonText([
            "cwd": "/store",
            "name": "Store title that must lose",
            "latestConversationSummary": ["summary": ["summary": "STORE digest that must lose"]],
        ])
        let emptyCWD = SourceMetadataProjection.cursorModernMetadata(
            storedText: stored,
            liveText: try jsonText([
                "cwd": "",
                "name": "Live overlay title",
                "latestConversationSummary": ["summary": ["summary": ""]],
            ])
        )
        XCTAssertEqual(emptyCWD.cwd, "")
        XCTAssertEqual(emptyCWD.metadata["cwd"] as? String, "")
        XCTAssertEqual(emptyCWD.metadata["name"] as? String, "Live overlay title")
        XCTAssertEqual(summaryText(emptyCWD.metadata), "")
        XCTAssertEqual(emptyCWD.observedRawCWDs, ["/store", ""])
        XCTAssertFalse(emptyCWD.hasInvalidRootEvidence)
        XCTAssertFalse(emptyCWD.hasMalformedMetadata)

        let nullCWD = SourceMetadataProjection.cursorModernMetadata(
            storedText: stored,
            liveText: "{\"cwd\":null,\"name\":\"Null overlay\"}"
        )
        XCTAssertEqual(nullCWD.cwd, "")
        XCTAssertTrue(nullCWD.metadata["cwd"] is NSNull)
        XCTAssertEqual(nullCWD.metadata["name"] as? String, "Null overlay")
        XCTAssertEqual(nullCWD.observedRawCWDs, ["/store"])
        XCTAssertTrue(nullCWD.hasInvalidRootEvidence)

        let typed = SourceMetadataProjection.cursorModernMetadata(
            storedText: stored,
            liveText: try jsonText(["cwd": 1, "name": "Typed overlay"])
        )
        XCTAssertEqual(typed.cwd, "")
        XCTAssertFalse(typed.metadata["cwd"] is String)
        XCTAssertEqual(typed.metadata["name"] as? String, "Typed overlay")
        XCTAssertEqual(typed.observedRawCWDs, ["/store"])
        XCTAssertTrue(typed.hasInvalidRootEvidence)

        let missingLiveCWD = SourceMetadataProjection.cursorModernMetadata(
            storedText: stored,
            liveText: try jsonText(["name": "Live name only"])
        )
        XCTAssertEqual(missingLiveCWD.cwd, "/store")
        XCTAssertEqual(missingLiveCWD.metadata["cwd"] as? String, "/store")
        XCTAssertEqual(missingLiveCWD.metadata["name"] as? String, "Live name only")
        XCTAssertEqual(summaryText(missingLiveCWD.metadata), "STORE digest that must lose")
        XCTAssertEqual(missingLiveCWD.observedRawCWDs, ["/store"])

        let padded = SourceMetadataProjection.cursorModernMetadata(
            storedText: try jsonText(["cwd": "  /padded  "]),
            liveText: nil
        )
        XCTAssertEqual(padded.cwd, "/padded")
        XCTAssertEqual(padded.observedRawCWDs, ["  /padded  "])
    }

    func testCursorModernMetadataObservedRawCWDsStayByteDistinctAndConservative() throws {
        let absent = SourceMetadataProjection.cursorModernMetadata(storedText: nil, liveText: nil)
        XCTAssertTrue(absent.metadata.isEmpty)
        XCTAssertEqual(absent.cwd, "")
        XCTAssertEqual(absent.observedRawCWDs, [])
        XCTAssertFalse(absent.hasInvalidRootEvidence)
        XCTAssertFalse(absent.hasMalformedMetadata)

        let emptyStored = SourceMetadataProjection.cursorModernMetadata(storedText: "", liveText: nil)
        XCTAssertTrue(emptyStored.hasMalformedMetadata)
        XCTAssertTrue(emptyStored.metadata.isEmpty)

        let same = SourceMetadataProjection.cursorModernMetadata(
            storedText: try jsonText(["cwd": "/same"]),
            liveText: try jsonText(["cwd": "/same"])
        )
        XCTAssertEqual(same.cwd, "/same")
        XCTAssertEqual(same.observedRawCWDs, ["/same"])

        let both = SourceMetadataProjection.cursorModernMetadata(
            storedText: try jsonText(["cwd": "/store"]),
            liveText: try jsonText(["cwd": "/live"])
        )
        XCTAssertEqual(both.cwd, "/live")
        XCTAssertEqual(both.observedRawCWDs, ["/store", "/live"])
        XCTAssertFalse(both.hasInvalidRootEvidence)
        XCTAssertFalse(both.hasMalformedMetadata)

        let spellings = ["/caf\u{00e9}", "/cafe\u{0301}"]
        let unicode = SourceMetadataProjection.cursorModernMetadata(
            storedText: try jsonText(["cwd": spellings[0]]),
            liveText: try jsonText(["cwd": spellings[1]])
        )
        XCTAssertEqual(unicode.observedRawCWDs.count, 2)
        XCTAssertEqual(unicode.observedRawCWDs.map { Data($0.utf8) }, spellings.map { Data($0.utf8) })

        let storedType = SourceMetadataProjection.cursorModernMetadata(
            storedText: try jsonText(["cwd": ["path": "/nested"]]),
            liveText: try jsonText(["cwd": "/live"])
        )
        XCTAssertEqual(storedType.cwd, "/live")
        XCTAssertEqual(storedType.observedRawCWDs, ["/live"])
        XCTAssertTrue(storedType.hasInvalidRootEvidence)

        let badStoredGoodLive = SourceMetadataProjection.cursorModernMetadata(
            storedText: "[{\"cwd\":\"/array-root\"}]",
            liveText: try jsonText(["cwd": "/live"])
        )
        XCTAssertEqual(badStoredGoodLive.cwd, "/live")
        XCTAssertEqual(badStoredGoodLive.metadata["cwd"] as? String, "/live")
        XCTAssertEqual(badStoredGoodLive.observedRawCWDs, ["/live"])
        XCTAssertTrue(badStoredGoodLive.hasMalformedMetadata)
    }

    func testClineArrayReaderAcceptsArbitraryChunkSplitsThroughNestedEscapesAndUTF8() throws {
        let payload = Data(#"[{"say":"task","ts":1,"text":"caf\u00e9\\\"end","nested":{"arr":[{"k":"值"}]}},{"say":"text","ts":2}]"#.utf8)
        XCTAssertEqual(try clineRecords([Data("[]".utf8)]).count, 0)
        for split in 0...payload.count {
            let records = try clineRecords([Data(payload.prefix(split)), Data(payload.suffix(from: split))])
            XCTAssertEqual(records.count, 2, "split \(split)")
            XCTAssertEqual(records[0]["say"] as? String, "task")
            XCTAssertEqual(records[0]["text"] as? String, "café\\\"end")
            let nested = try XCTUnwrap(records[0]["nested"] as? [String: Any])
            let arr = try XCTUnwrap(nested["arr"] as? [Any])
            let item = try XCTUnwrap(arr.first as? [String: Any])
            XCTAssertEqual(item["k"] as? String, "值")
            XCTAssertEqual(records[1]["say"] as? String, "text")
        }
    }

    func testClineArrayReaderRejectsMalformedArraysScalarsTrailingCommasAndJunk() {
        for (raw, name) in [
            ("{}", "object instead of array"),
            ("x[]", "junk before array"),
            ("[1]", "number member"),
            ("[true]", "bool member"),
            ("[null]", "null member"),
            (#"["x"]"#, "string member"),
            ("[{},]", "trailing comma"),
            ("[,{}]", "leading comma"),
            ("[{}]x", "junk after array"),
            ("[]x", "junk after empty array"),
            ("[{]", "unbalanced object"),
            ("[}", "closer without object"),
            (#"[{"a":"}]"#, "unterminated string"),
            ("[{}", "unclosed array"),
        ] as [(String, String)] {
            XCTAssertThrowsError(try clineRecords([Data(raw.utf8)]), name) {
                XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .malformed, name)
            }
        }
        XCTAssertThrowsError(try {
            var reader = SourceMetadataProjection.ClineArrayReader(maximumRecordBytes: 64, maximumRecords: 8)
            try reader.finish()
        }()) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .malformed)
        }
    }

    func testClineArrayReaderEnforcesRecordByteCountAndDepthLimits() {
        XCTAssertThrowsError(try clineRecords([Data("[]".utf8)], maximumRecordBytes: 0, maximumRecords: 8)) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .limitsExceeded)
        }
        XCTAssertThrowsError(try clineRecords([Data("[]".utf8)], maximumRecordBytes: 8, maximumRecords: 0)) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .limitsExceeded)
        }
        XCTAssertThrowsError(try clineRecords([Data("[{\"a\":1},{\"a\":2}]".utf8)], maximumRecordBytes: 64, maximumRecords: 1)) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .limitsExceeded)
        }
        XCTAssertThrowsError(try clineRecords([Data("[{\"ab\":1}]".utf8)], maximumRecordBytes: 2, maximumRecords: 8)) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .limitsExceeded)
        }
        var deep = Data(#"[{"nested":"#.utf8)
        deep.append(contentsOf: repeatElement(UInt8(91), count: 128))
        XCTAssertThrowsError(try clineRecords([deep])) {
            XCTAssertEqual($0 as? SourceMetadataProjection.ClineArrayError, .limitsExceeded)
        }
        var allowed = Data(#"[{"nested":"#.utf8)
        allowed.append(contentsOf: repeatElement(UInt8(91), count: 127))
        allowed.append(contentsOf: Data("0".utf8))
        allowed.append(contentsOf: repeatElement(UInt8(93), count: 127))
        allowed.append(contentsOf: Data("}]".utf8))
        XCTAssertEqual(try clineRecords([allowed]).count, 1)
    }

    func testClineProjectionMatchesNativeTaskIdentityCwdAndModel() async throws {
        let request = #"{"request":"Current Working Directory (/allowed) Files listed"}"#
        let objects: [[String: Any]] = [
            ["say": "task", "ts": 1_704_067_200_000, "text": "hello"],
            ["say": "api_req_started", "ts": 1_704_067_200_100, "text": request],
            ["say": "text", "ts": 1_704_067_200_200, "text": "answer", "modelInfo": ["modelId": "cline-model"]],
        ]
        let url = try clineArrayFixture(objects, task: "native-task")
        let info = try success(await ClineAdapter(tasksRoot: root.path).parseSessionInfo(locator: url.path))
        let projection = project(objects, format: .cline, locator: url.path)
        XCTAssertEqual(projection.nativeSessionID, info.id)
        XCTAssertEqual(projection.nativeSessionID, "native-task")
        XCTAssertEqual(projection.cwd, info.cwd)
        XCTAssertEqual(projection.cwd, "/allowed")
        XCTAssertEqual(projection.model, info.model)
        XCTAssertEqual(projection.model, "cline-model")
        XCTAssertEqual(projection.source, info.source)
        XCTAssertEqual(projection.source, .cline)
        XCTAssertTrue(projection.sawRecognizedRecord)
        XCTAssertFalse(projection.hasConflictingSources)

        let primary: [[String: Any]] = [
            ["say": "task", "ts": 1, "text": "hello"],
            ["say": "api_req_started", "ts": 2,
             "text": #"{"request":"Current Working Directory (Primary: /hidden) Files"}"#],
        ]
        let primaryURL = try clineArrayFixture(primary, task: "primary-task")
        let primaryInfo = try success(await ClineAdapter(tasksRoot: root.path).parseSessionInfo(locator: primaryURL.path))
        let primaryProjection = project(primary, format: .cline, locator: primaryURL.path)
        XCTAssertEqual(primaryProjection.cwd, primaryInfo.cwd)
        XCTAssertEqual(primaryProjection.cwd, "")
        XCTAssertTrue(primaryProjection.hasInvalidRootEvidence)
    }

    private var codexMessage: [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "answer"]]]]
    }

    private func project(_ objects: [[String: Any]], format: SourceMetadataProjection.Format, locator: String) -> SourceMetadataProjection {
        var projection = SourceMetadataProjection(format: format, locator: locator)
        for object in objects { projection.consume(object) }
        return projection
    }

    private func clineRecords(
        _ chunks: [Data],
        maximumRecordBytes: Int = 4_096,
        maximumRecords: Int = 64
    ) throws -> [[String: Any]] {
        var reader = SourceMetadataProjection.ClineArrayReader(
            maximumRecordBytes: maximumRecordBytes,
            maximumRecords: maximumRecords
        )
        var records: [[String: Any]] = []
        for chunk in chunks {
            try reader.consume(chunk) { records.append($0) }
        }
        try reader.finish()
        return records
    }

    private func clineArrayFixture(_ objects: [[String: Any]], task: String) throws -> URL {
        let url = root.appendingPathComponent(task).appendingPathComponent("ui_messages.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]).write(to: url)
        return url
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

    private func jsonText(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func hexUTF8(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    private func summaryText(_ metadata: [String: Any]) -> String? {
        let container = metadata["latestConversationSummary"] as? [String: Any]
        let nested = container?["summary"] as? [String: Any]
        return nested?["summary"] as? String ?? container?["summary"] as? String
    }
}
