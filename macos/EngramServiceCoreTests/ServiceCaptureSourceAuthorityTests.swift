import Darwin
import Foundation
import GRDB
import XCTest
import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

final class ServiceCaptureSourceAuthorityTests: XCTestCase {
    private let machine = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let instance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let otherInstance = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBB0"
    private let epoch = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
    private let nextEpoch = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private let rootPath = "/synthetic-authority/codex"
    private var root: URL!
    private var settingsURL: URL!
    private var authorityURL: URL!
    private var writer: EngramDatabaseWriter!
    private var gate: ServiceWriterGate!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".engram-authority-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        settingsURL = root.appendingPathComponent("settings.json")
        authorityURL = root.appendingPathComponent("source-authority.json")
        let databasePath = root.appendingPathComponent("index.sqlite").path
        writer = try EngramDatabaseWriter(path: databasePath)
        try writer.migrate()
        let owned = writer!
        gate = try ServiceWriterGate(databasePath: databasePath, runtimeDirectory: root,
            writerFactory: { _ in owned })
    }

    override func tearDownWithError() throws {
        gate = nil
        writer = nil
        try FileManager.default.removeItem(at: root)
    }

    func testLoadRejectsUnknownRootField() throws {
        try writeAuthority(object(["schemaVersion": 1, "sources": [validSource()], "label": "extra"]))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsUnknownSourceField() throws {
        var source = validSource()
        source["label"] = "extra"
        try writeAuthority(object(["schemaVersion": 1, "sources": [source]]))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsMissingRequiredSourceKey() throws {
        var source = validSource()
        source.removeValue(forKey: "parseFormat")
        try writeAuthority(object(["schemaVersion": 1, "sources": [source]]))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsWrongSchemaVersionAndNonInteger() throws {
        try writeAuthority(object(["schemaVersion": 2, "sources": [validSource()]]))
        assertLoadError(.invalidDocument)
        try writeAuthority(object(["schemaVersion": true, "sources": [validSource()]]))
        assertLoadError(.invalidDocument)
        try writeAuthority(object(["schemaVersion": "1", "sources": [validSource()]]))
        assertLoadError(.invalidDocument)
        try writeAuthority(object(["sources": [validSource()]]))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsEmptyOrTooManySources() throws {
        try writeAuthority(object(["schemaVersion": 1, "sources": []]))
        assertLoadError(.invalidDocument)
        let many = (0..<65).map { index in
            validSource(instance: uuid(index), configuredRoot: "/synthetic-authority/root-\(index)")
        }
        try writeAuthority(object(["schemaVersion": 1, "sources": many]))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsInvalidValues() throws {
        try writeAuthority(document(validSource(machine: machine.lowercased())))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(instance: "not-a-uuid")))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(epoch: epoch.lowercased())))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(configuredRoot: "/synthetic-authority/../codex")))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(configuredRoot: "relative")))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(source: "codex", parseFormat: "claudeDefault")))
        assertLoadError(.invalidDocument)
        try writeAuthority(document(validSource(source: "unknown", parseFormat: "codex")))
        assertLoadError(.invalidDocument)
    }

    func testLoadRejectsSymlinkHardLinkWorldReadableAndOversize() throws {
        try writeAuthority(document(validSource()))
        let link = root.appendingPathComponent("authority-link.json")
        XCTAssertEqual(symlink(authorityURL.path, link.path), 0)
        XCTAssertThrowsError(try ServiceCaptureSourceAuthority.load(url: link)) {
            XCTAssertEqual($0 as? ServiceCaptureSourceAuthorityError, .invalidFile)
        }

        let linked = root.appendingPathComponent("authority-hard.json")
        XCTAssertEqual(Darwin.link(authorityURL.path, linked.path), 0)
        XCTAssertThrowsError(try ServiceCaptureSourceAuthority.load(url: authorityURL)) {
            XCTAssertEqual($0 as? ServiceCaptureSourceAuthorityError, .invalidFile)
        }
        XCTAssertEqual(unlink(linked.path), 0)

        XCTAssertEqual(chmod(authorityURL.path, 0o644), 0)
        assertLoadError(.invalidFile)
        XCTAssertEqual(chmod(authorityURL.path, 0o600), 0)

        try Data(repeating: 0x20, count: ServiceCaptureSourceAuthority.maximumBytes + 1)
            .write(to: authorityURL, options: .atomic)
        XCTAssertEqual(chmod(authorityURL.path, 0o600), 0)
        assertLoadError(.invalidFile)
        XCTAssertThrowsError(try ServiceCaptureSourceAuthority.load(url: root)) {
            XCTAssertEqual($0 as? ServiceCaptureSourceAuthorityError, .invalidFile)
        }
    }

    func testLoadAcceptsExactSchemaVersion1Document() throws {
        try writeAuthority(document(validSource()))
        let entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].machineID, machine)
        XCTAssertEqual(entries[0].sourceInstanceID, instance)
        XCTAssertEqual(entries[0].source, .codex)
        XCTAssertEqual(entries[0].parseFormat, .codex)
        XCTAssertEqual(entries[0].configuredRoot, rootPath)
        XCTAssertEqual(entries[0].initialEpoch, epoch)
    }

    func testProvisionRequiresEnabledIndexCapturePolicy() async throws {
        try writeAuthority(document(validSource()))
        let entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        try writeSettings(["runtimeRole": "index", "captureIngest": ["enabled": false]])
        await assertProvisionError(entries, .capturePolicyUnavailable)
        try writeSettings(settings(role: "collector"))
        await assertProvisionError(entries, .capturePolicyUnavailable)
        // Intake policy admits local and omitted role; authority provisioning does not.
        try writeSettings(settings(role: "local"))
        await assertProvisionError(entries, .capturePolicyUnavailable)
        var omitted = settings()
        omitted.removeValue(forKey: "runtimeRole")
        try writeSettings(omitted)
        await assertProvisionError(entries, .capturePolicyUnavailable)
        XCTAssertEqual(try registryCount(), 0)
    }

    func testProvisionRejectsDisabledSourceWithoutWriting() async throws {
        try writeAuthority(document(validSource()))
        let entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        try writeSettings(settings(disabled: ["codex"]))
        await assertProvisionError(entries, .sourceDisabled)
        XCTAssertEqual(try registryCount(), 0)
        XCTAssertEqual(try historyCount(), 0)
    }

    func testExactBindingIsIdempotentThroughTheGate() async throws {
        try writeSettings(settings())
        try writeAuthority(document(validSource()))
        let entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
        try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
        XCTAssertEqual(try registryCount(), 1)
        XCTAssertEqual(try historyCount(), 1)
        let binding = try XCTUnwrap(writer.read {
            try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: instance)
        })
        XCTAssertEqual(binding.source, .codex)
        XCTAssertEqual(binding.parseFormat, .codex)
        XCTAssertEqual(binding.configuredRoot, rootPath)
        XCTAssertEqual(binding.approvedEpoch, epoch)
        XCTAssertEqual(binding.authorityGeneration, 1)
    }

    func testConflictOverlapAndChangedEpochRollBackTheEntireBatch() async throws {
        try writeSettings(settings())
        try writeAuthority(document(validSource(), validSource(instance: otherInstance,
            configuredRoot: rootPath + "/nested", epoch: nextEpoch)))
        var entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        await assertRegistryError(entries, .overlappingRoot)
        XCTAssertEqual(try registryCount(), 0)
        XCTAssertEqual(try historyCount(), 0)

        try writeAuthority(document(validSource(), validSource(epoch: nextEpoch)))
        entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        await assertRegistryError(entries, .sourceInstanceConflict)
        XCTAssertEqual(try registryCount(), 0)
        XCTAssertEqual(try historyCount(), 0)

        try writeAuthority(document(validSource()))
        entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
        try writeAuthority(document(validSource(epoch: nextEpoch)))
        entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        await assertRegistryError(entries, .sourceInstanceConflict)
        let binding = try XCTUnwrap(writer.read {
            try CaptureIngestSourceRegistry.binding($0, machineID: machine, sourceInstanceID: instance)
        })
        XCTAssertEqual(binding.approvedEpoch, epoch)
        XCTAssertEqual(binding.authorityGeneration, 1)
        XCTAssertEqual(try registryCount(), 1)
        XCTAssertEqual(try historyCount(), 1)
    }

    func testProvisionDoesNotAutoTrustPublicationsOrApproveEpoch() async throws {
        try writeSettings(settings())
        try writeAuthority(document(validSource()))
        let entries = try ServiceCaptureSourceAuthority.load(url: authorityURL)
        try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capture_ingest_publications") }, 0)
        XCTAssertEqual(try writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capture_ingest_ledger") }, 0)
        let history = try writer.read {
            try CaptureIngestSourceRegistry.history($0, machineID: machine, sourceInstanceID: instance)
        }
        XCTAssertEqual(history.count, 1)
        XCTAssertNil(history.first?.previousEpoch)
        XCTAssertEqual(history.first?.approvedEpoch, epoch)
    }

    private func validSource(machine: String? = nil, instance: String? = nil, source: String = "codex",
                             parseFormat: String = "codex", configuredRoot: String? = nil,
                             epoch: String? = nil) -> [String: Any] {
        ["machineID": machine ?? self.machine, "sourceInstanceID": instance ?? self.instance, "source": source,
         "parseFormat": parseFormat, "configuredRoot": configuredRoot ?? rootPath,
         "initialEpoch": epoch ?? self.epoch]
    }

    private func document(_ sources: [String: Any]...) -> [String: Any] {
        ["schemaVersion": 1, "sources": sources]
    }

    private func object(_ value: [String: Any]) -> [String: Any] { value }

    private func settings(role: String = "index", disabled: [String] = []) -> [String: Any] {
        ["runtimeRole": role, "disabledSources": disabled, "archivedDefaultOffSourcesMigrated": true,
         "captureIngest": ["enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1:8787",
             "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0]]
    }

    private func writeSettings(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: settingsURL, options: .atomic)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
    }

    private func writeAuthority(_ document: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: authorityURL, options: .atomic)
        XCTAssertEqual(chmod(authorityURL.path, 0o600), 0)
    }

    private func assertLoadError(_ expected: ServiceCaptureSourceAuthorityError) {
        XCTAssertThrowsError(try ServiceCaptureSourceAuthority.load(url: authorityURL)) {
            XCTAssertEqual($0 as? ServiceCaptureSourceAuthorityError, expected)
        }
    }

    private func assertProvisionError(_ entries: [ServiceCaptureSourceAuthorityEntry],
                                      _ expected: ServiceCaptureSourceAuthorityError) async {
        do {
            try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
            XCTFail("provision must reject \(expected)")
        } catch let error as ServiceCaptureSourceAuthorityError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func assertRegistryError(_ entries: [ServiceCaptureSourceAuthorityEntry],
                                     _ expected: CaptureIngestSourceRegistryError) async {
        do {
            try await ServiceCaptureSourceAuthority.provision(entries: entries, gate: gate, settingsURL: settingsURL)
            XCTFail("provision must reject \(expected)")
        } catch let error as CaptureIngestSourceRegistryError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func registryCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capture_ingest_source_registry") ?? 0 }
    }

    private func historyCount() throws -> Int {
        try writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM capture_ingest_epoch_history") ?? 0 }
    }

    private func uuid(_ index: Int) -> String {
        String(format: "BBBBBBBB-BBBB-4BBB-8BBB-%012X", index)
    }
}
