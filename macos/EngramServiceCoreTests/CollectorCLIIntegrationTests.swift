import CoreFoundation
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import EngramCollectorCore

/// Real executable boundaries only. An absent explicit binary opts out before
/// any fixture, listener, credential file, or process is created. The existing
/// RuntimeFixture owns all databases; this file never provisions a second copy.
final class CollectorCLIIntegrationTests: XCTestCase {
    func testColdOnceRunsOneBoundedCycleReportsActualCountsAndReleasesOwner() async throws {
        try await withFixture { scope in
            let replicas = try await scope.startReplicas()
            for index in 0..<8 {
                try scope.fixture.writeTranscript("CLI once \(index)", name: "rollout-\(index).jsonl")
            }
            try scope.fixture.writeSettings(scope.fixture.document(replicas: replicas))
            try scope.writeCredentials(scope.validCredentials)
            let child = try scope.launch(once: true)
            let result = try await child.waitForExit(seconds: 5)
            XCTAssertEqual(result.reason, .exit)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stderr, "")
            scope.assertNoPrivateOutput(result)

            let rows = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(rows.count, 2, "one JSON line followed by one newline")
            XCTAssertEqual(rows.last, "")
            let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            let names: Set<String> = ["scannedEntries", "captured", "recovered", "acknowledgedHQ", "acknowledgedM1", "deferred"]
            XCTAssertEqual(Set(values.keys), names.union(["diskAdmission"]))
            var counts: [String: Int] = [:]
            for name in names {
                let number = try XCTUnwrap(values[name] as? NSNumber)
                XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID(), name)
                let integer = try XCTUnwrap(values[name] as? Int)
                XCTAssertGreaterThanOrEqual(integer, 0, name)
                counts[name] = integer
            }
            XCTAssertGreaterThan(try XCTUnwrap(counts["scannedEntries"]), 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(counts["scannedEntries"]), 2)
            XCTAssertLessThanOrEqual(try XCTUnwrap(counts["captured"]), 2)
            XCTAssertEqual(counts["recovered"], 0)
            let captured = try scope.fixture.integer("SELECT count(*) FROM collector_publications")
            let hqACKs = try scope.fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'")
            let m1ACKs = try scope.fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'")
            let hqCount = try await replicas.hq.count()
            let m1Count = try await replicas.m1.count()
            XCTAssertEqual(counts["captured"], captured)
            XCTAssertEqual(counts["acknowledgedHQ"], hqACKs)
            XCTAssertEqual(counts["acknowledgedM1"], m1ACKs)
            XCTAssertEqual(hqCount, hqACKs)
            XCTAssertEqual(m1Count, m1ACKs)
            // A bounded cycle must not silently drain this eight-file bootstrap.
            let locatorCount = try scope.fixture.integer("SELECT count(*) FROM collector_locators")
            XCTAssertGreaterThan(locatorCount, 0)
            XCTAssertLessThan(locatorCount, 8)
            try scope.assertOwnerCanBeReacquired()
            try scope.fixture.assertNoProductIndex()
        }
    }

    func testOnceInventoryPressureReportsObservedInventoryAndUnevaluatedCaptureVolume() async throws {
        try await onceDiskAdmission(.inventoryPressure)
    }

    func testOnceSuccessfulCaptureReportsBothActualDiskAdmissionSamples() async throws {
        try await onceDiskAdmission(.captured)
    }

    func testOnceByteBudgetShortCircuitReportsOnlyNotEvaluatedDiskAdmission() async throws {
        try await onceDiskAdmission(.byteBudget)
    }

    func testResidentPublishesTwoGenerationsToBothReplicasAndTERMJoinsBeforeReopen() async throws {
        try await residentLifecycle(signal: SIGTERM)
    }

    func testResidentPublishesTwoGenerationsToBothReplicasAndINTJoinsBeforeReopen() async throws {
        try await residentLifecycle(signal: SIGINT)
    }

    func testResidentPublishesTwoGenerationsToBothReplicasAndHUPJoinsBeforeReopen() async throws {
        try await residentLifecycle(signal: SIGHUP)
    }

    func testEnabledMissingCredentialsFileRejectsBeforeAnyConnectionAndReleasesOwner() async throws {
        try await credentialsRejected(.missingFile)
    }

    func testEnabledMissingCredentialReferenceRejectsBeforeAnyConnectionAndReleasesOwner() async throws {
        try await credentialsRejected(.missingReference)
    }

    func testEnabledNonStringCredentialRejectsBeforeAnyConnectionAndReleasesOwner() async throws {
        try await credentialsRejected(.nonString)
    }

    func testEnabledEmptyCredentialRejectsBeforeAnyConnectionAndReleasesOwner() async throws {
        try await credentialsRejected(.empty)
    }

    func testEnabledIdenticalReplicaTokensRejectBeforeAnyConnectionAndReleaseOwner() async throws {
        try await credentialsRejected(.sameTokens)
    }

    func testEnabledUnsafeCredentialPermissionsRejectWithoutRepairOrConnection() async throws {
        try await credentialsRejected(.unsafePermissions)
    }

    func testEnabledCredentialLeafSymlinkRejectsWithoutConnectionOrTargetMutation() async throws {
        try await credentialsRejected(.leafSymlink)
    }

    func testEnabledCredentialAncestorSymlinkRejectsWithoutConnectionOrTargetMutation() async throws {
        try await credentialsRejected(.ancestorSymlink)
    }

    private enum OnceDiskCase: Equatable { case inventoryPressure, captured, byteBudget }

    private func onceDiskAdmission(_ scenario: OnceDiskCase) async throws {
        try await withFixture { scope in
            let replicas = try await scope.startReplicas()
            try scope.fixture.writeTranscript("CLI disk admission must describe an actual bounded capture attempt")
            let source = scope.fixture.sources.appendingPathComponent("rollout-one.jsonl")
            let sourceBytes = try Data(contentsOf: source)
            XCTAssertGreaterThan(sourceBytes.count, 1, "the one-byte budget must reject this real source")
            let threshold: Int64 = scenario == .inventoryPressure ? Int64.max : 0
            var document = scope.fixture.document(replicas: replicas)
            var collector = try XCTUnwrap(document["collector"] as? [String: Any])
            var budgets = try XCTUnwrap(collector["budgets"] as? [String: Any])
            // One file and one directory reach EOF within this single step;
            // observing no admission must not be an unfinished-bootstrap result.
            budgets["maxEntriesVisited"] = 16
            budgets["maxCandidateFiles"] = 16
            budgets["maxDirectoryOpens"] = 4
            budgets["maxMetadataBytes"] = 32_768
            budgets["minimumFreeDiskBytes"] = threshold
            if scenario == .byteBudget { budgets["maxCaptureBytes"] = 1 }
            collector["budgets"] = budgets
            document["collector"] = collector
            try scope.fixture.writeSettings(document)
            try scope.writeCredentials(scope.validCredentials)
            let child = try scope.launch(once: true)
            let result = try await child.waitForExit(seconds: 5)
            XCTAssertEqual(result.reason, .exit)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stderr, "")
            scope.assertNoPrivateOutput(result)
            let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(lines.last, "")
            let values = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            let countNames: Set<String> = ["scannedEntries", "captured", "recovered", "acknowledgedHQ", "acknowledgedM1", "deferred"]
            XCTAssertEqual(Set(values.keys), countNames.union(["diskAdmission"]))
            var counts: [String: Int64] = [:]
            for name in countNames { counts[name] = try self.nonnegativeJSONInteger(values[name]) }
            XCTAssertGreaterThan(try XCTUnwrap(counts["scannedEntries"]), 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(counts["scannedEntries"]), 16)
            XCTAssertEqual(try scope.fixture.integer("SELECT count(*) FROM collector_locators"), 1)
            XCTAssertEqual(try scope.fixture.integer("SELECT count(*) FROM collector_roots WHERE root_id = 'runtime-codex' AND active_scan_id IS NULL AND completed_revision >= requested_revision"), 1,
                "the actual once call must finish the single-file bootstrap")
            let expected: Int64 = scenario == .captured ? 1 : 0
            XCTAssertEqual(counts["captured"], expected)
            XCTAssertEqual(counts["recovered"], 0)
            XCTAssertEqual(counts["acknowledgedHQ"], expected)
            XCTAssertEqual(counts["acknowledgedM1"], expected)
            let actualPublications = try scope.fixture.integer("SELECT count(*) FROM collector_publications")
            let actualHQACKs = try scope.fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'")
            let actualM1ACKs = try scope.fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'")
            let hqCount = try await replicas.hq.count()
            let m1Count = try await replicas.m1.count()
            XCTAssertEqual(actualPublications, Int(expected))
            XCTAssertEqual(actualHQACKs, Int(expected))
            XCTAssertEqual(actualM1ACKs, Int(expected))
            XCTAssertEqual(hqCount, actualHQACKs)
            XCTAssertEqual(m1Count, actualM1ACKs)

            let admission = try XCTUnwrap(values["diskAdmission"] as? [String: Any])
            if scenario == .byteBudget {
                XCTAssertEqual(Set(admission.keys), Set(["state"]))
                XCTAssertEqual(admission["state"] as? String, "notEvaluated")
            } else {
                XCTAssertEqual(Set(admission.keys), Set(["state", "minimumFreeDiskBytes",
                    "inventoryMinimumAvailableBytes", "captureMinimumAvailableBytes"]))
                XCTAssertEqual(admission["state"] as? String, "observed")
                XCTAssertEqual(try self.nonnegativeJSONInteger(admission["minimumFreeDiskBytes"]), threshold)
                let inventory = try self.nonnegativeJSONInteger(admission["inventoryMinimumAvailableBytes"])
                if scenario == .inventoryPressure {
                    XCTAssertLessThan(inventory, threshold)
                    XCTAssertTrue(admission["captureMinimumAvailableBytes"] is NSNull,
                        "inventory rejection must not invent a capture-volume sample")
                } else {
                    XCTAssertGreaterThanOrEqual(inventory, threshold)
                    XCTAssertGreaterThanOrEqual(try self.nonnegativeJSONInteger(admission["captureMinimumAvailableBytes"]), threshold)
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            try scope.assertOwnerCanBeReacquired()
            try scope.fixture.assertNoProductIndex()
        }
    }

    private func nonnegativeJSONInteger(_ value: Any?) throws -> Int64 {
        let number = try XCTUnwrap(value as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
        let integer = try XCTUnwrap(value as? Int64)
        XCTAssertGreaterThanOrEqual(integer, 0)
        return integer
    }

    private func residentLifecycle(signal: Int32) async throws {
        try await withFixture { scope in
            let replicas = try await scope.startReplicas()
            try scope.fixture.writeTranscript("CLI first generation")
            try scope.fixture.writeSettings(scope.fixture.document(replicas: replicas))
            try scope.writeCredentials(scope.validCredentials)
            let identityBefore = try Data(contentsOf: scope.fixture.identity)
            let child = try scope.launch(once: false)
            let first = try await scope.awaitDualACKs(generations: 1)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.first?.sequence, 1)

            let source = scope.fixture.sources.appendingPathComponent("rollout-one.jsonl")
            let firstBytes = try Data(contentsOf: source)
            let message: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "CLI appended second generation"]]]]
            var append = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            append.append(10)
            let handle = try FileHandle(forWritingTo: source)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: append)
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            XCTAssertEqual(try Data(contentsOf: source), firstBytes + append)

            let second = try await scope.awaitDualACKs(generations: 2)
            XCTAssertEqual(second.count, 2)
            XCTAssertEqual(second[1].sequence, 2)
            XCTAssertEqual(second[1].sourceInstanceID, first[0].sourceInstanceID)
            XCTAssertEqual(second[1].collectorEpoch, first[0].collectorEpoch)
            XCTAssertNotEqual(second[1].manifestSHA256, first[0].manifestSHA256)
            try child.send(signal)
            let result = try await child.waitForExit(seconds: 5)
            XCTAssertEqual(result.reason, .exit, "signal \(signal) must reach graceful cleanup")
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout, "engram-collector: running\n")
            XCTAssertEqual(result.stderr, "")
            scope.assertNoPrivateOutput(result)
            try scope.assertOwnerCanBeReacquired()
            XCTAssertEqual(try scope.fixture.publications(), second)
            XCTAssertEqual(try Data(contentsOf: scope.fixture.identity), identityBefore)
            try scope.fixture.assertNoProductIndex()
        }
    }

    private enum BadCredentials: Equatable {
        case missingFile, missingReference, nonString, empty, sameTokens, unsafePermissions, leafSymlink, ancestorSymlink
    }

    private func credentialsRejected(_ kind: BadCredentials) async throws {
        try await withFixture { scope in
            let hq = try scope.startConnectionSink()
            let m1 = try scope.startConnectionSink()
            try await hq.calibrate()
            try await m1.calibrate()
            XCTAssertEqual(hq.connections, 1)
            XCTAssertEqual(m1.connections, 1)
            var document = scope.fixture.document()
            var block = try XCTUnwrap(document["collector"] as? [String: Any])
            block["replicas"] = [
                ["serverID": "hq", "baseURL": hq.baseURL.absoluteString, "credentialID": "hq-reference"],
                ["serverID": "m1", "baseURL": m1.baseURL.absoluteString, "credentialID": "m1-reference"],
            ]
            document["collector"] = block
            try scope.fixture.writeSettings(document)
            try scope.fixture.writeTranscript(CLIIntegrationScope.canary)
            var map: [String: Any] = scope.validCredentials
            switch kind {
            case .missingReference: map.removeValue(forKey: "m1-reference")
            case .nonString: map["m1-reference"] = 123
            case .empty: map["m1-reference"] = ""
            case .sameTokens: map["m1-reference"] = map["hq-reference"]
            default: break
            }
            var supplied = scope.credentials
            var immutableTarget: URL?
            if kind != .missingFile {
                try scope.writeCredentials(map)
                immutableTarget = scope.credentials
            }
            if kind == .unsafePermissions {
                guard chmod(scope.credentials.path, 0o644) == 0 else { throw CLIIntegrationFailure.fixture }
            }
            if kind == .leafSymlink {
                supplied = scope.fixture.base.appendingPathComponent("credentials-leaf-link.json")
                try FileManager.default.createSymbolicLink(at: supplied, withDestinationURL: scope.credentials)
            }
            if kind == .ancestorSymlink {
                let real = scope.fixture.base.appendingPathComponent("credentials-real")
                let nested = real.appendingPathComponent("nested")
                try CLIIntegrationScope.privateDirectory(real)
                try CLIIntegrationScope.privateDirectory(nested)
                let target = nested.appendingPathComponent("credentials.json")
                try FileManager.default.moveItem(at: scope.credentials, to: target)
                let alias = scope.fixture.base.appendingPathComponent("credentials-ancestor-link")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
                supplied = alias.appendingPathComponent("nested/credentials.json")
                immutableTarget = target
            }
            let originalBytes = try immutableTarget.map { try Data(contentsOf: $0) }
            let originalMode = try immutableTarget.map { try CLIIntegrationScope.mode($0) }
            let identityBefore = try Data(contentsOf: scope.fixture.identity)
            let child = try scope.launch(once: true, credentialsURL: supplied)
            let result = try await child.waitForExit(seconds: 5)
            XCTAssertEqual(result.reason, .exit)
            XCTAssertEqual(result.status, 70)
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "engram-collector: runtime failed\n")
            scope.assertNoPrivateOutput(result)

            // Cancellation drains pending accepts before closing the listener;
            // checking a publication count alone would miss an early HTTP GET.
            await hq.stop()
            await m1.stop()
            XCTAssertEqual(hq.connections, 1, "only the explicit pre-child calibration connection is allowed")
            XCTAssertEqual(m1.connections, 1, "only the explicit pre-child calibration connection is allowed")
            XCTAssertNil(hq.observationFailure)
            XCTAssertNil(m1.observationFailure)
            try scope.assertOwnerCanBeReacquired()
            for table in ["collector_streams", "collector_capture_reservations", "collector_publications", "collector_publication_replicas"] {
                XCTAssertEqual(try scope.fixture.integer("SELECT count(*) FROM \(table)"), 0)
            }
            if let immutableTarget {
                XCTAssertEqual(try Data(contentsOf: immutableTarget), originalBytes)
                XCTAssertEqual(try CLIIntegrationScope.mode(immutableTarget), originalMode)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: supplied.path))
            }
            XCTAssertEqual(try Data(contentsOf: scope.fixture.identity), identityBefore)
            try scope.fixture.assertNoProductIndex()
        }
    }

    private func withFixture(_ body: (CLIIntegrationScope) async throws -> Void) async throws {
        guard let path = ProcessInfo.processInfo.environment["ENGRAM_COLLECTOR_BINARY"] else {
            throw XCTSkip("Native CLI integration requires explicit ENGRAM_COLLECTOR_BINARY; no binary lookup is performed")
        }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CLIIntegrationFailure.binaryPath }
        let scope = try CLIIntegrationScope(binary: URL(fileURLWithPath: path))
        var bodyFailure: Error?
        do { try await body(scope) }
        catch { bodyFailure = error }
        // Cleanup is joined even if XCTest's calling task was cancelled.
        let cleanup = Task { try await scope.close() }
        do { try await cleanup.value }
        catch {
            XCTFail("CLI cleanup did not finish; the task-owned fixture is retained at \(scope.fixture.base.path)")
            throw error
        }
        if let bodyFailure { throw bodyFailure }
    }
}

