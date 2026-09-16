import Foundation
import EngramCoreRead
@testable import EngramCoreWrite
import GRDB
import XCTest

final class CaptureIngestClaimTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let journal = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let revision = "swift-parser-1"
    private var directory: URL!
    private var writer: EngramDatabaseWriter!
    private var nextOrdinal: Int64 = 1

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
    }

    override func tearDownWithError() throws {
        if let writer {
            try writer.read { db in
                for table in ["sessions", "session_index_jobs", "sessions_fts", "session_costs", "session_tools", "session_work_beats"] {
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0, table)
                }
            }
        }
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testFreshAndRepeatedMigrationAddsClaimColumnsWithoutProductRows() throws {
        try writer.migrate()
        try writer.migrate()
        guard try requireColumns() else { return }
        let fixture = try accept()
        let state = try workState(fixture)
        XCTAssertEqual(state.status, "pending")
        XCTAssertEqual(state.attempt, 0)
        XCTAssertNil(state.token)
        XCTAssertNil(state.claimedAt)
        XCTAssertNil(state.expiresAt)
        XCTAssertNil(state.retryAfter)
    }

    func testLegacyTableUpgradePreservesIntakeAndAllExistingStatuses() throws {
        let fixture = try accept()
        let statuses = ["pending", "processing", "parsed", "index_ready", "failed_retryable", "quarantined"]
        try writer.write { db in
            try db.execute(sql: "DROP TABLE capture_ingest_ledger")
            try db.execute(sql: """
                CREATE TABLE capture_ingest_ledger (
                    publication_sha256 TEXT NOT NULL REFERENCES capture_ingest_publications(publication_sha256),
                    parser_revision TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('pending','processing','parsed','index_ready','failed_retryable','quarantined')),
                    failure_code TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                    PRIMARY KEY (publication_sha256, parser_revision)
                )
                """)
            for status in statuses {
                try db.execute(sql: """
                    INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status, failure_code, created_at, updated_at)
                    VALUES (?, ?, ?, 'legacy_symbolic_code', '2001-01-01', '2002-02-02')
                    """, arguments: [fixture.digest, status, status])
            }
        }
        let before = try intakeState()
        try writer.migrate()
        try writer.migrate()
        guard try requireColumns() else { return }
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM capture_ingest_ledger ORDER BY parser_revision")
            XCTAssertEqual(rows.count, statuses.count)
            for row in rows {
                XCTAssertEqual(row["status"] as String, row["parser_revision"] as String)
                XCTAssertEqual(row["failure_code"] as String, "legacy_symbolic_code")
                XCTAssertEqual(row["created_at"] as String, "2001-01-01")
                XCTAssertEqual(row["updated_at"] as String, "2002-02-02")
                XCTAssertEqual(row["attempt_count"] as Int64, 0)
                XCTAssertNil(row["claim_token"] as String?)
                XCTAssertNil(row["claim_started_at"] as Int64?)
                XCTAssertNil(row["claim_expires_at"] as Int64?)
                XCTAssertNil(row["retry_after"] as Int64?)
            }
        }
        XCTAssertEqual(try intakeState(), before)
    }

    func testPendingClaimReturnsVerifiedPublicationAndInternalCanonicalUUIDOnly() throws {
        let fixture = try accept()
        let before = try intakeState()
        guard let claim = requireClaim(fixture, now: 0, lease: 300) else { return }
        XCTAssertEqual(claim.publication, fixture.record.publication)
        XCTAssertEqual(claim.publicationSHA256, fixture.digest)
        XCTAssertEqual(try claim.publication.sha256(), fixture.digest)
        XCTAssertEqual(claim.parserRevision, revision)
        XCTAssertEqual(UUID(uuidString: claim.token)?.uuidString, claim.token)
        XCTAssertEqual(claim.claimedAt, 0)
        XCTAssertEqual(claim.expiresAt, 300)
        XCTAssertEqual(claim.attemptCount, 1)
        let state = try workState(fixture)
        XCTAssertEqual(state, WorkState(status: "processing", code: nil, token: claim.token,
                                       claimedAt: 0, expiresAt: 300, attempt: 1, retryAfter: nil))
        XCTAssertEqual(try intakeState(), before, "claim is not intake advancement, admission, parsing, or readiness")
    }

    func testTwoSequentialClaimsHaveExactlyOneWinnerWithoutIncrementingLoserAttempt() throws {
        let fixture = try accept()
        guard let first = requireClaim(fixture, now: 100, lease: 10) else { return }
        let before = try ledgerState()
        XCTAssertNil(try claim(fixture, now: 100, lease: 10))
        XCTAssertEqual(try ledgerState(), before)
        XCTAssertEqual(try workState(fixture).token, first.token)
        XCTAssertEqual(try workState(fixture).attempt, 1)
    }

    func testIndependentDatabaseWritersCannotBothClaimOnePendingWorkRow() async throws {
        let fixture = try accept()
        let firstWriter = try XCTUnwrap(writer)
        let secondWriter = try EngramDatabaseWriter(path: databasePath)
        let digest = fixture.digest
        let parser = revision
        let results: [CaptureIngestClaim?]
        do {
            results = try await withThrowingTaskGroup(of: CaptureIngestClaim?.self) { group in
                for currentWriter in [firstWriter, secondWriter] {
                    group.addTask {
                        try currentWriter.write {
                            try CaptureIngestLedger.claim($0, publicationSHA256: digest, parserRevision: parser,
                                                         now: 100, leaseDuration: 10)
                        }
                    }
                }
                var claims: [CaptureIngestClaim?] = []
                for try await claimed in group { claims.append(claimed) }
                return claims
            }
        } catch {
            if let databaseError = error as? DatabaseError {
                XCTFail("two valid claim attempts must finish without throwing: DatabaseError resultCode=\(databaseError.resultCode.rawValue) extendedResultCode=\(databaseError.extendedResultCode.rawValue) message=\(databaseError.message ?? "nil")")
            } else {
                XCTFail("two valid claim attempts must finish without throwing: \(type(of: error))")
            }
            return
        }
        let winners = results.compactMap { $0 }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(try workState(fixture).attempt, 1)
        XCTAssertEqual(try workState(fixture).token, winners.first?.token)
    }

    func testExpiryBoundaryRevokesOldTokenBeforeReclaimAndReclaimAlwaysChangesToken() throws {
        let fixture = try accept()
        guard let old = requireClaim(fixture, now: 100, lease: 10) else { return }
        try requireCurrent(old, now: 109)
        XCTAssertNil(try claim(fixture, now: 109, lease: 10))
        let expiredState = try ledgerState()
        assertError(.claimLost) { try self.requireCurrent(old, now: 110) }
        assertError(.claimLost) { try self.fail(old, .retryable(.casUnavailable), now: 110, retryDelay: 1) }
        XCTAssertEqual(try ledgerState(), expiredState)
        guard let new = requireClaim(fixture, now: 110, lease: 10) else { return }
        XCTAssertNotEqual(new.token, old.token)
        XCTAssertEqual(new.claimedAt, 110)
        XCTAssertEqual(new.expiresAt, 120)
        XCTAssertEqual(new.attemptCount, 2)
        let reclaimedState = try ledgerState()
        assertError(.claimLost) { try self.requireCurrent(old, now: 111) }
        assertError(.claimLost) { try self.fail(old, .quarantined(.invalidManifest), now: 111) }
        XCTAssertEqual(try ledgerState(), reclaimedState)
        try requireCurrent(new, now: 119)
        assertError(.claimLost) { try self.requireCurrent(new, now: 120) }
    }

    func testRestartRetainsLeaseAndRecoversOnlyWhenExpired() throws {
        let fixture = try accept()
        guard let old = requireClaim(fixture, now: 100, lease: 10) else { return }
        let before = try intakeState()
        writer = nil
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        XCTAssertNil(try claim(fixture, now: 109, lease: 10))
        guard let recovered = requireClaim(fixture, now: 110, lease: 10) else { return }
        XCTAssertNotEqual(recovered.token, old.token)
        XCTAssertEqual(recovered.attemptCount, 2)
        XCTAssertEqual(try intakeState(), before)
        assertError(.claimLost) { try self.requireCurrent(old, now: 111) }
    }

    func testTerminalStatesCannotBeReclaimedOrOverwrittenByTheirFormerToken() throws {
        for terminal in ["parsed", "index_ready", "quarantined"] {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try writer.write { try $0.execute(sql: """
                UPDATE capture_ingest_ledger SET status = ?, failure_code = 'terminal_symbolic_code'
                WHERE publication_sha256 = ? AND parser_revision = ?
                """, arguments: [terminal, fixture.digest, revision]) }
            let before = try ledgerState()
            XCTAssertNil(try claim(fixture, now: 101, lease: 10))
            XCTAssertNil(try claim(fixture, now: 1_000, lease: 10))
            assertError(.claimLost) { try self.requireCurrent(claimed, now: 101) }
            assertError(.claimLost) { try self.fail(claimed, .retryable(.casUnavailable), now: 101, retryDelay: 1) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testParserRevisionsOwnIndependentClaimsAndCrossRevisionTokenIsRejected() throws {
        let fixture = try accept()
        try acceptRevision(fixture, parser: "swift-parser-2")
        guard let first = requireClaim(fixture),
              let second = requireClaim(fixture, parser: "swift-parser-2") else { return }
        XCTAssertNotEqual(first.token, second.token)
        let forged = replacing(first, parser: second.parserRevision)
        let before = try ledgerState()
        assertError(.claimLost) { try self.requireCurrent(forged, now: 101) }
        assertError(.claimLost) { try self.fail(forged, .parse(.malformedJSON), now: 101) }
        XCTAssertEqual(try ledgerState(), before)
        try fail(first, .parse(.malformedJSON), now: 101)
        XCTAssertEqual(try workState(fixture).status, "quarantined")
        XCTAssertEqual(try workState(fixture, parser: "swift-parser-2").status, "processing")
        try requireCurrent(second, now: 101)
    }

    func testUnknownPublicationOrRevisionDoesNotCreateWork() throws {
        let fixture = try accept()
        let before = try ledgerState()
        XCTAssertNoThrow(try {
            let result = try writer.write {
                try CaptureIngestLedger.claim($0, publicationSHA256: String(repeating: "f", count: 64),
                                              parserRevision: revision, now: 100, leaseDuration: 10)
            }
            XCTAssertNil(result)
        }())
        XCTAssertNoThrow(try {
            let result = try claim(fixture, parser: "never-enqueued-revision")
            XCTAssertNil(result)
        }())
        XCTAssertEqual(try ledgerState(), before)
    }

    func testRetryPersistsExplicitDeadlineClearsLeaseAndReclaimsAtExactDueTime() throws {
        let fixture = try accept()
        guard let first = requireClaim(fixture) else { return }
        let before = try intakeState()
        try fail(first, .retryable(.casUnavailable), now: 101, retryDelay: 30)
        XCTAssertEqual(try workState(fixture), WorkState(status: "failed_retryable", code: "retry.cas_unavailable",
                                                       token: nil, claimedAt: nil, expiresAt: nil, attempt: 1, retryAfter: 131))
        let released = try ledgerState()
        assertError(.claimLost) { try self.requireCurrent(first, now: 102) }
        assertError(.claimLost) { try self.fail(first, .parse(.malformedJSON), now: 102) }
        XCTAssertEqual(try ledgerState(), released)
        XCTAssertNil(try claim(fixture, now: 130, lease: 10))
        guard let retried = requireClaim(fixture, now: 131, lease: 10) else { return }
        XCTAssertNotEqual(retried.token, first.token)
        XCTAssertEqual(retried.attemptCount, 2)
        XCTAssertNil(try workState(fixture).code)
        XCTAssertNil(try workState(fixture).retryAfter)
        XCTAssertEqual(try intakeState(), before)
    }

    func testEveryParserFailureUsesFixedParseCodeAndNeverMarksParsedOrReady() throws {
        for reason in ParserFailure.allCases {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try fail(claimed, .parse(reason), now: 101)
            let state = try workState(fixture)
            XCTAssertEqual(state.status, "quarantined")
            XCTAssertEqual(state.code, "parse.\(reason.rawValue)")
            XCTAssertNil(state.token)
            XCTAssertNil(state.claimedAt)
            XCTAssertNil(state.expiresAt)
            XCTAssertNil(state.retryAfter)
        }
    }

    func testQuarantineAndRetryReasonsHaveDistinctFixedCodesWithoutArbitraryPayloads() throws {
        for reason in CaptureIngestWorkFailure.QuarantineCode.allCases {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try fail(claimed, .quarantined(reason), now: 101)
            XCTAssertEqual(try workState(fixture).status, "quarantined")
            XCTAssertEqual(try workState(fixture).code, "quarantine.\(reason.rawValue)")
        }
        for reason in CaptureIngestWorkFailure.RetryCode.allCases {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try fail(claimed, .retryable(reason), now: 101, retryDelay: 3_600)
            XCTAssertEqual(try workState(fixture).status, "failed_retryable")
            XCTAssertEqual(try workState(fixture).code, "retry.\(reason.rawValue)")
            XCTAssertEqual(try workState(fixture).retryAfter, 3_701)
        }
        for raw in ["/private/source.jsonl", "transcript body", "error: token=secret", "invalid_manifest\nbody"] {
            XCTAssertNil(CaptureIngestWorkFailure.QuarantineCode(rawValue: raw))
            XCTAssertNil(CaptureIngestWorkFailure.RetryCode(rawValue: raw))
            XCTAssertNil(ParserFailure(rawValue: raw))
        }
    }

    func testClaimRejectsInvalidDigestRevisionTimeAndLeaseWithoutChangingRows() throws {
        let fixture = try accept()
        let before = try ledgerState()
        for digest in ["", "a", String(repeating: "A", count: 64), String(repeating: "g", count: 64), fixture.digest + "\0"] {
            assertError(.invalidPublicationSHA256) {
                _ = try self.writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: digest,
                    parserRevision: self.revision, now: 100, leaseDuration: 10) }
            }
        }
        for parser in ["", " ", " x", "x ", "x\0y", String(repeating: "x", count: 129)] {
            assertError(.invalidParserRevision) { _ = try self.claim(fixture, parser: parser) }
        }
        assertError(.invalidTime) { _ = try self.claim(fixture, now: -1) }
        for lease: Int64 in [-1, 0, 301, Int64.max] {
            assertError(.invalidLeaseDuration) { _ = try self.claim(fixture, lease: lease) }
        }
        assertError(.timeOverflow) { _ = try self.claim(fixture, now: Int64.max, lease: 1) }
        assertError(.timeOverflow) { _ = try self.claim(fixture, now: Int64.max - 299, lease: 300) }
        XCTAssertEqual(try ledgerState(), before)
    }

    func testMaximumValidIntegerLeaseAndRetryBoundariesDoNotOverflow() throws {
        let fixture = try accept()
        guard let claimed = requireClaim(fixture, now: Int64.max - 300, lease: 300) else { return }
        XCTAssertEqual(claimed.expiresAt, Int64.max)
        try requireCurrent(claimed, now: Int64.max - 1)
        try fail(claimed, .retryable(.stagingUnavailable), now: Int64.max - 1, retryDelay: 1)
        XCTAssertEqual(try workState(fixture).retryAfter, Int64.max)
        assertError(.timeOverflow) { _ = try self.claim(fixture, now: Int64.max, lease: 1) }
    }

    func testFailureRejectsInvalidRetryDelayTimeAndOverflowWithoutConsumingClaim() throws {
        let fixture = try accept()
        guard let claimed = requireClaim(fixture) else { return }
        let before = try ledgerState()
        for delay: Int64? in [nil, -1, 0, 3_601, Int64.max] {
            assertError(.invalidRetryDelay) { try self.fail(claimed, .retryable(.casUnavailable), now: 101, retryDelay: delay) }
        }
        for failure: CaptureIngestWorkFailure in [.parse(.malformedJSON), .quarantined(.invalidManifest)] {
            assertError(.invalidRetryDelay) { try self.fail(claimed, failure, now: 101, retryDelay: 1) }
        }
        assertError(.invalidTime) { try self.fail(claimed, .parse(.malformedJSON), now: -1) }
        assertError(.invalidTime) { try self.requireCurrent(claimed, now: -1) }
        assertError(.invalidTime) { try self.requireCurrent(claimed, now: 99) }
        assertError(.invalidTime) { try self.fail(claimed, .parse(.malformedJSON), now: 99) }
        XCTAssertEqual(try ledgerState(), before)

        let extreme = try accept()
        guard let nearLimit = requireClaim(extreme, now: Int64.max - 2, lease: 2) else { return }
        let beforeOverflow = try ledgerState()
        assertError(.timeOverflow) { try self.fail(nearLimit, .retryable(.casUnavailable), now: Int64.max - 1, retryDelay: 2) }
        XCTAssertEqual(try ledgerState(), beforeOverflow)
    }

    func testAttemptCounterRejectsOverflowAndMalformedStoredValues() throws {
        guard try requireColumns() else { return }
        for (value, expected): (String, CaptureIngestLedgerError) in [
            (String(Int64.max), .attemptOverflow), ("-1", .invalidStoredRecord),
            ("'not-an-integer'", .invalidStoredRecord), ("1.5", .invalidStoredRecord)
        ] {
            let fixture = try accept()
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET attempt_count = \(value) WHERE publication_sha256 = ?",
                                              arguments: [fixture.digest]) }
            let before = try ledgerState()
            assertError(expected) { _ = try self.claim(fixture) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testLastValidAttemptAndMinimumLeaseCannotWrapOnExpiredOrRetryableReclaim() throws {
        guard try requireColumns() else { return }
        for retry in [false, true] {
            let fixture = try accept()
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET attempt_count = ? WHERE publication_sha256 = ?",
                                              arguments: [Int64.max - 1, fixture.digest]) }
            guard let claimed = requireClaim(fixture, now: 100, lease: 1) else { return }
            XCTAssertEqual(claimed.attemptCount, Int64.max)
            XCTAssertEqual(claimed.expiresAt, 101)
            if retry {
                try fail(claimed, .retryable(.casUnavailable), now: 100, retryDelay: 1)
            }
            let before = try ledgerState()
            assertError(.attemptOverflow) { _ = try self.claim(fixture, now: 101, lease: 1) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testMalformedPersistedLeaseCannotAcquireOrRetainAuthority() throws {
        guard try requireColumns() else { return }
        let mutations = [
            "claim_token = NULL", "claim_token = 'not-a-uuid'", "claim_started_at = NULL",
            "claim_started_at = -1", "claim_started_at = 110", "claim_expires_at = NULL",
            "claim_expires_at = 99", "claim_expires_at = 401", "claim_expires_at = 'not-an-integer'",
            "attempt_count = 0", "retry_after = 200"
        ]
        for mutation in mutations {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_ledger SET \(mutation) WHERE publication_sha256 = ?",
                                              arguments: [fixture.digest]) }
            let before = try ledgerState()
            assertError(.invalidStoredRecord) { _ = try self.claim(fixture, now: 1_000) }
            assertError(.invalidStoredRecord) { try self.requireCurrent(claimed, now: 101) }
            assertError(.invalidStoredRecord) { try self.fail(claimed, .parse(.malformedJSON), now: 101) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testRetryableWithoutValidExplicitDeadlineCannotBeReclaimed() throws {
        guard try requireColumns() else { return }
        for deadline in ["NULL", "-1", "'not-an-integer'", "1.5"] {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try fail(claimed, .retryable(.casUnavailable), now: 101, retryDelay: 1)
            try writer.write { try $0.execute(sql: """
                UPDATE capture_ingest_ledger SET retry_after = \(deadline)
                WHERE publication_sha256 = ?
                """, arguments: [fixture.digest]) }
            let before = try ledgerState()
            assertError(.invalidStoredRecord) { _ = try self.claim(fixture) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testClaimRejectsPublicationDigestMismatchAndDenormalizedTupleCorruption() throws {
        let mutations: [(String, String)] = [
            ("machine_id", journal), ("source_instance_id", journal),
            ("collector_epoch", journal), ("sequence", "2")
        ]
        for (column, value) in mutations {
            let fixture = try accept(sequence: 1)
            try writer.write { try $0.execute(sql: "UPDATE capture_ingest_publications SET \(column) = ? WHERE publication_sha256 = ?",
                                              arguments: [value, fixture.digest]) }
            let before = try ledgerState()
            assertError(.invalidStoredRecord) { _ = try self.claim(fixture) }
            XCTAssertEqual(try ledgerState(), before)
            try removeIntakeFixture(fixture)
        }
        let fixture = try accept()
        try writer.write { try $0.execute(sql: "UPDATE capture_ingest_publications SET canonical_bytes = ? WHERE publication_sha256 = ?",
                                          arguments: [Data("{}".utf8), fixture.digest]) }
        assertError(.invalidStoredRecord) { _ = try self.claim(fixture) }
    }

    func testCanonicalDecoderValidationCannotBeBypassedWithMatchingCorruptDigest() throws {
        let valid = try publication(sequence: 1)
        let canonical = try ArchiveCanonicalJSON.encode(valid)
        let text = try XCTUnwrap(String(data: canonical, encoding: .utf8))
        let variants = [
            Data((" " + text).utf8),
            Data((String(text.dropLast()) + ",\"unknown\":1}").utf8),
            Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8),
            Data(text.replacingOccurrences(of: "exact-source-v1", with: "unsupported-source-v1").utf8),
            Data(text.replacingOccurrences(of: machine, with: machine.lowercased()).utf8),
            Data("not-json".utf8),
            Data(repeating: 32, count: CollectorPublicationProtocolLimits.maxPublicationBytes + 1)
        ]
        for bytes in variants {
            let digest = try seedRawPublication(bytes, metadata: valid)
            let before = try ledgerState()
            assertError(.invalidStoredRecord) {
                _ = try self.writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: digest,
                    parserRevision: self.revision, now: 100, leaseDuration: 10) }
            }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testCurrentClaimAndFailureRevalidatePublicationAfterAcquisition() throws {
        for corruption in ["bytes", "machine_id", "source_instance_id", "collector_epoch", "sequence"] {
            let fixture = try accept()
            guard let claimed = requireClaim(fixture) else { return }
            try writer.write { db in
                if corruption == "bytes" {
                    try db.execute(sql: "UPDATE capture_ingest_publications SET canonical_bytes = ? WHERE publication_sha256 = ?",
                                   arguments: [Data("{}".utf8), fixture.digest])
                } else {
                    try db.execute(sql: "UPDATE capture_ingest_publications SET \(corruption) = ? WHERE publication_sha256 = ?",
                                   arguments: [corruption == "sequence" ? "99999" : journal, fixture.digest])
                }
            }
            let before = try ledgerState()
            assertError(.invalidStoredRecord) { try self.requireCurrent(claimed, now: 101) }
            assertError(.invalidStoredRecord) { try self.fail(claimed, .retryable(.casUnavailable), now: 101, retryDelay: 1) }
            XCTAssertEqual(try ledgerState(), before)
        }
    }

    func testClaimPayloadAndLeaseFieldsCannotBeSubstitutedWhileKeepingToken() throws {
        let fixture = try accept()
        guard let claimed = requireClaim(fixture) else { return }
        let other = try publication(sequence: 999)
        let forgedClaims = [
            replacing(claimed, publication: other), replacing(claimed, digest: try other.sha256()),
            replacing(claimed, token: UUID().uuidString), replacing(claimed, claimedAt: 99),
            replacing(claimed, expiresAt: 111), replacing(claimed, attempt: 2)
        ]
        let before = try ledgerState()
        for forged in forgedClaims {
            assertError(.claimLost) { try self.requireCurrent(forged, now: 101) }
            assertError(.claimLost) { try self.fail(forged, .parse(.malformedJSON), now: 101) }
        }
        XCTAssertEqual(try ledgerState(), before)
    }

    func testLaterIntakeTupleConflictRevokesProcessingWithoutOverwritingItsReason() throws {
        let fixture = try accept(sequence: 1)
        guard let claimed = requireClaim(fixture) else { return }
        let competing = try accept(sequence: 1, digestCharacter: "b")
        XCTAssertEqual(try workState(fixture).status, "quarantined")
        XCTAssertEqual(try workState(fixture).code, "sequence_conflict")
        XCTAssertEqual(try workState(competing).status, "quarantined")
        let before = try ledgerState()
        XCTAssertNil(try claim(fixture))
        assertError(.claimLost) { try self.requireCurrent(claimed, now: 101) }
        assertError(.claimLost) { try self.fail(claimed, .retryable(.casUnavailable), now: 101, retryDelay: 1) }
        XCTAssertEqual(try ledgerState(), before)
    }

    func testTupleConflictIsRecheckedEvenWhenLedgerStillSaysPendingOrProcessing() throws {
        let pending = try accept()
        let processing = try accept()
        guard let claimed = requireClaim(processing) else { return }
        for fixture in [pending, processing] {
            let original = fixture.record.publication
            let competing = try CollectorPublicationEnvelope(machineID: original.machineID,
                sourceInstanceID: original.sourceInstanceID, collectorEpoch: original.collectorEpoch,
                sequence: original.sequence, manifestSHA256: String(repeating: "b", count: 64))
            _ = try seedRawPublication(ArchiveCanonicalJSON.encode(competing), metadata: competing, addWork: false)
        }
        let before = try ledgerState()
        assertError(.sequenceConflict) { _ = try self.claim(pending) }
        assertError(.sequenceConflict) { try self.requireCurrent(claimed, now: 101) }
        assertError(.sequenceConflict) { try self.fail(claimed, .quarantined(.sequenceConflict), now: 101) }
        XCTAssertEqual(try ledgerState(), before)
    }

    func testExactIntakeReplayCannotResetClaimTokenLeaseOrAttempt() throws {
        let fixture = try accept()
        guard let claimed = requireClaim(fixture) else { return }
        let before = try ledgerState()
        try acceptRevision(fixture, parser: revision)
        XCTAssertEqual(try ledgerState(), before)
        try requireCurrent(claimed, now: 101)
    }

    func testRequireCurrentClaimIsReadOnlyAndFailureDoesNotAlterAnyIntakeState() throws {
        let fixture = try accept()
        guard let claimed = requireClaim(fixture) else { return }
        let workBefore = try ledgerState()
        let intakeBefore = try intakeState()
        try requireCurrent(claimed, now: 101)
        try requireCurrent(claimed, now: 101)
        XCTAssertEqual(try ledgerState(), workBefore)
        try fail(claimed, .quarantined(.invalidNativeIdentity), now: 101)
        XCTAssertEqual(try intakeState(), intakeBefore)
    }

    func testClaimTriggerFailureRollsBackEvenWhenOuterWriterCatchesAndCommits() throws {
        guard try requireColumns() else { return }
        let fixture = try accept()
        try acceptRevision(fixture, parser: "trigger-witness")
        let before = try ledgerState()
        var outerContinued = false
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_claim_failure AFTER UPDATE ON capture_ingest_ledger
                WHEN NEW.status = 'processing' AND NEW.parser_revision = 'swift-parser-1'
                BEGIN
                    UPDATE capture_ingest_ledger SET failure_code = 'trigger_side_effect' WHERE parser_revision = 'trigger-witness';
                    SELECT RAISE(FAIL, 'injected claim failure');
                END
                """)
            XCTAssertThrowsError(try CaptureIngestLedger.claim(db, publicationSHA256: fixture.digest,
                parserRevision: revision, now: 100, leaseDuration: 10)) { XCTAssertTrue($0 is DatabaseError) }
            XCTAssertEqual(try ledgerState(db), before)
            outerContinued = true
            try db.execute(sql: "DROP TRIGGER injected_claim_failure")
        }
        XCTAssertTrue(outerContinued)
        XCTAssertEqual(try ledgerState(), before)
    }

    func testFailureTriggerRollsBackEvenWhenOuterWriterCatchesAndCommits() throws {
        let fixture = try accept()
        try acceptRevision(fixture, parser: "trigger-witness")
        guard let claimed = requireClaim(fixture) else { return }
        let before = try ledgerState()
        var outerContinued = false
        try writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER injected_failure_update AFTER UPDATE ON capture_ingest_ledger
                WHEN NEW.status = 'failed_retryable' AND NEW.parser_revision = 'swift-parser-1'
                BEGIN
                    UPDATE capture_ingest_ledger SET failure_code = 'trigger_side_effect' WHERE parser_revision = 'trigger-witness';
                    SELECT RAISE(FAIL, 'injected failure update');
                END
                """)
            XCTAssertThrowsError(try CaptureIngestLedger.recordFailure(db, claim: claimed,
                failure: .retryable(.casUnavailable), now: 101, retryDelay: 1)) { XCTAssertTrue($0 is DatabaseError) }
            XCTAssertEqual(try ledgerState(db), before)
            outerContinued = true
            try db.execute(sql: "DROP TRIGGER injected_failure_update")
        }
        XCTAssertTrue(outerContinued)
        XCTAssertEqual(try ledgerState(), before)
    }

    private var databasePath: String { directory.appendingPathComponent("index.sqlite").path }

    private struct Fixture {
        let record: CollectorPublicationAcceptanceRecord
        let page: CollectorPublicationPage
        let requestedCursor: String?
        var digest: String { record.ack.publicationSHA256 }
    }

    private struct WorkState: Equatable {
        let status: String
        let code: String?
        let token: String?
        let claimedAt: Int64?
        let expiresAt: Int64?
        let attempt: Int64
        let retryAfter: Int64?
    }

    private func publication(sequence: Int64, digestCharacter: Character = "a") throws -> CollectorPublicationEnvelope {
        try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance, collectorEpoch: epoch,
            sequence: sequence, manifestSHA256: String(repeating: digestCharacter, count: 64))
    }

    private func accept(sequence: Int64? = nil, digestCharacter: Character = "a") throws -> Fixture {
        let publication = try publication(sequence: sequence ?? nextOrdinal, digestCharacter: digestCharacter)
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: nextOrdinal,
            publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
            storedAt: "2026-09-06T00:00:00.000Z")
        nextOrdinal += 1
        let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
        let page = try CollectorPublicationPage(items: [record], afterCursor: CollectorPublicationCursor(
            journalID: journal, afterArrivalOrdinal: ack.arrivalOrdinal).encoded(), hasMore: false)
        let requestedCursor = try writer.write { db in
            let cursor = try CaptureIngestLedger.checkpoint(db, serverID: "hq")
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: cursor, serverID: "hq", parserRevision: revision)
            return cursor
        }
        return Fixture(record: record, page: page, requestedCursor: requestedCursor)
    }

    private func acceptRevision(_ fixture: Fixture, parser: String) throws {
        try writer.write { try CaptureIngestLedger.accept($0, page: fixture.page,
            requestedCursor: fixture.requestedCursor, serverID: "hq", parserRevision: parser) }
    }

    private func claim(_ fixture: Fixture, parser: String? = nil, now: Int64 = 100, lease: Int64 = 10) throws -> CaptureIngestClaim? {
        try writer.write { try CaptureIngestLedger.claim($0, publicationSHA256: fixture.digest,
            parserRevision: parser ?? revision, now: now, leaseDuration: lease) }
    }

    private func requireClaim(_ fixture: Fixture, parser: String? = nil, now: Int64 = 100, lease: Int64 = 10,
                              file: StaticString = #filePath, line: UInt = #line) -> CaptureIngestClaim? {
        do {
            guard let result = try claim(fixture, parser: parser, now: now, lease: lease) else {
                XCTFail("eligible work must return a durable claim", file: file, line: line)
                return nil
            }
            return result
        } catch {
            XCTFail("eligible claim unexpectedly failed: \(type(of: error))", file: file, line: line)
            return nil
        }
    }

    private func requireCurrent(_ claimed: CaptureIngestClaim, now: Int64) throws {
        try writer.read { try CaptureIngestLedger.requireCurrentClaim($0, claim: claimed, now: now) }
    }

    private func fail(_ claimed: CaptureIngestClaim, _ failure: CaptureIngestWorkFailure,
                      now: Int64, retryDelay: Int64? = nil) throws {
        try writer.write { try CaptureIngestLedger.recordFailure($0, claim: claimed,
            failure: failure, now: now, retryDelay: retryDelay) }
    }

    private func replacing(_ claim: CaptureIngestClaim, parser: String? = nil,
                           publication: CollectorPublicationEnvelope? = nil, digest: String? = nil,
                           token: String? = nil, claimedAt: Int64? = nil, expiresAt: Int64? = nil,
                           attempt: Int64? = nil) -> CaptureIngestClaim {
        CaptureIngestClaim(publicationSHA256: digest ?? claim.publicationSHA256,
            parserRevision: parser ?? claim.parserRevision, publication: publication ?? claim.publication,
            token: token ?? claim.token, claimedAt: claimedAt ?? claim.claimedAt,
            expiresAt: expiresAt ?? claim.expiresAt, attemptCount: attempt ?? claim.attemptCount)
    }

    private func assertError(_ expected: CaptureIngestLedgerError, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? CaptureIngestLedgerError, expected, file: file, line: line)
        }
    }

    private func requireColumns(file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let required: Set<String> = ["claim_token", "claim_started_at", "claim_expires_at", "attempt_count", "retry_after"]
        let columns = try writer.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_ledger)").map { $0["name"] as String })
        }
        XCTAssertTrue(required.isSubset(of: columns), "missing durable claim columns: \(required.subtracting(columns))", file: file, line: line)
        return required.isSubset(of: columns)
    }

    private func workState(_ fixture: Fixture, parser: String? = nil) throws -> WorkState {
        try writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM capture_ingest_ledger WHERE publication_sha256 = ? AND parser_revision = ?",
                                               arguments: [fixture.digest, parser ?? revision]))
            return WorkState(status: row["status"], code: row["failure_code"], token: row["claim_token"],
                             claimedAt: row["claim_started_at"], expiresAt: row["claim_expires_at"],
                             attempt: row["attempt_count"], retryAfter: row["retry_after"])
        }
    }

    private func ledgerState() throws -> [String] { try writer.read { try ledgerState($0) } }

    private func ledgerState(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: "SELECT * FROM capture_ingest_ledger ORDER BY publication_sha256, parser_revision")
            .map { String(describing: $0) }
    }

    private func intakeState() throws -> [String] {
        try writer.read { db in
            var values = try String.fetchAll(db, sql: """
                SELECT publication_sha256 || ':' || hex(canonical_bytes) || ':' || machine_id || ':' || source_instance_id || ':' || collector_epoch || ':' || sequence
                FROM capture_ingest_publications ORDER BY publication_sha256
                """)
            values += try String.fetchAll(db, sql: """
                SELECT server_id || ':' || journal_id || ':' || arrival_ordinal || ':' || publication_sha256
                FROM capture_ingest_arrivals ORDER BY server_id, journal_id, arrival_ordinal
                """)
            values += try String.fetchAll(db, sql: "SELECT server_id || ':' || cursor FROM capture_ingest_checkpoints ORDER BY server_id")
            return values
        }
    }

    private func seedRawPublication(_ bytes: Data, metadata: CollectorPublicationEnvelope, addWork: Bool = true) throws -> String {
        let digest = ArchiveV2Hash.sha256(bytes)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO capture_ingest_publications(publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [digest, bytes, metadata.machineID, metadata.sourceInstanceID, metadata.collectorEpoch, metadata.sequence])
            if addWork {
                try db.execute(sql: "INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status) VALUES (?, ?, 'pending')",
                               arguments: [digest, revision])
            }
        }
        return digest
    }

    private func removeIntakeFixture(_ fixture: Fixture) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM capture_ingest_arrivals WHERE publication_sha256 = ?", arguments: [fixture.digest])
            try db.execute(sql: "DELETE FROM capture_ingest_ledger WHERE publication_sha256 = ?", arguments: [fixture.digest])
            try db.execute(sql: "DELETE FROM capture_ingest_publications WHERE publication_sha256 = ?", arguments: [fixture.digest])
        }
    }
}
