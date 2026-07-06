// macos/EngramTests/SettingsHonestyTests.swift
import XCTest
@testable import Engram

/// Source-honesty + behavior tests for WP12: the Settings surface must not
/// advertise persisted-but-unread controls, must not surface the deleted HTTP
/// transcript Web UI, and must report title regeneration honestly.
final class SettingsHonestyTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Source honesty

    func testNetworkSettingsSectionIsDeleted() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(settingsView.contains("case network"), "Network settings only hosted deleted peer-sync controls")
        XCTAssertFalse(settingsView.contains("NetworkSettingsSection"), "Deleted peer-sync settings must not leave an empty Network tab")

        let networkSettings = repoRoot.appendingPathComponent("macos/Engram/Views/Settings/NetworkSettingsSection.swift")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: networkSettings.path),
            "NetworkSettingsSection should be deleted with the dead peer-sync settings surface"
        )
    }

    func testGeneralSettingsDropsMcpEndpointAndHasDeveloperToolsToggle() throws {
        let source = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        XCTAssertFalse(source.contains("/mcp"), "MCP is stdio-only; the misleading /mcp endpoint row must be removed")
        XCTAssertFalse(source.contains("mcpEndpointText"), "Orphaned mcpEndpointText property must be removed")
        XCTAssertTrue(source.contains("showDeveloperTools"), "Developer Tools toggle must write the showDeveloperTools key B1's Observability gate reads")
        XCTAssertTrue(source.contains("Show Developer Tools"))
    }

    func testHttpTranscriptWebUiSurfaceIsDeleted() throws {
        let settingsView = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(settingsView.contains("Toggle(\"Enable Web UI\""), "Settings must not expose the deleted HTTP transcript Web UI gate")
        XCTAssertFalse(settingsView.contains("Enable Web UI"), "Settings must not offer a deleted Web UI toggle")

        let generalSettings = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        XCTAssertFalse(generalSettings.contains("Open Web UI"), "General settings must not link to the deleted HTTP transcript Web UI")
        XCTAssertFalse(generalSettings.contains("webUIURL"), "General settings must not compute a deleted Web UI endpoint")

        let statusStore = try source("macos/Shared/Service/EngramServiceStatusStore.swift")
        XCTAssertFalse(statusStore.contains("endpointHost"), "Status store must not track a deleted Web UI host")
        XCTAssertFalse(statusStore.contains("endpointPort"), "Status store must not track a deleted Web UI port")
        XCTAssertFalse(statusStore.contains(#""web_ready""#), "Status store must not decode deleted web_ready events")
        XCTAssertFalse(statusStore.contains(#""web_error""#), "Status store must not decode deleted web_error events")

        let runner = try source("macos/EngramService/Core/EngramServiceRunner.swift")
        XCTAssertFalse(runner.contains("EngramWebUIServer"), "Service runner must not start the deleted HTTP transcript Web UI")
        XCTAssertFalse(runner.contains("readWebUIEnabled"), "Service runner must not read the deleted Web UI gate")
        XCTAssertFalse(runner.contains("provisionWebToken"), "Service runner must not provision deleted Web UI tokens")
        XCTAssertFalse(runner.contains(#""web_ready""#), "Service runner must not emit deleted web_ready events")
        XCTAssertFalse(runner.contains(#""web_error""#), "Service runner must not emit deleted web_error events")
    }

    func testAdvancedSettingsHasNoWebApiSecurityControls() throws {
        let source = try source("macos/Engram/Views/SettingsView.swift")
        XCTAssertFalse(source.contains("Web API & Security"), "The misleading Web API & Security GroupBox must be removed")
        XCTAssertFalse(source.contains("$httpBearerToken"), "The unread bearer-token input control must be removed")
        XCTAssertFalse(source.contains("$httpAllowCIDR"), "The unread CIDR input control must be removed")
        XCTAssertFalse(source.contains("$httpHost"), "The unread HTTP host input control must be removed")
        // The scrub removeValue calls must remain so stale persisted values are wiped on next save.
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpBearerToken")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpAllowCIDR")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "httpHost")"#))
        XCTAssertTrue(source.contains(#"removeValue(forKey: "webUIEnabled")"#))
    }

    func testServiceCoreDoesNotLinkDeletedHttpStack() throws {
        let source = try source("macos/project.yml")
        let serviceCoreBlock = try XCTUnwrap(
            source.range(of: "  EngramServiceCore:")?.lowerBound
        )
        let serviceTargetBlock = try XCTUnwrap(
            source.range(of: "  EngramService:", range: serviceCoreBlock..<source.endIndex)?.lowerBound
        )
        let block = String(source[serviceCoreBlock..<serviceTargetBlock])

        XCTAssertFalse(block.contains("Hummingbird"), "EngramServiceCore must not link the deleted HTTP Web UI stack")
    }

    func testRegenerateAllStatusCopyIsHonest() throws {
        let source = try source("macos/Engram/Views/Settings/AISettingsSection.swift")
        XCTAssertFalse(source.contains("Service status: "), "Status must not freeze on the raw service status string")
        XCTAssertTrue(source.contains("Regenerating in background"), "Status must honestly say regeneration runs in the background")
        XCTAssertTrue(source.contains("case service(String, Int?)"), "Status enum must carry the optional session total")
    }

    // MARK: - Behavior

    func testRegenerationStatusLabelRendersHonestCopy() {
        // The enum carries (status, total); both with and without a total must
        // produce a non-nil, in-background label rather than the raw status.
        XCTAssertNotNil(TitleRegenerationStatus.service("started", 42).label)
        XCTAssertNotNil(TitleRegenerationStatus.service("running", nil).label)
        XCTAssertNil(TitleRegenerationStatus.idle.label)
        XCTAssertNotNil(TitleRegenerationStatus.queued.label)
        XCTAssertNotNil(TitleRegenerationStatus.error.label)
    }

    func testRegenerateAllTitlesDrivesServiceResponse() async throws {
        let mock = MockEngramServiceClient(
            regenerateAllTitles: EngramServiceRegenerateTitlesResponse(
                status: "started",
                total: 17,
                message: nil
            )
        )
        let response = try await mock.regenerateAllTitles()
        let status = TitleRegenerationStatus.service(response.status, response.total)
        XCTAssertEqual(status, .service("started", 17))
        XCTAssertNotNil(status.label)
    }
}
