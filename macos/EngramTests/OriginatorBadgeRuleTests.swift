// macos/EngramTests/OriginatorBadgeRuleTests.swift
import XCTest
@testable import Engram

/// Covers the display rule behind the "via Claude Code" originator badge. The
/// badge must be meaningful: it should mark sessions that ran inside the real
/// Claude Code app (native-derived minimax/lobsterai) but NOT every
/// provider-clone-root session, which carries originator="Claude Code" only as
/// a structural artifact of a forked provider CLI.
final class OriginatorBadgeRuleTests: XCTestCase {
    private func shows(_ source: String, _ originator: String?) -> Bool {
        SourceDisplay.showsViaClaudeCodeBadge(source: source, originator: originator)
    }

    func testNativeDerivedSourcesShowBadge() {
        XCTAssertTrue(shows("minimax", "Claude Code"))
        XCTAssertTrue(shows("lobsterai", "Claude Code"))
    }

    func testOriginatorSpellingVariantsStillMatch() {
        XCTAssertTrue(shows("minimax", "claude-code"))
        XCTAssertTrue(shows("lobsterai", "CLAUDE_CODE"))
    }

    func testNativeDerivedWithoutClaudeCodeOriginatorHidesBadge() {
        XCTAssertFalse(shows("minimax", nil))
        XCTAssertFalse(shows("lobsterai", "codex_cli_rs"))
    }

    func testProviderCloneRootsNeverShowBadge() {
        // All provider clones set originator="Claude Code" structurally; none
        // should be labeled "via Claude Code".
        for clone in ["kimi", "qwen", "mimo", "doubao", "glm", "deepseek", "codex"] {
            XCTAssertFalse(shows(clone, "Claude Code"), "\(clone) must not show the badge")
        }
    }

    func testNativeClaudeCodeSessionsHideBadge() {
        // A real Claude Code session has no originator and is not "via" anything.
        XCTAssertFalse(shows("claude-code", nil))
        XCTAssertFalse(shows("claude-code", "Claude Code"))
    }
}

/// Covers finding (4): the catalog records the secondary provider roots the
/// adapters actually watch, without breaking the one-entry-per-source invariant.
final class SourceCatalogAdditionalPathsTests: XCTestCase {
    private func entry(_ id: String) -> SourceCatalogEntry? {
        SourceCatalog.all.first { $0.id == id }
    }

    func testSecondaryProviderRootsAreRecorded() {
        XCTAssertEqual(entry("mimo")?.additionalPaths, ["~/.claude-mimosg/projects"])
        XCTAssertEqual(entry("glm")?.additionalPaths, ["~/.claude-glmc/projects"])
        XCTAssertEqual(entry("deepseek")?.additionalPaths, ["~/.claude-dsc/projects"])
    }

    func testSingleRootSourcesHaveNoAdditionalPaths() {
        XCTAssertEqual(entry("claude-code")?.additionalPaths, [])
        XCTAssertEqual(entry("kimi")?.additionalPaths, [])
        XCTAssertEqual(entry("doubao")?.additionalPaths, [])
    }
}
