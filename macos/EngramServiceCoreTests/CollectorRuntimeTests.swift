import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
@testable import EngramCollectorCore
@testable import EngramRemoteServerCore

private typealias Runtime = EngramCollectorCore.CollectorRuntime
private typealias RuntimeError = EngramCollectorCore.CollectorRuntimeError

final class CollectorRuntimeTests: XCTestCase {
    func testRuntimeForwardsInventoryPressureWithoutInventingCASObservation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("must remain dirty under inventory pressure")
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["minimumFreeDiskBytes"] = Int64.max
            collector["budgets"] = budgets
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                var blocked: EngramCollectorCore.CollectorRuntimeCycle?
                for now: Int64 in 100..<116 {
                    let cycle = try await runtime.runOnce(now: now)
                    XCTAssertEqual(cycle.captured, 0)
                    if cycle.deferred > 0 { blocked = cycle; break }
                }
                let cycle = try XCTUnwrap(blocked, "the real bounded bootstrap must reach the source admission")
                if case .observed(let threshold, let inventory, let capture) = cycle.diskAdmission {
                    XCTAssertEqual(threshold, Int64.max)
                    let available = try XCTUnwrap(inventory)
                    XCTAssertGreaterThanOrEqual(available, 0)
                    XCTAssertLessThan(available, threshold)
                    XCTAssertNil(capture, "inventory rejection must preserve the CAS short circuit")
                } else { XCTFail("Runtime discarded the Worker's actual pressure observation") }
                XCTAssertEqual(cycle.acknowledgedHQ + cycle.acknowledgedM1, 0)
                XCTAssertTrue(try fixture.publications().isEmpty)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_locators WHERE acknowledged_revision > 0"), 0)
                let hq = try await replicas.hq.count()
                let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 0)
                XCTAssertEqual(m1, 0)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testRuntimeForwardsBothDiskSamplesAndDoesNotReuseThemForIdleCycle() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("a real capture with both admission samples")
            try fixture.writeSettings(fixture.document(replicas: replicas))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                var captured: EngramCollectorCore.CollectorRuntimeCycle?
                for now: Int64 in 100..<116 {
                    let cycle = try await runtime.runOnce(now: now)
                    if cycle.captured > 0 { captured = cycle; break }
                }
                let cycle = try XCTUnwrap(captured, "the real bounded bootstrap must capture the source")
                if case .observed(let threshold, let inventory, let capture) = cycle.diskAdmission {
                    XCTAssertEqual(threshold, 0)
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(inventory), threshold)
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(capture), threshold)
                } else { XCTFail("Runtime discarded the Worker's actual two-volume observation") }
                XCTAssertEqual(cycle.captured, 1)
                XCTAssertEqual(cycle.acknowledgedHQ, 1)
                XCTAssertEqual(cycle.acknowledgedM1, 1)
                var idle: EngramCollectorCore.CollectorRuntimeCycle?
                for now: Int64 in 200..<216 {
                    let next = try await runtime.runOnce(now: now)
                    if next.captured == 0, next.recovered == 0, next.deferred == 0 { idle = next; break }
                }
                XCTAssertEqual(try XCTUnwrap(idle).diskAdmission, .notEvaluated,
                    "an idle cycle must not reuse the previous capture's observation")
                XCTAssertEqual(try fixture.publications().count, 1)
                let hq = try await replicas.hq.count()
                let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 1)
                XCTAssertEqual(m1, 1)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testBackgroundLoopRecoversAfterRealInventoryBusyLockIsReleased() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("before inventory lock")
            try fixture.writeSettings(fixture.document(replicas: replicas))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            let outcome = RuntimeLocked<Result<Void, Error>?>(nil)
            var waiter: Task<Void, Never>?
            var configuration = Configuration()
            configuration.allowsUnsafeTransactions = true
            configuration.busyMode = .timeout(1)
            let blocker = try DatabaseQueue(path: fixture.inventory.path, configuration: configuration)
            defer { try? blocker.close() }
            var transactionOpen = false
            do {
                try await runtime.start()
                waiter = observeWait(runtime, outcome: outcome)
                try await fixture.awaitACKs(2)
                // This is a real SQLite write lock, not an injected error. It is
                // held across more than two of Owner's 0.5-second busy timeouts.
                try await blocker.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
                transactionOpen = true
                try fixture.writeTranscript("after inventory lock, a larger generation")
                try await Task.sleep(for: .milliseconds(1200))
                try await blocker.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
                transactionOpen = false
                try blocker.close()
                // No manual runOnce or restart: the original background loop
                // must discover/capture the new bytes and independently ACK both.
                try await fixture.awaitACKs(4)
                XCTAssertNil(outcome.value, "a transient busy error must not terminate the loop")
                let hq = try await replicas.hq.count()
                let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 2)
                XCTAssertEqual(m1, 2)
                try await runtime.stop()
                await waiter?.value
                if case .failure(let error) = outcome.value {
                    XCTAssertTrue(error is CancellationError, "normal stop must not report a database failure")
                }
                await replicas.stop()
            } catch {
                if transactionOpen { try? await blocker.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") } }
                try? blocker.close()
                try? await runtime.stop()
                await waiter?.value
                throw error
            }
        } catch { await replicas.stop(); throw error }
    }

    func testInvalidFreshSettingsTerminateWaitAndNeverResumePublicationAutomatically() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("authorized initial generation")
            let document = fixture.document(replicas: replicas)
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            let outcome = RuntimeLocked<Result<Void, Error>?>(nil)
            var waiter: Task<Void, Never>?
            do {
                try await runtime.start()
                waiter = observeWait(runtime, outcome: outcome)
                try await fixture.awaitACKs(2)
                try fixture.writeSettings(["runtimeRole": "collector", "collector": ["enabled": "invalid"]])
                let terminal = try await awaitOutcome(outcome)
                if case .failure(let error) = terminal {
                    XCTAssertEqual(error as? RuntimeError, .invalidConfiguration)
                } else { XCTFail("invalid fresh settings were hidden as successful completion") }
                // The failed loop is terminal, not a catch-all retry loop that
                // may resume old work after a later settings edit.
                try fixture.writeSettings(document)
                try fixture.writeTranscript("must remain unpublished after configuration failure")
                try await Task.sleep(for: .milliseconds(350))
                let hq = try await replicas.hq.count()
                let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 1)
                XCTAssertEqual(m1, 1)
                XCTAssertEqual(try fixture.publications().count, 1)
                do { try await runtime.stop() }
                catch { XCTAssertEqual(error as? RuntimeError, .invalidConfiguration) }
                await waiter?.value
                let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                try await reopened.stop()
                await replicas.stop()
            } catch {
                try? await runtime.stop()
                await waiter?.value
                throw error
            }
        } catch { await replicas.stop(); throw error }
    }

    func testCancelledWaitJoinsLoopButKeepsOwnerUntilExplicitStop() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings(fixture.document())
        let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
        let firstOutcome = RuntimeLocked<Result<Void, Error>?>(nil)
        let secondOutcome = RuntimeLocked<Result<Void, Error>?>(nil)
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        do {
            do { try await runtime.waitUntilStopped(); XCTFail("never-started runtime reported a completed loop") }
            catch {}
            try await runtime.start()
            let entered = XCTestExpectation(description: "both loop waiters entered")
            entered.expectedFulfillmentCount = 2
            first = observeWait(runtime, outcome: firstOutcome, entered: entered)
            second = observeWait(runtime, outcome: secondOutcome, entered: entered)
            await fulfillment(of: [entered], timeout: 3)
            first?.cancel()
            let firstTerminal = try await awaitOutcome(firstOutcome)
            let secondTerminal = try await awaitOutcome(secondOutcome)
            if case .failure(let error) = firstTerminal { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("cancelled waiter must report cancellation") }
            if case .failure(let error) = secondTerminal { XCTAssertTrue(error is CancellationError) }
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret)) {
                XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .alreadyOwned)
            }
            try await runtime.stop()
            try await runtime.stop()
            await first?.value
            await second?.value
            let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            try await reopened.stop()
        } catch {
            try? await runtime.stop()
            await first?.value
            await second?.value
            throw error
        }
    }

    private func observeWait(_ runtime: Runtime, outcome: RuntimeLocked<Result<Void, Error>?>,
                             entered: XCTestExpectation? = nil) -> Task<Void, Never> {
        Task {
            entered?.fulfill()
            do { try await runtime.waitUntilStopped(); outcome.update { $0 = .success(()) } }
            catch { outcome.update { $0 = .failure(error) } }
        }
    }

    private func awaitOutcome(_ outcome: RuntimeLocked<Result<Void, Error>?>) async throws -> Result<Void, Error> {
        let deadline = Date().addingTimeInterval(3)
        while true {
            if let result = outcome.value { return result }
            guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func testOwnedCaptureWALModeProbeUsesExistingMainAndQueryOnlySQL() throws {
        for readOnlyMain in [true, false] {
            let fixture = try RuntimeFixture()
            defer { fixture.remove() }
            let file = fixture.capture.appendingPathComponent("archive.sqlite")
            let before = try Data(contentsOf: file)
            var configuration = Configuration()
            configuration.readonly = readOnlyMain
            configuration.foreignKeysEnabled = false
            configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
            var uri = URLComponents(url: file, resolvingAgainstBaseURL: false)!
            uri.queryItems = [URLQueryItem(name: "mode", value: readOnlyMain ? "ro" : "rw")]
            do {
                let database = try DatabaseQueue(path: uri.url!.absoluteString, configuration: configuration)
                defer { try? database.close() }
                let machine = try database.writeWithoutTransaction { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA query_only"), 1)
                    return try String.fetchOne(db, sql: "SELECT value FROM archive_metadata WHERE key = 'machine_id'")
                }
                XCTAssertEqual(machine, RuntimeFixture.machineID)
                XCTAssertThrowsError(try database.writeWithoutTransaction {
                    try $0.execute(sql: "UPDATE archive_metadata SET value = 'forbidden' WHERE key = 'machine_id'")
                })
                try database.close()
                XCTAssertEqual(try Data(contentsOf: file), before)
            } catch {
                print("Owned capture WAL diagnostic mode=\(readOnlyMain ? "ro" : "rw"): \(error)")
                if !readOnlyMain { throw error }
            }
        }
    }

    func testMissingCaptureRootOrMainFailsWithoutProvisioningOrIdentityChanges() throws {
        for removeRoot in [false, true] {
            let fixture = try RuntimeFixture()
            defer { fixture.remove() }
            let identityBefore = try Data(contentsOf: fixture.identity)
            let marker = fixture.shadow.appendingPathComponent("archive.sqlite")
            let markerBefore = try Data(contentsOf: marker)
            let target = removeRoot ? fixture.capture : fixture.capture.appendingPathComponent("archive.sqlite")
            try FileManager.default.removeItem(at: target)
            try fixture.writeSettings(fixture.document())
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret)) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try Data(contentsOf: fixture.identity), identityBefore)
            XCTAssertEqual(try Data(contentsOf: marker), markerBefore)
            // A failed later capture preflight must release the owner lock.
            let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
                shadowRoot: fixture.shadow, identityCatalog: fixture.identity, ownerRunID: UUID().uuidString))
            try owner.close()
        }
    }

    func testMismatchedExistingCaptureIdentityIsNeverMigratedOrReplaced() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let captureDatabase = fixture.capture.appendingPathComponent("archive.sqlite")
        let wrongID = "B0000000-1111-2222-3333-444444444444"
        let database = try DatabaseQueue(path: captureDatabase.path)
        try database.write { try $0.execute(sql: "UPDATE archive_metadata SET value = ? WHERE key = 'machine_id'", arguments: [wrongID]) }
        try database.close()
        let identityBefore = try Data(contentsOf: fixture.identity)
        try fixture.writeSettings(fixture.document())
        XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret)) {
            XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
        }
        var configuration = Configuration(); configuration.readonly = true
        let verify = try DatabaseQueue(path: captureDatabase.path, configuration: configuration)
        let value = try verify.read { try String.fetchOne($0, sql: "SELECT value FROM archive_metadata WHERE key = 'machine_id'") }
        try verify.close()
        XCTAssertEqual(value, wrongID)
        XCTAssertEqual(try Data(contentsOf: fixture.identity), identityBefore)
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
            shadowRoot: fixture.shadow, identityCatalog: fixture.identity, ownerRunID: UUID().uuidString))
        try owner.close()
    }

    func testClosedWALCaptureRestartsWithoutRelaxingBorrowedIdentityReader() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let captureDatabase = fixture.capture.appendingPathComponent("archive.sqlite")
        let header = try Data(contentsOf: captureDatabase).prefix(20)
        XCTAssertEqual(header.count, 20)
        XCTAssertEqual(header[18], 2)
        // Keep the existing strict borrowed-catalog guarantee. The runtime's
        // owned capture preflight is a different, explicitly writable topology.
        for suffix in ["-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: captureDatabase.path + suffix))
        }
        XCTAssertThrowsError(try EngramCollectorCore.CollectorMachineIdentityReader.read(from: captureDatabase)) {
            XCTAssertEqual($0 as? EngramCollectorCore.CollectorMachineIdentityError, .walSidecarsUnavailable)
        }
        try fixture.writeSettings(fixture.document())
        for _ in 0..<2 {
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            try await runtime.stop()
        }
        XCTAssertEqual(try EngramCollectorCore.CollectorMachineIdentityReader.read(from: fixture.identity), RuntimeFixture.machineID)
        try fixture.assertNoProductIndex()
    }

    func testAbsentAndDisabledSettingsDoNotAllocateOrLoadCredentials() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let calls = RuntimeLocked(0)
        let loader: @Sendable (String) throws -> String = { _ in calls.update { $0 += 1 }; return "forbidden" }
        XCTAssertNil(try Runtime.open(settingsURL: fixture.settings, secretLoader: loader))
        for document: [String: Any] in [[:], ["runtimeRole": "collector"],
            ["runtimeRole": "collector", "collector": ["enabled": false]]] {
            try fixture.writeSettings(document)
            XCTAssertNil(try Runtime.open(settingsURL: fixture.settings, secretLoader: loader))
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
        try fixture.assertNoProductIndex()
    }

    func testEnabledNonCollectorRoleFailsBeforeInventoryOrCredentials() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let calls = RuntimeLocked(0)
        for role in ["local", "index", "replica", "unknown"] {
            var document = fixture.document()
            document["runtimeRole"] = role
            try fixture.writeSettings(document)
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: { _ in
                calls.update { $0 += 1 }; return "forbidden"
            })) { XCTAssertEqual($0 as? RuntimeError, .invalidRole) }
        }
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
    }

    func testUnsafeSettingsAreRejectedWithoutPermissionRepairOrAllocation() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings(fixture.document())
        XCTAssertEqual(chmod(fixture.settings.path, 0o644), 0)
        XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: { _ in XCTFail("credential read"); return "x" })) {
            XCTAssertEqual($0 as? RuntimeError, .invalidSettings)
        }
        var info = stat()
        XCTAssertEqual(lstat(fixture.settings.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
        let link = fixture.base.appendingPathComponent("settings-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.settings)
        XCTAssertThrowsError(try Runtime.open(settingsURL: link, secretLoader: { _ in XCTFail("credential read"); return "x" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
    }

    func testUnsupportedSourcesInlineSecretsAndMissingBudgetsFailClosed() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        for variant in 0..<4 {
            var document = fixture.document()
            var block = document["collector"] as! [String: Any]
            if variant == 0 { block["roots"] = [["rootID": "unsupported", "source": "grok", "rootPath": fixture.sources.path, "revision": 1]] }
            if variant == 1 { block["bearerToken"] = "must-not-be-accepted" }
            if variant == 2 { block.removeValue(forKey: "budgets") }
            if variant == 3 { block["roots"] = [] }
            document["collector"] = block
            try fixture.writeSettings(document)
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: { _ in XCTFail("credential read"); return "x" })) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
    }

    func testExistingMachineIdentityIsReadOnlyAndMissingIdentityDoesNotProvision() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.identity)
        var document = fixture.document()
        var block = document["collector"] as! [String: Any]
        let missing = fixture.base.appendingPathComponent("missing-identity")
        block["identityCatalog"] = missing.appendingPathComponent("archive.sqlite").path
        document["collector"] = block
        try fixture.writeSettings(document)
        XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
        XCTAssertEqual(try Data(contentsOf: fixture.identity), before)
    }

    func testColdStartNativeWatchPublishesDualACKAndRestartKeepsIdentitySequence() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("first generation")
            try fixture.writeSettings(fixture.document(replicas: replicas))
            let identityBefore = try Data(contentsOf: fixture.identity)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let first = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(first.count, 1)
                XCTAssertEqual(first[0].sequence, 1)
                XCTAssertEqual(first[0].machineID, RuntimeFixture.machineID)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 1)
                XCTAssertEqual(m1Count, 1)
                // No explicit dirty mark or inventory API: only the real native
                // event stream may discover this newly written generation.
                try fixture.writeTranscript("second generation is larger")
                let second = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(second.count, 2)
                XCTAssertGreaterThan(second[1].sequence, second[0].sequence)
                XCTAssertEqual(second[1].sourceInstanceID, first[0].sourceInstanceID)
                XCTAssertEqual(second[1].collectorEpoch, first[0].collectorEpoch)
                try await runtime.stop()
                try await runtime.stop()
                do { _ = try await runtime.runOnce(now: 1); XCTFail("closed runtime accepted work") }
                catch { XCTAssertEqual(error as? RuntimeError, .closed) }
                let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                do {
                    for _ in 0..<8 { _ = try await reopened.runOnce(now: 20) }
                    XCTAssertEqual(try fixture.publications(), second)
                    XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4)
                    try await reopened.stop()
                } catch { try? await reopened.stop(); throw error }
                XCTAssertEqual(try Data(contentsOf: fixture.identity), identityBefore)
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testRuntimeOwnerExclusionAndStopReleasesOwnership() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        try fixture.writeSettings(fixture.document())
        let first = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
        do {
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret)) {
                XCTAssertEqual($0 as? EngramCollectorCore.CollectorInventoryOwnerError, .alreadyOwned)
            }
            try await first.stop()
            let second = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            try await second.stop()
        } catch { try? await first.stop(); throw error }
    }

    func testStartLoopPublishesAndStopJoinsBeforeReopen() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("background loop")
            try fixture.writeSettings(fixture.document(replicas: replicas))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                let deadline = Date().addingTimeInterval(10)
                while try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") < 2 {
                    guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try await runtime.stop()
                let count = try fixture.publications().count
                try fixture.writeTranscript("must not be discovered after stop")
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(try fixture.publications().count, count)
                let next = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                try await next.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testBootstrapIsBoundedAndPrivacyExclusionPreventsPublication() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            for index in 0..<10 { try fixture.writeTranscript("private \(index)", name: "rollout-session-\(index).jsonl") }
            var document = fixture.document(replicas: replicas)
            var block = document["collector"] as! [String: Any]
            block["privacy"] = ["revision": 2, "excludedProjectRoots": [fixture.project.path]]
            document["collector"] = block
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let cycle = try await runtime.runOnce(now: 1)
                XCTAssertLessThanOrEqual(cycle.scannedEntries, 2)
                XCTAssertLessThan(try fixture.integer("SELECT count(*) FROM collector_locators"), 10)
                for _ in 0..<20 { _ = try await runtime.runOnce(now: 2) }
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_locators"), 10)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 0)
                XCTAssertEqual(m1Count, 0)
                try await runtime.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }
}

