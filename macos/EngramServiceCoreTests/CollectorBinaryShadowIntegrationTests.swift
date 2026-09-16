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

/// Synthetic Codex and Claude happy paths across real executables. This proves neither
/// HTTPS/browser acceptance nor full W6 source, crash, rename or resource gates.
/// The supplied Service must already enforce expected-home and explicit-file
/// credentials without Keychain fallback; older binaries are unsafe to use.
final class CollectorBinaryShadowIntegrationTests: XCTestCase {
    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoCodexGenerations() async throws {
        try await verifyCodexGenerations(useStartupAuthority: false)
    }

    func testRealHQProvisionsExplicitSourceAuthorityWithoutSeededDatabase() async throws {
        try await verifyCodexGenerations(useStartupAuthority: true)
    }

    func testNewMachineCLIInitializationReachesBothReplicasAndHQWithoutSeededStores() async throws {
        try await verifyCodexGenerations(useStartupAuthority: true, bootstrapIdentity: true)
    }

    func testRealCodexForkAtFilesystemRootReachesBothReplicasAndHQForTwoGenerations() async throws {
        try await verifyCodexGenerations(useStartupAuthority: true, filesystemRootFork: true)
    }

    private func verifyCodexGenerations(useStartupAuthority: Bool, bootstrapIdentity: Bool = false, filesystemRootFork: Bool = false) async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, seedStores: !bootstrapIdentity)
        var bodyFailure: Error?
        do {
            let mintedID = bootstrapIdentity ? try await scope.initializeNewMachine() : nil
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialSource(filesystemRootFork: filesystemRootFork)
            try scope.startCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            if let mintedID { XCTAssertEqual(firstPublication.machineID, mintedID) }
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)

            // Only source authority is provisioned before the HQ writer starts.
            // Intake, CAS transfer, normalization and FTS must cross binaries.
            try scope.provisionHQ(firstPublication, useStartupAuthority: useStartupAuthority)
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
            if filesystemRootFork {
                try scope.readHQ { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT native_id FROM capture_ingest_identity_bindings WHERE stored_session_id = ?", arguments: [secondRead.sessionID]), "binary-shadow-codex")
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT cwd FROM sessions WHERE id = ?", arguments: [secondRead.sessionID]), "/")
                }
            }
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
    private static let claudeNativeID = "binary-shadow-claude"
    private static let claudeModel = "claude-sonnet-4-20250514"
    let fixture: RuntimeFixture
    let socketRoot: URL
    var source: URL {
        let relative: String
        switch sourceKind {
        case .claudeCode, .minimax: relative = "synthetic-project/claude-session.jsonl"
        case .lobsterai: relative = "lobsterai-project/claude-session.jsonl"
        case .qwen: relative = "synthetic-project/chats/qwen-session.jsonl"
        case .geminiCli: relative = "native-gemini/chats/stem.json"
        case .opencode: relative = "opencode.db"
        case .copilot: relative = copilotCheckpoint ? "native-copilot/checkpoints/index.md" : "native-copilot/events.jsonl"
        case .qoder, .commandcode: relative = "synthetic-project/native-session.jsonl"
        case .iflow: relative = "synthetic-project/session-native.jsonl"
        case .vscode: relative = "ws/chatSessions/binary-shadow-vscode.jsonl"
        case .cline: relative = "binary-shadow-cline/ui_messages.json"
        case .kimi: relative = "workspace/binary-shadow-kimi/context.jsonl"
        case .cursor: relative = "projects/proj/agent-transcripts/binary-shadow-cursor/binary-shadow-cursor.jsonl"
        case .antigravity: relative = "session/.system_generated/logs/transcript.jsonl"
        case .windsurf: relative = "transcripts/session.jsonl"
        case .pi: relative = "--synthetic-project--/binary-shadow-pi.jsonl"
        case .grok: relative = "synthetic-project/binary-shadow-grok/chat_history.jsonl"
        default: relative = "rollout-one.jsonl"
        }
        return fixture.sources.appendingPathComponent(relative)
    }
    private var hqParseFormatRawValue: String {
        if [.claudeCode, .minimax, .lobsterai].contains(sourceKind) { return "claudeDefault" }
        if sourceKind == .antigravity { return "antigravityCLITranscript" }
        if sourceKind == .windsurf { return "windsurfHookTranscript" }
        return sourceKind.rawValue
    }

    private var configuredCollectorRoot: String {
        if cursorLegacy { return cursorLegacyRoot.path }
        if sourceKind == .windsurf { return fixture.sources.appendingPathComponent("transcripts").path }
        return fixture.sources.path
    }
    private let copilotCheckpoint: Bool
    private let geminiRegistryOnly: Bool
    private let cursorLegacy: Bool
    private let piLargeReply: Bool
    private let sourceKind: EngramCoreRead.SourceName
    private let binaries: ShadowBinaries
    private let collectorRole: ShadowRole
    private let hqRole: ShadowRole
    private let deadline: Date
    private var children: [CLIIntegrationChild] = []
    private var joinedChildren: [CLIIntegrationChild] = []
    private var launchRecords: [ObjectIdentifier: ShadowLaunchRecord] = [:]
    private var reservations: [ShadowPortReservation] = []
    private var replicas: [ShadowReplica] = []
    private var seedDatabase: DatabaseQueue?
    private var startupAuthorityFile: URL?
    private var openCodeDatabase: DatabaseQueue?
    private var cursorStoreDatabase: DatabaseQueue?
    private var hqStarted = false
    private var socket: String { socketRoot.appendingPathComponent("service.sock").path }
    private var hqDatabase: URL { hqRole.root.appendingPathComponent("index.sqlite") }

    init(binaries: ShadowBinaries, sourceKind: EngramCoreRead.SourceName = .codex,
         copilotCheckpoint: Bool = false, geminiRegistryOnly: Bool = false,
         cursorLegacy: Bool = false, seedStores: Bool = true, timeout: TimeInterval = 25, piLargeReply: Bool = false) throws {
        guard [.codex, .claudeCode, .minimax, .lobsterai, .qwen, .qoder, .iflow, .vscode, .cline, .commandcode, .copilot, .geminiCli, .opencode, .kimi, .cursor, .antigravity, .windsurf, .pi, .grok].contains(sourceKind) else { throw BinaryShadowFailure.fixture }
        guard !cursorLegacy || sourceKind == .cursor else { throw BinaryShadowFailure.fixture }
        self.deadline = Date().addingTimeInterval(timeout)
        self.binaries = binaries
        self.sourceKind = sourceKind
        self.piLargeReply = piLargeReply
        self.copilotCheckpoint = copilotCheckpoint
        self.geminiRegistryOnly = geminiRegistryOnly
        self.cursorLegacy = cursorLegacy
        fixture = try RuntimeFixture(seedStores: seedStores)
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
            home: role.home, temporary: role.temporary, roleEnvironment: environment,
            lifetimeTimeout: max(30, deadline.timeIntervalSinceNow))
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

    func writeInitialSource(filesystemRootFork: Bool = false) throws -> Data {
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": Self.firstTimestamp,
             "payload": ["id": "binary-shadow-codex", "cwd": fixture.project.path, "originator": "codex-cli", "timestamp": Self.firstTimestamp]],
            ["type": "response_item", "timestamp": Self.firstTimestamp,
             "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": Self.firstText]]]],
            ["type": "response_item", "timestamp": Self.firstReplyTimestamp,
             "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": Self.firstReplyText]]]],
        ]
        if filesystemRootFork {
            var payload = try XCTUnwrap(records[0]["payload"] as? [String: Any])
            payload["cwd"] = "/"
            payload["forked_from_id"] = "binary-shadow-parent"
            records[0]["payload"] = payload
            records.insert(["type": "session_meta", "timestamp": Self.firstTimestamp,
                "payload": ["id": "binary-shadow-parent", "cwd": "/", "originator": "codex-cli", "timestamp": Self.firstTimestamp]], at: 1)
        }
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func initializeNewMachine() async throws -> String {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.identity.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shadow.path))
        for (name, arguments, expected) in [
            ("identity", ["--initialize-identity", fixture.identity.path], "engram-collector: identity initialized\n"),
            ("spool", ["--settings", fixture.settings.path, "--initialize"], "engram-collector: initialized\n"),
        ] {
            if name == "spool" { try fixture.writeSettings(fixture.document()) }
            let role = try ShadowRole(parent: fixture.base, name: "bootstrap-\(name)-process")
            let child = try launch(binaries.collector, role: role, arguments: arguments)
            let result = try await child.waitForExit(seconds: 5)
            try await child.stopAndJoin()
            try retireJoined(child)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, expected)
            XCTAssertEqual(result.stderr, "")
            guard result.status == 0 else { throw BinaryShadowFailure.fixture }
        }
        let machineID = try EngramCollectorCore.CollectorMachineIdentityReader.read(from: fixture.identity)
        XCTAssertNotEqual(machineID, RuntimeFixture.machineID)
        XCTAssertEqual(try EngramCollectorCore.CollectorMachineIdentityReader.read(
            from: fixture.shadow.appendingPathComponent("archive.sqlite")), machineID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inventory.path))
        return machineID
    }

    func startCollector(maxCaptureBytes: Int? = nil) throws {
        var document = fixture.document()
        var collector = try XCTUnwrap(document["collector"] as? [String: Any])
        if [.claudeCode, .minimax, .lobsterai].contains(sourceKind) {
            collector["roots"] = [["rootID": "runtime-claude", "source": "claude-code", "parseFormat": "claudeDefault",
                "rootPath": fixture.sources.path, "revision": 1]]
        } else if sourceKind == .geminiCli {
            var binding: [String: Any] = ["rootID": "runtime-gemini", "source": sourceKind.rawValue,
                "parseFormat": sourceKind.rawValue, "rootPath": fixture.sources.path, "revision": 1]
            if geminiRegistryOnly { binding["projectRegistryPath"] = fixture.base.appendingPathComponent("projects.json").path }
            collector["roots"] = [binding]
        } else if sourceKind == .kimi {
            collector["roots"] = [["rootID": "runtime-kimi", "source": "kimi", "parseFormat": "kimi",
                "rootPath": fixture.sources.path, "revision": 1,
                "projectRegistryPath": fixture.base.appendingPathComponent("kimi.json").path]]
        } else if sourceKind == .cursor {
            if cursorLegacy {
                collector["roots"] = [["rootID": "runtime-cursor-legacy", "source": "cursor",
                    "rootPath": cursorLegacyRoot.path, "revision": 1, "cursorLegacy": true]]
            } else {
                collector["roots"] = [["rootID": "runtime-cursor", "source": "cursor", "parseFormat": "cursor",
                    "rootPath": fixture.sources.path, "revision": 1]]
            }
        } else if sourceKind == .antigravity {
            collector["roots"] = [["rootID": "runtime-antigravity", "source": "antigravity",
                "parseFormat": "antigravityCLITranscript", "rootPath": fixture.sources.path, "revision": 1]]
        } else if sourceKind == .windsurf {
            collector["roots"] = [["rootID": "runtime-windsurf", "source": "windsurf",
                "parseFormat": "windsurfHookTranscript", "rootPath": configuredCollectorRoot, "revision": 1]]
        } else if [.qwen, .qoder, .iflow, .vscode, .cline, .commandcode, .copilot, .opencode, .pi, .grok].contains(sourceKind) {
            collector["roots"] = [["rootID": "runtime-\(sourceKind.rawValue)", "source": sourceKind.rawValue, "parseFormat": sourceKind.rawValue,
                "rootPath": fixture.sources.path, "revision": 1]]
        }
        if let maxCaptureBytes {
            var budgets = try XCTUnwrap(collector["budgets"] as? [String: Any])
            budgets["maxCaptureBytes"] = maxCaptureBytes
            collector["budgets"] = budgets
        }
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

    func provisionHQ(_ publication: ShadowPublication, useStartupAuthority: Bool = false) throws {
        guard !hqStarted, seedDatabase == nil else { throw BinaryShadowFailure.fixture }
        if useStartupAuthority {
            guard !FileManager.default.fileExists(atPath: hqDatabase.path) else {
                throw BinaryShadowFailure.fixture
            }
            let file = hqRole.root.appendingPathComponent("source-authority.json")
            try writeJSON(["schemaVersion": 1, "sources": [[
                "machineID": publication.machineID, "sourceInstanceID": publication.sourceInstanceID,
                "source": sourceKind.rawValue, "parseFormat": hqParseFormatRawValue,
                "configuredRoot": configuredCollectorRoot, "initialEpoch": publication.collectorEpoch,
            ]]], to: file)
            startupAuthorityFile = file
            return
        }
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        seedDatabase = database
        let parseFormat = try XCTUnwrap(EngramCoreWrite.CaptureIngestParseFormat(rawValue: hqParseFormatRawValue))
        try database.write { db in
            try EngramCoreWrite.EngramMigrationRunner.migrate(db)
            _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db,
                machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID,
                source: sourceKind, parseFormat: parseFormat,
                configuredRoot: configuredCollectorRoot,
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
        try writeJSON(["runtimeRole": "index", "disabledSources": allSources.filter { $0 != sourceKind.rawValue },
            "archivedDefaultOffSourcesMigrated": true, "aiProtocol": "disabled", "titleProvider": "native",
            "remoteOffloadEnabled": false, "livePublishEnabled": false, "liveIngestEnabled": false,
            "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": replicas[0].baseURL.absoluteString,
                "credentialID": "hq", "pageLimit": 10, "maxPages": 2, "requestTimeout": 0.5, "retryCount": 0]], to: settings)
        try writeJSON(["hq": replicas[0].token], to: credentials)
        try writeJSON([:], to: aiSecrets)
        _ = try launch(binaries.service, role: hqRole,
            arguments: ["--expected-home", hqRole.home.path, "--capture-credentials-file", credentials.path,
                "--database-path", hqDatabase.path, "--service-socket", socket]
                + (startupAuthorityFile.map { ["--capture-source-authority-file", $0.path] } ?? []),
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
        let readStarted = ContinuousClock.now
        let client = try EngramServiceWebReadClient(socketPath: socket, totalTimeout: piLargeReply ? 2 : 0.5)
        let request = try EngramServiceWebSessionsRequest(query: query, source: sourceKind.rawValue,
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
                var cursor: String?
                var messages: [EngramServiceWebNormalizedMessage] = []
                var payload = Data()
                var pages = 0
                repeat {
                    let page = try await client.messages(EngramServiceWebMessagesRequest(
                        sessionId: session.sessionId, generation: generation, cursor: cursor))
                    pages += 1
                    XCTAssertFalse(page.fragments.isEmpty)
                    for fragment in page.fragments {
                        XCTAssertEqual(fragment.messageOrdinal, messages.count)
                        XCTAssertEqual(fragment.utf8Offset, payload.count)
                        if !piLargeReply { XCTAssertTrue(fragment.isLastFragment) }
                        payload.append(contentsOf: fragment.payloadFragment.utf8)
                        if fragment.isLastFragment {
                            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(payload), fragment.payloadSHA256)
                            let value = try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: payload)
                            XCTAssertEqual(value.role, fragment.role)
                            messages.append(value)
                            payload.removeAll(keepingCapacity: true)
                        }
                    }
                    cursor = page.nextCursor
                    if cursor == nil { XCTAssertTrue(page.isComplete) }
                    try checkRunning()
                } while cursor != nil
                XCTAssertTrue(payload.isEmpty)
                if piLargeReply {
                    XCTAssertGreaterThan(pages, 1)
                    print("PI_LARGE_WEB sequence=\(publication.sequence) messages=\(messages.count) pages=\(pages) elapsed=\(readStarted.duration(to: .now))")
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
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE source = ?",
                    arguments: [sourceKind.rawValue]), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE tier = 'normal'"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_publications"), expectedGenerations)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_generations"), expectedGenerations)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_source_registry"), 1)
            }
            try database.close()
        } catch { try? database.close(); throw error }
    }

    func awaitCursorQuiescence(expectedPublications: [ShadowPublication]) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(10))
        var stableSince: ContinuousClock.Instant?
        var previousSequence: Int64?
        while ContinuousClock.now < limit {
            try checkRunning()
            let state = try readInventory { db -> (Int64, Int, Int, Int) in
                let sequence = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT last_sequence FROM collector_streams"))
                let dirty = try XCTUnwrap(Int.fetchOne(db, sql: "SELECT count(*) FROM collector_locators WHERE dirty_revision > acknowledged_revision"))
                let reservations = try XCTUnwrap(Int.fetchOne(db, sql: "SELECT count(*) FROM collector_capture_reservations"))
                let scanning = try XCTUnwrap(Int.fetchOne(db, sql: "SELECT count(*) FROM collector_roots WHERE active_scan_id IS NOT NULL OR requested_revision > completed_revision"))
                return (sequence, dirty, reservations, scanning)
            }
            if state.1 == 0, state.2 == 0, state.3 == 0, state.0 == previousSequence {
                if let since = stableSince, since.duration(to: .now) >= .seconds(2) {
                    XCTAssertEqual(try fixture.publications(), expectedPublications)
                    print("BINARY_SHADOW_CURSOR_QUIESCENT lastSequence=\(state.0) publications=\(expectedPublications.count) stableSeconds=2")
                    return
                }
                if stableSince == nil { stableSince = .now }
            } else { stableSince = nil }
            previousSequence = state.0
            try await pause()
        }
        XCTFail("Cursor kept reserving or left dirty work after source changes stopped")
        throw BinaryShadowFailure.deadline
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
        if let database = openCodeDatabase { try database.close(); openCodeDatabase = nil }
        if let database = cursorStoreDatabase { try database.close(); cursorStoreDatabase = nil }
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

