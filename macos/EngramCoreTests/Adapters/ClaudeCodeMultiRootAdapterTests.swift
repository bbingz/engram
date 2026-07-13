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

        let updatedLocators = try await adapter.listSessionLocators()
        XCTAssertEqual(updatedLocators, [defaultFile.path, automaticFile.path, customFile.path].sorted())
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
        subagentSession: String? = nil
    ) throws -> URL {
        var directory = root.appendingPathComponent(project, isDirectory: true)
        if let subagentSession {
            directory = directory
                .appendingPathComponent(subagentSession, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).jsonl")
        let records: [[String: Any]] = [
            [
                "type": "user",
                "sessionId": "session-\(name)",
                "agentId": subagentSession == nil ? "" : "agent-\(name)",
                "cwd": "/Users/test/\(name)",
                "timestamp": "2026-07-13T00:00:00Z",
                "message": ["role": "user", "content": "request \(name)"],
            ],
            [
                "type": "assistant",
                "sessionId": "session-\(name)",
                "agentId": subagentSession == nil ? "" : "agent-\(name)",
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
