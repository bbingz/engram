import Darwin
import Foundation
import GRDB
import XCTest
import EngramCoreRead
@testable import EngramCollectorCore
@testable import EngramCoreWrite
@testable import EngramServiceCore

private typealias ShadowPublication = EngramCollectorCore.CollectorPublicationEnvelope
private typealias ShadowPage = EngramCollectorCore.CollectorPublicationPage
private typealias ShadowManifest = EngramCollectorCore.ArchiveSourceManifest

/// One synthetic Codex happy path across real executables. This proves neither
/// HTTPS/browser acceptance nor full W6 source, crash, rename or resource gates.
/// The supplied Service must already enforce expected-home and explicit-file
/// credentials without Keychain fallback; older binaries are unsafe to use.
final class CollectorBinaryShadowIntegrationTests: XCTestCase {
    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoCodexGenerations() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialSource()
            try scope.startCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)

            // Only source authority is provisioned before the HQ writer starts.
            // Intake, CAS transfer, normalization and FTS must cross binaries.
            try scope.provisionHQ(firstPublication)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertMessages(firstRead.messages, secondGeneration: false)

            let secondBytes = try scope.appendSecondMessage(to: firstBytes)
            let second = try await scope.awaitDualPublications(count: 2)
            let secondPublication = second[1]
            XCTAssertEqual(second[0], firstPublication)
            XCTAssertEqual(secondPublication.sequence, 2)
            XCTAssertEqual(secondPublication.machineID, firstPublication.machineID)
            XCTAssertEqual(secondPublication.sourceInstanceID, firstPublication.sourceInstanceID)
            XCTAssertEqual(secondPublication.collectorEpoch, firstPublication.collectorEpoch)
            XCTAssertNotEqual(secondPublication.manifestSHA256, firstPublication.manifestSHA256)
            try await scope.assertReplicaBytes(secondPublication, expected: secondBytes)
            let secondRead = try await scope.awaitWebIPC(secondPublication, query: BinaryShadowScope.secondText)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            try scope.assertMessages(secondRead.messages, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary shadow cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }
}

private enum BinaryShadowFailure: Error { case binaryPath, fixture, deadline, replica, payloadLimit, cleanup }

private struct ShadowBinaries {
    let collector: URL
    let service: URL
    let remote: URL

    static func explicitEnvironment() throws -> Self {
        let env = ProcessInfo.processInfo.environment
        let keys = ["ENGRAM_COLLECTOR_BINARY", "ENGRAM_SERVICE_BINARY", "ENGRAM_REMOTE_SERVER_BINARY"]
        guard keys.allSatisfy({ env[$0] != nil }) else {
            throw XCTSkip("Binary shadow requires explicit collector, service and remote binary paths; no fixture was created")
        }
        let paths = try keys.map { key -> URL in
            guard let path = env[key], path.hasPrefix("/"), !path.utf8.contains(0),
                  FileManager.default.isExecutableFile(atPath: path) else { throw BinaryShadowFailure.binaryPath }
            return URL(fileURLWithPath: path)
        }
        return Self(collector: paths[0], service: paths[1], remote: paths[2])
    }
}

private struct ShadowRole {
    let root: URL
    let home: URL
    let temporary: URL

    init(parent: URL, name: String) throws {
        root = parent.appendingPathComponent(name)
        home = root.appendingPathComponent("home")
        temporary = home.appendingPathComponent("tmp")
        for directory in [root, home, temporary] { try BinaryShadowScope.directory(directory) }
    }
}

private struct ShadowReplica {
    let id: String
    let baseURL: URL
    let token: String
    let child: CLIIntegrationChild
}

private final class BinaryShadowScope: @unchecked Sendable {
    static let firstText = "constellation shadowfirst"
    static let secondText = "aurora shadowsecond"
    private static let firstReplyText = "The constellation snapshot is ready for replica verification."
    private static let firstTimestamp = "2026-09-07T00:00:00Z"
    private static let firstReplyTimestamp = "2026-09-07T00:00:01Z"
    private static let secondTimestamp = "2026-09-07T00:00:02Z"
    let fixture: RuntimeFixture
    let socketRoot: URL
    var source: URL { fixture.sources.appendingPathComponent("rollout-one.jsonl") }
    private let binaries: ShadowBinaries
    private let collectorRole: ShadowRole
    private let hqRole: ShadowRole
    private let deadline = Date().addingTimeInterval(25)
    private var children: [CLIIntegrationChild] = []
    private var joinedChildren: [CLIIntegrationChild] = []
    private var launchRecords: [ObjectIdentifier: ShadowLaunchRecord] = [:]
    private var reservations: [ShadowPortReservation] = []
    private var replicas: [ShadowReplica] = []
    private var seedDatabase: DatabaseQueue?
    private var hqStarted = false
    private var socket: String { socketRoot.appendingPathComponent("service.sock").path }
    private var hqDatabase: URL { hqRole.root.appendingPathComponent("index.sqlite") }

    init(binaries: ShadowBinaries) throws {
        self.binaries = binaries
        fixture = try RuntimeFixture()
        var template = Array("/private/tmp/eg-cbs-XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw BinaryShadowFailure.fixture
        }
        socketRoot = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        guard chmod(socketRoot.path, 0o700) == 0 else { throw BinaryShadowFailure.fixture }
        collectorRole = try ShadowRole(parent: fixture.base, name: "collector-process")
        hqRole = try ShadowRole(parent: fixture.base, name: "hq-service-process")
    }

    static func directory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    private func writePrivate(_ bytes: Data, to path: URL) throws {
        guard !FileManager.default.fileExists(atPath: path.path),
              FileManager.default.createFile(atPath: path.path, contents: bytes,
                  attributes: [.posixPermissions: 0o600]) else { throw BinaryShadowFailure.fixture }
    }