extension CollectorBinaryShadowIntegrationTests {
    /// Synthetic Claude append replay only; real host/profile roots remain unverified.
    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoClaudeGenerations() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .claudeCode)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialClaudeSource()
            try scope.startCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)
            try scope.provisionHQ(firstPublication, useStartupAuthority: true)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertClaudeMessagesAndMetadata(firstRead, secondGeneration: false)

            let secondBytes = try scope.appendClaudeReply(to: firstBytes)
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
            try scope.assertClaudeMessagesAndMetadata(secondRead, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary Claude shadow cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_CLAUDE_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }

    /// Synthetic Qwen append replay through native binaries; real host roots remain unverified.
    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoQwenGenerations() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .qwen)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialQwenSource()
            try scope.startCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)
            try scope.provisionHQ(firstPublication)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertQwenMessagesAndMetadata(firstRead, secondGeneration: false)

            let secondBytes = try scope.appendQwenReply(to: firstBytes)
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
            try scope.assertQwenMessagesAndMetadata(secondRead, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary Qwen shadow cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_QWEN_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealOpenCodeWALCommitsReachBothReplicasAndHQFTSWebIPC() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .opencode)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstSnapshot = try scope.writeOpenCodeGeneration(second: false)
            let mainBytes = try Data(contentsOf: scope.source)
            let wal = URL(fileURLWithPath: scope.source.path + "-wal")
            let firstWAL = try Data(contentsOf: wal)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            let firstManifest = try await scope.assertOpenCodeReplica(first, expected: firstSnapshot)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText)
            try scope.assertOpenCodeRead(firstRead, second: false, payloadBytes: firstSnapshot.nativePayloadByteCount)
            XCTAssertEqual(try Data(contentsOf: scope.source), mainBytes)
            XCTAssertEqual(try Data(contentsOf: wal), firstWAL)
            let secondSnapshot = try scope.writeOpenCodeGeneration(second: true)
            let secondWAL = try Data(contentsOf: wal)
            XCTAssertEqual(try Data(contentsOf: scope.source), mainBytes)
            XCTAssertNotEqual(secondWAL, firstWAL)
            let all = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(all[0], first)
            let second = all[1]
            XCTAssertEqual(second.sequence, 2)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            let secondManifest = try await scope.assertOpenCodeReplica(second, expected: secondSnapshot)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.replayLayout.sqliteSession?.walGeneration,
                secondManifest.replayLayout.sqliteSession?.walGeneration)
            XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.secondText)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            try scope.assertOpenCodeRead(secondRead, second: true, payloadBytes: secondSnapshot.nativePayloadByteCount)
            XCTAssertEqual(try Data(contentsOf: scope.source), mainBytes)
            XCTAssertEqual(try Data(contentsOf: wal), secondWAL)
            try scope.assertCollectorHasNoProductIndex()
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: secondRead, publication: second)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        if let browser {
            try await Task { try await scope.closeBrowser(browser, retainFixture: retain) }.value
        } else {
            try await Task { try await scope.close(retainFixture: retain) }.value
        }
        if retain { print("BINARY_SHADOW_OPENCODE_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealKimiShardsAndRegistryChangesReachBothReplicasAndHQFTSWebIPC() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .kimi)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            try scope.writeKimiInitial()
            let primaryBytes = try Data(contentsOf: scope.source)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            XCTAssertEqual(first.sequence, 1)
            let firstManifest = try await scope.assertKimiReplica(first, generation: 1)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText)
            try scope.assertKimiRead(firstRead, generation: 1)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            try scope.writeKimiShard()
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            let afterShard = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(afterShard[0], first)
            let second = afterShard[1]
            XCTAssertEqual(second.sequence, 2)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            let secondManifest = try await scope.assertKimiReplica(second, generation: 2)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.secondText)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            try scope.assertKimiRead(secondRead, generation: 2)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            try scope.writeKimiRegistry(secondCwd: true)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            let afterRegistry = try await scope.awaitDualPublications(count: 3)
            XCTAssertEqual(afterRegistry[0], first)
            XCTAssertEqual(afterRegistry[1], second)
            let third = afterRegistry[2]
            XCTAssertEqual(third.sequence, 3)
            XCTAssertEqual(third.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(third.collectorEpoch, first.collectorEpoch)
            let thirdManifest = try await scope.assertKimiReplica(third, generation: 3)
            XCTAssertEqual(secondManifest.generation, thirdManifest.generation)
            XCTAssertEqual(secondManifest.wholeSourceSHA256, thirdManifest.wholeSourceSHA256)
            XCTAssertEqual(secondManifest.chunks, thirdManifest.chunks)
            XCTAssertNotEqual(secondManifest.captureID, thirdManifest.captureID)
            let thirdRead = try await scope.awaitWebIPC(third, query: BinaryShadowScope.secondText)
            XCTAssertEqual(thirdRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(thirdRead.generation, secondRead.generation)
            try scope.assertKimiRead(thirdRead, generation: 3)
            XCTAssertEqual(thirdRead.messages, secondRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            try scope.assertCollectorHasNoProductIndex()
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: thirdRead, publication: third)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        if let browser {
            try await Task { try await scope.closeBrowser(browser, retainFixture: retain) }.value
        } else {
            try await Task { try await scope.close(retainFixture: retain) }.value
        }
        if retain { print("BINARY_SHADOW_KIMI_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealCursorModernChangesReachBothReplicasAndHQFTSWebIPC() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .cursor)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstMembers = try scope.writeCursorGeneration(1)
            let mainBytes = try Data(contentsOf: scope.cursorStore)
            let transcriptBytes = try Data(contentsOf: scope.source)
            let firstWAL = try Data(contentsOf: scope.cursorWAL)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            XCTAssertGreaterThan(first.sequence, 0)
            let firstManifest = try await scope.assertCursorReplica(first, generation: 1, expected: firstMembers)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText, expectedGenerations: 1)
            try scope.assertCursorRead(firstRead, generation: 1)
            XCTAssertEqual(try Data(contentsOf: scope.cursorStore), mainBytes)
            XCTAssertEqual(try Data(contentsOf: scope.source), transcriptBytes)
            XCTAssertEqual(try Data(contentsOf: scope.cursorWAL), firstWAL)

            let secondMembers = try scope.writeCursorGeneration(2)
            let secondWAL = try Data(contentsOf: scope.cursorWAL)
            XCTAssertEqual(try Data(contentsOf: scope.cursorStore), mainBytes)
            XCTAssertEqual(try Data(contentsOf: scope.source), transcriptBytes)
            XCTAssertNotEqual(secondWAL, firstWAL)
            let afterWAL = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(afterWAL[0], first)
            let second = afterWAL[1]
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertEqual(second.machineID, first.machineID)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            let secondManifest = try await scope.assertCursorReplica(second, generation: 2, expected: secondMembers)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.firstText, expectedGenerations: 2)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            XCTAssertEqual(secondRead.messages, firstRead.messages)
            try scope.assertCursorRead(secondRead, generation: 2)
            XCTAssertEqual(try Data(contentsOf: scope.cursorStore), mainBytes)
            XCTAssertEqual(try Data(contentsOf: scope.source), transcriptBytes)

            let thirdMembers = try scope.writeCursorGeneration(3)
            XCTAssertEqual(try Data(contentsOf: scope.cursorStore), mainBytes)
            XCTAssertEqual(try Data(contentsOf: scope.source), transcriptBytes)
            XCTAssertEqual(try Data(contentsOf: scope.cursorWAL), secondWAL)
            let afterMeta = try await scope.awaitDualPublications(count: 3)
            XCTAssertEqual(afterMeta[0], first)
            XCTAssertEqual(afterMeta[1], second)
            let third = afterMeta[2]
            XCTAssertGreaterThan(third.sequence, second.sequence)
            XCTAssertEqual(third.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(third.collectorEpoch, first.collectorEpoch)
            XCTAssertNotEqual(third.manifestSHA256, second.manifestSHA256)
            let thirdManifest = try await scope.assertCursorReplica(third, generation: 3, expected: thirdMembers)
            XCTAssertEqual(secondManifest.generation, thirdManifest.generation)
            XCTAssertNotEqual(secondManifest.captureID, thirdManifest.captureID)
            let thirdRead = try await scope.awaitWebIPC(third, query: BinaryShadowScope.firstText, expectedGenerations: 3)
            XCTAssertEqual(thirdRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(thirdRead.generation, secondRead.generation)
            XCTAssertEqual(thirdRead.messages, firstRead.messages)
            try scope.assertCursorRead(thirdRead, generation: 3)
            XCTAssertEqual(try Data(contentsOf: scope.source), transcriptBytes)

            let fourthMembers = try scope.writeCursorGeneration(4)
            XCTAssertEqual(try Data(contentsOf: scope.cursorStore), mainBytes)
            XCTAssertNotEqual(try Data(contentsOf: scope.source), transcriptBytes)
            let afterTranscript = try await scope.awaitDualPublications(count: 4)
            XCTAssertEqual(afterTranscript[0], first)
            XCTAssertEqual(afterTranscript[1], second)
            XCTAssertEqual(afterTranscript[2], third)
            let fourth = afterTranscript[3]
            XCTAssertGreaterThan(fourth.sequence, third.sequence)
            XCTAssertEqual(fourth.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(fourth.collectorEpoch, first.collectorEpoch)
            XCTAssertNotEqual(fourth.manifestSHA256, third.manifestSHA256)
            let fourthManifest = try await scope.assertCursorReplica(fourth, generation: 4, expected: fourthMembers)
            XCTAssertNotEqual(thirdManifest.generation, fourthManifest.generation)
            XCTAssertNotEqual(thirdManifest.captureID, fourthManifest.captureID)
            let fourthRead = try await scope.awaitWebIPC(fourth, query: BinaryShadowScope.secondText, expectedGenerations: 4)
            XCTAssertEqual(fourthRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(fourthRead.generation, thirdRead.generation)
            XCTAssertEqual(Array(fourthRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            try scope.assertCursorRead(fourthRead, generation: 4)
            try scope.assertCollectorHasNoProductIndex()
            try await scope.awaitCursorQuiescence(expectedPublications: afterTranscript)
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                XCTAssertEqual(fourthRead.messages.count, 3)
                XCTAssertEqual(fourthRead.messages.first?.content, BinaryShadowScope.firstText)
                XCTAssertEqual(fourthRead.messages.last?.content, BinaryShadowScope.secondText)
                try await scope.holdForBrowser(browser, read: fourthRead, publication: fourth)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        if let browser {
            try await Task { try await scope.closeBrowser(browser, retainFixture: retain) }.value
        } else {
            try await Task { try await scope.close(retainFixture: retain) }.value
        }
        if retain { print("BINARY_SHADOW_CURSOR_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealCursorLegacyChangesReachBothReplicasAndHQFTSWebIPC() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .cursor, cursorLegacy: true)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            try scope.writeCursorLegacyComposer()
            let mainBytes = try Data(contentsOf: scope.cursorLegacyMain)
            let firstWAL = try scope.cursorLegacyWALBytes()
            let unchangedPair = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(
                root: scope.cursorLegacyRoot, databaseName: "state.vscdb")
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            XCTAssertGreaterThan(first.sequence, 0)
            let firstManifest = try await scope.assertCursorLegacyReplica(first, cwd: scope.fixture.project.path)
            let firstContext = try XCTUnwrap(firstManifest.replayLayout.cursorLegacySession)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText, expectedGenerations: 1)
            try scope.assertCursorLegacyRead(firstRead, cwd: scope.fixture.project.path,
                nativeSize: firstContext.nativePayloadByteCount)
            try scope.assertCursorLegacyFilesUnchanged(main: mainBytes, wal: firstWAL)
            let afterFirst = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(
                root: scope.cursorLegacyRoot, databaseName: "state.vscdb")
            XCTAssertEqual(afterFirst.databaseGeneration, unchangedPair.databaseGeneration)
            XCTAssertEqual(afterFirst.walGeneration, unchangedPair.walGeneration)

            let ownedProject = scope.fixture.base.appendingPathComponent("new-owner")
            try FileManager.default.createDirectory(at: ownedProject, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try scope.rewriteCursorLegacyOwnership(cwd: ownedProject)
            try scope.assertCursorLegacyFilesUnchanged(main: mainBytes, wal: firstWAL)
            let afterOwnership = try EngramCollectorCore.CollectorSQLiteSnapshotLease.observe(
                root: scope.cursorLegacyRoot, databaseName: "state.vscdb")
            XCTAssertEqual(afterOwnership.databaseGeneration, unchangedPair.databaseGeneration)
            XCTAssertEqual(afterOwnership.walGeneration, unchangedPair.walGeneration)

            let afterCwd = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(afterCwd[0], first)
            let second = afterCwd[1]
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertEqual(second.machineID, first.machineID)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            let secondManifest = try await scope.assertCursorLegacyReplica(second, cwd: ownedProject.path)
            let secondContext = try XCTUnwrap(secondManifest.replayLayout.cursorLegacySession)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            XCTAssertNotEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
            XCTAssertEqual(secondContext.nativePayloadByteCount, firstContext.nativePayloadByteCount)
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.firstText, expectedGenerations: 2)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            XCTAssertEqual(secondRead.messages, firstRead.messages)
            try scope.assertCursorLegacyRead(secondRead, cwd: ownedProject.path,
                nativeSize: secondContext.nativePayloadByteCount)
            try scope.assertCursorLegacyFilesUnchanged(main: mainBytes, wal: firstWAL)
            try scope.assertCollectorHasNoProductIndex()
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: secondRead, publication: second)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        if let browser {
            try await Task { try await scope.closeBrowser(browser, retainFixture: retain) }.value
        } else {
            try await Task { try await scope.close(retainFixture: retain) }.value
        }
        if retain { print("BINARY_SHADOW_CURSOR_LEGACY_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealGrokCompactionOnlyChangeReachesBothReplicasAndHQWebIPC() async throws {
        let scope = try BinaryShadowScope(binaries: ShadowBinaries.explicitEnvironment(), sourceKind: .grok)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeGrokFiles(second: false)
            let primaryBytes = try Data(contentsOf: scope.source)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            try await scope.assertGrokReplicaBytes(first, expected: firstBytes)
            try scope.provisionHQ(first, useStartupAuthority: true)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.grokArchiveFirst)
            try scope.assertGrokRead(firstRead, second: false)

            let secondBytes = try scope.writeGrokFiles(second: true)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            let publications = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(publications[0], first)
            let second = publications[1]
            XCTAssertEqual(second.sequence, 2)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            try await scope.assertGrokReplicaBytes(second, expected: secondBytes)
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.grokArchiveSecond)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            try scope.assertGrokRead(secondRead, second: true)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task { try await scope.close(retainFixture: retain) }.value
        if retain { print("BINARY_SHADOW_GROK_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealGeminiNativeRootChangeReachesBothReplicasAndHQWebIPC() async throws {
        try await assertGeminiBinaryChain(registryOnly: false)
    }

    func testRealGeminiRegistryOnlyChangeReachesBothReplicasAndHQWebIPC() async throws {
        try await assertGeminiBinaryChain(registryOnly: true)
    }

    private func assertGeminiBinaryChain(registryOnly: Bool) async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .geminiCli, geminiRegistryOnly: registryOnly)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeGeminiFiles(second: false)
            let primaryBytes = try Data(contentsOf: scope.source)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            let firstManifest = try await scope.assertGeminiReplicaBytes(first, expected: firstBytes)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText)
            try scope.assertGeminiRead(firstRead, second: false)
            let secondBytes = try scope.writeGeminiFiles(second: true)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes)
            let all = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(all[0], first)
            let second = all[1]
            XCTAssertEqual(second.sequence, 2)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            let secondManifest = try await scope.assertGeminiReplicaBytes(second, expected: secondBytes)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            if registryOnly {
                XCTAssertEqual(firstManifest.wholeSourceSHA256, secondManifest.wholeSourceSHA256)
                XCTAssertEqual(firstManifest.chunks, secondManifest.chunks)
            }
            let secondRead = try await scope.awaitWebIPC(second, query: BinaryShadowScope.firstText)
            XCTAssertEqual(firstRead.sessionID, secondRead.sessionID)
            XCTAssertNotEqual(firstRead.generation, secondRead.generation)
            try scope.assertGeminiRead(secondRead, second: true)
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task { try await scope.close(retainFixture: retain) }.value
        if retain { print("BINARY_SHADOW_GEMINI_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealCopilotWorkspaceChangeReachesBothReplicasAndHQWebIPC() async throws {
        try await assertCopilotBinaryChain(checkpoint: false)
    }

    func testRealCopilotCheckpointBodyChangeReachesBothReplicasAndHQWebIPC() async throws {
        try await assertCopilotBinaryChain(checkpoint: true)
    }

    private func assertCopilotBinaryChain(checkpoint: Bool) async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .copilot, copilotCheckpoint: checkpoint)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeCopilotFiles(second: false)
            let primaryBytes = try Data(contentsOf: scope.source)
            try scope.startCollector()
            let initial = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(initial.first)
            let firstManifest = try await scope.assertCopilotReplicaBytes(first, expected: firstBytes)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(first, query: BinaryShadowScope.firstText, expectedGenerations: 1)
            try scope.assertCopilotRead(firstRead, second: false)
            let secondBytes = try scope.writeCopilotFiles(second: true)
            XCTAssertEqual(try Data(contentsOf: scope.source), primaryBytes, "only the auxiliary file changes")
            let all = try await scope.awaitDualPublications(count: 2)
            XCTAssertEqual(all[0], first)
            let second = all[1]
            // A redundant alias reservation may reuse the first capture and consume a sequence.
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            let secondManifest = try await scope.assertCopilotReplicaBytes(second, expected: secondBytes)
            XCTAssertEqual(firstManifest.generation, secondManifest.generation)
            XCTAssertNotEqual(firstManifest.captureID, secondManifest.captureID)
            let secondRead = try await scope.awaitWebIPC(second,
                query: checkpoint ? BinaryShadowScope.secondText : BinaryShadowScope.firstText, expectedGenerations: 2)
            XCTAssertEqual(firstRead.sessionID, secondRead.sessionID)
            XCTAssertNotEqual(firstRead.generation, secondRead.generation)
            try scope.assertCopilotRead(secondRead, second: true)
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task { try await scope.close(retainFixture: retain) }.value
        if retain { print("BINARY_SHADOW_COPILOT_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealVSCodeCapturedGenerationsReachHQSearchAfterOriginalSourceRemoval() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .vscode)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstBytes = try scope.writeVSCodeSource(second: false)
            try scope.startCollector()
            let firstPublications = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(firstPublications.first)
            try await scope.assertReplicaBytes(first, expected: firstBytes)
            try await scope.assertVSCodeFrozenContext(first)
            let secondBytes = try scope.writeVSCodeSource(second: true)
            let publications = try await scope.awaitDualPublications(count: 2)
            let second = try XCTUnwrap(publications.last)
            XCTAssertEqual(publications.first, first)
            XCTAssertEqual(second.machineID, first.machineID)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            try await scope.assertReplicaBytes(second, expected: secondBytes)
            try await scope.assertVSCodeFrozenContext(second)
            // No HQ parsing/indexing process exists until every live source input is gone.
            try FileManager.default.removeItem(at: scope.fixture.sources)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let read = try await scope.awaitWebIPC(second, query: BinaryShadowScope.secondText, expectedGenerations: 2)
            try scope.assertVSCodeRead(read)
            try scope.assertHQContainsOnlyBinaryProducedRows(expectedGenerations: 2)
            try scope.assertCollectorHasNoProductIndex()
            XCTAssertFalse(FileManager.default.fileExists(atPath: scope.fixture.sources.path))
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: read, publication: second)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task {
            if let browser { try await scope.closeBrowser(browser, retainFixture: retain) }
            else { try await scope.close(retainFixture: retain) }
        }.value
        if retain { print("BINARY_SHADOW_VSCODE_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealAntigravityCapturedGenerationsReachHQSearchAfterOriginalSourceRemoval() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .antigravity)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstBytes = try scope.writeAntigravityCLISource(second: false)
            try scope.startCollector()
            let firstPublications = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(firstPublications.first)
            try await scope.assertReplicaBytes(first, expected: firstBytes)
            try await scope.assertAntigravityCLILayout(first)
            let secondBytes = try scope.writeAntigravityCLISource(second: true)
            let publications = try await scope.awaitDualPublications(count: 2)
            let second = try XCTUnwrap(publications.last)
            XCTAssertEqual(publications.first, first)
            XCTAssertEqual(second.machineID, first.machineID)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            try await scope.assertReplicaBytes(second, expected: secondBytes)
            try await scope.assertAntigravityCLILayout(second)
            // No HQ parsing/indexing process exists until every live source input is gone.
            try FileManager.default.removeItem(at: scope.fixture.sources)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let read = try await scope.awaitWebIPC(second, query: BinaryShadowScope.secondText, expectedGenerations: 2)
            try scope.assertAntigravityRead(read)
            try scope.assertHQContainsOnlyBinaryProducedRows(expectedGenerations: 2)
            try scope.assertCollectorHasNoProductIndex()
            XCTAssertFalse(FileManager.default.fileExists(atPath: scope.fixture.sources.path))
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: read, publication: second)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task {
            if let browser { try await scope.closeBrowser(browser, retainFixture: retain) }
            else { try await scope.close(retainFixture: retain) }
        }.value
        if retain { print("BINARY_SHADOW_ANTIGRAVITY_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealWindsurfCapturedGenerationsReachHQSearchAfterOriginalSourceRemoval() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .windsurf)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstBytes = try scope.writeWindsurfHookSource(second: false)
            try scope.startCollector()
            let firstPublications = try await scope.awaitDualPublications(count: 1)
            let first = try XCTUnwrap(firstPublications.first)
            try await scope.assertReplicaBytes(first, expected: firstBytes)
            try await scope.assertWindsurfHookLayout(first)
            let secondBytes = try scope.writeWindsurfHookSource(second: true)
            let publications = try await scope.awaitDualPublications(count: 2)
            let second = try XCTUnwrap(publications.last)
            XCTAssertEqual(publications.first, first)
            XCTAssertEqual(second.machineID, first.machineID)
            XCTAssertEqual(second.sourceInstanceID, first.sourceInstanceID)
            XCTAssertEqual(second.collectorEpoch, first.collectorEpoch)
            XCTAssertGreaterThan(second.sequence, first.sequence)
            XCTAssertNotEqual(second.manifestSHA256, first.manifestSHA256)
            try await scope.assertReplicaBytes(second, expected: secondBytes)
            try await scope.assertWindsurfHookLayout(second)
            // No HQ parsing/indexing process exists until every live source input is gone.
            try FileManager.default.removeItem(at: scope.fixture.sources)
            try scope.provisionHQ(first)
            try scope.startHQ()
            let read = try await scope.awaitWebIPC(second, query: BinaryShadowScope.secondText, expectedGenerations: 2)
            try scope.assertWindsurfRead(read)
            try scope.assertHQContainsOnlyBinaryProducedRows(expectedGenerations: 2)
            try scope.assertCollectorHasNoProductIndex()
            XCTAssertFalse(FileManager.default.fileExists(atPath: scope.fixture.sources.path))
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: read, publication: second)
            }
        } catch { bodyFailure = error }
        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        try await Task {
            if let browser { try await scope.closeBrowser(browser, retainFixture: retain) }
            else { try await scope.close(retainFixture: retain) }
        }.value
        if retain { print("BINARY_SHADOW_WINDSURF_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)") }
        if let bodyFailure { throw bodyFailure }
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoMiniMaxGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.minimax)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoLobsterAIGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.lobsterai)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoClineGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.cline)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoIflowGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.iflow)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoQoderGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.qoder)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoCommandCodeGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.commandcode)
    }

    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoPiGenerations() async throws {
        try await assertAdditionalSourceBinaryChain(.pi)
    }

    func testRealPiNineMiBMessageReachesBothReplicasAndHQWebIPC() async throws {
        try await assertAdditionalSourceBinaryChain(.pi, largePi: true)
    }

    private func assertAdditionalSourceBinaryChain(_ source: EngramCoreRead.SourceName, largePi: Bool = false) async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let browser: ShadowBrowserLaunch?
        if ProcessInfo.processInfo.environment["ENGRAM_SHADOW_BROWSER_HOLD_SECONDS"] != nil {
            browser = try ShadowBrowserLaunch.explicitEnvironment()
            executionTimeAllowance = TimeInterval(browser!.holdSeconds + 60)
        } else { browser = nil }
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: source, timeout: largePi ? 240 : 25, piLargeReply: largePi)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas(browser: browser)
            let firstBytes = try scope.writeInitialAdditionalSource()
            if largePi { XCTAssertGreaterThan(firstBytes.count, 9 * 1024 * 1024) }
            try scope.startCollector(maxCaptureBytes: largePi ? 32 * 1024 * 1024 : nil)
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            if largePi { try await scope.assertLargeReplicaBytes(firstPublication, expected: firstBytes) }
            else { try await scope.assertReplicaBytes(firstPublication, expected: firstBytes) }
            try scope.provisionHQ(firstPublication)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertAdditionalMessagesAndMetadata(firstRead, secondGeneration: false)

            let secondBytes = try scope.appendAdditionalReply(to: firstBytes)
            let second = try await scope.awaitDualPublications(count: 2)
            let secondPublication = second[1]
            XCTAssertEqual(second[0], firstPublication)
            XCTAssertEqual(secondPublication.sequence, 2)
            XCTAssertEqual(secondPublication.machineID, firstPublication.machineID)
            XCTAssertEqual(secondPublication.sourceInstanceID, firstPublication.sourceInstanceID)
            XCTAssertEqual(secondPublication.collectorEpoch, firstPublication.collectorEpoch)
            XCTAssertNotEqual(secondPublication.manifestSHA256, firstPublication.manifestSHA256)
            if largePi { try await scope.assertLargeReplicaBytes(secondPublication, expected: secondBytes) }
            else { try await scope.assertReplicaBytes(secondPublication, expected: secondBytes) }
            let secondRead = try await scope.awaitWebIPC(secondPublication, query: BinaryShadowScope.secondText)
            XCTAssertEqual(secondRead.sessionID, firstRead.sessionID)
            XCTAssertNotEqual(secondRead.generation, firstRead.generation)
            try scope.assertAdditionalMessagesAndMetadata(secondRead, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
            if let browser {
                guard (testRun?.failureCount ?? 0) == 0 else { throw ShadowBrowserFailure.setupFailed }
                try await scope.holdForBrowser(browser, read: secondRead, publication: secondPublication)
            }
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task {
            if let browser { try await scope.closeBrowser(browser, retainFixture: retain) }
            else { try await scope.close(retainFixture: retain) }
        }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary native source shadow cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_NATIVE_PAIR_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }

    /// Synthetic nondefault Claude profile only. Does not replace the default-Claude replay.
    func testRealCollectorAndIndependentReplicasReachHQWebIPCForTwoCustomClaudeProfileGenerations() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .claudeCode)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialCustomClaudeProfileSource()
            try scope.startCustomClaudeProfileCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            XCTAssertEqual(firstPublication.sequence, 1)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)
            try scope.provisionHQCustomClaudeProfile(firstPublication)
            try scope.startHQ()
            let firstRead = try await scope.awaitWebIPC(firstPublication, query: BinaryShadowScope.firstText)
            try scope.assertCustomClaudeProfileMessagesAndMetadata(firstRead, secondGeneration: false)

            let secondBytes = try scope.appendCustomClaudeProfileReply(to: firstBytes)
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
            try scope.assertCustomClaudeProfileMessagesAndMetadata(secondRead, secondGeneration: true)
            XCTAssertEqual(Array(secondRead.messages.prefix(firstRead.messages.count)), firstRead.messages)
            XCTAssertEqual(try Data(contentsOf: scope.source), secondBytes)
            try scope.assertHQContainsOnlyBinaryProducedRows()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary custom Claude profile shadow cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_CUSTOM_CLAUDE_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }

    func testCustomClaudeProfilePublicationIsNotReinterpretedByDefaultHQInstance() async throws {
        let binaries = try ShadowBinaries.explicitEnvironment()
        let scope = try BinaryShadowScope(binaries: binaries, sourceKind: .claudeCode)
        var bodyFailure: Error?
        do {
            try await scope.startReplicas()
            let firstBytes = try scope.writeInitialCustomClaudeProfileSource()
            try scope.startCustomClaudeProfileCollector()
            let first = try await scope.awaitDualPublications(count: 1)
            let firstPublication = try XCTUnwrap(first.first)
            try await scope.assertReplicaBytes(firstPublication, expected: firstBytes)
            try scope.provisionHQ(firstPublication)
            try scope.assertDefaultHQInstanceRejectsCustomParseFormatReprovision(firstPublication)
            try scope.startHQ()
            try await scope.awaitHQQuarantine(publication: firstPublication, failureCode: "quarantine.binding_mismatch")
            try scope.assertHQDidNotIndexClaudeCodeSession()
            try scope.assertCollectorHasNoProductIndex()
        } catch { bodyFailure = error }

        let retain = bodyFailure != nil || (testRun?.failureCount ?? 0) > 0
        let cleanup = Task { try await scope.close(retainFixture: retain) }
        do { try await cleanup.value }
        catch {
            XCTFail("Binary custom Claude default-HQ reinterpret cleanup failed; retained fixture: \(scope.fixture.base.path), socket root: \(scope.socketRoot.path)")
            throw error
        }
        if retain {
            print("BINARY_SHADOW_CUSTOM_CLAUDE_DEFAULT_HQ_RETAINED fixture=\(scope.fixture.base.path) socketRoot=\(scope.socketRoot.path)")
        }
        if let bodyFailure { throw bodyFailure }
    }
}

