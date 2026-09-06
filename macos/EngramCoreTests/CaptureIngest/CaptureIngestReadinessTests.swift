import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import SQLite3
import XCTest

final class CaptureIngestReadinessTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let revision = "swift-parser-ready-v1"
    private let timestamp = "2026-09-06T01:02:03.000Z"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!
    private var nextOrdinal: Int64 = 1

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testLoadReturnsOwnedCompleteAllRoleNormalizedFieldsWithoutWrites() throws {
        let fixture = try parsed()
        let before = try state()
        let snapshot = try load(fixture)
        XCTAssertEqual(snapshot.sessionID, fixture.receipt.sessionID)
        XCTAssertEqual(snapshot.generationID, fixture.receipt.generationID)
        XCTAssertEqual(snapshot.publicationSHA256, fixture.publicationSHA256)
        XCTAssertEqual(snapshot.parserRevision, revision)
        XCTAssertEqual(snapshot.nativeIdentity, fixture.native)
        XCTAssertEqual(snapshot.bindingSnapshot, fixture.binding)
        XCTAssertEqual(snapshot.syncVersion, fixture.receipt.syncVersion)
        XCTAssertEqual(snapshot.snapshotHash, fixture.receipt.snapshotHash)
        XCTAssertEqual(snapshot.requiredFTSJobID, fixture.receipt.requiredFTSJobID)
        XCTAssertEqual(snapshot.messages, fixture.messages)
        XCTAssertEqual(snapshot.normalizedMessagesSHA256, try ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(fixture.messages)))
        XCTAssertEqual(try state(), before)
    }

    func testLoadDoesNotApplyIPCFrameLimitOrDropLargeToolFields() throws {
        let large = String(repeating: "界🌍\\\"\n", count: 32_000)
        let messages = [NormalizedMessage(role: .assistant, content: "complete", timestamp: timestamp,
            toolCalls: [.init(name: "fixture_tool", input: large, output: large)],
            usage: .init(inputTokens: 100, outputTokens: 200, cacheReadTokens: 3, cacheCreationTokens: 4))]
        let fixture = try parsed(messages: messages)
        XCTAssertGreaterThan(try ArchiveCanonicalJSON.encode(messages).count, 256 * 1024)
        XCTAssertTrue(try load(fixture).messages == messages, "Do not print large normalized payloads")
    }

    func testLoadPreservesAllTenThousandNormalizedMessagesAtInclusiveLimit() throws {
        let roles: [NormalizedMessageRole] = [.user, .assistant, .tool, .system]
        let messages = (0..<10_000).map { NormalizedMessage(role: roles[$0 % roles.count], content: "message-\($0)") }
        let fixture = try parsed(messages: messages)
        let snapshot = try load(fixture)
        XCTAssertEqual(snapshot.messages.count, 10_000)
        XCTAssertEqual(snapshot.messages.first, messages.first)
        XCTAssertEqual(snapshot.messages.last, messages.last)
        XCTAssertTrue(snapshot.messages == messages, "No normalized role, middle element or suffix may be dropped")
    }

    func testLoadRejectsWrongSessionGenerationAndParserAuthority() throws {
        let fixture = try parsed()
        let before = try state()
        assertError(.staleGeneration) { try load(fixture, sessionID: "missing") }
        assertError(.staleGeneration) { try load(fixture, generationID: String(repeating: "f", count: 64)) }
        assertError(.parserRevisionChanged) { try load(fixture, parser: "another-parser") }
        assertError(.invalidParserRevision) { try load(fixture, parser: " ") }
        XCTAssertEqual(try state(), before)
    }

    func testLoadPreservesByteDistinctNativeIdentities() throws {
        let composed = try parsed(nativeID: "caf\u{00E9}")
        let decomposed = try parsed(nativeID: "cafe\u{0301}")
        let first = try load(composed)
        let second = try load(decomposed)
        XCTAssertFalse(first.sessionID.utf8.elementsEqual(second.sessionID.utf8))
        XCTAssertTrue(first.nativeIdentity.nativeID.utf8.elementsEqual("caf\u{00E9}".utf8))
        XCTAssertTrue(second.nativeIdentity.nativeID.utf8.elementsEqual("cafe\u{0301}".utf8))
    }

    func testDisabledSourceIsRecoverableAtLoadAndCommit() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let before = try state()
        assertError(.sourceDisabled) { try load(fixture, sources: []) }
        assertError(.sourceDisabled) { try ready(snapshot, sources: []) }
        assertError(.sourceDisabled) { try load(fixture, sources: [.codex]) }
        assertError(.sourceDisabled) { try ready(snapshot, sources: [.codex]) }
        XCTAssertEqual(try state(), before)
        _ = try ready(snapshot)
        try assertReady(fixture)
    }

    func testLoadRejectsMalformedDigestCountSchemaAndPayloadStorageTypes() throws {
        let mutations = [
            "normalized_messages_sha256 = 'bad'",
            "normalized_messages_sha256 = upper(normalized_messages_sha256)",
            "normalized_messages_sha256 = zeroblob(64)",
            "normalized_message_count = 2.5",
            "normalized_message_count = -1",
            "normalized_message_count = normalized_message_count + 1",
            "normalized_schema_version = 2",
            "normalized_messages_json = CAST(normalized_messages_json AS TEXT)",
            "normalized_messages_json = x'FF'",
            "normalized_messages_json = CAST('[]' AS BLOB)",
        ]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try parsed(nativeID: "corrupt-\(index)")
            try corrupt(fixture, assignment: mutation)
            let before = try state()
            assertError(.invalidStoredRecord) { try load(fixture) }
            XCTAssertEqual(try state(), before, "corrupt normalized record must be read-only")
        }
    }

    func testLoadRejectsNoncanonicalAndUnknownNormalizedFieldsEvenWithMatchingHash() throws {
        for bytes in [Data("[ {\"role\":\"user\",\"content\":\"x\"} ]".utf8),
                      Data("[{\"content\":\"x\",\"role\":\"user\",\"unexpected\":true}]".utf8)] {
            let fixture = try parsed(nativeID: UUID().uuidString)
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE capture_ingest_generations SET normalized_messages_json = ?,
                        normalized_messages_sha256 = ?, normalized_message_count = 1 WHERE generation_id = ?
                    """, arguments: [bytes, ArchiveV2Hash.sha256(bytes), fixture.receipt.generationID])
            }
            assertError(.invalidStoredRecord) { try load(fixture) }
        }
    }

    func testPayloadAndMessageBudgetsAreCheckedBeforeFetchingPayload() throws {
        let cases: [(String, CaptureIngestReadinessError)] = [
            ("normalized_messages_json = zeroblob(\(CaptureIngestCommitter.maximumNormalizedPayloadBytes + 1))", .normalizedPayloadTooLarge),
            ("normalized_message_count = \(CaptureIngestCommitter.maximumNormalizedMessages + 1)", .tooManyMessages),
        ]
        for (index, entry) in cases.enumerated() {
            let fixture = try parsed(nativeID: "budget-\(index)")
            try corrupt(fixture, assignment: entry.0)
            let trace = ReadinessStatementTrace()
            try writer.read { db in
                trace.install(db)
                defer { trace.remove(db) }
                assertError(entry.1) {
                    try CaptureIngestNormalizedStore.load(db, sessionID: fixture.receipt.sessionID,
                        generationID: fixture.receipt.generationID, expectedParserRevision: revision,
                        enabledSources: [.claudeCode])
                }
            }
            XCTAssertTrue(trace.statements.contains { $0.lowercased().contains("length(normalized_messages_json)") },
                          "Read normalized BLOB length as metadata before materializing it")
            XCTAssertFalse(trace.statements.contains(where: ReadinessStatementTrace.projectsPayload),
                           "Over-budget metadata must prevent any direct or mixed payload projection")
        }
    }

    func testPayloadProjectionWitnessCatchesMixedAndQualifiedSelects() {
        for sql in [
            "SELECT normalized_messages_json FROM capture_ingest_generations",
            "SELECT length(normalized_messages_json), normalized_messages_json FROM capture_ingest_generations",
            "SELECT generation_id, g.normalized_messages_json AS payload FROM capture_ingest_generations g",
            "SELECT generation_id, g.* FROM capture_ingest_generations g",
            "SELECT * FROM capture_ingest_generations",
        ] { XCTAssertTrue(ReadinessStatementTrace.projectsPayload(sql)) }
        XCTAssertFalse(ReadinessStatementTrace.projectsPayload("SELECT generation_id, length(normalized_messages_json), typeof(normalized_messages_json) FROM capture_ingest_generations"))
        XCTAssertFalse(ReadinessStatementTrace.projectsPayload("SELECT length(g.normalized_messages_json), typeof(g.normalized_messages_json) FROM capture_ingest_generations g"))
    }

    func testLoadAndCommitRejectExpiredDeadlinesWithoutWrites() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let before = try state()
        let expired = ContinuousClock.now.advanced(by: .seconds(-1))
        assertError(.deadlineExceeded) { try load(fixture, deadline: expired) }
        assertError(.deadlineExceeded) { try ready(snapshot, deadline: expired) }
        XCTAssertEqual(try state(), before)
    }

    func testCancelledLoadAndCommitDoNotChangeReadiness() async throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let before = try state()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try self.load(fixture)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try self.ready(snapshot)) { XCTAssertTrue($0 is CancellationError) }
        }
        try await task.value
        XCTAssertEqual(try state(), before)
    }

    func testReadinessAtomicallyFillsRealFTSMapExactJobLedgerAndHead() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        XCTAssertEqual(try fts(fixture), [])
        let result = try ready(snapshot)
        XCTAssertEqual(result.sessionID, fixture.receipt.sessionID)
        XCTAssertEqual(result.generationID, fixture.receipt.generationID)
        XCTAssertEqual(result.syncVersion, fixture.receipt.syncVersion)
        XCTAssertEqual(result.snapshotHash, fixture.receipt.snapshotHash)
        XCTAssertEqual(result.requiredFTSJobID, fixture.receipt.requiredFTSJobID)
        XCTAssertEqual(result.disposition, .indexed)
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fts_map WHERE session_id = ?",
            arguments: [fixture.receipt.sessionID]) }, try expectedFTS(fixture).count)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH 'needleunique' AND session_id = ?",
            arguments: [fixture.receipt.sessionID]) }, 1, "Exercise the real FTS tokenizer/query path")
    }

    func testReadinessKeepsAllArtifactRolesButIndexesOnlyNonemptyUserAssistantAndStoredSummary() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let storedSummary = try writer.read { try String.fetchOne($0, sql: "SELECT summary FROM sessions WHERE id = ?",
            arguments: [fixture.receipt.sessionID]) }
        XCTAssertNotNil(storedSummary)
        _ = try ready(snapshot)
        let rows = try fts(fixture)
        XCTAssertEqual(rows, try expectedFTS(fixture))
        XCTAssertFalse(rows.contains("tool-only-needle"))
        XCTAssertFalse(rows.contains("system-only-needle"))
        XCTAssertTrue(rows.contains("  needleunique user text  "), "Filtering blank content must not trim stored nonempty text")
        XCTAssertEqual(try load(fixture).messages, fixture.messages)
    }

    func testRepeatedCompletedReadinessIsAnExactNoop() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let first = try ready(snapshot)
        let before = try state()
        XCTAssertEqual(try ready(snapshot), first)
        XCTAssertEqual(try state(), before)
    }

    func testOldPreparedGenerationCannotCompleteOrPurgeNewerJobAndFTS() throws {
        let first = try parsed()
        let stale = try load(first)
        _ = try ready(stale)
        let newer = try parsed(messages: [
            .init(role: .user, content: "new immutable generation"),
            .init(role: .assistant, content: "Implemented and verified the newer immutable generation completely."),
        ])
        XCTAssertNotNil(newer.receipt.requiredFTSJobID, "This fixture must exercise a non-skip generation")
        XCTAssertNotEqual(try writer.read { try String.fetchOne($0, sql: "SELECT tier FROM sessions WHERE id = ?",
            arguments: [newer.receipt.sessionID]) }, "skip")
        _ = try ready(load(newer))
        XCTAssertNil(try writer.read { try String.fetchOne($0, sql: "SELECT id FROM session_index_jobs WHERE id = ?",
            arguments: [try XCTUnwrap(first.receipt.requiredFTSJobID)]) }, "T2 removes the old job, so its absence is not current completion")
        let before = try state()
        assertError(.staleGeneration) { try ready(stale) }
        assertError(.staleGeneration) { try load(first) }
        XCTAssertEqual(try state(), before)
        try assertReady(newer)
    }

    func testNewParsedNotReadyKeepsPreviousReadyHeadAndFTS() throws {
        let first = try parsed()
        _ = try ready(load(first))
        let priorRows = try fts(first)
        let newer = try parsed(messages: [
            .init(role: .user, content: "pending new body"),
            .init(role: .assistant, content: "Implemented the new body and preserved the prior searchable generation."),
        ])
        XCTAssertNotNil(newer.receipt.requiredFTSJobID, "This fixture must exercise a non-skip generation")
        XCTAssertNotEqual(try writer.read { try String.fetchOne($0, sql: "SELECT tier FROM sessions WHERE id = ?",
            arguments: [newer.receipt.sessionID]) }, "skip")
        XCTAssertEqual(try head(newer, column: "last_parsed_generation_id"), newer.receipt.generationID)
        XCTAssertEqual(try head(newer, column: "last_ready_generation_id"), first.receipt.generationID)
        XCTAssertEqual(try fts(newer), priorRows)
        XCTAssertEqual(try ledgerStatus(newer), "parsed")
    }

    func testEpochApprovalAfterPrepareInvalidatesBothLoadAndCommit() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        try writer.write { db in
            _ = try CaptureIngestSourceRegistry.approveEpoch(db, machineID: machine, sourceInstanceID: instance,
                candidateEpoch: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", expectedEpoch: epoch, expectedAuthorityGeneration: 1)
        }
        let before = try state()
        assertError(.bindingChanged) { try load(fixture) }
        assertError(.bindingChanged) { try ready(snapshot) }
        XCTAssertEqual(try state(), before)
    }

    func testRegistryRootAndParseFormatChangesAfterPrepareCannotUseStaleBinding() throws {
        for assignment in ["configured_root = '/offline-client/changed'", "parse_format = 'claudeCustomProfile'"] {
            let fixture = try parsed(nativeID: UUID().uuidString)
            let snapshot = try load(fixture)
            let original = try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM capture_ingest_source_registry")) }
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET \(assignment)") }
            let before = try state()
            assertError(.bindingChanged) { try load(fixture) }
            assertError(.bindingChanged) { try ready(snapshot) }
            XCTAssertEqual(try state(), before)
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET configured_root = ?, parse_format = ?",
                arguments: [original["configured_root"] as String, original["parse_format"] as String]) }
        }
    }

    func testFreshParserRevisionIsRequiredAgainAfterPreparation() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let before = try state()
        assertError(.parserRevisionChanged) { try ready(snapshot, parser: "current-v2") }
        assertError(.invalidParserRevision) { try ready(snapshot, parser: "") }
        XCTAssertEqual(try state(), before)
    }

    func testCurrentSessionOwnerSourceVersionAndHashAreFencedAtLoadAndCommit() throws {
        let mutations = ["authoritative_node = 'other-owner'", "source = 'codex'", "sync_version = sync_version + 1",
                         "sync_version = 2.5", "snapshot_hash = 'wrong-hash'"]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try parsed(nativeID: "session-fence-\(index)")
            let snapshot = try load(fixture)
            try writer.write { try $0.execute(sql: "UPDATE sessions SET \(mutation) WHERE id = ?", arguments: [fixture.receipt.sessionID]) }
            let before = try state()
            assertError(.currentSnapshotMismatch) { try load(fixture) }
            assertError(.currentSnapshotMismatch) { try ready(snapshot) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testHiddenAndOrphanStateIsPreservedWithoutTreatingFTSAsWebVisibility() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET hidden_at = ?, orphan_status = 'orphaned', custom_name = 'manual-name' WHERE id = ?",
                           arguments: [timestamp, fixture.receipt.sessionID])
        }
        _ = try ready(snapshot)
        let row = try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT hidden_at, orphan_status, custom_name FROM sessions WHERE id = ?",
            arguments: [fixture.receipt.sessionID])) }
        XCTAssertEqual(row["hidden_at"] as String, timestamp)
        XCTAssertEqual(row["orphan_status"] as String, "orphaned")
        XCTAssertEqual(row["custom_name"] as String, "manual-name")
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture), "Hidden/orphan corpus retention follows existing FTS policy")
    }

    func testMissingWrongAndTerminalRequiredJobsDoNotProveReadiness() throws {
        let mutations = [
            "DELETE FROM session_index_jobs WHERE id = ?",
            "UPDATE session_index_jobs SET job_kind = 'embedding' WHERE id = ?",
            "UPDATE session_index_jobs SET target_sync_version = target_sync_version + 1 WHERE id = ?",
            "UPDATE session_index_jobs SET target_sync_version = 2.5 WHERE id = ?",
            "UPDATE session_index_jobs SET status = 'completed' WHERE id = ?",
            "UPDATE session_index_jobs SET status = 'not_applicable' WHERE id = ?",
            "UPDATE session_index_jobs SET status = 'failed_permanent' WHERE id = ?",
            "UPDATE session_index_jobs SET status = 'processing' WHERE id = ?",
            "UPDATE session_index_jobs SET status = 'unknown' WHERE id = ?",
            "UPDATE session_index_jobs SET not_before = '9999-12-31 23:59:59' WHERE id = ?",
        ]
        for (index, mutation) in mutations.enumerated() {
            let fixture = try parsed(nativeID: "job-fence-\(index)")
            let snapshot = try load(fixture)
            try writer.write { try $0.execute(sql: mutation, arguments: [try XCTUnwrap(fixture.receipt.requiredFTSJobID)]) }
            let before = try state()
            assertError(.requiredJobChanged) { try ready(snapshot) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testRetryableExactJobCanBecomeReadyWithoutResettingUnrelatedJobs() throws {
        let fixture = try parsed()
        let untouched = try parsed(nativeID: "other-pending-session")
        try writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET status = 'failed_retryable', retry_count = 3, last_error = 'fixture' WHERE id = ?",
            arguments: [try XCTUnwrap(fixture.receipt.requiredFTSJobID)]) }
        _ = try ready(load(fixture))
        try assertReady(fixture)
        XCTAssertEqual(try ledgerStatus(untouched), "parsed")
        XCTAssertEqual(try jobStatus(untouched), "pending")
        XCTAssertNil(try head(untouched, column: "last_ready_generation_id"))
    }

    func testElapsedDebounceIsEligibleWithoutWaitingOrReopeningTerminalJobs() throws {
        // Match IndexJobRunner admission: pending/failed_retryable and a NULL
        // or already elapsed not_before. A future deadline stays recoverable.
        let fixture = try parsed()
        try writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET not_before = '2000-01-01 00:00:00' WHERE id = ?",
            arguments: [try XCTUnwrap(fixture.receipt.requiredFTSJobID)]) }
        _ = try ready(load(fixture))
        try assertReady(fixture)
    }

    func testNilRequiredJobForNormalSessionCannotAdvanceReadyHead() throws {
        let fixture = try parsed()
        try corrupt(fixture, assignment: "required_fts_job_id = NULL")
        let before = try state()
        assertError(.requiredJobChanged) { try ready(load(fixture)) }
        XCTAssertEqual(try state(), before)
    }

    func testFreshSkipGenerationHasExplicitNotApplicableDispositionAndNoVisibleFTS() throws {
        let fixture = try parsed(agentRole: "dispatched")
        XCTAssertNil(fixture.receipt.requiredFTSJobID)
        let result = try ready(load(fixture))
        XCTAssertEqual(result.disposition, .skipNotApplicable)
        XCTAssertNil(result.requiredFTSJobID)
        XCTAssertEqual(try fts(fixture), [])
        XCTAssertEqual(try head(fixture, column: "last_ready_generation_id"), fixture.receipt.generationID)
        XCTAssertEqual(try ledgerStatus(fixture), "index_ready")
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT tier FROM sessions WHERE id = ?",
            arguments: [fixture.receipt.sessionID]) }, "skip")
    }

    func testBecomingSkipAfterPreparationPurgesOnlyItsExactCurrentFTSAndMarksNotApplicable() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["retained-before-skip"])
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = ?", arguments: [fixture.receipt.sessionID])
        }
        let result = try ready(snapshot)
        XCTAssertEqual(result.disposition, .skipNotApplicable)
        XCTAssertEqual(try fts(fixture), [])
        XCTAssertEqual(try jobStatus(fixture), "not_applicable")
        XCTAssertEqual(try head(fixture, column: "last_ready_generation_id"), fixture.receipt.generationID)
    }

    func testLedgerMustStillBeParsedOrAnExactlyMatchingReadyReplay() throws {
        for status in ["pending", "processing", "failed_retryable", "quarantined", "index_ready"] {
            let fixture = try parsed(nativeID: "ledger-\(status)")
            let snapshot = try load(fixture)
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = ? WHERE publication_sha256 = ? AND parser_revision = ?",
                arguments: [status, fixture.publicationSHA256, revision]) }
            let before = try state()
            assertError(.invalidStoredRecord) { try ready(snapshot) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testArtifactChangedAfterPreparationCannotUseOwnedPayloadAsCurrentAuthority() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        try corrupt(fixture, assignment: "normalized_messages_sha256 = '\(String(repeating: "f", count: 64))'")
        let before = try state()
        assertError(.invalidStoredRecord) { try ready(snapshot) }
        XCTAssertEqual(try state(), before)
    }

    func testVersionedRebuildUsesActualCapturePayloadAndReopenedExactJob() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        _ = try ready(snapshot)
        _ = try parsed(nativeID: "keep-rebuild-pending")
        try writer.write { db in
            try db.execute(sql: "UPDATE metadata SET value = 'old-version' WHERE key = 'fts_version'")
            try FTSRebuildPolicy.apply(db)
        }
        XCTAssertEqual(try jobStatus(fixture), "pending")
        _ = try ready(snapshot)
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture, table: "sessions_fts_rebuild"), try expectedFTS(fixture))
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
    }

    func testFTSMapInsertFailureRollsBackRawFTSBeforeOuterWriterContinues() throws {
        try assertRollback(event: "INSERT", table: "fts_map", condition: "", seedFTS: false)
    }

    func testFTSMapDeleteFailureRestoresPreviousSearchCorpusBeforeOuterWriterContinues() throws {
        try assertRollback(event: "DELETE", table: "fts_map", condition: "", seedFTS: true)
    }

    func testExactJobUpdateFailureRollsBackFTSMapAndShadow() throws {
        try assertRollback(event: "UPDATE", table: "session_index_jobs", condition: "WHEN NEW.status = 'completed'", rebuild: true)
    }

    func testLedgerReadyFailureRollsBackFTSJobAndAnyTriggerSideEffects() throws {
        try assertRollback(event: "UPDATE", table: "capture_ingest_ledger", condition: "WHEN NEW.status = 'index_ready'")
    }

    func testReadyHeadFailureRollsBackEveryEarlierReadinessWrite() throws {
        try assertRollback(event: "UPDATE", table: "capture_ingest_identity_bindings", condition: "WHEN NEW.last_ready_generation_id IS NOT NULL")
    }

    func testSkipNotApplicableFailureRestoresPurgedFTSAndEveryEarlierWrite() throws {
        try assertRollback(event: "UPDATE", table: "session_index_jobs", condition: "WHEN NEW.status = 'not_applicable'",
                           seedFTS: true, becomeSkip: true)
    }

    func testOuterTransactionRollbackRestoresSuccessfulInnerReadiness() throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        let before = try state()
        XCTAssertThrowsError(try writer.write { db in
            _ = try CaptureIngestReadiness.commit(db, snapshot: snapshot, expectedParserRevision: revision,
                enabledSources: [.claudeCode])
            throw FixtureFailure.outerRollback
        }) { XCTAssertEqual($0 as? FixtureFailure, .outerRollback) }
        XCTAssertEqual(try state(), before)
    }

    // This slice deliberately starts after verified replay. It uses a real T2
    // transaction and real SQLite/FTS but never opens source files or credentials.
    private struct Fixture {
        let receipt: CaptureIngestCommittedGeneration
        let publicationSHA256: String
        let native: CaptureIngestIdentity
        let binding: CaptureIngestSourceBinding
        let messages: [NormalizedMessage]
    }

    private enum FixtureFailure: Error, Equatable { case outerRollback }

    private func parsed(nativeID: String = "native-session", messages: [NormalizedMessage]? = nil,
                        agentRole: String? = nil) throws -> Fixture {
        let messages = messages ?? [
            .init(role: .system, content: "system-only-needle", timestamp: timestamp),
            .init(role: .user, content: "  needleunique user text  ", timestamp: timestamp),
            .init(role: .assistant, content: "Implemented the requested stable reader and verified the complete result.", timestamp: timestamp,
                  toolCalls: [.init(name: "edit_file", input: "raw fixture input", output: "raw fixture output")],
                  usage: .init(inputTokens: 10, outputTokens: 20, cacheReadTokens: 3, cacheCreationTokens: 4)),
            .init(role: .tool, content: "tool-only-needle", timestamp: timestamp),
            .init(role: .user, content: " \n\t"),
        ]
        let binding = try writer.write { db in
            if let existing = try CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instance) { return existing }
            return try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                source: .claudeCode, parseFormat: .claudeDefault, configuredRoot: "/offline-client/.claude/projects", initialEpoch: epoch)
        }
        let ordinal = nextOrdinal
        nextOrdinal += 1
        let raw = try ArchiveCanonicalJSON.encode(messages)
        let rawHash = ArchiveV2Hash.sha256(raw)
        let relative = "project/\(ArchiveV2Hash.sha256(Data(nativeID.utf8))).jsonl"
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("\(ordinal):\(nativeID)".utf8)), machineID: machine, source: "claude-code",
            locator: binding.configuredRoot + "/" + relative, sessionID: nil, capturedAt: timestamp,
            generation: .init(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: rawHash, rawByteCount: Int64(raw.count),
            chunks: [try .init(ordinal: 0, rawSHA256: rawHash, rawByteCount: Int64(raw.count))],
            replayLayout: .init(strategy: .singleFile, relativePaths: [relative]))
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: binding.approvedEpoch, sequence: ordinal, manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
        let digest = try publication.sha256()
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: ordinal,
            publicationSHA256: digest, manifestSHA256: publication.manifestSHA256, storedAt: timestamp)
        let page = try CollectorPublicationPage(items: [try .init(publication: publication, ack: ack)],
            afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: ordinal).encoded(), hasMore: false)
        let claim = try writer.write { db in
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: CaptureIngestLedger.checkpoint(db, serverID: "hq"),
                serverID: "hq", parserRevision: revision)
            return try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: digest, parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let identity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: instance, source: .claudeCode, nativeID: nativeID)
        let info = NormalizedSessionInfo(id: nativeID, source: .claudeCode, startTime: timestamp, endTime: timestamp,
            cwd: "/offline-client/project", project: "fixture", model: "offline-fixture", messageCount: messages.count,
            userMessageCount: messages.filter { $0.role == .user }.count,
            assistantMessageCount: messages.filter { $0.role == .assistant }.count,
            toolMessageCount: messages.filter { $0.role == .tool }.count,
            systemMessageCount: messages.filter { $0.role == .system }.count,
            summary: "Complete fixture summary", displayTitle: "Readiness fixture", filePath: manifest.locator,
            sizeBytes: manifest.rawByteCount, agentRole: agentRole, originator: "claude-code")
        let replay = CaptureIngestReplayResult(publicationSHA256: digest, verifiedManifest: manifest, bindingSnapshot: binding,
            scan: .init(info: info, messages: messages), rawSourceSessionID: nativeID, nativeIdentity: identity,
            parentIdentity: nil, suggestedParentIdentity: nil)
        let receipt = try writer.write { db in
            let result = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            // These fixtures exercise readiness, not the producer debounce clock.
            if let job = result.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [job])
            }
            return result
        }
        return .init(receipt: receipt, publicationSHA256: digest, native: identity, binding: binding, messages: messages)
    }

    private func load(_ fixture: Fixture, sessionID: String? = nil, generationID: String? = nil,
                      parser: String? = nil, sources: Set<SourceName> = [.claudeCode],
                      deadline: ContinuousClock.Instant? = nil) throws -> CaptureIngestNormalizedSnapshot {
        try writer.read { try CaptureIngestNormalizedStore.load($0, sessionID: sessionID ?? fixture.receipt.sessionID,
            generationID: generationID ?? fixture.receipt.generationID, expectedParserRevision: parser ?? revision,
            enabledSources: sources, deadline: deadline) }
    }

    private func ready(_ snapshot: CaptureIngestNormalizedSnapshot, parser: String? = nil,
                       sources: Set<SourceName> = [.claudeCode], deadline: ContinuousClock.Instant? = nil) throws -> CaptureIngestReadyGeneration {
        try writer.write { try CaptureIngestReadiness.commit($0, snapshot: snapshot, expectedParserRevision: parser ?? revision,
            enabledSources: sources, deadline: deadline) }
    }

    private func corrupt(_ fixture: Fixture, assignment: String) throws {
        try writer.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try db.execute(sql: "UPDATE capture_ingest_generations SET \(assignment) WHERE generation_id = ?",
                           arguments: [fixture.receipt.generationID])
        }
    }

    private func head(_ fixture: Fixture, column: String) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT \(column) FROM capture_ingest_identity_bindings WHERE stored_session_id = ?",
            arguments: [fixture.receipt.sessionID]) }
    }

    private func ledgerStatus(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT status FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
            arguments: [fixture.publicationSHA256, revision]) }
    }

    private func jobStatus(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT status FROM session_index_jobs WHERE id = ?",
            arguments: [try XCTUnwrap(fixture.receipt.requiredFTSJobID)]) }
    }

    private func fts(_ fixture: Fixture, table: String = "sessions_fts") throws -> [String] {
        try writer.read { try String.fetchAll($0, sql: "SELECT content FROM \(table) WHERE session_id = ? ORDER BY rowid",
            arguments: [fixture.receipt.sessionID]) }
    }

    private func expectedFTS(_ fixture: Fixture) throws -> [String] {
        var result = fixture.messages.filter { ($0.role == .user || $0.role == .assistant)
            && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.content)
        if let summary = try writer.read({ try String.fetchOne($0, sql: "SELECT summary FROM sessions WHERE id = ?", arguments: [fixture.receipt.sessionID]) }),
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(summary) }
        return result
    }

    private func assertReady(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try ledgerStatus(fixture), "index_ready", file: file, line: line)
        XCTAssertEqual(try jobStatus(fixture), "completed", file: file, line: line)
        XCTAssertEqual(try head(fixture, column: "last_ready_generation_id"), fixture.receipt.generationID, file: file, line: line)
        XCTAssertEqual(try head(fixture, column: "last_parsed_generation_id"), fixture.receipt.generationID, file: file, line: line)
    }

    private func state(_ db: Database) throws -> [String: [Row]] {
        var result: [String: [Row]] = [:]
        for table in ["sessions", "session_local_state", "session_relations", "session_costs", "session_tools", "session_index_jobs",
                      "sessions_fts", "sessions_fts_rebuild", "fts_map", "metadata", "capture_ingest_generations",
                      "capture_ingest_identity_bindings", "capture_ingest_ledger", "capture_ingest_source_registry", "capture_ingest_epoch_history"]
            where try db.tableExists(table) {
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    private func state() throws -> [String: [Row]] { try writer.read { try state($0) } }

    private func assertError<T>(_ expected: CaptureIngestReadinessError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestReadinessError, expected, file: file, line: line)
        }
    }

    private func assertRollback(event: String, table: String, condition: String,
                                seedFTS: Bool = false, rebuild: Bool = false, becomeSkip: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try parsed()
        let snapshot = try load(fixture)
        try writer.write { db in
            if seedFTS { try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["previous corpus"] ) }
            if rebuild {
                try db.execute(sql: "UPDATE metadata SET value = 'old' WHERE key = 'fts_version'")
                try FTSRebuildPolicy.apply(db)
            }
            if becomeSkip {
                try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = ?", arguments: [fixture.receipt.sessionID])
            }
        }
        let before = try state()
        var continued = false
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER readiness_fault AFTER \(event) ON \(table) \(condition)
                BEGIN
                    UPDATE sessions SET custom_name = 'trigger-side-effect';
                    SELECT RAISE(FAIL, 'readiness-stage-fault');
                END
                """)
            XCTAssertThrowsError(try CaptureIngestReadiness.commit(db, snapshot: snapshot, expectedParserRevision: revision,
                enabledSources: [.claudeCode]), file: file, line: line) {
                XCTAssertTrue($0 is DatabaseError, "Actual write fault must be reached", file: file, line: line)
                XCTAssertEqual(($0 as? DatabaseError)?.message, "readiness-stage-fault", file: file, line: line)
            }
            XCTAssertEqual(try state(db), before, "Inner savepoint must roll back before outer continuation", file: file, line: line)
            continued = true
            try db.execute(sql: "DROP TRIGGER readiness_fault")
        }
        XCTAssertTrue(continued, file: file, line: line)
        XCTAssertEqual(try state(), before, file: file, line: line)
    }
}

// Capture statement text only, never bound transcript data or expanded SQL.
private final class ReadinessStatementTrace {
    var statements: [String] = []

    static func projectsPayload(_ statement: String) -> Bool {
        let sql = statement.lowercased()
        guard sql.contains("select") else { return false }
        let withoutMetadata = sql.replacingOccurrences(
            of: #"\b(?:length|typeof)\s*\(\s*(?:[a-z_][a-z0-9_]*\.)?normalized_messages_json\s*\)"#,
            with: "", options: .regularExpression)
        if withoutMetadata.contains("normalized_messages_json") { return true }
        return withoutMetadata.contains("capture_ingest_generations")
            && withoutMetadata.range(of: #"(?:\bselect|,)\s*(?:[a-z_][a-z0-9_]*\.)?\*"#,
                                     options: .regularExpression) != nil
    }

    func install(_ db: Database) {
        sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            Unmanaged<ReadinessStatementTrace>.fromOpaque(context).takeUnretainedValue().statements.append(String(cString: sql))
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func remove(_ db: Database) { sqlite3_trace_v2(db.sqliteConnection, 0, nil, nil) }
}