    private func writeJSON(_ object: [String: Any], to path: URL) throws {
        try writePrivate(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), to: path)
    }

    private func launch(_ binary: URL, role: ShadowRole, arguments: [String] = [],
                        environment: [String: String] = [:]) throws -> CLIIntegrationChild {
        let child = try CLIIntegrationChild(binary: binary, arguments: arguments, root: role.root,
            home: role.home, temporary: role.temporary, roleEnvironment: environment)
        children.append(child)
        launchRecords[ObjectIdentifier(child)] = ShadowLaunchRecord(binary: binary, role: role,
            arguments: arguments, environment: environment)
        return child
    }

    func startReplicas(browser: ShadowBrowserLaunch? = nil) async throws {
        // Reserve both choices before releasing either. A stolen-port race
        // fails authentication/readiness; it never authorizes killing a listener.
        for _ in 0..<2 { reservations.append(try ShadowPortReservation()) }
        if let browser { try await prepareBrowserTLS(browser, upstreamPort: reservations[0].port) }
        for (index, id) in ["hq", "m1"].enumerated() {
            let role = try ShadowRole(parent: fixture.base, name: "remote-\(id)-process")
            let token = "synthetic-\(id)-\(UUID().uuidString)"
            let port = reservations[index].port
            var environment = [
                "ENGRAM_REMOTE_HOST": "127.0.0.1", "ENGRAM_REMOTE_PORT": String(port),
                "ENGRAM_REMOTE_STORE": role.root.appendingPathComponent("legacy").path,
                "ENGRAM_REMOTE_TOKEN": "synthetic-legacy-\(UUID().uuidString)",
                "ENGRAM_REMOTE_AT_REST_KEY": Data(repeating: UInt8(7 + index), count: 32).base64EncodedString(),
                "ENGRAM_REMOTE_ARCHIVE_ENABLED": "1", "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED": "1",
                "ENGRAM_REMOTE_ARCHIVE_SERVER_ID": id,
                "ENGRAM_REMOTE_ARCHIVE_ROOT": role.root.appendingPathComponent("archive").path,
                "ENGRAM_REMOTE_ARCHIVE_TOKEN": token,
                "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY": Data(repeating: UInt8(17 + index), count: 32).base64EncodedString(),
                "ENGRAM_REMOTE_MCP_ENABLED": "0", "ENGRAM_REMOTE_WEB_ENABLED": "0",
            ]
            if id == "hq", let web = browser?.context {
                environment["ENGRAM_REMOTE_WEB_ENABLED"] = "1"
                environment["ENGRAM_REMOTE_WEB_ORIGIN"] = web.origin
                environment["ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL"] = web.viewerCredential
                environment["ENGRAM_REMOTE_WEB_SERVICE_SOCKET"] = socket
            }
            try reservations[index].close()
            let child = try launch(binaries.remote, role: role, environment: environment)
            replicas.append(ShadowReplica(id: id, baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: token, child: child))
        }
        while true {
            try checkRunning()
            if let hq = try? await page(replicas[0]), let m1 = try? await page(replicas[1]) {
                XCTAssertTrue(hq.items.isEmpty)
                XCTAssertTrue(m1.items.isEmpty)
                let hqCursor = try EngramCollectorCore.CollectorPublicationCursor.decode(hq.afterCursor)
                let m1Cursor = try EngramCollectorCore.CollectorPublicationCursor.decode(m1.afterCursor)
                XCTAssertNotEqual(hqCursor.journalID, m1Cursor.journalID, "replicas must own independent journals")
                return
            }
            try await pause()
        }
    }

    func writeInitialSource() throws -> Data {
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": Self.firstTimestamp,
             "payload": ["id": "binary-shadow-codex", "cwd": fixture.project.path, "originator": "codex-cli", "timestamp": Self.firstTimestamp]],
            ["type": "response_item", "timestamp": Self.firstTimestamp,
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": Self.firstText]]]],
            ["type": "response_item", "timestamp": Self.firstReplyTimestamp,
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": Self.firstReplyText]]]],
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func startCollector() throws {
        var document = fixture.document()
        var collector = try XCTUnwrap(document["collector"] as? [String: Any])
        collector["replicas"] = replicas.map {
            ["serverID": $0.id, "baseURL": $0.baseURL.absoluteString, "credentialID": "\($0.id)-reference"]
        }
        document["collector"] = collector
        try fixture.writeSettings(document)
        let credentials = collectorRole.root.appendingPathComponent("credentials.json")
        try writeJSON(Dictionary(uniqueKeysWithValues: replicas.map { ("\($0.id)-reference", $0.token) }), to: credentials)
        _ = try launch(binaries.collector, role: collectorRole,
            arguments: ["--settings", fixture.settings.path, "--credentials-file", credentials.path])
    }

    func awaitDualPublications(count: Int) async throws -> [ShadowPublication] {
        while true {
            try checkRunning()
            if FileManager.default.fileExists(atPath: fixture.inventory.path),
               let publications = try? fixture.publications(), publications.count == count {
                let hq = try await page(replicas[0])
                let m1 = try await page(replicas[1])
                if hq.items.count == count, m1.items.count == count,
                   try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") == count * 2 {
                    for (replica, page) in zip(replicas, [hq, m1]) {
                        XCTAssertFalse(page.hasMore)
                        XCTAssertEqual(page.items.map(\.publication), publications)
                        for record in page.items { try record.ack.validate(against: record.publication, expectedServerID: replica.id) }
                    }
                    return publications
                }
            }
            try await pause()
        }
    }

    func assertReplicaBytes(_ publication: ShadowPublication, expected: Data) async throws {
        for replica in replicas {
            let manifestBytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(manifestBytes), publication.manifestSHA256)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: manifestBytes)
            XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(expected))
            var raw = Data()
            for chunk in manifest.chunks {
                let bytes = try await fetch(replica, path: "v2/archive/objects/\(chunk.rawSHA256)")
                XCTAssertEqual(bytes.count, Int(chunk.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), chunk.rawSHA256)
                raw.append(bytes)
            }
            XCTAssertEqual(raw, expected, "each real replica must return the exact uploaded source")
        }
    }

    func provisionHQ(_ publication: ShadowPublication) throws {
        guard !hqStarted, seedDatabase == nil else { throw BinaryShadowFailure.fixture }
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        seedDatabase = database
        try database.write { db in
            try EngramCoreWrite.EngramMigrationRunner.migrate(db)
            _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db,
                machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID,
                source: .codex, parseFormat: .codex, configuredRoot: fixture.sources.path,
                initialEpoch: publication.collectorEpoch)
            for table in ["sessions", "capture_ingest_publications", "capture_ingest_ledger",
                          "capture_ingest_identity_bindings", "capture_ingest_generations",
                          "session_index_jobs", "sessions_fts", "fts_map"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), 0)
            }
            // Normalized transcripts live in this generation payload, not a
            // separate messages table. No transcript bytes are fixture-seeded.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_generations WHERE normalized_messages_json IS NOT NULL"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_source_registry"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_epoch_history"), 1)
        }
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try database.close()
        seedDatabase = nil
        guard chmod(hqDatabase.path, 0o600) == 0 else { throw BinaryShadowFailure.fixture }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hqRole.root.appendingPathComponent("capture-ingest").path))
    }

    func startHQ() throws {
        guard seedDatabase == nil, !hqStarted else { throw BinaryShadowFailure.fixture }
        let settings = hqRole.root.appendingPathComponent("settings.json")
        let credentials = hqRole.root.appendingPathComponent("capture-credentials.json")
        let aiSecrets = hqRole.root.appendingPathComponent("empty-ai-secrets.json")
        let allSources = EngramCoreRead.SourceName.allCases.map(\.rawValue)
        try writeJSON(["runtimeRole": "index", "disabledSources": allSources.filter { $0 != "codex" },
            "archivedDefaultOffSourcesMigrated": true, "aiProtocol": "disabled", "titleProvider": "native",
            "remoteOffloadEnabled": false, "livePublishEnabled": false, "liveIngestEnabled": false,
            "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": replicas[0].baseURL.absoluteString,
                "credentialID": "hq", "pageLimit": 10, "maxPages": 2, "requestTimeout": 0.5, "retryCount": 0]], to: settings)
        try writeJSON(["hq": replicas[0].token], to: credentials)
        try writeJSON([:], to: aiSecrets)
        _ = try launch(binaries.service, role: hqRole,
            arguments: ["--expected-home", hqRole.home.path, "--capture-credentials-file", credentials.path,
                "--database-path", hqDatabase.path, "--service-socket", socket],
            environment: ["ENGRAM_SETTINGS_PATH": settings.path, "ENGRAM_RUNTIME_AI_SECRETS_PATH": aiSecrets.path,
                "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false", "ENGRAM_LIVE_PUBLISH_ENABLED": "false",
                "ENGRAM_LIVE_INGEST_ENABLED": "false", "ENGRAM_DISABLED_SOURCES": allSources.joined(separator: ","),
                "ENGRAM_USAGE_TOKEN_LIMITS": "{}"])
        hqStarted = true
    }

    struct WebRead {
        let sessionID: String
        let generation: String
        let messages: [EngramServiceWebNormalizedMessage]
    }

    func awaitWebIPC(_ publication: ShadowPublication, query: String, expectedGenerations: Int? = nil) async throws -> WebRead {
        let client = try EngramServiceWebReadClient(socketPath: socket, totalTimeout: 0.5)
        let request = try EngramServiceWebSessionsRequest(query: query, source: "codex",
            machineId: publication.machineID, sourceInstanceId: publication.sourceInstanceID)
        let digest = try publication.sha256()
        while true {
            try checkRunning()
            if let sessions = try? await client.sessions(request), let session = sessions.items.first,
               let response = try? await client.sessionDetail(EngramServiceWebSessionDetailRequest(sessionId: session.sessionId)),
               let detail = response.detail, detail.transcriptAvailability == .available,
               detail.lastReady?.publicationSHA256 == digest, let generation = detail.transcriptGeneration {
                XCTAssertEqual(sessions.items.count, 1)
                XCTAssertNil(sessions.nextCursor)
                XCTAssertEqual(detail.lastReady?.sequence, String(publication.sequence))
                XCTAssertEqual(detail.lastReady?.collectorEpoch, publication.collectorEpoch)
                try assertHQContainsOnlyBinaryProducedRows(expectedGenerations: expectedGenerations ?? Int(publication.sequence))
                let overview = try await client.overview(EngramServiceWebOverviewRequest())
                XCTAssertEqual(overview.capabilities.keywordSearch, .available)
                XCTAssertEqual(overview.capabilities.transcriptRead, .available)
                XCTAssertEqual(overview.streams.count, 1)
                XCTAssertEqual(overview.streams.first?.machineId, publication.machineID)
                XCTAssertEqual(overview.streams.first?.sourceInstanceId, publication.sourceInstanceID)
                let page = try await client.messages(EngramServiceWebMessagesRequest(sessionId: session.sessionId, generation: generation))
                XCTAssertTrue(page.isComplete)
                let messages = try page.fragments.enumerated().map { index, fragment in
                    XCTAssertEqual(fragment.messageOrdinal, index)
                    XCTAssertEqual(fragment.utf8Offset, 0)
                    XCTAssertTrue(fragment.isLastFragment, "these short messages must each fit in one fragment")
                    let bytes = Data(fragment.payloadFragment.utf8)
                    XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), fragment.payloadSHA256)
                    let value = try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: bytes)
                    XCTAssertEqual(value.role, fragment.role)
                    return value
                }
                return WebRead(sessionID: session.sessionId, generation: generation, messages: messages)
            }
            try await pause()
        }
    }

    func assertMessages(_ messages: [EngramServiceWebNormalizedMessage], secondGeneration: Bool) throws {
        XCTAssertEqual(messages.map(\.content), secondGeneration ? [Self.firstText, Self.firstReplyText, Self.secondText] : [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(messages.map(\.role), secondGeneration ? [.user, .assistant, .assistant] : [.user, .assistant])
        let timestamps = secondGeneration ? [Self.firstTimestamp, Self.firstReplyTimestamp, Self.secondTimestamp] : [Self.firstTimestamp, Self.firstReplyTimestamp]
        let formatter = ISO8601DateFormatter()
        for (message, expected) in zip(messages, timestamps) {
            XCTAssertEqual(formatter.date(from: try XCTUnwrap(message.timestamp)), formatter.date(from: expected))
            XCTAssertNil(message.usage, "absent source usage must not be invented")
        }
    }

    func appendSecondMessage(to first: Data) throws -> Data {
        XCTAssertEqual(try Data(contentsOf: source), first)
        var append = try JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": Self.secondTimestamp,
            "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": Self.secondText]]]], options: [.sortedKeys])
        append.append(10)
        let handle = try FileHandle(forWritingTo: source)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        XCTAssertEqual(try Data(contentsOf: source), first + append)
        return first + append
    }

    func assertHQContainsOnlyBinaryProducedRows(expectedGenerations: Int = 2) throws {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        do {
            try database.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE source = 'codex'"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE tier = 'normal'"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_publications"), expectedGenerations)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_generations"), expectedGenerations)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_source_registry"), 1)
            }
            try database.close()
        } catch { try? database.close(); throw error }
    }

    func assertCollectorHasNoProductIndex() throws {
        // The HQ role deliberately owns index.sqlite; never scan its sibling
        // tree or open arbitrary live databases to prove Collector isolation.
        for root in [fixture.shadow, fixture.identity.deletingLastPathComponent(), collectorRole.root] {
            let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            XCTAssertFalse(paths.contains { $0.hasSuffix("index.sqlite") || $0.hasSuffix("settings.local.json") }, root.path)
        }
        XCTAssertEqual(try fixture.integer("SELECT count(*) FROM sqlite_master WHERE name IN ('sessions', 'messages', 'session_fts', 'sessions_fts', 'embeddings')"), 0)
    }

    private func checkRunning() throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw BinaryShadowFailure.deadline }
        for child in children { try child.requireRunning() }
    }

    private func pause() async throws { try checkRunning(); try await Task.sleep(for: .milliseconds(25)) }

    private func page(_ replica: ShadowReplica) async throws -> ShadowPage {
        try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowPage.self,
            from: await fetch(replica, path: "v2/archive/publications"))
    }

    private func fetch(_ replica: ShadowReplica, path: String) async throws -> Data {
        try checkRunning()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: replica.baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(replica.token)", forHTTPHeaderField: "Authorization")
        let (stream, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BinaryShadowFailure.replica }
        var data = Data()
        for try await byte in stream {
            guard data.count < 1_048_576 else { throw BinaryShadowFailure.payloadLimit }
            data.append(byte)
        }
        return data
    }

    func close(retainFixture: Bool) async throws {
        var failed = false
        for child in children.reversed() {
            do { try await child.stopAndJoin() } catch { failed = true }
        }
        guard !failed else { throw BinaryShadowFailure.cleanup }
        for reservation in reservations { try reservation.close() }
        if let database = seedDatabase { try database.close(); seedDatabase = nil }
        guard !retainFixture else { return }
        try FileManager.default.removeItem(at: socketRoot)
        fixture.remove()
        guard !FileManager.default.fileExists(atPath: fixture.base.path) else { throw BinaryShadowFailure.cleanup }
    }
}

