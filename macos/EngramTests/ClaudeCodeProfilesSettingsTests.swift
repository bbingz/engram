import XCTest
@testable import Engram

final class ClaudeCodeProfilesSettingsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testDataSourcesLoadsProfileStatusAndExposesStableControlsWithoutPolling() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        let card = try XCTUnwrap(
            text.range(
                of: #"struct ClaudeCodeProfilesSettingsCard:[\s\S]*?// MARK: - Path Exists Indicator"#,
                options: .regularExpression
            ).map { String(text[$0]) }
        )

        XCTAssertTrue(card.contains("ClaudeCodeProfilesSettingsCard"))
        XCTAssertTrue(card.contains("@Environment(EngramServiceClient.self)"))
        XCTAssertTrue(card.contains("claudeCodeProfilesStatus()"))
        XCTAssertTrue(card.contains(".task { await loadStatus() }"))
        for identifier in [
            "claudeProfiles_autoDiscover",
            "claudeProfiles_add",
            "claudeProfiles_save",
            "claudeProfiles_refresh",
            "claudeProfiles_row_",
            "claudeProfiles_remove_",
        ] {
            XCTAssertTrue(card.contains(identifier), "Missing accessibility identifier " + identifier)
        }
        XCTAssertFalse(card.contains("Timer.publish"))
        XCTAssertFalse(card.contains(".onReceive"))
        XCTAssertFalse(card.contains("Task.sleep"))
    }

    func testProfileEditorUsesServiceAndDirectoryOnlyOpenPanel() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")

        XCTAssertTrue(text.contains("EngramServiceConfigureClaudeCodeProfilesRequest("))
        XCTAssertTrue(text.contains("configureClaudeCodeProfiles("))
        XCTAssertTrue(text.contains("NSOpenPanel()"))
        XCTAssertTrue(text.contains("panel.canChooseDirectories = true"))
        XCTAssertTrue(text.contains("panel.canChooseFiles = false"))
        XCTAssertTrue(text.contains("panel.allowsMultipleSelection = false"))
        XCTAssertTrue(text.contains("resolvingSymlinksInPath()"))
        XCTAssertTrue(text.contains("origin == \"custom\""))
        XCTAssertTrue(text.contains("customProjectsRoots.removeAll"))
    }

    func testProfileRowsShowCoverageAvailabilityAndReclamationProtection() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")

        for field in [
            "discoveredFileCount",
            "discoveredSourceBytes",
            "indexedLocatorCount",
            "capturedCount",
            "ignoredEmptyCaptureCount",
            "hqVerifiedCount",
            "m1VerifiedCount",
            "sourceReclamationAllowed",
            "profile.available",
            "profile.error",
            "ByteCountFormatter.string",
        ] {
            XCTAssertTrue(text.contains(field), "Missing profile status field " + field)
        }
    }

    func testAllProfileVisibleStringsHaveEnglishAndSimplifiedChineseValues() throws {
        let catalog = try stringCatalog()
        for key in Self.localizedKeys {
            let item = try XCTUnwrap(catalog[key] as? [String: Any], "Missing string key: " + key)
            let localizations = try XCTUnwrap(
                item["localizations"] as? [String: Any],
                "Missing localizations: " + key
            )
            for locale in ["en", "zh-Hans"] {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing " + locale + " localization: " + key
                )
                let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(
                    stringUnit["state"] as? String,
                    "translated",
                    "Untranslated " + locale + ": " + key
                )
                let value = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if locale == "zh-Hans", key != "HQ %lld · M1 %lld" {
                    XCTAssertNotEqual(value, key, "Chinese placeholder left in English: " + key)
                }
            }
        }
    }

    private func stringCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(
            "macos/Engram/Resources/Localizable.xcstrings"
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private static let localizedKeys = [
        "%lld files · %@ · %lld indexed · %lld archived · %lld empty ignored",
        "HQ %lld · M1 %lld",
        "Add Projects Folder",
        "Add Projects Folder…",
        "Automatic",
        "Automatically discover ~/.claude-*/projects",
        "Available",
        "Claude Code Profiles",
        "Choose a Claude Code projects folder. Custom folders are indexed and archived, but their source files are protected from automatic local reclamation.",
        "Configuration changes never delete existing sessions or archives.",
        "Default",
        "Error: profile configuration could not be saved.",
        "Error: profile status is unavailable.",
        "Error: no more than 64 custom projects folders can be added.",
        "Error: selected folder must be a Claude Code projects directory.",
        "Loading profiles…",
        "Local source reclamation allowed",
        "No Claude Code profiles found.",
        "Origin: %@",
        "Pending save",
        "Profile configuration is invalid.",
        "Profile status unavailable.",
        "Refresh",
        "Remove",
        "Save",
        "Saved.",
        "Saving…",
        "Source files protected from local reclamation",
        "Unavailable",
    ]
}
