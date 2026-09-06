import Foundation
import GRDB
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class WebNormalizedTranscriptSnapshotProviderTests: XCTestCase {
    func testReadySnapshotPreservesCompleteNormalizedFieldsWithoutWrites() async throws {
        let fixture = try makeFixture()
        let before = try fixture.state()
        let snapshot = try await visible(fixture)
        XCTAssertEqual(snapshot.sessionId, fixture.receipt.sessionID)
        XCTAssertEqual(snapshot.generation, fixture.receipt.generationID)
        XCTAssertTrue(snapshot.messages == fixture.messages, "Preserve every complete normalized field")
        XCTAssertTrue(snapshot.totalKnownComplete)
        XCTAssertNil(snapshot.truncatedAt)
        XCTAssertNil(snapshot.parseFailure)
        XCTAssertEqual(try fixture.state(), before)
    }

    func testParsedArtifactAloneIsNotWebReady() async throws {
        let fixture = try makeFixture(ready: false)
        let stored = try fixture.writer.read {
            try CaptureIngestNormalizedStore.load($0, sessionID: fixture.receipt.sessionID,
                generationID: fixture.receipt.generationID, expectedParserRevision: TranscriptSQLFixture.parser,
                enabledSources: [.claudeCode])
        }
        XCTAssertTrue(stored.messages == fixture.messages, "A real parsed artifact exists before Web admission")
        let before = try fixture.state()
        await denied { try await fixture.snapshot() }
        XCTAssertEqual(try fixture.state(), before)
    }

    func testHiddenSkipAndChildVisibilityAreRecheckedOnEveryCall() async throws {
        for assignment in ["hidden_at = '2026-09-06T00:00:00Z'", "tier = 'skip'",
                           "parent_session_id = 'parent'", "suggested_parent_id = 'parent'"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate("UPDATE sessions SET \(assignment)")
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, assignment)
        }
    }

    func testParsedReadyHeadsAndLedgerMustAgree() async throws {
        for sql in [
            "UPDATE capture_ingest_identity_bindings SET last_parsed_generation_id = NULL",
            "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL",
            "UPDATE capture_ingest_ledger SET status = 'parsed'",
            "UPDATE capture_ingest_ledger SET failure_code = 'corrupt'",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, sql)
        }
    }

    func testReadyScalarsCannotReplaceTheExactCompletedFTSJob() async throws {
        for sql in [
            "UPDATE session_index_jobs SET status = 'pending' WHERE job_kind = 'fts'",
            "UPDATE session_index_jobs SET target_sync_version = target_sync_version + 1 WHERE job_kind = 'fts'",
            "UPDATE capture_ingest_generations SET required_fts_job_id = NULL",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            await denied { try await fixture.snapshot() }
        }
    }

    func testCurrentSessionSnapshotAndOwnershipMustStillMatch() async throws {
        for assignment in ["sync_version = sync_version + 1", "snapshot_hash = '\(String(repeating: "f", count: 64))'",
                           "authoritative_node = 'another-node'", "source = 'codex'"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate("UPDATE sessions SET \(assignment)")
            await denied { try await fixture.snapshot() }
        }
    }

    func testCurrentRegistryAndEpochHistoryCannotReuseEarlierAdmission() async throws {
        for sql in [
            "UPDATE capture_ingest_source_registry SET configured_root = '/different-root'",
            "UPDATE capture_ingest_source_registry SET parse_format = 'claudeCustomProfile'",
            "UPDATE capture_ingest_source_registry SET authority_generation = authority_generation + 1",
            "DELETE FROM capture_ingest_epoch_history",
        ] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            try fixture.mutate(sql)
            await denied { try await fixture.snapshot() }
        }
    }

    func testMissingInvalidDisabledAndChangedParserPolicyAreUnavailable() async throws {
        let fixture = try makeFixture()
        let policies: [ServiceWebMetadataPolicy?] = [nil,
            .init(parserRevision: " ", enabledSources: [.claudeCode]),
            .init(parserRevision: "different-parser", enabledSources: [.claudeCode]),
            .init(parserRevision: TranscriptSQLFixture.parser, enabledSources: []),
            .init(parserRevision: TranscriptSQLFixture.parser, enabledSources: [.codex])]
        for policy in policies {
            fixture.policy.value = TranscriptSQLFixture.allowedPolicy
            _ = try await visible(fixture)
            fixture.policy.value = policy
            await denied { try await fixture.snapshot() }
        }
    }

    func testPolicyRevocationDuringReadRejectsThePreparedSnapshot() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        fixture.policy.arm { [policy = fixture.policy] call in
            if call == 2 { policy.value = nil }
        }
        await denied { try await fixture.snapshot() }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testAuthorityRevocationAfterLoadRejectsThePreparedSnapshot() async throws {
        for sql in ["UPDATE sessions SET hidden_at = '2026-09-06T00:00:00Z'",
                    "UPDATE capture_ingest_source_registry SET configured_root = '/revoked-root'",
                    "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            let writer = try XCTUnwrap(fixture.writer)
            fixture.policy.arm { [writer] call in
                if call == 2 { try writer.write { try $0.execute(sql: sql) } }
            }
            await denied { try await fixture.snapshot() }
            XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
        }
    }

    func testCorruptNormalizedPayloadNeverBecomesAnEmptyOrPartialSuccess() async throws {
        for assignment in ["normalized_messages_json = x'FF'",
                           "normalized_messages_sha256 = '\(String(repeating: "f", count: 64))'",
                           "normalized_message_count = normalized_message_count + 1",
                           "normalized_schema_version = 2"] {
            let fixture = try makeFixture()
            _ = try await visible(fixture)
            if assignment == "normalized_schema_version = 2" {
                try fixture.writer.write { db in
                    try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                    defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                    try db.execute(sql: "UPDATE capture_ingest_generations SET \(assignment)")
                }
            } else {
                try fixture.mutate("UPDATE capture_ingest_generations SET \(assignment)")
            }
            let before = try fixture.state()
            await denied { try await fixture.snapshot() }
            XCTAssertEqual(try fixture.state(), before, assignment)
        }
    }

    func testRequestedIdentityCannotSelectADifferentCurrentGeneration() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        await denied { try await fixture.snapshot(sessionID: "missing-session") }
        await denied { try await fixture.snapshot(generation: String(repeating: "f", count: 64)) }
        await denied { try await fixture.snapshot(generation: "invalid") }
        await denied { try await fixture.snapshot(sessionID: "") }
    }

    func testExpiredEntryDoesNotReadPolicyAndCancellationStaysCancellation() async throws {
        let fixture = try makeFixture()
        await denied { try await fixture.snapshot(deadline: ContinuousClock.now - .milliseconds(1)) }
        XCTAssertEqual(fixture.policy.calls, 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.snapshot()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation must not become \(error)") }
        XCTAssertEqual(fixture.policy.calls, 0)
    }

    func testCancellationAfterAsyncReadDoesNotReturnPreparedMessages() async throws {
        let fixture = try makeFixture()
        fixture.policy.arm { call in
            if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task { try await fixture.snapshot() }
        do { _ = try await task.value; XCTFail("Expected cancellation after read") }
        catch is CancellationError {}
        catch { XCTFail("Cancellation must not become \(error)") }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testExpiredPostReadDeadlineIsNotRenewed() async throws {
        let fixture = try makeFixture()
        fixture.policy.arm { call in
            if call == 2 { Thread.sleep(forTimeInterval: 0.08) }
        }
        await denied { try await fixture.snapshot(deadline: ContinuousClock.now + .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(fixture.policy.calls, 2)
    }

    func testStoppedProviderCannotReturnEarlierSnapshot() async throws {
        let fixture = try makeFixture()
        _ = try await visible(fixture)
        try fixture.stopProvider()
        await denied { try await fixture.snapshot() }
    }

    private func makeFixture(ready: Bool = true) throws -> TranscriptSQLFixture {
        let fixture = try TranscriptSQLFixture(ready: ready)
        addTeardownBlock { try fixture.close() }
        return fixture
    }

    private func visible(_ fixture: TranscriptSQLFixture) async throws -> ServiceTranscriptContinuation.Snapshot {
        let snapshot = try await fixture.snapshot()
        return try XCTUnwrap(snapshot, "The real completed generation must be admitted")
    }

    private func denied(_ operation: () async throws -> ServiceTranscriptContinuation.Snapshot?,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let snapshot = try await operation()
            XCTAssertNil(snapshot, "No messages may escape a revoked authority", file: file, line: line)
        }
        catch { XCTAssertEqual(error as? ServiceWebTranscriptSnapshotError, .unavailable, file: file, line: line) }
    }
}

private final class TranscriptPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = TranscriptSQLFixture.allowedPolicy as ServiceWebMetadataPolicy?
    private var count = 0
    private var hook: (@Sendable (Int) throws -> Void)?
    var value: ServiceWebMetadataPolicy? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    var calls: Int { lock.withLock { count } }
    func arm(_ hook: @escaping @Sendable (Int) throws -> Void) {
        lock.withLock { count = 0; self.hook = hook }
    }
    func read() throws -> ServiceWebMetadataPolicy? {
        let (call, callback) = lock.withLock { count += 1; return (count, hook) }
        try callback?(call)
        return value
    }
}

/// Real Ledger -> parsed generation -> FTS readiness, entirely in temporary SQLite.
/// The source manifest is evidence only: no source bytes are opened or replayed.
private final class TranscriptSQLFixture: @unchecked Sendable {
    static let parser = "swift-web-transcript-v1"
    static var allowedPolicy: ServiceWebMetadataPolicy { .init(parserRevision: parser, enabledSources: [.claudeCode]) }
    let root: URL
    let path: String
    let receipt: CaptureIngestCommittedGeneration
    let messages: [NormalizedMessage]
    let policy = TranscriptPolicyBox()
    var writer: EngramDatabaseWriter!
    private var provider: (any ServiceWebTranscriptSnapshotProviding)?
    private var providerStop: (() throws -> Void)?

    init(ready: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-normalized-\(UUID().uuidString)")
        path = root.appendingPathComponent("index.sqlite").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let writer = try EngramDatabaseWriter(path: path)
        self.writer = writer
        try writer.migrate()
        let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        let journal = "11111111-1111-4111-8111-111111111111"
        let timestamp = "2026-09-06T01:02:03.000Z"
        let nativeID = "normalized-demo-session"
        messages = [
            .init(role: .system, content: "Fixture system", timestamp: timestamp),
            .init(role: .user, content: "  Preserve 界🌍 and all normalized fields.  ", timestamp: timestamp),
            .init(role: .assistant, content: "Complete fixture answer.", timestamp: timestamp,
                  toolCalls: [.init(name: "fixture_tool", input: "input \\\"界", output: String(repeating: "界🌍\\\"\n", count: 24_000))],
                  usage: .init(inputTokens: 10, outputTokens: 20, cacheReadTokens: 3, cacheCreationTokens: 4)),
            .init(role: .tool, content: "Complete tool result", timestamp: timestamp),
        ]
        let binding = try writer.write {
            try CaptureIngestSourceRegistry.provision($0, machineID: machine, sourceInstanceID: instance,
                source: .claudeCode, parseFormat: .claudeDefault, configuredRoot: "/offline-client/.claude/projects", initialEpoch: epoch)
        }
        let bytes = try ArchiveCanonicalJSON.encode(messages)
        let digest = ArchiveV2Hash.sha256(bytes)
        let relative = "fixture/session.jsonl"
        let manifest = try ArchiveSourceManifest(captureID: ArchiveV2Hash.sha256(Data(nativeID.utf8)),
            machineID: machine, source: "claude-code", locator: binding.configuredRoot + "/" + relative,
            sessionID: nil, capturedAt: timestamp,
            generation: .init(device: 1, inode: 2, size: Int64(bytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: digest, rawByteCount: Int64(bytes.count),
            chunks: [try .init(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(bytes.count))],
            replayLayout: .init(strategy: .singleFile, relativePaths: [relative]))
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 1, manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
        let publicationSHA = try publication.sha256()
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: 1,
            publicationSHA256: publicationSHA, manifestSHA256: publication.manifestSHA256, storedAt: timestamp)
        let page = try CollectorPublicationPage(items: [try .init(publication: publication, ack: ack)],
            afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: 1).encoded(), hasMore: false)
        let claim = try writer.write { db in
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: nil, serverID: "hq", parserRevision: Self.parser)
            return try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publicationSHA,
                parserRevision: Self.parser, now: 100, leaseDuration: 10))
        }
        let identity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance, source: .claudeCode, nativeID: nativeID)
        let info = NormalizedSessionInfo(id: nativeID, source: .claudeCode, startTime: timestamp, endTime: timestamp,
            cwd: "/offline-client/project", project: "fixture", model: "offline-fixture", messageCount: messages.count,
            userMessageCount: 1, assistantMessageCount: 1, toolMessageCount: 1, systemMessageCount: 1,
            summary: "Complete fixture summary", displayTitle: "Normalized transcript fixture", filePath: manifest.locator,
            sizeBytes: manifest.rawByteCount, originator: "claude-code")
        let replay = CaptureIngestReplayResult(publicationSHA256: publicationSHA, verifiedManifest: manifest,
            bindingSnapshot: binding, scan: .init(info: info, messages: messages), rawSourceSessionID: nativeID,
            nativeIdentity: identity, parentIdentity: nil, suggestedParentIdentity: nil)
        receipt = try writer.write { db in
            let receipt = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: Self.parser, now: 101, indexedAt: timestamp)
            if let job = receipt.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [job])
            }
            return receipt
        }
        if ready {
            let snapshot = try writer.read {
                try CaptureIngestNormalizedStore.load($0, sessionID: receipt.sessionID, generationID: receipt.generationID,
                    expectedParserRevision: Self.parser, enabledSources: [.claudeCode])
            }
            let completed = try writer.write {
                try CaptureIngestReadiness.commit($0, snapshot: snapshot, expectedParserRevision: Self.parser, enabledSources: [.claudeCode])
            }
            XCTAssertEqual(completed.disposition, .indexed)
        }
        // The existing unavailable default produced the executable RED before
        // this factory was connected to the real normalized authority reader.
        let actual = try ServiceWebNormalizedTranscriptSnapshotProvider(databasePath: path,
            policy: { [policy = self.policy] in try policy.read() })
        provider = actual
        providerStop = { try actual.stop() }
    }

    func snapshot(sessionID: String? = nil, generation: String? = nil,
                  deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(2)) async throws -> ServiceTranscriptContinuation.Snapshot? {
        try await XCTUnwrap(provider).snapshot(sessionID: sessionID ?? receipt.sessionID,
            generation: generation ?? receipt.generationID, deadline: deadline)
    }

    func mutate(_ sql: String) throws { try writer.write { try $0.execute(sql: sql) } }

    func state() throws -> [String: [Row]] {
        try writer.read { db in
            var result: [String: [Row]] = [:]
            for table in ["sessions", "session_index_jobs", "sessions_fts", "fts_map", "metadata",
                          "capture_ingest_generations", "capture_ingest_identity_bindings", "capture_ingest_ledger",
                          "capture_ingest_publications", "capture_ingest_source_registry", "capture_ingest_epoch_history"] {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }

    func stopProvider() throws { try providerStop?() }

    func close() throws {
        policy.arm { _ in }
        try stopProvider()
        providerStop = nil
        provider = nil
        writer = nil
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}