/// Test-owned loopback port reservation only; never accepts or responds to HTTP.
private final class ShadowPortReservation {
    let port: UInt16
    private var descriptor: Int32

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw BinaryShadowFailure.fixture }
        var ready = false
        defer { if !ready { _ = Darwin.close(socket) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw BinaryShadowFailure.fixture }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) }
        }
        guard bound == 0, named == 0, address.sin_port != 0 else { throw BinaryShadowFailure.fixture }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = socket
        ready = true
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let owned = descriptor
        descriptor = -1
        guard Darwin.close(owned) == 0 else { throw BinaryShadowFailure.cleanup }
    }
}

extension CollectorBinaryShadowIntegrationTests {
    /// Explicitly opted-in live fixture for an independently verified browser.
    /// A successful hold proves setup and cleanup, not browser acceptance.
    func testRealBinaryHTTPSBrowserDemoWithBoundedHold() async throws {
        let browser = try ShadowBrowserLaunch.explicitEnvironment()
        let binaries = try ShadowBinaries.explicitEnvironment()
        executionTimeAllowance = TimeInterval(browser.holdSeconds + 60)
        let scope = try BinaryShadowScope(binaries: binaries)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstBytes = try scope.writeInitialSource()
            try scope.startCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)
            try scope.provisionHQ(firstPublication)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertMessages(firstRead.messages, secondGeneration: false)

