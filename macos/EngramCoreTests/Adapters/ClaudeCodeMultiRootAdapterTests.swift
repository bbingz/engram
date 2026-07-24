import Foundation
import XCTest
@testable import EngramCoreRead

final class ClaudeCodeMultiRootAdapterTests: XCTestCase {
    private var fixtureRoot: URL!
    private var homeDirectory: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-claude-multi-root-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = fixtureRoot.appendingPathComponent("home", isDirectory: true)
        settingsURL = homeDirectory.appendingPathComponent(".engram/settings.json")
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        homeDirectory = nil
        settingsURL = nil
        try super.tearDownWithError()
    }

    func testListingMergesRootsAndCanonicalizesDuplicateRootsAndLocators() async throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let automaticOne = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-api-one"))
        let automaticTwo = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-api-two"))
        let customRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("custom-profile"))
        let duplicateParent = fixtureRoot.appendingPathComponent("automatic-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateParent, withIntermediateDirectories: true)
        let duplicateRoot = duplicateParent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: duplicateRoot, withDestinationURL: automaticOne)
        try writeSettings(autoDiscover: true, customProjectsRoots: [customRoot.path, duplicateRoot.path])

        let defaultFile = try makeTranscript(root: defaultRoot, project: "-Users-default", name: "default")
        let automaticFile = try makeTranscript(root: automaticOne, project: "-Users-api-one", name: "api-one")
        let subagentFile = try makeTranscript(
            root: automaticTwo,
            project: "-Users-api-two",
            name: "agent",
            subagentSession: "parent-session"
        )
        let customFile = try makeTranscript(root: customRoot, project: "-Users-custom", name: "custom")
        try FileManager.default.createSymbolicLink(
            at: defaultFile.deletingLastPathComponent().appendingPathComponent("default-alias.jsonl"),
            withDestinationURL: defaultFile
        )

        let adapter = ClaudeCodeAdapter(profileResolver: makeResolver())
        let locators = try await adapter.listSessionLocators()
        let expected = [defaultFile, automaticFile, subagentFile, customFile]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()

        XCTAssertEqual(locators, expected)
        XCTAssertEqual(Set(locators).count, locators.count)
    }

    func testNonDefaultProfilesForceClaudeSourceWhileDefaultKeepsDerivedSources() async throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let automaticRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-minimax-api"))
        let defaultMiniMax = try makeTranscript(
            root: defaultRoot,
            project: "-Users-default",
            name: "minimax",
            model: "MiniMax-M2.1"
        )
        let defaultLobster = try makeTranscript(
            root: defaultRoot,
            project: "lobsterai-workspace",
            name: "lobster",
            model: "claude-sonnet-4"
        )
        let automaticMiniMax = try makeTranscript(
            root: automaticRoot,
            project: "-Users-automatic",
            name: "minimax",
            model: "MiniMax-M2.1"
        )

        let adapter = ClaudeCodeAdapter(profileResolver: makeResolver())
        let defaultMiniMaxInfo = try success(await adapter.parseSessionInfo(locator: defaultMiniMax.path))
        let defaultLobsterInfo = try success(await adapter.parseSessionInfo(locator: defaultLobster.path))
        let automaticInfo = try success(await adapter.parseSessionInfo(locator: automaticMiniMax.path))

        XCTAssertEqual(defaultMiniMaxInfo.source, .minimax)
        XCTAssertNil(defaultMiniMaxInfo.originator)
        XCTAssertEqual(defaultLobsterInfo.source, .lobsterai)
        XCTAssertNil(defaultLobsterInfo.originator)
        XCTAssertEqual(automaticInfo.source, .claudeCode)
        XCTAssertEqual(automaticInfo.originator, "claude-code")
        XCTAssertEqual(automaticInfo.model, "MiniMax-M2.1")
    }

    func testDerivedEnumerationOnlyUsesDefaultProfile() async throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let automaticRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-api"))
        let defaultMiniMax = try makeTranscript(
            root: defaultRoot,
            project: "-Users-default",
            name: "minimax",
            model: "MiniMax-M2.1"
        )
        _ = try makeTranscript(
            root: automaticRoot,
            project: "-Users-automatic",
            name: "minimax",
            model: "MiniMax-M2.1"
        )
        let defaultLobster = try makeTranscript(
            root: defaultRoot,
            project: "lobsterai-default",
            name: "lobster",
            model: "claude-sonnet-4"
        )
        _ = try makeTranscript(
            root: automaticRoot,
            project: "lobsterai-automatic",
            name: "lobster",
            model: "claude-sonnet-4"
        )
        let base = ClaudeCodeAdapter(profileResolver: makeResolver())

        let minimax = try await ClaudeCodeDerivedSourceAdapter(source: .minimax, base: base)
            .listSessionLocators()
        let lobster = try await ClaudeCodeDerivedSourceAdapter(source: .lobsterai, base: base)
            .listSessionLocators()

        XCTAssertEqual(minimax, [defaultMiniMax.resolvingSymlinksInPath().standardizedFileURL.path])
        XCTAssertEqual(lobster, [defaultLobster.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    func testArchiveDescriptorAndProfileUseLongestContainingRoot() async throws {
        let outerRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("outer"))
        let nestedRoot = try makeProjectsRoot(parent: outerRoot.appendingPathComponent("nested"))
        try writeSettings(autoDiscover: false, customProjectsRoots: [outerRoot.path, nestedRoot.path])
        let nestedFile = try makeTranscript(
            root: nestedRoot,
            project: "-Users-nested",
            name: "nested"
        )
        let adapter = ClaudeCodeAdapter(profileResolver: makeResolver())

        let profile = try XCTUnwrap(adapter.profile(for: nestedFile.path))
        let descriptor = try await adapter.archiveSourceDescriptor(locator: nestedFile.path)

        XCTAssertEqual(
            profile.projectsRoot,
            nestedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertEqual(descriptor.files.first?.replayRelativePath, "-Users-nested/nested.jsonl")
    }

    func testLocatorOutsideResolvedProfilesFailsClosed() async throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        _ = try makeTranscript(root: defaultRoot, project: "-Users-default", name: "inside")
        let outsideRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("outside"))
        let outsideFile = try makeTranscript(root: outsideRoot, project: "-Users-outside", name: "outside")
        let adapter = ClaudeCodeAdapter(profileResolver: makeResolver())
        let parseFailure = try failure(await adapter.parseSessionInfo(locator: outsideFile.path))
        let scanFailure = try failure(await adapter.scanForIndexing(locator: outsideFile.path))

        XCTAssertNil(adapter.profile(for: outsideFile.path))
        XCTAssertEqual(parseFailure, .unsupportedVirtualLocator)
        XCTAssertEqual(scanFailure, .unsupportedVirtualLocator)
        do {
            _ = try await adapter.archiveSourceDescriptor(locator: outsideFile.path)
            XCTFail("expected an outside-root descriptor failure")
        } catch let error as ArchiveSourceDescriptorError {
            guard case .pathOutsideRoot = error else {
                return XCTFail("unexpected descriptor failure: \(error)")
            }
        }
    }

    func testSettingsChangesApplyOnNextListing() async throws {
        let defaultRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let automaticRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-api"))
        let customRoot = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("custom"))
        let defaultFile = try makeTranscript(root: defaultRoot, project: "-Users-default", name: "default")
        let automaticFile = try makeTranscript(root: automaticRoot, project: "-Users-auto", name: "automatic")
        let customFile = try makeTranscript(root: customRoot, project: "-Users-custom", name: "custom")
        try writeSettings(autoDiscover: false, customProjectsRoots: [])
        let adapter = ClaudeCodeAdapter(profileResolver: makeResolver())

        let initialLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(initialLocators, [defaultFile.path])

        try writeSettings(autoDiscover: true, customProjectsRoots: [customRoot.path])

        let automaticBeforeListing = try failure(
            await adapter.parseSessionInfo(locator: automaticFile.path)
        )
        XCTAssertEqual(
            automaticBeforeListing,
            .unsupportedVirtualLocator,
            "settings changes must not alter the immutable snapshot before the next listing"
        )
        let customBeforeListing = try failure(
            await adapter.parseSessionInfo(locator: customFile.path)
        )
        XCTAssertEqual(
            customBeforeListing,
            .unsupportedVirtualLocator,
            "custom roots must not become addressable until the next listing refresh"
        )
        _ = try success(await adapter.parseSessionInfo(locator: defaultFile.path))

        let updatedLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(updatedLocators, [defaultFile.path, automaticFile.path, customFile.path].sorted())
        _ = try success(await adapter.parseSessionInfo(locator: automaticFile.path))
        _ = try success(await adapter.parseSessionInfo(locator: customFile.path))
    }

    func testProfileResolutionIsBoundToListingAndTailKeepsAutomaticSource() async throws {
        let automaticRoot = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude-api"))
        let locator = try makeTranscript(
            root: automaticRoot,
            project: "-Users-automatic",
            name: "automatic",
            model: "MiniMax-M2.1"
        )
        let profile = ClaudeCodeProfile(
            id: "automatic-test",
            displayName: "Automatic",
            projectsRoot: automaticRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            origin: .automatic,
            available: true,
            sourceReclamationAllowed: false
        )
        let provider = CountingProfileProvider(profiles: [profile])
        let adapter = ClaudeCodeAdapter(profileResolutionProvider: { provider.resolve() })

        XCTAssertEqual(provider.invocationCount, 1, "resolver-backed adapters need one initial snapshot")
        let detected = await adapter.detect()
        XCTAssertTrue(detected)
        XCTAssertNotNil(adapter.profile(for: locator.path))
        _ = try await adapter.archiveSourceDescriptor(locator: locator.path)
        _ = try success(await adapter.parseSessionInfo(locator: locator.path))
        let scan = try success(await adapter.scanForIndexing(locator: locator.path))
        _ = try await adapter.streamMessages(locator: locator.path, options: StreamMessagesOptions())
        _ = try await adapter.streamMessagesWithMetadata(
            locator: locator.path,
            options: StreamMessagesOptions()
        )
        let accessible = await adapter.isAccessible(locator: locator.path)
        XCTAssertTrue(accessible)
        XCTAssertEqual(
            provider.invocationCount,
            1,
            "descriptor, parse, scan, stream, detect, and accessibility must use the current snapshot"
        )

        let parsedOffset = try XCTUnwrap(scan.checkpointParsedOffset)
        let boundaryHash = try XCTUnwrap(scan.checkpointBoundaryHash)
        try appendTranscriptRecord(
            [
                "type": "assistant",
                "sessionId": "session-automatic",
                "timestamp": "2026-07-13T00:00:02Z",
                "message": [
                    "role": "assistant",
                    "model": "MiniMax-M2.1",
                    "content": "tail response",
                ],
            ],
            to: locator
        )
        switch try await adapter.scanTailForIndexing(
            locator: locator.path,
            from: parsedOffset,
            expectedBoundaryHash: boundaryHash
        ) {
        case .success(let tail):
            XCTAssertEqual(tail.infoDelta.source, .claudeCode)
            XCTAssertEqual(tail.messages.map(\.content), ["tail response"])
        case .fallback:
            XCTFail("expected an incremental tail scan")
        case .failure(let failure):
            XCTFail("unexpected tail scan failure: \(failure)")
        }
        XCTAssertEqual(provider.invocationCount, 1, "tail scanning must use the current snapshot")

        _ = try await adapter.listSessionLocators()
        XCTAssertEqual(provider.invocationCount, 2, "base listing refreshes profiles exactly once")
        _ = try await adapter.listSessionLocators(modifiedSince: .distantPast, fileManager: .default)
        XCTAssertEqual(provider.invocationCount, 3, "modified listing refreshes profiles exactly once")
        _ = try await ClaudeCodeDerivedSourceAdapter(source: .minimax, base: adapter)
            .listSessionLocators()
        XCTAssertEqual(provider.invocationCount, 4, "derived listing refreshes profiles exactly once")
    }

    func testLegacyInitializerKeepsSingleRootDerivedClassification() async throws {
        let root = try makeProjectsRoot(parent: fixtureRoot.appendingPathComponent("legacy"))
        let minimaxFile = try makeTranscript(
            root: root,
            project: "-Users-legacy",
            name: "minimax",
            model: "MiniMax-M2.1"
        )
        let lobsterFile = try makeTranscript(
            root: root,
            project: "lobsterai-legacy",
            name: "lobster",
            model: "claude-sonnet-4"
        )
        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)

        let locators = try await adapter.listSessionLocators()
        let minimaxInfo = try success(await adapter.parseSessionInfo(locator: minimaxFile.path))
        let lobsterInfo = try success(await adapter.parseSessionInfo(locator: lobsterFile.path))

        XCTAssertEqual(locators, [lobsterFile.path, minimaxFile.path].sorted())
        XCTAssertEqual(minimaxInfo.source, .minimax)
        XCTAssertEqual(lobsterInfo.source, .lobsterai)
    }

    private func makeResolver() -> ClaudeCodeProfileResolver {
        ClaudeCodeProfileResolver(homeDirectory: homeDirectory, settingsURL: settingsURL)
    }

    @discardableResult
    private func makeProjectsRoot(parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeTranscript(
        root: URL,
        project: String,
        name: String,
        model: String = "claude-sonnet-4",
        subagentSession: String? = nil,
        workflowRun: String? = nil
    ) throws -> URL {
        var directory = root.appendingPathComponent(project, isDirectory: true)
        if let subagentSession {
            directory = directory
                .appendingPathComponent(subagentSession, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            if let workflowRun {
                // Workflow nesting: subagents/workflows/wf_*/agent-*.jsonl (row 32).
                directory = directory
                    .appendingPathComponent("workflows", isDirectory: true)
                    .appendingPathComponent(workflowRun, isDirectory: true)
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Workflow agents must use the agent- filename prefix (listing filter);
        // direct subagents keep the historical `\(name).jsonl` layout.
        let fileName: String
        if workflowRun != nil {
            fileName = name.hasPrefix("agent-") ? "\(name).jsonl" : "agent-\(name).jsonl"
        } else {
            fileName = "\(name).jsonl"
        }
        let file = directory.appendingPathComponent(fileName)
        let agentId: String
        if subagentSession == nil {
            agentId = ""
        } else if name.hasPrefix("agent-") {
            agentId = name
        } else {
            agentId = "agent-\(name)"
        }
        let records: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "session-\(name)",
                "agentId": agentId,
                "cwd": "/Users/test/\(name)",
                "timestamp": "2026-07-13T00:00:00Z",
                "message": ["role": "user", "content": "request \(name)"],
            ],
            [
                "type": "assistant",
                "sessionId": "session-\(name)",
                "agentId": agentId,
                "timestamp": "2026-07-13T00:00:01Z",
                "message": ["role": "assistant", "model": model, "content": "response \(name)"],
            ],
        ]
        let lines = try records.map { record -> String in
            let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // row 32 (claude-workflow-subagents): workflow-nested agent-*.jsonl under
    // subagents/workflows/wf_*/ must be discovered and parent-linked. Fails
    // before the listSessionLocators descent lands.
    func testClaudeWorkflowSubagentsAreDiscovered_repro() async throws {
        let root = try makeProjectsRoot(parent: homeDirectory.appendingPathComponent(".claude"))
        let parentUUID = "11111111-2222-3333-4444-555555555555"
        let project = "-Users-workflow"
        let workflowFile = try makeTranscript(
            root: root,
            project: project,
            name: "worker",
            subagentSession: parentUUID,
            workflowRun: "wf_run1"
        )

        // A3: journal.jsonl control file must not be listed.
        let wfDir = workflowFile.deletingLastPathComponent()
        try " {\"type\":\"started\"}\n".write(
            to: wfDir.appendingPathComponent("journal.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        // A4: session-level workflows/ sibling must not be listed.
        let sessionWorkflows = root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionWorkflows, withIntermediateDirectories: true)
        try "{}\n".write(
            to: sessionWorkflows.appendingPathComponent("wf_a.json"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = ClaudeCodeAdapter(projectsRoot: root.path)
        let locators = try await adapter.listSessionLocators()
        let workflowPath = workflowFile.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertTrue(
            locators.contains(workflowPath),
            "workflow agent-*.jsonl must be discovered under subagents/workflows/wf_*/"
        )
        XCTAssertFalse(
            locators.contains(where: { $0.hasSuffix("/journal.jsonl") }),
            "journal.jsonl control files must not be listed"
        )
        XCTAssertFalse(
            locators.contains(where: { $0.hasSuffix("/wf_a.json") }),
            "session-level workflows/*.json must not be listed"
        )

        let info = try await adapter.parseSessionInfo(locator: workflowPath)
        switch info {
        case .success(let session):
            XCTAssertEqual(session.agentRole, "subagent")
            XCTAssertEqual(session.parentSessionId, parentUUID)
            // Row id is agentId, not the parent UUID.
            XCTAssertEqual(session.id, "agent-worker")
            XCTAssertNotEqual(session.id, parentUUID)
        case .failure(let error):
            XCTFail("parseSessionInfo failed: \(error)")
        }
    }

    private func writeSettings(autoDiscover: Bool, customProjectsRoots: [String]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "claudeCodeProfiles": [
                    "autoDiscover": autoDiscover,
                    "customProjectsRoots": customProjectsRoots,
                ],
            ],
            options: [.sortedKeys]
        )
        try data.write(to: settingsURL)
    }

    private func appendTranscriptRecord(_ record: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func success<T>(_ result: AdapterParseResult<T>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let failure):
            throw failure
        }
    }

    private func failure<T>(_ result: AdapterParseResult<T>) throws -> ParserFailure {
        switch result {
        case .success:
            XCTFail("expected adapter failure")
            throw ParserFailure.malformedJSON
        case .failure(let failure):
            return failure
        }
    }
}

private final class CountingProfileProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let profiles: [ClaudeCodeProfile]
    private var count = 0

    init(profiles: [ClaudeCodeProfile]) {
        self.profiles = profiles
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func resolve() -> [ClaudeCodeProfile] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return profiles
    }
}
