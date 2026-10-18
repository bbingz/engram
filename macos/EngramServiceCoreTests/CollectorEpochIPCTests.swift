import Darwin
import EngramCoreRead
@testable import EngramCoreWrite
import Foundation
import GRDB
import XCTest
@testable import EngramServiceCore

/// W4.7 HQ operator surface. Invariant "Collector Epoch Approval Is A Local
/// Operator Action".
final class CollectorEpochIPCTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let unknownInstance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBB0"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let nextEpoch = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let strayEpoch = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let rootPath = "/synthetic-epoch/codex"
    private var directory: URL!
    private var settingsURL: URL!
    private var writer: EngramDatabaseWriter!
    private var gate: ServiceWriterGate!
    private var previousSettingsPath: String?
    private var nextOrdinal: Int64 = 1

    override func setUpWithError() throws {
        guard let canonicalTemp = Darwin.realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(canonicalTemp) }
        directory = URL(fileURLWithPath: String(cString: canonicalTemp), isDirectory: true)
            .appendingPathComponent("collector-epoch-\(UUID().uuidString)", isDirectory: true)
        let runtime = directory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        settingsURL = directory.appendingPathComponent("settings.json")
        let databasePath = directory.appendingPathComponent("index.sqlite").path
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        let owned = writer!
        gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: runtime,
                                     writerFactory: { _ in owned })
        try writer.write { db in
            _ = try CaptureIngestSourceRegistry.provision(
                db, machineID: machine, sourceInstanceID: instance, source: .codex,
                parseFormat: .codex, configuredRoot: rootPath, initialEpoch: epoch
            )
        }
        try writeSettings(settings())
        previousSettingsPath = getenv("ENGRAM_SETTINGS_PATH").map { String(cString: $0) }
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousSettingsPath { setenv("ENGRAM_SETTINGS_PATH", previousSettingsPath, 1) }
        else { unsetenv("ENGRAM_SETTINGS_PATH") }
        gate = nil
        writer = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testCollectorEpochCapabilityAndWebBoundary() {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("collectorApproveEpoch"))
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("collectorEpochDryRun"))
        for command in ["collectorApproveEpoch", "collectorEpochDryRun"] {
            XCTAssertThrowsError(try EngramServiceWebWriteClient.validateCommand(command)) {
                XCTAssertEqual($0 as? EngramServiceWebWriteClientError, .unsupported)
            }
            XCTAssertThrowsError(try EngramServiceWebReadClient.validateCommand(command)) {
                XCTAssertEqual($0 as? EngramServiceWebReadClientError, .unsupported)
            }
        }
    }

    func testDryRunReportsExpectedBindingAndBacklogWithoutWriting() async throws {
        try accept(epoch: epoch, sequence: 1)
        try accept(epoch: nextEpoch, sequence: 2)
        try accept(epoch: nextEpoch, sequence: 3)
        try accept(epoch: strayEpoch, sequence: 4)
        let before = try snapshot()
        let generationBefore = await gate.currentDatabaseGeneration()

        let response: EngramServiceCollectorEpochDryRunResponse = try await success(
            "collectorEpochDryRun", dryRunPayload(candidate: nextEpoch)
        )

        XCTAssertTrue(response.dryRun)
        XCTAssertEqual(response.current, binding(epoch: epoch, generation: 1))
        XCTAssertEqual(response.candidateEpoch, nextEpoch)
        XCTAssertFalse(response.candidateWasPreviouslyApproved)
        XCTAssertEqual(response.currentBacklog.publicationCount, 1)
        XCTAssertEqual(response.currentBacklog.ledgerTaskCounts["pending"], 1)
        XCTAssertEqual(response.candidateBacklog.publicationCount, 2)
        XCTAssertEqual(response.candidateBacklog.ledgerTaskCounts["pending"], 2)
        XCTAssertEqual(response.candidateBacklog.ledgerTaskCounts["parsed"], 0)
        XCTAssertEqual(response.observedUnapprovedEpochs, [
            EngramServiceCollectorObservedEpoch(collectorEpoch: nextEpoch, publicationCount: 2),
            EngramServiceCollectorObservedEpoch(collectorEpoch: strayEpoch, publicationCount: 1),
        ])
        XCTAssertEqual(try snapshot(), before)
        let generationAfter = await gate.currentDatabaseGeneration()
        XCTAssertEqual(generationAfter, generationBefore)
    }

    func testApproveAdvancesGenerationAndAppendsHistory() async throws {
        let response: EngramServiceCollectorApproveEpochResponse = try await success(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1)
        )

        XCTAssertEqual(response.previousEpoch, epoch)
        XCTAssertEqual(response.previousAuthorityGeneration, 1)
        XCTAssertEqual(response.current, binding(epoch: nextEpoch, generation: 2))
        let history = try writer.read {
            try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance)
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.last?.previousEpoch, epoch)
        XCTAssertEqual(history.last?.approvedEpoch, nextEpoch)
        XCTAssertEqual(history.last?.authorityGeneration, 2)

        let dryRun: EngramServiceCollectorEpochDryRunResponse = try await success(
            "collectorEpochDryRun", dryRunPayload(candidate: epoch)
        )
        XCTAssertEqual(dryRun.current, binding(epoch: nextEpoch, generation: 2))
        XCTAssertTrue(dryRun.candidateWasPreviouslyApproved)
    }

    func testApproveRefusesStaleExpectedBindingWithoutWriting() async throws {
        let before = try snapshot()
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: strayEpoch, generation: 1),
            reason: "staleBinding"
        )
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 2),
            reason: "staleBinding"
        )
        XCTAssertEqual(try snapshot(), before)

        let _: EngramServiceCollectorApproveEpochResponse = try await success(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1)
        )
        let applied = try snapshot()
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "staleBinding"
        )
        XCTAssertEqual(try snapshot(), applied)
    }

    func testApproveRefusesPreviouslyApprovedEpoch() async throws {
        let _: EngramServiceCollectorApproveEpochResponse = try await success(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1)
        )
        let applied = try snapshot()
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: epoch, expected: nextEpoch, generation: 2),
            reason: "epochPreviouslyApproved"
        )
        XCTAssertEqual(try snapshot(), applied)
    }

    func testApproveRefusesUnregisteredInstanceAndNoncanonicalIDs() async throws {
        let before = try snapshot()
        try await assertRefused(
            "collectorApproveEpoch",
            approvePayload(instance: unknownInstance, candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "unregisteredSourceInstance"
        )
        try await assertRefused(
            "collectorEpochDryRun", dryRunPayload(instance: unknownInstance, candidate: nextEpoch),
            reason: "unregisteredSourceInstance"
        )
        try await assertRefused(
            "collectorApproveEpoch",
            approvePayload(machine: machine.lowercased(), candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "invalidMachineID"
        )
        try await assertRefused(
            "collectorApproveEpoch",
            approvePayload(candidate: nextEpoch.lowercased(), expected: epoch, generation: 1),
            reason: "invalidEpoch"
        )
        try await assertRefused(
            "collectorEpochDryRun", dryRunPayload(candidate: nextEpoch.lowercased()),
            reason: "invalidEpoch"
        )
        XCTAssertEqual(try snapshot(), before)
    }

    func testApproveAndDryRunRefuseOutsideIndexRole() async throws {
        let before = try snapshot()
        try writeSettings(settings(role: "local"))
        try await assertRefused("collectorEpochDryRun", dryRunPayload(candidate: nextEpoch),
                                reason: "capturePolicyUnavailable")
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "capturePolicyUnavailable"
        )
        var missingCapture = settings()
        missingCapture.removeValue(forKey: "captureIngest")
        try writeSettings(missingCapture)
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "capturePolicyUnavailable"
        )
        try writeSettings(settings(disabled: ["codex"]))
        try await assertRefused(
            "collectorApproveEpoch", approvePayload(candidate: nextEpoch, expected: epoch, generation: 1),
            reason: "sourceDisabled"
        )
        XCTAssertEqual(try snapshot(), before)
    }

    func testCollectorEpochCommandsRejectMissingOrExtraPayloadKeys() async throws {
        let before = try snapshot()
        let validDryRun = dryRunPayload(candidate: nextEpoch)
        let validApprove = approvePayload(candidate: nextEpoch, expected: epoch, generation: 1)
        var missingDryRun = validDryRun
        missingDryRun.removeValue(forKey: "candidateEpoch")
        var extraDryRun = validDryRun
        extraDryRun["expectedEpoch"] = epoch
        var missingApprove = validApprove
        missingApprove.removeValue(forKey: "expectedAuthorityGeneration")
        var extraApprove = validApprove
        extraApprove["force"] = true
        var wrongType = validApprove
        wrongType["expectedAuthorityGeneration"] = "1"
        let cases: [(String, [String: Any]?)] = [
            ("collectorEpochDryRun", nil), ("collectorEpochDryRun", missingDryRun),
            ("collectorEpochDryRun", extraDryRun), ("collectorApproveEpoch", nil),
            ("collectorApproveEpoch", missingApprove), ("collectorApproveEpoch", extraApprove),
            ("collectorApproveEpoch", wrongType),
        ]
        for (command, payload) in cases {
            let error = try await failure(command, payload)
            XCTAssertEqual(error.name, "InvalidRequest", "\(command) \(String(describing: payload))")
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testClientSendsExactCommandNamesAndPayloads() async throws {
        let dryRun = EngramServiceCollectorEpochDryRunResponse(
            dryRun: true, current: binding(epoch: epoch, generation: 1), candidateEpoch: nextEpoch,
            candidateWasPreviouslyApproved: false,
            currentBacklog: .init(publicationCount: 0, ledgerTaskCounts: [:]),
            candidateBacklog: .init(publicationCount: 0, ledgerTaskCounts: [:]),
            observedUnapprovedEpochs: []
        )
        let approve = EngramServiceCollectorApproveEpochResponse(
            previousEpoch: epoch, previousAuthorityGeneration: 1, current: binding(epoch: nextEpoch, generation: 2)
        )
        let transport = CollectorEpochRecordingTransport { request in
            let result: Data
            switch request.command {
            case "collectorEpochDryRun": result = try JSONEncoder().encode(dryRun)
            case "collectorApproveEpoch": result = try JSONEncoder().encode(approve)
            default: throw EngramServiceError.invalidRequest(message: "unexpected command")
            }
            return .success(requestId: request.requestId, result: result)
        }
        let client = EngramServiceClient(transport: transport)

        let dryRunResult = try await client.collectorEpochDryRun(.init(
            machineID: machine, sourceInstanceID: instance, candidateEpoch: nextEpoch
        ))
        XCTAssertEqual(dryRunResult, dryRun)
        let approveResult = try await client.collectorApproveEpoch(.init(
            machineID: machine, sourceInstanceID: instance, candidateEpoch: nextEpoch,
            expectedEpoch: epoch, expectedAuthorityGeneration: 1
        ))
        XCTAssertEqual(approveResult, approve)

        let requests = transport.requestsSnapshot()
        XCTAssertEqual(requests.map(\.command), ["collectorEpochDryRun", "collectorApproveEpoch"])
        let keys = try requests.map { request in
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.payload)) as? [String: Any]).keys)
        }
        XCTAssertEqual(keys, [
            ["machineID", "sourceInstanceID", "candidateEpoch"],
            ["machineID", "sourceInstanceID", "candidateEpoch", "expectedEpoch", "expectedAuthorityGeneration"],
        ])
    }

    // MARK: - Harness

    private func handler() -> EngramServiceCommandHandler {
        EngramServiceCommandHandler(writerGate: gate)
    }

    private func send(_ command: String, _ payload: [String: Any]?) async throws -> EngramServiceResponseEnvelope {
        let data = try payload.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return await handler().handle(EngramServiceRequestEnvelope(command: command, payload: data))
    }

    private func success<T: Decodable>(_ command: String, _ payload: [String: Any]) async throws -> T {
        let response = try await send(command, payload)
        guard case .success(_, let result, _) = response else {
            XCTFail("\(command) must succeed, got \(response)")
            throw EngramServiceError.invalidRequest(message: "unexpected failure")
        }
        return try JSONDecoder().decode(T.self, from: result)
    }

    private func failure(_ command: String, _ payload: [String: Any]?) async throws -> EngramServiceErrorEnvelope {
        let response = try await send(command, payload)
        guard case .failure(_, let error) = response else {
            XCTFail("\(command) must fail")
            throw EngramServiceError.invalidRequest(message: "unexpected success")
        }
        return error
    }

    private func assertRefused(
        _ command: String, _ payload: [String: Any], reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let error = try await failure(command, payload)
        XCTAssertEqual(error.name, "CollectorEpochRefused", file: file, line: line)
        XCTAssertEqual(error.retryPolicy, "never", file: file, line: line)
        XCTAssertEqual(error.details?["reason"], .string(reason), file: file, line: line)
    }

    private func dryRunPayload(machine: String? = nil, instance: String? = nil, candidate: String) -> [String: Any] {
        ["machineID": machine ?? self.machine, "sourceInstanceID": instance ?? self.instance,
         "candidateEpoch": candidate]
    }

    private func approvePayload(
        machine: String? = nil, instance: String? = nil, candidate: String, expected: String, generation: Int64
    ) -> [String: Any] {
        ["machineID": machine ?? self.machine, "sourceInstanceID": instance ?? self.instance,
         "candidateEpoch": candidate, "expectedEpoch": expected, "expectedAuthorityGeneration": generation]
    }

    private func binding(epoch: String, generation: Int64) -> EngramServiceCollectorEpochBinding {
        EngramServiceCollectorEpochBinding(
            machineID: machine, sourceInstanceID: instance, source: "codex", parseFormat: "codex",
            configuredRoot: rootPath, approvedEpoch: epoch, authorityGeneration: generation
        )
    }

    private func snapshot() throws -> [String] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT 'r', machine_id, source_instance_id, approved_epoch, authority_generation, updated_at
                FROM capture_ingest_source_registry
                UNION ALL
                SELECT 'h', machine_id, source_instance_id, approved_epoch, authority_generation, previous_epoch
                FROM capture_ingest_epoch_history
                UNION ALL
                SELECT 'l', publication_sha256, status, attempt_count, parser_revision, NULL FROM capture_ingest_ledger
                ORDER BY 1, 2, 3, 4, 5
                """).map { $0.description }
        }
    }

    private func accept(epoch: String, sequence: Int64) throws {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        let publication = try CollectorPublicationEnvelope(
            machineID: machine, sourceInstanceID: instance, collectorEpoch: epoch, sequence: sequence,
            manifestSHA256: String(format: "%064x", sequence)
        )
        try writer.write { db in
            let cursor = try CaptureIngestLedger.checkpoint(db, serverID: "hq")
            let ack = try CollectorPublicationACK(
                serverID: "hq", journalID: journal, arrivalOrdinal: ordinal,
                publicationSHA256: publication.sha256(), manifestSHA256: publication.manifestSHA256,
                storedAt: "2026-10-18T00:00:00.000Z"
            )
            let record = try CollectorPublicationAcceptanceRecord(publication: publication, ack: ack)
            let page = try CollectorPublicationPage(
                items: [record],
                afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: ordinal).encoded(),
                hasMore: false
            )
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: cursor, serverID: "hq",
                                           parserRevision: "swift-capture-v1")
        }
    }

    private func settings(role: String = "index", disabled: [String] = []) -> [String: Any] {
        ["runtimeRole": role, "disabledSources": disabled, "archivedDefaultOffSourcesMigrated": true,
         "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1:8787",
             "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0]]
    }

    private func writeSettings(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: settingsURL, options: .atomic)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
    }
}

private final class CollectorEpochRecordingTransport: EngramServiceTransport, @unchecked Sendable {
    typealias Responder = @Sendable (EngramServiceRequestEnvelope) throws -> EngramServiceResponseEnvelope

    private let lock = NSLock()
    private var requests: [EngramServiceRequestEnvelope] = []
    private let responder: Responder

    init(responder: @escaping Responder) { self.responder = responder }

    func send(
        _ request: EngramServiceRequestEnvelope, timeout _: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope {
        record(request)
        return try responder(request)
    }

    private func record(_ request: EngramServiceRequestEnvelope) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func close() {}

    func requestsSnapshot() -> [EngramServiceRequestEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