            let secondBytes = try scope.appendSecondMessage(to: firstBytes)
            let second = try await scope.awaitDualPublications(count: 2)
            let secondPublication = second[1]
            XCTAssertEqual(second[0], firstPublication)
            XCTAssertEqual(secondPublication.sequence, 2)
            XCTAssertEqual(secondPublication.machineID, firstPublication.machineID)
            XCTAssertEqual(secondPublication.sourceInstanceID, firstPublication.sourceInstanceID)
            XCTAssertEqual(secondPublication.collectorEpoch, firstPublication.collectorEpoch)
            XCTAssertNotEqual(secondPublication.manifestSHA256, firstPublication.manifestSHA256)
            try await scope.assertReplicaBytes(secondPublication, expected: secondBytes)
            let secondRead = try await scope.awaitWebIPC(secondPublication, query: BinaryShadowScope.secondText)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            try scope.assertMessages(secondRead.messages, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
            guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
            try await scope.holdForBrowser(browser, read: secondRead, publication: secondPublication)
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.closeBrowser(browser, retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary browser cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_BROWSER_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }
}

private enum ShadowBrowserFailure: Error {
    case configuration, helperFailed, invalidReady, invalidStop, childExited, setupFailed
}

private final class ShadowBrowserLaunch: @unchecked Sendable {
    let node: URL
    let helper: URL
    let holdSeconds: Int
    var context: ShadowBrowserContext?
    var tlsChild: CLIIntegrationChild?
    var certificateChildren: [CLIIntegrationChild] = []

    private init(node: URL, helper: URL, holdSeconds: Int) {
        self.node = node
        self.helper = helper
        self.holdSeconds = holdSeconds
    }

    static func explicitEnvironment() throws -> ShadowBrowserLaunch {
        let environment = ProcessInfo.processInfo.environment
        guard let nodePath = environment["ENGRAM_SHADOW_NODE_BINARY"],
              let holdText = environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] else {
            throw XCTSkip("Browser demo requires explicit Node and hold seconds; no fixture was created")
        }
        guard nodePath.hasPrefix("/"), !nodePath.utf8.contains(0),
              FileManager.default.isExecutableFile(atPath: nodePath),
              let hold = Int(holdText), (1...300).contains(hold), String(hold) == holdText,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw ShadowBrowserFailure.configuration
        }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = checkout.appendingPathComponent("scripts/collector-shadow-tls.mjs")
        var status = stat()
        guard lstat(helper.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw ShadowBrowserFailure.configuration
        }
        return ShadowBrowserLaunch(node: URL(fileURLWithPath: nodePath), helper: helper, holdSeconds: hold)
    }

    /// TLS admission stops before the product roles. Even a failed certificate
    /// helper remains tracked until its preinstalled termination callback joins.
    func stopOwnedHelpers() async throws {
        var failed = false
        if let tlsChild {
            do { try await tlsChild.stopAndJoin() } catch { failed = true }
        }
        for child in certificateChildren.reversed() {
            do { try await child.stopAndJoin() } catch { failed = true }
        }
        if failed { throw BinaryShadowFailure.cleanup }
    }

    static func readPrivate(_ path: URL, maximumBytes: Int, allowMissing: Bool = false) throws -> Data? {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, allowMissing, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ShadowBrowserFailure.configuration }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o600,
              status.st_size >= 0, status.st_size <= maximumBytes else {
            throw ShadowBrowserFailure.configuration
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0, count <= maximumBytes else { throw ShadowBrowserFailure.configuration }
        return Data(bytes.prefix(count))
    }
}

private struct ShadowBrowserContext {
    let origin: String
    let viewerCredential: String
    let viewerCredentialFile: URL
    let readyFile: URL
    let stopFile: URL
    let runID: String
}

private struct ShadowBrowserReady: Encodable {
    let schemaVersion = 1
    let runID: String
    let webURL: String
    let viewerCredentialFile: String
    let stopFile: String
    let expiresAt: String
    let sessionID: String
    let generation: String
    let machineID: String
    let sourceInstanceID: String
    let publicationSHA256: String
    let expectedMessages: [EngramServiceWebNormalizedMessage]
}

