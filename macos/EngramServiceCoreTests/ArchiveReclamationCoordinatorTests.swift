import Darwin
import EngramCoreRead
import Foundation
import GRDB
import XCTest

@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ArchiveReclamationCoordinatorTests: XCTestCase {
    private let machineID = "11111111-2222-4333-8444-777777777777"
    private let now = ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z")!
    private let nowString = "2026-07-13T00:00:00.000Z"
    private var root: URL!
    private var homeDirectory: URL!
    private var settingsURL: URL!
    private var databaseURL: URL!
    private var productDatabase: DatabaseQueue!
    private var archiveRoot: URL!
    private var catalog: ArchiveCatalog!
    private var cas: ImmutableArchiveCAS!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-reclamation-coordinator-\(UUID().uuidString)", isDirectory: true)
        homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        settingsURL = homeDirectory.appendingPathComponent(".engram/settings.json")
        databaseURL = root.appendingPathComponent("index.sqlite")
        archiveRoot = root.appendingPathComponent("archive-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)

        productDatabase = try DatabaseQueue(path: databaseURL.path)
        try productDatabase.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions(
                  id TEXT PRIMARY KEY,
                  start_time TEXT NOT NULL,
                  end_time TEXT
                )
                """)
            try db.execute(sql: "CREATE TABLE favorites(session_id TEXT PRIMARY KEY)")
        }

        catalog = try ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try catalog.migrate()
        cas = try ImmutableArchiveCAS(root: archiveRoot)
    }

    override func tearDownWithError() throws {
        productDatabase = nil
        catalog = nil
        cas = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    func testSourceReclamationGateUsesResolvedClaudeProfilesAndPreservesCodex() async throws {
        let defaultRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        let automaticRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude-sonnet", isDirectory: true)
        )
        let customRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("custom-profile", isDirectory: true)
        )
        let unknownRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("unknown-profile", isDirectory: true)
        )
        let escapedRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("escaped-profile", isDirectory: true)
        )
        let escapedParent = homeDirectory.appendingPathComponent(".claude-escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: escapedParent.appendingPathComponent("projects", isDirectory: true),
            withDestinationURL: escapedRoot
        )
        try writeSettings(customProjectsRoots: [customRoot.path])

        let coordinator = try makeCoordinator()
        let defaultAllowed = await coordinator.sourceReclamationAllowed(
            locator: defaultRoot.appendingPathComponent("project/default.jsonl").path,
            source: "claude-code"
        )
        let automaticAllowed = await coordinator.sourceReclamationAllowed(
            locator: automaticRoot.appendingPathComponent("project/automatic.jsonl").path,
            source: "claude-code"
        )
        let customAllowed = await coordinator.sourceReclamationAllowed(
            locator: customRoot.appendingPathComponent("project/custom.jsonl").path,
            source: "claude-code"
        )
        let unknownAllowed = await coordinator.sourceReclamationAllowed(
            locator: unknownRoot.appendingPathComponent("project/unknown.jsonl").path,
            source: "claude-code"
        )
        let escapedAllowed = await coordinator.sourceReclamationAllowed(
            locator: escapedRoot.appendingPathComponent("project/escaped.jsonl").path,
            source: "claude-code"
        )
        let codexAllowed = await coordinator.sourceReclamationAllowed(
            locator: unknownRoot.appendingPathComponent("project/codex.jsonl").path,
            source: "codex"
        )

        XCTAssertTrue(defaultAllowed)
        XCTAssertTrue(automaticAllowed)
        XCTAssertFalse(customAllowed)
        XCTAssertFalse(unknownAllowed)
        XCTAssertFalse(escapedAllowed)
        XCTAssertTrue(codexAllowed)
    }

    func testPreviewAndRunReclaimDefaultAutomaticAndCodexButProtectOtherClaudeRoots() async throws {
        let defaultRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        let automaticRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude-sonnet", isDirectory: true)
        )
        let customRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("custom-profile", isDirectory: true)
        )
        let unknownRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("unknown-profile", isDirectory: true)
        )
        let escapedRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("escaped-profile", isDirectory: true)
        )
        let escapedParent = homeDirectory.appendingPathComponent(".claude-escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: escapedParent.appendingPathComponent("projects", isDirectory: true),
            withDestinationURL: escapedRoot
        )
        try writeSettings(customProjectsRoots: [customRoot.path])

        let defaultFixture = try addEligibleBinding(
            seed: "default",
            source: "claude-code",
            projectsRoot: defaultRoot
        )
        let automaticFixture = try addEligibleBinding(
            seed: "automatic",
            source: "claude-code",
            projectsRoot: automaticRoot
        )
        let customFixture = try addEligibleBinding(
            seed: "custom",
            source: "claude-code",
            projectsRoot: customRoot
        )
        let unknownFixture = try addEligibleBinding(
            seed: "unknown",
            source: "claude-code",
            projectsRoot: unknownRoot
        )
        let escapedFixture = try addEligibleBinding(
            seed: "escaped",
            source: "claude-code",
            projectsRoot: escapedRoot
        )
        let codexFixture = try addEligibleBinding(
            seed: "codex",
            source: "codex",
            projectsRoot: root.appendingPathComponent("codex-sessions", isDirectory: true)
        )
        let allFixtures = [
            defaultFixture,
            automaticFixture,
            customFixture,
            unknownFixture,
            escapedFixture,
            codexFixture,
        ]
        try await replicate(allFixtures)
        try recordCurrentRecoveryLeases(manifestSHA256: defaultFixture.binding.manifestSHA256)

        let coordinator = try makeCoordinator()
        let preview = await coordinator.preview(now: now)

        XCTAssertEqual(preview.eligibleCount, 3)
        XCTAssertEqual(preview.blockedCounts["unsupported_source"], 3)
        for fixture in [customFixture, unknownFixture, escapedFixture] {
            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.bytes)
            XCTAssertNil(try catalog.reclamationIntent(manifestSHA256: fixture.binding.manifestSHA256))
        }

        let run = await coordinator.runNow(now: now)

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.sourceFilesReclaimed, 3)
        for fixture in [defaultFixture, automaticFixture, codexFixture] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
            XCTAssertEqual(
                try catalog.reclamationIntent(manifestSHA256: fixture.binding.manifestSHA256)?.phase,
                .sourceDeleted
            )
        }
        for fixture in [customFixture, unknownFixture, escapedFixture] {
            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.bytes)
            XCTAssertNil(try catalog.reclamationIntent(manifestSHA256: fixture.binding.manifestSHA256))
        }
    }

    /// R5: when the source-byte budget binds, cursor must not advance past the
    /// eligible row that was skipped (same fairness as M4 count-cap stop).
    func testReclamationCursorDoesNotSkipBudgetBoundEligibles_repro() async throws {
        try writeSettings(customProjectsRoots: [])
        let projectsRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        // Force a tiny byte budget so only the first ~25-byte source fits.
        ArchiveReclamationCoordinator.testMaximumSourceBytesPerCycle = 40
        defer { ArchiveReclamationCoordinator.testMaximumSourceBytesPerCycle = nil }

        var fixtures: [BindingFixture] = []
        for index in 0..<3 {
            let seed = String(format: "r5-%02d", index)
            fixtures.append(
                try addEligibleBinding(
                    seed: seed,
                    source: "claude-code",
                    projectsRoot: projectsRoot
                )
            )
        }
        try await replicate(fixtures)
        try recordCurrentRecoveryLeases(manifestSHA256: fixtures[0].binding.manifestSHA256)

        let coordinator = try makeCoordinator()
        let first = await coordinator.runNow(now: now)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(
            first.sourceFilesReclaimed,
            1,
            "R5: only the first eligible should fit the tiny byte budget"
        )

        let ordered = fixtures.sorted {
            if $0.binding.boundAt != $1.binding.boundAt {
                return $0.binding.boundAt < $1.binding.boundAt
            }
            return $0.binding.manifestSHA256 < $1.binding.manifestSHA256
        }
        let checkpoint = try XCTUnwrap(
            try catalog.archiveCursorCheckpoint(for: .reclamationCycle),
            "R5: cursor checkpoint must exist after partial budget cycle"
        )
        struct CursorPayload: Codable {
            let boundAt: String
            let manifestSHA256: String
        }
        let payload = try JSONDecoder().decode(CursorPayload.self, from: checkpoint.payload)
        XCTAssertEqual(
            payload.manifestSHA256,
            ordered[0].binding.manifestSHA256,
            "R5: cursor stays on last reclaimed eligible, not past budget-skipped ones"
        )
        XCTAssertNotEqual(
            payload.manifestSHA256,
            ordered[1].binding.manifestSHA256,
            "R5: must not advance past the budget-skipped eligible"
        )

        // Full budget restored for next cycle (via defer already reset at end —
        // re-set high budget explicitly for second run).
        ArchiveReclamationCoordinator.testMaximumSourceBytesPerCycle = nil
        let second = await coordinator.runNow(now: now)
        XCTAssertTrue(second.accepted)
        XCTAssertGreaterThanOrEqual(
            second.sourceFilesReclaimed,
            2,
            "R5: budget-skipped eligibles must reclaim on the next cycle"
        )
    }

    /// M4: after reclaiming the per-cycle cap, cursor advances only past examined
    /// candidates — remaining eligible sessions stay available for the next cycle
    /// without waiting for a full catalog wrap.
    func testReclamationCursorAdvancesOnlyPastProcessedCandidates_repro() async throws {
        try writeSettings(customProjectsRoots: [])
        let projectsRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        // Cap is 10 reclaims/cycle; create 15 eligible so the first cycle must
        // leave 5 unprocessed.
        var fixtures: [BindingFixture] = []
        for index in 0..<15 {
            let seed = String(format: "m4-%02d", index)
            fixtures.append(
                try addEligibleBinding(
                    seed: seed,
                    source: "claude-code",
                    projectsRoot: projectsRoot
                )
            )
        }
        try await replicate(fixtures)
        try recordCurrentRecoveryLeases(manifestSHA256: fixtures[0].binding.manifestSHA256)

        let coordinator = try makeCoordinator()
        let first = await coordinator.runNow(now: now)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.sourceFilesReclaimed, 10)

        let ordered = fixtures.sorted {
            if $0.binding.boundAt != $1.binding.boundAt {
                return $0.binding.boundAt < $1.binding.boundAt
            }
            return $0.binding.manifestSHA256 < $1.binding.manifestSHA256
        }
        let expectedCursor = ordered[9].binding // 10th examined+reclaimed
        let checkpoint = try XCTUnwrap(
            try catalog.archiveCursorCheckpoint(for: .reclamationCycle),
            "M4: cursor checkpoint must be stored after a reclaim cycle"
        )
        struct CursorPayload: Codable {
            let boundAt: String
            let manifestSHA256: String
        }
        let payload = try JSONDecoder().decode(CursorPayload.self, from: checkpoint.payload)
        XCTAssertEqual(
            payload.boundAt,
            expectedCursor.boundAt,
            "M4: cursor boundAt must match last processed candidate"
        )
        XCTAssertEqual(
            payload.manifestSHA256,
            expectedCursor.manifestSHA256,
            "M4: cursor must not jump past unprocessed eligible candidates (was page.last)"
        )
        XCTAssertNotEqual(
            payload.manifestSHA256,
            ordered[14].binding.manifestSHA256,
            "M4: must not advance past the full page last item"
        )

        let second = await coordinator.runNow(now: now)
        XCTAssertTrue(second.accepted)
        XCTAssertEqual(
            second.sourceFilesReclaimed,
            5,
            "M4: remaining eligible sessions must reclaim on the next cycle without full wrap"
        )
    }

    func testClaudeProfileGateDoesNotChangeCASEvictionEligibility() async throws {
        let customRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("custom-profile", isDirectory: true)
        )
        try writeSettings(customProjectsRoots: [customRoot.path])
        let fixture = try addEligibleBinding(
            seed: "custom-cas",
            source: "claude-code",
            projectsRoot: customRoot
        )
        try await replicate([fixture])
        try recordCurrentRecoveryLeases(manifestSHA256: fixture.binding.manifestSHA256)
        try markSourceDeleted(fixture)

        let coordinator = try makeCoordinator()
        let run = await coordinator.runNow(now: now)

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.sourceFilesReclaimed, 0)
        XCTAssertEqual(run.casObjectsEvicted, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.bytes)
        XCTAssertEqual(
            try catalog.localObject(objectSHA256: fixture.objectSHA256)?.residency,
            .evicted
        )
        XCTAssertEqual(
            try catalog.reclamationIntent(manifestSHA256: fixture.binding.manifestSHA256)?.phase,
            .localContentEvicted
        )
    }

    func testRunDoesNotResumeLegacySourceIntentForProtectedClaudeRoot() async throws {
        let customRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("custom-profile", isDirectory: true)
        )
        try writeSettings(customProjectsRoots: [customRoot.path])
        let fixture = try addEligibleBinding(
            seed: "custom-recovery",
            source: "claude-code",
            projectsRoot: customRoot
        )
        try await replicate([fixture])
        try recordCurrentRecoveryLeases(manifestSHA256: fixture.binding.manifestSHA256)
        let intent = try catalog.upsertReclamationIntent(
            manifestSHA256: fixture.binding.manifestSHA256,
            captureID: fixture.capture.captureID,
            sessionID: fixture.binding.sessionID,
            locator: fixture.capture.locator,
            updatedAt: "2026-07-12T23:59:00.000Z"
        )
        XCTAssertTrue(try catalog.transitionReclamationIntent(
            manifestSHA256: intent.manifestSHA256,
            from: .eligible,
            to: .quarantinePlanned,
            expectedClaimGeneration: intent.claimGeneration,
            quarantinePath: fixture.sourceURL.deletingLastPathComponent()
                .appendingPathComponent(".engram-reclaim-legacy-test")
                .path,
            updatedAt: nowString
        ))

        let coordinator = try makeCoordinator()
        let run = await coordinator.runNow(now: now)

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.sourceFilesReclaimed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(
            try catalog.reclamationIntent(manifestSHA256: fixture.binding.manifestSHA256)?.phase,
            .quarantinePlanned
        )
        if FileManager.default.fileExists(atPath: fixture.sourceURL.path) {
            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.bytes)
        }
    }

    func testInvalidClaudeProfileConfigurationFailsClosedForSourceOnly() async throws {
        let defaultRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        )
        let privateRoot = try makeProjectsRoot(
            parent: homeDirectory.appendingPathComponent(".claude-private", isDirectory: true)
        )
        let codexRoot = try makeProjectsRoot(
            parent: root.appendingPathComponent("codex-sessions", isDirectory: true)
        )
        try writeSettings(
            autoDiscover: false,
            customProjectsRoots: [privateRoot.path]
        )

        let resolver = ClaudeCodeProfileResolver(
            homeDirectory: homeDirectory,
            settingsURL: settingsURL
        )
        let validResolution = resolver.resolve()
        XCTAssertNil(validResolution.configurationError)
        let validPrivateProfile = try XCTUnwrap(
            validResolution.profiles.first { $0.projectsRoot == privateRoot.path }
        )
        XCTAssertEqual(validPrivateProfile.origin, .custom)
        XCTAssertFalse(validPrivateProfile.sourceReclamationAllowed)
        let validCoordinator = try makeCoordinator()
        let validPrivateAllowed = await validCoordinator.sourceReclamationAllowed(
            locator: privateRoot.appendingPathComponent("project/valid.jsonl").path,
            source: "claude-code"
        )
        XCTAssertFalse(validPrivateAllowed)

        let defaultFixture = try addEligibleBinding(
            seed: "invalid-default",
            source: "claude-code",
            projectsRoot: defaultRoot
        )
        let privateFixture = try addEligibleBinding(
            seed: "invalid-private",
            source: "claude-code",
            projectsRoot: privateRoot
        )
        let legacyFixture = try addEligibleBinding(
            seed: "invalid-legacy",
            source: "claude-code",
            projectsRoot: privateRoot
        )
        let codexFixture = try addEligibleBinding(
            seed: "invalid-codex",
            source: "codex",
            projectsRoot: codexRoot
        )
        let casFixture = try addEligibleBinding(
            seed: "invalid-cas",
            source: "claude-code",
            projectsRoot: privateRoot
        )
        let allFixtures = [
            defaultFixture,
            privateFixture,
            legacyFixture,
            codexFixture,
            casFixture,
        ]
        try await replicate(allFixtures)
        try recordCurrentRecoveryLeases(manifestSHA256: defaultFixture.binding.manifestSHA256)

        let legacyIntent = try catalog.upsertReclamationIntent(
            manifestSHA256: legacyFixture.binding.manifestSHA256,
            captureID: legacyFixture.capture.captureID,
            sessionID: legacyFixture.binding.sessionID,
            locator: legacyFixture.capture.locator,
            updatedAt: "2026-07-12T23:59:00.000Z"
        )
        XCTAssertTrue(try catalog.transitionReclamationIntent(
            manifestSHA256: legacyIntent.manifestSHA256,
            from: .eligible,
            to: .quarantinePlanned,
            expectedClaimGeneration: legacyIntent.claimGeneration,
            quarantinePath: legacyFixture.sourceURL.deletingLastPathComponent()
                .appendingPathComponent(".engram-reclaim-invalid-profile-test")
                .path,
            updatedAt: nowString
        ))
        try markSourceDeleted(casFixture)
        try writeInvalidProfileSettings()

        let invalidResolution = resolver.resolve()
        XCTAssertNotNil(invalidResolution.configurationError)
        let coordinator = try makeCoordinator()
        let defaultAllowed = await coordinator.sourceReclamationAllowed(
            locator: defaultFixture.capture.locator,
            source: defaultFixture.capture.source
        )
        let privateAllowed = await coordinator.sourceReclamationAllowed(
            locator: privateFixture.capture.locator,
            source: privateFixture.capture.source
        )
        let codexAllowed = await coordinator.sourceReclamationAllowed(
            locator: codexFixture.capture.locator,
            source: codexFixture.capture.source
        )
        XCTAssertFalse(defaultAllowed)
        XCTAssertFalse(privateAllowed)
        XCTAssertTrue(codexAllowed)

        let preview = await coordinator.preview(now: now)
        XCTAssertEqual(preview.eligibleCount, 1)
        XCTAssertEqual(preview.blockedCounts["unsupported_source"], 4)

        let run = await coordinator.runNow(now: now)

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.sourceFilesReclaimed, 1)
        XCTAssertEqual(run.casObjectsEvicted, 1)
        for fixture in [defaultFixture, privateFixture, legacyFixture, casFixture] {
            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), fixture.bytes)
        }
        for fixture in [defaultFixture, privateFixture] {
            XCTAssertNil(try catalog.reclamationIntent(
                manifestSHA256: fixture.binding.manifestSHA256
            ))
        }
        XCTAssertEqual(
            try catalog.reclamationIntent(manifestSHA256: legacyFixture.binding.manifestSHA256)?.phase,
            .quarantinePlanned
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexFixture.sourceURL.path))
        XCTAssertEqual(
            try catalog.reclamationIntent(manifestSHA256: codexFixture.binding.manifestSHA256)?.phase,
            .sourceDeleted
        )
        XCTAssertEqual(
            try catalog.localObject(objectSHA256: casFixture.objectSHA256)?.residency,
            .evicted
        )
        XCTAssertEqual(
            try catalog.reclamationIntent(manifestSHA256: casFixture.binding.manifestSHA256)?.phase,
            .localContentEvicted
        )
    }

    private struct BindingFixture {
        let sourceURL: URL
        let bytes: Data
        let objectSHA256: String
        let capture: ArchiveCapture
        let binding: ArchiveBinding
    }

    private func makeCoordinator() throws -> ArchiveReclamationCoordinator {
        try ArchiveReclamationCoordinator(
            settingsURL: settingsURL,
            environment: [:],
            databasePath: databaseURL.path,
            catalog: catalog,
            cas: cas,
            profileResolver: ClaudeCodeProfileResolver(
                homeDirectory: homeDirectory,
                settingsURL: settingsURL
            )
        )
    }

    private func makeProjectsRoot(parent: URL) throws -> URL {
        let projectsRoot = parent.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        return projectsRoot
    }

    private func writeSettings(
        autoDiscover: Bool = true,
        customProjectsRoots: [String]
    ) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "archiveReclamation": ["enabled": true, "hotWindowDays": 30],
                "claudeCodeProfiles": [
                    "autoDiscover": autoDiscover,
                    "customProjectsRoots": customProjectsRoots,
                ],
            ],
            options: [.sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private func writeInvalidProfileSettings() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "archiveReclamation": ["enabled": true, "hotWindowDays": 30],
                "claudeCodeProfiles": ["autoDiscover": false],
            ],
            options: [.sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private func addEligibleBinding(
        seed: String,
        source: String,
        projectsRoot: URL
    ) throws -> BindingFixture {
        let sourceURL = projectsRoot
            .appendingPathComponent("project-\(seed)", isDirectory: true)
            .appendingPathComponent("\(seed).jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data("eligible transcript \(seed)".utf8)
        try bytes.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sourceURL.path
        )

        var info = stat()
        XCTAssertEqual(Darwin.lstat(sourceURL.path, &info), 0)
        let generation = try ArchiveSourceGeneration(
            device: Int64(info.st_dev),
            inode: Int64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: nanoseconds(info.st_mtimespec),
            ctimeNs: nanoseconds(info.st_ctimespec),
            mode: Int64(info.st_mode)
        )
        let objectSHA256 = ArchiveV2Hash.sha256(bytes)
        _ = try cas.publishObject(raw: bytes, expectedSHA256: objectSHA256)
        let chunk = try ArchiveChunkReference(
            ordinal: 0,
            rawSHA256: objectSHA256,
            rawByteCount: Int64(bytes.count)
        )
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
        let unbound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: source,
            locator: sourceURL.path,
            sessionID: nil,
            capturedAt: "2026-05-01T00:00:00.000Z",
            generation: generation,
            wholeSourceSHA256: objectSHA256,
            rawByteCount: Int64(bytes.count),
            chunks: [chunk],
            replayLayout: try ArchiveReplayLayout(
                strategy: .singleFile,
                relativePaths: ["\(seed).jsonl"]
            )
        )
        let capture = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(unbound)
        )
        let sessionID = "session-\(seed)"
        let bound = try ArchiveSourceManifest(
            captureID: captureID,
            machineID: machineID,
            source: source,
            locator: sourceURL.path,
            sessionID: sessionID,
            capturedAt: unbound.capturedAt,
            generation: generation,
            wholeSourceSHA256: objectSHA256,
            rawByteCount: Int64(bytes.count),
            chunks: [chunk],
            replayLayout: unbound.replayLayout
        )
        let boundBytes = try ArchiveCanonicalJSON.encode(bound)
        let manifestSHA256 = ArchiveV2Hash.sha256(boundBytes)
        _ = try cas.publishManifest(boundBytes, expectedSHA256: manifestSHA256)
        let binding = try catalog.bind(
            canonicalManifestBytes: boundBytes,
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(Data("snapshot-\(seed)".utf8)),
            boundAt: "2026-05-01T00:01:00.000Z"
        )
        _ = try catalog.setRemotePolicySnapshot(
            manifestSHA256: binding.manifestSHA256,
            projectRootSnapshot: projectsRoot.path,
            eligibility: .eligible
        )
        try productDatabase.write { db in
            try db.execute(
                sql: "INSERT INTO sessions(id, start_time, end_time) VALUES (?, ?, ?)",
                arguments: [sessionID, "2026-05-01T00:00:00.000Z", "2026-05-01T00:10:00.000Z"]
            )
        }
        return BindingFixture(
            sourceURL: sourceURL,
            bytes: bytes,
            objectSHA256: objectSHA256,
            capture: capture,
            binding: binding
        )
    }

    private func replicate(_ fixtures: [BindingFixture]) async throws {
        let coordinator = try ArchiveReplicationCoordinator(
            catalog: catalog,
            cas: cas,
            backends: [
                ReclamationReplicaBackend(replicaID: "hq"),
                ReclamationReplicaBackend(replicaID: "m1"),
            ]
        )
        let cycle = await coordinator.runOnce(limit: fixtures.count * 2)
        XCTAssertNil(cycle.cycleError)
        XCTAssertEqual(cycle.verified, fixtures.count * 2)
    }

    private func recordCurrentRecoveryLeases(manifestSHA256: String) throws {
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            _ = try catalog.recordRecoveryLease(
                replicaID: replicaID,
                manifestSHA256: manifestSHA256,
                verifiedAt: nowString,
                verifiedBytes: 1
            )
        }
    }

    private func markSourceDeleted(_ fixture: BindingFixture) throws {
        var intent = try catalog.upsertReclamationIntent(
            manifestSHA256: fixture.binding.manifestSHA256,
            captureID: fixture.capture.captureID,
            sessionID: fixture.binding.sessionID,
            locator: fixture.capture.locator,
            updatedAt: "2026-07-12T23:59:00.000Z"
        )
        for (phase, quarantinePath) in [
            (ArchiveReclamationPhase.quarantinePlanned, fixture.capture.locator + ".q"),
            (.sourceQuarantined, fixture.capture.locator + ".q"),
            (.sourceDeletePlanned, fixture.capture.locator + ".q"),
            (.sourceDeleted, nil),
        ] {
            XCTAssertTrue(try catalog.transitionReclamationIntent(
                manifestSHA256: intent.manifestSHA256,
                from: intent.phase,
                to: phase,
                expectedClaimGeneration: intent.claimGeneration,
                quarantinePath: quarantinePath,
                updatedAt: nowString
            ))
            intent = try XCTUnwrap(
                catalog.reclamationIntent(manifestSHA256: intent.manifestSHA256)
            )
        }
    }

    private func nanoseconds(_ value: timespec) -> Int64 {
        Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }
}

private final class ReclamationReplicaBackend: ArchiveReplicaBackend, @unchecked Sendable {
    let replicaID: String
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var manifests: [String: Data] = [:]
    private var receipts: [String: Data] = [:]

    init(replicaID: String) {
        self.replicaID = replicaID
    }

    func headObject(digest: String) async throws -> Bool {
        locked { objects[digest] != nil }
    }

    func putObject(digest: String, data: Data) async throws {
        locked { objects[digest] = data }
    }

    func getObject(digest: String) async throws -> Data {
        try locked { try required(objects[digest]) }
    }

    func headManifest(digest: String) async throws -> Bool {
        locked { manifests[digest] != nil }
    }

    func putManifest(digest: String, data: Data) async throws {
        locked { manifests[digest] = data }
    }

    func getManifest(digest: String) async throws -> Data {
        try locked { try required(manifests[digest]) }
    }

    func createReceipt(manifestDigest: String) async throws -> Data {
        let manifestBytes = try locked { try required(manifests[manifestDigest]) }
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: manifestBytes
        )
        guard let sessionID = manifest.sessionID else {
            throw ArchiveReplicaBackendError.unexpectedStatus(422)
        }
        let receipt = try ArchiveServerReceipt(
            serverID: replicaID,
            machineID: manifest.machineID,
            sessionID: sessionID,
            captureID: manifest.captureID,
            manifestSHA256: manifestDigest,
            wholeSourceSHA256: manifest.wholeSourceSHA256,
            objectCount: manifest.chunks.count,
            rawByteCount: manifest.rawByteCount,
            storedAt: "2026-07-12T23:59:00.000Z"
        )
        let bytes = try ArchiveCanonicalJSON.encode(receipt)
        locked { receipts[manifestDigest] = bytes }
        return bytes
    }

    func getReceipt(manifestDigest: String) async throws -> Data {
        try locked { try required(receipts[manifestDigest]) }
    }

    func listMachines(cursor: String?, limit: Int) async throws -> ArchiveMachinePage {
        try ArchiveMachinePage(machineIDs: [], nextCursor: nil)
    }

    func listReceipts(
        machineID: String,
        cursor: String?,
        limit: Int
    ) async throws -> ArchiveReceiptPage {
        try ArchiveReceiptPage(receipts: [], nextCursor: nil)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else {
            throw ArchiveReplicaBackendError.unexpectedStatus(404)
        }
        return value
    }
}
