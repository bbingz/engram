import CryptoKit
import Darwin
import Foundation
import GRDB
import Hummingbird
import HTTPTypes
import NIOCore
import XCTest
import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore
@testable import EngramRemoteServerCore

final class ServiceCapturePublicationConsumerTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let revision = "consumer-test-v1"
    private let token = "synthetic-publication-reader-token"
    private var root: URL!
    private var writer: EngramCoreWrite.EngramDatabaseWriter!
    private var gate: EngramServiceCore.ServiceWriterGate!
    private var cas: EngramCoreWrite.ImmutableArchiveCAS!
    private var replica: EngramRemoteServerCore.ArchiveStore!
    private var serving: Task<Void, Error>?
    private var baseURL: URL!
    private var policyBox = ConsumerPolicyBox()

    override func setUpWithError() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = checkout.appendingPathComponent(".engram-consumer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        writer = try EngramCoreWrite.EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        let ownedWriter = writer!
        gate = try EngramServiceCore.ServiceWriterGate(databasePath: root.appendingPathComponent("index.sqlite").path,
            runtimeDirectory: root, writerFactory: { _ in ownedWriter })
        cas = try EngramCoreWrite.ImmutableArchiveCAS(root: root.appendingPathComponent("central-cas"))
        replica = try EngramRemoteServerCore.ArchiveStore(root: root.appendingPathComponent("replica"),
            key: key, serverID: "hq", publicationsEnabled: true)
        try replica.warmPublicationIndex()
        policyBox.set(.init(parserRevision: revision, enabledSources: [.claudeCode]))
    }

    override func tearDown() async throws {
        serving?.cancel()
        _ = try? await serving?.value
        serving = nil
        gate = nil
        writer = nil
        replica = nil
        try FileManager.default.removeItem(at: root)
    }

    func testRealHTTPEmptyPagePersistsJournalAndRestartDiscoversLaterPublication() async throws {
        try await startServer()
        let first = makeConsumer()
        let empty = try await first.runOnce()
        XCTAssertEqual(empty, .accepted(pages: 1, publications: 0))
        let initial = try XCTUnwrap(checkpoint())
        XCTAssertEqual(try EngramCoreRead.CollectorPublicationCursor.decode(initial).afterArrivalOrdinal, 0)
        await first.stop()
        let fixture = try await seedOverHTTP(sequence: 1)
        let restarted = makeConsumer()
        let result = try await restarted.runOnce()
        XCTAssertEqual(result, .accepted(pages: 1, publications: 1))
        try assertDurable(fixture)
        let repeated = try await restarted.runOnce()
        XCTAssertEqual(repeated, .accepted(pages: 1, publications: 0))
        XCTAssertEqual(try count("capture_ingest_publications"), 1)
        XCTAssertEqual(try count("capture_ingest_ledger"), 1)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 1)
        await restarted.stop()
    }

    func testRealHTTPBoundedPagesAndRestartResume() async throws {
        _ = try seed(sequence: 1)
        _ = try seed(sequence: 2)
        _ = try seed(sequence: 3)
        try await startServer()
        let config = try configuration(pageLimit: 1, maxPages: 2)
        let consumer = makeConsumer(config: config)
        let result = try await consumer.runOnce()
        XCTAssertEqual(result, .accepted(pages: 2, publications: 2))
        XCTAssertEqual(try count("capture_ingest_publications"), 2)
        await consumer.stop()
        let second = makeConsumer(config: config)
        let resumed = try await second.runOnce()
        XCTAssertEqual(resumed, .accepted(pages: 1, publications: 1))
        XCTAssertEqual(try count("capture_ingest_publications"), 3)
        await second.stop()
    }

    func testUnknownSourceAndNewEpochAreNotAutomaticallyProvisionedOrParsed() async throws {
        try writer.write { db in
            _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: machine,
                sourceInstanceID: instance, source: .claudeCode, parseFormat: .claudeDefault,
                configuredRoot: "/synthetic/offline/projects", initialEpoch: epoch)
        }
        _ = try seed(sequence: 1, sourceInstance: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")
        _ = try seed(sequence: 1, collectorEpoch: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
        try await startServer()
        let consumer = makeConsumer()
        _ = try await consumer.runOnce()
        XCTAssertEqual(try count("capture_ingest_publications"), 2)
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
        XCTAssertEqual(try writer.read { db in
            try String.fetchOne(db, sql: "SELECT approved_epoch FROM capture_ingest_source_registry")
        }, epoch)
        XCTAssertEqual(try count("sessions"), 0)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
        XCTAssertEqual(try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_ingest_ledger WHERE status = 'pending'")
        }, 2)
        await consumer.stop()
    }

    func testWrongServerFailsBeforeCursorAdvanceEvenForEmptyPage() async throws {
        try await startServer()
        let config = try configuration(serverID: "wrong-server")
        try await assertRejected(makeConsumer(config: config))
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_checkpoints"), 0)
    }

    func testWrongJournalIsNotResetOrSilentlyRebound() async throws {
        let prior = try EngramCoreRead.CollectorPublicationCursor(
            journalID: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF", afterArrivalOrdinal: 0).encoded()
        try writer.write { db in
            try db.execute(sql: "INSERT INTO capture_ingest_checkpoints(server_id,cursor) VALUES ('hq', ?)", arguments: [prior])
        }
        try await startServer()
        try await assertRejected(makeConsumer())
        XCTAssertEqual(try checkpoint(), prior)
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
    }

    func testTransferBudgetFailureDoesNotAcceptOrAdvanceCursor() async throws {
        _ = try seed(sequence: 1, raw: Data(repeating: 7, count: 8192))
        try await startServer()
        try await assertRejected(makeConsumer(config: try configuration(maxRunBytes: 4096)))
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
    }

    func testRealHTTPMultiChunkCaptureResumesFromDurableCASAcrossConsumerRestarts() async throws {
        let fixture = try seedMultiChunk(sequence: 1, firstByte: 31, lastByte: 32)
        try await startServer()
        let config = try configuration(maxRunBytes: 9 * 1024 * 1024)
        await assertBudgetStop(config)
        XCTAssertTrue((try? cas.readObject(sha256: fixture.digests[0])) == fixture.chunks[0],
            "first run must durably retain its fitting 8 MiB prefix")
        XCTAssertThrowsError(try cas.readObject(sha256: fixture.digests[1]))
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)

        // Re-open the CAS and use a fresh consumer: progress must not depend on
        // an in-memory cursor, download buffer, or resumable side ledger.
        cas = try EngramCoreWrite.ImmutableArchiveCAS(root: root.appendingPathComponent("central-cas"))
        let restarted = makeConsumer(config: config)
        do {
            let result = try await restarted.runOnce()
            XCTAssertEqual(result, .accepted(pages: 1, publications: 1))
        } catch { XCTFail("a validated cached prefix must permit the second run to finish: \(error)") }
        await restarted.stop()
        XCTAssertNotNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 1)
        try assertMultiChunkDurable(fixture)
    }

    func testRealHTTPPageLargerThanRunBudgetRetainsProgressWithoutEarlyCursorAdvance() async throws {
        let first = try seedMultiChunk(sequence: 1, firstByte: 41, lastByte: 42)
        let second = try seedMultiChunk(sequence: 2, firstByte: 43, lastByte: 44)
        try await startServer()
        let config = try configuration(pageLimit: 2, maxPages: 1, maxRunBytes: 9 * 1024 * 1024)
        for round in 1...3 {
            await assertBudgetStop(config)
            XCTAssertNil(try checkpoint(), "round \(round) must not drop the unfinished page suffix")
            XCTAssertEqual(try count("capture_ingest_publications"), 0)
            XCTAssertEqual(try count("capture_ingest_ledger"), 0)
            XCTAssertTrue((try? cas.readObject(sha256: first.digests[0])) == first.chunks[0])
            if round >= 2 {
                XCTAssertTrue((try? cas.readObject(sha256: first.digests[1])) == first.chunks[1])
                XCTAssertTrue((try? cas.readManifest(sha256: first.manifestSHA)) == first.manifestBytes)
            }
            if round == 3 {
                XCTAssertTrue((try? cas.readObject(sha256: second.digests[0])) == second.chunks[0])
            }
            cas = try EngramCoreWrite.ImmutableArchiveCAS(root: root.appendingPathComponent("central-cas"))
        }
        let finishing = makeConsumer(config: config)
        do {
            let result = try await finishing.runOnce()
            XCTAssertEqual(result, .accepted(pages: 1, publications: 2))
        } catch { XCTFail("four bounded runs must complete the same durable page: \(error)") }
        await finishing.stop()
        XCTAssertEqual(try count("capture_ingest_publications"), 2)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 2)
        XCTAssertEqual(try count("capture_ingest_ledger"), 2)
        XCTAssertNotNil(try checkpoint())
        try assertMultiChunkDurable(first)
        try assertMultiChunkDurable(second)
    }

    func testCorruptCachedPrefixFailsClosedInsteadOfRedownloadingOrAccepting() async throws {
        let fixture = try seedMultiChunk(sequence: 1, firstByte: 51, lastByte: 52)
        for (digest, raw) in zip(fixture.digests, fixture.chunks) {
            _ = try cas.publishObject(raw: raw, expectedSHA256: digest)
        }
        let path = root.appendingPathComponent("central-cas/objects/sha256/\(fixture.digests[0].prefix(2))/\(fixture.digests[0])")
        let corrupt = Data(repeating: 99, count: fixture.chunks[0].count)
        try corrupt.write(to: path)
        try await startServer()
        let consumer = makeConsumer(config: try configuration(maxRunBytes: 9 * 1024 * 1024))
        do { _ = try await consumer.runOnce(); XCTFail("unverified cached bytes must never become an intake hit") }
        catch {
            XCTAssertEqual(error as? EngramCoreWrite.ImmutableArchiveCASError,
                .digestMismatch(expected: fixture.digests[0], actual: EngramCoreRead.ArchiveV2Hash.sha256(corrupt)))
        }
        await consumer.stop()
        XCTAssertTrue(try Data(contentsOf: path) == corrupt, "intake must not repair or overwrite a corrupt immutable object")
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        XCTAssertEqual(try count("capture_ingest_ledger"), 0)
    }

    func testActualHTTPRejectsDigestSizeAndOversizedPageResponses() async throws {
        let fixture = try seed(sequence: 1)
        for fault in [ConsumerHTTPFault.manifestDigest, .objectDigest, .objectSize, .pageSize] {
            try await startAdversarialServer(fixture: fixture, fault: fault)
            try await assertRejected(makeConsumer())
            XCTAssertNil(try checkpoint(), "fault: \(fault)")
            XCTAssertEqual(try count("capture_ingest_publications"), 0)
            serving?.cancel()
            _ = try? await serving?.value
            serving = nil
        }
    }

    func testActualHTTPRedirectIsNotFollowed() async throws {
        let fixture = try seed(sequence: 1)
        let followed = ConsumerFlag()
        try await startAdversarialServer(fixture: fixture, fault: .redirect, followed: followed)
        try await assertRejected(makeConsumer())
        XCTAssertFalse(followed.value, "redirect must not leak the bearer to a redirected request")
        XCTAssertNil(try checkpoint())
    }

    func testActualHTTPTransient503RetriesWithinConfiguredLimitAndAccepts() async throws {
        let fixture = try seed(sequence: 1)
        let attempts = ConsumerCounter()
        try await startAdversarialServer(fixture: fixture, fault: .retryOnce, attempts: attempts)
        let consumer = makeConsumer()
        let result = try await consumer.runOnce()
        XCTAssertEqual(result, .accepted(pages: 1, publications: 1))
        XCTAssertEqual(attempts.value, 2)
        try assertDurable(fixture)
        await consumer.stop()
    }

    func testActualHTTPPersistent503ExhaustsExactlyBoundedRetriesWithoutCursor() async throws {
        let fixture = try seed(sequence: 1)
        let attempts = ConsumerCounter()
        try await startAdversarialServer(fixture: fixture, fault: .unavailable, attempts: attempts)
        let consumer = makeConsumer()
        do { _ = try await consumer.runOnce(); XCTFail("persistent 503 must fail") }
        catch { XCTAssertEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError, .httpStatus(503)) }
        XCTAssertEqual(attempts.value, 3, "one initial attempt plus retryCount=2")
        XCTAssertNil(try checkpoint())
        await consumer.stop()
    }

    func testActualHTTPSlowResponseTimesOutWithBoundedAttempts() async throws {
        let fixture = try seed(sequence: 1)
        let attempts = ConsumerCounter()
        try await startAdversarialServer(fixture: fixture, fault: .slow, attempts: attempts)
        let config = try EngramServiceCore.ServiceCaptureIngestConfiguration(serverID: "hq", baseURL: baseURL,
            credentialID: "synthetic-hq", requestTimeout: 0.1, retryCount: 1)
        let consumer = makeConsumer(config: config)
        let start = ContinuousClock.now
        do { _ = try await consumer.runOnce(); XCTFail("slow response must time out") }
        catch { XCTAssertEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError, .transportUnavailable) }
        XCTAssertEqual(attempts.value, 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        XCTAssertNil(try checkpoint())
        await consumer.stop()
    }

    func testActualHTTPPartialTimeoutConsumesRunBudgetAcrossRetryAttempts() async throws {
        let fixture = try seed(sequence: 1)
        let attempts = ConsumerCounter()
        try await startAdversarialServer(fixture: fixture, fault: .partialSlow, attempts: attempts)
        let config = try EngramServiceCore.ServiceCaptureIngestConfiguration(serverID: "hq", baseURL: baseURL,
            credentialID: "synthetic-hq", maxRunBytes: 1024, requestTimeout: 0.1, retryCount: 2)
        let consumer = makeConsumer(config: config)
        do { _ = try await consumer.runOnce(); XCTFail("partial attempts must not bypass the run byte limit") }
        catch { XCTAssertEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError, .responseTooLarge) }
        // Attempt one delivers 768 bytes then times out. Only 256 bytes remain,
        // so attempt two must reject its 768-byte body without a third attempt.
        XCTAssertEqual(attempts.value, 2)
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        await consumer.stop()
    }

    func testStopWhileQueuedAtWriterGateJoinsWithoutAcceptingOrBlockingLaterWrites() async throws {
        _ = try seed(sequence: 1)
        try await startServer()
        let downloaded = expectation(description: "download completed")
        let releaseDownload = ConsumerRelease()
        let consumer = makeConsumer(hooks: .init(afterDownload: {
            downloaded.fulfill()
            await releaseDownload.wait()
        }))
        let running = Task { try await consumer.runOnce() }
        await fulfillment(of: [downloaded], timeout: 5)
        let held = expectation(description: "writer gate held")
        let releaseGate = ConsumerRelease()
        let gate = self.gate!
        let holder = Task {
            try await gate.performWriteCommand(name: "syntheticGateHolder") { _ in
                held.fulfill()
                await releaseGate.wait()
                return true
            }
        }
        await fulfillment(of: [held], timeout: 5)
        await releaseDownload.release()
        // The serialized gate remains held throughout stop; joining cannot
        // depend on letting the holder finish or permitting acceptance.
        let stopped = expectation(description: "stop joined queued consumer")
        let stopper = Task { await consumer.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertNil(try checkpoint())
        await releaseGate.release()
        _ = try await holder.value
        _ = await stopper.value
        do { _ = try await running.value; XCTFail("cancelled queued intake returned success") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        _ = try await gate.performWriteCommand(name: "afterQueuedStop") { _ in true }
    }

    func testCorruptCentralObjectPreventsAcceptanceAndCursorAdvance() async throws {
        let fixture = try seed(sequence: 1)
        _ = try cas.publishObject(raw: fixture.raw, expectedSHA256: fixture.chunkSHA)
        let path = root.appendingPathComponent("central-cas/objects/sha256/\(fixture.chunkSHA.prefix(2))/\(fixture.chunkSHA)")
        try Data("corrupt".utf8).write(to: path)
        try await startServer()
        try await assertRejected(makeConsumer())
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
    }

    func testCASIsDurableBeforeAtomicAcceptanceAndTransactionFailureRollsBackCursor() async throws {
        let fixture = try seed(sequence: 1)
        try await startServer()
        let cas = self.cas!
        let observed = ConsumerFlag()
        let consumer = makeConsumer(hooks: .init(beforeAcceptance: {
            XCTAssertEqual(try cas.readObject(sha256: fixture.chunkSHA), fixture.raw)
            XCTAssertEqual(try cas.readManifest(sha256: fixture.manifestSHA), fixture.manifestBytes)
            observed.set()
        }, afterAcceptance: { throw ConsumerTestError.injected }))
        try await assertRejected(consumer)
        XCTAssertTrue(observed.value)
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 0)
        XCTAssertEqual(try count("capture_ingest_ledger"), 0)
    }

    func testPolicyRevokedAfterTransferDoesNotAccept() async throws {
        _ = try seed(sequence: 1)
        try await startServer()
        let policy = policyBox
        let entered = ConsumerFlag()
        let consumer = makeConsumer(hooks: .init(afterDownload: { policy.set(nil); entered.set() }))
        try await assertRejected(consumer)
        XCTAssertTrue(entered.value)
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
    }

    func testRealHTTPByteDistinctUnicodeParserRevisionChangeRevokesAcceptance() async throws {
        _ = try seed(sequence: 1)
        try await startServer()
        let composed = "revision-\u{00E9}"
        let decomposed = "revision-e\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality is canonically equivalent here")
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8), "durable parser identity is byte-exact")
        policyBox.set(.init(parserRevision: composed, enabledSources: [.claudeCode]))
        let policy = policyBox
        let entered = ConsumerFlag()
        let consumer = makeConsumer(hooks: .init(afterDownload: {
            policy.set(.init(parserRevision: decomposed, enabledSources: [.claudeCode]))
            entered.set()
        }))
        do { _ = try await consumer.runOnce(); XCTFail("byte-distinct parser revision must revoke the downloaded page") }
        catch { XCTAssertEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError, .policyChanged) }
        await consumer.stop()
        XCTAssertTrue(entered.value, "revocation must occur after the real HTTP transfer")
        XCTAssertNil(try checkpoint())
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        XCTAssertEqual(try count("capture_ingest_arrivals"), 0)
        XCTAssertEqual(try count("capture_ingest_ledger"), 0)
    }

    func testStopCancelsAndJoinsOwnedTransferBeforeAcceptance() async throws {
        _ = try seed(sequence: 1)
        try await startServer()
        let entered = expectation(description: "download reached fence")
        let exited = ConsumerFlag()
        let consumer = makeConsumer(hooks: .init(afterDownload: {
            entered.fulfill()
            defer { exited.set() }
            try await Task.sleep(for: .seconds(60))
        }))
        let task = Task { try await consumer.runOnce() }
        await fulfillment(of: [entered], timeout: 5)
        await consumer.stop()
        do { _ = try await task.value; XCTFail("cancelled transfer returned success") }
        catch { XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)") }
        XCTAssertTrue(exited.value)
        XCTAssertNil(try checkpoint())
        let stopped = try await consumer.runOnce()
        XCTAssertEqual(stopped, .idle)
        _ = try await gate.performWriteCommand(name: "postConsumerStop") { _ in true }
    }

    func testDefaultOffDoesNotCallCredentialProviderOrWriteAnything() async throws {
        let called = ConsumerFlag()
        let consumer = EngramServiceCore.ServiceCapturePublicationConsumer(gate: gate, cas: cas,
            configuration: { nil }, policy: { nil }, credential: { _ in called.set(); return nil })
        let result = try await consumer.runOnce()
        XCTAssertEqual(result, .idle)
        XCTAssertFalse(called.value)
        XCTAssertEqual(try count("capture_ingest_checkpoints"), 0)
        await consumer.stop()
    }

    func testOwnerOnlySettingsExplicitOptInAndMalformedValuesFailClosed() throws {
        let settings = root.appendingPathComponent("settings.json")
        XCTAssertNil(try EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: settings))
        try writeSettings(["unrelated": true], at: settings)
        XCTAssertNil(try EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: settings))
        let enabled: [String: Any] = ["enabled": true, "serverID": "hq", "baseURL": "https://hq.example",
            "credentialID": "archive-hq"]
        try writeSettings(["captureIngest": enabled], at: settings)
        let config = try XCTUnwrap(EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: settings))
        XCTAssertEqual(config.serverID, "hq")
        XCTAssertEqual(config.credentialID, "archive-hq")
        for bad in [["enabled": 1], ["enabled": true], enabled.merging(["token": "do-not-accept-inline-secret"]) { _, new in new },
                    enabled.merging(["baseURL": "http://public.example"]) { _, new in new },
                    enabled.merging(["baseURL": "https://u:p@hq.example"]) { _, new in new }] {
            try writeSettings(["captureIngest": bad], at: settings)
            XCTAssertThrowsError(try EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: settings))
        }
        try writeSettings(["captureIngest": enabled], at: settings)
        XCTAssertEqual(chmod(settings.path, 0o644), 0)
        XCTAssertThrowsError(try EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: settings))
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
        let link = root.appendingPathComponent("linked-settings.json")
        XCTAssertEqual(symlink(settings.path, link.path), 0)
        XCTAssertThrowsError(try EngramServiceCore.ServiceCaptureIngestConfiguration.load(at: link))
    }

    private var key: SymmetricKey { SymmetricKey(data: Data(repeating: 9, count: 32)) }

    private func startServer() async throws {
        // The seed store owns a process-local journal lock. Release it before
        // the real app opens and warms its own single publication owner.
        replica = nil
        let archive = EngramRemoteServerCore.EngramRemoteArchiveConfig(serverID: "hq",
            root: root.appendingPathComponent("replica"), bearerToken: token,
            atRestKey: key, publicationsEnabled: true)
        let config = EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: 0,
            storeRoot: root.appendingPathComponent("legacy"), bearerToken: "synthetic-distinct-legacy",
            atRestKey: SymmetricKey(data: Data(repeating: 8, count: 32)), archiveV2: archive)
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: config)
        let bound = expectation(description: "temporary RemoteServer bound")
        let portBox = ConsumerPort()
        serving = Task { try await app.run { port in portBox.set(port); bound.fulfill() } }
        await fulfillment(of: [bound], timeout: 10)
        baseURL = URL(string: "http://127.0.0.1:\(try XCTUnwrap(portBox.value))")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for attempt in 0..<7 {
            var request = URLRequest(url: baseURL.appendingPathComponent("v2/archive/publications"), timeoutInterval: 2)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await session.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            if status == 200 {
                _ = try EngramCoreRead.ArchiveCanonicalJSON.decode(EngramCoreRead.CollectorPublicationPage.self, from: bytes)
                return
            }
            guard status == 503, attempt < 6 else { throw ConsumerTestError.serverNotReady }
            try await Task.sleep(for: .milliseconds(20 * (1 << attempt)))
        }
    }

    private func startAdversarialServer(fixture: Fixture, fault: ConsumerHTTPFault,
                                        followed: ConsumerFlag = ConsumerFlag(),
                                        attempts: ConsumerCounter = ConsumerCounter()) async throws {
        let router = Router()
        let capabilities = try EngramCoreRead.ArchiveCanonicalJSON.encode(
            EngramCoreRead.CollectorPublicationCapabilities(serverID: "hq"))
        let page = try EngramRemoteServerCore.ArchiveCanonicalJSON.encode(replica.listPublications(cursor: nil, limit: 10))
        let token = self.token
        func response(_ bytes: Data) -> Response {
            Response(status: .ok, headers: [.contentType: "application/json", .contentLength: "\(bytes.count)"],
                body: .init(byteBuffer: ByteBuffer(data: bytes)))
        }
        router.get("/v2/archive/publication-capabilities") { request, _ in
            guard request.headers[.authorization] == "Bearer \(token)" else { return Response(status: .unauthorized) }
            let attempt = attempts.increment()
            if fault == .unavailable || (fault == .retryOnce && attempt == 1) {
                return Response(status: .serviceUnavailable)
            }
            if fault == .slow { try await Task.sleep(for: .seconds(1)) }
            if fault == .partialSlow {
                return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody { writer in
                    try await writer.write(ByteBuffer(bytes: [UInt8](repeating: 32, count: 768)))
                    try await Task.sleep(for: .seconds(1))
                    try await writer.finish(nil)
                })
            }
            if fault == .redirect {
                return Response(status: .temporaryRedirect, headers: [.location: "/redirected"])
            }
            return response(capabilities)
        }
        router.get("/redirected") { _, _ in followed.set(); return response(capabilities) }
        router.get("/v2/archive/publications") { _, _ in
            response(fault == .pageSize ? Data(repeating: 32, count: 262145) : page)
        }
        router.get("/v2/archive/manifests/:digest") { _, _ in
            response(fault == .manifestDigest ? fixture.manifestBytes + Data([10]) : fixture.manifestBytes)
        }
        router.get("/v2/archive/objects/:digest") { _, _ in
            let bytes: Data
            switch fault {
            case .objectDigest: bytes = Data(repeating: 7, count: fixture.raw.count)
            case .objectSize: bytes = fixture.raw + Data([7])
            default: bytes = fixture.raw
            }
            return response(bytes)
        }
        let bound = expectation(description: "adversarial HTTP listener bound")
        let portBox = ConsumerPort()
        let app = Application(router: router,
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port { portBox.set(port); bound.fulfill() }
            })
        serving = Task { try await app.run() }
        await fulfillment(of: [bound], timeout: 10)
        baseURL = URL(string: "http://127.0.0.1:\(try XCTUnwrap(portBox.value))")!
    }

    private func configuration(serverID: String = "hq", pageLimit: Int = 10,
                               maxPages: Int = 2, maxRunBytes: Int = 32 * 1024 * 1024) throws -> EngramServiceCore.ServiceCaptureIngestConfiguration {
        try .init(serverID: serverID, baseURL: baseURL, credentialID: "synthetic-hq",
            pageLimit: pageLimit, maxPages: maxPages, maxRunBytes: maxRunBytes,
            requestTimeout: 2, retryCount: 2)
    }

    private func makeConsumer(config: EngramServiceCore.ServiceCaptureIngestConfiguration? = nil,
                              hooks: EngramServiceCore.ServiceCapturePublicationConsumerHooks = .init()) -> EngramServiceCore.ServiceCapturePublicationConsumer {
        let configuration = config ?? (try! self.configuration())
        let box = policyBox
        let token = self.token
        return .init(gate: gate, cas: cas, configuration: { configuration }, policy: { box.value },
            credential: { identifier in identifier == "synthetic-hq" ? token : nil }, hooks: hooks)
    }

    private struct Fixture: Sendable {
        let raw: Data
        let chunkSHA: String
        let manifestSHA: String
        let manifestBytes: Data
        let publicationSHA: String
        let publicationBytes: Data
    }

    private struct MultiChunkFixture: Sendable {
        let chunks: [Data]
        let digests: [String]
        let manifestSHA: String
        let manifestBytes: Data
    }

    private func seedMultiChunk(sequence: Int64, firstByte: UInt8, lastByte: UInt8) throws -> MultiChunkFixture {
        let chunks = [Data(repeating: firstByte, count: Int(EngramCoreRead.ArchiveSourceManifest.rawChunkSize)),
            Data(repeating: lastByte, count: 2 * 1024 * 1024)]
        let digests = chunks.map { EngramCoreRead.ArchiveV2Hash.sha256($0) }
        var whole = SHA256()
        for chunk in chunks { whole.update(data: chunk) }
        let wholeDigest = whole.finalize().map { String(format: "%02x", $0) }.joined()
        let size = Int64(chunks.reduce(0) { $0 + $1.count })
        let manifest = try EngramCoreRead.ArchiveSourceManifest(
            captureID: EngramCoreRead.ArchiveV2Hash.sha256(Data("synthetic-multichunk-\(sequence)-\(firstByte)".utf8)),
            machineID: machine, source: "claude-code", locator: "/synthetic/offline/projects/multi-\(sequence).jsonl",
            sessionID: nil, capturedAt: "2026-09-06T00:00:00Z",
            generation: .init(device: 1, inode: sequence, size: size, mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: wholeDigest, rawByteCount: size,
            chunks: try chunks.enumerated().map { index, bytes in
                try .init(ordinal: index, rawSHA256: digests[index], rawByteCount: Int64(bytes.count))
            }, replayLayout: .init(strategy: .singleFile, relativePaths: ["multi-\(sequence).jsonl"]))
        let bytes = try EngramCoreRead.ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA = EngramCoreRead.ArchiveV2Hash.sha256(bytes)
        for (digest, raw) in zip(digests, chunks) { _ = try replica.putObject(digest: digest, raw: raw) }
        _ = try replica.putManifest(digest: manifestSHA, canonicalBytes: bytes)
        let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: instance,
            collectorEpoch: epoch, sequence: sequence, manifestSHA256: manifestSHA)
        _ = try replica.acceptPublication(digest: publication.sha256(),
            canonicalBytes: EngramCoreRead.ArchiveCanonicalJSON.encode(publication))
        return .init(chunks: chunks, digests: digests, manifestSHA: manifestSHA, manifestBytes: bytes)
    }

    private func assertMultiChunkDurable(_ fixture: MultiChunkFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for (digest, raw) in zip(fixture.digests, fixture.chunks) {
            XCTAssertTrue((try? cas.readObject(sha256: digest)) == raw, "exact chunk must be present", file: file, line: line)
        }
        XCTAssertTrue((try? cas.readManifest(sha256: fixture.manifestSHA)) == fixture.manifestBytes,
            "exact manifest must be present", file: file, line: line)
        XCTAssertEqual(try count("sessions"), 0, file: file, line: line)
    }

    private func assertBudgetStop(_ config: EngramServiceCore.ServiceCaptureIngestConfiguration,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let consumer = makeConsumer(config: config)
        do { _ = try await consumer.runOnce(); XCTFail("the run must yield at its byte budget", file: file, line: line) }
        catch {
            XCTAssertEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError,
                .transferBudgetExceeded, file: file, line: line)
        }
        await consumer.stop()
    }

    private func seed(sequence: Int64, sourceInstance: String? = nil, collectorEpoch: String? = nil,
                      raw: Data? = nil) throws -> Fixture {
        let fixture = try makeFixture(sequence: sequence, sourceInstance: sourceInstance,
            collectorEpoch: collectorEpoch, raw: raw)
        _ = try replica.putObject(digest: fixture.chunkSHA, raw: fixture.raw)
        _ = try replica.putManifest(digest: fixture.manifestSHA, canonicalBytes: fixture.manifestBytes)
        _ = try replica.acceptPublication(digest: fixture.publicationSHA, canonicalBytes: fixture.publicationBytes)
        return fixture
    }

    private func seedOverHTTP(sequence: Int64) async throws -> Fixture {
        let fixture = try makeFixture(sequence: sequence)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (path, bytes, contentType) in [
            ("objects/\(fixture.chunkSHA)", fixture.raw, "application/octet-stream"),
            ("manifests/\(fixture.manifestSHA)", fixture.manifestBytes, "application/json"),
            ("publications/\(fixture.publicationSHA)", fixture.publicationBytes, "application/json")
        ] {
            var request = URLRequest(url: baseURL.appendingPathComponent("v2/archive/\(path)"), timeoutInterval: 2)
            request.httpMethod = "PUT"
            request.httpBody = bytes
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            guard status == 200 || status == 201 else { throw ConsumerTestError.serverNotReady }
        }
        return fixture
    }

    private func makeFixture(sequence: Int64, sourceInstance: String? = nil, collectorEpoch: String? = nil,
                             raw: Data? = nil) throws -> Fixture {
        let raw = raw ?? Data("synthetic exact bytes \(sequence)".utf8)
        let digest = EngramCoreRead.ArchiveV2Hash.sha256(raw)
        let manifest = try EngramCoreRead.ArchiveSourceManifest(
            captureID: EngramCoreRead.ArchiveV2Hash.sha256(Data(UUID().uuidString.utf8)),
            machineID: machine, source: "claude-code", locator: "/synthetic/offline/projects/session.jsonl",
            sessionID: nil, capturedAt: "2026-09-06T00:00:00Z",
            generation: .init(device: 1, inode: 2, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: digest, rawByteCount: Int64(raw.count),
            chunks: [try .init(ordinal: 0, rawSHA256: digest, rawByteCount: Int64(raw.count))],
            replayLayout: .init(strategy: .singleFile, relativePaths: ["session.jsonl"]))
        let bytes = try EngramCoreRead.ArchiveCanonicalJSON.encode(manifest)
        let manifestSHA = EngramCoreRead.ArchiveV2Hash.sha256(bytes)
        let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machine,
            sourceInstanceID: sourceInstance ?? instance, collectorEpoch: collectorEpoch ?? epoch,
            sequence: sequence, manifestSHA256: manifestSHA)
        let publicationSHA = try publication.sha256()
        return .init(raw: raw, chunkSHA: digest, manifestSHA: manifestSHA,
            manifestBytes: bytes, publicationSHA: publicationSHA,
            publicationBytes: try EngramCoreRead.ArchiveCanonicalJSON.encode(publication))
    }

    private func assertDurable(_ fixture: Fixture) throws {
        XCTAssertEqual(try cas.readObject(sha256: fixture.chunkSHA), fixture.raw)
        XCTAssertEqual(try cas.readManifest(sha256: fixture.manifestSHA), fixture.manifestBytes)
        XCTAssertEqual(try writer.read { db in
            try EngramCoreWrite.CaptureIngestLedger.entry(db, publicationSHA256: fixture.publicationSHA,
                parserRevision: revision)?.status
        }, .pending)
        XCTAssertEqual(try count("sessions"), 0)
    }

    private func checkpoint() throws -> String? {
        try writer.read { try EngramCoreWrite.CaptureIngestLedger.checkpoint($0, serverID: "hq") }
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    private func assertRejected(_ consumer: EngramServiceCore.ServiceCapturePublicationConsumer,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        do { _ = try await consumer.runOnce(); XCTFail("must reject", file: file, line: line) }
        catch { XCTAssertNotEqual(error as? EngramServiceCore.ServiceCapturePublicationConsumerError,
            .notImplemented, "failure must be a real fence, not the RED stub", file: file, line: line) }
        await consumer.stop()
    }

    private func writeSettings(_ object: [String: Any], at url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
}

private enum ConsumerTestError: Error { case injected, serverNotReady }
private enum ConsumerHTTPFault: Sendable {
    case manifestDigest, objectDigest, objectSize, pageSize, redirect, retryOnce, unavailable, slow, partialSlow
}
private final class ConsumerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); defer { lock.unlock() }; storage = true }
}
private final class ConsumerPort: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: Int) { lock.lock(); defer { lock.unlock() }; storage = value }
}
private final class ConsumerPolicyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: EngramServiceCore.ServiceCaptureIngestParserPolicy?
    var value: EngramServiceCore.ServiceCaptureIngestParserPolicy? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: EngramServiceCore.ServiceCaptureIngestParserPolicy?) { lock.lock(); defer { lock.unlock() }; storage = value }
}
private final class ConsumerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; storage += 1; return storage }
}
private actor ConsumerRelease {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}