private extension BinaryShadowScope {
    static let grokArchiveFirst = "grokarchivefirstzxq"
    static let grokArchiveSecond = "grokarchivesecondzxq"

    func writeGrokFiles(second: Bool) throws -> Data {
        let session = source.deletingLastPathComponent()
        if !second {
            try Self.directory(session.deletingLastPathComponent())
            try Self.directory(session)
            try Self.directory(session.appendingPathComponent("compaction"))
            let records: [[String: Any]] = [
                ["type": "user", "content": Self.firstText, "timestamp": Self.firstTimestamp],
                ["type": "assistant", "content": Self.firstReplyText, "timestamp": Self.firstReplyTimestamp,
                 "usage": ["input_tokens": 100, "output_tokens": 7]],
            ]
            let chat = try records.reduce(into: Data()) { bytes, record in
                bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                bytes.append(10)
            }
            try writePrivate(chat, to: source)
            try writeJSON(["info": ["id": "binary-shadow-grok", "cwd": fixture.project.path],
                           "current_model_id": "grok-test-model"], to: session.appendingPathComponent("summary.json"))
            try writeJSON(["working_directory": fixture.project.path], to: session.appendingPathComponent("prompt_context.json"))
            try writePrivate(Data("{\"method\":\"session/update\"}\n".utf8), to: session.appendingPathComponent("updates.jsonl"))
            try writePrivate(Data("# Archive index\n".utf8), to: session.appendingPathComponent("compaction/INDEX.md"))
        }
        let archive = Self.grokArchiveMarkdown(second: second)
        let segment = session.appendingPathComponent("compaction/segment_000.md")
        if second {
            try Data(archive.utf8).write(to: segment)
        } else {
            try writePrivate(Data(archive.utf8), to: segment)
        }
        let paths = ["chat_history.jsonl", "summary.json", "prompt_context.json", "updates.jsonl",
                     "compaction/INDEX.md", "compaction/segment_000.md"]
        return try paths.sorted().reduce(into: Data()) { bytes, path in
            bytes.append(try Data(contentsOf: session.appendingPathComponent(path)))
        }
    }

