import EngramCoreWrite
import Foundation
import XCTest

@testable import EngramServiceCore

final class ArchiveV2IPCTests: XCTestCase {
    func testReclamationCapabilityBoundary() {
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("archiveReclamationStatus"))
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("archiveReclamationPreview"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveReclamationUpdateSettings"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveReclamationRun"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveV2RecoveryDrill"))
    }

    func testDisabledReclamationStatusAndPreviewAreReadOnly() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let statusResponse = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveReclamationStatus")
        )
        guard case .success(_, let statusData, _) = statusResponse else {
            return XCTFail("archiveReclamationStatus failed")
        }
        let status = try JSONDecoder().decode(
            EngramServiceArchiveReclamationStatusResponse.self,
            from: statusData
        )
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.hotWindowDays, 30)

        let previewResponse = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveReclamationPreview")
        )
        guard case .success(_, let previewData, _) = previewResponse else {
            return XCTFail("archiveReclamationPreview failed")
        }
        let preview = try JSONDecoder().decode(
            EngramServiceArchiveReclamationPreviewResponse.self,
            from: previewData
        )
        XCTAssertEqual(preview.eligibleCount, 0)
    }

    func testReclamationReadCommandsRejectEvenEmptyPayload() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)
        let empty = try JSONEncoder().encode([String: String]())

        for command in ["archiveReclamationStatus", "archiveReclamationPreview"] {
            let response = await handler.handle(
                EngramServiceRequestEnvelope(command: command, payload: empty)
            )
            guard case .failure(_, let error) = response else {
                return XCTFail("\(command) accepted a payload")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
        }
    }
    func testDisabledStatusReturnsStrictFixedZeroResponseWithoutPayload() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let response = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveV2Status")
        )

        let status = try decodeSuccess(
            EngramServiceArchiveV2StatusResponse.self,
            from: response
        )
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.localCaptureEnabled)
        XCTAssertFalse(status.remoteReplicationEnabled)
        XCTAssertNil(status.configurationError)
        XCTAssertEqual(status.capturedCount, 0)
        XCTAssertEqual(status.boundCount, 0)
        XCTAssertEqual(status.unboundCount, 0)
        XCTAssertEqual(status.remotePolicyUnknownCount, 0)
        XCTAssertEqual(status.remotePolicyEligibleCount, 0)
        XCTAssertEqual(status.remotePolicyExcludedCount, 0)
        XCTAssertEqual(status.unsupportedLocatorCount, 0)
        XCTAssertEqual(status.unsafeLocatorCount, 0)
        XCTAssertEqual(status.replicas.map(\.replicaID), ["hq", "m1"])
        XCTAssertTrue(status.replicas.allSatisfy {
            $0.queuedCount == 0
                && $0.retryingCount == 0
                && $0.quarantinedCount == 0
                && $0.verifiedCount == 0
        })
        XCTAssertEqual(status.singleReplicaVerifiedCount, 0)
        XCTAssertEqual(status.dualReplicaVerifiedCount, 0)
        XCTAssertEqual(status.latestReceipts, [])
        XCTAssertNil(status.lastCaptureError)
        XCTAssertNil(status.lastReplicationError)
        XCTAssertFalse(status.cycleRunning)
        XCTAssertFalse(status.cycleCoalesced)
    }

    func testStatusRejectsAnyPayloadAsInvalidRequest() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveV2Status",
                payload: Data("{}".utf8)
            )
        )

        assertFailure(response, named: "InvalidRequest")
    }

    func testRetryDecodesStrictReplicaAndDisabledHandlerNeverStartsWork() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)
        let payload = try JSONEncoder().encode(
            EngramServiceArchiveV2RetryRequest(replicaID: "m1")
        )

        let response = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveV2Retry", payload: payload)
        )

        let retry = try decodeSuccess(
            EngramServiceArchiveV2RetryResponse.self,
            from: response
        )
        XCTAssertFalse(retry.accepted)
        XCTAssertEqual(retry.resetRows, 0)
        XCTAssertEqual(retry.error, "archive_v2_disabled")
    }

    func testRetryRejectsInvalidReplicaPayloadAsInvalidRequest() async throws {
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)

        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveV2Retry",
                payload: Data(#"{"replicaID":"other"}"#.utf8)
            )
        )

        assertFailure(response, named: "InvalidRequest")
    }

    func testStatusIsExcludedFromTelemetryButRetryIsRecorded() async throws {
        let harness = try makeHarness()
        let telemetry = ServiceTelemetryCollector()
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            telemetry: telemetry
        )

        _ = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveV2Status")
        )
        _ = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveV2Retry",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveV2RetryRequest(replicaID: nil)
                )
            )
        )

        let snapshot = await telemetry.snapshot()
        XCTAssertFalse(snapshot.spans.contains { $0.command == "archiveV2Status" })
        XCTAssertFalse(snapshot.commands.contains { $0.command == "archiveV2Status" })
        XCTAssertTrue(snapshot.spans.contains { $0.command == "archiveV2Retry" })
        XCTAssertTrue(snapshot.commands.contains { $0.command == "archiveV2Retry" })
    }

    func testSocketAllowsStatusWithoutCapabilityButRejectsRetryWithWrongToken() async throws {
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("archiveV2Status"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveV2Retry"))
        let harness = try makeHarness()
        let handler = EngramServiceCommandHandler(writerGate: harness.gate)
        let server = UnixSocketServiceServer(socketPath: harness.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }
        let transport = UnixSocketEngramServiceTransport(socketPath: harness.socket.path)

        let statusResponse = try await transport.send(
            EngramServiceRequestEnvelope(
                command: "archiveV2Status",
                capabilityToken: "wrong-token"
            ),
            timeout: 2
        )
        _ = try decodeSuccess(
            EngramServiceArchiveV2StatusResponse.self,
            from: statusResponse
        )

        let retryResponse = try await transport.send(
            EngramServiceRequestEnvelope(
                command: "archiveV2Retry",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveV2RetryRequest(replicaID: nil)
                ),
                capabilityToken: "wrong-token"
            ),
            timeout: 2
        )
        assertFailure(retryResponse, named: "Unauthorized")

        let authorizedRetry = try await transport.send(
            EngramServiceRequestEnvelope(
                command: "archiveV2Retry",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveV2RetryRequest(replicaID: nil)
                )
            ),
            timeout: 2
        )
        let retry = try decodeSuccess(
            EngramServiceArchiveV2RetryResponse.self,
            from: authorizedRetry
        )
        XCTAssertEqual(retry.error, "archive_v2_disabled")
    }

    func testInjectedCoordinatorRetryOnlyResetsRowsWithoutReplication() async throws {
        let harness = try makeHarness(remoteEnabled: true)
        let probes = ArchiveV2IPCProbes()
        var operations = makeOperations()
        operations.retry = { replicaID in
            await probes.recordRetry(replicaID)
            return 7
        }
        operations.replicate = { _ in
            await probes.recordReplication()
            return ArchiveReplicationCycleResult()
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveV2Coordinator: coordinator
        )

        let response = await handler.handle(
            EngramServiceRequestEnvelope(
                command: "archiveV2Retry",
                payload: try JSONEncoder().encode(
                    EngramServiceArchiveV2RetryRequest(replicaID: "hq")
                )
            )
        )

        let retry = try decodeSuccess(
            EngramServiceArchiveV2RetryResponse.self,
            from: response
        )
        XCTAssertTrue(retry.accepted)
        XCTAssertEqual(retry.resetRows, 7)
        XCTAssertNil(retry.error)
        let retryReplicaIDs = await probes.retryReplicaIDs()
        let replicationCount = await probes.replicationCount()
        XCTAssertEqual(retryReplicaIDs, ["hq"])
        XCTAssertEqual(replicationCount, 0)
    }

    func testStatusEncodingDoesNotLeakPathsTokensOrRemoteResponseBodies() async throws {
        let harness = try makeHarness(remoteEnabled: true)
        var operations = makeOperations()
        operations.status = {
            throw ArchiveV2IPCSensitiveError()
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: "remote_credentials_unavailable",
            operations: operations
        )
        let handler = EngramServiceCommandHandler(
            writerGate: harness.gate,
            archiveV2Coordinator: coordinator
        )

        let response = await handler.handle(
            EngramServiceRequestEnvelope(command: "archiveV2Status")
        )
        guard case .success(_, let data, _) = response else {
            return XCTFail("archiveV2Status failed")
        }
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("/private/archive-v2"))
        XCTAssertFalse(encoded.contains("secret-token"))
        XCTAssertFalse(encoded.contains("upstream response body"))

        let status = try JSONDecoder().decode(
            EngramServiceArchiveV2StatusResponse.self,
            from: data
        )
        XCTAssertEqual(status.configurationError, "remote_credentials_unavailable")
        XCTAssertEqual(status.capturedCount, 0)
    }

    private func makeHarness(remoteEnabled: Bool = false) throws -> ArchiveV2IPCHarness {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "engram-a2ipc-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        let socket = runtime.appendingPathComponent("engram-service.sock")
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let database = root.appendingPathComponent("index.sqlite")
        let gate = try ServiceWriterGate(
            databasePath: database.path,
            runtimeDirectory: runtime
        )
        let settingsURL = root.appendingPathComponent("settings.json")
        let settingsObject: [String: Any] = [
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": remoteEnabled,
                "batchSize": 4,
                "replicas": remoteEnabled ? [
                    ["id": "hq", "serverURL": "https://hq.example.ts.net", "requireTLS": true],
                    ["id": "m1", "serverURL": "https://m1.example.ts.net", "requireTLS": true],
                ] : [],
                "excludedProjectRoots": [],
            ],
        ]
        try JSONSerialization.data(withJSONObject: settingsObject).write(to: settingsURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ArchiveV2IPCHarness(
            gate: gate,
            socket: socket,
            settings: ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:])
        )
    }

    private func makeOperations() -> ArchiveV2ServiceCoordinatorOperations {
        ArchiveV2ServiceCoordinatorOperations(
            capture: { _, _, _ in
                ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0)
            },
            bindingTargets: { _ in [] },
            historicalUnknown: { _ in ArchiveV2ServiceUnknownPage(targets: []) },
            advancePolicyCursor: { _ in },
            snapshot: { _, _ in ArchiveV2ServiceIndexSnapshot(rows: []) },
            bindOne: { _, _ in nil },
            applyRemotePolicy: { _, _, _ in },
            replicate: { _ in ArchiveReplicationCycleResult() },
            status: { archiveV2IPCZeroAggregate() },
            retry: { _ in 0 }
        )
    }

    private func decodeSuccess<T: Decodable>(
        _ type: T.Type,
        from response: EngramServiceResponseEnvelope
    ) throws -> T {
        guard case .success(_, let data, _) = response else {
            throw ArchiveV2IPCTestError.expectedSuccess
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func assertFailure(
        _ response: EngramServiceResponseEnvelope,
        named expectedName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(_, let error) = response else {
            return XCTFail("expected \(expectedName) failure", file: file, line: line)
        }
        XCTAssertEqual(error.name, expectedName, file: file, line: line)
    }
}

private struct ArchiveV2IPCHarness {
    let gate: ServiceWriterGate
    let socket: URL
    let settings: ArchiveV2Settings
}

private enum ArchiveV2IPCTestError: Error {
    case expectedSuccess
}

private struct ArchiveV2IPCSensitiveError: LocalizedError {
    var errorDescription: String? {
        "/private/archive-v2 secret-token upstream response body"
    }
}

private actor ArchiveV2IPCProbes {
    private var retried: [String?] = []
    private var replications = 0

    func recordRetry(_ replicaID: String?) {
        retried.append(replicaID)
    }

    func recordReplication() {
        replications += 1
    }

    func retryReplicaIDs() -> [String?] {
        retried
    }

    func replicationCount() -> Int {
        replications
    }
}

private func archiveV2IPCZeroAggregate() -> ArchiveStatusAggregate {
    let zero = ArchiveReplicaStatusCounts(
        pending: 0,
        inflight: 0,
        retry: 0,
        quarantine: 0,
        verified: 0
    )
    return ArchiveStatusAggregate(
        captured: 0,
        bound: 0,
        unbound: 0,
        unknown: 0,
        eligible: 0,
        excluded: 0,
        hq: zero,
        m1: zero,
        singleVerified: 0,
        dualVerified: 0,
        latestReceipts: []
    )
}
