import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import SQLite3
import XCTest

final class CaptureIngestReadinessTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let grokInstance = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
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

    func testLoadAndReadyPreserveCompleteHistoryAboveTenThousand() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "message-\(index)")
        }
        let fixture = try parsed(messages: messages)
        let snapshot = try load(fixture)
        XCTAssertEqual(snapshot.messages.count, 10_001)
        XCTAssertEqual(snapshot.messages.first, messages.first)
        XCTAssertEqual(snapshot.messages.last, messages.last)
        XCTAssertTrue(snapshot.messages == messages, "No normalized role, middle element or suffix may be dropped")
        XCTAssertNotEqual(snapshot.normalizedMessagesSHA256, try ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(messages)),
                          "parent digest must hash the bounded v2 manifest, not the giant message array")
        let stored = try writer.read {
            try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                       arguments: [fixture.receipt.generationID]))
        }
        XCTAssertEqual(stored["normalized_schema_version"] as Int, 1)
        XCTAssertEqual(stored["normalized_storage_version"] as Int?, 2)
        XCTAssertEqual(stored["normalized_message_count"] as Int, 0,
                       "v2 writes sentinel 0 on the legacy count column; never clamp")
        XCTAssertEqual(stored["normalized_total_message_count"] as Int?, 10_001)
        _ = try ready(snapshot)
        try assertReady(fixture)
        XCTAssertEqual(try fts(fixture).first, messages.first?.content)
        XCTAssertTrue(try fts(fixture).contains(try XCTUnwrap(messages.last?.content)))
        XCTAssertEqual(try fts(fixture), try expectedFTS(fixture))
    }

    func testWeakReviewSkipRepairPromotesV1AndDrainsFTSToReady_repro() async throws {
        let fixture = try parsed(nativeID: "weak-v1", messages: weakReviewMessages(count: 20))
        try seedSidecars(fixture)
        try demoteToFalseSkip(fixture)
        let beforeSession = try sessionColumns(fixture, excluding: ["tier"])
        let beforeGeneration = try generationColumns(fixture, excluding: ["required_fts_job_id"])
        let beforeSidecars = try sidecarState(fixture)
        XCTAssertEqual(try sessionTier(fixture), "skip")
        XCTAssertNil(try requiredJob(fixture))
        let first = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 4)
        }
        XCTAssertEqual(first.repaired, 1)
        XCTAssertEqual(try sessionTier(fixture), "premium")
        XCTAssertEqual(try requiredJob(fixture), expectedFTSJobID(fixture))
        XCTAssertEqual(try sessionColumns(fixture, excluding: ["tier"]), beforeSession)
        XCTAssertEqual(try generationColumns(fixture, excluding: ["required_fts_job_id"]), beforeGeneration)
        XCTAssertEqual(try sidecarState(fixture), beforeSidecars)
        let identity = try snapshotIdentity(fixture)
        XCTAssertEqual(identity.0, fixture.receipt.syncVersion)
        XCTAssertEqual(identity.1, fixture.receipt.snapshotHash)
        XCTAssertEqual(identity.2, fixture.receipt.generationID)
        let second = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 4)
        }
        XCTAssertEqual(second.repaired, 0)
        XCTAssertEqual(try sessionColumns(fixture, excluding: ["tier"]), beforeSession)
        XCTAssertEqual(try generationColumns(fixture, excluding: ["required_fts_job_id"]), beforeGeneration)
        XCTAssertEqual(try sidecarState(fixture), beforeSidecars)
        _ = try await makeRunner().runRecoverableJobsOnce()
        try assertReady(fixture)
        XCTAssertTrue(try fts(fixture).contains("Review P2 tests for correctness and summarize the result."))
        XCTAssertEqual(try sessionColumns(fixture, excluding: ["tier"]), beforeSession)
        XCTAssertEqual(try generationColumns(fixture, excluding: ["required_fts_job_id"]), beforeGeneration)
        XCTAssertEqual(try sidecarState(fixture), beforeSidecars)
    }

    func testWeakReviewSkipRepairPromotesV2AndDrainsFTSToReady_repro() async throws {
        let messages = weakReviewMessages(count: 10_001)
        let fixture = try parsed(nativeID: "weak-v2", messages: messages)
        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT normalized_storage_version, normalized_message_count, normalized_total_message_count
                FROM capture_ingest_generations WHERE generation_id = ?
                """, arguments: [fixture.receipt.generationID]))
            XCTAssertEqual(row["normalized_storage_version"] as Int, 2)
            XCTAssertEqual(row["normalized_message_count"] as Int, 0)
            XCTAssertEqual(row["normalized_total_message_count"] as Int?, 10_001)
        }
        try demoteToFalseSkip(fixture)
        let batch = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 1)
        }
        XCTAssertEqual(batch.repaired, 1)
        XCTAssertEqual(try sessionTier(fixture), "premium")
        XCTAssertEqual(try requiredJob(fixture), expectedFTSJobID(fixture))
        _ = try await makeRunner().runRecoverableJobsOnce()
        try assertReady(fixture)
        XCTAssertTrue(try fts(fixture).contains("Review P2 tests for correctness and summarize the result."))
    }

    func testWeakReviewSkipRepairPreservesExplicitProbeSubagentAndDispatched() throws {
        let probe = try parsed(nativeID: "explicit-probe", messages: [
            .init(role: .user, content: "Review these snippets. Report only blocking correctness findings."),
            .init(role: .assistant, content: "No blocking issues.")
        ])
        let subagent = try parsed(nativeID: "role-subagent", messages: weakReviewMessages(count: 20),
                                  agentRole: "subagent")
        let dispatched = try parsed(nativeID: "role-dispatched", messages: weakReviewMessages(count: 20),
                                    agentRole: "dispatched")
        XCTAssertEqual(try sessionTier(probe), "skip")
        XCTAssertNil(try requiredJob(probe))
        try demoteToFalseSkip(subagent)
        try demoteToFalseSkip(dispatched)
        let before = try state()
        let batch = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 8)
        }
        XCTAssertEqual(batch.repaired, 0)
        XCTAssertGreaterThanOrEqual(batch.reviewedUnchanged, 1)
        XCTAssertEqual(try sessionTier(probe), "skip")
        XCTAssertNil(try requiredJob(probe))
        XCTAssertEqual(try sessionTier(subagent), "skip")
        XCTAssertEqual(try sessionTier(dispatched), "skip")
        XCTAssertNil(try requiredJob(subagent))
        XCTAssertNil(try requiredJob(dispatched))
        let after = try state()
        XCTAssertEqual(after["sessions"], before["sessions"])
        XCTAssertEqual(after["session_index_jobs"], before["session_index_jobs"])
        XCTAssertEqual(after["capture_ingest_generations"], before["capture_ingest_generations"])
        let again = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 8)
        }
        XCTAssertEqual(again.repaired, 0)
        XCTAssertEqual(again.reviewedUnchanged, 0)
    }

    func testWeakReviewSkipRepairIgnoresStaleAndDisabledWithoutMutation() throws {
        let stale = try parsed(nativeID: "stale-head", messages: weakReviewMessages(count: 20))
        let current = try parsed(nativeID: "policy-disabled", messages: weakReviewMessages(count: 20))
        try demoteToFalseSkip(stale)
        try demoteToFalseSkip(current)
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET sync_version = sync_version + 1 WHERE id = ?",
                           arguments: [stale.receipt.sessionID])
        }
        let before = try state()
        let emptyPolicy = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [], limit: 8)
        }
        XCTAssertEqual(emptyPolicy.repaired, 0)
        XCTAssertEqual(try state(), before)
        let otherSource = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.codex], limit: 8)
        }
        XCTAssertEqual(otherSource.repaired, 0)
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try sessionTier(stale), "skip")
        XCTAssertEqual(try sessionTier(current), "skip")
        XCTAssertNil(try requiredJob(stale))
        XCTAssertNil(try requiredJob(current))
    }

    func testWeakReviewSkipRepairRollsBackPartialCandidate() throws {
        let fixture = try parsed(nativeID: "rollback-weak", messages: weakReviewMessages(count: 20))
        try seedSidecars(fixture)
        try demoteToFalseSkip(fixture)
        let before = try state()
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER repair_bind_fault AFTER UPDATE ON capture_ingest_generations
                WHEN NEW.required_fts_job_id IS NOT NULL AND OLD.required_fts_job_id IS NULL
                BEGIN
                    SELECT RAISE(FAIL, 'repair-bind-fault');
                END
                """)
            let batch = try CaptureIngestReadiness.repairWeakReviewSkips(db,
                expectedParserRevision: revision, enabledSources: [.claudeCode], limit: 1)
            XCTAssertEqual(batch.repaired, 0)
            XCTAssertEqual(batch.reviewedUnchanged, 0)
            XCTAssertEqual(try state(db), before)
            try db.execute(sql: "DROP TRIGGER repair_bind_fault")
        }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try sessionTier(fixture), "skip")
        XCTAssertNil(try requiredJob(fixture))
    }

    func testWeakReviewSkipRepairPreservesOriginalProbeLocatorSkip_repro() throws {
        let probeLocator = "/offline-client/.claude/projects/.engram/probes/claude/session.jsonl"
        let fixture = try parsed(nativeID: "original-probe-locator", messages: weakReviewMessages(count: 20),
                                 locator: probeLocator)
        try demoteToFalseSkip(fixture)
        let storedPath = try writer.read { try String.fetchOne($0, sql: "SELECT file_path FROM sessions WHERE id = ?",
                                                                arguments: [fixture.receipt.sessionID]) }
        XCTAssertEqual(storedPath?.hasPrefix("capture://"), true)
        XCTAssertFalse(storedPath?.contains("/.engram/probes/") == true)
        let batch = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 1)
        }
        XCTAssertEqual(batch.repaired, 0)
        XCTAssertEqual(batch.reviewedUnchanged, 1)
        XCTAssertEqual(try sessionTier(fixture), "skip")
        XCTAssertNil(try requiredJob(fixture))
        XCTAssertTrue(try isReviewed(fixture))
    }

    func testWeakReviewSkipRepairLeavesTruncatedFirstUserWindowUnmarked() throws {
        let injections = (0..<48).map { index in
            NormalizedMessage(role: .user, content: "# AGENTS.md instructions for /repo \(index)", timestamp: timestamp)
        }
        let fixture = try parsed(nativeID: "truncated-first-users", messages: injections + weakReviewMessages(count: 20))
        try demoteToFalseSkip(fixture)
        let batch = try writer.write {
            try CaptureIngestReadiness.repairWeakReviewSkips($0, expectedParserRevision: revision,
                enabledSources: [.claudeCode], limit: 1)
        }
        XCTAssertEqual(batch.repaired, 0)
        XCTAssertEqual(batch.reviewedUnchanged, 0)
        XCTAssertEqual(try sessionTier(fixture), "skip")
        XCTAssertNil(try requiredJob(fixture))
        XCTAssertFalse(try isReviewed(fixture))
    }

    func testReadyRejectsPartialRangeSnapshot() throws {
        let messages = (0..<10_001).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "message-\(index)")
        }
        let fixture = try parsed(messages: messages)
        let partial = try load(fixture, messageRange: 0..<1)
        XCTAssertEqual(partial.messageStartOrdinal, 0)
        XCTAssertEqual(partial.messages.count, 1)
        XCTAssertEqual(partial.totalMessageCount, 10_001)
        assertError(.invalidStoredRecord) { try ready(partial) }
        let page = try loadPage(fixture, fromOrdinal: 0, maximumMessages: 2, roles: [.user])
        XCTAssertEqual(page.ordinals, [0, 2])
        assertError(.invalidStoredRecord) { try ready(page.snapshot) }
        _ = try ready(try load(fixture))
        try assertReady(fixture)
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

    func testGrokReadinessCommitIndexesLabeledArchivePhraseAndExcludesOtherSystem_repro() throws {
        let phrase = "GROKARCHFTS_zx9q_compaction_only"
        let archive = "Grok compaction archive\nsegment_000.md\n\n# Turn\n\(phrase)\n"
        let unlabeled = "system-unlabeled-must-stay-out"
        let grok = try parsedGrok(messages: [
            .init(role: .system, content: archive, timestamp: timestamp),
            .init(role: .system, content: unlabeled, timestamp: timestamp),
            .init(role: .user, content: "grok user needle", timestamp: timestamp),
            .init(role: .assistant, content: "Implemented the Grok archive readiness path.", timestamp: timestamp),
        ])
        XCTAssertGreaterThan(grok.messages.filter { $0.role == .system }.count, 0)
        let snapshot = try load(grok, sources: [.grok])
        _ = try writer.write { db in
            try CaptureIngestReadiness.commit(db, snapshot: snapshot, expectedParserRevision: revision,
                enabledSources: [.grok])
        }
        let contents = try writer.read {
            try String.fetchAll($0, sql: "SELECT content FROM sessions_fts WHERE session_id = ?",
                arguments: [grok.receipt.sessionID])
        }
        XCTAssertTrue(contents.contains { $0.contains(phrase) }, "archived phrase must appear in stored FTS content")
        XCTAssertFalse(contents.contains { $0.contains(unlabeled) })
        XCTAssertEqual(try writer.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM sessions_fts
                WHERE sessions_fts MATCH 'GROKARCHFTS_zx9q_compaction_only' AND session_id = ?
                """, arguments: [grok.receipt.sessionID])
        }, 1)
        let stored = try writer.read {
            try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                       arguments: [grok.receipt.generationID]))
        }
        XCTAssertEqual(
            stored["normalized_total_message_count"] as Int? ?? stored["normalized_message_count"] as Int,
            grok.messages.count,
            "Web COALESCE(normalized_total_message_count, normalized_message_count) must include archives"
        )

        let control = try parsed(messages: [
            .init(role: .system, content: archive, timestamp: timestamp),
            .init(role: .user, content: "claude user needle", timestamp: timestamp),
            .init(role: .assistant, content: "Implemented the control readiness path.", timestamp: timestamp),
        ])
        _ = try ready(try load(control))
        XCTAssertEqual(try writer.read {
            try Int.fetchOne($0, sql: """
                SELECT COUNT(*) FROM sessions_fts
                WHERE sessions_fts MATCH 'GROKARCHFTS_zx9q_compaction_only' AND session_id = ?
                """, arguments: [control.receipt.sessionID])
        }, 0, "non-Grok system archives must stay out of capture-owned FTS")
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
    private func weakReviewMessages(count: Int) -> [NormalizedMessage] {
        var messages: [NormalizedMessage] = [
            .init(role: .user, content: "Review P2 tests for correctness and summarize the result.",
                  timestamp: timestamp)
        ]
        while messages.count < count {
            let index = messages.count
            messages.append(.init(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: index.isMultiple(of: 2)
                    ? "Continue the ordinary implementation turn \(index)."
                    : "Continued the ordinary implementation turn \(index).",
                timestamp: timestamp
            ))
        }
        return messages
    }

    private func demoteToFalseSkip(_ fixture: Fixture) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = ?",
                           arguments: [fixture.receipt.sessionID])
            try db.execute(sql: """
                UPDATE capture_ingest_generations SET required_fts_job_id = NULL WHERE generation_id = ?
                """, arguments: [fixture.receipt.generationID])
            try db.execute(sql: "DELETE FROM session_index_jobs WHERE session_id = ?",
                           arguments: [fixture.receipt.sessionID])
            try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?",
                           arguments: [fixture.receipt.sessionID])
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET status = 'parsed'
                WHERE publication_sha256 = ? AND parser_revision = ?
                """, arguments: [fixture.publicationSHA256, revision])
            try db.execute(sql: """
                UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL
                WHERE stored_session_id = ?
                """, arguments: [fixture.receipt.sessionID])
        }
    }

    private func seedSidecars(_ fixture: Fixture) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE sessions SET custom_name = 'User title', generated_title = 'Generated title',
                    parent_session_id = 'manual-parent', link_source = 'manual'
                WHERE id = ?
                """, arguments: [fixture.receipt.sessionID])
            try db.execute(sql: """
                INSERT INTO session_costs(session_id, model, input_tokens, output_tokens, cost_usd)
                VALUES (?, 'offline-fixture', 11, 22, 0.5)
                ON CONFLICT(session_id) DO UPDATE SET input_tokens = excluded.input_tokens,
                    output_tokens = excluded.output_tokens, cost_usd = excluded.cost_usd
                """, arguments: [fixture.receipt.sessionID])
            try db.execute(sql: """
                INSERT INTO session_tools(session_id, tool_name, call_count) VALUES (?, 'edit_file', 7)
                ON CONFLICT(session_id, tool_name) DO UPDATE SET call_count = excluded.call_count
                """, arguments: [fixture.receipt.sessionID])
            try db.execute(sql: """
                INSERT INTO session_work_beats(
                    session_id, beat_index, action_date, action_timestamp, work_key, work_title,
                    human_intent, assistant_outcome, kind, status)
                VALUES (?, 0, '2026-09-06', ?, 'sidecar-work', 'Sidecar beat',
                    'Keep the custom beat', 'Beat stayed', 'implementation', 'completed')
                ON CONFLICT(session_id, beat_index) DO UPDATE SET work_title = excluded.work_title
                """, arguments: [fixture.receipt.sessionID, timestamp])
        }
    }

    private func sessionColumns(_ fixture: Fixture, excluding: Set<String>) throws -> [String: DatabaseValue] {
        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?",
                                                 arguments: [fixture.receipt.sessionID]))
            return namedValues(row, excluding: excluding)
        }
    }

    private func generationColumns(_ fixture: Fixture, excluding: Set<String>) throws -> [String: DatabaseValue] {
        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                                 arguments: [fixture.receipt.generationID]))
            return namedValues(row, excluding: excluding)
        }
    }

    private func namedValues(_ row: Row, excluding: Set<String>) -> [String: DatabaseValue] {
        Dictionary(uniqueKeysWithValues: row.columnNames
            .filter { !excluding.contains($0) }
            .map { ($0, row[$0] as DatabaseValue) })
    }

    private func sidecarState(_ fixture: Fixture) throws -> [String: String] {
        try writer.read { db in
            let session = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT custom_name, generated_title, parent_session_id, link_source, snapshot_hash,
                    sync_version FROM sessions WHERE id = ?
                """, arguments: [fixture.receipt.sessionID]))
            let cost = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT input_tokens, output_tokens, cost_usd FROM session_costs WHERE session_id = ?
                """, arguments: [fixture.receipt.sessionID]))
            let tool = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT call_count FROM session_tools WHERE session_id = ? AND tool_name = 'edit_file'
                """, arguments: [fixture.receipt.sessionID]))
            let beat = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT work_title, human_intent FROM session_work_beats
                WHERE session_id = ? AND beat_index = 0
                """, arguments: [fixture.receipt.sessionID]))
            return [
                "custom": session["custom_name"] as String? ?? "",
                "title": session["generated_title"] as String? ?? "",
                "parent": session["parent_session_id"] as String? ?? "",
                "link": session["link_source"] as String? ?? "",
                "hash": session["snapshot_hash"] as String? ?? "",
                "version": String(session["sync_version"] as Int? ?? -1),
                "in": String(cost["input_tokens"] as Int? ?? -1),
                "out": String(cost["output_tokens"] as Int? ?? -1),
                "usd": String(cost["cost_usd"] as Double? ?? -1),
                "tool": String(tool["call_count"] as Int? ?? -1),
                "beat": beat["work_title"] as String? ?? "",
                "intent": beat["human_intent"] as String? ?? "",
            ]
        }
    }

    private func sessionTier(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: "SELECT tier FROM sessions WHERE id = ?",
                                              arguments: [fixture.receipt.sessionID]) }
    }

    private func requiredJob(_ fixture: Fixture) throws -> String? {
        try writer.read { try String.fetchOne($0, sql: """
            SELECT required_fts_job_id FROM capture_ingest_generations WHERE generation_id = ?
            """, arguments: [fixture.receipt.generationID]) }
    }

    private func expectedFTSJobID(_ fixture: Fixture) -> String {
        "\(fixture.receipt.sessionID):\(fixture.receipt.syncVersion):\(fixture.receipt.snapshotHash):fts"
    }

    private func snapshotIdentity(_ fixture: Fixture) throws -> (Int, String, String) {
        try writer.read { db in
            let session = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT sync_version, snapshot_hash FROM sessions WHERE id = ?
                """, arguments: [fixture.receipt.sessionID]))
            let generation = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generation_id, sync_version, snapshot_hash FROM capture_ingest_generations
                WHERE generation_id = ?
                """, arguments: [fixture.receipt.generationID]))
            XCTAssertEqual(session["sync_version"] as Int, generation["sync_version"] as Int)
            XCTAssertEqual(session["snapshot_hash"] as String, generation["snapshot_hash"] as String)
            return (session["sync_version"] as Int? ?? 0, session["snapshot_hash"] as String? ?? "",
                    generation["generation_id"] as String? ?? "")
        }
    }

    private func makeRunner() -> IndexJobRunner {
        let policy = CaptureFTSReadinessPolicy(parserRevision: revision, enabledSources: [.claudeCode])
        return IndexJobRunner(writer: writer, adapters: [], capturePolicy: { policy })
    }

    // transaction and real SQLite/FTS but never opens source files or credentials.
    private struct Fixture {
        let receipt: CaptureIngestCommittedGeneration
        let publicationSHA256: String
        let native: CaptureIngestIdentity
        let binding: CaptureIngestSourceBinding
        let messages: [NormalizedMessage]
    }

    private enum FixtureFailure: Error, Equatable { case outerRollback }

    private func isReviewed(_ fixture: Fixture) throws -> Bool {
        try writer.read {
            try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key = ?",
                                arguments: ["capture_weak_review_skip_reviewed:" + fixture.receipt.generationID]) != nil
        }
    }

    private func parsed(nativeID: String = "native-session", messages: [NormalizedMessage]? = nil,
                        agentRole: String? = nil, locator: String? = nil) throws -> Fixture {
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
            locator: locator ?? (binding.configuredRoot + "/" + relative), sessionID: nil, capturedAt: timestamp,
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

    private func parsedGrok(messages: [NormalizedMessage]) throws -> Fixture {
        let binding = try writer.write { db in
            if let existing = try CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: grokInstance) {
                return existing
            }
            return try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: grokInstance,
                source: .grok, parseFormat: .grok, configuredRoot: "/offline-client/.grok/sessions", initialEpoch: epoch)
        }
        let ordinal = nextOrdinal
        nextOrdinal += 1
        let project = "%2FUsers%2Ftest%2Fproject"
        let session = "019dd6e3-91d1-7326-8299-314858773a0e"
        let prefix = project + "/" + session + "/"
        let chat = prefix + "chat_history.jsonl"
        let chatBytes = Data("{\"type\":\"user\",\"content\":\"<user_query>Inspect</user_query>\"}\n".utf8)
        let summaryBytes = Data("{\"info\":{\"id\":\"\(session)\",\"cwd\":\"/Users/test/project\"}}\n".utf8)
        let promptBytes = Data("{\"working_directory\":\"/Users/test/project\"}\n".utf8)
        let members: [(String, Data)] = [(chat, chatBytes), (prefix + "prompt_context.json", promptBytes),
                                         (prefix + "summary.json", summaryBytes)]
        var combined = Data()
        var files: [ArchiveFileSetEntry] = []
        for (index, member) in members.enumerated() {
            files.append(try ArchiveFileSetEntry(
                relativePath: member.0, byteOffset: Int64(combined.count),
                rawByteCount: Int64(member.1.count), wholeSourceSHA256: ArchiveV2Hash.sha256(member.1),
                generation: .init(device: 1, inode: Int64(index + 2), size: Int64(member.1.count),
                                  mtimeNs: 3, ctimeNs: 4, mode: 0o100600)))
            combined.append(member.1)
        }
        let hash = ArchiveV2Hash.sha256(combined)
        let manifest = try ArchiveSourceManifest(
            schemaVersion: 2, captureID: ArchiveV2Hash.sha256(Data("\(ordinal):grok".utf8)),
            machineID: machine, source: "grok", locator: binding.configuredRoot + "/" + chat,
            sessionID: nil, capturedAt: timestamp,
            generation: .init(device: 1, inode: 2, size: Int64(chatBytes.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: Int64(combined.count),
            chunks: [try .init(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(combined.count))],
            replayLayout: .init(strategy: .fileSet, relativePaths: members.map(\.0),
                entrypointRelativePath: chat, files: files,
                absentRelativePaths: [prefix + "compaction/INDEX.md", prefix + "updates.jsonl"]))
        XCTAssertTrue(ArchiveSourceDescriptor.isGrokFileSet(manifest))
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: grokInstance,
            collectorEpoch: binding.approvedEpoch, sequence: ordinal,
            manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
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
        let identity = try CaptureIngestIdentity(machineID: machine, sourceInstanceID: grokInstance, source: .grok, nativeID: session)
        let info = NormalizedSessionInfo(id: session, source: .grok, startTime: timestamp, endTime: timestamp,
            cwd: "/Users/test/project", project: "fixture", model: "grok-4",
            messageCount: messages.filter { $0.role == .user || $0.role == .assistant || $0.role == .tool }.count,
            userMessageCount: messages.filter { $0.role == .user }.count,
            assistantMessageCount: messages.filter { $0.role == .assistant }.count,
            toolMessageCount: messages.filter { $0.role == .tool }.count,
            systemMessageCount: messages.filter { $0.role == .system }.count,
            summary: "Grok fixture summary", displayTitle: "Grok readiness", filePath: manifest.locator,
            sizeBytes: Int64(chatBytes.count), originator: "grok")
        let replay = CaptureIngestReplayResult(publicationSHA256: digest, verifiedManifest: manifest, bindingSnapshot: binding,
            scan: .init(info: info, messages: messages), rawSourceSessionID: session, nativeIdentity: identity,
            parentIdentity: nil, suggestedParentIdentity: nil)
        let receipt = try writer.write { db in
            let result = try CaptureIngestCommitter.commitParsed(db, claim: claim, replay: replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            if let job = result.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET not_before = NULL WHERE id = ?", arguments: [job])
            }
            return result
        }
        return .init(receipt: receipt, publicationSHA256: digest, native: identity, binding: binding, messages: messages)
    }

    private func load(_ fixture: Fixture, sessionID: String? = nil, generationID: String? = nil,
                      parser: String? = nil, sources: Set<SourceName> = [.claudeCode],
                      deadline: ContinuousClock.Instant? = nil,
                      messageRange: Range<Int>? = nil) throws -> CaptureIngestNormalizedSnapshot {
        try writer.read { try CaptureIngestNormalizedStore.load($0, sessionID: sessionID ?? fixture.receipt.sessionID,
            generationID: generationID ?? fixture.receipt.generationID, expectedParserRevision: parser ?? revision,
            enabledSources: sources, deadline: deadline, messageRange: messageRange) }
    }

    private func loadPage(_ fixture: Fixture, fromOrdinal: Int, maximumMessages: Int,
                          roles: Set<NormalizedMessageRole>, sources: Set<SourceName> = [.claudeCode],
                          deadline: ContinuousClock.Instant? = nil,
                          maximumPayloadBytes: Int = 1024 * 1024) throws -> (snapshot: CaptureIngestNormalizedSnapshot, ordinals: [Int], hasMore: Bool) {
        try writer.read {
            try CaptureIngestNormalizedStore.loadPage($0, sessionID: fixture.receipt.sessionID,
                generationID: fixture.receipt.generationID, expectedParserRevision: revision,
                enabledSources: sources, fromOrdinal: fromOrdinal, maximumMessages: maximumMessages,
                roles: roles, deadline: deadline, maximumPayloadBytes: maximumPayloadBytes)
        }
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
