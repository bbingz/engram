import Darwin
import Foundation
import XCTest
import EngramCoreRead
@testable import EngramCoreWrite
@testable import EngramServiceCore

/// Focused D5 seam: capture-policy GET plus native `setSourceEnabled` owner.
/// Hide/recovery persistence stays owned by existing source-toggle IPC tests.
final class WebSourceSettingsTests: XCTestCase {
    private var root: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-d5-src-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        settingsURL = root.appendingPathComponent("settings.json")
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testKnownKeysMatchEverySourceName() {
        XCTAssertEqual(EngramServiceWebSourceSettingsValidation.knownKeys, Set(SourceName.allCases.map(\.rawValue)))
    }

    func testGetterReturnsEverySourceWhenAllDisabled() throws {
        try writeCaptureSettings(disabled: SourceName.allCases.map(\.rawValue))
        let page = try EngramServiceCommandHandler.webSourceSettings(settingsURL: settingsURL)
        XCTAssertEqual(page.sources.map(\.key), EngramServiceWebSourceSettingsValidation.knownKeys.sorted())
        XCTAssertEqual(Set(page.sources.map(\.enabled)), [false])
        XCTAssertTrue(try XCTUnwrap(ServiceCaptureIngestRuntime.policy(at: settingsURL)).enabledSources.isEmpty)
        let writer = try EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSetSourceEnabled(
                EngramServiceWebSetSourceEnabledRequest(source: "codex", enabled: true),
                writer: writer,
                settingsURL: settingsURL
            ).enabled,
            true
        )
    }

    func testAbsentAndInvalidPolicyAreUnavailable() throws {
        XCTAssertThrowsError(try EngramServiceCommandHandler.webSourceSettings(settingsURL: settingsURL)) {
            XCTAssertEqual($0 as? EngramServiceError, .serviceUnavailable(message: "Web source settings are unavailable."))
        }
        try Data("{}".utf8).write(to: settingsURL)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        XCTAssertThrowsError(try EngramServiceCommandHandler.webSourceSettings(settingsURL: settingsURL)) {
            XCTAssertEqual($0 as? EngramServiceError, .serviceUnavailable(message: "Web source settings are unavailable."))
        }
    }

    func testInvalidPolicyDoesNotWriteSettings() throws {
        let writer = try EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        let request = try EngramServiceWebSetSourceEnabledRequest(source: "codex", enabled: false)
        XCTAssertThrowsError(
            try EngramServiceCommandHandler.webSetSourceEnabled(request, writer: writer, settingsURL: settingsURL)
        ) {
            XCTAssertEqual($0 as? EngramServiceError, .serviceUnavailable(message: "Web source settings are unavailable."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.path))
        let invalid = Data("{}".utf8)
        try invalid.write(to: settingsURL)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
        XCTAssertThrowsError(
            try EngramServiceCommandHandler.webSetSourceEnabled(request, writer: writer, settingsURL: settingsURL)
        ) {
            XCTAssertEqual($0 as? EngramServiceError, .serviceUnavailable(message: "Web source settings are unavailable."))
        }
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalid)
    }

    func testExistingSetSourceEnabledOwnerIsRereadByCapturePolicy() throws {
        try writeCaptureSettings(disabled: [], extra: ["customSetting": true])
        let writer = try EngramDatabaseWriter(path: root.appendingPathComponent("index.sqlite").path)
        try writer.migrate()
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSetSourceEnabled(
                EngramServiceWebSetSourceEnabledRequest(source: "codex", enabled: false),
                writer: writer,
                settingsURL: settingsURL
            ).enabled,
            false
        )
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSourceEnabledResponse(source: "codex", settingsURL: settingsURL).enabled,
            false
        )
        XCTAssertFalse(try currentEnabled().contains("codex"))
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSetSourceEnabled(
                EngramServiceWebSetSourceEnabledRequest(source: "codex", enabled: true),
                writer: writer,
                settingsURL: settingsURL
            ).enabled,
            true
        )
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSourceEnabledResponse(source: "codex", settingsURL: settingsURL).enabled,
            true
        )
        XCTAssertTrue(try currentEnabled().contains("codex"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertEqual(saved["customSetting"] as? Bool, true)
        XCTAssertThrowsError(try EngramServiceWebSetSourceEnabledRequest(source: "not-a-source", enabled: true))
    }

    func testEnvOverrideDoesNotReplaceCapturePolicyProjection() throws {
        try writeCaptureSettings(disabled: [])
        let previous = getenv("ENGRAM_DISABLED_SOURCES").map { String(cString: $0) }
        setenv("ENGRAM_DISABLED_SOURCES", "codex", 1)
        defer {
            if let previous { setenv("ENGRAM_DISABLED_SOURCES", previous, 1) }
            else { unsetenv("ENGRAM_DISABLED_SOURCES") }
        }
        XCTAssertEqual(
            try EngramServiceCommandHandler.webSourceSettings(settingsURL: settingsURL)
                .sources.first { $0.key == "codex" }?.enabled,
            true
        )
        XCTAssertTrue(try XCTUnwrap(ServiceCaptureIngestRuntime.policy(at: settingsURL)).enabledSources.contains(.codex))
        XCTAssertTrue(EngramServiceRunner.readDisabledSources(
            environment: ["ENGRAM_DISABLED_SOURCES": "codex"]
        ).contains("codex"))
    }

    private func writeCaptureSettings(disabled: [String], extra: [String: Any] = [:]) throws {
        var document: [String: Any] = [
            "runtimeRole": "index",
            "disabledSources": disabled,
            ArchivedDefaultOffSources.settingsMigrationKey: true,
            "captureIngest": [
                "enabled": true, "serverID": "hq", "baseURL": "http://127.0.0.1",
                "credentialID": "hq", "requestTimeout": 0.2, "retryCount": 0,
            ],
        ]
        extra.forEach { document[$0] = $1 }
        try JSONSerialization.data(withJSONObject: document).write(to: settingsURL)
        XCTAssertEqual(chmod(settingsURL.path, 0o600), 0)
    }

    private func currentEnabled() throws -> Set<String> {
        Set(try XCTUnwrap(ServiceCaptureIngestRuntime.policy(at: settingsURL)).enabledSources.map(\.rawValue))
    }
}
