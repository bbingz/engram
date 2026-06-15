// macos/EngramTests/SettingsHonestyTests.swift
import XCTest
@testable import Engram

/// Source-honesty + behavior tests for WP12: the Settings surface must not
/// advertise persisted-but-unread controls, must surface the real Web UI gate
/// and Developer Tools toggle, and must report title regeneration honestly.
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

    func testNetworkSettingsHasWebUIToggleAndDropsStrictSingleWriter() throws {
        let source = try source("macos/Engram/Views/Settings/NetworkSettingsSection.swift")
        XCTAssertTrue(source.contains("webUIEnabled"), "Web UI toggle must read/write the webUIEnabled gate the runner reads")
        XCTAssertTrue(source.contains("Enable Web UI"))
        XCTAssertFalse(source.contains("mcpStrictSingleWriter"), "No-op strict-single-writer state must be removed")
        XCTAssertFalse(source.contains("Strict single writer"), "No-op strict-single-writer toggle must be removed")
    }

    func testGeneralSettingsDropsMcpEndpointAndHasDeveloperToolsToggle() throws {
        let source = try source("macos/Engram/Views/Settings/GeneralSettingsSection.swift")
        XCTAssertFalse(source.contains("/mcp"), "MCP is stdio-only; the misleading /mcp endpoint row must be removed")
        XCTAssertFalse(source.contains("mcpEndpointText"), "Orphaned mcpEndpointText property must be removed")
        XCTAssertTrue(source.contains("webUIURL"), "The Open Web UI button's webUIURL property must survive")
        XCTAssertTrue(source.contains("showDeveloperTools"), "Developer Tools toggle must write the showDeveloperTools key B1's Observability gate reads")
        XCTAssertTrue(source.contains("Show Developer Tools"))
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