    static func grokArchiveMarkdown(second: Bool) -> String {
        "# Compacted conversation\n\n## Turn 1\n\n" + grokArchiveFirst + "\n"
            + (second ? "\n## Turn 2\n\n" + grokArchiveSecond + "\n" : "")
    }

    func assertGrokReplicaBytes(_ publication: ShadowPublication, expected: Data) async throws {
        try await assertReplicaBytes(publication, expected: expected)
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isGrokFileSet(manifest))
            XCTAssertEqual(manifest.locator, source.path)
            let files = try XCTUnwrap(manifest.replayLayout.files)
            XCTAssertEqual(files.count, 6)
            for member in files {
                let raw = expected.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(raw), member.wholeSourceSHA256)
            }
        }
    }

    func assertGrokRead(_ read: WebRead, second: Bool) throws {
        XCTAssertEqual(read.messages.map(\.role), [.system, .user, .assistant])
        XCTAssertEqual(read.messages.map(\.content), [
            "Grok compaction archive\nsegment_000.md\n\n" + Self.grokArchiveMarkdown(second: second),
            Self.firstText, Self.firstReplyText,
        ])
        XCTAssertEqual(read.messages.last?.usage?.inputTokens, 100)
        XCTAssertEqual(read.messages.last?.usage?.outputTokens, 7)
        try readHQ { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(row["source"] as String, "grok")
            XCTAssertEqual(row["cwd"] as String, fixture.project.path)
            XCTAssertEqual(row["model"] as String, "grok-test-model")
            XCTAssertEqual(row["message_count"] as Int, 2)
            XCTAssertEqual(row["system_message_count"] as Int, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT stored_session_id) FROM capture_ingest_generations"), 1)
        }
    }

    var vscodeWorkspace: URL { source.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("workspace.json") }
    var vscodeConfiguration: URL { fixture.sources.appendingPathComponent("example.code-workspace") }
    func vscodeConfigurationBytes() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["folders": [["path": fixture.project.path]]], options: [.sortedKeys])
    }
    func writeVSCodeSource(second: Bool) throws -> Data {
        guard sourceKind == .vscode else { throw BinaryShadowFailure.fixture }
        if !second {
            try Self.directory(source.deletingLastPathComponent().deletingLastPathComponent())
            try Self.directory(source.deletingLastPathComponent())
            try writePrivate(vscodeConfigurationBytes(), to: vscodeConfiguration)
            try writePrivate(JSONSerialization.data(withJSONObject: ["configuration": vscodeConfiguration.absoluteString],
                options: [.sortedKeys]), to: vscodeWorkspace)
        }
        var requests: [[String: Any]] = [["timestamp": 1_788_739_200_000,
            "message": ["text": Self.firstText],
            "response": [["value": ["kind": "markdownContent", "content": ["value": Self.firstReplyText]]]]]]
        if second { requests.append(["timestamp": 1_788_739_202_000, "message": ["text": Self.secondText], "response": []]) }
        var journal = try JSONSerialization.data(withJSONObject: ["kind": 0,
            "v": ["sessionId": "binary-shadow-vscode", "creationDate": 1_788_739_200_000, "requests": requests]], options: [.sortedKeys])
        journal.append(10)
        if second {
            let handle = try FileHandle(forWritingTo: source)
            do { try handle.truncate(atOffset: 0); try handle.write(contentsOf: journal); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
        } else {
            try writePrivate(journal, to: source)
        }
        return journal + (try Data(contentsOf: vscodeWorkspace))
    }
    func assertVSCodeFrozenContext(_ publication: ShadowPublication) async throws {
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isVSCodeFileSet(manifest))
            XCTAssertEqual(manifest.replayLayout.vscodeWorkspaceContext?.configurationData, try vscodeConfigurationBytes())
            XCTAssertEqual(manifest.replayLayout.vscodeWorkspaceContext?.configurationLocator, vscodeConfiguration.path)
        }
    }
    func assertVSCodeRead(_ read: WebRead) throws {
        XCTAssertEqual(read.messages.map(\.content), [Self.firstText, Self.firstReplyText, Self.secondText])
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertTrue(read.messages.allSatisfy { $0.usage == nil })
        try readHQ { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(row["source"] as String, "vscode")
            XCTAssertEqual(row["cwd"] as String, fixture.project.path)
            XCTAssertNil(row["model"] as String?)
            XCTAssertEqual(row["message_count"] as Int, 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = 'binary-shadow-vscode'", arguments: [read.sessionID]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT stored_session_id) FROM capture_ingest_generations"), 1)
        }
    }

    func writeAntigravityCLISource(second: Bool) throws -> Data {
        guard sourceKind == .antigravity else { throw BinaryShadowFailure.fixture }
        if !second {
            try Self.directory(fixture.sources.appendingPathComponent("session"))
            try Self.directory(fixture.sources.appendingPathComponent("session/.system_generated"))
            try Self.directory(fixture.sources.appendingPathComponent("session/.system_generated/logs"))
        }
        let sample = fixture.project.path + "/a"
        var records: [[String: Any]] = [
            ["type": "USER_INPUT", "created_at": Self.firstTimestamp, "content": Self.firstText + " " + sample],
            ["type": "PLANNER_RESPONSE", "created_at": Self.firstReplyTimestamp, "content": Self.firstReplyText,
             "tool_calls": [["name": "read", "args": ["path": sample]]]],
            ["type": "TOOL_OUTPUT", "created_at": Self.firstReplyTimestamp, "content": "tool " + sample],
        ]
        if second {
            records.append(["type": "USER_INPUT", "created_at": Self.secondTimestamp,
                            "content": Self.secondText + " " + sample])
        }
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            data.append(10)
        }
        if second {
            let handle = try FileHandle(forWritingTo: source)
            do { try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
        } else {
            try writePrivate(bytes, to: source)
        }
        return bytes
    }

    func assertAntigravityCLILayout(_ publication: ShadowPublication) async throws {
        let relative = "session/.system_generated/logs/transcript.jsonl"
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isAntigravityCLITranscript(manifest))
            XCTAssertEqual(manifest.source, "antigravity")
            XCTAssertEqual(manifest.replayLayout.relativePaths, [relative])
            XCTAssertTrue(manifest.locator.hasSuffix("/" + relative))
            XCTAssertNil(manifest.sessionID)
        }
    }

    func assertAntigravityRead(_ read: WebRead) throws {
        let sample = fixture.project.path + "/a"
        XCTAssertEqual(read.messages.map(\.content), [
            Self.firstText + " " + sample, Self.firstReplyText, "tool " + sample, Self.secondText + " " + sample,
        ])
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertTrue(read.messages.allSatisfy { $0.usage == nil })
        try readHQ { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(row["source"] as String, "antigravity")
            XCTAssertEqual(row["cwd"] as String, fixture.project.path)
            XCTAssertNil(row["model"] as String?)
            XCTAssertEqual(row["message_count"] as Int, 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM capture_ingest_identity_bindings
                WHERE stored_session_id = ? AND native_id = 'session'
                """, arguments: [read.sessionID]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT stored_session_id) FROM capture_ingest_generations"), 1)
        }
    }

    func writeWindsurfHookSource(second: Bool) throws -> Data {
        guard sourceKind == .windsurf else { throw BinaryShadowFailure.fixture }
        if !second {
            try Self.directory(fixture.sources.appendingPathComponent("transcripts"))
        }
        let sample = fixture.project.path + "/a"
        var records: [[String: Any]] = [
            ["type": "user_input", "status": "done",
             "user_input": ["user_response": Self.firstText + " " + sample]],
            ["type": "planner_response", "status": "done",
             "planner_response": ["response": Self.firstReplyText]],
            windsurfCodeAction(sample: sample),
        ]
        if second {
            records.append(["type": "user_input", "status": "done",
                            "user_input": ["user_response": Self.secondText + " " + sample]])
        }
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]))
            data.append(10)
        }
        if second {
            let handle = try FileHandle(forWritingTo: source)
            do { try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
        } else {
            try writePrivate(bytes, to: source)
        }
        return bytes
    }

    func assertWindsurfHookLayout(_ publication: ShadowPublication) async throws {
        let relative = "session.jsonl"
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isWindsurfHookTranscript(manifest))
            XCTAssertEqual(manifest.source, "windsurf")
            XCTAssertEqual(manifest.replayLayout.relativePaths, [relative])
            XCTAssertEqual(manifest.locator, source.path)
            XCTAssertTrue(manifest.locator.hasSuffix("/transcripts/" + relative))
            XCTAssertNil(manifest.sessionID)
        }
    }

    func assertWindsurfRead(_ read: WebRead) throws {
        let sample = fixture.project.path + "/a"
        let action = windsurfCodeAction(sample: sample)
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertEqual(read.messages[0].content, Self.firstText + " " + sample)
        XCTAssertEqual(read.messages[1].content, Self.firstReplyText)
        let tool = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(read.messages[2].content.utf8)) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: tool), NSDictionary(dictionary: action))
        XCTAssertEqual(read.messages[3].content, Self.secondText + " " + sample)
        XCTAssertTrue(read.messages.allSatisfy { $0.usage == nil })
        XCTAssertTrue(read.messages.allSatisfy { $0.timestamp == nil })
        XCTAssertTrue(read.messages.allSatisfy { $0.toolCalls == nil })
        try readHQ { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(row["source"] as String, "windsurf")
            XCTAssertEqual(row["cwd"] as String, "")
            XCTAssertNil(row["model"] as String?)
            XCTAssertEqual(row["start_time"] as String, "")
            XCTAssertNil(row["end_time"] as String?)
            XCTAssertEqual(row["message_count"] as Int, 4)
            XCTAssertEqual(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM capture_ingest_identity_bindings
                WHERE stored_session_id = ? AND native_id = 'session'
                """, arguments: [read.sessionID]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT stored_session_id) FROM capture_ingest_generations"), 1)
        }
    }

    private func windsurfCodeAction(sample: String) -> [String: Any] {
        ["type": "code_action", "status": "done", "code_action": ["path": sample, "new_content": "body"]]
    }

    func writeInitialAdditionalSource() throws -> Data {
        guard [.minimax, .lobsterai, .qoder, .iflow, .cline, .commandcode, .pi].contains(sourceKind) else { throw BinaryShadowFailure.fixture }
        try Self.directory(source.deletingLastPathComponent())
        if sourceKind == .cline {
            let bytes = try clineArray(secondGeneration: false)
            try writePrivate(bytes, to: source)
            return bytes
        }
        var records = [additionalRecord(assistant: false, second: false), additionalRecord(assistant: true, second: false)]
        if sourceKind == .pi {
            records.insert(["type": "session", "id": "binary-shadow-pi", "cwd": fixture.project.path,
                "timestamp": Self.firstTimestamp], at: 0)
        }
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func appendAdditionalReply(to first: Data) throws -> Data {
        XCTAssertEqual(try Data(contentsOf: source), first)
        if sourceKind == .cline {
            let bytes = try clineArray(secondGeneration: true)
            let handle = try FileHandle(forWritingTo: source)
            do { try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            return bytes
        }
        var append = try JSONSerialization.data(withJSONObject: additionalRecord(assistant: true, second: true), options: [.sortedKeys])
        append.append(10)
        let handle = try FileHandle(forWritingTo: source)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        return first + append
    }

    func clineArray(secondGeneration: Bool) throws -> Data {
        func request(second: Bool) throws -> [String: Any] {
            let text = try JSONSerialization.data(withJSONObject: [
                "request": "Current Working Directory (\(fixture.project.path)) Files",
                "tokensIn": second ? 40 : 100, "tokensOut": second ? 9 : 7,
            ], options: [.sortedKeys])
            return ["say": "api_req_started", "text": String(decoding: text, as: UTF8.self),
                "ts": second ? 1_780_000_000_003 : 1_780_000_000_001,
                "modelInfo": ["modelId": "cline-model"]]
        }
        var records: [[String: Any]] = [
            ["say": "task", "text": Self.firstText, "ts": 1_780_000_000_000],
            try request(second: false),
            ["say": "text", "text": Self.firstReplyText, "ts": 1_780_000_000_002],
        ]
        if secondGeneration {
            records.append(try request(second: true))
            records.append(["say": "text", "text": Self.secondText, "ts": 1_780_000_000_004])
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
    }

    private var additionalFirstReplyText: String {
        Self.firstReplyText + (piLargeReply ? String(repeating: "x", count: 9 * 1024 * 1024) : "")
    }

    func additionalRecord(assistant: Bool, second: Bool) -> [String: Any] {
        let role = assistant ? "assistant" : "user"
        let text = second ? Self.secondText : (assistant ? additionalFirstReplyText : Self.firstText)
        var record: [String: Any] = ["sessionId": "binary-shadow-\(sourceKind.rawValue)", "cwd": fixture.project.path,
            "timestamp": second ? Self.secondTimestamp : (assistant ? Self.firstReplyTimestamp : Self.firstTimestamp)]
        if sourceKind == .pi {
            var message: [String: Any] = ["role": role, "content": [["type": "text", "text": text]]]
            if assistant {
                message["model"] = "pi-test-model"
                message["usage"] = ["input": second ? 40 : 100, "output": second ? 9 : 7]
            }
            return ["type": "message", "id": second ? "message-3" : (assistant ? "message-2" : "message-1"),
                "timestamp": record["timestamp"]!, "message": message]
        }
        if ([EngramCoreRead.SourceName.qoder, .iflow, .minimax, .lobsterai].contains(sourceKind)) {
            record["type"] = role
            var message: [String: Any] = ["content": text]
            if assistant {
                message["model"] = "MiniMax-M2.1"
                message["usage"] = ["input_tokens": second ? 40 : 100, "output_tokens": second ? 9 : 7]
            }
            record["message"] = message
        } else {
            record["role"] = role
            record["content"] = [["type": "text", "text": text]]
            if assistant { record["metadata"] = ["model": "command-code-agent"] }
        }
        return record
    }

    func assertAdditionalMessagesAndMetadata(_ read: WebRead, secondGeneration: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), secondGeneration ? [Self.firstText, additionalFirstReplyText, Self.secondText] : [Self.firstText, additionalFirstReplyText])
        XCTAssertEqual(read.messages.map(\.role), secondGeneration ? [.user, .assistant, .assistant] : [.user, .assistant])
        if ([EngramCoreRead.SourceName.qoder, .iflow, .minimax, .lobsterai, .cline, .pi].contains(sourceKind)) {
            let assistants = read.messages.filter { $0.role == .assistant }
            XCTAssertEqual(try XCTUnwrap(assistants.first).usage?.inputTokens, 100)
            XCTAssertEqual(try XCTUnwrap(assistants.first).usage?.outputTokens, 7)
            if secondGeneration {
                XCTAssertEqual(try XCTUnwrap(assistants.last).usage?.inputTokens, 40)
                XCTAssertEqual(try XCTUnwrap(assistants.last).usage?.outputTokens, 9)
            }
        } else {
            XCTAssertTrue(read.messages.allSatisfy { $0.usage == nil })
        }
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, "binary-shadow-\(sourceKind.rawValue)"]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, sourceKind.rawValue)
            XCTAssertEqual(session["model"] as String?, sourceKind == .pi ? "pi-test-model" : sourceKind == .cline ? "cline-model" : ([EngramCoreRead.SourceName.qoder, .iflow, .minimax, .lobsterai].contains(sourceKind)) ? "MiniMax-M2.1" : "command-code-agent")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["file_path"] as String, "capture://\(read.generation)")
            XCTAssertEqual(session["message_count"] as Int, secondGeneration ? 3 : 2)
            if ([EngramCoreRead.SourceName.qoder, .iflow, .minimax, .lobsterai, .cline, .pi].contains(sourceKind)) {
                let cost = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM session_costs WHERE session_id = ?", arguments: [read.sessionID]))
                XCTAssertEqual(cost["input_tokens"] as Int, secondGeneration ? 140 : 100)
                XCTAssertEqual(cost["output_tokens"] as Int, secondGeneration ? 16 : 7)
            }
        }
    }

    func writeInitialQwenSource() throws -> Data {
        guard sourceKind == .qwen else { throw BinaryShadowFailure.fixture }
        try Self.directory(source.deletingLastPathComponent().deletingLastPathComponent())
        try Self.directory(source.deletingLastPathComponent())
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": "binary-shadow-qwen", "cwd": fixture.project.path,
             "timestamp": Self.firstTimestamp, "message": ["parts": [["text": Self.firstText]]]],
            qwenReplyRecord(second: false),
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func appendQwenReply(to first: Data) throws -> Data {
        XCTAssertEqual(try Data(contentsOf: source), first)
        var append = try JSONSerialization.data(withJSONObject: qwenReplyRecord(second: true), options: [.sortedKeys])
        append.append(10)
        let handle = try FileHandle(forWritingTo: source)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        return first + append
    }

    func qwenReplyRecord(second: Bool) -> [String: Any] {
        ["type": "assistant", "sessionId": "binary-shadow-qwen", "cwd": fixture.project.path,
         "model": "qwen3-coder", "timestamp": second ? Self.secondTimestamp : Self.firstReplyTimestamp,
         "message": ["parts": [["text": second ? Self.secondText : Self.firstReplyText]]],
         "usageMetadata": ["promptTokenCount": second ? 40 : 100, "candidatesTokenCount": second ? 9 : 7]]
    }

    func assertQwenMessagesAndMetadata(_ read: WebRead, secondGeneration: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), secondGeneration ? [Self.firstText, Self.firstReplyText, Self.secondText] : [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), secondGeneration ? [.user, .assistant, .assistant] : [.user, .assistant])
        let assistants = read.messages.filter { $0.role == .assistant }
        XCTAssertEqual(try XCTUnwrap(assistants.first).usage?.inputTokens, 100)
        XCTAssertEqual(try XCTUnwrap(assistants.first).usage?.outputTokens, 7)
        if secondGeneration {
            XCTAssertEqual(try XCTUnwrap(assistants.last).usage?.inputTokens, 40)
            XCTAssertEqual(try XCTUnwrap(assistants.last).usage?.outputTokens, 9)
        }
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, "binary-shadow-qwen"]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "qwen")
            XCTAssertEqual(session["model"] as String?, "qwen3-coder")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["file_path"] as String, "capture://\(read.generation)")
            XCTAssertEqual(session["message_count"] as Int, secondGeneration ? 3 : 2)
            let cost = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM session_costs WHERE session_id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(cost["input_tokens"] as Int, secondGeneration ? 140 : 100)
            XCTAssertEqual(cost["output_tokens"] as Int, secondGeneration ? 16 : 7)
        }
    }

    func writeInitialClaudeSource() throws -> Data {
        guard sourceKind == .claudeCode else { throw BinaryShadowFailure.fixture }
        // Claude discovery expects a project directory below the configured root.
        try Self.directory(source.deletingLastPathComponent())
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": Self.claudeNativeID, "cwd": fixture.project.path,
             "timestamp": Self.firstTimestamp, "message": ["content": Self.firstText]],
            claudeReplyRecord(second: false),
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func appendClaudeReply(to first: Data) throws -> Data {
        guard sourceKind == .claudeCode else { throw BinaryShadowFailure.fixture }
        XCTAssertEqual(try Data(contentsOf: source), first)
        var append = try JSONSerialization.data(withJSONObject: claudeReplyRecord(second: true), options: [.sortedKeys])
        append.append(10)
        let handle = try FileHandle(forWritingTo: source)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        var result = first; result.append(append)
        return result
    }

    func claudeReplyRecord(second: Bool) -> [String: Any] {
        ["type": "assistant", "sessionId": Self.claudeNativeID, "cwd": fixture.project.path,
         "timestamp": second ? Self.secondTimestamp : Self.firstReplyTimestamp,
         "message": ["id": second ? "claude-reply-two" : "claude-reply-one", "model": Self.claudeModel,
             "content": [["type": "text", "text": second ? Self.secondText : Self.firstReplyText]],
             "usage": ["input_tokens": second ? 40 : 100, "output_tokens": second ? 9 : 7,
                 "cache_read_input_tokens": second ? 10 : 20, "cache_creation_input_tokens": second ? 3 : 5]]]
    }

    func assertClaudeMessagesAndMetadata(_ read: WebRead, secondGeneration: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), secondGeneration ? [Self.firstText, Self.firstReplyText, Self.secondText] : [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), secondGeneration ? [.user, .assistant, .assistant] : [.user, .assistant])
        let timestamps = secondGeneration ? [Self.firstTimestamp, Self.firstReplyTimestamp, Self.secondTimestamp] : [Self.firstTimestamp, Self.firstReplyTimestamp]
        XCTAssertEqual(read.messages.map(\.timestamp), timestamps.map { Optional($0) })
        XCTAssertNil(try XCTUnwrap(read.messages.first).usage)
        let assistants = read.messages.filter { $0.role == .assistant }
        XCTAssertEqual(try XCTUnwrap(assistants.first).usage,
            EngramServiceWebTokenUsage(inputTokens: 100, outputTokens: 7, cacheReadTokens: 20, cacheCreationTokens: 5))
        if secondGeneration {
            XCTAssertEqual(try XCTUnwrap(assistants.last).usage,
                EngramServiceWebTokenUsage(inputTokens: 40, outputTokens: 9, cacheReadTokens: 10, cacheCreationTokens: 3))
        }
        // Model and aggregate costs are not fields in the Web message projection.
        // Read the binary-produced rows; the fixture seeds authority only.
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, Self.claudeNativeID]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "claude-code")
            XCTAssertEqual(session["model"] as String?, Self.claudeModel)
            XCTAssertEqual(session["tier"] as String?, "normal")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["start_time"] as String, Self.firstTimestamp)
            XCTAssertEqual(session["end_time"] as String?, secondGeneration ? Self.secondTimestamp : Self.firstReplyTimestamp)
            XCTAssertEqual(session["message_count"] as Int, secondGeneration ? 3 : 2)
            XCTAssertEqual(session["user_message_count"] as Int, 1)
            XCTAssertEqual(session["assistant_message_count"] as Int, secondGeneration ? 2 : 1)
            let cost = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM session_costs WHERE session_id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(cost["model"] as String?, Self.claudeModel)
            XCTAssertEqual(cost["input_tokens"] as Int, secondGeneration ? 140 : 100)
            XCTAssertEqual(cost["output_tokens"] as Int, secondGeneration ? 16 : 7)
            XCTAssertEqual(cost["cache_read_tokens"] as Int, secondGeneration ? 30 : 20)
            XCTAssertEqual(cost["cache_creation_tokens"] as Int, secondGeneration ? 8 : 5)
        }
    }

    private static let customClaudeModel = "MiniMax-M2.1"

    func writeInitialCustomClaudeProfileSource() throws -> Data {
        guard sourceKind == .claudeCode else { throw BinaryShadowFailure.fixture }
        try Self.directory(source.deletingLastPathComponent())
        let records: [[String: Any]] = [
            ["type": "user", "sessionId": Self.claudeNativeID, "cwd": fixture.project.path,
             "timestamp": Self.firstTimestamp, "message": ["content": Self.firstText]],
            customClaudeReplyRecord(second: false),
        ]
        let bytes = try records.reduce(into: Data()) { data, record in
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try writePrivate(bytes, to: source)
        return bytes
    }

    func appendCustomClaudeProfileReply(to first: Data) throws -> Data {
        guard sourceKind == .claudeCode else { throw BinaryShadowFailure.fixture }
        XCTAssertEqual(try Data(contentsOf: source), first)
        var append = try JSONSerialization.data(withJSONObject: customClaudeReplyRecord(second: true), options: [.sortedKeys])
        append.append(10)
        let handle = try FileHandle(forWritingTo: source)
        do { try handle.seekToEnd(); try handle.write(contentsOf: append); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        var result = first; result.append(append)
        return result
    }

    func customClaudeReplyRecord(second: Bool) -> [String: Any] {
        ["type": "assistant", "sessionId": Self.claudeNativeID, "cwd": fixture.project.path,
         "timestamp": second ? Self.secondTimestamp : Self.firstReplyTimestamp,
         "message": ["id": second ? "claude-reply-two" : "claude-reply-one", "model": Self.customClaudeModel,
             "content": [["type": "text", "text": second ? Self.secondText : Self.firstReplyText]],
             "usage": ["input_tokens": second ? 40 : 100, "output_tokens": second ? 9 : 7,
                 "cache_read_input_tokens": second ? 10 : 20, "cache_creation_input_tokens": second ? 3 : 5]]]
    }

    func startCustomClaudeProfileCollector() throws {
        var document = fixture.document()
        var collector = try XCTUnwrap(document["collector"] as? [String: Any])
        collector["roots"] = [["rootID": "runtime-claude-custom", "source": "claude-code",
            "rootPath": fixture.sources.path, "revision": 1, "parseFormat": "claudeCustomProfile"]]
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

    func provisionHQCustomClaudeProfile(_ publication: ShadowPublication) throws {
        guard !hqStarted, seedDatabase == nil else { throw BinaryShadowFailure.fixture }
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        seedDatabase = database
        try database.write { db in
            try EngramCoreWrite.EngramMigrationRunner.migrate(db)
            _ = try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db,
                machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID,
                source: .claudeCode, parseFormat: .claudeCustomProfile, configuredRoot: fixture.sources.path,
                initialEpoch: publication.collectorEpoch)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parse_format FROM capture_ingest_source_registry"),
                EngramCoreWrite.CaptureIngestParseFormat.claudeCustomProfile.rawValue)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions"), 0)
        }
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try database.close()
        seedDatabase = nil
        guard chmod(hqDatabase.path, 0o600) == 0 else { throw BinaryShadowFailure.fixture }
    }

    func assertDefaultHQInstanceRejectsCustomParseFormatReprovision(_ publication: ShadowPublication) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        do {
            try database.write { db in
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parse_format FROM capture_ingest_source_registry"),
                    EngramCoreWrite.CaptureIngestParseFormat.claudeDefault.rawValue)
                XCTAssertThrowsError(try EngramCoreWrite.CaptureIngestSourceRegistry.provision(db,
                    machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID,
                    source: .claudeCode, parseFormat: .claudeCustomProfile,
                    configuredRoot: fixture.sources.path, initialEpoch: publication.collectorEpoch)) {
                    XCTAssertEqual($0 as? EngramCoreWrite.CaptureIngestSourceRegistryError, .sourceInstanceConflict)
                }
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parse_format FROM capture_ingest_source_registry"),
                    EngramCoreWrite.CaptureIngestParseFormat.claudeDefault.rawValue)
            }
            try database.close()
        } catch {
            try? database.close()
            throw error
        }
    }

    func awaitHQQuarantine(publication: ShadowPublication, failureCode: String) async throws {
        let digest = try publication.sha256()
        while true {
            try checkRunning()
            if FileManager.default.fileExists(atPath: hqDatabase.path),
               let row = try? readDatabase(hqDatabase, { db in
                   try Row.fetchOne(db, sql: """
                       SELECT status, failure_code FROM capture_ingest_ledger
                       WHERE publication_sha256 = ?
                       """, arguments: [digest])
               }) {
                let status = row["status"] as String
                switch status {
                case "pending", "processing", "failed_retryable":
                    break
                case "quarantined":
                    XCTAssertEqual(row["failure_code"] as String?, failureCode)
                    return
                default:
                    XCTFail("HQ ledger reached terminal status \(status) instead of quarantined")
                    return
                }
            }
            try await pause()
        }
    }

    func assertHQDidNotIndexClaudeCodeSession() throws {
        try readDatabase(hqDatabase) { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE source = 'claude-code'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_source_registry"), 1)
        }
    }

    func assertCustomClaudeProfileMessagesAndMetadata(_ read: WebRead, secondGeneration: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), secondGeneration ? [Self.firstText, Self.firstReplyText, Self.secondText] : [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), secondGeneration ? [.user, .assistant, .assistant] : [.user, .assistant])
        try readHQ { db in
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "claude-code")
            XCTAssertEqual(session["model"] as String?, Self.customClaudeModel)
            XCTAssertEqual(session["tier"] as String?, "normal")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parse_format FROM capture_ingest_source_registry"),
                EngramCoreWrite.CaptureIngestParseFormat.claudeCustomProfile.rawValue)
        }
    }
}