private extension BinaryShadowScope {
    func prepareBrowserTLS(_ browser: ShadowBrowserLaunch, upstreamPort: UInt16) async throws {
        guard browser.context == nil, browser.tlsChild == nil else { throw ShadowBrowserFailure.configuration }
        let tlsRole = try ShadowRole(parent: fixture.base, name: "browser-tls-process")
        let key = tlsRole.home.appendingPathComponent("key.pem")
        let cert = tlsRole.home.appendingPathComponent("cert.pem")
        let config = tlsRole.home.appendingPathComponent("openssl.cnf")
        try writePrivate(Data("""
            [req]
            distinguished_name = dn
            prompt = no
            [dn]
            CN = 127.0.0.1
            [v3_req]
            subjectAltName = IP:127.0.0.1
            basicConstraints = critical,CA:FALSE
            keyUsage = critical,digitalSignature,keyEncipherment
            extendedKeyUsage = serverAuth

            """.utf8), to: config)
        try await runBrowserOpenSSL(browser, name: "key", arguments: ["genrsa", "-out", key.path, "2048"])
        guard chmod(key.path, 0o600) == 0 else { throw ShadowBrowserFailure.configuration }
        try await runBrowserOpenSSL(browser, name: "cert", arguments: ["req", "-new", "-x509", "-key", key.path,
            "-out", cert.path, "-days", "1", "-subj", "/CN=127.0.0.1", "-config", config.path, "-extensions", "v3_req"])
        guard chmod(cert.path, 0o600) == 0 else { throw ShadowBrowserFailure.configuration }
        _ = try ShadowBrowserLaunch.readPrivate(key, maximumBytes: 65_536)
        _ = try ShadowBrowserLaunch.readPrivate(cert, maximumBytes: 65_536)
        let child = try launch(browser.node, role: tlsRole, arguments: [browser.helper.path,
            "--cert", cert.path, "--key", key.path,
            "--upstream", "http://127.0.0.1:\(upstreamPort)", "--port", "0"])
        browser.tlsChild = child
        struct TLSReady: Decodable { let actualPort: Int }
        let stdout = tlsRole.root.appendingPathComponent("cli.stdout")
        while true {
            try checkRunning()
            let bytes = try XCTUnwrap(ShadowBrowserLaunch.readPrivate(stdout, maximumBytes: 4096))
            if bytes.last == 10 {
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(object.keys) == ["actualPort"] else { throw ShadowBrowserFailure.invalidReady }
                let ready = try JSONDecoder().decode(TLSReady.self, from: bytes)
                guard (1...65535).contains(ready.actualPort) else { throw ShadowBrowserFailure.invalidReady }
                let viewer = "synthetic-browser-viewer-\(UUID().uuidString)"
                let credentialFile = tlsRole.home.appendingPathComponent("viewer-credential.json")
                try writeJSON(["credential": viewer], to: credentialFile)
                browser.context = ShadowBrowserContext(origin: "https://127.0.0.1:\(ready.actualPort)",
                    viewerCredential: viewer, viewerCredentialFile: credentialFile,
                    readyFile: tlsRole.home.appendingPathComponent("ready.json"),
                    stopFile: tlsRole.home.appendingPathComponent("browser-stop.json"), runID: UUID().uuidString)
                return
            }
            try await pause()
        }
    }

    func runBrowserOpenSSL(_ browser: ShadowBrowserLaunch, name: String, arguments: [String]) async throws {
        try checkRunning()
        let role = try ShadowRole(parent: fixture.base, name: "browser-openssl-\(name)-process")
        let child = try CLIIntegrationChild(binary: URL(fileURLWithPath: "/usr/bin/openssl"), arguments: arguments,
            root: role.root, home: role.home, temporary: role.temporary)
        browser.certificateChildren.append(child)
        let result = try await child.waitForExit(seconds: 5)
        guard result.reason == .exit, result.status == 0 else { throw ShadowBrowserFailure.helperFailed }
        try await child.stopAndJoin()
        try checkRunning()
    }

