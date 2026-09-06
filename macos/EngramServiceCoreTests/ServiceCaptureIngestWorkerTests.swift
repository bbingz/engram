import Darwin
import EngramCoreRead
@testable import EngramCoreWrite
import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

final class ServiceCaptureIngestWorkerTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let otherInstance = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let otherEpoch = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let revision = "swift-parser-t4a"
    private let logicalRoot = "/offline-client/.claude/projects"

    private var directory: URL!
    private var runtime: URL!
    private var writer: EngramDatabaseWriter!
    private var gate: ServiceWriterGate!
    private var cas: ImmutableArchiveCAS!
    private var stagingParent: URL!
    private var nextOrdinal: Int64 = 1
    private var sqlTrace = SQLTrace()
    private var clock = UnixClock(1000)
    private var policyBox = PolicyBox()

    override func setUpWithError() throws {
        guard let canonicalTemp = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonicalTemp) }
        let root = URL(fileURLWithPath: String(cString: canonicalTemp), isDirectory: true)
            .appendingPathComponent("t4a-worker-\(UUID().uuidString)", isDirectory: true)
        directory = root
        runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let casRoot = root.appendingPathComponent("cas", isDirectory: true)
        try FileManager.default.createDirectory(at: casRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        stagingParent = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        writer = try EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        try writer.write { db in
            db.trace { [sqlTrace] event in sqlTrace.append(event.expandedDescription) }
        }
        let activeWriter = writer!
        gate = try ServiceWriterGate(
            databasePath: root.appendingPathComponent("index.sqlite").path,
            runtimeDirectory: runtime,
            writerFactory: { _ in activeWriter }
        )
        cas = try ImmutableArchiveCAS(root: casRoot)
        try writer.write { db in
            _ = try CaptureIngestSourceRegistry.provision(
                db, machineID: machine, sourceInstanceID: instance, source: .claudeCode,
                parseFormat: .claudeDefault, configuredRoot: logicalRoot, initialEpoch: epoch
            )
        }
        policyBox.set(ServiceCaptureIngestParserPolicy(parserRevision: revision, enabledSources: [.claudeCode]))
    }

    override func tearDownWithError() throws {
        gate = nil
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testCommandNamesAreNotLongRunningClassifications() {
        XCTAssertFalse(ServiceWriterGate.isLongRunningWriteCommand(ServiceCaptureIngestWorker.claimCommandName))
        XCTAssertFalse(ServiceWriterGate.isLongRunningWriteCommand(ServiceCaptureIngestWorker.commitCommandName))
        XCTAssertFalse(ServiceWriterGate.isLongRunningWriteCommand(ServiceCaptureIngestWorker.failureCommandName))
    }

    func testColdConstructionDoesNotCreateWorkOrDirectories() async throws {
        let before = try ledgerSnapshot()
        _ = makeWorker()
        XCTAssertEqual(try ledgerSnapshot(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path), [])
        XCTAssertEqual(try count("sessions"), 0)
    }

    func testDefaultOffPolicySelectsNothingWithoutWorkerSQL() async throws {
        let seeded = try await seedEligible()
        policyBox.set(nil)
        sqlTrace.beginWindow()
        let result = try await makeWorker().step()
        let sql = sqlTrace.endWindow()
        XCTAssertEqual(result, .idle)
        XCTAssertTrue(sql.isEmpty, "default-OFF may emit no worker SQL, got \(sql)")
        XCTAssertEqual(try work(seeded).status, .pending)
        XCTAssertEqual(try work(seeded).attempt, 0)
    }

    func testPositiveParsedHasExactReplayParityUserStateAndScalarPreselection() async throws {
        let seeded = try await seedEligible()
        let independent = try await CaptureIngestReplay.replay(
            publication: seeded.publication, bindingSnapshot: try currentBinding(),
            cas: cas, stagingParent: stagingParent
        )
        sqlTrace.beginWindow()
        let result = try await makeWorker().step()
        let sql = sqlTrace.endWindow()
        guard case .parsed(let receipt) = result else {
            return XCTFail("positive baseline must parse, got \(result)")
        }
        XCTAssertEqual(try work(seeded).status, .parsed)
        try assertExactParsed(seeded, receipt: receipt, independent: independent)
        try assertScalarPreselection(sql, chosen: seeded.digest)
    }

    func testAbsentRegistryIsNotSelectedAndPositiveBaselineParses() async throws {
        let enabled = try await seedEligible(relative: "project/enabled.jsonl", nativeID: "enabled")
        let absent = try await seedEligible(
            relative: "project/absent.jsonl", nativeID: "absent", instanceID: otherInstance, provision: false
        )
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [enabled.digest])
        }
        let result = try await makeWorker().step()
        guard case .parsed(_) = result else { return XCTFail("enabled row is the positive baseline, got \(result)") }
        XCTAssertEqual(try work(enabled).status, .parsed)
        try await assertIdleSecondStepLeaves(absent, expectedStatus: .pending, expectedAttempt: 0)
    }

    func testNullParseFormatIsNotSelected() async throws {
        let enabled = try await seedEligible(relative: "project/ok.jsonl", nativeID: "ok")
        let nullFormat = try await seedEligible(
            source: .claudeCode, format: .claudeDefault,
            configuredRoot: "/offline-client/.claude/projects-null",
            relative: "project/null-format.jsonl", nativeID: "null-format",
            instanceID: otherInstance, provision: true
        )
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_source_registry SET parse_format = NULL
                WHERE source_instance_id = ?
                """, arguments: [otherInstance])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [enabled.digest])
        }
        let result = try await makeWorker().step()
        guard case .parsed(_) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(try work(enabled).status, .parsed)
        try await assertIdleSecondStepLeaves(nullFormat, expectedStatus: .pending, expectedAttempt: 0)
    }

    func testHistoryMismatchIsNotSelected() async throws {
        let enabled = try await seedEligible(relative: "project/hist-ok.jsonl", nativeID: "hist-ok")
        let mismatched = try await seedEligible(
            source: .claudeCode, format: .claudeDefault,
            configuredRoot: "/offline-client/.claude/projects-hist",
            relative: "project/hist-bad.jsonl", nativeID: "hist-bad",
            instanceID: otherInstance, provision: true
        )
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [enabled.digest])
        }
        let result = try await makeWorker().step()
        guard case .parsed(_) = result else { return XCTFail("valid history is the positive baseline, got \(result)") }
        XCTAssertEqual(try work(enabled).status, .parsed)
        // Prove valid work before corrupting a sibling authority; full replay
        // intentionally rejects a source whose registered roots are untrusted.
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM capture_ingest_epoch_history WHERE source_instance_id = ?
                """, arguments: [otherInstance])
        }
        try await assertIdleSecondStepLeaves(mismatched, expectedStatus: .pending, expectedAttempt: 0)
    }

    func testDisabledPolicyAtGateSelectsNothing() async throws {
        let gated = try await seedEligible(relative: "project/gate.jsonl", nativeID: "gate")
        let barrier = WorkerBarrier()
        let worker = makeWorker(hooks: .init(queuedAtGate: { [policyBox] in
            policyBox.set(ServiceCaptureIngestParserPolicy(parserRevision: "swift-parser-t4a", enabledSources: []))
            try await barrier.wait()
        }))
        let gatedDone = Flag()
        let running = Task {
            defer { gatedDone.set() }
            return try await worker.step()
        }
        let gatedEntered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(gatedEntered, "gate barrier must be entered")
        XCTAssertFalse(gatedDone.value, "must not finish before release")
        barrier.release()
        let gatedResult = try await running.value
        XCTAssertEqual(gatedResult, .idle)
        XCTAssertGreaterThanOrEqual(barrier.exited, 1)
        XCTAssertEqual(try work(gated).status, .pending)
        XCTAssertEqual(try work(gated).attempt, 0)
    }

    func testChangedPolicyAroundReplayLeavesProcessing() async throws {
        let replayed = try await seedEligible(relative: "project/replay-policy.jsonl", nativeID: "replay-policy")
        let replayBarrier = WorkerBarrier()
        let replayEntered = Flag()
        let replayWorker = makeWorker(hooks: .init(beforeReplay: {
            try await replayBarrier.wait()
        }, afterReplay: { [policyBox] in
            replayEntered.set()
            policyBox.set(ServiceCaptureIngestParserPolicy(parserRevision: "swift-parser-other", enabledSources: [.claudeCode]))
        }))
        let replayTask = Task { try await replayWorker.step() }
        let replayBarrierEntered = await waitUntil { replayBarrier.entered >= 1 }
        XCTAssertTrue(replayBarrierEntered, "replay barrier must be entered")
        replayBarrier.release()
        let replayResult = try await replayTask.value
        XCTAssertTrue(replayEntered.value, "afterReplay must run")
        XCTAssertGreaterThanOrEqual(replayBarrier.exited, 1)
        assertNotParsed(replayResult, "policy change around replay is neutral")
        if case .recordedFailure = replayResult { XCTFail("policy change around replay is neutral") }
        let after = try work(replayed)
        XCTAssertEqual(after.status, .processing)
        XCTAssertNil(after.failureCode)
        XCTAssertGreaterThan(after.attempt, 0)
        XCTAssertNotNil(after.token)
    }

    func testCreatedAtOrderPicksEarlierRow() async throws {
        let later = try await seedEligible(relative: "project/later.jsonl", nativeID: "later")
        let earlier = try await seedEligible(relative: "project/earlier.jsonl", nativeID: "earlier")
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [earlier.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-02 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [later.digest])
        }
        let first = try await makeWorker().step()
        guard case .parsed(_) = first else { return XCTFail("earlier created_at must win, got \(first)") }
        XCTAssertEqual(try work(earlier).status, .parsed)
        XCTAssertEqual(try work(later).status, .pending)
    }

    func testEqualTimeBinaryDigestTiePicksLesserDigest() async throws {
        let a = try await seedEligible(relative: "project/tie-a.jsonl", nativeID: "tie-a")
        let b = try await seedEligible(relative: "project/tie-b.jsonl", nativeID: "tie-b")
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-03 00:00:00'
                WHERE publication_sha256 IN (?, ?)
                """, arguments: [a.digest, b.digest])
        }
        let winner = a.digest.utf8.lexicographicallyPrecedes(b.digest.utf8) ? a : b
        let loser = winner.digest == a.digest ? b : a
        let tied = try await makeWorker().step()
        guard case .parsed(_) = tied else { return XCTFail("BINARY digest tie must pick the lesser digest, got \(tied)") }
        XCTAssertEqual(try work(winner).status, .parsed)
        XCTAssertEqual(try work(loser).status, .pending)
    }

    func testOtherParserRevisionIsNotSelected() async throws {
        let enabled = try await seedEligible(relative: "project/current-parser.jsonl", nativeID: "current-parser")
        let other = try await seedEligible(
            relative: "project/other-parser.jsonl", nativeID: "other-parser", parser: "swift-parser-other"
        )
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [enabled.digest])
        }
        let result = try await makeWorker().step()
        guard case .parsed(_) = result else { return XCTFail("current parser is the positive baseline, got \(result)") }
        XCTAssertEqual(try work(enabled).status, .parsed)
        try await assertIdleSecondStepLeaves(
            other, parser: "swift-parser-other", expectedStatus: .pending, expectedAttempt: 0
        )
    }

    func testTerminalStatusIsNotSelected() async throws {
        let enabled = try await seedEligible(relative: "project/live-pending.jsonl", nativeID: "live-pending")
        let terminal = try await seedEligible(relative: "project/terminal.jsonl", nativeID: "terminal")
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET status = 'quarantined', failure_code = 'quarantine.invalid_manifest'
                WHERE publication_sha256 = ?
                """, arguments: [terminal.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [enabled.digest])
        }
        let result = try await makeWorker().step()
        guard case .parsed(_) = result else { return XCTFail("pending row is the positive baseline, got \(result)") }
        XCTAssertEqual(try work(enabled).status, .parsed)
        try await assertIdleSecondStepLeaves(terminal, expectedStatus: .quarantined, expectedAttempt: 0)
    }

    func testDueRetryBoundaryLiveLeaseAndExpiredTakeover() async throws {
        let duePending = try await seedEligible(relative: "project/due.jsonl", nativeID: "due")
        let dueRetry = try await seedEligible(relative: "project/due-retry.jsonl", nativeID: "due-retry")
        let futureRetry = try await seedEligible(relative: "project/future-retry.jsonl", nativeID: "future-retry")
        let live = try await seedEligible(relative: "project/live.jsonl", nativeID: "live")
        let expired = try await seedEligible(relative: "project/expired.jsonl", nativeID: "expired")
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = 'failed_retryable', attempt_count = 1, retry_after = 1000,
                    claim_token = NULL, claim_started_at = NULL, claim_expires_at = NULL
                WHERE publication_sha256 = ?
                """, arguments: [dueRetry.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = 'failed_retryable', attempt_count = 1, retry_after = 1001,
                    claim_token = NULL, claim_started_at = NULL, claim_expires_at = NULL
                WHERE publication_sha256 = ?
                """, arguments: [futureRetry.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = 'processing', attempt_count = 1, claim_token = ?, claim_started_at = 900,
                    claim_expires_at = 1100, retry_after = NULL
                WHERE publication_sha256 = ?
                """, arguments: [UUID().uuidString, live.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger
                SET status = 'processing', attempt_count = 1, claim_token = ?, claim_started_at = 100,
                    claim_expires_at = 200, retry_after = NULL
                WHERE publication_sha256 = ?
                """, arguments: [UUID().uuidString, expired.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:00' WHERE publication_sha256 = ?
                """, arguments: [duePending.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:01' WHERE publication_sha256 = ?
                """, arguments: [dueRetry.digest])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '2026-09-01 00:00:02' WHERE publication_sha256 = ?
                """, arguments: [expired.digest])
        }
        let first = try await makeWorker().step()
        guard case .parsed(_) = first else { return XCTFail("due pending is the first positive baseline, got \(first)") }
        XCTAssertEqual(try work(duePending).status, .parsed)
        let second = try await makeWorker().step()
        guard case .parsed(_) = second else { return XCTFail("retry_after == now is due, got \(second)") }
        XCTAssertEqual(try work(dueRetry).status, .parsed)
        XCTAssertEqual(try work(futureRetry).status, .retryableFailure)
        XCTAssertEqual(try work(live).status, .processing)
        let third = try await makeWorker().step()
        guard case .parsed(_) = third else { return XCTFail("expired processing must be takeable, got \(third)") }
        XCTAssertEqual(try work(expired).status, .parsed)
        XCTAssertEqual(try work(futureRetry).status, .retryableFailure)
        XCTAssertEqual(try work(live).status, .processing)
    }

    func testConcurrentStepReturnsBusyWithoutWaitingForTheFirst() async throws {
        _ = try await seedEligible(relative: "project/first.jsonl", nativeID: "first")
        _ = try await seedEligible(relative: "project/second.jsonl", nativeID: "second")
        let barrier = WorkerBarrier()
        let worker = makeWorker(hooks: .init(queuedAtGate: { try await barrier.wait() }))
        let firstDone = Flag()
        let first = Task {
            defer { firstDone.set() }
            return try await worker.step()
        }
        let firstEntered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(firstEntered, "first step must enter the barrier")
        XCTAssertFalse(firstDone.value, "first step must not complete before release")
        let secondDone = Flag()
        let second = Task {
            defer { secondDone.set() }
            return try await worker.step()
        }
        let secondReturned = await waitUntil { secondDone.value }
        if !secondReturned {
            barrier.release()
            _ = try? await first.value
            _ = try? await second.value
            return XCTFail("busy must return without waiting for the first step")
        }
        let busy = try await second.value
        XCTAssertEqual(busy, .busy)
        XCTAssertFalse(firstDone.value, "first step must still be blocked")
        barrier.release()
        _ = try await first.value
        XCTAssertTrue(firstDone.value)
    }

    func testParserRevocationQueuedAtGateRollsBackClaimAndAttempt() async throws {
        let seeded = try await seedEligible()
        let barrier = WorkerBarrier()
        let worker = makeWorker(hooks: .init(queuedAtGate: { [policyBox] in
            policyBox.set(nil)
            try await barrier.wait()
        }))
        let done = Flag()
        let running = Task {
            defer { done.set() }
            return try await worker.step()
        }
        let revokeEntered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(revokeEntered, "gate barrier must be entered")
        XCTAssertFalse(done.value, "must not join before release")
        barrier.release()
        let result = try await running.value
        XCTAssertEqual(result, .idle)
        XCTAssertEqual(try work(seeded).status, .pending)
        XCTAssertEqual(try work(seeded).attempt, 0)
    }

    func testRegistryRevocationAroundReplayLeavesProcessing() async throws {
        let seeded = try await seedEligible()
        let barrier = WorkerBarrier()
        let afterEntered = Flag()
        let writer = self.writer!
        let worker = makeWorker(hooks: .init(beforeReplay: {
            try await barrier.wait()
        }, afterReplay: {
            afterEntered.set()
            try writer.write { db in
                _ = try CaptureIngestSourceRegistry.approveEpoch(
                    db, machineID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                    sourceInstanceID: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB",
                    candidateEpoch: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE",
                    expectedEpoch: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                    expectedAuthorityGeneration: 1
                )
            }
        }))
        let running = Task { try await worker.step() }
        let registryReplayEntered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(registryReplayEntered, "replay barrier must be entered")
        barrier.release()
        let result = try await running.value
        XCTAssertTrue(afterEntered.value, "afterReplay must run")
        let binding = try currentBinding()
        XCTAssertEqual(binding.approvedEpoch, otherEpoch)
        XCTAssertEqual(binding.authorityGeneration, 2)
        let history = try writer.read {
            try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance)
        }
        XCTAssertTrue(history.contains { $0.approvedEpoch == otherEpoch && $0.authorityGeneration == 2 })
        assertNotParsed(result, "stale registry must not parse")
        if case .recordedFailure = result { XCTFail("stale registry must not fabricate a replay failure") }
        let after = try work(seeded)
        XCTAssertEqual(after.status, .processing)
        XCTAssertNil(after.failureCode)
        XCTAssertGreaterThan(after.attempt, 0)
        XCTAssertNotNil(after.token)
    }

    func testChildSkipStaysParsedSkipWithIndependentReplayProof() async throws {
        let seeded = try await seedEligible(
            relative: "project/parent/subagents/agent-one.jsonl", nativeID: "parent"
        )
        let independent = try await CaptureIngestReplay.replay(
            publication: seeded.publication, bindingSnapshot: try currentBinding(),
            cas: cas, stagingParent: stagingParent
        )
        XCTAssertTrue(
            independent.scan.info.agentRole == "dispatched" || independent.parentIdentity != nil,
            "independent subagent replay must prove skip-class identity"
        )
        let result = try await makeWorker().step()
        guard case .parsed(let receipt) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
        XCTAssertNil(receipt.requiredFTSJobID)
        XCTAssertEqual(try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = ?",
                             arguments: [receipt.sessionID])
        }, 0)
        try assertExactParsed(seeded, receipt: receipt, independent: independent)
    }

    func testLastGoodReadyHeadRemainsAfterLaterParsedGeneration() async throws {
        let first = try await seedEligible(relative: "project/first.jsonl", nativeID: "native-session", sequence: 1)
        let replayed = try await CaptureIngestReplay.replay(
            publication: first.publication, bindingSnapshot: try currentBinding(),
            cas: cas, stagingParent: stagingParent
        )
        let seededReceipt = try writer.write { db -> CaptureIngestCommittedGeneration in
            let claim = try XCTUnwrap(CaptureIngestLedger.claim(
                db, publicationSHA256: first.digest, parserRevision: revision, now: clock.now, leaseDuration: 30
            ))
            return try CaptureIngestCommitter.commitParsed(
                db, claim: claim, replay: replayed, expectedParserRevision: revision,
                now: clock.now, indexedAt: indexedAt(from: clock.now)
            )
        }
        try writer.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = ?
                WHERE stored_session_id = ?
                """, arguments: [seededReceipt.generationID, seededReceipt.sessionID])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET status = 'index_ready' WHERE publication_sha256 = ?
                """, arguments: [first.digest])
            try db.execute(sql: """
                INSERT OR REPLACE INTO session_local_state(session_id, custom_name) VALUES (?, 'keep-me')
                """, arguments: [seededReceipt.sessionID])
        }
        let second = try await seedEligible(relative: "project/second.jsonl", nativeID: "native-session", sequence: 2)
        let independent = try await CaptureIngestReplay.replay(
            publication: second.publication, bindingSnapshot: try currentBinding(),
            cas: cas, stagingParent: stagingParent
        )
        let result = try await makeWorker().step()
        guard case .parsed(let receipt) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(try work(second).status, .parsed)
        XCTAssertEqual(try writer.read { db -> String? in
            try Row.fetchOne(db, sql: """
                SELECT last_ready_generation_id FROM capture_ingest_identity_bindings
                WHERE stored_session_id = ?
                """, arguments: [receipt.sessionID])?["last_ready_generation_id"]
        }, seededReceipt.generationID)
        try assertExactParsed(second, receipt: receipt, independent: independent,
                              expectedReadyHead: seededReceipt.generationID)
        XCTAssertEqual(try writer.read { db in
            try String.fetchOne(db, sql: "SELECT custom_name FROM session_local_state WHERE session_id = ?",
                                arguments: [receipt.sessionID])
        }, "keep-me")
    }

    func testMissingCASMappingWithIndependentReplayProofAndPositiveBaseline() async throws {
        try await assertReplayMapped(
            relative: "project/missing.jsonl", nativeID: "missing", publishObjects: false,
            expectedReplay: .retryable(.casUnavailable),
            expectedStatus: .retryableFailure, expectedCode: "retry.cas_unavailable"
        )
    }

    func testCorruptObjectMappingWithIndependentReplayProofAndPositiveBaseline() async throws {
        let corrupt = try await seedEligible(relative: "project/corrupt.jsonl", nativeID: "corrupt")
        try Data("tampered".utf8).write(to: objectURL(corrupt.manifest.chunks[0].rawSHA256))
        try await proveReplay(corrupt, .quarantined(.sourceIntegrityMismatch))
        let mapped = try await makeWorker().step()
        XCTAssertEqual(mapped, .recordedFailure)
        XCTAssertEqual(try work(corrupt).status, .quarantined)
        XCTAssertEqual(try work(corrupt).failureCode, "quarantine.source_integrity_mismatch")
        try await assertPositiveBaseline(relative: "project/corrupt-ok.jsonl", nativeID: "corrupt-ok")
    }

    func testMalformedJSONMappingWithIndependentReplayProofAndPositiveBaseline() async throws {
        try await assertReplayMapped(
            relative: "project/bad-json.jsonl", nativeID: "bad-json",
            bytes: Data("{broken\n".utf8),
            expectedReplay: .parseFailed(.malformedJSON),
            expectedStatus: .quarantined, expectedCodePrefix: "parse."
        )
    }

    func testUnsafeStagingMappingWithIndependentReplayProofAndPositiveBaseline() async throws {
        let unsafe = try await seedEligible(relative: "project/unsafe.jsonl", nativeID: "unsafe")
        XCTAssertEqual(chmod(stagingParent.path, 0o755), 0)
        try await proveReplay(unsafe, .quarantined(.unsafeStaging))
        let mapped = try await makeWorker().step()
        XCTAssertEqual(mapped, .recordedFailure)
        XCTAssertEqual(try work(unsafe).status, .retryableFailure)
        XCTAssertEqual(try work(unsafe).failureCode, "retry.staging_unavailable")
        XCTAssertEqual(chmod(stagingParent.path, 0o700), 0)
        try await assertPositiveBaseline(relative: "project/unsafe-ok.jsonl", nativeID: "unsafe-ok")
    }

    func testInvalidManifestAndMismatchMapToInvalidManifest() async throws {
        let invalid = try await seedEligible(relative: "project/inv-man.jsonl", nativeID: "inv-man")
        let replaced = try replaceManifest(invalid, Data("not-json".utf8))
        try await proveReplay(replaced, .quarantined(.invalidManifest))
        let mapped = try await makeWorker().step()
        XCTAssertEqual(mapped, .recordedFailure)
        XCTAssertEqual(try work(replaced).failureCode, "quarantine.invalid_manifest")

        let mismatch = try await seedEligible(
            relative: "project/mismatch.jsonl", nativeID: "mismatch",
            manifestMachine: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
        )
        try await proveReplay(mismatch, .quarantined(.manifestMismatch))
        let mappedMismatch = try await makeWorker().step()
        XCTAssertEqual(mappedMismatch, .recordedFailure)
        XCTAssertEqual(try work(mismatch).failureCode, "quarantine.invalid_manifest")
        try await assertPositiveBaseline(relative: "project/manifest-ok.jsonl", nativeID: "manifest-ok")
    }

    func testUnsupportedShapeAndInvalidLayoutMapToUnsupportedCaptureShape() async throws {
        let shape = try await seedEligible(relative: "project/shape.jsonl", nativeID: "shape")
        let shaped = try alterManifest(shape) { $0["sessionID"] = "normalized-export" }
        try await proveReplay(shaped, .quarantined(.unsupportedCaptureShape))
        let shapedResult = try await makeWorker().step()
        XCTAssertEqual(shapedResult, .recordedFailure)
        XCTAssertEqual(try work(shaped).failureCode, "quarantine.unsupported_capture_shape")

        let layout = try await seedEligible(relative: "project/layout.jsonl", nativeID: "layout")
        let laid = try alterManifest(layout) { $0["locator"] = "/other-root/project/layout.jsonl" }
        try await proveReplay(laid, .quarantined(.invalidReplayLayout))
        let laidResult = try await makeWorker().step()
        XCTAssertEqual(laidResult, .recordedFailure)
        XCTAssertEqual(try work(laid).failureCode, "quarantine.unsupported_capture_shape")
        try await assertPositiveBaseline(relative: "project/shape-ok.jsonl", nativeID: "shape-ok")
    }

    func testInvalidNativeIdentityMappingWithIndependentReplayProof() async throws {
        try await assertReplayMapped(
            relative: "project/bad-id.jsonl", nativeID: "bad\u{0000}id",
            expectedReplay: .quarantined(.invalidNativeIdentity),
            expectedStatus: .quarantined, expectedCode: "quarantine.invalid_native_identity"
        )
    }

    func testSourceMismatchMapsToBindingMismatchWithIndependentReplayProof() async throws {
        try await assertReplayMapped(
            relative: "project/derived.jsonl", nativeID: "derived",
            bytes: try claudeBytes(nativeID: "derived", model: "MiniMax-M2"),
            expectedReplay: .quarantined(.sourceMismatch),
            expectedStatus: .quarantined, expectedCode: "quarantine.binding_mismatch"
        )
    }

    func testMissingStagingParentMapsToStagingUnavailable() async throws {
        let seeded = try await seedEligible(relative: "project/miss-stage.jsonl", nativeID: "miss-stage")
        let missing = directory.appendingPathComponent("missing-stage")
        try await proveReplay(seeded, .retryable(.stagingUnavailable), staging: missing)
        let mapped = try await makeWorker(staging: missing).step()
        XCTAssertEqual(mapped, .recordedFailure)
        XCTAssertEqual(try work(seeded).failureCode, "retry.staging_unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        try await assertPositiveBaseline(relative: "project/miss-stage-ok.jsonl", nativeID: "miss-stage-ok")
    }

    func testStolenClaimBeforeCommitDoesNotPoisonTheNewerClaim() async throws {
        let seeded = try await seedEligible()
        let writer = self.writer!
        let digest = seeded.digest
        let revision = self.revision
        let stolen = Locked<String?>(nil)
        let worker = makeWorker(hooks: .init(afterClaim: {
            let token = UUID().uuidString
            stolen.set(token)
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE capture_ingest_ledger
                    SET claim_token = ?, attempt_count = attempt_count + 1
                    WHERE publication_sha256 = ? AND parser_revision = ?
                    """, arguments: [token, digest, revision])
            }
        }))
        let result = try await worker.step()
        assertNotParsed(result, "stale claim must not parse")
        if case .recordedFailure = result { XCTFail("stale claim must not fabricate a replay failure") }
        let after = try work(seeded)
        XCTAssertEqual(after.token, stolen.value)
        XCTAssertNotEqual(after.failureCode, "retry.interrupted")
        XCTAssertNil(after.failureCode)
        XCTAssertEqual(after.status, .processing)
    }

    func testExpiredClaimBeforeCommitStaysProcessingWithoutFailure() async throws {
        let seeded = try await seedEligible()
        let writer = self.writer!
        let digest = seeded.digest
        let revision = self.revision
        let clock = self.clock
        let worker = makeWorker(hooks: .init(afterClaim: {
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE capture_ingest_ledger
                    SET claim_started_at = 1000, claim_expires_at = 1001
                    WHERE publication_sha256 = ? AND parser_revision = ?
                    """, arguments: [digest, revision])
            }
            clock.set(1001)
        }))
        let result = try await worker.step()
        assertNotParsed(result, "expired claim is neutral")
        if case .recordedFailure = result { XCTFail("expired claim is neutral") }
        let after = try work(seeded)
        XCTAssertEqual(after.status, .processing)
        XCTAssertNil(after.failureCode)
        XCTAssertEqual(after.claimedAt, 1000)
        XCTAssertEqual(after.expiresAt, 1001)
    }

    func testUnknownEpochDoesNotPoisonLedger() async throws {
        let unknown = try await seedEligible(
            relative: "project/unknown.jsonl", nativeID: "unknown", publicationEpoch: otherEpoch
        )
        let result = try await makeWorker().step()
        XCTAssertEqual(result, .idle)
        XCTAssertEqual(try work(unknown).status, .pending)
        XCTAssertNil(try work(unknown).failureCode)
        XCTAssertEqual(try work(unknown).attempt, 0)
    }

    func testCallerCancelQueuedJoinsWithoutEarlyReturn() async throws {
        try await assertCancelOrStop(stop: false, replayEntered: false)
    }

    func testCallerCancelReplayEnteredJoinsWithoutEarlyReturn() async throws {
        try await assertCancelOrStop(stop: false, replayEntered: true)
    }

    func testStopQueuedJoinsWithoutEarlyReturn() async throws {
        try await assertCancelOrStop(stop: true, replayEntered: false)
    }

    func testStopReplayEnteredJoinsWithoutEarlyReturn() async throws {
        try await assertCancelOrStop(stop: true, replayEntered: true)
    }

    func testPrecancelAndIdempotentStopSealFutureAdmission() async throws {
        let seeded = try await seedEligible()
        let worker = makeWorker()
        let precancel = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.step()
        }
        do {
            _ = try await precancel.value
            XCTFail("precancel must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try work(seeded).status, .pending)
        try await worker.stop()
        try await worker.stop()
        do {
            let result = try await worker.step()
            assertNotParsed(result, "stop must seal future admission")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        XCTAssertEqual(try work(seeded).status, .pending)
        XCTAssertEqual(try work(seeded).attempt, 0)
    }

    func testInheritedAcceptedWriteTaskLocalUsesRealGateAndJoins() async throws {
        let seeded = try await seedEligible()
        let gateHold = DispatchSemaphore(value: 0)
        let entered = Flag()
        let worker = makeWorker(hooks: .init(beforeWriterTransaction: {
            entered.set()
            XCTAssertEqual(gateHold.wait(timeout: .now() + 5), .success, "real gate barrier must be released")
        }))
        let done = Flag()
        let running = Task {
            defer { done.set() }
            return try await ServiceWriterGate.$preserveAcceptedWriteProducer.withValue(true) {
                try await worker.step()
            }
        }
        let realGateEntered = await waitUntil { entered.value }
        XCTAssertTrue(realGateEntered, "must enter the real writer-gate transaction")
        XCTAssertFalse(done.value, "must not complete before cancel")
        running.cancel()
        gateHold.signal()
        do {
            _ = try await running.value
            XCTFail("cancel must join the owned write")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(done.value)
        XCTAssertEqual(try work(seeded).status, .pending)
        XCTAssertEqual(try work(seeded).attempt, 0)
    }

    func testWriterTriggerCancellationRollsBackParsedToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .cancel, failurePath: false)
    }

    func testWriterTriggerPolicyFlipRollsBackParsedToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .policy, failurePath: false)
    }

    func testWriterTriggerClockExpiryRollsBackParsedToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .clock, failurePath: false)
    }

    func testRecordFailureCancelFenceRollsBackToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .cancel, failurePath: true)
    }

    func testRecordFailurePolicyFenceRollsBackToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .policy, failurePath: true)
    }

    func testRecordFailureClockFenceRollsBackToOriginalProcessingClaim() async throws {
        try await assertPostMaterializationRollback(kind: .clock, failurePath: true)
    }

    func testUnexpectedCommitAbortPropagatesWithoutRawPersistentError() async throws {
        let seeded = try await seedEligible()
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER t4a_abort AFTER INSERT ON capture_ingest_generations
                BEGIN SELECT RAISE(ABORT, 'injected commit failure'); END
                """)
        }
        do {
            _ = try await makeWorker().step()
            XCTFail("injected commit abort must propagate")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        let after = try work(seeded)
        XCTAssertEqual(after.status, .processing)
        XCTAssertNil(after.failureCode)
        XCTAssertFalse((after.failureCode ?? "").contains("injected"))
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try count("sessions"), 0)
    }

    func testInvalidLeaseRetryDeadlineAndClockOverflowFailClosed() async throws {
        let seeded = try await seedEligible()
        for lease in [Int64(0), 301, -1] {
            do {
                _ = try await makeWorker(lease: lease).step()
                XCTFail("invalid lease \(lease) must fail closed")
            } catch {
                XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
                XCTAssertEqual(try work(seeded).status, .pending)
            }
        }
        for retry in [Int64(0), 3601, -1] {
            do {
                _ = try await makeWorker(retry: retry).step()
                XCTFail("invalid retry \(retry) must fail closed")
            } catch {
                XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
                XCTAssertEqual(try work(seeded).status, .pending)
            }
        }
        do {
            _ = try await makeWorker(deadline: ContinuousClock().now.advanced(by: .seconds(-1))).step()
            XCTFail("expired monotonic deadline must fail closed")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
            XCTAssertEqual(try work(seeded).status, .pending)
        }
        clock.set(Int64.max)
        do {
            _ = try await makeWorker(lease: 1).step()
            XCTFail("unix clock overflow must fail closed")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
            XCTAssertEqual(try work(seeded).status, .pending)
        }
    }

    func testConfiguredRootMismatchAfterReplayBeforeRecordFailureStaysProcessing() async throws {
        try await assertReplayMismatchBeforeRecordFailure(.configuredRoot)
    }

    func testParseFormatMismatchAfterReplayBeforeRecordFailureStaysProcessing() async throws {
        try await assertReplayMismatchBeforeRecordFailure(.parseFormat)
    }

    func testAuthorityGenerationMismatchAfterReplayBeforeRecordFailureStaysProcessing() async throws {
        try await assertReplayMismatchBeforeRecordFailure(.authorityGeneration)
    }

    func testParsedMaterializationTriggerConfiguredRootRollsBackIngestAndRegistry() async throws {
        try await assertParsedMaterializationFullBindingRollback(.configuredRoot)
    }

    func testParsedMaterializationTriggerParseFormatRollsBackIngestAndRegistry() async throws {
        try await assertParsedMaterializationFullBindingRollback(.parseFormat)
    }

    func testParsedMaterializationTriggerAuthorityGenerationRollsBackIngestAndRegistry() async throws {
        try await assertParsedMaterializationFullBindingRollback(.authorityGeneration)
    }

    func testRecordFailureMaterializationTriggerConfiguredRootRollsBackToProcessingClaim() async throws {
        try await assertRecordFailureMaterializationFullBindingRollback(.configuredRoot)
    }

    func testRecordFailureMaterializationTriggerParseFormatRollsBackToProcessingClaim() async throws {
        try await assertRecordFailureMaterializationFullBindingRollback(.parseFormat)
    }

    func testRecordFailureMaterializationTriggerAuthorityGenerationRollsBackToProcessingClaim() async throws {
        try await assertRecordFailureMaterializationFullBindingRollback(.authorityGeneration)
    }

    func testPostClaimTriggerCallerCancellationRollsBackPending() async throws {
        try await assertPostClaimFenceRollback(.cancel)
    }

    func testPostClaimTriggerPolicyFlipRollsBackPending() async throws {
        try await assertPostClaimFenceRollback(.policy)
    }

    func testPostClaimTriggerClockExpiryRollsBackPending() async throws {
        try await assertPostClaimFenceRollback(.clock)
    }

    // MARK: - Shared assertions

    private enum FenceKind { case cancel, policy, clock }

    private func assertPostMaterializationRollback(kind: FenceKind, failurePath: Bool) async throws {
        let seeded = try await seedEligible(
            relative: "project/fence-\(failurePath)-\(String(describing: kind)).jsonl",
            nativeID: "fence-\(failurePath)-\(String(describing: kind))",
            publishObjects: true,
            bytes: failurePath ? Data("{broken\n".utf8) : nil
        )
        if failurePath {
            try await proveReplay(seeded, .parseFailed(.malformedJSON))
        }
        let claimed = Locked<WorkRow?>(nil)
        let hookEntered = Flag()
        let triggerEntered = Flag()
        let writer = self.writer!
        let digest = seeded.digest
        let revision = self.revision
        let policyBox = self.policyBox
        let clock = self.clock
        let cancelAction = Cancellation()
        try writer.write { db in
            db.add(function: DatabaseFunction("t4a_fence_enter", argumentCount: 0, pure: false) { _ in
                triggerEntered.set()
                return 1
            })
            if failurePath {
                try db.execute(sql: """
                    CREATE TEMP TRIGGER t4a_fence AFTER UPDATE OF status ON capture_ingest_ledger
                    WHEN NEW.status IN ('failed_retryable', 'quarantined')
                    BEGIN SELECT t4a_fence_enter(); END
                    """)
            } else {
                try db.execute(sql: """
                    CREATE TEMP TRIGGER t4a_fence AFTER INSERT ON capture_ingest_generations
                    BEGIN SELECT t4a_fence_enter(); END
                    """)
            }
        }
        let afterMaterialization: @Sendable () throws -> Void = {
            hookEntered.set()
            switch kind {
            case .cancel: cancelAction.perform()
            case .policy: policyBox.set(nil)
            case .clock: clock.set(9999)
            }
        }
        let admit = WorkerBarrier()
        let worker = makeWorker(hooks: .init(
            queuedAtGate: { try await admit.wait() },
            afterClaim: {
                claimed.set(try writer.read { db in
                    try WorkRow.fetch(db, digest: digest, revision: revision)
                })
            },
            afterParsedMaterialization: failurePath ? nil : afterMaterialization,
            afterFailureMaterialization: failurePath ? afterMaterialization : nil
        ))
        let task = Task { try await worker.step() }
        let admitted = await waitUntil { admit.entered >= 1 }
        XCTAssertTrue(admitted, "must enter before installing the cancel target")
        cancelAction.action = { task.cancel() }
        admit.release()
        do {
            _ = try await task.value
            if kind == .cancel { XCTFail("cancellation must propagate") }
            else { XCTFail("post-materialization fence must fail the outer write") }
        } catch {
            if kind == .cancel { XCTAssertTrue(error is CancellationError, "got \(error)") }
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        XCTAssertTrue(hookEntered.value, "after materialization hook must run")
        XCTAssertTrue(triggerEntered.value, "real writer trigger must run")
        let expected = try XCTUnwrap(claimed.value)
        XCTAssertEqual(expected.status, .processing)
        XCTAssertNil(expected.failureCode)
        XCTAssertGreaterThan(expected.attempt, 0)
        XCTAssertNotNil(expected.token)
        XCTAssertEqual(try work(seeded), expected)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
        XCTAssertNotEqual(try work(seeded).failureCode, "retry.interrupted")
    }

    private func assertCancelOrStop(stop: Bool, replayEntered: Bool) async throws {
        let seeded = try await seedEligible(
            relative: "project/join-\(stop)-\(replayEntered).jsonl",
            nativeID: "join-\(stop)-\(replayEntered)"
        )
        let barrier = WorkerBarrier()
        let hooks: ServiceCaptureIngestWorkerHooks
        if replayEntered {
            hooks = .init(beforeReplay: { try await barrier.wait() })
        } else {
            hooks = .init(queuedAtGate: { try await barrier.wait() })
        }
        let worker = makeWorker(hooks: hooks)
        let done = Flag()
        let running = Task {
            defer { done.set() }
            return try await worker.step()
        }
        let joinEntered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(joinEntered, "barrier must be entered")
        XCTAssertFalse(done.value, "join must not return before cancel/stop")
        if stop {
            try await worker.stop()
        } else {
            running.cancel()
        }
        let joined = await waitUntil { done.value }
        XCTAssertTrue(joined, "cancel/stop must join the owned task")
        XCTAssertGreaterThanOrEqual(barrier.exited, 1, "barrier must exit on cancel/stop")
        barrier.release()
        do {
            _ = try await running.value
            XCTFail("cancelled work must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        try await worker.stop()
        let after = try work(seeded)
        if replayEntered {
            XCTAssertEqual(after.status, .processing)
            XCTAssertNil(after.failureCode)
            XCTAssertGreaterThan(after.attempt, 0)
        } else {
            XCTAssertEqual(after.status, .pending)
            XCTAssertEqual(after.attempt, 0)
        }
        XCTAssertNotEqual(after.failureCode, "retry.interrupted")
    }

    private func assertReplayMapped(
        relative: String, nativeID: String, publishObjects: Bool = true, bytes: Data? = nil,
        expectedReplay: CaptureIngestReplayError,
        expectedStatus: CaptureIngestStatus, expectedCode: String? = nil, expectedCodePrefix: String? = nil
    ) async throws {
        let seeded = try await seedEligible(
            relative: relative, nativeID: nativeID, publishObjects: publishObjects, bytes: bytes
        )
        try await proveReplay(seeded, expectedReplay)
        let mapped = try await makeWorker().step()
        XCTAssertEqual(mapped, .recordedFailure)
        XCTAssertEqual(try work(seeded).status, expectedStatus)
        if let expectedCode {
            XCTAssertEqual(try work(seeded).failureCode, expectedCode)
        }
        if let expectedCodePrefix {
            XCTAssertTrue(try XCTUnwrap(work(seeded).failureCode).hasPrefix(expectedCodePrefix))
        }
        XCTAssertNotEqual(try work(seeded).failureCode, "retry.interrupted")
        try await assertPositiveBaseline(
            relative: "project/ok-\(seeded.digest.prefix(12)).jsonl",
            nativeID: "ok-\(seeded.digest.prefix(12))"
        )
    }

    private func assertPositiveBaseline(relative: String, nativeID: String) async throws {
        policyBox.set(ServiceCaptureIngestParserPolicy(parserRevision: revision, enabledSources: [.claudeCode]))
        XCTAssertEqual(chmod(stagingParent.path, 0o700), 0)
        let seeded = try await seedEligible(relative: relative, nativeID: nativeID)
        let independent = try await CaptureIngestReplay.replay(
            publication: seeded.publication, bindingSnapshot: try currentBinding(),
            cas: cas, stagingParent: stagingParent
        )
        sqlTrace.beginWindow()
        let result = try await makeWorker().step()
        let sql = sqlTrace.endWindow()
        guard case .parsed(let receipt) = result else {
            return XCTFail("unmodified baseline must parse, got \(result)")
        }
        try assertExactParsed(seeded, receipt: receipt, independent: independent)
        try assertScalarPreselection(sql, chosen: seeded.digest)
    }

    private func assertExactParsed(
        _ seeded: Seeded, receipt: CaptureIngestCommittedGeneration, independent: CaptureIngestReplayResult,
        expectedReadyHead: String? = nil
    ) throws {
        XCTAssertEqual(receipt.sessionID, try independent.nativeIdentity.proposedSessionID())
        XCTAssertEqual(receipt.generationID.count, 64)
        let generation = try writer.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                       arguments: [receipt.generationID]))
        }
        XCTAssertEqual(generation["publication_sha256"] as String, seeded.digest)
        XCTAssertEqual(generation["parser_revision"] as String, revision)
        XCTAssertEqual(generation["native_id"] as String, independent.nativeIdentity.nativeID)
        XCTAssertEqual(generation["normalized_message_count"] as Int, independent.scan.messages.count)
        XCTAssertEqual(generation["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(generation["created_at"] as String, indexedAt(from: 1000))
        let payload: Data = generation["normalized_messages_json"]
        let stored = try ArchiveCanonicalJSON.decode([NormalizedMessage].self, from: payload)
        XCTAssertEqual(stored, independent.scan.messages)
        XCTAssertEqual(stored.compactMap(\.usage), independent.scan.messages.compactMap(\.usage))
        let session = try session(receipt.sessionID)
        XCTAssertEqual(session["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(session["source_locator"] as String, "capture://\(receipt.generationID)")
        XCTAssertEqual(session["indexed_at"] as String, indexedAt(from: 1000))
        XCTAssertNotEqual(try work(seeded).status, .indexReady)
        XCTAssertEqual(try writer.read { db -> String? in
            try Row.fetchOne(db, sql: """
                SELECT last_ready_generation_id FROM capture_ingest_identity_bindings
                WHERE stored_session_id = ?
                """, arguments: [receipt.sessionID])?["last_ready_generation_id"]
        }, expectedReadyHead)
        if receipt.requiredFTSJobID != nil {
            XCTAssertEqual(try writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM session_index_jobs WHERE session_id = ? AND job_kind = 'fts'
                        AND target_sync_version = ? AND status = 'pending'
                    """, arguments: [receipt.sessionID, receipt.syncVersion])
            }, 1)
        }
        XCTAssertEqual(try count("sessions_fts"), 0)
    }

    private func assertScalarPreselection(_ sql: [String], chosen digest: String) throws {
        XCTAssertFalse(sql.isEmpty, "positive parse must emit worker SQL")
        guard let preselect = sql.first(where: isTwoKeyLimit1Preselection) else {
            return XCTFail("missing two-key LIMIT 1 preselection in \(sql)")
        }
        XCTAssertEqual(projectedColumns(in: preselect).map { $0.lowercased() }.sorted(),
                       ["parser_revision", "publication_sha256"],
                       "preselection must project exactly the two ledger keys: \(preselect)")
        let envelopeReads = sql.filter { statement in
            let lower = statement.lowercased()
            return lower.contains("capture_ingest_publications")
                && (lower.contains("select *") || lower.contains("canonical_bytes"))
        }
        XCTAssertFalse(envelopeReads.isEmpty, "chosen claim must point-read the canonical envelope")
        for statement in envelopeReads {
            let lower = statement.lowercased()
            XCTAssertTrue(
                lower.contains("where") && lower.contains("publication_sha256") && lower.contains(digest),
                "envelope read must WHERE publication_sha256 = chosen digest \(digest): \(statement)"
            )
            let digests = hex64(in: statement)
            XCTAssertFalse(digests.isEmpty, "point read must mention the chosen digest: \(statement)")
            XCTAssertEqual(Set(digests), [digest], "envelope read must be only the chosen digest \(digest): \(statement)")
        }
        if let preselectIndex = sql.firstIndex(where: isTwoKeyLimit1Preselection) {
            for statement in sql.prefix(preselectIndex) {
                let lower = statement.lowercased()
                XCTAssertFalse(
                    lower.contains("canonical_bytes") || lower.contains("select * from capture_ingest_publications"),
                    "preselection window loaded a publication envelope: \(statement)"
                )
            }
        }
    }

    private func isTwoKeyLimit1Preselection(_ sql: String) -> Bool {
        let lower = sql.lowercased()
        guard lower.contains("from capture_ingest_ledger") else { return false }
        guard lower.contains("limit 1") else { return false }
        guard !lower.contains("select *") else { return false }
        guard !lower.contains("canonical_bytes") else { return false }
        guard !lower.contains("manifest_json") else { return false }
        guard !lower.contains("normalized_messages_json") else { return false }
        let columns = projectedColumns(in: sql).map { $0.lowercased() }
        return Set(columns) == ["publication_sha256", "parser_revision"] && columns.count == 2
    }

    private func projectedColumns(in sql: String) -> [String] {
        let collapsed = sql.lowercased().replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        guard let selectRange = collapsed.range(of: "select "),
              let fromRange = collapsed.range(of: " from ") else { return [] }
        guard selectRange.upperBound < fromRange.lowerBound else { return [] }
        let list = collapsed[selectRange.upperBound..<fromRange.lowerBound]
        return list.split(separator: ",").map { part in
            part.split(separator: ".").last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`[]")) ?? ""
        }.filter { !$0.isEmpty }
    }

    private func assertIdleSecondStepLeaves(
        _ excluded: Seeded, parser: String? = nil,
        expectedStatus: CaptureIngestStatus, expectedAttempt: Int64
    ) async throws {
        let before = try work(of: excluded.digest, parser: parser)
        XCTAssertEqual(before.status, expectedStatus)
        XCTAssertEqual(before.attempt, expectedAttempt)
        let second = try await makeWorker().step()
        XCTAssertEqual(second, .idle)
        XCTAssertEqual(try work(of: excluded.digest, parser: parser), before)
        XCTAssertEqual(try work(of: excluded.digest, parser: parser).status, expectedStatus)
        XCTAssertEqual(try work(of: excluded.digest, parser: parser).attempt, expectedAttempt)
    }

    // MARK: - Harness

    private func makeWorker(
        hooks: ServiceCaptureIngestWorkerHooks = .init(),
        deadline: ContinuousClock.Instant? = nil,
        lease: Int64 = 300,
        retry: Int64 = 30,
        staging: URL? = nil
    ) -> ServiceCaptureIngestWorker {
        ServiceCaptureIngestWorker(
            gate: gate, cas: cas, stagingParent: staging ?? stagingParent,
            policy: { [policyBox] in policyBox.value },
            unixClock: { [clock] in clock.now },
            deadline: deadline, leaseDuration: lease, retryDelay: retry, hooks: hooks
        )
    }

    private struct Seeded {
        let digest: String
        let publication: CollectorPublicationEnvelope
        let manifest: ArchiveSourceManifest
        let binding: CaptureIngestSourceBinding
    }

    private func seedEligible(
        source: SourceName = .claudeCode, format: CaptureIngestParseFormat = .claudeDefault,
        configuredRoot: String? = nil, relative: String = "project/session.jsonl",
        nativeID: String = "native-session", instanceID: String? = nil, publicationEpoch: String? = nil,
        parser: String? = nil, sequence: Int64? = nil, provision: Bool = false, publishObjects: Bool = true,
        bytes: Data? = nil, manifestMachine: String? = nil
    ) async throws -> Seeded {
        let instanceID = instanceID ?? instance
        let root = configuredRoot ?? logicalRoot
        if provision {
            try writer.write { db in
                if try CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instanceID) == nil {
                    _ = try CaptureIngestSourceRegistry.provision(
                        db, machineID: machine, sourceInstanceID: instanceID, source: source,
                        parseFormat: format, configuredRoot: root, initialEpoch: epoch
                    )
                }
            }
        }
        let raw = try bytes ?? claudeBytes(nativeID: nativeID)
        let fixture = try publishCAS(
            raw: raw, source: source, root: root, relative: relative,
            instanceID: instanceID, epoch: publicationEpoch ?? epoch,
            publishObjects: publishObjects, manifestMachine: manifestMachine, sequence: sequence ?? nextOrdinal
        )
        try accept(fixture.publication, parser: parser ?? revision)
        let binding = try writer.read {
            try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: instanceID)
        } ?? CaptureIngestSourceBinding(
            machineID: machine, sourceInstanceID: instanceID, source: source, parseFormat: format,
            configuredRoot: root, approvedEpoch: publicationEpoch ?? epoch, authorityGeneration: 1
        )
        return Seeded(digest: try fixture.publication.sha256(), publication: fixture.publication,
                      manifest: fixture.manifest, binding: binding)
    }

    private func publishCAS(
        raw: Data, source: SourceName, root: String, relative: String, instanceID: String,
        epoch: String, publishObjects: Bool, manifestMachine: String?, sequence: Int64
    ) throws -> (publication: CollectorPublicationEnvelope, manifest: ArchiveSourceManifest) {
        let hash = ArchiveV2Hash.sha256(raw)
        var chunks: [ArchiveChunkReference] = []
        var offset = 0
        while offset < raw.count {
            let end = min(raw.count, offset + Int(ArchiveSourceManifest.rawChunkSize))
            let bytes = Data(raw[offset..<end])
            let digest = ArchiveV2Hash.sha256(bytes)
            chunks.append(try ArchiveChunkReference(ordinal: chunks.count, rawSHA256: digest, rawByteCount: Int64(bytes.count)))
            if publishObjects { _ = try cas.publishObject(raw: bytes, expectedSHA256: digest) }
            offset = end
        }
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data(UUID().uuidString.utf8)),
            machineID: manifestMachine ?? machine, source: source.rawValue,
            locator: root + "/" + relative, sessionID: nil, capturedAt: "2026-09-06T00:00:00Z",
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count), chunks: chunks,
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
        )
        let manifestBytes = try ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA = ArchiveV2Hash.sha256(manifestBytes)
        _ = try cas.publishManifest(manifestBytes, expectedSHA256: manifestSHA)
        let publication = try CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: instanceID, collectorEpoch: epoch,
            sequence: sequence, manifestSHA256: manifestSHA
        )
        return (publication, manifest)
    }

    private func accept(_ publication: CollectorPublicationEnvelope, parser: String) throws {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        try writer.write { db in
            let cursor = try CaptureIngestLedger.checkpoint(db, serverID: "hq")
            let ack = try CollectorPublicationACK(
                serverID: "hq", journalID: journal, arrivalOrdinal: ordinal,
                publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
                storedAt: "2026-09-06T00:00:00.000Z"
            )
            let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
            let page = try CollectorPublicationPage(
                items: [record],
                afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: ordinal).encoded(),
                hasMore: false
            )
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: cursor, serverID: "hq", parserRevision: parser)
        }
    }

    private func proveReplay(
        _ seeded: Seeded, _ expected: CaptureIngestReplayError, staging: URL? = nil
    ) async throws {
        do {
            _ = try await CaptureIngestReplay.replay(
                publication: seeded.publication, bindingSnapshot: seeded.binding,
                cas: cas, stagingParent: staging ?? stagingParent
            )
            XCTFail("independent replay must fail with \(expected)")
        } catch {
            XCTAssertEqual(error as? CaptureIngestReplayError, expected, "independent replay")
        }
    }

    private func currentBinding() throws -> CaptureIngestSourceBinding {
        try XCTUnwrap(writer.read { try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: instance) })
    }

    private func session(_ id: String) throws -> Row {
        try XCTUnwrap(writer.read { try Row.fetchOne($0, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id]) })
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    private func ledgerSnapshot() throws -> [String] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM capture_ingest_ledger ORDER BY publication_sha256, parser_revision")
                .map { String(describing: $0) }
        }
    }

    private func objectURL(_ digest: String) -> URL {
        directory.appendingPathComponent("cas/objects/sha256/\(digest.prefix(2))/\(digest)")
    }

    private func replaceManifest(_ seeded: Seeded, _ bytes: Data) throws -> Seeded {
        let hash = ArchiveV2Hash.sha256(bytes)
        _ = try cas.publishManifest(bytes, expectedSHA256: hash)
        let publication = try CollectorPublicationEnvelope(
            machineID: seeded.publication.machineID, sourceInstanceID: seeded.publication.sourceInstanceID,
            collectorEpoch: seeded.publication.collectorEpoch, sequence: seeded.publication.sequence + 10,
            manifestSHA256: hash
        )
        try writer.write { db in
            try db.execute(sql: "DELETE FROM capture_ingest_arrivals WHERE publication_sha256 = ?", arguments: [seeded.digest])
            try db.execute(sql: "DELETE FROM capture_ingest_ledger WHERE publication_sha256 = ?", arguments: [seeded.digest])
        }
        try accept(publication, parser: revision)
        let manifest = (try? ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes)) ?? seeded.manifest
        return Seeded(digest: try publication.sha256(), publication: publication, manifest: manifest, binding: seeded.binding)
    }

    private func alterManifest(_ seeded: Seeded, edit: (inout [String: Any]) -> Void) throws -> Seeded {
        var object = try JSONSerialization.jsonObject(with: ArchiveCanonicalJSON.encode(seeded.manifest)) as! [String: Any]
        edit(&object)
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes: Data
        if let decoded = try? JSONDecoder().decode(ArchiveSourceManifest.self, from: raw) {
            bytes = try ArchiveCanonicalJSON.encode(decoded)
        } else {
            bytes = raw
        }
        return try replaceManifest(seeded, bytes)
    }

    private func work(_ seeded: Seeded) throws -> WorkRow { try work(of: seeded.digest) }

    private func work(of digest: String, parser: String? = nil) throws -> WorkRow {
        try writer.read { try WorkRow.fetch($0, digest: digest, revision: parser ?? revision) }
    }

    private func assertNotParsed(_ result: ServiceCaptureIngestStepResult, _ message: String) {
        if case .parsed = result { XCTFail(message) }
    }

    private func indexedAt(from unix: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    private func hex64(in sql: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "[0-9a-f]{64}")
        let range = NSRange(sql.startIndex..., in: sql)
        return pattern.matches(in: sql, range: range).compactMap { match in
            Range(match.range, in: sql).map { String(sql[$0]) }
        }
    }

    private func waitUntil(_ probe: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func claudeBytes(nativeID: String, model: String = "claude-test") throws -> Data {
        let common: [String: Any] = ["sessionId": nativeID, "cwd": "/repo/project", "timestamp": "2026-09-06T00:00:00Z"]
        func record(_ type: String, _ message: [String: Any]) -> [String: Any] {
            common.merging(["type": type, "message": message]) { _, new in new }
        }
        return try jsonl([
            record("user", ["content": "Implement a useful feature"]),
            record("assistant", ["id": "usage-once", "model": model,
                                 "content": [["type": "text", "text": "Working"]],
                                 "usage": ["input_tokens": 7, "output_tokens": 3]]),
        ])
    }

    private func jsonl(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            result.append(0x0a)
        }
        return result
    }

    // MARK: - Additive full-binding / post-claim draft helpers

    private enum FullBindingFault: String {
        case configuredRoot, parseFormat, authorityGeneration
    }

    private func assertReplayMismatchBeforeRecordFailure(_ fault: FullBindingFault) async throws {
        let seeded = try await seedEligible(
            relative: "project/bind-\(fault.rawValue).jsonl",
            nativeID: "bind-\(fault.rawValue)",
            bytes: Data("{broken\n".utf8)
        )
        try await proveReplay(seeded, .parseFailed(.malformedJSON))
        let originalRegistry = try registryState()
        XCTAssertEqual(originalRegistry.approvedEpoch, epoch)
        let claimed = Locked<WorkRow?>(nil)
        let replayStarted = Flag()
        let mutated = Flag()
        let barrier = WorkerBarrier()
        let writer = self.writer!
        let worker = makeWorker(hooks: .init(
            afterClaim: {
                claimed.set(try writer.read { db in
                    try WorkRow.fetch(db, digest: seeded.digest, revision: self.revision)
                })
            },
            beforeReplay: { try await barrier.wait() },
            afterReplay: {
                replayStarted.set()
                try writer.write { db in
                    try self.applyFullBindingFault(db, fault)
                }
                mutated.set()
            }
        ))
        let running = Task { try await worker.step() }
        let entered = await waitUntil { barrier.entered >= 1 }
        XCTAssertTrue(entered, "public replay must start before the binding mutation")
        barrier.release()
        let result = try await running.value
        XCTAssertTrue(replayStarted.value, "afterReplay must run after public Replay and before recordFailure")
        XCTAssertTrue(mutated.value, "Store mutation must run")
        XCTAssertGreaterThanOrEqual(barrier.exited, 1)
        let expectedClaim = try XCTUnwrap(claimed.value)
        XCTAssertEqual(expectedClaim.status, .processing)
        XCTAssertNil(expectedClaim.failureCode)
        XCTAssertGreaterThan(expectedClaim.attempt, 0)
        assertNotParsed(result, "accepted binding mismatch is neutral")
        if case .recordedFailure = result { XCTFail("accepted binding mismatch must not invent a replay failure") }
        XCTAssertEqual(try work(seeded), expectedClaim)
        XCTAssertNil(try work(seeded).failureCode)
        XCTAssertNotEqual(try work(seeded).failureCode, "retry.interrupted")
        let afterRegistry = try registryState()
        XCTAssertEqual(afterRegistry.approvedEpoch, originalRegistry.approvedEpoch)
        try assertRegistryShows(fault, original: originalRegistry, current: afterRegistry)
        try assertNoIngestArtifacts()
    }

    private func assertParsedMaterializationFullBindingRollback(_ fault: FullBindingFault) async throws {
        let seeded = try await seedEligible(
            relative: "project/parsed-bind-\(fault.rawValue).jsonl",
            nativeID: "parsed-bind-\(fault.rawValue)"
        )
        let originalRegistry = try registryState()
        let claimed = Locked<WorkRow?>(nil)
        let triggerEntered = Flag()
        let writer = self.writer!
        try installFullBindingTrigger(
            name: "t4a_parsed_bind",
            whenSQL: "NEW.status = 'parsed'",
            fault: fault,
            entered: triggerEntered
        )
        let worker = makeWorker(hooks: .init(afterClaim: {
            claimed.set(try writer.read { db in
                try WorkRow.fetch(db, digest: seeded.digest, revision: self.revision)
            })
        }))
        do {
            _ = try await worker.step()
            XCTFail("post-parsed full-binding trigger must fail the outer write")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        XCTAssertTrue(triggerEntered.value, "parsed-status SQL trigger must run")
        let expectedClaim = try XCTUnwrap(claimed.value)
        XCTAssertEqual(try work(seeded), expectedClaim)
        XCTAssertEqual(try work(seeded).status, .processing)
        XCTAssertNil(try work(seeded).failureCode)
        XCTAssertEqual(try registryState(), originalRegistry)
        try assertHistoryMatches(originalRegistry)
        try assertNoIngestArtifacts()
    }

    private func assertRecordFailureMaterializationFullBindingRollback(_ fault: FullBindingFault) async throws {
        let seeded = try await seedEligible(
            relative: "project/fail-bind-\(fault.rawValue).jsonl",
            nativeID: "fail-bind-\(fault.rawValue)",
            bytes: Data("{broken\n".utf8)
        )
        try await proveReplay(seeded, .parseFailed(.malformedJSON))
        let originalRegistry = try registryState()
        let claimed = Locked<WorkRow?>(nil)
        let triggerEntered = Flag()
        let writer = self.writer!
        try installFullBindingTrigger(
            name: "t4a_failure_bind",
            whenSQL: "NEW.status IN ('failed_retryable', 'quarantined')",
            fault: fault,
            entered: triggerEntered
        )
        let worker = makeWorker(hooks: .init(afterClaim: {
            claimed.set(try writer.read { db in
                try WorkRow.fetch(db, digest: seeded.digest, revision: self.revision)
            })
        }))
        do {
            _ = try await worker.step()
            XCTFail("post-failure full-binding trigger must fail the outer write")
        } catch {
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        XCTAssertTrue(triggerEntered.value, "failure-status SQL trigger must run")
        let expectedClaim = try XCTUnwrap(claimed.value)
        XCTAssertEqual(try work(seeded), expectedClaim)
        XCTAssertEqual(try work(seeded).status, .processing)
        XCTAssertNil(try work(seeded).failureCode)
        XCTAssertNotEqual(try work(seeded).failureCode, "retry.interrupted")
        XCTAssertEqual(try registryState(), originalRegistry)
        try assertHistoryMatches(originalRegistry)
        try assertNoIngestArtifacts()
    }

    private func assertPostClaimFenceRollback(_ kind: FenceKind) async throws {
        let seeded = try await seedEligible(
            relative: "project/postclaim-\(String(describing: kind)).jsonl",
            nativeID: "postclaim-\(String(describing: kind))"
        )
        let before = try work(seeded)
        XCTAssertEqual(before.status, .pending)
        XCTAssertEqual(before.attempt, 0)
        XCTAssertNil(before.token)
        let originalRegistry = try registryState()
        let originalLedger = try ledgerSnapshot()
        let triggerEntered = Flag()
        let replayEntered = Flag()
        let claimed = Flag()
        let admit = WorkerBarrier()
        let cancelAction = Cancellation()
        let policyBox = self.policyBox
        let clock = self.clock
        try writer.write { db in
            db.add(function: DatabaseFunction("t4a_postclaim_enter", argumentCount: 0, pure: false) { _ in
                triggerEntered.set()
                switch kind {
                case .cancel: cancelAction.perform()
                case .policy: policyBox.set(nil)
                case .clock: clock.set(9999)
                }
                return 1
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER t4a_postclaim AFTER UPDATE OF status ON capture_ingest_ledger
                WHEN NEW.status = 'processing' AND OLD.status = 'pending'
                BEGIN SELECT t4a_postclaim_enter(); END
                """)
        }
        let worker = makeWorker(hooks: .init(
            queuedAtGate: { try await admit.wait() },
            afterClaim: { claimed.set() },
            beforeReplay: { replayEntered.set() }
        ))
        let task = Task { try await worker.step() }
        let admitted = await waitUntil { admit.entered >= 1 }
        XCTAssertTrue(admitted, "must enter before installing the cancel target")
        cancelAction.action = { task.cancel() }
        admit.release()
        do {
            _ = try await task.value
            if kind == .cancel { XCTFail("post-claim cancellation must propagate") }
            else { XCTFail("post-claim policy/clock fence must fail the outer write") }
        } catch {
            if kind == .cancel { XCTAssertTrue(error is CancellationError, "got \(error)") }
            XCTAssertNotEqual(error as? ServiceCaptureIngestWorkerError, .notImplemented)
        }
        XCTAssertTrue(triggerEntered.value, "post-claim SQL trigger must run after Ledger.claim UPDATE")
        XCTAssertFalse(claimed.value, "rolled-back claim must not observe afterClaim")
        XCTAssertFalse(replayEntered.value, "rolled-back claim must not start Replay")
        XCTAssertEqual(try work(seeded), before)
        XCTAssertEqual(try work(seeded).status, .pending)
        XCTAssertEqual(try work(seeded).attempt, 0)
        XCTAssertNil(try work(seeded).token)
        XCTAssertNil(try work(seeded).retryAfter)
        XCTAssertEqual(try ledgerSnapshot(), originalLedger)
        XCTAssertEqual(try registryState(), originalRegistry)
        try assertNoIngestArtifacts()
    }

    private func installFullBindingTrigger(
        name: String, whenSQL: String, fault: FullBindingFault, entered: Flag
    ) throws {
        let mutation = fullBindingTriggerSQL(fault)
        try writer.write { db in
            db.add(function: DatabaseFunction("t4a_fullbind_enter", argumentCount: 0, pure: false) { _ in
                entered.set()
                return 1
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER \(name) AFTER UPDATE OF status ON capture_ingest_ledger
                WHEN \(whenSQL)
                BEGIN
                \(mutation)
                SELECT t4a_fullbind_enter();
                END
                """)
        }
    }

    private func applyFullBindingFault(_ db: Database, _ fault: FullBindingFault) throws {
        switch fault {
        case .configuredRoot:
            try db.execute(sql: """
                UPDATE capture_ingest_source_registry SET configured_root = ?
                WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: ["/offline-client/.claude/projects-mutated", machine, instance])
        case .parseFormat:
            try db.execute(sql: """
                UPDATE capture_ingest_source_registry SET parse_format = ?
                WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: [CaptureIngestParseFormat.claudeCustomProfile.rawValue, machine, instance])
        case .authorityGeneration:
            try db.execute(sql: """
                UPDATE capture_ingest_source_registry SET authority_generation = 2
                WHERE machine_id = ? AND source_instance_id = ? AND authority_generation = 1
                """, arguments: [machine, instance])
            try db.execute(sql: """
                UPDATE capture_ingest_epoch_history SET authority_generation = 2
                WHERE machine_id = ? AND source_instance_id = ? AND authority_generation = 1
                    AND approved_epoch = ?
                """, arguments: [machine, instance, epoch])
        }
        XCTAssertEqual(db.changesCount, 1, "full-binding fault \(fault) must update one row")
    }

    private func fullBindingTriggerSQL(_ fault: FullBindingFault) -> String {
        switch fault {
        case .configuredRoot:
            return """
                UPDATE capture_ingest_source_registry
                SET configured_root = '/offline-client/.claude/projects-mutated'
                WHERE machine_id = '\(machine)' AND source_instance_id = '\(instance)';
                """
        case .parseFormat:
            return """
                UPDATE capture_ingest_source_registry
                SET parse_format = 'claudeCustomProfile'
                WHERE machine_id = '\(machine)' AND source_instance_id = '\(instance)';
                """
        case .authorityGeneration:
            return """
                UPDATE capture_ingest_source_registry SET authority_generation = 2
                WHERE machine_id = '\(machine)' AND source_instance_id = '\(instance)' AND authority_generation = 1;
                UPDATE capture_ingest_epoch_history SET authority_generation = 2
                WHERE machine_id = '\(machine)' AND source_instance_id = '\(instance)'
                    AND authority_generation = 1 AND approved_epoch = '\(epoch)';
                """
        }
    }

    private struct RegistryState: Equatable {
        var configuredRoot: String
        var parseFormat: String
        var authorityGeneration: Int64
        var approvedEpoch: String
    }

    private func registryState() throws -> RegistryState {
        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT configured_root, parse_format, authority_generation, approved_epoch
                FROM capture_ingest_source_registry WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: [machine, instance]))
            return RegistryState(
                configuredRoot: row["configured_root"],
                parseFormat: row["parse_format"],
                authorityGeneration: row["authority_generation"],
                approvedEpoch: row["approved_epoch"]
            )
        }
    }

    private func assertRegistryShows(
        _ fault: FullBindingFault, original: RegistryState, current: RegistryState
    ) throws {
        XCTAssertEqual(current.approvedEpoch, original.approvedEpoch)
        switch fault {
        case .configuredRoot:
            XCTAssertEqual(current.configuredRoot, "/offline-client/.claude/projects-mutated")
            XCTAssertEqual(current.parseFormat, original.parseFormat)
            XCTAssertEqual(current.authorityGeneration, original.authorityGeneration)
        case .parseFormat:
            XCTAssertEqual(current.parseFormat, CaptureIngestParseFormat.claudeCustomProfile.rawValue)
            XCTAssertEqual(current.configuredRoot, original.configuredRoot)
            XCTAssertEqual(current.authorityGeneration, original.authorityGeneration)
        case .authorityGeneration:
            XCTAssertEqual(current.authorityGeneration, 2)
            XCTAssertEqual(current.configuredRoot, original.configuredRoot)
            XCTAssertEqual(current.parseFormat, original.parseFormat)
            let history = try writer.read {
                try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance)
            }
            XCTAssertTrue(history.contains {
                $0.approvedEpoch.utf8.elementsEqual(epoch.utf8) && $0.authorityGeneration == 2
            })
        }
    }

    private func assertHistoryMatches(_ original: RegistryState) throws {
        let history = try writer.read {
            try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance)
        }
        XCTAssertTrue(history.contains {
            $0.approvedEpoch.utf8.elementsEqual(original.approvedEpoch.utf8)
                && $0.authorityGeneration == original.authorityGeneration
        })
    }

    private func assertNoIngestArtifacts() throws {
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
    }
}

private struct WorkRow: Equatable {
    var status: CaptureIngestStatus
    var failureCode: String?
    var token: String?
    var claimedAt: Int64?
    var expiresAt: Int64?
    var attempt: Int64
    var retryAfter: Int64?

    static func fetch(_ db: Database, digest: String, revision: String) throws -> WorkRow {
        let row = try XCTUnwrap(Row.fetchOne(db, sql: """
            SELECT status, failure_code, claim_token, claim_started_at, claim_expires_at, attempt_count, retry_after
            FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?
            """, arguments: [digest, revision]))
        guard let status = CaptureIngestStatus(rawValue: row["status"] as String) else {
            throw CaptureIngestLedgerError.invalidStoredRecord
        }
        return WorkRow(
            status: status,
            failureCode: row["failure_code"],
            token: row["claim_token"],
            claimedAt: row["claim_started_at"],
            expiresAt: row["claim_expires_at"],
            attempt: row["attempt_count"],
            retryAfter: row["retry_after"]
        )
    }
}

private final class UnixClock: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int64
    init(_ now: Int64) { raw = now }
    var now: Int64 { lock.lock(); defer { lock.unlock() }; return raw }
    func set(_ value: Int64) { lock.lock(); raw = value; lock.unlock() }
}

private final class PolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: ServiceCaptureIngestParserPolicy?
    var value: ServiceCaptureIngestParserPolicy? { lock.lock(); defer { lock.unlock() }; return raw }
    func set(_ value: ServiceCaptureIngestParserPolicy?) { lock.lock(); raw = value; lock.unlock() }
}

private final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [String] = []
    private var windowing = false
    private var window: [String] = []
    func append(_ sql: String) {
        lock.lock()
        raw.append(sql)
        if windowing { window.append(sql) }
        lock.unlock()
    }
    func beginWindow() {
        lock.lock()
        windowing = true
        window.removeAll()
        lock.unlock()
    }
    func endWindow() -> [String] {
        lock.lock()
        windowing = false
        let value = window
        window.removeAll()
        lock.unlock()
        return value
    }
}

private final class WorkerBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var _entered = 0
    private var _exited = 0
    private var released = false
    private var cancelled = false

    var entered: Int { lock.lock(); defer { lock.unlock() }; return _entered }
    var exited: Int { lock.lock(); defer { lock.unlock() }; return _exited }

    func wait() async throws {
        defer {
            lock.lock()
            _exited += 1
            lock.unlock()
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                _entered += 1
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            resumeCancelled()
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func resumeCancelled() {
        lock.lock()
        cancelled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return raw }
    func set() { lock.lock(); raw = true; lock.unlock() }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Value
    init(_ value: Value) { raw = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return raw }
    func set(_ value: Value) { lock.lock(); raw = value; lock.unlock() }
}

private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: (() -> Void)?
    var action: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return raw }
        set { lock.lock(); raw = newValue; lock.unlock() }
    }
    func perform() { action?() }
}
