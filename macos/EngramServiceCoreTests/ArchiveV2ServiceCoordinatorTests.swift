import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB
import XCTest

@testable import EngramServiceCore

final class ArchiveV2ServiceCoordinatorTests: XCTestCase {
    func testCycleOrdersArchivePhasesAroundIndexAndUsesOneSnapshot() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let operations = makeOperations(events: events)
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let result = try await coordinator.runCycle(
            adapters: [],
            cursorScope: .full
        ) { _ in
            await events.append("index")
            return try await self.emptyIndexResult(gate: harness.gate)
        }

        XCTAssertEqual(result.indexed, 0)
        let recorded = await events.values()
        let snapshotCount = await events.count(of: "snapshot")
        XCTAssertEqual(
            recorded,
            ["capture", "index", "targets", "historical", "snapshot", "replicate"]
        )
        XCTAssertEqual(snapshotCount, 1)
    }

    func testBacklogPassUsesIndependentBudgetsAndBacklogReplication() async throws {
        let harness = try makeHarness(remoteReady: true, batchSize: 3)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.backlogCapture = { _ in
            await events.append("backlogCapture")
            return ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 0,
                processed: 1,
                capturedSourceBytes: 64
            )
        }
        operations.replicateBacklog = { limit in
            await events.append("replicateBacklog:\(limit)")
            return ArchiveReplicationCycleResult(
                claimed: 2,
                verified: 2,
                verifiedByReplica: ["hq": 1, "m1": 1]
            )
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let summary = try await coordinator.runBacklogPass(adapters: [])
        let recordedEvents = await events.values()

        XCTAssertEqual(summary.capturedFiles, 1)
        XCTAssertEqual(summary.capturedSourceBytes, 64)
        XCTAssertEqual(summary.hqVerified, 1)
        XCTAssertEqual(summary.m1Verified, 1)
        XCTAssertEqual(
            recordedEvents,
            [
                "backlogCapture", "targets", "historical", "snapshot",
                "replicateBacklog:16",
            ]
        )
    }

    func testIndexFailurePropagatesAndSkipsEveryPostIndexArchivePhase() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: makeOperations(events: events)
        )

        do {
            _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
                await events.append("index")
                throw TestError.indexFailed
            }
            XCTFail("expected index failure")
        } catch TestError.indexFailed {
            // expected
        }

        let recorded = await events.values()
        XCTAssertEqual(recorded, ["capture", "index"])
    }

    func testRemoteFailureDoesNotFailSuccessfulIndexAndIsReportedSymbolically() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.replicate = { _ in
            await events.append("replicate")
            return ArchiveReplicationCycleResult(cycleError: "transport_failure")
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let result = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            await events.append("index")
            return try await self.emptyIndexResult(gate: harness.gate)
        }
        let status = await coordinator.status()

        XCTAssertEqual(result.indexed, 0)
        XCTAssertEqual(status.lastReplicationError, "transport_failure")
        XCTAssertTrue(status.remoteReplicationEnabled)
    }

    func testStatusRecordsLatestReplicationCycleAndNextScheduledOpportunity() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let results = ReplicationResultQueue([
            ArchiveReplicationCycleResult(
                claimed: 4,
                verified: 2,
                retryScheduled: 2,
                staleRecovered: 1,
                reconciled: 3
            ),
            ArchiveReplicationCycleResult(
                claimed: 1,
                verified: 1,
                quarantined: 1,
                lostClaims: 1,
                cycleError: "catalog_failure"
            ),
        ])
        let clock = CoordinatorDateQueue([
            Date(timeIntervalSince1970: 1_752_278_400),
            Date(timeIntervalSince1970: 1_752_278_401.5),
            Date(timeIntervalSince1970: 1_752_278_460),
            Date(timeIntervalSince1970: 1_752_278_461),
        ])
        var operations = makeOperations(events: events)
        operations.replicate = { _ in await results.next() }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations,
            now: clock.next
        )
        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        await coordinator.recordNextScheduledCycle(
            at: Date(timeIntervalSince1970: 1_752_279_300)
        )
        var status = await coordinator.status()

        XCTAssertEqual(status.nextScheduledCycleAt, "2025-07-12T00:15:00.000Z")
        XCTAssertEqual(status.lastReplicationCycle?.startedAt, "2025-07-12T00:00:00.000Z")
        XCTAssertEqual(status.lastReplicationCycle?.finishedAt, "2025-07-12T00:00:01.500Z")
        XCTAssertEqual(status.lastReplicationCycle?.durationMs, 1_500)
        XCTAssertEqual(status.lastReplicationCycle?.claimedCount, 4)
        XCTAssertEqual(status.lastReplicationCycle?.verifiedCount, 2)
        XCTAssertEqual(status.lastReplicationCycle?.retryScheduledCount, 2)
        XCTAssertEqual(status.lastReplicationCycle?.staleRecoveredCount, 1)
        XCTAssertEqual(status.lastReplicationCycle?.reconciledCount, 3)

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        status = await coordinator.status()

        XCTAssertEqual(status.lastReplicationCycle?.startedAt, "2025-07-12T00:01:00.000Z")
        XCTAssertEqual(status.lastReplicationCycle?.finishedAt, "2025-07-12T00:01:01.000Z")
        XCTAssertEqual(status.lastReplicationCycle?.durationMs, 1_000)
        XCTAssertEqual(status.lastReplicationCycle?.claimedCount, 1)
        XCTAssertEqual(status.lastReplicationCycle?.verifiedCount, 1)
        XCTAssertEqual(status.lastReplicationCycle?.quarantinedCount, 1)
        XCTAssertEqual(status.lastReplicationCycle?.lostClaimCount, 1)
        XCTAssertEqual(status.lastReplicationCycle?.cycleError, "catalog_failure")
    }

    func testConcurrentCyclesCoalesceWithoutRepeatingCaptureOrIndex() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: makeOperations(events: events, captureDelayNanos: 80_000_000)
        )

        async let first = coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            await events.append("index")
            return try await self.emptyIndexResult(gate: harness.gate)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        async let second = coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            await events.append("second-index-must-not-run")
            return try await self.emptyIndexResult(gate: harness.gate)
        }

        let values = try await [first, second]
        XCTAssertEqual(values[0], values[1])
        let captureCount = await events.count(of: "capture")
        let indexCount = await events.count(of: "index")
        let secondIndexCount = await events.count(of: "second-index-must-not-run")
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(indexCount, 1)
        XCTAssertEqual(secondIndexCount, 0)
        let status = await coordinator.status()
        XCTAssertTrue(status.cycleCoalesced)
    }

    func testRetryOnlyResetsCatalogRowsAndNeverRunsNetwork() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.retry = { replicaID in
            await events.append("retry:\(replicaID ?? "all")")
            return 7
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let response = await coordinator.retryQuarantined(replicaID: "m1")

        XCTAssertTrue(response.accepted)
        XCTAssertEqual(response.resetRows, 7)
        XCTAssertNil(response.error)
        let recorded = await events.values()
        let replicateCount = await events.count(of: "replicate")
        XCTAssertEqual(recorded, ["retry:m1"])
        XCTAssertEqual(replicateCount, 0)
    }

    func testRecoveryDrillRunsOnlyRequestedReplicaAndReturnsLease() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.recoveryDrill = { replicaID in
            await events.append("drill:\(replicaID)")
            return ArchiveRecoveryLease(
                replicaID: replicaID,
                manifestSHA256: String(repeating: "a", count: 64),
                verifiedAt: "2026-07-12T00:00:00.000Z",
                verifiedBytes: 42
            )
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let lease = try await coordinator.runRecoveryDrill(replicaID: "m1")

        XCTAssertEqual(lease.replicaID, "m1")
        XCTAssertEqual(lease.verifiedBytes, 42)
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["drill:m1"])
    }

    func testConcurrentRecoveryDrillsForOneReplicaCoalesce() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.recoveryDrill = { replicaID in
            await events.append("drill:\(replicaID)")
            try await Task.sleep(nanoseconds: 50_000_000)
            return ArchiveRecoveryLease(
                replicaID: replicaID,
                manifestSHA256: String(repeating: "b", count: 64),
                verifiedAt: "2026-07-12T00:00:00.000Z",
                verifiedBytes: 12
            )
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        async let first = coordinator.runRecoveryDrill(replicaID: "hq")
        try await Task.sleep(nanoseconds: 5_000_000)
        async let second = coordinator.runRecoveryDrill(replicaID: "hq")
        let leases = try await [first, second]

        XCTAssertEqual(leases[0], leases[1])
        let drillCount = await events.count(of: "drill:hq")
        XCTAssertEqual(drillCount, 1)
    }

    func testStatusMapsFixedAggregateAndOnlyApprovedReceiptFields() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        var operations = makeOperations(events: events)
        operations.status = {
            ArchiveStatusAggregate(
                captured: 9,
                bound: 8,
                unbound: 1,
                unknown: 2,
                eligible: 5,
                excluded: 1,
                hq: ArchiveReplicaStatusCounts(pending: 1, inflight: 2, retry: 3, quarantine: 4, verified: 5),
                m1: ArchiveReplicaStatusCounts(pending: 6, inflight: 7, retry: 8, quarantine: 9, verified: 10),
                singleVerified: 3,
                dualVerified: 2,
                latestReceipts: [
                    ArchiveStatusReceiptSummary(
                        replicaID: "hq",
                        manifestSHA256: String(repeating: "a", count: 64),
                        captureID: String(repeating: "b", count: 64),
                        receiptSHA256: String(repeating: "c", count: 64),
                        storedAt: "2026-07-12T00:00:00.000Z",
                        verifiedAt: "2026-07-12T00:00:01.000Z"
                    ),
                ]
            )
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        let status = await coordinator.status()

        XCTAssertEqual(status.capturedCount, 9)
        XCTAssertEqual(status.replicas.map(\.replicaID), ["hq", "m1"])
        XCTAssertEqual(status.replicas[0].queuedCount, 3)
        XCTAssertEqual(status.replicas[1].queuedCount, 13)
        XCTAssertEqual(status.latestReceipts.count, 1)
        XCTAssertEqual(status.latestReceipts[0].receiptSHA256, String(repeating: "c", count: 64))
    }

    func testStatusCollectsReplicaTelemetryConcurrentlyOnlyOnRequestAndKeepsPartialSuccess() async throws {
        let harness = try makeHarness(remoteReady: true)
        let probe = ConcurrentTelemetryProbe()
        let hqSnapshot = try makeRemoteTelemetrySnapshot(replicaID: "hq")
        let coordinator = ArchiveV2ServiceCoordinator.make(
            settings: harness.settings,
            databasePath: harness.database.path,
            writerGate: harness.gate,
            tokenLoaderFactory: { StaticTokenLoader() },
            backendFactory: { connection in
                RemoteTelemetryBackend(
                    replicaID: connection.replicaID,
                    result: connection.replicaID == "hq"
                        ? .success(hqSnapshot)
                        : .failure(.transport(.network)),
                    probe: probe
                )
            }
        )

        let beforeStatus = await probe.startedReplicaIDs()
        XCTAssertEqual(beforeStatus, [])
        let status = await coordinator.status()
        let startedReplicaIDs = await probe.startedReplicaIDs()
        let overlapped = await probe.overlapped()

        XCTAssertEqual(status.replicas.map(\.replicaID), ["hq", "m1"])
        XCTAssertEqual(status.replicas[0].remoteTelemetry?.serverID, "hq")
        XCTAssertNil(status.replicas[0].remoteTelemetryError)
        XCTAssertNil(status.replicas[1].remoteTelemetry)
        XCTAssertEqual(status.replicas[1].remoteTelemetryError, "transport_network")
        XCTAssertEqual(Set(startedReplicaIDs), Set(["hq", "m1"]))
        XCTAssertTrue(overlapped)
    }

    func testRemoteTelemetryErrorsMapToFixedSymbolsWithoutRawDetails() {
        let cases: [(Error, String)] = [
            (ArchiveReplicaBackendError.invalidDigest, "invalid_request"),
            (ArchiveReplicaBackendError.invalidRequest, "invalid_request"),
            (ArchiveReplicaBackendError.notHTTPResponse, "not_http_response"),
            (ArchiveReplicaBackendError.unexpectedStatus(599), "unexpected_status"),
            (ArchiveReplicaBackendError.responseTooLarge(.telemetry), "response_too_large"),
            (ArchiveReplicaBackendError.redirectRejected, "redirect_rejected"),
            (ArchiveReplicaBackendError.finalURLMismatch, "final_url_mismatch"),
            (ArchiveReplicaBackendError.invalidCanonicalResponse, "invalid_canonical_response"),
            (ArchiveReplicaBackendError.telemetryUnsupported, "telemetry_unsupported"),
            (ArchiveReplicaBackendError.transport(.cancelled), "transport_cancelled"),
            (ArchiveReplicaBackendError.transport(.timedOut), "transport_timeout"),
            (ArchiveReplicaBackendError.transport(.tls), "transport_tls"),
            (ArchiveReplicaBackendError.transport(.network), "transport_network"),
            (
                NSError(
                    domain: "https://secret-host.example/token/private/path",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "bearer super-secret-token"]
                ),
                "remote_telemetry_unavailable"
            ),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                ArchiveV2ServiceCoordinator.remoteTelemetryErrorSymbol(error),
                expected
            )
        }
    }

    func testDefaultOffFactoryHasNoDirectoryCredentialBackendOrCatalogSideEffect() async throws {
        let root = temporaryRoot("default-off")
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let runtimeURL = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let gate = try ServiceWriterGate(databasePath: databaseURL.path, runtimeDirectory: runtimeURL)
        let settings = ArchiveV2Settings.load(
            settingsURL: root.appendingPathComponent("missing-settings.json"),
            environment: [:]
        )
        let probes = FactoryProbes()

        let coordinator = ArchiveV2ServiceCoordinator.make(
            settings: settings,
            databasePath: databaseURL.path,
            writerGate: gate,
            tokenLoaderFactory: {
                probes.incrementTokenFactories()
                return MissingTokenLoader()
            },
            backendFactory: { _ in
                probes.incrementBackends()
                throw TestError.backendMustNotBeBuilt
            }
        )
        let result = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            try await self.emptyIndexResult(gate: gate)
        }

        XCTAssertEqual(result.indexed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive-v2").path))
        XCTAssertEqual(probes.tokenFactories, 0)
        XCTAssertEqual(probes.backends, 0)
        let status = await coordinator.status()
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.capturedCount, 0)
    }

    func testMissingTokenKeepsLocalCaptureEnabledAndBuildsNoBackend() async throws {
        let harness = try makeHarness(remoteReady: true)
        let databasePath = harness.database.path
        let probes = FactoryProbes()
        let coordinator = ArchiveV2ServiceCoordinator.make(
            settings: harness.settings,
            databasePath: databasePath,
            writerGate: harness.gate,
            tokenLoaderFactory: {
                probes.incrementTokenFactories()
                return MissingTokenLoader()
            },
            backendFactory: { _ in
                probes.incrementBackends()
                throw TestError.backendMustNotBeBuilt
            }
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        let status = await coordinator.status()

        XCTAssertTrue(status.enabled)
        XCTAssertTrue(status.localCaptureEnabled)
        XCTAssertFalse(status.remoteReplicationEnabled)
        XCTAssertEqual(status.configurationError, "remote_credentials_unavailable")
        XCTAssertEqual(probes.tokenFactories, 1)
        XCTAssertEqual(probes.backends, 0)
        let archiveRoot = URL(fileURLWithPath: databasePath)
            .deletingLastPathComponent()
            .appendingPathComponent("archive-v2", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot.path))
    }

    func testMissingCredentialsStillFreezeIngestionPolicyWithoutRunningNetwork() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let records = PolicyRecordLog()
        let target = ArchiveV2ServiceCaptureTarget(
            captureID: String(repeating: "8", count: 64),
            source: .codex,
            locator: "/tmp/archive-v2-missing-token.jsonl",
            generation: nil,
            capturedAt: "2026-07-12T00:00:00.000Z"
        )
        let bound = ArchiveV2ServicePolicyTarget(
            manifestSHA256: String(repeating: "9", count: 64),
            captureID: target.captureID,
            sessionID: "missing-token-session",
            source: target.source,
            locator: target.locator,
            boundAt: target.capturedAt,
            historical: false
        )
        var operations = makeOperations(events: events)
        operations.bindingTargets = { _ in
            await events.append("targets")
            return [target]
        }
        operations.snapshot = { _, _ in
            await events.append("snapshot")
            return ArchiveV2ServiceIndexSnapshot(rows: [
                ArchiveV2ServiceSnapshotRow(
                    captureID: target.captureID,
                    sessionID: bound.sessionID,
                    source: target.source,
                    locator: target.locator,
                    cwd: "/private/project/secret",
                    trustedIndexState: true,
                    proof: nil
                ),
            ])
        }
        operations.bindOne = { _, _ in
            await events.append("bind")
            return bound
        }
        operations.applyRemotePolicy = { policyTarget, root, eligibility in
            await events.append("policy")
            await records.append(
                sessionID: policyTarget.sessionID,
                root: root,
                eligibility: eligibility
            )
        }
        operations.replicate = { _ in
            await events.append("network-must-not-run")
            return ArchiveReplicationCycleResult()
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: "remote_credentials_unavailable",
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            await events.append("index")
            return try await self.emptyIndexResult(gate: harness.gate)
        }

        let policyRecords = await records.values()
        XCTAssertEqual(
            policyRecords,
            [PolicyRecord("missing-token-session", "/private/project/secret", .excluded)]
        )
        let recordedEvents = await events.values()
        XCTAssertTrue(recordedEvents.contains("historical"))
        XCTAssertTrue(recordedEvents.contains("policy"))
        XCTAssertFalse(recordedEvents.contains("network-must-not-run"))
    }

    func testInvalidRemoteConfigurationLeavesNewBindingsPolicyUnknown() async throws {
        let harness = try makeHarness(remoteReady: false)
        let events = EventLog()
        let target = ArchiveV2ServiceCaptureTarget(
            captureID: String(repeating: "6", count: 64),
            source: .codex,
            locator: "/tmp/archive-v2-invalid-config.jsonl",
            generation: nil,
            capturedAt: "2026-07-12T00:00:00.000Z"
        )
        var operations = makeOperations(events: events)
        operations.bindingTargets = { _ in
            await events.append("targets")
            return [target]
        }
        operations.bindOne = { target, _ in
            await events.append("bind")
            return ArchiveV2ServicePolicyTarget(
                manifestSHA256: String(repeating: "7", count: 64),
                captureID: target.captureID,
                sessionID: "invalid-config-session",
                source: target.source,
                locator: target.locator,
                boundAt: target.capturedAt,
                historical: false
            )
        }
        operations.applyRemotePolicy = { _, _, _ in
            await events.append("policy-must-not-run")
        }
        operations.replicate = { _ in
            await events.append("network-must-not-run")
            return ArchiveReplicationCycleResult()
        }
        let invalidSettings = ArchiveV2Settings(
            exactArchiveEnabled: true,
            remoteConfiguration: nil,
            configurationError: .invalidRemoteConfiguration
        )
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: invalidSettings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: ArchiveV2SettingsConfigurationError.invalidRemoteConfiguration.rawValue,
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }

        let recorded = await events.values()
        XCTAssertTrue(recorded.contains("bind"), "local capture binding should remain available")
        XCTAssertFalse(recorded.contains("historical"))
        XCTAssertFalse(recorded.contains("policy-must-not-run"))
        XCTAssertFalse(recorded.contains("network-must-not-run"))
    }

    func testSnapshotPreservesDuplicateLocatorRowsAndUsesCaptureExactProofFields() async throws {
        let harness = try makeHarness(remoteReady: false)
        let sourceURL = temporaryRoot("duplicate").appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one\n".utf8).write(to: sourceURL)
        let stat = try XCTUnwrap(FileIndexStat.directFileStat(locator: sourceURL.path))
        let target = try captureTarget(
            digestCharacter: "d",
            locator: sourceURL.path,
            stat: stat,
            captureMtimeOffset: 17
        )
        try await seedSnapshotRows(
            gate: harness.gate,
            locator: sourceURL.path,
            stat: stat,
            parseStatus: .ok,
            sessions: [
                ("duplicate-a", "/project/a"),
                ("duplicate-b", "/project/b"),
            ]
        )

        let snapshot = try await ArchiveV2ServiceCoordinator.readIndexSnapshot(
            gate: harness.gate,
            targets: [target]
        )

        XCTAssertEqual(snapshot.rows.map(\.sessionID), ["duplicate-a", "duplicate-b"])
        XCTAssertEqual(snapshot.rows.compactMap(\.proof).count, 2)
        XCTAssertEqual(
            snapshot.rows[0].proof?.modifiedAtNanos,
            stat.modifiedAtNanos + 17,
            "proof must carry the exact capture generation rather than FileManager mtime"
        )
    }

    func testSnapshotRejectsCaptureGenerationThatDoesNotMatchIndexedFileGeneration() async throws {
        let harness = try makeHarness(remoteReady: false)
        let sourceURL = temporaryRoot("generation-aba").appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("indexed-generation\n".utf8).write(to: sourceURL)
        let indexedStat = try XCTUnwrap(FileIndexStat.directFileStat(locator: sourceURL.path))
        let mismatchedGeneration = try ArchiveSourceGeneration(
            device: try XCTUnwrap(indexedStat.device),
            inode: try XCTUnwrap(indexedStat.inode),
            size: indexedStat.sizeBytes + 1,
            mtimeNs: indexedStat.modifiedAtNanos,
            ctimeNs: 0,
            mode: 0o100600
        )
        let target = ArchiveV2ServiceCaptureTarget(
            captureID: String(repeating: "7", count: 64),
            source: .codex,
            locator: sourceURL.path,
            generation: mismatchedGeneration,
            capturedAt: "2026-07-12T00:00:00.000Z"
        )
        try await seedSnapshotRows(
            gate: harness.gate,
            locator: sourceURL.path,
            stat: indexedStat,
            parseStatus: .ok,
            sessions: [("generation-b", "/project/b")]
        )

        let snapshot = try await ArchiveV2ServiceCoordinator.readIndexSnapshot(
            gate: harness.gate,
            targets: [target]
        )

        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertFalse(snapshot.rows[0].trustedIndexState)
        XCTAssertNil(
            snapshot.rows[0].proof,
            "an index row for generation B must not authorize binding captured generation A"
        )
    }

    func testSnapshotLeavesStaleAndNonOKIndexRowsUntrusted() async throws {
        let harness = try makeHarness(remoteReady: false)
        let root = temporaryRoot("stale")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleURL = root.appendingPathComponent("stale.jsonl")
        let retryURL = root.appendingPathComponent("retry.jsonl")
        try Data("stale-before\n".utf8).write(to: staleURL)
        try Data("retry\n".utf8).write(to: retryURL)
        let staleStat = try XCTUnwrap(FileIndexStat.directFileStat(locator: staleURL.path))
        let retryStat = try XCTUnwrap(FileIndexStat.directFileStat(locator: retryURL.path))
        let staleTarget = try captureTarget(digestCharacter: "e", locator: staleURL.path, stat: staleStat)
        let retryTarget = try captureTarget(digestCharacter: "f", locator: retryURL.path, stat: retryStat)
        try await seedSnapshotRows(
            gate: harness.gate,
            locator: staleURL.path,
            stat: staleStat,
            parseStatus: .ok,
            sessions: [("stale-session", "/project/stale")]
        )
        try await seedSnapshotRows(
            gate: harness.gate,
            locator: retryURL.path,
            stat: retryStat,
            parseStatus: .retry,
            sessions: [("retry-session", "/project/retry")],
            migrate: false
        )
        try FileHandle(forWritingTo: staleURL).closeAfterAppending(Data("changed\n".utf8))

        let snapshot = try await ArchiveV2ServiceCoordinator.readIndexSnapshot(
            gate: harness.gate,
            targets: [staleTarget, retryTarget]
        )

        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.proof == nil })
    }

    func testHistoricalUntrustedRowStaysUnknownButAdvancesDurableCursor() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let stat = FileIndexStat(sizeBytes: 1, modifiedAtNanos: 1, inode: 1, device: 1)
        let capture = try captureTarget(
            digestCharacter: "1",
            locator: "/tmp/archive-v2-untrusted.jsonl",
            stat: stat
        )
        let target = ArchiveV2ServicePolicyTarget(
            manifestSHA256: String(repeating: "2", count: 64),
            captureID: capture.captureID,
            sessionID: "untrusted-session",
            source: capture.source,
            locator: capture.locator,
            boundAt: "2026-07-12T00:00:00.000Z",
            historical: true
        )
        var operations = makeOperations(events: events)
        operations.historicalUnknown = { _ in
            await events.append("historical")
            return ArchiveV2ServiceUnknownPage(targets: [target])
        }
        operations.snapshot = { _, _ in
            await events.append("snapshot")
            return ArchiveV2ServiceIndexSnapshot(rows: [
                ArchiveV2ServiceSnapshotRow(
                    captureID: target.captureID,
                    sessionID: target.sessionID,
                    source: target.source,
                    locator: target.locator,
                    cwd: "/project/untrusted",
                    trustedIndexState: false,
                    proof: nil
                ),
            ])
        }
        operations.advancePolicyCursor = { advanced in
            XCTAssertEqual(advanced, target)
            await events.append("cursor")
        }
        operations.applyRemotePolicy = { _, _, _ in
            await events.append("policy-must-not-run")
        }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            await events.append("index")
            return try await self.emptyIndexResult(gate: harness.gate)
        }

        let recorded = await events.values()
        XCTAssertTrue(recorded.contains("cursor"))
        XCTAssertFalse(recorded.contains("policy-must-not-run"))
    }

    func testHistoricalPolicySweepRevisitsOldUnknownDespiteContinuouslyGrowingTail() throws {
        let archiveRoot = temporaryRoot("policy-sweep")
        let machineID = "22222222-2222-4222-8222-222222222222"
        let catalog = try ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try catalog.migrate()
        let old = try [
            addUnknownBinding(
                to: catalog,
                machineID: machineID,
                seed: "policy-old-a",
                boundAt: "2026-07-12T00:00:00.000Z"
            ),
            addUnknownBinding(
                to: catalog,
                machineID: machineID,
                seed: "policy-old-b",
                boundAt: "2026-07-12T00:00:01.000Z"
            ),
        ]

        let first = try ArchiveV2ServiceCoordinator.loadHistoricalUnknownPage(
            catalog: catalog,
            limit: 1
        )
        XCTAssertEqual(first.targets.map(\.manifestSHA256), [old[0].manifestSHA256])
        try ArchiveV2ServiceCoordinator.storePolicyCursor(
            catalog: catalog,
            target: try XCTUnwrap(first.targets.first)
        )

        let tail = try addUnknownBinding(
            to: catalog,
            machineID: machineID,
            seed: "policy-new-tail",
            boundAt: "2026-07-12T00:00:02.000Z"
        )
        let reopened = try ArchiveCatalog(root: archiveRoot, machineID: machineID)
        try reopened.migrate()
        let second = try ArchiveV2ServiceCoordinator.loadHistoricalUnknownPage(
            catalog: reopened,
            limit: 10
        )
        XCTAssertEqual(second.targets.map(\.manifestSHA256), [old[1].manifestSHA256])
        XCTAssertFalse(second.targets.contains { $0.manifestSHA256 == tail.manifestSHA256 })
        try ArchiveV2ServiceCoordinator.storePolicyCursor(
            catalog: reopened,
            target: try XCTUnwrap(second.targets.first)
        )

        let frozenSweepEnd = try ArchiveV2ServiceCoordinator.loadHistoricalUnknownPage(
            catalog: reopened,
            limit: 10
        )
        XCTAssertTrue(frozenSweepEnd.targets.isEmpty)

        let nextSweep = try ArchiveV2ServiceCoordinator.loadHistoricalUnknownPage(
            catalog: reopened,
            limit: 1
        )
        XCTAssertEqual(
            nextSweep.targets.map(\.manifestSHA256),
            [old[0].manifestSHA256],
            "a leaveUnknown row must be revisited even while newer unknown rows keep arriving"
        )
    }

    func testTrustedRemotePolicyIsEligibleExcludedOrFailClosedFromCwd() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let records = PolicyRecordLog()
        let stat = FileIndexStat(sizeBytes: 1, modifiedAtNanos: 1, inode: 1, device: 1)
        let captures = try [
            captureTarget(digestCharacter: "3", locator: "/tmp/archive-v2-policy-a.jsonl", stat: stat),
            captureTarget(digestCharacter: "4", locator: "/tmp/archive-v2-policy-b.jsonl", stat: stat),
            captureTarget(digestCharacter: "5", locator: "/tmp/archive-v2-policy-c.jsonl", stat: stat),
        ]
        let targets = captures.enumerated().map { index, capture in
            ArchiveV2ServicePolicyTarget(
                manifestSHA256: String(repeating: String(index + 6), count: 64),
                captureID: capture.captureID,
                sessionID: "policy-\(index)",
                source: capture.source,
                locator: capture.locator,
                boundAt: "2026-07-12T00:00:0\(index).000Z",
                historical: true
            )
        }
        let cwds = ["/project/allowed", "/private/project/secret", "relative/project"]
        var operations = makeOperations(events: events)
        operations.historicalUnknown = { _ in ArchiveV2ServiceUnknownPage(targets: targets) }
        operations.snapshot = { _, _ in
            ArchiveV2ServiceIndexSnapshot(
                rows: targets.enumerated().map { index, target in
                    ArchiveV2ServiceSnapshotRow(
                        captureID: target.captureID,
                        sessionID: target.sessionID,
                        source: target.source,
                        locator: target.locator,
                        cwd: cwds[index],
                        trustedIndexState: true,
                        proof: nil
                    )
                }
            )
        }
        operations.applyRemotePolicy = { target, root, eligibility in
            await records.append(
                sessionID: target.sessionID,
                root: root,
                eligibility: eligibility
            )
        }
        operations.advancePolicyCursor = { _ in }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        let values = await records.values()

        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], PolicyRecord("policy-0", "/project/allowed", .eligible))
        XCTAssertEqual(values[1], PolicyRecord("policy-1", "/private/project/secret", .excluded))
        XCTAssertEqual(values[2], PolicyRecord("policy-2", nil, .excluded))
    }

    func testCaptureSummaryRetriesMissingAndDeclaredSingleFileDiagnosticsButClearsTerminalOutcomes() {
        let root = temporaryRoot("capture-summary")
        let retry = root.appendingPathComponent("retry.jsonl").path
        let succeeded = root.appendingPathComponent("succeeded.jsonl").path
        let unsafe = root.appendingPathComponent("unsafe.jsonl").path
        let missing = root.appendingPathComponent("missing.jsonl").path
        let unsupported = root.appendingPathComponent("unsupported.jsonl").path
        let result = ArchiveCaptureCycleResult(
            items: [
                ArchiveCaptureCycleItem(
                    source: .claudeCode,
                    locator: retry,
                    classification: .declaredSingleFile(URL(fileURLWithPath: retry)),
                    captureID: nil,
                    diagnostic: "io(operation: read-source, code: 5)"
                ),
                ArchiveCaptureCycleItem(
                    source: .claudeCode,
                    locator: succeeded,
                    classification: .declaredSingleFile(URL(fileURLWithPath: succeeded)),
                    captureID: String(repeating: "a", count: 64),
                    diagnostic: nil
                ),
                ArchiveCaptureCycleItem(
                    source: .claudeCode,
                    locator: unsafe,
                    classification: .unsafe("descriptor rejected"),
                    captureID: nil,
                    diagnostic: "synthetic descriptor failure"
                ),
                ArchiveCaptureCycleItem(
                    source: .claudeCode,
                    locator: missing,
                    classification: .missing,
                    captureID: nil,
                    diagnostic: nil
                ),
                ArchiveCaptureCycleItem(
                    source: .claudeCode,
                    locator: unsupported,
                    classification: .unsupportedVirtual,
                    captureID: nil,
                    diagnostic: nil
                ),
                ArchiveCaptureCycleItem(
                    source: .codex,
                    locator: "",
                    classification: .unsafe("locator enumeration failed"),
                    captureID: nil,
                    diagnostic: "synthetic enumeration failure"
                ),
            ],
            captures: [],
            processed: 7,
            capturedSourceBytes: 4_096
        )

        let summary = ArchiveV2ServiceCoordinator.captureSummary(from: result)

        XCTAssertEqual(summary.unsupported, 1)
        XCTAssertEqual(summary.unsafe, 4)
        XCTAssertEqual(summary.processed, 7)
        XCTAssertEqual(summary.capturedSourceBytes, 4_096)
        XCTAssertEqual(summary.transientRetryLocators, [.claudeCode: [retry, missing]])
        XCTAssertEqual(
            summary.resolvedRetryLocators,
            [.claudeCode: [succeeded, unsafe, unsupported]]
        )
        XCTAssertNil(summary.transientRetryLocators[.codex])
        XCTAssertNil(summary.resolvedRetryLocators[.codex])
    }

    func testRecentCaptureRetryLocatorsStayStableDeduplicatedAndClearAfterResolution() async throws {
        let harness = try makeHarness(remoteReady: false, batchSize: 4)
        let events = EventLog()
        let root = temporaryRoot("retry-state")
        let first = root.appendingPathComponent("first.jsonl").path
        let second = root.appendingPathComponent("second.jsonl").path
        let third = root.appendingPathComponent("third.jsonl").path
        let summaries = CaptureSummaryQueue([
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 2,
                transientRetryLocators: [.claudeCode: [first, second, first]],
                resolvedRetryLocators: [:]
            ),
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 2,
                transientRetryLocators: [.claudeCode: [second, third, second]],
                resolvedRetryLocators: [.claudeCode: [first]]
            ),
            ArchiveV2ServiceCaptureSummary(
                unsupported: 1,
                unsafe: 0,
                transientRetryLocators: [:],
                resolvedRetryLocators: [.claudeCode: [second]]
            ),
        ])
        var operations = makeOperations(events: events)
        operations.capture = { _, _, _ in try await summaries.next() }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: operations
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        let firstState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 100)
        let firstBoundedState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 1)
        XCTAssertEqual(
            firstState,
            [.claudeCode: [first, second]]
        )
        XCTAssertEqual(
            firstBoundedState,
            [.claudeCode: [first]]
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        let secondState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 100)
        XCTAssertEqual(
            secondState,
            [.claudeCode: [second, third]]
        )

        _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: harness.gate)
        }
        let thirdState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 100)
        let zeroState = await coordinator.recentCaptureRetryLocators(maximumPerSource: 0)
        XCTAssertEqual(
            thirdState,
            [.claudeCode: [third]],
            "a later terminal outcome must stop an earlier transient failure from retrying forever"
        )
        XCTAssertEqual(zeroState, [:])
    }

    func testRecentCaptureRetryLocatorsHonorConfiguredAndAbsoluteHardBounds() async throws {
        let root = temporaryRoot("retry-bounds")
        let locators = (0 ..< 105).map {
            root.appendingPathComponent("retry-\($0).jsonl").path
        }

        let configuredHarness = try makeHarness(remoteReady: false, batchSize: 3)
        let configuredEvents = EventLog()
        var configuredOperations = makeOperations(events: configuredEvents)
        configuredOperations.capture = { _, _, _ in
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: locators.count,
                transientRetryLocators: [.codex: locators],
                resolvedRetryLocators: [:]
            )
        }
        let configuredCoordinator = ArchiveV2ServiceCoordinator(
            settings: configuredHarness.settings,
            writerGate: configuredHarness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: configuredOperations
        )
        _ = try await configuredCoordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: configuredHarness.gate)
        }
        let configuredState = await configuredCoordinator.recentCaptureRetryLocators(
            maximumPerSource: 1_000
        )
        XCTAssertEqual(
            configuredState[.codex],
            Array(locators.prefix(3))
        )

        let hardHarness = try makeHarness(remoteReady: false, batchSize: 100)
        let hardEvents = EventLog()
        var hardOperations = makeOperations(events: hardEvents)
        hardOperations.capture = configuredOperations.capture
        let hardCoordinator = ArchiveV2ServiceCoordinator(
            settings: hardHarness.settings,
            writerGate: hardHarness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: hardOperations
        )
        _ = try await hardCoordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
            try await self.emptyIndexResult(gate: hardHarness.gate)
        }
        let hardState = await hardCoordinator.recentCaptureRetryLocators(
            maximumPerSource: 1_000
        )
        XCTAssertEqual(
            hardState[.codex],
            Array(locators.prefix(100))
        )
    }

    func testResolvedRetryFreesCapacityForNewTransientInTheSameSummary() async throws {
        let harness = try makeHarness(remoteReady: false, batchSize: 2)
        let events = EventLog()
        let root = temporaryRoot("retry-replacement")
        let first = root.appendingPathComponent("first.jsonl").path
        let second = root.appendingPathComponent("second.jsonl").path
        let replacement = root.appendingPathComponent("replacement.jsonl").path
        let summaries = CaptureSummaryQueue([
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 2,
                transientRetryLocators: [.claudeCode: [first, second]]
            ),
            ArchiveV2ServiceCaptureSummary(
                unsupported: 0,
                unsafe: 2,
                transientRetryLocators: [.claudeCode: [first, replacement]],
                resolvedRetryLocators: [.claudeCode: [first]]
            ),
        ])
        var operations = makeOperations(events: events)
        operations.capture = { _, _, _ in try await summaries.next() }
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: false,
            configurationError: nil,
            operations: operations
        )

        for _ in 0 ..< 2 {
            _ = try await coordinator.runCycle(adapters: [], cursorScope: .recent) { _ in
                try await self.emptyIndexResult(gate: harness.gate)
            }
        }
        let state = await coordinator.recentCaptureRetryLocators(maximumPerSource: 100)

        XCTAssertEqual(
            state[.claudeCode],
            [second, replacement],
            "resolved locators must free bounded capacity before new failures are appended"
        )
    }

    func testCancellationStopsBeforeIndexAndEveryLaterPhase() async throws {
        let harness = try makeHarness(remoteReady: true)
        let events = EventLog()
        let coordinator = ArchiveV2ServiceCoordinator(
            settings: harness.settings,
            writerGate: harness.gate,
            remoteReady: true,
            configurationError: nil,
            operations: makeOperations(events: events, captureDelayNanos: 5_000_000_000)
        )
        let task = Task {
            try await coordinator.runCycle(adapters: [], cursorScope: .full) { _ in
                await events.append("index-must-not-run")
                return try await self.emptyIndexResult(gate: harness.gate)
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        let recorded = await events.values()
        XCTAssertEqual(recorded, ["capture"])
    }

    // MARK: - Helpers

    private func makeHarness(remoteReady: Bool, batchSize: Int = 4) throws -> Harness {
        let root = temporaryRoot("harness")
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let database = root.appendingPathComponent("index.sqlite")
        let gate = try ServiceWriterGate(databasePath: database.path, runtimeDirectory: runtime)
        let settingsURL = root.appendingPathComponent("settings.json")
        let object: [String: Any] = [
            "exactArchiveEnabled": true,
            "remoteArchiveV2": [
                "enabled": remoteReady,
                "batchSize": batchSize,
                "replicas": remoteReady ? [
                    ["id": "hq", "serverURL": "https://hq.example.ts.net", "requireTLS": true],
                    ["id": "m1", "serverURL": "https://m1.example.ts.net", "requireTLS": true],
                ] : [],
                "excludedProjectRoots": ["/private/project"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
        return Harness(
            settings: ArchiveV2Settings.load(settingsURL: settingsURL, environment: [:]),
            gate: gate,
            database: database
        )
    }

    private func makeOperations(
        events: EventLog,
        captureDelayNanos: UInt64 = 0
    ) -> ArchiveV2ServiceCoordinatorOperations {
        ArchiveV2ServiceCoordinatorOperations(
            capture: { _, _, _ in
                await events.append("capture")
                if captureDelayNanos > 0 {
                    try await Task.sleep(nanoseconds: captureDelayNanos)
                }
                return ArchiveV2ServiceCaptureSummary(unsupported: 0, unsafe: 0)
            },
            bindingTargets: { _ in
                await events.append("targets")
                return []
            },
            historicalUnknown: { _ in
                await events.append("historical")
                return ArchiveV2ServiceUnknownPage(targets: [])
            },
            advancePolicyCursor: { _ in
                await events.append("cursor")
            },
            snapshot: { _, _ in
                await events.append("snapshot")
                return ArchiveV2ServiceIndexSnapshot(rows: [])
            },
            bindOne: { _, _ in
                await events.append("bind")
                return nil
            },
            applyRemotePolicy: { _, _, _ in
                await events.append("policy")
            },
            replicate: { _ in
                await events.append("replicate")
                return ArchiveReplicationCycleResult()
            },
            status: { zeroAggregate() },
            retry: { _ in 0 }
        )
    }

    private func emptyIndexResult(gate: ServiceWriterGate) async throws -> EngramDatabaseIndexResult {
        try await gate.performWriteCommand(name: "archiveV2TestIndex") { writer in
            try writer.migrate()
            return try await writer.indexAllSessions(adapters: [])
        }.value
    }

    private func captureTarget(
        digestCharacter: Character,
        locator: String,
        stat: FileIndexStat,
        captureMtimeOffset: Int64 = 0
    ) throws -> ArchiveV2ServiceCaptureTarget {
        ArchiveV2ServiceCaptureTarget(
            captureID: String(repeating: String(digestCharacter), count: 64),
            source: .codex,
            locator: locator,
            generation: try ArchiveSourceGeneration(
                device: try XCTUnwrap(stat.device),
                inode: try XCTUnwrap(stat.inode),
                size: stat.sizeBytes,
                mtimeNs: stat.modifiedAtNanos + captureMtimeOffset,
                ctimeNs: 0,
                mode: 0o100600
            ),
            capturedAt: "2026-07-12T00:00:00.000Z"
        )
    }

    private func seedSnapshotRows(
        gate: ServiceWriterGate,
        locator: String,
        stat: FileIndexStat,
        parseStatus: FileIndexParseStatus,
        sessions: [(id: String, cwd: String)],
        migrate: Bool = true
    ) async throws {
        _ = try await gate.performWriteCommand(name: "archiveV2SeedSnapshot") { writer in
            if migrate { try writer.migrate() }
            try writer.write { db in
                for session in sessions {
                    try db.execute(
                        sql: """
                        INSERT INTO sessions(
                          id, source, start_time, end_time, file_path, source_locator,
                          project, cwd
                        ) VALUES (?, 'codex', '2026-07-12T00:00:00Z',
                                  '2026-07-12T00:01:00Z', ?, ?, 'archive-v2-test', ?)
                        """,
                        arguments: [session.id, locator, locator, session.cwd]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO file_index_state(
                      source, locator, size_bytes, mtime_ns, inode, device,
                      parsed_offset, boundary_hash, parse_status, failure_kind,
                      retry_after, retry_count, last_error, schema_version, updated_at
                    ) VALUES ('codex', ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, 0, NULL, ?, 1)
                    """,
                    arguments: [
                        locator,
                        stat.sizeBytes,
                        stat.modifiedAtNanos,
                        stat.inode,
                        stat.device,
                        stat.sizeBytes,
                        parseStatus.rawValue,
                        FileIndexState.currentSchemaVersion,
                    ]
                )
            }
        }
    }

    private func addUnknownBinding(
        to catalog: ArchiveCatalog,
        machineID: String,
        seed: String,
        boundAt: String
    ) throws -> ArchiveBinding {
        let captureID = ArchiveV2Hash.sha256(Data("capture-\(seed)".utf8))
        let locator = "/tmp/\(seed).jsonl"
        let generation = try ArchiveSourceGeneration(
            device: 1,
            inode: 1,
            size: 0,
            mtimeNs: 1,
            ctimeNs: 1,
            mode: 0o100600
        )
        let replay = try ArchiveReplayLayout(
            strategy: .singleFile,
            relativePaths: ["sessions/\(seed).jsonl"]
        )
        let common: (String?) throws -> ArchiveSourceManifest = { sessionID in
            try ArchiveSourceManifest(
                captureID: captureID,
                machineID: machineID,
                source: SourceName.codex.rawValue,
                locator: locator,
                sessionID: sessionID,
                capturedAt: "2026-07-12T00:00:00.000Z",
                generation: generation,
                wholeSourceSHA256: ArchiveV2Hash.sha256(Data()),
                rawByteCount: 0,
                chunks: [],
                replayLayout: replay
            )
        }
        _ = try catalog.recordCapture(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(common(nil))
        )
        return try catalog.bind(
            canonicalManifestBytes: ArchiveCanonicalJSON.encode(
                common("session-\(seed)")
            ),
            sourceSnapshotFingerprint: ArchiveV2Hash.sha256(
                Data("snapshot-\(seed)".utf8)
            ),
            boundAt: boundAt
        )
    }

    private func temporaryRoot(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("engram-archive-v2-service-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct Harness {
    let settings: ArchiveV2Settings
    let gate: ServiceWriterGate
    let database: URL
}

private enum TestError: Error {
    case indexFailed
    case backendMustNotBeBuilt
    case missingCaptureSummary
}

private actor EventLog {
    private var events: [String] = []

    func append(_ value: String) {
        events.append(value)
    }

    func values() -> [String] {
        events
    }

    func count(of value: String) -> Int {
        events.filter { $0 == value }.count
    }
}

private actor CaptureSummaryQueue {
    private var summaries: [ArchiveV2ServiceCaptureSummary]

    init(_ summaries: [ArchiveV2ServiceCaptureSummary]) {
        self.summaries = summaries
    }

    func next() throws -> ArchiveV2ServiceCaptureSummary {
        guard !summaries.isEmpty else { throw TestError.missingCaptureSummary }
        return summaries.removeFirst()
    }
}

private struct PolicyRecord: Equatable {
    let sessionID: String
    let root: String?
    let eligibility: ArchiveRemoteEligibility

    init(_ sessionID: String, _ root: String?, _ eligibility: ArchiveRemoteEligibility) {
        self.sessionID = sessionID
        self.root = root
        self.eligibility = eligibility
    }
}

private actor PolicyRecordLog {
    private var records: [PolicyRecord] = []

    func append(sessionID: String, root: String?, eligibility: ArchiveRemoteEligibility) {
        records.append(PolicyRecord(sessionID, root, eligibility))
    }

    func values() -> [PolicyRecord] { records }
}

private final class FactoryProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var _tokenFactories = 0
    private var _backends = 0

    var tokenFactories: Int { lock.withLock { _tokenFactories } }
    var backends: Int { lock.withLock { _backends } }

    func incrementTokenFactories() { lock.withLock { _tokenFactories += 1 } }
    func incrementBackends() { lock.withLock { _backends += 1 } }
}

private final class CoordinatorDateQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.withLock {
            precondition(!dates.isEmpty, "test date queue exhausted")
            return dates.removeFirst()
        }
    }
}

private actor ReplicationResultQueue {
    private var results: [ArchiveReplicationCycleResult]

    init(_ results: [ArchiveReplicationCycleResult]) {
        self.results = results
    }

    func next() -> ArchiveReplicationCycleResult {
        precondition(!results.isEmpty, "test replication result queue exhausted")
        return results.removeFirst()
    }
}

private extension FileHandle {
    func closeAfterAppending(_ data: Data) throws {
        try seekToEnd()
        try write(contentsOf: data)
        try close()
    }
}

private struct MissingTokenLoader: ArchiveReplicaTokenLoading {
    func loadToken(replicaID _: String) throws -> String? { nil }
}

private struct StaticTokenLoader: ArchiveReplicaTokenLoading {
    func loadToken(replicaID: String) throws -> String? { "\(replicaID)-token" }
}

private actor ConcurrentTelemetryProbe {
    private var started: [String] = []
    private var didOverlap = false

    func begin(replicaID: String) async {
        started.append(replicaID)
        if started.count > 1 {
            didOverlap = true
        } else {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func startedReplicaIDs() -> [String] { started }
    func overlapped() -> Bool { didOverlap }
}

private actor RemoteTelemetryBackend: ArchiveReplicaBackend {
    let replicaID: String
    private let result: Result<ArchiveRemoteTelemetrySnapshot, ArchiveReplicaBackendError>
    private let probe: ConcurrentTelemetryProbe

    init(
        replicaID: String,
        result: Result<ArchiveRemoteTelemetrySnapshot, ArchiveReplicaBackendError>,
        probe: ConcurrentTelemetryProbe
    ) {
        self.replicaID = replicaID
        self.result = result
        self.probe = probe
    }

    func remoteTelemetryStatus() async throws -> ArchiveRemoteTelemetrySnapshot {
        await probe.begin(replicaID: replicaID)
        return try result.get()
    }

    func headObject(digest _: String) async throws -> Bool { throw TestError.backendMustNotBeBuilt }
    func putObject(digest _: String, data _: Data) async throws { throw TestError.backendMustNotBeBuilt }
    func getObject(digest _: String) async throws -> Data { throw TestError.backendMustNotBeBuilt }
    func headManifest(digest _: String) async throws -> Bool { throw TestError.backendMustNotBeBuilt }
    func putManifest(digest _: String, data _: Data) async throws { throw TestError.backendMustNotBeBuilt }
    func getManifest(digest _: String) async throws -> Data { throw TestError.backendMustNotBeBuilt }
    func createReceipt(manifestDigest _: String) async throws -> Data { throw TestError.backendMustNotBeBuilt }
    func getReceipt(manifestDigest _: String) async throws -> Data { throw TestError.backendMustNotBeBuilt }
    func listMachines(cursor _: String?, limit _: Int) async throws -> ArchiveMachinePage {
        throw TestError.backendMustNotBeBuilt
    }
    func listReceipts(
        machineID _: String,
        cursor _: String?,
        limit _: Int
    ) async throws -> ArchiveReceiptPage {
        throw TestError.backendMustNotBeBuilt
    }
}

private func makeRemoteTelemetrySnapshot(
    replicaID: String
) throws -> ArchiveRemoteTelemetrySnapshot {
    try ArchiveRemoteTelemetrySnapshot(
        serverID: replicaID,
        sourceRevision: String(repeating: replicaID == "hq" ? "a" : "b", count: 40),
        processStartedAt: "2026-07-12T00:00:00.000Z",
        snapshotAt: "2026-07-12T00:01:00.000Z",
        uptimeSeconds: 60,
        diskAvailableBytes: 500,
        diskTotalBytes: 1_000,
        requestCount: 4,
        successCount: 2,
        clientErrorCount: 1,
        serverErrorCount: 1,
        requestBytes: 100,
        responseBytes: 200,
        lastArchiveMutationAt: "2026-07-12T00:00:30.000Z",
        persistenceError: nil,
        endpoints: [
            try ArchiveRemoteTelemetryEndpoint(
                endpoint: "status",
                requestCount: 4,
                errorCount: 2,
                totalDurationMs: 20,
                maximumDurationMs: 8,
                requestBytes: 100,
                responseBytes: 200
            ),
        ],
        recentErrors: [
            try ArchiveRemoteTelemetryError(
                timestamp: "2026-07-12T00:00:45.000Z",
                endpoint: "status",
                method: "GET",
                statusCode: 500,
                category: "internal_error"
            ),
        ]
    )
}

private func zeroAggregate() -> ArchiveStatusAggregate {
    let zero = ArchiveReplicaStatusCounts(pending: 0, inflight: 0, retry: 0, quarantine: 0, verified: 0)
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