    func holdForBrowser(_ browser: ShadowBrowserLaunch, read: WebRead, publication: ShadowPublication) async throws {
        let web = try XCTUnwrap(browser.context)
        let clock = ContinuousClock()
        let until = clock.now.advanced(by: .seconds(browser.holdSeconds))
        let ready = ShadowBrowserReady(runID: web.runID, webURL: web.origin + "/web/",
            viewerCredentialFile: web.viewerCredentialFile.path, stopFile: web.stopFile.path,
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(browser.holdSeconds))),
            sessionID: read.sessionID, generation: read.generation, machineID: publication.machineID,
            sourceInstanceID: publication.sourceInstanceID, publicationSHA256: try publication.sha256(),
            expectedMessages: read.messages)
        try writePrivate(JSONEncoder().encode(ready), to: web.readyFile)
        print("BINARY_SHADOW_BROWSER_READY readyFile=\(web.readyFile.path)")
        while clock.now < until {
            try Task.checkCancellation()
            // Setup still uses the original 25s/30s gates. Only this explicit
            // demo hold has its own bounded clock; no production polling changes.
            guard children.allSatisfy({ $0.isRunning }) else { throw ShadowBrowserFailure.childExited }
            if let bytes = try ShadowBrowserLaunch.readPrivate(web.stopFile, maximumBytes: 1024, allowMissing: true) {
                guard let request = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                      request.count == 1, request["runID"] == web.runID else { throw ShadowBrowserFailure.invalidStop }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func closeBrowser(_ browser: ShadowBrowserLaunch, retainFixture: Bool) async throws {
        var failed = false
        do { try await browser.stopOwnedHelpers() } catch { failed = true }
        // A helper join failure also forbids deletion, even if every product
        // role later joins successfully. Always attempt all role joins.
        do { try await close(retainFixture: retainFixture || failed) } catch { failed = true }
        if failed { throw BinaryShadowFailure.cleanup }
    }
}

private struct ShadowLaunchRecord {
    let binary: URL
    let role: ShadowRole
    let arguments: [String]
    let environment: [String: String]
}

extension CollectorBinaryShadowIntegrationTests {
    func testRealBinaryRenamePreservesNativeIdentityAndPositiveUsageAcrossThreeGenerations() async throws {
        try await runRecoveryCase { scope, limit in try await scope.renameWithUsage(limit: limit) }
    }

    func testRealBinaryCollectorCrashRecoversPendingM1WithoutRepublishingHQ() async throws {
        try await runRecoveryCase { scope, limit in try await scope.collectorPendingRecovery(limit: limit) }
    }

    func testRealBinaryHQCrashAfterDurableReadyResumesNextGeneration() async throws {
        try await runRecoveryCase { scope, limit in try await scope.hqReadyRecovery(limit: limit) }
    }

    private func runRecoveryCase(_ body: (BinaryShadowScope, ShadowRecoveryLimit) async throws -> Void) async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        executionTimeAllowance = 60
        let limit = ShadowRecoveryLimit()
        let scope = try BinaryShadowScope(binaries: binaries)
        var bodyFailure: Error?
        do {
            try limit.check()
            try await body(scope, limit)
            try limit.check()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary recovery cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain { print("BINARY_RECOVERY_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }
}

private struct ShadowRecoveryLimit {
    private let deadline = ContinuousClock.now.advanced(by: .seconds(25))
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw BinaryShadowFailure.deadline }
    }
}

private struct ShadowReadySnapshot: Equatable {
    let normalized: Data
    let ftsContent: [String]
    let checkpoint: String
}

private extension BinaryShadowScope {
    func activeChild(for role: ShadowRole) throws -> CLIIntegrationChild {
        let matches = children.filter { launchRecords[ObjectIdentifier($0)]?.role.root == role.root }
        guard matches.count == 1, let child = matches.first else { throw BinaryShadowFailure.fixture }
        return child
    }

    func retireJoined(_ child: CLIIntegrationChild) throws {
        guard !child.isRunning, children.contains(where: { $0 === child }) else { throw BinaryShadowFailure.cleanup }
        children.removeAll { $0 === child }
        joinedChildren.append(child)
    }

    func stopOwned(_ child: CLIIntegrationChild) async throws {
        try checkRunning()
        try await child.stopAndJoin()
        try retireJoined(child)
    }

    func crashOwned(_ child: CLIIntegrationChild) async throws {
        try checkRunning()
        let result = try await child.crashAndJoin()
        XCTAssertEqual(result.reason, .uncaughtSignal)
        XCTAssertEqual(result.status, SIGKILL)
        try retireJoined(child)
    }

    @discardableResult
    func restartOwned(_ previous: CLIIntegrationChild) throws -> CLIIntegrationChild {
        try checkRunning()
        guard joinedChildren.contains(where: { $0 === previous }), !previous.isRunning,
              let record = launchRecords[ObjectIdentifier(previous)],
              !children.contains(where: { launchRecords[ObjectIdentifier($0)]?.role.root == record.role.root }) else {
            throw BinaryShadowFailure.fixture
        }
        let logs = record.role.root.appendingPathComponent("restart-\(UUID().uuidString)")
        try Self.directory(logs)
        // Restart the identical executable/config/HOME/store, with new log
        // files only. Never reconstruct catalog, CAS, ledger or source state.
        let child = try CLIIntegrationChild(binary: record.binary, arguments: record.arguments, root: logs,
            home: record.role.home, temporary: record.role.temporary, roleEnvironment: record.environment)
        children.append(child)
        launchRecords[ObjectIdentifier(child)] = record
        for index in replicas.indices where replicas[index].child === previous {
            let replica = replicas[index]
            replicas[index] = ShadowReplica(id: replica.id, baseURL: replica.baseURL, token: replica.token, child: child)
        }
        return child
    }

    func assertSuccessor(_ next: ShadowPublication, of previous: ShadowPublication) {
        XCTAssertEqual(next.machineID, previous.machineID)
        XCTAssertEqual(next.sourceInstanceID, previous.sourceInstanceID)
        XCTAssertEqual(next.collectorEpoch, previous.collectorEpoch)
        // Abandoned capture reservations can leave legitimate sequence gaps.
        XCTAssertGreaterThan(next.sequence, previous.sequence)
        XCTAssertNotEqual(next.manifestSHA256, previous.manifestSHA256)
    }

    func appendRecords(_ records: [[String: Any]], to target: URL, prefix: Data) throws -> Data {
        guard target.deletingLastPathComponent().path.utf8.elementsEqual(fixture.sources.path.utf8) else { throw BinaryShadowFailure.fixture }
        XCTAssertEqual(try Data(contentsOf: target), prefix)
        var append = Data()
        for record in records {
            append.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            append.append(10)
        }
        let handle = try FileHandle(forWritingTo: target)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        XCTAssertEqual(try Data(contentsOf: target), prefix + append)
        return prefix + append
    }

    static func usageRecord(second: Bool) -> [String: Any] {
        let last = ["input_tokens": second ? 50 : 120, "cached_input_tokens": second ? 10 : 20,
            "output_tokens": second ? 9 : 7, "reasoning_output_tokens": second ? 4 : 3,
            "total_tokens": second ? 59 : 127]
        let total = ["input_tokens": second ? 170 : 120, "cached_input_tokens": second ? 30 : 20,
            "output_tokens": second ? 16 : 7, "reasoning_output_tokens": second ? 7 : 3,
            "total_tokens": second ? 186 : 127]
        return ["type": "event_msg", "timestamp": second ? secondTimestamp : firstReplyTimestamp,
            "payload": ["type": "token_count", "info": ["last_token_usage": last, "total_token_usage": total]]]
    }

    func assertPositiveUsage(_ read: WebRead, second: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), second ? [Self.firstText, Self.firstReplyText, Self.secondText] : [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), second ? [.user, .assistant, .assistant] : [.user, .assistant])
        let timestamps = second ? [Self.firstTimestamp, Self.firstReplyTimestamp, Self.secondTimestamp] : [Self.firstTimestamp, Self.firstReplyTimestamp]
        XCTAssertEqual(read.messages.map(\.timestamp), timestamps.map { Optional($0) })
        XCTAssertNil(try XCTUnwrap(read.messages.first).usage)
        let assistants = read.messages.filter { $0.role == .assistant }
        XCTAssertEqual(try XCTUnwrap(assistants.first).usage,
            EngramServiceWebTokenUsage(inputTokens: 100, outputTokens: 7, cacheReadTokens: 20, cacheCreationTokens: 0))
        if second {
            XCTAssertEqual(try XCTUnwrap(assistants.last).usage,
                EngramServiceWebTokenUsage(inputTokens: 40, outputTokens: 9, cacheReadTokens: 10, cacheCreationTokens: 0))
        }
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = 'binary-shadow-codex'", arguments: [read.sessionID]), 1)
            let cost = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM session_costs WHERE session_id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(cost["input_tokens"] as Int, second ? 140 : 100)
            XCTAssertEqual(cost["output_tokens"] as Int, second ? 16 : 7)
            XCTAssertEqual(cost["cache_read_tokens"] as Int, second ? 30 : 20)
            XCTAssertEqual(cost["cache_creation_tokens"] as Int, 0)
        }
    }

    func renameWithUsage(limit: ShadowRecoveryLimit) async throws {
        try await startReplicas()
        let initial = try writeInitialSource()
        let firstBytes = try appendRecords([Self.usageRecord(second: false)], to: source, prefix: initial)
        try startCollector()
        let firstPublications = try await awaitDualPublications(count: 1)
        let first = try XCTUnwrap(firstPublications.first)
        try await assertReplicaBytes(first, expected: firstBytes)
        try provisionHQ(first)
        try startHQ()
        let firstRead = try await awaitWebIPC(first, query: Self.firstText, expectedGenerations: 1)
        try assertPositiveUsage(firstRead, second: false)
        try limit.check()

        var before = stat()
        guard lstat(source.path, &before) == 0 else { throw BinaryShadowFailure.fixture }
        let renamed = fixture.sources.appendingPathComponent("rollout-renamed.jsonl")
        guard !FileManager.default.fileExists(atPath: renamed.path) else { throw BinaryShadowFailure.fixture }
        try FileManager.default.moveItem(at: source, to: renamed)
        var after = stat()
        guard lstat(renamed.path, &after) == 0 else { throw BinaryShadowFailure.fixture }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(try Data(contentsOf: renamed), firstBytes)
        let renamedPublications = try await awaitDualPublications(count: 2)
        XCTAssertEqual(renamedPublications.first, first)
        let second = try XCTUnwrap(renamedPublications.last)
        assertSuccessor(second, of: first)
        try await assertReplicaBytes(second, expected: firstBytes)
        let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self,
            from: await fetch(replicas[0], path: "v2/archive/manifests/\(second.manifestSHA256)"))
        XCTAssertEqual(manifest.locator, renamed.path)
        let renamedRead = try await awaitWebIPC(second, query: Self.firstText, expectedGenerations: 2)
        XCTAssertEqual(renamedRead.sessionID, firstRead.sessionID)
        XCTAssertNotEqual(renamedRead.generation, firstRead.generation)
        XCTAssertEqual(renamedRead.messages, firstRead.messages)
        try assertPositiveUsage(renamedRead, second: false)
        try limit.check()

        let thirdBytes = try appendRecords([
            ["type": "response_item", "timestamp": Self.secondTimestamp,
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": Self.secondText]]]],
            Self.usageRecord(second: true),
        ], to: renamed, prefix: firstBytes)
        let all = try await awaitDualPublications(count: 3)
        XCTAssertEqual(Array(all.prefix(2)), renamedPublications)
        let third = try XCTUnwrap(all.last)
        assertSuccessor(third, of: second)
        try await assertReplicaBytes(third, expected: thirdBytes)
        let thirdRead = try await awaitWebIPC(third, query: Self.secondText, expectedGenerations: 3)
        XCTAssertEqual(thirdRead.sessionID, firstRead.sessionID)
        XCTAssertNotEqual(thirdRead.generation, renamedRead.generation)
        XCTAssertEqual(Array(thirdRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
        try assertPositiveUsage(thirdRead, second: true)
        try assertHQContainsOnlyBinaryProducedRows(expectedGenerations: 3)
    }

    struct PendingReplicaEvidence {
        let publications: [ShadowPublication]
        let canonicalBytes: Data
        let hqPage: ShadowPage
        let hqACKBytes: Data
        let m1State: String
        let m1Attempts: Int
        let m1RetryNotBefore: Int64?
    }

    func awaitPendingM1(limit: ShadowRecoveryLimit) async throws -> PendingReplicaEvidence {
        while true {
            try limit.check()
            try checkRunning()
            let publications = try fixture.publications()
            if publications.count == 2, let next = publications.last {
                let digest = try next.sha256()
                let hqPage = try await page(replicas[0])
                if hqPage.items.map(\.publication) == publications {
                    let pending: (Data, Data, String, Int, Int64?)? = try readInventory { db in
                        let rows = try Row.fetchAll(db, sql: "SELECT replica_id, state, ack_bytes, attempts, retry_not_before FROM collector_publication_replicas WHERE publication_digest = ?", arguments: [digest])
                        guard rows.count == 2,
                              let hq = rows.first(where: { ($0["replica_id"] as String) == "hq" }),
                              let m1 = rows.first(where: { ($0["replica_id"] as String) == "m1" }),
                              (hq["state"] as String) == "acknowledged",
                              ["pending", "inflight"].contains(m1["state"] as String),
                              let ack: Data = hq["ack_bytes"] else { return nil }
                        XCTAssertNil(m1["ack_bytes"] as Data?)
                        XCTAssertGreaterThanOrEqual(m1["attempts"] as Int, 0)
                        let bytes = try XCTUnwrap(Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications WHERE publication_digest = ?", arguments: [digest]))
                        return (bytes, ack, m1["state"], m1["attempts"], m1["retry_not_before"])
                    }
                    if let pending {
                        return PendingReplicaEvidence(publications: publications, canonicalBytes: pending.0,
                            hqPage: hqPage, hqACKBytes: pending.1, m1State: pending.2,
                            m1Attempts: pending.3, m1RetryNotBefore: pending.4)
                    }
                }
            }
            try await pause()
        }
    }

    func collectorPendingRecovery(limit: ShadowRecoveryLimit) async throws {
        try await startReplicas()
        let firstBytes = try writeInitialSource()
        try startCollector()
        let firstPublications = try await awaitDualPublications(count: 1)
        let first = try XCTUnwrap(firstPublications.first)
        try await assertReplicaBytes(first, expected: firstBytes)
        try provisionHQ(first)
        try startHQ()
        let firstRead = try await awaitWebIPC(first, query: Self.firstText, expectedGenerations: 1)
        try assertMessages(firstRead.messages, secondGeneration: false)
        let m1Before = try await page(replicas[1])
        let m1 = replicas[1].child
        try await stopOwned(m1)
        let secondBytes = try appendSecondMessage(to: firstBytes)
        let pending = try await awaitPendingM1(limit: limit)
        XCTAssertTrue(["pending", "inflight"].contains(pending.m1State))
        XCTAssertGreaterThanOrEqual(pending.m1Attempts, 0)
        if let retry = pending.m1RetryNotBefore { XCTAssertGreaterThan(retry, 0) }
        let second = try XCTUnwrap(pending.publications.last)
        assertSuccessor(second, of: first)
        XCTAssertEqual(pending.publications.first, first)
        let collector = try activeChild(for: collectorRole)
        // This is an actual unclean exit with a durable pending replica row;
        // it does not claim a mid-ACK-transaction or pre-intent crash boundary.
        try await crashOwned(collector)
        XCTAssertEqual(try fixture.publications(), pending.publications)
        try assertPendingBytesUnchanged(pending, publication: second)
        try restartOwned(m1)
        try await awaitReplicaRestartReady(replicas[1], expected: m1Before, limit: limit)
        try restartOwned(collector)
        let recovered = try await awaitDualPublications(count: 2)
        XCTAssertEqual(recovered, pending.publications)
        let hqAfter = try await page(replicas[0])
        XCTAssertEqual(hqAfter, pending.hqPage)
        let m1After = try await page(replicas[1])
        XCTAssertEqual(try EngramCollectorCore.CollectorPublicationCursor.decode(m1After.afterCursor).journalID,
            try EngramCollectorCore.CollectorPublicationCursor.decode(m1Before.afterCursor).journalID)
        XCTAssertEqual(m1After.items.first, m1Before.items.first)
        try assertPendingBytesUnchanged(pending, publication: second)
        try await assertReplicaBytes(second, expected: secondBytes)
        let secondRead = try await awaitWebIPC(second, query: Self.secondText, expectedGenerations: 2)
        XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
        XCTAssertNotEqual(secondRead.generation, firstRead.generation)
        XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
        try assertMessages(secondRead.messages, secondGeneration: true)
    }

    func awaitReplicaRestartReady(_ replica: ShadowReplica, expected: ShadowPage, limit: ShadowRecoveryLimit) async throws {
        while true {
            try limit.check()
            do {
                let current = try await page(replica)
                guard current == expected else { throw BinaryShadowFailure.replica }
                return
            } catch let error as URLError where error.code == .cannotConnectToHost {
                // Only the fresh owned listener's startup gap is retryable;
                // authentication, journal, payload and other errors fail closed.
                try await pause()
            }
        }
    }

    func assertPendingBytesUnchanged(_ evidence: PendingReplicaEvidence, publication: ShadowPublication) throws {
        let digest = try publication.sha256()
        try readInventory { db in
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT canonical_bytes FROM collector_publications WHERE publication_digest = ?", arguments: [digest]), evidence.canonicalBytes)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT ack_bytes FROM collector_publication_replicas WHERE publication_digest = ? AND replica_id = 'hq'", arguments: [digest]), evidence.hqACKBytes)
        }
    }

    func hqReadyRecovery(limit: ShadowRecoveryLimit) async throws {
        try await startReplicas()
        let firstBytes = try writeInitialSource()
        try startCollector()
        let firstPublications = try await awaitDualPublications(count: 1)
        let first = try XCTUnwrap(firstPublications.first)
        try await assertReplicaBytes(first, expected: firstBytes)
        try provisionHQ(first)
        try startHQ()
        let firstRead = try await awaitWebIPC(first, query: Self.firstText, expectedGenerations: 1)
        try assertMessages(firstRead.messages, secondGeneration: false)
        let before = try durableReadySnapshot(first, read: firstRead, expectedGenerations: 1)
        let hq = try activeChild(for: hqRole)
        // Post-ready process recovery, not a claim of arbitrary transaction
        // interruption: the exact FTS/ledger/ready tuple is durable first.
        try await crashOwned(hq)
        let secondBytes = try appendSecondMessage(to: firstBytes)
        let all = try await awaitDualPublications(count: 2)
        XCTAssertEqual(all.first, first)
        let second = try XCTUnwrap(all.last)
        assertSuccessor(second, of: first)
        try await assertReplicaBytes(second, expected: secondBytes)
        XCTAssertEqual(try durableReadySnapshot(first, read: firstRead, expectedGenerations: 1), before)
        try limit.check()
        try restartOwned(hq)
        let secondRead = try await awaitWebIPC(second, query: Self.secondText, expectedGenerations: 2)
        XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
        XCTAssertNotEqual(secondRead.generation, firstRead.generation)
        XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
        try assertMessages(secondRead.messages, secondGeneration: true)
        _ = try durableReadySnapshot(second, read: secondRead, expectedGenerations: 2)
    }

    func durableReadySnapshot(_ publication: ShadowPublication, read: WebRead, expectedGenerations: Int) throws -> ShadowReadySnapshot {
        try assertHQContainsOnlyBinaryProducedRows(expectedGenerations: expectedGenerations)
        let digest = try publication.sha256()
        return try readHQ { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT g.normalized_messages_json, g.normalized_messages_sha256, g.native_id,
                    g.sync_version, g.required_fts_job_id, l.status AS ledger_status,
                    i.last_ready_generation_id, i.last_parsed_generation_id,
                    j.status AS job_status, j.job_kind, j.target_sync_version
                FROM capture_ingest_generations g
                JOIN capture_ingest_ledger l ON l.publication_sha256 = g.publication_sha256 AND l.parser_revision = g.parser_revision
                JOIN capture_ingest_identity_bindings i ON i.stored_session_id = g.stored_session_id
                JOIN session_index_jobs j ON j.id = g.required_fts_job_id AND j.session_id = g.stored_session_id
                WHERE g.generation_id = ? AND g.publication_sha256 = ? AND g.stored_session_id = ?
                """, arguments: [read.generation, digest, read.sessionID]))
            XCTAssertEqual(row["native_id"] as String, "binary-shadow-codex")
            XCTAssertEqual(row["ledger_status"] as String, "index_ready")
            XCTAssertEqual(row["last_ready_generation_id"] as String, read.generation)
            XCTAssertEqual(row["last_parsed_generation_id"] as String, read.generation)
            XCTAssertNotNil(row["required_fts_job_id"] as String?)
            XCTAssertEqual(row["job_status"] as String, "completed")
            XCTAssertEqual(row["job_kind"] as String, "fts")
            XCTAssertEqual(row["target_sync_version"] as Int, row["sync_version"] as Int)
            let normalized: Data = row["normalized_messages_json"]
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(normalized), row["normalized_messages_sha256"] as String)
            let fts = try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ? ORDER BY rowid", arguments: [read.sessionID])
            XCTAssertFalse(fts.isEmpty)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_arrivals WHERE server_id = 'hq'"), expectedGenerations)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_checkpoints"), 1)
            let cursor = try XCTUnwrap(String.fetchOne(db, sql: "SELECT cursor FROM capture_ingest_checkpoints WHERE server_id = 'hq'"))
            let decoded = try EngramCollectorCore.CollectorPublicationCursor.decode(cursor)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_arrivals WHERE server_id = 'hq' AND journal_id = ? AND arrival_ordinal = ? AND publication_sha256 = ?", arguments: [decoded.journalID, decoded.afterArrivalOrdinal, digest]), 1)
            return ShadowReadySnapshot(normalized: normalized, ftsContent: fts, checkpoint: cursor)
        }
    }

    func readHQ<T>(_ body: (Database) throws -> T) throws -> T { try readDatabase(hqDatabase, body) }
    func readInventory<T>(_ body: (Database) throws -> T) throws -> T { try readDatabase(fixture.inventory, body) }

    func readDatabase<T>(_ path: URL, _ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: path.path, configuration: configuration)
        do {
            let result = try database.read(body)
            try database.close()
            return result
        } catch { try? database.close(); throw error }
    }
}