private extension BinaryShadowScope {
    func writeCopilotFiles(second: Bool) throws -> Data {
        let session = fixture.sources.appendingPathComponent("native-copilot")
        let workspace = session.appendingPathComponent("workspace.yaml")
        if !second {
            try Self.directory(session)
            var records: [[String: Any]] = [["type": "session.start", "timestamp": Self.firstTimestamp,
                "data": ["context": ["cwd": fixture.project.path]]]]
            if !copilotCheckpoint {
                records += [["type": "user.message", "timestamp": Self.firstTimestamp, "data": ["content": Self.firstText]],
                    ["type": "assistant.message", "timestamp": Self.firstReplyTimestamp, "data": ["content": Self.firstReplyText]],
                    ["type": "session.shutdown", "data": ["modelMetrics": ["native-model": ["usage":
                        ["inputTokens": 100, "outputTokens": 7, "cacheReadTokens": 3, "cacheWriteTokens": 2]]]]]]
            }
            let events = try records.reduce(into: Data()) { bytes, row in
                bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10)
            }
            try writePrivate(events, to: session.appendingPathComponent("events.jsonl"))
            try writePrivate(Data("id: binary-shadow-copilot\ncwd: \(fixture.project.path)\ncreated_at: \(Self.firstTimestamp)\nsummary: initial metadata\n".utf8), to: workspace)
            if copilotCheckpoint {
                try Self.directory(session.appendingPathComponent("checkpoints"))
                // One checkpoint is correctly skip; use two for normal Web visibility.
                try writePrivate(Data("| 1 | Native checkpoint | 001-body.md |\n| 2 | Saved context | .hidden.MD |\n".utf8), to: source)
                try writePrivate(Data("Preserved hidden checkpoint context.\n".utf8),
                    to: session.appendingPathComponent("checkpoints/.hidden.MD"))
            }
        }
        if copilotCheckpoint {
            let text = second ? Self.secondText : Self.firstText
            try Data(("# Saved conversation\n\n" + text + "\n" + Self.firstReplyText + "\n").utf8)
                .write(to: session.appendingPathComponent("checkpoints/001-body.md"))
        } else if second {
            try Data("id: binary-shadow-copilot\ncwd: \(fixture.project.path)\ncreated_at: \(Self.firstTimestamp)\nsummary: changed workspace only\n".utf8).write(to: workspace)
        }
        var paths = ["events.jsonl", "workspace.yaml"]
        if copilotCheckpoint { paths += ["checkpoints/.hidden.MD", "checkpoints/001-body.md", "checkpoints/index.md"] }
        return try paths.sorted().reduce(into: Data()) { bytes, path in
            bytes.append(try Data(contentsOf: session.appendingPathComponent(path)))
        }
    }

    func assertCopilotReplicaBytes(_ publication: ShadowPublication, expected: Data) async throws -> ShadowManifest {
        try await assertReplicaBytes(publication, expected: expected)
        var first: ShadowManifest?
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertEqual(manifest.schemaVersion, 2)
            XCTAssertEqual(manifest.source, "copilot")
            XCTAssertEqual(manifest.locator, source.path)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCopilotFileSet(manifest))
            let files = try XCTUnwrap(manifest.replayLayout.files)
            XCTAssertEqual(files.count, copilotCheckpoint ? 5 : 2)
            for member in files {
                let bytes = expected.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), member.wholeSourceSHA256)
            }
            if let first { XCTAssertEqual(manifest, first) } else { first = manifest }
        }
        return try XCTUnwrap(first)
    }

    func assertCopilotRead(_ read: WebRead, second: Bool) throws {
        if copilotCheckpoint {
            XCTAssertEqual(read.messages.count, 2)
            XCTAssertEqual(read.messages.first?.role, .assistant)
            XCTAssertTrue(read.messages.first?.content.contains(second ? Self.secondText : Self.firstText) == true)
        } else {
            XCTAssertEqual(read.messages.map(\.content), [Self.firstText, Self.firstReplyText])
            XCTAssertEqual(read.messages.map(\.role), [.user, .assistant])
            XCTAssertEqual(read.messages.last?.usage?.inputTokens, 100)
            XCTAssertEqual(read.messages.last?.usage?.outputTokens, 7)
        }
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, "binary-shadow-copilot"]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "copilot")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["message_count"] as Int, 2)
        }
    }
}

