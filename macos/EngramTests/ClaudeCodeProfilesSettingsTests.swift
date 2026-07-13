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

    func testStateKeepsSaveDisabledWhenInitialStatusLoadFails() {
        var state = ClaudeCodeProfilesSettingsState()

        state.applyStatusFailure()

        XCTAssertFalse(state.canEdit)
        XCTAssertNil(state.configurationRequest)
        XCTAssertNil(state.status)
        XCTAssertTrue(state.customProjectsRoots.isEmpty)
    }

    func testStateHidesStaleMetricsButPreservesTrustedEditsAfterRefreshFailure() throws {
        let root = "/custom/projects"
        var state = ClaudeCodeProfilesSettingsState()
        state.applyStatusSuccess(
            try status(
                autoDiscover: true,
                customProjectsRoots: [root],
                profiles: [try profile(id: "custom-id", root: root, origin: "custom")]
            )
        )
        state.autoDiscover = false

        state.applyStatusFailure()

        XCTAssertTrue(state.canEdit)
        XCTAssertFalse(state.autoDiscover)
        XCTAssertEqual(state.customProjectsRoots, [root])
        XCTAssertNil(state.status)
        XCTAssertEqual(state.rows.count, 1)
        XCTAssertNil(state.rows[0].profile)
        XCTAssertTrue(state.rows[0].canRemoveCustomRegistration)
    }

    func testStateAddsRemovesAndBuildsCompleteConfigurationRequest() throws {
        var state = ClaudeCodeProfilesSettingsState()
        state.applyStatusSuccess(try status(autoDiscover: true))
        state.autoDiscover = false

        XCTAssertEqual(state.addCustomRoot("/z/projects"), .added)
        XCTAssertEqual(state.addCustomRoot("/a/projects"), .added)
        XCTAssertEqual(state.addCustomRoot("/a/projects"), .duplicate)
        XCTAssertEqual(
            state.configurationRequest,
            EngramServiceConfigureClaudeCodeProfilesRequest(
                autoDiscover: false,
                customProjectsRoots: ["/a/projects", "/z/projects"]
            )
        )

        state.removeCustomRoot("/a/projects")

        XCTAssertEqual(state.customProjectsRoots, ["/z/projects"])
    }

    func testStateClassifiesDuplicateBeforeCustomRootLimit() throws {
        let roots = (0..<64).map { "/profiles/\($0)/projects" }
        var state = ClaudeCodeProfilesSettingsState()
        state.applyStatusSuccess(
            try status(autoDiscover: false, customProjectsRoots: roots)
        )

        XCTAssertEqual(state.addCustomRoot(roots[0]), .duplicate)
        XCTAssertEqual(state.addCustomRoot("/profiles/overflow/projects"), .limitReached)
    }

    func testStateMergesAutomaticCustomOverlapAndKeepsRedundantRegistrationRemovable() throws {
        let overlap = "/profiles/overlap/projects"
        let automaticOnly = "/profiles/automatic/projects"
        let defaultRoot = "/home/.claude/projects"
        var state = ClaudeCodeProfilesSettingsState()
        state.applyStatusSuccess(
            try status(
                autoDiscover: true,
                customProjectsRoots: [overlap, defaultRoot],
                profiles: [
                    try profile(
                        id: "automatic-only",
                        root: automaticOnly,
                        origin: "automatic"
                    ),
                    try profile(
                        id: "overlap",
                        root: overlap,
                        origin: "automatic"
                    ),
                    try profile(
                        id: "default",
                        displayName: "Server Default",
                        root: defaultRoot,
                        origin: "default"
                    ),
                ]
            )
        )

        let overlapRow = try XCTUnwrap(state.rows.first { $0.projectsRoot == overlap })
        XCTAssertEqual(state.rows.filter { $0.projectsRoot == overlap }.count, 1)
        XCTAssertNotNil(overlapRow.profile)
        XCTAssertTrue(overlapRow.canRemoveCustomRegistration)

        let defaultRow = try XCTUnwrap(state.rows.first { $0.projectsRoot == defaultRoot })
        XCTAssertEqual(state.rows.filter { $0.projectsRoot == defaultRoot }.count, 1)
        XCTAssertNotNil(defaultRow.profile)
        XCTAssertTrue(defaultRow.canRemoveCustomRegistration)
        XCTAssertEqual(defaultRow.displayName, String(localized: "Default"))

        state.autoDiscover = false

        XCTAssertNil(state.rows.first { $0.projectsRoot == automaticOnly })
        XCTAssertNotNil(state.rows.first { $0.projectsRoot == overlap })
        XCTAssertNotNil(state.rows.first { $0.projectsRoot == defaultRoot })
    }

    func testPendingRowIdentifiersAreStableAndUniquePerRoot() throws {
        var state = ClaudeCodeProfilesSettingsState()
        state.applyStatusSuccess(
            try status(
                autoDiscover: false,
                customProjectsRoots: ["/a/projects", "/b/projects"]
            )
        )

        let firstRows = state.rows
        let secondRows = state.rows

        XCTAssertEqual(firstRows.map(\.rowAccessibilityIdentifier), secondRows.map(\.rowAccessibilityIdentifier))
        XCTAssertEqual(Set(firstRows.map(\.rowAccessibilityIdentifier)).count, 2)
        XCTAssertEqual(Set(firstRows.map(\.removeAccessibilityIdentifier)).count, 2)
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
        ] {
            XCTAssertTrue(card.contains(identifier), "Missing accessibility identifier " + identifier)
        }
        XCTAssertFalse(card.contains("Timer.publish"))
        XCTAssertFalse(card.contains(".onReceive"))
        XCTAssertFalse(card.contains("Task.sleep"))
        XCTAssertTrue(
            card.contains(
                "Button(\"Refresh\") { Task { await loadStatus() } }\n" +
                    "                        .disabled(loading || saving)"
            )
        )
        XCTAssertTrue(card.contains("editor.applyStatusFailure()"))
    }

    func testSaveDoesNotReportSuccessForInvalidConfigurationResponse() throws {
        let text = try source("macos/Engram/Views/Settings/SourcesSettingsSection.swift")
        let save = try XCTUnwrap(
            text.components(separatedBy: "private func save() async {").last?
                .components(separatedBy: "private func addProjectsFolder()").first
        )

        XCTAssertTrue(save.contains("if response.configurationError != nil"))
        XCTAssertTrue(save.contains("Profile configuration is invalid."))
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
        XCTAssertTrue(text.contains("canRemoveCustomRegistration"))
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

    private func status(
        autoDiscover: Bool,
        customProjectsRoots: [String] = [],
        profiles: [EngramServiceClaudeCodeProfileStatus] = []
    ) throws -> EngramServiceClaudeCodeProfilesStatusResponse {
        try EngramServiceClaudeCodeProfilesStatusResponse(
            autoDiscover: autoDiscover,
            customProjectsRoots: customProjectsRoots,
            profiles: profiles,
            configurationError: nil
        )
    }

    private func profile(
        id: String,
        displayName: String = "Profile",
        root: String,
        origin: String
    ) throws -> EngramServiceClaudeCodeProfileStatus {
        try EngramServiceClaudeCodeProfileStatus(
            id: id,
            displayName: displayName,
            projectsRoot: root,
            origin: origin,
            available: true,
            sourceReclamationAllowed: origin != "custom",
            discoveredFileCount: 3,
            discoveredSourceBytes: 512,
            indexedLocatorCount: 2,
            capturedCount: 2,
            ignoredEmptyCaptureCount: 1,
            hqVerifiedCount: 1,
            m1VerifiedCount: 1,
            error: nil
        )
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