private enum CLIIntegrationFailure: Error {
    case binaryPath, fixture, earlyExit(Int32), deadline, outputLimit, cleanup, observer
}

private final class CLIIntegrationScope: @unchecked Sendable {
    static let canary = "CLI_NATIVE_PRIVATE_CANARY_DO_NOT_PRINT"
    let fixture: RuntimeFixture
    let binary: URL
    let home: URL
    let temporary: URL
    let credentials: URL
    private var child: CLIIntegrationChild?
    private var replicas: RuntimeReplicas?
    private var sinks: [CLIConnectionSink] = []
    private var reopenedOwner: EngramCollectorCore.CollectorInventoryOwner?

    var validCredentials: [String: String] {
        ["hq-reference": "synthetic-hq-runtime-token", "m1-reference": "synthetic-m1-runtime-token"]
    }

    init(binary: URL) throws {
        self.binary = binary
        fixture = try RuntimeFixture()
        home = fixture.base.appendingPathComponent("cli-private-home")
        temporary = home.appendingPathComponent("tmp")
        credentials = fixture.base.appendingPathComponent("\(Self.canary)-credentials.json")
        do {
            try Self.privateDirectory(home)
            try Self.privateDirectory(temporary)
            let defaultRoot = home.appendingPathComponent(".engram")
            try Self.privateDirectory(defaultRoot)
            try Data(Self.canary.utf8).write(to: defaultRoot.appendingPathComponent("settings.json"))
            guard chmod(defaultRoot.appendingPathComponent("settings.json").path, 0o600) == 0 else {
                throw CLIIntegrationFailure.fixture
            }
        } catch { fixture.remove(); throw error }
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    static func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CLIIntegrationFailure.fixture }
        return info.st_mode
    }

    func writeCredentials(_ map: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: credentials)
        guard chmod(credentials.path, 0o600) == 0 else { throw CLIIntegrationFailure.fixture }
    }

    func startReplicas() async throws -> RuntimeReplicas {
        let result = try await RuntimeReplicas.start(parent: fixture.base)
        replicas = result
        return result
    }

    func startConnectionSink() throws -> CLIConnectionSink {
        let result = try CLIConnectionSink()
        sinks.append(result)
        return result
    }

    func launch(once: Bool, credentialsURL: URL? = nil) throws -> CLIIntegrationChild {
        guard child == nil else { throw CLIIntegrationFailure.fixture }
        var arguments = ["--settings", fixture.settings.path, "--credentials-file", (credentialsURL ?? credentials).path]
        if once { arguments.append("--once") }
        let result = try CLIIntegrationChild(binary: binary, arguments: arguments, root: fixture.base, home: home, temporary: temporary)
        child = result
        return result
    }

    func awaitDualACKs(generations: Int) async throws -> [EngramCollectorCore.CollectorPublicationEnvelope] {
        guard let child, let replicas else { throw CLIIntegrationFailure.fixture }
        let deadline = Date().addingTimeInterval(10)
        while true {
            try child.requireRunning()
            let hq = try await replicas.hq.count()
            let m1 = try await replicas.m1.count()
            if hq >= generations, m1 >= generations,
               FileManager.default.fileExists(atPath: fixture.inventory.path),
               try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE state = 'acknowledged'") >= generations * 2 {
                XCTAssertEqual(hq, generations)
                XCTAssertEqual(m1, generations)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'hq' AND state = 'acknowledged'"), generations)
                XCTAssertEqual(try fixture.integer("SELECT count(*) FROM collector_publication_replicas WHERE replica_id = 'm1' AND state = 'acknowledged'"), generations)
                return try fixture.publications()
            }
            guard Date() < deadline else { throw CLIIntegrationFailure.deadline }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    func assertOwnerCanBeReacquired() throws {
        guard child?.isRunning == false else { throw CLIIntegrationFailure.cleanup }
        let owner = try XCTUnwrap(EngramCollectorCore.CollectorInventoryOwner.open(enabled: true,
            shadowRoot: fixture.shadow, identityCatalog: fixture.identity, ownerRunID: UUID().uuidString))
        reopenedOwner = owner
        try owner.close()
        reopenedOwner = nil
    }

    func assertNoPrivateOutput(_ result: CLIIntegrationChild.Result) {
        let output = result.stdout + result.stderr
        for value in [Self.canary, fixture.base.path, "hq-reference", "m1-reference"] + Array(validCredentials.values) {
            XCTAssertFalse(output.contains(value), "private data escaped the CLI output boundary")
        }
    }

    func close() async throws {
        var failed = false
        if let child {
            do { try await child.stopAndJoin() }
            catch { failed = true }
        }
        if let replicas { await replicas.stop() }
        for sink in sinks {
            await sink.stop()
            if sink.observationFailure != nil { failed = true }
        }
        if let owner = reopenedOwner {
            do { try owner.close(); reopenedOwner = nil }
            catch { failed = true }
        }
        guard !failed else { throw CLIIntegrationFailure.cleanup }
        fixture.remove()
        guard !FileManager.default.fileExists(atPath: fixture.base.path) else { throw CLIIntegrationFailure.cleanup }
    }
}