private extension BinaryShadowScope {
    func geminiCWD(second: Bool) -> String {
        second ? fixture.base.appendingPathComponent("second-gemini-project").path : fixture.project.path
    }

    func writeGeminiFiles(second: Bool) throws -> Data {
        let project = fixture.sources.appendingPathComponent("native-gemini")
        let chats = project.appendingPathComponent("chats")
        let rootFile = project.appendingPathComponent(".project_root")
        if !second {
            try Self.directory(project)
            try Self.directory(chats)
            let bytes = try JSONSerialization.data(withJSONObject: ["sessionId": "binary-shadow-gemini",
                "startTime": Self.firstTimestamp, "lastUpdated": Self.firstReplyTimestamp,
                "messages": [["type": "user", "timestamp": Self.firstTimestamp, "content": Self.firstText],
                    ["type": "gemini", "timestamp": Self.firstReplyTimestamp, "content": Self.firstReplyText,
                     "tokens": ["input": 100, "cached": 4, "output": 7, "thoughts": 2, "tool": 1]]]], options: [.sortedKeys])
            try writePrivate(bytes, to: source)
            if !geminiRegistryOnly {
                try writePrivate(Data("{\"originator\":\"gemini-cli\"}".utf8),
                    to: chats.appendingPathComponent("binary-shadow-gemini.engram.json"))
            }
        }
        if second { try Self.directory(URL(fileURLWithPath: geminiCWD(second: true))) }
        if geminiRegistryOnly {
            let bytes = try JSONSerialization.data(withJSONObject: ["projects": [geminiCWD(second: second): "native-gemini",
                "/unrelated-private-project": "do-not-capture-this-project"]], options: [.sortedKeys])
            try bytes.write(to: fixture.base.appendingPathComponent("projects.json"))
        } else {
            try Data((geminiCWD(second: second) + "\n").utf8).write(to: rootFile)
        }
        let paths = geminiRegistryOnly ? ["chats/stem.json"]
            : [".project_root", "chats/binary-shadow-gemini.engram.json", "chats/stem.json"]
        return try paths.reduce(into: Data()) { bytes, path in
            bytes.append(try Data(contentsOf: project.appendingPathComponent(path)))
        }
    }

    func assertGeminiReplicaBytes(_ publication: ShadowPublication, expected: Data) async throws -> ShadowManifest {
        try await assertReplicaBytes(publication, expected: expected)
        var first: ShadowManifest?
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertEqual(manifest.schemaVersion, geminiRegistryOnly ? 3 : 2)
            XCTAssertEqual(manifest.locator, source.path)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isGeminiFileSet(manifest))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("do-not-capture-this-project"))
            let files = try XCTUnwrap(manifest.replayLayout.files)
            XCTAssertEqual(files.count, geminiRegistryOnly ? 1 : 3)
            for member in files {
                let bytes = expected.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), member.wholeSourceSHA256)
            }
            if let first { XCTAssertEqual(manifest, first) } else { first = manifest }
        }
        return try XCTUnwrap(first)
    }

    func assertGeminiRead(_ read: WebRead, second: Bool) throws {
        XCTAssertEqual(read.messages.map(\.content), [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(read.messages.last?.usage?.inputTokens, 96)
        XCTAssertEqual(read.messages.last?.usage?.outputTokens, 10)
        XCTAssertEqual(read.messages.last?.usage?.cacheReadTokens, 4)
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, "binary-shadow-gemini"]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "gemini-cli")
            XCTAssertEqual(session["cwd"] as String, geminiCWD(second: second))
            XCTAssertEqual(session["message_count"] as Int, 2)
        }
    }
}

private extension BinaryShadowScope {
    func writeOpenCodeGeneration(second: Bool) throws -> EngramCollectorCore.CollectorOpenCodeSource.Snapshot {
        if !second {
            guard openCodeDatabase == nil else { throw BinaryShadowFailure.fixture }
            let database = try DatabaseQueue(path: source.path)
            openCodeDatabase = database
            try database.writeWithoutTransaction { db in
                try db.execute(sql: """
                    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
                    CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, slug TEXT, agent TEXT,
                        directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
                    CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
                    CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT);
                    PRAGMA wal_checkpoint(TRUNCATE);
                    """)
            }
            try database.write { db in
                try db.execute(sql: "INSERT INTO session VALUES ('binary-shadow-opencode', NULL, 'native', 'build', ?, 'Native binary task', 1788739200000, 1788739201000, NULL)", arguments: [fixture.project.path])
                try db.execute(sql: "INSERT INTO session(id, directory, title, time_archived) VALUES ('archived-private', '/private/project', 'SIBLING-BINARY-SECRET', 1)")
                try db.execute(sql: """
                    INSERT INTO message VALUES ('m-user','binary-shadow-opencode',1788739200000,'{"role":"user"}');
                    INSERT INTO message VALUES ('m-answer','binary-shadow-opencode',1788739201000,
                        '{"role":"assistant","tokens":{"input":96,"output":10,"reasoning":2,"cache":{"read":4,"write":3}}}');
                    """)
                for (id, message, time, text) in [("p-user", "m-user", 1788739200000 as Int64, Self.firstText),
                                                ("p-answer", "m-answer", 1788739201000 as Int64, Self.firstReplyText)] {
                    let payload = try JSONSerialization.data(withJSONObject: ["type": "text", "text": text], options: [.sortedKeys])
                    try db.execute(sql: "INSERT INTO part VALUES (?, ?, ?, ?)", arguments: [id, message, time, String(decoding: payload, as: UTF8.self)])
                }
            }
        } else {
            let database = try XCTUnwrap(openCodeDatabase)
            try database.write { db in
                try db.execute(sql: "UPDATE session SET time_updated = 1788739202000 WHERE id = 'binary-shadow-opencode'")
                try db.execute(sql: "INSERT INTO message VALUES ('m-second', 'binary-shadow-opencode', 1788739202000, '{\"role\":\"assistant\"}')")
                let payload = try JSONSerialization.data(withJSONObject: ["type": "text", "text": Self.secondText], options: [.sortedKeys])
                try db.execute(sql: "INSERT INTO part VALUES ('p-second', 'm-second', 1788739202000, ?)", arguments: [String(decoding: payload, as: UTF8.self)])
            }
        }
        let staging = fixture.base.appendingPathComponent(second ? "expected-image-two" : "expected-image-one")
        try Self.directory(staging)
        let snapshot = try EngramCollectorCore.CollectorOpenCodeSource.snapshot(root: fixture.sources,
            sessionID: "binary-shadow-opencode", stagingParent: staging)
        XCTAssertNil(snapshot.image.range(of: Data("SIBLING-BINARY-SECRET".utf8)))
        return snapshot
    }

