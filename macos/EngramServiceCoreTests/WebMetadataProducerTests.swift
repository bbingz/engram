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

    func testOverviewOrdersMachineThenInstance() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry(machine: secondMachine, instance: secondInstance)
        try fixture.seedRegistry(machine: machine, instance: secondInstance)
        try fixture.seedRegistry()
        let producer = try fixture.producer()
        defer { try? producer.stop() }
        let page = try await producer.overview(try EngramServiceWebOverviewRequest(), requestId: requestId,
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

        let limited = try await producer.sessions(try EngramServiceWebSessionsRequest(limit: 1),
                                                  requestId: requestId, deadline: fixture.deadline())
        XCTAssertEqual(limited.items.count, 1)
        XCTAssertNotNil(limited.nextCursor)

        for id in ["skip", "hidden", "child", "local-only"] {
            let detail = try await producer.sessionDetail(try EngramServiceWebSessionDetailRequest(sessionId: id),
                                                          requestId: requestId, deadline: fixture.deadline())
            XCTAssertNil(detail.detail, id)
        }
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
        let fields = ["source", "machine", "instance", "project", "limit", "queryBytes", "snapshot", "token", "kind"]
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
                source: field == "source" ? "codex" : "claude-code",
                machineId: field == "machine" ? secondMachine : machine,
                sourceInstanceId: field == "instance" ? secondInstance : instance,
                projectKey: field == "project" ? "project_2" : "project_1",
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
        XCTAssertNil(secretPath.projectKey)
        XCTAssertFalse(secretPath.projectLabel?.contains("sk-") == true)
        let path = try XCTUnwrap(page.items.first { $0.sessionId == "path-only" })
        XCTAssertNil(path.title)
        XCTAssertNil(path.projectKey)
        XCTAssertNil(path.projectLabel)
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
            ("limit", titleLimit, labelLimit, titleLimit, labelLimit, nil),
            ("over", titleLimit + "b", labelLimit + "b", nil, nil, nil),
            ("nul", "safe\u{0}secret", "safe\u{0}secret", nil, nil, nil),
            ("crossing", titleCrossing, labelCrossing, redactedTitle, redactedLabel, nil),
            ("valid-key", "safe", "project_1", "safe", "project_1", "project_1"),
            ("changed-token", "safe", changedValidToken, "safe", "[REDACTED]", nil),
            ("unsafe", "/Users/fixture/private.jsonl", "/Users/fixture/private", nil, nil, nil),
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

    private func validPolicy() -> ServiceWebMetadataPolicy {
        .init(parserRevision: parser, enabledSources: [.claudeCode])
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

private final class MetadataSQLFixture: @unchecked Sendable {
    let directory: URL
    let path: String
    let clock = WebMetadataTestClock()
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
                  }, liveClock: Bool = false) throws -> ServiceWebMetadataProducer {
        try ServiceWebMetadataProducer(
            databasePath: path,
            policy: policy,
            clock: liveClock ? .live : clock.clock,
            hooks: hooks
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

    func revoke(_ fault: MetadataAuthorityFault, sessionID: String, policy: PolicyBox) throws {
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

    func mutateReadyScalar(_ fault: MetadataReadyScalarFault) throws {
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