final class CLIIntegrationChild: @unchecked Sendable {
    struct Result {
        let status: Int32
        let reason: Process.TerminationReason
        let stdout: String
        let stderr: String
    }

    private final class Termination: @unchecked Sendable {
        struct Snapshot {
            let status: Int32
            let reason: Process.TerminationReason
        }

        private let lock = NSLock()
        private var completed: Snapshot?
        var snapshot: Snapshot? { lock.withLock { completed } }

        func record(_ process: Process) {
            let value = Snapshot(status: process.terminationStatus, reason: process.terminationReason)
            lock.withLock { completed = value }
        }
    }

    private let process: Process
    private let termination = Termination()
    private let stdoutURL: URL
    private let stderrURL: URL
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let deadline = Date().addingTimeInterval(30)
    private var outputClosed = false
    var isRunning: Bool { termination.snapshot == nil }

    private static let allowedRoleEnvironment: Set<String> = [
        "ENGRAM_SETTINGS_PATH", "ENGRAM_RUNTIME_AI_SECRETS_PATH", "ENGRAM_REMOTE_OFFLOAD_ENABLED",
        "ENGRAM_LIVE_PUBLISH_ENABLED", "ENGRAM_LIVE_INGEST_ENABLED", "ENGRAM_DISABLED_SOURCES",
        "ENGRAM_USAGE_TOKEN_LIMITS", "ENGRAM_REMOTE_HOST", "ENGRAM_REMOTE_PORT", "ENGRAM_REMOTE_STORE",
        "ENGRAM_REMOTE_TOKEN", "ENGRAM_REMOTE_AT_REST_KEY", "ENGRAM_REMOTE_ARCHIVE_ENABLED",
        "ENGRAM_REMOTE_COLLECTOR_PUBLICATIONS_ENABLED", "ENGRAM_REMOTE_ARCHIVE_SERVER_ID",
        "ENGRAM_REMOTE_ARCHIVE_ROOT", "ENGRAM_REMOTE_ARCHIVE_TOKEN", "ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY",
        "ENGRAM_REMOTE_MCP_ENABLED", "ENGRAM_REMOTE_WEB_ENABLED", "ENGRAM_REMOTE_WEB_ORIGIN",
        "ENGRAM_REMOTE_WEB_VIEWER_CREDENTIAL", "ENGRAM_REMOTE_WEB_SERVICE_SOCKET",
    ]

