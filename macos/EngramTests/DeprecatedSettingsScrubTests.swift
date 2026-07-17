// macos/EngramTests/DeprecatedSettingsScrubTests.swift
import XCTest
@testable import Engram

final class DeprecatedSettingsScrubTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testAISettingsOnlyAdvertisesImplementedSummaryProtocol() throws {
        let source = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        let pickerStart = try XCTUnwrap(source.range(of: #"Picker("Protocol""#))
        let pickerEnd = try XCTUnwrap(source.range(of: #".pickerStyle(.segmented)"#, range: pickerStart.lowerBound..<source.endIndex))
        let picker = String(source[pickerStart.lowerBound..<pickerEnd.lowerBound])

        XCTAssertTrue(picker.contains(#"Text("OpenAI Compatible").tag("openai")"#))
        XCTAssertFalse(picker.contains(#".tag("anthropic")"#))
        XCTAssertFalse(picker.contains(#".tag("gemini")"#))
        XCTAssertTrue(source.contains(#"aiProtocol = v == "openai" ? v : "openai""#))
    }

    func testTitleSettingsPreserveStoredApiKeyWhenSwitchingToOllama() throws {
        let source = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        let start = try XCTUnwrap(source.range(of: "private func saveTitleSettings()"))
        let end = try XCTUnwrap(source.range(of: "private func loadAISettings()", range: start.lowerBound..<source.endIndex))
        let saveTitleSettings = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            saveTitleSettings.contains("TitleAPIKeyPersistenceAction.decide"),
            "Title key persistence should be an explicit decision so Ollama provider changes preserve existing cloud API keys"
        )
        XCTAssertFalse(
            saveTitleSettings.contains("KeychainHelper.delete(\"titleApiKey\")"),
            "Switching to Ollama must not delete the stored titleApiKey; only clearing a non-Ollama key should delete it"
        )
    }

    func testTitleAPIKeyPersistenceDecisionPreservesOllamaKeys() {
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(provider: "ollama", apiKey: ""),
            .preserveExisting
        )
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(provider: "ollama", apiKey: "stored-cloud-key"),
            .preserveExisting
        )
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(provider: "openai", apiKey: ""),
            .deleteExisting
        )
        XCTAssertEqual(
            TitleAPIKeyPersistenceAction.decide(provider: "custom", apiKey: " custom-key "),
            .write("custom-key")
        )
    }

    func testScrubRemovesVikingDictAndReportsChange() {
        var settings: [String: Any] = [
            "aiProtocol": "gemini",
            "ollamaModel": "qwen3-embedding:4b",
            "syncNodeName": "legacy-node",
            "syncEnabled": true,
            "embedding": [
                "provider": "ollama",
                "model": "nomic-embed-text",
                "dimension": 768
            ],
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
        XCTAssertNil(settings["syncNodeName"])
        XCTAssertNil(settings["syncEnabled"])
        XCTAssertNil(settings["embedding"])
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

    func testUsageTokenLimitSettingsWritesServiceReaderShape() {
        let settings = UsageTokenLimitSettings(
            codexFiveHourTokens: 1300,
            codexWeeklyTokens: 9000,
            claudeFiveHourTokens: 750,
            claudeWeeklyTokens: nil
        )

        let object = settings.settingsObject()

        let codex = object["codex"]
        XCTAssertEqual(codex?["fiveHourTokens"], 1300)
        XCTAssertEqual(codex?["weeklyTokens"], 9000)

        let claude = object["claude-code"]
        XCTAssertEqual(claude?["fiveHourTokens"], 750)
        XCTAssertNil(claude?["weeklyTokens"])
    }

    func testUsageTokenLimitSettingsOmitsEmptySources() {
        let settings = UsageTokenLimitSettings(
            codexFiveHourTokens: 0,
            codexWeeklyTokens: nil,
            claudeFiveHourTokens: -1,
            claudeWeeklyTokens: 0
        )

        XCTAssertTrue(settings.settingsObject().isEmpty)
    }

    func testUsageTokenLimitSettingsPreservesUnknownSourcesWhenSavingVisibleFields() {
        let settings = UsageTokenLimitSettings(sourceLimits: [
            "codex": UsageTokenLimitSettings.Limit(fiveHourTokens: 1300, weeklyTokens: nil),
            "claude-code": UsageTokenLimitSettings.Limit(fiveHourTokens: 750, weeklyTokens: nil),
            "opencode": UsageTokenLimitSettings.Limit(fiveHourTokens: 2400, weeklyTokens: nil),
        ])

        let object = settings.settingsObject(preservingUnknownFrom: [
            "opencode": [
                "fiveHourTokens": 2200.0,
                "weeklyTokens": -1.0,
            ],
            "gemini-cli": [
                "weeklyTokens": 5000.0,
            ],
            "codex": [
                "fiveHourTokens": 1.0,
                "weeklyTokens": 2.0,
            ],
            "invalid": [
                "fiveHourTokens": 0.0,
            ],
        ])

        XCTAssertEqual(object["codex"]?["fiveHourTokens"], 1300)
        XCTAssertNil(object["codex"]?["weeklyTokens"])
        XCTAssertEqual(object["claude-code"]?["fiveHourTokens"], 750)

        XCTAssertEqual(object["opencode"]?["fiveHourTokens"], 2400)
        XCTAssertNil(object["opencode"]?["weeklyTokens"])
        XCTAssertEqual(object["gemini-cli"]?["weeklyTokens"], 5000)
        XCTAssertNil(object["invalid"])
    }

    func testUsageTokenLimitRowsClearVisibleSourceWhilePreservingHiddenSources() {
        let rows = [
            UsageTokenLimitEditableRow(id: "codex", name: "Codex", fiveHourTokens: 0, weeklyTokens: 0),
            UsageTokenLimitEditableRow(id: "claude-code", name: "Claude Code", fiveHourTokens: 750, weeklyTokens: 0),
        ]

        let object = UsageTokenLimitEditableRow.settingsObject(
            from: rows,
            preservingUnknownFrom: [
                "codex": [
                    "fiveHourTokens": 1300.0,
                ],
                "custom-ai": [
                    "weeklyTokens": 5000.0,
                ],
            ]
        )

        XCTAssertNil(object["codex"])
        XCTAssertEqual(object["claude-code"]?["fiveHourTokens"], 750)
        XCTAssertEqual(object["custom-ai"]?["weeklyTokens"], 5000)
    }

    func testUsageTokenLimitRowsCanExcludeDeletedCustomSources() {
        let rows = [
            UsageTokenLimitEditableRow(id: "codex", name: "Codex", fiveHourTokens: 1300, weeklyTokens: 0),
        ]

        let object = UsageTokenLimitEditableRow.settingsObject(
            from: rows,
            preservingUnknownFrom: [
                "custom-ai": [
                    "weeklyTokens": 5000.0,
                ],
                "hidden-ai": [
                    "fiveHourTokens": 700.0,
                ],
            ],
            excludingSourceIDs: [" Custom-AI "]
        )

        XCTAssertEqual(object["codex"]?["fiveHourTokens"], 1300)
        XCTAssertNil(object["custom-ai"])
        XCTAssertEqual(object["hidden-ai"]?["fiveHourTokens"], 700)
    }

    func testUsageTokenLimitSettingsReadsAndWritesArbitrarySourceLimits() {
        let parsed = UsageTokenLimitSettings(settingsObject: [
            "codex": [
                "fiveHourTokens": 1300.0,
            ],
            "opencode": [
                "fiveHourTokens": 2200.0,
            ],
            "copilot": [
                "weeklyTokens": 7000.0,
            ],
            "gemini-cli": [
                "fiveHourTokens": 0.0,
                "weeklyTokens": 5000.0,
            ],
        ])

        XCTAssertEqual(parsed.limit(for: "codex")?.fiveHourTokens, 1300)
        XCTAssertEqual(parsed.limit(for: "opencode")?.fiveHourTokens, 2200)
        XCTAssertEqual(parsed.limit(for: "copilot")?.weeklyTokens, 7000)
        XCTAssertNil(parsed.limit(for: "gemini-cli")?.fiveHourTokens)
        XCTAssertEqual(parsed.limit(for: "gemini-cli")?.weeklyTokens, 5000)

        let object = parsed.settingsObject()
        XCTAssertEqual(object["opencode"]?["fiveHourTokens"], 2200)
        XCTAssertEqual(object["copilot"]?["weeklyTokens"], 7000)
        XCTAssertEqual(object["gemini-cli"]?["weeklyTokens"], 5000)
    }

    func testUsageTokenLimitRowsLoadUnknownSourcesFromSettings() {
        let settings = UsageTokenLimitSettings(settingsObject: [
            "codex": [
                "fiveHourTokens": 1300.0,
            ],
            "custom-ai": [
                "weeklyTokens": 5000.0,
            ],
        ])

        let rows = UsageTokenLimitEditableRow.rows(for: settings)

        XCTAssertEqual(rows.first { $0.id == "codex" }?.fiveHourTokens, 1300)
        XCTAssertEqual(rows.first { $0.id == "custom-ai" }?.name, "custom-ai")
        XCTAssertEqual(rows.first { $0.id == "custom-ai" }?.weeklyTokens, 5000)
        XCTAssertEqual(rows.last?.id, "custom-ai")
    }

    func testUsageTokenLimitSettingsNormalizesSourceKeys() {
        let parsed = UsageTokenLimitSettings(settingsObject: [
            " Codex ": [
                "fiveHourTokens": 1300.0,
            ],
            "CLAUDE-CODE": [
                "weeklyTokens": 9000.0,
            ],
        ])

        XCTAssertEqual(parsed.limit(for: "codex")?.fiveHourTokens, 1300)
        XCTAssertEqual(parsed.limit(for: "claude-code")?.weeklyTokens, 9000)
        XCTAssertEqual(parsed.limit(for: " Codex ")?.fiveHourTokens, 1300)
        XCTAssertEqual(parsed.limit(for: "CLAUDE-CODE")?.weeklyTokens, 9000)
        XCTAssertEqual(Set(parsed.settingsObject().keys), ["codex", "claude-code"])

        let direct = UsageTokenLimitSettings(sourceLimits: [
            " Codex ": UsageTokenLimitSettings.Limit(fiveHourTokens: 1400, weeklyTokens: nil),
        ])

        XCTAssertEqual(direct.limit(for: "codex")?.fiveHourTokens, 1400)
        XCTAssertEqual(direct.limit(for: " Codex ")?.fiveHourTokens, 1400)
        XCTAssertEqual(Set(direct.settingsObject().keys), ["codex"])
    }

    func testUsageTokenLimitSettingsReadsServiceReaderShape() {
        let parsed = UsageTokenLimitSettings(settingsObject: [
            "codex": [
                "fiveHourTokens": 1300.0,
                "weeklyTokens": 9000.0
            ],
            "claude-code": [
                "fiveHourTokens": 750.0
            ]
        ])

        XCTAssertEqual(parsed.codexFiveHourTokens, 1300)
        XCTAssertEqual(parsed.codexWeeklyTokens, 9000)
        XCTAssertEqual(parsed.claudeFiveHourTokens, 750)
        XCTAssertNil(parsed.claudeWeeklyTokens)
    }

    func testUsageTokenLimitRowsAppendCustomSourceOnceWithNormalizedID() {
        let rows = UsageTokenLimitEditableRow.appendingCustomSource(
            " Pi ",
            to: UsageTokenLimitEditableRow.defaultRows
        )
        let duplicateRows = UsageTokenLimitEditableRow.appendingCustomSource("PI", to: rows)

        XCTAssertEqual(rows.last?.id, "pi")
        XCTAssertEqual(rows.last?.name, "pi")
        XCTAssertEqual(duplicateRows.filter { $0.id == "pi" }.count, 1)
    }

    func testUsageTokenLimitRowsDistinguishDefaultAndCustomSources() {
        let rows = UsageTokenLimitEditableRow.appendingCustomSource(
            "commandcode",
            to: UsageTokenLimitEditableRow.defaultRows
        )

        XCTAssertEqual(rows.first { $0.id == "codex" }?.isDefaultSource, true)
        XCTAssertEqual(rows.first { $0.id == "commandcode" }?.isDefaultSource, false)
    }

    /// SEC-M3: Release must not fall back to plaintext settings for API keys.
    func testAISettingsFailClosedOnKeychainWithoutPlaintextFallback_repro() throws {
        let settingsIO = try source("macos/Engram/Views/Settings/SettingsIO.swift")
        let ai = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertTrue(settingsIO.contains("allowsPlaintextSettingsFallback"))
        XCTAssertTrue(ai.contains("KeychainHelper.allowsPlaintextSettingsFallback"))
        XCTAssertTrue(
            ai.contains("mutateEngramSettings { $0[\"aiApiKey\"] = \"@keychain\" }"),
            "SEC-M3: fail-closed path must write @keychain marker, not raw secret"
        )
    }

    /// M20: Test Connection must guard URL(string:) instead of force-unwrap.
    func testAISettingsTestConnectionGuardsInvalidURL_repro() throws {
        let ai = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertFalse(
            ai.contains("URLRequest(url: URL(string: testURL)!)"),
            "M20: must not force-unwrap free-text testURL"
        )
        XCTAssertTrue(
            ai.contains("guard let parsed = URL(string: testURL)"),
            "M20: must guard-let parse URL"
        )
        XCTAssertTrue(
            ai.contains(".failed(\"Invalid URL\")") || ai.contains("Invalid URL"),
            "M20: invalid URL must surface failed status"
        )
    }
}
