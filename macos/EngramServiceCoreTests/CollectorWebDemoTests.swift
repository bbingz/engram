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
        let raw = try transcript(cwd: projectRoot.path)
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
        XCTAssertEqual(normalized.messages.count, 3)
        _ = try await gate.performWriteCommand(name: "demoReady") { writer in
            try writer.write { db in
                try EngramCoreWrite.CaptureIngestReadiness.commit(db, snapshot: normalized,
                    expectedParserRevision: self.revision, enabledSources: [.claudeCode])
            }
        }
        let usageTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T01:00:00Z"))
        _ = try await gate.performWriteCommand(name: "demoUsage") { writer in
            try EngramCoreWrite.WriterStartupUsageCollector(writer: writer, now: { usageTime }).collect()
        }
        let repoCandidates = try writer.read { try EngramCoreWrite.RepoDiscovery.sessionCwdCounts($0) }
        XCTAssertEqual(repoCandidates.map(\.cwd), [projectRoot.path])
        _ = try await gate.performWriteCommand(name: "demoRepoObservations") { writer in
            try writer.write { db in
                try EngramCoreWrite.RepoDiscovery.discover(db, probe: { cwd in
                    EngramCoreWrite.GitRepoProbe(path: cwd, name: "Constellation", branch: "feature/capture",
                        dirtyCount: 2, untrackedCount: 1, unpushedCount: 0,
                        lastCommitHash: String(repeating: "a", count: 40), lastCommitMsg: "Restore capture indexing",
                        lastCommitAt: "2026-09-06T00:00:00Z")
                }, now: { "2026-09-06T01:00:00Z" })
            }
        }
        let aiConfiguration = URLSessionConfiguration.ephemeral
        aiConfiguration.protocolClasses = [DemoAIURLProtocol.self]
        let aiSession = URLSession(configuration: aiConfiguration)
        defer { aiSession.invalidateAndCancel() }
        let aiAnswer = try await EngramServiceCore.EngramServiceCommandHandler.ServiceAIClient.chat(
            purpose: "summary", sessionID: receipt.sessionID,
            config: .init(provider: "synthetic", baseURL: "https://engram-ai.test/v1",
                apiKey: "synthetic-test-key", model: "demo-chat", maxTokens: 100, temperature: 0),
            messages: [["role": "user", "content": "Summarize the captured session."]],
            urlSession: aiSession, audit: EngramServiceCore.ServiceAIAuditRecorder(writerGate: gate))
        XCTAssertEqual(aiAnswer, "Synthetic captured summary")
        let fullSavedSummary = String(repeating: "The complete saved summary preserves each decision and next step. ", count: 20)
        let insightContent = "Continuity " + String(repeating: "🙂中", count: 4_500)
        _ = try await gate.performWriteCommand(name: "demoInsight") { writer in
            try writer.write { db in
                try db.execute(sql: "UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?",
                    arguments: [fullSavedSummary, normalized.messages.count, receipt.sessionID])
                try db.execute(sql: "INSERT INTO insights (id, content, source_session_id) VALUES (?, ?, ?)",
                    arguments: ["demo-insight", insightContent, receipt.sessionID])
                try db.execute(sql: "INSERT INTO insights_fts (insight_id, content) VALUES (?, ?)",
                    arguments: ["demo-insight", insightContent])
            }
        }
        let searchReader = try EngramServiceCore.SQLiteEngramServiceReadProvider(
            databasePath: databasePath, embeddingEnvironment: [:])
        let metadata = try EngramServiceCore.ServiceWebMetadataProducer(databasePath: databasePath,
            policy: { .init(parserRevision: self.revision, enabledSources: [.claudeCode]) })
        defer { try? metadata.stop() }
        let transcripts = try EngramServiceCore.ServiceWebNormalizedTranscriptSnapshotProvider(databasePath: databasePath,
            policy: { .init(parserRevision: self.revision, enabledSources: [.claudeCode]) })
        defer { try? transcripts.stop() }
        let handler = EngramServiceCore.EngramServiceCommandHandler(writerGate: gate,
            webTranscriptSnapshotProvider: transcripts, webMetadataProducer: metadata, readProvider: searchReader)
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
        XCTAssertEqual(detailValue["summary"] as? String, fullSavedSummary, "Web detail must preserve the complete saved summary through producer and handler projection")
        let messages = try await request("/web/api/sessions/\(escapedID)/messages?generation=\(receipt.generationID)", cookie: cookie)
        XCTAssertEqual(messages.1.statusCode, 200)
        XCTAssertTrue(String(decoding: messages.0, as: UTF8.self).contains("constellation"))
        let children = try await request("/web/api/sessions/\(escapedID)/children?limit=20", cookie: cookie)
        XCTAssertEqual(children.1.statusCode, 200)
        let childPage = try XCTUnwrap(JSONSerialization.jsonObject(with: children.0) as? [String: Any])
        XCTAssertEqual(childPage["sessionId"] as? String, sessionID)
        XCTAssertEqual((childPage["items"] as? [[String: Any]])?.count, 0)
        let timeline = try await request("/web/api/sessions/\(escapedID)/timeline?generation=\(receipt.generationID)&limit=1", cookie: cookie)
        XCTAssertEqual(timeline.1.statusCode, 200)
        let timelinePage = try XCTUnwrap(JSONSerialization.jsonObject(with: timeline.0) as? [String: Any])
        XCTAssertEqual(timelinePage["generation"] as? String, receipt.generationID)
        XCTAssertEqual(timelinePage["totalEntries"] as? Int, 3)
        XCTAssertEqual((timelinePage["entries"] as? [[String: Any]])?.first?["index"] as? Int, 0)
        let nextOffset = try XCTUnwrap(timelinePage["nextOffset"] as? Int)
        let timelineNext = try await request("/web/api/sessions/\(escapedID)/timeline?generation=\(receipt.generationID)&offset=\(nextOffset)&limit=2", cookie: cookie)
        XCTAssertEqual(timelineNext.1.statusCode, 200)
        let nextPage = try XCTUnwrap(JSONSerialization.jsonObject(with: timelineNext.0) as? [String: Any])
        XCTAssertEqual((nextPage["entries"] as? [[String: Any]])?.first?["index"] as? Int, 1)
        XCTAssertNil(nextPage["nextOffset"])
        let tools = try await request("/web/api/tool-analytics?groupBy=session", cookie: cookie)
        XCTAssertEqual(tools.1.statusCode, 200)
        let toolPage = try XCTUnwrap(JSONSerialization.jsonObject(with: tools.0) as? [String: Any])
        XCTAssertEqual(toolPage["totalCalls"] as? Int, 1)
        XCTAssertEqual(toolPage["groupCount"] as? Int, 1)
        let toolItems = try XCTUnwrap(toolPage["items"] as? [[String: Any]])
        XCTAssertEqual(toolItems.first?["sessionId"] as? String, receipt.sessionID)
        XCTAssertEqual(toolItems.first?["callCount"] as? Int, 1)
        let files = try await request("/web/api/file-activity", cookie: cookie)
        XCTAssertEqual(files.1.statusCode, 200)
        let filePage = try XCTUnwrap(JSONSerialization.jsonObject(with: files.0) as? [String: Any])
        XCTAssertEqual(filePage["totalFiles"] as? Int, 1)
        XCTAssertEqual(filePage["totalOperations"] as? Int, 1)
        let fileItems = try XCTUnwrap(filePage["items"] as? [[String: Any]])
        XCTAssertEqual(fileItems.first?["readCount"] as? Int, 1)
        XCTAssertEqual(fileItems.first?["editCount"] as? Int, 0)
        XCTAssertEqual(fileItems.first?["writeCount"] as? Int, 0)
        XCTAssertEqual(fileItems.first?["sessionCount"] as? Int, 1)
        XCTAssertTrue((fileItems.first?["label"] as? String)?.contains("main.swift") == true)
        XCTAssertFalse(String(decoding: files.0, as: UTF8.self).contains("/synthetic/"))
        let usage = try await request("/web/api/usage", cookie: cookie)
        XCTAssertEqual(usage.1.statusCode, 200)
        let usagePage = try XCTUnwrap(JSONSerialization.jsonObject(with: usage.0) as? [String: Any])
        XCTAssertEqual(usagePage["scope"] as? String, "server")
        let usageItems = try XCTUnwrap(usagePage["items"] as? [[String: Any]])
        let tokenUsage = try XCTUnwrap(usageItems.first { $0["metric"] as? String == "5h token total" })
        XCTAssertEqual(tokenUsage["source"] as? String, "claude-code")
        XCTAssertEqual(tokenUsage["value"] as? Int, 140)
        XCTAssertEqual(tokenUsage["basis"] as? String, "indexedSessions")
        let repos = try await request("/web/api/repos", cookie: cookie)
        XCTAssertEqual(repos.1.statusCode, 200)
        let repoPage = try XCTUnwrap(JSONSerialization.jsonObject(with: repos.0) as? [String: Any])
        XCTAssertEqual(repoPage["scope"] as? String, "serverFilesystem")
        XCTAssertEqual(repoPage["totalRepos"] as? Int, 1)
        let repoItems = try XCTUnwrap(repoPage["items"] as? [[String: Any]])
        XCTAssertEqual(repoItems.first?["name"] as? String, "Constellation")
        XCTAssertEqual(repoItems.first?["branch"] as? String, "feature/capture")
        XCTAssertEqual(repoItems.first?["dirtyCount"] as? Int, 2)
        XCTAssertEqual(repoItems.first?["sessionCount"] as? Int, 1)
        XCTAssertFalse(String(decoding: repos.0, as: UTF8.self).contains("/synthetic/"))
        let audit = try await request("/web/api/ai/audit?sessionId=\(escapedID)", cookie: cookie)
        XCTAssertEqual(audit.1.statusCode, 200)
        let auditPage = try XCTUnwrap(JSONSerialization.jsonObject(with: audit.0) as? [String: Any])
        XCTAssertEqual(auditPage["total"] as? Int, 1)
        let auditItem = try XCTUnwrap((auditPage["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(auditItem["sessionId"] as? String, receipt.sessionID)
        XCTAssertEqual(auditItem["caller"] as? String, "summary")
        XCTAssertEqual(auditItem["model"] as? String, "demo-chat")
        XCTAssertEqual(auditItem["totalTokens"] as? Int, 150)
        let auditID = try XCTUnwrap(auditItem["id"] as? String)
        let auditDetail = try await request("/web/api/ai/audit/\(auditID)", cookie: cookie)
        XCTAssertEqual(auditDetail.1.statusCode, 200)
        let auditDetailPage = try XCTUnwrap(JSONSerialization.jsonObject(with: auditDetail.0) as? [String: Any])
        XCTAssertEqual(auditDetailPage["hasRequestBody"] as? Bool, false)
        XCTAssertEqual(auditDetailPage["hasResponseBody"] as? Bool, false)
        XCTAssertFalse(String(decoding: auditDetail.0, as: UTF8.self).contains("synthetic-test-key"))
        let aiStats = try await request("/web/api/ai/stats", cookie: cookie)
        XCTAssertEqual(aiStats.1.statusCode, 200)
        let aiStatsPage = try XCTUnwrap(JSONSerialization.jsonObject(with: aiStats.0) as? [String: Any])
        let aiTotals = try XCTUnwrap(aiStatsPage["totals"] as? [String: Any])
        XCTAssertEqual(aiTotals["requests"] as? Int, 1)
        XCTAssertEqual(aiTotals["promptTokens"] as? Int, 120)
        XCTAssertEqual(aiTotals["completionTokens"] as? Int, 30)
        let insightSearch = try await request("/web/api/search?query=Continuity", cookie: cookie)
        XCTAssertEqual(insightSearch.1.statusCode, 200)
        let insightSearchPage = try XCTUnwrap(JSONSerialization.jsonObject(with: insightSearch.0) as? [String: Any])
        XCTAssertEqual((insightSearchPage["items"] as? [Any])?.count, 0)
        let insightHit = try XCTUnwrap((insightSearchPage["insightResults"] as? [[String: Any]])?.first)
        XCTAssertEqual(insightHit["id"] as? String, "demo-insight")
        XCTAssertEqual(insightHit["sourceSessionId"] as? String, receipt.sessionID)
        XCTAssertLessThanOrEqual(try XCTUnwrap(insightHit["content"] as? String).unicodeScalars.count, 600)
        let insightFirst = try await request("/web/api/insights/demo-insight", cookie: cookie)
        XCTAssertEqual(insightFirst.1.statusCode, 200)
        let firstInsightPage = try XCTUnwrap(JSONSerialization.jsonObject(with: insightFirst.0) as? [String: Any])
        let insightRevision = try XCTUnwrap(firstInsightPage["revision"] as? String)
        let nextInsightOffset = try XCTUnwrap(firstInsightPage["nextOffset"] as? Int)
        XCTAssertEqual(nextInsightOffset, 8_000)
        let insightNext = try await request("/web/api/insights/demo-insight?offset=\(nextInsightOffset)&revision=\(insightRevision)", cookie: cookie)
        XCTAssertEqual(insightNext.1.statusCode, 200)
        let nextInsightPage = try XCTUnwrap(JSONSerialization.jsonObject(with: insightNext.0) as? [String: Any])
        XCTAssertNil(nextInsightPage["nextOffset"])
        XCTAssertEqual(try XCTUnwrap(firstInsightPage["content"] as? String) + XCTUnwrap(nextInsightPage["content"] as? String), insightContent)
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

    /// Real HTTP -> typed socket client -> service gate -> SQLite -> Settings read.
    /// Uses only synthetic records and isolated loopback listeners.
    func testAliasEditorThroughHTTPAndServiceIPC() async throws {
        let fixture = try MetadataSQLFixture()
        defer { fixture.remove() }
        try fixture.migrate()
        try fixture.seedRegistry()
        let rawProject = "/synthetic/engram"
        let rawAlias = "/old/synthetic-engram"
        try fixture.seedBoundSession(id: "alias-session", start: "2026-09-01 12:00:00", project: rawProject)
        try fixture.seedBoundSession(id: "manual-hidden", start: "2026-09-01 12:00:00", nativeID: "manual-native", project: rawProject, hidden: true)
        try fixture.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS session_local_state (session_id TEXT PRIMARY KEY, hidden_at TEXT, custom_name TEXT, local_readable_path TEXT)")
            try db.execute(sql: "INSERT INTO session_local_state(session_id, hidden_at) VALUES ('manual-hidden', '2026-09-01 12:00:00')")
        }
        for id in ["relationship-child", "relationship-confirm", "relationship-dismiss"] {
            try fixture.seedBoundSession(id: id, start: "2026-09-01 12:01:00", nativeID: "native-\(id)", project: rawProject)
        }
        try fixture.write { db in
            try db.execute(sql: "UPDATE sessions SET suggested_parent_id = 'alias-session' WHERE id IN ('relationship-confirm', 'relationship-dismiss')")
        }
        let settingsURL = fixture.directory.appendingPathComponent("settings.json")
        let settings: [String: Any] = [
            "runtimeRole": "index",
            "disabledSources": EngramServiceCore.EngramServiceWebSourceSettingsValidation.knownKeys.filter { $0 != "claude-code" }.sorted(),
            EngramServiceCore.ArchivedDefaultOffSources.settingsMigrationKey: true,
            "customSetting": "preserve-me",
            "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1", "credentialID": "hq"],
        ]
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        let previousSettingsPath = getenv("ENGRAM_SETTINGS_PATH").map { String(cString: $0) }
        setenv("ENGRAM_SETTINGS_PATH", settingsURL.path, 1)
        defer {
            if let previousSettingsPath { setenv("ENGRAM_SETTINGS_PATH", previousSettingsPath, 1) }
            else { unsetenv("ENGRAM_SETTINGS_PATH") }
        }
        let metadata = try fixture.producer(policy: {
            guard let policy = EngramServiceCore.ServiceCaptureIngestRuntime.policy(at: settingsURL) else { return nil }
            return .init(parserRevision: "parser-v1", enabledSources: policy.enabledSources)
        }, liveClock: true)
        defer { try? metadata.stop() }
        let runtime = fixture.directory.appendingPathComponent("runtime")
        try directory(runtime)
        let gate = try EngramServiceCore.ServiceWriterGate(databasePath: fixture.path, runtimeDirectory: runtime)
        let searchReader = try EngramServiceCore.SQLiteEngramServiceReadProvider(databasePath: fixture.path, embeddingEnvironment: [:])
        let handler = EngramServiceCore.EngramServiceCommandHandler(writerGate: gate,
            webMetadataProducer: metadata, readProvider: searchReader)
        let socketRoot = URL(fileURLWithPath: "/tmp/eg-alias-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try directory(socketRoot)
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = socketRoot.appendingPathComponent("service.sock").path
        let ipc = EngramServiceCore.UnixSocketServiceServer(socketPath: socket) { await handler.handle($0) }
        try ipc.start()
        defer { ipc.stop() }
        let authority = "127.0.0.1:18789"
        let origin = "https://\(authority)"
        let editor = "synthetic-alias-editor"
        let config = try EngramRemoteServerCore.EngramRemoteServerConfig(host: "127.0.0.1", port: 0,
            storeRoot: fixture.directory.appendingPathComponent("web-store"), bearerToken: "synthetic-alias-bearer",
            atRestKey: SymmetricKey(data: Data(repeating: 8, count: 32)),
            web: EngramRemoteServerCore.EngramRemoteWebConfig(origin: origin, viewerCredential: viewer,
                serverBearerCredentials: ["synthetic-alias-bearer"], editorCredential: editor), webServiceSocketPath: socket)
        let app = try EngramRemoteServerCore.EngramRemoteServerApp(config: config)
        let bound = expectation(description: "Alias HTTP listener bound")
        let boundPort = DemoPort()
        let serving = Task { try await app.run { port in boundPort.set(port); bound.fulfill() } }
        defer { serving.cancel() }
        await fulfillment(of: [bound], timeout: 10)
        let base = "http://127.0.0.1:\(try XCTUnwrap(boundPort.value))"
        let clientConfig = URLSessionConfiguration.ephemeral
        clientConfig.httpShouldSetCookies = false
        let client = URLSession(configuration: clientConfig)
        defer { client.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", cookie: String? = nil,
                     body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + path)))
            request.timeoutInterval = 5
            request.httpMethod = method
            request.setValue(authority, forHTTPHeaderField: "Host")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("1", forHTTPHeaderField: "X-Engram-Web")
            if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await client.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        do {
            let viewerLogin = try await request("/web/api/auth", method: "POST", body: ["credential": viewer])
            XCTAssertEqual(viewerLogin.1.statusCode, 204)
            let viewerCookie = try XCTUnwrap(viewerLogin.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
            let canonical = try XCTUnwrap(EngramServiceCore.EngramServiceWebWriteValidation.publishedProjectKey(rawProject))
            let denied = try await request("/web/api/settings/aliases", method: "POST", cookie: viewerCookie,
                body: ["alias": rawAlias, "canonical": canonical])
            XCTAssertEqual(denied.1.statusCode, 403)
            let editorLogin = try await request("/web/api/auth", method: "POST", body: ["credential": editor])
            XCTAssertEqual(editorLogin.1.statusCode, 204)
            let editorCookie = try XCTUnwrap(editorLogin.1.value(forHTTPHeaderField: "Set-Cookie")?.components(separatedBy: ";").first)
            let added = try await request("/web/api/settings/aliases", method: "POST", cookie: editorCookie,
                body: ["alias": rawAlias, "canonical": canonical])
            XCTAssertEqual(added.1.statusCode, 200, String(decoding: added.0, as: UTF8.self))
            let result = try JSONDecoder().decode(EngramRemoteServerCore.EngramServiceWebAliasMutationResponse.self, from: added.0)
            XCTAssertEqual(result.changed, 1)
            let database = try DatabaseQueue(path: fixture.path)
            defer { try? database.close() }
            let stored = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT canonical FROM project_aliases WHERE alias = ?", arguments: [rawAlias])
            }
            XCTAssertEqual(stored, rawProject)
            let settings = try await request("/web/api/settings", cookie: viewerCookie)
            XCTAssertEqual(settings.1.statusCode, 200)
            let page = try JSONDecoder().decode(EngramRemoteServerCore.EngramServiceWebSettingsResponse.self, from: settings.0)
            XCTAssertTrue(page.aliases.contains { $0.alias == result.alias && $0.canonical == canonical })
            XCTAssertFalse(String(decoding: settings.0, as: UTF8.self).contains(rawProject))
            let removed = try await request("/web/api/settings/aliases", method: "DELETE", cookie: editorCookie,
                body: ["alias": result.alias, "canonical": canonical])
            XCTAssertEqual(removed.1.statusCode, 200)
            let remaining = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project_aliases WHERE alias = ?", arguments: [rawAlias])
            }
            XCTAssertEqual(remaining, 0)
            let note = "ContinuitySaved " + String(repeating: "🙂中", count: 6_000)
            let deniedInsight = try await request("/web/api/insights", method: "POST", cookie: viewerCookie,
                body: ["content": note, "sourceSessionId": "alias-session"])
            XCTAssertEqual(deniedInsight.1.statusCode, 403)
            let savedInsight = try await request("/web/api/insights", method: "POST", cookie: editorCookie,
                body: ["content": note, "wing": "Engineering", "room": "Engram", "importance": 4,
                       "sourceSessionId": "alias-session"])
            XCTAssertEqual(savedInsight.1.statusCode, 200, String(decoding: savedInsight.0, as: UTF8.self))
            let savedNote = try XCTUnwrap(JSONSerialization.jsonObject(with: savedInsight.0) as? [String: Any])
            let noteID = try XCTUnwrap(savedNote["id"] as? String)
            let storedNote = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT content FROM insights WHERE id = ?", arguments: [noteID])
            }
            XCTAssertEqual(storedNote, note)
            let foundNote = try await request("/web/api/search?query=ContinuitySaved", cookie: viewerCookie)
            XCTAssertEqual(foundNote.1.statusCode, 200)
            let foundNotePage = try XCTUnwrap(JSONSerialization.jsonObject(with: foundNote.0) as? [String: Any])
            XCTAssertEqual((foundNotePage["insightResults"] as? [[String: Any]])?.first?["id"] as? String, noteID)
            let readNote = try await request("/web/api/insights/\(noteID)", cookie: viewerCookie)
            XCTAssertEqual(readNote.1.statusCode, 200)
            let readNotePage = try XCTUnwrap(JSONSerialization.jsonObject(with: readNote.0) as? [String: Any])
            XCTAssertEqual(readNotePage["sourceSessionId"] as? String, "alias-session")
            XCTAssertEqual(readNotePage["content"] as? String, String(String.UnicodeScalarView(note.unicodeScalars.prefix(8_000))))
            let deniedHiddenNote = try await request("/web/api/insights", method: "POST", cookie: editorCookie,
                body: ["content": "Hidden source must not receive a new note", "sourceSessionId": "manual-hidden"])
            XCTAssertTrue([403, 404].contains(deniedHiddenNote.1.statusCode))
            let hiddenNoteCount = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights WHERE source_session_id = 'manual-hidden'")
            }
            XCTAssertEqual(hiddenNoteCount, 0)
            let relationshipBase = "/web/api/sessions/relationship-child"
            let deniedLink = try await request(relationshipBase + "/link", method: "POST", cookie: viewerCookie, body: ["parentId": "alias-session"])
            XCTAssertEqual(deniedLink.1.statusCode, 403)
            let linked = try await request(relationshipBase + "/link", method: "POST", cookie: editorCookie, body: ["parentId": "alias-session"])
            XCTAssertEqual(linked.1.statusCode, 200, String(decoding: linked.0, as: UTF8.self))
            let linkedChildren = try await request("/web/api/sessions/alias-session/children", cookie: viewerCookie)
            XCTAssertEqual(linkedChildren.1.statusCode, 200)
            let linkedPage = try JSONDecoder().decode(EngramRemoteServerCore.EngramServiceWebChildrenResponse.self, from: linkedChildren.0)
            XCTAssertTrue(linkedPage.items.contains { $0.session.sessionId == "relationship-child" && $0.relationship == .confirmed })
            let unlinked = try await request(relationshipBase + "/link", method: "DELETE", cookie: editorCookie, body: [:])
            XCTAssertEqual(unlinked.1.statusCode, 200)
            let storedParent = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'relationship-child'")
            }
            XCTAssertNil(storedParent)
            let confirmed = try await request("/web/api/sessions/relationship-confirm/confirm-suggestion", method: "POST", cookie: editorCookie, body: ["suggestedParentId": "alias-session"])
            XCTAssertEqual(confirmed.1.statusCode, 200, String(decoding: confirmed.0, as: UTF8.self))
            let confirmedParent = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT parent_session_id FROM sessions WHERE id = 'relationship-confirm'")
            }
            XCTAssertEqual(confirmedParent, "alias-session")
            let stale = try await request("/web/api/sessions/relationship-dismiss/suggestion", method: "DELETE", cookie: editorCookie, body: ["suggestedParentId": "relationship-child"])
            XCTAssertEqual(stale.1.statusCode, 409)
            let keptSuggestion = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'relationship-dismiss'")
            }
            XCTAssertEqual(keptSuggestion, "alias-session")
            let dismissed = try await request("/web/api/sessions/relationship-dismiss/suggestion", method: "DELETE", cookie: editorCookie, body: ["suggestedParentId": "alias-session"])
            XCTAssertEqual(dismissed.1.statusCode, 200)
            let clearedSuggestion = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT suggested_parent_id FROM sessions WHERE id = 'relationship-dismiss'")
            }
            XCTAssertNil(clearedSuggestion)
            let sourcesPath = "/web/api/settings/sources"
            let deniedSource = try await request(sourcesPath, method: "POST", cookie: viewerCookie,
                body: ["source": "claude-code", "enabled": false])
            XCTAssertEqual(deniedSource.1.statusCode, 403)
            let disabled = try await request(sourcesPath, method: "POST", cookie: editorCookie,
                body: ["source": "claude-code", "enabled": false])
            XCTAssertEqual(disabled.1.statusCode, 200)
            let offResponse = try await request(sourcesPath, cookie: viewerCookie)
            XCTAssertEqual(offResponse.1.statusCode, 200)
            let off = try JSONDecoder().decode(EngramRemoteServerCore.EngramServiceWebSourceSettingsResponse.self, from: offResponse.0)
            XCTAssertFalse(off.sources.isEmpty)
            XCTAssertTrue(off.sources.allSatisfy { !$0.enabled }, "Controls remain readable with all sources off")
            let hidden = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE hidden_at IS NOT NULL AND id IN ('alias-session', 'manual-hidden')")
            }
            XCTAssertEqual(hidden, 2)
            let enabled = try await request(sourcesPath, method: "POST", cookie: editorCookie,
                body: ["source": "claude-code", "enabled": true])
            XCTAssertEqual(enabled.1.statusCode, 200)
            let visible = try await database.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM sessions WHERE hidden_at IS NULL ORDER BY id")
            }
            XCTAssertEqual(visible, ["alias-session", "relationship-child", "relationship-confirm", "relationship-dismiss"], "Manual hide must survive source re-enable")
            let onResponse = try await request(sourcesPath, cookie: viewerCookie)
            let on = try JSONDecoder().decode(EngramRemoteServerCore.EngramServiceWebSourceSettingsResponse.self, from: onResponse.0)
            XCTAssertTrue(on.sources.contains { $0.key == "claude-code" && $0.enabled })
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            XCTAssertEqual(saved["customSetting"] as? String, "preserve-me")
            let aiSettingsPath = "/web/api/settings/ai"
            let currentAISettings = try await request(aiSettingsPath, cookie: viewerCookie)
            XCTAssertEqual(currentAISettings.1.statusCode, 200)
            let aiPatch: [String: Any] = ["aiModel": "fixture-summary-model", "summaryMaxTokens": 800,
                "summaryPrompt": "Decisions\nNext steps",
                "titleProvider": "openai", "titleBaseUrl": "https://title-provider.example/v1",
                "titleModel": "fixture-title-model",
                "aiAudit": ["enabled": true, "logBodies": false, "maxBodySize": 12000]]
            let deniedAISettings = try await request(aiSettingsPath, method: "POST", cookie: viewerCookie, body: aiPatch)
            XCTAssertEqual(deniedAISettings.1.statusCode, 403)
            let changedAISettings = try await request(aiSettingsPath, method: "POST", cookie: editorCookie, body: aiPatch)
            XCTAssertEqual(changedAISettings.1.statusCode, 200, String(decoding: changedAISettings.0, as: UTF8.self))
            let reloadedAISettings = try await request(aiSettingsPath, cookie: viewerCookie)
            XCTAssertEqual(reloadedAISettings.1.statusCode, 200)
            let aiEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reloadedAISettings.0) as? [String: Any])
            let aiValues = try XCTUnwrap(aiEnvelope["settings"] as? [String: Any])
            XCTAssertEqual(aiValues["aiModel"] as? String, "fixture-summary-model")
            XCTAssertEqual(aiValues["summaryMaxTokens"] as? Int, 800)
            XCTAssertNil(aiValues["aiApiKey"])
            XCTAssertEqual(aiValues["summaryPrompt"] as? String, "Decisions\nNext steps")
            let resolvedAI = EngramServiceCore.EngramServiceCommandHandler.ServiceAISettings.read(
                settingsPath: settingsURL, environment: [:],
                keychainReader: { _ in "fixture-only-not-a-real-key" })
            XCTAssertEqual(resolvedAI.summaryConfig?.model, "fixture-summary-model")
            XCTAssertEqual(resolvedAI.summaryConfig?.maxTokens, 800)
            XCTAssertEqual(resolvedAI.summaryConfig?.summaryPrompt, "Decisions\nNext steps")
            XCTAssertEqual(resolvedAI.titleConfig?.model, "fixture-title-model")
            XCTAssertEqual(resolvedAI.titleConfig?.baseURL, "https://title-provider.example/v1")
            XCTAssertEqual(resolvedAI.auditConfig.maxBodySize, 12000)
            let savedAISettings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            XCTAssertEqual(savedAISettings["summaryMaxTokens"] as? Int, 800)
            XCTAssertEqual(savedAISettings["customSetting"] as? String, "preserve-me")
            XCTAssertNotNil(savedAISettings["captureIngest"])
            let rejectedSecret = try await request(aiSettingsPath, method: "POST", cookie: editorCookie,
                body: ["aiApiKey": "fixture-only-not-a-real-key"])
            XCTAssertEqual(rejectedSecret.1.statusCode, 400)
            let afterRejectedSecret = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
            XCTAssertNil(afterRejectedSecret["aiApiKey"])
            let invalidSettings = Data("{}".utf8)
            try invalidSettings.write(to: settingsURL)
            XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
            let unavailable = try await request(sourcesPath, method: "POST", cookie: editorCookie,
                body: ["source": "claude-code", "enabled": false])
            XCTAssertEqual(unavailable.1.statusCode, 503)
            XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettings, "Invalid policy must fail before writing settings")
        } catch {
            serving.cancel()
            _ = try? await serving.value
            throw error
        }
        serving.cancel()
        _ = try? await serving.value
        ipc.stop()
        let drained = await ipc.drainClientHandlers(timeoutNanoseconds: 2_000_000_000)
        XCTAssertTrue(drained)
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

    private func transcript(cwd: String) throws -> Data {
        let longTranscript = ProcessInfo.processInfo.environment["ENGRAM_DEMO_LONG_TRANSCRIPT"] == "1"
        let assistantText = longTranscript
            ? "constellation <img src=x onerror=alert(1)> " + String(repeating: "星🙂", count: 45_000)
                + " " + String(repeating: "W", count: 600) + " end-of-transcript"
            : "The constellation travels from exact capture through central indexing to this Web view."
        let common: [String: Any] = ["sessionId": "demo-session", "cwd": cwd, "timestamp": "2026-09-06T00:00:00Z"]
        let records: [[String: Any]] = [
            common.merging(["type": "user", "message": ["content": "Explain the constellation capture demo."]]) { _, value in value },
            common.merging(["type": "assistant", "message": ["model": "synthetic-model", "usage": ["input_tokens": 100, "output_tokens": 40], "content": [["type": "text", "text": assistantText], ["type": "tool_use", "id": "demo-read", "name": "Read", "input": ["file_path": "/synthetic/constellation/main.swift"]]]]]) { _, value in value },
            common.merging(["type": "user", "message": ["content": "Show the repository branch and summarize pending file changes."]]) { _, value in value },
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

/// In-process provider fixture. No request can reach an external AI endpoint.
private final class DemoAIURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "engram-ai.test",
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let data = Data(#"{"choices":[{"message":{"content":"Synthetic captured summary"}}],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150}}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
