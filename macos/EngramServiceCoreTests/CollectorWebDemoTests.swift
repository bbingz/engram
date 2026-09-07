import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
import EngramCoreRead
@testable import EngramCollectorCore
@testable import EngramCoreWrite
@testable import EngramServiceCore
@testable import EngramRemoteServerCore

/// A synthetic-data composition test, not a deployed collector or uploader.
/// Capture and replica transfer run in process; Web requests use real HTTP and IPC.
final class CollectorWebDemoTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let revision = "swift-demo-v1"
    private let viewer = "synthetic-local-demo-viewer"

    func testSyntheticCaptureToCentralToWeb() async throws {
        let hold = min(900, max(0, Int(ProcessInfo.processInfo.environment["ENGRAM_DEMO_HOLD_SECONDS"] ?? "0") ?? 0))
        executionTimeAllowance = TimeInterval(max(60, hold + 60))
        if let isolatedHome = ProcessInfo.processInfo.environment["ENGRAM_DEMO_EXPECTED_HOME"] {
            guard FileManager.default.homeDirectoryForCurrentUser.path == isolatedHome else {
                return XCTFail("System home must be isolated before running startup integration tests")
            }
            print("ENGRAM_DEMO_HOME_VERIFIED=\(isolatedHome)")
        }
        // Match the owner's existing canonical /Users fixture convention;
        // Foundation normalizes /private/tmp aliases differently from POSIX.
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = checkout.appendingPathComponent(".engram-demo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source")
        let shadow = root.appendingPathComponent("shadow")
        let identity = root.appendingPathComponent("identity")
        let central = root.appendingPathComponent("central")
        let stage = root.appendingPathComponent("stage")
        for url in [sourceRoot, shadow, identity, central, stage] { try directory(url) }
        let identityPath = identity.appendingPathComponent("archive.sqlite")
        try identityCatalog(identityPath)
        // The owner requires separately provisioned identity catalogs.
        try identityCatalog(shadow.appendingPathComponent("archive.sqlite"))
        let projectRoot = sourceRoot.appendingPathComponent("demo-project")
        try directory(projectRoot)
        let source = projectRoot.appendingPathComponent("demo.jsonl")
        let raw = try transcript()
        try raw.write(to: source)
        XCTAssertEqual(chmod(source.path, 0o600), 0)
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
            shadowRoot: shadow, identityCatalog: identityPath, ownerRunID: UUID().uuidString))
        defer { try? owner.close() }
        let configuration = EngramCollectorCore.CollectorRootConfiguration(rootID: "demo-root",
            source: .claudeCode, rootPath: sourceRoot.path, revision: 1)
        _ = try owner.enrollAndActivateRoot(configuration)
        for _ in 0..<8 {
            let step = try owner.stepRoot(configuration, budget: .init(maxEntriesVisited: 32,
                maxCandidateFiles: 16, maxDirectoryOpens: 8, maxMetadataBytes: 16_384))
            if step.outcome == .finished { break }
        }
        let claims = try owner.claimDirty(configuration: configuration, limit: 1, now: 1)
        let claim = try XCTUnwrap(claims.first)
        XCTAssertEqual(claim.relativePath, "demo-project/demo.jsonl")
        let captureRoot = root.appendingPathComponent("capture")
        let collectorCAS = try EngramCollectorCore.ImmutableArchiveCAS(root: captureRoot)
        let catalog = try EngramCollectorCore.ArchiveCatalog(root: captureRoot, machineID: machine)
        try catalog.migrate()
        let descriptor = try EngramCollectorCore.ArchiveSourceDescriptor.singleFile(locator: source.path,
            sourceURL: source, replayRelativePath: claim.relativePath)
        let captured = try EngramCollectorCore.ExactSourceCapturer(cas: collectorCAS, catalog: catalog,
            descriptor: descriptor).capture(source: .claudeCode, locator: source.path, machineID: machine)
        let privacy = try EngramCollectorCore.CollectorPrivacyProof.assess(capture: captured,
            cas: collectorCAS, format: .claudeCode(forceClaudeCodeSource: false),
            policy: .init(revision: 1, excludedProjectRoots: []))
        guard case .eligible(let proof) = privacy else { return XCTFail("Synthetic capture was withheld: \(privacy)") }
        XCTAssertEqual(proof.nativeSessionID, "demo-session")
        XCTAssertEqual(try owner.acknowledge(claim, configuration: configuration,
            captureID: captured.manifest.captureID), .acknowledged)
        XCTAssertTrue(try owner.claimDirty(configuration: configuration, limit: 1, now: 2).isEmpty)

        // Exercise real encrypted replica storage + durable acceptance, crossing
        // module boundaries as canonical bytes, never synthesizing a server ACK.
        let replica = try EngramRemoteServerCore.ArchiveStore(root: root.appendingPathComponent("replica"),
            key: SymmetricKey(data: Data(repeating: 7, count: 32)), serverID: "demo", publicationsEnabled: true)
        try replica.warmPublicationIndex()
        for chunk in captured.manifest.chunks {
            _ = try replica.putObject(digest: chunk.rawSHA256, raw: collectorCAS.readObject(sha256: chunk.rawSHA256))
        }
        let manifestSHA = captured.capture.unboundManifestSHA256
        _ = try replica.putManifest(digest: manifestSHA, canonicalBytes: captured.capture.unboundManifestBytes)
        let publication = try EngramCoreRead.CollectorPublicationEnvelope(machineID: machine,
            sourceInstanceID: instance, collectorEpoch: epoch, sequence: 1, manifestSHA256: manifestSHA)
        let bytes = try EngramCoreRead.ArchiveCanonicalJSON.encode(publication)
        _ = try replica.acceptPublication(digest: publication.sha256(), canonicalBytes: bytes)
        let accepted = try replica.listPublications(cursor: nil, limit: 10)
        XCTAssertEqual(accepted.items.count, 1)
        let page = try EngramCoreRead.ArchiveCanonicalJSON.decode(EngramCoreRead.CollectorPublicationPage.self,
            from: EngramRemoteServerCore.ArchiveCanonicalJSON.encode(accepted))
        let cas = try EngramCoreWrite.ImmutableArchiveCAS(root: central.appendingPathComponent("cas"))
        for chunk in captured.manifest.chunks {
            _ = try cas.publishObject(raw: replica.getObject(digest: chunk.rawSHA256), expectedSHA256: chunk.rawSHA256)
        }
        _ = try cas.publishManifest(replica.getManifest(digest: manifestSHA), expectedSHA256: manifestSHA)
        let databasePath = central.appendingPathComponent("index.sqlite").path
        let writer = try EngramCoreWrite.EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        let gate = try EngramServiceCore.ServiceWriterGate(databasePath: databasePath, runtimeDirectory: central,
            writerFactory: { _ in writer })
        _ = try await gate.performWriteCommand(name: "demoAccept") { writer in
            try writer.write { db in
                _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db, machineID: self.machine,
                    sourceInstanceID: self.instance, source: .claudeCode, parseFormat: .claudeDefault,
                    configuredRoot: sourceRoot.path, initialEpoch: self.epoch)
                try EngramCoreWrite.CaptureIngestLedger.accept(db, page: page, requestedCursor: nil,
                    serverID: "demo", parserRevision: self.revision)
            }
        }
        let worker = EngramServiceCore.ServiceCaptureIngestWorker(gate: gate, cas: cas, stagingParent: stage,
            policy: { .init(parserRevision: self.revision, enabledSources: [.claudeCode]) },
            unixClock: { Int64(Date().timeIntervalSince1970) })
        guard case .parsed(let receipt) = try await worker.step() else { return XCTFail("Worker did not parse the captured publication") }
        let normalized = try writer.read { db in
            try EngramCoreWrite.CaptureIngestNormalizedStore.load(db, sessionID: receipt.sessionID,
                generationID: receipt.generationID, expectedParserRevision: revision, enabledSources: [.claudeCode])
        }
        XCTAssertEqual(normalized.messages.count, 2)
        _ = try await gate.performWriteCommand(name: "demoReady") { writer in
            try writer.write { db in
                try EngramCoreWrite.CaptureIngestReadiness.commit(db, snapshot: normalized,
                    expectedParserRevision: self.revision, enabledSources: [.claudeCode])
            }
        }
        let metadata = try EngramServiceCore.ServiceWebMetadataProducer(databasePath: databasePath,
            policy: { .init(parserRevision: self.revision, enabledSources: [.claudeCode]) })
        defer { try? metadata.stop() }
        let transcripts = try EngramServiceCore.ServiceWebNormalizedTranscriptSnapshotProvider(databasePath: databasePath,
            policy: { .init(parserRevision: self.revision, enabledSources: [.claudeCode]) })
        defer { try? transcripts.stop() }
        let handler = EngramServiceCore.EngramServiceCommandHandler(writerGate: gate,
            webTranscriptSnapshotProvider: transcripts, webMetadataProducer: metadata)
        let socketRoot = URL(fileURLWithPath: "/tmp/eg-demo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try directory(socketRoot)
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = socketRoot.appendingPathComponent("service.sock").path
        let ipc = EngramServiceCore.UnixSocketServiceServer(socketPath: socket) { await handler.handle($0) }
        try ipc.start()
        defer { ipc.stop() }
        let port = hold > 0 ? 18789 : 0
        // Test-only HTTP configuration is already constrained to loopback.
        let authority = "127.0.0.1:18789"
        let origin = "http://\(authority)"
        let config = try EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: port,
            storeRoot: root.appendingPathComponent("web-store"), bearerToken: "synthetic-legacy-token",
            atRestKey: SymmetricKey(data: Data(repeating: 8, count: 32)),
            web: .forLoopbackHTTPTesting(origin: origin, viewerCredential: viewer,
                serverBearerCredentials: ["synthetic-legacy-token"]), webServiceSocketPath: socket)
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: config)
        let bound = expectation(description: "HTTP listener bound")
        let boundPort = DemoPort()
        let serving = Task { try await app.run { port in boundPort.set(port); bound.fulfill() } }
        defer { serving.cancel() }
        await fulfillment(of: [bound], timeout: 10)
        let base = "http://127.0.0.1:\(try XCTUnwrap(boundPort.value))"
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", cookie: String? = nil, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
            request.httpMethod = method
            request.setValue(authority, forHTTPHeaderField: "Host")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("1", forHTTPHeaderField: "X-Engram-Web")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await client.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        let login = try await request("/web/api/auth", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["credential": viewer]))
        XCTAssertEqual(login.1.statusCode, 204)
        let cookie = try XCTUnwrap(login.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
        let overview = try await request("/web/api/overview", cookie: cookie)
        XCTAssertEqual(overview.1.statusCode, 200)
        let overviewObject = try XCTUnwrap(JSONSerialization.jsonObject(with: overview.0) as? [String: Any])
        let capabilities = try XCTUnwrap(overviewObject["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["transcriptRead"] as? String, "available")
        let sessions = try await request("/web/api/sessions?query=constellation", cookie: cookie)
        XCTAssertEqual(sessions.1.statusCode, 200)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: sessions.0) as? [String: Any])
        let items = try XCTUnwrap(list["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1, "Actual FTS query must find the captured conversation")
        let sessionID = try XCTUnwrap(items.first?["sessionId"] as? String)
        XCTAssertEqual(sessionID, receipt.sessionID)
        let escapedID = try XCTUnwrap(sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let detail = try await request("/web/api/sessions/\(escapedID)", cookie: cookie)
        XCTAssertEqual(detail.1.statusCode, 200)
        let detailObject = try XCTUnwrap(JSONSerialization.jsonObject(with: detail.0) as? [String: Any])
        let detailValue = try XCTUnwrap(detailObject["detail"] as? [String: Any])
        XCTAssertEqual(detailValue["transcriptAvailability"] as? String, "available")
        XCTAssertEqual(detailValue["transcriptGeneration"] as? String, receipt.generationID)
        let messages = try await request("/web/api/sessions/\(escapedID)/messages?generation=\(receipt.generationID)", cookie: cookie)
        XCTAssertEqual(messages.1.statusCode, 200)
        XCTAssertTrue(String(decoding: messages.0, as: UTF8.self).contains("constellation"))
        let html = try await request("/web/")
        XCTAssertEqual(html.1.statusCode, 200)
        XCTAssertTrue(String(decoding: html.0, as: UTF8.self).contains("<html"))
        XCTAssertEqual(try Data(contentsOf: source), raw, "Capture must not modify the synthetic source")
        if hold > 0 {
            print("ENGRAM_DEMO_READY \(origin)/web/ credential=\(viewer) holdSeconds=\(hold)")
            try await Task.sleep(for: .seconds(hold))
        }
        serving.cancel()
        _ = try? await serving.value
        ipc.stop()
        let drained = await ipc.drainClientHandlers(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(drained)
        try await worker.stop()
    }

    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    private func identityCatalog(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [machine])
        }
        try queue.close()
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func transcript() throws -> Data {
        let longTranscript = ProcessInfo.processInfo.environment["ENGRAM_DEMO_LONG_TRANSCRIPT"] == "1"
        let assistantText = longTranscript
            ? "constellation <img src=x onerror=alert(1)> " + String(repeating: "星🙂", count: 45_000)
                + " " + String(repeating: "W", count: 600) + " end-of-transcript"
            : "The constellation travels from exact capture through central indexing to this Web view."
        let common: [String: Any] = ["sessionId": "demo-session", "cwd": "/synthetic/constellation", "timestamp": "2026-09-06T00:00:00Z"]
        let records: [[String: Any]] = [
            common.merging(["type": "user", "message": ["content": "Explain the constellation capture demo."]]) { _, value in value },
            common.merging(["type": "assistant", "message": ["model": "synthetic-model", "content": [["type": "text", "text": assistantText]]]]) { _, value in value },
        ]
        var bytes = Data()
        for record in records { bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); bytes.append(10) }
        return bytes
    }
}

private final class DemoPort: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ port: Int) { lock.lock(); defer { lock.unlock() }; storage = port }
}
