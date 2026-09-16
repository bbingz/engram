import Foundation
import GRDB
import SQLite3
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

// A5c TEST-DRAFT correction. Calls the producer API against real migrated
// schema. No second query/decoder. GREEN still throws notImplemented.
final class WebMetadataProducerTests: XCTestCase {
    private let requestId = "AAAAAAAA-0000-4000-8000-000000000099"
    private let parser = "parser-v1"
    private let machine = "AAAAAAAA-0000-4000-8000-000000000001"
    private let instance = "BBBBBBBB-0000-4000-8000-000000000002"
    private let secondMachine = "FFFFFFFF-0000-4000-8000-000000000001"
    private let secondInstance = "EEEEEEEE-0000-4000-8000-000000000002"
    private let epoch = "CCCCCCCC-0000-4000-8000-000000000003"

    // MARK: - Provider / policy / pool

    func testUnavailableProducerNeverReturnsEmptySuccess() async {
        let producer = UnavailableServiceWebMetadataProducer()
        await assertUnavailable(producer, deadline: ContinuousClock.now.advanced(by: .seconds(2)))
        XCTAssertNoThrow(try producer.stop())
    }

    func testMissingInvalidEmptyAndThrowingPolicyAreUnavailableOnFirstPage() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        let box = PolicyBox(ServiceWebMetadataPolicy(parserRevision: parser, enabledSources: [.claudeCode]))
        let producer = try ServiceWebMetadataProducer(
            databasePath: fixture.path, policy: { try box.current() }, clock: fixture.clock.clock
        )
        defer { try? producer.stop() }
        box.policy = nil
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.policy = .init(parserRevision: "", enabledSources: [.claudeCode])
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.policy = .init(parserRevision: " parser-v1", enabledSources: [.claudeCode])
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.policy = .init(parserRevision: "parser\u{0}v1", enabledSources: [.claudeCode])
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.policy = .init(parserRevision: String(repeating: "p", count: 129), enabledSources: [.claudeCode])
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.policy = .init(parserRevision: parser, enabledSources: [])
        await assertUnavailable(producer, deadline: fixture.deadline())
        box.failure = ServiceWebMetadataError.unavailable
        await assertUnavailable(producer, deadline: fixture.deadline())
    }

    func testInitDoesNotChmodAndConnectionBusyTimeoutIsZero() throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        for suffix in ["", "-wal", "-shm"] {
            let candidate = fixture.path + suffix
            if FileManager.default.fileExists(atPath: candidate) {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate)
            }
        }
        let observer = MetadataSQLObserver()
        let producer = try ServiceWebMetadataProducer(
            databasePath: fixture.path,
            policy: { self.validPolicy() },
            clock: fixture.clock.clock,
            hooks: .init(prepareDatabase: { try observer.install($0) })
        )
        defer { try? producer.stop() }
        for suffix in ["", "-wal", "-shm"] {
            let candidate = fixture.path + suffix
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            let mode = try FileManager.default.attributesOfItem(atPath: candidate)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o644, candidate)
        }
        try observer.assertConnections()
        XCTAssertEqual(ServiceWebMetadataLimits.maximumSnapshots, 8)
        XCTAssertEqual(ServiceWebMetadataLimits.maximumCursorPositions, 128)
        XCTAssertEqual(ServiceWebMetadataLimits.leaseLifetime, .seconds(30))
    }

    func testObserverCoversActualOverviewListDetailAndLeasedContinuationOnEveryConnection() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-03 12:00:00", indexReady: true)
        try fixture.seedBoundSession(id: "two", start: "2026-09-02 12:00:00", nativeID: "native-two", indexReady: true)
        let observer = MetadataSQLObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try observer.install($0) }))
        defer { try? producer.stop() }
        let before = observer.productionStatements
        let overview = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(overview.streams.count, 1)
        XCTAssertEqual(overview.streams.first?.fts?.readyLogicalSessions, 2)
        let first = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.sessionId), ["one"])
        let cursor = try XCTUnwrap(first.nextCursor)
        let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: "one"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(detail.detail?.session.sessionId, "one")
        let second = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1,
            snapshotId: first.snapshotId, cursor: cursor), requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.sessionId), ["two"])
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertGreaterThan(observer.productionStatements, before)
        try observer.assertConnections(requireSnapshot: true)
        XCTAssertEqual(observer.productionDenials, 0, "Real metadata SQL must not attempt any forbidden operation")
    }

    // MARK: - Empty / missing / counts

    func testHealthyEmptyCorpusIsMeasuredEmptyNotUnavailable() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
                                               deadline: fixture.deadline())
        XCTAssertTrue(page.streams.isEmpty)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.capabilities.transcriptRead, .unavailable)
        XCTAssertNotEqual(page.capabilities.keywordSearch, .unknown)
        XCTAssertEqual(UUID(uuidString: page.snapshotId)?.uuidString, page.snapshotId)
        try assertRoundTrip(page)
        try assertEnvelopeUnderBudget(page)
    }

    func testMissingCaptureTablesMeasureEmptyWhenProducerExists() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.dropCaptureTables()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
                                               deadline: fixture.deadline())
        XCTAssertTrue(page.streams.isEmpty)
        XCTAssertEqual(page.capabilities.transcriptRead, .unavailable)
    }

    func testHealthyFTSEmptyIsZeroReadyAndMissingFTSIsNil() async throws {
        let measured = try MetadataSQLFixture()
        defer { measured.remove() }
        try measured.migrate()
        try measured.seedRegistry()
        let measuredProducer = try measured.producer()
        defer { try? measuredProducer.stop() }
        let measuredPage = try await measuredProducer.overview(try EngramServiceWebOverviewRequest(),
                                                               requestId: requestId, deadline: measured.deadline())
        XCTAssertEqual(measuredPage.streams.count, 1)
        XCTAssertEqual(measuredPage.streams.first?.fts?.readyLogicalSessions, 0)
        XCTAssertNil(measuredPage.streams.first?.lastCapture)
        XCTAssertNil(measuredPage.streams.first?.heartbeatAt)
        XCTAssertNil(measuredPage.streams.first?.replicaACKs)
        XCTAssertNil(measuredPage.streams.first?.ai)

        let missing = try MetadataSQLFixture()
        defer { missing.remove() }
        try missing.migrate()
        try missing.seedRegistry()
        try missing.dropFTS()
        let missingProducer = try missing.producer()
        defer { try? missingProducer.stop() }
        let missingPage = try await missingProducer.overview(try EngramServiceWebOverviewRequest(),
                                                             requestId: requestId, deadline: missing.deadline())
        XCTAssertEqual(missingPage.streams.count, 1)
        XCTAssertNil(missingPage.streams.first?.fts)
    }

    func testOverviewKeepsItsDeadlineWithUnrelatedFTSDocuments() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        // Other streams and old history share this virtual table. They must not
        // be rescanned once for every ready session in the selected stream.
        try fixture.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < 16384)
                INSERT INTO sessions_fts(session_id, content) SELECT 'unrelated-' || x, 'history' FROM n
                """)
        }
        for ordinal in 0..<1024 {
            try fixture.seedBoundSession(id: "ready-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "native-\(ordinal)", indexReady: true)
        }
        let producer = try fixture.producer(liveClock: true)
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 1024)
    }

    func testOverviewDoesNotReadLargeNormalizedBodiesForReadyCounts() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        for ordinal in 0..<64 {
            try fixture.seedBoundSession(id: "large-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "large-native-\(ordinal)", indexReady: true)
        }
        try fixture.write { db in
            // Opaque payloads deliberately exercise overflow-page I/O only.
            // Metadata admission does not decode/authenticate transcript bodies.
            try db.execute(sql: "UPDATE capture_ingest_generations SET normalized_messages_json = zeroblob(524288)")
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }), liveClock: true)
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 64)
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(reads.pageReads, 1024, "A metadata overview must not traverse the 32 MiB transcript bodies")
    }

    func testOverviewDoesNotScanUnrelatedLargeFTSBodies() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        for ordinal in 0..<16 {
            try fixture.seedBoundSession(id: "mapped-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "mapped-native-\(ordinal)", indexReady: true)
        }
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                SELECT session_id, 0, rowid FROM sessions_fts
                """)
            // Reading UNINDEXED session_id from an FTS row also traverses its
            // body overflow pages. These unrelated bodies total 32 MiB.
            let body = String(repeating: "history ", count: 65536)
            for ordinal in 0..<64 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                    arguments: ["unrelated-\(ordinal)", body])
            }
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }), liveClock: true)
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 16)
        XCTAssertGreaterThan(reads.pageReads, 0)
        XCTAssertLessThan(reads.pageReads, 1024, "Ready counts must not scan unrelated FTS bodies")
    }

    func testOverviewDoesNotReadMappedReadyFTSBodiesForReadyCounts() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        for ordinal in 0..<16 {
            try fixture.seedBoundSession(id: "owned-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "owned-native-\(ordinal)", indexReady: true)
        }
        try fixture.write { db in
            // This fixture has only the owned ready sessions. LIKE on UNINDEXED
            // FTS5 session_id matched zero rows (prior mapped RED was empty fts_map).
            try db.execute(sql: "DELETE FROM sessions_fts")
            try db.execute(sql: "DELETE FROM fts_map")
            let body = String(repeating: "history ", count: 262144)
            for ordinal in 0..<16 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: ["owned-\(ordinal)", body])
            }
            try db.execute(sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                SELECT session_id, 0, rowid FROM sessions_fts
                """)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map"), 16)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM fts_map m
                JOIN sessions_fts_content f ON f.id = m.fts_rowid
                WHERE f.c0 = m.session_id
                """), 16)
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }), liveClock: true)
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        let ready = page.streams.first?.fts?.readyLogicalSessions
        XCTAssertEqual(ready, 16)
        XCTAssertGreaterThan(reads.pageReads, 0)
        XCTAssertLessThan(reads.pageReads, 1024, "Ready counts must not read mapped ready FTS bodies pageReads=\(reads.pageReads)")
    }

    func testOverviewLookaheadDoesNotReadyCountTheNextStream() async throws {
        // Cursor replay and fitting-count shrink stay on
        // testOldestSnapshotEvictionCursorCapAndReplay and
        // testValidDTORoundTripsAndFullEnvelopeShrinksWithoutLossOnOneSnapshot.
        let invalidMachine = "CCCCCCCC-0000-4000-8000-000000000001"
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedRegistry(machine: invalidMachine)
        try fixture.seedRegistry(machine: secondMachine)
        try fixture.seedBoundSession(id: "tiny-0", start: "2026-09-01T00:00:00Z",
            nativeID: "tiny-native", indexReady: true)
        for ordinal in 0..<16 {
            try fixture.seedBoundSession(id: "large-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "large-native-\(ordinal)", machine: secondMachine, indexReady: true)
        }
        try fixture.write { db in
            try db.execute(sql: """
                DELETE FROM capture_ingest_epoch_history
                WHERE machine_id = ?
                """, arguments: [invalidMachine])
            try db.execute(sql: "DELETE FROM sessions_fts")
            try db.execute(sql: "DELETE FROM fts_map")
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                           arguments: ["tiny-0", "tiny"])
            let body = String(repeating: "history ", count: 262144)
            for ordinal in 0..<16 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: ["large-\(ordinal)", body])
            }
            try db.execute(sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                SELECT f.c0, 0, f.id FROM sessions_fts_content f
                WHERE f.c0 = ?
                """, arguments: ["tiny-0"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_map"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM fts_map m
                JOIN sessions_fts_content f ON f.id = m.fts_rowid
                WHERE f.c0 = m.session_id AND m.session_id = ?
                """, arguments: ["tiny-0"]), 1)
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }), liveClock: true)
        defer { try? producer.stop() }
        let first = try await producer.overview(try EngramServiceWebOverviewRequest(limit: 1), requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(first.streams.map(\.machineId), [machine])
        XCTAssertEqual(first.streams.first?.fts?.readyLogicalSessions, 1)
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertGreaterThan(reads.pageReads, 0)
        XCTAssertLessThan(reads.pageReads, 1024,
            "Out-of-page stream ready counts must not run on hasMore pageReads=\(reads.pageReads)")
        let second = try await producer.overview(
            try EngramServiceWebOverviewRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.streams.map(\.machineId), [secondMachine])
        XCTAssertEqual(second.streams.first?.fts?.readyLogicalSessions, 16)
        XCTAssertNil(second.nextCursor)
        let replay = try await producer.overview(
            try EngramServiceWebOverviewRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(replay.streams.map(\.machineId), second.streams.map(\.machineId))
        XCTAssertEqual(replay.streams.first?.fts?.readyLogicalSessions, 16)
        XCTAssertEqual(replay.nextCursor, second.nextCursor)
    }

    func testOverviewDoesNotReadNonReadySessionOverflowForReadyCounts() async throws {
        // Join-order page-read RED, not FTS membership. Source-driven sessions
        // scans touch non-ready heap overflow (summary/instruction_summary sit
        // before authority columns). last_ready NULL or mismatched must not count.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        for ordinal in 0..<8 {
            try fixture.seedBoundSession(id: "ready-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "ready-native-\(ordinal)", indexReady: true)
        }
        for ordinal in 0..<128 {
            try fixture.seedBoundSession(id: "pending-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "pending-native-\(ordinal)", indexReady: false)
        }
        for ordinal in 0..<8 {
            try fixture.seedBoundSession(id: "mismatch-\(ordinal)", start: "2026-09-01T00:00:00Z",
                nativeID: "mismatch-native-\(ordinal)", indexReady: true, divergeHeads: true)
        }
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                SELECT session_id, 0, rowid FROM sessions_fts
                """)
            let blob = String(repeating: "summary ", count: 8192)
            try db.execute(sql: """
                UPDATE sessions SET summary = ?, instruction_summary = ?
                WHERE id LIKE 'pending-%' OR id LIKE 'mismatch-%'
                """, arguments: [blob, blob])
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }), liveClock: true)
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
            deadline: ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration))
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 8)
        XCTAssertGreaterThan(reads.pageReads, 0)
        XCTAssertLessThan(reads.pageReads, 1024, "Ready counts must not read non-ready session overflow")
    }

    func testOverviewFTSMapIsOnlyAnAccelerator() async throws {
        for missingTable in [false, true] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            for id in ["mapped", "unmapped", "stale-map", "wrong-map", "missing-fts"] {
                try fixture.seedBoundSession(id: id, start: "2026-09-01T00:00:00Z",
                    nativeID: "native-\(id)", indexReady: true, fts: id != "missing-fts")
            }
            try fixture.write { db in
                try db.execute(sql: """
                    INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                    SELECT session_id, 0, rowid FROM sessions_fts WHERE session_id = 'mapped';
                    INSERT INTO fts_map(session_id, msg_seq, fts_rowid) VALUES ('stale-map', 0, 999999);
                    INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                    SELECT 'wrong-map', 0, rowid FROM sessions_fts WHERE session_id = 'mapped';
                    INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                    SELECT 'missing-fts', 0, rowid FROM sessions_fts WHERE session_id = 'mapped';
                    """)
                if missingTable { try db.execute(sql: "DROP TABLE fts_map") }
            }
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 4,
                "Missing/stale maps must neither hide real FTS rows nor invent FTS membership")
        }
    }

    func testOverviewMappedContentLookupFallsBackWhenOwnedFTSDDLMismatches() async throws {
        for shape in ["ordinary", "reordered", "external"] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "keep", start: "2026-09-01T00:00:00Z",
                nativeID: "native-keep", indexReady: true)
            try fixture.seedBoundSession(id: "extra", start: "2026-09-01T00:00:00Z",
                nativeID: "native-extra", indexReady: true)
            try fixture.seedBoundSession(id: "ghost", start: "2026-09-01T00:00:00Z",
                nativeID: "native-ghost", indexReady: true, fts: false)
            try fixture.write { db in
                try db.execute(sql: "DROP TABLE sessions_fts")
                try db.execute(sql: "DELETE FROM fts_map")
                switch shape {
                case "ordinary":
                    try db.execute(sql: "CREATE TABLE 'sessions_fts_content'(id INTEGER PRIMARY KEY, c0, c1)")
                    try db.execute(sql: "INSERT INTO sessions_fts_content(id, c0, c1) VALUES (1, 'ghost', 'invented')")
                    try db.execute(sql: "CREATE TABLE sessions_fts(session_id TEXT NOT NULL, content TEXT NOT NULL)")
                    try db.execute(sql: """
                        INSERT INTO sessions_fts(session_id, content) VALUES ('keep', 'keep'), ('extra', 'extra')
                        """)
                    try db.execute(sql: """
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                        SELECT session_id, 0, rowid FROM sessions_fts;
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid) VALUES ('ghost', 0, 1)
                        """)
                case "reordered":
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE sessions_fts USING fts5(
                          content,
                          session_id UNINDEXED,
                          tokenize='trigram case_sensitive 0'
                        )
                        """)
                    try db.execute(sql: """
                        INSERT INTO sessions_fts(session_id, content) VALUES ('keep', 'ghost'), ('extra', 'extra')
                        """)
                    try db.execute(sql: """
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                        SELECT session_id, 0, rowid FROM sessions_fts;
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                        SELECT 'ghost', 0, rowid FROM sessions_fts WHERE session_id = 'keep'
                        """)
                default:
                    try db.execute(sql: "CREATE TABLE 'sessions_fts_content'(id INTEGER PRIMARY KEY, c0, c1)")
                    try db.execute(sql: "INSERT INTO sessions_fts_content(id, c0, c1) VALUES (99, 'ghost', 'invented')")
                    try db.execute(sql: "CREATE TABLE fts_external(session_id TEXT, content TEXT)")
                    try db.execute(sql: """
                        INSERT INTO fts_external(session_id, content) VALUES ('keep', 'keep'), ('extra', 'extra')
                        """)
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE sessions_fts USING fts5(
                          session_id UNINDEXED,
                          content,
                          content='fts_external',
                          tokenize='trigram case_sensitive 0'
                        )
                        """)
                    try db.execute(sql: """
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                        SELECT session_id, 0, rowid FROM sessions_fts;
                        INSERT INTO fts_map(session_id, msg_seq, fts_rowid) VALUES ('ghost', 0, 99)
                        """)
                }
            }
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 2, shape)
        }
    }

    func testPublicationTaskAndLogicalUnitsStayIndependent() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "logical", start: "2026-09-02 12:00:00", extraParserTask: true, indexReady: true)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
                                               deadline: fixture.deadline())
        let ingest = try XCTUnwrap(page.streams.first?.ingest)
        XCTAssertEqual(ingest.publicationCount, 1)
        XCTAssertEqual(ingest.taskCounts.indexReady + ingest.taskCounts.parsed, 2)
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 1)
        XCTAssertNil(page.streams.first?.lastCapture)
        XCTAssertNil(page.streams.first?.heartbeatAt)
        XCTAssertNil(page.streams.first?.replicaACKs)
        XCTAssertNil(page.streams.first?.ai)
    }

    func testOverviewIngestAggregatesKeepParsePrefixAndPendingOldestSemantics() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "ready", start: "2026-09-02 12:00:00", extraParserTask: true, indexReady: true)
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO capture_ingest_publications(
                    publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence)
                VALUES
                    ('\(String(repeating: "a", count: 64))', x'00', ?, ?, ?, 11),
                    ('\(String(repeating: "b", count: 64))', x'00', ?, ?, ?, 12),
                    ('\(String(repeating: "c", count: 64))', x'00', ?, ?, ?, 13),
                    ('\(String(repeating: "d", count: 64))', x'00', ?, ?, ?, 14),
                    ('\(String(repeating: "e", count: 64))', x'00', ?, ?, ?, 15),
                    ('\(String(repeating: "f", count: 64))', x'00', ?, ?, ?, 16)
                """, arguments: [
                    machine, instance, epoch, machine, instance, epoch, machine, instance, epoch,
                    machine, instance, epoch, machine, instance, epoch, machine, instance, epoch,
                ])
            try db.execute(sql: """
                INSERT INTO capture_ingest_ledger(
                    publication_sha256, parser_revision, status, failure_code, created_at)
                VALUES
                    ('\(String(repeating: "a", count: 64))', 'parser-v1', 'pending', NULL, '2020-01-01 00:00:00'),
                    ('\(String(repeating: "b", count: 64))', 'parser-v1', 'pending', NULL, 'not-a-date'),
                    ('\(String(repeating: "c", count: 64))', 'parser-v1', 'pending', NULL, '2026-01-01 00:00:00'),
                    ('\(String(repeating: "d", count: 64))', 'parser-v1', 'parsed', 'parse.ignored', '1960-01-01 00:00:00'),
                    ('\(String(repeating: "e", count: 64))', 'parser-v1', 'quarantined', 'parse.overflow', '2024-01-01 00:00:00'),
                    ('\(String(repeating: "e", count: 64))', 'parser-v2', 'failed_retryable', 'other.denied', '2023-01-01 00:00:00'),
                    ('\(String(repeating: "f", count: 64))', 'parser-v1', 'failed_retryable', 'parse.timeout', '2022-01-01 00:00:00')
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        let ingest = try XCTUnwrap(page.streams.first?.ingest)
        XCTAssertEqual(ingest.publicationCount, 7)
        XCTAssertEqual(ingest.taskCounts.pending, 3)
        XCTAssertEqual(ingest.taskCounts.processing, 0)
        XCTAssertEqual(ingest.taskCounts.parsed, 2)
        XCTAssertEqual(ingest.taskCounts.indexReady, 1)
        XCTAssertEqual(ingest.taskCounts.retryableFailure, 2)
        XCTAssertEqual(ingest.taskCounts.quarantined, 1)
        XCTAssertEqual(ingest.parseFailureTasks, 2)
        XCTAssertEqual(ingest.oldestPendingAt, 1_577_836_800)
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 1)

        let empty = try MetadataSQLFixture()
        defer { empty.remove() }
        try empty.migrate()
        try empty.seedRegistry()
        let emptyProducer = try empty.producer()
        defer { try? emptyProducer.stop() }
        let emptyPage = try await emptyProducer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: empty.deadline())
        let emptyIngest = try XCTUnwrap(emptyPage.streams.first?.ingest)
        XCTAssertEqual(emptyIngest.publicationCount, 0)
        XCTAssertEqual(emptyIngest.taskCounts.pending, 0)
        XCTAssertEqual(emptyIngest.taskCounts.processing, 0)
        XCTAssertEqual(emptyIngest.taskCounts.parsed, 0)
        XCTAssertEqual(emptyIngest.taskCounts.indexReady, 0)
        XCTAssertEqual(emptyIngest.taskCounts.retryableFailure, 0)
        XCTAssertEqual(emptyIngest.taskCounts.quarantined, 0)
        XCTAssertEqual(emptyIngest.parseFailureTasks, 0)
        XCTAssertNil(emptyIngest.oldestPendingAt)
        XCTAssertEqual(emptyPage.streams.first?.fts?.readyLogicalSessions, 0)

        try fixture.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = 'not-a-date' WHERE status = 'pending'
                """)
        }
        let invalidPage = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertNil(try XCTUnwrap(invalidPage.streams.first?.ingest).oldestPendingAt)

        try fixture.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_ledger SET created_at = '1969-12-31 00:00:00'
                WHERE publication_sha256 = ?
                """, arguments: [String(repeating: "a", count: 64)])
        }
        do {
            _ = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTFail("negative pending epoch must stay unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
    }

    func testOverviewIngestAggregatesDoNotRescanLedgerJoin_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let rows = 2_048
        try fixture.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM n WHERE x < ?)
                INSERT INTO capture_ingest_publications(
                    publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence)
                SELECT printf('%064x', x), zeroblob(8192), ?, ?, ?, x FROM n
                """, arguments: [rows, machine, instance, epoch])
            try db.execute(sql: """
                INSERT INTO capture_ingest_ledger(
                    publication_sha256, parser_revision, status, failure_code, created_at)
                SELECT publication_sha256, 'parser-v1',
                    CASE
                        WHEN sequence <= 16 THEN 'pending'
                        WHEN sequence <= 32 THEN 'quarantined'
                        WHEN sequence <= 40 THEN 'failed_retryable'
                        ELSE 'parsed'
                    END,
                    CASE
                        WHEN sequence BETWEEN 17 AND 24 THEN 'parse.overflow'
                        WHEN sequence BETWEEN 25 AND 32 THEN 'other.denied'
                        WHEN sequence BETWEEN 33 AND 40 THEN 'parse.timeout'
                        ELSE NULL
                    END,
                    CASE
                        WHEN sequence = 1 THEN '2020-01-01 00:00:00'
                        WHEN sequence = 2 THEN 'not-a-date'
                        WHEN sequence <= 16 THEN '2026-01-01 00:00:00'
                        ELSE '2026-09-01 00:00:00'
                    END
                FROM capture_ingest_publications
                WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: [machine, instance])
            try db.execute(sql: """
                INSERT INTO capture_ingest_ledger(
                    publication_sha256, parser_revision, status, failure_code, created_at)
                SELECT publication_sha256, 'parser-v2', 'parsed', NULL, '2026-09-01 00:00:00'
                FROM capture_ingest_publications
                WHERE machine_id = ? AND source_instance_id = ?
                """, arguments: [machine, instance])
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        let ingest = try XCTUnwrap(page.streams.first?.ingest)
        XCTAssertEqual(ingest.publicationCount, Int64(rows))
        XCTAssertEqual(ingest.taskCounts.pending, 16)
        XCTAssertEqual(ingest.taskCounts.quarantined, 16)
        XCTAssertEqual(ingest.taskCounts.retryableFailure, 8)
        XCTAssertEqual(ingest.taskCounts.parsed, Int64(rows - 40 + rows))
        XCTAssertEqual(ingest.parseFailureTasks, 16)
        XCTAssertEqual(ingest.oldestPendingAt, 1_577_836_800)
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 0)
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(reads.pageReads, 1_536, "One ledger join must not be repeated pageReads=\(reads.pageReads)")
    }

    func testOverviewOrdersMachineThenInstance() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry(machine: secondMachine, instance: secondInstance)
        try fixture.seedRegistry(machine: machine, instance: secondInstance)
        try fixture.seedRegistry()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        // Default overview page size is the UI's limit=2; this case needs the
        // full three-stream order, so request an explicit page that fits it.
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(limit: 3), requestId: requestId,
                                               deadline: fixture.deadline())
        XCTAssertEqual(page.streams.map { Data("\($0.machineId)/\($0.sourceInstanceId)".utf8) },
                       ["\(machine)/\(instance)", "\(machine)/\(secondInstance)", "\(secondMachine)/\(secondInstance)"].map { Data($0.utf8) })
    }

    // MARK: - Sort, filters, query, visibility

    func testSessionSortIsTimeThenExactUTF8Identity() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let nfc = "caf\u{e9}"
        let nfd = "cafe\u{301}"
        try fixture.seedBoundSession(id: nfd, start: "2026-09-01 12:00:00")
        try fixture.seedBoundSession(id: nfc, start: "2026-09-01 12:00:00", nativeID: "native-nfc")
        try fixture.seedBoundSession(id: "later", start: "2026-09-02 12:00:00", nativeID: "native-later")
        try fixture.seedBoundSession(id: "undated", start: nil, nativeID: "native-undated")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 10),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map { Data($0.sessionId.utf8) }, ["later", nfd, nfc, "undated"].map { Data($0.utf8) })
        XCTAssertNotEqual(Data(nfd.utf8), Data(nfc.utf8))
    }

    func testSessionsInitialListDoesNotReadUnrelatedVisibleSummaryOverflow_repro() async throws {
        // idx_sessions_visible heap-visits every non-hidden row. Unrelated
        // summary overflow must not be pulled into an initial list page.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep-new", start: "2026-09-03 12:00:00", nativeID: "native-new")
        try fixture.seedBoundSession(id: "keep-mid", start: "2026-09-03 11:00:00", nativeID: "native-mid")
        try fixture.seedBoundSession(id: "keep-old", start: "2026-09-03 10:00:00", nativeID: "native-old")
        try fixture.seedBoundSession(id: "skip", start: "2026-09-04 12:00:00", nativeID: "native-skip",
                                     tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-04 13:00:00", nativeID: "native-hidden",
                                     hidden: true)
        try fixture.seedBoundSession(id: "child", start: "2026-09-04 14:00:00", nativeID: "native-child",
                                     parent: "keep-new")
        for ordinal in 0..<128 {
            try fixture.seedBoundSession(
                id: String(format: "overflow-%03d", ordinal),
                start: "2026-08-01 00:00:00",
                nativeID: String(format: "native-overflow-%03d", ordinal))
        }
        try fixture.write { db in
            try db.execute(
                sql: "UPDATE sessions SET summary = ? WHERE id LIKE 'overflow-%'",
                arguments: [String(repeating: "meta ", count: 16384)])
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let first = try await producer.sessions(
            try EngramServiceWebSessionsRequest(limit: 2),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.sessionId), ["keep-new", "keep-mid"])
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(
            reads.pageReads, 2048,
            "Unrelated visible summary overflow must not be heap-scanned pageReads=\(reads.pageReads)")
        let second = try await producer.sessions(
            try EngramServiceWebSessionsRequest(
                limit: 2, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.sessionId), ["keep-old", "overflow-000"])
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertNotNil(second.nextCursor)
    }

    func testFiltersRequireExactUTF8AndSeededNonmatches() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedRegistry(machine: secondMachine, instance: secondInstance)
        try fixture.seedRegistry(instance: secondInstance)
        let codexInstance = "DDDDDDDD-0000-4000-8000-000000000004"
        try fixture.seedRegistry(instance: codexInstance, source: .codex)
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00", project: "project_1",
                                     title: "alpha searchable", tier: "normal")
        try fixture.seedBoundSession(id: "other-project", start: "2026-09-03 11:00:00", nativeID: "native-proj",
                                     project: "project_2", title: "alpha other")
        try fixture.seedBoundSession(id: "other-machine", start: "2026-09-03 10:00:00", nativeID: "native-machine",
                                     machine: secondMachine, instance: secondInstance, project: "project_2", title: "alpha machine")
        try fixture.seedBoundSession(id: "other-instance", start: "2026-09-03 10:00:00", nativeID: "native-instance",
                                     instance: secondInstance, project: "project_2", title: "alpha instance")
        try fixture.seedBoundSession(id: "codex", start: "2026-09-03 10:00:00", nativeID: "native-codex",
                                     instance: codexInstance, source: .codex, project: "project_2", title: "alpha codex")
        try fixture.seedBoundSession(id: "lite", start: "2026-09-03 09:00:00", nativeID: "native-lite",
                                     project: "project_1", title: "alpha lite", tier: "lite")
        try fixture.seedBoundSession(id: "skip", start: "2026-09-03 08:00:00", nativeID: "native-skip",
                                     title: "alpha skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-03 07:00:00", nativeID: "native-hidden",
                                     title: "alpha hidden", hidden: true)
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 06:00:00", nativeID: "native-child",
                                     parent: "keep")
        try fixture.seedLocalSession(id: "local-only")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let listed = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 20),
                                                 requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(listed.items.map(\.sessionId)),
                       ["keep", "other-project", "other-machine", "other-instance", "codex", "lite"])

        let byProject = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: "project_1", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(byProject.items.map(\.sessionId)), ["keep", "lite"])

        let byMachine = try await producer.sessions(
            try EngramServiceWebSessionsRequest(machineId: machine, sourceInstanceId: instance, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(byMachine.items.map(\.sessionId)), ["keep", "other-project", "lite"])
        let machineOnly = try await producer.sessions(try EngramServiceWebSessionsRequest(machineId: machine, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(machineOnly.items.map(\.sessionId)), ["keep", "other-project", "other-instance", "codex", "lite"])
        let otherInstance = try await producer.sessions(try EngramServiceWebSessionsRequest(machineId: machine,
            sourceInstanceId: secondInstance, limit: 20), requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(otherInstance.items.map(\.sessionId), ["other-instance"])

        let bySource = try await producer.sessions(
            try EngramServiceWebSessionsRequest(source: "claude-code", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(bySource.items.map(\.sessionId)),
                       ["keep", "other-project", "other-machine", "other-instance", "lite"])
        let byCodex = try await producer.sessions(try EngramServiceWebSessionsRequest(source: "codex", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(byCodex.items.map(\.sessionId), ["codex"])

        let searched = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "alpha searchable", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(searched.items.map(\.sessionId), ["keep"])
        // agents=all pins `sessions` to the skip-excluding index in the total
        // statement while the page itself seeks the FTS hit set first; both
        // must agree.
        let searchedAll = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "alpha searchable", agents: .all, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(searchedAll.items.map(\.sessionId), ["keep"])
        XCTAssertEqual(searchedAll.totalCount, searched.totalCount)

        let limited = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                                  requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(limited.items.count, 1)
        XCTAssertNotNil(limited.nextCursor)

        for id in ["skip", "hidden", "local-only"] {
            let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: id),
                                                          requestId: requestId, deadline: fixture.deadline())
            XCTAssertNil(detail.detail, id)
        }
    }

    func testSessionsDateToolHideAndExactTotalCount_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedBoundSession(id: "mixed", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-mixed", title: "mixed tools")
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-tool", title: "tool only")
        try fixture.seedBoundSession(id: "unknown-counts", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-unknown", title: "unknown counts")
        try fixture.seedBoundSession(id: "page-a", start: Self.sqliteUTC(localDate: "2026-09-07", hour: 11),
                                     nativeID: "native-a", title: "page a")
        try fixture.seedBoundSession(id: "page-b", start: Self.sqliteUTC(localDate: "2026-09-07", hour: 10),
                                     nativeID: "native-b", title: "page b")
        try fixture.seedBoundSession(id: "before", start: Self.sqliteUTC(localDate: "2026-09-06"),
                                     nativeID: "native-before")
        try fixture.seedBoundSession(id: "after", start: Self.sqliteUTC(localDate: "2026-09-08"),
                                     nativeID: "native-after")
        try fixture.seedBoundSession(id: "undated", start: nil, nativeID: "native-undated")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "child", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-child", parent: "keep")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 2, tool_message_count = 1 WHERE id = 'keep'
                """)
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 1, tool_message_count = 4 WHERE id = 'mixed'
                """)
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 1, tool_message_count = 0 WHERE id IN ('page-a', 'page-b')
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let ranged = try await producer.sessions(
            try EngramServiceWebSessionsRequest(since: "2026-09-07", until: "2026-09-07", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(ranged.items.map(\.sessionId)),
                       ["keep", "mixed", "tool-only", "unknown-counts", "page-a", "page-b"])
        XCTAssertEqual(ranged.totalCount, 6)
        XCTAssertNil(ranged.nextCursor)

        let hiddenTools = try await producer.sessions(
            try EngramServiceWebSessionsRequest(since: "2026-09-07", until: "2026-09-07",
                                               tools: .hide, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(hiddenTools.items.map(\.sessionId)),
                       ["keep", "mixed", "unknown-counts", "page-a", "page-b"])
        XCTAssertEqual(hiddenTools.totalCount, 5)
        XCTAssertFalse(hiddenTools.items.contains { $0.sessionId == "tool-only" })

        let first = try await producer.sessions(
            try EngramServiceWebSessionsRequest(since: "2026-09-07", until: "2026-09-07", limit: 2),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.count, 2)
        XCTAssertEqual(first.totalCount, 6)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.sessions(
            try EngramServiceWebSessionsRequest(since: "2026-09-07", until: "2026-09-07",
                                               limit: 2, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.totalCount, 6)
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        await assertStale(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(since: "2026-09-07", until: "2026-09-07",
                                                   tools: .hide, limit: 2,
                                                   snapshotId: first.snapshotId, cursor: cursor),
                requestId: self.requestId, deadline: fixture.deadline())
        }

        let searched = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "alpha searchable", tools: .hide, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(searched.items.map(\.sessionId), ["keep"])
        XCTAssertEqual(searched.totalCount, 1)
    }

    func testPluralSourcesAndProjectKeysCanonicalizeAndRejectSingularConflict_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let codexInstance = "DDDDDDDD-0000-4000-8000-000000000004"
        try fixture.seedRegistry(instance: codexInstance, source: .codex)
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00", project: "project_1")
        try fixture.seedBoundSession(id: "other-project", start: "2026-09-03 11:00:00", nativeID: "native-proj",
                                     project: "project_2")
        try fixture.seedBoundSession(id: "codex", start: "2026-09-03 10:00:00", nativeID: "native-codex",
                                     instance: codexInstance, source: .codex, project: "project_2")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(source: "codex", sources: ["codex"], limit: 20))
        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(projectKey: "project_1", projectKeys: ["project_1"], limit: 20))
        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(sources: [], limit: 20))
        XCTAssertThrowsError(try EngramServiceWebSessionsRequest(sources: Array(repeating: "codex", count: 33), limit: 20))
        let canonical = try EngramServiceWebSessionsRequest(sources: ["codex", "claude-code"],
            projectKeys: ["project_2", "project_1"], limit: 20)
        XCTAssertEqual(canonical.sources, ["claude-code", "codex"])
        XCTAssertEqual(canonical.projectKeys, ["project_1", "project_2"])

        let page = try await producer.sessions(canonical, requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(page.items.map(\.sessionId)), ["keep", "other-project", "codex"])
        XCTAssertTrue(page.items.allSatisfy { ["claude-code", "codex"].contains($0.source) })
        XCTAssertTrue(page.items.allSatisfy { ["project_1", "project_2"].contains($0.projectKey ?? "") })
    }

    func testSessionIdFilterMatchesStoredIdOrNativeAndReturnsAllAuthorized_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let hiddenInstance = "CCCCCCCC-0000-4000-8000-000000000014"
        let childInstance = "DDDDDDDD-0000-4000-8000-000000000015"
        try fixture.seedRegistry(instance: hiddenInstance)
        try fixture.seedRegistry(instance: childInstance)
        try fixture.seedBoundSession(id: "canonical-keep", start: "2026-09-03 12:00:00", nativeID: "old-uuid-keep")
        try fixture.seedBoundSession(id: "canonical-two", start: "2026-09-03 11:00:00", nativeID: "old-uuid-two")
        try fixture.seedBoundSession(id: "old-uuid-keep", start: "2026-09-03 10:00:00", nativeID: "other-native")
        try fixture.seedBoundSession(id: "hidden-native", start: "2026-09-03 09:00:00", nativeID: "old-uuid-keep",
                                     instance: hiddenInstance, hidden: true)
        try fixture.seedBoundSession(id: "child-native", start: "2026-09-03 08:00:00", nativeID: "old-uuid-keep",
                                     instance: childInstance, parent: "canonical-keep")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let matches = try await producer.sessions(
            try EngramServiceWebSessionsRequest(sessionId: "old-uuid-keep", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(matches.items.map(\.sessionId), ["canonical-keep", "old-uuid-keep"])
        XCTAssertEqual(matches.items.first { $0.sessionId == "canonical-keep" }?.nativeId, "old-uuid-keep")
        XCTAssertEqual(matches.items.first { $0.sessionId == "old-uuid-keep" }?.nativeId, "other-native")

        let first = try await producer.sessions(
            try EngramServiceWebSessionsRequest(sessionId: "old-uuid-keep", limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.sessionId), ["canonical-keep"])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.sessions(
            try EngramServiceWebSessionsRequest(sessionId: "old-uuid-keep", limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.sessionId), ["old-uuid-keep"])
        XCTAssertEqual(second.snapshotId, first.snapshotId)
    }

    func testAgentsHideAllOnlyRetainSkipHiddenRegistryFences_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 11:00:00", nativeID: "native-child",
                                     parent: "parent")
        try fixture.seedBoundSession(id: "skip-child", start: "2026-09-03 10:00:00", nativeID: "native-skip",
                                     tier: "skip", parent: "parent")
        try fixture.seedBoundSession(id: "hidden-child", start: "2026-09-03 09:00:00", nativeID: "native-hidden",
                                     hidden: true, parent: "parent")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET suggested_parent_id = 'parent', agent_role = 'dispatched'
                WHERE id = 'child'
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let hidden = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 20),
                                                 requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(hidden.items.map(\.sessionId), ["parent"])
        XCTAssertEqual(hidden.items.first?.isAgent, false)

        let all = try await producer.sessions(try EngramServiceWebSessionsRequest(agents: .all, limit: 20),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(all.items.map(\.sessionId)), ["parent", "child"])
        XCTAssertEqual(all.items.first { $0.sessionId == "child" }?.isAgent, true)

        let only = try await producer.sessions(try EngramServiceWebSessionsRequest(agents: .only, limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(only.items.map(\.sessionId), ["child"])
        XCTAssertEqual(only.items.first?.isAgent, true)
        XCTAssertFalse(only.items.contains { $0.sessionId == "skip-child" || $0.sessionId == "hidden-child" })
    }

    func testAgentsHideExcludesRoleOnlySubagentAndDispatched_repro() async throws {
        // hide must use the same is-agent predicate as only/summary, not
        // parent/suggested-null alone. NULL agent_role is not an agent.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "human", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "null-role", start: "2026-09-03 11:00:00", nativeID: "native-null")
        try fixture.seedBoundSession(id: "role-dispatched", start: "2026-09-03 10:00:00",
                                     nativeID: "native-dispatched")
        try fixture.seedBoundSession(id: "role-subagent", start: "2026-09-03 09:00:00",
                                     nativeID: "native-subagent")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET agent_role = 'dispatched' WHERE id = 'role-dispatched'
                """)
            try db.execute(sql: """
                UPDATE sessions SET agent_role = 'subagent' WHERE id = 'role-subagent'
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let hidden = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 20),
                                                 requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(hidden.items.map(\.sessionId), ["human", "null-role"])
        XCTAssertTrue(hidden.items.allSatisfy { $0.isAgent == false })

        let all = try await producer.sessions(try EngramServiceWebSessionsRequest(agents: .all, limit: 20),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(all.items.map(\.sessionId)),
                       ["human", "null-role", "role-dispatched", "role-subagent"])
        XCTAssertEqual(all.items.first { $0.sessionId == "role-dispatched" }?.isAgent, true)
        XCTAssertEqual(all.items.first { $0.sessionId == "role-subagent" }?.isAgent, true)
        XCTAssertEqual(all.items.first { $0.sessionId == "null-role" }?.isAgent, false)

        let only = try await producer.sessions(try EngramServiceWebSessionsRequest(agents: .only, limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(only.items.map(\.sessionId)), ["role-dispatched", "role-subagent"])
        XCTAssertTrue(only.items.allSatisfy { $0.isAgent == true })
    }

    func testSessionDetailAllowsAuthorizedNonSkipChildren_repro() async throws {
        // List agents=all/only may return a non-skip child; detail must use the
        // same authorized non-skip identity lookup, not default hide.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "parent", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 11:00:00", nativeID: "native-child",
                                     parent: "parent")
        try fixture.seedBoundSession(id: "skip-child", start: "2026-09-03 10:00:00", nativeID: "native-skip",
                                     tier: "skip", parent: "parent")
        try fixture.seedBoundSession(id: "hidden-child", start: "2026-09-03 09:00:00", nativeID: "native-hidden",
                                     hidden: true, parent: "parent")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let all = try await producer.sessions(try EngramServiceWebSessionsRequest(agents: .all, limit: 20),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(all.items.map(\.sessionId)), ["parent", "child"])

        let child = try await producer.sessionDetail(
            try EngramServiceWebSessionDetailRequest(sessionId: "child"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(child.detail?.session.sessionId, "child")
        XCTAssertEqual(child.detail?.session.isAgent, true)

        let parent = try await producer.sessionDetail(
            try EngramServiceWebSessionDetailRequest(sessionId: "parent"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(parent.detail?.session.sessionId, "parent")

        for id in ["skip-child", "hidden-child"] {
            let denied = try await producer.sessionDetail(
                try EngramServiceWebSessionDetailRequest(sessionId: id),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertNil(denied.detail, id)
        }
    }

    func testFacetsSourceCountsExcludeHiddenSkipDisabledAndPaginate_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let codexInstance = "DDDDDDDD-0000-4000-8000-000000000004"
        try fixture.seedRegistry(instance: codexInstance, source: .codex)
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 11:00:00", nativeID: "native-child",
                                     parent: "keep")
        try fixture.seedBoundSession(id: "skip", start: "2026-09-03 10:00:00", nativeID: "native-skip",
                                     tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-03 09:00:00", nativeID: "native-hidden",
                                     hidden: true)
        try fixture.seedBoundSession(id: "codex", start: "2026-09-03 08:00:00", nativeID: "native-codex",
                                     instance: codexInstance, source: .codex)
        let revokedInstance = "EEEEEEEE-0000-4000-8000-000000000005"
        try fixture.seedRegistry(instance: revokedInstance)
        try fixture.seedBoundSession(id: "revoked", start: "2026-09-03 07:00:00", nativeID: "native-revoked",
                                     instance: revokedInstance)
        try fixture.write { db in
            try db.execute(sql: "DELETE FROM capture_ingest_epoch_history WHERE source_instance_id = ?",
                           arguments: [revokedInstance])
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        // invariant 2 (subagent sessions stay skip): skip/hidden/revoked stay out of facet counts
        let hidden = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source, limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(hidden.items.map(\.key), ["claude-code", "codex"])
        XCTAssertEqual(hidden.items.map(\.sessionCount), [1, 1])

        let first = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source, limit: 1),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.key), ["claude-code"])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.facets(
            try EngramServiceWebFacetsRequest(kind: .source, limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.key), ["codex"])
        XCTAssertEqual(second.snapshotId, first.snapshotId)

        let all = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source, agents: .all, limit: 20),
                                            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(all.items.first { $0.key == "claude-code" }?.sessionCount, 2)

        await assertStale(deadline: fixture.deadline()) {
            try await producer.facets(
                try EngramServiceWebFacetsRequest(kind: .project, limit: 1, snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.facets(
                try EngramServiceWebFacetsRequest(kind: .source, agents: .all, limit: 1,
                                                 snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.facets(
                try EngramServiceWebFacetsRequest(kind: .source, query: "codex", limit: 1,
                                                 snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.facets(
                try EngramServiceWebFacetsRequest(kind: .source, limit: 2, snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }

        let restricted = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? restricted.stop() }
        let onlyClaude = try await restricted.facets(try EngramServiceWebFacetsRequest(kind: .source, limit: 20),
                                                     requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(onlyClaude.items.map(\.key), ["claude-code"])
    }

    func testFacetsProjectSearchSpacesAndDuplicateBasenamesHaveDistinctKeys_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "token", start: "2026-09-03 12:00:00", project: "project_1")
        try fixture.seedBoundSession(id: "spaces", start: "2026-09-03 11:00:00", nativeID: "native-spaces",
                                     project: "My Project")
        try fixture.seedBoundSession(id: "left", start: "2026-09-03 10:00:00", nativeID: "native-left",
                                     project: "/Users/a/engram")
        try fixture.seedBoundSession(id: "right", start: "2026-09-03 09:00:00", nativeID: "native-right",
                                     project: "/Users/b/engram")
        try fixture.seedBoundSession(id: "cased", start: "2026-09-03 08:00:00", nativeID: "native-cased",
                                     project: "My Engram")
        let producer = try fixture.producer()
        defer { try? producer.stop() }

        let page = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .project, limit: 20),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.count, 5)
        let token = try XCTUnwrap(page.items.first { $0.label == "project_1" || $0.key == "project_1" })
        XCTAssertEqual(token.key, "project_1")
        let spaced = try XCTUnwrap(page.items.first { $0.label == "My Project" })
        XCTAssertEqual(spaced.key, Self.opaqueProjectKey("My Project"))
        XCTAssertTrue(spaced.key.hasPrefix("p."))
        XCTAssertFalse(spaced.key.contains(" "))
        let twins = page.items.filter { $0.label == "engram" }
        XCTAssertEqual(twins.count, 2)
        XCTAssertEqual(Set(twins.map(\.key)).count, 2)
        XCTAssertFalse(page.items.contains { $0.key.contains("/") || $0.label.contains("/") })
        let cased = try XCTUnwrap(page.items.first { $0.label == "My Engram" })
        XCTAssertEqual(cased.key, Self.opaqueProjectKey("My Engram"))

        let searched = try await producer.facets(
            try EngramServiceWebFacetsRequest(kind: .project, query: "engram", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(searched.items.map(\.label)), ["engram", "My Engram"])
        XCTAssertEqual(searched.items.count, 3)
    }

    func testFacetsReturnedProjectKeyFiltersExactSessions_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "token", start: "2026-09-03 12:00:00", project: "project_1")
        try fixture.seedBoundSession(id: "spaces", start: "2026-09-03 11:00:00", nativeID: "native-spaces",
                                     project: "My Project")
        try fixture.seedBoundSession(id: "left", start: "2026-09-03 10:00:00", nativeID: "native-left",
                                     project: "/Users/a/engram")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let facets = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .project, limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        let spaced = try XCTUnwrap(facets.items.first { $0.label == "My Project" })
        let left = try XCTUnwrap(facets.items.first { $0.label == "engram" })
        let tokenSessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: "project_1", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(tokenSessions.items.map(\.sessionId), ["token"])
        XCTAssertEqual(tokenSessions.items.first?.projectKey, "project_1")
        let spacedSessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: spaced.key, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(spacedSessions.items.map(\.sessionId), ["spaces"])
        XCTAssertEqual(spacedSessions.items.first?.projectKey, spaced.key)
        let leftSessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: left.key, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(leftSessions.items.map(\.sessionId), ["left"])
        XCTAssertEqual(leftSessions.items.first?.projectKey, left.key)
        XCTAssertEqual(leftSessions.items.first?.projectLabel, "engram")
        XCTAssertFalse(leftSessions.items.contains { $0.projectKey?.contains("/") == true })
    }

    func testFacetsAfterPreparationRegistryRevokeIsStale_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00")
        let policy = PolicyBox(validPolicy())
        let mutation = MetadataPreparationMutation(operation: .facets) {
            try fixture.revoke(.registryRoot, sessionID: "keep", policy: policy)
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                            policy: { try policy.current() })
        defer { try? producer.stop() }
        let baseline = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source, limit: 20),
                                                 requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(baseline.items.map(\.key), ["claude-code"])
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source, limit: 20),
                                      requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testFacetsOpaqueProjectKeyDoesNotCollideWithLegacyDigestToken_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let digest = ArchiveV2Hash.sha256(Data("My Project".utf8))
        try fixture.seedBoundSession(id: "spaces", start: "2026-09-03 12:00:00", project: "My Project")
        try fixture.seedBoundSession(id: "digest", start: "2026-09-03 11:00:00", nativeID: "native-digest",
                                     project: digest)
        let literalOpaque = "p." + digest
        try fixture.seedBoundSession(id: "literal", start: "2026-09-03 10:00:00", nativeID: "native-literal",
                                     project: literalOpaque)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .project, limit: 20),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.count, 3)
        let opaque = try XCTUnwrap(page.items.first { $0.label == "My Project" })
        XCTAssertEqual(opaque.key, literalOpaque)
        let legacy = try XCTUnwrap(page.items.first { $0.key == digest })
        XCTAssertEqual(legacy.key, digest)
        let literal = try XCTUnwrap(page.items.first { $0.key == Self.opaqueProjectKey(literalOpaque) })
        XCTAssertEqual(literal.key, "p." + ArchiveV2Hash.sha256(Data(literalOpaque.utf8)))
        XCTAssertNotEqual(opaque.key, legacy.key)
        XCTAssertNotEqual(opaque.key, literal.key)
        let opaqueSessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: opaque.key, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(opaqueSessions.items.map(\.sessionId), ["spaces"])
        let legacySessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: digest, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(legacySessions.items.map(\.sessionId), ["digest"])
        let literalSessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: literal.key, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(literalSessions.items.map(\.sessionId), ["literal"])
    }

    func testFacetsProjectNULBytesDoNotBecomePrefixToken_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "safe", start: "2026-09-03 12:00:00", project: "safe")
        try fixture.seedBoundSession(id: "nul", start: "2026-09-03 11:00:00", nativeID: "native-nul",
                                     project: "placeholder")
        try fixture.write { db in
            let nulBytes = Data("safe\u{0}secret".utf8)
            try db.execute(sql: "UPDATE sessions SET project = CAST(? AS TEXT) WHERE id = 'nul'",
                           arguments: [nulBytes])
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .project, limit: 20),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.key), ["safe"])
        XCTAssertEqual(page.items.first?.sessionCount, 1)
        let sessions = try await producer.sessions(
            try EngramServiceWebSessionsRequest(projectKey: "safe", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(sessions.items.map(\.sessionId), ["safe"])
    }

    func testStatsGroupsTotalsDatesLiteFencesAndStaleFilters_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let monday = "2026-09-07"
        let wednesday = "2026-09-09"
        let nextMonday = "2026-09-14"
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: monday),
                                     project: "project_1")
        try fixture.seedBoundSession(id: "lite", start: Self.sqliteUTC(localDate: wednesday),
                                     nativeID: "native-lite", project: "My Project", tier: "lite")
        try fixture.seedBoundSession(id: "week-two", start: Self.sqliteUTC(localDate: nextMonday),
                                     nativeID: "native-week", project: "project_1")
        try fixture.seedBoundSession(id: "unknown-project", start: Self.sqliteUTC(localDate: monday, hour: 15),
                                     nativeID: "native-unknown", project: nil)
        try fixture.seedBoundSession(id: "unknown-date", start: nil, nativeID: "native-date",
                                     project: "project_1")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: monday),
                                     nativeID: "native-skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: monday),
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "child", start: Self.sqliteUTC(localDate: monday),
                                     nativeID: "native-child", parent: "keep")
        let disabledInstance = "FFFFFFFF-0000-4000-8000-00000000000F"
        try fixture.seedRegistry(instance: disabledInstance, source: .codex)
        try fixture.seedBoundSession(id: "codex", start: Self.sqliteUTC(localDate: monday),
                                     nativeID: "native-codex", instance: disabledInstance, source: .codex)
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET message_count = 10, user_message_count = 3,
                    assistant_message_count = 5, tool_message_count = 2 WHERE id = 'keep'
                """)
            try db.execute(sql: """
                UPDATE sessions SET message_count = 4, user_message_count = 1,
                    assistant_message_count = 2, tool_message_count = 1 WHERE id = 'lite'
                """)
            try db.execute(sql: """
                UPDATE sessions SET message_count = 6, user_message_count = 2,
                    assistant_message_count = 3, tool_message_count = 1 WHERE id = 'week-two'
                """)
            try db.execute(sql: """
                UPDATE sessions SET message_count = 2, user_message_count = 1,
                    assistant_message_count = 1, tool_message_count = 0 WHERE id = 'unknown-project'
                """)
            try db.execute(sql: """
                UPDATE sessions SET message_count = 1, user_message_count = 1,
                    assistant_message_count = 0, tool_message_count = 0 WHERE id = 'unknown-date'
                """)
        }
        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }

        let sources = try await producer.stats(try EngramServiceWebStatsRequest(limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(sources.groupBy, .source)
        XCTAssertEqual(sources.timeZone, TimeZone.current.identifier)
        XCTAssertEqual(sources.items.map(\.key), ["claude-code"])
        XCTAssertEqual(sources.items.first?.label, "claude-code")
        XCTAssertEqual(sources.totals.sessionCount, 5)
        XCTAssertEqual(sources.totals.messageCount, 23)
        XCTAssertEqual(sources.totals.userMessageCount, 8)
        XCTAssertEqual(sources.totals.assistantMessageCount, 11)
        XCTAssertEqual(sources.totals.toolMessageCount, 4)
        XCTAssertEqual(sources.items.first?.sessionCount, sources.totals.sessionCount)

        let quiet = try await producer.stats(try EngramServiceWebStatsRequest(excludeNoise: true, limit: 20),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(quiet.totals.sessionCount, 4)
        XCTAssertEqual(quiet.totals.messageCount, 19)

        let projects = try await producer.stats(try EngramServiceWebStatsRequest(groupBy: .project, limit: 20),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(projects.items.map(\.key)),
                       ["project_1", Self.opaqueProjectKey("My Project"),
                        EngramServiceWebMetadataValidation.unknownProjectKey])
        XCTAssertEqual(projects.items.first { $0.key == "project_1" }?.sessionCount, 3)
        XCTAssertEqual(projects.items.first { $0.key == EngramServiceWebMetadataValidation.unknownProjectKey }?.label,
                       "Unknown")

        let days = try await producer.stats(try EngramServiceWebStatsRequest(groupBy: .day, limit: 20),
                                            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(days.items.map(\.key)),
                       [monday, wednesday, nextMonday, EngramServiceWebMetadataValidation.unknownDateKey])
        XCTAssertEqual(days.items.first { $0.key == monday }?.label, monday)
        XCTAssertEqual(days.items.first { $0.key == EngramServiceWebMetadataValidation.unknownDateKey }?.label,
                       "Unknown")

        let weeks = try await producer.stats(try EngramServiceWebStatsRequest(groupBy: .week, limit: 20),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(weeks.items.map(\.key)),
                       [monday, nextMonday, EngramServiceWebMetadataValidation.unknownDateKey])

        let ranged = try await producer.stats(
            try EngramServiceWebStatsRequest(groupBy: .day, since: monday, until: wednesday, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(ranged.items.map(\.key)), [monday, wednesday])
        XCTAssertEqual(ranged.totals.sessionCount, 3)

        let first = try await producer.stats(try EngramServiceWebStatsRequest(groupBy: .project, limit: 1),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.totals.sessionCount, 5)
        XCTAssertGreaterThan(first.totals.sessionCount, first.items[0].sessionCount)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.stats(
            try EngramServiceWebStatsRequest(groupBy: .project, limit: 1,
                                            snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.totals.sessionCount, 5)
        XCTAssertNotEqual(second.items.first?.key, first.items.first?.key)

        await assertStale(deadline: fixture.deadline()) {
            try await producer.stats(
                try EngramServiceWebStatsRequest(groupBy: .source, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.stats(
                try EngramServiceWebStatsRequest(groupBy: .project, excludeNoise: true, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.stats(
                try EngramServiceWebStatsRequest(groupBy: .project, since: monday, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.stats(
                try EngramServiceWebStatsRequest(groupBy: .project, agents: .all, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.stats(
                try EngramServiceWebStatsRequest(groupBy: .project, limit: 2,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }

        let enabled = try fixture.producer()
        defer { try? enabled.stop() }
        let both = try await enabled.stats(try EngramServiceWebStatsRequest(limit: 20),
                                           requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(both.items.map(\.key), ["claude-code", "codex"])
        XCTAssertEqual(both.totals.sessionCount, 6)
    }

    func testStatsAfterPreparationRegistryRevokeIsStale_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00")
        let policy = PolicyBox(validPolicy())
        let mutation = MetadataPreparationMutation(operation: .stats) {
            try fixture.revoke(.registryRoot, sessionID: "keep", policy: policy)
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                            policy: { try policy.current() })
        defer { try? producer.stop() }
        let baseline = try await producer.stats(try EngramServiceWebStatsRequest(limit: 20),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(baseline.items.map(\.key), ["claude-code"])
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.stats(try EngramServiceWebStatsRequest(limit: 20),
                                     requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testSettingsReadsEnabledSourcesAuthorizedCountSafeAliasesAndRetiredFields_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00", project: "project_1")
        try fixture.seedBoundSession(id: "lite", start: "2026-09-03 11:00:00", nativeID: "native-lite",
                                     project: "project_1", tier: "lite")
        try fixture.seedBoundSession(id: "skip", start: "2026-09-03 10:00:00", nativeID: "native-skip",
                                     project: "hidden_proj", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: "2026-09-03 09:00:00", nativeID: "native-hidden",
                                     project: "hidden_proj", hidden: true)
        try fixture.seedBoundSession(id: "child", start: "2026-09-03 08:00:00", nativeID: "native-child",
                                     parent: "keep")
        let disabledInstance = "FFFFFFFF-0000-4000-8000-00000000000F"
        try fixture.seedRegistry(instance: disabledInstance, source: .codex)
        try fixture.seedBoundSession(id: "codex", start: "2026-09-03 07:00:00", nativeID: "native-codex",
                                     instance: disabledInstance, source: .codex, project: "codex_proj")
        try fixture.seedBoundSession(id: "dir", start: "2026-09-03 06:00:00", nativeID: "native-dir",
                                     project: "/Users/me/engram")
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO project_aliases(alias, canonical) VALUES
                    ('old_keep', 'project_1'),
                    ('beta', 'project_1'),
                    ('hidden_name', 'hidden_proj'),
                    ('codex_old', 'codex_proj'),
                    ('/tmp/absolute', 'project_1'),
                    ('/old/engram', '/Users/me/engram')
                """)
        }
        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }

        let page = try await producer.settings(try EngramServiceWebSettingsRequest(limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        let dirAlias = Self.opaqueProjectKey("/old/engram")
        let dirCanonical = Self.opaqueProjectKey("/Users/me/engram")
        let absAlias = Self.opaqueProjectKey("/tmp/absolute")
        XCTAssertEqual(page.sources.map(\.key), ["claude-code"])
        XCTAssertEqual(page.sources.map(\.label), ["claude-code"])
        XCTAssertEqual(page.totalSessions, 3)
        XCTAssertEqual(page.aliases.map { "\($0.alias)>\($0.canonical)" },
                       ["\(dirAlias)>\(dirCanonical)", "beta>project_1", "old_keep>project_1",
                        "\(absAlias)>project_1"])
        XCTAssertEqual(page.aliases.map(\.aliasLabel), ["engram", "beta", "old_keep", "absolute"])
        XCTAssertEqual(page.aliases.map(\.canonicalLabel), ["engram", "project_1", "project_1", "project_1"])
        XCTAssertFalse(page.aliases.contains { $0.alias.contains("/") || $0.canonical.contains("/") })
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.nodeName.availability, .unavailable)
        XCTAssertEqual(page.peers.availability, .unavailable)
        XCTAssertEqual(page.port.availability, .unavailable)
        let encoded = try JSONEncoder().encode(page)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["nodeName"] as? [String: Any])?.keys.sorted(), ["availability"])
        XCTAssertNil((object["port"] as? [String: Any])?["value"])
        XCTAssertNil(object["httpPort"])

        let first = try await producer.settings(try EngramServiceWebSettingsRequest(limit: 1),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.aliases.map(\.alias), [dirAlias])
        XCTAssertEqual(first.aliases.first?.aliasLabel, "engram")
        XCTAssertEqual(first.totalSessions, 3)
        XCTAssertEqual(first.sources.map(\.key), ["claude-code"])
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.settings(
            try EngramServiceWebSettingsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.totalSessions, 3)
        XCTAssertEqual(second.aliases.map(\.alias), ["beta"])

        await assertStale(deadline: fixture.deadline()) {
            try await producer.settings(
                try EngramServiceWebSettingsRequest(limit: 2, snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }

        let enabled = try fixture.producer()
        defer { try? enabled.stop() }
        let both = try await enabled.settings(try EngramServiceWebSettingsRequest(limit: 20),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(both.sources.map(\.key), ["claude-code", "codex"])
        XCTAssertEqual(both.totalSessions, 4)
        XCTAssertEqual(Set(both.aliases.map(\.canonical)), ["codex_proj", "project_1", dirCanonical])
    }

    func testSettingsPathShapedCanonicalKeepsAliasAsOpaqueIdentityAndBasenameLabel_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "dir", start: "2026-09-03 12:00:00", project: "/Users/me/engram")
        try fixture.seedBoundSession(id: "hidden-dir", start: "2026-09-03 11:00:00", nativeID: "native-hidden-dir",
                                     project: "/secret/hidden", hidden: true)
        try fixture.write { db in
            try db.execute(sql: """
                INSERT INTO project_aliases(alias, canonical) VALUES
                    ('/old/engram', '/Users/me/engram'),
                    ('/old/hidden', '/secret/hidden')
                """)
        }
        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }
        let page = try await producer.settings(try EngramServiceWebSettingsRequest(limit: 20),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.totalSessions, 1)
        XCTAssertEqual(page.aliases.count, 1)
        let row = try XCTUnwrap(page.aliases.first)
        XCTAssertEqual(row.alias, Self.opaqueProjectKey("/old/engram"))
        XCTAssertEqual(row.canonical, Self.opaqueProjectKey("/Users/me/engram"))
        XCTAssertEqual(row.aliasLabel, "engram")
        XCTAssertEqual(row.canonicalLabel, "engram")
        XCTAssertFalse(row.alias.contains("/"))
        XCTAssertFalse(row.canonical.contains("/"))
        XCTAssertFalse(row.aliasLabel.contains("/"))
        XCTAssertFalse(row.canonicalLabel.contains("/"))
    }

    func testSettingsAfterPreparationRegistryRevokeIsStale_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00")
        try fixture.write { db in
            try db.execute(sql: "INSERT INTO project_aliases(alias, canonical) VALUES ('old_keep', 'project_1')")
        }
        let policy = PolicyBox(validPolicy())
        let mutation = MetadataPreparationMutation(operation: .settings) {
            try fixture.revoke(.registryRoot, sessionID: "keep", policy: policy)
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                            policy: { try policy.current() })
        defer { try? producer.stop() }
        let baseline = try await producer.settings(try EngramServiceWebSettingsRequest(limit: 20),
                                                   requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(baseline.sources.map(\.key), ["claude-code"])
        XCTAssertEqual(baseline.totalSessions, 1)
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.settings(try EngramServiceWebSettingsRequest(limit: 20),
                                        requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testSummaryExposesIsAgentAndScalarMessageCounts_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "counted", start: "2026-09-03 12:00:00")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions
                SET user_message_count = 3, assistant_message_count = 5, system_message_count = 1
                WHERE id = 'counted'
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                               requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.first?.sessionId, "counted")
        XCTAssertEqual(page.items.first?.isAgent, false)
        XCTAssertEqual(page.items.first?.userMessageCount, 3)
        XCTAssertEqual(page.items.first?.assistantMessageCount, 5)
        XCTAssertEqual(page.items.first?.systemMessageCount, 1)
    }

    func testSessionsOwnedMatchDoesNotMaterializeLargeFTSBodies_repro() async throws {
        // Correlated MATCH + UNINDEXED session_id does extra page work per
        // visible session that fails the term. Owned rowid→c0 projection
        // must keep whole-operation SQLite page work (including MATCH
        // postings) under this budget. Not a claim that no FTS pages are read.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                     title: "history keep", indexReady: true)
        for ordinal in 0..<32 {
            try fixture.seedBoundSession(id: "other-\(ordinal)",
                                         start: String(format: "2026-09-02 %02d:00:00", ordinal % 24),
                                         nativeID: "native-other-\(ordinal)", title: "other",
                                         indexReady: true)
        }
        try fixture.write { db in
            let body = String(repeating: "history ", count: 65536)
            for ordinal in 0..<64 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: ["unrelated-\(ordinal)", body])
            }
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "history", limit: 50),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), ["keep"])
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(reads.pageReads, 32768,
                          "Owned MATCH page work including postings pageReads=\(reads.pageReads)")
    }

    func testSessionsOwnedMatchDoesNotReadUnrelatedFTSContentOverflow_repro() async throws {
        // Many MATCH hits with a page-filling content pad. Unhinted PK
        // lookup of sessions_fts_content is one leaf per hit; a same-tx
        // guarded covering (id,c0) hint must not pay that.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                     title: "history keep", indexReady: true)
        for ordinal in 0..<32 {
            try fixture.seedBoundSession(id: "other-\(ordinal)",
                                         start: String(format: "2026-09-02 %02d:00:00", ordinal % 24),
                                         nativeID: "native-other-\(ordinal)", title: "other",
                                         indexReady: true)
        }
        try fixture.write { db in
            // One "history" token per row plus ~3KB non-matching pad so
            // unhinted content-table PK lookups are one leaf per hit.
            // Repeated-token postings hid the covering-index delta.
            let body = "history " + String(repeating: "x", count: 3000)
            for ordinal in 0..<2048 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: [String(format: "f%04d", ordinal), body])
            }
            XCTAssertTrue(try FTSRebuildPolicy.hasOwnedContentIdentityIndex(db))
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "history", limit: 50),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), ["keep"])
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(
            reads.pageReads, 1536,
            "Unrelated FTS content-table c0 lookups must not be heap-scanned pageReads=\(reads.pageReads)")
    }

    func testSessionsOwnedMatchLiveRevalidationDoesNotMaterializeLargeFTSBodies() async throws {
        // Whole sessions() operation, including current per-item live
        // revalidation. Budget is total SQL page work (MATCH postings
        // included), not elimination of every FTS body read.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        var expected: [String] = []
        for ordinal in 0..<16 {
            let id = String(format: "keep-%02d", ordinal)
            expected.append(id)
            try fixture.seedBoundSession(id: id,
                                         start: String(format: "2026-09-03 12:%02d:00", ordinal),
                                         nativeID: "native-keep-\(ordinal)",
                                         title: "history keep \(ordinal)", indexReady: true)
        }
        try fixture.write { db in
            let body = String(repeating: "history ", count: 65536)
            for ordinal in 0..<64 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: ["unrelated-\(ordinal)", body])
            }
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "history", limit: 16),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), expected.reversed())
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(reads.pageReads, 32768,
                          "Whole-operation owned MATCH page work including postings pageReads=\(reads.pageReads)")
    }

    func testSessionsOwnedMatchDoesNotScanUnrelatedVisibleSessionOverflow_repro() async throws {
        // idx_sessions_visible does not cover s.id. A visible-first plan
        // heap-visits every visible row (including local-only) before the
        // sparse MATCH set. Hit-driven identity CROSS JOIN must not.
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                     title: "history keep", indexReady: true)
        for ordinal in 0..<64 {
            try fixture.seedBoundSession(id: "other-\(ordinal)",
                                         start: String(format: "2026-09-02 %02d:00:00", ordinal % 24),
                                         nativeID: "native-other-\(ordinal)", title: "other",
                                         indexReady: true)
            try fixture.seedLocalSession(id: "local-\(ordinal)")
        }
        try fixture.write { db in
            let overflow = String(repeating: "meta ", count: 16384)
            try db.execute(sql: "UPDATE sessions SET summary = ? WHERE id != ?",
                           arguments: [overflow, "keep"])
        }
        let reads = MetadataPageReadObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try reads.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "history", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), ["keep"])
        XCTAssertGreaterThan(reads.pageReads, 0, "The production database must be observed")
        XCTAssertLessThan(reads.pageReads, 2048,
                          "Unrelated visible overflow must not be heap-scanned pageReads=\(reads.pageReads)")
    }

    func testSessionsOwnedMatchAndShortLikeKeepsConjunction() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                     title: "history keep xy", indexReady: true)
        try fixture.seedBoundSession(id: "match-only", start: "2026-09-03 11:00:00",
                                     nativeID: "native-match", title: "history only", indexReady: true)
        try fixture.seedBoundSession(id: "like-only", start: "2026-09-03 10:00:00",
                                     nativeID: "native-like", title: "other xy", indexReady: true)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "history keep", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), ["keep"])
    }

    func testSessionsShortQueryDoesNotScanFTSLike_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "hit", start: "2026-09-03 12:00:00",
                                     title: "测试 keep", indexReady: true)
        try fixture.write { db in
            let body = String(repeating: "测试 ", count: 4096)
            for ordinal in 0..<32 {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: ["filler-\(ordinal)", body])
            }
            XCTAssertFalse(try db.tableExists("sqlite_stat1"), "fixture must stay statistics-free like HQ")
        }
        let statements = MetadataShortQueryStatements()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { db in
            db.trace(options: .statement) { event in
                if case .statement(let statement) = event { statements.record(statement.sql) }
            }
        }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "测试", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items, [])
        XCTAssertEqual(page.totalCount, 0)
        XCTAssertEqual(page.warningCode, "query_too_short")
        XCTAssertEqual(page.warning, "Use Search for 1-2 character filters (8s budget).")
        XCTAssertFalse(statements.values.contains { $0.contains("content LIKE") },
                       statements.values.joined(separator: "\n---\n"))
        XCTAssertFalse(statements.values.contains {
            $0.localizedCaseInsensitiveContains("like") && $0.contains("sessions_fts")
        }, statements.values.joined(separator: "\n---\n"))
    }

    func testSessionsOwnedMatchFallsBackWhenIdentityIndexIsAbsentOrWrong() async throws {
        for shape in ["absent", "wrong"] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                         title: "history keep", indexReady: true)
            try fixture.seedBoundSession(id: "other", start: "2026-09-03 11:00:00",
                                         nativeID: "native-other", title: "other", indexReady: true)
            try fixture.write { db in
                if shape == "absent" {
                    try db.execute(sql: "DROP INDEX idx_sessions_fts_content_identity")
                } else {
                    try db.execute(sql: "DROP INDEX idx_sessions_fts_content_identity")
                    try db.execute(sql: "CREATE INDEX idx_sessions_fts_content_identity ON sessions_fts_content(c0)")
                }
            }
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            let page = try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "history", limit: 20),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(page.items.map(\.sessionId), ["keep"], shape)
        }
    }

    func testSessionsOwnedMatchKeepsUnmappedHitWhenMappedRowMisses() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                     title: "zzzz", indexReady: true)
        try fixture.seedBoundSession(id: "other", start: "2026-09-03 11:00:00", nativeID: "native-other",
                                     title: "zzzz other", indexReady: true)
        try fixture.write { db in
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                           arguments: ["keep", "nope mapped"])
            try db.execute(sql: """
                INSERT INTO fts_map(session_id, msg_seq, fts_rowid)
                SELECT 'keep', 0, rowid FROM sessions_fts
                WHERE session_id = 'keep' AND content = 'nope mapped'
                """)
            try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                           arguments: ["keep", "engram unmapped hit"])
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "engram", limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map(\.sessionId), ["keep"])
    }

    func testSessionsMatchFallsBackWhenOwnedFTSDDLMismatches() async throws {
        for shape in ["reordered", "external"] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "keep", start: "2026-09-03 12:00:00",
                                         title: "keep", indexReady: true)
            try fixture.seedBoundSession(id: "extra", start: "2026-09-03 11:00:00", nativeID: "native-extra",
                                         title: "extra", indexReady: true)
            try fixture.write { db in
                try db.execute(sql: "DROP TABLE sessions_fts")
                try db.execute(sql: "DELETE FROM fts_map")
                if shape == "reordered" {
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE sessions_fts USING fts5(
                          content,
                          session_id UNINDEXED,
                          tokenize='trigram case_sensitive 0'
                        )
                        """)
                    try db.execute(sql: """
                        INSERT INTO sessions_fts(session_id, content) VALUES ('keep', 'ghost'), ('extra', 'extra')
                        """)
                } else {
                    try db.execute(sql: "CREATE TABLE fts_external(session_id TEXT, content TEXT)")
                    try db.execute(sql: """
                        INSERT INTO fts_external(session_id, content) VALUES ('keep', 'keep'), ('extra', 'extra')
                        """)
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE sessions_fts USING fts5(
                          session_id UNINDEXED,
                          content,
                          content='fts_external',
                          tokenize='trigram case_sensitive 0'
                        )
                        """)
                    try db.execute(sql: "INSERT INTO sessions_fts(sessions_fts) VALUES('rebuild')")
                }
            }
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            let query = shape == "reordered" ? "ghost" : "keep"
            let page = try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: query, limit: 20),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(page.items.map(\.sessionId), ["keep"], shape)
        }
    }

    func testAfterPreparationQueryMissOnCurrentPageItem_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "page-one", start: "2026-09-03 12:00:00",
                                     title: "shared one", indexReady: true)
        try fixture.seedBoundSession(id: "page-two", start: "2026-09-02 12:00:00", nativeID: "native-two",
                                     title: "shared two", indexReady: true)
        let mutation = MetadataPreparationMutation(operation: .sessions) {
            try fixture.write { db in
                try db.execute(sql: "DELETE FROM sessions_fts WHERE session_id = ?", arguments: ["page-two"])
            }
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }))
        defer { try? producer.stop() }
        let baseline = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "shared", limit: 2),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(baseline.items.map(\.sessionId)), ["page-one", "page-two"])
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 2),
                requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testAfterPreparationRevokesNonFirstCurrentPageItem_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "page-one", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "page-two", start: "2026-09-02 12:00:00", nativeID: "native-two")
        try fixture.seedBoundSession(id: "page-three", start: "2026-09-01 12:00:00", nativeID: "native-three")
        let policy = PolicyBox(validPolicy())
        let mutation = MetadataPreparationMutation(operation: .sessions) {
            try fixture.revoke(.hidden, sessionID: "page-three", policy: policy)
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                            policy: { try policy.current() })
        defer { try? producer.stop() }
        let baseline = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 3),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(baseline.items.map(\.sessionId), ["page-one", "page-two", "page-three"])
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 3),
                requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testSessionsBatchFreshnessPreservesBinarySessionIdentity_repro() async throws {
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: composed, start: "2026-09-03 12:00:00", nativeID: "native-composed")
        try fixture.seedBoundSession(id: decomposed, start: "2026-09-02 12:00:00", nativeID: "native-decomposed")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 2),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.map { Data($0.sessionId.utf8) },
                       [Data(composed.utf8), Data(decomposed.utf8)])
    }

    func testSnapshotTokenAndFilterCrosswireIsStale() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-03 12:00:00", title: "shared caf\u{e9}")
        try fixture.seedBoundSession(id: "two", start: "2026-09-02 12:00:00", nativeID: "native-two", title: "shared caf\u{e9}")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let fields = ["source", "sources", "machine", "instance", "project", "projectKeys", "sessionId",
                      "agents", "limit", "queryBytes", "snapshot", "token", "kind"]
        for field in fields {
            let base = try EngramServiceWebSessionsRequest(query: "shared caf\u{e9}", source: "claude-code",
                machineId: machine, sourceInstanceId: instance, projectKey: "project_1", limit: 1)
            let first = try await producer.sessions(base, requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(first.items.map(\.sessionId), ["one"], field)
            let originalCursor = try XCTUnwrap(first.nextCursor)
            var snapshotID = first.snapshotId
            var token = originalCursor
            if field == "snapshot" || field == "token" {
                let other = try await producer.sessions(base, requestId: requestId, deadline: fixture.deadline())
                XCTAssertNotEqual(other.snapshotId, first.snapshotId)
                let otherCursor = try XCTUnwrap(other.nextCursor)
                XCTAssertNotEqual(otherCursor, originalCursor)
                if field == "snapshot" { snapshotID = other.snapshotId } else { token = otherCursor }
            }
            if field == "kind" {
                snapshotID = try await producer.overview(try EngramServiceWebOverviewRequest(limit: 1),
                    requestId: requestId, deadline: fixture.deadline()).snapshotId
            }
            let request = try EngramServiceWebSessionsRequest(
                query: field == "queryBytes" ? "shared cafe\u{301}" : "shared caf\u{e9}",
                source: field == "sources" ? nil : (field == "source" ? "codex" : "claude-code"),
                sources: field == "sources" ? ["codex"] : nil,
                machineId: field == "machine" ? secondMachine : machine,
                sourceInstanceId: field == "instance" ? secondInstance : instance,
                projectKey: field == "projectKeys" ? nil : (field == "project" ? "project_2" : "project_1"),
                projectKeys: field == "projectKeys" ? ["project_2"] : nil,
                sessionId: field == "sessionId" ? "one" : nil,
                agents: field == "agents" ? .all : .hide,
                limit: field == "limit" ? 2 : 1, snapshotId: snapshotID, cursor: token)
            if field == "queryBytes" {
                XCTAssertNotEqual(Data(try XCTUnwrap(request.query).utf8), Data(try XCTUnwrap(base.query).utf8))
            }
            await assertStale(deadline: fixture.deadline()) {
                try await producer.sessions(request, requestId: requestId, deadline: fixture.deadline())
            }
        }
    }

    func testUnrelatedInsertStaysInvisibleOnHeldSnapshot() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "first", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "second", start: "2026-09-02 12:00:00", nativeID: "native-2")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                                requestId: requestId, deadline: fixture.deadline())
        let cursor = try XCTUnwrap(first.nextCursor)
        try fixture.seedBoundSession(id: "third", start: "2026-09-04 12:00:00", nativeID: "native-3")
        let next = try await producer.sessions(
            try EngramServiceWebSessionsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.sessionId), ["first"])
        XCTAssertEqual(next.items.map(\.sessionId), ["second"])
        XCTAssertFalse(next.items.map(\.sessionId).contains("third"))
        let frame = try ServiceWebMetadataProducer.encodedSuccessFrame(requestId: requestId, result: next)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        XCTAssertNil(object["database_generation"])
    }

    // MARK: - Leases / cursors

    func testHardExpiryFiresWithoutAnotherRequestAndIsNotRefreshedAt29s() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "first", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "second", start: "2026-09-02 12:00:00", nativeID: "native-2")
        try fixture.seedBoundSession(id: "third", start: "2026-09-01 12:00:00", nativeID: "native-3")
        XCTAssertTrue(try fixture.checkpoint().released)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                                requestId: requestId, deadline: fixture.deadline())
        let cursor = try XCTUnwrap(first.nextCursor)
        XCTAssertEqual(producer.retainedLeaseCount, 1)
        try fixture.touchWAL()
        XCTAssertTrue(try fixture.checkpoint().pinned)
        let originalTimer = try XCTUnwrap(fixture.clock.scheduledIDs.only)
        fixture.clock.advance(.seconds(29))
        let continued = try await producer.sessions(
            try EngramServiceWebSessionsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(continued.items.map(\.sessionId), ["second"])
        XCTAssertNotNil(continued.nextCursor)
        XCTAssertEqual(fixture.clock.scheduledIDs, [originalTimer], "Continuation must not reschedule expiry")
        XCTAssertEqual(producer.retainedLeaseCount, 1)
        XCTAssertTrue(try fixture.checkpoint().pinned)
        fixture.clock.advance(.seconds(1))
        XCTAssertEqual(fixture.clock.firedIDs, [originalTimer])
        try await assertWALReleased(fixture) // No client call between t=30 and resource proof.
        XCTAssertEqual(producer.retainedLeaseCount, 0)
        await assertStale(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
    }

    func testOldestSnapshotEvictionCursorCapAndReplay() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        for index in 0..<130 {
            try fixture.seedBoundSession(
                id: String(format: "s-%03d", index),
                start: String(format: "2026-09-01 %02d:%02d:00", index / 60, index % 60),
                nativeID: "native-\(index)", title: "row \(index) shared"
            )
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        var firstCursors: [(String, String)] = []
        for _ in 0..<9 {
            let page = try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 1),
                requestId: requestId, deadline: fixture.deadline())
            firstCursors.append((page.snapshotId, try XCTUnwrap(page.nextCursor)))
            fixture.clock.advance(.milliseconds(1)) // Unambiguous creation order, not a tied timestamp.
        }
        XCTAssertEqual(producer.retainedLeaseCount, 8)
        await assertStale(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 1,
                                                    snapshotId: firstCursors[0].0, cursor: firstCursors[0].1),
                requestId: requestId, deadline: fixture.deadline())
        }

        let retained = try await producer.sessions(try EngramServiceWebSessionsRequest(query: "shared", limit: 1,
            snapshotId: firstCursors[1].0, cursor: firstCursors[1].1), requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(retained.items.count, 1, "Evict only the oldest snapshot, not every snapshot")

        let walk = try await producer.sessions(
            try EngramServiceWebSessionsRequest(query: "shared", limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        var cursor = try XCTUnwrap(walk.nextCursor)
        let snapshot = walk.snapshotId
        let firstWalkCursor = cursor
        for _ in 0..<128 {
            let page = try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 1, snapshotId: snapshot, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
            let replay = try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 1, snapshotId: snapshot, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(page.nextCursor, replay.nextCursor)
            XCTAssertEqual(page.items, replay.items)
            XCTAssertEqual(page.snapshotId, replay.snapshotId)
            cursor = try XCTUnwrap(page.nextCursor)
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(query: "shared", limit: 1,
                                                    snapshotId: snapshot, cursor: firstWalkCursor),
                requestId: requestId, deadline: fixture.deadline())
        }

        try producer.stop()
        XCTAssertEqual(producer.retainedLeaseCount, 0)
    }

    func testCancellingOneExpiryTimerLeavesOtherProducerTimerAndWALLeaseAlive() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "a", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "b", start: "2026-09-02 12:00:00", nativeID: "native-b")
        XCTAssertTrue(try fixture.checkpoint().released)
        let firstProducer = try fixture.producer()
        defer { try? firstProducer.stop() }
        let first = try await firstProducer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertNotNil(first.nextCursor)
        let firstTimer = try XCTUnwrap(fixture.clock.scheduledIDs.only)
        fixture.clock.advance(.seconds(5))
        let other = try fixture.producer()
        defer { try? other.stop() }
        let second = try await other.sessions(try EngramServiceWebSessionsRequest(limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertNotNil(second.nextCursor)
        let otherTimer = try XCTUnwrap(fixture.clock.scheduledIDs.subtracting([firstTimer]).only)
        try fixture.touchWAL()
        XCTAssertTrue(try fixture.checkpoint().pinned)
        try firstProducer.stop()
        XCTAssertTrue(fixture.clock.cancelledIDs.contains(firstTimer))
        XCTAssertFalse(fixture.clock.cancelledIDs.contains(otherTimer))
        XCTAssertEqual(fixture.clock.scheduledIDs, [otherTimer])
        XCTAssertTrue(try fixture.checkpoint().pinned, "The other snapshot must still hold WAL")
        fixture.clock.advance(.seconds(25))
        XCTAssertTrue(fixture.clock.firedIDs.isEmpty)
        XCTAssertTrue(try fixture.checkpoint().pinned)
        fixture.clock.advance(.seconds(5))
        XCTAssertEqual(fixture.clock.firedIDs, [otherTimer])
        try await assertWALReleased(fixture)
    }

    func testStopAndWeakDeinitIndependentlyReleaseActualWALSnapshots() async throws {
        for closeExplicitly in [true, false] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "a", start: "2026-09-03 12:00:00")
            try fixture.seedBoundSession(id: "b", start: "2026-09-02 12:00:00", nativeID: "native-b")
            XCTAssertTrue(try fixture.checkpoint().released)
            var producer: ServiceWebMetadataProducer? = try fixture.producer()
            weak var weakProducer = producer
            defer { try? producer?.stop() }
            let page = try await producer!.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertNotNil(page.nextCursor)
            try fixture.touchWAL()
            XCTAssertTrue(try fixture.checkpoint().pinned)
            if closeExplicitly { try producer?.stop() }
            producer = nil
            XCTAssertNil(weakProducer, "Expiry callbacks must not retain the producer")
            try await assertWALReleased(fixture)
            XCTAssertTrue(fixture.clock.scheduledIDs.isEmpty)
        }
    }

    func testUnknownCursorIsStale() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "a", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "b", start: "2026-09-02 12:00:00", nativeID: "native-b")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.sessions(
                try EngramServiceWebSessionsRequest(limit: 1, snapshotId: requestId, cursor: "opaque_token"),
                requestId: requestId, deadline: fixture.deadline())
        }
    }

    // MARK: - Authority recheck

    func testIndependentAfterPreparationRevocationsOnFirstPage() async throws {
        try await assertPreparationRevocations(surface: .firstPage)
    }

    func testIndependentAfterPreparationRevocationsOnLeasedLaterPage() async throws {
        try await assertPreparationRevocations(surface: .laterPage)
    }

    func testIndependentAfterPreparationRevocationsOnDetail() async throws {
        try await assertPreparationRevocations(surface: .detail)
    }

    private enum PreparationSurface: Equatable { case firstPage, laterPage, detail }

    private func assertPreparationRevocations(surface: PreparationSurface) async throws {
        for fault in MetadataAuthorityFault.allCases {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "page-one", start: "2026-09-03 12:00:00", indexReady: true)
            try fixture.seedBoundSession(id: "page-two", start: "2026-09-02 12:00:00", nativeID: "native-two", indexReady: true)
            try fixture.seedLocalSession(id: "parent")
            let target = surface == .laterPage ? "page-two" : "page-one"
            let policy = PolicyBox(validPolicy())
            let mutation = MetadataPreparationMutation(operation: surface == .detail ? .detail : .sessions) {
                try fixture.revoke(fault, sessionID: target, policy: policy)
            }
            let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                                policy: { try policy.current() })
            defer { try? producer.stop() }
            // Each case starts positive and unmixed; mutation is armed ONLY
            // after baseline calls complete, never before a request's entry.
            let first = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(first.items.map(\.sessionId), ["page-one"], "\(surface)/\(fault)")
            let cursor = try XCTUnwrap(first.nextCursor)
            let baseline = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: target),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(baseline.detail?.session.sessionId, target, "\(surface)/\(fault)")
            mutation.arm()
            if surface == .detail {
                if fault == .missingPolicy {
                    do {
                        _ = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: target),
                            requestId: requestId, deadline: fixture.deadline())
                        XCTFail("Missing current policy must be unavailable")
                    } catch { XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable) }
                } else {
                    let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: target),
                        requestId: requestId, deadline: fixture.deadline())
                    XCTAssertNil(detail.detail, "Excluded detail must be nil: \(fault)")
                }
            } else {
                let request = try EngramServiceWebSessionsRequest(limit: 1,
                    snapshotId: surface == .laterPage ? first.snapshotId : nil,
                    cursor: surface == .laterPage ? cursor : nil)
                await assertStaleOrUnavailable(deadline: fixture.deadline()) {
                    try await producer.sessions(request, requestId: requestId, deadline: fixture.deadline())
                }
            }
            XCTAssertEqual(mutation.entryCount, 1, "\(surface)/\(fault) never reached the required post-preparation hook")
        }
    }

    func testHidingAlreadyReturnedPageOneDoesNotAffectPageTwo() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "page-one", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "page-two", start: "2026-09-02 12:00:00", nativeID: "native-two")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let first = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.sessionId), ["page-one"])
        let cursor = try XCTUnwrap(first.nextCursor)
        try fixture.hide("page-one")
        let second = try await producer.sessions(
            try EngramServiceWebSessionsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.items.map(\.sessionId), ["page-two"])
    }

    func testReadyCounterPositiveBaselineThenOneScalarFaultAtATime() async throws {
        for fault in MetadataReadyScalarFault.allCases {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "ready", start: "2026-09-03 12:00:00", indexReady: true)
            let producer = try fixture.producer()
            defer { try? producer.stop() }
            let before = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(before.streams.count, 1, "\(fault)")
            XCTAssertEqual(before.streams.first?.fts?.readyLogicalSessions, 1, "Invalid baseline for \(fault)")
            try fixture.mutateReadyScalar(fault)
            let after = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(after.streams.compactMap { $0.fts?.readyLogicalSessions }.reduce(0, +), 0, "\(fault)")
        }
    }

    func testReadyCounterRechecksCallableParserAndEnabledSourcePolicy() async throws {
        for parserChanged in [true, false] {
            let fixture = try MetadataSQLFixture()
            defer { fixture.remove() }
            try fixture.migrate()
            try fixture.seedRegistry()
            try fixture.seedBoundSession(id: "ready", start: "2026-09-03 12:00:00", indexReady: true)
            let policy = PolicyBox(validPolicy())
            let producer = try fixture.producer(policy: { try policy.current() })
            defer { try? producer.stop() }
            let before = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(before.streams.first?.fts?.readyLogicalSessions, 1)
            policy.policy = parserChanged ? .init(parserRevision: "parser-v2", enabledSources: [.claudeCode])
                : .init(parserRevision: parser, enabledSources: [.codex])
            let after = try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: requestId, deadline: fixture.deadline())
            if parserChanged { XCTAssertEqual(after.streams.first?.fts?.readyLogicalSessions, 0) }
            else { XCTAssertTrue(after.streams.isEmpty) }
        }
    }

    func testDivergentHeadsAreMetadataOnlyNeverTranscriptAuthority() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "heads", start: "2026-09-07 12:00:00", nativeID: "native-heads",
                                     divergeHeads: true)
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
                                               deadline: fixture.deadline())
        XCTAssertEqual(page.streams.first?.fts?.readyLogicalSessions, 0)
        let fake = try await producer.sessionDetail(
            try EngramServiceWebSessionDetailRequest(sessionId: "heads"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(fake.detail?.transcriptAvailability, .unavailable)
        XCTAssertNil(fake.detail?.transcriptGeneration)
        XCTAssertNotEqual(fake.detail?.lastParsed?.generationId, fake.detail?.lastReady?.generationId)
    }

    func testLargeStorageGenerationMetadataUsesTheFullMessageCount() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "large", start: "2026-09-03 12:00:00", indexReady: true)
        // This verifies metadata projection only; message-row admission is covered by the real transcript provider.
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE capture_ingest_generations SET normalized_storage_version = 2,
                    normalized_message_count = 0, normalized_total_message_count = 10001
                """)
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let response = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: "large"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(response.detail?.lastParsed?.normalizedMessageCount, 10_001)
        XCTAssertEqual(response.detail?.lastReady?.normalizedMessageCount, 10_001)
        try assertRoundTrip(response)
    }

    func testMetadataScalarsDoNotReadOpaqueCorruptedBLOBs() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "ready", start: "2026-09-03 12:00:00", indexReady: true)
        let observer = MetadataSQLObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try observer.install($0) }))
        defer { try? producer.stop() }
        let before = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(before.streams.first?.fts?.readyLogicalSessions, 1)
        // Explicitly corrupted opaque BLOB fixture, NOT a valid ingestion/readiness baseline.
        try fixture.write { db in
            try db.execute(sql: "UPDATE capture_ingest_publications SET canonical_bytes = x'00'")
            try db.execute(sql: "UPDATE capture_ingest_generations SET manifest_json = x'00', normalized_messages_json = x'00'")
        }
        let after = try await producer.overview(try EngramServiceWebOverviewRequest(),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(after.streams.first?.fts?.readyLogicalSessions, 1)
        let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: "ready"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(detail.detail?.session.sessionId, "ready")
        XCTAssertEqual(detail.detail?.transcriptAvailability, .unavailable)
        XCTAssertNil(detail.detail?.transcriptGeneration)
        try observer.assertConnections(requireSnapshot: true)
        XCTAssertEqual(observer.productionDenials, 0)
    }

    // MARK: - Redaction

    func testNaturalLanguagePasswordInExistingTitleIsRedactedOnRead() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "password-title", start: "2026-09-06 12:00:00",
            title: "Check disk usage; sudo 密码是Example#4821，请继续")
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.first?.title, "Check disk usage; [REDACTED]，请继续")
    }

    func testRedactionThenPathFenceAndProjectKeyOmission() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "pure-secret", start: "2026-09-06 12:00:00",
                                     project: "project_1", title: "token=sk-abcdefghijklmnop")
        try fixture.seedBoundSession(id: "secret-path", start: "2026-09-05 12:00:00", nativeID: "native-sp",
                                     project: "api_key=sk-abcdefghijklmnop",
                                     title: "token=sk-abcdefghijklmnop /Users/fixture/sessions/log.jsonl")
        try fixture.seedBoundSession(id: "path-only", start: "2026-09-04 12:00:00", nativeID: "native-path",
                                     project: "/Users/fixture/sessions", title: "/Users/fixture/sessions/log.jsonl")
        try fixture.seedBoundSession(id: "oversize", start: "2026-09-03 12:00:00", nativeID: "native-over",
                                     title: String(repeating: "中", count: 400))
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 10),
                                               requestId: requestId, deadline: fixture.deadline())
        let secret = try XCTUnwrap(page.items.first { $0.sessionId == "pure-secret" })
        XCTAssertEqual(secret.title?.contains(TranscriptRedactionPolicy.redactionToken), true)
        XCTAssertFalse(secret.title?.contains("sk-") == true)
        XCTAssertEqual(secret.projectKey, "project_1")
        XCTAssertEqual(secret.projectLabel, "project_1")
        let secretPath = try XCTUnwrap(page.items.first { $0.sessionId == "secret-path" })
        XCTAssertNil(secretPath.title)
        XCTAssertEqual(secretPath.projectKey, Self.opaqueProjectKey("api_key=sk-abcdefghijklmnop"))
        XCTAssertFalse(secretPath.projectKey?.contains("sk-") == true)
        XCTAssertFalse(secretPath.projectLabel?.contains("sk-") == true)
        let path = try XCTUnwrap(page.items.first { $0.sessionId == "path-only" })
        XCTAssertNil(path.title)
        XCTAssertEqual(path.projectKey, Self.opaqueProjectKey("/Users/fixture/sessions"))
        XCTAssertFalse(path.projectKey?.contains("/") == true)
        XCTAssertEqual(path.projectLabel, "sessions")
        XCTAssertFalse(path.projectLabel?.contains("/") == true)
        let oversize = try XCTUnwrap(page.items.first { $0.sessionId == "oversize" })
        XCTAssertNil(oversize.title)
        try assertRoundTrip(page)
    }

    func testRedactionFullStringBeforeNULAndExactUTF8ByteFencesWithoutFallback() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let titleLimit = String(repeating: "中", count: 341) + "a"
        let labelLimit = String(repeating: "中", count: 85) + "a"
        XCTAssertEqual(titleLimit.utf8.count, 1024)
        XCTAssertEqual(labelLimit.utf8.count, 256)
        let titleCrossing = String(repeating: "x", count: 1000) + " github_pat_" + String(repeating: "s", count: 60)
        let labelCrossing = String(repeating: "x", count: 230) + " github_pat_" + String(repeating: "s", count: 60)
        XCTAssertGreaterThan(titleCrossing.utf8.count, 1024)
        XCTAssertGreaterThan(labelCrossing.utf8.count, 256)
        // At each byte boundary the secret suffix is below the regex minimum;
        // truncating first would leak an unrecognized token prefix.
        let redactedTitle = String(repeating: "x", count: 1000) + " [REDACTED]"
        let redactedLabel = String(repeating: "x", count: 230) + " [REDACTED]"
        XCTAssertEqual(TranscriptRedactionPolicy.redact(titleCrossing), redactedTitle)
        XCTAssertEqual(TranscriptRedactionPolicy.redact(labelCrossing), redactedLabel)
        let changedValidToken = "ghp_abcdefghijklmnopqrst"
        let rows: [(id: String, title: String?, project: String?, expectedTitle: String?, expectedLabel: String?, key: String?)] = [
            ("limit", titleLimit, labelLimit, titleLimit, labelLimit, Self.opaqueProjectKey(labelLimit)),
            ("over", titleLimit + "b", labelLimit + "b", nil, "Project", Self.opaqueProjectKey(labelLimit + "b")),
            ("nul", "safe\u{0}secret", "safe\u{0}secret", nil, "Project", nil),
            ("crossing", titleCrossing, labelCrossing, redactedTitle, redactedLabel, Self.opaqueProjectKey(labelCrossing)),
            ("valid-key", "safe", "project_1", "safe", "project_1", "project_1"),
            ("changed-token", "safe", changedValidToken, "safe", "[REDACTED]", Self.opaqueProjectKey(changedValidToken)),
            ("unsafe", "/Users/fixture/private.jsonl", "/Users/fixture/private", nil, "private",
             Self.opaqueProjectKey("/Users/fixture/private")),
            ("absent", nil, nil, nil, nil, nil),
        ]
        for row in rows {
            try fixture.seedBoundSession(id: row.id, start: "2026-09-03 12:00:00", nativeID: "native-\(row.id)",
                                         project: row.project, title: row.title)
        }
        try fixture.write { db in
            // GRDB binds String as NUL-terminated text. Bind bytes explicitly
            // so this fixture exercises a full SQLite TEXT value containing NUL.
            let nulBytes = Data("safe\u{0}secret".utf8)
            try db.execute(sql: """
                UPDATE sessions SET generated_title = CAST(? AS TEXT), project = CAST(? AS TEXT)
                WHERE id = 'nul'
                """, arguments: [nulBytes, nulBytes])
            let stored = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT hex(CAST(generated_title AS BLOB)) AS title_bytes,
                    hex(CAST(project AS BLOB)) AS project_bytes,
                    typeof(generated_title) AS title_type, typeof(project) AS project_type
                FROM sessions WHERE id = 'nul'
                """))
            XCTAssertEqual(stored["title_bytes"] as String, "7361666500736563726574", "fixture must contain the full NUL string")
            XCTAssertEqual(stored["project_bytes"] as String, "7361666500736563726574", "fixture must contain the full NUL string")
            XCTAssertEqual(stored["title_type"] as String, "text")
            XCTAssertEqual(stored["project_type"] as String, "text")
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.items.count, rows.count)
        for row in rows {
            let item = try XCTUnwrap(page.items.first { $0.sessionId == row.id })
            XCTAssertEqual(item.title, row.expectedTitle, row.id)
            XCTAssertEqual(item.projectLabel, row.expectedLabel, row.id)
            XCTAssertEqual(item.projectKey, row.key, row.id)
            let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: row.id),
                requestId: requestId, deadline: fixture.deadline())
            XCTAssertEqual(detail.detail?.session, item, row.id)
        }
        try assertRoundTrip(page)
    }

    func testSnapshotTransactionEndsBeforeConnectionCloseForDetailAndStop() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "one", start: "2026-09-03 12:00:00")
        try fixture.seedBoundSession(id: "two", start: "2026-09-02 12:00:00", nativeID: "native-two")
        let lifecycle = MetadataSnapshotLifecycleObserver()
        let producer = try fixture.producer(hooks: .init(prepareDatabase: { try lifecycle.install($0) }))
        defer { try? producer.stop() }
        let page = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertNotNil(page.nextCursor)
        let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: "one"),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(detail.detail?.session.sessionId, "one")
        try producer.stop()
        lifecycle.assertClosedSnapshots(2)
    }

    // MARK: - Cancel / envelope

    func testDeterministicSelfPrecancelNeverEntersSnapshotOrSQL() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "row", start: "2026-09-03 12:00:00")

        let entries = LockedValue(0)
        let precancelled = try fixture.producer(hooks: .init(inDatabaseOperation: { _, _ in
            entries.update { $0 += 1 }
        }))
        defer { try? precancelled.stop() }
        let pre = Task {
            withUnsafeCurrentTask { $0?.cancel() } // Cancellation is established before the call, not raced from outside.
            return try await precancelled.overview(try EngramServiceWebOverviewRequest(),
                                            requestId: self.requestId, deadline: fixture.deadline())
        }
        do {
            _ = try await pre.value
            XCTFail("precancel must not succeed")
        } catch is CancellationError {
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        XCTAssertEqual(entries.value, 0)
        XCTAssertEqual(precancelled.retainedLeaseCount, 0)
    }

    func testEnteredSnapshotCreationSQLiteCancellationIsInterruptedAndJoined() async throws {
        try await assertEnteredSQLTermination(.snapshotConnectionSetup, termination: .cancel)
    }

    func testEnteredSnapshotReadSQLiteCancellationIsInterruptedAndJoined() async throws {
        try await assertEnteredSQLTermination(.snapshotRead, termination: .cancel)
    }

    func testEnteredSnapshotCreationSQLiteDeadlineIsInterruptedAndJoined() async throws {
        try await assertEnteredSQLTermination(.snapshotConnectionSetup, termination: .deadline)
    }

    func testEnteredSnapshotReadSQLiteDeadlineIsInterruptedAndJoined() async throws {
        try await assertEnteredSQLTermination(.snapshotRead, termination: .deadline)
    }

    func testStopJoinsEnteredSnapshotCreationSQLiteWork() async throws {
        try await assertEnteredSQLTermination(.snapshotConnectionSetup, termination: .stop)
    }

    func testStopJoinsEnteredSnapshotReadSQLiteWork() async throws {
        try await assertEnteredSQLTermination(.snapshotRead, termination: .stop)
    }

    private enum SQLTermination: Equatable { case cancel, deadline, stop }

    private func assertEnteredSQLTermination(_ phase: ServiceWebMetadataDatabasePhase,
                                             termination: SQLTermination) async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "row", start: "2026-09-03 12:00:00")
        let entered = expectation(description: "\(phase) executing SQLite UDF")
        let probe = MetadataSQLWorkProbe(phase: phase, entered: entered)
        let producer = try fixture.producer(hooks: .init(inDatabaseOperation: { try probe.run($0, db: $1) }),
                                            liveClock: true)
        defer { probe.unblock(); try? producer.stop() }
        let requestReturned = LockedValue(false)
        let began = ContinuousClock.now
        let deadline = began + (termination == .deadline ? .seconds(1) : .seconds(2))
        let task = Task.detached {
            defer { requestReturned.update { $0 = true } }
            return try await producer.overview(try EngramServiceWebOverviewRequest(),
                requestId: self.requestId, deadline: deadline)
        }
        defer { task.cancel(); probe.unblock() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(probe.didEnterSQL, "A pre-entry cancellation or notImplemented error is not this test's evidence")
        var stopReturned = false
        if probe.didEnterSQL {
            switch termination {
            case .cancel: task.cancel()
            case .deadline: break // Real producer deadline must interrupt; probe never calls interrupt/progress APIs.
            case .stop:
                let stopper = Task.detached {
                    try producer.stop()
                    XCTAssertTrue(probe.didExitSQL, "stop returned while SQLite work was still entered")
                }
                let stopped = await stopper.result
                switch stopped {
                case .success: stopReturned = true
                case .failure(let error): XCTFail("stop failed: \(error)")
                }
            }
        } else {
            task.cancel()
            probe.unblock()
        }
        let outcome = await task.result // Always join, including failed entry instrumentation.
        switch outcome {
        case .success: XCTFail("Entered cancelled/timed-out/stopped work must not produce a response")
        case .failure(let error):
            if termination == .deadline {
                XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
            } else {
                XCTAssertTrue(error is CancellationError || (error as? ServiceWebMetadataError) == .unavailable,
                              "Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(requestReturned.value)
        XCTAssertTrue(probe.didExitSQL)
        XCTAssertEqual(probe.sqliteResult, SQLITE_INTERRUPT, "Post-query cancellation or watchdog SQLITE_ERROR is insufficient")
        XCTAssertFalse(probe.watchdogFired)
        XCTAssertLessThanOrEqual(try XCTUnwrap(probe.sqlDuration), .seconds(2))
        if termination == .stop { XCTAssertTrue(stopReturned) }
        // This bounds cooperative SQLite work, not synchronous kernel I/O or
        // main-thread scheduling. No impossible OS-blocked wall-clock guarantee.
        try producer.stop()
        try await assertWALReleased(fixture)
    }

    func testDeadlineUsesInjectedClock() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        await assertUnavailable(producer, deadline: fixture.clock.now() - .seconds(1))
    }

    func testValidDTORoundTripsAndFullEnvelopeShrinksWithoutLossOnOneSnapshot() async throws {
        let summaries = (0..<100).map { index in
            EngramServiceWebSessionSummary(
                sessionId: String(format: "%03d-", index) + String(repeating: "s", count: 1800),
                source: "claude-code",
                captureIdentity: .init(machineId: machine, sourceInstanceId: instance),
                metadataGeneration: String(repeating: "a", count: 64),
                title: String(repeating: "t", count: 1024),
                projectKey: "project_1",
                projectLabel: "project_1",
                startedAt: 1_788_660_000
            )
        }
        for summary in summaries { try assertRoundTrip(summary) }
        let unshrunk = EngramServiceWebSessionsResponse(
            snapshotId: requestId, observedAt: 1, items: summaries, nextCursor: "next_token")
        try assertRoundTrip(unshrunk)
        let unshrunkFrame = try ServiceWebMetadataProducer.encodedSuccessFrame(requestId: requestId, result: unshrunk)
        XCTAssertGreaterThan(unshrunkFrame.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)

        // With the frozen summary DTO maxima, even worst-case JSON escaping
        // cannot make a single legal item exceed 261120 bytes. This bounds the
        // case; it is NOT a test of producer rejection of an illegal fake DTO.
        let maxItem = EngramServiceWebSessionSummary(
            sessionId: String(repeating: "\u{1}", count: 4096), source: "claude-code",
            captureIdentity: .init(machineId: machine, sourceInstanceId: instance),
            metadataGeneration: String(repeating: "a", count: 64),
            title: String(repeating: "\u{1}", count: 1024), projectKey: String(repeating: "p", count: 128),
            projectLabel: String(repeating: "\u{1}", count: 256), startedAt: 253_402_300_799)
        try assertRoundTrip(maxItem)
        let one = EngramServiceWebSessionsResponse(
            snapshotId: requestId, observedAt: 1, items: [maxItem], nextCursor: nil)
        try assertRoundTrip(one)
        let oneFrame = try ServiceWebMetadataProducer.encodedSuccessFrame(requestId: requestId, result: one)
        XCTAssertLessThan(oneFrame.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)

        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        var expected = Set<String>()
        for index in 0..<100 {
            let id = String(format: "%03d-", index) + String(repeating: "s", count: 1800)
            expected.insert(id)
            try fixture.seedBoundSession(
                id: id, start: String(format: "2026-09-01 00:%02d:00", index % 60),
                nativeID: "native-env-\(index)", title: String(repeating: "t", count: 1024)
            )
        }
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        var seen = Set<String>()
        var request = try EngramServiceWebSessionsRequest(limit: 100)
        var pages = 0
        var heldSnapshot: String?
        var reachedEnd = false
        while pages < 32 {
            let page = try await producer.sessions(request, requestId: requestId, deadline: fixture.deadline())
            let frame = try ServiceWebMetadataProducer.encodedSuccessFrame(requestId: requestId, result: page)
            XCTAssertLessThanOrEqual(frame.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
            try assertRoundTrip(page)
            XCTAssertFalse(page.items.isEmpty, "A successful shrinking page must make progress")
            if pages == 0 {
                heldSnapshot = page.snapshotId
                XCTAssertLessThan(page.items.count, 100)
                XCTAssertNotNil(page.nextCursor)
            } else {
                XCTAssertEqual(page.snapshotId, heldSnapshot)
            }
            let ids = page.items.map(\.sessionId)
            XCTAssertEqual(Set(ids).count, ids.count)
            XCTAssertTrue(seen.isDisjoint(with: Set(ids)))
            seen.formUnion(ids)
            pages += 1
            guard let cursor = page.nextCursor else { reachedEnd = true; break }
            request = try EngramServiceWebSessionsRequest(
                limit: 100, snapshotId: page.snapshotId, cursor: cursor)
        }
        XCTAssertEqual(seen, expected)
        XCTAssertGreaterThan(pages, 1)
        XCTAssertTrue(reachedEnd)
    }

    // MARK: - D2 search / status

    func testSearchStatusProgressCountsAuthorizedSessionsAndOmitsUnknown_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedBoundSession(id: "mixed", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-mixed", title: "mixed session")
        try fixture.seedBoundSession(id: "lite", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-lite", title: "lite session", tier: "lite")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-skip", title: "skip session", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-hidden", title: "hidden session", hidden: true)
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-tool", title: "tool only")
        try fixture.seedBoundSession(id: "ghost", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-ghost", machine: secondMachine, instance: secondInstance,
                                     title: "unauthorized better")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
        }
        let noMeta = try fixture.producer()
        defer { try? noMeta.stop() }
        let omitted = try await noMeta.searchStatus(try EngramServiceWebSearchStatusRequest(),
                                                    requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(omitted.keyword, .available)
        XCTAssertEqual(omitted.semantic, .unavailable)
        XCTAssertEqual(omitted.hybrid, .unavailable)
        XCTAssertEqual(omitted.warningCode, "embeddingProviderUnavailable")
        XCTAssertEqual(omitted.eligibleSessionCount, 3)
        XCTAssertNil(omitted.embeddedSessionCount)
        XCTAssertNil(omitted.progressPercent)
        XCTAssertNil(omitted.model)
        let encoded = try JSONEncoder().encode(omitted)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["embeddedSessionCount"])
        XCTAssertNil(object["progressPercent"])

        try fixture.seedEmbeddingMeta(model: "probe")
        try fixture.seedSemanticChunk(sessionID: "keep", model: "probe", vector: [1, 0, 0],
                                      text: "keep vector memory")
        try fixture.seedSemanticChunk(sessionID: "ghost", model: "probe", vector: [1, 0, 0],
                                      text: "unauthorized better vector")
        try fixture.seedSemanticChunk(sessionID: "hidden", model: "probe", vector: [1, 0, 0],
                                      text: "hidden better vector")
        let env = isolatedEmbeddingEnv(apiKey: "test")
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let status = try await producer.searchStatus(try EngramServiceWebSearchStatusRequest(),
                                                     requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(status.eligibleSessionCount, 3)
        XCTAssertEqual(status.embeddedSessionCount, 1)
        XCTAssertEqual(status.progressPercent, 33)
        XCTAssertEqual(status.keyword, .available)
        XCTAssertEqual(status.semantic, .available)
        XCTAssertEqual(status.hybrid, .available)
        XCTAssertEqual(status.model, "probe")
        XCTAssertEqual(status.dimension, 3)
        let hiddenTools = try await producer.searchStatus(
            try EngramServiceWebSearchStatusRequest(tools: .hide),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(hiddenTools.eligibleSessionCount, 2)
        XCTAssertEqual(hiddenTools.embeddedSessionCount, 1)
        XCTAssertEqual(hiddenTools.progressPercent, 50)
    }

    func testSearchStatusDoesNotInvokeEmbeddingFactory_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedEmbeddingMeta(model: "probe")
        try fixture.seedSemanticChunk(sessionID: "keep", model: "probe", vector: [1, 0, 0],
                                      text: "keep vector memory")
        let counter = SearchEmbedCounter()
        let env = isolatedEmbeddingEnv(apiKey: "test")
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let provider = try searchProvider(databasePath: fixture.path, environment: env, counter: counter)
        let status = try await producer.searchStatus(try EngramServiceWebSearchStatusRequest(),
                                                     requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(status.semantic, .available)
        let afterStatus = await counter.count()
        XCTAssertEqual(afterStatus, 0)
        let keyword = try await performSearch(
            producer: producer, provider: provider,
            request: EngramServiceWebSearchRequest(query: "alpha searchable"))
        XCTAssertEqual(keyword.items.map(\.session.sessionId), ["keep"])
        XCTAssertEqual(keyword.searchModes, ["keyword"])
        XCTAssertNil(keyword.warning)
        let afterKeyword = await counter.count()
        XCTAssertEqual(afterKeyword, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(keyword)) as? [String: Any])
        XCTAssertNil(object["totalCount"])
        XCTAssertNil(object["nextCursor"])
    }

    func testSemanticSearchUsesInjectedProviderOnceAndExcludesUnauthorizedHits_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedBoundSession(id: "lite", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-lite", title: "lite vector", tier: "lite")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-skip", title: "skip vector", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-hidden", title: "hidden vector", hidden: true)
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-tool", title: "tool vector")
        try fixture.seedBoundSession(id: "before", start: Self.sqliteUTC(localDate: "2026-09-06"),
                                     nativeID: "native-before", title: "old vector")
        try fixture.seedBoundSession(id: "ghost", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-ghost", machine: secondMachine, instance: secondInstance,
                                     title: "unauthorized vector")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
        }
        try fixture.seedEmbeddingMeta(model: "probe")
        try fixture.seedSemanticChunk(sessionID: "keep", model: "probe", vector: [0.2, 0.98, 0],
                                      text: "keep weaker vector memory")
        for id in ["lite", "skip", "hidden", "tool-only", "before", "ghost"] {
            try fixture.seedSemanticChunk(sessionID: id, model: "probe", vector: [1, 0, 0],
                                          text: "perfect unauthorized vector memory")
        }
        let counter = SearchEmbedCounter()
        let env = isolatedEmbeddingEnv(apiKey: "test")
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let provider = try searchProvider(databasePath: fixture.path, environment: env, counter: counter)
        let request = try EngramServiceWebSearchRequest(
            query: "vector memory", since: "2026-09-07", until: "2026-09-07",
            tools: .hide, mode: .semantic, limit: 10)
        let result = try await performSearch(producer: producer, provider: provider, request: request)
        XCTAssertEqual(result.items.map(\.session.sessionId), ["keep"])
        XCTAssertEqual(result.items.first?.matchType, "semantic")
        XCTAssertEqual(result.searchModes, ["semantic"])
        let afterSemantic = await counter.count()
        XCTAssertEqual(afterSemantic, 1)
        XCTAssertNil(result.warning)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertNil(object["totalCount"])
    }

    func testSemanticDegradesWithoutFactoryWhenProviderMissing_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedEmbeddingMeta(model: "probe")
        try fixture.seedSemanticChunk(sessionID: "keep", model: "probe", vector: [1, 0, 0],
                                      text: "keep vector memory")
        let counter = SearchEmbedCounter()
        let env = isolatedEmbeddingEnv()
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let provider = try searchProvider(databasePath: fixture.path, environment: env, counter: counter)
        let result = try await performSearch(
            producer: producer, provider: provider,
            request: EngramServiceWebSearchRequest(query: "alpha searchable", mode: .semantic))
        XCTAssertEqual(result.items.map(\.session.sessionId), ["keep"])
        XCTAssertEqual(result.searchModes, ["keyword"])
        XCTAssertEqual(result.warningCode, "embeddingProviderUnavailable")
        XCTAssertEqual(result.items.first?.matchType, "keyword")
        let afterDegrade = await counter.count()
        XCTAssertEqual(afterDegrade, 0)
    }

    func testSearchDateAndToolsFencesExcludeToolOnlyAndOutOfRange_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     title: "alpha searchable")
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: "2026-09-07"),
                                     nativeID: "native-tool", title: "alpha searchable tools")
        try fixture.seedBoundSession(id: "before", start: Self.sqliteUTC(localDate: "2026-09-06"),
                                     nativeID: "native-before", title: "alpha searchable before")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
        }
        let env = isolatedEmbeddingEnv()
        let producer = try fixture.producer(embeddingEnvironment: env)
        defer { try? producer.stop() }
        let provider = try searchProvider(databasePath: fixture.path, environment: env, counter: SearchEmbedCounter())
        let result = try await performSearch(
            producer: producer, provider: provider,
            request: EngramServiceWebSearchRequest(
                query: "alpha searchable", since: "2026-09-07", until: "2026-09-07", tools: .hide))
        XCTAssertEqual(result.items.map(\.session.sessionId), ["keep"])
        XCTAssertEqual(result.searchModes, ["keyword"])
    }

    func testScopedSearchDeadlineCancelsAndJoinsInjectedSlowProvider_repro() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-d2-search-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("index.sqlite").path
        try EngramDatabaseWriter(path: dbPath).migrate()
        let entered = expectation(description: "scoped search entered")
        let cancelled = expectation(description: "scoped search observed cancel")
        let exited = expectation(description: "scoped search exited")
        let provider = SlowScopedSearchProvider(entered: entered, cancelled: cancelled, exited: exited)
        let producer = ImmediateScopeProducer()
        let gate = try ServiceWriterGate(databasePath: dbPath, runtimeDirectory: root)
        let handler = EngramServiceCommandHandler(
            writerGate: gate,
            webMetadataProducer: producer,
            readProvider: provider
        )
        let envelope = EngramServiceRequestEnvelope(
            requestId: requestId,
            command: "webSearch",
            payload: try JSONEncoder().encode(
                try EngramServiceWebSearchRequest(query: "alpha searchable", mode: .semantic)
            ),
            capabilityToken: nil
        )
        let began = ContinuousClock.now
        let response = await handler.webSearchResponse(
            envelope, deadline: began + .milliseconds(150)
        )
        XCTAssertLessThan(began.duration(to: .now), .seconds(1))
        await fulfillment(of: [entered, cancelled, exited], timeout: 1)
        XCTAssertTrue(provider.didEnter)
        XCTAssertTrue(provider.didCancel)
        XCTAssertTrue(provider.didExit)
        XCTAssertFalse(producer.didAdmit)
        guard case .failure(_, let error) = response else {
            return XCTFail("Deadline must fail closed, not return ranked hits")
        }
        XCTAssertEqual(error.name, "ServiceUnavailable")
        XCTAssertEqual(error.retryPolicy, "safe")
        XCTAssertNil(error.details)
    }

    // MARK: - D3 costs / top-N sessions

    func testCostsGroupsFullSetTotalsFencesStartTimePagingAndUnpriced_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let day = "2026-09-07"
        let later = "2026-09-09"
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: day),
                                     project: "project_1")
        try fixture.seedBoundSession(id: "lite", start: Self.sqliteUTC(localDate: later),
                                     nativeID: "native-lite", project: "My Project", tier: "lite")
        try fixture.seedBoundSession(id: "before", start: Self.sqliteUTC(localDate: "2026-09-06"),
                                     nativeID: "native-before", project: "project_1")
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-tool", project: "project_1")
        try fixture.seedBoundSession(id: "week-two", start: Self.sqliteUTC(localDate: "2026-09-14"),
                                     nativeID: "native-week", project: "project_1")
        try fixture.seedBoundSession(id: "unpriced-empty", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-empty", project: "project_1")
        try fixture.seedBoundSession(id: "unpriced-named", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-named", project: "project_1")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "child", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-child", parent: "keep")
        try fixture.seedBoundSession(id: "ghost", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-ghost", machine: secondMachine, instance: secondInstance)
        try fixture.seedBoundSession(id: "no-cost", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-none", project: "project_1")
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
            try db.execute(sql: "UPDATE sessions SET end_time = ? WHERE id = 'before'",
                           arguments: [Self.sqliteUTC(localDate: day)])
        }
        try fixture.seedSessionCost(id: "keep", model: "claude", cost: 3, input: 100, output: 50,
                                    cacheRead: 10, cacheCreation: 5)
        try fixture.seedSessionCost(id: "lite", model: "gpt", cost: 2)
        try fixture.seedSessionCost(id: "before", model: "old-model", cost: 1.5)
        try fixture.seedSessionCost(id: "tool-only", model: "tool-model", cost: 1.4)
        try fixture.seedSessionCost(id: "week-two", model: "week-model", cost: 1.3)
        try fixture.seedSessionCost(id: "unpriced-empty", model: "", cost: 0, input: 20)
        try fixture.seedSessionCost(id: "unpriced-named", model: "no-price", cost: 0, input: 10)
        try fixture.seedSessionCost(id: "skip", model: "skip-model", cost: 99)
        try fixture.seedSessionCost(id: "hidden", model: "hidden-model", cost: 99)
        try fixture.seedSessionCost(id: "child", model: "child-model", cost: 99)
        try fixture.seedSessionCost(id: "ghost", model: "ghost-model", cost: 99)

        let missing = try MetadataSQLFixture()
        defer { missing.remove() }
        try missing.migrate()
        try missing.seedRegistry()
        try missing.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: day))
        try missing.write { try $0.execute(sql: "DROP TABLE session_costs") }
        let missingProducer = try missing.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? missingProducer.stop() }
        let empty = try await missingProducer.costs(try EngramServiceWebCostsRequest(),
                                                    requestId: requestId, deadline: missing.deadline())
        XCTAssertEqual(empty.totals.sessionCount, 0)
        XCTAssertEqual(empty.totals.costUsd, 0)
        XCTAssertEqual(empty.items, [])
        XCTAssertNil(empty.nextCursor)
        let emptyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
        XCTAssertNil(emptyObject["nextCursor"])
        XCTAssertNil(emptyObject["unpricedUnattributedSessions"])

        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }

        let models = try await producer.costs(try EngramServiceWebCostsRequest(limit: 20),
                                              requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(models.groupBy, .model)
        XCTAssertEqual(models.timeZone, TimeZone.current.identifier)
        XCTAssertEqual(models.totals.sessionCount, 7)
        XCTAssertEqual(models.totals.costUsd, 9.2, accuracy: 0.001)
        XCTAssertEqual(models.totals.inputTokens, 130)
        XCTAssertEqual(models.totals.outputTokens, 50)
        XCTAssertEqual(models.totals.cacheReadTokens, 10)
        XCTAssertEqual(models.totals.cacheCreationTokens, 5)
        XCTAssertEqual(models.items.map(\.key),
                       ["claude", "gpt", "old-model", "tool-model", "week-model", "no-price",
                        EngramServiceWebMetadataValidation.unknownModelKey])
        XCTAssertFalse(models.items.contains { $0.key == "skip-model" || $0.key == "ghost-model" })
        XCTAssertEqual(models.unpricedUnattributedSessions, 1)
        XCTAssertEqual(models.unpricedNoPriceSessions, 1)
        XCTAssertEqual(models.unpricedUnattributedTokens, 20)
        XCTAssertEqual(models.unpricedNoPriceTokens, 10)
        XCTAssertGreaterThan(models.totals.sessionCount, models.items.prefix(1).reduce(0) { $0 + $1.sessionCount })

        let first = try await producer.costs(try EngramServiceWebCostsRequest(limit: 1),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.key), ["claude"])
        XCTAssertEqual(first.totals.sessionCount, 7)
        XCTAssertEqual(first.totals.costUsd, models.totals.costUsd, accuracy: 0.001)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.costs(
            try EngramServiceWebCostsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.totals.sessionCount, 7)
        XCTAssertEqual(second.totals.costUsd, first.totals.costUsd, accuracy: 0.001)
        XCTAssertEqual(second.items.map(\.key), ["gpt"])

        await assertStale(deadline: fixture.deadline()) {
            try await producer.costs(
                try EngramServiceWebCostsRequest(groupBy: .source, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }
        await assertStale(deadline: fixture.deadline()) {
            try await producer.costs(
                try EngramServiceWebCostsRequest(since: day, limit: 1,
                                                snapshotId: first.snapshotId, cursor: cursor),
                requestId: requestId, deadline: fixture.deadline())
        }

        let ranged = try await producer.costs(
            try EngramServiceWebCostsRequest(since: day, until: day, tools: .hide, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(ranged.totals.sessionCount, 3)
        XCTAssertEqual(Set(ranged.items.map(\.key)),
                       ["claude", "no-price", EngramServiceWebMetadataValidation.unknownModelKey])
        XCTAssertFalse(ranged.items.contains { $0.key == "old-model" || $0.key == "tool-model" })

        let days = try await producer.costs(try EngramServiceWebCostsRequest(groupBy: .day, limit: 20),
                                            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(days.items.map(\.key)), [day, later, "2026-09-06", "2026-09-14"])
        XCTAssertEqual(days.totals.sessionCount, 7)

        let projects = try await producer.costs(try EngramServiceWebCostsRequest(groupBy: .project, limit: 20),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(Set(projects.items.map(\.key)),
                       ["project_1", Self.opaqueProjectKey("My Project")])
        XCTAssertEqual(projects.items.first { $0.key == "project_1" }?.sessionCount, 6)
    }

    func testCostSessionsTopNLimitFencesAndOmitsEmptyModel_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let day = "2026-09-07"
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: day))
        try fixture.seedBoundSession(id: "lite", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-lite", tier: "lite")
        try fixture.seedBoundSession(id: "before", start: Self.sqliteUTC(localDate: "2026-09-06"),
                                     nativeID: "native-before")
        try fixture.seedBoundSession(id: "tool-only", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-tool")
        try fixture.seedBoundSession(id: "unpriced-empty", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-empty")
        try fixture.seedBoundSession(id: "skip", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-skip", tier: "skip")
        try fixture.seedBoundSession(id: "hidden", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-hidden", hidden: true)
        try fixture.seedBoundSession(id: "ghost", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-ghost", machine: secondMachine, instance: secondInstance)
        try fixture.write { db in
            try db.execute(sql: """
                UPDATE sessions SET user_message_count = 0, tool_message_count = 3 WHERE id = 'tool-only'
                """)
            try db.execute(sql: "UPDATE sessions SET end_time = ? WHERE id = 'before'",
                           arguments: [Self.sqliteUTC(localDate: day)])
        }
        try fixture.seedSessionCost(id: "keep", model: "claude", cost: 3)
        try fixture.seedSessionCost(id: "lite", model: "gpt", cost: 2)
        try fixture.seedSessionCost(id: "before", model: "old-model", cost: 1.5)
        try fixture.seedSessionCost(id: "tool-only", model: "tool-model", cost: 1.4)
        try fixture.seedSessionCost(id: "unpriced-empty", model: "", cost: 0, input: 20)
        try fixture.seedSessionCost(id: "skip", model: "skip-model", cost: 99)
        try fixture.seedSessionCost(id: "hidden", model: "hidden-model", cost: 99)
        try fixture.seedSessionCost(id: "ghost", model: "ghost-model", cost: 99)

        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }

        let top = try await producer.costSessions(try EngramServiceWebCostSessionsRequest(limit: 3),
                                                  requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(top.items.map(\.session.sessionId), ["keep", "lite", "before"])
        XCTAssertEqual(top.items.map(\.costUsd), [3, 2, 1.5])
        XCTAssertEqual(top.items.first?.model, "claude")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(top)) as? [String: Any])
        XCTAssertNil(object["totalCount"])
        XCTAssertNil(object["nextCursor"])

        let hiddenTools = try await producer.costSessions(
            try EngramServiceWebCostSessionsRequest(since: day, until: day, tools: .hide, limit: 20),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(hiddenTools.items.map(\.session.sessionId), ["keep", "lite", "unpriced-empty"])
        XCTAssertNil(hiddenTools.items.first { $0.session.sessionId == "unpriced-empty" }?.model)
        XCTAssertFalse(hiddenTools.items.contains { $0.session.sessionId == "before" })
        XCTAssertFalse(hiddenTools.items.contains {
            ["skip", "hidden", "ghost", "tool-only"].contains($0.session.sessionId)
        })

        let defaultLimit = try EngramServiceWebCostSessionsRequest()
        XCTAssertEqual(defaultLimit.limit, 20)
        XCTAssertEqual(try EngramServiceWebCostSessionsRequest(limit: 100).limit, 100)
        XCTAssertThrowsError(try EngramServiceWebCostSessionsRequest(limit: 101))
        XCTAssertEqual(try EngramServiceWebCostsRequest().limit, 50)
        XCTAssertEqual(try EngramServiceWebCostsRequest().groupBy, .model)
    }

    func testCostsAfterPreparationRegistryRevokeIsStale_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        try fixture.seedBoundSession(id: "keep", start: Self.sqliteUTC(localDate: "2026-09-07"))
        try fixture.seedSessionCost(id: "keep", model: "claude", cost: 3)
        let policy = PolicyBox(validPolicy())
        let mutation = MetadataPreparationMutation(operation: .costs) {
            try fixture.revoke(.registryRoot, sessionID: "keep", policy: policy)
        }
        let producer = try fixture.producer(hooks: .init(afterPreparation: { try mutation.run($0) }),
                                            policy: { try policy.current() })
        defer { try? producer.stop() }
        let baseline = try await producer.costs(try EngramServiceWebCostsRequest(limit: 20),
                                                requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(baseline.items.map(\.key), ["claude"])
        mutation.arm()
        await assertStaleOrUnavailable(deadline: fixture.deadline()) {
            try await producer.costs(try EngramServiceWebCostsRequest(limit: 20),
                                     requestId: requestId, deadline: fixture.deadline())
        }
        XCTAssertEqual(mutation.entryCount, 1)
    }

    func testCostsRawTotalsSurviveSubCentGroupRounding_repro() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let day = "2026-09-07"
        try fixture.seedBoundSession(id: "alpha", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-alpha")
        try fixture.seedBoundSession(id: "bravo", start: Self.sqliteUTC(localDate: day),
                                     nativeID: "native-bravo")
        try fixture.seedSessionCost(id: "alpha", model: "a-model", cost: 0.006)
        try fixture.seedSessionCost(id: "bravo", model: "b-model", cost: 0.006)
        let producer = try fixture.producer(policy: {
            .init(parserRevision: self.parser, enabledSources: [.claudeCode])
        })
        defer { try? producer.stop() }
        let page = try await producer.costs(try EngramServiceWebCostsRequest(limit: 20),
                                            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(page.totals.costUsd, 0.012, accuracy: 1e-9)
        XCTAssertEqual(page.totals.sessionCount, 2)
        XCTAssertEqual(page.items.map(\.key), ["a-model", "b-model"])
        XCTAssertEqual(page.items[0].costUsd, 0.006, accuracy: 1e-9)
        XCTAssertEqual(page.items[1].costUsd, 0.006, accuracy: 1e-9)
        XCTAssertNotEqual(page.totals.costUsd, 0.02, accuracy: 0.001)
        let first = try await producer.costs(try EngramServiceWebCostsRequest(limit: 1),
                                             requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(first.items.map(\.key), ["a-model"])
        XCTAssertEqual(first.totals.costUsd, 0.012, accuracy: 1e-9)
        let cursor = try XCTUnwrap(first.nextCursor)
        let second = try await producer.costs(
            try EngramServiceWebCostsRequest(limit: 1, snapshotId: first.snapshotId, cursor: cursor),
            requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(second.snapshotId, first.snapshotId)
        XCTAssertEqual(second.items.map(\.key), ["b-model"])
        XCTAssertEqual(second.totals.costUsd, first.totals.costUsd, accuracy: 1e-12)
    }

    private func isolatedEmbeddingEnv(apiKey: String? = nil, model: String = "probe", dim: String = "3") -> [String: String] {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-d2-embed-\(UUID().uuidString)").path
        var env = [
            "HOME": home,
            "CFFIXED_USER_HOME": home,
            "ENGRAM_SETTINGS_PATH": home + "/missing-settings.json",
            "ENGRAM_EMBEDDING_MODEL": model,
            "ENGRAM_EMBEDDING_DIM": dim,
        ]
        if let apiKey { env["ENGRAM_EMBEDDING_API_KEY"] = apiKey }
        return env
    }

    private func searchProvider(
        databasePath: String,
        environment: [String: String],
        counter: SearchEmbedCounter
    ) throws -> SQLiteEngramServiceReadProvider {
        try SQLiteEngramServiceReadProvider(
            databasePath: databasePath,
            embeddingEnvironment: environment,
            embeddingProviderFactory: { _ in
                SearchCountingEmbeddingProvider(counter: counter) { _ in [1, 0, 0] }
            }
        )
    }

    private func performSearch(
        producer: ServiceWebMetadataProducer,
        provider: SQLiteEngramServiceReadProvider,
        request: EngramServiceWebSearchRequest
    ) async throws -> EngramServiceWebSearchResponse {
        let deadline = ContinuousClock.now.advanced(by: ServiceWebMetadataLimits.maximumRequestDuration)
        let scope = try await producer.searchScope(request, requestId: requestId, deadline: deadline)
        let ranked = try await provider.search(
            EngramServiceSearchRequest(query: request.query, mode: request.mode.rawValue, limit: request.limit),
            scope: scope
        )
        return try await producer.admitSearch(request, ranked: ranked, requestId: requestId, deadline: deadline)
    }

    private func validPolicy() -> ServiceWebMetadataPolicy {
        .init(parserRevision: parser, enabledSources: [.claudeCode])
    }

    private static func opaqueProjectKey(_ raw: String) -> String {
        "p." + ArchiveV2Hash.sha256(Data(raw.utf8))
    }

    private static func sqliteUTC(localDate: String, hour: Int = 12) -> String {
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let date = local.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      components.year!, components.month!, components.day!,
                      components.hour!, components.minute!, components.second!)
    }

    private func assertUnavailable(_ producer: any ServiceWebMetadataProviding,
                                   deadline: ContinuousClock.Instant) async {
        do {
            _ = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId, deadline: deadline)
            XCTFail("overview must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.sessions(try EngramServiceWebSessionsRequest(), requestId: requestId, deadline: deadline)
            XCTFail("sessions must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: "unavailable"),
                requestId: requestId, deadline: deadline)
            XCTFail("detail must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.facets(try EngramServiceWebFacetsRequest(kind: .source),
                requestId: requestId, deadline: deadline)
            XCTFail("facets must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.stats(try EngramServiceWebStatsRequest(),
                requestId: requestId, deadline: deadline)
            XCTFail("stats must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.settings(try EngramServiceWebSettingsRequest(),
                requestId: requestId, deadline: deadline)
            XCTFail("settings must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.searchScope(try EngramServiceWebSearchRequest(query: "alpha"),
                requestId: requestId, deadline: deadline)
            XCTFail("searchScope must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.admitSearch(
                try EngramServiceWebSearchRequest(query: "alpha"),
                ranked: EngramServiceSearchResponse(items: []),
                requestId: requestId, deadline: deadline)
            XCTFail("admitSearch must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.searchStatus(try EngramServiceWebSearchStatusRequest(),
                requestId: requestId, deadline: deadline)
            XCTFail("searchStatus must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.costs(try EngramServiceWebCostsRequest(),
                requestId: requestId, deadline: deadline)
            XCTFail("costs must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
        do {
            _ = try await producer.costSessions(try EngramServiceWebCostSessionsRequest(),
                requestId: requestId, deadline: deadline)
            XCTFail("costSessions must be unavailable")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .unavailable)
        }
    }

    private func assertStale(deadline: ContinuousClock.Instant, _ body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("expected stale")
        } catch {
            XCTAssertEqual(error as? ServiceWebMetadataError, .stale)
        }
    }

    private func assertStaleOrUnavailable(deadline: ContinuousClock.Instant, _ body: () async throws -> some Any) async {
        do {
            _ = try await body()
            XCTFail("expected stale or unavailable")
        } catch {
            let error = error as? ServiceWebMetadataError
            XCTAssertTrue(error == .stale || error == .unavailable, "\(String(describing: error))")
        }
    }

    private func assertRoundTrip<T: Codable>(_ value: T) throws {
        _ = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func assertEnvelopeUnderBudget(_ value: some Encodable) throws {
        let frame = try ServiceWebMetadataProducer.encodedSuccessFrame(requestId: requestId, result: value)
        XCTAssertLessThanOrEqual(frame.count, EngramServiceWebReadLimits.maximumPageEnvelopeBytes)
    }

    private func assertWALReleased(_ fixture: MetadataSQLFixture) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if try fixture.checkpoint().released { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Snapshot resources still pin WAL after the bounded release window")
        throw MetadataTestFailure.resourceNotReleased
    }
}

private final class PolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPolicy: ServiceWebMetadataPolicy?
    private var storedFailure: Error?
    var policy: ServiceWebMetadataPolicy? {
        get { lock.withLock { storedPolicy } }
        set { lock.withLock { storedPolicy = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    init(_ policy: ServiceWebMetadataPolicy?) { storedPolicy = policy }
    func current() throws -> ServiceWebMetadataPolicy? {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            return storedPolicy
        }
    }
}

private enum MetadataAuthorityFault: CaseIterable {
    case missingPolicy, disabledSource, parserRevision
    case registrySource, registryRoot, registryFormat, registryEpoch, registryHistory
    case parent, hidden, skip
}

private enum MetadataReadyScalarFault: CaseIterable {
    case parsedHead, readyHead, identityVersion, generationVersion, sessionVersion
    case sessionOwner, sessionSource, sessionHash, generationHash, generationParser
    case generationRoot, generationFormat, generationEpoch, generationAuthority, generationSequence
    case ledgerOnly, ftsOnly, registryRoot, registryFormat, registryEpoch, registryAuthority
    case historyMissing, historyAuthority, historyEpoch
}

private final class MetadataPreparationMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: ServiceWebMetadataOperation
    private let mutate: () throws -> Void
    private var armed = false
    private var entries = 0
    init(operation: ServiceWebMetadataOperation, mutate: @escaping () throws -> Void) {
        self.operation = operation
        self.mutate = mutate
    }
    var entryCount: Int { lock.withLock { entries } }
    func arm() { lock.withLock { armed = true; entries = 0 } }
    func run(_ actual: ServiceWebMetadataOperation) throws {
        let shouldMutate = lock.withLock {
            guard actual == operation, armed else { return false }
            armed = false
            entries += 1
            return true
        }
        if shouldMutate { try mutate() }
    }
}

private final class WebMetadataTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var scheduled: [UUID: (due: Duration, fire: @Sendable () -> Void)] = [:]
    private var fired: [UUID] = []
    private var cancelled: Set<UUID> = []

    func now() -> ContinuousClock.Instant { lock.withLock { origin + offset } }
    var firedIDs: [UUID] { lock.withLock { fired } }
    var scheduledIDs: Set<UUID> { lock.withLock { Set(scheduled.keys) } }
    var cancelledIDs: Set<UUID> { lock.withLock { cancelled } }

    var clock: ServiceWebMetadataClock {
        ServiceWebMetadataClock(
            now: { [weak self] in self?.now() ?? ContinuousClock.now },
            schedule: { [weak self] deadline, fire in
                let id = UUID()
                guard let self else {
                    return ServiceWebMetadataExpiryHandle(id: id, cancel: {})
                }
                return self.lock.withLock {
                    self.scheduled[id] = (deadline - self.origin, fire)
                    return ServiceWebMetadataExpiryHandle(id: id) { [weak self] in
                        guard let self else { return }
                        self.lock.withLock {
                            self.scheduled[id] = nil
                            self.cancelled.insert(id)
                        }
                    }
                }
            }
        )
    }

    func advance(_ duration: Duration) {
        let due: [(UUID, @Sendable () -> Void)] = lock.withLock {
            offset += duration
            let current = offset
            let firedNow = scheduled.filter { $0.value.due <= current }
            for id in firedNow.keys { scheduled[id] = nil }
            fired.append(contentsOf: firedNow.keys)
            return firedNow.map { ($0.key, $0.value.fire) }
        }
        for item in due { item.1() }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}

private enum MetadataTestFailure: Error {
    case instrumentation, resourceNotReleased, workloadCompleted, watchdog
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}

/// Runs genuine SQLite work on the borrowed production connection. It does
/// not install a progress handler or call sqlite3_interrupt. The UDF watchdog
/// throws only to bound a BROKEN implementation's cleanup; that produces
/// SQLITE_ERROR and is explicitly rejected, never counted as cancellation.
private final class MetadataSQLWorkProbe: @unchecked Sendable {
    let phase: ServiceWebMetadataDatabasePhase
    let entered: XCTestExpectation
    private struct State {
        var armed = true
        var entered = false
        var exited = false
        var unblock = false
        var watchdog = false
        var code: Int32?
        var duration: Duration?
    }
    private let state = LockedValue(State())
    init(phase: ServiceWebMetadataDatabasePhase, entered: XCTestExpectation) {
        self.phase = phase
        self.entered = entered
    }
    var didEnterSQL: Bool { state.value.entered }
    var didExitSQL: Bool { state.value.exited }
    var sqliteResult: Int32? { state.value.code }
    var sqlDuration: Duration? { state.value.duration }
    var watchdogFired: Bool { state.value.watchdog }
    func unblock() { state.update { $0.unblock = true } }

    func run(_ actualPhase: ServiceWebMetadataDatabasePhase, db: Database) throws {
        guard actualPhase == phase else { return }
        var shouldRun = false
        state.update { if $0.armed { $0.armed = false; shouldRun = true } }
        guard shouldRun else { return }
        XCTAssertTrue(db.description.contains("snapshot."), "Must be the actual snapshot connection")
        XCTAssertEqual(db.isInsideTransaction, phase == .snapshotRead)
        let began = ContinuousClock.now
        let function = DatabaseFunction("a5c_sql_entry", argumentCount: 1, pure: false) { [self] arguments in
            var first = false
            state.update { if !$0.entered { $0.entered = true; first = true } }
            if first { entered.fulfill() }
            if state.value.unblock || ContinuousClock.now - began >= .seconds(2) {
                state.update { $0.watchdog = true }
                throw MetadataTestFailure.watchdog
            }
            return arguments[0]
        }
        db.add(function: function)
        defer {
            db.remove(function: function)
            state.update { $0.exited = true; $0.duration = ContinuousClock.now - began }
        }
        do {
            _ = try Int64.fetchOne(db, sql: """
                WITH RECURSIVE work(n) AS (
                    VALUES(1) UNION ALL SELECT n + 1 FROM work WHERE n < 1000000000
                ) SELECT sum(a5c_sql_entry(n)) FROM work
                """)
            state.update { $0.code = SQLITE_OK }
            throw MetadataTestFailure.workloadCompleted
        } catch let error as DatabaseError {
            state.update { $0.code = error.resultCode.rawValue }
            throw error
        }
    }
}

private final class MetadataPageReadObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var pageReads: Int { lock.withLock { total } }

    func install(_ db: Database) throws {
        let connection = try XCTUnwrap(db.sqliteConnection)
        try db.execute(sql: "PRAGMA cache_size = -256")
        let context = Unmanaged.passUnretained(self).toOpaque()
        let code = sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
            guard let context, let statement, let connection = sqlite3_db_handle(OpaquePointer(statement)) else { return 0 }
            var current: Int32 = 0
            var highwater: Int32 = 0
            let result = sqlite3_db_status(connection, SQLITE_DBSTATUS_CACHE_MISS, &current, &highwater, 1)
            guard result == SQLITE_OK else { return 0 }
            let observer = Unmanaged<MetadataPageReadObserver>.fromOpaque(context).takeUnretainedValue()
            observer.lock.withLock { observer.total += Int(current) }
            return 0
        }, context)
        XCTAssertEqual(code, SQLITE_OK)
    }
}

private final class MetadataSQLObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [Connection] = []
    private final class Connection {
        let description: String
        let readonly: Int32
        let timeout: Int
        var probing = true
        var authorizerCode: Int32 = -1
        var traceCode: Int32 = -1
        var probeCodes: [Int32] = []
        var probeDenials = 0
        var productionDenials = 0
        var statements = 0
        let lock = NSLock()
        init(_ db: Database, readonly: Int32, timeout: Int) {
            description = db.description
            self.readonly = readonly
            self.timeout = timeout
        }
    }
    var productionStatements: Int {
        lock.withLock { connections.reduce(0) { sum, record in sum + record.lock.withLock { record.statements } } }
    }
    var productionDenials: Int {
        lock.withLock { connections.reduce(0) { sum, record in sum + record.lock.withLock { record.productionDenials } } }
    }

    func install(_ db: Database) throws {
        let connection = try XCTUnwrap(db.sqliteConnection)
        let record = Connection(db, readonly: sqlite3_db_readonly(connection, "main"),
                                timeout: try XCTUnwrap(Int.fetchOne(db, sql: "PRAGMA busy_timeout")))
        lock.withLock { connections.append(record) } // Keeps both C callback contexts alive.
        let context = Unmanaged.passUnretained(record).toOpaque()
        record.authorizerCode = sqlite3_set_authorizer(connection, { context, action, _, column, _, _ in
            guard let context else { return SQLITE_OK }
            let record = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
            let columnName = column.map { String(cString: $0) } ?? ""
            let deniedWrites: Set<Int32> = [
                SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE, SQLITE_ATTACH, SQLITE_DETACH,
                SQLITE_CREATE_TABLE, SQLITE_DROP_TABLE, SQLITE_ALTER_TABLE,
                SQLITE_CREATE_INDEX, SQLITE_DROP_INDEX, SQLITE_CREATE_VIEW, SQLITE_DROP_VIEW,
                SQLITE_CREATE_TRIGGER, SQLITE_DROP_TRIGGER, SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE,
                SQLITE_CREATE_TEMP_TABLE, SQLITE_DROP_TEMP_TABLE,
                SQLITE_CREATE_TEMP_INDEX, SQLITE_DROP_TEMP_INDEX, SQLITE_CREATE_TEMP_VIEW, SQLITE_DROP_TEMP_VIEW,
                SQLITE_CREATE_TEMP_TRIGGER, SQLITE_DROP_TEMP_TRIGGER, SQLITE_REINDEX, SQLITE_ANALYZE,
            ]
            if action == SQLITE_PRAGMA { return SQLITE_OK }
            let blob = action == SQLITE_READ
                && ["canonical_bytes", "manifest_json", "normalized_messages_json"].contains(columnName)
            if blob || deniedWrites.contains(action) {
                record.lock.withLock {
                    if record.probing { record.probeDenials += 1 } else { record.productionDenials += 1 }
                }
                return SQLITE_DENY
            }
            return SQLITE_OK
        }, context)
        record.traceCode = sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_STMT), { _, context, _, _ in
            guard let context else { return 0 }
            let record = Unmanaged<Connection>.fromOpaque(context).takeUnretainedValue()
            record.lock.withLock { if !record.probing { record.statements += 1 } }
            return 0
        }, context)
        XCTAssertEqual(record.authorizerCode, SQLITE_OK)
        XCTAssertEqual(record.traceCode, SQLITE_OK)
        guard record.authorizerCode == SQLITE_OK, record.traceCode == SQLITE_OK else {
            throw MetadataTestFailure.instrumentation
        }
        for sql in [
            "SELECT canonical_bytes FROM capture_ingest_publications LIMIT 1",
            "SELECT manifest_json FROM capture_ingest_generations LIMIT 1",
            "SELECT normalized_messages_json FROM capture_ingest_generations LIMIT 1",
            "UPDATE metadata_wal_probe SET value = 1",
            "CREATE TABLE metadata_authorizer_probe(value INTEGER)",
            "ATTACH DATABASE ':memory:' AS metadata_authorizer_probe",
        ] {
            let code = sqlite3_exec(connection, sql, nil, nil, nil)
            record.probeCodes.append(code)
            XCTAssertEqual(code, SQLITE_AUTH, sql) // SQLITE_ERROR/READONLY is not authorization evidence.
            guard code == SQLITE_AUTH else { throw MetadataTestFailure.instrumentation }
        }
        record.lock.withLock { record.probing = false }
    }

    func assertConnections(requireSnapshot: Bool = false) throws {
        let records = lock.withLock { connections }
        XCTAssertFalse(records.isEmpty)
        if requireSnapshot {
            XCTAssertTrue(records.contains { $0.description.contains("snapshot.") })
            XCTAssertTrue(records.contains { !$0.description.contains("snapshot.") })
            XCTAssertGreaterThanOrEqual(records.count, 2)
        }
        for record in records {
            XCTAssertEqual(record.readonly, 1, record.description)
            XCTAssertEqual(record.timeout, 0, record.description)
            XCTAssertEqual(record.authorizerCode, SQLITE_OK, record.description)
            XCTAssertEqual(record.traceCode, SQLITE_OK, record.description)
            XCTAssertEqual(record.probeCodes, Array(repeating: SQLITE_AUTH, count: 6), record.description)
            XCTAssertEqual(record.lock.withLock { record.probeDenials }, 6, record.description)
            XCTAssertEqual(record.lock.withLock { record.productionDenials }, 0, record.description)
        }
    }

}

private final class MetadataShortQueryStatements: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func record(_ sql: String) { lock.withLock { statements.append(sql) } }
    var values: [String] { lock.withLock { statements } }
}

private final class MetadataSnapshotLifecycleObserver: @unchecked Sendable {
    private final class Record {
        let lock = NSLock()
        var events: [String] = []
    }
    private let lock = NSLock()
    private var records: [Record] = []

    func install(_ db: Database) throws {
        guard db.description.contains(".snapshot.") else { return }
        let connection = try XCTUnwrap(db.sqliteConnection)
        let record = Record()
        lock.withLock { records.append(record) }
        let code = sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_CLOSE), { event, context, _, sql in
            guard let context else { return 0 }
            let record = Unmanaged<Record>.fromOpaque(context).takeUnretainedValue()
            if event == UInt32(SQLITE_TRACE_CLOSE) {
                record.lock.withLock { record.events.append("CLOSE") }
            } else if let sql {
                let statement = String(cString: sql.assumingMemoryBound(to: CChar.self))
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if statement == "COMMIT" || statement == "COMMIT TRANSACTION" {
                    record.lock.withLock { record.events.append("COMMIT") }
                }
            }
            return 0
        }, Unmanaged.passUnretained(record).toOpaque())
        XCTAssertEqual(code, SQLITE_OK)
        guard code == SQLITE_OK else { throw MetadataTestFailure.instrumentation }
    }

    func assertClosedSnapshots(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let records = lock.withLock { self.records }
        XCTAssertEqual(records.count, count, file: file, line: line)
        for record in records {
            let events = record.lock.withLock { record.events }
            XCTAssertEqual(events, ["COMMIT", "CLOSE"],
                "GRDB snapshot must end its transaction before closing; explicit close makes deinit use a NULL connection",
                file: file, line: line)
        }
    }
}

final class MetadataSQLFixture: @unchecked Sendable {
    let directory: URL
    let path: String
    fileprivate let clock = WebMetadataTestClock()
    private let machine = "AAAAAAAA-0000-4000-8000-000000000001"
    private let instance = "BBBBBBBB-0000-4000-8000-000000000002"
    private let epoch = "CCCCCCCC-0000-4000-8000-000000000003"
    private let root = "/Users/fixture/sessions"
    private var writer: DatabaseQueue?
    private var sequences: [String: Int64] = [:]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-a5c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        path = directory.appendingPathComponent("index.sqlite").path
    }

    func remove() {
        do { try writer?.close() } catch { XCTFail("fixture writer close: \(error)") }
        writer = nil
        do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("fixture cleanup: \(error)") }
    }
    func deadline() -> ContinuousClock.Instant {
        clock.now() + ServiceWebMetadataLimits.maximumRequestDuration
    }

    func migrate() throws {
        try EngramDatabaseWriter(path: path).migrate()
        var configuration = Configuration()
        configuration.busyMode = .immediateError
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "PRAGMA busy_timeout = 0")
        }
        writer = try DatabaseQueue(path: path, configuration: configuration)
        try write { db in
            try db.execute(sql: "CREATE TABLE metadata_wal_probe(value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO metadata_wal_probe VALUES (0)")
        }
    }

    func producer(hooks: ServiceWebMetadataTestHooks = .init(),
                  policy: @escaping @Sendable () throws -> ServiceWebMetadataPolicy? = {
                      .init(parserRevision: "parser-v1", enabledSources: [.claudeCode, .codex])
                  }, liveClock: Bool = false,
                  embeddingEnvironment: [String: String]? = nil) throws -> ServiceWebMetadataProducer {
        try ServiceWebMetadataProducer(
            databasePath: path,
            policy: policy,
            clock: liveClock ? .live : clock.clock,
            hooks: hooks,
            embeddingEnvironment: embeddingEnvironment ?? [
                "HOME": directory.path,
                "CFFIXED_USER_HOME": directory.path,
                "ENGRAM_SETTINGS_PATH": directory.appendingPathComponent("missing-settings.json").path,
            ]
        )
    }

    func seedRegistry(machine: String? = nil, instance: String? = nil, source: SourceName = .claudeCode) throws {
        let machine = machine ?? self.machine
        let instance = instance ?? self.instance
        try write { db in
            _ = try CaptureIngestSourceRegistry.provision(
                db, machineID: machine, sourceInstanceID: instance, source: source,
                parseFormat: source == .codex ? .codex : .claudeDefault,
                configuredRoot: configuredRoot(instance), initialEpoch: epoch
            )
        }
    }

    func seedBoundSession(
        id: String, start: String?, nativeID: String = "native-1",
        machine: String? = nil, instance: String? = nil,
        source: SourceName = .claudeCode,
        project: String? = "project_1", title: String? = "title",
        tier: String = "normal", hidden: Bool = false, parent: String? = nil,
        extraParserTask: Bool = false, indexReady: Bool = false, divergeHeads: Bool = false,
        fts: Bool = true
    ) throws {
        let machine = machine ?? self.machine
        let instance = instance ?? self.instance
        let parser = "parser-v1"
        let root = configuredRoot(instance)
        let stream = "\(machine):\(instance)"
        let sequence = (sequences[stream] ?? 0) + 1
        sequences[stream] = sequence + (divergeHeads ? 1 : 0)
        let manifest = try ArchiveSourceManifest(
            captureID: ArchiveV2Hash.sha256(Data("capture:\(id):\(sequence)".utf8)),
            machineID: machine, source: source.rawValue, locator: "\(root)/\(nativeID).jsonl",
            sessionID: nil, capturedAt: "2026-09-01T00:00:00Z",
            generation: .init(device: 1, inode: sequence, size: 0, mtimeNs: 1, ctimeNs: 1, mode: 0o100600),
            wholeSourceSHA256: ArchiveV2Hash.sha256(Data()), rawByteCount: 0, chunks: [],
            replayLayout: .init(strategy: .singleFile, relativePaths: ["\(nativeID).jsonl"]))
        let manifestBytes = try ArchiveCanonicalJSON.encode(manifest)
        _ = try ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: manifestBytes)
        let envelope = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: sequence, manifestSHA256: ArchiveV2Hash.sha256(manifestBytes))
        let publicationBytes = try ArchiveCanonicalJSON.encode(envelope)
        _ = try ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: publicationBytes)
        let publication = ArchiveV2Hash.sha256(publicationBytes)
        let generation = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode([publication, parser]))
        let snapshot = ArchiveV2Hash.sha256(Data("snapshot:\(id)".utf8))
        let messages = Data("[]".utf8)
        let messageSHA = ArchiveV2Hash.sha256(messages)
        let secondParser = "parser-v2"
        let secondPublicationBytes = try ArchiveCanonicalJSON.encode(CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: instance, collectorEpoch: epoch,
            sequence: sequence + 1, manifestSHA256: ArchiveV2Hash.sha256(manifestBytes)))
        let secondPublication = ArchiveV2Hash.sha256(secondPublicationBytes)
        let secondGeneration = ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode([secondPublication, parser]))
        try write { db in
            try db.execute(sql: """
                INSERT INTO sessions(
                    id, source, start_time, cwd, project, file_path, generated_title, custom_name,
                    tier, hidden_at, parent_session_id, suggested_parent_id, authoritative_node,
                    sync_version, snapshot_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                """, arguments: [
                    id, source.rawValue, start ?? "invalid", root, project,
                    "\(root)/\(nativeID).jsonl", title, nil as String?, tier,
                    hidden ? "2026-09-01 00:00:00" : nil, parent,
                    "capture-v1.\(machine).\(instance)", 1, snapshot,
                ])
            if fts, let title {
                try db.execute(sql: "INSERT INTO sessions_fts(session_id, content) VALUES (?, ?)",
                               arguments: [id, title])
            }
            try db.execute(sql: """
                INSERT INTO capture_ingest_publications(
                    publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [publication, publicationBytes, machine, instance, epoch, sequence])
            try db.execute(sql: """
                INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status)
                VALUES (?, ?, ?)
                """, arguments: [publication, parser, indexReady && !divergeHeads ? "index_ready" : "parsed"])
            if extraParserTask {
                try db.execute(sql: """
                    INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status)
                    VALUES (?, ?, 'parsed')
                    """, arguments: [publication, secondParser])
            }
            try db.execute(sql: """
                INSERT INTO capture_ingest_identity_bindings(
                    machine_id, source_instance_id, source, native_id, stored_session_id, last_sync_version)
                VALUES (?, ?, ?, ?, ?, 0)
                """, arguments: [machine, instance, source.rawValue, nativeID, id])
            try insertGeneration(db, generation: generation, publication: publication, parser: parser,
                                 machine: machine, instance: instance, nativeID: nativeID, sessionID: id,
                                 sequence: sequence, syncVersion: 1, snapshot: snapshot, messages: messages,
                                 messageSHA: messageSHA, source: source, manifest: manifestBytes)
            var parsed = generation
            var ready: String? = indexReady ? generation : nil
            if divergeHeads {
                try db.execute(sql: """
                    INSERT INTO capture_ingest_publications(
                        publication_sha256, canonical_bytes, machine_id, source_instance_id, collector_epoch, sequence)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [secondPublication, secondPublicationBytes, machine, instance, epoch, sequence + 1])
                try db.execute(sql: """
                    INSERT INTO capture_ingest_ledger(publication_sha256, parser_revision, status)
                    VALUES (?, ?, 'index_ready')
                    """, arguments: [secondPublication, parser])
                try insertGeneration(db, generation: secondGeneration, publication: secondPublication, parser: parser,
                                     machine: machine, instance: instance, nativeID: nativeID, sessionID: id,
                                     sequence: sequence + 1, syncVersion: 2, snapshot: snapshot, messages: messages,
                                     messageSHA: messageSHA, source: source, manifest: manifestBytes)
                parsed = generation
                ready = secondGeneration
            }
            try db.execute(sql: """
                UPDATE capture_ingest_identity_bindings
                SET last_parsed_generation_id = ?, last_ready_generation_id = ?, last_sync_version = ?
                WHERE stored_session_id = ?
                """, arguments: [parsed, ready, divergeHeads ? 2 : 1, id])
        }
    }

    func seedSessionCost(
        id: String, model: String?, cost: Double,
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0
    ) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO session_costs(
                    session_id, model, input_tokens, output_tokens,
                    cache_read_tokens, cache_creation_tokens, cost_usd, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, '2026-09-07T00:00:00.000Z')
                """, arguments: [id, model, input, output, cacheRead, cacheCreation, cost])
        }
    }

    func seedEmbeddingMeta(model: String, dimension: Int = 3) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO embedding_meta(id, provider, model, dimension)
                VALUES (1, 'test', ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider = excluded.provider,
                    model = excluded.model, dimension = excluded.dimension
                """, arguments: [model, dimension])
        }
    }

    func seedSemanticChunk(sessionID: String, model: String, vector: [Float], text: String) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES (?, ?, 0, ?, ?, ?, ?)
                """, arguments: [
                    "\(sessionID):c0", sessionID, text,
                    VectorMath.encode(VectorMath.l2Normalize(vector)),
                    model, vector.count,
                ])
        }
    }

    func seedLocalSession(id: String) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, cwd, file_path, tier, authoritative_node)
                VALUES (?, 'codex', '2026-09-02 12:00:00', '/tmp', '/tmp/\(id).jsonl', 'normal', 'local')
                """, arguments: [id])
        }
    }

    func hide(_ id: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE sessions SET hidden_at = datetime('now') WHERE id = ?", arguments: [id])
        }
    }

    fileprivate func revoke(_ fault: MetadataAuthorityFault, sessionID: String, policy: PolicyBox) throws {
        switch fault {
        case .missingPolicy: policy.policy = nil
        case .disabledSource: policy.policy = .init(parserRevision: "parser-v1", enabledSources: [.codex])
        case .parserRevision: policy.policy = .init(parserRevision: "parser-v2", enabledSources: [.claudeCode])
        case .registrySource: try write { try $0.execute(sql: "UPDATE capture_ingest_source_registry SET source = 'codex'") }
        case .registryRoot: try mutateReadyScalar(.registryRoot)
        case .registryFormat: try mutateReadyScalar(.registryFormat)
        case .registryEpoch: try mutateReadyScalar(.registryEpoch)
        case .registryHistory: try mutateReadyScalar(.historyMissing)
        case .parent:
            try write { try $0.execute(sql: "UPDATE sessions SET parent_session_id = 'parent' WHERE id = ?", arguments: [sessionID]) }
        case .hidden: try hide(sessionID)
        case .skip:
            try write { try $0.execute(sql: "UPDATE sessions SET tier = 'skip' WHERE id = ?", arguments: [sessionID]) }
        }
    }

    fileprivate func mutateReadyScalar(_ fault: MetadataReadyScalarFault) throws {
        let sql: String
        switch fault {
        case .parsedHead: sql = "UPDATE capture_ingest_identity_bindings SET last_parsed_generation_id = NULL"
        case .readyHead: sql = "UPDATE capture_ingest_identity_bindings SET last_ready_generation_id = NULL"
        case .identityVersion: sql = "UPDATE capture_ingest_identity_bindings SET last_sync_version = 2"
        case .generationVersion: sql = "UPDATE capture_ingest_generations SET sync_version = 2"
        case .sessionVersion: sql = "UPDATE sessions SET sync_version = 2"
        case .sessionOwner: sql = "UPDATE sessions SET authoritative_node = 'local'"
        case .sessionSource: sql = "UPDATE sessions SET source = 'codex'"
        case .sessionHash: sql = "UPDATE sessions SET snapshot_hash = '\(ArchiveV2Hash.sha256(Data("other".utf8)))'"
        case .generationHash: sql = "UPDATE capture_ingest_generations SET snapshot_hash = '\(ArchiveV2Hash.sha256(Data("other".utf8)))'"
        case .generationParser: sql = "UPDATE capture_ingest_generations SET parser_revision = 'parser-v2'"
        case .generationRoot: sql = "UPDATE capture_ingest_generations SET configured_root = '/Users/fixture/other'"
        case .generationFormat: sql = "UPDATE capture_ingest_generations SET parse_format = 'claudeCustomProfile'"
        case .generationEpoch: sql = "UPDATE capture_ingest_generations SET collector_epoch = 'DDDDDDDD-0000-4000-8000-000000000099'"
        case .generationAuthority: sql = "UPDATE capture_ingest_generations SET authority_generation = 2"
        case .generationSequence: sql = "UPDATE capture_ingest_generations SET sequence = sequence + 1"
        case .ledgerOnly: sql = "UPDATE capture_ingest_ledger SET status = 'parsed'" // Both heads remain equal and nonnil.
        case .ftsOnly: sql = "DELETE FROM sessions_fts" // Every authority scalar remains unchanged.
        case .registryRoot: sql = "UPDATE capture_ingest_source_registry SET configured_root = '/Users/fixture/other'"
        case .registryFormat: sql = "UPDATE capture_ingest_source_registry SET parse_format = 'claudeCustomProfile'"
        case .registryEpoch: sql = "UPDATE capture_ingest_source_registry SET approved_epoch = 'DDDDDDDD-0000-4000-8000-000000000099'"
        case .registryAuthority: sql = "UPDATE capture_ingest_source_registry SET authority_generation = 2"
        case .historyMissing: sql = "DELETE FROM capture_ingest_epoch_history"
        case .historyAuthority: sql = "UPDATE capture_ingest_epoch_history SET authority_generation = 2"
        case .historyEpoch: sql = "UPDATE capture_ingest_epoch_history SET approved_epoch = 'DDDDDDDD-0000-4000-8000-000000000099'"
        }
        try write { try $0.execute(sql: sql) }
    }

    func dropCaptureTables() throws {
        try write { db in
            for table in ["capture_ingest_generations", "capture_ingest_identity_bindings",
                          "capture_ingest_epoch_history", "capture_ingest_source_registry",
                          "capture_ingest_ledger", "capture_ingest_arrivals",
                          "capture_ingest_checkpoints", "capture_ingest_publications"] {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
        }
    }

    func dropFTS() throws {
        try write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS sessions_fts")
        }
    }

    private func insertGeneration(
        _ db: Database, generation: String, publication: String, parser: String,
        machine: String, instance: String, nativeID: String, sessionID: String,
        sequence: Int64, syncVersion: Int, snapshot: String, messages: Data, messageSHA: String,
        source: SourceName, manifest: Data
    ) throws {
        try db.execute(sql: """
            INSERT INTO capture_ingest_generations(
                generation_id, publication_sha256, parser_revision, machine_id, source_instance_id,
                source, parse_format, configured_root, collector_epoch, authority_generation, sequence,
                native_id, raw_source_session_id, stored_session_id, manifest_json, normalized_schema_version,
                normalized_messages_json, normalized_messages_sha256, normalized_message_count, sync_version,
                snapshot_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, 1, ?, ?, 0, ?, ?, datetime('now'))
            """, arguments: [
                generation, publication, parser, machine, instance, source.rawValue,
                (source == .codex ? CaptureIngestParseFormat.codex : .claudeDefault).rawValue,
                configuredRoot(instance), epoch, sequence,
                nativeID, nativeID, sessionID, manifest, messages, messageSHA, syncVersion, snapshot,
            ])
    }

    func write(_ body: (Database) throws -> Void) throws {
        try XCTUnwrap(writer).write(body)
    }

    func configuredRoot(_ instance: String) -> String { "\(root)/\(instance)" }

    func touchWAL() throws {
        try write { try $0.execute(sql: "UPDATE metadata_wal_probe SET value = value + 1") }
    }

    struct Checkpoint {
        let code: Int32
        let log: Int32
        let completed: Int32
        var pinned: Bool { code == SQLITE_BUSY || (log > 0 && completed < log) }
        var released: Bool { code == SQLITE_OK && log == 0 && completed == 0 }
    }

    // Writer stays alive, autocheckpoint=0, busy_timeout=0. This is independent
    // SQLite resource evidence, not an assertion about a producer-owned counter.
    func checkpoint() throws -> Checkpoint {
        try XCTUnwrap(writer).writeWithoutTransaction { db in
            XCTAssertFalse(db.isInsideTransaction)
            var log: Int32 = -1
            var completed: Int32 = -1
            let code = sqlite3_wal_checkpoint_v2(db.sqliteConnection, "main", SQLITE_CHECKPOINT_TRUNCATE,
                                                &log, &completed)
            return Checkpoint(code: code, log: log, completed: completed)
        }
    }
}

private actor SearchEmbedCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

private final class ImmediateScopeProducer: ServiceWebMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = false
    var didAdmit: Bool { lock.withLock { admitted } }

    func overview(_ request: EngramServiceWebOverviewRequest, requestId: String,
                  deadline: ContinuousClock.Instant) async throws -> EngramServiceWebOverviewResponse {
        throw ServiceWebMetadataError.unavailable
    }
    func sessions(_ request: EngramServiceWebSessionsRequest, requestId: String,
                  deadline: ContinuousClock.Instant) async throws -> EngramServiceWebSessionsResponse {
        throw ServiceWebMetadataError.unavailable
    }
    func sessionDetail(_ request: EngramServiceWebSessionDetailRequest, requestId: String,
                       deadline: ContinuousClock.Instant) async throws -> EngramServiceWebSessionDetailResponse {
        throw ServiceWebMetadataError.unavailable
    }
    func searchScope(_ request: EngramServiceWebSearchRequest, requestId: String,
                     deadline: ContinuousClock.Instant) async throws -> EngramServiceSearchScope {
        .unrestricted
    }
    func admitSearch(_ request: EngramServiceWebSearchRequest, ranked: EngramServiceSearchResponse,
                     requestId: String, deadline: ContinuousClock.Instant) async throws -> EngramServiceWebSearchResponse {
        lock.withLock { admitted = true }
        throw ServiceWebMetadataError.unavailable
    }
    func stop() throws {}
}

private final class SlowScopedSearchProvider: EngramServiceReadProvider, @unchecked Sendable {
    private let empty = EmptyEngramServiceReadProvider()
    private let lock = NSLock()
    private let entered: XCTestExpectation
    private let cancelled: XCTestExpectation
    private let exited: XCTestExpectation
    private var enteredFlag = false
    private var cancelledFlag = false
    private var exitedFlag = false
    var didEnter: Bool { lock.withLock { enteredFlag } }
    var didCancel: Bool { lock.withLock { cancelledFlag } }
    var didExit: Bool { lock.withLock { exitedFlag } }

    init(entered: XCTestExpectation, cancelled: XCTestExpectation, exited: XCTestExpectation) {
        self.entered = entered
        self.cancelled = cancelled
        self.exited = exited
    }

    func search(_ request: EngramServiceSearchRequest) async throws -> EngramServiceSearchResponse {
        try await search(request, scope: .unrestricted)
    }

    func search(_ request: EngramServiceSearchRequest, scope: EngramServiceSearchScope) async throws -> EngramServiceSearchResponse {
        lock.withLock { enteredFlag = true }
        entered.fulfill()
        defer {
            lock.withLock { exitedFlag = true }
            exited.fulfill()
        }
        do {
            try await Task.sleep(for: .seconds(5))
        } catch is CancellationError {
            lock.withLock { cancelledFlag = true }
            cancelled.fulfill()
            throw CancellationError()
        }
        XCTFail("Injected search must not finish after the handler deadline")
        return EngramServiceSearchResponse(items: [], searchModes: ["semantic"], warning: nil)
    }

    func health() async throws -> EngramServiceHealthResponse { try await empty.health() }
    func liveSessions() async throws -> EngramServiceLiveSessionsResponse { try await empty.liveSessions() }
    func sources() async throws -> [EngramServiceSourceInfo] { try await empty.sources() }
    func memoryFiles() async throws -> [EngramServiceMemoryFile] { try await empty.memoryFiles() }
    func memoryFileContent(_ request: EngramServiceMemoryFileContentRequest) async throws -> EngramServiceMemoryFileContentResponse {
        try await empty.memoryFileContent(request)
    }
    func insights() async throws -> [EngramServiceInsightInfo] { try await empty.insights() }
    func insightDetail(_ request: EngramServiceInsightDetailRequest) async throws -> EngramServiceInsightInfo? {
        try await empty.insightDetail(request)
    }
    func costs() async throws -> EngramServiceCostsResponse { try await empty.costs() }
    func replayTimeline(_ request: EngramServiceReplayTimelineRequest) async throws -> EngramServiceReplayTimelineResponse {
        try await empty.replayTimeline(request)
    }
    func resumeCommand(_ request: EngramServiceResumeCommandRequest) async throws -> EngramServiceResumeCommandResponse {
        try await empty.resumeCommand(request)
    }
    func projectMigrations(_ request: EngramServiceProjectMigrationsRequest) async throws -> EngramServiceProjectMigrationsResponse {
        try await empty.projectMigrations(request)
    }
    func projectCwds(_ request: EngramServiceProjectCwdsRequest) async throws -> EngramServiceProjectCwdsResponse {
        try await empty.projectCwds(request)
    }
}

private struct SearchCountingEmbeddingProvider: EmbeddingProvider {
    let model = "probe"
    let dimension = 3
    let counter: SearchEmbedCounter
    let vector: @Sendable (String) throws -> [Float]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        await counter.increment()
        return try texts.map { try VectorMath.l2Normalize(vector($0)) }
    }
}
