import Foundation
@testable import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import SQLite3
import XCTest

final class CaptureIngestCommitTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let nextEpoch = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let otherMachine = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let otherInstance = "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let revision = "swift-parser-z"
    private let timestamp = "2026-09-06T01:02:03.000Z"
    private let logicalRoot = "/offline-client/.claude/projects"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!
    private var nextOrdinal: Int64 = 1

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFreshAndRepeatedMigrationCreatesOnlyEmptyCommitStores() throws {
        let before = try state()
        try writer.migrate()
        try writer.migrate()
        guard try requireSchema() else { return }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("session_index_jobs"), 0)
    }

    func testMigrationPreservesLegacyRowsWithoutInventingIdentityAliases() throws {
        try seedSession(id: "native-session", owner: "local")
        let fixture = try makeFixture()
        try writer.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS capture_ingest_generations")
            try db.execute(sql: "DROP TABLE IF EXISTS capture_ingest_identity_bindings")
        }
        let before = try state()
        try writer.migrate()
        guard try requireSchema() else { return }
        XCTAssertEqual(try state().filter { before[$0.key] != nil }, before)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try ledger(fixture)["status"] as String, "processing")
    }

    func testNormalizedStorageBudgetAndSchemaAreFixedNotAnIPCFrameLimit() {
        XCTAssertEqual(CaptureIngestCommitter.normalizedSchemaVersion, 1)
        XCTAssertEqual(CaptureIngestCommitter.maximumNormalizedPayloadBytes, 100 * 1024 * 1024)
        XCTAssertEqual(CaptureIngestCommitter.maximumNormalizedMessages, 10_000)
        XCTAssertGreaterThan(CaptureIngestCommitter.maximumNormalizedPayloadBytes, 256 * 1024)
    }

    func testFirstCommitAtomicallyPersistsCompleteProvenanceSnapshotJobAndParsedOnly() throws {
        let fixture = try makeFixture()
        let intakeBefore = try intakeState()
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertEqual(receipt.sessionID, try fixture.replay.nativeIdentity.proposedSessionID())
        XCTAssertEqual(receipt.syncVersion, 1, "publication sequence is not a snapshot version")
        XCTAssertEqual(receipt.generationID.count, 64)
        XCTAssertEqual(receipt.generationID, receipt.generationID.lowercased())
        let generation = try generation(receipt)
        XCTAssertEqual(generation["publication_sha256"] as String, fixture.claim.publicationSHA256)
        XCTAssertEqual(generation["parser_revision"] as String, revision)
        XCTAssertEqual(generation["machine_id"] as String, machine)
        XCTAssertEqual(generation["source_instance_id"] as String, instance)
        XCTAssertEqual(generation["source"] as String, "claude-code")
        XCTAssertEqual(generation["parse_format"] as String, "claudeDefault")
        XCTAssertEqual(generation["configured_root"] as String, logicalRoot)
        XCTAssertEqual(generation["collector_epoch"] as String, epoch)
        XCTAssertEqual(generation["authority_generation"] as Int64, 1)
        XCTAssertEqual(generation["sequence"] as Int64, fixture.claim.publication.sequence)
        XCTAssertEqual(generation["native_id"] as String, "native-session")
        XCTAssertEqual(generation["raw_source_session_id"] as String, fixture.replay.rawSourceSessionID)
        XCTAssertEqual(generation["stored_session_id"] as String, receipt.sessionID)
        XCTAssertEqual(generation["manifest_json"] as Data, try ArchiveCanonicalJSON.encode(fixture.replay.verifiedManifest))
        XCTAssertEqual(generation["normalized_schema_version"] as Int, 1)
        XCTAssertEqual(generation["normalized_message_count"] as Int, fixture.replay.scan.messages.count)
        XCTAssertEqual(generation["sync_version"] as Int, receipt.syncVersion)
        XCTAssertEqual(generation["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(generation["created_at"] as String, timestamp)
        try assertPayload(receipt, equals: fixture.replay.scan.messages)
        let binding = try identity(fixture)
        XCTAssertEqual(binding["stored_session_id"] as String, receipt.sessionID)
        XCTAssertEqual(binding["last_parsed_generation_id"] as String, receipt.generationID)
        XCTAssertEqual(binding["last_sync_version"] as Int, 1)
        XCTAssertNil(binding["last_ready_generation_id"] as String?)
        let session = try session(receipt.sessionID)
        XCTAssertEqual(session["authoritative_node"] as String, fixture.replay.nativeIdentity.peer)
        XCTAssertEqual(session["sync_version"] as Int, receipt.syncVersion)
        XCTAssertEqual(session["snapshot_hash"] as String, receipt.snapshotHash)
        XCTAssertEqual(session["source_locator"] as String, "capture://\(receipt.generationID)")
        XCTAssertFalse((session["file_path"] as String).contains("/offline-client/"))
        try assertExactPendingFTS(receipt)
        try assertParsedOnly(fixture, receipt: receipt)
        XCTAssertEqual(try intakeState(), intakeBefore, "parsed commit does not advance intake")
    }

    func testLargeUnicodeToolFieldsAndEveryNormalizedFieldRoundTripWithoutFragmentsLost() throws {
        let toolText = String(repeating: "漢字😀\\\"\n", count: 30_000)
        let messages: [NormalizedMessage] = [
            .init(role: .user, content: "Implement the complete transcript reader.", timestamp: timestamp),
            .init(role: .assistant, content: "Implemented it.", timestamp: timestamp,
                  toolCalls: [.init(name: "Write", input: toolText, output: toolText + "tail-output"),
                              .init(name: "Read", input: nil, output: "")],
                  usage: .init(inputTokens: 7, outputTokens: 11, cacheReadTokens: 13, cacheCreationTokens: 17)),
            .init(role: .tool, content: "complete tool message", timestamp: nil, toolCalls: []),
            .init(role: .system, content: "preserved supported role", timestamp: timestamp),
        ]
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        let payload: Data = try generation(receipt)["normalized_messages_json"]
        XCTAssertGreaterThan(payload.count, 256 * 1024)
        try assertPayload(receipt, equals: messages)
        XCTAssertEqual(try count("sessions_fts"), 0, "storage has no read/FTS consumer in T2")
        try assertParsedOnly(fixture, receipt: receipt)
    }

    func testTenThousandCompleteMessagesAreAcceptedWithoutPrefixTruncation() throws {
        let messages = (0..<10_000).map { index in
            NormalizedMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                              content: "message-\(index)", timestamp: timestamp)
        }
        let fixture = try makeFixture(messages: messages)
        guard let receipt = requireCommit(fixture) else { return }
        try assertPayload(receipt, equals: messages)
        XCTAssertEqual(try generation(receipt)["normalized_message_count"] as Int, 10_000)
    }

    func testOverMessageBudgetFailsWholeGenerationInsteadOfSavingAPrefix() throws {
        let fixture = try makeFixture()
        var scan = fixture.replay.scan
        scan.messages = Array(repeating: .init(role: .user, content: "not a successful prefix"), count: 10_001)
        let before = try state()
        assertCommitError(.tooManyMessages) { try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan)) }
        XCTAssertEqual(try state(), before)
    }

    func testOverEncodedPayloadBudgetFailsWholeGenerationWithoutPersistingLargeLogs() throws {
        let fixture = try makeFixture()
        let before = try state()
        // The fixture manifest stays small. The budget must reject this forged
        // in-memory artifact before any database payload or diagnostic is saved.
        var scan = fixture.replay.scan
        scan.messages[1].toolCalls = [.init(name: "Write", input: String(repeating: "x", count: 100 * 1024 * 1024 + 1))]
        assertCommitError(.normalizedPayloadTooLarge) {
            try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan))
        }
        XCTAssertEqual(try state(), before)
    }

    func testNewGenerationWithSameHashGetsNewSyncVersionAndExactFTSJob() throws {
        let first = try makeFixture(sequence: 100)
        guard let one = requireCommit(first) else { return }
        let immutable = try generation(one)
        let second = try makeFixture(sequence: 101)
        guard let two = requireCommit(second) else { return }
        XCTAssertEqual(two.snapshotHash, one.snapshotHash)
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertNotEqual(two.generationID, one.generationID)
        XCTAssertNotEqual(two.requiredFTSJobID, one.requiredFTSJobID)
        XCTAssertEqual(try generation(one), immutable)
        XCTAssertEqual(try count("capture_ingest_generations"), 2)
        try assertExactPendingFTS(two)
        XCTAssertEqual(try identity(second)["last_parsed_generation_id"] as String, two.generationID)
        XCTAssertNil(try identity(second)["last_ready_generation_id"] as String?)
    }

    func testAnotherIdentityHigherStreamSequenceDoesNotRejectLegalLowerSequence() throws {
        let high = try makeFixture(nativeID: "other-session", sequence: 9_000)
        guard requireCommit(high) != nil else { return }
        let low = try makeFixture(nativeID: "native-session", sequence: 2)
        guard let committed = requireCommit(low) else { return }
        XCTAssertEqual(committed.syncVersion, 1)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 2)
        XCTAssertEqual(try count("sessions"), 2)
        try assertExactPendingFTS(committed)
    }

    func testOlderIdentitySequenceIsRejectedBeforeNoopSidecarsOrOrphanRecovery() throws {
        let latest = try makeFixture(sequence: 50)
        guard let current = requireCommit(latest) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET orphan_status = 'orphaned', orphan_reason = 'keep' WHERE id = ?",
                                         arguments: [current.sessionID]) }
        let older = try makeFixture(sequence: 49, messages: [
            .init(role: .user, content: "Replace sidecars incorrectly."),
            .init(role: .assistant, content: "Incorrect old result.",
                  toolCalls: [.init(name: "WrongOldTool", input: "old")],
                  usage: .init(inputTokens: 999, outputTokens: 999)),
        ])
        let before = try state()
        assertCommitError(.staleGeneration) { try self.commit(older) }
        XCTAssertEqual(try state(), before)
    }

    func testEqualStreamSequenceDifferentPublicationNeverCreatesSecondGeneration() throws {
        let first = try makeFixture(sequence: 7)
        guard let committed = requireCommit(first) else { return }
        let productBefore = try productState()
        let competing = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: 7, manifestSHA256: String(repeating: "0", count: 64))
        _ = try accept(competing, parser: revision)
        let conflict = try writer.read { try XCTUnwrap(Row.fetchOne($0,
            sql: "SELECT status, failure_code FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
            arguments: [competing.sha256(), revision])) }
        XCTAssertEqual(conflict["status"] as String, "quarantined")
        XCTAssertEqual(conflict["failure_code"] as String, "sequence_conflict")
        XCTAssertNil(try writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: competing.sha256(),
                                                                     parserRevision: revision, now: 101, leaseDuration: 10) })
        assertLedgerError(.claimLost) { try self.commit(first) }
        XCTAssertEqual(try productState(), productBefore)
        XCTAssertEqual(try identity(first)["last_parsed_generation_id"] as String, committed.generationID)
    }

    func testSamePublicationCanReparseOnlyAsNewTrustedRevisionWithoutLexicalOrdering() throws {
        let first = try makeFixture()
        guard let one = requireCommit(first) else { return }
        let next = try withRevision(first, parser: "swift-parser-a")
        guard let two = requireCommit(next, expectedRevision: "swift-parser-a") else { return }
        XCTAssertEqual(next.claim.publicationSHA256, first.claim.publicationSHA256)
        XCTAssertNotEqual(two.generationID, one.generationID)
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertEqual(two.snapshotHash, one.snapshotHash)
        XCTAssertEqual(try count("capture_ingest_generations"), 2)
        try assertExactPendingFTS(two)
    }

    func testOldClaimRevisionFailsAgainstTrustedCurrentRevisionAndCannotSortItsWayIn() throws {
        let fixture = try makeFixture()
        let before = try state()
        assertCommitError(.parserRevisionChanged) { try self.commit(fixture, expectedRevision: "swift-parser-a") }
        XCTAssertEqual(try state(), before)
        let composed = try withRevision(fixture, parser: "parser-é")
        let unicodeBefore = try state()
        assertCommitError(.parserRevisionChanged) { try self.commit(composed, expectedRevision: "parser-e\u{301}") }
        XCTAssertEqual(try state(), unicodeBefore, "revision equality is byte exact, not Unicode equivalence")
    }

    func testExpectedParserRevisionMustSatisfyTheExistingBoundedRevisionContract() throws {
        let fixture = try makeFixture()
        let before = try state()
        for invalid in ["", " leading", "trailing ", "bad\0revision", String(repeating: "x", count: 129)] {
            assertCommitError(.invalidParserRevision) { try self.commit(fixture, expectedRevision: invalid) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testSamePublicationRevisionReplayNeverResetsAnyExistingJobState() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture), let jobID = receipt.requiredFTSJobID else { return }
        for status in ["pending", "processing", "failed_retryable", "failed_permanent", "completed", "not_applicable"] {
            try writer.write { try $0.execute(sql: """
                UPDATE session_index_jobs SET status = ?, retry_count = 8, last_error = 'preserved',
                    created_at = '2001-01-01', updated_at = '2002-02-02', not_before = '2003-03-03'
                WHERE id = ?
                """, arguments: [status, jobID]) }
            let before = try state()
            XCTAssertNil(try claim(fixture))
            assertLedgerError(.claimLost) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before, status)
        }
    }

    func testRestartDoesNotDuplicateCommittedGenerationOrAdvanceItsHead() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let before = try state()
        writer = nil
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        XCTAssertNil(try claim(fixture))
        assertLedgerError(.claimLost) { try self.commit(fixture) }
        XCTAssertEqual(try state(), before)
        XCTAssertEqual(try identity(fixture)["last_parsed_generation_id"] as String, receipt.generationID)
    }

    func testIndependentWritersCannotCommitTheSameClaimTwice() async throws {
        let fixture = try makeFixture()
        let firstWriter = try XCTUnwrap(writer)
        let secondWriter = try EngramDatabaseWriter(path: databasePath)
        let parser = revision
        let indexedAt = timestamp
        let attempts = await withTaskGroup(of: CommitAttempt.self) { group in
            for current in [firstWriter, secondWriter] {
                group.addTask {
                    do {
                        let receipt = try current.write { try CaptureIngestCommitter.commitParsed($0,
                            claim: fixture.claim, replay: fixture.replay, expectedParserRevision: parser,
                            now: 101, indexedAt: indexedAt) }
                        return .committed(receipt)
                    } catch CaptureIngestLedgerError.claimLost {
                        return .claimLost
                    } catch {
                        return .unexpected(String(describing: type(of: error)))
                    }
                }
            }
            var result: [CommitAttempt] = []
            for await attempt in group { result.append(attempt) }
            return result
        }
        var receipts: [CaptureIngestCommittedGeneration] = []
        var rejected = 0
        for attempt in attempts {
            switch attempt {
            case .committed(let receipt): receipts.append(receipt)
            case .claimLost: rejected += 1
            case .unexpected(let type): XCTFail("competing commit must not throw an unrelated error: \(type)")
            }
        }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(rejected, 1)
        guard let receipt = receipts.first else { return }
        XCTAssertEqual(try count("capture_ingest_generations"), 1)
        XCTAssertEqual(try count("sessions"), 1)
        try assertExactPendingFTS(receipt)
        try assertParsedOnly(fixture, receipt: receipt)
    }

    func testApprovedNewAuthoritySequenceOneSupersedesOldThousandWithoutMovingReadyHead() throws {
        let old = try makeFixture(sequence: 1_000)
        guard let one = requireCommit(old) else { return }
        try markReadyForFixture(old, receipt: one)
        let immutable = try generation(one)
        _ = try approveNextEpoch()
        let next = try makeFixture(sequence: 1)
        guard let two = requireCommit(next) else { return }
        XCTAssertEqual(two.syncVersion, 2)
        XCTAssertEqual(try generation(two)["authority_generation"] as Int64, 2)
        XCTAssertEqual(try generation(two)["sequence"] as Int64, 1)
        XCTAssertEqual(try identity(next)["last_ready_generation_id"] as String, one.generationID)
        XCTAssertEqual(try generation(one), immutable)
        XCTAssertEqual(try ledger(old)["status"] as String, "index_ready")
        XCTAssertEqual(try ledger(next)["status"] as String, "parsed")
    }

    func testUnknownEpochAndRegistryChangeAfterReplayCannotGrantCommitAuthority() throws {
        let unknown = try makeFixture(publicationEpoch: nextEpoch)
        let before = try state()
        assertCommitError(.bindingChanged) { try self.commit(unknown) }
        XCTAssertEqual(try state(), before)
        let old = try makeFixture(sequence: 2)
        _ = try approveNextEpoch()
        let afterApproval = try state()
        assertCommitError(.bindingChanged) { try self.commit(old) }
        XCTAssertEqual(try state(), afterApproval)
    }

    func testEveryBindingSnapshotFieldIsRecheckedWithByteExactStrings() throws {
        let fixture = try makeFixture()
        let original = fixture.replay.bindingSnapshot
        let variants = [
            binding(original, machineID: otherMachine), binding(original, instanceID: otherInstance),
            binding(original, source: .codex), binding(original, format: .claudeCustomProfile),
            binding(original, root: logicalRoot + "/different"), binding(original, approvedEpoch: nextEpoch),
            binding(original, authority: 2),
        ]
        let before = try state()
        for changed in variants {
            assertCommitError(.bindingChanged) { try self.commit(fixture, replay: self.replacing(fixture.replay, binding: changed)) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testRegistryFieldsChangedAfterReplayRejectWithoutAnyCommitSideEffects() throws {
        let fixture = try makeFixture()
        let fields: [(String, DatabaseValue, DatabaseValue)] = [
            ("machine_id", otherMachine.databaseValue, machine.databaseValue),
            ("source_instance_id", otherInstance.databaseValue, instance.databaseValue),
            ("source", "codex".databaseValue, "claude-code".databaseValue),
            ("parse_format", "claudeCustomProfile".databaseValue, "claudeDefault".databaseValue),
            ("configured_root", (logicalRoot + "/changed").databaseValue, logicalRoot.databaseValue),
            ("approved_epoch", nextEpoch.databaseValue, epoch.databaseValue),
            ("authority_generation", Int64(2).databaseValue, Int64(1).databaseValue),
        ]
        for (column, changed, original) in fields {
            try mutateRegistryField(column, value: changed)
            let afterDrift = try state()
            XCTAssertThrowsError(try commit(fixture)) { error in
                // Single-field corruption may invalidate the registry's own
                // history check before the complete binding can be compared.
                XCTAssertTrue(error as? CaptureIngestCommitError == .bindingChanged
                    || error as? CaptureIngestSourceRegistryError == .invalidStoredBinding, column)
            }
            XCTAssertEqual(try state(), afterDrift, column)
            try mutateRegistryField(column, value: original)
        }
    }

    func testExpiredLeaseBoundaryAndNegativeTimeRejectBeforeAnyCommitWrites() throws {
        let fixture = try makeFixture()
        let before = try state()
        assertLedgerError(.invalidTime) { try self.commit(fixture, now: -1) }
        assertLedgerError(.invalidTime) { try self.commit(fixture, now: 99) }
        assertLedgerError(.claimLost) { try self.commit(fixture, now: 110) }
        XCTAssertEqual(try state(), before)
    }

    func testReclaimedTokenRevokesOldCommitButNewClaimCanCommit() throws {
        let fixture = try makeFixture()
        let renewed = try XCTUnwrap(claim(fixture, now: 110))
        XCTAssertNotEqual(renewed.token, fixture.claim.token)
        let before = try state()
        assertLedgerError(.claimLost) { try self.commit(fixture, now: 111) }
        XCTAssertEqual(try state(), before)
        guard let receipt = requireCommit(fixture.withClaim(renewed), now: 111) else { return }
        XCTAssertEqual(receipt.syncVersion, 1)
    }

    func testNonProcessingLedgerStateAlwaysRevokesFormerToken() throws {
        for (index, status) in ["pending", "parsed", "index_ready", "quarantined", "failed_retryable"].enumerated() {
            let fixture = try makeFixture(nativeID: "state-\(index)", sequence: Int64(index + 1))
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET status = ? WHERE publication_sha256 = ?",
                                             arguments: [status, fixture.claim.publicationSHA256]) }
            let before = try state()
            assertLedgerError(.claimLost) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testPostClaimCanonicalPublicationCorruptionCannotReachTheSnapshotWriter() throws {
        let fixture = try makeFixture()
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_publications SET canonical_bytes = ? WHERE publication_sha256 = ?",
                                         arguments: [Data("corrupt".utf8), fixture.claim.publicationSHA256]) }
        let before = try state()
        assertLedgerError(.invalidStoredRecord) { try self.commit(fixture) }
        XCTAssertEqual(try state(), before)
    }

    func testForgedReplayPublicationManifestIdentityAndScanRelationshipsAreRejected() throws {
        let fixture = try makeFixture()
        let replay = fixture.replay
        var wrongID = replay.scan
        wrongID.info.id = "forged-native"
        var wrongSource = replay.scan
        wrongSource.info.source = .codex
        var wrongLocator = replay.scan
        wrongLocator.info.filePath = "/private/staging/forged.jsonl"
        let anotherIdentity = try replay.nativeIdentity.mapping(nativeID: "different-native")
        let crossNamespaceParent = try CaptureIngestIdentity(machineID: otherMachine, sourceInstanceID: instance,
                                                           source: .claudeCode, nativeID: "parent")
        let anotherManifest = try manifest(binding: replay.bindingSnapshot, nativeID: "native-session", sequence: 999,
                                          messages: replay.scan.messages, captureSalt: "wrong-manifest")
        let variants = [
            replacing(replay, digest: String(repeating: "0", count: 64)),
            replacing(replay, manifest: anotherManifest), replacing(replay, identity: anotherIdentity),
            replacing(replay, scan: wrongID), replacing(replay, scan: wrongSource), replacing(replay, scan: wrongLocator),
            replacing(replay, rawNativeID: ""), replacing(replay, rawNativeID: "bad\0native"),
            replacing(replay, parent: crossNamespaceParent), replacing(replay, suggested: crossNamespaceParent),
        ]
        let before = try state()
        for variant in variants {
            assertCommitError(.invalidReplay) { try self.commit(fixture, replay: variant) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testEveryPartialParseFailureRejectsCompleteLookingMessagePrefixes() throws {
        let fixture = try makeFixture()
        let before = try state()
        for failure in ParserFailure.allCases {
            var scan = fixture.replay.scan
            scan.parseFailure = failure
            assertCommitError(.invalidReplay) { try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan)) }
            XCTAssertEqual(try state(), before, failure.rawValue)
        }
    }

    func testJSONEscapeExpansionCountsAgainstTheEncodedPayloadBudget() throws {
        let fixture = try makeFixture()
        var scan = fixture.replay.scan
        scan.messages[1].toolCalls = [.init(name: "Write", output: String(repeating: "\u{0001}", count: 20 * 1024 * 1024))]
        let before = try state()
        assertCommitError(.normalizedPayloadTooLarge) {
            try self.commit(fixture, replay: self.replacing(fixture.replay, scan: scan))
        }
        XCTAssertEqual(try state(), before, "the encoded JSON bytes, not Swift character count, set the budget")
    }

    func testMachineInstanceSourceAndExactNativeBytesKeepDistinctIdentities() throws {
        let fixtures = [
            try makeFixture(nativeID: "native-é", sequence: 1),
            try makeFixture(nativeID: "native-e\u{301}", sequence: 2),
            try makeFixture(nativeID: "native-é", sequence: 1, machineID: otherMachine),
            try makeFixture(nativeID: "native-é", sequence: 1, instanceID: otherInstance,
                            root: "/offline-client/second-profile/projects"),
            try makeFixture(nativeID: "native-é", sequence: 1, source: .codex,
                            instanceID: nextEpoch, root: "/offline-client/.codex/sessions"),
        ]
        var storedIDs: [String] = []
        for fixture in fixtures {
            guard let receipt = requireCommit(fixture) else { return }
            storedIDs.append(receipt.sessionID)
            XCTAssertTrue((try identity(fixture)["native_id"] as String).utf8.elementsEqual(fixture.replay.nativeIdentity.nativeID.utf8))
        }
        XCTAssertEqual(Set(storedIDs).count, fixtures.count)
        XCTAssertEqual(try count("sessions"), fixtures.count)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), fixtures.count)
    }

    func testExistingProposedIDWithoutProvenBindingIsRejectedEvenForMatchingOwner() throws {
        for (index, owner) in ["local", "capture-v1.\(machine).\(instance)", "legacy-hq"].enumerated() {
            let fixture = try makeFixture(nativeID: "collision-\(index)", sequence: Int64(index + 1))
            let proposed = try fixture.replay.nativeIdentity.proposedSessionID()
            try seedSession(id: proposed, owner: owner)
            let before = try state()
            assertCommitError(.identityConflict) { try self.commit(fixture) }
            XCTAssertEqual(try state(), before, "matching string namespace is not alias proof")
        }
    }

    func testUnprovedSameNativeLocalRowCanCoexistWithoutAliasOrUserDataChanges() throws {
        let fixture = try makeFixture()
        let localID = fixture.replay.nativeIdentity.nativeID
        try seedSession(id: localID, owner: "local")
        try writer.write { db in
            try db.execute(sql: "INSERT INTO session_local_state(session_id, hidden_at, custom_name, local_readable_path) VALUES (?, '2001-01-01', 'keep-local-name', '/legacy/keep.jsonl')",
                           arguments: [localID])
            try db.execute(sql: "INSERT INTO insights(id, content, source_session_id) VALUES ('local-insight', 'keep local insight', ?)",
                           arguments: [localID])
        }
        let localBefore = try session(localID)
        let dependenciesBefore = try writer.read { try state($0, tables: ["session_local_state", "insights"]) }
        guard let receipt = requireCommit(fixture) else { return }
        XCTAssertNotEqual(receipt.sessionID, localID)
        XCTAssertEqual(try session(localID), localBefore)
        XCTAssertEqual(try writer.read { try state($0, tables: ["session_local_state", "insights"]) }, dependenciesBefore)
        XCTAssertEqual(try count("sessions"), 2)
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 1)
        XCTAssertEqual(try identity(fixture)["stored_session_id"] as String, receipt.sessionID)
        // No same-machine proof is inferred from native ID or path coincidence.
        // Legacy alias/cutover proof is deliberately outside this shadow-DB slice.
    }

    func testPersistedIdentityCannotTransferToAnUnprovedStoredIDOrForeignOwner() throws {
        let first = try makeFixture()
        guard let one = requireCommit(first) else { return }
        let next = try makeFixture(sequence: 2)
        try seedSession(id: "foreign", owner: "local")
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_identity_bindings SET stored_session_id = 'foreign'") }
        let redirected = try state()
        assertCommitError(.identityConflict) { try self.commit(next) }
        XCTAssertEqual(try state(), redirected)
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET stored_session_id = ?", arguments: [one.sessionID])
            try db.execute(sql: "UPDATE sessions SET authoritative_node = 'foreign-owner' WHERE id = ?", arguments: [one.sessionID])
        }
        let wrongOwner = try state()
        assertCommitError(.identityConflict) { try self.commit(next) }
        XCTAssertEqual(try state(), wrongOwner)
    }

    func testNextSyncVersionChecksMaximumOfRowBindingAndImmutableGenerationHistory() throws {
        for (index, counter) in ["session", "binding", "generation"].enumerated() {
            let first = try makeFixture(nativeID: "version-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion(counter, receipt: one, value: .int64(50))
            let next = try makeFixture(nativeID: "version-\(index)", sequence: Int64(index * 2 + 2))
            guard let two = requireCommit(next) else { return }
            XCTAssertEqual(two.syncVersion, 51, counter)
            try assertExactPendingFTS(two)
        }
    }

    func testCommitMaterializesBoundedHistoryRowsForManyGenerations() throws {
        let first = try makeFixture(sequence: 1)
        guard let one = requireCommit(first) else { return }
        try seedHistory(from: one, versions: 2...64)
        XCTAssertEqual(try count("capture_ingest_generations"), 64)
        let next = try makeFixture(sequence: 2)

        // SQLITE_TRACE_ROW measures result rows crossing into Swift, not rows
        // scanned by SQLite. The bound does not claim constant SQL scan work.
        var historyRows = 0
        let two = try withUnsafeMutablePointer(to: &historyRows) { counter in
            try writer.write { db in
                XCTAssertEqual(sqlite3_trace_v2(db.sqliteConnection, UInt32(SQLITE_TRACE_ROW), { _, context, statement, _ in
                    guard let context, let statement,
                          let rawSQL = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    let sql = String(cString: rawSQL).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if sql.hasPrefix("select ") && sql.contains("from capture_ingest_generations") {
                        context.assumingMemoryBound(to: Int.self).pointee += 1
                    }
                    return 0
                }, counter), SQLITE_OK)
                defer { sqlite3_trace_v2(db.sqliteConnection, 0, nil, nil) }
                return try CaptureIngestCommitter.commitParsed(db, claim: next.claim, replay: next.replay,
                    expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            }
        }
        XCTAssertGreaterThan(historyRows, 0, "the production history reads must actually be measured")
        XCTAssertLessThanOrEqual(historyRows, 4, "history result materialization must stay bounded as generations grow")
        XCTAssertEqual(two.syncVersion, 65, "non-head history still participates in the maximum")
        try assertExactPendingFTS(two)
    }

    func testNonHeadCorruptHistoryRejectsDespiteValidHeadAndLargerValidCounters() throws {
        let first = try makeFixture(nativeID: "native-é", sequence: 1)
        guard let one = requireCommit(first) else { return }
        let historicalID = try XCTUnwrap(seedHistory(from: one, versions: 2...2).first)
        try setVersion("session", receipt: one, value: .int64(50))
        try setVersion("binding", receipt: one, value: .int64(50))
        let next = try makeFixture(nativeID: "native-é", sequence: 2)
        let originalIdentity: [String: DatabaseValue] = [
            "machine_id": machine.databaseValue, "source_instance_id": instance.databaseValue,
            "source": "claude-code".databaseValue, "native_id": "native-é".databaseValue,
        ]
        let variants: [(String, DatabaseValue)] = [
            ("machine_id", otherMachine.databaseValue), ("source_instance_id", otherInstance.databaseValue),
            ("source", "codex".databaseValue), ("native_id", "native-e\u{301}".databaseValue),
            ("machine_id", Data(machine.utf8).databaseValue),
            ("source_instance_id", Data(instance.utf8).databaseValue),
            ("source", Data("claude-code".utf8).databaseValue), ("native_id", Data("native-é".utf8).databaseValue),
            ("sync_version", "not-an-integer".databaseValue), ("sync_version", 1.5.databaseValue),
            ("sync_version", Data([2]).databaseValue), ("sync_version", Int64(0).databaseValue),
            ("sync_version", Int64(-1).databaseValue),
        ]
        for (index, variant) in variants.enumerated() {
            let (column, value) = variant
            if column != "sync_version" {
                let foreignID = "corrupt-history-identity-\(index)"
                try seedSession(id: foreignID, owner: "local")
                var foreign = originalIdentity
                foreign[column] = value
                // Keep the composite FK valid while making provenance disagree
                // with the generation's stored session. No FK bypass is needed.
                try writer.write { try $0.execute(sql: """
                    INSERT INTO capture_ingest_identity_bindings(machine_id, source_instance_id, source, native_id, stored_session_id)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [foreign["machine_id"]!, foreign["source_instance_id"]!, foreign["source"]!,
                                       foreign["native_id"]!, foreignID.databaseValue]) }
            }
            try writer.write { db in
                // Deliberately seed zero/negative historical corruption in this
                // isolated fixture, then restore CHECK enforcement immediately.
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { XCTAssertNoThrow(try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")) }
                try db.execute(sql: "UPDATE capture_ingest_generations SET \(column) = ? WHERE generation_id = ?",
                               arguments: [value, historicalID])
            }
            XCTAssertEqual(try identity(next)["last_parsed_generation_id"] as String, one.generationID)
            let before = try state()
            assertCommitError(.invalidStoredRecord) { try self.commit(next) }
            XCTAssertEqual(try state(), before, "non-head corruption variant \(index): \(column)")
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_generations SET \(column) = ? WHERE generation_id = ?",
                arguments: [originalIdentity[column] ?? Int64(2).databaseValue, historicalID]) }
        }
        guard let two = requireCommit(next) else { return }
        XCTAssertEqual(two.syncVersion, 51, "failed attempts preserve the claim and valid maximum counters")
    }

    func testOverflowInAnyRelatedSyncVersionRejectsAtomically() throws {
        for (index, counter) in ["session", "binding", "generation"].enumerated() {
            let first = try makeFixture(nativeID: "overflow-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion(counter, receipt: one, value: .int64(Int64.max))
            let next = try makeFixture(nativeID: "overflow-\(index)", sequence: Int64(index * 2 + 2))
            let before = try state()
            assertCommitError(.syncVersionOverflow) { try self.commit(next) }
            XCTAssertEqual(try state(), before, counter)
        }
    }

    func testMalformedPersistedVersionCannotCoerceToAValidOrderingCounter() throws {
        for (index, malformed) in [DatabaseValue.Storage.int64(-1), .string("not-an-integer"), .double(1.5)].enumerated() {
            let first = try makeFixture(nativeID: "malformed-version-\(index)", sequence: Int64(index * 2 + 1))
            guard let one = requireCommit(first) else { return }
            try setVersion("session", receipt: one, value: malformed)
            let next = try makeFixture(nativeID: "malformed-version-\(index)", sequence: Int64(index * 2 + 2))
            let before = try state()
            assertCommitError(.invalidStoredRecord) { try self.commit(next) }
            XCTAssertEqual(try state(), before)
        }
    }

    func testKnownParentMapsOnlyInsideItsNamespaceAndSuggestedParentDoesNotBecomeALink() throws {
        let parent = try makeFixture(nativeID: "parent", sequence: 1)
        guard let parentReceipt = requireCommit(parent) else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent", suggestedNativeID: "other-hint")
        guard let childReceipt = requireCommit(child) else { return }
        XCTAssertEqual(try session(childReceipt.sessionID)["parent_session_id"] as String, parentReceipt.sessionID)
        XCTAssertEqual(try generation(childReceipt)["parent_native_id"] as String, "parent")
        XCTAssertEqual(try generation(childReceipt)["suggested_parent_native_id"] as String, "other-hint")
        let hintOnly = try makeFixture(nativeID: "hint-only", sequence: 3, suggestedNativeID: "parent")
        guard let hintReceipt = requireCommit(hintOnly) else { return }
        XCTAssertNil(try session(hintReceipt.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try generation(hintReceipt)["suggested_parent_native_id"] as String, "parent")
    }

    func testUnknownOrCrossNamespaceParentRemainsUnlinkedWithoutLosingNativeProvenance() throws {
        let foreignParent = try makeFixture(nativeID: "parent", machineID: otherMachine)
        guard requireCommit(foreignParent) != nil else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent")
        guard let receipt = requireCommit(child) else { return }
        XCTAssertNil(try session(receipt.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try generation(receipt)["parent_native_id"] as String, "parent")
        XCTAssertEqual(try count("capture_ingest_identity_bindings"), 2, "do not create an unproved placeholder parent binding")
    }

    func testManualUnlinkStaysAuthoritativeAcrossCapturedGenerations() throws {
        let parent = try makeFixture(nativeID: "parent", sequence: 1)
        guard requireCommit(parent) != nil else { return }
        let child = try makeFixture(nativeID: "child", sequence: 2, parentNativeID: "parent")
        guard let one = requireCommit(child) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET parent_session_id = NULL, link_source = 'manual' WHERE id = ?",
                                         arguments: [one.sessionID]) }
        let next = try makeFixture(nativeID: "child", sequence: 3, parentNativeID: "parent")
        guard let two = requireCommit(next) else { return }
        XCTAssertNil(try session(two.sessionID)["parent_session_id"] as String?)
        XCTAssertEqual(try session(two.sessionID)["link_source"] as String, "manual")
    }

    func testSkipPayloadIsPreservedWithoutFTSOrReadyPromotionAndPinnedDispatchStaysSkip() throws {
        let skipped = try makeFixture(nativeID: "dispatched", sequence: 1, agentRole: "dispatched")
        guard let receipt = requireCommit(skipped) else { return }
        XCTAssertEqual(try session(receipt.sessionID)["tier"] as String, "skip")
        XCTAssertNil(receipt.requiredFTSJobID)
        XCTAssertNil(try generation(receipt)["required_fts_job_id"] as String?)
        try assertPayload(receipt, equals: skipped.replay.scan.messages)
        try assertParsedOnly(skipped, receipt: receipt)
        let ordinary = try makeFixture(nativeID: "pinned-skip", sequence: 2)
        guard let normal = requireCommit(ordinary) else { return }
        try writer.write { try $0.execute(sql: "UPDATE sessions SET tier = 'skip', agent_role = 'dispatched' WHERE id = ?",
                                         arguments: [normal.sessionID]) }
        let next = try makeFixture(nativeID: "pinned-skip", sequence: 3)
        guard let preserved = requireCommit(next) else { return }
        XCTAssertEqual(try session(preserved.sessionID)["tier"] as String, "skip")
        XCTAssertNil(preserved.requiredFTSJobID)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM session_index_jobs WHERE session_id = ? AND target_sync_version = ?",
                                                        arguments: [preserved.sessionID, preserved.syncVersion]) }, 0)
    }

    func testEnsureHelperRejectsNoncurrentOwnerVersionHashAndAbsentSessionWithoutWrites() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture) else { return }
        let before = try state()
        let variants = [
            ("missing-session", fixture.replay.nativeIdentity.peer, receipt.syncVersion, receipt.snapshotHash),
            (receipt.sessionID, "wrong-owner", receipt.syncVersion, receipt.snapshotHash),
            (receipt.sessionID, fixture.replay.nativeIdentity.peer, receipt.syncVersion + 1, receipt.snapshotHash),
            (receipt.sessionID, fixture.replay.nativeIdentity.peer, receipt.syncVersion, String(repeating: "0", count: 64)),
        ]
        for (sessionID, owner, version, hash) in variants {
            assertCommitError(.currentSnapshotMismatch) {
                try self.writer.write { try SessionSnapshotWriter(db: $0).ensureCurrentCaptureFTSJob(
                    sessionID: sessionID, authoritativeNode: owner, syncVersion: version, snapshotHash: hash) }
            }
            XCTAssertEqual(try state(), before)
        }
    }

    func testEnsureHelperNeverResetsExactExistingJobStatusRetryOrDebounce() throws {
        let fixture = try makeFixture()
        guard let receipt = requireCommit(fixture), let jobID = receipt.requiredFTSJobID else { return }
        for status in ["pending", "processing", "failed_retryable", "failed_permanent", "completed", "not_applicable"] {
            try writer.write { try $0.execute(sql: """
                UPDATE session_index_jobs SET status = ?, retry_count = 9, last_error = 'keep-symbolic-code',
                    created_at = '2001-01-01', updated_at = '2002-02-02', not_before = '2003-03-03' WHERE id = ?
                """, arguments: [status, jobID]) }
            let before = try state()
            let ensured = try writer.write { try SessionSnapshotWriter(db: $0).ensureCurrentCaptureFTSJob(
                sessionID: receipt.sessionID, authoritativeNode: fixture.replay.nativeIdentity.peer,
                syncVersion: receipt.syncVersion, snapshotHash: receipt.snapshotHash) }
            XCTAssertEqual(ensured, jobID)
            XCTAssertEqual(try state(), before, status)
        }
    }

    func testInitialCommitFailureAtEveryWriteStageRollsBackWhenOuterTransactionContinues() throws {
        guard try requireSchema() else { return }
        let stages: [(String, String, String)] = [
            ("identity_insert", "INSERT", "capture_ingest_identity_bindings"),
            ("snapshot", "INSERT", "sessions"), ("costs", "INSERT", "session_costs"),
            ("tools", "INSERT", "session_tools"), ("beats", "INSERT", "session_work_beats"),
            ("job", "INSERT", "session_index_jobs"), ("generation", "INSERT", "capture_ingest_generations"),
            ("head", "UPDATE", "capture_ingest_identity_bindings"), ("ledger", "UPDATE", "capture_ingest_ledger"),
        ]
        for (index, stage) in stages.enumerated() {
            let fixture = try makeFixture(nativeID: "initial-failure-\(index)", sequence: Int64(index + 1))
            try acceptRevision(fixture, parser: "failure-witness")
            try assertInjectedRollback(stage: stage, fixture: fixture)
        }
    }

    func testReplacementFailureAtEveryWriteStageKeepsLastGoodAndReadyGeneration() throws {
        let first = try makeFixture(sequence: 1)
        guard let receipt = requireCommit(first) else { return }
        try markReadyForFixture(first, receipt: receipt)
        let stages: [(String, String, String)] = [
            ("snapshot", "UPDATE", "sessions"), ("costs", "UPDATE", "session_costs"),
            ("tools", "INSERT", "session_tools"), ("beats", "INSERT", "session_work_beats"),
            ("job", "INSERT", "session_index_jobs"), ("generation", "INSERT", "capture_ingest_generations"),
            ("head", "UPDATE", "capture_ingest_identity_bindings"), ("ledger", "UPDATE", "capture_ingest_ledger"),
        ]
        for (index, stage) in stages.enumerated() {
            let fixture = try makeFixture(sequence: Int64(index + 2), messages: defaultMessages(suffix: " replacement-\(index)"))
            try acceptRevision(fixture, parser: "failure-witness")
            try assertInjectedRollback(stage: stage, fixture: fixture)
            XCTAssertEqual(try identity(first)["last_parsed_generation_id"] as String, receipt.generationID)
            XCTAssertEqual(try identity(first)["last_ready_generation_id"] as String, receipt.generationID)
        }
    }

    func testOuterRollbackAfterSuccessfulCommitRevertsReceiptArtifactsAndLedgerTogether() throws {
        let fixture = try makeFixture()
        let before = try state()
        XCTAssertThrowsError(try writer.write { db in
            _ = try CaptureIngestCommitter.commitParsed(db, claim: fixture.claim, replay: fixture.replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp)
            throw InjectedFailure.outerRollback
        }) { XCTAssertEqual($0 as? InjectedFailure, .outerRollback) }
        XCTAssertEqual(try state(), before)
    }

    private var databasePath: String { directory.appendingPathComponent("index.sqlite").path }

    private struct Fixture: Sendable {
        let claim: CaptureIngestClaim
        let replay: CaptureIngestReplayResult
        let page: CollectorPublicationPage
        let requestedCursor: String?

        func withClaim(_ value: CaptureIngestClaim) -> Self {
            Self(claim: value, replay: replay, page: page, requestedCursor: requestedCursor)
        }
    }

    private enum InjectedFailure: Error, Equatable { case outerRollback }

    private enum CommitAttempt: Sendable {
        case committed(CaptureIngestCommittedGeneration)
        case claimLost
        case unexpected(String)
    }

    private var productTables: [String] {
        ["sessions", "session_local_state", "session_relations", "session_costs", "session_tools",
         "session_work_beats", "session_index_jobs", "sessions_fts", "fts_map", "insights", "sync_ledger",
         "capture_ingest_identity_bindings", "capture_ingest_generations"]
    }

    private var intakeTables: [String] {
        ["capture_ingest_publications", "capture_ingest_arrivals", "capture_ingest_checkpoints",
         "capture_ingest_source_registry", "capture_ingest_epoch_history"]
    }

    private func makeFixture(
        nativeID: String = "native-session", sequence: Int64? = nil, source: SourceName = .claudeCode,
        machineID: String? = nil, instanceID: String? = nil, root: String? = nil,
        publicationEpoch: String? = nil, messages: [NormalizedMessage]? = nil,
        parentNativeID: String? = nil, suggestedNativeID: String? = nil,
        agentRole: String? = nil, captureSalt: String = ""
    ) throws -> Fixture {
        let machineID = machineID ?? machine
        let instanceID = instanceID ?? instance
        let root = root ?? logicalRoot
        let current = try writer.write { db in
            if let existing = try CaptureIngestSourceRegistry.binding(db, machineID: machineID, sourceInstanceID: instanceID) {
                return existing
            }
            return try CaptureIngestSourceRegistry.provision(db, machineID: machineID, sourceInstanceID: instanceID,
                source: source, parseFormat: source == .codex ? .codex : .claudeDefault,
                configuredRoot: root, initialEpoch: epoch)
        }
        let sequence = sequence ?? nextOrdinal
        let messages = messages ?? defaultMessages()
        let manifest = try manifest(binding: current, nativeID: nativeID, sequence: sequence,
                                    messages: messages, captureSalt: captureSalt)
        let publication = try CollectorPublicationEnvelope(machineID: machineID, sourceInstanceID: instanceID,
            collectorEpoch: publicationEpoch ?? current.approvedEpoch, sequence: sequence,
            manifestSHA256: ArchiveV2Hash.sha256(ArchiveCanonicalJSON.encode(manifest)))
        let accepted = try accept(publication, parser: revision)
        let claim = try writer.write { db in
            try XCTUnwrap(CaptureIngestLedger.claim(db, publicationSHA256: publication.sha256(),
                parserRevision: revision, now: 100, leaseDuration: 10))
        }
        let identity = try CaptureIngestIdentity(machineID: machineID, sourceInstanceID: instanceID, source: source, nativeID: nativeID)
        let info = NormalizedSessionInfo(
            id: nativeID, source: source, startTime: "2026-09-06T01:00:00Z", endTime: "2026-09-06T01:02:00Z",
            cwd: "/offline-client/project", project: "project", model: "claude-sonnet-4-20250514",
            messageCount: messages.count,
            userMessageCount: messages.filter { $0.role == .user }.count,
            assistantMessageCount: messages.filter { $0.role == .assistant }.count,
            toolMessageCount: messages.filter { $0.role == .tool }.count,
            systemMessageCount: messages.filter { $0.role == .system }.count,
            summary: "Complete captured session", displayTitle: "Captured fixture",
            filePath: manifest.locator, sizeBytes: manifest.rawByteCount,
            agentRole: agentRole, originator: source == .codex ? "codex" : "claude-code",
            parentSessionId: parentNativeID, suggestedParentId: suggestedNativeID
        )
        let replay = CaptureIngestReplayResult(
            publicationSHA256: claim.publicationSHA256, verifiedManifest: manifest, bindingSnapshot: current,
            scan: IndexingScan(info: info, messages: messages), rawSourceSessionID: nativeID,
            nativeIdentity: identity,
            parentIdentity: try parentNativeID.map { try identity.mapping(nativeID: $0) },
            suggestedParentIdentity: try suggestedNativeID.map { try identity.mapping(nativeID: $0) }
        )
        return Fixture(claim: claim, replay: replay, page: accepted.page, requestedCursor: accepted.requestedCursor)
    }

    private func manifest(
        binding: CaptureIngestSourceBinding, nativeID: String, sequence: Int64,
        messages: [NormalizedMessage], captureSalt: String
    ) throws -> ArchiveSourceManifest {
        // T2 starts after replay: synthetic parse artifacts avoid any source or
        // CAS I/O while retaining a valid canonical manifest/envelope binding.
        let raw = try ArchiveCanonicalJSON.encode(messages)
        let hash = ArchiveV2Hash.sha256(raw)
        let relative = "project/\(ArchiveV2Hash.sha256(Data(nativeID.utf8))).jsonl"
        return try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("\(binding.sourceInstanceID):\(binding.approvedEpoch):\(sequence):\(nativeID):\(captureSalt)".utf8)),
            machineID: binding.machineID, source: binding.source.rawValue,
            locator: binding.configuredRoot + "/" + relative, sessionID: nil, capturedAt: timestamp,
            generation: ArchiveSourceGeneration(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: hash, rawByteCount: Int64(raw.count),
            chunks: [try ArchiveChunkReference(ordinal: 0, rawSHA256: hash, rawByteCount: Int64(raw.count))],
            replayLayout: ArchiveReplayLayout(strategy: .singleFile, relativePaths: [relative])
        )
    }

    private func defaultMessages(suffix: String = "") -> [NormalizedMessage] {
        [
            .init(role: .user, content: "Implement the requested complete transcript reader." + suffix,
                  timestamp: "2026-09-06T01:00:00Z"),
            .init(role: .assistant, content: "Result\nImplemented the complete transcript reader.\n\nValidation\nchecks run: targeted tests" + suffix,
                  timestamp: "2026-09-06T01:02:00Z", toolCalls: [.init(name: "edit_file", input: "fixture", output: "complete")],
                  usage: .init(inputTokens: 100, outputTokens: 50, cacheReadTokens: 3, cacheCreationTokens: 4)),
        ]
    }

    private func accept(_ publication: CollectorPublicationEnvelope, parser: String) throws
        -> (page: CollectorPublicationPage, requestedCursor: String?) {
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: nextOrdinal,
            publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256, storedAt: timestamp)
        nextOrdinal += 1
        let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
        let page = try CollectorPublicationPage(items: [record], afterCursor: CollectorPublicationCursor(
            journalID: journal, afterArrivalOrdinal: ack.arrivalOrdinal).encoded(), hasMore: false)
        let requested = try writer.write { db in
            let cursor = try CaptureIngestLedger.checkpoint(db, serverID: "hq")
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: cursor, serverID: "hq", parserRevision: parser)
            return cursor
        }
        return (page, requested)
    }

    private func acceptRevision(_ fixture: Fixture, parser: String) throws {
        try writer.write { try CaptureIngestLedger.accept($0, page: fixture.page,
            requestedCursor: fixture.requestedCursor, serverID: "hq", parserRevision: parser) }
    }

    private func withRevision(_ fixture: Fixture, parser: String) throws -> Fixture {
        try acceptRevision(fixture, parser: parser)
        let revised = try XCTUnwrap(writer.write { try CaptureIngestLedger.claim($0,
            publicationSHA256: fixture.claim.publicationSHA256, parserRevision: parser, now: 100, leaseDuration: 10) })
        return fixture.withClaim(revised)
    }

    private func claim(_ fixture: Fixture, now: Int64 = 101) throws -> CaptureIngestClaim? {
        try writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: fixture.claim.publicationSHA256,
            parserRevision: fixture.claim.parserRevision, now: now, leaseDuration: 10) }
    }

    private func approveNextEpoch() throws -> CaptureIngestSourceBinding {
        try writer.write { db in
            let current = try XCTUnwrap(CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instance))
            return try CaptureIngestSourceRegistry.approveEpoch(db, machineID: machine, sourceInstanceID: instance,
                candidateEpoch: nextEpoch, expectedEpoch: current.approvedEpoch, expectedAuthorityGeneration: current.authorityGeneration)
        }
    }

    private func mutateRegistryField(_ column: String, value: DatabaseValue) throws {
        try writer.write { db in
            if column == "machine_id" || column == "source_instance_id" {
                // Preserve the existing history FK while changing one binding
                // field. The replay/publication still carry the old identity.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                try db.execute(sql: "UPDATE capture_ingest_epoch_history SET \(column) = ?", arguments: [value])
            }
            try db.execute(sql: "UPDATE capture_ingest_source_registry SET \(column) = ?", arguments: [value])
        }
    }

    @discardableResult
    private func commit(_ fixture: Fixture, replay: CaptureIngestReplayResult? = nil,
                        expectedRevision: String? = nil, now: Int64 = 101) throws -> CaptureIngestCommittedGeneration {
        try writer.write { try CaptureIngestCommitter.commitParsed($0, claim: fixture.claim, replay: replay ?? fixture.replay,
            expectedParserRevision: expectedRevision ?? revision, now: now, indexedAt: timestamp) }
    }

    private func requireCommit(_ fixture: Fixture, expectedRevision: String? = nil, now: Int64 = 101,
                               file: StaticString = #filePath, line: UInt = #line) -> CaptureIngestCommittedGeneration? {
        do { return try commit(fixture, expectedRevision: expectedRevision, now: now) }
        catch {
            XCTFail("eligible complete generation must commit: \(type(of: error))", file: file, line: line)
            return nil
        }
    }

    private func replacing(
        _ replay: CaptureIngestReplayResult, digest: String? = nil, manifest: ArchiveSourceManifest? = nil,
        binding: CaptureIngestSourceBinding? = nil, scan: IndexingScan? = nil, rawNativeID: String? = nil,
        identity: CaptureIngestIdentity? = nil, parent: CaptureIngestIdentity? = nil, suggested: CaptureIngestIdentity? = nil
    ) -> CaptureIngestReplayResult {
        CaptureIngestReplayResult(publicationSHA256: digest ?? replay.publicationSHA256,
            verifiedManifest: manifest ?? replay.verifiedManifest, bindingSnapshot: binding ?? replay.bindingSnapshot,
            scan: scan ?? replay.scan, rawSourceSessionID: rawNativeID ?? replay.rawSourceSessionID,
            nativeIdentity: identity ?? replay.nativeIdentity, parentIdentity: parent ?? replay.parentIdentity,
            suggestedParentIdentity: suggested ?? replay.suggestedParentIdentity)
    }

    private func binding(
        _ original: CaptureIngestSourceBinding, machineID: String? = nil, instanceID: String? = nil,
        source: SourceName? = nil, format: CaptureIngestParseFormat? = nil, root: String? = nil,
        approvedEpoch: String? = nil, authority: Int64? = nil
    ) -> CaptureIngestSourceBinding {
        CaptureIngestSourceBinding(machineID: machineID ?? original.machineID,
            sourceInstanceID: instanceID ?? original.sourceInstanceID, source: source ?? original.source,
            parseFormat: format ?? original.parseFormat, configuredRoot: root ?? original.configuredRoot,
            approvedEpoch: approvedEpoch ?? original.approvedEpoch, authorityGeneration: authority ?? original.authorityGeneration)
    }

    private func seedSession(id: String, owner: String) throws {
        try writer.write { try $0.execute(sql: """
            INSERT INTO sessions(id, source, start_time, file_path, source_locator, authoritative_node,
                                 sync_version, snapshot_hash, tier, custom_name)
            VALUES (?, 'claude-code', '2026-01-01', '/legacy/do-not-open.jsonl', '/legacy/do-not-open.jsonl', ?, 17, ?, 'normal', 'keep-user-name')
            """, arguments: [id, owner, String(repeating: "a", count: 64)]) }
    }

    @discardableResult
    private func seedHistory(from receipt: CaptureIngestCommittedGeneration, versions: ClosedRange<Int>) throws -> [String] {
        try writer.write { db in
            try versions.map { version in
                let parser = "history-\(version)"
                let id = ArchiveV2Hash.sha256(Data("\(receipt.generationID):\(parser)".utf8))
                // Copy a complete valid row without invoking the commit API per
                // generation. Only the ID, parser revision, and version change.
                try db.execute(sql: """
                    INSERT INTO capture_ingest_generations(
                        generation_id, publication_sha256, parser_revision, machine_id, source_instance_id, source,
                        parse_format, configured_root, collector_epoch, authority_generation, sequence, native_id,
                        raw_source_session_id, stored_session_id, parent_native_id, suggested_parent_native_id,
                        manifest_json, normalized_schema_version, normalized_messages_json, normalized_messages_sha256,
                        normalized_message_count, sync_version, snapshot_hash, required_fts_job_id, created_at)
                    SELECT ?, publication_sha256, ?, machine_id, source_instance_id, source,
                        parse_format, configured_root, collector_epoch, authority_generation, sequence, native_id,
                        raw_source_session_id, stored_session_id, parent_native_id, suggested_parent_native_id,
                        manifest_json, normalized_schema_version, normalized_messages_json, normalized_messages_sha256,
                        normalized_message_count, ?, snapshot_hash, required_fts_job_id, created_at
                    FROM capture_ingest_generations WHERE generation_id = ?
                    """, arguments: [id, parser, version, receipt.generationID])
                XCTAssertEqual(db.changesCount, 1)
                return id
            }
        }
    }

    private func setVersion(_ counter: String, receipt: CaptureIngestCommittedGeneration, value: DatabaseValue.Storage) throws {
        let converted: DatabaseValue
        switch value {
        case .int64(let number): converted = number.databaseValue
        case .double(let number): converted = number.databaseValue
        case .string(let string): converted = string.databaseValue
        case .blob(let bytes): converted = bytes.databaseValue
        case .null: converted = .null
        }
        try writer.write { db in
            switch counter {
            case "session":
                try db.execute(sql: "UPDATE sessions SET sync_version = ? WHERE id = ?", arguments: [converted, receipt.sessionID])
            case "binding":
                try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_sync_version = ? WHERE stored_session_id = ?",
                               arguments: [converted, receipt.sessionID])
            default:
                try db.execute(sql: "UPDATE capture_ingest_generations SET sync_version = ? WHERE generation_id = ?",
                               arguments: [converted, receipt.generationID])
            }
        }
    }

    private func markReadyForFixture(_ fixture: Fixture, receipt: CaptureIngestCommittedGeneration) throws {
        // Seed a previously completed generation; T2 itself must never do this.
        try writer.write { db in
            try db.execute(sql: "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = ? WHERE stored_session_id = ?",
                           arguments: [receipt.generationID, receipt.sessionID])
            try db.execute(sql: "UPDATE capture_ingest_ledger SET status = 'index_ready' WHERE publication_sha256 = ? AND parser_revision = ?",
                           arguments: [fixture.claim.publicationSHA256, fixture.claim.parserRevision])
            if let job = receipt.requiredFTSJobID {
                try db.execute(sql: "UPDATE session_index_jobs SET status = 'completed' WHERE id = ?", arguments: [job])
            }
        }
    }

    private func requireSchema(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let required: [String: Set<String>] = [
            "capture_ingest_identity_bindings": ["machine_id", "source_instance_id", "source", "native_id", "stored_session_id",
                "last_parsed_generation_id", "last_ready_generation_id", "last_sync_version"],
            "capture_ingest_generations": ["generation_id", "publication_sha256", "parser_revision", "machine_id", "source_instance_id",
                "source", "parse_format", "configured_root", "collector_epoch", "authority_generation", "sequence", "native_id",
                "raw_source_session_id", "stored_session_id", "parent_native_id", "suggested_parent_native_id", "manifest_json",
                "normalized_schema_version", "normalized_messages_json", "normalized_messages_sha256", "normalized_message_count",
                "sync_version", "snapshot_hash", "required_fts_job_id", "created_at"],
        ]
        return try writer.read { db in
            var complete = true
            for table in required.keys.sorted() {
                let columns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
                let missing = required[table]!.subtracting(columns)
                XCTAssertTrue(missing.isEmpty, "missing commit schema \(table): \(missing.sorted())", file: file, line: line)
                complete = complete && missing.isEmpty
            }
            return complete
        }
    }

    private func generation(_ receipt: CaptureIngestCommittedGeneration) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM capture_ingest_generations WHERE generation_id = ?",
                                                    arguments: [receipt.generationID])) }
    }

    private func identity(_ fixture: Fixture) throws -> Row {
        let native = fixture.replay.nativeIdentity
        return try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: """
            SELECT * FROM capture_ingest_identity_bindings WHERE machine_id = ? AND source_instance_id = ? AND source = ? AND native_id = ?
            """, arguments: [native.machineID, native.sourceInstanceID, native.source.rawValue, native.nativeID])) }
    }

    private func session(_ id: String) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [id])) }
    }

    private func ledger(_ fixture: Fixture) throws -> Row {
        try writer.read { try XCTUnwrap(Row.fetchOne($0,
            sql: "SELECT * FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
            arguments: [fixture.claim.publicationSHA256, fixture.claim.parserRevision])) }
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try XCTUnwrap(Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")) }
    }

    private func state(_ db: Database, tables: [String]) throws -> [String: [Row]] {
        var result: [String: [Row]] = [:]
        for table in tables where try db.tableExists(table) {
            result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
        }
        return result
    }

    private func state() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: productTables + intakeTables + ["capture_ingest_ledger"]) }
    }

    private func productState() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: productTables) }
    }

    private func intakeState() throws -> [String: [Row]] {
        try writer.read { try state($0, tables: intakeTables) }
    }

    private func assertPayload(_ receipt: CaptureIngestCommittedGeneration, equals expected: [NormalizedMessage],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try generation(receipt)
        let payload: Data = row["normalized_messages_json"]
        let decoded = try ArchiveCanonicalJSON.decode([NormalizedMessage].self, from: payload)
        XCTAssertTrue(decoded == expected, "complete normalized fields must round-trip without truncation", file: file, line: line)
        XCTAssertTrue(payload == (try ArchiveCanonicalJSON.encode(expected)),
                      "stored bytes must equal the whole canonical payload; do not log large transcript values", file: file, line: line)
        XCTAssertEqual(row["normalized_messages_sha256"] as String, ArchiveV2Hash.sha256(payload), file: file, line: line)
    }

    private func assertExactPendingFTS(_ receipt: CaptureIngestCommittedGeneration,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let expectedID = "\(receipt.sessionID):\(receipt.syncVersion):\(receipt.snapshotHash):fts"
        XCTAssertEqual(receipt.requiredFTSJobID, expectedID, file: file, line: line)
        let jobs = try writer.read { try Row.fetchAll($0, sql: "SELECT * FROM session_index_jobs WHERE session_id = ? AND job_kind = 'fts' AND target_sync_version = ?",
                                                     arguments: [receipt.sessionID, receipt.syncVersion]) }
        XCTAssertEqual(jobs.count, 1, file: file, line: line)
        guard let job = jobs.first else { return }
        XCTAssertEqual(job["id"] as String, expectedID, file: file, line: line)
        XCTAssertEqual(job["status"] as String, "pending", file: file, line: line)
        XCTAssertEqual(job["retry_count"] as Int, 0, file: file, line: line)
        XCTAssertEqual(try generation(receipt)["required_fts_job_id"] as String, expectedID, file: file, line: line)
    }

    private func assertParsedOnly(_ fixture: Fixture, receipt: CaptureIngestCommittedGeneration,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try ledger(fixture)
        XCTAssertEqual(row["status"] as String, "parsed", file: file, line: line)
        XCTAssertNil(row["failure_code"] as String?, file: file, line: line)
        XCTAssertNil(row["claim_token"] as String?, file: file, line: line)
        XCTAssertNil(row["claim_started_at"] as Int64?, file: file, line: line)
        XCTAssertNil(row["claim_expires_at"] as Int64?, file: file, line: line)
        XCTAssertNil(row["retry_after"] as Int64?, file: file, line: line)
        XCTAssertEqual(row["attempt_count"] as Int64, fixture.claim.attemptCount, file: file, line: line)
        XCTAssertEqual(try identity(fixture)["last_parsed_generation_id"] as String, receipt.generationID, file: file, line: line)
        XCTAssertNil(try identity(fixture)["last_ready_generation_id"] as String?, file: file, line: line)
        XCTAssertEqual(try count("sessions_fts"), 0, file: file, line: line)
    }

    private func assertCommitError<T>(_ expected: CaptureIngestCommitError, file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestCommitError, expected, file: file, line: line)
        }
    }

    private func assertLedgerError<T>(_ expected: CaptureIngestLedgerError, file: StaticString = #filePath, line: UInt = #line,
                                       _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestLedgerError, expected, file: file, line: line)
        }
    }

    private func assertInjectedRollback(stage: (String, String, String), fixture: Fixture,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let (label, event, table) = stage
        let condition = table == "capture_ingest_ledger" ? "WHEN NEW.status = 'parsed'" : ""
        let before = try state()
        var continued = false
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_capture_commit_stage AFTER \(event) ON \(table) \(condition)
                BEGIN
                    UPDATE capture_ingest_ledger SET failure_code = 'injected_side_effect' WHERE parser_revision = 'failure-witness';
                    SELECT RAISE(FAIL, 'injected-\(label)');
                END
                """)
            XCTAssertThrowsError(try CaptureIngestCommitter.commitParsed(db, claim: fixture.claim, replay: fixture.replay,
                expectedParserRevision: revision, now: 101, indexedAt: timestamp), file: file, line: line) { error in
                XCTAssertTrue(error is DatabaseError, "stage must actually execute: \(label)", file: file, line: line)
                XCTAssertTrue((error as? DatabaseError)?.message?.contains("injected-\(label)") == true,
                              "the intended trigger, not an earlier validation failure, must fire", file: file, line: line)
            }
            XCTAssertEqual(try state(db, tables: productTables + intakeTables + ["capture_ingest_ledger"]), before,
                           "inner savepoint must restore all tables before outer continuation: \(label)", file: file, line: line)
            continued = true
            try db.execute(sql: "DROP TRIGGER fail_capture_commit_stage")
        }
        XCTAssertTrue(continued, file: file, line: line)
        XCTAssertEqual(try state(), before, label, file: file, line: line)
    }
}
