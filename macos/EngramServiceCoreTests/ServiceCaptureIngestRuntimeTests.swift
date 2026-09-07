import Darwin
import Foundation
import GRDB
import Hummingbird
import HTTPTypes
import XCTest
import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceCaptureIngestRuntimeTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let journal = "11111111-1111-4111-8111-111111111111"
    private let logicalRoot = "/synthetic-offline-runtime/.claude/projects"
    private var root: URL!
    private var settingsURL: URL!
    private var databasePath: String!
    private var writer: EngramDatabaseWriter!
    private var gate: ServiceWriterGate!
    private var serving: Task<Void, Error>?
    private var baseURL: URL!
    private var runtimes: [ServiceCaptureIngestRuntime] = []
    private var credentialCalls = RuntimeCounter()
    private var requests = RuntimeCounter()

    override func setUpWithError() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        root = checkout.appendingPathComponent(".engram-capture-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        settingsURL = root.appendingPathComponent("settings.json")
        databasePath = root.appendingPathComponent("index.sqlite").path
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        let ownedWriter = writer!
        gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: root,
            writerFactory: { _ in ownedWriter })
        baseURL = URL(string: "http://127.0.0.1:1")!
    }

    override func tearDown() async throws {
        for runtime in runtimes {
            await runtime.stop()
            try await runtime.closeReaders()
        }
        runtimes.removeAll()
        serving?.cancel()
        _ = try? await serving?.value
        serving = nil
        gate = nil
        writer = nil
        try FileManager.default.removeItem(at: root)
    }

    func testColdOffInvalidAndNonIndexRolesDoNotAllocateOrReadCredentials() throws {
        XCTAssertNil(try makeRuntime())
        let documents: [[String: Any]] = [
            [:], ["runtimeRole": "index"], ["captureIngest": ["enabled": false]],
            settings(role: "collector"), settings(role: "replica"), settings(role: "unknown"),
            settings(role: "index", credentialID: "generic-unsupported-id"),
            settings().merging(["disabledSources": ["claude-code", 1]]) { _, new in new },
            settings().merging(["archivedDefaultOffSourcesMigrated": 1]) { _, new in new },
            settings().merging(["captureIngest": ["enabled": 1]]) { _, new in new },
        ]
        for document in documents {
            try writeSettings(document)
            XCTAssertNil(try makeRuntime())
            XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path))
            XCTAssertEqual(credentialCalls.value, 0)
            XCTAssertEqual(try count("capture_ingest_source_registry"), 0)
        }
        try Data("{invalid".utf8).write(to: settingsURL)
        XCTAssertNil(try makeRuntime())
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path))
        XCTAssertEqual(credentialCalls.value, 0)
    }

    func testUnsafeSettingsAreRejectedWithoutRepairOrAllocation() throws {
        try writeSettings(settings())
        XCTAssertEqual(chmod(settingsURL.path, 0o644), 0)
        XCTAssertNil(try makeRuntime())
        let mode = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644, "strict admission must not repair settings permissions")
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        let linkURL = root.appendingPathComponent("settings-link.json")
        XCTAssertEqual(symlink(settingsURL.path, linkURL.path), 0)
        XCTAssertNil(try makeRuntime(settings: linkURL))
        let hardURL = root.appendingPathComponent("settings-hard.json")
        XCTAssertEqual(link(settingsURL.path, hardURL.path), 0)
        XCTAssertNil(try makeRuntime())
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path))
        XCTAssertEqual(credentialCalls.value, 0)
    }

    func testPolicyPreservesArchivedDefaultsAndRequiresStrictTypedSettings() throws {
        var document = settings()
        document.removeValue(forKey: "archivedDefaultOffSourcesMigrated")
        document["disabledSources"] = ["claude-code"]
        try writeSettings(document)
        let policy = ServiceCaptureIngestRuntime.policy(at: settingsURL)
        XCTAssertEqual(policy?.parserRevision, ServiceCaptureIngestRuntime.parserRevision)
        XCTAssertEqual(policy?.enabledSources.contains(.codex), true)
        XCTAssertEqual(policy?.enabledSources.contains(.claudeCode), false)
        for raw in ["cline", "iflow", "lobsterai"] {
            XCTAssertEqual(policy?.enabledSources.contains(SourceName(rawValue: raw)!), false)
        }
        document["archivedDefaultOffSourcesMigrated"] = true
        try writeSettings(document)
        for raw in ["cline", "iflow", "lobsterai"] {
            XCTAssertEqual(ServiceCaptureIngestRuntime.policy(at: settingsURL)?.enabledSources.contains(SourceName(rawValue: raw)!), true)
        }
        // Existing missing-disabledSources semantics preserve archived defaults,
        // including a document already carrying the migration marker.
        document.removeValue(forKey: "disabledSources")
        try writeSettings(document)
        XCTAssertEqual(ServiceCaptureIngestRuntime.policy(at: settingsURL)?.enabledSources.contains(.cline), false)
        for malformed: Any in ["claude-code", ["claude-code", false], NSNull()] {
            document["disabledSources"] = malformed
            try writeSettings(document)
            XCTAssertNil(ServiceCaptureIngestRuntime.policy(at: settingsURL))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path))
        XCTAssertEqual(credentialCalls.value, 0)
    }

    func testLocalIndexAndImplicitLocalRolesAllowOnlyExplicitColdOptIn() async throws {
        for role in ["local", "index", "implicit-local"] {
            var document = settings(role: role)
            if role == "implicit-local" { document.removeValue(forKey: "runtimeRole") }
            try writeSettings(document)
            guard let runtime = try makeRuntime() else { XCTFail("valid explicit opt-in must construct a dormant runtime"); continue }
            XCTAssertEqual(credentialCalls.value, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: casRoot.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: stageRoot.path))
            await runtime.stop()
            try await runtime.closeReaders()
        }
    }

    func testValidFactoryIsDormantUntilStartAndStopPreventsResurrection() async throws {
        try await startUnavailableReplica()
        try writeSettings(settings())
        guard let runtime = try makeRuntime() else { return XCTFail("valid runtime factory is required") }
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(credentialCalls.value, 0)
        await runtime.stop()
        await runtime.start()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(credentialCalls.value, 0)
        XCTAssertEqual(try count("capture_ingest_publications"), 0)
        _ = try await gate.performWriteCommand(name: "afterColdRuntimeStop") { _ in true }
    }

    func testIndependentLoopsReachRealWebReadinessWhileReplicaKeepsReturning503() async throws {
        try await startUnavailableReplica()
        try writeSettings(settings())
        _ = try seedPending(sequence: 1, nativeID: "runtime-ready")
        try seedLegacySentinel()
        guard let runtime = try makeRuntime() else { return XCTFail("valid runtime factory is required") }
        XCTAssertEqual(credentialCalls.value, 0)
        XCTAssertEqual(try readyCount(), 0)
        await runtime.start()
        await runtime.start() // Idempotent start cannot create duplicate loops.
        guard try await waitForReady(1) else { return XCTFail("independent replay and FTS must progress despite perpetual intake 503") }
        let intakeStarted = try await waitUntil { self.requests.value > 0 }
        XCTAssertTrue(intakeStarted, "real intake loop must also have started")
        XCTAssertGreaterThan(credentialCalls.value, 0)
        try await assertVisible(runtime, query: "runtime-ready")
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT status FROM session_index_jobs WHERE id = 'legacy-sentinel:1:h:fts'") }, "pending")
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT retry_count FROM session_index_jobs WHERE id = 'legacy-sentinel:1:h:fts'") }, 0)
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT status FROM session_index_jobs WHERE id = 'legacy-sentinel:embedding'") }, "pending")
        XCTAssertEqual(try count("insights"), 0)
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT approved_epoch FROM capture_ingest_source_registry") }, epoch)
    }

    func testMissingCredentialDoesNotStarveAlreadyAcceptedReplayAndReadiness() async throws {
        try await startUnavailableReplica()
        try writeSettings(settings())
        _ = try seedPending(sequence: 1, nativeID: "missing-credential-ready")
        guard let runtime = try makeRuntime(missingCredential: true) else { return XCTFail("factory must not require a live credential lookup") }
        XCTAssertEqual(credentialCalls.value, 0)
        await runtime.start()
        guard try await waitForReady(1) else { return XCTFail("missing intake credential must not gate persisted work") }
        XCTAssertGreaterThan(credentialCalls.value, 0)
        XCTAssertEqual(requests.value, 0)
        try await assertVisible(runtime, query: "missing-credential-ready")
    }

    func testFreshSourceRoleAndInvalidSettingsRevokeInstalledWebReaders() async throws {
        try await startUnavailableReplica()
        let valid = settings()
        try writeSettings(valid)
        _ = try seedPending(sequence: 1, nativeID: "runtime-revocation")
        guard let runtime = try makeRuntime() else { return XCTFail("valid runtime factory is required") }
        await runtime.start()
        guard try await waitForReady(1) else { return XCTFail("positive ready baseline required before revocation") }
        let identity = try await assertVisible(runtime, query: "runtime-revocation")
        for invalid in [valid.merging(["disabledSources": ["claude-code"]]) { _, new in new },
                        valid.merging(["disabledSources": [true]]) { _, new in new },
                        valid.merging(["runtimeRole": "collector"]) { _, new in new },
                        valid.merging(["captureIngest": ["enabled": false]]) { _, new in new }] {
            try writeSettings(invalid)
            await assertNotVisible(runtime, identity: identity)
            try writeSettings(valid)
            _ = try await assertVisible(runtime, query: "runtime-revocation")
        }
        XCTAssertEqual(chmod(settingsURL.path, 0o644), 0)
        await assertNotVisible(runtime, identity: identity)
        let mode = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
        XCTAssertEqual(try readyCount(), 1, "policy revocation must not destroy last-good data")
    }

    func testStoppedRuntimeJoinsKeepsReadersUntilCloseAndFreshInstanceResumes() async throws {
        try await startUnavailableReplica()
        try writeSettings(settings())
        _ = try seedPending(sequence: 1, nativeID: "runtime-first")
        guard let runtime = try makeRuntime() else { return XCTFail("valid runtime factory is required") }
        await runtime.start()
        guard try await waitForReady(1) else { return XCTFail("ready baseline required") }
        let identity = try await assertVisible(runtime, query: "runtime-first")
        await runtime.stop()
        await runtime.stop()
        let requestsAfterStop = requests.value
        let tokensAfterStop = credentialCalls.value
        await runtime.start()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(requests.value, requestsAfterStop)
        XCTAssertEqual(credentialCalls.value, tokensAfterStop)
        _ = try await gate.performWriteCommand(name: "afterRuntimeJoin") { _ in true }
        _ = try await assertVisible(runtime, query: "runtime-first")
        // This is the caller's separate post-handler-drain phase; stop must not
        // close readers while existing handlers may still use them.
        try await runtime.closeReaders()
        try await runtime.closeReaders()
        await assertNotVisible(runtime, identity: identity)
        _ = try seedPending(sequence: 2, nativeID: "runtime-second")
        guard let restarted = try makeRuntime() else { return XCTFail("fresh runtime must restart from persisted work") }
        await restarted.start()
        guard try await waitForReady(2) else { return XCTFail("restart must finish only the new pending capture") }
        _ = try await assertVisible(restarted, query: "runtime-second")
        XCTAssertEqual(try count("capture_ingest_generations"), 2)
        XCTAssertEqual(try count("capture_ingest_publications"), 2)
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
    }

    func testRuntimeNeverProvisionsUnknownSourcesOrApprovesNewEpochs() async throws {
        try await startUnavailableReplica()
        try writeSettings(settings())
        _ = try seedPending(sequence: 1, nativeID: "unknown-source",
            sourceInstance: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD", provision: false)
        _ = try seedPending(sequence: 2, nativeID: "unknown-epoch",
            collectorEpoch: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")
        guard let runtime = try makeRuntime() else { return XCTFail("valid runtime factory is required") }
        await runtime.start()
        let intakeStarted = try await waitUntil { self.requests.value > 0 }
        XCTAssertTrue(intakeStarted)
        try await Task.sleep(for: .milliseconds(500))
        await runtime.stop()
        XCTAssertEqual(try count("capture_ingest_source_registry"), 1)
        XCTAssertEqual(try writer.read { try String.fetchOne($0, sql: "SELECT approved_epoch FROM capture_ingest_source_registry") }, epoch)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_ingest_ledger WHERE status = 'pending' AND attempt_count = 0") }, 2)
        XCTAssertEqual(try count("capture_ingest_generations"), 0)
    }

    func testRealRunnerStartsCaptureIngestServesWebIPCAndReleasesResourcesOnCancellation() async throws {
        // Native startup has some process-home fallbacks. Merely passing a
        // dictionary to run() is not sufficient isolation for this integration.
        let processEnvironment = ProcessInfo.processInfo.environment
        let expectedHome = try XCTUnwrap(processEnvironment["ENGRAM_DEMO_EXPECTED_HOME"],
            "launch this integration with an explicitly isolated process home")
        let fixedHome = try XCTUnwrap(processEnvironment["CFFIXED_USER_HOME"])
        XCTAssertEqual(fixedHome, expectedHome)
        XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser.path, expectedHome)
        let checkout = root.deletingLastPathComponent().path
        guard fixedHome == expectedHome,
              FileManager.default.homeDirectoryForCurrentUser.path == expectedHome,
              expectedHome.hasPrefix(checkout + "/.engram-demo-test-home.") else {
            return XCTFail("Runner integration requires the authorized checkout-local isolated home")
        }
        try await startUnavailableReplica()
        var document = settings()
        document["remoteOffloadEnabled"] = false
        document["livePublishEnabled"] = false
        document["liveIngestEnabled"] = false
        document["titleProvider"] = "native"
        try writeSettings(document)
        _ = try seedPending(sequence: 1, nativeID: "real-runner-ready")
        XCTAssertEqual(try readyCount(), 0)
        XCTAssertEqual(credentialCalls.value, 0)
        // Both references own the seed writer; drop both before the real Runner
        // obtains its own database-adjacent writer lock and writer pool.
        gate = nil
        writer = nil

        let socketRoot = URL(fileURLWithPath: "/tmp/eg-cir-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = socketRoot.appendingPathComponent("service.sock").path
        let path = databasePath!
        let environment = [
            "HOME": root.path,
            "CFFIXED_USER_HOME": root.path,
            "XCTestConfigurationFilePath": "/tmp/synthetic-capture-runner.xctestconfiguration",
            "ENGRAM_SETTINGS_PATH": settingsURL.path,
            "ENGRAM_RUNTIME_AI_SECRETS_PATH": root.appendingPathComponent("absent-ai-secrets.json").path,
            "ENGRAM_REMOTE_OFFLOAD_ENABLED": "false",
            "ENGRAM_LIVE_PUBLISH_ENABLED": "false",
            "ENGRAM_LIVE_INGEST_ENABLED": "false",
            // This disables physical legacy adapters only. The strict capture
            // runtime independently reads disabledSources from our settings.
            "ENGRAM_DISABLED_SOURCES": SourceName.allCases.map(\.rawValue).joined(separator: ","),
            "ENGRAM_USAGE_TOKEN_LIMITS": "{}",
        ]
        let calls = credentialCalls
        let runner = Task {
            try await EngramServiceRunner.run(arguments: ["--service-socket", socket, "--database-path", path],
                environment: environment, testHooks: .init(optionalAIMaintenance: { _ in },
                    captureIngestCredentialLoader: { identifier in
                        XCTAssertEqual(identifier, "hq")
                        calls.increment()
                        return "synthetic-runtime-bearer"
                    }))
        }
        func exchange(_ command: String, payload: Data) async throws -> Data? {
            let request = EngramServiceRequestEnvelope(command: command, payload: payload)
            let bytes = try await EngramServiceSocketIO.exchange(JSONEncoder().encode(request),
                socketPath: socket, totalTimeout: 0.5)
            let response = try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: bytes)
            XCTAssertEqual(response.requestId, request.requestId)
            if case .success(_, let result, _) = response { return result }
            return nil
        }
        var failure: Error?
        do {
            let sessionRequest = try JSONEncoder().encode(EngramServiceWebSessionsRequest(query: "constellation real-runner-ready"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            var visible: EngramServiceWebSessionsResponse?
            while ContinuousClock.now < deadline {
                if let bytes = try? await exchange("webSessions", payload: sessionRequest),
                   let page = try? JSONDecoder().decode(EngramServiceWebSessionsResponse.self, from: bytes),
                   !page.items.isEmpty {
                    visible = page
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let page = try XCTUnwrap(visible, "actual Runner must start replay/FTS and install the real Web handler")
            XCTAssertEqual(page.items.count, 1)
            let id = try XCTUnwrap(page.items.first?.sessionId)
            let detailResult = try await exchange("webSessionDetail", payload: JSONEncoder().encode(
                EngramServiceWebSessionDetailRequest(sessionId: id)))
            let detail = try JSONDecoder().decode(EngramServiceWebSessionDetailResponse.self,
                from: XCTUnwrap(detailResult))
            XCTAssertEqual(detail.detail?.transcriptAvailability, .available)
            let generation = try XCTUnwrap(detail.detail?.transcriptGeneration)
            let messagesResult = try await exchange("webMessages", payload: JSONEncoder().encode(
                EngramServiceWebMessagesRequest(sessionId: id, generation: generation)))
            let messages = try JSONDecoder().decode(EngramServiceWebMessagesResponse.self,
                from: XCTUnwrap(messagesResult))
            XCTAssertEqual(messages.sessionId, id)
            XCTAssertEqual(messages.generation, generation)
            XCTAssertEqual(messages.fragments.count, 2)
            XCTAssertTrue(messages.fragments.contains { $0.payloadFragment.contains("real-runner-ready") })
            let intakeStarted = try await waitUntil { self.requests.value > 0 }
            XCTAssertTrue(intakeStarted, "the actual Runner must also start bounded HTTP intake")
            XCTAssertGreaterThan(calls.value, 0)
        } catch { failure = error }

        // Cleanup is awaited even when a RED assertion throws. No shutdown IPC
        // command is used: that command intentionally signals the host process.
        runner.cancel()
        do { try await runner.value }
        catch is CancellationError { /* A cooperative cancellation is acceptable. */ }
        catch { if failure == nil { failure = error } }
        let stoppedRequests = requests.value
        let stoppedCredentials = calls.value
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(requests.value, stoppedRequests)
        XCTAssertEqual(calls.value, stoppedCredentials)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
        XCTAssertNoThrow(try ServiceWriterGate(databasePath: path, runtimeDirectory: socketRoot,
            acquireRuntimeLock: false), "Runner must join its workers and release the database writer lock")
        if let failure { throw failure }
    }

    func testThrowingBackendFactoriesPrecedeCaptureRuntimeAndAnyStartedServiceWork() throws {
        // Structural RED is intentional: executing the broken startup failure
        // path would strand unstructured runtime tasks with no cancellation owner.
        let sourceURL = root.deletingLastPathComponent()
            .appendingPathComponent("macos/EngramService/Core/EngramServiceRunner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "let runtimeHome = RemoteSyncConfig.homeDirectory(environment: environment)")).lowerBound
        let end = try XCTUnwrap(source.range(of: "static func cancelAndAwaitCheckpointTask", range: start..<source.endIndex)).lowerBound
        let body = String(source[start..<end])
        for factory in ["let remoteSync = try RemoteSyncCoordinator.makeIfEnabled(",
                        "let liveSync = try RemoteSyncCoordinator.makeLiveIfEnabled("] {
            let construction = try XCTUnwrap(body.range(of: factory)).lowerBound
            for admission in ["let captureIngestRuntime = try ServiceCaptureIngestRuntime.make(",
                              "await captureIngestRuntime?.start()", "try server.start()",
                              "let initialScanTask = Task {"] {
                let admitted = try XCTUnwrap(body.range(of: admission)).lowerBound
                XCTAssertLessThan(construction, admitted,
                    "\(factory) must finish before \(admission) can allocate readers or start unstructured work")
            }
        }
    }

    func testBadLocalBackendFailsBeforeCaptureStartupWithoutLeavingOwnedWork() async throws {
        // Functional GREEN only: never intentionally execute the known leaking
        // candidate. The separate source-order test records its structural RED.
        let sourceURL = root.deletingLastPathComponent()
            .appendingPathComponent("macos/EngramService/Core/EngramServiceRunner.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let runtimeMake = try XCTUnwrap(source.range(of: "let captureIngestRuntime = try ServiceCaptureIngestRuntime.make(")).lowerBound
        for factory in ["let remoteSync = try RemoteSyncCoordinator.makeIfEnabled(",
                        "let liveSync = try RemoteSyncCoordinator.makeLiveIfEnabled("] {
            guard let position = source.range(of: factory)?.lowerBound, position < runtimeMake else {
                throw XCTSkip("Run this functional fixture only after rebuilding the structural-order GREEN candidate")
            }
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        let expectedHome = try XCTUnwrap(processEnvironment["ENGRAM_DEMO_EXPECTED_HOME"])
        let fixedHome = try XCTUnwrap(processEnvironment["CFFIXED_USER_HOME"])
        XCTAssertEqual(fixedHome, expectedHome)
        XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser.path, expectedHome)
        guard fixedHome == expectedHome,
              FileManager.default.homeDirectoryForCurrentUser.path == expectedHome,
              expectedHome.hasPrefix(root.deletingLastPathComponent().path + "/.engram-demo-test-home.") else {
            return XCTFail("Runner failure integration requires the authorized isolated process home")
        }
        try await startUnavailableReplica()
        try writeSettings(settings())
        let badStore = root.appendingPathComponent("not-a-directory")
        let sentinel = Data("synthetic local backend obstruction".utf8)
        try sentinel.write(to: badStore)
        XCTAssertEqual(chmod(badStore.path, 0o600), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path))
        gate = nil
        writer = nil

        let socketRoot = URL(fileURLWithPath: "/tmp/eg-cif-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = socketRoot.appendingPathComponent("service.sock").path
        let path = databasePath!
        let calls = credentialCalls
        let optionalWork = RuntimeCounter()
        for enableOffload in [true, false] {
            // Exercise each throwing factory independently. The second pass
            // arms only legacy live publication, still using a local fixture
            // backend: no HTTP backend, credential lookup or real peer exists.
            let environment = [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "XCTestConfigurationFilePath": "/tmp/synthetic-capture-runner-failure.xctestconfiguration",
                "ENGRAM_SETTINGS_PATH": settingsURL.path,
                "ENGRAM_RUNTIME_AI_SECRETS_PATH": root.appendingPathComponent("absent-ai-secrets.json").path,
                "ENGRAM_REMOTE_OFFLOAD_ENABLED": enableOffload ? "true" : "false",
                "ENGRAM_REMOTE_OFFLOAD_BACKEND": "local",
                "ENGRAM_REMOTE_OFFLOAD_STORE": badStore.path,
                "ENGRAM_REMOTE_OFFLOAD_PEER": "synthetic-local-failure-peer",
                "ENGRAM_LIVE_PUBLISH_ENABLED": enableOffload ? "false" : "true",
                "ENGRAM_LIVE_INGEST_ENABLED": "false",
                "ENGRAM_DISABLED_SOURCES": SourceName.allCases.map(\.rawValue).joined(separator: ","),
                "ENGRAM_USAGE_TOKEN_LIMITS": "{}",
            ]
            let runner = Task {
                try await EngramServiceRunner.run(arguments: ["--service-socket", socket, "--database-path", path],
                    environment: environment, testHooks: .init(optionalAIMaintenance: { _ in optionalWork.increment() },
                        captureIngestCredentialLoader: { identifier in
                            XCTAssertEqual(identifier, "hq")
                            calls.increment()
                            return "synthetic-runtime-bearer"
                        }))
            }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                runner.cancel()
            }
            let result = await runner.result
            timeout.cancel()
            await timeout.value
            switch result {
            case .success:
                XCTFail("a regular file cannot serve as a local backend directory")
            case .failure(let error):
                let failure = error as NSError
                XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
                XCTAssertEqual(failure.code, CocoaError.fileWriteFileExists.rawValue)
            }
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(calls.value, 0, "failing backend construction must precede capture credentials")
            XCTAssertEqual(requests.value, 0, "no capture HTTP task may survive failed startup")
            XCTAssertEqual(optionalWork.value, 0, "no optional startup task may begin")
            XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
            XCTAssertFalse(FileManager.default.fileExists(atPath: captureRoot.path), "even dormant capture storage must not be allocated")
            XCTAssertEqual(try Data(contentsOf: badStore), sentinel)
            XCTAssertNoThrow(try ServiceWriterGate(databasePath: path, runtimeDirectory: socketRoot,
                acquireRuntimeLock: false), "failed startup must release its writer gate before returning")
        }
    }

    private var captureRoot: URL { root.appendingPathComponent("capture-ingest") }
    private var casRoot: URL { captureRoot.appendingPathComponent("cas") }
    private var stageRoot: URL { captureRoot.appendingPathComponent("stage") }

    private func makeRuntime(settings: URL? = nil, missingCredential: Bool = false) throws -> ServiceCaptureIngestRuntime? {
        let calls = credentialCalls
        let runtime = try ServiceCaptureIngestRuntime.make(gate: gate, databasePath: databasePath,
            settingsURL: settings ?? settingsURL, credentialLoader: { identifier in
                XCTAssertEqual(identifier, "hq", "runtime must pass an explicit ArchiveCredentialStore account id")
                calls.increment()
                return missingCredential ? nil : "synthetic-runtime-bearer"
            })
        if let runtime { runtimes.append(runtime) }
        return runtime
    }

    private func settings(role: String = "index", credentialID: String = "hq") -> [String: Any] {
        ["runtimeRole": role, "disabledSources": [], "archivedDefaultOffSourcesMigrated": true,
         "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": baseURL.absoluteString,
             "credentialID": credentialID, "requestTimeout": 0.2, "retryCount": 0]]
    }

    private func writeSettings(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
    }

    private func startUnavailableReplica() async throws {
        let router = Router()
        let requests = requests
        router.get("/v2/archive/publication-capabilities") { request, _ in
            XCTAssertEqual(request.headers[.authorization], "Bearer synthetic-runtime-bearer")
            requests.increment()
            return Response(status: .serviceUnavailable)
        }
        let bound = expectation(description: "runtime fixture replica bound")
        let port = RuntimePort()
        let app = Application(router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in
                if let value = channel.localAddress?.port { port.set(value); bound.fulfill() }
            })
        serving = Task { try await app.run() }
        await fulfillment(of: [bound], timeout: 5)
        baseURL = URL(string: "http://127.0.0.1:\(try XCTUnwrap(port.value))")!
    }

    @discardableResult
    private func seedPending(sequence: Int64, nativeID: String, sourceInstance: String? = nil,
                             collectorEpoch: String? = nil, provision: Bool = true) throws -> String {
        if !FileManager.default.fileExists(atPath: captureRoot.path) {
            try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let raw = try transcript(nativeID: nativeID)
        let rawSHA = ArchiveV2Hash.sha256(raw)
        _ = try cas.publishObject(raw: raw, expectedSHA256: rawSHA)
        let relative = "runtime/\(nativeID).jsonl"
        let manifest = try ArchiveSourceManifest(captureID: ArchiveV2Hash.sha256(Data("runtime-\(sequence)".utf8)),
            machineID: machine, source: "claude-code", locator: logicalRoot + "/" + relative,
            sessionID: nil, capturedAt: "2026-09-06T00:00:00Z",
            generation: .init(device: 1, inode: sequence, size: Int64(raw.count), mtimeNs: 3, ctimeNs: 4, mode: 0o100600),
            wholeSourceSHA256: rawSHA, rawByteCount: Int64(raw.count),
            chunks: [try .init(ordinal: 0, rawSHA256: rawSHA, rawByteCount: Int64(raw.count))],
            replayLayout: .init(strategy: .singleFile, relativePaths: [relative]))
        let bytes = try ArchiveCanonicalJSON.encode(manifest)
        let digest = ArchiveV2Hash.sha256(bytes)
        _ = try cas.publishManifest(bytes, expectedSHA256: digest)
        let publication = try CollectorPublicationEnvelope(machineID: machine, sourceInstanceID: sourceInstance ?? instance,
            collectorEpoch: collectorEpoch ?? epoch, sequence: sequence, manifestSHA256: digest)
        let publicationSHA = try publication.sha256()
        let ack = try CollectorPublicationACK(serverID: "hq", journalID: journal, arrivalOrdinal: sequence,
            publicationSHA256: publicationSHA, manifestSHA256: digest, storedAt: "2026-09-06T00:00:00.000Z")
        let page = try CollectorPublicationPage(items: [try .init(publication: publication, ack: ack)],
            afterCursor: CollectorPublicationCursor(journalID: journal, afterArrivalOrdinal: sequence).encoded(), hasMore: false)
        try writer.write { db in
            if provision, try CaptureIngestSourceRegistry.binding(db, machineID: machine, sourceInstanceID: instance) == nil {
                _ = try CaptureIngestSourceRegistry.provision(db, machineID: machine, sourceInstanceID: instance,
                    source: .claudeCode, parseFormat: .claudeDefault, configuredRoot: logicalRoot, initialEpoch: epoch)
            }
            try CaptureIngestLedger.accept(db, page: page, requestedCursor: CaptureIngestLedger.checkpoint(db, serverID: "hq"),
                serverID: "hq", parserRevision: ServiceCaptureIngestRuntime.parserRevision)
        }
        return publicationSHA
    }

    private func seedLegacySentinel() throws {
        let path = root.appendingPathComponent("legacy-sentinel.jsonl")
        try transcript(nativeID: "legacy-sentinel").write(to: path)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO sessions(id, source, start_time, file_path, source_locator, authoritative_node, sync_version, snapshot_hash, tier)
                VALUES ('legacy-sentinel', 'claude-code', '2026-09-06T00:00:00Z', ?, ?, 'local', 1, 'h', 'normal')
                """, arguments: [path.path, path.path])
            for kind in ["fts", "embedding"] {
                let id = kind == "fts" ? "legacy-sentinel:1:h:fts" : "legacy-sentinel:embedding"
                try db.execute(sql: "INSERT INTO session_index_jobs(id, session_id, job_kind, target_sync_version, status) VALUES (?, 'legacy-sentinel', ?, 1, 'pending')", arguments: [id, kind])
            }
        }
    }

    private func transcript(nativeID: String) throws -> Data {
        let common: [String: Any] = ["sessionId": nativeID, "cwd": "/synthetic/runtime-project", "timestamp": "2026-09-06T00:00:00Z"]
        let records: [[String: Any]] = [
            common.merging(["type": "user", "message": ["content": "Explain constellation \(nativeID) through the captured runtime."]]) { _, new in new },
            common.merging(["type": "assistant", "message": ["model": "synthetic-model", "content": [["type": "text", "text": "The constellation \(nativeID) remains searchable without a working replica or AI provider."]]]]) { _, new in new },
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        return data
    }

    @discardableResult
    private func assertVisible(_ runtime: ServiceCaptureIngestRuntime, query: String) async throws -> (sessionID: String, generation: String) {
        let page = try await runtime.metadataProducer.sessions(try .init(query: "constellation " + query),
            requestId: UUID().uuidString, deadline: .now.advanced(by: .seconds(2)))
        XCTAssertEqual(page.items.count, 1, "the actual FTS-backed Web reader must find the capture")
        let id = try XCTUnwrap(page.items.first?.sessionId)
        let handler = EngramServiceCommandHandler(writerGate: gate,
            webTranscriptSnapshotProvider: runtime.transcriptProvider, webMetadataProducer: runtime.metadataProducer)
        func request(_ command: String, payload: Data) async throws -> Data {
            let response = await handler.handle(.init(command: command, payload: payload))
            let bytes: Data?
            if case .success(_, let result, _) = response { bytes = result } else { bytes = nil }
            return try XCTUnwrap(bytes, "the real Web command handler must successfully serve \(command)")
        }
        // The handler composes metadata with normalized transcript authority;
        // the metadata producer alone deliberately does not advertise it.
        let detail = try JSONDecoder().decode(EngramServiceWebSessionDetailResponse.self,
            from: await request("webSessionDetail", payload: JSONEncoder().encode(
                EngramServiceWebSessionDetailRequest(sessionId: id))))
        let generation = try XCTUnwrap(detail.detail?.transcriptGeneration)
        let messages = try JSONDecoder().decode(EngramServiceWebMessagesResponse.self,
            from: await request("webMessages", payload: JSONEncoder().encode(
                EngramServiceWebMessagesRequest(sessionId: id, generation: generation))))
        XCTAssertEqual(messages.sessionId, id)
        XCTAssertEqual(messages.generation, generation)
        XCTAssertEqual(messages.fragments.count, 2)
        XCTAssertTrue(messages.fragments.contains { $0.payloadFragment.contains(query) })
        let snapshot = try await runtime.transcriptProvider.snapshot(sessionID: id, generation: generation,
            deadline: .now.advanced(by: .seconds(2)))
        XCTAssertEqual(snapshot?.messages.count, 2)
        XCTAssertTrue(snapshot?.messages.contains { $0.content.contains(query) } == true)
        XCTAssertEqual(try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM capture_ingest_generations g JOIN session_index_jobs j ON j.id = g.required_fts_job_id
                WHERE g.generation_id = ? AND j.job_kind = 'fts' AND j.status = 'completed'
                """, arguments: [generation])
        }, 1)
        return (id, generation)
    }

    private func assertNotVisible(_ runtime: ServiceCaptureIngestRuntime, identity: (sessionID: String, generation: String)) async {
        do {
            let page = try await runtime.metadataProducer.sessions(try .init(query: "constellation"),
                requestId: UUID().uuidString, deadline: .now.advanced(by: .seconds(2)))
            XCTAssertFalse(page.items.contains { $0.sessionId == identity.sessionID })
        } catch { /* Closed or revoked readers may return unavailable. */ }
        do {
            let snapshot = try await runtime.transcriptProvider.snapshot(sessionID: identity.sessionID,
                generation: identity.generation, deadline: .now.advanced(by: .seconds(2)))
            XCTAssertNil(snapshot)
        } catch { /* Closed or revoked readers may return unavailable. */ }
    }

    private func count(_ table: String) throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    private func readyCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_ingest_ledger WHERE status = 'index_ready'")! }
    }

    private func waitForReady(_ count: Int) async throws -> Bool { try await waitUntil { try self.readyCount() == count } }

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < end {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try condition()
    }
}

private final class RuntimeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); defer { lock.unlock() }; stored += 1 }
}
private final class RuntimePort: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Int) { lock.lock(); defer { lock.unlock() }; stored = value }
}