    func assertOpenCodeReplica(_ publication: ShadowPublication,
                               expected: EngramCollectorCore.CollectorOpenCodeSource.Snapshot) async throws -> ShadowManifest {
        try await assertReplicaBytes(publication, expected: expected.image)
        var first: ShadowManifest?
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isOpenCodeSessionImage(manifest))
            XCTAssertEqual(manifest.schemaVersion, 4)
            XCTAssertEqual(manifest.locator, source.path + "::" + expected.sessionID)
            XCTAssertGreaterThan(manifest.rawByteCount, expected.nativePayloadByteCount)
            XCTAssertEqual(manifest.generation, expected.databaseGeneration)
            XCTAssertEqual(manifest.replayLayout.sqliteSession?.databaseLocator, source.path)
            XCTAssertEqual(manifest.replayLayout.sqliteSession?.nativeSessionID, expected.sessionID)
            XCTAssertEqual(manifest.replayLayout.sqliteSession?.nativePayloadByteCount, expected.nativePayloadByteCount)
            XCTAssertEqual(manifest.replayLayout.sqliteSession?.walGeneration, expected.walGeneration)
            if let first { XCTAssertEqual(manifest, first) } else { first = manifest }
        }
        return try XCTUnwrap(first)
    }

    func assertOpenCodeRead(_ read: WebRead, second: Bool, payloadBytes: Int64) throws {
        XCTAssertEqual(read.messages.map(\.content), [Self.firstText, Self.firstReplyText] + (second ? [Self.secondText] : []))
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant] + (second ? [.assistant] : []))
        XCTAssertEqual(read.messages[1].usage?.inputTokens, 96)
        XCTAssertEqual(read.messages[1].usage?.outputTokens, 12)
        XCTAssertEqual(read.messages[1].usage?.cacheReadTokens, 4)
        XCTAssertEqual(read.messages[1].usage?.cacheCreationTokens, 3)
        try readHQ { db in
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "opencode")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["size_bytes"] as Int64, payloadBytes)
            let term = second ? "aurora" : "constellation"
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT session_id) FROM sessions_fts WHERE sessions_fts MATCH ? AND session_id = ?", arguments: [term, read.sessionID]), 1)
            let fts = try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [read.sessionID]).joined(separator: "\n")
            XCTAssertTrue(fts.contains(second ? Self.secondText : Self.firstText))
            XCTAssertEqual(session["message_count"] as Int, second ? 3 : 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = 'binary-shadow-opencode'", arguments: [read.sessionID]), 1)
        }
    }
}

private extension BinaryShadowScope {
    static let kimiNativeID = "binary-shadow-kimi"
    static let kimiWorkspace = "workspace"
    static let kimiUnrelated = "UNRELATED-KIMI-SECRET"

    var kimiRegistry: URL { fixture.base.appendingPathComponent("kimi.json") }
    var kimiSession: URL { fixture.sources.appendingPathComponent("\(Self.kimiWorkspace)/\(Self.kimiNativeID)") }
    var kimiShard: URL { kimiSession.appendingPathComponent("context_sub_2.jsonl") }
    var kimiWire: URL { kimiSession.appendingPathComponent("wire.jsonl") }
    func kimiCWD(second: Bool) -> String {
        second ? fixture.base.appendingPathComponent("second-kimi-project").path : fixture.project.path
    }

    func writeKimiInitial() throws {
        try Self.directory(fixture.sources.appendingPathComponent(Self.kimiWorkspace))
        try Self.directory(kimiSession)
        try writePrivate(kimiJSONL([["role": "user", "content": Self.firstText],
            ["role": "assistant", "content": Self.firstReplyText]]), to: source)
        try writePrivate(kimiJSONL(kimiWireTurns(second: false)), to: kimiWire)
        try writeKimiRegistry(secondCwd: false)
    }

    func writeKimiShard() throws {
        try writePrivate(kimiJSONL([["role": "user", "content": Self.secondText]]), to: kimiShard)
        try kimiJSONL(kimiWireTurns(second: true)).write(to: kimiWire)
    }

    func writeKimiRegistry(secondCwd: Bool) throws {
        if secondCwd { try Self.directory(URL(fileURLWithPath: kimiCWD(second: true))) }
        try JSONSerialization.data(withJSONObject: ["work_dirs": [
            ["path": kimiCWD(second: secondCwd), "last_session_id": Self.kimiNativeID],
            ["path": "/\(Self.kimiUnrelated)", "last_session_id": "other-session"],
        ]], options: [.sortedKeys]).write(to: kimiRegistry)
    }

    func kimiRelativePaths(generation: Int) -> [String] {
        let prefix = "\(Self.kimiWorkspace)/\(Self.kimiNativeID)/"
        var paths = [prefix + "context.jsonl"]
        if generation >= 2 { paths.append(prefix + "context_sub_2.jsonl") }
        paths.append(prefix + "wire.jsonl")
        return paths.sorted()
    }

    func kimiExpectedBytes(generation: Int) throws -> Data {
        try kimiRelativePaths(generation: generation).reduce(into: Data()) { bytes, path in
            bytes.append(try Data(contentsOf: fixture.sources.appendingPathComponent(path)))
        }
    }

    func kimiContextOnlySize(generation: Int) throws -> Int64 {
        var size = Int64(try Data(contentsOf: source).count)
        if generation >= 2 { size += Int64(try Data(contentsOf: kimiShard).count) }
        return size
    }

    func assertKimiReplica(_ publication: ShadowPublication, generation: Int) async throws -> ShadowManifest {
        let expected = try kimiExpectedBytes(generation: generation)
        try await assertReplicaBytes(publication, expected: expected)
        var first: ShadowManifest?
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertEqual(manifest.schemaVersion, 5)
            XCTAssertEqual(manifest.source, "kimi")
            XCTAssertEqual(manifest.locator, source.path)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isKimiFileSet(manifest))
            let context = try XCTUnwrap(manifest.replayLayout.kimiProjectContext)
            XCTAssertEqual(context.nativeSessionID, Self.kimiNativeID)
            XCTAssertEqual(context.workspaceName, Self.kimiWorkspace)
            XCTAssertEqual(context.cwd, kimiCWD(second: generation == 3))
            XCTAssertEqual(context.registryLocator, kimiRegistry.path)
            XCTAssertNil(bytes.range(of: Data(Self.kimiUnrelated.utf8)))
            XCTAssertEqual(manifest.replayLayout.relativePaths, kimiRelativePaths(generation: generation))
            XCTAssertEqual(manifest.replayLayout.absentRelativePaths, [])
            XCTAssertGreaterThan(manifest.rawByteCount, try kimiContextOnlySize(generation: generation))
            let files = try XCTUnwrap(manifest.replayLayout.files)
            for member in files {
                let slice = expected.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(slice), member.wholeSourceSHA256)
            }
            if let first { XCTAssertEqual(manifest, first) } else { first = manifest }
        }
        return try XCTUnwrap(first)
    }

    func assertKimiRead(_ read: WebRead, generation: Int) throws {
        let contents: [String] = [Self.firstText, Self.firstReplyText] + (generation >= 2 ? [Self.secondText] : [])
        XCTAssertEqual(read.messages.map(\.content), contents)
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant] + (generation >= 2 ? [.user] : []))
        XCTAssertEqual(read.messages[1].usage?.inputTokens, 96)
        XCTAssertEqual(read.messages[1].usage?.outputTokens, 12)
        XCTAssertEqual(read.messages[1].usage?.cacheReadTokens, 4)
        XCTAssertEqual(read.messages[1].usage?.cacheCreationTokens, 3)
        let expectedSize = try kimiContextOnlySize(generation: generation)
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, Self.kimiNativeID]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "kimi")
            XCTAssertEqual(session["cwd"] as String, kimiCWD(second: generation == 3))
            XCTAssertEqual(session["size_bytes"] as Int64, expectedSize)
            XCTAssertEqual(session["message_count"] as Int, contents.count)
            let term = generation >= 2 ? "aurora" : "constellation"
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT session_id) FROM sessions_fts WHERE sessions_fts MATCH ? AND session_id = ?",
                arguments: [term, read.sessionID]), 1)
            let fts = try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?", arguments: [read.sessionID]).joined(separator: "\n")
            XCTAssertTrue(fts.contains(generation >= 2 ? Self.secondText : Self.firstText))
        }
    }

    private func kimiJSONL(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { bytes, row in
            bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            bytes.append(10)
        }
    }

    private func kimiWireTurns(second: Bool) -> [[String: Any]] {
        var rows: [[String: Any]] = [
            ["timestamp": 1_788_739_201, "message": ["type": "TurnBegin"]],
            ["timestamp": 1_788_739_202, "message": ["type": "StatusUpdate",
                "payload": ["token_usage": ["input_other": 96, "output": 12, "input_cache_read": 4, "input_cache_creation": 3]]]],
            ["timestamp": 1_788_739_203, "message": ["type": "TurnEnd"]],
        ]
        if second {
            rows += [
                ["timestamp": 1_788_739_204, "message": ["type": "TurnBegin"]],
                ["timestamp": 1_788_739_205, "message": ["type": "TurnEnd"]],
            ]
        }
        return rows
    }
}

private extension BinaryShadowScope {
    static let cursorNativeID = "binary-shadow-cursor"
    static let cursorStoreTitle = "Store title"
    static let cursorWALTitle = "WAL store title"
    static let cursorLiveTitle = "Live overlay title"
    static let cursorStoreRelative = "chats/ws/binary-shadow-cursor/store.db"
    static let cursorMetaRelative = "chats/ws/binary-shadow-cursor/meta.json"
    static let cursorTranscriptRelative =
        "projects/proj/agent-transcripts/binary-shadow-cursor/binary-shadow-cursor.jsonl"

    var cursorStore: URL { fixture.sources.appendingPathComponent(Self.cursorStoreRelative) }
    var cursorWAL: URL { URL(fileURLWithPath: cursorStore.path + "-wal") }
    var cursorMeta: URL { fixture.sources.appendingPathComponent(Self.cursorMetaRelative) }

    func writeCursorGeneration(_ generation: Int) throws -> [String: Data] {
        switch generation {
        case 1:
            guard cursorStoreDatabase == nil else { throw BinaryShadowFailure.fixture }
            try FileManager.default.createDirectory(at: cursorStore.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let database = try DatabaseQueue(path: cursorStore.path)
            cursorStoreDatabase = database
            try database.writeWithoutTransaction { db in
                try db.execute(sql: """
                    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
                    CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
                    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
                    PRAGMA wal_checkpoint(TRUNCATE);
                    """)
            }
            try chmodPrivate(cursorStore)
            try database.write { db in
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('0', ?)",
                    arguments: [try cursorStoredHex(["cwd": fixture.project.path, "name": Self.cursorStoreTitle])])
                try db.execute(sql: "INSERT INTO blobs (id, data) VALUES ('user', ?)",
                    arguments: [#"{"role":"user","content":"STORE user that must lose"}"#])
                try db.execute(sql: "INSERT INTO blobs (id, data) VALUES ('assistant', ?)",
                    arguments: [#"{"role":"assistant","content":"STORE assistant that must lose"}"#])
            }
            try chmodPrivate(cursorWAL)
            try writePrivate(try JSONSerialization.data(withJSONObject: ["cwd": fixture.project.path],
                options: [.sortedKeys]), to: cursorMeta)
            try writePrivate(try cursorJSONL([
                (role: "user", text: Self.firstText),
                (role: "assistant", text: Self.firstReplyText),
            ]), to: source)
        case 2:
            let database = try XCTUnwrap(cursorStoreDatabase)
            try database.write { db in
                try db.execute(sql: "UPDATE meta SET value = ? WHERE key = '0'",
                    arguments: [try cursorStoredHex(["cwd": fixture.project.path, "name": Self.cursorWALTitle])])
            }
        case 3:
            try JSONSerialization.data(withJSONObject: [
                "cwd": fixture.project.path, "name": Self.cursorLiveTitle,
            ], options: [.sortedKeys]).write(to: cursorMeta)
        case 4:
            let handle = try FileHandle(forWritingTo: source)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: try cursorJSONL([(role: "assistant", text: Self.secondText)]))
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
        default:
            throw BinaryShadowFailure.fixture
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cursorStore.path + "-journal"))
        return try cursorCurrentMembers()
    }

    func assertCursorReplica(_ publication: ShadowPublication, generation: Int, expected: [String: Data]) async throws -> ShadowManifest {
        let raw = try cursorConcatenated(expected)
        try await assertReplicaBytes(publication, expected: raw)
        var first: ShadowManifest?
        for replica in replicas {
            let bytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: bytes)
            XCTAssertEqual(manifest.schemaVersion, 2)
            XCTAssertEqual(manifest.source, "cursor")
            XCTAssertEqual(manifest.locator, source.path)
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
            XCTAssertEqual(manifest.replayLayout.entrypointRelativePath, Self.cursorTranscriptRelative)
            XCTAssertNil(manifest.sessionID)
            XCTAssertNil(manifest.replayLayout.sqliteSession)
            XCTAssertEqual(Set(manifest.replayLayout.relativePaths), Set(expected.keys))
            XCTAssertEqual(manifest.replayLayout.absentRelativePaths, [])
            let files = try XCTUnwrap(manifest.replayLayout.files)
            XCTAssertFalse(files.contains { $0.relativePath.hasSuffix("-shm") || $0.relativePath.hasSuffix("-journal") })
            for member in files {
                let slice = raw.subdata(in: Int(member.byteOffset)..<Int(member.byteOffset + member.rawByteCount))
                XCTAssertEqual(slice, expected[member.relativePath])
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(slice), member.wholeSourceSHA256)
            }
            XCTAssertGreaterThan(manifest.rawByteCount, try cursorNativeSize())
            if let first { XCTAssertEqual(manifest, first) } else { first = manifest }
        }
        XCTAssertTrue((1...4).contains(generation))
        return try XCTUnwrap(first)
    }

    func assertCursorRead(_ read: WebRead, generation: Int) throws {
        let contents: [String] = [Self.firstText, Self.firstReplyText] + (generation >= 4 ? [Self.secondText] : [])
        XCTAssertEqual(read.messages.map(\.content), contents)
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant] + (generation >= 4 ? [.assistant] : []))
        XCTAssertTrue(read.messages.allSatisfy { $0.timestamp == nil && $0.usage == nil })
        let title = generation >= 3 ? Self.cursorLiveTitle : (generation == 2 ? Self.cursorWALTitle : Self.cursorStoreTitle)
        let nativeSize = try cursorNativeSize()
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, Self.cursorNativeID]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "cursor")
            XCTAssertEqual(session["cwd"] as String, fixture.project.path)
            XCTAssertEqual(session["generated_title"] as String, title)
            XCTAssertEqual(session["size_bytes"] as Int64, nativeSize)
            XCTAssertEqual(session["message_count"] as Int, contents.count)
            let term = generation >= 4 ? "aurora" : "constellation"
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT session_id) FROM sessions_fts WHERE sessions_fts MATCH ? AND session_id = ?",
                arguments: [term, read.sessionID]), 1)
            let fts = try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?",
                arguments: [read.sessionID]).joined(separator: "\n")
            XCTAssertTrue(fts.contains(generation >= 4 ? Self.secondText : Self.firstText))
        }
    }

    private func cursorCurrentMembers() throws -> [String: Data] {
        [
            Self.cursorStoreRelative: try Data(contentsOf: cursorStore),
            Self.cursorStoreRelative + "-wal": try Data(contentsOf: cursorWAL),
            Self.cursorMetaRelative: try Data(contentsOf: cursorMeta),
            Self.cursorTranscriptRelative: try Data(contentsOf: source),
        ]
    }

    private func cursorConcatenated(_ members: [String: Data]) throws -> Data {
        try members.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.reduce(into: Data()) { bytes, path in
            bytes.append(try XCTUnwrap(members[path]))
        }
    }

    private func cursorNativeSize() throws -> Int64 {
        Int64(try Data(contentsOf: cursorStore).count + Data(contentsOf: source).count)
    }

    private func cursorStoredHex(_ object: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .map { String(format: "%02x", $0) }.joined()
    }

    private func cursorJSONL(_ rows: [(role: String, text: String)]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: [
                "role": row.role,
                "message": ["content": [["type": "text", "text": row.text]]],
            ], options: [.sortedKeys]))
            data.append(10)
        }
    }

    private func chmodPrivate(_ url: URL) throws {
        guard chmod(url.path, 0o600) == 0 else { throw BinaryShadowFailure.fixture }
    }
}

