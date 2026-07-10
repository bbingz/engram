// macos/EngramTests/CommandPaletteTests.swift
import XCTest
import SwiftUI
@testable import Engram

final class CommandPaletteTests: XCTestCase {

    // MARK: - Navigation commands

    func testNavigationCommandsCoverAllScreens() {
        let commands = PaletteItem.navigationCommands(navigate: { _ in })
        XCTAssertEqual(commands.count, Screen.allCases.count)
        for command in commands {
            XCTAssertEqual(command.category, .navigation)
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertTrue(command.secondaryActions.isEmpty)
        }
    }

    func testNavigationCommandInvokesNavigate() {
        var navigated: Screen?
        let commands = PaletteItem.navigationCommands(navigate: { navigated = $0 })
        // The first command corresponds to the first Screen case.
        commands.first?.action()
        XCTAssertEqual(navigated, Screen.allCases.first)
    }

    // MARK: - Action commands

    func testActionCommandsAreThreeAndCategorized() {
        var navigated: Screen?
        var refreshed = false
        var regenerated = false
        let actions = PaletteItem.actionCommands(
            navigate: { navigated = $0 },
            refreshUsage: { refreshed = true },
            regenerateTitles: { regenerated = true }
        )
        XCTAssertEqual(actions.count, 3)
        for action in actions {
            XCTAssertEqual(action.category, .action)
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.icon.isEmpty)
            XCTAssertTrue(action.secondaryActions.isEmpty)
        }
        // Open Settings → navigate(.settings)
        actions[0].action()
        XCTAssertEqual(navigated, .settings)
        // Refresh Usage Data
        actions[1].action()
        XCTAssertTrue(refreshed)
        // Regenerate All Titles
        actions[2].action()
        XCTAssertTrue(regenerated)
    }

    // MARK: - Session result

    func testSessionResultIsSessionCategoryWithTwoSecondaryActions() {
        var selected = false
        var resumed = false
        var exported = false
        let item = PaletteItem.sessionResult(
            id: "sess-1",
            title: "A session",
            subtitle: "a snippet",
            onSelect: { selected = true },
            onResume: { resumed = true },
            onExport: { exported = true }
        )
        XCTAssertEqual(item.category, .session)
        XCTAssertEqual(item.id, "sess-1")
        item.action()
        XCTAssertTrue(selected)

        XCTAssertEqual(item.secondaryActions.count, 2)
        XCTAssertEqual(item.secondaryActions[0].label, "Resume")
        XCTAssertEqual(item.secondaryActions[1].label, "Export")
        item.secondaryActions[0].run()
        item.secondaryActions[1].run()
        XCTAssertTrue(resumed)
        XCTAssertTrue(exported)
    }

    // MARK: - Shared tokens

    func testLongLabelDisambiguatesAndFallsBack() {
        XCTAssertEqual(SourceColors.longLabel(for: "iflow"), "iFlow")
        XCTAssertEqual(SourceColors.longLabel(for: "claude-code"), "Claude Code")
        XCTAssertEqual(SourceColors.longLabel(for: "gemini-cli"), "Gemini CLI")
        // Unknown ids fall back to label(for:).
        XCTAssertEqual(
            SourceColors.longLabel(for: "totally-unknown"),
            SourceColors.label(for: "totally-unknown")
        )
    }

    func testThemeCornerRadiusTokenIsEight() {
        XCTAssertEqual(Theme.cornerRadius, 8)
    }

    // MARK: - H12 export state machine

    func testExportStateStartsIdleAndKeepsResultsVisible() {
        let state = CommandPaletteExportState.idle
        XCTAssertFalse(state.isInFlight)
        XCTAssertNil(state.statusText)
        XCTAssertNil(state.revealPath)
        XCTAssertTrue(state.keepsResultsVisible)
        XCTAssertTrue(state.allowsExportAction)
    }

    func testExportStateInFlightShowsProgressAndBlocksDuplicateExport() {
        var state = CommandPaletteExportState.idle
        XCTAssertTrue(state.begin(sessionId: "s1"))
        XCTAssertEqual(state, .inFlight(sessionId: "s1"))
        XCTAssertTrue(state.isInFlight)
        XCTAssertEqual(state.statusText, "Exporting…")
        XCTAssertTrue(state.keepsResultsVisible)
        XCTAssertFalse(state.allowsExportAction)
        // Second begin while in flight is rejected (no double-submit).
        XCTAssertFalse(state.begin(sessionId: "s2"))
        XCTAssertEqual(state, .inFlight(sessionId: "s1"))
    }

    func testExportStateSucceededExposesFinderRevealPath() {
        var state = CommandPaletteExportState.idle
        XCTAssertTrue(state.begin(sessionId: "s1"))
        state.succeed(path: "/tmp/exports/s1.md")
        XCTAssertEqual(state, .succeeded(path: "/tmp/exports/s1.md"))
        XCTAssertEqual(state.statusText, "Exported to s1.md")
        XCTAssertEqual(state.revealPath, "/tmp/exports/s1.md")
        XCTAssertTrue(state.keepsResultsVisible)
        XCTAssertTrue(state.allowsExportAction)
    }

    func testExportStateFailedSurfacesMessageWithoutClearingList() {
        var state = CommandPaletteExportState.idle
        XCTAssertTrue(state.begin(sessionId: "s1"))
        state.fail(message: "Export failed")
        XCTAssertEqual(state, .failed(message: "Export failed"))
        XCTAssertEqual(state.statusText, "Export failed")
        XCTAssertNil(state.revealPath)
        XCTAssertTrue(state.keepsResultsVisible)
        XCTAssertTrue(state.allowsExportAction)
    }

    func testExportStateClearReturnsToIdle() {
        var state = CommandPaletteExportState.succeeded(path: "/tmp/out.md")
        state.clear()
        XCTAssertEqual(state, .idle)
    }

    // MARK: - H12 production wiring (source contract)

    func testCommandPaletteWiresExportStateWithoutReplacingResults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EngramTests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo root
        let path = root.appendingPathComponent("macos/Engram/Views/CommandPaletteView.swift").path
        let source = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(
            source.contains("@State private var exportState: CommandPaletteExportState"),
            "palette must hold the export state machine"
        )
        XCTAssertTrue(
            source.contains("exportState.statusText"),
            "in-flight/success/failure status must render as a banner"
        )
        XCTAssertTrue(
            source.contains("commandPalette_exportProgress")
                || source.contains("\"commandPalette_exportProgress\""),
            "in-flight export must surface a progress affordance"
        )
        XCTAssertTrue(
            source.contains("Show in Finder"),
            "success must wire a Finder reveal action"
        )
        XCTAssertTrue(
            source.contains("commandPalette_revealExport")
                || source.contains("\"commandPalette_revealExport\""),
            "success reveal must be identifiable in the view hierarchy"
        )
        // Disable only the export secondary action — not the whole row / results.
        XCTAssertTrue(
            source.contains(".disabled(isExport && !exportState.allowsExportAction)"),
            "inFlight must disable only the duplicate export action"
        )
        XCTAssertFalse(
            source.contains("if let exportMessage"),
            "export must not replace the results pane with a full-screen message"
        )
        // Results list remains reachable independent of export state.
        XCTAssertTrue(
            source.contains("ForEach(Array(visibleItems.enumerated())"),
            "results list must stay in the body while export status is shown"
        )
        XCTAssertTrue(
            source.contains("exportState.begin(sessionId:")
                || source.contains("next.begin(sessionId:"),
            "export() must begin the state machine before the service call"
        )
        XCTAssertTrue(
            source.contains(".succeeded(path:")
                || source.contains("terminal = .succeeded"),
            "success path must transition to succeeded with the export path"
        )
        XCTAssertTrue(
            source.contains(".failed(message:")
                || source.contains("terminal = .failed"),
            "failure path must transition to failed so the user can retry"
        )
    }
}