private final class RuntimeLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ operation: (inout Value) -> Void) { lock.withLock { operation(&stored) } }
}

final class RuntimeFixture: @unchecked Sendable {
    enum Failure: Error { case unsafeFixture, deadline }
    static let machineID = "A0000000-1111-2222-3333-444444444444"
    let base: URL
    let settings: URL
    let shadow: URL
    let capture: URL
    let identity: URL
    let sources: URL
    let project: URL
    var inventory: URL { shadow.appendingPathComponent("inventory/inventory.sqlite") }
    var secret: @Sendable (String) throws -> String { { id in
        guard id == "hq-reference" || id == "m1-reference" else { throw Failure.unsafeFixture }
        return id == "hq-reference" ? "synthetic-hq-runtime-token" : "synthetic-m1-runtime-token"
    } }

    init() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = checkout.appendingPathComponent(".engram-runtime-test-\(UUID().uuidString)")
        settings = base.appendingPathComponent("settings.json")
        shadow = base.appendingPathComponent("shadow")
        capture = shadow.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        sources = base.appendingPathComponent("sources")
        project = base.appendingPathComponent("project")
        for path in [base, shadow, capture, identity.deletingLastPathComponent(), sources, project] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        for path in [identity, shadow.appendingPathComponent("archive.sqlite")] {
            let database = try DatabaseQueue(path: path.path)
            try database.write { db in
                try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [Self.machineID])
            }
            try database.close()
            guard chmod(path.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        }
        // Explicit fixture provisioning is not a production runtime capability.
        // A synchronous Queue.close is the cold-WAL fence; lexical lifetime of
        // ArchiveCatalog's DatabasePool is not evidence that every reader closed.
        var provisionConfiguration = Configuration()
        provisionConfiguration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        }
        let captureDatabase = capture.appendingPathComponent("archive.sqlite")
        let provision = try DatabaseQueue(path: captureDatabase.path, configuration: provisionConfiguration)
        try provision.write { try EngramCollectorCore.ArchiveCatalogMigrations.migrate($0, machineID: Self.machineID) }
        try provision.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try provision.close()
        guard chmod(captureDatabase.path, 0o600) == 0 else { throw Failure.unsafeFixture }
        // Match the existing closed-WAL identity-reader fixture: some SQLite
        // builds retain empty sidecars even after this verified close. Only this
        // invocation's fully checkpointed, synchronously closed files are removed.
        let wal = URL(fileURLWithPath: captureDatabase.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            guard try Data(contentsOf: wal).isEmpty else { throw Failure.unsafeFixture }
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: captureDatabase.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        _ = try EngramCollectorCore.ImmutableArchiveCAS(root: capture)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    func document(replicas: RuntimeReplicas? = nil) -> [String: Any] {
        ["runtimeRole": "collector", "collector": ["enabled": true, "shadowRoot": shadow.path,
            "identityCatalog": identity.path,
            "roots": [["rootID": "runtime-codex", "source": "codex", "rootPath": sources.path, "revision": 1]],
            "replicas": [["serverID": "hq", "baseURL": replicas?.hq.baseURL.absoluteString ?? "https://hq.invalid", "credentialID": "hq-reference"],
                ["serverID": "m1", "baseURL": replicas?.m1.baseURL.absoluteString ?? "https://m1.invalid", "credentialID": "m1-reference"]],
            "privacy": ["revision": 1, "excludedProjectRoots": [String]()],
            "budgets": ["maxEntriesVisited": 2, "maxCandidateFiles": 2, "maxDirectoryOpens": 1,
                "maxMetadataBytes": 8192, "maxCaptureFiles": 2, "maxCaptureBytes": 1048576,
                "maxUploadClaimsPerReplica": 2, "maxRecoveryCandidates": 8, "maxResponseBytes": 4096,
                "minimumFreeDiskBytes": 0, "maxIncomingPaths": 64, "maxPathUTF8Bytes": 4096,
                "maxTotalPathUTF8Bytes": 32768, "maxCheckpointUTF8Bytes": 512,
                "maxQueuedBatches": 16, "maxQueuedUTF8Bytes": 65536, "pollIntervalMilliseconds": 50]]]
    }

    func writeSettings(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: settings)
        guard chmod(settings.path, 0o600) == 0 else { throw Failure.unsafeFixture }
    }

    func writeTranscript(_ text: String, name: String = "rollout-one.jsonl") throws {
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": "native-runtime-session", "cwd": project.path]]
        let message: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        let bytes = try [metadata, message].map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
        try bytes.write(to: sources.appendingPathComponent(name))
    }

    func integer(_ sql: String) throws -> Int {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? database.close() }
        return try database.read { try XCTUnwrap(Int.fetchOne($0, sql: sql)) }
    }

    func publications() throws -> [EngramCollectorCore.CollectorPublicationEnvelope] {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? database.close() }
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT canonical_bytes FROM collector_publications ORDER BY sequence").map {
                try EngramCollectorCore.ArchiveCanonicalJSON.decode(EngramCollectorCore.CollectorPublicationEnvelope.self, from: $0)
            }
        }
    }

    func drive(_ runtime: EngramCollectorCore.CollectorRuntime, acknowledged: Int) async throws -> [EngramCollectorCore.CollectorPublicationEnvelope] {
        let deadline = Date().addingTimeInterval(10)
        while true {
            _ = try await runtime.runOnce(now: Int64(Date().timeIntervalSince1970))
            if try integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") >= acknowledged { return try publications() }
            guard Date() < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func awaitACKs(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") < expected {
            guard Date() < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func assertNoProductIndex(file: StaticString = #filePath, line: UInt = #line) throws {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: base.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix("index.sqlite") || $0.hasSuffix("settings.local.json") }, file: file, line: line)
        for relative in paths where relative.hasSuffix(".sqlite") {
            let target = base.appendingPathComponent(relative)
            let ownedCapture = target.path.utf8.elementsEqual(capture.appendingPathComponent("archive.sqlite").path.utf8)
            var configuration = Configuration(); configuration.readonly = !ownedCapture
            var databasePath = target.path
            if ownedCapture {
                // Only this invocation's explicit fixture-owned cold WAL main
                // may initialize its sidecars. Never apply this to identity
                // markers, an arbitrary SQLite path, or a real provider store.
                var uri = URLComponents(url: target, resolvingAgainstBaseURL: false)!
                uri.queryItems = [URLQueryItem(name: "mode", value: "rw")]
                databasePath = uri.url!.absoluteString
                configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
            }
            let database = try DatabaseQueue(path: databasePath, configuration: configuration)
            defer { try? database.close() }
            let query: (Database) throws -> [String] = {
                try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE name IN ('sessions', 'messages', 'session_fts', 'sessions_fts', 'embeddings')")
            }
            let forbidden: [String]
            if ownedCapture {
                forbidden = try database.writeWithoutTransaction { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA query_only"), 1, file: file, line: line)
                    return try query(db)
                }
            } else { forbidden = try database.read(query) }
            try database.close()
            XCTAssertTrue(forbidden.isEmpty, relative, file: file, line: line)
        }
    }
}

final class RuntimeHTTPReplica: @unchecked Sendable {
    let baseURL: URL
    let token: String
    let task: Task<Void, Error>
    init(baseURL: URL, token: String, task: Task<Void, Error>) { self.baseURL = baseURL; self.token = token; self.task = task }
    static func start(id: String, parent: URL) async throws -> RuntimeHTTPReplica {
        let root = parent.appendingPathComponent("replica-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let token = "synthetic-\(id)-runtime-token"
        let configuration = EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: 0,
            storeRoot: root.appendingPathComponent("legacy"), bearerToken: "synthetic-\(id)-legacy-token",
            atRestKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            archiveV2: .init(serverID: id, root: root.appendingPathComponent("archive"), bearerToken: token,
                atRestKey: SymmetricKey(data: Data(repeating: id == "hq" ? 11 : 12, count: 32)), publicationsEnabled: true))
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: configuration)
        let port = RuntimeLocked<Int?>(nil)
        let ready = XCTestExpectation(description: "runtime \(id) loopback listener")
        let task = Task { try await app.run { bound in port.update { $0 = bound }; ready.fulfill() } }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 10) == .completed, let bound = port.value else {
            task.cancel(); _ = try? await task.value; throw RuntimeFixture.Failure.deadline
        }
        let result = RuntimeHTTPReplica(baseURL: URL(string: "http://127.0.0.1:\(bound)")!, token: token, task: task)
        do {
            let deadline = Date().addingTimeInterval(5)
            while true {
                if (try? await result.count()) != nil { return result }
                guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                try await Task.sleep(for: .milliseconds(25))
            }
        } catch { await result.stop(); throw error }
    }
    func stop() async { task.cancel(); _ = try? await task.value }
    func count() async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/archive/publications"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let items = page["items"] as? [[String: Any]] else { throw RuntimeFixture.Failure.unsafeFixture }
        return items.count
    }
}

struct RuntimeReplicas {
    let hq: RuntimeHTTPReplica
    let m1: RuntimeHTTPReplica
    static func start(parent: URL) async throws -> Self {
        let hq = try await RuntimeHTTPReplica.start(id: "hq", parent: parent)
        do { return try await .init(hq: hq, m1: RuntimeHTTPReplica.start(id: "m1", parent: parent)) }
        catch { await hq.stop(); throw error }
    }
    func stop() async { await hq.stop(); await m1.stop() }
}