private extension BinaryShadowScope {
    static let cursorLegacyComposerID = "binary-shadow-cursor-legacy"
    static let cursorLegacyTitle = "Legacy shadow title"

    var cursorLegacyRoot: URL { fixture.sources.appendingPathComponent("User/globalStorage") }
    var cursorLegacyMain: URL { cursorLegacyRoot.appendingPathComponent("state.vscdb") }
    var cursorLegacyWAL: URL { URL(fileURLWithPath: cursorLegacyMain.path + "-wal") }
    var cursorLegacyWorkspace: URL { fixture.sources.appendingPathComponent("User/workspaceStorage/owned") }

    func writeCursorLegacyComposer() throws {
        guard cursorLegacy, !FileManager.default.fileExists(atPath: cursorLegacyMain.path) else {
            throw BinaryShadowFailure.fixture
        }
        for directory in [cursorLegacyRoot, cursorLegacyWorkspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let composer = try JSONSerialization.data(withJSONObject: [
            "composerId": Self.cursorLegacyComposerID, "name": Self.cursorLegacyTitle,
            "conversation": [
                ["type": 1, "text": Self.firstText],
                ["type": 2, "text": Self.firstReplyText],
            ],
        ] as [String: Any], options: [.sortedKeys])
        let global = try DatabaseQueue(path: cursorLegacyMain.path)
        try global.write { db in
            try db.execute(sql: "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
                arguments: ["composerData:" + Self.cursorLegacyComposerID, String(decoding: composer, as: UTF8.self)])
        }
        try global.close()
        try chmodPrivate(cursorLegacyMain)
        let ownership = try DatabaseQueue(path: cursorLegacyWorkspace.appendingPathComponent("state.vscdb").path)
        try ownership.write { db in
            try db.execute(sql: "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT)")
            let value = try JSONSerialization.data(withJSONObject: [
                "allComposers": [["composerId": Self.cursorLegacyComposerID]],
            ], options: [.sortedKeys])
            try db.execute(sql: "INSERT INTO ItemTable(key, value) VALUES ('composer.composerData', ?)",
                arguments: [String(decoding: value, as: UTF8.self)])
        }
        try ownership.close()
        try chmodPrivate(cursorLegacyWorkspace.appendingPathComponent("state.vscdb"))
        try rewriteCursorLegacyOwnership(cwd: fixture.project)
    }

    func rewriteCursorLegacyOwnership(cwd: URL) throws {
        try JSONSerialization.data(withJSONObject: ["folder": cwd.absoluteString], options: [.sortedKeys])
            .write(to: cursorLegacyWorkspace.appendingPathComponent("workspace.json"))
    }

    func cursorLegacyWALBytes() throws -> Data? {
        FileManager.default.fileExists(atPath: cursorLegacyWAL.path) ? try Data(contentsOf: cursorLegacyWAL) : nil
    }

    func assertCursorLegacyFilesUnchanged(main: Data, wal: Data?) throws {
        XCTAssertEqual(try Data(contentsOf: cursorLegacyMain), main)
        if let wal {
            XCTAssertEqual(try Data(contentsOf: cursorLegacyWAL), wal)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: cursorLegacyWAL.path))
        }
    }

    func assertCursorLegacyReplica(_ publication: ShadowPublication, cwd: String) async throws -> ShadowManifest {
        var first: ShadowManifest?
        var firstRaw: Data?
        for replica in replicas {
            let manifestBytes = try await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)")
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(manifestBytes), publication.manifestSHA256)
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self, from: manifestBytes)
            XCTAssertEqual(manifest.schemaVersion, 6)
            XCTAssertEqual(manifest.source, "cursor")
            XCTAssertTrue(EngramCollectorCore.ArchiveSourceDescriptor.isCursorLegacySession(manifest))
            XCTAssertFalse(EngramCollectorCore.ArchiveSourceDescriptor.isCursorModernFileSet(manifest))
            XCTAssertEqual(manifest.replayLayout.strategy, .singleFile)
            XCTAssertEqual(manifest.replayLayout.relativePaths, ["session.cursor-legacy.json"])
            XCTAssertNil(manifest.sessionID)
            XCTAssertNil(manifest.replayLayout.sqliteSession)
            let context = try XCTUnwrap(manifest.replayLayout.cursorLegacySession)
            XCTAssertEqual(manifest.locator, context.logicalLocator)
            XCTAssertEqual(context.composerID, Self.cursorLegacyComposerID)
            XCTAssertEqual(context.cwd, cwd)
            XCTAssertEqual(context.databaseLocator, cursorLegacyMain.path)
            var raw = Data()
            for chunk in manifest.chunks {
                let bytes = try await fetch(replica, path: "v2/archive/objects/\(chunk.rawSHA256)")
                XCTAssertEqual(bytes.count, Int(chunk.rawByteCount))
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), chunk.rawSHA256)
                raw.append(bytes)
            }
            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(raw), manifest.wholeSourceSHA256)
            let body = try EngramCollectorCore.ArchiveCursorLegacySession.decodeCanonical(raw)
            XCTAssertEqual(try body.encodeCanonical(), raw)
            XCTAssertEqual(body.composerID, Self.cursorLegacyComposerID)
            XCTAssertEqual(body.cwd, cwd)
            XCTAssertEqual(body.nativePayloadByteCount, context.nativePayloadByteCount)
            XCTAssertGreaterThan(Int64(raw.count), body.nativePayloadByteCount)
            if let first {
                XCTAssertEqual(manifest, first)
                XCTAssertEqual(raw, firstRaw)
            } else {
                first = manifest
                firstRaw = raw
            }
        }
        try await assertReplicaBytes(publication, expected: try XCTUnwrap(firstRaw))
        return try XCTUnwrap(first)
    }

    func assertCursorLegacyRead(_ read: WebRead, cwd: String, nativeSize: Int64) throws {
        XCTAssertEqual(read.messages.map(\.content), [Self.firstText, Self.firstReplyText])
        XCTAssertEqual(read.messages.map(\.role), [.user, .assistant])
        XCTAssertTrue(read.messages.allSatisfy { $0.timestamp == nil && $0.usage == nil })
        try readHQ { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_identity_bindings WHERE stored_session_id = ? AND native_id = ?",
                arguments: [read.sessionID, Self.cursorLegacyComposerID]), 1)
            let session = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE id = ?", arguments: [read.sessionID]))
            XCTAssertEqual(session["source"] as String, "cursor")
            XCTAssertEqual(session["cwd"] as String, cwd)
            XCTAssertEqual(session["generated_title"] as String, Self.cursorLegacyTitle)
            XCTAssertEqual(session["size_bytes"] as Int64, nativeSize)
            XCTAssertEqual(session["message_count"] as Int, 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(DISTINCT session_id) FROM sessions_fts WHERE sessions_fts MATCH ? AND session_id = ?",
                arguments: ["constellation", read.sessionID]), 1)
            let fts = try String.fetchAll(db, sql: "SELECT content FROM sessions_fts WHERE session_id = ?",
                arguments: [read.sessionID]).joined(separator: "\n")
            XCTAssertTrue(fts.contains(Self.firstText))
            XCTAssertTrue(fts.contains(Self.firstReplyText))
        }
    }
}


final class CollectorLargeHistoryBinaryTests: XCTestCase {
    func testLargeHistoryIsByteExactOnBothReplicasAndCompleteAcrossWebPages() async throws {
        let scope = try BinaryShadowScope(binaries: ShadowBinaries.explicitEnvironment(), timeout: 240)
        var failure: Error?
        do {
            let raw = try scope.writeLargeHistory()
            XCTAssertGreaterThan(raw.count, 100 * 1024 * 1024)
            try await scope.startReplicas()
            try scope.startCollector(maxCaptureBytes: 256 * 1024 * 1024)
            let publications = try await scope.awaitDualPublications(count: 1)
            let publication = try XCTUnwrap(publications.first)
            try await scope.assertLargeReplicaBytes(publication, expected: raw)
            try scope.provisionHQ(publication, useStartupAuthority: true)
            try scope.startHQ()
            try await scope.verifyAllLargeHistoryPages(publication)
            try scope.assertLargeStoredGeneration()
            try scope.assertCollectorHasNoProductIndex()
        } catch { failure = error }
        let retain = failure != nil || (testRun?.failureCount ?? 0) > 0
        try await scope.close(retainFixture: retain)
        if retain { print("LARGE_HISTORY_RETAINED fixture=\(scope.fixture.base.path)") }
        if let failure { throw failure }
    }
}

private extension BinaryShadowScope {
    static let largeMessageCount = 10_001
    static func largeText(_ ordinal: Int) -> String {
        "large-history-\(ordinal) " + String(repeating: "x", count: 11 * 1024)
    }

    func writeLargeHistory() throws -> Data {
        var raw = try writeInitialSource()
        for ordinal in 2..<Self.largeMessageCount {
            let record: [String: Any] = ["type": "response_item", "timestamp": Self.secondTimestamp,
                "payload": ["type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": Self.largeText(ordinal)]]]]
            raw.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            raw.append(10)
        }
        try raw.write(to: source)
        return raw
    }

    func assertLargeReplicaBytes(_ publication: ShadowPublication, expected: Data) async throws {
        for replica in replicas {
            let manifest = try EngramCollectorCore.ArchiveCanonicalJSON.decode(ShadowManifest.self,
                from: await fetch(replica, path: "v2/archive/manifests/\(publication.manifestSHA256)"))
            XCTAssertEqual(manifest.wholeSourceSHA256, EngramCollectorCore.ArchiveV2Hash.sha256(expected))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var offset = 0
            for chunk in manifest.chunks {
                try checkRunning()
                var request = URLRequest(url: replica.baseURL.appendingPathComponent("v2/archive/objects/\(chunk.rawSHA256)"))
                request.setValue("Bearer \(replica.token)", forHTTPHeaderField: "Authorization")
                let (bytes, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                guard bytes.count == Int(chunk.rawByteCount), bytes.count <= 8 * 1024 * 1024,
                      offset + bytes.count <= expected.count else { throw BinaryShadowFailure.replica }
                XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(bytes), chunk.rawSHA256)
                XCTAssertTrue(bytes == expected.subdata(in: offset..<(offset + bytes.count)))
                offset += bytes.count
            }
            XCTAssertEqual(offset, expected.count)
            print("LARGE_HISTORY_REPLICA server=\(replica.id) bytes=\(offset)")
        }
    }

    func assertLargeStoredGeneration() throws {
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
        defer { try? database.close() }
        try database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE tier IN ('lite', 'normal', 'premium')"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_generations"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT normalized_storage_version FROM capture_ingest_generations"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT normalized_total_message_count FROM capture_ingest_generations"), Self.largeMessageCount)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_ingest_generation_messages"), Self.largeMessageCount)
        }
    }

    func verifyAllLargeHistoryPages(_ publication: ShadowPublication) async throws {
        let client = try EngramServiceWebReadClient(socketPath: socket, totalTimeout: 2)
        let filter = try EngramServiceWebSessionsRequest(query: Self.firstText, source: sourceKind.rawValue,
            machineId: publication.machineID, sourceInstanceId: publication.sourceInstanceID)
        let digest = try publication.sha256()
        while true {
            try checkRunning()
            if let sessions = try? await client.sessions(filter), let session = sessions.items.first,
               let response = try? await client.sessionDetail(EngramServiceWebSessionDetailRequest(sessionId: session.sessionId)),
               let detail = response.detail, detail.transcriptAvailability == .available,
               detail.lastReady?.publicationSHA256 == digest, let generation = detail.transcriptGeneration {
                XCTAssertEqual(detail.lastReady?.normalizedMessageCount, Self.largeMessageCount)
                var cursor: String?
                var ordinal = 0
                var payload = Data()
                var pages = 0
                repeat {
                    try checkRunning()
                    let page = try await client.messages(EngramServiceWebMessagesRequest(
                        sessionId: session.sessionId, generation: generation, cursor: cursor, maxFragments: 100))
                    XCTAssertFalse(page.fragments.isEmpty)
                    for fragment in page.fragments {
                        XCTAssertEqual(fragment.messageOrdinal, ordinal)
                        XCTAssertEqual(fragment.utf8Offset, payload.count)
                        payload.append(contentsOf: fragment.payloadFragment.utf8)
                        if fragment.isLastFragment {
                            XCTAssertEqual(EngramCollectorCore.ArchiveV2Hash.sha256(payload), fragment.payloadSHA256)
                            let message = try JSONDecoder().decode(EngramServiceWebNormalizedMessage.self, from: payload)
                            let expected = ordinal == 0 ? Self.firstText : ordinal == 1 ? Self.firstReplyText : Self.largeText(ordinal)
                            XCTAssertTrue(message.content == expected, "message content differs at ordinal \(ordinal)")
                            XCTAssertEqual(message.role, ordinal == 0 ? .user : .assistant)
                            payload.removeAll(keepingCapacity: true)
                            ordinal += 1
                        }
                    }
                    pages += 1
                    cursor = page.nextCursor
                    if cursor == nil { XCTAssertTrue(page.isComplete) }
                } while cursor != nil
                XCTAssertGreaterThan(pages, 1)
                XCTAssertTrue(payload.isEmpty)
                XCTAssertEqual(ordinal, Self.largeMessageCount)
                print("LARGE_HISTORY_WEB messages=\(ordinal) pages=\(pages)")
                return
            }
            if FileManager.default.fileExists(atPath: hqDatabase.path) {
                var configuration = Configuration(); configuration.readonly = true
                let db = try DatabaseQueue(path: hqDatabase.path, configuration: configuration)
                let error = try? await db.read { try String.fetchOne($0,
                    sql: "SELECT failure_code FROM capture_ingest_ledger WHERE status = 'quarantined' LIMIT 1") }
                try db.close()
                if let error { XCTFail("Large history quarantined: \(error)"); throw BinaryShadowFailure.fixture }
            }
            try await pause()
        }
    }
}
