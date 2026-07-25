import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Domain-scoped orphan `file_index_state` pruning (v2).
final class FileIndexStateOrphanPruneTests: XCTestCase {
    private var tempDB: URL!
    private var writer: EngramDatabaseWriter!

    override func setUpWithError() throws {
        tempDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-orphan-v2-\(UUID().uuidString).sqlite")
        writer = try EngramDatabaseWriter(path: tempDB.path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let tempDB {
            try? FileManager.default.removeItem(at: tempDB)
        }
        tempDB = nil
    }

    // MARK: - Helpers

    private func seedState(
        source: SourceName,
        locator: String,
        parsedOffset: Int64 = 42,
        boundaryHash: String? = nil
    ) throws {
        try writer.upsertFileIndexState(
            FileIndexState(
                source: source,
                locator: locator,
                sizeBytes: 100,
                modifiedAtNanos: 1_000,
                inode: 1,
                device: 1,
                parsedOffset: parsedOffset,
                boundaryHash: boundaryHash ?? "hash-\(locator)",
                parseStatus: .ok,
                failureKind: nil,
                retryAfterEpochSeconds: nil,
                retryCount: 0,
                lastError: nil,
                schemaVersion: FileIndexState.currentSchemaVersion,
                updatedAtEpochSeconds: 1_800_000_000
            )
        )
    }

    private func hasState(source: SourceName, locator: String) throws -> Bool {
        try writer.knownFileIndexStates(source: source, locators: [locator])[locator] != nil
    }

    private func parsedOffset(source: SourceName, locator: String) throws -> Int64? {
        try writer.knownFileIndexStates(source: source, locators: [locator])[locator]?.parsedOffset
    }

    // MARK: - Load-bearing: multi-writer under one SourceName

    /// Two writers under `source='codex'`: adapter domain is `~/.codex/...`,
    /// foreign rows under `~/.claude-openai/...` must survive with parse offsets.
    func testForeignRootRowsUnderSameSourceSurvivePrune_repro() throws {
        let codexRoot = "/Users/test/.codex"
        let foreignRoot = "/Users/test/.claude-openai"
        let keep = "\(codexRoot)/sessions/rollout-keep.jsonl"
        let orphanUnderCodex = "\(codexRoot)/sessions/rollout-orphan.jsonl"
        let foreignLive = "\(foreignRoot)/projects/p/session.jsonl"

        try seedState(source: .codex, locator: keep, parsedOffset: 100)
        try seedState(source: .codex, locator: orphanUnderCodex, parsedOffset: 200)
        try seedState(source: .codex, locator: foreignLive, parsedOffset: 3_237)

        let deleted = try writer.pruneOrphanFileIndexStates(
            source: .codex,
            keeping: [keep],
            under: [codexRoot]
        )
        XCTAssertEqual(deleted, 1, "only the orphan under the declared root is in scope")
        XCTAssertTrue(try hasState(source: .codex, locator: keep))
        XCTAssertFalse(try hasState(source: .codex, locator: orphanUnderCodex))
        XCTAssertTrue(
            try hasState(source: .codex, locator: foreignLive),
            "rows under a second writer's root must not be deleted"
        )
        XCTAssertEqual(
            try parsedOffset(source: .codex, locator: foreignLive),
            3_237,
            "foreign-root parsed_offset must survive a same-source prune"
        )
    }

    /// autoDiscover=false style: roots and keep-set shrink together from the same
    /// profile list; rows under a dropped profile stay.
    func testShrunkProfileSetDoesNotPruneOtherProfiles_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profiles-\(UUID().uuidString)", isDirectory: true)
        let primary = root.appendingPathComponent("claude/projects", isDirectory: true)
        let secondary = root.appendingPathComponent("claude-extra/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primaryProject = primary.appendingPathComponent("-Users-test", isDirectory: true)
        let secondaryProject = secondary.appendingPathComponent("-Users-test", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondaryProject, withIntermediateDirectories: true)

        let primaryFile = primaryProject.appendingPathComponent("keep.jsonl")
        let secondaryFile = secondaryProject.appendingPathComponent("other-profile.jsonl")
        try "p\n".write(to: primaryFile, atomically: true, encoding: .utf8)
        try "s\n".write(to: secondaryFile, atomically: true, encoding: .utf8)

        try seedState(source: .claudeCode, locator: primaryFile.path, parsedOffset: 11)
        try seedState(source: .claudeCode, locator: secondaryFile.path, parsedOffset: 22)
        // Orphan under primary (listed root, not listed file).
        let primaryOrphan = primaryProject.appendingPathComponent("orphan.jsonl").path
        try seedState(source: .claudeCode, locator: primaryOrphan, parsedOffset: 33)

        let lock = NSLock()
        var liveProfiles: [ClaudeCodeProfile] = [
            ClaudeCodeProfile(
                id: "primary",
                displayName: "Primary",
                projectsRoot: primary.path,
                origin: .default,
                available: true,
                sourceReclamationAllowed: true
            ),
            ClaudeCodeProfile(
                id: "secondary",
                displayName: "Secondary",
                projectsRoot: secondary.path,
                origin: .automatic,
                available: true,
                sourceReclamationAllowed: true
            ),
        ]
        let adapter = ClaudeCodeAdapter(profileResolutionProvider: {
            lock.lock()
            defer { lock.unlock() }
            return liveProfiles
        })

        // Full profile set: both roots declared, both files kept; orphan under primary deleted.
        var keep = try await adapter.listSessionLocators()
        XCTAssertEqual(Set(adapter.enumerationRoots), Set([primary.path, secondary.path]))
        XCTAssertTrue(keep.contains(primaryFile.path))
        XCTAssertTrue(keep.contains(secondaryFile.path))
        var deleted = try writer.pruneOrphanFileIndexStates(
            source: .claudeCode,
            keeping: keep,
            under: adapter.enumerationRoots
        )
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(try hasState(source: .claudeCode, locator: primaryOrphan))
        XCTAssertEqual(try parsedOffset(source: .claudeCode, locator: secondaryFile.path), 22)

        // Shrink to primary only (autoDiscover off). Same list call stamps roots.
        lock.lock()
        liveProfiles = [liveProfiles[0]]
        lock.unlock()
        keep = try await adapter.listSessionLocators()
        XCTAssertEqual(adapter.enumerationRoots, [primary.path])
        XCTAssertEqual(keep, [primaryFile.path])

        deleted = try writer.pruneOrphanFileIndexStates(
            source: .claudeCode,
            keeping: keep,
            under: adapter.enumerationRoots
        )
        XCTAssertEqual(deleted, 0, "shrunk roots must not reach the dropped profile")
        XCTAssertTrue(
            try hasState(source: .claudeCode, locator: secondaryFile.path),
            "rows under a dropped profile must survive when roots shrink with the keep-set"
        )
        XCTAssertEqual(try parsedOffset(source: .claudeCode, locator: secondaryFile.path), 22)
        XCTAssertTrue(try hasState(source: .claudeCode, locator: primaryFile.path))
    }

    // MARK: - Remaining plan cases

    func testOrphanUnderDeclaredRootIsPruned_repro() async throws {
        let keep = "/tmp/domain/keep.jsonl"
        let orphan = "/tmp/domain/orphan.jsonl"
        try seedState(source: .claudeCode, locator: keep)
        try seedState(source: .claudeCode, locator: orphan)

        let adapter = DomainSessionAdapter(
            source: .claudeCode,
            locators: [keep],
            roots: ["/tmp/domain"]
        )
        XCTAssertEqual(adapter.enumerationRoots, ["/tmp/domain"])
        _ = try await writer.indexRecentSessions(adapters: [adapter])

        XCTAssertTrue(try hasState(source: .claudeCode, locator: keep))
        XCTAssertFalse(
            try hasState(source: .claudeCode, locator: orphan),
            "orphan under a declared root must be deleted after complete list"
        )
    }

    // A declared root containing a SQL LIKE wildcard must not widen the domain.
    // `LIKE root || '/%'` reads `_` as "any character", so the `.claude-a_b`
    // profile would have swept `.claude-aXb` — the exact cross-domain delete the
    // root scoping exists to prevent, arrived at through the predicate itself.
    func testRootWithLikeWildcardDoesNotOverMatch_repro() throws {
        let declaredRoot = "/tmp/prune_wildcard/.claude-a_b/projects"
        let neighbourRoot = "/tmp/prune_wildcard/.claude-aXb/projects"
        let neighbour = "\(neighbourRoot)/\(UUID().uuidString).jsonl"
        try seedState(source: .claudeCode, locator: neighbour)

        let deleted = try writer.pruneOrphanFileIndexStates(
            source: .claudeCode,
            keeping: ["\(declaredRoot)/kept.jsonl"],
            under: [declaredRoot]
        )

        XCTAssertEqual(deleted, 0, "a wildcard in the root must not delete outside the declared domain")
        XCTAssertTrue(
            try hasState(source: .claudeCode, locator: neighbour),
            "rows under a neighbouring root must survive a root containing '_'"
        )
    }

    func testEmptyEnumerationRootsNeverPrunes() throws {
        let locator = "/tmp/no-domain/\(UUID().uuidString).jsonl"
        try seedState(source: .codex, locator: locator)
        // Non-empty keep-set but empty roots (default domain) → no-op.
        let deleted = try writer.pruneOrphanFileIndexStates(
            source: .codex,
            keeping: ["/tmp/other.jsonl"],
            under: []
        )
        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(try hasState(source: .codex, locator: locator))
    }

    func testEmptyKeepSetNeverPrunes() throws {
        let locator = "/tmp/empty-keep/\(UUID().uuidString).jsonl"
        try seedState(source: .claudeCode, locator: locator)
        let deleted = try writer.pruneOrphanFileIndexStates(
            source: .claudeCode,
            keeping: [],
            under: ["/tmp/empty-keep"]
        )
        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(try hasState(source: .claudeCode, locator: locator))
    }

    func testPruneKeepsEnumeratedRowsAndTheirParseOffsets() throws {
        let root = "/tmp/cursor-domain"
        let plain = "\(root)/plain.jsonl"
        let composite = "\(root)/composite.jsonl::session-a"
        try seedState(source: .cursor, locator: plain, parsedOffset: 777, boundaryHash: "b-plain")
        try seedState(source: .cursor, locator: composite, parsedOffset: 888, boundaryHash: "b-comp")
        try seedState(source: .cursor, locator: "\(root)/orphan.jsonl", parsedOffset: 1)

        let deleted = try writer.pruneOrphanFileIndexStates(
            source: .cursor,
            keeping: [plain, composite],
            under: [root]
        )
        XCTAssertEqual(deleted, 1)
        let kept = try writer.knownFileIndexStates(source: .cursor, locators: [plain, composite])
        XCTAssertEqual(kept[plain]?.parsedOffset, 777)
        XCTAssertEqual(kept[plain]?.boundaryHash, "b-plain")
        XCTAssertEqual(kept[composite]?.parsedOffset, 888)
        XCTAssertEqual(kept[composite]?.boundaryHash, "b-comp")
    }

    func testDefaultAdapterEnumerationRootsAreEmpty() {
        let adapter = DomainSessionAdapter(source: .codex, locators: ["/x"], roots: nil)
        // When roots is nil, DomainSessionAdapter uses protocol default via no override path —
        // use a plain adapter without roots property override.
        XCTAssertEqual(
            (FixedDefaultRootsAdapter() as any SessionAdapter).enumerationRoots,
            [],
            "default domain must be empty so non-opted-in adapters never prune"
        )
        XCTAssertEqual(adapter.enumerationRoots, [])
    }
}

// MARK: - Test adapters

/// Adapter that opts into a declared domain (mirrors ClaudeCode after a list).
private final class DomainSessionAdapter: SessionAdapter {
    let source: SourceName
    let locators: [String]
    private let roots: [String]?

    init(source: SourceName, locators: [String], roots: [String]?) {
        self.source = source
        self.locators = locators
        self.roots = roots
    }

    var enumerationRoots: [String] { roots ?? [] }

    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { locators }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .success(
            NormalizedSessionInfo(
                id: "domain-\((locator as NSString).lastPathComponent)",
                source: source,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "test",
                messageCount: 0,
                userMessageCount: 0,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "domain",
                filePath: locator,
                sizeBytes: 0
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func isAccessible(locator: String) async -> Bool { true }
}

/// Relies on the protocol default for `enumerationRoots`.
private final class FixedDefaultRootsAdapter: SessionAdapter {
    let source: SourceName = .codex
    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        .failure(.fileMissing)
    }
    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func isAccessible(locator: String) async -> Bool { false }
}
