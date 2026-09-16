import CryptoKit
import Darwin
import Foundation
import GRDB
import Network
import SQLite3
import XCTest
@testable import EngramCollectorCore
@testable import EngramRemoteServerCore

private typealias Runtime = EngramCollectorCore.CollectorRuntime
private typealias RuntimeError = EngramCollectorCore.CollectorRuntimeError

final class CollectorRuntimeTests: XCTestCase {
    func testResidentDiscoversNewDirectoryWhileReplicaResponseIsPending() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = RuntimeLocked<[NWConnection]>([])
        let ready = XCTestExpectation(description: "slow replica listening")
        let received = XCTestExpectation(description: "slow replica received a request")
        let didReceive = RuntimeLocked(false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connections.update { $0.append(connection) }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard data?.isEmpty == false else { return }
                didReceive.update { seen in
                    if !seen { seen = true; received.fulfill() }
                }
                // Keep the connection open without replying until runtime cancellation.
            }
        }
        listener.start(queue: .global())
        defer {
            listener.cancel()
            connections.value.forEach { $0.cancel() }
        }
        do {
            await fulfillment(of: [ready], timeout: 5)
            let port = try XCTUnwrap(listener.port)
            var document = fixture.document(replicas: replicas)
            var block = try XCTUnwrap(document["collector"] as? [String: Any])
            var endpoints = try XCTUnwrap(block["replicas"] as? [[String: Any]])
            endpoints[1]["baseURL"] = "http://127.0.0.1:\(port.rawValue)"
            block["replicas"] = endpoints; document["collector"] = block
            try fixture.writeSettings(document)
            try fixture.writeTranscript("initial upload")
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                await fulfillment(of: [received], timeout: 5)
                let directory = fixture.sources.appendingPathComponent("new-history")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try fixture.writeTranscript("arrived during slow upload", name: "new-history/rollout-later.jsonl")
                let sql = "SELECT count(*) FROM collector_locators WHERE relative_path = 'new-history/rollout-later.jsonl'"
                let deadline = Date().addingTimeInterval(3)
                while try fixture.integer(sql) == 0, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(try fixture.integer(sql), 1, "resident discovery must advance before a slow replica replies")
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"), 0)
                try await runtime.stop()
                let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                try await reopened.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testResidentCapturesAndPublishesToHealthyReplicaWhileOtherReplicaRequestIsHeld() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        let listener = try NWListener(using: .tcp, on: .any)
        let connections = RuntimeLocked<[NWConnection]>([])
        let ready = XCTestExpectation(description: "slow replica listening")
        let received = XCTestExpectation(description: "slow replica received a request")
        let didReceive = RuntimeLocked(false)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connections.update { $0.append(connection) }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                guard data?.isEmpty == false else { return }
                didReceive.update { seen in
                    if !seen { seen = true; received.fulfill() }
                }
            }
        }
        listener.start(queue: .global())
        defer {
            listener.cancel()
            connections.value.forEach { $0.cancel() }
        }
        do {
            await fulfillment(of: [ready], timeout: 5)
            let port = try XCTUnwrap(listener.port)
            var document = fixture.document(replicas: replicas)
            var block = try XCTUnwrap(document["collector"] as? [String: Any])
            var endpoints = try XCTUnwrap(block["replicas"] as? [[String: Any]])
            endpoints[1]["baseURL"] = "http://127.0.0.1:\(port.rawValue)"
            block["replicas"] = endpoints; document["collector"] = block
            try fixture.writeSettings(document)
            try fixture.writeTranscript("initial upload", name: "rollout-one.jsonl", sessionID: "native-runtime-first")
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                await fulfillment(of: [received], timeout: 5)
                let firstHQ = Date().addingTimeInterval(5)
                while try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'") < 1,
                      Date() < firstHQ {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), 1)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"), 0)
                try FileManager.default.createDirectory(at: fixture.sources.appendingPathComponent("later-history"),
                    withIntermediateDirectories: false)
                try fixture.writeTranscript("arrived while m1 still held", name: "later-history/rollout-two.jsonl",
                    sessionID: "native-runtime-later")
                let later = "SELECT count(*) FROM collector_locators WHERE relative_path = 'later-history/rollout-two.jsonl'"
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    let locators = try fixture.integer(later)
                    let captured = try fixture.publications().count
                    let hq = try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'")
                    if locators == 1, captured >= 2, hq >= 2 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(try fixture.integer(later), 1, "new source must be inventoried while m1 is held")
                let captured = try fixture.publications().count
                let hqAcknowledged = try fixture.integer(
                    "SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"
                )
                let hqPublished = try await replicas.hq.count()
                XCTAssertGreaterThanOrEqual(captured, 2, "new source must be durably captured while m1 is held")
                XCTAssertGreaterThanOrEqual(hqAcknowledged, 2, "healthy replica must ACK the new capture before m1 replies")
                XCTAssertEqual(hqPublished, captured)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"), 0,
                    "held replica must not ACK early")
                try await runtime.stop()
                let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                try await reopened.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testLargeHistoryCaptureBudgetAcceptsOneGiBAndRejectsUnboundedValues() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        var document = f.document()
        var collector = document["collector"] as! [String: Any]
        var budgets = collector["budgets"] as! [String: Any]
        budgets["maxCaptureBytes"] = 1_073_741_824
        collector["budgets"] = budgets; document["collector"] = collector
        try f.writeSettings(document)
        let runtime = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
        try await runtime.stop()
        budgets["maxCaptureBytes"] = 1_073_741_825
        collector["budgets"] = budgets; document["collector"] = collector
        try f.writeSettings(document)
        XCTAssertThrowsError(try Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
    }

    func testCommandCodeRuntimePublishesUnknownProjectToBothReplicas() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let primary = f.sources.appendingPathComponent("users-bing-code-project/session.jsonl")
            try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data((#"{"role":"user","sessionId":"native-commandcode","content":"preserve this history"}"# + "\n").utf8)
            try bytes.write(to: primary)
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-commandcode", "source": "commandcode",
                "rootPath": f.sources.path, "revision": 1]]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let publications = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(publications.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(publications.first).manifestSHA256))
            XCTAssertEqual(manifest.source, "commandcode")
            XCTAssertEqual(manifest.locator, primary.path)
            try await assertReplicaObjects(replicas, cas: cas, manifest: manifest, expected: bytes)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testCursorLegacyRuntimeAutomaticallyCapturesPagesAcrossRestartToBothReplicas() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let global = f.sources.appendingPathComponent("User/globalStorage")
            let workspace = f.sources.appendingPathComponent("User/workspaceStorage/owned")
            for directory in [global, workspace] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let ids = ["a:/%_", "z:/%_"]
            let queue = try DatabaseQueue(path: global.appendingPathComponent("state.vscdb").path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT)")
                for id in ids {
                    let value = try JSONSerialization.data(withJSONObject: ["composerId": id,
                        "conversation": [["type": 1, "text": "runtime legacy " + id]]], options: [.sortedKeys])
                    try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
                        arguments: ["composerData:" + id, String(decoding: value, as: UTF8.self)])
                }
            }
            try queue.close()
            let ownership = try DatabaseQueue(path: workspace.appendingPathComponent("state.vscdb").path)
            try await ownership.write { db in
                try db.execute(sql: "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
                let value = try JSONSerialization.data(withJSONObject: ["allComposers": ids.map { ["composerId": $0] }])
                try db.execute(sql: "INSERT INTO ItemTable(key, value) VALUES ('composer.composerData', ?)",
                    arguments: [String(decoding: value, as: UTF8.self)])
            }
            try ownership.close()
            try JSONSerialization.data(withJSONObject: ["folder": f.project.absoluteString])
                .write(to: workspace.appendingPathComponent("workspace.json"))
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "legacy", "source": "cursor", "rootPath": global.path,
                "revision": 1, "cursorLegacy": true]]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxCaptureFiles"] = 1
            collector["budgets"] = budgets; document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 100..<116 {
                _ = try await active!.runOnce(now: now)
                if try f.publications().count == 1 { break }
            }
            XCTAssertEqual(try f.publications().count, 1, "explicit legacy bootstrap must reach actual capture")
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 120..<140 {
                _ = try await active!.runOnce(now: now)
                if try f.publications().count >= 2,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            let publications = try f.publications()
            XCTAssertEqual(publications.count, 2, "restart must resume the bounded walk without republishing its first session")
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            var capturedIDs: [String] = []
            for publication in publications {
                let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: publication.manifestSHA256))
                var bytes = Data()
                for chunk in manifest.chunks { bytes.append(try cas.readObject(sha256: chunk.rawSHA256)) }
                let body = try EngramCollectorCore.ArchiveCursorLegacySession.decodeCanonical(bytes)
                XCTAssertEqual(body.cwd, f.project.path)
                capturedIDs.append(body.composerID)
            }
            XCTAssertEqual(capturedIDs, ids)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 2); XCTAssertEqual(m1, 2)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
            try await active!.stop(); active = nil
            let unrelated = try DatabaseQueue(path: global.appendingPathComponent("state.vscdb").path)
            try await unrelated.write { db in
                try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES ('unrelated-setting', 'changed')")
            }
            try unrelated.close()
            let oldDirty = try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'state.vscdb'")
            // Force a durable reconciliation while stopped, so this assertion
            // cannot pass merely because the native callback has not arrived.
            let inventory = try DatabaseQueue(path: f.inventory.path)
            try await inventory.write { db in
                try db.execute(sql: "UPDATE collector_roots SET requested_revision = requested_revision + 1 WHERE root_id = 'legacy'")
            }
            try inventory.close()
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 150..<250 {
                _ = try await active!.runOnce(now: now)
                try await Task.sleep(for: .milliseconds(20))
                if try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            XCTAssertEqual(try f.publications().count, 2, "unrelated shared-DB writes must not republish unchanged scoped rows")
            XCTAssertGreaterThan(try f.integer("SELECT dirty_revision FROM collector_locators WHERE relative_path = 'state.vscdb'"), oldDirty)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"), 0)
            // Drain earlier native main-file events before changing only a
            // sibling ownership input; no forced re-scan is used below.
            for now: Int64 in 300..<324 {
                _ = try await active!.runOnce(now: now)
                try await Task.sleep(for: .milliseconds(20))
            }
            let unchangedPair = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(root: global, databaseName: "state.vscdb")
            let newProject = f.base.appendingPathComponent("new-owner")
            try FileManager.default.createDirectory(at: newProject, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["folder": newProject.absoluteString])
                .write(to: workspace.appendingPathComponent("workspace.json"))
            for now: Int64 in 400..<500 {
                _ = try await active!.runOnce(now: now)
                try await Task.sleep(for: .milliseconds(20))
                if try f.publications().count == 4,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0,
                   try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") == 8 { break }
            }
            XCTAssertEqual(try f.publications().count, 4, "ownership-only changes must wake the acknowledged legacy database")
            let afterOwnership = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(root: global, databaseName: "state.vscdb")
            XCTAssertEqual(afterOwnership.databaseGeneration, unchangedPair.databaseGeneration)
            XCTAssertEqual(afterOwnership.walGeneration, unchangedPair.walGeneration)
            for publication in try f.publications().suffix(2) {
                let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: publication.manifestSHA256))
                XCTAssertEqual(manifest.replayLayout.cursorLegacySession?.cwd, newProject.path)
            }
            let finalHQ = try await replicas.hq.count(), finalM1 = try await replicas.m1.count()
            XCTAssertEqual(finalHQ, 4); XCTAssertEqual(finalM1, 4)
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testExplicitCursorLegacyConfigurationValidatesPairedRootsBeforeOpening() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let legacyPath = f.sources.appendingPathComponent("User/globalStorage").path
        let modern: [String: Any] = ["rootID": "modern", "source": "cursor",
            "rootPath": f.base.appendingPathComponent("modern").path, "revision": 1]
        let legacy: [String: Any] = ["rootID": "legacy", "source": "cursor",
            "rootPath": legacyPath, "revision": 1, "cursorLegacy": true, "cursorModernRootID": "modern"]
        func write(_ roots: [[String: Any]]) throws {
            var document = f.document()
            var block = document["collector"] as! [String: Any]
            block["roots"] = roots; document["collector"] = block
            try f.writeSettings(document)
        }
        try write([modern, legacy])
        let runtime = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
        try await runtime.stop()
        var standalone = legacy; standalone.removeValue(forKey: "cursorModernRootID")
        try write([standalone])
        let single = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
        try await single.stop()
        for changes: [String: Any] in [
            ["cursorModernRootID": "missing"], ["cursorModernRootID": "legacy"],
            ["cursorLegacy": false], ["cursorLegacy": "true"],
            ["rootPath": f.sources.path], ["source": "codex"]
        ] {
            var invalid = legacy
            for (key, value) in changes { invalid[key] = value }
            try write([modern, invalid])
            XCTAssertThrowsError(try Runtime.open(settingsURL: f.settings, secretLoader: f.secret)) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
            }
        }
    }

    func testRestartDeliversPendingArchivesWithMissingOrReplacedSourceWithoutRebinding() async throws {
        for replaceSource in [false, true] {
            let f = try RuntimeFixture(); defer { f.remove() }
            let replicas = try await RuntimeReplicas.start(parent: f.base)
            var active: Runtime?
            do {
                try f.writeTranscript("captured before source disappears")
                try f.writeSettings(f.document(replicas: replicas))
                active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: { id in
                    "wrong-credential-" + id
                }))
                for now: Int64 in 100..<132 {
                    _ = try await active!.runOnce(now: now)
                    if try !f.publications().isEmpty { break }
                }
                let original = try f.publications()
                XCTAssertEqual(original.count, 1)
                XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
                let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-codex'"
                let binding = try f.integerRow(bindingSQL)
                try await active!.stop(); active = nil
                let held = f.base.appendingPathComponent("held-original-source")
                try FileManager.default.moveItem(at: f.sources, to: held)
                if replaceSource {
                    try FileManager.default.createDirectory(at: f.sources, withIntermediateDirectories: false)
                    try f.writeTranscript("replacement must never join original stream")
                }
                active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
                let delivered = try await f.drive(active!, acknowledged: 2)
                XCTAssertEqual(delivered, original)
                XCTAssertEqual(try f.integerRow(bindingSQL), binding)
                for now: Int64 in 2000..<2004 {
                    let cycle = try await active!.runOnce(now: now)
                    XCTAssertEqual(cycle.captured, 0)
                    XCTAssertGreaterThan(cycle.deferred, 0)
                }
                XCTAssertEqual(try f.publications(), original)
                XCTAssertEqual(FileManager.default.fileExists(atPath: f.sources.path), replaceSource)
                let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
                try await active!.stop(); active = nil
                await replicas.stop()
            } catch {
                try? await active?.stop()
                await replicas.stop()
                throw error
            }
        }
    }

    func testWindsurfHookRestartRecoversFrozenReservationAfterSourceDeletion() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        _ = try writeWindsurfTranscript(f, text: "unpublished windsurf before source disappears")
        let root = EngramCollectorCore.CollectorRootConfiguration(
            rootID: "runtime-windsurf", source: .windsurf, rootPath: f.sources.appendingPathComponent("transcripts").path, revision: 1)
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(
            enabled: true, shadowRoot: f.shadow, identityCatalog: f.identity, ownerRunID: UUID().uuidString))
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: f.capture, machineID: RuntimeFixture.machineID)
        try catalog.migrate()
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
        _ = try owner.enrollAndActivateRoot(root)
        _ = try owner.applyEvents(
            configuration: root, expectedCheckpoint: try owner.rootState(rootID: root.rootID)?.eventCheckpoint,
            nextCheckpoint: .init(epoch: "fixture-events", cursor: UUID().uuidString),
            dirtyRelativePaths: ["session.jsonl"],
            budget: .init(maxIncomingPaths: 8, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096,
                maxCheckpointUTF8Bytes: 512))
        enum SeedFailure: Error, Equatable { case injected }
        let seeded = RuntimeLocked<EngramCollectorCore.ArchiveCaptureResult?>(nil)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { result in
            seeded.update { $0 = result }
            throw SeedFailure.injected
        })
        let worker = try EngramCollectorCore.CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: [root],
            replicas: [
                .init(replicaID: "hq", baseURL: URL(string: "https://hq.invalid")!, bearerToken: "seed-hq-token"),
                .init(replicaID: "m1", baseURL: URL(string: "https://m1.invalid")!, bearerToken: "seed-m1-token"),
            ],
            policy: { try EngramCollectorCore.CollectorPrivacyPolicy(
                revision: 1, excludedProjectRoots: [], allowedSources: [.windsurf]) },
            testHooks: hooks)
        do {
            _ = try await worker.runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? SeedFailure, .injected) }
        let reserved = try XCTUnwrap(owner.captureReservations(limit: 8).first)
        let durable = try XCTUnwrap(seeded.value)
        XCTAssertTrue(try owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertFalse(try catalog.unboundCaptures(limit: 8).isEmpty)
        try catalog.close()
        try owner.close()
        let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-windsurf'"
        let binding = try f.integerRow(bindingSQL)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-windsurf", "source": "windsurf",
                "parseFormat": "windsurfHookTranscript", "rootPath": f.sources.appendingPathComponent("transcripts").path, "revision": 1]]
            document["collector"] = collector
            try f.writeSettings(document)
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            try await active!.start()
            try await f.awaitACKs(2)
            let published = try f.publications()
            XCTAssertEqual(published.count, 1)
            let envelope = try XCTUnwrap(published.first)
            XCTAssertEqual(envelope.sequence, reserved.sequence)
            XCTAssertEqual(envelope.collectorEpoch, reserved.collectorEpoch)
            XCTAssertEqual(envelope.manifestSHA256, durable.capture.unboundManifestSHA256)
            var original = Data()
            for chunk in durable.manifest.chunks { original.append(try cas.readObject(sha256: chunk.rawSHA256)) }
            for replica in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in durable.manifest.chunks {
                    restored.append(try await replica.getSyntheticArchive("objects/\(chunk.rawSHA256)"))
                }
                XCTAssertEqual(restored, original)
            }
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.appendingPathComponent("transcripts").path))
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testWindsurfHookDefaultFormatWithholdsEscapedExcludedPaths() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let file = try writeWindsurfTranscript(f, text: "allowed primary")
            var raw = try Data(contentsOf: file)
            raw.append(Data((String(repeating: " ", count: 50_000) + "\n").utf8))
            raw.append(Data((#"{"type":"user_input","status":"done","user_input":{"user_response":"\u002fsensitive\u002fproject\u002ffile"}}"# + "\n").utf8))
            try raw.write(to: file)
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-windsurf", "source": "windsurf",
                "rootPath": f.sources.appendingPathComponent("transcripts").path, "revision": 1]]
            collector["privacy"] = ["revision": 1, "excludedProjectRoots": ["/sensitive"]]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 100..<132 { _ = try await active!.runOnce(now: now) }
            XCTAssertEqual(try f.publications().count, 1, "The capture must be discovered before it is withheld")
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 0); XCTAssertEqual(m1, 0)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testWindsurfHookSettingsPublishTwoGenerationsWithStableIdentity() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let file = try writeWindsurfTranscript(f, text: "windsurf first generation")
            let decoy = f.sources.appendingPathComponent("transcripts/cache/session.jsonl")
            try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("must not publish".utf8).write(to: decoy)
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-windsurf", "source": "windsurf", "parseFormat": "windsurfHookTranscript",
                "rootPath": f.sources.appendingPathComponent("transcripts").path, "revision": 1]]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxEntriesVisited"] = 16
            budgets["maxCandidateFiles"] = 8
            budgets["maxDirectoryOpens"] = 4
            collector["budgets"] = budgets
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let first = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(first.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(first.first).manifestSHA256))
            XCTAssertEqual(manifest.source, "windsurf")
            XCTAssertEqual(manifest.locator, file.path)
            for replica in [replicas.hq, replicas.m1] {
                var stored = Data()
                for chunk in manifest.chunks {
                    stored.append(try await replica.getSyntheticArchive("objects/\(chunk.rawSHA256)"))
                }
                XCTAssertEqual(stored, try Data(contentsOf: file))
            }
            XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: file)))
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1); XCTAssertEqual(firstM1, 1)
            _ = try writeWindsurfTranscript(f, text: "windsurf second longer generation")
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let second = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(second.count, 2)
            XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
            XCTAssertEqual(second.first?.collectorEpoch, second.last?.collectorEpoch)
            XCTAssertNotEqual(second.first?.manifestSHA256, second.last?.manifestSHA256)
            XCTAssertEqual(try XCTUnwrap(second.last).sequence, try XCTUnwrap(second.first).sequence + 1)
            XCTAssertEqual(Set(second.map(\.manifestSHA256)).count, 2)
            let later = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(second.last).manifestSHA256))
            XCTAssertEqual(later.source, "windsurf")
            XCTAssertEqual(later.locator, file.path)
            for replica in [replicas.hq, replicas.m1] {
                var stored = Data()
                for chunk in later.chunks {
                    stored.append(try await replica.getSyntheticArchive("objects/\(chunk.rawSHA256)"))
                }
                XCTAssertEqual(stored, try Data(contentsOf: file))
            }
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 2); XCTAssertEqual(m1, 2)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testAntigravityCLIRestartRecoversFrozenReservationAfterSourceDeletion() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        _ = try writeAntigravityTranscript(f, text: "unpublished antigravity before source disappears")
        let root = EngramCollectorCore.CollectorRootConfiguration(
            rootID: "runtime-antigravity", source: .antigravity, rootPath: f.sources.path, revision: 1)
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(
            enabled: true, shadowRoot: f.shadow, identityCatalog: f.identity, ownerRunID: UUID().uuidString))
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: f.capture, machineID: RuntimeFixture.machineID)
        try catalog.migrate()
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
        _ = try owner.enrollAndActivateRoot(root)
        _ = try owner.applyEvents(
            configuration: root, expectedCheckpoint: try owner.rootState(rootID: root.rootID)?.eventCheckpoint,
            nextCheckpoint: .init(epoch: "fixture-events", cursor: UUID().uuidString),
            dirtyRelativePaths: ["session/.system_generated/logs/transcript.jsonl"],
            budget: .init(maxIncomingPaths: 8, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096,
                maxCheckpointUTF8Bytes: 512))
        enum SeedFailure: Error, Equatable { case injected }
        let seeded = RuntimeLocked<EngramCollectorCore.ArchiveCaptureResult?>(nil)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { result in
            seeded.update { $0 = result }
            throw SeedFailure.injected
        })
        let worker = try EngramCollectorCore.CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: [root],
            replicas: [
                .init(replicaID: "hq", baseURL: URL(string: "https://hq.invalid")!, bearerToken: "seed-hq-token"),
                .init(replicaID: "m1", baseURL: URL(string: "https://m1.invalid")!, bearerToken: "seed-m1-token"),
            ],
            policy: { try EngramCollectorCore.CollectorPrivacyPolicy(
                revision: 1, excludedProjectRoots: [], allowedSources: [.antigravity]) },
            testHooks: hooks)
        do {
            _ = try await worker.runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? SeedFailure, .injected) }
        let reserved = try XCTUnwrap(owner.captureReservations(limit: 8).first)
        let durable = try XCTUnwrap(seeded.value)
        XCTAssertTrue(try owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertFalse(try catalog.unboundCaptures(limit: 8).isEmpty)
        try catalog.close()
        try owner.close()
        let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-antigravity'"
        let binding = try f.integerRow(bindingSQL)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-antigravity", "source": "antigravity",
                "parseFormat": "antigravityCLITranscript", "rootPath": f.sources.path, "revision": 1]]
            document["collector"] = collector
            try f.writeSettings(document)
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            try await active!.start()
            try await f.awaitACKs(2)
            let published = try f.publications()
            XCTAssertEqual(published.count, 1)
            let envelope = try XCTUnwrap(published.first)
            XCTAssertEqual(envelope.sequence, reserved.sequence)
            XCTAssertEqual(envelope.collectorEpoch, reserved.collectorEpoch)
            XCTAssertEqual(envelope.manifestSHA256, durable.capture.unboundManifestSHA256)
            var original = Data()
            for chunk in durable.manifest.chunks { original.append(try cas.readObject(sha256: chunk.rawSHA256)) }
            for replica in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in durable.manifest.chunks {
                    restored.append(try await replica.getSyntheticArchive("objects/\(chunk.rawSHA256)"))
                }
                XCTAssertEqual(restored, original)
            }
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.path))
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testRestartRecoversUnpublishedReservationAfterSourceRemovedWithoutRebinding() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        try f.writeTranscript("unpublished reservation before source disappears")
        let root = EngramCollectorCore.CollectorRootConfiguration(
            rootID: "runtime-codex", source: .codex, rootPath: f.sources.path, revision: 1)
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(
            enabled: true, shadowRoot: f.shadow, identityCatalog: f.identity, ownerRunID: UUID().uuidString))
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: f.capture, machineID: RuntimeFixture.machineID)
        try catalog.migrate()
        let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
        _ = try owner.enrollAndActivateRoot(root)
        _ = try owner.applyEvents(
            configuration: root, expectedCheckpoint: try owner.rootState(rootID: root.rootID)?.eventCheckpoint,
            nextCheckpoint: .init(epoch: "fixture-events", cursor: UUID().uuidString),
            dirtyRelativePaths: ["rollout-one.jsonl"],
            budget: .init(maxIncomingPaths: 8, maxPathUTF8Bytes: 1_024, maxTotalPathUTF8Bytes: 4_096,
                maxCheckpointUTF8Bytes: 512))
        enum SeedFailure: Error, Equatable { case injected }
        let seeded = RuntimeLocked<EngramCollectorCore.ArchiveCaptureResult?>(nil)
        let hooks = EngramCollectorCore.CollectorPublicationWorkerTestHooks(afterCapture: { result in
            seeded.update { $0 = result }
            throw SeedFailure.injected
        })
        let worker = try EngramCollectorCore.CollectorPublicationWorker(
            owner: owner, catalog: catalog, cas: cas, roots: [root],
            replicas: [
                .init(replicaID: "hq", baseURL: URL(string: "https://hq.invalid")!, bearerToken: "seed-hq-token"),
                .init(replicaID: "m1", baseURL: URL(string: "https://m1.invalid")!, bearerToken: "seed-m1-token"),
            ],
            policy: { try EngramCollectorCore.CollectorPrivacyPolicy(
                revision: 1, excludedProjectRoots: [], allowedSources: [.claudeCode, .codex]) },
            testHooks: hooks)
        do {
            _ = try await worker.runOnce(now: 100)
            XCTFail("expected interruption after immutable capture and before publication")
        } catch { XCTAssertEqual(error as? SeedFailure, .injected) }
        let reserved = try XCTUnwrap(owner.captureReservations(limit: 8).first)
        let durable = try XCTUnwrap(seeded.value)
        XCTAssertTrue(try owner.publicationIntents(limit: 8).isEmpty)
        XCTAssertFalse(try catalog.unboundCaptures(limit: 8).isEmpty)
        try catalog.close()
        try owner.close()
        let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-codex'"
        let binding = try f.integerRow(bindingSQL)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            try f.writeSettings(f.document(replicas: replicas))
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            try await active!.start()
            try await f.awaitACKs(2)
            let published = try f.publications()
            XCTAssertEqual(published.count, 1)
            let envelope = try XCTUnwrap(published.first)
            XCTAssertEqual(envelope.sequence, reserved.sequence)
            XCTAssertEqual(envelope.collectorEpoch, reserved.collectorEpoch)
            XCTAssertEqual(envelope.manifestSHA256, durable.capture.unboundManifestSHA256)
            var original = Data()
            for chunk in durable.manifest.chunks { original.append(try cas.readObject(sha256: chunk.rawSHA256)) }
            for replica in [replicas.hq, replicas.m1] {
                var restored = Data()
                for chunk in durable.manifest.chunks {
                    restored.append(try await replica.getSyntheticArchive("objects/\(chunk.rawSHA256)"))
                }
                XCTAssertEqual(restored, original)
            }
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_capture_reservations"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publications"), 1)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.path))
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testMissingConfiguredSourceRootDoesNotBlockHealthyRootAndBindsOnlyWhenConfiguredPathAppears() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            try f.writeTranscript("runtime missing-root healthy-codex")
            let absent = f.base.appendingPathComponent("absent-legacy/User/globalStorage")
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().deletingLastPathComponent().path))
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [
                ["rootID": "gone-legacy", "source": "cursor", "rootPath": absent.path,
                    "revision": 1, "cursorLegacy": true],
                ["rootID": "runtime-codex", "source": "codex", "rootPath": f.sources.path, "revision": 1],
            ]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            // start() and runOnce share startEventsIfNeeded; a missing leading
            // root must not abort the healthy Codex worker/replica path.
            try await active!.start()
            try await f.awaitACKs(2)
            let first = try f.publications()
            XCTAssertEqual(first.count, 1)
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1)
            XCTAssertEqual(firstM1, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_roots WHERE root_id = 'gone-legacy'"), 0)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_root_bindings WHERE root_id = 'gone-legacy'"), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
            let codexBinding = try f.integerRow("""
                SELECT device, inode, generation, birth_seconds, birth_nanoseconds
                FROM collector_root_bindings WHERE root_id = 'runtime-codex' AND root_revision = 1
                """)
            XCTAssertEqual(codexBinding.count, 5)

            let staged = f.base.appendingPathComponent("staged-legacy/User/globalStorage")
            let workspace = staged.deletingLastPathComponent().appendingPathComponent("workspaceStorage/owned")
            for directory in [staged, workspace] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let queue = try DatabaseQueue(path: staged.appendingPathComponent("state.vscdb").path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT)")
                let value = try JSONSerialization.data(withJSONObject: ["composerId": "late",
                    "conversation": [["type": 1, "text": "runtime late-appear"]]], options: [.sortedKeys])
                try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
                    arguments: ["composerData:late", String(decoding: value, as: UTF8.self)])
            }
            try queue.close()
            let ownership = try DatabaseQueue(path: workspace.appendingPathComponent("state.vscdb").path)
            try await ownership.write { db in
                try db.execute(sql: "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
                let value = try JSONSerialization.data(withJSONObject: ["allComposers": [["composerId": "late"]]])
                try db.execute(sql: "INSERT INTO ItemTable(key, value) VALUES ('composer.composerData', ?)",
                    arguments: [String(decoding: value, as: UTF8.self)])
            }
            try ownership.close()
            try JSONSerialization.data(withJSONObject: ["folder": f.project.absoluteString])
                .write(to: workspace.appendingPathComponent("workspace.json"))

            // Publish a complete source tree atomically so the resident loop
            // observes late availability, not a partially written fixture.
            try FileManager.default.moveItem(at: staged.deletingLastPathComponent().deletingLastPathComponent(),
                to: absent.deletingLastPathComponent().deletingLastPathComponent())
            try await f.awaitACKs(4)
            let all = try f.publications()
            XCTAssertEqual(all.count, 2)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertTrue(all.contains(firstPublication), "healthy Codex publication must survive late binding of the other root")
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            func inspect(_ publication: EngramCollectorCore.CollectorPublicationEnvelope) throws -> EngramCollectorCore.ArchiveSourceManifest {
                try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: publication.manifestSHA256))
            }
            let late = try XCTUnwrap(all.map(inspect).first { $0.replayLayout.cursorLegacySession != nil })
            XCTAssertEqual(late.replayLayout.cursorLegacySession?.composerID, "late")
            XCTAssertEqual(late.replayLayout.cursorLegacySession?.cwd, f.project.path)
            XCTAssertEqual(try f.integerRow("""
                SELECT device, inode, generation, birth_seconds, birth_nanoseconds
                FROM collector_root_bindings WHERE root_id = 'runtime-codex' AND root_revision = 1
                """), codexBinding)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_root_bindings WHERE root_id = 'gone-legacy' AND root_revision = 1"), 1)
            let finalHQ = try await replicas.hq.count(), finalM1 = try await replicas.m1.count()
            XCTAssertEqual(finalHQ, 2)
            XCTAssertEqual(finalM1, 2)
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testLiveCoordinatorUnavailableOrReplacedSourceDoesNotRebindAndSameInodeCanReappear() async throws {
        for replaceSource in [false, true] {
            let f = try RuntimeFixture(); defer { f.remove() }
            let replicas = try await RuntimeReplicas.start(parent: f.base)
            var active: Runtime?
            do {
                try f.writeTranscript("live coordinator first generation")
                try f.writeSettings(f.document(replicas: replicas))
                active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
                let original = try await f.drive(active!, acknowledged: 2)
                XCTAssertEqual(original.count, 1)
                let bindingSQL = """
                    SELECT device, inode, generation, birth_seconds, birth_nanoseconds
                    FROM collector_root_bindings WHERE root_id = 'runtime-codex' AND root_revision = 1
                    """
                let binding = try f.integerRow(bindingSQL)
                let held = f.base.appendingPathComponent("held-live-source")
                try FileManager.default.moveItem(at: f.sources, to: held)
                if replaceSource {
                    try FileManager.default.createDirectory(at: f.sources, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    try f.writeTranscript("replacement must never join the live coordinator stream")
                }
                var sawUnavailable = false
                for now: Int64 in 2000..<2008 {
                    let cycle = try await active!.runOnce(now: now)
                    XCTAssertEqual(cycle.captured, 0)
                    if cycle.deferred > 0 { sawUnavailable = true }
                }
                XCTAssertTrue(sawUnavailable, "live watch must notice a missing or replaced root")
                XCTAssertEqual(try f.publications(), original)
                XCTAssertEqual(try f.integerRow(bindingSQL), binding)
                XCTAssertEqual(FileManager.default.fileExists(atPath: f.sources.path), replaceSource)
                if !replaceSource {
                    try FileManager.default.moveItem(at: held, to: f.sources)
                    try f.writeTranscript("same inode reappearance is a new generation")
                    let resumed = try await f.drive(active!, acknowledged: 4)
                    XCTAssertEqual(resumed.count, 2)
                    XCTAssertEqual(resumed[0], original[0])
                    XCTAssertGreaterThan(resumed[1].sequence, original[0].sequence)
                    XCTAssertEqual(try f.integerRow(bindingSQL), binding)
                }
                try await active!.stop(); active = nil
                await replicas.stop()
            } catch {
                try? await active?.stop()
                await replicas.stop()
                throw error
            }
        }
    }

    func testLiveCoordinatorSourceLossDoesNotMaskMissingInventory() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            try f.writeTranscript("published before inventory disappears")
            try f.writeSettings(f.document(replicas: replicas))
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let published = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(published.count, 1)
            let originalInventory = f.inventory.deletingLastPathComponent()
            let held = f.base.appendingPathComponent("held-live-inventory")
            try FileManager.default.moveItem(at: originalInventory, to: held)
            try FileManager.default.removeItem(at: f.sources)
            do {
                _ = try await active!.runOnce(now: 3000)
                XCTFail("missing owned inventory must propagate, never become source deferral")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: originalInventory.path))
            }
            try FileManager.default.moveItem(at: held, to: originalInventory)
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testLiveCoordinatorRecoveryRequiredStillReenrollsWithoutRebinding() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            try f.writeTranscript("recovery still uses full enrollment")
            try f.writeSettings(f.document(replicas: replicas))
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let original = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(original.count, 1)
            let bindingSQL = """
                SELECT device, inode, generation, birth_seconds, birth_nanoseconds
                FROM collector_root_bindings WHERE root_id = 'runtime-codex' AND root_revision = 1
                """
            let binding = try f.integerRow(bindingSQL)
            let beforeRequested = try f.integer("SELECT requested_revision FROM collector_roots WHERE root_id = 'runtime-codex'")
            let inventory = try DatabaseQueue(path: f.inventory.path)
            try await inventory.write { db in
                try db.execute(sql: """
                    UPDATE collector_roots SET requested_revision = requested_revision + 1
                    WHERE root_id = 'runtime-codex'
                    """)
            }
            try inventory.close()
            var recovered = false
            for now: Int64 in 4000..<4032 {
                _ = try await active!.runOnce(now: now)
                let requested = try f.integer("SELECT requested_revision FROM collector_roots WHERE root_id = 'runtime-codex'")
                let completed = try f.integer("SELECT completed_revision FROM collector_roots WHERE root_id = 'runtime-codex'")
                if requested > beforeRequested, completed == requested {
                    recovered = true
                    break
                }
            }
            XCTAssertTrue(recovered, "recoveryRequired must re-enroll and finish bootstrap")
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            try f.writeTranscript("post-recovery generation is larger than the first")
            let after = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(after.count, 2)
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testPairedModernIDRemovalRecapturesLegacyWithUnchangedMainAndWAL() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let modern = f.base.appendingPathComponent("modern")
            let global = f.sources.appendingPathComponent("User/globalStorage")
            let workspace = f.sources.appendingPathComponent("User/workspaceStorage/owned")
            let store = modern.appendingPathComponent("chats/ws/owned/store.db")
            let transcript = modern.appendingPathComponent("projects/proj/agent-transcripts/owned/owned.jsonl")
            let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
            for directory in [global, workspace, store.deletingLastPathComponent(),
                              transcript.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let queue = try DatabaseQueue(path: global.appendingPathComponent("state.vscdb").path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT)")
                let value = try JSONSerialization.data(withJSONObject: ["composerId": "owned",
                    "conversation": [["type": 1, "text": "paired legacy owned"]]], options: [.sortedKeys])
                try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
                    arguments: ["composerData:owned", String(decoding: value, as: UTF8.self)])
            }
            try queue.close()
            let ownership = try DatabaseQueue(path: workspace.appendingPathComponent("state.vscdb").path)
            try await ownership.write { db in
                try db.execute(sql: "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
                let value = try JSONSerialization.data(withJSONObject: ["allComposers": [["composerId": "owned"]]])
                try db.execute(sql: "INSERT INTO ItemTable(key, value) VALUES ('composer.composerData', ?)",
                    arguments: [String(decoding: value, as: UTF8.self)])
            }
            try ownership.close()
            try JSONSerialization.data(withJSONObject: ["folder": f.project.absoluteString])
                .write(to: workspace.appendingPathComponent("workspace.json"))
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(store.path, &database), SQLITE_OK)
            let writer = try XCTUnwrap(database)
            func sql(_ statement: String) throws {
                guard sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK else {
                    throw NSError(domain: "PairedModernIDRemovalFixture", code: Int(sqlite3_errcode(writer)))
                }
            }
            try sql("""
                PRAGMA journal_mode=WAL;
                PRAGMA wal_autocheckpoint=0;
                CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                PRAGMA wal_checkpoint(TRUNCATE);
                """)
            let stored = try JSONSerialization.data(withJSONObject: ["cwd": f.project.path], options: [.sortedKeys])
            let hex = stored.map { String(format: "%02x", $0) }.joined()
            try sql("""
                BEGIN;
                INSERT INTO meta(key, value) VALUES ('0', '\(hex)');
                INSERT INTO blobs(id, data) VALUES ('user', '{"role":"user","content":"paired modern owned"}');
                COMMIT;
                """)
            sqlite3_close(writer)
            try stored.write(to: meta)
            try Data("{\"role\":\"user\",\"content\":\"paired modern owned\"}\n".utf8).write(to: transcript)
            for path in [store, URL(fileURLWithPath: store.path + "-wal"), meta, transcript] where FileManager.default.fileExists(atPath: path.path) {
                XCTAssertEqual(chmod(path.path, 0o600), 0)
            }
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [
                ["rootID": "modern", "source": "cursor", "rootPath": modern.path, "revision": 1, "parseFormat": "cursor"],
                ["rootID": "legacy", "source": "cursor", "rootPath": global.path, "revision": 1,
                    "cursorLegacy": true, "cursorModernRootID": "modern"],
            ]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxCaptureFiles"] = 4
            collector["budgets"] = budgets; document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            func inspect(_ publication: EngramCollectorCore.CollectorPublicationEnvelope) throws -> EngramCollectorCore.ArchiveSourceManifest {
                try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: publication.manifestSHA256))
            }
            for now: Int64 in 100..<140 {
                _ = try await active!.runOnce(now: now)
                if try f.publications().count == 1,
                   try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") == 0 { break }
            }
            let first = try f.publications()
            XCTAssertEqual(first.count, 1, "paired modern ID must suppress the matching legacy composer")
            let firstManifest = try inspect(XCTUnwrap(first.first))
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(firstManifest))
            XCTAssertNil(firstManifest.replayLayout.cursorLegacySession)
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1); XCTAssertEqual(firstM1, 1)
            // Drain earlier native main-file events before the unchanged-pair
            // snapshot and modern-ID removal; a late main callback must not
            // look like peer-removal recapture.
            for now: Int64 in 140..<164 {
                _ = try await active!.runOnce(now: now)
                try await Task.sleep(for: .milliseconds(20))
            }
            let legacyMain = global.appendingPathComponent("state.vscdb")
            let legacyWAL = URL(fileURLWithPath: legacyMain.path + "-wal")
            let unchangedPair = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(
                root: global, databaseName: "state.vscdb")
            let mainBytes = try Data(contentsOf: legacyMain)
            let walBytes = FileManager.default.fileExists(atPath: legacyWAL.path) ? try Data(contentsOf: legacyWAL) : nil
            try FileManager.default.removeItem(at: store.deletingLastPathComponent())
            try FileManager.default.removeItem(at: transcript.deletingLastPathComponent())
            for now: Int64 in 200..<240 {
                _ = try await active!.runOnce(now: now)
                if try f.publications().count == 2 { break }
            }
            let publications = try f.publications()
            XCTAssertEqual(publications.count, 2, "removing the paired modern ID must recapture the unchanged legacy composer")
            let recapture = try XCTUnwrap(publications.map(inspect).first { $0.replayLayout.cursorLegacySession != nil })
            XCTAssertEqual(recapture.replayLayout.cursorLegacySession?.composerID, "owned")
            XCTAssertEqual(recapture.replayLayout.cursorLegacySession?.cwd, f.project.path)
            var bytes = Data()
            for chunk in recapture.chunks { bytes.append(try cas.readObject(sha256: chunk.rawSHA256)) }
            let body = try EngramCollectorCore.ArchiveCursorLegacySession.decodeCanonical(bytes)
            XCTAssertEqual(body.composerID, "owned")
            XCTAssertEqual(body.cwd, f.project.path)
            let afterPair = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(
                root: global, databaseName: "state.vscdb")
            XCTAssertEqual(afterPair.databaseGeneration, unchangedPair.databaseGeneration)
            XCTAssertEqual(afterPair.walGeneration, unchangedPair.walGeneration)
            XCTAssertEqual(try Data(contentsOf: legacyMain), mainBytes)
            if let walBytes {
                XCTAssertEqual(try Data(contentsOf: legacyWAL), walBytes)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: legacyWAL.path))
            }
            let finalHQ = try await replicas.hq.count(), finalM1 = try await replicas.m1.count()
            XCTAssertEqual(finalHQ, 2); XCTAssertEqual(finalM1, 2)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

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

    func testLongPollBootstrapFinishesWithoutWaitingFullInterval_repro() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            for index in 0..<8 {
                let file = fixture.sources.appendingPathComponent("rollout-boot-\(index).jsonl")
                try Data().write(to: file)
                XCTAssertEqual(chmod(file.path, 0o600), 0)
            }
            try fixture.writeSettings(fixture.document(replicas: replicas, pollIntervalMilliseconds: 5_000))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let started = ContinuousClock.now
                try await runtime.start()
                let deadline = Date().addingTimeInterval(3)
                while try fixture.integer("SELECT count(*) FROM collector_locators") < 8 {
                    guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(25))
                }
                XCTAssertLessThan(started.duration(to: .now), .milliseconds(3_000),
                    "bootstrap slices must continue promptly under a 5000ms periodic deadline")
                XCTAssertEqual(
                    try fixture.integer("SELECT count(*) FROM collector_locators WHERE last_capture_id IS NOT NULL"),
                    0, "zero-byte bootstrap files must not satisfy continuation via captured/recovered")
                try await runtime.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testLongPollWatchingDirtyIsCapturedBeforePeriodicDeadline_repro() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("seed-before-watch")
            try fixture.writeSettings(fixture.document(replicas: replicas, pollIntervalMilliseconds: 5_000))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                try await fixture.awaitCaptured(relativePath: "rollout-one.jsonl", timeout: 3)
                try fixture.writeTranscript("arrived-while-watching", name: "rollout-watch.jsonl")
                try await fixture.awaitCaptured(relativePath: "rollout-watch.jsonl", timeout: 2.5)
                try await runtime.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testLongPollIdleSkipsExpensiveWorkUntilDeadlineAndStillDrainsLaterDirty_repro() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("idle-seed")
            try fixture.writeSettings(fixture.document(replicas: replicas, pollIntervalMilliseconds: 10_000))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                try await fixture.awaitCaptured(relativePath: "rollout-one.jsonl", timeout: 3)
                XCTAssertEqual(
                    CollectorCaptureScheduler.cheapWakeMilliseconds(intervalMilliseconds: 10_000), 1_000)
                XCTAssertFalse(CollectorCaptureScheduler.shouldRunCapture(
                    deadlineReached: false,
                    samples: [.init(phase: .watching, historyDone: true, queuedBatchCount: 0,
                                    pendingGap: false, historyWaiting: false)]),
                    "idle mailbox samples must not schedule expensive capture before the periodic deadline")
                XCTAssertTrue(CollectorCaptureScheduler.shouldRunCapture(
                    deadlineReached: true,
                    samples: [.init(phase: .watching, historyDone: true, queuedBatchCount: 0,
                                    pendingGap: false, historyWaiting: false)]))
                try fixture.writeTranscript("after-idle", name: "rollout-after-idle.jsonl")
                try await fixture.awaitCaptured(relativePath: "rollout-after-idle.jsonl", timeout: 2.5)
                try await runtime.stop()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testLongPollHistoryWaitAndZeroProgressDoNotBusySpin_repro() throws {
        XCTAssertEqual(CollectorCaptureScheduler.cheapWakeMilliseconds(intervalMilliseconds: 5_000), 1_000)
        XCTAssertFalse(CollectorCaptureScheduler.shouldRunCapture(
            deadlineReached: false,
            samples: [.init(phase: .recovering, historyDone: false, queuedBatchCount: 0,
                            pendingGap: false, historyWaiting: true)]))
        XCTAssertFalse(CollectorCaptureScheduler.shouldRunCapture(
            deadlineReached: false,
            samples: [.init(phase: .recovering, historyDone: false, queuedBatchCount: 0,
                            pendingGap: false, historyWaiting: false)]))
        XCTAssertTrue(CollectorCaptureScheduler.shouldRunCapture(
            deadlineReached: false,
            samples: [.init(phase: .recovering, historyDone: true, queuedBatchCount: 0,
                            pendingGap: false, historyWaiting: true)]))
        XCTAssertTrue(CollectorCaptureScheduler.shouldRunCapture(
            deadlineReached: false,
            samples: [.init(phase: .watching, historyDone: true, queuedBatchCount: 2,
                            pendingGap: false, historyWaiting: false)]))
        XCTAssertTrue(CollectorCaptureScheduler.shouldRunCapture(
            deadlineReached: false,
            samples: [.init(phase: .recoveryRequired, historyDone: false, queuedBatchCount: 0,
                            pendingGap: true, historyWaiting: false)]))
        XCTAssertTrue(CollectorCaptureScheduler.shouldContinuePromptly(.init(
            bootstrapProgressed: true, drainableBatchesRemaining: false, captured: 0, recovered: 0)))
        XCTAssertTrue(CollectorCaptureScheduler.shouldContinuePromptly(.init(
            bootstrapProgressed: false, drainableBatchesRemaining: true, captured: 0, recovered: 0)))
        XCTAssertTrue(CollectorCaptureScheduler.shouldContinuePromptly(.init(
            bootstrapProgressed: false, drainableBatchesRemaining: false, captured: 1, recovered: 0)))
        XCTAssertTrue(CollectorCaptureScheduler.shouldContinuePromptly(.init(
            bootstrapProgressed: false, drainableBatchesRemaining: false, captured: 0, recovered: 1)))
        XCTAssertFalse(CollectorCaptureScheduler.shouldContinuePromptly(.init(
            bootstrapProgressed: false, drainableBatchesRemaining: false, captured: 0, recovered: 0)))
        XCTAssertTrue(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .paused(.budget), entriesVisited: 2, candidateFiles: 2, directoriesOpened: 1, metadataBytes: 8)))
        XCTAssertTrue(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .progress, entriesVisited: 1, candidateFiles: 0, directoriesOpened: 0, metadataBytes: 0)))
        XCTAssertFalse(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .paused(.budget), entriesVisited: 0, candidateFiles: 0, directoriesOpened: 0, metadataBytes: 0)))
        XCTAssertFalse(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .paused(.diskPressure), entriesVisited: 2, candidateFiles: 2, directoriesOpened: 1, metadataBytes: 8)))
        XCTAssertFalse(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .finished, entriesVisited: 2, candidateFiles: 2, directoriesOpened: 1, metadataBytes: 8)))
        XCTAssertFalse(CollectorCaptureScheduler.bootstrapProgressed(.init(
            outcome: .blocked(.enumerationUnavailable), entriesVisited: 1, candidateFiles: 0, directoriesOpened: 1, metadataBytes: 4)))
    }

    func testLongPollStopCancelsIdleWaitWithoutWaitingInterval_repro() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try fixture.writeTranscript("stop-while-idle")
            try fixture.writeSettings(fixture.document(replicas: replicas, pollIntervalMilliseconds: 10_000))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                try await runtime.start()
                try await fixture.awaitCaptured(relativePath: "rollout-one.jsonl", timeout: 3)
                let began = ContinuousClock.now
                try await runtime.stop()
                XCTAssertLessThan(began.duration(to: .now), .milliseconds(2_000),
                    "stop must cancel the idle wait instead of joining the 10000ms interval")
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
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
            if variant == 0 { block["roots"] = [["rootID": "unsupported", "source": "unknown-source", "rootPath": fixture.sources.path, "revision": 1]] }
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

    func testDefaultClaudeRuntimeRecoversThreeSourceStreamsWithoutOriginalRoot() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            try writeCustomClaudeMiniMax(f, text: "shared-root native generation")
            let mini = f.sources.appendingPathComponent("synthetic-project/claude-session.jsonl")
            let miniBytes = try Data(contentsOf: mini)
            let lobster = f.sources.appendingPathComponent("lobsterai-project/s.jsonl")
            let claude = f.sources.appendingPathComponent("ordinary-project/s.jsonl")
            let claudeBytes = Data(String(decoding: miniBytes, as: UTF8.self)
                .replacingOccurrences(of: "MiniMax-M2.1", with: "claude-test").utf8)
            for file in [lobster, claude] {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try miniBytes.write(to: lobster)
            try claudeBytes.write(to: claude)
            try f.writeSettings(customClaudeDocument(f, replicas: replicas, parseFormat: "claudeDefault"))
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings,
                secretLoader: { "unavailable-" + $0 }))
            for now: Int64 in 100..<132 {
                _ = try await active!.runOnce(now: now)
                if try f.publications().count == 3 { break }
            }
            let original = try f.publications()
            XCTAssertEqual(original.count, 3)
            XCTAssertEqual(Set(original.map(\.sourceInstanceID)).count, 3)
            XCTAssertTrue(original.allSatisfy { $0.sequence == 1 })
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
            try await active!.stop(); active = nil
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let recovered = try await f.drive(active!, acknowledged: 6)
            XCTAssertEqual(Set(try recovered.map { try $0.sha256() }), Set(try original.map { try $0.sha256() }))
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            var seen = Set<String>()
            for publication in recovered {
                let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self, from: cas.readManifest(sha256: publication.manifestSHA256))
                seen.insert(manifest.source)
                let bytes = manifest.source == "claude-code" ? claudeBytes : miniBytes
                try await assertReplicaObjects(replicas, cas: cas, manifest: manifest, expected: bytes)
            }
            XCTAssertEqual(seen, Set(["claude-code", "minimax", "lobsterai"]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.path))
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            if let active { try? await active.stop() }
            await replicas.stop()
            throw error
        }
    }

    func testJSONSettingsCustomClaudeProfilePublishesMiniMaxAsClaudeCode() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try writeCustomClaudeMiniMax(fixture, text: "custom-profile-minimax")
            try fixture.writeSettings(customClaudeDocument(fixture, replicas: replicas, parseFormat: "claudeCustomProfile"))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                var published: EngramCollectorCore.CollectorRuntimeCycle?
                for now: Int64 in 100..<132 {
                    let cycle = try await runtime.runOnce(now: now)
                    if cycle.captured > 0, cycle.acknowledgedHQ > 0, cycle.acknowledgedM1 > 0 {
                        published = cycle
                        break
                    }
                }
                let cycle = try XCTUnwrap(published, "JSON parseFormat=claudeCustomProfile must authorize MiniMax as claude-code")
                XCTAssertEqual(cycle.captured, 1)
                XCTAssertEqual(cycle.acknowledgedHQ, 1)
                XCTAssertEqual(cycle.acknowledgedM1, 1)
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

    func testJSONSettingsParseFormatChangeInvalidatesLiveCustomClaudeAuthority() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            try writeCustomClaudeMiniMax(fixture, text: "custom-profile-first")
            try fixture.writeSettings(customClaudeDocument(fixture, replicas: replicas, parseFormat: "claudeCustomProfile"))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                var published: EngramCollectorCore.CollectorRuntimeCycle?
                for now: Int64 in 100..<132 {
                    let cycle = try await runtime.runOnce(now: now)
                    if cycle.acknowledgedHQ > 0, cycle.acknowledgedM1 > 0 { published = cycle; break }
                }
                XCTAssertNotNil(published, "the custom-profile root must publish before the format rewrite")
                XCTAssertEqual(try fixture.integer(
                    "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 2)
                try writeCustomClaudeMiniMax(fixture, text: "custom-profile-after-format-change")
                try fixture.writeSettings(customClaudeDocument(fixture, replicas: replicas, parseFormat: "claudeDefault"))
                for now: Int64 in 200..<216 {
                    do { _ = try await runtime.runOnce(now: now) }
                    catch { XCTAssertEqual(error as? RuntimeError, .invalidConfiguration) }
                }
                XCTAssertEqual(try fixture.integer(
                    "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 2,
                    "a settings parseFormat rewrite must not keep publishing MiniMax under the previous forced format")
                try await runtime.stop()
                let reopened = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                do {
                    for now: Int64 in 300..<316 { _ = try await reopened.runOnce(now: now) }
                    XCTAssertEqual(try fixture.integer(
                        "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 4,
                        "reopening under claudeDefault must publish a distinct truthful MiniMax stream")
                    let publications = try fixture.publications()
                    XCTAssertEqual(Set(publications.map(\.sourceInstanceID)).count, 2)
                    let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                    let sources = try publications.map { publication in
                        try EngramCollectorCore.ArchiveCanonicalJSON.decode(EngramCollectorCore.ArchiveSourceManifest.self,
                            from: cas.readManifest(sha256: publication.manifestSHA256)).source
                    }
                    XCTAssertEqual(Set(sources), Set(["claude-code", "minimax"]))
                    try await reopened.stop()
                } catch { try? await reopened.stop(); throw error }
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testJSONSettingsRejectUnsupportedSourcesEvenWhenParseFormatIsPresent() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        for source in ["qwen", "iflow", "qoder", "commandcode", "minimax", "lobsterai"] {
            var document = fixture.document()
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [[
                "rootID": "runtime-unsupported", "source": source, "rootPath": fixture.sources.path,
                "revision": 1, "parseFormat": "claudeCustomProfile",
            ]]
            document["collector"] = collector
            try fixture.writeSettings(document)
            XCTAssertThrowsError(try Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret), source) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration, source)
            }
        }
    }

    func testOpenCodeOneImageBudgetResumesAfterRestartAndReauthorizesExcludedCapture() async throws {
        let f = try RuntimeFixture()
        defer { f.remove() }
        let source = f.sources.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        let writer = try XCTUnwrap(database)
        let excluded = f.base.appendingPathComponent("excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let db = try DatabaseQueue(path: source.path)
        try await db.writeWithoutTransaction { db in
            try db.execute(sql: """
                PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
                CREATE TABLE session(id TEXT PRIMARY KEY, directory TEXT, time_created INTEGER,
                    time_updated INTEGER, time_archived INTEGER);
                CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
                PRAGMA wal_checkpoint(TRUNCATE);
                """)
            for id in ["ses-A", "ses-B", "ses-C"] {
                try db.execute(sql: "INSERT INTO session VALUES (?, ?, 100, 200, NULL)",
                    arguments: [id, id == "ses-A" ? excluded.path : f.project.path])
                try db.execute(sql: "INSERT INTO message VALUES (?, ?, 100, ?)",
                    arguments: ["m-" + id, id, "{\"role\":\"user\"}"])
                try db.execute(sql: "INSERT INTO part VALUES (?, ?, 100, ?)",
                    arguments: ["p-" + id, "m-" + id, "{\"type\":\"text\",\"text\":\"" + id + "\"}"])
            }
        }
        try db.close()
        // Keep a live connection attached to the WAL while the collector cycles.
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; SELECT count(*) FROM session",
            nil, nil, nil), SQLITE_OK)
        let originalMain = try Data(contentsOf: source)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let originalWAL = try Data(contentsOf: wal)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-opencode", "source": "opencode",
                "rootPath": f.sources.path, "revision": 1, "parseFormat": "opencode"]]
            collector["privacy"] = ["revision": 1, "excludedProjectRoots": [excluded.path]]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxCaptureFiles"] = 1
            collector["budgets"] = budgets
            document["collector"] = collector
            try f.writeSettings(document)
            let first = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do {
                let deadline = Date().addingTimeInterval(10)
                while try f.integer("SELECT count(*) FROM collector_publications") == 0 {
                    _ = try await first.runOnce(now: Int64(Date().timeIntervalSince1970))
                    guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(try f.publications().count, 1)
                let firstHQ = try await replicas.hq.count()
                let firstM1 = try await replicas.m1.count()
                XCTAssertEqual(firstHQ, 0)
                XCTAssertEqual(firstM1, 0)
                try await first.stop()
            } catch { try? await first.stop(); throw error }
            let restarted = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do {
                let captures = try await f.drive(restarted, acknowledged: 4)
                XCTAssertEqual(captures.count, 3, "restart must resume after A rather than recapture or skip B/C")
                let eofDeadline = Date().addingTimeInterval(10)
                while try f.integer("SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision") > 0 {
                    _ = try await restarted.runOnce(now: Int64(Date().timeIntervalSince1970))
                    guard Date() < eofDeadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(try Data(contentsOf: source), originalMain)
                XCTAssertEqual(try Data(contentsOf: wal), originalWAL)
                XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
                database = nil
                try FileManager.default.removeItem(at: source)
                collector["privacy"] = ["revision": 2, "excludedProjectRoots": [String]()]
                document["collector"] = collector
                try f.writeSettings(document)
                let reauthorized = try await f.drive(restarted, acknowledged: 6)
                XCTAssertEqual(reauthorized.count, 3,
                    "A must be reauthorized from its stored image after the original source disappears")
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 3)
                XCTAssertEqual(m1Count, 3)
                try await restarted.stop()
                try f.assertNoProductIndex()
            } catch { try? await restarted.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testOpenCodeWALOnlyCommitsReachBothReplicasWithoutLocalIndexOrSourceMutation() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let source = fixture.sources.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        let writer = try XCTUnwrap(database)
        defer { sqlite3_close(writer) }
        func sql(_ statement: String) throws {
            guard sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "OpenCodeWALFixture", code: Int(sqlite3_errcode(writer)))
            }
        }
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, slug TEXT, agent TEXT,
                directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        let mainBytes = try Data(contentsOf: source)
        let cwd = fixture.project.path.replacingOccurrences(of: "'", with: "''")
        try sql("""
            BEGIN;
            INSERT INTO session VALUES ('ses-wal', NULL, 'native', 'build', '\(cwd)',
                'Native OpenCode WAL', 1788825600000, 1788825601000, NULL);
            INSERT INTO message VALUES ('m-user', 'ses-wal', 1788825601000, '{"role":"user"}');
            INSERT INTO part VALUES ('p-user', 'm-user', 1788825601000,
                '{"type":"text","text":"OpenCode WAL-only initial question"}');
            COMMIT;
            """)
        XCTAssertEqual(try Data(contentsOf: source), mainBytes, "the fixture must commit entirely in WAL")
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let initialWAL = try Data(contentsOf: wal)
        XCTAssertFalse(initialWAL.isEmpty)
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-opencode", "source": "opencode",
                "rootPath": fixture.sources.path, "revision": 1, "parseFormat": "opencode"]]
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let first = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(first.count, 1)
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: XCTUnwrap(first.first).manifestSHA256))
                XCTAssertEqual(manifest.source, "opencode")
                XCTAssertEqual(manifest.locator, source.path + "::ses-wal")
                XCTAssertEqual(try Data(contentsOf: source), mainBytes)
                XCTAssertEqual(try Data(contentsOf: wal), initialWAL, "Collector must not checkpoint or rewrite source WAL")
                try sql("""
                    BEGIN;
                    INSERT INTO message VALUES ('m-answer', 'ses-wal', 1788825602000,
                        '{"role":"assistant","tokens":{"input":96,"output":10,"cache":{"read":4}}}');
                    INSERT INTO part VALUES ('p-answer', 'm-answer', 1788825602000,
                        '{"type":"text","text":"OpenCode second WAL-only answer"}');
                    UPDATE session SET time_updated=1788825602000 WHERE id='ses-wal';
                    COMMIT;
                    """)
                let secondWAL = try Data(contentsOf: wal)
                let second = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(second.count, 2)
                XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
                XCTAssertNotEqual(second.first?.manifestSHA256, second.last?.manifestSHA256)
                XCTAssertEqual(try Data(contentsOf: source), mainBytes)
                XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 2)
                XCTAssertEqual(m1Count, 2)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testQwenJSONSettingsCaptureTwoGenerationsWithoutLocalIndexOrSourceRelabeling() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            let file = try writeQwenTranscript(fixture, text: "qwen first generation")
            try fixture.writeSettings(qwenDocument(fixture, replicas: replicas))
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let first = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(first.count, 1)
                let bytes = try Data(contentsOf: file)
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                    EngramCollectorCore.ArchiveSourceManifest.self,
                    from: cas.readManifest(sha256: XCTUnwrap(first.first).manifestSHA256))
                XCTAssertEqual(manifest.source, "qwen")
                XCTAssertEqual(manifest.locator, file.path)
                XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(bytes))
                _ = try writeQwenTranscript(fixture, text: "qwen second longer generation")
                let second = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(second.count, 2)
                XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
                XCTAssertNotEqual(second.first?.manifestSHA256, second.last?.manifestSHA256)
                let hq = try await replicas.hq.count()
                let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 2)
                XCTAssertEqual(m1, 2)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testAntigravityCLIDefaultFormatWithholdsEscapedExcludedPaths() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let file = try writeAntigravityTranscript(f, text: "allowed primary")
            var raw = try Data(contentsOf: file)
            raw.append(Data((String(repeating: " ", count: 50_000) + "\n").utf8))
            raw.append(Data((#"{"type":"USER_INPUT","content":"\u002fsensitive\u002fproject\u002ffile"}"# + "\n").utf8))
            try raw.write(to: file)
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-antigravity", "source": "antigravity",
                "rootPath": f.sources.path, "revision": 1]]
            collector["privacy"] = ["revision": 1, "excludedProjectRoots": ["/sensitive"]]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 100..<132 { _ = try await active!.runOnce(now: now) }
            XCTAssertEqual(try f.publications().count, 1, "The capture must be discovered before it is withheld")
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 0); XCTAssertEqual(m1, 0)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testAntigravityCLISettingsPublishTwoGenerationsWithStableIdentity() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let file = try writeAntigravityTranscript(f, text: "antigravity first generation")
            let decoy = f.sources.appendingPathComponent("session/cache/transcript.jsonl")
            try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("must not publish".utf8).write(to: decoy)
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-antigravity", "source": "antigravity", "parseFormat": "antigravityCLITranscript",
                "rootPath": f.sources.path, "revision": 1]]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxEntriesVisited"] = 16
            budgets["maxCandidateFiles"] = 8
            budgets["maxDirectoryOpens"] = 4
            collector["budgets"] = budgets
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let first = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(first.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(first.first).manifestSHA256))
            XCTAssertEqual(manifest.source, "antigravity")
            XCTAssertEqual(manifest.locator, file.path)
            XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: file)))
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1); XCTAssertEqual(firstM1, 1)
            _ = try writeAntigravityTranscript(f, text: "antigravity second longer generation")
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let second = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(second.count, 2)
            XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
            XCTAssertEqual(second.first?.collectorEpoch, second.last?.collectorEpoch)
            XCTAssertNotEqual(second.first?.manifestSHA256, second.last?.manifestSHA256)
            XCTAssertEqual(try XCTUnwrap(second.last).sequence, try XCTUnwrap(second.first).sequence + 1)
            XCTAssertEqual(Set(second.map(\.manifestSHA256)).count, 2)
            let later = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(second.last).manifestSHA256))
            XCTAssertEqual(later.source, "antigravity")
            XCTAssertEqual(later.locator, file.path)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 2); XCTAssertEqual(m1, 2)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testIflowJSONSettingsPublishThenRestartResumesOriginalStreamWithoutDistractors() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let file = try writeIflowTranscript(f, text: "iflow first generation")
            let project = file.deletingLastPathComponent()
            try writeIflowJSONL(project.appendingPathComponent("notes.jsonl"), sessionId: "distractor-name",
                cwd: f.project.path, text: "wrong filename")
            let deeper = project.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try writeIflowJSONL(deeper.appendingPathComponent("session-two.jsonl"), sessionId: "distractor-nested",
                cwd: f.project.path, text: "deeper directory")
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-iflow", "source": "iflow", "parseFormat": "iflow",
                "rootPath": f.sources.path, "revision": 1]]
            var budgets = collector["budgets"] as! [String: Any]
            budgets["maxEntriesVisited"] = 16
            budgets["maxCandidateFiles"] = 8
            budgets["maxDirectoryOpens"] = 4
            collector["budgets"] = budgets
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let first = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(first.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(first.first).manifestSHA256))
            XCTAssertEqual(manifest.source, "iflow")
            XCTAssertEqual(manifest.locator, file.path)
            XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: file)))
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1); XCTAssertEqual(firstM1, 1)
            _ = try writeIflowTranscript(f, text: "iflow second longer generation")
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let second = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(second.count, 2)
            XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
            XCTAssertEqual(second.first?.collectorEpoch, second.last?.collectorEpoch)
            XCTAssertNotEqual(second.first?.manifestSHA256, second.last?.manifestSHA256)
            XCTAssertEqual(try XCTUnwrap(second.last).sequence, try XCTUnwrap(second.first).sequence + 1)
            XCTAssertEqual(Set(second.map(\.manifestSHA256)).count, 2)
            let later = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(second.last).manifestSHA256))
            XCTAssertEqual(later.source, "iflow")
            XCTAssertEqual(later.locator, file.path)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 2); XCTAssertEqual(m1, 2)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testVSCodeRuntimeRecoversUnpublishedFrozenConfigurationAfterSourceRemoval() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let root = f.sources.appendingPathComponent("workspaceStorage")
            let primary = root.appendingPathComponent("ws/chatSessions/chat.jsonl")
            try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let journal = Data((#"{"kind":0,"v":{"sessionId":"vscode-recovery","creationDate":1700000000000,"requests":[]}}"# + "\n").utf8)
            try journal.write(to: primary)
            let external = f.sources.appendingPathComponent("shared.code-workspace")
            let configBytes = try JSONSerialization.data(withJSONObject: ["folders": [["path": f.project.path]]])
            try configBytes.write(to: external)
            let workspace = try JSONSerialization.data(withJSONObject: ["configuration": external.absoluteString])
            try workspace.write(to: root.appendingPathComponent("ws/workspace.json"))
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-vscode", "source": "vscode", "parseFormat": "vscode",
                "rootPath": root.path, "revision": 1]]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: { "wrong-credential-" + $0 }))
            for now: Int64 in 100..<132 {
                _ = try await active!.runOnce(now: now)
                if try !f.publications().isEmpty { break }
            }
            let original = try f.publications()
            XCTAssertEqual(original.count, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
            let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-vscode'"
            let binding = try f.integerRow(bindingSQL)
            try await active!.stop(); active = nil
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let delivered = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(delivered, original)
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(delivered.first).manifestSHA256))
            XCTAssertEqual(manifest.replayLayout.vscodeWorkspaceContext?.configurationData, configBytes)
            XCTAssertEqual(manifest.replayLayout.vscodeWorkspaceContext?.configurationLocator, external.path)
            try await assertReplicaObjects(replicas, cas: cas, manifest: manifest, expected: journal + workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.path))
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testVSCodeRuntimePublishesFrozenWorkspaceToBothReplicasWithoutProductIndex() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let root = f.sources.appendingPathComponent("workspaceStorage")
            let primary = root.appendingPathComponent("ws/chatSessions/chat.jsonl")
            try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
            let journal = Data((#"{"kind":0,"v":{"sessionId":"vscode-runtime","creationDate":1700000000000,"requests":[]}}"# + "\n").utf8)
            try journal.write(to: primary)
            let workspace = try JSONSerialization.data(withJSONObject: ["folder": f.project.absoluteString])
            try workspace.write(to: root.appendingPathComponent("ws/workspace.json"))
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-vscode", "source": "vscode", "parseFormat": "vscode",
                "rootPath": root.path, "revision": 1]]
            document["collector"] = collector
            try f.writeSettings(document)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let publications = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(publications.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(publications.first).manifestSHA256))
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isVSCodeFileSet(manifest))
            XCTAssertEqual(manifest.locator, primary.path)
            XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, "ws/chatSessions/chat.jsonl")
            XCTAssertNotNil(manifest.replayLayout.vscodeWorkspaceContext)
            try await assertReplicaObjects(replicas, cas: cas, manifest: manifest, expected: journal + workspace)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            for now: Int64 in 3_000..<3_004 {
                let cycle = try await active!.runOnce(now: now)
                XCTAssertEqual(cycle.captured, 0)
            }
            let external = f.sources.appendingPathComponent("shared.code-workspace")
            let configOne = try JSONSerialization.data(withJSONObject: ["folders": [["path": f.project.path]]])
            try configOne.write(to: external)
            let workspaceTwo = try JSONSerialization.data(withJSONObject: ["configuration": external.absoluteString])
            try workspaceTwo.write(to: root.appendingPathComponent("ws/workspace.json"))
            let second = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(second.count, 2)
            let secondManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(second.last).manifestSHA256))
            XCTAssertEqual(secondManifest.generation, manifest.generation)
            XCTAssertEqual(secondManifest.replayLayout.vscodeWorkspaceContext?.configurationData, configOne)
            let anotherProject = f.base.appendingPathComponent("another-project")
            try FileManager.default.createDirectory(at: anotherProject, withIntermediateDirectories: false)
            let configTwo = try JSONSerialization.data(withJSONObject: ["folders": [["path": anotherProject.path]]])
            try configTwo.write(to: external)
            let third = try await f.drive(active!, acknowledged: 6)
            XCTAssertEqual(third.count, 3)
            let thirdManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(third.last).manifestSHA256))
            XCTAssertEqual(thirdManifest.generation, manifest.generation)
            XCTAssertEqual(thirdManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            XCTAssertNotEqual(thirdManifest.captureID, secondManifest.captureID)
            XCTAssertEqual(thirdManifest.replayLayout.vscodeWorkspaceContext?.configurationData, configTwo)
            try await assertReplicaObjects(replicas, cas: cas, manifest: thirdManifest, expected: journal + workspaceTwo)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_locators"), 1)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testClineLegacyThenUIPreferencePublishesExactBytesToBothReplicasAfterRestart() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let legacy = try writeClineTask(f, name: "claude_messages.json", text: "cline legacy generation")
            let ui = legacy.deletingLastPathComponent().appendingPathComponent("ui_messages.json")
            try f.writeSettings(clineDocument(f, replicas: replicas))
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let first = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(first.count, 1)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let firstManifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(first.first).manifestSHA256))
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isClineFileSet(firstManifest))
            XCTAssertEqual(firstManifest.source, "cline")
            XCTAssertEqual(firstManifest.locator, legacy.path)
            XCTAssertEqual(firstManifest.replayLayout.entrypointRelativePath, "task-native/claude_messages.json")
            XCTAssertEqual(firstManifest.replayLayout.absentRelativePaths, ["task-native/ui_messages.json"])
            XCTAssertEqual(firstManifest.wholeSourceSHA256,
                EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: legacy)))
            let firstHQ = try await replicas.hq.count(), firstM1 = try await replicas.m1.count()
            XCTAssertEqual(firstHQ, 1); XCTAssertEqual(firstM1, 1)
            let uiBytes = try writeClineArray(ui, text: "cline ui generation distinct from legacy", cwd: f.project.path)
            try await active!.stop(); active = nil
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let second = try await f.drive(active!, acknowledged: 4)
            XCTAssertEqual(second.count, 2)
            XCTAssertEqual(second.first?.sourceInstanceID, second.last?.sourceInstanceID)
            XCTAssertEqual(second.first?.collectorEpoch, second.last?.collectorEpoch)
            XCTAssertEqual(try XCTUnwrap(second.last).sequence, try XCTUnwrap(second.first).sequence + 1)
            let later = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(second.last).manifestSHA256))
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isClineFileSet(later))
            XCTAssertEqual(later.source, "cline")
            XCTAssertEqual(later.locator, ui.path)
            XCTAssertEqual(later.replayLayout.entrypointRelativePath, "task-native/ui_messages.json")
            XCTAssertEqual(later.replayLayout.absentRelativePaths, [])
            XCTAssertEqual(later.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(uiBytes))
            try await assertReplicaObjects(replicas, cas: cas, manifest: later, expected: uiBytes)
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 2); XCTAssertEqual(m1, 2)
            for now: Int64 in 3_000..<3_004 {
                let cycle = try await active!.runOnce(now: now)
                XCTAssertEqual(cycle.captured, 0)
            }
            XCTAssertEqual(try f.publications().count, 2)
            try await active!.stop(); active = nil
            try f.assertNoProductIndex()
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testClineRestartDeliversPendingArchiveAfterSourceRemovedWithoutRebinding() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        var active: Runtime?
        do {
            let legacy = try writeClineTask(f, name: "claude_messages.json", text: "cline unpublished before source disappears")
            let legacyBytes = try Data(contentsOf: legacy)
            try f.writeSettings(clineDocument(f, replicas: replicas))
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: { id in
                "wrong-credential-" + id
            }))
            for now: Int64 in 100..<132 {
                _ = try await active!.runOnce(now: now)
                if try !f.publications().isEmpty { break }
            }
            let original = try f.publications()
            XCTAssertEqual(original.count, 1)
            XCTAssertEqual(try f.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
            let bindingSQL = "SELECT device, inode, generation, birth_seconds, birth_nanoseconds FROM collector_root_bindings WHERE root_id = 'runtime-cline'"
            let binding = try f.integerRow(bindingSQL)
            try await active!.stop(); active = nil
            try FileManager.default.removeItem(at: f.sources)
            active = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            let delivered = try await f.drive(active!, acknowledged: 2)
            XCTAssertEqual(delivered, original)
            XCTAssertEqual(try f.integerRow(bindingSQL), binding)
            let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                EngramCollectorCore.ArchiveSourceManifest.self,
                from: cas.readManifest(sha256: try XCTUnwrap(delivered.first).manifestSHA256))
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isClineFileSet(manifest))
            XCTAssertEqual(manifest.replayLayout.absentRelativePaths, ["task-native/ui_messages.json"])
            try await assertReplicaObjects(replicas, cas: cas, manifest: manifest, expected: legacyBytes)
            for now: Int64 in 2_000..<2_004 {
                let cycle = try await active!.runOnce(now: now)
                XCTAssertEqual(cycle.captured, 0)
                XCTAssertGreaterThan(cycle.deferred, 0)
            }
            XCTAssertEqual(try f.publications(), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.sources.path))
            let hq = try await replicas.hq.count(), m1 = try await replicas.m1.count()
            XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
            try await active!.stop(); active = nil
            await replicas.stop()
        } catch {
            try? await active?.stop()
            await replicas.stop()
            throw error
        }
    }

    func testQwenExcludedProjectAndConflictingIdentityNeverPublish() async throws {
        for excluded in [true, false] {
            let fixture = try RuntimeFixture()
            defer { fixture.remove() }
            let replicas = try await RuntimeReplicas.start(parent: fixture.base)
            do {
                _ = try writeQwenTranscript(fixture, text: "private qwen", conflictingIdentity: !excluded)
                var document = qwenDocument(fixture, replicas: replicas)
                if excluded {
                    var collector = document["collector"] as! [String: Any]
                    collector["privacy"] = ["revision": 1, "excludedProjectRoots": [fixture.project.path]]
                    document["collector"] = collector
                }
                try fixture.writeSettings(document)
                let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                do {
                    for now: Int64 in 100..<132 { _ = try await runtime.runOnce(now: now) }
                    XCTAssertEqual(try fixture.publications().count, 1, "the private capture must actually be discovered")
                    XCTAssertEqual(try fixture.integer(
                        "SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0)
                    let hq = try await replicas.hq.count()
                    let m1 = try await replicas.m1.count()
                    XCTAssertEqual(hq, 0)
                    XCTAssertEqual(m1, 0)
                    try await runtime.stop()
                } catch { try? await runtime.stop(); throw error }
                await replicas.stop()
            } catch { await replicas.stop(); throw error }
        }
    }

    func testQoderNativeJSONSettingsPublishTwoGenerationsToBothReplicas() async throws {
        try await assertAdditionalFileSource("qoder")
        try await assertAdditionalFileSource("qoder", omitFormat: true)
    }

    func testCommandCodeNativeJSONSettingsPublishTwoGenerationsToBothReplicas() async throws {
        try await assertAdditionalFileSource("commandcode")
        try await assertAdditionalFileSource("commandcode", omitFormat: true)
    }

    func testQoderAndCommandCodeExcludedOrConflictingCapturesNeverReachReplicas() async throws {
        for source in ["qoder", "commandcode"] {
            try await assertAdditionalFileSource(source, excluded: true)
            try await assertAdditionalFileSource(source, conflictingIdentity: true)
        }
    }

    func testKimiSettingsRequireExplicitNonoverlappingRegistryAndCompatibleFormat() throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let registry = f.base.appendingPathComponent("kimi.json").path
        let variants: [(String?, String?)] = [
            (nil, nil), (registry, "codex"), ("relative/kimi.json", nil),
            (f.sources.appendingPathComponent("kimi.json").path, nil),
            (f.shadow.appendingPathComponent("kimi.json").path, nil),
            (f.identity.deletingLastPathComponent().appendingPathComponent("kimi.json").path, nil),
        ]
        for (path, format) in variants {
            var document = f.document()
            var collector = document["collector"] as! [String: Any]
            var root: [String: Any] = ["rootID": "runtime-kimi", "source": "kimi",
                "rootPath": f.sources.path, "revision": 1]
            if let path { root["projectRegistryPath"] = path }
            if let format { root["parseFormat"] = format }
            collector["roots"] = [root]; document["collector"] = collector
            try f.writeSettings(document)
            XCTAssertThrowsError(try Runtime.open(settingsURL: f.settings, secretLoader: f.secret)) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
            }
        }
        try f.assertNoProductIndex()
    }

    func testKimiShardWireAndRegistryOnlyChangesReachIndependentReplicas() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let session = f.sources.appendingPathComponent("legacy/session-one")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let primary = session.appendingPathComponent("context.jsonl")
        let primaryBytes = Data("{\"role\":\"user\",\"content\":\"constellation native Kimi\"}\n".utf8)
        try primaryBytes.write(to: primary)
        let registry = f.base.appendingPathComponent("kimi.json")
        func writeRegistry(_ cwd: String) throws {
            try JSONSerialization.data(withJSONObject: ["work_dirs": [["path": cwd, "last_session_id": "session-one"],
                ["path": "/UNRELATED-KIMI-SECRET", "last_session_id": "other"]]], options: [.sortedKeys]).write(to: registry, options: .atomic)
        }
        try writeRegistry(f.project.path)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-kimi", "source": "kimi", "parseFormat": "kimi",
                "rootPath": f.sources.path, "revision": 1, "projectRegistryPath": registry.path]]
            var budgets = collector["budgets"] as! [String: Any]; budgets["maxCaptureFiles"] = 1; collector["budgets"] = budgets
            document["collector"] = collector; try f.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do {
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
                var previous: EngramCollectorCore.ArchiveSourceManifest?
                var firstPublication: EngramCollectorCore.CollectorPublicationEnvelope?
                for stage in 0..<4 {
                    if stage == 1 { try Data("{\"role\":\"assistant\",\"content\":\"aurora added shard\"}\n".utf8).write(to: session.appendingPathComponent("context_sub_2.jsonl")) }
                    if stage == 2 { try Data("{\"timestamp\":1788825601,\"message\":{\"type\":\"TurnBegin\"}}\n".utf8).write(to: session.appendingPathComponent("wire.jsonl")) }
                    if stage == 3 { try writeRegistry(f.base.appendingPathComponent("second-project").path) }
                    let records = try await f.drive(runtime, acknowledged: (stage + 1) * 2)
                    XCTAssertEqual(records.count, stage + 1)
                    let publication = try XCTUnwrap(records.last)
                    let bytes = try cas.readManifest(sha256: publication.manifestSHA256)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: bytes)
                    XCTAssertEqual(manifest.schemaVersion, 5)
                    XCTAssertEqual(manifest.source, "kimi")
                    XCTAssertEqual(manifest.locator, primary.path)
                    XCTAssertEqual(manifest.replayLayout.kimiProjectContext?.nativeSessionID, "session-one")
                    XCTAssertEqual(manifest.replayLayout.kimiProjectContext?.cwd,
                        stage == 3 ? f.base.appendingPathComponent("second-project").path : f.project.path)
                    XCTAssertNil(bytes.range(of: Data("UNRELATED-KIMI-SECRET".utf8)))
                    let expected: [String] = ["legacy/session-one/context.jsonl"]
                        + (stage >= 1 ? ["legacy/session-one/context_sub_2.jsonl"] : [])
                        + (stage >= 2 ? ["legacy/session-one/wire.jsonl"] : [])
                    XCTAssertEqual(manifest.replayLayout.relativePaths, expected.sorted())
                    XCTAssertEqual(manifest.replayLayout.absentRelativePaths, stage >= 2 ? [] : ["legacy/session-one/wire.jsonl"])
                    for replica in [replicas.hq, replicas.m1] {
                        let storedManifest = try await replica.getSyntheticArchive("manifests/" + publication.manifestSHA256)
                        XCTAssertEqual(storedManifest, bytes)
                        for chunk in manifest.chunks {
                            let stored = try await replica.getSyntheticArchive("objects/" + chunk.rawSHA256)
                            XCTAssertEqual(stored, try cas.readObject(sha256: chunk.rawSHA256))
                        }
                    }
                    if let previous {
                        XCTAssertEqual(previous.generation, manifest.generation)
                        XCTAssertNotEqual(previous.captureID, manifest.captureID)
                        if stage == 3 {
                            XCTAssertEqual(previous.wholeSourceSHA256, manifest.wholeSourceSHA256)
                            XCTAssertEqual(previous.chunks, manifest.chunks)
                        }
                    }
                    if let firstPublication {
                        XCTAssertEqual(firstPublication.sourceInstanceID, publication.sourceInstanceID)
                        XCTAssertEqual(firstPublication.collectorEpoch, publication.collectorEpoch)
                        XCTAssertEqual(publication.sequence, firstPublication.sequence + Int64(stage))
                    } else { firstPublication = publication }
                    previous = manifest
                }
                XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
                try await runtime.stop(); try f.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testKimiExcludedCaptureReauthorizesAfterRestartWithoutOriginalSourceOrRegistry() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let session = f.sources.appendingPathComponent("legacy/session-one")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let primary = session.appendingPathComponent("context.jsonl")
        try Data("{\"role\":\"user\",\"content\":\"private Kimi retained locally\"}\n".utf8).write(to: primary)
        let registry = f.base.appendingPathComponent("kimi.json")
        try JSONSerialization.data(withJSONObject: ["work_dirs": [["path": f.project.path, "last_session_id": "session-one"]]])
            .write(to: registry)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-kimi", "source": "kimi", "rootPath": f.sources.path,
                "revision": 1, "projectRegistryPath": registry.path]]
            collector["privacy"] = ["revision": 1, "excludedProjectRoots": [f.project.path]]
            document["collector"] = collector; try f.writeSettings(document)
            let first = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do {
                let deadline = Date().addingTimeInterval(10)
                while try f.publications().isEmpty {
                    _ = try await first.runOnce(now: Int64(Date().timeIntervalSince1970))
                    guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let original = try f.publications()
                let hq = try await replicas.hq.count(); let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 0); XCTAssertEqual(m1, 0)
                try await first.stop()
                try FileManager.default.removeItem(at: primary)
                try FileManager.default.removeItem(at: registry)
                collector["privacy"] = ["revision": 2, "excludedProjectRoots": [String]()]
                document["collector"] = collector; try f.writeSettings(document)
                let restarted = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
                do {
                    let recovered = try await f.drive(restarted, acknowledged: 2)
                    XCTAssertEqual(recovered, original)
                    let hq = try await replicas.hq.count(); let m1 = try await replicas.m1.count()
                    XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
                    try await restarted.stop(); try f.assertNoProductIndex()
                } catch { try? await restarted.stop(); throw error }
            } catch { try? await first.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorSettingsAcceptNilOrCursorFormatAndRejectIncompatibleFormatOrRegistry() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        for format in [Optional<String>.none, "cursor"] {
            var document = f.document()
            var collector = document["collector"] as! [String: Any]
            var root: [String: Any] = ["rootID": "runtime-cursor", "source": "cursor",
                "rootPath": f.sources.path, "revision": 1]
            if let format { root["parseFormat"] = format }
            collector["roots"] = [root]; document["collector"] = collector
            try f.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do { try await runtime.stop() } catch { try? await runtime.stop(); throw error }
        }
        let registry = f.base.appendingPathComponent("cursor.json").path
        let rejected: [(String?, String?)] = [
            (nil, "codex"), (nil, "kimi"), (registry, nil), (registry, "cursor"),
            ("relative/cursor.json", "cursor"),
        ]
        for (path, format) in rejected {
            var document = f.document()
            var collector = document["collector"] as! [String: Any]
            var root: [String: Any] = ["rootID": "runtime-cursor", "source": "cursor",
                "rootPath": f.sources.path, "revision": 1]
            if let path { root["projectRegistryPath"] = path }
            if let format { root["parseFormat"] = format }
            collector["roots"] = [root]; document["collector"] = collector
            try f.writeSettings(document)
            XCTAssertThrowsError(try Runtime.open(settingsURL: f.settings, secretLoader: f.secret)) {
                XCTAssertEqual($0 as? RuntimeError, .invalidConfiguration)
            }
        }
        try f.assertNoProductIndex()
    }

    func testCursorWALAndMetaOnlyChangesReachBothReplicasWithStableTranscriptPrimary() async throws {
        let fixture = try RuntimeFixture(); defer { fixture.remove() }
        let storeRelative = "chats/ws/sid/store.db"
        let transcriptRelative = "projects/proj/agent-transcripts/sid/sid.jsonl"
        let store = fixture.sources.appendingPathComponent(storeRelative)
        let transcript = fixture.sources.appendingPathComponent(transcriptRelative)
        let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &database), SQLITE_OK)
        let writer = try XCTUnwrap(database)
        defer { sqlite3_close(writer) }
        func sql(_ statement: String) throws {
            guard sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "CursorRuntimeWALFixture", code: Int(sqlite3_errcode(writer)))
            }
        }
        try sql("""
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        let originalMain = try Data(contentsOf: store)
        let stored = try JSONSerialization.data(withJSONObject: ["cwd": fixture.project.path], options: [.sortedKeys])
        let hex = stored.map { String(format: "%02x", $0) }.joined()
        try sql("""
            BEGIN;
            INSERT INTO meta(key, value) VALUES ('0', '\(hex)');
            INSERT INTO blobs(id, data) VALUES ('user', '{"role":"user","content":"cursor runtime question"}');
            INSERT INTO blobs(id, data) VALUES ('assistant', '{"role":"assistant","content":"cursor runtime answer"}');
            COMMIT;
            """)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; SELECT count(*) FROM meta",
            nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try Data(contentsOf: store), originalMain, "the fixture must commit key0 entirely in WAL")
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let initialWAL = try Data(contentsOf: wal)
        XCTAssertFalse(initialWAL.isEmpty)
        let live = try JSONSerialization.data(withJSONObject: ["cwd": fixture.project.path], options: [.sortedKeys])
        try live.write(to: meta)
        let transcriptBytes = Data(("{\"role\":\"user\",\"content\":\"cursor runtime question\"}\n"
            + "{\"role\":\"assistant\",\"content\":\"cursor runtime answer\"}\n").utf8)
        try transcriptBytes.write(to: transcript)
        XCTAssertEqual(chmod(store.path, 0o600), 0)
        XCTAssertEqual(chmod(wal.path, 0o600), 0)
        XCTAssertEqual(chmod(meta.path, 0o600), 0)
        XCTAssertEqual(chmod(transcript.path, 0o600), 0)
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-cursor", "source": "cursor",
                "rootPath": fixture.sources.path, "revision": 1, "parseFormat": "cursor"]]
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                func inspect(
                    _ publication: EngramCollectorCore.CollectorPublicationEnvelope,
                    expected: [String: Data]
                ) async throws -> EngramCollectorCore.ArchiveSourceManifest {
                    let bytes = try cas.readManifest(sha256: publication.manifestSHA256)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                        EngramCollectorCore.ArchiveSourceManifest.self, from: bytes)
                    XCTAssertEqual(manifest.schemaVersion, 2)
                    XCTAssertEqual(manifest.source, "cursor")
                    XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
                    XCTAssertEqual(manifest.locator, transcript.path)
                    XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, transcriptRelative)
                    XCTAssertNil(manifest.sessionID)
                    XCTAssertNil(manifest.replayLayout.sqliteSession)
                    XCTAssertNil(manifest.replayLayout.geminiProjectContext)
                    XCTAssertNil(manifest.replayLayout.kimiProjectContext)
                    XCTAssertEqual(manifest.replayLayout.relativePaths, [
                        storeRelative, storeRelative + "-wal", "chats/ws/sid/meta.json", transcriptRelative,
                    ].sorted())
                    XCTAssertEqual(manifest.replayLayout.absentRelativePaths, [])
                    var raw = Data()
                    for chunk in manifest.chunks { raw.append(try cas.readObject(sha256: chunk.rawSHA256)) }
                    for member in try XCTUnwrap(manifest.replayLayout.files) {
                        XCTAssertFalse(member.relativePath.hasSuffix("-shm"))
                        XCTAssertFalse(member.relativePath.hasSuffix("-journal"))
                        let stored = raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                        XCTAssertEqual(stored, expected[member.relativePath])
                        XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(stored), member.wholeSourceSHA256)
                    }
                    for replica in [replicas.hq, replicas.m1] {
                        let remoteManifest = try await replica.getSyntheticArchive("manifests/" + publication.manifestSHA256)
                        XCTAssertEqual(remoteManifest, bytes)
                        for chunk in manifest.chunks {
                            let remoteObject = try await replica.getSyntheticArchive("objects/" + chunk.rawSHA256)
                            XCTAssertEqual(remoteObject, try cas.readObject(sha256: chunk.rawSHA256))
                        }
                    }
                    return manifest
                }
                func expectedMembers(walBytes: Data, metaBytes: Data) throws -> [String: Data] {
                    [storeRelative: originalMain, storeRelative + "-wal": walBytes,
                        "chats/ws/sid/meta.json": metaBytes, transcriptRelative: transcriptBytes]
                }
                let first = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(first.count, 1)
                let firstManifest = try await inspect(XCTUnwrap(first.first),
                    expected: expectedMembers(walBytes: initialWAL, metaBytes: live))
                XCTAssertEqual(try Data(contentsOf: store), originalMain)
                XCTAssertEqual(try Data(contentsOf: wal), initialWAL)
                XCTAssertEqual(try Data(contentsOf: transcript), transcriptBytes)
                try sql("""
                    BEGIN;
                    INSERT INTO blobs(id, data) VALUES ('wal-only', '{"role":"assistant","content":"wal-only change"}');
                    COMMIT;
                    """)
                XCTAssertEqual(chmod(wal.path, 0o600), 0)
                let secondWAL = try Data(contentsOf: wal)
                XCTAssertNotEqual(secondWAL, initialWAL)
                let second = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(second.count, 2)
                let secondManifest = try await inspect(XCTUnwrap(second.last),
                    expected: expectedMembers(walBytes: secondWAL, metaBytes: live))
                XCTAssertEqual(try Data(contentsOf: store), originalMain)
                XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
                let updatedLive = try JSONSerialization.data(
                    withJSONObject: ["cwd": fixture.project.path, "name": "updated-live"], options: [.sortedKeys])
                try updatedLive.write(to: meta)
                XCTAssertEqual(chmod(meta.path, 0o600), 0)
                let third = try await fixture.drive(runtime, acknowledged: 6)
                XCTAssertEqual(third.count, 3)
                let thirdManifest = try await inspect(XCTUnwrap(third.last),
                    expected: expectedMembers(walBytes: secondWAL, metaBytes: updatedLive))
                XCTAssertEqual(firstManifest.generation, secondManifest.generation)
                XCTAssertEqual(secondManifest.generation, thirdManifest.generation)
                XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
                XCTAssertNotEqual(secondManifest.captureID, thirdManifest.captureID)
                XCTAssertEqual(first.first?.sourceInstanceID, third.last?.sourceInstanceID)
                XCTAssertEqual(first.first?.collectorEpoch, third.last?.collectorEpoch)
                XCTAssertEqual(try XCTUnwrap(third.last).sequence, try XCTUnwrap(first.first).sequence + 2)
                XCTAssertEqual(try Data(contentsOf: store), originalMain)
                XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
                XCTAssertEqual(try Data(contentsOf: transcript), transcriptBytes)
                let hq = try await replicas.hq.count(); let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 3); XCTAssertEqual(m1, 3)
                try await runtime.stop()
                let offlineLive = try JSONSerialization.data(
                    withJSONObject: ["cwd": fixture.project.path, "name": "changed-while-stopped"], options: [.sortedKeys])
                try offlineLive.write(to: meta)
                XCTAssertEqual(chmod(meta.path, 0o600), 0)
                let restarted = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
                do {
                    let fourth = try await fixture.drive(restarted, acknowledged: 8)
                    XCTAssertEqual(fourth.count, 4)
                    let fourthManifest = try await inspect(XCTUnwrap(fourth.last),
                        expected: expectedMembers(walBytes: secondWAL, metaBytes: offlineLive))
                    XCTAssertEqual(fourthManifest.generation, thirdManifest.generation)
                    XCTAssertNotEqual(fourthManifest.captureID, thirdManifest.captureID)
                    XCTAssertEqual(fourth.last?.sourceInstanceID, first.first?.sourceInstanceID)
                    XCTAssertEqual(fourth.last?.collectorEpoch, first.first?.collectorEpoch)
                    XCTAssertEqual(try Data(contentsOf: store), originalMain)
                    XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
                    try await restarted.stop()
                } catch { try? await restarted.stop(); throw error }
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCursorExcludedCaptureReauthorizesAfterRestartWithoutOriginalSource() async throws {
        let f = try RuntimeFixture(); defer { f.remove() }
        let store = f.sources.appendingPathComponent("chats/ws/sid/store.db")
        let transcript = f.sources.appendingPathComponent("projects/proj/agent-transcripts/sid/sid.jsonl")
        let meta = store.deletingLastPathComponent().appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &database), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        let writer = try XCTUnwrap(database)
        func sql(_ statement: String) throws {
            guard sqlite3_exec(writer, statement, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "CursorRuntimeExcludeFixture", code: Int(sqlite3_errcode(writer)))
            }
        }
        let stored = try JSONSerialization.data(withJSONObject: ["cwd": f.project.path], options: [.sortedKeys])
        let hex = stored.map { String(format: "%02x", $0) }.joined()
        try sql("""
            PRAGMA journal_mode=DELETE;
            CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            BEGIN;
            INSERT INTO meta(key, value) VALUES ('0', '\(hex)');
            INSERT INTO blobs(id, data) VALUES ('user', '{"role":"user","content":"private cursor retained locally"}');
            COMMIT;
            """)
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        database = nil
        try JSONSerialization.data(withJSONObject: ["cwd": f.project.path], options: [.sortedKeys]).write(to: meta)
        try Data("{\"role\":\"user\",\"content\":\"private cursor retained locally\"}\n".utf8).write(to: transcript)
        XCTAssertEqual(chmod(store.path, 0o600), 0)
        XCTAssertEqual(chmod(meta.path, 0o600), 0)
        XCTAssertEqual(chmod(transcript.path, 0o600), 0)
        let replicas = try await RuntimeReplicas.start(parent: f.base)
        do {
            var document = f.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-cursor", "source": "cursor",
                "rootPath": f.sources.path, "revision": 1, "parseFormat": "cursor"]]
            collector["privacy"] = ["revision": 1, "excludedProjectRoots": [f.project.path]]
            document["collector"] = collector; try f.writeSettings(document)
            let first = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
            do {
                let deadline = Date().addingTimeInterval(10)
                while try f.publications().isEmpty {
                    _ = try await first.runOnce(now: Int64(Date().timeIntervalSince1970))
                    guard Date() < deadline else { throw RuntimeFixture.Failure.deadline }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let original = try f.publications()
                let hq = try await replicas.hq.count(); let m1 = try await replicas.m1.count()
                XCTAssertEqual(hq, 0); XCTAssertEqual(m1, 0)
                try await first.stop()
                XCTAssertEqual(try f.publications(), original, "inventory must survive Runtime shutdown and a cold DB reopen")
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: f.capture)
                let sealed = try cas.readManifest(sha256: XCTUnwrap(original.first).manifestSHA256)
                try FileManager.default.removeItem(at: f.sources.appendingPathComponent("chats"))
                try FileManager.default.removeItem(at: f.sources.appendingPathComponent("projects"))
                XCTAssertEqual(try cas.readManifest(sha256: XCTUnwrap(original.first).manifestSHA256), sealed)
                collector["privacy"] = ["revision": 2, "excludedProjectRoots": [String]()]
                document["collector"] = collector; try f.writeSettings(document)
                let restarted = try XCTUnwrap(Runtime.open(settingsURL: f.settings, secretLoader: f.secret))
                do {
                    let recovered = try await f.drive(restarted, acknowledged: 2)
                    XCTAssertEqual(recovered, original)
                    let publication = try XCTUnwrap(recovered.first)
                    let hqManifest = try await replicas.hq.getSyntheticArchive("manifests/" + publication.manifestSHA256)
                    let m1Manifest = try await replicas.m1.getSyntheticArchive("manifests/" + publication.manifestSHA256)
                    XCTAssertEqual(hqManifest, sealed)
                    XCTAssertEqual(m1Manifest, sealed)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                        EngramCollectorCore.ArchiveSourceManifest.self, from: sealed)
                    for replica in [replicas.hq, replicas.m1] {
                        for chunk in manifest.chunks {
                            let remoteObject = try await replica.getSyntheticArchive("objects/" + chunk.rawSHA256)
                            XCTAssertEqual(remoteObject, try cas.readObject(sha256: chunk.rawSHA256))
                        }
                    }
                    let hq = try await replicas.hq.count(); let m1 = try await replicas.m1.count()
                    XCTAssertEqual(hq, 1); XCTAssertEqual(m1, 1)
                    try await restarted.stop(); try f.assertNoProductIndex()
                } catch { try? await restarted.stop(); throw error }
            } catch { try? await first.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testGeminiNativeProjectRootAndExactSessionIDSidecarPublishTwoGenerations() async throws {
        try await assertGeminiCompositePublication(registryOnly: false, jsonl: false)
    }

    func testGeminiJSONLMetadataAndSidecarPublishWithoutProductParserDependency() async throws {
        try await assertGeminiCompositePublication(registryOnly: false, jsonl: true)
    }

    func testGeminiRegistryOnlyCwdChangesCaptureIdentityWithoutUploadingRegistry() async throws {
        try await assertGeminiCompositePublication(registryOnly: true, jsonl: false)
    }

    func testGeminiFinalJSONLSessionIDAfterEightKiBSelectsExactSidecar() async throws {
        try await assertGeminiCompositePublication(registryOnly: false, jsonl: true, lateIdentity: true)
    }

    func testGeminiEmptyNativeProjectRootRemainsCapturedWithRegistryFallback() async throws {
        try await assertGeminiCompositePublication(registryOnly: true, jsonl: false, emptyRoot: true)
    }

    private func assertGeminiCompositePublication(registryOnly: Bool, jsonl: Bool,
                                                  lateIdentity: Bool = false, emptyRoot: Bool = false) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            let project = fixture.sources.appendingPathComponent("native-project")
            let chats = project.appendingPathComponent("chats")
            try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
            let relative = "native-project/chats/stem-does-not-match." + (jsonl ? "jsonl" : "json")
            let primary = fixture.sources.appendingPathComponent(relative)
            let projectRoot = project.appendingPathComponent(".project_root")
            let sidecar = chats.appendingPathComponent("native-gemini-id.engram.json")
            let registry = fixture.base.appendingPathComponent("projects.json")
            let messages: [[String: Any]] = [
                ["id": "m1", "type": "user", "timestamp": "2026-09-08T00:00:01Z", "content": lateIdentity ? String(repeating: "x", count: 9_000) : "native Gemini question"],
                ["id": "m2", "type": "gemini", "timestamp": "2026-09-08T00:00:02Z", "content": "native Gemini answer",
                 "tokens": ["input": 100, "output": 7, "cached": 3, "thoughts": 2, "tool": 1]],
            ]
            let metadata: [String: Any] = ["sessionId": lateIdentity ? "old-gemini-id" : "native-gemini-id", "startTime": "2026-09-08T00:00:00Z",
                "lastUpdated": "2026-09-08T00:00:02Z"]
            let sourceBytes: Data
            if jsonl {
                sourceBytes = try ([metadata] + messages + [["$set": ["sessionId": "native-gemini-id", "lastUpdated": "2026-09-08T00:00:03Z"]]])
                    .reduce(into: Data()) { bytes, row in
                        bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10)
                    }
            } else {
                sourceBytes = try JSONSerialization.data(withJSONObject: metadata.merging(["messages": messages]) { _, value in value },
                    options: [.prettyPrinted, .sortedKeys])
            }
            try sourceBytes.write(to: primary)
            let unrelated = "unrelated-project-private-sentinel"
            try Data("{\"originator\":\"decoy\",\"parentSessionId\":\"wrong-stem\"}".utf8)
                .write(to: chats.appendingPathComponent("stem-does-not-match.engram.json"))
            try Data(unrelated.utf8).write(to: chats.appendingPathComponent("other.engram.json"))
            func writeRegistry(_ cwd: String) throws {
                try JSONSerialization.data(withJSONObject: ["projects": [cwd: "native-project", "/private-other": unrelated]],
                    options: [.sortedKeys]).write(to: registry)
            }
            if registryOnly {
                try writeRegistry(fixture.project.path)
                if emptyRoot { try Data(" \n".utf8).write(to: projectRoot) }
            } else {
                try Data((fixture.project.path + "\n").utf8).write(to: projectRoot)
                try Data("{\"originator\":\"claude-code\",\"parentSessionId\":\"first-parent\"}".utf8).write(to: sidecar)
            }
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            var root: [String: Any] = ["rootID": "runtime-gemini", "source": "gemini-cli",
                "rootPath": fixture.sources.path, "revision": 1]
            if registryOnly { root["projectRegistryPath"] = registry.path; root["parseFormat"] = "gemini-cli" }
            collector["roots"] = [root]; document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                func inspect(_ publication: EngramCollectorCore.CollectorPublicationEnvelope, cwd: String) throws -> EngramCollectorCore.ArchiveSourceManifest {
                    let bytes = try cas.readManifest(sha256: publication.manifestSHA256)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(EngramCollectorCore.ArchiveSourceManifest.self, from: bytes)
                    XCTAssertEqual(manifest.source, "gemini-cli")
                    XCTAssertEqual(manifest.locator, primary.path)
                    XCTAssertEqual(manifest.schemaVersion, registryOnly ? 3 : 2)
                    XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, relative)
                    let expected = registryOnly ? (emptyRoot ? [relative, "native-project/.project_root"] : [relative])
                        : [relative, "native-project/.project_root", "native-project/chats/native-gemini-id.engram.json"]
                    XCTAssertEqual(manifest.replayLayout.relativePaths, expected.sorted())
                    XCTAssertEqual(manifest.replayLayout.absentRelativePaths,
                        registryOnly ? (emptyRoot ? ["native-project/chats/native-gemini-id.engram.json"]
                            : ["native-project/.project_root", "native-project/chats/native-gemini-id.engram.json"]) : [])
                    var raw = Data()
                    for chunk in manifest.chunks { raw.append(try cas.readObject(sha256: chunk.rawSHA256)) }
                    for member in try XCTUnwrap(manifest.replayLayout.files) {
                        let memberBytes = raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                        XCTAssertEqual(memberBytes, try Data(contentsOf: fixture.sources.appendingPathComponent(member.relativePath)))
                        XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(memberBytes), member.wholeSourceSHA256)
                    }
                    XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(unrelated))
                    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(unrelated))
                    if registryOnly {
                        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                        let layout = try XCTUnwrap(object["replayLayout"] as? [String: Any])
                        let context = try XCTUnwrap(layout["geminiProjectContext"] as? [String: Any])
                        XCTAssertEqual(context["kind"] as? String, "geminiProjectsRegistryProjection")
                        XCTAssertEqual(context["projectName"] as? String, "native-project")
                        XCTAssertEqual(context["cwd"] as? String, cwd)
                        XCTAssertEqual(context["registryLocator"] as? String, registry.path)
                        XCTAssertEqual(context["registrySHA256"] as? String,
                            EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: registry)))
                        XCTAssertEqual(FileManager.default.fileExists(atPath: projectRoot.path), emptyRoot,
                            "derived evidence must preserve actual native input presence")
                    }
                    return manifest
                }
                let firstRecords = try await fixture.drive(runtime, acknowledged: 2)
                let first = try XCTUnwrap(firstRecords.first)
                let firstManifest = try inspect(first, cwd: fixture.project.path)
                let secondCwd = fixture.base.appendingPathComponent("second-project").path
                if registryOnly { try writeRegistry(secondCwd) }
                else { try Data("{\"originator\":\"claude-code\",\"parentSessionId\":\"second-parent\"}".utf8).write(to: sidecar) }
                let secondRecords = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(secondRecords.count, 2)
                let second = try XCTUnwrap(secondRecords.last)
                let secondManifest = try inspect(second, cwd: registryOnly ? secondCwd : fixture.project.path)
                XCTAssertEqual(firstManifest.generation, secondManifest.generation)
                XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
                if registryOnly {
                    XCTAssertEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
                    XCTAssertEqual(firstManifest.chunks, secondManifest.chunks)
                }
                XCTAssertEqual(first.sourceInstanceID, second.sourceInstanceID)
                XCTAssertEqual(second.sequence, first.sequence + 1)
                XCTAssertEqual(try Data(contentsOf: primary), sourceBytes)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 2)
                XCTAssertEqual(m1Count, 2)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testCopilotWorkspaceOnlyChangesPublishNewCompleteFileSetsToBothReplicas() async throws {
        try await assertCopilotCompositePublication(checkpointFallback: false)
    }

    func testCopilotCheckpointBodyChangesPublishDespiteStartOnlyEvents() async throws {
        try await assertCopilotCompositePublication(checkpointFallback: true)
    }

    func testCopilotLateConversationWinsOverCheckpointAfterLargeMetadataPrefix() async throws {
        try await assertCopilotCompositePublication(checkpointFallback: false, latePrefix: true)
    }

    func testCopilotLateCheckpointWinsOnlyAfterCompleteNonConversationEvents() async throws {
        try await assertCopilotCompositePublication(checkpointFallback: true, latePrefix: true)
    }

    func testCopilotPrimaryDoesNotStarveWithSingleFileCaptureBudget() async throws {
        try await assertCopilotCompositePublication(checkpointFallback: false, latePrefix: true, singleFileBudget: true)
    }

    private func assertCopilotCompositePublication(checkpointFallback: Bool, latePrefix: Bool = false,
                                                   singleFileBudget: Bool = false) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            let session = fixture.sources.appendingPathComponent("session-1")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let events = session.appendingPathComponent("events.jsonl")
            let workspace = session.appendingPathComponent("workspace.yaml")
            var records: [[String: Any]] = [
                ["type": "session.start", "timestamp": "2026-09-08T00:00:00Z",
                 "data": ["context": ["cwd": fixture.project.path]]],
            ]
            if latePrefix {
                records.insert(["type": "session.info", "data": ["content": String(repeating: "p", count: 70_000)]], at: 0)
            }
            if !checkpointFallback {
                records.append(["type": "user.message", "timestamp": "2026-09-08T00:00:01Z",
                    "data": ["content": "native copilot question"]])
                records.append(["type": "assistant.message", "timestamp": "2026-09-08T00:00:02Z",
                    "data": ["content": "native copilot answer"]])
            }
            let eventBytes = try records.reduce(into: Data()) { bytes, record in
                bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                bytes.append(10)
            }
            try eventBytes.write(to: events)
            let yaml = "id: native-copilot\ncwd: \(fixture.project.path)\ncreated_at: 2026-09-08T00:00:00Z\nsummary: first summary\n"
            try Data(yaml.utf8).write(to: workspace)
            let primary: URL
            let auxiliary: URL
            var expected = ["session-1/events.jsonl", "session-1/workspace.yaml"]
            if checkpointFallback {
                let checkpoints = session.appendingPathComponent("checkpoints")
                try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false)
                primary = checkpoints.appendingPathComponent("index.md")
                auxiliary = checkpoints.appendingPathComponent("001-body.md")
                try Data(((latePrefix ? String(repeating: "Header text.\n", count: 6_000) : "") + "| 1 | Recovered conversation | 001-body.md |\n").utf8).write(to: primary)
                try Data("# Original checkpoint\n\nOriginal body.\n".utf8).write(to: auxiliary)
                expected += ["session-1/checkpoints/index.md", "session-1/checkpoints/001-body.md"]
            } else {
                primary = events
                auxiliary = workspace
                if latePrefix {
                    let checkpoints = session.appendingPathComponent("checkpoints")
                    try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: false)
                    try Data("| 1 | Must not replace conversation | absent.md |\n".utf8)
                        .write(to: checkpoints.appendingPathComponent("index.md"))
                    expected.append("session-1/checkpoints/index.md")
                }
            }
            let primaryBytes = try Data(contentsOf: primary)
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-copilot", "source": "copilot",
                "rootPath": fixture.sources.path, "revision": 1]]
            if singleFileBudget {
                var budgets = collector["budgets"] as! [String: Any]
                budgets["maxCaptureFiles"] = 1
                collector["budgets"] = budgets
            }
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                func manifest(_ envelope: EngramCollectorCore.CollectorPublicationEnvelope) throws -> EngramCollectorCore.ArchiveSourceManifest {
                    try EngramCollectorCore.ArchiveCanonicalJSON.decode(EngramCollectorCore.ArchiveSourceManifest.self,
                        from: cas.readManifest(sha256: envelope.manifestSHA256))
                }
                func assertComplete(_ manifest: EngramCollectorCore.ArchiveSourceManifest) throws {
                    XCTAssertEqual(manifest.schemaVersion, 2)
                    XCTAssertEqual(manifest.source, "copilot")
                    XCTAssertEqual(manifest.locator, primary.path)
                    XCTAssertEqual(manifest.replayLayout.relativePaths, expected.sorted())
                    XCTAssertEqual(manifest.replayLayout.entrypointRelativePath,
                        checkpointFallback ? "session-1/checkpoints/index.md" : "session-1/events.jsonl")
                    var bytes = Data()
                    for chunk in manifest.chunks { bytes.append(try cas.readObject(sha256: chunk.rawSHA256)) }
                    for file in try XCTUnwrap(manifest.replayLayout.files) {
                        let stored = bytes.subdata(in: Int(file.byteOffset)..<Int(file.byteOffset + file.rawByteCount))
                        XCTAssertEqual(stored, try Data(contentsOf: fixture.sources.appendingPathComponent(file.relativePath)))
                        XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(stored), file.wholeSourceSHA256)
                    }
                }
                let first = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(first.count, 1)
                let original = try manifest(XCTUnwrap(first.first))
                try assertComplete(original)
                let changed = checkpointFallback ? "# Updated checkpoint\n\nAuxiliary-only body update.\n"
                    : yaml.replacingOccurrences(of: "first summary", with: "updated auxiliary summary")
                try Data(changed.utf8).write(to: auxiliary)
                let second = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(second.count, 2)
                let updated = try manifest(XCTUnwrap(second.last))
                try assertComplete(updated)
                XCTAssertEqual(updated.generation, original.generation,
                    "only the auxiliary file changed; primary-stat equality must not hide it")
                XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
                XCTAssertEqual(try Data(contentsOf: events), eventBytes)
                XCTAssertNotEqual(updated.captureID, original.captureID)
                XCTAssertEqual(first.first?.sourceInstanceID, second.last?.sourceInstanceID)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 2)
                XCTAssertEqual(m1Count, 2)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    func testGrokSegmentOnlyChangePublishesUpdatedFileSetWithStablePrimary_repro() async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            let sessionID = "019dd6e3-91d1-7326-8299-314858773a0e"
            let project = "native-project"
            let prefix = project + "/" + sessionID + "/"
            let relative = prefix + "chat_history.jsonl"
            let segmentRelative = prefix + "compaction/segment_000.md"
            let session = fixture.sources.appendingPathComponent(project).appendingPathComponent(sessionID)
            let compaction = session.appendingPathComponent("compaction")
            try FileManager.default.createDirectory(at: compaction, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let chatBytes = Data("{\"type\":\"user\",\"content\":\"<user_query>Inspect</user_query>\"}\n".utf8)
            let firstSegment = Data("# first archive\n".utf8)
            let secondSegment = Data("# updated archive\n".utf8)
            let members: [(String, Data)] = [
                ("chat_history.jsonl", chatBytes),
                ("updates.jsonl", Data("{\"type\":\"assistant\",\"content\":\"ok\"}\n".utf8)),
                ("summary.json", try JSONSerialization.data(withJSONObject: [
                    "info": ["id": sessionID, "cwd": fixture.project.path],
                ], options: [.sortedKeys]) + Data([10])),
                ("prompt_context.json", try JSONSerialization.data(withJSONObject: [
                    "working_directory": fixture.project.path,
                ], options: [.sortedKeys]) + Data([10])),
                ("compaction/INDEX.md", Data("# index\n".utf8)),
                ("compaction/segment_000.md", firstSegment),
            ]
            for (name, bytes) in members {
                let url = session.appendingPathComponent(name)
                try bytes.write(to: url)
                XCTAssertEqual(chmod(url.path, 0o600), 0)
            }
            let expected = [
                prefix + "chat_history.jsonl",
                prefix + "compaction/INDEX.md",
                prefix + "compaction/segment_000.md",
                prefix + "prompt_context.json",
                prefix + "summary.json",
                prefix + "updates.jsonl",
            ].sorted()
            var document = fixture.document(replicas: replicas)
            var collector = document["collector"] as! [String: Any]
            collector["roots"] = [["rootID": "runtime-grok", "source": "grok",
                "rootPath": fixture.sources.path, "revision": 1]]
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                func inspect(
                    _ publication: EngramCollectorCore.CollectorPublicationEnvelope,
                    segment: Data
                ) throws -> EngramCollectorCore.ArchiveSourceManifest {
                    let bytes = try cas.readManifest(sha256: publication.manifestSHA256)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                        EngramCollectorCore.ArchiveSourceManifest.self, from: bytes)
                    XCTAssertEqual(manifest.source, "grok")
                    XCTAssertEqual(manifest.schemaVersion, 2)
                    XCTAssertEqual(manifest.locator, fixture.sources.appendingPathComponent(relative).path)
                    XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, relative)
                    XCTAssertEqual(manifest.replayLayout.relativePaths, expected)
                    var raw = Data()
                    for chunk in manifest.chunks { raw.append(try cas.readObject(sha256: chunk.rawSHA256)) }
                    for member in try XCTUnwrap(manifest.replayLayout.files) {
                        let memberBytes = raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                        XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(memberBytes), member.wholeSourceSHA256)
                        if member.relativePath == segmentRelative {
                            XCTAssertEqual(memberBytes, segment)
                        } else if member.relativePath == relative {
                            XCTAssertEqual(memberBytes, chatBytes)
                        }
                    }
                    return manifest
                }
                let firstRecords = try await fixture.drive(runtime, acknowledged: 2)
                XCTAssertEqual(firstRecords.count, 1)
                let first = try XCTUnwrap(firstRecords.first)
                let firstManifest = try inspect(first, segment: firstSegment)
                XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("chat_history.jsonl")), chatBytes)
                try secondSegment.write(to: session.appendingPathComponent("compaction/segment_000.md"))
                XCTAssertEqual(chmod(session.appendingPathComponent("compaction/segment_000.md").path, 0o600), 0)
                XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("chat_history.jsonl")), chatBytes)
                let secondRecords = try await fixture.drive(runtime, acknowledged: 4)
                XCTAssertEqual(secondRecords.count, 2)
                let second = try XCTUnwrap(secondRecords.last)
                let secondManifest = try inspect(second, segment: secondSegment)
                XCTAssertEqual(firstManifest.generation, secondManifest.generation)
                XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
                XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
                XCTAssertEqual(first.sourceInstanceID, second.sourceInstanceID)
                XCTAssertEqual(second.sequence, first.sequence + 1)
                XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("chat_history.jsonl")), chatBytes)
                let hqCount = try await replicas.hq.count()
                let m1Count = try await replicas.m1.count()
                XCTAssertEqual(hqCount, 2)
                XCTAssertEqual(m1Count, 2)
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    private func assertAdditionalFileSource(
        _ source: String, excluded: Bool = false, conflictingIdentity: Bool = false, omitFormat: Bool = false
    ) async throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let replicas = try await RuntimeReplicas.start(parent: fixture.base)
        do {
            let file = try writeAdditionalFileSource(fixture, source: source, text: "first generation",
                conflictingIdentity: conflictingIdentity)
            var document = customClaudeDocument(fixture, replicas: replicas, parseFormat: source)
            var collector = document["collector"] as! [String: Any]
            var root: [String: Any] = ["rootID": "runtime-" + source, "source": source,
                "rootPath": fixture.sources.path, "revision": 1]
            if !omitFormat { root["parseFormat"] = source }
            collector["roots"] = [root]
            if excluded {
                collector["privacy"] = ["revision": 1, "excludedProjectRoots": [fixture.project.path]]
            }
            document["collector"] = collector
            try fixture.writeSettings(document)
            let runtime = try XCTUnwrap(Runtime.open(settingsURL: fixture.settings, secretLoader: fixture.secret))
            do {
                if excluded || conflictingIdentity {
                    for now: Int64 in 100..<132 { _ = try await runtime.runOnce(now: now) }
                    XCTAssertEqual(try fixture.publications().count, 1, source)
                    XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'"), 0, source)
                    let hq = try await replicas.hq.count()
                    let m1 = try await replicas.m1.count()
                    XCTAssertEqual(hq, 0, source)
                    XCTAssertEqual(m1, 0, source)
                } else {
                    let first = try await fixture.drive(runtime, acknowledged: 2)
                    XCTAssertEqual(first.count, 1, source)
                    let cas = try EngramCollectorCore.ImmutableArchiveCAS(root: fixture.capture)
                    let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(
                        EngramCollectorCore.ArchiveSourceManifest.self,
                        from: cas.readManifest(sha256: XCTUnwrap(first.first).manifestSHA256))
                    XCTAssertEqual(manifest.source, source)
                    XCTAssertEqual(manifest.locator, file.path)
                    XCTAssertEqual(manifest.wholeSourceSHA256,
                        EngramCollectorCore.ArchiveV2Hash.sha256(try Data(contentsOf: file)))
                    _ = try writeAdditionalFileSource(fixture, source: source, text: "second longer generation")
                    let second = try await fixture.drive(runtime, acknowledged: 4)
                    XCTAssertEqual(second.count, 2, source)
                    XCTAssertEqual(first[0].sourceInstanceID, second[1].sourceInstanceID)
                    XCTAssertNotEqual(first[0].manifestSHA256, second[1].manifestSHA256)
                    let hq = try await replicas.hq.count()
                    let m1 = try await replicas.m1.count()
                    XCTAssertEqual(hq, 2, source)
                    XCTAssertEqual(m1, 2, source)
                }
                try await runtime.stop()
                try fixture.assertNoProductIndex()
            } catch { try? await runtime.stop(); throw error }
            await replicas.stop()
        } catch { await replicas.stop(); throw error }
    }

    private func writeAdditionalFileSource(
        _ fixture: RuntimeFixture, source: String, text: String, conflictingIdentity: Bool = false
    ) throws -> URL {
        let project = fixture.sources.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let native = "native-" + source
        let common: [String: Any] = ["sessionId": native, "cwd": fixture.project.path,
            "timestamp": "2026-09-08T00:00:00Z"]
        let user: [String: Any]
        let assistant: [String: Any]
        if source == "qoder" {
            user = ["type": "user", "message": ["content": text]]
            assistant = ["type": "assistant", "message": ["model": "MiniMax-M2.1", "content": "native qoder reply",
                "usage": ["input_tokens": 12, "output_tokens": 7]]]
        } else {
            user = ["role": "user", "content": [["type": "text", "text": text]]]
            assistant = ["role": "assistant", "metadata": ["model": "commandcode-model"],
                "content": [["type": "text", "text": "native commandcode reply"]]]
        }
        let records = [common.merging(user) { _, new in new },
            common.merging(assistant) { _, new in new }.merging(
                ["sessionId": conflictingIdentity ? "different-native" : native]) { _, new in new }]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        let file = project.appendingPathComponent("session.jsonl")
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        return file
    }

    private func qwenDocument(_ fixture: RuntimeFixture, replicas: RuntimeReplicas) -> [String: Any] {
        var document = customClaudeDocument(fixture, replicas: replicas, parseFormat: "qwen")
        var collector = document["collector"] as! [String: Any]
        collector["roots"] = [["rootID": "runtime-qwen", "source": "qwen", "parseFormat": "qwen",
            "rootPath": fixture.sources.path, "revision": 1]]
        document["collector"] = collector
        return document
    }

    private func writeWindsurfTranscript(_ f: RuntimeFixture, text: String) throws -> URL {
        let file = f.sources.appendingPathComponent("transcripts/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user_input", "status": "done", "user_input": ["user_response": text + " " + f.project.path + "/file"]],
            ["type": "planner_response", "status": "done", "planner_response": ["response": "native reply"]],
        ]
        let raw = try records.reduce(into: Data()) { bytes, record in
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            bytes.append(10)
        }
        try raw.write(to: file)
        return file
    }

    private func writeAntigravityTranscript(_ f: RuntimeFixture, text: String) throws -> URL {
        let file = f.sources.appendingPathComponent("session/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "USER_INPUT", "created_at": "2026-09-10T00:00:00Z", "content": text + " " + f.project.path + "/file"],
            ["type": "PLANNER_RESPONSE", "created_at": "2026-09-10T00:00:01Z", "content": "native reply"],
        ]
        let raw = try records.reduce(into: Data()) { bytes, record in
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            bytes.append(10)
        }
        try raw.write(to: file)
        return file
    }

    private func writeIflowJSONL(_ file: URL, sessionId: String, cwd: String, text: String) throws {
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": sessionId, "cwd": cwd, "timestamp": "2026-09-08T00:00:00Z",
             "message": ["content": text]],
            ["type": "assistant", "sessionId": sessionId, "cwd": cwd, "timestamp": "2026-09-08T00:00:01Z",
             "message": ["model": "iflow-model", "content": "iflow reply"]],
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
    }

    private func writeIflowTranscript(_ fixture: RuntimeFixture, text: String) throws -> URL {
        let project = fixture.sources.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = project.appendingPathComponent("session-one.jsonl")
        try writeIflowJSONL(file, sessionId: "native-iflow", cwd: fixture.project.path, text: text)
        return file
    }

    private func clineDocument(_ fixture: RuntimeFixture, replicas: RuntimeReplicas) -> [String: Any] {
        var document = fixture.document(replicas: replicas)
        var collector = document["collector"] as! [String: Any]
        collector["roots"] = [["rootID": "runtime-cline", "source": "cline", "parseFormat": "cline",
            "rootPath": fixture.sources.appendingPathComponent("tasks").path, "revision": 1]]
        var budgets = collector["budgets"] as! [String: Any]
        budgets["maxCaptureFiles"] = 1
        budgets["maxEntriesVisited"] = 16
        budgets["maxCandidateFiles"] = 8
        budgets["maxDirectoryOpens"] = 4
        collector["budgets"] = budgets
        document["collector"] = collector
        return document
    }

    private func writeClineTask(_ fixture: RuntimeFixture, name: String, text: String) throws -> URL {
        let task = fixture.sources.appendingPathComponent("tasks/task-native")
        try FileManager.default.createDirectory(at: task, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = task.appendingPathComponent(name)
        _ = try writeClineArray(file, text: text, cwd: fixture.project.path)
        return file
    }

    @discardableResult
    private func writeClineArray(_ file: URL, text: String, cwd: String) throws -> Data {
        let request = String(decoding: try JSONSerialization.data(withJSONObject: [
            "request": "Current Working Directory (\(cwd)) Files listed",
        ], options: [.sortedKeys]), as: UTF8.self)
        let objects: [[String: Any]] = [
            ["say": "task", "ts": 1_704_067_200_000, "text": text],
            ["say": "api_req_started", "ts": 1_704_067_200_100, "text": request],
            ["say": "text", "ts": 1_704_067_200_200, "text": text + " reply",
             "modelInfo": ["modelId": "cline-model"]],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        return bytes
    }

    private func assertReplicaObjects(
        _ replicas: RuntimeReplicas,
        cas: EngramCollectorCore.ImmutableArchiveCAS,
        manifest: EngramCollectorCore.ArchiveSourceManifest,
        expected: Data
    ) async throws {
        var restored = Data()
        for chunk in manifest.chunks { restored.append(try cas.readObject(sha256: chunk.rawSHA256)) }
        XCTAssertEqual(restored, expected)
        for replica in [replicas.hq, replicas.m1] {
            var stored = Data()
            for chunk in manifest.chunks {
                stored.append(try await replica.getSyntheticArchive("objects/" + chunk.rawSHA256))
            }
            XCTAssertEqual(stored, expected)
        }
    }

    private func writeQwenTranscript(
        _ fixture: RuntimeFixture, text: String, conflictingIdentity: Bool = false
    ) throws -> URL {
        let chats = fixture.sources.appendingPathComponent("qwen-project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": "native-qwen", "cwd": fixture.project.path,
             "timestamp": "2026-09-08T00:00:00Z", "message": ["parts": [["text": text]]]],
            ["type": "assistant", "sessionId": conflictingIdentity ? "different-native-qwen" : "native-qwen",
             "cwd": fixture.project.path, "model": "qwen3-coder", "timestamp": "2026-09-08T00:00:01Z",
             "message": ["parts": [["text": "qwen reply"]]],
             "usageMetadata": ["promptTokenCount": 12, "candidatesTokenCount": 7]],
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        let file = chats.appendingPathComponent("session.jsonl")
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        return file
    }

    private func customClaudeDocument(
        _ fixture: RuntimeFixture, replicas: RuntimeReplicas, parseFormat: String
    ) -> [String: Any] {
        var document = fixture.document(replicas: replicas)
        var collector = document["collector"] as! [String: Any]
        collector["roots"] = [[
            "rootID": "runtime-claude-custom", "source": "claude-code",
            "rootPath": fixture.sources.path, "revision": 1, "parseFormat": parseFormat,
        ]]
        var budgets = collector["budgets"] as! [String: Any]
        budgets["maxEntriesVisited"] = 16
        budgets["maxCandidateFiles"] = 8
        budgets["maxDirectoryOpens"] = 4
        collector["budgets"] = budgets
        document["collector"] = collector
        return document
    }

    private func writeCustomClaudeMiniMax(_ fixture: RuntimeFixture, text: String) throws {
        let project = fixture.sources.appendingPathComponent("synthetic-project")
        if !FileManager.default.fileExists(atPath: project.path) {
            try FileManager.default.createDirectory(
                at: project, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": "native-runtime-custom", "cwd": fixture.project.path,
             "message": ["content": text]],
            ["type": "assistant", "sessionId": "native-runtime-custom", "cwd": fixture.project.path,
             "message": ["model": "MiniMax-M2.1", "content": text]],
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        let file = project.appendingPathComponent("claude-session.jsonl")
        try bytes.write(to: file)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
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

    init(seedStores: Bool = true) throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        base = checkout.appendingPathComponent(".engram-runtime-test-\(UUID().uuidString)")
        settings = base.appendingPathComponent("settings.json")
        shadow = base.appendingPathComponent("shadow")
        capture = shadow.appendingPathComponent("capture")
        identity = base.appendingPathComponent("identity/archive.sqlite")
        sources = base.appendingPathComponent("sources")
        project = base.appendingPathComponent("project")
        let directories = seedStores ? [base, shadow, capture, identity.deletingLastPathComponent(), sources, project] : [base, sources, project]
        for path in directories {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard seedStores else { return }
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

    func document(replicas: RuntimeReplicas? = nil, pollIntervalMilliseconds: Int = 50) -> [String: Any] {
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
                "maxQueuedBatches": 16, "maxQueuedUTF8Bytes": 65536, "pollIntervalMilliseconds": pollIntervalMilliseconds]]]
    }

    func writeSettings(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: settings)
        guard chmod(settings.path, 0o600) == 0 else { throw Failure.unsafeFixture }
    }

    func writeTranscript(_ text: String, name: String = "rollout-one.jsonl",
                         sessionID: String = "native-runtime-session") throws {
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": sessionID, "cwd": project.path]]
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

    func integerRow(_ sql: String) throws -> [Int64] {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: inventory.path, configuration: configuration)
        defer { try? database.close() }
        return try database.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: sql))
            return row.columnNames.map { row[$0] as Int64 }
        }
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

    func awaitACKs(_ expected: Int, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") < expected {
            guard Date() < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func awaitCaptured(relativePath: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let captured = try integer("""
                SELECT COUNT(*) FROM collector_locators WHERE relative_path = '\(relativePath)'
                    AND last_capture_id IS NOT NULL AND acknowledged_revision > 0
                """)
            if captured == 1 { return }
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
    func getSyntheticArchive(_ relative: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/archive/" + relative))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RuntimeFixture.Failure.unsafeFixture }
        return bytes
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
