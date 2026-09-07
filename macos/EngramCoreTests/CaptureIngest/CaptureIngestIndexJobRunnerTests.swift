import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import XCTest

final class CaptureIngestIndexJobRunnerTests: XCTestCase {
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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: directory.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testDefaultOffNeverInvokesLegacyAdapterOrMutatesCaptureJob() async throws {
        let fixture = try parsed()
        let spy = CaptureRunnerSpyAdapter()
        let runner = IndexJobRunner(writer: writer, adapters: [spy])
        let before = try state()
        let result = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(result.result.completed, 0)
        XCTAssertEqual(result.result.notApplicable, 0)
        XCTAssertTrue(result.drained)
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try job(fixture)["status"] as String, "pending")
        XCTAssertNil(try runner.recommendedFtsRetryDelayNanoseconds())
    }

    func testEnabledCaptureConsumesCompleteNormalizedMessagesWithNoAdapters() async throws {
        let fixture = try parsed()
        let runner = makeRunner()
        let result = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(result.result.completed, 1)
        XCTAssertEqual(result.result.notApplicable, 0)
        XCTAssertTrue(result.drained)
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
        XCTAssertFalse(try fts(fixture).contains("legacy-adapter-must-not-be-read"))
        XCTAssertEqual(try normalizedMessages(fixture), fixture.messages)
    }

    func testEnabledCaptureNeverCallsAnAvailableLegacyAdapter() async throws {
        let fixture = try parsed()
        let spy = CaptureRunnerSpyAdapter()
        let runner = makeRunner(adapters: [spy])
        _ = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(spy.calls, 0)
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
    }

    func testDisabledCapturePolicyDoesNotBecomeNotApplicableOrActionableBacklog() async throws {
        _ = try parsed()
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [])
        try await assertDeferred(makeRunner(policy: policy, adapters: [CaptureRunnerSpyAdapter()]))
    }

    func testParserRevisionMismatchDefersWithoutChangingJobOrPayload() async throws {
        _ = try parsed()
        let policy = CaptureFTSReadinessPolicy(parserRevision: "different-parser", enabledSources: [.claudeCode])
        try await assertDeferred(makeRunner(policy: policy, adapters: [CaptureRunnerSpyAdapter()]))
    }

    func testMissingBindingReservedCaptureIdentityNeverFallsBack() async throws {
        try seedLegacy(id: "remote:capture-v1.reserved:missing-binding", owner: "legacy")
        try seedLegacy(id: "alias-reserved-owner", owner: "capture-v1.reserved")
        let spy = CaptureRunnerSpyAdapter()
        try await assertDeferred(makeRunner(adapters: [spy]))
        XCTAssertEqual(spy.calls, 0)
    }

    func testMissingCaptureTablesStillFenceReservedIdentities() async throws {
        try seedLegacy(id: "remote:capture-v1.missing-table:session", owner: "legacy")
        try seedLegacy(id: "alias-missing-table", owner: "capture-v1.reserved")
        try writer.write { db in
            try db.execute(sql: "DROP TABLE capture_ingest_generations")
            try db.execute(sql: "DROP TABLE capture_ingest_identity_bindings")
        }
        let spy = CaptureRunnerSpyAdapter()
        try await assertDeferred(makeRunner(adapters: [spy]))
        XCTAssertEqual(spy.calls, 0)
    }

    func testBoundAliasIsOwnedEvenWhenItsIDAndOwnerAreNotReserved() async throws {
        let fixture = try parsed()
        try seedLegacy(id: "opaque-existing-alias", owner: "local")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id, stored_session_id) VALUES (?, ?, 'claude-code', 'alias-native', 'opaque-existing-alias')",
                           arguments: [machine, instance])
            try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = ?", arguments: [try jobID(fixture)])
        }
        let spy = CaptureRunnerSpyAdapter()
        try await assertDeferred(makeRunner(adapters: [spy]))
        XCTAssertEqual(spy.calls, 0)
    }

    func testMissingParsedHeadIsDeferredBeforeNormalizedPayloadConsumption() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_parsed_generation_id = NULL WHERE stored_session_id = ?",
                           arguments: [fixture.receipt.sessionID])
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = X'00' WHERE generation_id = ?",
                           arguments: [fixture.receipt.generationID])
        }
        let hook = CaptureRunnerFlag()
        let runner = makeRunner(adapters: [CaptureRunnerSpyAdapter()])
        runner.afterCaptureLoadForTesting = { hook.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(hook.value, "Excluded rows must not attempt normalized loading, even corrupt payloads")
    }

    func testOffloadedCaptureRetainsCompactLastGoodWithoutLoadingOrLegacyShadowRewrite() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = ?", arguments: [fixture.receipt.sessionID])
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["compact-last-good"])
        }
        let spy = CaptureRunnerSpyAdapter()
        let hook = CaptureRunnerFlag()
        let runner = makeRunner(adapters: [spy])
        runner.afterCaptureLoadForTesting = { hook.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(hook.value)
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(try fts(fixture), ["compact-last-good"])
    }

    func testFutureCaptureDebounceIsBacklogButNotDueUntilMadeDue() async throws {
        let fixture = try parsed()
        try writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET not_before = datetime('now', '+40 seconds') WHERE id = ?",
                                         arguments: [try jobID(fixture)]) }
        let runner = makeRunner()
        let before = try state()
        let result = try await runner.runRecoverableJobsOnce()
        XCTAssertFalse(result.drained)
        XCTAssertEqual(result.result.completed, 0)
        XCTAssertEqual(try state(), before)
        let delay = try XCTUnwrap(runner.recommendedFtsRetryDelayNanoseconds())
        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThanOrEqual(delay, 40_000_000_000)
        try writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [try jobID(fixture)]) }
        _ = try await runner.runRecoverableJobsOnce()
        try assertReady(fixture)
    }

    func testCurrentCorruptPayloadGetsBoundedSafeRetryAndPreservesLastGood() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["last-good-kept"])
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = ? WHERE generation_id = ?",
                           arguments: [Data("private-corrupt-payload-secret".utf8), fixture.receipt.generationID])
        }
        let runner = makeRunner()
        for attempt in 1...3 {
            _ = try await runner.runRecoverableJobsOnce()
            let current = try job(fixture)
            XCTAssertEqual(current["retry_count"] as Int, attempt)
            XCTAssertEqual(current["status"] as String, attempt == 3 ? "failed_permanent" : "failed_retryable")
            let code: String = try XCTUnwrap(current["last_error"] as String?)
            XCTAssertLessThanOrEqual(code.utf8.count, 64)
            XCTAssertFalse(code.contains("private-corrupt"))
            XCTAssertFalse(code.contains(fixture.receipt.sessionID))
            XCTAssertEqual(try fts(fixture), ["last-good-kept"])
            XCTAssertEqual(try ledgerStatus(fixture), "parsed")
            if attempt < 3 {
                XCTAssertNotNil(current["not_before"] as String?)
                try writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [try jobID(fixture)]) }
            }
        }
        let terminal = try state()
        _ = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(try state(), terminal, "No automatic reopening of a permanent generation failure")
    }

    func testCurrentSchemaCorruptionGetsSafeRetryRatherThanBusyLoop() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_schema_version = 2 WHERE generation_id = ?",
                           arguments: [fixture.receipt.generationID])
        }
        _ = try await makeRunner().runRecoverableJobsOnce()
        XCTAssertEqual(try job(fixture)["status"] as String, "failed_retryable")
        XCTAssertEqual(try job(fixture)["retry_count"] as Int, 1)
    }

    func testCurrentOversizedMessageCountGetsBoundedRetryWithoutReadyPromotion() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_message_count = 10001 WHERE generation_id = ?", arguments: [fixture.receipt.generationID])
        }
        _ = try await makeRunner().runRecoverableJobsOnce()
        XCTAssertEqual(try job(fixture)["status"] as String, "failed_retryable")
        XCTAssertEqual(try job(fixture)["retry_count"] as Int, 1)
        XCTAssertEqual(try ledgerStatus(fixture), "parsed")
        XCTAssertNil(try readyHead(fixture))
    }

    func testExpiredDeadlineNeverRecordsRetryOrReadiness() async throws {
        _ = try parsed()
        let runner = makeRunner(policy: .init(parserRevision: revision, enabledSources: [.claudeCode], deadline: ContinuousClock.now.advanced(by: .seconds(-1))))
        let before = try state()
        do { _ = try await runner.runRecoverableJobsOnce() }
        catch { XCTAssertEqual(error as? CaptureIngestReadinessError, .deadlineExceeded) }
        XCTAssertEqual(try state(), before)
    }

    func testSkipWithExistingRequiredJobPurgesFTSAndCommitsSkipReadiness() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["must-purge-skip"])
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = ?", arguments: [fixture.receipt.sessionID])
        }
        let result = try await makeRunner().runRecoverableJobsOnce()
        XCTAssertEqual(result.result.notApplicable, 1)
        XCTAssertEqual(try job(fixture)["status"] as String, "not_applicable")
        XCTAssertEqual(try ledgerStatus(fixture), "index_ready")
        XCTAssertEqual(try readyHead(fixture), fixture.receipt.generationID)
        XCTAssertEqual(try fts(fixture), [])
    }

    func testActiveRebuildCompletesFromNormalizedCaptureAndPreservesExcludedLastGood() async throws {
        let fixture = try parsed()
        try seedLegacy(id: "remote:capture-v1.excluded:old", owner: "capture-v1.excluded")
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: "remote:capture-v1.excluded:old", contents: ["excluded-last-good"])
            try db.execute(sql: "UPDATE metadata SET value = 'old' WHERE key = 'fts_version'")
            try FTSRebuildPolicy.apply(db)
        }
        _ = try await makeRunner().runRecoverableJobsOnce()
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
        try writer.read { db in
            XCTAssertFalse(try db.tableExists("sessions_fts_rebuild"))
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'fts_version'"), FTSRebuildPolicy.expectedVersion)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = 'remote:capture-v1.excluded:old'"), ["excluded-last-good"])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM session_index_jobs WHERE session_id = 'remote:capture-v1.excluded:old'"), "pending")
        }
    }

    func testPolicyRevocationAfterLoadDefersWithoutWrites() async throws {
        _ = try parsed()
        let policy = CaptureRunnerPolicyBox(enabledPolicy)
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy.value })
        try await assertLoadRace(runner: runner) { policy.value = nil }
    }

    func testOffloadAfterLoadDefersWithoutWrites() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE sessions SET offload_state = 'offloaded' WHERE id = ?", arguments: [fixture.receipt.sessionID]) }
        }
    }

    func testParserPolicyChangedAfterLoadDefersWithoutWrites() async throws {
        _ = try parsed()
        let policy = CaptureRunnerPolicyBox(enabledPolicy)
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy.value })
        try await assertLoadRace(runner: runner) {
            policy.value = .init(parserRevision: "replacement-parser", enabledSources: [.claudeCode])
        }
    }

    func testRequiredJobIdentityChangedAfterLoadDefersWithoutWrites() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE capture_ingest_generations SET required_fts_job_id = NULL WHERE generation_id = ?", arguments: [fixture.receipt.generationID]) }
        }
    }

    func testJobDeadlineChangedAfterLoadDefersWithoutWrites() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET not_before = datetime('now', '+60 seconds') WHERE id = ?", arguments: [try self.jobID(fixture)]) }
        }
    }

    func testJobStatusChangedAfterLoadDefersWithoutWrites() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = ?", arguments: [try self.jobID(fixture)]) }
        }
    }

    func testIdentityVersionChangedAfterLoadDoesNotMisclassifyInvalidStoredRecordAsRetry() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_sync_version = last_sync_version + 1 WHERE stored_session_id = ?", arguments: [fixture.receipt.sessionID]) }
        }
    }

    func testCaptureReadinessDatabaseFailurePropagatesWithoutRetryOrPartialWrites() async throws {
        _ = try parsed()
        try writer.write { try $0.execute(sql: "CREATE TEMP TRIGGER fail_capture_write AFTER INSERT ON fts_map BEGIN SELECT RAISE(FAIL, 'injected-database-fault'); END") }
        let before = try state()
        do { _ = try await makeRunner().runRecoverableJobsOnce(); XCTFail("Must propagate the actual database failure") }
        catch { XCTAssertEqual((error as? DatabaseError)?.message, "injected-database-fault") }
        XCTAssertEqual(try state(), before)
    }

    func testJobRetryTupleChangedAfterLoadIsNotCompletedOrRetriedAgain() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE session_index_jobs SET retry_count = retry_count + 1, last_error = 'other-worker' WHERE id = ?",
                                                  arguments: [try self.jobID(fixture)]) }
        }
    }

    func testEpochAuthorityChangedAfterLoadDefersWithoutWrites() async throws {
        _ = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { db in
                _ = try CaptureIngestSourceRegistry.approveEpoch(db, machineID: self.machine, sourceInstanceID: self.instance,
                    candidateEpoch: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", expectedEpoch: self.epoch, expectedAuthorityGeneration: 1)
            }
        }
    }

    func testNewParsedHeadAfterLoadCannotBeOverwrittenByOldJob() async throws {
        _ = try parsed()
        try await assertLoadRace(runner: makeRunner()) { _ = try self.parsed() }
    }

    func testSessionVersionChangedAfterLoadDoesNotPoisonJob() async throws {
        let fixture = try parsed()
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE sessions SET sync_version = sync_version + 1 WHERE id = ?", arguments: [fixture.receipt.sessionID]) }
        }
    }

    func testCorruptLoadThenAuthorityChangeCannotRecordRetry() async throws {
        let fixture = try parsed()
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = X'00' WHERE generation_id = ?",
                                         arguments: [fixture.receipt.generationID]) }
        try await assertLoadRace(runner: makeRunner()) {
            try self.writer.write { try $0.execute(sql: "UPDATE sessions SET snapshot_hash = ? WHERE id = ?",
                                                  arguments: [String(repeating: "b", count: 64), fixture.receipt.sessionID]) }
        }
    }

    func testParentCancellationAfterLoadRollsBackWithoutRetry() async throws {
        _ = try parsed()
        let runner = makeRunner()
        let pause = CaptureRunnerPause()
        runner.afterCaptureLoadForTesting = { await pause.wait() }
        let before = try state()
        let task = Task { try await runner.runRecoverableJobsOnce() }
        await fulfillment(of: [pause.entered], timeout: 2)
        task.cancel()
        await pause.release()
        do { _ = try await task.value; XCTFail("Parent cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try state(), before)
    }

    func testAlreadyCancelledEntryCannotFinalizeRebuildOrLoadCapture() async throws {
        let fixture = try parsed()
        try writer.write { db in
            try FTSRebuildPolicy.replaceFtsContent(db, sessionId: fixture.receipt.sessionID, contents: ["cancel-last-good"])
            try db.execute(sql: "UPDATE metadata SET value = 'old' WHERE key = 'fts_version'")
            try FTSRebuildPolicy.apply(db)
        }
        let runner = makeRunner()
        let pause = CaptureRunnerPause()
        let before = try state()
        let task = Task {
            await pause.wait()
            return try await runner.runRecoverableJobsOnce()
        }
        await fulfillment(of: [pause.entered], timeout: 2)
        task.cancel()
        await pause.release()
        do { _ = try await task.value; XCTFail("Already cancelled entry must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try state(), before)
    }

    func testParentCancellationInsideActualReadinessWriterRollsBackEveryTable() async throws {
        _ = try parsed()
        let runner = makeRunner()
        let pause = CaptureRunnerPause()
        let cancelledDuringWrite = CaptureRunnerFlag()
        let cancel = CaptureRunnerCancellation()
        runner.afterCaptureLoadForTesting = { await pause.wait() }
        try writer.write { db in
            db.add(function: DatabaseFunction("cancel_capture_runner", argumentCount: 0, pure: false) { _ in
                cancelledDuringWrite.set()
                cancel.perform()
                return 1
            })
            // The ordinary fts_map row is written from the real readiness FTS
            // transaction. Cancelling here must roll back FTS, map and readiness.
            try db.execute(sql: "CREATE TEMP TRIGGER cancel_capture_write AFTER INSERT ON fts_map BEGIN SELECT cancel_capture_runner(); END")
        }
        let before = try state()
        let task = Task { try await runner.runRecoverableJobsOnce() }
        cancel.action = { task.cancel() }
        await fulfillment(of: [pause.entered], timeout: 2)
        await pause.release()
        do { _ = try await task.value; XCTFail("Cancellation inside actual writer must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        cancel.action = nil
        XCTAssertTrue(cancelledDuringWrite.value, "Must reach the actual GRDB writer, not only a test hook")
        XCTAssertEqual(try state(), before)
    }

    func testPolicyRevocationInsideActualReadinessWriterRollsBackEveryTable() async throws {
        let fixture = try parsed()
        let policy = CaptureRunnerPolicyBox(enabledPolicy)
        let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy.value })
        let revokedDuringWrite = CaptureRunnerFlag()
        let deletedVectorDuringWrite = CaptureRunnerFlag()
        try writer.write { db in
            try db.execute(sql: "INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding) VALUES ('capture-vector', ?, 0, 'summary-only', ?)",
                           arguments: [fixture.receipt.sessionID, Data([0, 0, 128, 63])])
            db.add(function: DatabaseFunction("observe_capture_vector_delete", argumentCount: 0, pure: false) { _ in
                deletedVectorDuringWrite.set()
                return 1
            })
            try db.execute(sql: "CREATE TEMP TRIGGER observe_capture_vector AFTER DELETE ON semantic_chunks BEGIN SELECT observe_capture_vector_delete(); END")
            db.add(function: DatabaseFunction("revoke_capture_policy", argumentCount: 0, pure: false) { _ in
                revokedDuringWrite.set()
                policy.value = nil
                return 1
            })
            try db.execute(sql: "CREATE TEMP TRIGGER revoke_capture_write AFTER INSERT ON fts_map BEGIN SELECT revoke_capture_policy(); END")
        }
        let before = try state()
        let vectors = try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM semantic_chunks ORDER BY id") }
        let result = try await runner.runRecoverableJobsOnce()
        XCTAssertTrue(revokedDuringWrite.value, "Must revoke policy inside actual readiness writes")
        XCTAssertTrue(deletedVectorDuringWrite.value, "Must attempt the real first-FTS embedding requeue before rollback")
        XCTAssertEqual(result.result.completed, 0)
        XCTAssertEqual(result.result.notApplicable, 0)
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM semantic_chunks ORDER BY id") }, vectors)
    }

    func testMissingEpochHistoryIsExcludedBeforeLoadAndIsNotDueBacklog() async throws {
        _ = try parsed()
        try writer.write { try $0.execute(sql: "DELETE FROM capture_ingest_epoch_history") }
        let loaded = CaptureRunnerFlag()
        let runner = makeRunner()
        runner.afterCaptureLoadForTesting = { loaded.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(loaded.value, "Unverifiable registry authority must not load normalized data")
    }

    func testEpochHistoryRevokedAfterLoadCannotWriteOrRemainDue() async throws {
        _ = try parsed()
        let runner = makeRunner()
        try await assertLoadRace(runner: runner) {
            try writer.write { try $0.execute(sql: "DELETE FROM capture_ingest_epoch_history") }
        }
        XCTAssertNil(try runner.recommendedFtsRetryDelayNanoseconds())
        try await assertDeferred(runner)
    }

    func testSiblingRegistryMissingHistoryIsExcludedBeforeLoad() async throws {
        _ = try parsed()
        let sibling = try provisionSibling()
        try writer.write { try $0.execute(sql: "DELETE FROM capture_ingest_epoch_history WHERE source_instance_id = ?", arguments: [sibling]) }
        let loaded = CaptureRunnerFlag()
        let runner = makeRunner()
        runner.afterCaptureLoadForTesting = { loaded.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(loaded.value)
    }

    func testSiblingRegistryOverlapIsExcludedBeforeLoad() async throws {
        _ = try parsed()
        let sibling = try provisionSibling()
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET configured_root = '/offline-client' WHERE source_instance_id = ?", arguments: [sibling]) }
        let loaded = CaptureRunnerFlag()
        let runner = makeRunner()
        runner.afterCaptureLoadForTesting = { loaded.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(loaded.value)
    }

    func testSiblingRegistryOverlapAfterLoadDefersAndIsNotDue() async throws {
        _ = try parsed()
        let sibling = try provisionSibling()
        let runner = makeRunner()
        try await assertLoadRace(runner: runner) {
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET configured_root = '/offline-client' WHERE source_instance_id = ?", arguments: [sibling]) }
        }
        XCTAssertNil(try runner.recommendedFtsRetryDelayNanoseconds())
        try await assertDeferred(runner)
    }

    func testInvalidSessionTierIsExcludedBeforeLoadWithoutRetryWrites() async throws {
        let fixture = try parsed()
        try writer.write { try $0.execute(sql: "UPDATE sessions SET tier = 'invalid-tier' WHERE id = ?", arguments: [fixture.receipt.sessionID]) }
        let loaded = CaptureRunnerFlag()
        let runner = makeRunner()
        runner.afterCaptureLoadForTesting = { loaded.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(loaded.value)
    }

    func testUnrelatedValidSiblingDoesNotSuppressCaptureReadiness() async throws {
        let fixture = try parsed()
        _ = try provisionSibling()
        _ = try await makeRunner().runRecoverableJobsOnce()
        try assertReady(fixture)
    }

    func testMalformedSiblingRootIsExcludedWithoutLoadingOrRetrying() async throws {
        _ = try parsed()
        let sibling = try provisionSibling()
        for root in ["/offline-client/other/..", "/offline-client//other", "/offline-client/other\0suffix"] {
            try writer.write { db in
                // Bind bytes then CAST so the embedded-NUL case is not silently
                // truncated by SQLite's NUL-terminated text binding API.
                try db.execute(sql: "UPDATE capture_ingest_source_registry SET configured_root = CAST(? AS TEXT) WHERE source_instance_id = ?", arguments: [Data(root.utf8), sibling])
                XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT CAST(configured_root AS BLOB) FROM capture_ingest_source_registry WHERE source_instance_id = ?", arguments: [sibling]), Data(root.utf8))
            }
            let loaded = CaptureRunnerFlag()
            let runner = makeRunner()
            runner.afterCaptureLoadForTesting = { loaded.set() }
            try await assertDeferred(runner)
            XCTAssertFalse(loaded.value)
        }
    }

    func testNoncanonicalSiblingEpochEvenWithMatchingHistoryIsNotActionable() async throws {
        _ = try parsed()
        let sibling = try provisionSibling()
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_source_registry SET approved_epoch = lower(approved_epoch) WHERE source_instance_id = ?", arguments: [sibling])
            try db.execute(sql: "UPDATE capture_ingest_epoch_history SET approved_epoch = lower(approved_epoch) WHERE source_instance_id = ?", arguments: [sibling])
        }
        let loaded = CaptureRunnerFlag()
        let runner = makeRunner()
        runner.afterCaptureLoadForTesting = { loaded.set() }
        try await assertDeferred(runner)
        XCTAssertFalse(loaded.value)
    }

    private func provisionSibling() throws -> String {
        let sibling = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
        _ = try writer.write { db in
            try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: sibling,
                source: .claudeCode, parseFormat: .claudeDefault, configuredRoot: "/offline-client/other", initialEpoch: epoch)
        }
        return sibling
    }

    func testLegacyAdapterReturningAfterCaptureOwnershipChangeCannotWriteFTSOrJob() async throws {
        try seedLegacy(id: "legacy-adopted-later", owner: "local")
        let pause = CaptureRunnerPause()
        let spy = CaptureRunnerSpyAdapter(pause: pause)
        let runner = makeRunner(adapters: [spy])
        let task = Task { try await runner.runRecoverableJobsOnce() }
        await fulfillment(of: [pause.entered], timeout: 2)
        try writer.write { try $0.execute(sql: "UPDATE sessions SET authoritative_node = 'capture-v1.new-owner' WHERE id = 'legacy-adopted-later'") }
        let before = try state()
        await pause.release()
        _ = try await task.value
        XCTAssertEqual(spy.calls, 1, "A real legacy read must have been in flight")
        XCTAssertEqual(try state(), before)
    }

    func testLegacyHQPeerStillUsesItsAdapter() async throws {
        try seedLegacy(id: "remote:hq:legacy-session", owner: "hq")
        let spy = CaptureRunnerSpyAdapter()
        let result = try await makeRunner(adapters: [spy]).runRecoverableJobsOnce()
        XCTAssertEqual(result.result.completed, 1)
        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(try writer.read { try String.fetchAll($0, sql: "SELECT content FROM sessions_fts WHERE session_id = 'remote:hq:legacy-session'") }, ["legacy-adapter-must-not-be-read"])
    }

    private var enabledPolicy: CaptureFTSReadinessPolicy {
        .init(parserRevision: revision, enabledSources: [.claudeCode])
    }

    private func makeRunner(policy: CaptureFTSReadinessPolicy? = nil, adapters: [any SessionAdapter] = []) -> IndexJobRunner {
        let current = policy ?? enabledPolicy
        return IndexJobRunner(writer: writer, adapters: adapters, capturePolicy: { current })
    }

    private func assertDeferred(_ runner: IndexJobRunner, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try state()
        let result = try await runner.runRecoverableJobsOnce()
        XCTAssertEqual(result.result.completed, 0, file: file, line: line)
        XCTAssertEqual(result.result.notApplicable, 0, file: file, line: line)
        XCTAssertTrue(result.drained, file: file, line: line)
        XCTAssertNil(try runner.recommendedFtsRetryDelayNanoseconds(), file: file, line: line)
        XCTAssertFalse(try runner.shouldStopFtsDrainWave(), file: file, line: line)
        XCTAssertEqual(try state(), before, file: file, line: line)
    }

    private func assertLoadRace(runner: IndexJobRunner, mutation: () throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let pause = CaptureRunnerPause()
        runner.afterCaptureLoadForTesting = { await pause.wait() }
        let task = Task { try await runner.runRecoverableJobsOnce() }
        await fulfillment(of: [pause.entered], timeout: 2)
        let before: [String: [Row]]
        do { try mutation(); before = try state() }
        catch { await pause.release(); _ = try? await task.value; throw error }
        await pause.release()
        _ = try await task.value
        XCTAssertEqual(try state(), before, "Stale completion must leave all newer state unchanged", file: file, line: line)
    }

    private func seedLegacy(id: String, owner: String) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO sessions(id, source, start_time, file_path, source_locator, authoritative_node, sync_version, snapshot_hash, tier) VALUES (?, 'claude-code', '2026-01-01', '/never-open/legacy.jsonl', '/never-open/legacy.jsonl', ?, 1, 'h', 'normal')",
                           arguments: [id, owner])
            try db.execute(sql: "INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status) VALUES (?, ?, 'fts', 1, 'pending')",
                           arguments: [id + ":1:h:fts", id])
        }
    }

    // The remaining fixture helpers are copied from the existing T3a tests;
    // the producer is a real T2 transaction, not a mocked readiness path.
    private struct Fixture {
        let receipt: CaptureIngestCommittedGeneration
        let publicationSHA256: String
        let native: CaptureIngestIdentity
        let binding: CaptureIngestSourceBinding
        let messages: [NormalizedMessage]
    }

    private func parsed(nativeID: String = "native-session", messages: [NormalizedMessage]? = nil,
                        agentRole: String? = nil) throws -> Fixture {
        let messages: [NormalizedMessage] = messages ?? [
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

    private func jobID(_ fixture: Fixture) throws -> String { try XCTUnwrap(fixture.receipt.requiredFTSJobID) }

    private func job(_ fixture: Fixture) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM session_index_jobs WHERE id = ?", arguments: [try jobID(fixture)])) }
    }

    private func ledgerStatus(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT status FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?", arguments: [fixture.publicationSHA256, revision]) }
    }

    private func readyHead(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT last_ready_generation_id FROM capture_ingest_identity_bindings WHERE stored_session_id = ?", arguments: [fixture.receipt.sessionID]) }
    }

    private func normalizedMessages(_ fixture: Fixture) throws -> [NormalizedMessage] {
        try writer.read { db in
            let data = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT normalized_messages_json FROM capture_ingest_generations WHERE generation_id = ?", arguments: [fixture.receipt.generationID]))
            return try ArchiveCanonicalJSON.decode([NormalizedMessage].self, from: data)
        }
    }

    private func fts(_ fixture: Fixture) throws -> [String] {
        try writer.read { try String.fetchAll($0, sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY rowid", arguments: [fixture.receipt.sessionID]) }
    }

    private func expectedFTS(_ fixture: Fixture) throws -> [String] {
        var values = fixture.messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.content)
        if let summary = try writer.read({ try String.fetchOne($0, sql: "SELECT summary FROM sessions WHERE id = ?", arguments: [fixture.receipt.sessionID]) }), !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append(summary) }
        return values
    }

    private func assertReady(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try job(fixture)["status"] as String, "completed", file: file, line: line)
        XCTAssertEqual(try ledgerStatus(fixture), "index_ready", file: file, line: line)
        XCTAssertEqual(try readyHead(fixture), fixture.receipt.generationID, file: file, line: line)
    }

    private func state() throws -> [String: [Row]] {
        try writer.read { db in
            var result: [String: [Row]] = [:]
            for table in ["sessions", "session_local_state", "session_relations", "session_costs", "session_tools", "session_index_jobs", "sessions_fts", "sessions_fts_rebuild", "fts_map", "metadata", "capture_ingest_generations", "capture_ingest_identity_bindings", "capture_ingest_ledger", "capture_ingest_source_registry", "capture_ingest_epoch_history"] where try db.tableExists(table) {
                result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return result
        }
    }
}

private final class CaptureRunnerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); defer { lock.unlock() }; stored = true }
}

private final class CaptureRunnerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (() -> Void)?
    var action: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    func perform() { action?() }
}

private final class CaptureRunnerPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureFTSReadinessPolicy?
    init(_ value: CaptureFTSReadinessPolicy?) { stored = value }
    var value: CaptureFTSReadinessPolicy? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private actor CaptureRunnerPause {
    nonisolated let entered = XCTestExpectation(description: "actual capture load or legacy adapter paused")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CaptureRunnerSpyAdapter: SessionAdapter, @unchecked Sendable {
    let source: SourceName = .claudeCode
    private let lock = NSLock()
    private var count = 0
    private let pause: CaptureRunnerPause?
    init(pause: CaptureRunnerPause? = nil) { self.pause = pause }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func countCall() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func detect() async -> Bool { true }
    func listSessionLocators() async throws -> [String] { [] }
    func isAccessible(locator: String) async -> Bool { false }
    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> { .failure(.fileMissing) }
    func streamMessages(locator: String, options: StreamMessagesOptions) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        countCall()
        if let pause { await pause.wait() }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(role: .user, content: "legacy-adapter-must-not-be-read"))
            continuation.finish()
        }
    }
}
