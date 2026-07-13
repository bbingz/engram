import EngramCoreRead
import EngramCoreWrite
import Foundation
import XCTest

@testable import EngramServiceCore

final class ClaudeCodeProfileServiceTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var runtime: URL!
    private var database: URL!
    private var settings: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-profile-service-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        runtime = root.appendingPathComponent("run", isDirectory: true)
        database = root.appendingPathComponent("index.sqlite")
        settings = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testStatusCountsBoundedClaudeLocatorsAndUsesCanonicalRootBoundary() async throws {
        let projectsRoot = home
            .appendingPathComponent(".claude-api", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let project = projectsRoot.appendingPathComponent("project", isDirectory: true)
        let session = project.appendingPathComponent("session.jsonl")
        let subagents = project
            .appendingPathComponent("session-id", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let subagent = subagents.appendingPathComponent("agent.jsonl")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: session)
        try Data("hello".utf8).write(to: subagent)
        try Data("ignored".utf8).write(
            to: subagents.appendingPathComponent("not-jsonl.txt")
        )

        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime
        )
        _ = try await gate.performWriteCommand(name: "profile-test-migrate") { writer in
            try writer.migrate()
            return ()
        }
        _ = try await gate.performWriteCommand(name: "profile-test-seed") { writer in
            try writer.write { db in
                let insert = """
                    INSERT INTO file_index_state(
                        source, locator, size_bytes, mtime_ns, inode, device,
                        parsed_offset, boundary_hash, parse_status, failure_kind,
                        retry_after, retry_count, last_error, schema_version, updated_at
                    ) VALUES (?, ?, 1, 1, 1, 1, 0, NULL, ?, NULL, NULL, 0, NULL, ?, 1)
                    """
                try db.execute(
                    sql: insert,
                    arguments: ["claude-code", session.path, "ok", FileIndexState.currentSchemaVersion]
                )
                try db.execute(
                    sql: insert,
                    arguments: ["claude-code", subagent.path, "terminal", FileIndexState.currentSchemaVersion]
                )
                try db.execute(
                    sql: insert,
                    arguments: ["claude-code", "\(projectsRoot.path)/project/stale.jsonl", "ok", 0]
                )
                try db.execute(
                    sql: insert,
                    arguments: ["minimax", "\(projectsRoot.path)/project/minimax.jsonl", "ok", FileIndexState.currentSchemaVersion]
                )
                try db.execute(
                    sql: insert,
                    arguments: ["claude-code", "\(projectsRoot.path)-other/project/sibling.jsonl", "ok", FileIndexState.currentSchemaVersion]
                )
            }
            return ()
        }

        let service = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(
                homeDirectory: home,
                settingsURL: settings
            ),
            writerGate: gate,
            archiveCatalog: nil,
            settingsURL: settings,
            signalDrainer: {}
        )

        let response = await service.status()

        XCTAssertTrue(response.autoDiscover)
        XCTAssertEqual(response.customProjectsRoots, [])
        XCTAssertNil(response.configurationError)
        XCTAssertEqual(response.profiles.map(\.projectsRoot), [projectsRoot.path])
        let profile = try XCTUnwrap(response.profiles.first)
        XCTAssertEqual(profile.origin, "automatic")
        XCTAssertTrue(profile.available)
        XCTAssertEqual(profile.discoveredFileCount, 2)
        XCTAssertEqual(profile.discoveredSourceBytes, 8)
        XCTAssertEqual(profile.indexedLocatorCount, 1)
        XCTAssertEqual(profile.capturedCount, 0)
        XCTAssertEqual(profile.ignoredEmptyCaptureCount, 0)
        XCTAssertEqual(profile.hqVerifiedCount, 0)
        XCTAssertEqual(profile.m1VerifiedCount, 0)
        XCTAssertNil(profile.error)
    }

    func testStatusCapsProfileRowsAt128InDeterministicRootOrder() async throws {
        for index in 0..<130 {
            let projects = home
                .appendingPathComponent(String(format: ".claude-%03d", index), isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        }
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        _ = try await gate.performWriteCommand(name: "profile-test-migrate") { writer in
            try writer.migrate()
            return ()
        }
        let service = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settings),
            writerGate: gate,
            archiveCatalog: nil,
            settingsURL: settings,
            signalDrainer: {}
        )

        let response = await service.status()

        XCTAssertEqual(response.profiles.count, 128)
        XCTAssertEqual(response.profiles.map(\.projectsRoot), response.profiles.map(\.projectsRoot).sorted())
        XCTAssertTrue(response.profiles.last?.projectsRoot.contains(".claude-127/projects") == true)
    }

    func testStatusReturnsFixedDatabaseUnavailableSymbolWithoutDroppingProfile() async throws {
        let projectsRoot = home
            .appendingPathComponent(".claude-api", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        let service = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settings),
            writerGate: gate,
            archiveCatalog: nil,
            settingsURL: settings,
            signalDrainer: {}
        )

        let response = await service.status()

        XCTAssertEqual(response.profiles.count, 1)
        XCTAssertEqual(response.profiles[0].error, "status_database_unavailable")
        XCTAssertEqual(response.profiles[0].indexedLocatorCount, 0)
    }

    func testConfigureReplacesCompleteProfileSettingsPreservesOtherKeysAndSignals() async throws {
        let first = root.appendingPathComponent("first/projects", isDirectory: true)
        let second = root.appendingPathComponent("second/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "provider": "openai",
            "claudeCodeProfiles": [
                "autoDiscover": true,
                "customProjectsRoots": [first.path],
            ],
        ], options: [.sortedKeys]).write(to: settings)
        let signal = ProfileDrainerSignalProbe()
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        _ = try await gate.performWriteCommand(name: "profile-test-migrate") { writer in
            try writer.migrate()
            return ()
        }
        let service = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settings),
            writerGate: gate,
            archiveCatalog: nil,
            settingsURL: settings,
            signalDrainer: { await signal.record() }
        )

        let response = try await service.configure(
            EngramServiceConfigureClaudeCodeProfilesRequest(
                autoDiscover: false,
                customProjectsRoots: [second.path]
            )
        )

        XCTAssertFalse(response.autoDiscover)
        XCTAssertEqual(response.customProjectsRoots, [second.path])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        XCTAssertEqual(object["provider"] as? String, "openai")
        let saved = try XCTUnwrap(object["claudeCodeProfiles"] as? [String: Any])
        XCTAssertEqual(saved["autoDiscover"] as? Bool, false)
        XCTAssertEqual(saved["customProjectsRoots"] as? [String], [second.path])
        let signalCount = await signal.count
        XCTAssertEqual(signalCount, 1)
    }

    func testConfigureValidationFailureDoesNotWriteOrSignal() async throws {
        let sentinel = Data(#"{"provider":"keep"}"#.utf8)
        try sentinel.write(to: settings)
        let invalidParent = root.appendingPathComponent("not-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidParent, withIntermediateDirectories: true)
        let signal = ProfileDrainerSignalProbe()
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        let service = ClaudeCodeProfileService(
            profileResolver: ClaudeCodeProfileResolver(homeDirectory: home, settingsURL: settings),
            writerGate: gate,
            archiveCatalog: nil,
            settingsURL: settings,
            signalDrainer: { await signal.record() }
        )

        do {
            _ = try await service.configure(
                EngramServiceConfigureClaudeCodeProfilesRequest(
                    autoDiscover: true,
                    customProjectsRoots: [invalidParent.path]
                )
            )
            XCTFail("invalid full replacement unexpectedly succeeded")
        } catch let error as EngramServiceError {
            XCTAssertEqual(error, .invalidRequest(message: "invalid_claude_code_profiles"))
        }

        XCTAssertEqual(try Data(contentsOf: settings), sentinel)
        let signalCount = await signal.count
        XCTAssertEqual(signalCount, 0)
    }
}

private actor ProfileDrainerSignalProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
