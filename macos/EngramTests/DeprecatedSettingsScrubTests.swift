// macos/EngramTests/DeprecatedSettingsScrubTests.swift
import XCTest
@testable import Engram

final class DeprecatedSettingsScrubTests: XCTestCase {

    func testScrubRemovesVikingDictAndReportsChange() {
        var settings: [String: Any] = [
            "aiProtocol": "gemini",
            "ollamaModel": "qwen3-embedding:4b",
            "viking": [
                "agentId": "ffb1327b18bf",
                "apiKey": "@keychain",
                "enabled": true,
                "url": "http://10.0.8.9:1933"
            ]
        ]

        let didChange = DeprecatedSettings.scrub(&settings)

        XCTAssertTrue(didChange)
        XCTAssertNil(settings["viking"])
        XCTAssertEqual(settings["aiProtocol"] as? String, "gemini")
        XCTAssertEqual(settings["ollamaModel"] as? String, "qwen3-embedding:4b")
    }

    func testScrubIsIdempotentWhenKeyAbsent() {
        var settings: [String: Any] = [
            "aiProtocol": "gemini",
            "ollamaModel": "qwen3-embedding:4b"
        ]
        let snapshot = settings

        let didChange = DeprecatedSettings.scrub(&settings)

        XCTAssertFalse(didChange)
        XCTAssertEqual(settings.count, snapshot.count)
        XCTAssertEqual(settings["aiProtocol"] as? String, "gemini")
        XCTAssertEqual(settings["ollamaModel"] as? String, "qwen3-embedding:4b")
    }

    func testScrubLeavesUnrelatedKeysUntouched() {
        var settings: [String: Any] = [
            "viking": ["enabled": true],
            "openaiApiKey": "",
            "syncPeers": []
        ]

        DeprecatedSettings.scrub(&settings)

        XCTAssertNil(settings["viking"])
        XCTAssertNotNil(settings["openaiApiKey"])
        XCTAssertNotNil(settings["syncPeers"])
    }

    func testDeprecatedKeychainAccountsListContainsViking() {
        // Guard against accidental deletion of the keychain cleanup target.
        XCTAssertTrue(DeprecatedSettings.keychainAccounts.contains("vikingApiKey"))
    }

    func testSecureSettingsWriteCreatesDirectory0700AndFile0600() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = home.appendingPathComponent(".engram/settings.json")
        defer { try? FileManager.default.removeItem(at: home) }

        try writeEngramSettingsDataSecurely(Data(#"{"aiProtocol":"openai"}"#.utf8), to: file)

        var dirInfo = stat()
        var fileInfo = stat()
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &dirInfo), 0)
        XCTAssertEqual(lstat(file.path, &fileInfo), 0)
        XCTAssertEqual(dirInfo.st_mode & 0o077, 0)
        XCTAssertEqual(fileInfo.st_mode & 0o077, 0)
    }

    func testSecureSettingsWriteRepairsLegacyLoosePermissions() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = home.appendingPathComponent(".engram", isDirectory: true)
        let file = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try Data(#"{"aiProtocol":"openai"}"#.utf8).write(to: file)
        chmod(directory.path, 0o755)
        chmod(file.path, 0o644)

        try writeEngramSettingsDataSecurely(Data(#"{"aiProtocol":"gemini"}"#.utf8), to: file)

        var dirInfo = stat()
        var fileInfo = stat()
        XCTAssertEqual(lstat(directory.path, &dirInfo), 0)
        XCTAssertEqual(lstat(file.path, &fileInfo), 0)
        XCTAssertEqual(dirInfo.st_mode & 0o077, 0)
        XCTAssertEqual(fileInfo.st_mode & 0o077, 0)
    }
}
