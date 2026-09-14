import CryptoKit
import Darwin
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import XCTest
@testable import EngramCollectorCore
@testable import EngramRemoteServerCore

private typealias PublicationIntent = EngramCollectorCore.CollectorPublicationIntent
private typealias PublicationClaim = EngramCollectorCore.CollectorPublicationClaim
private typealias PublicationEnvelope = EngramCollectorCore.CollectorPublicationEnvelope
private typealias PublicationACK = EngramCollectorCore.CollectorPublicationACK
private typealias CaptureResult = EngramCollectorCore.ArchiveCaptureResult
private typealias Canonical = EngramCollectorCore.ArchiveCanonicalJSON
private typealias PublicationWorker = EngramCollectorCore.CollectorPublicationWorker
private typealias WorkerError = EngramCollectorCore.CollectorPublicationWorkerError

final class CollectorPublicationWorkerTests: XCTestCase {
    func testDefaultClaudeRootPublishesIndependentDerivedSourceStreams() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.claudeCode, .minimax, .lobsterai])
        f.policy.change { $0 = allowed }
        var known = Set<String>()
        var instances: [String: String] = [:]
        var sequences: [String: Int64] = [:]
        let lobster = f.sourceRoot.appendingPathComponent("lobsterai-project/s.jsonl")
        try FileManager.default.createDirectory(at: lobster.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (offset, item) in [("claude-code", "claude-test", f.source), ("minimax", "MiniMax-M2", f.source),
                               ("lobsterai", "claude-test", lobster), ("claude-code", "claude-test", f.source)].enumerated() {
            let (expectedSource, model, file) = item
            let bytes = try derivedClaudeBytes(model: model, cwd: f.project.path, text: "generation \(offset)")
            try bytes.write(to: file)
            if offset > 0 {
                try f.markDirty(relativePath: file == lobster ? "lobsterai-project/s.jsonl" : nil)
            }
            let result = try await f.worker(replicas.endpoints).runOnce(now: Int64(100 + offset))
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            let added = try f.owner.publicationIntents(limit: 8).filter { !known.contains($0.digest) }
            XCTAssertEqual(added.count, 1)
            let intent = try XCTUnwrap(added.first)
            known.insert(intent.digest)
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            XCTAssertEqual(capture.source, expectedSource)
            if let instance = instances[expectedSource] {
                XCTAssertEqual(intent.publication.sourceInstanceID, instance)
            } else { instances[expectedSource] = intent.publication.sourceInstanceID }
            sequences[expectedSource, default: 0] += 1
            XCTAssertEqual(intent.publication.sequence, sequences[expectedSource])
            let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
            for replica in [replicas.hq, replicas.m1] {
                var copied = Data()
                for chunk in manifest.chunks { copied.append(try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
                XCTAssertEqual(copied, bytes)
            }
            try f.reopenOwnerAndCatalog()
        }
        XCTAssertEqual(Set(instances.values).count, 3)
        try f.assertNoLegacyAuthority()
        await replicas.stop()
    }

    func testDerivedClaudeSavedCASRecoveryKeepsReservedSourceAfterSourceDeletion() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.claudeCode, .minimax])
        f.policy.change { $0 = allowed }
        let bytes = try derivedClaudeBytes(model: "MiniMax-M2", cwd: f.project.path, text: "frozen native generation")
        try bytes.write(to: f.source)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in throw PublicationFixture.Failure.injected })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("injected post-CAS interruption must escape")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        XCTAssertEqual(reserved.effectiveSource, .minimax)
        try FileManager.default.removeItem(at: f.source)
        try f.reopenOwnerAndCatalog()
        let result = try await f.worker(replicas.endpoints).runOnce(now: 200)
        XCTAssertEqual(result.captured, 0)
        XCTAssertEqual(result.recovered, 1)
        XCTAssertEqual(result.sourceHintBytesRead, 0)
        XCTAssertEqual(result.acknowledgedHQ, 1)
        XCTAssertEqual(result.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(intent.publication.sourceInstanceID, reserved.sourceInstanceID)
        XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
        XCTAssertEqual(intent.publication.sequence, reserved.sequence)
        let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
        XCTAssertEqual(capture.source, "minimax")
        let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
        for replica in [replicas.hq, replicas.m1] {
            var copied = Data()
            for chunk in manifest.chunks { copied.append(try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
            XCTAssertEqual(copied, bytes)
        }
        await replicas.stop()
    }

    func testForcedClaudeProfileSkipsHintReadsAndPreservesClaudeSource() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        try derivedClaudeBytes(model: "MiniMax-M2", cwd: f.project.path, text: "forced profile").write(to: f.source)
        let result = try await f.worker(replicas.endpoints,
            formats: [f.configuration.rootID: .claudeCode(forceClaudeCodeSource: true)]).runOnce(now: 100)
        XCTAssertEqual(result.captured, 1)
        XCTAssertEqual(result.sourceHintBytesRead, 0)
        XCTAssertEqual(result.acknowledgedHQ, 1)
        XCTAssertEqual(result.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(try f.catalog.capture(captureID: intent.captureID)?.source, "claude-code")
        await replicas.stop()
    }

    func testQueuedUploaderCanProgressBetweenGenericCaptureUnits_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second independent capture unit").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 2
        let captures = PublicationLocked(0)
        let progressedBeforeSecond = PublicationLocked(false)
        let hqRequests = PublicationLocked(0)
        let firstStillRunning = PublicationLocked(true)
        let nestedRanDuringFirst = PublicationLocked(false)
        let nestedCaptured = PublicationLocked<Int?>(nil)
        let firstCaptured = XCTestExpectation(description: "first generic unit captured")
        let hoppersEntered = PublicationLocked(0)
        let releaseFirstCapture = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(
            beforeCapture: { _ in
                if captures.value >= 1 {
                    let claimed = try f.integer("""
                        SELECT count(*) FROM collector_publication_replicas
                        WHERE replica_id = 'hq' AND state IN ('inflight', 'acknowledged')
                        """)
                    progressedBeforeSecond.change { $0 = claimed > 0 || hqRequests.value > 0 }
                }
            },
            afterCapture: { _ in
                captures.change { $0 += 1 }
                guard captures.value == 1 else { return }
                firstCaptured.fulfill()
                XCTAssertTrue(publicationWaitUntil(2) { releaseFirstCapture.value },
                    "queued uploader must enter before the first capture unit resumes")
            },
            beforeRequest: { id, _ in
                if id == "hq" { hqRequests.change { $0 += 1 } }
            }
        )
        let worker = try f.worker(replicas.endpoints, budget: budget, hooks: hooks)
        let captureTask = Task { try await worker.captureOnce(now: 100) }
        await fulfillment(of: [firstCaptured], timeout: 5)
        let uploadTask = Task {
            hoppersEntered.change { $0 += 1 }
            _ = try? await worker.uploadOnce(replicaID: "hq", now: 100)
        }
        XCTAssertTrue(publicationWaitUntil(2) { hoppersEntered.value >= 1 },
            "HQ upload must reach its actor hop before the first capture resumes")
        let nestedTask = Task {
            hoppersEntered.change { $0 += 1 }
            let nested = try? await worker.captureOnce(now: 100)
            nestedRanDuringFirst.change { $0 = firstStillRunning.value }
            nestedCaptured.change { $0 = nested?.captured }
        }
        XCTAssertTrue(publicationWaitUntil(2) { hoppersEntered.value == 2 },
            "nested capture must reach its actor hop before the first capture resumes")
        releaseFirstCapture.change { $0 = true }
        let cycle = try await captureTask.value
        firstStillRunning.change { $0 = false }
        await uploadTask.value
        await nestedTask.value
        XCTAssertEqual(cycle.captured, 2)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertTrue(progressedBeforeSecond.value,
            "yield must let a queued uploader claim or start HTTP before the next generic capture")
        XCTAssertGreaterThan(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'acknowledged'
            """), 0, "the interrupted upload must still finish a valid ACK after the cycle")
        XCTAssertEqual(nestedCaptured.value, 0, "overlapping captureOnce must stay rejected")
        XCTAssertTrue(nestedRanDuringFirst.value, "the rejected nested capture must have been queued during the first cycle")
        await replicas.stop()
    }

    /// afterCapture is before owner.finishCapture. Preseed one finished
    /// publication, hold the next afterCapture, then ACK the earlier HQ row.
    /// Worker-level split only; not Runtime start() routing.
    func testIndependentUploadWorkerCanACKWhileCaptureHeld_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let first = try await f.worker(replicas.endpoints).captureOnce(now: 100)
        XCTAssertEqual(first.captured, 1)
        XCTAssertEqual(first.acknowledgedHQ, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'pending'
            """), 1)
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second held capture unit").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        let released = PublicationLocked(false)
        let secondHeld = XCTestExpectation(description: "second capture held before finishCapture")
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(
            afterCapture: { _ in
                secondHeld.fulfill()
                XCTAssertTrue(publicationWaitUntil(5) { released.value },
                    "second capture must stay held until the earlier publication ACK is observed")
            }
        )
        let captureWorker = try f.worker(replicas.endpoints, hooks: hooks)
        let uploadWorker = try f.worker(replicas.endpoints)
        let captureTask = Task { try await captureWorker.captureOnce(now: 101) }
        await fulfillment(of: [secondHeld], timeout: 5)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'pending'
            """), 1, "held afterCapture must not have finished the second publication yet")
        let uploadTask = Task { _ = try await uploadWorker.uploadOnce(replicaID: "hq", now: 101) }
        let acknowledgedWhileHeld = publicationWaitUntil(3) {
            (try? f.integer("""
                SELECT count(*) FROM collector_publication_replicas
                WHERE replica_id = 'hq' AND state = 'acknowledged'
                """)) ?? 0 > 0
        }
        XCTAssertTrue(acknowledgedWhileHeld,
            "HQ ACK of the first finished publication must complete while the second capture remains held")
        XCTAssertFalse(released.value)
        released.change { $0 = true }
        _ = try await captureTask.value
        _ = try await uploadTask.value
        await replicas.stop()
    }

    func testReplicaUploadRunsAtMostTwoOverlappingPublicationPuts_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        for name in ["two.jsonl", "three.jsonl"] {
            let file = f.sourceRoot.appendingPathComponent(name)
            try f.transcript(text: name).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o600), 0)
            try f.markDirty(relativePath: name)
        }
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 3
        let hold = try await PublicationHeldArchiveProxy.start(forwarding: replicas.hq)
        addTeardownBlock { await hold.stop() }
        let endpoints = [
            EngramCollectorCore.CollectorReplicaEndpoint(
                replicaID: "hq", baseURL: hold.baseURL, bearerToken: replicas.hq.token),
            replicas.m1.endpoint,
        ]
        let worker = try f.worker(endpoints, budget: budget)
        let captured = try await worker.captureOnce(now: 100)
        XCTAssertEqual(captured.captured, 3)
        let upload = Task { try await worker.uploadOnce(replicaID: "hq", now: 100) }
        XCTAssertTrue(publicationWaitUntil(5) { hold.maxInFlight >= 2 },
            "two claimed HQ publication PUTs must be in flight together")
        XCTAssertEqual(hold.inFlight, 2)
        XCTAssertLessThanOrEqual(hold.maxInFlight, 2)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'acknowledged'
            """), 0)
        hold.releaseHolds()
        let result = try await upload.value
        XCTAssertEqual(result.acknowledged, 3)
        XCTAssertEqual(result.deferred, 0)
        XCTAssertEqual(hold.maxInFlight, 2)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'acknowledged'
            """), 3)
        await replicas.stop()
    }

    func testReplicaUploadCancelWhileTwoPutsHeldLeavesNoACK_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let extra = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-unit").write(to: extra)
        XCTAssertEqual(chmod(extra.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 2
        let hold = try await PublicationHeldArchiveProxy.start(forwarding: replicas.hq)
        addTeardownBlock { await hold.stop() }
        let endpoints = [
            EngramCollectorCore.CollectorReplicaEndpoint(
                replicaID: "hq", baseURL: hold.baseURL, bearerToken: replicas.hq.token),
            replicas.m1.endpoint,
        ]
        let worker = try f.worker(endpoints, budget: budget)
        let captured = try await worker.captureOnce(now: 100)
        XCTAssertEqual(captured.captured, 2)
        let upload = Task { try await worker.uploadOnce(replicaID: "hq", now: 100) }
        XCTAssertTrue(publicationWaitUntil(5) { hold.inFlight == 2 })
        upload.cancel()
        do {
            _ = try await upload.value
            XCTFail("cancelled overlapping upload must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'acknowledged'
            """), 0)
        let cancelledRecords = try await replicas.hq.publications()
        XCTAssertEqual(cancelledRecords.count, 0)
        await replicas.stop()
    }

    func testReplicaUploadOverlapKeepsACKAndDeferOwnership_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let extra = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-unit").write(to: extra)
        XCTAssertEqual(chmod(extra.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 2
        let hold = try await PublicationHeldArchiveProxy.start(forwarding: replicas.hq)
        addTeardownBlock { await hold.stop() }
        let endpoints = [
            EngramCollectorCore.CollectorReplicaEndpoint(
                replicaID: "hq", baseURL: hold.baseURL, bearerToken: replicas.hq.token),
            replicas.m1.endpoint,
        ]
        let worker = try f.worker(endpoints, budget: budget)
        let captured = try await worker.captureOnce(now: 100)
        XCTAssertEqual(captured.captured, 2)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 2)
        let corrupt = try XCTUnwrap(intents.first).digest
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterResponse: { _, path, bytes in
            path.hasSuffix(corrupt) ? Data("[]".utf8) : bytes
        })
        let upload = Task { try await f.worker(endpoints, budget: budget, hooks: hooks).uploadOnce(replicaID: "hq", now: 100) }
        XCTAssertTrue(publicationWaitUntil(5) { hold.inFlight == 2 })
        hold.releaseHolds()
        let result = try await upload.value
        XCTAssertEqual(result.acknowledged, 1)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND state = 'acknowledged'
            """), 1)
        XCTAssertEqual(try f.integer("""
            SELECT count(*) FROM collector_publication_replicas
            WHERE replica_id = 'hq' AND last_error = 'invalidACK'
            """), 1)
        let accepted = try await replicas.hq.publications()
        XCTAssertEqual(accepted.count, 2)
        await replicas.stop()
    }

    func testDerivedClaudeFirstModelHintCannotAuthorizeLaterConflictingSource() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.claudeCode, .minimax])
        f.policy.change { $0 = allowed }
        var bytes = try derivedClaudeBytes(model: "MiniMax-M2", cwd: f.project.path, text: "first model")
        bytes.append(try derivedClaudeBytes(model: "claude-test", cwd: f.project.path, text: String(repeating: "later ", count: 16000)))
        try bytes.write(to: f.source)
        let result = try await f.worker(replicas.endpoints).runOnce(now: 100)
        XCTAssertEqual(result.captured, 1)
        XCTAssertGreaterThan(result.sourceHintBytesRead, 0)
        XCTAssertLessThanOrEqual(result.sourceHintBytesRead, 32768)
        XCTAssertEqual(result.acknowledgedHQ, 0)
        XCTAssertEqual(result.acknowledgedM1, 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(try f.catalog.capture(captureID: intent.captureID)?.source, "minimax")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
        await replicas.stop()
    }

    func testClaudeHintReadsShareOneCycleBudgetAcrossFailedCaptures() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        let bytes = try derivedClaudeBytes(model: "claude-test", cwd: f.project.path, text: "bounded hint")
        try bytes.write(to: f.source)
        try bytes.write(to: f.sourceRoot.appendingPathComponent("two.jsonl"))
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureBytes = Int64(bytes.count + bytes.count / 2)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw EngramCollectorCore.ExactSourceCapturerError.generationChanged
        })
        let result = try await f.worker(replicas.endpoints, budget: budget, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(result.captured, 0)
        XCTAssertEqual(result.sourceHintBytesRead, budget.maxCaptureBytes)
        XCTAssertGreaterThanOrEqual(result.deferred, 2)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        await replicas.stop()
    }

    func testClaudeHintAtExactBudgetPreservesUnterminatedSourceUntilCompleteGeneration() async throws {
        for hasModel in [false, true] {
            let f = try PublicationFixture(sourceName: .claudeCode)
            let replicas = try await replicas(for: f)
            let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 2, excludedProjectRoots: [], allowedSources: [.claudeCode, .minimax])
            f.policy.change { $0 = allowed }
            let complete = try derivedClaudeBytes(model: "MiniMax-M2", cwd: f.project.path, text: "exact budget")
            let bytes = hasModel ? Data(complete.dropLast()) : Data(complete.prefix { $0 != 0x0A })
            try bytes.write(to: f.source)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureBytes = Int64(bytes.count)
            let result = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.sourceHintBytesRead, Int64(bytes.count))
            XCTAssertEqual(result.acknowledgedHQ, 0)
            XCTAssertEqual(result.acknowledgedM1, 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(try f.catalog.capture(captureID: intent.captureID)?.source, hasModel ? "minimax" : "claude-code")
            var terminated = bytes
            terminated.append(0x0A)
            try terminated.write(to: f.source)
            try f.markDirty()
            budget.maxCaptureBytes = Int64(terminated.count)
            let completed = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(completed.captured, 1)
            XCTAssertEqual(completed.acknowledgedHQ, 1)
            XCTAssertEqual(completed.acknowledgedM1, 1)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 2)
            await replicas.stop()
        }
    }

    private func derivedClaudeBytes(model: String, cwd: String, text: String) throws -> Data {
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": "shared-native", "cwd": cwd, "timestamp": "2026-09-09T00:00:00Z",
             "message": ["role": "user", "content": text]],
            ["type": "assistant", "sessionId": "shared-native", "cwd": cwd, "timestamp": "2026-09-09T00:00:01Z",
             "message": ["role": "assistant", "model": model,
                "content": [["type": "text", "text": "Native reply"]], "usage": ["input_tokens": 7, "output_tokens": 3]]],
        ]
        var bytes = Data()
        for record in records {
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            bytes.append(0x0A)
        }
        return bytes
    }

    func testClineSourceDisappearingAfterReservationDefersWithoutAcknowledgment() async throws {
        let f = try PublicationFixture(sourceName: .cline)
        let replicas = try await replicas(for: f)
        let bytes = try Data(contentsOf: f.source)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            try FileManager.default.removeItem(at: f.source)
        })
        let missing = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(missing.captured, 0)
        XCTAssertGreaterThan(missing.deferred, 0)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        try bytes.write(to: f.source)
        try f.reopenOwnerAndCatalog()
        var captures = 0, hq = 0, m1 = 0
        for now: Int64 in 200...204 {
            let resumed = try await f.worker(replicas.endpoints).runOnce(now: now)
            captures += resumed.captured; hq += resumed.acknowledgedHQ; m1 += resumed.acknowledgedM1
        }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(hq, 1)
        XCTAssertEqual(m1, 1)
        await replicas.stop()
    }

    func testClinePrimaryClaimRejectsAnotherTaskAndDoesNotStealClaimedPrimary() async throws {
        let f = try PublicationFixture(sourceName: .cline)
        let replicas = try await replicas(for: f)
        let alias = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 100).first)
        let other = f.sourceRoot.appendingPathComponent("other-task")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try f.transcript().write(to: other.appendingPathComponent("ui_messages.json"))
        let wrong = try EngramCollectorCore.CollectorClineSource.observe(rootPath: f.sourceRoot.path,
            primaryRelative: "other-task/ui_messages.json")
        XCTAssertThrowsError(try f.owner.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: wrong.snapshot))
        try f.transcript().write(to: f.source.deletingLastPathComponent().appendingPathComponent("ui_messages.json"))
        let correct = try EngramCollectorCore.CollectorClineSource.observe(rootPath: f.sourceRoot.path,
            primaryRelative: "task-native/ui_messages.json")
        let primary = try XCTUnwrap(f.owner.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: correct.snapshot))
        XCTAssertEqual(primary.relativePath, "task-native/ui_messages.json")
        XCTAssertNil(try f.owner.claimFileSetPrimary(alias, configuration: f.configuration, snapshot: correct.snapshot))
        XCTAssertNil(try f.owner.claimClinePendingAlias(primary, configuration: f.configuration))
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        await replicas.stop()
    }

    func testClineOnlyDirtyLegacyCapturesUIUnderOneFileBudgetAndStaysSettledAfterRestart() async throws {
        let f = try PublicationFixture(sourceName: .cline)
        let replicas = try await replicas(for: f)
        let ui = f.source.deletingLastPathComponent().appendingPathComponent("ui_messages.json")
        try f.transcript(text: "preferred UI").write(to: ui)
        let worker = try f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1))
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
        let cycle = try await worker.runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let manifest = try JSONDecoder().decode(EngramCollectorCore.ArchiveSourceManifest.self,
            from: f.cas.readManifest(sha256: intent.publication.manifestSHA256))
        XCTAssertEqual(manifest.locator, ui.path)
        XCTAssertEqual(manifest.replayLayout.absentRelativePaths, [])
        try f.reopenOwnerAndCatalog()
        let settled = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: 200)
        XCTAssertEqual(settled.captured, 0)
        XCTAssertEqual(settled.recovered, 0)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
        await replicas.stop()
    }

    func testClinePreferredUICaptureFailureDoesNotAcknowledgeLegacyAndCanRetry() async throws {
        let f = try PublicationFixture(sourceName: .cline)
        let replicas = try await replicas(for: f)
        try f.transcript(text: "preferred UI").write(to: f.source.deletingLastPathComponent().appendingPathComponent("ui_messages.json"))
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw EngramCollectorCore.ExactSourceCapturerError.generationChanged
        })
        let failed = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1), hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(failed.captured, 0)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        try f.reopenOwnerAndCatalog()
        for tick in 200...204 { _ = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: Int64(tick)) }
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        XCTAssertFalse(try f.owner.publicationIntents(limit: 8).isEmpty)
        await replicas.stop()
    }

    func testClineUnpublishedCASRecoversAfterTaskRemoval() async throws {
        let f = try PublicationFixture(sourceName: .cline)
        let replicas = try await replicas(for: f)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in throw PublicationFixture.Failure.injected })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("Expected crash after CAS persistence")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        try FileManager.default.removeItem(at: f.source.deletingLastPathComponent())
        try f.reopenOwnerAndCatalog()
        let recovered = try await f.worker(replicas.endpoints).runOnce(now: 200)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(intent.publication.sequence, reserved.sequence)
        XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
        await replicas.stop()
    }

    func testKimiDurableUnpublishedReservationRecoversWithoutPrimaryAndRegistry() async throws {
        let f = try PublicationFixture(sourceName: .kimi)
        let replicas = try await replicas(for: f)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: f.kimiRegistry)
        try f.reopen()
        let recovered = try await f.worker(replicas.endpoints).runOnce(now: 200)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(published.publication.sequence, reserved.sequence)
        XCTAssertEqual(published.publication.collectorEpoch, reserved.collectorEpoch)
        await replicas.stop()
    }

    func testKimiUncapturedReservationDoesNotBlockAfterPrimaryOrRegistryRemoval() async throws {
        for missingRegistry in [false, true] {
            let f = try PublicationFixture(sourceName: .kimi)
            let replicas = try await replicas(for: f)
            let observed = try EngramCollectorCore.CollectorKimiSource.observe(rootPath: f.sourceRoot.path,
                primaryRelative: f.sourceRelativePath, registryLocator: f.kimiRegistry.path)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 100).first)
            let reserved = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: observed.generation, snapshot: observed.snapshot))
            let removed = missingRegistry ? f.kimiRegistry : f.source
            let bytes = try Data(contentsOf: removed)
            try FileManager.default.removeItem(at: removed)
            try f.reopen()
            let cycle = try await f.worker(replicas.endpoints).runOnce(now: 200)
            XCTAssertEqual(cycle.deferred, 1)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
            try bytes.write(to: removed)
            let resumed = try await f.worker(replicas.endpoints).runOnce(now: 300)
            XCTAssertEqual(resumed.captured, 1)
            XCTAssertEqual(resumed.acknowledgedHQ, 1)
            XCTAssertEqual(resumed.acknowledgedM1, 1)
            let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertGreaterThan(published.publication.sequence, reserved.sequence)
            await replicas.stop()
        }
    }

    func testCursorUncapturedReservationDoesNotBlockAfterPrimaryRemoval() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        let observed = try EngramCollectorCore.CollectorCursorSource.observe(
            rootPath: f.sourceRoot.path, primaryRelative: f.sourceRelativePath)
        let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 100).first)
        let reserved = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
            generation: observed.generation, snapshot: observed.snapshot))
        let bytes = try Data(contentsOf: f.source)
        try FileManager.default.removeItem(at: f.source)
        try f.reopenOwnerAndCatalog()
        let cycle = try await f.worker(replicas.endpoints).runOnce(now: 200)
        XCTAssertEqual(cycle.deferred, 1)
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.recovered, 0)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
        try bytes.write(to: f.source)
        XCTAssertEqual(chmod(f.source.path, 0o600), 0)
        let resumed = try await f.worker(replicas.endpoints).runOnce(now: 300)
        XCTAssertEqual(resumed.captured, 1)
        XCTAssertEqual(resumed.acknowledgedHQ, 1)
        XCTAssertEqual(resumed.acknowledgedM1, 1)
        let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertGreaterThan(published.publication.sequence, reserved.sequence)
        await replicas.stop()
    }

    func testCursorDurableUnpublishedReservationRecoversWithoutPrimary() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertFalse(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        try FileManager.default.removeItem(at: f.source)
        try f.reopenOwnerAndCatalog()
        let recovered = try await f.worker(replicas.endpoints).runOnce(now: 200)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(published.publication.sequence, reserved.sequence)
        XCTAssertEqual(published.publication.collectorEpoch, reserved.collectorEpoch)
        await replicas.stop()
    }

    func testCursorModernStaleSnapshotMissingRootDoesNotBlockSavedCASRecovery() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertFalse(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        let staleSnapshot: Set<Data> = [Data(f.configuration.rootID.utf8)]
        try FileManager.default.removeItem(at: f.sourceRoot)
        let recovered = try await f.worker(replicas.endpoints).runOnce(now: 200, captureRootIDs: staleSnapshot)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
        let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(published.publication.sequence, reserved.sequence)
        XCTAssertEqual(published.publication.collectorEpoch, reserved.collectorEpoch)
        await replicas.stop()
    }

    func testCursorStaleSnapshotRetainsUncapturedReservationUntilOriginalRootReturns() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        do {
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                throw PublicationFixture.Failure.injected
            })
            do {
                _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
                XCTFail("expected interruption before capture")
            } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
            let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
            let held = f.base.appendingPathComponent("held-original-root")
            try FileManager.default.moveItem(at: f.sourceRoot, to: held)
            let stale: Set<Data> = [Data(f.configuration.rootID.utf8)]
            let deferred = try await f.worker(replicas.endpoints).runOnce(now: 200, captureRootIDs: stale)
            XCTAssertEqual(deferred.captured, 0)
            XCTAssertEqual(deferred.recovered, 0)
            XCTAssertGreaterThan(deferred.deferred, 0)
            XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            try FileManager.default.moveItem(at: held, to: f.sourceRoot)
            let resumed = try await f.worker(replicas.endpoints).runOnce(now: 300, captureRootIDs: stale)
            XCTAssertEqual(resumed.captured, 1)
            XCTAssertEqual(resumed.acknowledgedHQ, 1)
            XCTAssertEqual(resumed.acknowledgedM1, 1)
            let published = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(published.publication.sequence, reserved.sequence)
            XCTAssertEqual(published.publication.collectorEpoch, reserved.collectorEpoch)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testUnavailableSourceProbeAndWorkerDoNotMaskMissingInventory() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        do {
            let originalInventory = f.inventory.deletingLastPathComponent()
            let held = f.base.appendingPathComponent("held-inventory")
            try FileManager.default.moveItem(at: originalInventory, to: held)
            defer { try? FileManager.default.moveItem(at: held, to: originalInventory) }
            try FileManager.default.removeItem(at: f.sourceRoot)
            XCTAssertThrowsError(try f.owner.sourceRootIsUnavailable(f.configuration))
            do {
                _ = try await f.worker(replicas.endpoints).runOnce(now: 200,
                    captureRootIDs: [Data(f.configuration.rootID.utf8)])
                XCTFail("missing owned inventory must propagate, never become source deferral")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: originalInventory.path))
            }
            let hq = try await replicas.hq.publications(), m1 = try await replicas.m1.publications()
            XCTAssertTrue(hq.isEmpty); XCTAssertTrue(m1.isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testDiskAdmissionRecordsIndependentVolumePressureAndResetsEachCycle() async throws {
        for recovering in [false, true] {
            for inventoryPressure in [false, true] {
                let override = PublicationLocked<Int64?>(nil)
                let samples = PublicationLocked<[Int64]>([])
                let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, measured in
                    let value = override.value ?? measured
                    samples.change { $0.append(value) }
                    return value
                }))
                let replicas = try await replicas(for: f)
                if recovering {
                    let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                        throw PublicationFixture.Failure.injected
                    })
                    do {
                        _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 99)
                        XCTFail("the uncaptured reservation must be established by the real worker")
                    } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
                    XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
                    XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
                }
                samples.change { $0.removeAll() }
                override.change { $0 = 0 }
                var budget = EngramCollectorCore.CollectorPublicationBudget()
                budget.minimumFreeDiskBytes = inventoryPressure ? Int64.max : 1
                let worker = try f.worker(replicas.endpoints, budget: budget)
                let blocked = try await worker.runOnce(now: 100)
                assertDiskObservation(blocked.diskAdmission, threshold: budget.minimumFreeDiskBytes,
                    captureMinimum: inventoryPressure ? nil : 0, inventoryBelowThreshold: inventoryPressure)
                XCTAssertEqual(samples.value, inventoryPressure ? [] : [0], "preserve inventory-before-CAS short circuit")
                XCTAssertEqual(blocked.captured, 0)
                XCTAssertGreaterThan(blocked.deferred, 0)
                XCTAssertEqual(blocked.acknowledgedHQ + blocked.acknowledgedM1, 0)
                XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
                XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
                XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
                if !inventoryPressure {
                    override.change { $0 = 4096 }
                    let resumed = try await worker.runOnce(now: 101)
                    assertDiskObservation(resumed.diskAdmission, threshold: 1, captureMinimum: 4096)
                    XCTAssertEqual(resumed.captured, 1)
                    XCTAssertEqual(resumed.acknowledgedHQ, 1)
                    XCTAssertEqual(resumed.acknowledgedM1, 1)
                    let idle = try await worker.runOnce(now: 102)
                    XCTAssertEqual(idle.diskAdmission, .notEvaluated,
                        "an idle pass must not advertise the previous pass's observation")
                }
                await replicas.stop()
            }
        }

        // One low admission followed by a successful admission in the same
        // cycle must preserve the actual minimum, not the last observation.
        let samples = PublicationLocked<[Int64]>([])
        let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
            var value: Int64 = 4096
            samples.change { recorded in
                if recorded.isEmpty { value = 0 }
                recorded.append(value)
            }
            return value
        }))
        let replicas = try await replicas(for: f)
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "another bounded candidate").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.minimumFreeDiskBytes = 1
        budget.maxCaptureFiles = 2
        let worker = try f.worker(replicas.endpoints, budget: budget)
        let mixed = try await worker.runOnce(now: 100)
        XCTAssertEqual(samples.value, [0, 4096], "status must not add an extra volume probe")
        assertDiskObservation(mixed.diskAdmission, threshold: 1, captureMinimum: 0)
        XCTAssertEqual(mixed.captured, 1)
        XCTAssertEqual(mixed.acknowledgedHQ, 1)
        XCTAssertEqual(mixed.acknowledgedM1, 1)
        let resumed = try await worker.runOnce(now: 101)
        assertDiskObservation(resumed.diskAdmission, threshold: 1, captureMinimum: 4096)
        XCTAssertEqual(resumed.captured, 1)
        XCTAssertEqual(resumed.acknowledgedHQ, 1)
        XCTAssertEqual(resumed.acknowledgedM1, 1)
        await replicas.stop()
    }

    func testCaptureFileAndByteBudgetShortCircuitsDoNotInventDiskObservations() async throws {
        for fileBudget in [false, true] {
            let probes = PublicationLocked(0)
            let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
                probes.change { $0 += 1 }
                return 0
            }))
            let replicas = try await replicas(for: f)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.minimumFreeDiskBytes = 1
            if fileBudget { budget.maxCaptureFiles = 0 }
            else { budget.maxCaptureBytes = 1 }
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(cycle.diskAdmission, .notEvaluated)
            XCTAssertEqual(probes.value, 0)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.deferred, fileBudget ? 0 : 1,
                "neither a zero nor a nonzero deferred count identifies disk pressure")
            XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testPrivacyAndTransportDeferralsRemainIndependentOfDiskAdmission() async throws {
        for privacyWithheld in [false, true] {
            let probes = PublicationLocked(0)
            let f = try PublicationFixture(casTestHooks: .init(afterVolumeStat: { _, _ in
                probes.change { $0 += 1 }
                return 4096
            }))
            let replicas = try await replicas(for: f)
            var endpoints = replicas.endpoints
            if privacyWithheld {
                f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) }
            } else {
                endpoints[0] = .init(replicaID: "hq", baseURL: endpoints[0].baseURL,
                    bearerToken: "synthetic-wrong-hq-token")
            }
            let requests = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in
                requests.change { $0 += 1 }
            })
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.minimumFreeDiskBytes = 1
            let worker = try f.worker(endpoints, budget: budget, hooks: hooks)
            let captured = try await worker.runOnce(now: 100)
            assertDiskObservation(captured.diskAdmission, threshold: 1, captureMinimum: 4096)
            XCTAssertEqual(captured.captured, 1)
            XCTAssertGreaterThan(captured.deferred, 0)
            XCTAssertEqual(captured.acknowledgedHQ, 0)
            XCTAssertEqual(captured.acknowledgedM1, privacyWithheld ? 0 : 1)
            if privacyWithheld { XCTAssertEqual(requests.value, 0) }
            else { XCTAssertGreaterThan(requests.value, 0) }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND last_error = '\(privacyWithheld ? "privacyWithheld" : "unavailable")'"), 1)
            let backlogOnly = try await worker.runOnce(now: 200_000)
            XCTAssertEqual(backlogOnly.diskAdmission, .notEvaluated,
                "upload-only deferrals must not reuse an old successful disk sample")
            XCTAssertEqual(backlogOnly.captured, 0)
            XCTAssertGreaterThan(backlogOnly.deferred, 0)
            XCTAssertEqual(probes.value, 1, "upload retries must not introduce capture-admission probes")
            if privacyWithheld { XCTAssertEqual(requests.value, 0) }
            await replicas.stop()
        }
    }

    private func assertDiskObservation(
        _ status: EngramCollectorCore.CollectorDiskAdmissionStatus,
        threshold: Int64, captureMinimum: Int64?, inventoryBelowThreshold: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .observed(let actualThreshold, let inventory, let capture) = status else {
            XCTFail("expected this cycle's actual disk-admission observation", file: file, line: line)
            return
        }
        XCTAssertEqual(actualThreshold, threshold, file: file, line: line)
        guard let inventory else {
            XCTFail("inventory must be sampled before CAS", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(inventory, 0, file: file, line: line)
        if inventoryBelowThreshold { XCTAssertLessThan(inventory, threshold, file: file, line: line) }
        else { XCTAssertGreaterThanOrEqual(inventory, threshold, file: file, line: line) }
        XCTAssertEqual(capture, captureMinimum, file: file, line: line)
    }

    func testReservationEpochSequenceAndCanonicalIntentSurviveOwnerRestart() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        let reserved = prepared.reservation
        XCTAssertEqual(reserved.sequence, 1)
        XCTAssertNotNil(UUID(uuidString: reserved.sourceInstanceID))
        XCTAssertNotNil(UUID(uuidString: reserved.collectorEpoch))
        try f.reopen()
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
        let intent = try XCTUnwrap(f.owner.finishCapture(reserved, configuration: f.configuration, capture: prepared.capture.capture))
        XCTAssertEqual(intent.publication.sequence, reserved.sequence)
        XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
        XCTAssertEqual(intent.publication.sourceInstanceID, reserved.sourceInstanceID)
        XCTAssertEqual(intent.canonicalBytes, try Canonical.encode(intent.publication))
        XCTAssertEqual(intent.digest, try intent.publication.sha256())
        XCTAssertNil(prepared.capture.manifest.sessionID)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        try f.reopen()
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        XCTAssertTrue(try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 2).isEmpty)
    }

    func testFinishTransactionFailureLeavesReservationAndNoHalfQueueOrDirtyACK() throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        probe.action = { throw PublicationFixture.Failure.injected }
        XCTAssertThrowsError(try f.finish(prepared)) { XCTAssertEqual($0 as? PublicationFixture.Failure, .injected) }
        probe.action = nil
        XCTAssertEqual(try f.inventoryDigest(), before)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 1)
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        _ = try f.finish(prepared)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
    }

    func testDuplicateCapturedGenerationReusesPublicationAndNewGenerationAdvancesSameStream() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let first = try f.finish(f.prepare())
        try f.markDirty()
        let duplicate = try f.finish(f.prepare(markDirty: false))
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        try f.writeTranscript(text: "second-generation-is-longer")
        try f.markDirty()
        let next = try f.finish(f.prepare(markDirty: false))
        XCTAssertGreaterThan(next.publication.sequence, first.publication.sequence)
        XCTAssertEqual(next.publication.collectorEpoch, first.publication.collectorEpoch)
        XCTAssertEqual(next.publication.sourceInstanceID, first.publication.sourceInstanceID)
        XCTAssertNotEqual(next.digest, first.digest)
    }

    func testWrongAndMalformedACKsNeverMutateReplicaState() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let intent = try f.finish(f.prepare())
        let claim = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 10).first)
        let before = try f.inventoryDigest()
        for bytes in [
            try f.ack(intent, server: "m1"),
            try f.ack(intent, publicationDigest: String(repeating: "a", count: 64)),
            try f.ack(intent, manifestDigest: String(repeating: "b", count: 64)),
            Data("{\"schemaVersion\":1}".utf8),
            Data(repeating: 65, count: 4_097),
        ] {
            XCTAssertThrowsError(try f.owner.recordPublicationACK(claim, canonicalBytes: bytes))
            XCTAssertEqual(try f.inventoryDigest(), before)
        }
        XCTAssertTrue(try f.owner.recordPublicationACK(claim, canonicalBytes: f.ack(intent)))
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 1)
        XCTAssertFalse(try f.owner.recordPublicationACK(claim, canonicalBytes: f.ack(intent)))
        try f.assertNoLegacyAuthority()
    }

    func testNewOwnerReclaimsInflightAndRejectsOldLateACKAndDeferral() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let intent = try f.finish(f.prepare())
        let old = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 10).first)
        try f.reopen()
        let current = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: 11).first)
        XCTAssertNotEqual(current.ownerRunID, old.ownerRunID)
        XCTAssertGreaterThan(current.claimGeneration, old.claimGeneration)
        let before = try f.inventoryDigest()
        XCTAssertFalse(try f.owner.recordPublicationACK(old, canonicalBytes: f.ack(intent)))
        XCTAssertFalse(try f.owner.deferPublication(old, now: 11, reason: .unavailable))
        XCTAssertEqual(try f.inventoryDigest(), before)
        XCTAssertTrue(try f.owner.recordPublicationACK(current, canonicalBytes: f.ack(intent)))
    }

    func testRetryIsReplicaIndependentBoundedAndNotClaimedBeforeDeadline() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        var now: Int64 = 10
        for _ in 0..<22 {
            let claim = try XCTUnwrap(f.owner.claimPublications(replicaID: "hq", limit: 1, now: now).first)
            XCTAssertTrue(try f.owner.deferPublication(claim, now: now, reason: .unavailable))
            let deadline = try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'hq'")
            XCTAssertGreaterThan(deadline, now)
            XCTAssertLessThanOrEqual(deadline - now, 86_400)
            XCTAssertTrue(try f.owner.claimPublications(replicaID: "hq", limit: 1, now: deadline - 1).isEmpty)
            now = deadline
        }
        let m1 = try XCTUnwrap(f.owner.claimPublications(replicaID: "m1", limit: 1, now: 10).first)
        XCTAssertEqual(m1.attempts, 0)
        XCTAssertEqual(try f.integer("SELECT attempts FROM collector_publication_replicas WHERE replica_id = 'hq'"), 22)
    }

    func testPublicationInputBoundsFailBeforeAnyMutation() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        let before = try f.inventoryDigest()
        for count in [-1, 0, 65] {
            XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "hq", limit: count, now: 1))
            XCTAssertThrowsError(try f.owner.publicationIntents(limit: count))
            XCTAssertThrowsError(try f.owner.captureReservations(limit: count))
        }
        XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "other", limit: 1, now: 1))
        XCTAssertThrowsError(try f.owner.claimPublications(replicaID: "hq", limit: 1, now: -1))
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testSequenceOverflowFailsClosedWithoutChangingEpochOrAcknowledgingDirtyWork() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        _ = try f.finish(f.prepare())
        try f.writeTranscript(text: "next-generation-after-sequence-exhaustion")
        try f.markDirty()
        let captured = try f.capture()
        let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 2).first)
        try f.mutate("UPDATE collector_streams SET last_sequence = 9223372036854775807")
        let before = try f.inventoryDigest()
        XCTAssertThrowsError(try f.owner.reserveCapture(claim, configuration: f.configuration, generation: captured.manifest.generation)) {
            XCTAssertEqual($0 as? WorkerError, .sequenceExhausted)
        }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testCancellationInsideFinishCommitRollsBackInsteadOfAcknowledgingCapture() async throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        let task = Task {
            try withUnsafeCurrentTask { borrowed in
                probe.action = { borrowed?.cancel() }
                defer { probe.action = nil }
                return try f.finish(prepared)
            }
        }
        do { _ = try await task.value; XCTFail("cancelled transaction committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testStorageReplacementInFinishCommitRollsBackOriginalInventory() throws {
        let probe = PublicationProbe()
        let f = try PublicationFixture(probe: probe)
        defer { f.remove() }
        let prepared = try f.prepare()
        let before = try f.inventoryDigest()
        let lock = f.shadow.appendingPathComponent("collector-owner.lock")
        let saved = f.base.appendingPathComponent("saved-owner-lock")
        var moved = false
        probe.action = {
            try FileManager.default.moveItem(at: lock, to: saved)
            moved = true
            try Data().write(to: lock)
            XCTAssertEqual(chmod(lock.path, 0o600), 0)
        }
        XCTAssertThrowsError(try f.finish(prepared)) {
            XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .unsafePath)
        }
        probe.action = nil
        XCTAssertTrue(moved, "the injected filesystem boundary must actually execute")
        if moved {
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.moveItem(at: saved, to: lock)
        }
        XCTAssertEqual(try f.inventoryDigest(), before)
    }

    func testClosedOwnerRejectsAllPublicationOperations() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        try f.owner.close()
        for operation in [
            { _ = try f.owner.captureReservations(limit: 1) },
            { _ = try f.owner.publicationIntents(limit: 1) },
            { _ = try f.owner.claimPublications(replicaID: "hq", limit: 1, now: 1) },
            { _ = try f.finish(prepared) },
        ] {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .closed) }
        }
    }

    func testRealTwoHTTPReplicasAcceptExactBytesAndIndependentDurableACKs() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let before = try Data(contentsOf: f.source)
        let worker = try f.worker(replicas.endpoints)
        let cycle = try await worker.runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        for replica in replicas.all {
            let records = try await replica.publications()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?["publicationSHA256"] as? String, intent.digest)
            let manifest = try await replica.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            XCTAssertEqual(manifest.0, capture.unboundManifestBytes)
            let decoded = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: manifest.0)
            var restored = Data()
            for chunk in decoded.chunks {
                let object = try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)")
                XCTAssertEqual(object.1, 200)
                restored.append(object.0)
            }
            XCTAssertEqual(restored, before)
        }
        XCTAssertEqual(try Data(contentsOf: f.source), before)
        try f.assertNoLegacyAuthority()
        try f.reopen()
        let resumed = try f.worker(replicas.endpoints)
        let resumedCycle = try await resumed.runOnce(now: 101)
        XCTAssertEqual(resumedCycle, .init())
        await replicas.stop()
    }

    func testHQFailureDoesNotBlockM1AndRestartRetriesOnlyHQ() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var endpoints = replicas.endpoints
        endpoints[0] = .init(replicaID: "hq", baseURL: endpoints[0].baseURL, bearerToken: "synthetic-wrong-hq-token")
        let first = try await f.worker(endpoints).runOnce(now: 100)
        XCTAssertEqual(first.acknowledgedHQ, 0)
        XCTAssertEqual(first.acknowledgedM1, 1)
        let firstM1 = try await replicas.m1.publications()
        let firstHQ = try await replicas.hq.publications()
        XCTAssertEqual(firstM1.count, 1)
        XCTAssertEqual(firstHQ.count, 0)
        try f.reopen()
        let requests = PublicationLocked<[String]>([])
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in requests.change { $0.append(id + path) } })
        let second = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200_000)
        XCTAssertEqual(second.acknowledgedHQ, 1)
        XCTAssertEqual(second.acknowledgedM1, 0)
        XCTAssertFalse(requests.value.contains { $0.hasPrefix("m1") })
        await replicas.stop()
    }

    func testLostPublicationResponseRetriesIdenticalCanonicalIntentWithoutNewJournalEntry() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let dropped = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterResponse: { id, path, bytes in
            if id == "hq", path.hasPrefix("/v2/archive/publications/") {
                dropped.change { $0 = true }
                throw WorkerError.transport
            }
            return bytes
        })
        let first = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertTrue(dropped.value, "drop occurs after the real server committed")
        XCTAssertEqual(first.acknowledgedHQ, 0)
        XCTAssertEqual(first.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let accepted = try await replicas.hq.publications()
        XCTAssertEqual(accepted.count, 1)
        let ordinal = accepted.first?["arrivalOrdinal"] as? Int
        try f.reopen()
        _ = try await f.worker(replicas.endpoints).runOnce(now: 200_000)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        let retried = try await replicas.hq.publications()
        XCTAssertEqual(retried.count, 1)
        XCTAssertEqual(retried.first?["arrivalOrdinal"] as? Int, ordinal)
        XCTAssertEqual(retried.first?["publicationSHA256"] as? String, intent.digest)
        await replicas.stop()
    }

    func testTamperedActualHTTPACKNeverMarksHQSuccessful() async throws {
        for field in ["serverID", "publicationSHA256", "manifestSHA256", "malformed"] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            let tampered = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterResponse: { id, path, bytes in
                guard id == "hq", path.hasPrefix("/v2/archive/publications/") else { return bytes }
                tampered.change { $0 = true }
                if field == "malformed" { return Data("not-json".utf8) }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                object[field] = field == "serverID" ? "m1" : String(repeating: "f", count: 64)
                return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            })
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(tampered.value)
            XCTAssertEqual(cycle.acknowledgedHQ, 0)
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), 0)
            await replicas.stop()
        }
    }

    func testActualHTTPResponseBudgetIsEnforced() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxResponseBytes = 32
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
        await replicas.stop()
    }

    func testDelayedReplicaPUTsFailAtThirtyAndAcknowledgeAtOneEighty_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let hqProxy = try await PublicationDelayedArchiveProxy.start(
            forwarding: replicas.hq, delayedPathPrefix: "/v2/archive/manifests/")
        let m1Proxy = try await PublicationDelayedArchiveProxy.start(
            forwarding: replicas.m1, delayedPathPrefix: "/v2/archive/publications/")
        addTeardownBlock {
            await hqProxy.stop()
            await m1Proxy.stop()
        }
        let endpoints = [
            EngramCollectorCore.CollectorReplicaEndpoint(
                replicaID: "hq", baseURL: hqProxy.baseURL, bearerToken: replicas.hq.token),
            EngramCollectorCore.CollectorReplicaEndpoint(
                replicaID: "m1", baseURL: m1Proxy.baseURL, bearerToken: replicas.m1.token),
        ]
        let started = Date()
        let cycle = try await f.worker(endpoints).runOnce(now: 100)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1, "HQ manifest PUT must survive a 35s first-response delay")
        XCTAssertEqual(cycle.acknowledgedM1, 1, "M1 publication PUT must survive a 35s first-response delay")
        XCTAssertGreaterThan(elapsed, 30)
        XCTAssertLessThan(elapsed, 70, "HQ and M1 delays must overlap instead of stacking")
        let hqRecords = try await replicas.hq.publications()
        let m1Records = try await replicas.m1.publications()
        XCTAssertEqual(hqRecords.count, 1)
        XCTAssertEqual(m1Records.count, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 2)
    }

    func testUnsupportedPublicationCapabilityRetainsHQBacklogWithoutLegacyFallback() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f, hqPublicationsEnabled: false)
        let paths = PublicationLocked<[String]>([])
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in if id == "hq" { paths.change { $0.append(path) } } })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        XCTAssertEqual(paths.value, ["/v2/archive/publication-capabilities"])
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state != 'acknowledged'"), 1)
        try f.assertNoLegacyAuthority()
        await replicas.stop()
    }

    func testExcludedUnknownAndAmbiguousCapturesAreRetainedWithZeroOutboundRequests() async throws {
        for variant in 0..<3 {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            if variant == 0 { f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) } }
            if variant == 1 { try f.writeBytes(Data("{\"type\":\"unrecognized\"}\n".utf8)) }
            if variant == 2 { try f.writeBytes(try f.transcript() + f.transcript(cwd: f.base.appendingPathComponent("other-project").path)) }
            let requests = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in requests.change { $0 += 1 } })
            let raw = try Data(contentsOf: f.source)
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 1)
            XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
            XCTAssertEqual(requests.value, 0)
            XCTAssertEqual(try Data(contentsOf: f.source), raw)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            let hqRecords = try await replicas.hq.publications()
            let m1Records = try await replicas.m1.publications()
            XCTAssertEqual(hqRecords.count, 0)
            XCTAssertEqual(m1Records.count, 0)
            await replicas.stop()
        }
    }

    func testClaudeMultiRootHQAckThenM1PrivacyWithholdOnNonFirstRootExclusion() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let second = f.base.appendingPathComponent("project-two")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = try f.transcript(text: "first-root", cwd: f.project.path)
            + (try f.transcript(text: "second-root", cwd: second.path))
        try f.writeBytes(original)
        try f.markDirty()
        let replicas = try await replicas(for: f)
        // Replica workers run concurrently. First defer M1 at authentication so
        // the later policy change occurs after a verified HQ ACK.
        var endpoints = replicas.endpoints
        endpoints[1] = .init(replicaID: "m1", baseURL: endpoints[1].baseURL, bearerToken: "synthetic-wrong-m1-token")
        let first = try await f.worker(endpoints).runOnce(now: 100)
        XCTAssertEqual(first.acknowledgedHQ, 1)
        XCTAssertEqual(first.acknowledgedM1, 0)
        let reached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, _ in
            if id == "m1", !reached.value {
                reached.change { $0 = true }
                f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [second.path]) }
            }
        })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200_000)
        XCTAssertTrue(reached.value)
        XCTAssertEqual(cycle.acknowledgedHQ, 0, "HQ was already acknowledged in the first cycle")
        XCTAssertEqual(cycle.acknowledgedM1, 0)
        let hqRecords = try await replicas.hq.publications()
        let m1Records = try await replicas.m1.publications()
        XCTAssertEqual(hqRecords.count, 1)
        XCTAssertEqual(m1Records.count, 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
        let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
        XCTAssertFalse(manifest.chunks.isEmpty)
        for chunk in manifest.chunks {
            let object = try await replicas.m1.get("/v2/archive/objects/\(chunk.rawSHA256)")
            XCTAssertEqual(object.1, 404)
        }
        XCTAssertEqual(try Data(contentsOf: f.source), original)
        await replicas.stop()
    }

    func testClaudeMultiRootObjectStageSymlinkAliasForcesAllRootsIsCurrentWithhold() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let second = f.base.appendingPathComponent("project-two")
        let excluded = f.base.appendingPathComponent("excluded-target")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        f.policy.change { $0 = try! .init(revision: 1, excludedProjectRoots: [excluded.path]) }
        try f.writeBytes(try f.transcript(text: "first-root", cwd: f.project.path)
            + (try f.transcript(text: "second-root", cwd: second.path)))
        try f.markDirty()
        let replicas = try await replicas(for: f)
        // Isolate HQ's cached proof from an independently authorized M1 request
        // that could otherwise precede the alias mutation.
        var endpoints = replicas.endpoints
        endpoints[1] = .init(replicaID: "m1", baseURL: endpoints[1].baseURL, bearerToken: "synthetic-wrong-m1-token")
        let reached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in
            if id == "hq", path.hasPrefix("/v2/archive/objects/"), !reached.value {
                reached.change { $0 = true }
                try FileManager.default.removeItem(at: second)
                try FileManager.default.createSymbolicLink(at: second, withDestinationURL: excluded)
            }
        })
        let cycle = try await f.worker(endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertTrue(reached.value)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertEqual(cycle.acknowledgedM1, 0)
        let hqRecords = try await replicas.hq.publications()
        let m1Records = try await replicas.m1.publications()
        XCTAssertEqual(hqRecords.count, 0)
        XCTAssertEqual(m1Records.count, 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
        let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
        XCTAssertFalse(manifest.chunks.isEmpty)
        for chunk in manifest.chunks {
            let hqObject = try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)")
            let m1Object = try await replicas.m1.get("/v2/archive/objects/\(chunk.rawSHA256)")
            XCTAssertEqual(hqObject.1, 404)
            XCTAssertEqual(m1Object.1, 404)
        }
        await replicas.stop()
    }

    func testPolicyIsRefreshedImmediatelyBeforeEveryHTTPStage() async throws {
        for blockedPrefix in ["/v2/archive/publication-capabilities", "/v2/archive/objects/", "/v2/archive/manifests/", "/v2/archive/publications/"] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            let reached = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { id, path in
                if id == "hq", path.hasPrefix(blockedPrefix) {
                    reached.change { $0 = true }
                    f.policy.change { $0 = try! .init(revision: 2, excludedProjectRoots: [f.project.path]) }
                }
            })
            let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(reached.value, blockedPrefix)
            XCTAssertEqual(cycle.acknowledgedHQ, 0)
            let hqRecords = try await replicas.hq.publications()
            XCTAssertEqual(hqRecords.count, 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            if blockedPrefix != "/v2/archive/publications/" {
                let manifest = try await replicas.hq.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
                XCTAssertEqual(manifest.1, 404)
            }
            if blockedPrefix == "/v2/archive/publication-capabilities" || blockedPrefix == "/v2/archive/objects/" {
                let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
                let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
                XCTAssertFalse(manifest.chunks.isEmpty, "the object-leak control needs actual captured bytes")
                for chunk in manifest.chunks {
                    let object = try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)")
                    XCTAssertEqual(object.1, 404, "privacy withdrawal must prevent the raw object PUT, not only its publication")
                }
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND last_error = 'privacyWithheld'"), 1)
            await replicas.stop()
        }
    }

    func testRetrySkipsExistingObjectPUTAfterSuccessfulHEAD_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        do {
            let first = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(first.captured, 1)
            XCTAssertEqual(first.acknowledgedHQ, 1)
            XCTAssertEqual(first.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            let manifest = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
            XCTAssertFalse(manifest.chunks.isEmpty)
            for chunk in manifest.chunks {
                let existing = try await replicas.m1.get("/v2/archive/objects/\(chunk.rawSHA256)")
                XCTAssertEqual(existing.1, 200)
            }
            try f.mutate("""
                UPDATE collector_publication_replicas SET state = 'pending', claim_owner_run_id = NULL,
                    claimed_at = NULL, ack_bytes = NULL, last_error = NULL, retry_not_before = NULL
                WHERE replica_id = 'm1'
                """)
            try f.reopenOwnerAndCatalog()
            let methods = PublicationLocked<[(String, String)]>([])
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeHTTP: { id, path, method in
                if id == "m1", path.hasPrefix("/v2/archive/objects/") {
                    methods.change { $0.append((method, path)) }
                }
            })
            let retry = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200)
            XCTAssertEqual(retry.acknowledgedM1, 1)
            let objectHeads = methods.value.filter { $0.0 == "HEAD" }
            let objectPuts = methods.value.filter { $0.0 == "PUT" }
            XCTAssertEqual(objectHeads.count, manifest.chunks.count)
            XCTAssertTrue(objectPuts.isEmpty, "HEAD 200 must skip the object PUT on retry")
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"
            ), 1)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testRetrySkipsExistingManifestPUTAfterSuccessfulHEAD_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        do {
            let first = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(first.captured, 1)
            XCTAssertEqual(first.acknowledgedHQ, 1)
            XCTAssertEqual(first.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let existing = try await replicas.m1.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
            XCTAssertEqual(existing.1, 200)
            try f.mutate("""
                UPDATE collector_publication_replicas SET state = 'pending', claim_owner_run_id = NULL,
                    claimed_at = NULL, ack_bytes = NULL, last_error = NULL, retry_not_before = NULL
                WHERE replica_id = 'm1'
                """)
            try f.reopenOwnerAndCatalog()
            let methods = PublicationLocked<[(String, String)]>([])
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeHTTP: { id, path, method in
                if id == "m1" { methods.change { $0.append((method, path)) } }
            })
            let retry = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200)
            XCTAssertEqual(retry.acknowledgedM1, 1)
            let manifestHeads = methods.value.filter { $0.0 == "HEAD" && $0.1.hasPrefix("/v2/archive/manifests/") }
            let manifestPuts = methods.value.filter { $0.0 == "PUT" && $0.1.hasPrefix("/v2/archive/manifests/") }
            let publicationPuts = methods.value.filter { $0.0 == "PUT" && $0.1.hasPrefix("/v2/archive/publications/") }
            XCTAssertEqual(manifestHeads.count, 1)
            XCTAssertTrue(manifestPuts.isEmpty, "HEAD 200 must skip the manifest PUT on retry")
            XCTAssertEqual(publicationPuts.count, 1, "publication PUT must still run after a skipped manifest")
            let replayed = try await replicas.m1.publications()
            XCTAssertEqual(replayed.count, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"
            ), 1)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testObjectHEADFailureDoesNotUploadOrAcknowledge() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        do {
            let first = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(first.acknowledgedM1, 1)
            try f.mutate("""
                UPDATE collector_publication_replicas SET state = 'pending', claim_owner_run_id = NULL,
                    claimed_at = NULL, ack_bytes = NULL, last_error = NULL, retry_not_before = NULL
                WHERE replica_id = 'm1'
                """)
            try f.reopenOwnerAndCatalog()
            let puts = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeHTTP: { id, path, method in
                if id == "m1", path.hasPrefix("/v2/archive/objects/") {
                    if method == "PUT" { puts.change { $0 += 1 } }
                    if method == "HEAD" { throw EngramCollectorCore.CollectorPublicationWorkerError.transport }
                }
            })
            let retry = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200)
            XCTAssertEqual(retry.acknowledgedM1, 0)
            XCTAssertEqual(puts.value, 0)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND last_error = 'unavailable'"
            ), 1)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testGeminiRegistryChangeDirtiesEveryKnownLocatorAcrossBoundedPasses() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        for index in 0..<64 {
            let relative = String(format: "project/chats/session-%03d.json", index)
            try f.transcript().write(to: f.sourceRoot.appendingPathComponent(relative))
            try f.markDirty(relativePath: relative)
        }
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let worker = try f.worker(replicas.endpoints, budget: budget)
        _ = try await worker.runOnce(now: 100)
        // Establish the clean baseline after any initial observer reconciliation.
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
        for now: Int64 in 101...104 { _ = try await worker.runOnce(now: now) }
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 65,
            "bounded registry reconciliation must eventually visit every known source")
    }

    func testSameTickGeminiRegistryDirtyIsCapturedAfterReconcile_repro() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        do {
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 0
            let worker = try f.worker(replicas.endpoints, budget: budget)
            _ = try await worker.captureOnce(now: 100)
            try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
            XCTAssertTrue(try f.owner.rootsWithUnacknowledgedDirty([f.configuration]).isEmpty)
            try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
            XCTAssertTrue(try f.owner.rootsWithUnacknowledgedDirty([f.configuration]).isEmpty,
                "registry file bytes alone must not dirty; pending work is created inside the next captureOnce")
            budget.maxCaptureFiles = 8
            let cycle = try await f.worker(replicas.endpoints, budget: budget).captureOnce(now: 101)
            XCTAssertGreaterThan(cycle.captured, 0, "registry reconcile in this captureOnce must still be claimable")
            await replicas.stop()
        } catch {
            await replicas.stop()
            throw error
        }
    }

    func testGeminiRegistryReconciliationResumesAfterRestartBetweenBoundedPages() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        for index in 0..<64 {
            let relative = String(format: "project/chats/session-%03d.json", index)
            try f.transcript().write(to: f.sourceRoot.appendingPathComponent(relative))
            try f.markDirty(relativePath: relative)
        }
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let worker = try f.worker(replicas.endpoints, budget: budget)
        for now: Int64 in 100...102 { _ = try await worker.runOnce(now: now) }
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
        _ = try await worker.runOnce(now: 103)
        let firstPage = try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision")
        XCTAssertGreaterThan(firstPage, 0)
        XCTAssertLessThanOrEqual(firstPage, 64, "one cycle must retain its bounded reconciliation budget")
        try f.reopen()
        _ = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 104)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 65,
            "the saved cursor must resume beyond page one after restart")
    }

    func testGeminiRegistryReappearanceDirtiesPreviouslyAcknowledgedSources() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        try FileManager.default.removeItem(at: f.geminiRegistry)
        let worker = try f.worker(replicas.endpoints, budget: budget)
        _ = try await worker.runOnce(now: 100)
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        try f.writeGeminiRegistry(cwd: f.project.path)
        _ = try await worker.runOnce(now: 101)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
    }

    func testGeminiRegistryLocatorChangeReconcilesPreviouslyAcknowledgedSources() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        _ = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        let alternate = f.base.appendingPathComponent("alternate-projects.json")
        try Data(contentsOf: f.geminiRegistry).write(to: alternate)
        let worker = try f.worker(replicas.endpoints,
            registryPaths: [f.configuration.rootID: alternate.path], budget: budget)
        _ = try await worker.runOnce(now: 101)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1,
            "a new registry locator changes provenance even if its selected cwd is identical")
    }

    func testGeminiRegistryChangeWhileWorkerStoppedIsNotForgotten() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        _ = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        try f.mutate("UPDATE collector_locators SET acknowledged_revision = dirty_revision")
        try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
        try f.reopen()
        _ = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 101)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
    }

    func testGeminiRegistryMutationBeforeCaptureCannotCommitStaleContext() async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        let replicas = try await replicas(for: f)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
        })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertEqual(cycle.acknowledgedM1, 0)
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
    }

    func testGeminiReservationRejectsMissingOrCorruptPersistedContextPair() async throws {
        for assignment in ["gemini_context_bytes = NULL", "gemini_context_sha256 = NULL",
                           "gemini_context_sha256 = '" + String(repeating: "0", count: 64) + "'"] {
            let f = try PublicationFixture(sourceName: .geminiCli)
            let replicas = try await replicas(for: f)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                throw PublicationFixture.Failure.injected
            })
            do {
                _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
                XCTFail("expected interruption after reservation")
            } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
            XCTAssertNotNil(try f.owner.captureReservations(limit: 8).first?.snapshot?.geminiProjectContext)
            try f.owner.close()
            try f.mutate("UPDATE collector_capture_reservations SET " + assignment)
            XCTAssertThrowsError(try {
                try f.reopen()
                _ = try f.owner.captureReservations(limit: 8)
            }())
        }
    }

    func testGeminiDurableRecoveryPreservesReservedRegistryContextAfterLiveChange() async throws {
        try await assertGeminiRegistryRecovery(changedAuthority: false)
    }

    func testGeminiNativeRootRecoveryDoesNotInventRegistryDependency() async throws {
        try await assertGeminiRegistryRecovery(changedAuthority: false, nativeRoot: true)
    }

    func testGeminiRegistryAuthorityChangeWithholdsWithoutDeletingDurableReservation() async throws {
        try await assertGeminiRegistryRecovery(changedAuthority: true)
    }

    private func assertGeminiRegistryRecovery(changedAuthority: Bool, nativeRoot: Bool = false) async throws {
        let f = try PublicationFixture(sourceName: .geminiCli)
        if nativeRoot {
            try Data(f.project.path.utf8).write(to: f.sourceRoot.appendingPathComponent("project/.project_root"))
        }
        let replicas = try await replicas(for: f)
        let captured = PublicationLocked<CaptureResult?>(nil)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { result in
            captured.change { $0 = result }
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
            XCTFail("expected interruption after durable capture")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let durable = try XCTUnwrap(captured.value)
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        XCTAssertEqual(reserved.snapshot?.geminiProjectContext?.cwd, nativeRoot ? nil : f.project.path)
        try f.writeGeminiRegistry(cwd: f.base.appendingPathComponent("changed-project").path)
        try f.markDirty()
        try f.reopen()
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        var paths: [String: String]? = nil
        if changedAuthority {
            let alternate = f.base.appendingPathComponent("alternate-projects.json")
            try Data(contentsOf: f.geminiRegistry).write(to: alternate)
            paths = [f.configuration.rootID: alternate.path]
        }
        let cycle = try await f.worker(replicas.endpoints, registryPaths: paths, budget: budget).runOnce(now: 200)
        XCTAssertEqual(cycle.recovered, changedAuthority ? 0 : 1)
        XCTAssertEqual(cycle.acknowledgedHQ, changedAuthority ? 0 : 1)
        XCTAssertEqual(cycle.acknowledgedM1, changedAuthority ? 0 : 1)
        XCTAssertEqual(try f.catalog.capture(captureID: durable.capture.captureID), durable.capture)
        if changedAuthority {
            XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        } else {
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).first?.captureID, durable.capture.captureID)
        }
    }

    func testPolicyChangeRequeuesLongWithheldCaptureAcrossRestartWithoutResettingTransportBackoff() async throws {
        let f = try PublicationFixture(sourceName: .opencode)
        let replicas = try await replicas(for: f)
        let excluded = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 1,
            excludedProjectRoots: [f.project.path], allowedSources: [.opencode])
        f.policy.change { $0 = excluded }
        let first = try await f.worker(replicas.endpoints).runOnce(now: 100)
        XCTAssertEqual(first.captured, 1)
        XCTAssertEqual(first.acknowledgedHQ + first.acknowledgedM1, 0)
        var now: Int64 = 101
        for iteration in 0..<17 {
            for replicaID in ["hq", "m1"] {
                let claim = try XCTUnwrap(f.owner.claimPublications(replicaID: replicaID, limit: 1, now: now).first)
                XCTAssertTrue(try f.owner.deferPublication(claim, now: now,
                    reason: replicaID == "hq" ? .privacyWithheld : .unavailable))
            }
            if iteration < 16 {
                now = try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'hq'")
            }
        }
        let deadline = try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'hq'")
        XCTAssertEqual(deadline - now, 86_400)
        try FileManager.default.removeItem(at: f.source)
        try f.reopen()
        let unchanged = try await f.worker(replicas.endpoints).runOnce(now: now + 1)
        XCTAssertEqual(unchanged.acknowledgedHQ + unchanged.acknowledgedM1, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'hq'"), deadline)
        let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(revision: 2,
            excludedProjectRoots: [], allowedSources: [.opencode])
        f.policy.change { $0 = allowed }
        try f.reopen()
        let changed = try await f.worker(replicas.endpoints).runOnce(now: now + 2)
        XCTAssertEqual(changed.acknowledgedHQ, 1, "fresh policy must not wait for yesterday's privacy deferral")
        XCTAssertEqual(changed.acknowledgedM1, 0, "transport retry deadlines must survive privacy changes")
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_publication_replicas WHERE replica_id = 'm1'"), deadline)
        await replicas.stop()
    }

    func testCursorLegacyComparisonReadsShareOneCycleBudgetAndResumeWithoutRepublishing() async throws {
        let reads = PublicationLocked<Int64>(0)
        let f = try PublicationFixture(casTestHooks: .init(afterBoundedReadChunk: { _, count in
            reads.change { $0 += Int64(count) }
        }), sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try f.writeCursorLegacyComposer("a")
            try f.writeCursorLegacyComposer("b")
            let ownership = try DatabaseQueue(path: f.workspaceStorage.appendingPathComponent("ws-owned/state.vscdb").path)
            try await ownership.write { db in
                let bytes = try JSONSerialization.data(withJSONObject: ["allComposers": [["composerId": "a"], ["composerId": "b"]]])
                try db.execute(sql: "UPDATE ItemTable SET value = ? WHERE key = 'composer.composerData'",
                    arguments: [String(decoding: bytes, as: UTF8.self)])
            }
            try ownership.close()
            let initial = try f.worker(replicas.endpoints)
            for now: Int64 in 100..<120 {
                _ = try await initial.runOnce(now: now)
                if try f.owner.publicationIntents(limit: 8).count == 2,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            let intents = try f.owner.publicationIntents(limit: 8)
            XCTAssertEqual(intents.count, 2)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
            var costs: [Int64] = []
            for intent in intents {
                let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
                costs.append(capture.rawByteCount + Int64(capture.unboundManifestBytes.count))
            }
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 4
            budget.maxCaptureBytes = try XCTUnwrap(costs.max())
            XCTAssertGreaterThan(costs.reduce(0, +), budget.maxCaptureBytes)
            // Revisit the same rows after an unrelated source change. Measure
            // actual CAS read chunks, not a counter maintained by the Worker.
            let unrelated = try DatabaseQueue(path: f.sourceRoot.appendingPathComponent("state.vscdb").path)
            try await unrelated.write { db in
                try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES ('unrelated-setting', 'pad')")
            }
            try unrelated.close()
            try f.markDirty(relativePath: "state.vscdb")
            let worker = try f.worker(replicas.endpoints, budget: budget)
            reads.change { $0 = 0 }
            let first = try await worker.runOnce(now: 200)
            XCTAssertLessThanOrEqual(reads.value, budget.maxCaptureBytes)
            XCTAssertGreaterThan(reads.value, 0)
            XCTAssertEqual(first.captured, 0)
            XCTAssertGreaterThan(first.deferred, 0)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 2)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 1)
            for now: Int64 in 201..<210 {
                reads.change { $0 = 0 }
                _ = try await worker.runOnce(now: now)
                XCTAssertLessThanOrEqual(reads.value, budget.maxCaptureBytes)
                if try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 2)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyOversizedPriorComparisonDoesNotStarveCurrentCapture() async throws {
        let oldManifest = PublicationLocked<String?>(nil)
        let oldReads = PublicationLocked(0)
        let f = try PublicationFixture(casTestHooks: .init(beforeBoundedReadAllocation: { url in
            if let hash = oldManifest.value, url.path.contains(hash) { oldReads.change { $0 += 1 } }
        }), sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try f.writeCursorLegacyComposer("owned")
            let initial = try f.worker(replicas.endpoints)
            for now: Int64 in 100..<110 {
                _ = try await initial.runOnce(now: now)
                if try f.owner.publicationIntents(limit: 8).count == 1,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            let original = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let capture = try XCTUnwrap(f.catalog.capture(captureID: original.captureID))
            oldManifest.change { $0 = capture.unboundManifestSHA256 }
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureBytes = capture.rawByteCount + 128
            XCTAssertLessThan(budget.maxCaptureBytes, capture.rawByteCount + Int64(capture.unboundManifestBytes.count))
            let unrelated = try DatabaseQueue(path: f.sourceRoot.appendingPathComponent("state.vscdb").path)
            try await unrelated.write { db in
                try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES ('unrelated-setting', 'pad')")
            }
            try unrelated.close()
            try f.markDirty(relativePath: "state.vscdb")
            let worker = try f.worker(replicas.endpoints, budget: budget)
            for now: Int64 in 200..<210 {
                _ = try await worker.runOnce(now: now)
                if try f.owner.publicationIntents(limit: 8).count == 2,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            XCTAssertEqual(oldReads.value, 0, "an over-budget optional comparison must not allocate its prior manifest")
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 2)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyCapturedReservationRecoversOriginalBytesToBothHTTPReplicas() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        do {
            // Seed the durable dirty work directly: event/discovery routing is
            // tested separately, while this case starts at reservation recovery.
            try f.mutate("""
                INSERT INTO collector_locators(root_id, root_revision, relative_path,
                    dirty_revision, acknowledged_revision, claim_generation)
                SELECT root_id, root_revision, 'state.vscdb', 1, 0, 0 FROM collector_roots
                """)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100)
                .first { $0.relativePath == "state.vscdb" })
            let generation = try EngramCollectorCore.ArchiveSourceGeneration(
                device: 1, inode: 2, size: 8192, mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
            let body = try EngramCollectorCore.ArchiveCursorLegacySession(
                logicalDatabaseLocator: f.sourceRoot.appendingPathComponent("state.vscdb").path,
                composerID: "owned:/%_", cwd: f.project.path, databaseGeneration: generation, walGeneration: nil,
                composer: .init(rowID: 1, key: "composerData:owned:/%_",
                    value: Data(#"{"composerId":"owned:/%_"}"#.utf8)), bubbles: [])
            let context = try EngramCollectorCore.ArchiveCursorLegacyContext(session: body)
            _ = try f.owner.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
                generation: generation, walGeneration: nil)
            let reserved = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: generation, cursorLegacySession: context))
            let durable = try EngramCollectorCore.ExactSourceCapturer.captureCursorLegacySession(
                body, machineID: PublicationFixture.machine, cas: f.cas, catalog: f.catalog)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            // Capture and reservation exist, but no live legacy database does.
            try f.reopenOwnerAndCatalog()
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 0
            let result = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(result.recovered, 1)
            XCTAssertEqual(result.captured, 0)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(intent.captureID, durable.capture.captureID)
            XCTAssertEqual(intent.publication.sequence, reserved.sequence)
            XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
            for server in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in durable.manifest.chunks {
                    let response = try await server.get("/v2/archive/objects/\(chunk.rawSHA256)")
                    XCTAssertEqual(response.1, 200)
                    restored.append(response.0)
                }
                XCTAssertEqual(restored, try body.encodeCanonical())
            }
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyObserverMissingRootDoesNotBlockSavedCASRecovery() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            // Seed the durable dirty work directly: event/discovery routing is
            // tested separately, while this case starts at reservation recovery.
            try f.mutate("""
                INSERT INTO collector_locators(root_id, root_revision, relative_path,
                    dirty_revision, acknowledged_revision, claim_generation)
                SELECT root_id, root_revision, 'state.vscdb', 1, 0, 0 FROM collector_roots
                """)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100)
                .first { $0.relativePath == "state.vscdb" })
            let generation = try EngramCollectorCore.ArchiveSourceGeneration(
                device: 1, inode: 2, size: 8192, mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
            let body = try EngramCollectorCore.ArchiveCursorLegacySession(
                logicalDatabaseLocator: f.sourceRoot.appendingPathComponent("state.vscdb").path,
                composerID: "owned:/%_", cwd: f.project.path, databaseGeneration: generation, walGeneration: nil,
                composer: .init(rowID: 1, key: "composerData:owned:/%_",
                    value: Data(#"{"composerId":"owned:/%_"}"#.utf8)), bubbles: [])
            let context = try EngramCollectorCore.ArchiveCursorLegacyContext(session: body)
            _ = try f.owner.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
                generation: generation, walGeneration: nil)
            let reserved = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: generation, cursorLegacySession: context))
            let durable = try EngramCollectorCore.ExactSourceCapturer.captureCursorLegacySession(
                body, machineID: PublicationFixture.machine, cas: f.cas, catalog: f.catalog)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            // Capture and reservation exist, but no live legacy database does.
            try f.reopenOwnerAndCatalog()
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 1
            try FileManager.default.removeItem(at: f.sourceRoot)
            let result = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(result.recovered, 1)
            XCTAssertEqual(result.captured, 0)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(intent.captureID, durable.capture.captureID)
            XCTAssertEqual(intent.publication.sequence, reserved.sequence)
            XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
            for server in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in durable.manifest.chunks {
                    let response = try await server.get("/v2/archive/objects/\(chunk.rawSHA256)")
                    XCTAssertEqual(response.1, 200)
                    restored.append(response.0)
                }
                XCTAssertEqual(restored, try body.encodeCanonical())
            }
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            let next = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 201)
            XCTAssertEqual(next.captured, 0)
            XCTAssertEqual(next.acknowledgedHQ, 0)
            XCTAssertEqual(next.acknowledgedM1, 0)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyWorkerRejectsMissingOrLegacyModernPeerBeforeWork() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            let legacy = EngramCollectorCore.CollectorRootConfiguration(rootID: "legacy", source: .cursor,
                rootPath: f.sourceRoot.path, revision: 1, cursorLegacy: true, cursorModernRootID: "peer")
            let peer = EngramCollectorCore.CollectorRootConfiguration(rootID: "peer", source: .cursor,
                rootPath: f.sourceRoot.path, revision: 1, cursorLegacy: true)
            for roots in [[legacy], [legacy, peer]] {
                XCTAssertThrowsError(try f.worker(replicas.endpoints, roots: roots)) {
                    XCTAssertEqual($0 as? EngramCollectorCore.CollectorPublicationWorkerError, .invalidConfiguration)
                }
            }
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyObservationSkipsUntilTenSecondCadence_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let states = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(
                beforePeerRootState: { states.change { $0 += 1 } })
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(states.value, 1)
            _ = try await worker.captureOnce(now: 109)
            XCTAssertEqual(states.value, 1, "repeated observation inside 10s must be skipped")
            _ = try await worker.captureOnce(now: 110)
            XCTAssertEqual(states.value, 2, "observation resumes at 10s")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyWorkspaceEditIsSeenAtNextAllowedObservationAndRollback() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            try f.writeCursorLegacyComposer("owned")
            let pair = try enrollPairedCursorLegacyPeer(f)
            let states = PublicationLocked(0)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(
                beforePeerRootState: { states.change { $0 += 1 } })
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(states.value, 1)
            let before = try f.text(
                "SELECT fingerprint FROM collector_cursor_legacy_workspaces WHERE workspace_id = 'ws-owned'")
            try f.mutateCursorLegacyOwnershipCwd(f.base.appendingPathComponent("edited-project").path)
            _ = try await worker.captureOnce(now: 109)
            XCTAssertEqual(states.value, 1, "workspace edit must wait for the next allowed observation")
            XCTAssertEqual(
                try f.text("SELECT fingerprint FROM collector_cursor_legacy_workspaces WHERE workspace_id = 'ws-owned'"),
                before)
            _ = try await worker.captureOnce(now: 110)
            XCTAssertEqual(states.value, 2)
            XCTAssertNotEqual(
                try f.text("SELECT fingerprint FROM collector_cursor_legacy_workspaces WHERE workspace_id = 'ws-owned'"),
                before)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(states.value, 3, "clock rollback must observe again")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyPeerFingerprintHintReusesUnchangedObservation_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let counts = DiscoverModernCounts()
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: counts.hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(counts.observations, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = '\(pair.legacy.rootID)' AND cursor_legacy_observer_error IS NOT NULL"), 0)
            _ = try await worker.captureOnce(now: 110)
            XCTAssertEqual(counts.observations, 1, "unchanged peer checkpoint inside 30s must not rescan")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyPeerFingerprintHintRefreshesOnCheckpointExpiryAndRollback() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let counts = DiscoverModernCounts()
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: counts.hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(counts.observations, 1)
            try f.markDirty(configuration: pair.modern, relativePath: "chats/ws/refresh/store.db")
            _ = try await worker.captureOnce(now: 110)
            XCTAssertEqual(counts.observations, 2, "event checkpoint change must rescan")
            _ = try await worker.captureOnce(now: 120)
            XCTAssertEqual(counts.observations, 2, "unchanged checkpoint stays cached")
            _ = try await worker.captureOnce(now: 140)
            XCTAssertEqual(counts.observations, 3, "TTL expiry must rescan")
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(counts.observations, 4, "clock rollback must rescan")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyNilPeerRootStateComputesFreshWithoutCaching() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f, inventoryModern: false)
            XCTAssertNil(try f.owner.rootState(rootID: pair.modern.rootID))
            let counts = DiscoverModernCounts()
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: counts.hooks)
            let live = Set([Data(pair.legacy.rootID.utf8)])
            _ = try await worker.captureOnce(now: 100, captureRootIDs: live)
            _ = try await worker.captureOnce(now: 110, captureRootIDs: live)
            XCTAssertEqual(counts.observations, 2)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = '\(pair.legacy.rootID)' AND cursor_legacy_observer_error IS NOT NULL"), 0)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyPeerRootStateErrorIsNotSourceObservationFailure() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(
                beforePeerRootState: { throw PublicationFixture.Failure.injected })
            do {
                _ = try await f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: hooks)
                    .captureOnce(now: 100)
                XCTFail("inventory rootState errors must propagate")
            } catch {
                XCTAssertEqual(error as? PublicationFixture.Failure, .injected)
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = '\(pair.legacy.rootID)' AND cursor_legacy_observer_error IS NOT NULL"), 0)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyUnavailableModernPeerFailsClosedWithoutEmptySetACK() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let counts = DiscoverModernCounts()
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: counts.hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(counts.observations, 1)
            let capturesAfterWarm = counts.captures
            try f.writeCursorLegacyComposer("owned")
            try FileManager.default.removeItem(at: URL(fileURLWithPath: pair.modern.rootPath))
            try f.markDirty(configuration: pair.legacy, relativePath: "state.vscdb")
            let insideTTL = try await worker.runOnce(now: 101)
            XCTAssertEqual(counts.observations, 1, "unchanged checkpoint keeps the observation hint")
            XCTAssertEqual(counts.captures, capturesAfterWarm + 1, "capture must still discover the missing peer")
            XCTAssertEqual(insideTTL.captured, 0)
            XCTAssertEqual(insideTTL.acknowledgedHQ, 0)
            XCTAssertEqual(insideTTL.acknowledgedM1, 0)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = '\(pair.legacy.rootID)' AND cursor_legacy_observer_error IS NOT NULL"), 0)
            XCTAssertEqual(
                try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'state.vscdb' AND dirty_revision > acknowledged_revision"),
                1)
            let expired = try await worker.runOnce(now: 130)
            XCTAssertEqual(counts.observations, 2)
            XCTAssertEqual(expired.captured, 0)
            XCTAssertEqual(expired.acknowledgedHQ, 0)
            XCTAssertEqual(expired.acknowledgedM1, 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = '\(pair.legacy.rootID)' AND cursor_legacy_observer_error IS NOT NULL"), 1)
            XCTAssertEqual(
                try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'state.vscdb' AND dirty_revision > acknowledged_revision"),
                1)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyModernConflictInsideHintTTLCannotAuthorizeCapture() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try writeEmptyCursorLegacyState(f)
            let pair = try enrollPairedCursorLegacyPeer(f)
            let counts = DiscoverModernCounts()
            let worker = try f.worker(replicas.endpoints, roots: [pair.legacy, pair.modern], hooks: counts.hooks)
            _ = try await worker.captureOnce(now: 100)
            XCTAssertEqual(counts.observations, 1)
            let capturesAfterWarm = counts.captures
            try f.writeCursorLegacyComposer("owned")
            try writeCursorStore(
                at: URL(fileURLWithPath: pair.modern.rootPath).appendingPathComponent("chats/ws/owned/store.db"),
                cwd: f.project.path, text: "modern twin")
            try f.markDirty(configuration: pair.legacy, relativePath: "state.vscdb")
            let cycle = try await worker.runOnce(now: 101)
            XCTAssertEqual(counts.observations, 1, "TTL hint must not skip capture-time discovery")
            XCTAssertEqual(counts.captures, capturesAfterWarm + 1)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.acknowledgedHQ, 0)
            XCTAssertEqual(cycle.acknowledgedM1, 0)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyUncapturedReservationRecapturesMatchingSource() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            let composerID = "owned:/%_"
            try f.writeCursorLegacyComposer(composerID)
            let live = try f.captureLiveCursorLegacy(composerID)
            XCTAssertEqual(f.sourceRoot.lastPathComponent, "globalStorage")
            XCTAssertEqual(live.cwd, f.project.path)
            let session = try live.archiveSession()
            let body = try session.encodeCanonical()
            XCTAssertEqual(session.logicalDatabaseLocator, f.configuration.rootPath + "/state.vscdb")
            let reserved = try f.seedCursorLegacyReservation(session)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            let result = try await f.worker(replicas.endpoints).runOnce(now: 200)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.recovered, 0)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(intent.publication.sequence, reserved.sequence)
            XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            XCTAssertEqual(capture.rawByteCount, Int64(body.count))
            XCTAssertEqual(capture.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(body))
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self, from: capture.unboundManifestBytes)
            for server in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in manifest.chunks {
                    restored.append(try await server.get("/v2/archive/objects/\(chunk.rawSHA256)").0)
                }
                XCTAssertEqual(restored, body)
            }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyUncapturedReservationAbandonsChangedPairOrOwnershipOnlyCwd() async throws {
        for kind in ["wal", "ownership"] {
            let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
            let replicas = try await replicas(for: f)
            do {
                let composerID = "owned:/%_"
                try f.writeCursorLegacyComposer(composerID)
                let live = try f.captureLiveCursorLegacy(composerID)
                let session = try live.archiveSession()
                XCTAssertEqual(live.cwd, f.project.path)
                let reserved: EngramCollectorCore.CollectorCaptureReservation
                if kind == "ownership" {
                    reserved = try f.seedCursorLegacyReservation(session)
                    try f.mutateCursorLegacyOwnershipCwd(f.alternateProject.path)
                    let after = try f.captureLiveCursorLegacy(composerID)
                    let owned = try after.archiveSession()
                    XCTAssertEqual(after.rows.databaseGeneration, session.databaseGeneration)
                    XCTAssertEqual(after.rows.walGeneration, session.walGeneration)
                    XCTAssertEqual(owned.rawPayloadByteCount, session.rawPayloadByteCount)
                    XCTAssertEqual(owned.nativePayloadByteCount, session.nativePayloadByteCount)
                    XCTAssertFalse(Data(after.cwd.utf8).elementsEqual(Data(session.cwd.utf8)))
                } else {
                    reserved = try f.seedCursorLegacyReservation(session)
                    try f.writeCursorLegacyComposer(composerID, extraKey: "composerData:late-twin")
                }
                let cycle = try await f.worker(replicas.endpoints).runOnce(now: 200)
                XCTAssertEqual(cycle.captured, 0, kind)
                XCTAssertEqual(cycle.recovered, 0, kind)
                XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty, kind)
                XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty, kind)
                XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty, kind)
                XCTAssertEqual(
                    try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'state.vscdb' AND dirty_revision > acknowledged_revision"),
                    1, kind)
                XCTAssertEqual(reserved.cursorLegacySession?.composerID, composerID)
                await replicas.stop()
            } catch { await replicas.stop(); throw error }
        }
    }

    func testCursorLegacyUncapturedReservationMissingSourceKeepsDirtyRecoverable() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            let generation = try EngramCollectorCore.ArchiveSourceGeneration(
                device: 1, inode: 2, size: 8192, mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
            let body = try EngramCollectorCore.ArchiveCursorLegacySession(
                logicalDatabaseLocator: f.sourceRoot.appendingPathComponent("state.vscdb").path,
                composerID: "owned:/%_", cwd: f.project.path, databaseGeneration: generation, walGeneration: nil,
                composer: .init(rowID: 1, key: "composerData:owned:/%_",
                    value: Data(#"{"composerId":"owned:/%_"}"#.utf8)), bubbles: [])
            let reserved = try f.seedCursorLegacyReservation(body)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sourceRoot.appendingPathComponent("state.vscdb").path))
            let cycle = try await f.worker(replicas.endpoints).runOnce(now: 200)
            XCTAssertEqual(cycle.deferred, 1)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.recovered, 0)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(
                try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'state.vscdb' AND dirty_revision > acknowledged_revision"),
                1)
            try f.writeCursorLegacyComposer(reserved.cursorLegacySession?.composerID ?? "owned:/%_")
            let live = try f.captureLiveCursorLegacy("owned:/%_")
            let next = try f.seedCursorLegacyReservation(try live.archiveSession())
            let resumed = try await f.worker(replicas.endpoints).runOnce(now: 300)
            XCTAssertEqual(resumed.captured, 1)
            XCTAssertGreaterThan(next.sequence, reserved.sequence)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).first?.publication.sequence, next.sequence)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyUncapturedReservationDefersEncodedBodyBudgetWithoutAbandon() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try f.writeCursorLegacyComposer("owned:/%_")
            let session = try f.captureLiveCursorLegacy("owned:/%_").archiveSession()
            let encoded = try session.encodeCanonical()
            XCTAssertGreaterThan(Int64(encoded.count), session.rawPayloadByteCount)
            XCTAssertGreaterThan(Int64(encoded.count), session.nativePayloadByteCount)
            let reserved = try f.seedCursorLegacyReservation(session)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureBytes = Int64(encoded.count) - 1
            XCTAssertLessThan(budget.maxCaptureBytes, reserved.generation.size)
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.recovered, 0)
            XCTAssertGreaterThan(cycle.deferred, 0)
            XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            budget.maxCaptureBytes = Int64(encoded.count)
            let resumed = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 201)
            XCTAssertEqual(resumed.captured, 1, "encoded body, not the live SQLite file, is the capture charge")
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).first?.publication.sequence, reserved.sequence)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorLegacyUncapturedReservationRejectsCorruptLocatorWithoutDeletingWork() async throws {
        let f = try PublicationFixture(sourceName: .cursor, legacySourceRoot: true)
        let replicas = try await replicas(for: f)
        do {
            try f.writeCursorLegacyComposer("owned:/%_")
            let session = try f.captureLiveCursorLegacy("owned:/%_").archiveSession()
            let reserved = try f.seedCursorLegacyReservation(session)
            let decoy = f.base.appendingPathComponent("decoy/User/globalStorage")
            try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let context = try EngramCollectorCore.ArchiveCursorLegacyContext(
                databaseLocator: decoy.appendingPathComponent("state.vscdb").path,
                composerID: session.composerID, cwd: session.cwd,
                rawPayloadByteCount: session.rawPayloadByteCount,
                nativePayloadByteCount: session.nativePayloadByteCount, walGeneration: session.walGeneration)
            let bytes = try EngramCollectorCore.ArchiveCanonicalJSON.encode(context)
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let digest = EngramCollectorCore.ArchiveV2Hash.sha256(bytes)
            // Model a canonical, hash-valid stale context in the owned spool;
            // keep the configured root unchanged to exercise reload validation.
            try f.mutate("UPDATE collector_capture_reservations SET cursor_legacy_bytes = X'\(hex)', cursor_legacy_sha256 = '\(digest)' WHERE relative_path = 'state.vscdb'")
            XCTAssertThrowsError(try f.owner.captureReservations(limit: 8)) {
                XCTAssertEqual($0 as? EngramCollectorCore.CollectorPublicationWorkerError, .invalidCapture)
            }
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                throw PublicationFixture.Failure.injected
            })
            do {
                _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 200)
                XCTFail("A corrupt reserved locator must stop before source I/O")
            } catch {
                XCTAssertEqual(error as? EngramCollectorCore.CollectorPublicationWorkerError, .invalidCapture)
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE cursor_legacy_bytes = X'\(hex)' AND cursor_legacy_sha256 = '\(digest)'"), 1)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            XCTAssertEqual(
                try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'state.vscdb' AND dirty_revision > acknowledged_revision"),
                1)
            XCTAssertEqual(reserved.cursorLegacySession?.databaseLocator, f.configuration.rootPath + "/state.vscdb")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testOpenCodeCapturedReservationRecoversWithoutOriginalDatabase() async throws {
        let f = try PublicationFixture(sourceName: .opencode)
        let replicas = try await replicas(for: f)
        do {
            let captured = PublicationLocked<CaptureResult?>(nil)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { value in
                captured.change { $0 = value }
                throw CancellationError()
            })
            do {
                _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
                XCTFail("interruption must preserve a CAS-only capture")
            } catch is CancellationError {}
            let durable = try XCTUnwrap(captured.value)
            let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
            XCTAssertEqual(reserved.sqliteSession?.nativeSessionID, "native-one")
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            try FileManager.default.removeItem(at: f.source)
            try f.reopen()
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 0
            let result = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(result.recovered, 1)
            XCTAssertEqual(result.captured, 0)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(intent.captureID, durable.capture.captureID)
            XCTAssertEqual(intent.publication.sequence, reserved.sequence)
            XCTAssertEqual(intent.publication.collectorEpoch, reserved.collectorEpoch)
            var restored = Data()
            for chunk in durable.manifest.chunks {
                restored.append(try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)").0)
            }
            var expected = Data()
            for chunk in durable.manifest.chunks { expected.append(try f.cas.readObject(sha256: chunk.rawSHA256)) }
            XCTAssertEqual(restored, expected)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testOpenCodeUncapturedReservationCannotRelabelChangedSourceAfterRestart() async throws {
        let f = try PublicationFixture(sourceName: .opencode)
        let replicas = try await replicas(for: f)
        do {
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                throw CancellationError()
            })
            do {
                _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
                XCTFail("interruption must preserve an uncaptured reservation")
            } catch is CancellationError {}
            let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
            try f.writeTranscript(text: "changed-source-after-reservation")
            try f.markDirty(relativePath: "opencode.db-wal")
            try f.reopen()
            let worker = try f.worker(replicas.endpoints)
            let abandoned = try await worker.runOnce(now: 200)
            XCTAssertEqual(abandoned.captured, 0)
            XCTAssertEqual(abandoned.recovered, 0)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            let next = try await worker.runOnce(now: 202)
            XCTAssertEqual(next.captured, 1)
            XCTAssertEqual(next.acknowledgedHQ, 1)
            XCTAssertEqual(next.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertGreaterThan(intent.publication.sequence, reserved.sequence)
            let capture = try XCTUnwrap(f.catalog.capture(captureID: intent.captureID))
            XCTAssertNotEqual(capture.generation, reserved.generation)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCrashAfterCaptureRecoversReservedGenerationNotChangedSourceBytes() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let captured = PublicationLocked<CaptureResult?>(nil)
        let beforeCaptureReached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { reservation in
            beforeCaptureReached.change { $0 = true }
            XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reservation])
            XCTAssertEqual(reservation.generation.size, Int64(original.count))
            XCTAssertTrue(try f.catalog.unboundCaptures(limit: 1).isEmpty,
                          "ordering intent must already be durable before the capture writer records any generation")
        }, afterCapture: { value in
            XCTAssertTrue(beforeCaptureReached.value)
            captured.change { $0 = value }
            XCTAssertEqual(try f.catalog.capture(captureID: value.capture.captureID), value.capture)
            XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100); XCTFail("crash injection was ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let durable = try XCTUnwrap(captured.value)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 0)
        let reservation = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        try f.writeTranscript(text: "new-live-generation-not-the-reserved-capture", cwd: f.base.appendingPathComponent("excluded").path)
        try f.markDirty()
        try f.reopen()
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
        XCTAssertEqual(cycle.recovered, 1)
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(intent.captureID, durable.capture.captureID)
        XCTAssertEqual(intent.publication.sequence, reservation.sequence)
        XCTAssertEqual(intent.publication.collectorEpoch, reservation.collectorEpoch)
        var restored = Data()
        for chunk in durable.manifest.chunks { restored.append(try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
        XCTAssertEqual(restored, original)
        XCTAssertNotEqual(try Data(contentsOf: f.source), original)
        XCTAssertFalse(try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 201).isEmpty,
                       "recovering old dirty revision must retain the newer event")
        await replicas.stop()
    }

    func testSchemaNineStreamMigrationResumesSavedCaptureAfterSourceDeletion() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        try f.owner.close()
        let database = try DatabaseQueue(path: f.inventory.path)
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            do {
                try db.inTransaction {
                    try db.execute(sql: """
                        CREATE TABLE collector_streams_v9 (
                            root_id TEXT NOT NULL, root_revision INTEGER NOT NULL CHECK(root_revision > 0),
                            source_instance_id TEXT NOT NULL, collector_epoch TEXT NOT NULL,
                            last_sequence INTEGER NOT NULL CHECK(typeof(last_sequence) = 'integer' AND last_sequence >= 0),
                            PRIMARY KEY(root_id, root_revision),
                            UNIQUE(root_id, root_revision, source_instance_id, collector_epoch),
                            FOREIGN KEY(root_id) REFERENCES collector_roots(root_id)
                        ) WITHOUT ROWID;
                        INSERT INTO collector_streams_v9 SELECT root_id, root_revision,
                            source_instance_id, collector_epoch, last_sequence FROM collector_streams;
                        DROP TABLE collector_streams;
                        ALTER TABLE collector_streams_v9 RENAME TO collector_streams;
                        UPDATE collector_metadata SET value = '9' WHERE key = 'publication_schema_version';
                        """)
                    XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                    return .commit
                }
            } catch {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                throw error
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            XCTAssertFalse(try db.columns(in: "collector_streams").contains { $0.name == "effective_source" })
        }
        XCTAssertThrowsError(try EngramCollectorCore.CollectorInventoryStore(database: database,
            machineID: PublicationFixture.machine, ownerRunID: "failed-migration",
            testHooks: .init(beforeCommit: { throw PublicationFixture.Failure.injected }))) {
            XCTAssertEqual($0 as? PublicationFixture.Failure, .injected)
        }
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertFalse(try db.columns(in: "collector_streams").contains { $0.name == "effective_source" })
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'"), "9")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source_instance_id FROM collector_streams"), prepared.reservation.sourceInstanceID)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT sequence FROM collector_capture_reservations"), prepared.reservation.sequence)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        try database.close()
        try FileManager.default.removeItem(at: f.source)
        try f.reopen()
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [prepared.reservation])
        XCTAssertEqual(try f.integer("SELECT CAST(value AS INTEGER) FROM collector_metadata WHERE key = 'publication_schema_version'"), 11)
        let intent = try f.finish(prepared)
        XCTAssertEqual(intent.captureID, prepared.capture.capture.captureID)
        XCTAssertEqual(intent.publication.sourceInstanceID, prepared.reservation.sourceInstanceID)
        XCTAssertEqual(intent.publication.collectorEpoch, prepared.reservation.collectorEpoch)
        XCTAssertEqual(intent.publication.sequence, prepared.reservation.sequence)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
    }

    func testPublicationSchemaMigrationPreservesLegacyReservationAndRejectsUnknownVersions() throws {
        for legacy in ["1", "2", "3"] { try assertPublicationSchemaMigration(legacy: legacy) }
    }

    private func assertPublicationSchemaMigration(legacy: String) throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let prepared = try f.prepare()
        try f.owner.close()
        let database = try DatabaseQueue(path: f.inventory.path)
        try database.write { db in
            if legacy == "1" { try db.execute(sql: "DROP TABLE collector_capture_reservation_dependencies") }
            if legacy != "3" {
                try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN gemini_context_bytes")
                try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN gemini_context_sha256")
            }
            for column in ["sqlite_session_bytes", "sqlite_session_sha256"] {
                try db.execute(sql: "ALTER TABLE collector_capture_reservations DROP COLUMN \(column)")
            }
            for column in ["opencode_walk_generation", "opencode_walk_wal_generation", "opencode_walk_page_after"] {
                try db.execute(sql: "ALTER TABLE collector_roots DROP COLUMN \(column)")
            }
            try db.execute(sql: "UPDATE collector_metadata SET value = ? WHERE key = 'publication_schema_version'", arguments: [legacy])
        }
        try database.close()
        try f.reopen()
        XCTAssertEqual(try f.integer("SELECT CAST(value AS INTEGER) FROM collector_metadata WHERE key = 'publication_schema_version'"), 11)
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [prepared.reservation])
        XCTAssertNil(prepared.reservation.snapshot)
        XCTAssertNil(prepared.reservation.sqliteSession)
        let intent = try f.finish(prepared)
        XCTAssertEqual(intent.captureID, prepared.capture.capture.captureID)
        for version in ["0", "12", "not-a-version"] {
            try f.owner.close()
            let database = try DatabaseQueue(path: f.inventory.path)
            let previousOwner = try database.read { try String.fetchOne($0,
                sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'") }
            try database.write { db in
                try db.execute(sql: "UPDATE collector_metadata SET value = ? WHERE key = 'publication_schema_version'", arguments: [version])
            }
            XCTAssertThrowsError(try EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
                shadowRoot: f.shadow, identityCatalog: f.identity, ownerRunID: UUID().uuidString))
            XCTAssertEqual(try database.read { try String.fetchOne($0,
                sql: "SELECT value FROM collector_metadata WHERE key = 'active_owner_run_id'") }, previousOwner)
            XCTAssertEqual(try database.read { try String.fetchOne($0,
                sql: "SELECT value FROM collector_metadata WHERE key = 'publication_schema_version'") }, version)
            XCTAssertEqual(try database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_publications") }, 1)
            try database.close()
        }
    }

    func testCopilotPersistedReservationCannotLoseAllDependencyRows() throws {
        let f = try PublicationFixture(sourceName: .copilot)
        defer { f.remove() }
        let observed = try EngramCollectorCore.CollectorCopilotSource.observe(rootPath: f.sourceRoot.path,
            primaryRelative: f.sourceRelativePath)
        let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100).first)
        _ = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
            generation: observed.generation, snapshot: observed.snapshot))
        let database = try DatabaseQueue(path: f.inventory.path)
        try database.write { try $0.execute(sql: "DELETE FROM collector_capture_reservation_dependencies") }
        try database.close()
        XCTAssertThrowsError(try f.owner.captureReservations(limit: 8))
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 0)
    }

    func testCopilotReservationRejectsMissingSnapshotAndUnboundPrimaryGeneration() throws {
        for missingSnapshot in [true, false] {
            let f = try PublicationFixture(sourceName: .copilot)
            defer { f.remove() }
            let observed = try EngramCollectorCore.CollectorCopilotSource.observe(rootPath: f.sourceRoot.path,
                primaryRelative: f.sourceRelativePath)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100).first)
            let auxiliary = try XCTUnwrap(observed.snapshot.present.first { $0.relativePath.hasSuffix("workspace.yaml") })
            XCTAssertThrowsError(try f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: missingSnapshot ? observed.generation : auxiliary.generation,
                snapshot: missingSnapshot ? nil : observed.snapshot))
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservation_dependencies"), 0)
        }
    }

    func testCopilotRecoveryMatchesReservedAuxiliarySnapshotWithoutReadingChangedLiveFiles() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        let replicas = try await replicas(for: f)
        do {
            let first = try f.capture()
            let workspace = f.source.deletingLastPathComponent().appendingPathComponent("workspace.yaml")
            let reservedBytes = Data("id: native-one\ncwd: \(f.project.path)\nsummary: reserved second version\n".utf8)
            try reservedBytes.write(to: workspace)
            let second = try f.capture()
            XCTAssertEqual(first.manifest.generation, second.manifest.generation)
            XCTAssertNotEqual(first.capture.captureID, second.capture.captureID)
            let observed = try EngramCollectorCore.CollectorCopilotSource.observe(rootPath: f.sourceRoot.path,
                primaryRelative: f.sourceRelativePath)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100).first)
            let reservation = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: observed.generation, snapshot: observed.snapshot))
            XCTAssertEqual(try f.owner.captureReservations(limit: 8).first?.snapshot, observed.snapshot)
            try Data("id: forged-live\ncwd: /excluded-live\n".utf8).write(to: workspace)
            try f.markDirty(relativePath: "session-1/workspace.yaml")
            try f.reopen()
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 0
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(cycle.recovered, 1)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(cycle.acknowledgedHQ, 1)
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            XCTAssertEqual(intent.captureID, second.capture.captureID)
            XCTAssertEqual(intent.publication.sequence, reservation.sequence)
            var raw = Data()
            for chunk in second.manifest.chunks {
                raw.append(try await replicas.hq.get("/v2/archive/objects/\(chunk.rawSHA256)").0)
            }
            let member = try XCTUnwrap(second.manifest.replayLayout.files?.first { $0.relativePath == "session-1/workspace.yaml" })
            XCTAssertEqual(raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount)), reservedBytes)
            XCTAssertNotEqual(try Data(contentsOf: workspace), reservedBytes)
            XCTAssertFalse(try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 201).isEmpty)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testGrokSegmentOnlyChangePublishesUpdatedFileSetWithStablePrimary_repro() async throws {
        let f = try PublicationFixture(sourceName: .grok)
        let replicas = try await replicas(for: f)
        do {
            let chatBytes = try Data(contentsOf: f.source)
            let segmentRelative = "native-project/019dd6e3-91d1-7326-8299-314858773a0e/compaction/segment_000.md"
            let segment = f.sourceRoot.appendingPathComponent(segmentRelative)
            let firstSegment = try Data(contentsOf: segment)
            let first = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(first.captured, 1)
            XCTAssertEqual(first.acknowledgedHQ, 1)
            XCTAssertEqual(first.acknowledgedM1, 1)
            let firstIntent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let firstManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: firstIntent.publication.manifestSHA256))
            XCTAssertEqual(firstManifest.source, "grok")
            XCTAssertEqual(firstManifest.replayLayout.entrypointRelativePath, f.sourceRelativePath)
            XCTAssertTrue(firstManifest.replayLayout.relativePaths.contains(segmentRelative))
            let updated = Data("# updated archive\n".utf8)
            try updated.write(to: segment)
            guard chmod(segment.path, 0o600) == 0 else { throw PublicationFixture.Failure.unsafeFixture }
            XCTAssertEqual(try Data(contentsOf: f.source), chatBytes)
            try f.markDirty(relativePath: segmentRelative)
            let second = try await f.worker(replicas.endpoints).runOnce(now: 200)
            XCTAssertEqual(second.captured, 1)
            XCTAssertEqual(second.acknowledgedHQ, 1)
            XCTAssertEqual(second.acknowledgedM1, 1)
            let intents = try f.owner.publicationIntents(limit: 8)
            XCTAssertEqual(intents.count, 2)
            let secondIntent = try XCTUnwrap(intents.last)
            let secondManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: secondIntent.publication.manifestSHA256))
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            XCTAssertEqual(secondIntent.publication.sequence, firstIntent.publication.sequence + 1)
            XCTAssertEqual(try Data(contentsOf: f.source), chatBytes)
            var raw = Data()
            for chunk in secondManifest.chunks { raw.append(try f.cas.readObject(sha256: chunk.rawSHA256)) }
            let member = try XCTUnwrap(secondManifest.replayLayout.files?.first { $0.relativePath == segmentRelative })
            XCTAssertEqual(raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount)), updated)
            XCTAssertNotEqual(firstSegment, updated)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCodexForkLinkedTranscriptPublishes_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        let child: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": "child-native", "cwd": f.project.path, "timestamp": "2026-09-12T00:00:01Z",
                "forked_from_id": "parent-native",
            ],
        ]
        let parent: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": "parent-native", "cwd": f.project.path, "timestamp": "2026-09-12T00:00:00Z",
            ],
        ]
        let reply: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "fork"]]],
        ]
        var bytes = Data()
        for row in [child, parent, reply] {
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(10)
        }
        try f.writeBytes(bytes)
        try f.markDirty()
        let replicas = try await replicas(for: f)
        do {
            let result = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE last_error = 'privacyWithheld'"), 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: intent.publication.manifestSHA256))
            XCTAssertEqual(manifest.source, "codex")
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorRootlessModernPublishesWithoutInventingProject_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        try f.writeTranscript(cwd: "")
        try f.markDirty()
        let replicas = try await replicas(for: f)
        do {
            let result = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE last_error = 'privacyWithheld'"), 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: intent.publication.manifestSHA256))
            XCTAssertEqual(manifest.source, "cursor")
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorRootlessLegacyCapturedPublishesWithoutInventingProject_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        let replicas = try await replicas(for: f)
        do {
            try f.mutate("""
                INSERT INTO collector_locators(root_id, root_revision, relative_path,
                    dirty_revision, acknowledged_revision, claim_generation)
                SELECT root_id, root_revision, 'state.vscdb', 1, 0, 0 FROM collector_roots
                """)
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 100)
                .first { $0.relativePath == "state.vscdb" })
            let generation = try EngramCollectorCore.ArchiveSourceGeneration(
                device: 1, inode: 2, size: 8192, mtimeNs: 3, ctimeNs: 4, mode: 0o100600)
            let body = try EngramCollectorCore.ArchiveCursorLegacySession(
                logicalDatabaseLocator: f.sourceRoot.appendingPathComponent("state.vscdb").path,
                composerID: "owned:/%_", cwd: "", databaseGeneration: generation, walGeneration: nil,
                composer: .init(rowID: 1, key: "composerData:owned:/%_",
                    value: Data(#"{"composerId":"owned:/%_"}"#.utf8)), bubbles: [])
            let context = try EngramCollectorCore.ArchiveCursorLegacyContext(session: body)
            _ = try f.owner.reconcileCursorLegacyWalk(claim, configuration: f.configuration,
                generation: generation, walGeneration: nil)
            _ = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: generation, cursorLegacySession: context))
            _ = try EngramCollectorCore.ExactSourceCapturer.captureCursorLegacySession(
                body, machineID: PublicationFixture.machine, cas: f.cas, catalog: f.catalog)
            try f.reopenOwnerAndCatalog()
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 0
            let result = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
            XCTAssertEqual(result.recovered, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE last_error = 'privacyWithheld'"), 0)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCopilotMessageOverOneMiBPublishes_repro() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        let oversized = String(repeating: "x", count: 1024 * 1024 + 1)
        let records: [[String: Any]] = [
            ["type": "session.start", "timestamp": "2026-09-08T00:00:00Z",
             "data": ["context": ["cwd": f.project.path]]],
            ["type": "user.message", "timestamp": "2026-09-08T00:00:01Z", "data": ["content": "ok"]],
            ["type": "user.message", "timestamp": "2026-09-08T00:00:02Z", "data": ["content": oversized]],
        ]
        try f.writeBytes(try records.reduce(into: Data()) { bytes, row in
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(10)
        })
        try f.markDirty()
        let replicas = try await replicas(for: f)
        do {
            let result = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE last_error = 'privacyWithheld'"), 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: intent.publication.manifestSHA256))
            XCTAssertEqual(manifest.source, "copilot")
            var raw = Data()
            for chunk in manifest.chunks { raw.append(try f.cas.readObject(sha256: chunk.rawSHA256)) }
            XCTAssertGreaterThan(raw.count, 1024 * 1024)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCopilotIndexOnlyClaimRecapturesCleanEventsAndAcksAliasAfterCheckpointChange_repro() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        let replicas = try await replicas(for: f)
        do {
            let checkpoints = f.source.deletingLastPathComponent().appendingPathComponent("checkpoints")
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let index = checkpoints.appendingPathComponent("index.md")
            let body = checkpoints.appendingPathComponent("001.md")
            let originalIndex = Data("| 1 | Original checkpoint | 001.md |\n".utf8)
            let originalBody = Data("# original body\n".utf8)
            try originalIndex.write(to: index)
            try originalBody.write(to: body)
            let first = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: 100)
            XCTAssertEqual(first.captured, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_locators WHERE relative_path = 'session-1/events.jsonl' AND dirty_revision > acknowledged_revision"
            ), 0)
            let firstIntent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let firstManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: firstIntent.publication.manifestSHA256))
            XCTAssertEqual(firstManifest.replayLayout.entrypointRelativePath, "session-1/events.jsonl")
            let updatedIndex = Data("| 1 | Updated checkpoint | 001.md |\n".utf8)
            let updatedBody = Data("# updated body\n".utf8)
            try updatedIndex.write(to: index)
            try updatedBody.write(to: body)
            try f.mutate("""
                INSERT INTO collector_locators(root_id, root_revision, relative_path,
                    dirty_revision, acknowledged_revision, claim_generation)
                SELECT root_id, root_revision, 'session-1/checkpoints/index.md', 1, 0, 0 FROM collector_roots
                """)
            let second = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: 200)
            XCTAssertEqual(second.captured, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"
            ), 0)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md' AND last_error IS NOT NULL"
            ), 0)
            let intents = try f.owner.publicationIntents(limit: 8)
            XCTAssertEqual(intents.count, 2)
            let secondManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: try XCTUnwrap(intents.last).publication.manifestSHA256))
            XCTAssertEqual(secondManifest.replayLayout.entrypointRelativePath, "session-1/events.jsonl")
            XCTAssertNotEqual(firstIntent.captureID, intents.last?.captureID)
            var raw = Data()
            for chunk in secondManifest.chunks { raw.append(try f.cas.readObject(sha256: chunk.rawSHA256)) }
            let indexMember = try XCTUnwrap(secondManifest.replayLayout.files?.first {
                $0.relativePath == "session-1/checkpoints/index.md"
            })
            let bodyMember = try XCTUnwrap(secondManifest.replayLayout.files?.first {
                $0.relativePath == "session-1/checkpoints/001.md"
            })
            XCTAssertEqual(
                raw.subdata(in: Int(indexMember.byteOffset)..<Int(indexMember.byteOffset + indexMember.rawByteCount)),
                updatedIndex
            )
            XCTAssertEqual(
                raw.subdata(in: Int(bodyMember.byteOffset)..<Int(bodyMember.byteOffset + bodyMember.rawByteCount)),
                updatedBody
            )
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCopilotPreferredEntrypointFailureDefersWithoutAcknowledgingExistingFiles() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        let replicas = try await replicas(for: f)
        do {
            try Data("{\"type\":\"session.start\",\"data\":{\"context\":{\"cwd\":\"\(f.project.path)\"}}}\n".utf8)
                .write(to: f.source)
            let checkpoints = f.source.deletingLastPathComponent().appendingPathComponent("checkpoints")
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data("# no table row\n".utf8).write(to: checkpoints.appendingPathComponent("index.md"))
            try f.markDirty(relativePath: "session-1/checkpoints/index.md")
            let cycle = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 2)).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertGreaterThan(
                try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"),
                0
            )
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCopilotIndexOnlyEmptyIndexNeverCapturedDefersSixtySecondsWithoutACK_repro() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.source)
        let checkpoints = f.source.deletingLastPathComponent().appendingPathComponent("checkpoints")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("# no table row\n".utf8).write(to: checkpoints.appendingPathComponent("index.md"))
        try f.markDirty(relativePath: "session-1/checkpoints/index.md")
        let result = try await f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 2)).captureOnce(now: 100)
        XCTAssertEqual(result.captured, 0)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        XCTAssertEqual(
            try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md'"),
            160
        )
        XCTAssertEqual(
            try f.text("SELECT last_error FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md'"),
            "unavailable"
        )
        XCTAssertGreaterThan(
            try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md'"),
            try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md'")
        )
    }

    func testCopilotIndexOnlyClaimGenerationChangeRetainsDirtyWorkAndRetries() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        let replicas = try await replicas(for: f)
        do {
            let checkpoints = f.source.deletingLastPathComponent().appendingPathComponent("checkpoints")
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data("| 1 | Checkpoint | 001.md |\n".utf8)
                .write(to: checkpoints.appendingPathComponent("index.md"))
            try Data("# body\n".utf8).write(to: checkpoints.appendingPathComponent("001.md"))
            let first = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: 100)
            XCTAssertEqual(first.captured, 1)
            try f.mutate("""
                INSERT INTO collector_locators(root_id, root_revision, relative_path,
                    dirty_revision, acknowledged_revision, claim_generation)
                SELECT root_id, root_revision, 'session-1/checkpoints/index.md', 1, 0, 0 FROM collector_roots
                """)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
                throw EngramCollectorCore.ExactSourceCapturerError.generationChanged
            })
            let failed = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1), hooks: hooks)
                .runOnce(now: 200)
            XCTAssertEqual(failed.captured, 0)
            XCTAssertTrue(try f.owner.captureReservations(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md' AND dirty_revision > acknowledged_revision"
            ), 1)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            try Data("# retried body\n".utf8).write(to: checkpoints.appendingPathComponent("001.md"))
            try f.reopenOwnerAndCatalog()
            for tick in 300...304 {
                _ = try await f.worker(replicas.endpoints, budget: .init(maxCaptureFiles: 1)).runOnce(now: Int64(tick))
            }
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 2)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testPiMessageOverOneMiBPublishes_repro() async throws {
        let f = try PublicationFixture(sourceName: .pi)
        let oversized = String(repeating: "x", count: 1024 * 1024 + 1)
        try f.writeTranscript(text: oversized)
        try f.markDirty()
        let replicas = try await replicas(for: f)
        do {
            let result = try await f.worker(replicas.endpoints).runOnce(now: 100)
            XCTAssertEqual(result.captured, 1)
            XCTAssertEqual(result.acknowledgedHQ, 1)
            XCTAssertEqual(result.acknowledgedM1, 1)
            XCTAssertEqual(try f.integer(
                "SELECT count(*) FROM collector_publication_replicas WHERE last_error = 'privacyWithheld'"), 0)
            let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: f.cas.readManifest(sha256: intent.publication.manifestSHA256))
            XCTAssertEqual(manifest.source, "pi")
            var raw = Data()
            for chunk in manifest.chunks { raw.append(try f.cas.readObject(sha256: chunk.rawSHA256)) }
            XCTAssertGreaterThan(raw.count, 1024 * 1024)
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCancellationAfterActualACKLeavesReplayableBacklog() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let reached = PublicationLocked(false)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeACKCommit: { claim in
            if claim.replicaID == "hq" {
                reached.change { $0 = true }
                throw CancellationError()
            }
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100); XCTFail("cancellation became a success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(reached.value)
        let cancelledRecords = try await replicas.hq.publications()
        XCTAssertEqual(cancelledRecords.count, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), 0)
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        try f.reopen()
        _ = try await f.worker(replicas.endpoints).runOnce(now: 200_000)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8), [intent])
        let replayedRecords = try await replicas.hq.publications()
        XCTAssertEqual(replayedRecords.count, 1)
        await replicas.stop()
    }

    func testMissingCASObjectRetainsBacklogAndMakesNoHTTPRequests() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let prepared = try f.prepare()
        _ = try f.finish(prepared)
        let digest = try XCTUnwrap(prepared.capture.manifest.chunks.first).rawSHA256
        let object = f.captureRoot.appendingPathComponent("objects/sha256/\(digest.prefix(2))/\(digest)")
        try FileManager.default.removeItem(at: object)
        let requests = PublicationLocked(0)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in requests.change { $0 += 1 } })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas"), 2)
        await replicas.stop()
    }

    func testCaptureByteAndDiskBudgetsDoNotCreatePartialCaptureOrAcknowledgeDirty() async throws {
        for diskPressure in [false, true] {
            let f = try PublicationFixture()
            let replicas = try await replicas(for: f)
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            if diskPressure { budget.minimumFreeDiskBytes = Int64.max }
            else { budget.maxCaptureBytes = 1 }
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 0)
            XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testOldRevisionReservationsDoNotStarveCurrentRevisionRecovery() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let capture = try f.capture()
        var current: EngramCollectorCore.CollectorCaptureReservation?
        for revision in 1...65 {
            if revision > 1 {
                f.rootRevision = Int64(revision)
                _ = try f.owner.enrollAndActivateRoot(f.configuration)
                try f.markDirty()
            }
            let claim = try XCTUnwrap(f.owner.claimDirty(configuration: f.configuration, limit: 1, now: 1).first)
            current = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: f.configuration,
                generation: capture.manifest.generation))
        }
        let reserved = try XCTUnwrap(current)
        XCTAssertEqual(reserved.rootRevision, 65)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision < 65"), 64)
        try f.reopen()
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
        XCTAssertEqual(cycle.recovered, 1, "old revisions must not consume the entire bounded recovery window")
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.rootRevision, 65)
        XCTAssertEqual(intents.first?.captureID, capture.capture.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, reserved.sequence)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision = 65"), 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_revision < 65"), 64,
                       "recovery must fence old reservations without deleting their durable evidence")
        await replicas.stop()
    }

    func testLiveAppendAfterStableCapturePublishesReservedGenerationAndRetainsDirty() async throws {
        let fixture = PublicationLocked<PublicationFixture?>(nil)
        let appended = PublicationLocked(false)
        let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterFinalLinkPublished: { url in
            guard url.pathExtension == "json", !appended.value, let f = fixture.value else { return }
            // Manifest publication is after the capturer's stable-FD read and
            // final generation check. Catalog commit follows before it returns.
            // This existing CAS hook needs no timing race or production changes.
            let handle = try FileHandle(forWritingTo: f.source)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"later append\"}}\n".utf8))
            try handle.synchronize()
            try f.markDirty()
            appended.change { $0 = true }
        })
        let f = try PublicationFixture(casTestHooks: casHooks)
        fixture.change { $0 = f }
        defer { fixture.change { $0 = nil } }
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let cycle = try await f.worker(replicas.endpoints).runOnce(now: 100)
        XCTAssertTrue(appended.value, "the stable-capture/live-append boundary must actually execute")
        let durable = try XCTUnwrap(f.catalog.unboundCaptures(limit: 8).first)
        XCTAssertEqual(durable.rawByteCount, Int64(original.count))
        XCTAssertEqual(durable.generation.size, Int64(original.count))
        XCTAssertNotEqual(try Data(contentsOf: f.source), original)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let pending = try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 101)
        XCTAssertEqual(pending.first?.dirtyRevision, 2, "publication of the old generation must not erase the appended event")
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1, "an already durable generation must retain its publication entry")
        XCTAssertEqual(intents.first?.captureID, durable.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        if let intent = intents.first {
            for replica in replicas.all {
                let manifest = try await replica.get("/v2/archive/manifests/\(intent.publication.manifestSHA256)")
                XCTAssertEqual(manifest.0, durable.unboundManifestBytes)
                let decoded = try Canonical.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: manifest.0)
                var restored = Data()
                for chunk in decoded.chunks { restored.append(try await replica.get("/v2/archive/objects/\(chunk.rawSHA256)").0) }
                XCTAssertEqual(restored, original)
            }
        }
        await replicas.stop()
    }

    func testRecaptureAfterNegativeRecoveryRefreshesBoundaryBeforeCrash() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        _ = try f.capture()
        try f.writeTranscript(text: "unrelated-older-generation-with-a-different-size")
        _ = try f.capture()
        let oldBoundary = try XCTUnwrap(f.catalog.unboundCaptureBoundary())
        let prior = try f.catalog.unboundCaptures(limit: 8)
        XCTAssertEqual(prior.count, 2)
        try f.writeTranscript(text: "reserved-generation-to-be-captured-after-negative-recovery")
        try f.markDirty()
        let beforeCapture = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, hooks: beforeCapture).runOnce(now: 100); XCTFail("reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let reserved = try XCTUnwrap(f.owner.captureReservations(limit: 8).first)
        try f.seedRecoveryCheckpoint(reserved, after: .init(capturedAt: prior[0].capturedAt, captureID: prior[0].captureID),
            through: oldBoundary)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE recovery_state IS NOT NULL"), 1,
                       "the regression requires a real persisted recovery checkpoint")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        budget.maxRecoveryCandidates = 1
        let firstPage = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 101)
        XCTAssertEqual(firstPage.recovered, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE recovery_state IS NOT NULL"), 0,
                       "a negative filtered scan must clear the seeded checkpoint before recapture")
        let captured = PublicationLocked<CaptureResult?>(nil)
        let afterCapture = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { value in
            captured.change { $0 = value }
            XCTAssertEqual(try f.catalog.capture(captureID: value.capture.captureID), value.capture)
            throw PublicationFixture.Failure.injected
        })
        budget.maxCaptureFiles = 1
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: afterCapture).runOnce(now: 102); XCTFail("durable recapture interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        let durable = try XCTUnwrap(captured.value)
        XCTAssertTrue(durable.capture.capturedAt > oldBoundary.capturedAt
            || (durable.capture.capturedAt == oldBoundary.capturedAt && durable.capture.captureID > oldBoundary.captureID),
            "the actual newly committed capture must be beyond the old frozen catalog boundary")
        XCTAssertEqual(try f.owner.captureReservations(limit: 8), [reserved])
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        try f.writeTranscript(text: "later-live-generation-that-must-not-replace-the-durable-recapture")
        try f.markDirty()
        try f.reopen()
        budget.maxRecoveryCandidates = 8
        let recovered = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 200)
        XCTAssertEqual(recovered.recovered, 1)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(recovered.acknowledgedHQ, 1)
        XCTAssertEqual(recovered.acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.captureID, durable.capture.captureID)
        XCTAssertEqual(intents.first?.publication.sequence, reserved.sequence)
        let pending = try f.owner.claimDirty(configuration: f.configuration, limit: 8, now: 201)
        XCTAssertEqual(pending.first?.dirtyRevision, reserved.dirtyRevision + 1)
        await replicas.stop()
    }

    func testCapturedJSONLLongLinesReachBothReplicasWithoutPrivacyTruncation() async throws {
        for source: EngramCollectorCore.SourceName in [.codex, .claudeCode] {
            let f = try PublicationFixture(sourceName: source)
            let replicas = try await replicas(for: f)
            try f.writeTranscript(text: "first-" + String(repeating: "x", count: 2 * 1024 * 1024) + "-last")
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureBytes = 8 * 1024 * 1024
            let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 100)
            XCTAssertEqual(cycle.captured, 1)
            XCTAssertEqual(cycle.acknowledgedHQ, 1, "complete frozen long-line metadata must pass privacy assessment")
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            await replicas.stop()
        }
    }

    func testFreshOnlyReservationDoesNotReuseAnExistingCapture() throws {
        let f = try PublicationFixture()
        let vscode = try f.installNativeVSCodePrimary(rootID: "daily-vscode")
        let observed = try EngramCollectorCore.CollectorVSCodeSource.observe(
            rootPath: vscode.configuration.rootPath, primaryRelative: vscode.relativePath,
            maximumByteCount: 1_048_576)
        let claim = try XCTUnwrap(f.owner.claimDirty(
            configuration: vscode.configuration, limit: 1, now: 100).first)
        let original = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: vscode.configuration,
            generation: observed.generation, snapshot: observed.snapshot, allowExisting: false))
        XCTAssertNil(try f.owner.reserveCapture(claim, configuration: vscode.configuration,
            generation: observed.generation, snapshot: observed.snapshot, allowExisting: false))
        let recovered = try XCTUnwrap(f.owner.reserveCapture(claim, configuration: vscode.configuration,
            generation: observed.generation, snapshot: observed.snapshot))
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 1)
    }

    func testFreshVSCodeCaptureDoesNotScanUnrelatedRecoveryHistory_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        for index in 0..<8 {
            try f.writeTranscript(text: "unrelated-capture-\(index)")
            _ = try f.capture()
        }
        let vscode = try f.installNativeVSCodePrimary(rootID: "daily-vscode")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        budget.maxRecoveryCandidates = 1
        let worker = try f.worker(replicas.endpoints, roots: [vscode.configuration], budget: budget)
        let cycle = try await worker.runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1, "a newly reserved file has no prior capture to recover")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_id = 'daily-vscode'"), 0)
        await replicas.stop()
    }

    func testInterruptedRecoverySkipsUnrelatedUnboundHistoryBeforeLimit_repro() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        for index in 0..<8 {
            try f.writeTranscript(text: "unrelated-prior-\(index)-" + String(repeating: "n", count: 16 + index))
            _ = try f.capture()
        }
        try f.writeTranscript(text: "reserved-generation-already-durable")
        let matching = try f.capture()
        try f.markDirty()
        let interrupted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, hooks: interrupted).runOnce(now: 100)
            XCTFail("reservation interruption ignored")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
        XCTAssertGreaterThan(try f.catalog.unboundCaptures(limit: 64).count, 8)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 0
        budget.maxRecoveryCandidates = 1
        let cycle = try await f.worker(replicas.endpoints, budget: budget).runOnce(now: 101)
        XCTAssertEqual(cycle.recovered, 1, "recovery must find the reserved generation without paging unrelated unbound history")
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        XCTAssertNil(try f.recoveryAfterID(f.configuration.rootID))
        let intent = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        XCTAssertEqual(intent.captureID, matching.capture.captureID)
        await replicas.stop()
    }

    func testEarlierMidScanReservationDoesNotStarveLaterVSCodeRecoveryBudget() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let allowed = try EngramCollectorCore.CollectorPrivacyPolicy(
            revision: 2, excludedProjectRoots: [], allowedSources: [.codex, .vscode])
        f.policy.change { $0 = allowed }
        let claude = try f.enrollCodexRoot(rootID: "daily-claude")
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        budget.maxRecoveryCandidates = 1
        let persisted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do {
            _ = try await f.worker(replicas.endpoints, roots: [claude], budget: budget, hooks: persisted)
                .runOnce(now: 100)
            XCTFail("reservation interruption ignored")
        } catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        try f.writeTranscript(text: "unrelated-later-catalog-tail")
        _ = try f.capture()
        let vscode = try f.installNativeVSCodePrimary(rootID: "daily-vscode")
        try f.reserveVSCodePrimary(vscode)
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).map(\.rootID),
                       ["daily-claude", "daily-vscode"])
        XCTAssertNil(try f.recoveryAfterID("daily-claude"))
        XCTAssertNil(try f.recoveryAfterID("daily-vscode"))
        let worker = try f.worker(replicas.endpoints, roots: [claude, vscode.configuration], budget: budget)
        let first = try await worker.runOnce(now: 200)
        XCTAssertEqual(first.captured, 0)
        XCTAssertNotNil(try f.recoveryAfterID("daily-claude"),
                        "A full matching page that is not the frozen boundary must persist a checkpoint")
        XCTAssertNil(try f.recoveryAfterID("daily-vscode"),
                     "B must stay unvisited while A consumes the only recovery candidate")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_id = 'daily-vscode'"), 1)
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8).filter { $0.rootID == "daily-vscode" }.count, 0)
        let second = try await worker.runOnce(now: 201)
        XCTAssertEqual(second.captured, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_id = 'daily-vscode'"), 0,
                       "B's negative filtered scan must consume zero and then capture")
        XCTAssertEqual(try f.owner.publicationIntents(limit: 8).filter { $0.rootID == "daily-vscode" }.count, 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations WHERE root_id = 'daily-claude'"), 0,
                       "A must finish after B takes the rotated cycle")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE last_error = 'unavailable'"), 0)
        await replicas.stop()
    }

    func testMissingUncapturedSourceDoesNotStarveAnotherDirtyFileInRoot() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        let interrupted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { _ in
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: interrupted).runOnce(now: 100); XCTFail("reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).count, 1)
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        try FileManager.default.removeItem(at: f.source)
        let other = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "another-live-source-in-the-same-root").write(to: other)
        XCTAssertEqual(chmod(other.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        var captured = 0
        var acknowledgedHQ = 0
        var acknowledgedM1 = 0
        let worker = try f.worker(replicas.endpoints, budget: budget)
        for now: Int64 in [101, 102, 103] {
            let cycle = try await worker.runOnce(now: now)
            captured += cycle.captured
            acknowledgedHQ += cycle.acknowledgedHQ
            acknowledgedM1 += cycle.acknowledgedM1
        }
        XCTAssertEqual(captured, 1, "an absent uncaptured file must not reserve its entire root forever")
        XCTAssertEqual(acknowledgedHQ, 1)
        XCTAssertEqual(acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.relativePath, "two.jsonl")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        await replicas.stop()
    }

    func testNeverCapturedMissingSourceDefersSixtySecondsAndStaysUnacknowledged_repro() async throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.source)
        let result = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 100)
        XCTAssertEqual(result.captured, 0)
        XCTAssertGreaterThanOrEqual(result.deferred, 1)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 160)
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = 'one.jsonl'"), "unavailable")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertGreaterThan(try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'one.jsonl' AND last_capture_id IS NULL"), 1)
    }

    func testPreviouslyCapturedMissingSourceDefersOneSecondAndStaysUnacknowledged_repro() async throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let first = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 100)
        XCTAssertEqual(first.captured, 1)
        XCTAssertGreaterThan(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'one.jsonl' AND last_capture_id IS NOT NULL"), 1)
        try f.markDirty()
        try FileManager.default.removeItem(at: f.source)
        let second = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 200)
        XCTAssertEqual(second.captured, 0)
        XCTAssertGreaterThanOrEqual(second.deferred, 1)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 201)
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = 'one.jsonl'"), "unavailable")
        XCTAssertGreaterThan(
            try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"),
            try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'")
        )
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'one.jsonl' AND last_capture_id IS NOT NULL"), 1)
    }

    func testNeverCapturedZeroByteKimiDefersSixtySecondsWakesOnAppendDirty_repro() async throws {
        let f = try PublicationFixture(sourceName: .kimi)
        defer { f.remove() }
        let path = f.sourceRelativePath
        try f.writeBytes(Data())
        XCTAssertEqual(try Data(contentsOf: f.source).count, 0)
        let empty = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 100)
        XCTAssertEqual(empty.captured, 0)
        XCTAssertGreaterThanOrEqual(empty.deferred, 1)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = '\(path)'"), 160)
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = '\(path)'"), "unavailable")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(path)'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(path)' AND last_capture_id IS NULL"), 1)
        let held = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 120)
        XCTAssertEqual(held.captured, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = '\(path)'"), 160)
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(path)'"), 0)
        try f.writeTranscript(text: "appended after empty")
        try f.markDirty()
        let woken = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 121)
        XCTAssertEqual(woken.captured, 1)
        XCTAssertGreaterThan(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(path)'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(path)' AND last_capture_id IS NOT NULL"), 1)
    }

    func testPreviouslyCapturedZeroByteKimiDefersOneSecondAndStaysUnacknowledged_repro() async throws {
        let f = try PublicationFixture(sourceName: .kimi)
        defer { f.remove() }
        let path = f.sourceRelativePath
        let first = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 100)
        XCTAssertEqual(first.captured, 1)
        XCTAssertGreaterThan(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(path)'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(path)' AND last_capture_id IS NOT NULL"), 1)
        try f.writeBytes(Data())
        try f.markDirty()
        let second = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 200)
        XCTAssertEqual(second.captured, 0)
        XCTAssertGreaterThanOrEqual(second.deferred, 1)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = '\(path)'"), 201)
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = '\(path)'"), "unavailable")
        XCTAssertGreaterThan(
            try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = '\(path)'"),
            try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = '\(path)'")
        )
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(path)' AND last_capture_id IS NOT NULL"), 1)
    }

    func testMissingCodexPageUsesOneUnavailableDeferralTransaction_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        defer { f.remove() }
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-missing").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: second)
        var commits = 0
        f.probe.action = { commits += 1 }
        let result = try await f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8)).captureOnce(now: 100)
        XCTAssertEqual(result.captured, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE last_error = 'unavailable'"), 2)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 160)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'two.jsonl'"), 160)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        XCTAssertEqual(commits, 3, "claimDirty + one unavailable batch + first privacy reconcile")
    }

    func testCopilotIndexOnlyGroupUsesOneUnavailableDeferralTransaction_repro() async throws {
        let f = try PublicationFixture(sourceName: .copilot)
        defer { f.remove() }
        try FileManager.default.removeItem(at: f.source)
        let checkpoints = f.source.deletingLastPathComponent().appendingPathComponent("checkpoints")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("# no table row\n".utf8).write(to: checkpoints.appendingPathComponent("index.md"))
        try f.markDirty(relativePath: "session-1/checkpoints/index.md")
        var commits = 0
        f.probe.action = { commits += 1 }
        let result = try await f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 2)).captureOnce(now: 100)
        XCTAssertEqual(result.captured, 0)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE last_error = 'unavailable'"), 2)
        XCTAssertEqual(
            try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'session-1/events.jsonl'"),
            160)
        XCTAssertEqual(
            try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'session-1/checkpoints/index.md'"),
            160)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
        XCTAssertEqual(commits, 3, "claimDirty + one unavailable group batch + first privacy reconcile")
    }

    func testMixedCapturedAndNeverCapturedMissingCodexShareOneBatchAndDeadlines_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        defer { f.remove() }
        let first = try await f.worker(Self.captureOnlyEndpoints).captureOnce(now: 100)
        XCTAssertEqual(first.captured, 1)
        try f.markDirty()
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.markDirty(relativePath: "two.jsonl")
        try FileManager.default.removeItem(at: f.source)
        var commits = 0
        f.probe.action = { commits += 1 }
        let result = try await f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8)).captureOnce(now: 200)
        XCTAssertEqual(result.captured, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 201)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'two.jsonl'"), 260)
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = 'one.jsonl'"), "unavailable")
        XCTAssertEqual(try f.text("SELECT last_error FROM collector_locators WHERE relative_path = 'two.jsonl'"), "unavailable")
        XCTAssertGreaterThan(
            try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"),
            try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'")
        )
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'one.jsonl' AND last_capture_id IS NOT NULL"), 1)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'two.jsonl' AND last_capture_id IS NULL"), 1)
        XCTAssertEqual(commits, 2, "claimDirty + one mixed-deadline unavailable batch; privacy already reconciled")
    }

    func testUnavailableBusyRetainsBatchForSameWorkerDrain_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        defer { f.remove() }
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-missing").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: second)
        var commits = 0
        f.probe.action = {
            commits += 1
            if commits == 2 { throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked") }
        }
        let worker = try f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8))
        do {
            _ = try await worker.captureOnce(now: 100)
            XCTFail("busy flush must throw")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_BUSY)
        }
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE retry_not_before IS NOT NULL"), 0)
        f.probe.action = nil
        let drained = try await worker.captureOnce(now: 50)
        XCTAssertEqual(drained.captured, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 160)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'two.jsonl'"), 160)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
    }

    func testUnavailableBusyThenNewerDirtyWakesOnlyThatClaimOnDrain_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        defer { f.remove() }
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-missing").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: second)
        var commits = 0
        f.probe.action = {
            commits += 1
            if commits == 2 { throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked") }
        }
        let worker = try f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8))
        do { _ = try await worker.captureOnce(now: 100); XCTFail("busy flush must throw") }
        catch let error as DatabaseError { XCTAssertEqual(error.resultCode, .SQLITE_BUSY) }
        f.probe.action = nil
        try f.transcript(text: "second-restored").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        let drained = try await worker.captureOnce(now: 50)
        XCTAssertEqual(drained.captured, 1)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 160)
        XCTAssertGreaterThan(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'two.jsonl'"), 0)
        XCTAssertEqual(try f.integer("SELECT COUNT(*) FROM collector_locators WHERE relative_path = 'two.jsonl' AND last_capture_id IS NOT NULL"), 1)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE relative_path = 'one.jsonl' AND acknowledged_revision > 0"), 0)
    }

    func testUnavailableCancellationRetainsBatchForLaterNoncancelledOrNewOwner_repro() async throws {
        let f = try PublicationFixture(sourceName: .codex)
        defer { f.remove() }
        let second = f.sourceRoot.appendingPathComponent("two.jsonl")
        try f.transcript(text: "second-missing").write(to: second)
        XCTAssertEqual(chmod(second.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.removeItem(at: second)
        let handle = PublicationLocked<Task<EngramCollectorCore.CollectorPublicationCycle, Error>?>(nil)
        var commits = 0
        f.probe.action = {
            commits += 1
            if commits == 2 {
                let task = handle.value
                XCTAssertNotNil(task, "the captureOnce task must already be retained")
                task?.cancel()
            }
        }
        let worker = try f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8))
        let captureTask = Task {
            while handle.value == nil { await Task.yield() }
            return try await worker.captureOnce(now: 100)
        }
        handle.change { $0 = captureTask }
        do {
            _ = try await captureTask.value
            XCTFail("cancelled flush must throw")
        } catch is CancellationError {}
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE retry_not_before IS NOT NULL"), 0)
        f.probe.action = nil
        handle.change { $0 = nil }
        let drained = try await worker.captureOnce(now: 50)
        XCTAssertEqual(drained.captured, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 160)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'two.jsonl'"), 160)
        try f.reopen()
        let replacementHandle = PublicationLocked<Task<EngramCollectorCore.CollectorPublicationCycle, Error>?>(nil)
        var laterCommits = 0
        f.probe.action = {
            laterCommits += 1
            if laterCommits == 2 {
                let task = replacementHandle.value
                XCTAssertNotNil(task, "the replacement captureOnce task must already be retained")
                task?.cancel()
            }
        }
        let replacement = try f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8))
        let replacementTask = Task {
            while replacementHandle.value == nil { await Task.yield() }
            return try await replacement.captureOnce(now: 300)
        }
        replacementHandle.change { $0 = replacementTask }
        do {
            _ = try await replacementTask.value
            XCTFail("cancelled replacement flush must throw")
        } catch is CancellationError {}
        try f.reopen()
        f.probe.action = nil
        let recovered = try await f.worker(Self.captureOnlyEndpoints, budget: .init(maxCaptureFiles: 8)).captureOnce(now: 300)
        XCTAssertEqual(recovered.captured, 0)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'one.jsonl'"), 360)
        XCTAssertEqual(try f.integer("SELECT retry_not_before FROM collector_locators WHERE relative_path = 'two.jsonl'"), 360)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
    }

    func testEndpointConfigurationRejectsCredentialAndOriginAliasing() throws {
        let f = try PublicationFixture()
        defer { f.remove() }
        let good: [EngramCollectorCore.CollectorReplicaEndpoint] = [
            .init(replicaID: "hq", baseURL: URL(string: "https://hq.example")!, bearerToken: "hq-test"),
            .init(replicaID: "m1", baseURL: URL(string: "https://m1.example")!, bearerToken: "m1-test"),
        ]
        for invalid in [
            [good[0]],
            [good[0], good[0]],
            [good[0], .init(replicaID: "m1", baseURL: good[0].baseURL, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: good[1].baseURL, bearerToken: "hq-test")],
            [good[0], .init(replicaID: "m1", baseURL: URL(string: "http://public.example")!, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: URL(string: "https://user:pass@m1.example")!, bearerToken: "m1-test")],
            [good[0], .init(replicaID: "m1", baseURL: good[1].baseURL, bearerToken: "bad\r\nHeader: value")],
        ] {
            XCTAssertThrowsError(try f.worker(invalid)) { XCTAssertEqual($0 as? WorkerError, .invalidConfiguration) }
        }
    }

    func testFDAdmissionRejectsChangedSecondGenerationBeforeAnyAdditionalCASWrite() async throws {
        for growsBeyondRemainingBudget in [false, true] {
            let publishedObjects = PublicationLocked(0)
            let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterFinalLinkPublished: { url in
                if url.pathExtension != "json" { publishedObjects.change { $0 += 1 } }
            })
            let f = try PublicationFixture(casTestHooks: casHooks)
            let replicas = try await replicas(for: f)
            let original = try Data(contentsOf: f.source)
            let second = f.sourceRoot.appendingPathComponent("two.jsonl")
            try original.write(to: second)
            XCTAssertEqual(chmod(second.path, 0o600), 0)
            try f.markDirty(relativePath: "two.jsonl")
            var budget = EngramCollectorCore.CollectorPublicationBudget()
            budget.maxCaptureFiles = 2
            budget.maxCaptureBytes = Int64(original.count * 2)
            let reached = PublicationLocked(false)
            let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCaptureFDAdmission: { reservation in
                guard reservation.relativePath == "two.jsonl" else { return }
                // The first file already consumed N of the 2N cycle budget.
                // Mutate the second only after its final path preflight, but
                // before the actual capturer opens and admits its descriptor.
                let text = growsBeyondRemainingBudget
                    ? String(repeating: "x", count: original.count / 2 + "synthetic capture".utf8.count)
                    : "different capture"
                let changed = try f.transcript(text: text)
                if growsBeyondRemainingBudget {
                    XCTAssertGreaterThan(changed.count, original.count)
                    XCTAssertLessThan(changed.count, original.count * 2)
                } else { XCTAssertEqual(changed.count, original.count) }
                try changed.write(to: second)
                XCTAssertEqual(chmod(second.path, 0o600), 0)
                try f.markDirty(relativePath: "two.jsonl")
                reached.change { $0 = true }
            })
            let cycle = try await f.worker(replicas.endpoints, budget: budget, hooks: hooks).runOnce(now: 100)
            XCTAssertTrue(reached.value, "the actual preflight-to-FD gap must be exercised")
            XCTAssertEqual(cycle.captured, 1)
            XCTAssertEqual(cycle.acknowledgedHQ, 1)
            XCTAssertEqual(cycle.acknowledgedM1, 1)
            let durable = try f.catalog.unboundCaptures(limit: 8)
            XCTAssertEqual(durable.count, 1, "FD admission must reject the changed generation before catalog commit")
            XCTAssertEqual(durable.first?.locator, f.source.path)
            XCTAssertEqual(publishedObjects.value, 1, "only the already admitted first source may publish CAS bytes")
            XCTAssertEqual(try f.owner.publicationIntents(limit: 8).count, 1)
            XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'two.jsonl'"), 0)
            await replicas.stop()
        }
    }

    func testCASVolumePressureBlocksCaptureEvenWhenOwnerVolumeHasSpace() async throws {
        let fixture = PublicationLocked<PublicationFixture?>(nil)
        let queried = PublicationLocked(0)
        let casHooks = EngramCollectorCore.ImmutableArchiveCASTestHooks(afterVolumeStat: { descriptor, measured in
            guard let f = fixture.value else { throw PublicationFixture.Failure.unsafeFixture }
            var opened = stat()
            var actualCAS = stat()
            var volume = statfs()
            XCTAssertEqual(fstat(descriptor, &opened), 0)
            XCTAssertEqual(lstat(f.captureRoot.path, &actualCAS), 0)
            XCTAssertEqual(fstatfs(descriptor, &volume), 0)
            XCTAssertEqual(opened.st_dev, actualCAS.st_dev)
            XCTAssertEqual(opened.st_ino, actualCAS.st_ino)
            XCTAssertGreaterThanOrEqual(measured, 0)
            queried.change { $0 += 1 }
            return 0
        })
        let f = try PublicationFixture(casTestHooks: casHooks)
        fixture.change { $0 = f }
        defer { fixture.change { $0 = nil } }
        let replicas = try await replicas(for: f)
        XCTAssertNotEqual(f.shadow.path, f.captureRoot.path)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.minimumFreeDiskBytes = 1
        XCTAssertGreaterThan(try f.owner.availableSpoolBytes(), budget.minimumFreeDiskBytes,
            "the owner volume must independently pass admission in this fixture")
        let requests = PublicationLocked(0)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in
            requests.change { $0 += 1 }
        })
        let original = try Data(contentsOf: f.source)
        let cycle = try await f.worker(replicas.endpoints, budget: budget, hooks: hooks).runOnce(now: 100)
        XCTAssertGreaterThan(queried.value, 0, "budget admission must query the actual CAS root descriptor")
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
        XCTAssertEqual(requests.value, 0)
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        XCTAssertTrue(try f.owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'one.jsonl'"), 0)
        XCTAssertEqual(try Data(contentsOf: f.source), original)
        await replicas.stop()
    }

    func testMissingIntermediateDirectoryDoesNotStarveAnotherDirtyFileInRoot() async throws {
        let f = try PublicationFixture()
        let replicas = try await replicas(for: f)
        let original = try Data(contentsOf: f.source)
        let nested = f.sourceRoot.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let nestedSource = nested.appendingPathComponent("one.jsonl")
        try original.write(to: nestedSource)
        XCTAssertEqual(chmod(nestedSource.path, 0o600), 0)
        try f.markDirty(relativePath: "nested/one.jsonl")
        try FileManager.default.removeItem(at: f.source)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        let interrupted = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeCapture: { reservation in
            XCTAssertEqual(reservation.relativePath, "nested/one.jsonl")
            throw PublicationFixture.Failure.injected
        })
        do { _ = try await f.worker(replicas.endpoints, budget: budget, hooks: interrupted).runOnce(now: 100); XCTFail("nested reservation interruption ignored") }
        catch { XCTAssertEqual(error as? PublicationFixture.Failure, .injected) }
        XCTAssertEqual(try f.owner.captureReservations(limit: 8).first?.relativePath, "nested/one.jsonl")
        XCTAssertTrue(try f.catalog.unboundCaptures(limit: 8).isEmpty)
        // Removing the intermediate directory exercises openComponent ENOENT,
        // not the separate final-leaf POSIX ENOENT regression above.
        try FileManager.default.removeItem(at: nested)
        let other = f.sourceRoot.appendingPathComponent("two.jsonl")
        try original.write(to: other)
        XCTAssertEqual(chmod(other.path, 0o600), 0)
        try f.markDirty(relativePath: "two.jsonl")
        let worker = try f.worker(replicas.endpoints, budget: budget)
        var captured = 0
        var acknowledgedHQ = 0
        var acknowledgedM1 = 0
        for now: Int64 in [101, 102, 103, 104, 105] {
            let cycle = try await worker.runOnce(now: now)
            captured += cycle.captured
            acknowledgedHQ += cycle.acknowledgedHQ
            acknowledgedM1 += cycle.acknowledgedM1
        }
        XCTAssertEqual(captured, 1, "a missing intermediate directory must not pin its root's reservation")
        XCTAssertEqual(acknowledgedHQ, 1)
        XCTAssertEqual(acknowledgedM1, 1)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.relativePath, "two.jsonl")
        XCTAssertEqual(try f.integer("SELECT acknowledged_revision FROM collector_locators WHERE relative_path = 'nested/one.jsonl'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.path))
        await replicas.stop()
    }

    func testForcedCustomClaudeProfileProofIsFormatBound() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        let replicas = try await replicas(for: f)
        try f.writeBytes(try minimaxClaudeTranscript(cwd: f.project.path, text: "custom-profile-minimax"))
        try f.markDirty()
        let captured = try f.capture()
        let forced = EngramCollectorCore.SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: true)
        let defaultProfile = EngramCollectorCore.SourceMetadataProjection.Format.claudeCode(forceClaudeCodeSource: false)
        let policy = f.policy.value
        let assessment = try EngramCollectorCore.CollectorPrivacyProof.assess(
            capture: captured, cas: f.cas, format: forced, policy: policy)
        guard case .eligible(let proof) = assessment else {
            XCTFail("existing forced-profile policy must keep MiniMax eligible as claude-code")
            return
        }
        XCTAssertEqual(proof.source, .claudeCode)
        XCTAssertTrue(proof.isCurrent(for: captured, policy: policy, format: forced))
        XCTAssertFalse(proof.isCurrent(for: captured, policy: policy, format: defaultProfile),
            "a cached custom-profile proof must not remain current after parseFormat flips to default")
        XCTAssertEqual(
            try EngramCollectorCore.CollectorPrivacyProof.assess(
                capture: captured, cas: f.cas, format: defaultProfile, policy: policy),
            .withheld(.conflictingSourceIdentity))
        let cycle = try await f.worker(
            replicas.endpoints,
            formats: [f.configuration.rootID: forced]
        ).runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 1)
        XCTAssertEqual(cycle.acknowledgedM1, 1)
        let hqRecords = try await replicas.hq.publications()
        let m1Records = try await replicas.m1.publications()
        XCTAssertEqual(hqRecords.count, 1)
        XCTAssertEqual(m1Records.count, 1)
        await replicas.stop()
    }

    func testDefaultClaudeProfileMiniMaxRemainsWithheldAndIsNotRelabeled() async throws {
        let f = try PublicationFixture(sourceName: .claudeCode)
        try f.writeBytes(try minimaxClaudeTranscript(cwd: f.project.path, text: "default-profile-minimax"))
        try f.markDirty()
        let replicas = try await replicas(for: f)
        let requests = PublicationLocked(0)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(beforeRequest: { _, _ in
            requests.change { $0 += 1 }
        })
        let cycle = try await f.worker(replicas.endpoints, hooks: hooks).runOnce(now: 100)
        XCTAssertEqual(cycle.captured, 1)
        XCTAssertEqual(cycle.acknowledgedHQ, 0)
        XCTAssertEqual(cycle.acknowledgedM1, 0)
        XCTAssertEqual(requests.value, 0)
        let hqRecords = try await replicas.hq.publications()
        let m1Records = try await replicas.m1.publications()
        XCTAssertEqual(hqRecords.count, 0)
        XCTAssertEqual(m1Records.count, 0)
        await replicas.stop()
    }

    // Held-open Cursor WAL / missing FSEvent (binary retain
    // .engram-runtime-test-3DDB9E51-2CBE-40DA-A9C8-17B71923C7B9).
    // Passive metadata repair must dirty a clean last_capture_id from
    // descriptor-relative member stats once per 1000ms without events.
    func testCursorHeldOpenWALOnlyChangePublishesBothReplicasWithoutEventOrChmod_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        try writeCursorSessionMeta(nextTo: f.source, cwd: f.project.path, name: "Store title")
        let writer = try openHeldCursorWALWriter(at: f.source)
        defer { try? writer.close() }
        let replicas = try await replicas(for: f)
        let worker = try f.worker(replicas.endpoints)
        let wal = URL(fileURLWithPath: f.source.path + "-wal")
        let initial = try await worker.runOnce(now: 100)
        XCTAssertEqual(initial.captured, 1)
        XCTAssertEqual(initial.acknowledgedHQ, 1)
        XCTAssertEqual(initial.acknowledgedM1, 1)
        let first = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let replicaCount1 = try await replicas.hq.publications().count
        XCTAssertEqual(replicaCount1, 1)
        let replicaCount2 = try await replicas.m1.publications().count
        XCTAssertEqual(replicaCount2, 1)
        let firstWAL = try Data(contentsOf: wal)
        XCTAssertFalse(firstWAL.isEmpty, "the held writer must actually be in WAL mode before the idle/update window")
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: 101)
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: 102)
        XCTAssertEqual(try Data(contentsOf: wal), firstWAL)
        let walStatBefore = try FileManager.default.attributesOfItem(atPath: wal.path)
        try updateHeldCursorStoreTitle(writer, cwd: f.project.path, name: "WAL store title")
        let secondWAL = try Data(contentsOf: wal)
        XCTAssertNotEqual(secondWAL, firstWAL, "generation-2 UPDATE must stay in the held-open WAL")
        let walStatAfter = try FileManager.default.attributesOfItem(atPath: wal.path)
        let walStatChanged = walStatBefore[.size] as? NSNumber != walStatAfter[.size] as? NSNumber
            || walStatBefore[.modificationDate] as? Date != walStatAfter[.modificationDate] as? Date
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
        var now: Int64 = 103
        let published = try await runCursorWorkerUntilPublicationCount(
            worker, fixture: f, count: 2, now: &now, step: 1, attempts: 8
        )
        XCTAssertTrue(
            published,
            "WAL-only bytes must publish without chmod, close, or a manual event (WAL stat changed: \(walStatChanged))"
        )
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 2)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 2)
        XCTAssertEqual(intents.first?.digest, first.digest)
        let second = try XCTUnwrap(intents.dropFirst().first)
        XCTAssertNotEqual(second.captureID, first.captureID)
        XCTAssertNotEqual(second.publication.manifestSHA256, first.publication.manifestSHA256)
        XCTAssertGreaterThan(second.publication.sequence, first.publication.sequence)
        let replicaCount3 = try await replicas.hq.publications().count
        XCTAssertEqual(replicaCount3, 2)
        let replicaCount4 = try await replicas.m1.publications().count
        XCTAssertEqual(replicaCount4, 2)
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: now)
        await replicas.stop()
    }

    func testCursorUnchangedIdleAndMetadataOnlyChangeWithoutEventPublish_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        try writeCursorSessionMeta(nextTo: f.source, cwd: f.project.path, name: "meta-one")
        let writer = try openHeldCursorWALWriter(at: f.source)
        defer { try? writer.close() }
        let replicas = try await replicas(for: f)
        let worker = try f.worker(replicas.endpoints)
        let initial = try await worker.runOnce(now: 100)
        XCTAssertEqual(initial.captured, 1)
        XCTAssertEqual(initial.acknowledgedHQ, 1)
        XCTAssertEqual(initial.acknowledgedM1, 1)
        let first = try XCTUnwrap(f.owner.publicationIntents(limit: 8).first)
        let wal = try Data(contentsOf: URL(fileURLWithPath: f.source.path + "-wal"))
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: 101)
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: 102)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.source.path + "-wal")), wal)
        try writeCursorSessionMeta(nextTo: f.source, cwd: f.project.path, name: "meta-two")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
        var now: Int64 = 103
        let published = try await runCursorWorkerUntilPublicationCount(
            worker, fixture: f, count: 2, now: &now, step: 1, attempts: 8
        )
        XCTAssertTrue(published, "metadata-only member change must publish without an event")
        let second = try XCTUnwrap(f.owner.publicationIntents(limit: 8).last)
        XCTAssertNotEqual(second.captureID, first.captureID)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
        let replicaCount5 = try await replicas.hq.publications().count
        XCTAssertEqual(replicaCount5, 2)
        let replicaCount6 = try await replicas.m1.publications().count
        XCTAssertEqual(replicaCount6, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.source.path + "-wal")), wal)
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: now)
        await replicas.stop()
    }

    func testCursorKnownLocatorPagerRotatesTwoSessionsWithinCaptureFileBudget_repro() async throws {
        let f = try PublicationFixture(sourceName: .cursor)
        try writeCursorSessionMeta(nextTo: f.source, cwd: f.project.path, name: "one")
        let firstWriter = try openHeldCursorWALWriter(at: f.source)
        defer { try? firstWriter.close() }
        let secondStore = f.sourceRoot.appendingPathComponent("chats/ws/native-two/store.db")
        try writeCursorStore(at: secondStore, cwd: f.project.path, text: "second session")
        try writeCursorSessionMeta(nextTo: secondStore, cwd: f.project.path, name: "two")
        let secondWriter = try openHeldCursorWALWriter(at: secondStore)
        defer { try? secondWriter.close() }
        try f.markDirty(relativePath: "chats/ws/native-two/store.db")
        let replicas = try await replicas(for: f)
        var budget = EngramCollectorCore.CollectorPublicationBudget()
        budget.maxCaptureFiles = 1
        let worker = try f.worker(replicas.endpoints, budget: budget)
        var now: Int64 = 100
        let enrolled = try await runCursorWorkerUntilPublicationCount(worker, fixture: f, count: 2, now: &now, step: 1, attempts: 8)
        XCTAssertTrue(enrolled, "manual dirty enrollment must capture both known sessions before the pager window")
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
        let afterEnrollment = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(Set(afterEnrollment.map(\.relativePath)).count, 2)
        now = 110
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: now)
        now += 1
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: now)
        let secondWAL = URL(fileURLWithPath: secondStore.path + "-wal")
        let firstWAL = URL(fileURLWithPath: f.source.path + "-wal")
        let stableFirstWAL = try Data(contentsOf: firstWAL)
        let beforeSecondWAL = try Data(contentsOf: secondWAL)
        try updateHeldCursorStoreTitle(secondWriter, cwd: f.project.path, name: "two-wal")
        XCTAssertNotEqual(try Data(contentsOf: secondWAL), beforeSecondWAL)
        XCTAssertEqual(try Data(contentsOf: firstWAL), stableFirstWAL)
        now += 1
        let published = try await runCursorWorkerUntilPublicationCount(
            worker, fixture: f, count: 3, now: &now, step: 1, attempts: 8
        )
        XCTAssertTrue(published, "maxCaptureFiles=1 must still rotate onto the changed known locator")
        let intents = try f.owner.publicationIntents(limit: 8)
        XCTAssertEqual(intents.count, 3)
        XCTAssertEqual(intents.filter { $0.relativePath == "chats/ws/native-two/store.db" }.count, 2)
        XCTAssertEqual(intents.filter { $0.relativePath == f.sourceRelativePath }.count, 1)
        XCTAssertEqual(try Data(contentsOf: firstWAL), stableFirstWAL)
        XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 6)
        let replicaCount7 = try await replicas.hq.publications().count
        XCTAssertEqual(replicaCount7, 3)
        let replicaCount8 = try await replicas.m1.publications().count
        XCTAssertEqual(replicaCount8, 3)
        try await assertCursorStableObservationsDoNotReserve(worker, fixture: f, now: now)
        await replicas.stop()
    }

    private func openHeldCursorWALWriter(at store: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: store.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
                try db.execute(sql: "PRAGMA user_version=7")
            }
        } catch {
            try? queue.close()
            throw error
        }
        return queue
    }

    private func updateHeldCursorStoreTitle(_ writer: DatabaseQueue, cwd: String, name: String) throws {
        let stored = try JSONSerialization.data(withJSONObject: ["cwd": cwd, "name": name], options: [.sortedKeys])
        let hex = stored.map { String(format: "%02x", $0) }.joined()
        try writer.write { db in
            try db.execute(sql: "UPDATE meta SET value = ? WHERE key = '0'", arguments: [hex])
        }
    }

    private func writeCursorSessionMeta(nextTo store: URL, cwd: String, name: String) throws {
        try JSONSerialization.data(withJSONObject: ["cwd": cwd, "name": name], options: [.sortedKeys])
            .write(to: store.deletingLastPathComponent().appendingPathComponent("meta.json"))
    }

    private func writeCursorStore(at store: URL, cwd: String, text: String) throws {
        try FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stored = try JSONSerialization.data(withJSONObject: ["cwd": cwd], options: [.sortedKeys])
        let hex = stored.map { String(format: "%02x", $0) }.joined()
        let queue = try DatabaseQueue(path: store.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: """
                    PRAGMA journal_mode=DELETE;
                    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                    CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY, data BLOB);
                    """)
                try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('0', ?)", arguments: [hex])
                try db.execute(sql: "INSERT INTO blobs(id, data) VALUES ('user', ?)", arguments: [
                    try JSONSerialization.data(withJSONObject: ["role": "user", "content": text], options: [.sortedKeys])
                ])
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
        guard chmod(store.path, 0o600) == 0 else { throw PublicationFixture.Failure.unsafeFixture }
        for sidecar in [store.path + "-wal", store.path + "-shm", store.path + "-journal"]
        where FileManager.default.fileExists(atPath: sidecar) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: sidecar))
        }
    }

    private struct PairedCursorLegacyPeer {
        let legacy: EngramCollectorCore.CollectorRootConfiguration
        let modern: EngramCollectorCore.CollectorRootConfiguration
    }

    private func writeEmptyCursorLegacyState(_ fixture: PublicationFixture) throws {
        let database = fixture.sourceRoot.appendingPathComponent("state.vscdb")
        let queue = try DatabaseQueue(path: database.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);")
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
        guard chmod(database.path, 0o600) == 0 else { throw PublicationFixture.Failure.unsafeFixture }
    }

    private func enrollPairedCursorLegacyPeer(
        _ fixture: PublicationFixture, inventoryModern: Bool = true
    ) throws -> PairedCursorLegacyPeer {
        let modernRoot = fixture.base.appendingPathComponent("modern-cursor")
        try FileManager.default.createDirectory(
            at: modernRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let modern = EngramCollectorCore.CollectorRootConfiguration(
            rootID: "peer-modern", source: .cursor, rootPath: modernRoot.path, revision: 1)
        let legacy = EngramCollectorCore.CollectorRootConfiguration(
            rootID: fixture.configuration.rootID, source: .cursor, rootPath: fixture.sourceRoot.path,
            revision: 2, cursorLegacy: true, cursorModernRootID: modern.rootID)
        if inventoryModern {
            _ = try fixture.owner.enrollAndActivateRoot(modern)
            try fixture.markDirty(configuration: modern, relativePath: "chats/ws/placeholder/store.db")
        }
        _ = try fixture.owner.enrollAndActivateRoot(legacy)
        return .init(legacy: legacy, modern: modern)
    }

    private func assertCursorStableObservationsDoNotReserve(
        _ worker: PublicationWorker, fixture: PublicationFixture, now: Int64
    ) async throws {
        let publications = try fixture.integer("SELECT count(*) FROM collector_publications")
        let acknowledged = try fixture.integer(
            "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"
        )
        let cycle = try await worker.runOnce(now: now)
        XCTAssertEqual(cycle.captured, 0)
        XCTAssertEqual(cycle.recovered, 0)
        XCTAssertEqual(cycle.deferred, 0)
        XCTAssertTrue(try fixture.owner.captureReservations(limit: 8).isEmpty)
        XCTAssertEqual(
            try fixture.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"),
            0
        )
        XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publications"), publications)
        XCTAssertEqual(
            try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"),
            acknowledged
        )
    }

    private func runCursorWorkerUntilPublicationCount(
        _ worker: PublicationWorker, fixture: PublicationFixture, count: Int,
        now: inout Int64, step: Int64, attempts: Int
    ) async throws -> Bool {
        for _ in 0..<attempts {
            _ = try await worker.runOnce(now: now)
            if try fixture.integer("SELECT count(*) FROM collector_publications") >= count { return true }
            now += step
        }
        return false
    }

    private func minimaxClaudeTranscript(cwd: String, text: String) throws -> Data {
        let row: [String: Any] = [
            "type": "assistant", "sessionId": "native-one", "cwd": cwd,
            "message": ["model": "MiniMax-M2.1", "content": text],
        ]
        return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
    }

    private static let captureOnlyEndpoints: [EngramCollectorCore.CollectorReplicaEndpoint] = [
        .init(replicaID: "hq", baseURL: URL(string: "https://hq.example")!, bearerToken: "hq-test"),
        .init(replicaID: "m1", baseURL: URL(string: "https://m1.example")!, bearerToken: "m1-test"),
    ]

    private func replicas(for fixture: PublicationFixture, hqPublicationsEnabled: Bool = true) async throws -> PublicationReplicas {
        do {
            let replicas = try await PublicationReplicas.start(in: fixture.base, hqPublicationsEnabled: hqPublicationsEnabled)
            // Async teardown runs even when the notImplemented RED path throws.
            // Join both actual server tasks before removing their owned stores.
            addTeardownBlock {
                await replicas.stop()
                fixture.remove()
            }
            return replicas
        } catch {
            fixture.remove()
            throw error
        }
    }
}

/// Bounded poll for test latches. Avoids unbounded sleeps and lone Task.yield assumptions.
private func publicationWaitUntil(_ timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.001)
    }
    return predicate()
}

private struct PublicationRecoveryCheckpoint: Codable {
    let reservationID: String
    let boundaryTime: String
    let boundaryID: String
    let afterTime: String
    let afterID: String
}

private final class DiscoverModernCounts: @unchecked Sendable {
    private let observationCount = PublicationLocked(0)
    private let captureCount = PublicationLocked(0)
    var observations: Int { observationCount.value }
    var captures: Int { captureCount.value }
    var hooks: EngramCollectorCore.CollectorPublicationWorkerTestHooks {
        .init(beforeDiscoverModern: { [observationCount, captureCount] _, purpose in
            switch purpose {
            case .observationHint: observationCount.change { $0 += 1 }
            case .captureAuthorization: captureCount.change { $0 += 1 }
            }
        })
    }
}

private final class PublicationLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private final class PublicationProbe {
    var action: (() throws -> Void)?
}

private final class PublicationFixture: @unchecked Sendable {
    enum Failure: Error, Equatable { case injected, unsafeFixture }
    static let machine = "11111111-2222-3333-4444-555555555555"
    let base: URL
    let shadow: URL
    let captureRoot: URL
    let identity: URL
    let sourceRoot: URL
    let project: URL
    let source: URL
    let sourceName: EngramCollectorCore.SourceName
    let usesLegacySourceRoot: Bool
    var catalog: EngramCollectorCore.ArchiveCatalog
    let cas: EngramCollectorCore.ImmutableArchiveCAS
    let policy: PublicationLocked<EngramCollectorCore.CollectorPrivacyPolicy>
    let probe: PublicationProbe
    var owner: EngramCollectorCore.CollectorInventoryOwner!
    var rootRevision: Int64 = 1
    var configuration: EngramCollectorCore.CollectorRootConfiguration {
        .init(rootID: "synthetic-codex-root", source: sourceName, rootPath: sourceRoot.path, revision: rootRevision, cursorLegacy: usesLegacySourceRoot)
    }
    var inventory: URL { shadow.appendingPathComponent("inventory/inventory.sqlite") }
    var sourceRelativePath: String { Self.sourceRelativePath(for: sourceName) }
    private static func sourceRelativePath(for sourceName: EngramCollectorCore.SourceName) -> String {
        switch sourceName {
        case .cline: return "task-native/claude_messages.json"
        case .kimi: return "workspace/native-one/context.jsonl"
        case .opencode: return "opencode.db"
        case .copilot: return "session-1/events.jsonl"
        case .geminiCli: return "project/chats/stem.json"
        case .cursor: return "chats/ws/native-one/store.db"
        case .grok: return "native-project/019dd6e3-91d1-7326-8299-314858773a0e/chat_history.jsonl"
        default: return "one.jsonl"
        }
    }
    var geminiRegistry: URL { base.appendingPathComponent("projects.json") }
    var kimiRegistry: URL { base.appendingPathComponent("kimi.json") }
    var workspaceStorage: URL { sourceRoot.deletingLastPathComponent().appendingPathComponent("workspaceStorage") }
    var alternateProject: URL { base.appendingPathComponent("project-other") }

    init(probe: PublicationProbe = .init(), casTestHooks: EngramCollectorCore.ImmutableArchiveCASTestHooks = .init(),
         sourceName: EngramCollectorCore.SourceName = .codex, legacySourceRoot: Bool = false) throws {
        if let expectedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == expectedHome else {
                throw Failure.unsafeFixture
            }
        }
        self.probe = probe
        self.sourceName = sourceName
        self.usesLegacySourceRoot = legacySourceRoot
        guard !legacySourceRoot || sourceName == .cursor else { throw Failure.unsafeFixture }
        // Every opened root is an explicit test-owned checkout child. This does
        // not discover source paths under the real home, including on CI where
        // the optional local Foundation-home diagnostic is not configured.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureBase = checkout.appendingPathComponent(".engram-publication-test-\(UUID().uuidString)")
        base = fixtureBase
        var completed = false
        // Captures only this invocation's exact local path, not a glob or an
        // incompletely initialized self. Previous failed fixtures are evidence.
        defer { if !completed { try? FileManager.default.removeItem(at: fixtureBase) } }
        shadow = base.appendingPathComponent("shadow")
        captureRoot = base.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        sourceRoot = legacySourceRoot
            ? base.appendingPathComponent("User").appendingPathComponent("globalStorage")
            : base.appendingPathComponent("sources")
        project = base.appendingPathComponent("project")
        source = sourceRoot.appendingPathComponent(Self.sourceRelativePath(for: sourceName))
        var directories = [base, shadow, captureRoot, identity.deletingLastPathComponent(), project]
        if legacySourceRoot {
            directories += [
                sourceRoot.deletingLastPathComponent(),
                sourceRoot,
                sourceRoot.deletingLastPathComponent().appendingPathComponent("workspaceStorage"),
                base.appendingPathComponent("project-other"),
            ]
        } else {
            directories.append(sourceRoot)
        }
        for url in directories {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        if !legacySourceRoot, sourceName == .cline || sourceName == .copilot || sourceName == .geminiCli || sourceName == .kimi || sourceName == .cursor || sourceName == .grok {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Both identity readers see closed rollback-journal identity fixtures.
        // The active capture writer's WAL/SHM must never pass as this authority.
        for identityURL in [identity, shadow.appendingPathComponent("archive.sqlite")] {
            let identityQueue = try DatabaseQueue(path: identityURL.path)
            do {
                try identityQueue.write { db in
                    try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                    try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machine])
                }
                try identityQueue.close()
            } catch {
                try? identityQueue.close()
                throw error
            }
            guard chmod(identityURL.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        }
        catalog = try EngramCollectorCore.ArchiveCatalog(root: captureRoot, machineID: Self.machine)
        try catalog.migrate()
        cas = try EngramCollectorCore.ImmutableArchiveCAS(root: captureRoot, testHooks: casTestHooks)
        policy = PublicationLocked(try .init(revision: 1, excludedProjectRoots: [], allowedSources: [.cline, .copilot, .geminiCli, .opencode, .kimi, .cursor, .grok, .pi].contains(sourceName) ? [sourceName] : [.claudeCode, .codex]))
        do {
            if !legacySourceRoot {
                try writeTranscript()
                if sourceName == .geminiCli { try writeGeminiRegistry(cwd: project.path) }
                if sourceName == .kimi {
                    try JSONSerialization.data(withJSONObject: ["work_dirs": [["path": project.path,
                        "last_session_id": "native-one"]]]).write(to: kimiRegistry)
                }
                if sourceName == .copilot {
                    try Data("id: native-one\ncwd: \(project.path)\nsummary: first version\n".utf8)
                        .write(to: source.deletingLastPathComponent().appendingPathComponent("workspace.yaml"))
                }
                if sourceName == .grok {
                    try writeGrokAuxiliaries(segment: Data("# first archive\n".utf8))
                }
            }
            try reopen()
            if !legacySourceRoot { try markDirty() }
            completed = true
        } catch {
            try? owner?.close()
            throw error
        }
    }

    func reopen() throws {
        try owner?.close()
        owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
            shadowRoot: shadow, identityCatalog: identity, ownerRunID: UUID().uuidString,
            testHooks: .init(beforeInventoryCommit: { [probe] in try probe.action?() })))
        _ = try owner.enrollAndActivateRoot(configuration)
    }

    func reopenOwnerAndCatalog() throws {
        try catalog.close()
        catalog = try EngramCollectorCore.ArchiveCatalog(root: captureRoot, machineID: Self.machine)
        try catalog.migrate()
        try reopen()
    }

    func remove() {
        probe.action = nil
        do {
            try catalog.close()
            try owner?.close()
            try FileManager.default.removeItem(at: base)
        } catch {
            XCTFail("Publication fixture retained at \(base.path): \(error)")
        }
    }

    func writeGeminiRegistry(cwd: String) throws {
        try JSONSerialization.data(withJSONObject: ["projects": [cwd: "project"]], options: [.sortedKeys])
            .write(to: geminiRegistry)
    }

    func transcript(text: String = "synthetic capture", cwd: String? = nil) throws -> Data {
        if sourceName == .cline {
            let request = try JSONSerialization.data(withJSONObject: ["request": "Current Working Directory (\(cwd ?? project.path)) Files"])
            return try JSONSerialization.data(withJSONObject: [
                ["say": "task", "text": text, "ts": 1780000000000],
                ["say": "api_req_started", "text": String(decoding: request, as: UTF8.self), "ts": 1780000000001],
                ["say": "text", "text": "answer", "ts": 1780000000002],
            ], options: [.sortedKeys])
        }
        if sourceName == .kimi {
            return try JSONSerialization.data(withJSONObject: ["role": "user", "content": text]) + Data([10])
        }
        if sourceName == .geminiCli {
            return try JSONSerialization.data(withJSONObject: ["sessionId": "native-one",
                "startTime": "2026-09-08T00:00:00Z", "lastUpdated": "2026-09-08T00:00:02Z",
                "messages": [["type": "user", "content": text, "timestamp": "2026-09-08T00:00:01Z"]]], options: [.sortedKeys])
        }
        if sourceName == .copilot {
            let records: [[String: Any]] = [
                ["type": "session.start", "timestamp": "2026-09-08T00:00:00Z", "data": ["context": ["cwd": cwd ?? project.path]]],
                ["type": "user.message", "timestamp": "2026-09-08T00:00:01Z", "data": ["content": text]],
            ]
            return try records.reduce(into: Data()) { bytes, row in
                bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10)
            }
        }
        if sourceName == .pi {
            let session: [String: Any] = [
                "type": "session", "id": "native-one",
                "cwd": cwd ?? project.path, "timestamp": "2026-04-29T01:00:00.000Z",
            ]
            let message: [String: Any] = [
                "type": "message", "id": "msg-user",
                "message": ["role": "user", "content": [["type": "text", "text": text]]],
            ]
            return try [session, message].reduce(into: Data()) { bytes, row in
                bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                bytes.append(10)
            }
        }
        if sourceName == .grok {
            return Data("{\"type\":\"user\",\"content\":\"<user_query>Inspect</user_query>\"}\n".utf8)
        }
        if sourceName == .claudeCode {
            let row: [String: Any] = [
                "type": "assistant", "sessionId": "native-one", "cwd": cwd ?? project.path,
                "message": ["model": "claude-sonnet-4", "content": text],
            ]
            return try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
        }
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "native-one", "cwd": cwd ?? project.path]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]],
        ]
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        return data
    }

    func writeTranscript(text: String = "synthetic capture", cwd: String? = nil) throws {
        if sourceName == .cursor {
            let stored = try JSONSerialization.data(withJSONObject: ["cwd": cwd ?? project.path], options: [.sortedKeys])
            let hex = stored.map { String(format: "%02x", $0) }.joined()
            let queue = try DatabaseQueue(path: source.path)
            do {
                try queue.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA journal_mode=DELETE")
                    try db.execute(sql: """
                        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                        CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY, data BLOB);
                        DELETE FROM meta; DELETE FROM blobs;
                        """)
                    try db.execute(sql: "INSERT INTO meta(key, value) VALUES ('0', ?)", arguments: [hex])
                    try db.execute(sql: "INSERT INTO blobs(id, data) VALUES ('user', ?)", arguments: [
                        try JSONSerialization.data(withJSONObject: ["role": "user", "content": text], options: [.sortedKeys])
                    ])
                }
                try queue.close()
            } catch {
                try? queue.close()
                throw error
            }
            guard chmod(source.path, 0o600) == 0 else { throw Failure.unsafeFixture }
            for sidecar in [source.path + "-wal", source.path + "-shm", source.path + "-journal"] {
                if FileManager.default.fileExists(atPath: sidecar) {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: sidecar))
                }
            }
            return
        }
        if sourceName == .opencode {
            let queue = try DatabaseQueue(path: source.path)
            defer { try? queue.close() }
            let payload = try JSONSerialization.data(withJSONObject: ["type": "text", "text": text], options: [.sortedKeys])
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS session(id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER, time_updated INTEGER);
                    CREATE TABLE IF NOT EXISTS message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                    CREATE TABLE IF NOT EXISTS part(id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
                    """)
                try db.execute(sql: "INSERT OR REPLACE INTO session VALUES ('native-one', ?, 100, 200)", arguments: [cwd ?? project.path])
                try db.execute(sql: "INSERT OR REPLACE INTO message VALUES ('message-one', 'native-one', 100, ?)", arguments: ["{\"role\":\"user\"}"])
                try db.execute(sql: "INSERT OR REPLACE INTO part VALUES ('part-one', 'message-one', 100, ?)", arguments: [String(decoding: payload, as: UTF8.self)])
            }
            return
        }
        try writeBytes(transcript(text: text, cwd: cwd))
    }

    func writeBytes(_ bytes: Data) throws {
        try bytes.write(to: source)
        guard chmod(source.path, 0o600) == 0 else { throw Failure.unsafeFixture }
    }

    func writeGrokAuxiliaries(segment: Data) throws {
        let session = source.deletingLastPathComponent()
        let compaction = session.appendingPathComponent("compaction")
        try FileManager.default.createDirectory(
            at: compaction, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let files: [(URL, Data)] = [
            (session.appendingPathComponent("updates.jsonl"), Data("{\"type\":\"assistant\",\"content\":\"ok\"}\n".utf8)),
            (session.appendingPathComponent("summary.json"), try JSONSerialization.data(
                withJSONObject: ["info": ["id": "019dd6e3-91d1-7326-8299-314858773a0e", "cwd": project.path]],
                options: [.sortedKeys]) + Data([10])),
            (session.appendingPathComponent("prompt_context.json"), try JSONSerialization.data(
                withJSONObject: ["working_directory": project.path], options: [.sortedKeys]) + Data([10])),
            (compaction.appendingPathComponent("INDEX.md"), Data("# index\n".utf8)),
            (compaction.appendingPathComponent("segment_000.md"), segment),
        ]
        for (url, bytes) in files {
            try bytes.write(to: url)
            guard chmod(url.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        }
    }

    func writeCursorLegacyComposer(_ id: String, extraKey: String? = nil) throws {
        let database = sourceRoot.appendingPathComponent("state.vscdb")
        let queue = try DatabaseQueue(path: database.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);
                    """)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO cursorDiskKV(key, value) VALUES (?, ?)",
                    arguments: ["composerData:" + id, #"{"composerId":"\#(id)"}"#]
                )
                if let extraKey {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO cursorDiskKV(key, value) VALUES (?, ?)",
                        arguments: [extraKey, "pad"]
                    )
                }
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
        guard chmod(database.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        if usesLegacySourceRoot, extraKey == nil {
            try installCursorLegacyOwnership(composerID: id)
        }
    }

    func installCursorLegacyOwnership(composerID: String, cwd: String? = nil) throws {
        guard usesLegacySourceRoot else { throw Failure.unsafeFixture }
        let directory = workspaceStorage.appendingPathComponent("ws-owned")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try writeCursorLegacyWorkspaceJSON(cwd: cwd ?? project.path)
        let database = directory.appendingPathComponent("state.vscdb")
        let queue = try DatabaseQueue(path: database.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT);")
                let index = try JSONSerialization.data(withJSONObject: [
                    "allComposers": [["composerId": composerID]],
                ])
                guard let value = String(data: index, encoding: .utf8) else { throw Failure.unsafeFixture }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO ItemTable(key, value) VALUES (?, ?)",
                    arguments: ["composer.composerData", value]
                )
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
        guard chmod(database.path, 0o600) == 0 else { throw Failure.unsafeFixture }
    }

    func writeCursorLegacyWorkspaceJSON(cwd: String) throws {
        guard usesLegacySourceRoot else { throw Failure.unsafeFixture }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "folder": URL(fileURLWithPath: cwd).absoluteString,
        ])
        try bytes.write(to: workspaceStorage.appendingPathComponent("ws-owned").appendingPathComponent("workspace.json"))
    }

    func mutateCursorLegacyOwnershipCwd(_ cwd: String) throws {
        try writeCursorLegacyWorkspaceJSON(cwd: cwd)
    }

    func captureLiveCursorLegacy(_ id: String) throws -> EngramCollectorCore.CollectorCursorLegacyOwnership.Capture {
        try EngramCollectorCore.CollectorCursorLegacyOwnership.capture(
            globalStorageRoot: sourceRoot, composerID: id, stagingParent: cas.snapshotStagingParent)
    }

    func seedCursorLegacyReservation(
        _ session: EngramCollectorCore.ArchiveCursorLegacySession
    ) throws -> EngramCollectorCore.CollectorCaptureReservation {
        let context = try EngramCollectorCore.ArchiveCursorLegacyContext(session: session)
        try mutate("""
            INSERT INTO collector_locators(root_id, root_revision, relative_path,
                dirty_revision, acknowledged_revision, claim_generation)
            SELECT root_id, root_revision, 'state.vscdb', 1, 0, 0 FROM collector_roots
            WHERE NOT EXISTS (
                SELECT 1 FROM collector_locators
                WHERE root_id = collector_roots.root_id AND relative_path = 'state.vscdb'
            )
            """)
        try mutate("""
            UPDATE collector_locators SET dirty_revision = dirty_revision + 1
            WHERE relative_path = 'state.vscdb' AND dirty_revision = acknowledged_revision
            """)
        let claim = try XCTUnwrap(owner.claimDirty(configuration: configuration, limit: 8, now: 100)
            .first { $0.relativePath == "state.vscdb" })
        _ = try owner.reconcileCursorLegacyWalk(
            claim, configuration: configuration,
            generation: session.databaseGeneration, walGeneration: session.walGeneration
        )
        return try XCTUnwrap(owner.reserveCapture(
            claim, configuration: configuration, generation: session.databaseGeneration,
            cursorLegacySession: context
        ))
    }

    func markDirty(relativePath: String? = nil) throws {
        try markDirty(configuration: configuration, relativePath: relativePath ?? sourceRelativePath)
    }

    func markDirty(
        configuration: EngramCollectorCore.CollectorRootConfiguration, relativePath: String
    ) throws {
        let checkpoint = try owner.rootState(rootID: configuration.rootID)?.eventCheckpoint
        _ = try owner.applyEvents(configuration: configuration, expectedCheckpoint: checkpoint,
            nextCheckpoint: .init(epoch: "fixture-events-\(configuration.rootID)", cursor: UUID().uuidString),
            dirtyRelativePaths: [relativePath],
            budget: .init(maxIncomingPaths: 8, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096, maxCheckpointUTF8Bytes: 512))
    }

    func enrollCodexRoot(rootID: String) throws -> EngramCollectorCore.CollectorRootConfiguration {
        let directory = base.appendingPathComponent("\(rootID)-source")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("one.jsonl")
        try transcript(text: "\(rootID)-reserved-generation").write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        let enrolled = EngramCollectorCore.CollectorRootConfiguration(
            rootID: rootID, source: .codex, rootPath: directory.path, revision: 1)
        _ = try owner.enrollAndActivateRoot(enrolled)
        try markDirty(configuration: enrolled, relativePath: "one.jsonl")
        return enrolled
    }

    func installNativeVSCodePrimary(
        rootID: String
    ) throws -> (
        configuration: EngramCollectorCore.CollectorRootConfiguration, relativePath: String
    ) {
        let storage = base.appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Code")
            .appendingPathComponent("User")
            .appendingPathComponent("workspaceStorage")
        let relative = "wsrepro00000000000000000000000001/chatSessions/native-repro.jsonl"
        let primary = storage.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: primary.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data((#"{"kind":0,"v":{"sessionId":"vscode-repro","creationDate":1700000000000,"requests":[]}}"# + "\n").utf8)
            .write(to: primary)
        guard chmod(primary.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        let enrolled = EngramCollectorCore.CollectorRootConfiguration(
            rootID: rootID, source: .vscode, rootPath: storage.path, revision: 1)
        _ = try owner.enrollAndActivateRoot(enrolled)
        try markDirty(configuration: enrolled, relativePath: relative)
        return (enrolled, relative)
    }

    func reserveVSCodePrimary(
        _ installed: (configuration: EngramCollectorCore.CollectorRootConfiguration, relativePath: String)
    ) throws {
        let observed = try EngramCollectorCore.CollectorVSCodeSource.observe(
            rootPath: installed.configuration.rootPath, primaryRelative: installed.relativePath,
            maximumByteCount: 1_048_576)
        let claim = try XCTUnwrap(owner.claimDirty(
            configuration: installed.configuration, limit: 8, now: 100).first)
        _ = try XCTUnwrap(owner.reserveCapture(
            claim, configuration: installed.configuration, generation: observed.generation,
            snapshot: observed.snapshot))
    }

    func seedRecoveryCheckpoint(
        _ reservation: EngramCollectorCore.CollectorCaptureReservation,
        after: EngramCollectorCore.ArchiveCaptureCursor,
        through boundary: EngramCollectorCore.ArchiveCaptureCursor
    ) throws {
        let payload = try Canonical.encode(PublicationRecoveryCheckpoint(
            reservationID: reservation.id,
            boundaryTime: boundary.capturedAt,
            boundaryID: boundary.captureID,
            afterTime: after.capturedAt,
            afterID: after.captureID
        ))
        XCTAssertTrue(try owner.storeCaptureRecoveryState(reservation, payload: payload))
    }

    func recoveryAfterID(_ rootID: String) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            guard let bytes = try Data.fetchOne(
                db, sql: "SELECT recovery_state FROM collector_capture_reservations WHERE root_id = ?",
                arguments: [rootID]
            ) else { return nil }
            return (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["afterID"] as? String
        }
    }

    func capture() throws -> CaptureResult {
        if sourceName == .copilot {
            let snapshot = try EngramCollectorCore.CollectorCopilotSource.observe(rootPath: sourceRoot.path,
                primaryRelative: sourceRelativePath).snapshot
            let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
                files: snapshot.present.map { sourceRoot.appendingPathComponent($0.relativePath) },
                absentFiles: snapshot.absentRelativePaths.map { sourceRoot.appendingPathComponent($0) })
            return try EngramCollectorCore.ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: sourceName, locator: source.path, machineID: Self.machine)
        }
        if sourceName == .grok {
            let snapshot = try EngramCollectorCore.CollectorGrokSource.observe(rootPath: sourceRoot.path,
                primaryRelative: sourceRelativePath).snapshot
            let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.fileSet(locator: source.path, root: sourceRoot,
                files: snapshot.present.map { sourceRoot.appendingPathComponent($0.relativePath) },
                absentFiles: snapshot.absentRelativePaths.map { sourceRoot.appendingPathComponent($0) })
            return try EngramCollectorCore.ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
                .capture(source: sourceName, locator: source.path, machineID: Self.machine)
        }
        let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.singleFile(locator: source.path, sourceURL: source, replayRelativePath: "one.jsonl")
        return try EngramCollectorCore.ExactSourceCapturer(cas: cas, catalog: catalog, descriptor: descriptor)
            .capture(source: sourceName, locator: source.path, machineID: Self.machine)
    }

    struct Prepared {
        let reservation: EngramCollectorCore.CollectorCaptureReservation
        let capture: CaptureResult
    }

    func prepare(markDirty: Bool = true) throws -> Prepared {
        // The allocator/Owner unit cases may use an already durable capture.
        // The real Worker crash test separately proves reservation-before-capture.
        let captured = try capture()
        let claim = try XCTUnwrap(owner.claimDirty(configuration: configuration, limit: 8, now: 1).first)
        let reservation = try XCTUnwrap(owner.reserveCapture(claim, configuration: configuration, generation: captured.manifest.generation))
        return .init(reservation: reservation, capture: captured)
    }

    func finish(_ prepared: Prepared) throws -> PublicationIntent {
        let intent = try owner.finishCapture(prepared.reservation, configuration: configuration, capture: prepared.capture.capture)
        return try XCTUnwrap(intent)
    }

    func worker(
        _ endpoints: [EngramCollectorCore.CollectorReplicaEndpoint],
        formats: [String: EngramCollectorCore.SourceMetadataProjection.Format] = [:],
        registryPaths: [String: String]? = nil,
        roots: [EngramCollectorCore.CollectorRootConfiguration]? = nil,
        budget: EngramCollectorCore.CollectorPublicationBudget = .init(),
        hooks: EngramCollectorCore.CollectorPublicationWorkerTestHooks = .init()
    ) throws -> PublicationWorker {
        try PublicationWorker(owner: owner, catalog: catalog, cas: cas, roots: roots ?? [configuration],
            formats: formats, projectRegistryPaths: registryPaths
                ?? (sourceName == .kimi ? [configuration.rootID: kimiRegistry.path]
                    : sourceName == .geminiCli ? [configuration.rootID: geminiRegistry.path] : [:]), replicas: endpoints,
            policy: { [policy] in policy.value }, budget: budget, testHooks: hooks)
    }

    func ack(_ intent: PublicationIntent, server: String = "hq", publicationDigest: String? = nil, manifestDigest: String? = nil) throws -> Data {
        try Canonical.encode(PublicationACK(serverID: server, journalID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", arrivalOrdinal: 1,
            publicationSHA256: publicationDigest ?? intent.digest, manifestSHA256: manifestDigest ?? intent.publication.manifestSHA256,
            storedAt: "2026-09-06T12:00:00.000Z"))
    }

    func integer(_ sql: String) throws -> Int64 {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try XCTUnwrap(Int64.fetchOne($0, sql: sql)) }
    }

    func text(_ sql: String) throws -> String {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { try XCTUnwrap(String.fetchOne($0, sql: sql)) }
    }

    func mutate(_ sql: String) throws {
        let queue = try DatabaseQueue(path: inventory.path)
        defer { try? queue.close() }
        try queue.write { try $0.execute(sql: sql) }
    }

    func inventoryDigest() throws -> Data {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            var result = Data()
            for table in tables {
                guard table.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { throw Failure.unsafeFixture }
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                let rendered = rows.map { row in row.columnNames.map { String(describing: row[$0] as DatabaseValue) }.joined(separator: "|") }.sorted()
                result.append(Data((table + ":" + rendered.joined(separator: "\n")).utf8))
            }
            return result
        }
    }

    func assertNoLegacyAuthority(file: StaticString = #filePath, line: UInt = #line) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: captureRoot.appendingPathComponent("archive.sqlite").path, configuration: configuration)
        defer { try? queue.close() }
        for table in ["archive_session_bindings", "archive_replica_receipts", "archive_recovery_leases", "archive_reclamation_intents"] {
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") }, 0, table, file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("index.sqlite").path), file: file, line: line)
    }
}

/// Real existing RemoteServer app, real loopback HTTP and encrypted ArchiveStore.
/// No URLProtocol, mock server, alternate storage implementation or product writer.
private final class PublicationHTTPReplica: @unchecked Sendable {
    let id: String
    let token: String
    let config: EngramRemoteServerCore.EngramRemoteServerConfig
    let baseURL: URL
    private let server: Task<Void, Error>

    private init(id: String, token: String, config: EngramRemoteServerCore.EngramRemoteServerConfig, baseURL: URL, server: Task<Void, Error>) {
        self.id = id; self.token = token; self.config = config; self.baseURL = baseURL; self.server = server
    }

    static func start(id: String, parent: URL, publicationsEnabled: Bool = true) async throws -> PublicationHTTPReplica {
        let token = "synthetic-\(id)-archive-token"
        let root = parent.appendingPathComponent("replica-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: 0,
            storeRoot: root.appendingPathComponent("legacy"), bearerToken: "synthetic-\(id)-legacy-token",
            atRestKey: SymmetricKey(data: Data(repeating: 8, count: 32)),
            archiveV2: .init(serverID: id, root: root.appendingPathComponent("archive"), bearerToken: token,
                atRestKey: SymmetricKey(data: Data(repeating: id == "hq" ? 11 : 12, count: 32)), publicationsEnabled: publicationsEnabled))
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: config)
        let bound = XCTestExpectation(description: "\(id) real archive HTTP listener")
        let port = PublicationLocked<Int?>(nil)
        let server = Task { try await app.run { value in port.change { $0 = value }; bound.fulfill() } }
        let result = await XCTWaiter.fulfillment(of: [bound], timeout: 10)
        guard result == .completed, let selected = port.value else {
            server.cancel()
            _ = try? await server.value
            throw PublicationFixture.Failure.unsafeFixture
        }
        let replica = PublicationHTTPReplica(id: id, token: token, config: config,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(selected)")), server: server)
        do {
        if publicationsEnabled {
            // The actual app warms its durable publication journal off the accept
            // path. Wait with a deadline; listener-bound alone is not readiness.
            let deadline = Date().addingTimeInterval(5)
            while true {
                if try await replica.get("/v2/archive/publications").1 == 200 { break }
                guard Date() < deadline else { throw PublicationFixture.Failure.unsafeFixture }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        return replica
        } catch {
            await replica.stop()
            throw error
        }
    }

    var endpoint: EngramCollectorCore.CollectorReplicaEndpoint { .init(replicaID: id, baseURL: baseURL, bearerToken: token) }
    func cancel() { server.cancel() }
    func stop() async { server.cancel(); _ = try? await server.value }

    func get(_ path: String) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: baseURL)))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.data(for: request)
        return (bytes, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }

    func publications() async throws -> [[String: Any]] {
        let response = try await get("/v2/archive/publications")
        XCTAssertEqual(response.1, 200)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: response.0) as? [String: Any])
        let items = try XCTUnwrap(page["items"] as? [[String: Any]])
        return try items.map { try XCTUnwrap($0["ack"] as? [String: Any]) }
    }
}

private struct PublicationReplicas {
    let hq: PublicationHTTPReplica
    let m1: PublicationHTTPReplica
    var all: [PublicationHTTPReplica] { [hq, m1] }
    var endpoints: [EngramCollectorCore.CollectorReplicaEndpoint] { all.map(\.endpoint) }
    static func start(in parent: URL, hqPublicationsEnabled: Bool = true) async throws -> Self {
        let hq = try await PublicationHTTPReplica.start(id: "hq", parent: parent, publicationsEnabled: hqPublicationsEnabled)
        do {
            let m1 = try await PublicationHTTPReplica.start(id: "m1", parent: parent)
            return .init(hq: hq, m1: m1)
        }
        catch { await hq.stop(); throw error }
    }
    func cancel() { hq.cancel(); m1.cancel() }
    func stop() async { await hq.stop(); await m1.stop() }
}

/// Fixture-only loopback: forward archive GET/HEAD/PUT to a warmed native replica
/// and delay the first PUT whose path matches `delayedPathPrefix`.
private final class PublicationDelayedArchiveProxy: @unchecked Sendable {
    let baseURL: URL
    private let engine: Engine
    private let server: Task<Void, Error>

    static func start(
        forwarding replica: PublicationHTTPReplica,
        delayedPathPrefix: String,
        delay: Duration = .seconds(35)
    ) async throws -> PublicationDelayedArchiveProxy {
        let engine = Engine(native: replica.baseURL, delayedPathPrefix: delayedPathPrefix, delay: delay)
        let router = Router()
        router.get("/v2/archive/**") { request, _ in try await engine.forward(request) }
        router.head("/v2/archive/**") { request, _ in try await engine.forward(request) }
        router.put("/v2/archive/**") { request, _ in try await engine.forward(request) }
        let bound = XCTestExpectation(description: "delayed archive proxy bound")
        let port = PublicationLocked<Int?>(nil)
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                if let selected = channel.localAddress?.port {
                    port.change { $0 = selected }
                    bound.fulfill()
                }
            })
        let server = Task { try await app.run() }
        let result = await XCTWaiter.fulfillment(of: [bound], timeout: 10)
        guard result == .completed, let selected = port.value,
              let url = URL(string: "http://127.0.0.1:\(selected)") else {
            server.cancel()
            _ = try? await server.value
            throw PublicationFixture.Failure.unsafeFixture
        }
        return PublicationDelayedArchiveProxy(baseURL: url, engine: engine, server: server)
    }

    private init(baseURL: URL, engine: Engine, server: Task<Void, Error>) {
        self.baseURL = baseURL
        self.engine = engine
        self.server = server
    }

    func stop() async {
        server.cancel()
        _ = try? await server.value
    }

    private final class Engine: @unchecked Sendable {
        private let native: URL
        private let delayedPathPrefix: String
        private let delay: Duration
        private let lock = NSLock()
        private var delayedFirstMatch = false

        init(native: URL, delayedPathPrefix: String, delay: Duration) {
            self.native = native
            self.delayedPathPrefix = delayedPathPrefix
            self.delay = delay
        }

        func forward(_ request: Request) async throws -> Response {
            try Task.checkCancellation()
            let path = request.uri.path
            if request.method == .put, path.hasPrefix(delayedPathPrefix), consumeFirstDelay() {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
            }
            let limit = bodyLimit(path)
            var inbound = request
            let body: Data
            if request.method == .put {
                do {
                    let buffer = try await inbound.collectBody(upTo: limit)
                    body = Data(buffer.readableBytesView)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return Response(status: .contentTooLarge)
                }
            } else {
                body = Data()
            }
            guard let url = URL(string: path, relativeTo: native)?.absoluteURL else {
                return Response(status: .badRequest)
            }
            var outbound = URLRequest(url: url, timeoutInterval: 30)
            outbound.httpMethod = request.method.rawValue
            if let authorization = request.headers[.authorization] {
                outbound.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            if let contentType = request.headers[.contentType] {
                outbound.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if !body.isEmpty { outbound.httpBody = body }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let bytes: Data
            let status: Int
            let contentType: String?
            do {
                let (data, response) = try await session.data(for: outbound)
                guard let http = response as? HTTPURLResponse else {
                    return Response(status: .serviceUnavailable)
                }
                status = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type")
                bytes = data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Response(status: .serviceUnavailable)
            }
            guard bytes.count <= limit else { return Response(status: .contentTooLarge) }
            var headers = HTTPFields()
            if let contentType { headers[.contentType] = contentType }
            headers[.contentLength] = "\(bytes.count)"
            return Response(
                status: HTTPResponse.Status(code: status),
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(data: bytes)))
        }

        private func consumeFirstDelay() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if delayedFirstMatch { return false }
            delayedFirstMatch = true
            return true
        }

        private func bodyLimit(_ path: String) -> Int {
            if path.hasPrefix("/v2/archive/objects/") {
                return EngramCollectorCore.ArchiveV2ProtocolLimits.maxObjectRawBytes
            }
            if path.hasPrefix("/v2/archive/manifests/") {
                return EngramCollectorCore.ArchiveV2ProtocolLimits.maxManifestBytes
            }
            return EngramCollectorCore.CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
        }
    }
}

/// Holds every HQ publication PUT until `releaseHolds()`. Forwards other archive
/// traffic immediately so overlap is observed at the actual transmit unit.
private final class PublicationHeldArchiveProxy: @unchecked Sendable {
    let baseURL: URL
    private let engine: Engine
    private let server: Task<Void, Error>

    var inFlight: Int { engine.inFlight }
    var maxInFlight: Int { engine.maxInFlight }

    static func start(forwarding replica: PublicationHTTPReplica) async throws -> PublicationHeldArchiveProxy {
        let engine = Engine(native: replica.baseURL)
        let router = Router()
        router.get("/v2/archive/**") { request, _ in try await engine.forward(request) }
        router.head("/v2/archive/**") { request, _ in try await engine.forward(request) }
        router.put("/v2/archive/**") { request, _ in try await engine.forward(request) }
        let bound = XCTestExpectation(description: "held archive proxy bound")
        let port = PublicationLocked<Int?>(nil)
        let app = Application(
            router: router,
            configuration: ApplicationConfiguration(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                if let selected = channel.localAddress?.port {
                    port.change { $0 = selected }
                    bound.fulfill()
                }
            })
        let server = Task { try await app.run() }
        let result = await XCTWaiter.fulfillment(of: [bound], timeout: 10)
        guard result == .completed, let selected = port.value,
              let url = URL(string: "http://127.0.0.1:\(selected)") else {
            server.cancel()
            _ = try? await server.value
            throw PublicationFixture.Failure.unsafeFixture
        }
        return PublicationHeldArchiveProxy(baseURL: url, engine: engine, server: server)
    }

    private init(baseURL: URL, engine: Engine, server: Task<Void, Error>) {
        self.baseURL = baseURL
        self.engine = engine
        self.server = server
    }

    func releaseHolds() { engine.releaseHolds() }

    func stop() async {
        engine.releaseHolds()
        server.cancel()
        _ = try? await server.value
    }

    private final class Engine: @unchecked Sendable {
        private let native: URL
        private let lock = NSLock()
        private var released = false
        private var storedInFlight = 0
        private var storedMaxInFlight = 0

        init(native: URL) { self.native = native }

        var inFlight: Int {
            lock.lock(); defer { lock.unlock() }
            return storedInFlight
        }

        var maxInFlight: Int {
            lock.lock(); defer { lock.unlock() }
            return storedMaxInFlight
        }

        func releaseHolds() {
            lock.lock()
            released = true
            lock.unlock()
        }

        func forward(_ request: Request) async throws -> Response {
            try Task.checkCancellation()
            let path = request.uri.path
            let held = request.method == .put && path.hasPrefix("/v2/archive/publications/")
            if held {
                lock.lock()
                storedInFlight += 1
                if storedInFlight > storedMaxInFlight { storedMaxInFlight = storedInFlight }
                lock.unlock()
            }
            defer {
                if held {
                    lock.lock()
                    storedInFlight -= 1
                    lock.unlock()
                }
            }
            if held {
                while true {
                    try Task.checkCancellation()
                    lock.lock()
                    let done = released
                    lock.unlock()
                    if done { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let limit: Int
            if path.hasPrefix("/v2/archive/objects/") {
                limit = EngramCollectorCore.ArchiveV2ProtocolLimits.maxObjectRawBytes
            } else if path.hasPrefix("/v2/archive/manifests/") {
                limit = EngramCollectorCore.ArchiveV2ProtocolLimits.maxManifestBytes
            } else {
                limit = EngramCollectorCore.CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
            }
            var inbound = request
            let body: Data
            if request.method == .put {
                do {
                    let buffer = try await inbound.collectBody(upTo: limit)
                    body = Data(buffer.readableBytesView)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return Response(status: .contentTooLarge)
                }
            } else {
                body = Data()
            }
            guard let url = URL(string: path, relativeTo: native)?.absoluteURL else {
                return Response(status: .badRequest)
            }
            var outbound = URLRequest(url: url, timeoutInterval: 30)
            outbound.httpMethod = request.method.rawValue
            if let authorization = request.headers[.authorization] {
                outbound.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            if let contentType = request.headers[.contentType] {
                outbound.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            if !body.isEmpty { outbound.httpBody = body }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let bytes: Data
            let status: Int
            let contentType: String?
            do {
                let (data, response) = try await session.data(for: outbound)
                guard let http = response as? HTTPURLResponse else {
                    return Response(status: .serviceUnavailable)
                }
                status = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type")
                bytes = data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return Response(status: .serviceUnavailable)
            }
            guard bytes.count <= limit else { return Response(status: .contentTooLarge) }
            var headers = HTTPFields()
            if let contentType { headers[.contentType] = contentType }
            headers[.contentLength] = "\(bytes.count)"
            return Response(
                status: HTTPResponse.Status(code: status),
                headers: headers,
                body: .init(byteBuffer: ByteBuffer(data: bytes)))
        }
    }
}
