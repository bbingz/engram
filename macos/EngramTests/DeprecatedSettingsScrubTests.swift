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
}