    init(binary: URL, arguments: [String], root: URL, home: URL, temporary: URL,
         roleEnvironment: [String: String] = [:]) throws {
        guard Set(roleEnvironment.keys).isSubset(of: Self.allowedRoleEnvironment),
              roleEnvironment.values.allSatisfy({ !$0.utf8.contains(0) }) else { throw CLIIntegrationFailure.fixture }
        stdoutURL = root.appendingPathComponent("cli.stdout")
        stderrURL = root.appendingPathComponent("cli.stderr")
        for url in [stdoutURL, stderrURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw CLIIntegrationFailure.fixture
            }
        }
        stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        do { stderrHandle = try FileHandle(forWritingTo: stderrURL) }
        catch { try? stdoutHandle.close(); throw error }
        process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = root
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path,
            "CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path, "LANG": "C", "LC_ALL": "C"]
        process.environment = environment.merging(roleEnvironment) { original, _ in original }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let completion = termination
        process.terminationHandler = { finished in completion.record(finished) }
        do { try process.run() }
        catch { try? stdoutHandle.close(); try? stderrHandle.close(); throw error }
    }

    func requireRunning() throws {
        try Task.checkCancellation()
        if let completed = termination.snapshot { throw CLIIntegrationFailure.earlyExit(completed.status) }
        guard Date() < deadline else { throw CLIIntegrationFailure.deadline }
    }

    func send(_ signal: Int32) throws {
        try requireRunning()
        guard [SIGTERM, SIGINT, SIGHUP].contains(signal), process.isRunning, process.processIdentifier > 0,
              Darwin.kill(process.processIdentifier, signal) == 0 else { throw CLIIntegrationFailure.cleanup }
    }

    func waitForExit(seconds: TimeInterval) async throws -> Result {
        try await join(seconds: seconds)
        return try result()
    }

    func crashAndJoin() async throws -> Result {
        try requireRunning()
        guard process.isRunning, process.processIdentifier > 0,
              Darwin.kill(process.processIdentifier, SIGKILL) == 0 else { throw CLIIntegrationFailure.cleanup }
        try await join(seconds: 3)
        let outcome = try result()
        guard outcome.reason == .uncaughtSignal, outcome.status == SIGKILL else { throw CLIIntegrationFailure.cleanup }
        return outcome
    }

    private func join(seconds: TimeInterval) async throws {
        let until = Date().addingTimeInterval(seconds)
        // Foundation's isRunning=false is not a waitUntilExit completion
        // barrier. Join the pre-run callback without blocking a run loop.
        while termination.snapshot == nil {
            try Task.checkCancellation()
            guard Date() < until else { throw CLIIntegrationFailure.deadline }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func stopAndJoin() async throws {
        if process.isRunning {
            guard process.processIdentifier > 0 else { throw CLIIntegrationFailure.cleanup }
            _ = Darwin.kill(process.processIdentifier, SIGTERM)
            do { try await join(seconds: 2) }
            catch {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                try await join(seconds: 3)
            }
        } else { try await join(seconds: 1) }
        try closeOutput()
    }

    private func closeOutput() throws {
        guard !outputClosed else { return }
        try stdoutHandle.close()
        try stderrHandle.close()
        outputClosed = true
    }

    private func result() throws -> Result {
        guard let completed = termination.snapshot else { throw CLIIntegrationFailure.cleanup }
        try closeOutput()
        func read(_ url: URL) throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else { throw CLIIntegrationFailure.outputLimit }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try Result(status: completed.status, reason: completed.reason,
            stdout: read(stdoutURL), stderr: read(stderrURL))
    }
}

/// Negative-case observation only: accept and count any loopback connection,
/// send no HTTP response, and close every accepted socket. No server is copied.
private final class CLIConnectionSink: @unchecked Sendable {
    let baseURL: URL
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let lock = NSLock()
    private var accepted = 0
    private var failure: Int32?
    private var stopping = false
    private var stopped = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var connections: Int { lock.withLock { accepted } }
    var observationFailure: Int32? { lock.withLock { failure } }

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw CLIIntegrationFailure.observer }
        var configured = false
        defer { if !configured { _ = Darwin.close(socket) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw CLIIntegrationFailure.observer }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let flags = fcntl(socket, F_GETFL)
        guard bound == 0, flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0,
              Darwin.listen(socket, 16) == 0 else { throw CLIIntegrationFailure.observer }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) }
        }
        guard named == 0, address.sin_port != 0,
              let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))") else {
            throw CLIIntegrationFailure.observer
        }
        baseURL = url
        descriptor = socket
        source = DispatchSource.makeReadSource(fileDescriptor: socket,
            queue: DispatchQueue(label: "engram.cli-negative-connections.\(UUID().uuidString)"))
        source.setEventHandler { [weak self] in self?.acceptAvailable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            // Drain the kernel accept queue even if cancellation overtook the
            // ordinary read handler, so the calibration count cannot hide a queued GET.
            self.acceptAvailable()
            let closed = Darwin.close(self.descriptor)
            let code = errno
            let waiters = self.lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                if closed != 0 { self.failure = code }
                self.stopped = true
                let values = self.stopWaiters
                self.stopWaiters.removeAll()
                return values
            }
            for waiter in waiters { waiter.resume() }
        }
        source.resume()
        configured = true
    }

    func calibrate() async throws {
        guard connections == 0, observationFailure == nil,
              let port = baseURL.port, let exactPort = UInt16(exactly: port) else { throw CLIIntegrationFailure.observer }
        let probe = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw CLIIntegrationFailure.observer }
        defer { _ = Darwin.close(probe) }
        let flags = fcntl(probe, F_GETFL)
        guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) == 0 else { throw CLIIntegrationFailure.observer }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = exactPort.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw CLIIntegrationFailure.observer }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 || errno == EINPROGRESS else { throw CLIIntegrationFailure.observer }
        let deadline = Date().addingTimeInterval(2)
        while true {
            try Task.checkCancellation()
            guard observationFailure == nil, connections <= 1 else { throw CLIIntegrationFailure.observer }
            // Count publication follows accepted-socket close. Joining this
            // bounded observation and the deferred probe close precede launch.
            if connections == 1 { return }
            guard Date() < deadline else { throw CLIIntegrationFailure.deadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func acceptAvailable() {
        for _ in 0..<64 {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                let closed = Darwin.close(connection)
                let code = errno
                lock.withLock {
                    if closed != 0 { failure = code }
                    accepted += 1
                }
                continue
            }
            if errno == EINTR { continue }
            if errno != EAGAIN && errno != EWOULDBLOCK {
                let code = errno
                lock.withLock { failure = code }
            }
            return
        }
        lock.withLock { failure = EOVERFLOW }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if stopped { lock.unlock(); continuation.resume(); return }
            stopWaiters.append(continuation)
            let cancel = !stopping
            stopping = true
            lock.unlock()
            if cancel { source.cancel() }
        }
    }
}
