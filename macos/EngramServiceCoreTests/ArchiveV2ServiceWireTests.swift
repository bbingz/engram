import Foundation
import XCTest
@testable import EngramServiceCore

final class ArchiveV2ServiceWireTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let timestamp = "2026-07-12T00:00:00.000Z"

    func testArchiveV2CapabilityContractProtectsRetryOnly() {
        XCTAssertFalse(ServiceCapabilityToken.requiresToken("archiveV2Status"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("archiveV2Retry"))

        for forbidden in [
            "archiveV2Delete",
            "archiveV2Evict",
            "archiveV2GC",
            "archiveV2Reclaim",
        ] {
            XCTAssertFalse(ServiceCapabilityToken.requiresToken(forbidden))
        }
    }

    func testRetryRequestAcceptsOnlyNilHQOrM1() throws {
        XCTAssertNil(try EngramServiceArchiveV2RetryRequest(replicaID: nil).replicaID)
        XCTAssertEqual(try EngramServiceArchiveV2RetryRequest(replicaID: "hq").replicaID, "hq")
        XCTAssertEqual(try EngramServiceArchiveV2RetryRequest(replicaID: "m1").replicaID, "m1")

        XCTAssertThrowsError(try EngramServiceArchiveV2RetryRequest(replicaID: "third"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EngramServiceArchiveV2RetryRequest.self,
                from: Data(#"{"replicaID":"third"}"#.utf8)
            )
        )
    }

    func testStatusRoundTripsCanonicalBoundedShape() throws {
        let reasons = [
            try EngramServiceArchiveV2RetryReasonCount(
                symbol: "transport_network",
                count: 2
            ),
        ]
        let cycle = try EngramServiceArchiveV2ReplicationCycleSummary(
            startedAt: "2026-07-12T00:00:00.000Z",
            finishedAt: "2026-07-12T00:00:01.500Z",
            durationMs: 1_500,
            claimedCount: 4,
            verifiedCount: 2,
            retryScheduledCount: 2,
            quarantinedCount: 0,
            lostClaimCount: 0,
            staleRecoveredCount: 1,
            reconciledCount: 3,
            cancelled: false,
            cycleError: nil
        )
        let status = try makeStatus(
            replicas: [
                try replica(
                    "hq",
                    oldestOutstandingAt: "2026-07-11T23:30:00.000Z",
                    nextRetryAt: "2026-07-12T00:05:00.000Z",
                    retryReasons: reasons,
                    remoteTelemetry: try remoteTelemetry("hq")
                ),
                try replica("m1", remoteTelemetryError: "transport_network"),
            ],
            lastReplicationCycle: cycle,
            nextScheduledCycleAt: "2026-07-12T00:15:00.000Z"
        )
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(
            EngramServiceArchiveV2StatusResponse.self,
            from: encoded
        )

        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.replicas.map(\.replicaID), ["hq", "m1"])
        XCTAssertEqual(decoded.latestReceipts.map(\.replicaID), ["hq", "m1"])
        XCTAssertEqual(decoded.replicas[0].remoteTelemetry?.serverID, "hq")
        XCTAssertEqual(decoded.replicas[1].remoteTelemetryError, "transport_network")
    }

    func testStatusDecodesOlderPayloadWithoutDiagnostics() throws {
        let encoded = try JSONEncoder().encode(
            makeStatus(
                lastReplicationCycle: try EngramServiceArchiveV2ReplicationCycleSummary(
                    startedAt: timestamp,
                    finishedAt: timestamp,
                    durationMs: 0,
                    claimedCount: 0,
                    verifiedCount: 0,
                    retryScheduledCount: 0,
                    quarantinedCount: 0,
                    lostClaimCount: 0,
                    staleRecoveredCount: 0,
                    reconciledCount: 0,
                    cancelled: false,
                    cycleError: nil
                ),
                nextScheduledCycleAt: timestamp
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "lastReplicationCycle")
        object.removeValue(forKey: "nextScheduledCycleAt")
        var replicas = try XCTUnwrap(object["replicas"] as? [[String: Any]])
        for index in replicas.indices {
            replicas[index].removeValue(forKey: "oldestOutstandingAt")
            replicas[index].removeValue(forKey: "nextRetryAt")
            replicas[index].removeValue(forKey: "retryReasons")
            replicas[index].removeValue(forKey: "remoteTelemetry")
            replicas[index].removeValue(forKey: "remoteTelemetryError")
        }
        object["replicas"] = replicas

        let decoded = try JSONDecoder().decode(
            EngramServiceArchiveV2StatusResponse.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )

        XCTAssertNil(decoded.lastReplicationCycle)
        XCTAssertNil(decoded.nextScheduledCycleAt)
        XCTAssertTrue(decoded.replicas.allSatisfy {
            $0.oldestOutstandingAt == nil
                && $0.nextRetryAt == nil
                && $0.retryReasons.isEmpty
                && $0.remoteTelemetry == nil
                && $0.remoteTelemetryError == nil
        })
    }

    func testRemoteTelemetryRejectsMalformedOrUnboundedIPCValues() throws {
        let endpoint = try remoteEndpoint()
        let error = try remoteError()

        XCTAssertThrowsError(
            try remoteTelemetry("hq", endpoints: Array(repeating: endpoint, count: 8))
        )
        XCTAssertThrowsError(
            try remoteTelemetry("hq", endpoints: [endpoint, endpoint])
        )
        XCTAssertThrowsError(
            try remoteTelemetry("hq", recentErrors: Array(repeating: error, count: 101))
        )
        XCTAssertThrowsError(
            try replica("hq", remoteTelemetry: try remoteTelemetry("m1"))
        )
        XCTAssertThrowsError(
            try replica("hq", remoteTelemetryError: "https_secret_host_token")
        )
        XCTAssertThrowsError(
            try replica(
                "hq",
                remoteTelemetry: try remoteTelemetry("hq"),
                remoteTelemetryError: "transport_network"
            )
        )

        let valid = try JSONEncoder().encode(
            makeStatus(
                replicas: [
                    try replica("hq", remoteTelemetry: try remoteTelemetry("hq")),
                    try replica("m1"),
                ]
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var replicas = try XCTUnwrap(object["replicas"] as? [[String: Any]])
        var telemetry = try XCTUnwrap(replicas[0]["remoteTelemetry"] as? [String: Any])
        telemetry["requestCount"] = -1
        replicas[0]["remoteTelemetry"] = telemetry
        object["replicas"] = replicas

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EngramServiceArchiveV2StatusResponse.self,
                from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        )
    }

    func testStatusDiagnosticsRejectInvalidValues() throws {
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryReasonCount(
                symbol: "bad/path",
                count: 1
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryReasonCount(
                symbol: "transport_network",
                count: -1
            )
        )
        XCTAssertThrowsError(
            try replica(
                "hq",
                oldestOutstandingAt: "2026-07-12T00:00:00Z"
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2ReplicationCycleSummary(
                startedAt: timestamp,
                finishedAt: timestamp,
                durationMs: -1,
                claimedCount: 0,
                verifiedCount: 0,
                retryScheduledCount: 0,
                quarantinedCount: 0,
                lostClaimCount: 0,
                staleRecoveredCount: 0,
                reconciledCount: 0,
                cancelled: false,
                cycleError: nil
            )
        )
        XCTAssertThrowsError(try makeStatus(nextScheduledCycleAt: "not-a-timestamp"))
    }

    func testStatusRejectsNegativeCountsFromInitializerAndDecoder() throws {
        XCTAssertThrowsError(try makeStatus(capturedCount: -1))

        let valid = try JSONEncoder().encode(makeStatus())
        let invalid = try replacingJSONValue(
            in: valid,
            key: "remotePolicyEligibleCount",
            value: -1
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EngramServiceArchiveV2StatusResponse.self,
                from: invalid
            )
        )

        XCTAssertThrowsError(
            try EngramServiceArchiveV2ReplicaStatus(
                replicaID: "hq",
                queuedCount: 0,
                retryingCount: -1,
                quarantinedCount: 0,
                verifiedCount: 0
            )
        )
    }

    func testStatusRequiresExactlyCanonicalHQAndM1ReplicaRows() throws {
        let hq = try replica("hq")
        let m1 = try replica("m1")

        XCTAssertThrowsError(try makeStatus(replicas: [hq]))
        XCTAssertThrowsError(try makeStatus(replicas: [m1, hq]))
        XCTAssertThrowsError(try makeStatus(replicas: [hq, hq]))
        XCTAssertThrowsError(
            try EngramServiceArchiveV2ReplicaStatus(
                replicaID: "third",
                queuedCount: 0,
                retryingCount: 0,
                quarantinedCount: 0,
                verifiedCount: 0
            )
        )
    }

    func testStatusRejectsMalformedOrOversizedSymbolicErrors() throws {
        for invalid in [
            "bad/path",
            "UPPERCASE",
            "",
            String(repeating: "a", count: 65),
        ] {
            XCTAssertThrowsError(
                try makeStatus(
                    remoteReplicationEnabled: false,
                    configurationError: invalid
                )
            )
            XCTAssertThrowsError(try makeStatus(lastCaptureError: invalid))
            XCTAssertThrowsError(try makeStatus(lastReplicationError: invalid))
        }
    }

    func testLatestReceiptsAreLimitedToTwoCurrentUniqueReplicas() throws {
        let hq = try receipt(replicaID: "hq", manifest: digestA, receipt: digestB)
        let m1 = try receipt(replicaID: "m1", manifest: digestB, receipt: digestA)

        XCTAssertThrowsError(try makeStatus(latestReceipts: [hq, hq]))
        XCTAssertThrowsError(try makeStatus(latestReceipts: [m1, hq]))
        XCTAssertThrowsError(try makeStatus(latestReceipts: [hq, m1, hq]))
        XCTAssertThrowsError(
            try EngramServiceArchiveV2LatestReceipt(
                replicaID: "third",
                manifestSHA256: digestA,
                receiptSHA256: digestB,
                verifiedAt: timestamp
            )
        )
    }

    func testLatestReceiptRejectsMalformedDigestAndNonCanonicalTimestamp() {
        XCTAssertThrowsError(
            try EngramServiceArchiveV2LatestReceipt(
                replicaID: "hq",
                manifestSHA256: "not-a-digest",
                receiptSHA256: digestB,
                verifiedAt: timestamp
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2LatestReceipt(
                replicaID: "hq",
                manifestSHA256: digestA,
                receiptSHA256: digestB,
                verifiedAt: "2026-07-12T00:00:00Z"
            )
        )
    }

    func testStatusFlagsRejectImpossibleEnablementHierarchy() throws {
        XCTAssertThrowsError(
            try makeStatus(
                enabled: false,
                localCaptureEnabled: true,
                remoteReplicationEnabled: false
            )
        )
        XCTAssertThrowsError(
            try makeStatus(
                enabled: true,
                localCaptureEnabled: false,
                remoteReplicationEnabled: true
            )
        )
        XCTAssertThrowsError(
            try makeStatus(
                remoteReplicationEnabled: true,
                configurationError: "missing_token_hq"
            )
        )

        let valid = try JSONEncoder().encode(makeStatus())
        let invalid = try replacingJSONValue(
            in: valid,
            key: "configurationError",
            value: "missing_token_hq"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EngramServiceArchiveV2StatusResponse.self,
                from: invalid
            )
        )
    }

    func testRetryResponseValidatesRowsAndSymbolicError() throws {
        XCTAssertEqual(
            try EngramServiceArchiveV2RetryResponse(
                accepted: true,
                resetRows: 2,
                error: nil
            ).resetRows,
            2
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryResponse(
                accepted: true,
                resetRows: -1,
                error: nil
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryResponse(
                accepted: false,
                resetRows: 1,
                error: "retry_rejected"
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryResponse(
                accepted: true,
                resetRows: 0,
                error: "retry_rejected"
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryResponse(
                accepted: false,
                resetRows: 0,
                error: nil
            )
        )
        XCTAssertThrowsError(
            try EngramServiceArchiveV2RetryResponse(
                accepted: false,
                resetRows: 0,
                error: "contains/path"
            )
        )
        XCTAssertEqual(
            try EngramServiceArchiveV2RetryResponse(
                accepted: false,
                resetRows: 0,
                error: "retry_rejected"
            ).error,
            "retry_rejected"
        )

        for payload in [
            #"{"accepted":true,"resetRows":0,"error":"retry_rejected"}"#,
            #"{"accepted":false,"resetRows":0,"error":null}"#,
            #"{"accepted":false,"resetRows":1,"error":"retry_rejected"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    EngramServiceArchiveV2RetryResponse.self,
                    from: Data(payload.utf8)
                )
            )
        }
    }

    func testStatusEncodingContainsNoSecretPathOrPayloadFields() throws {
        let encoded = try JSONEncoder().encode(makeStatus())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let encodedKeys = Set(object.keys)
        XCTAssertTrue(encodedKeys.isDisjoint(with: ["path", "token", "raw", "body", "url"]))

        let text = String(decoding: encoded, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("/users/"))
        XCTAssertFalse(text.contains("bearer"))
        XCTAssertFalse(text.contains("authorization"))
    }

    func testClientUsesFrozenStatusAndRetryCommands() async throws {
        let status = try makeStatus()
        let retry = try EngramServiceArchiveV2RetryResponse(
            accepted: true,
            resetRows: 1,
            error: nil
        )
        let transport = ArchiveV2WireRecordingTransport { request in
            let result: Data
            switch request.command {
            case "archiveV2Status":
                result = try JSONEncoder().encode(status)
            case "archiveV2Retry":
                result = try JSONEncoder().encode(retry)
            default:
                throw EngramServiceError.invalidRequest(message: "unexpected command")
            }
            return .success(requestId: request.requestId, result: result)
        }
        let client = EngramServiceClient(transport: transport)

        let clientStatus = try await client.archiveV2Status()
        XCTAssertEqual(clientStatus, status)
        let statusRequests = transport.requestsSnapshot()
        XCTAssertEqual(statusRequests.map(\.command), ["archiveV2Status"])
        XCTAssertNil(
            statusRequests.first?.payload,
            "archiveV2Status must use a truly absent payload because the handler rejects {}"
        )

        let retryRequest = try EngramServiceArchiveV2RetryRequest(replicaID: "m1")
        let clientRetry = try await client.archiveV2Retry(retryRequest)
        XCTAssertEqual(clientRetry, retry)
        let requests = transport.requestsSnapshot()
        XCTAssertEqual(requests.map(\.command), ["archiveV2Status", "archiveV2Retry"])
        XCTAssertEqual(
            try JSONDecoder().decode(
                EngramServiceArchiveV2RetryRequest.self,
                from: try XCTUnwrap(requests.last?.payload)
            ),
            retryRequest
        )
    }

    func testMockClientImplementsArchiveV2WireContract() async throws {
        let status = try makeStatus()
        let retry = try EngramServiceArchiveV2RetryResponse(
            accepted: true,
            resetRows: 0,
            error: nil
        )
        let client = MockEngramServiceClient(
            archiveV2Status: status,
            archiveV2Retry: retry
        )

        let clientStatus = try await client.archiveV2Status()
        XCTAssertEqual(clientStatus, status)
        let clientRetry = try await client.archiveV2Retry(
            EngramServiceArchiveV2RetryRequest(replicaID: nil)
        )
        XCTAssertEqual(clientRetry, retry)
    }

    private func makeStatus(
        enabled: Bool = true,
        localCaptureEnabled: Bool = true,
        remoteReplicationEnabled: Bool = true,
        configurationError: String? = nil,
        capturedCount: Int = 8,
        boundCount: Int = 7,
        unboundCount: Int = 1,
        remotePolicyUnknownCount: Int = 1,
        remotePolicyEligibleCount: Int = 5,
        remotePolicyExcludedCount: Int = 1,
        unsupportedLocatorCount: Int = 2,
        unsafeLocatorCount: Int = 1,
        replicas: [EngramServiceArchiveV2ReplicaStatus]? = nil,
        singleReplicaVerifiedCount: Int = 2,
        dualReplicaVerifiedCount: Int = 3,
        latestReceipts: [EngramServiceArchiveV2LatestReceipt]? = nil,
        lastCaptureError: String? = "source_changed",
        lastReplicationError: String? = "network_unavailable",
        cycleRunning: Bool = true,
        cycleCoalesced: Bool = false,
        lastReplicationCycle: EngramServiceArchiveV2ReplicationCycleSummary? = nil,
        nextScheduledCycleAt: String? = nil
    ) throws -> EngramServiceArchiveV2StatusResponse {
        try EngramServiceArchiveV2StatusResponse(
            enabled: enabled,
            localCaptureEnabled: localCaptureEnabled,
            remoteReplicationEnabled: remoteReplicationEnabled,
            configurationError: configurationError,
            capturedCount: capturedCount,
            boundCount: boundCount,
            unboundCount: unboundCount,
            remotePolicyUnknownCount: remotePolicyUnknownCount,
            remotePolicyEligibleCount: remotePolicyEligibleCount,
            remotePolicyExcludedCount: remotePolicyExcludedCount,
            unsupportedLocatorCount: unsupportedLocatorCount,
            unsafeLocatorCount: unsafeLocatorCount,
            replicas: replicas ?? [try replica("hq"), try replica("m1")],
            singleReplicaVerifiedCount: singleReplicaVerifiedCount,
            dualReplicaVerifiedCount: dualReplicaVerifiedCount,
            latestReceipts: latestReceipts ?? [
                try receipt(replicaID: "hq", manifest: digestA, receipt: digestB),
                try receipt(replicaID: "m1", manifest: digestB, receipt: digestA),
            ],
            lastCaptureError: lastCaptureError,
            lastReplicationError: lastReplicationError,
            cycleRunning: cycleRunning,
            cycleCoalesced: cycleCoalesced,
            lastReplicationCycle: lastReplicationCycle,
            nextScheduledCycleAt: nextScheduledCycleAt
        )
    }

    private func replica(
        _ id: String,
        oldestOutstandingAt: String? = nil,
        nextRetryAt: String? = nil,
        retryReasons: [EngramServiceArchiveV2RetryReasonCount] = [],
        remoteTelemetry: EngramServiceArchiveV2RemoteTelemetry? = nil,
        remoteTelemetryError: String? = nil
    ) throws -> EngramServiceArchiveV2ReplicaStatus {
        try EngramServiceArchiveV2ReplicaStatus(
            replicaID: id,
            queuedCount: id == "hq" ? 1 : 2,
            retryingCount: 1,
            quarantinedCount: 0,
            verifiedCount: 3,
            oldestOutstandingAt: oldestOutstandingAt,
            nextRetryAt: nextRetryAt,
            retryReasons: retryReasons,
            remoteTelemetry: remoteTelemetry,
            remoteTelemetryError: remoteTelemetryError
        )
    }

    private func remoteTelemetry(
        _ serverID: String,
        endpoints: [EngramServiceArchiveV2RemoteEndpoint]? = nil,
        recentErrors: [EngramServiceArchiveV2RemoteError]? = nil
    ) throws -> EngramServiceArchiveV2RemoteTelemetry {
        try EngramServiceArchiveV2RemoteTelemetry(
            serverID: serverID,
            sourceRevision: String(repeating: serverID == "hq" ? "a" : "b", count: 40),
            snapshotAt: timestamp,
            uptimeSeconds: 60,
            diskAvailableBytes: 500,
            diskTotalBytes: 1_000,
            requestCount: 4,
            clientErrorCount: 1,
            serverErrorCount: 1,
            lastArchiveMutationAt: timestamp,
            persistenceError: nil,
            endpoints: endpoints ?? [try remoteEndpoint()],
            recentErrors: recentErrors ?? [try remoteError()]
        )
    }

    private func remoteEndpoint() throws -> EngramServiceArchiveV2RemoteEndpoint {
        try EngramServiceArchiveV2RemoteEndpoint(
            endpoint: "status",
            requestCount: 4,
            errorCount: 2,
            totalDurationMs: 20,
            maximumDurationMs: 8,
            requestBytes: 100,
            responseBytes: 200
        )
    }

    private func remoteError() throws -> EngramServiceArchiveV2RemoteError {
        try EngramServiceArchiveV2RemoteError(
            timestamp: timestamp,
            endpoint: "status",
            method: "GET",
            statusCode: 500,
            category: "internal_error"
        )
    }

    private func receipt(
        replicaID: String,
        manifest: String,
        receipt: String
    ) throws -> EngramServiceArchiveV2LatestReceipt {
        try EngramServiceArchiveV2LatestReceipt(
            replicaID: replicaID,
            manifestSHA256: manifest,
            receiptSHA256: receipt,
            verifiedAt: timestamp
        )
    }

    private func replacingJSONValue(
        in data: Data,
        key: String,
        value: Any
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private final class ArchiveV2WireRecordingTransport: EngramServiceTransport, @unchecked Sendable {
    typealias Responder = @Sendable (
        EngramServiceRequestEnvelope
    ) throws -> EngramServiceResponseEnvelope

    private let lock = NSLock()
    private var requests: [EngramServiceRequestEnvelope] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout _: TimeInterval?
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
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func close() {}

    func requestsSnapshot() -> [EngramServiceRequestEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
