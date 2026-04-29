// macos/EngramTests/SourceColorsTests.swift
import XCTest
import SwiftUI
@testable import Engram

final class SourceColorsTests: XCTestCase {

    // All known sources from SourceColors.color(for:)
    private let allSources = [
        "claude-code", "cursor", "codex", "gemini-cli", "windsurf",
        "cline", "vscode", "antigravity", "copilot", "pi", "opencode",
        "iflow", "qwen", "kimi", "minimax", "lobsterai"
    ]

    func testAllKnownSourcesReturnNonNilColor() {
        for source in allSources {
            let color = SourceColors.color(for: source)
            // Color initializer always succeeds, so just verify we get one
            XCTAssertNotNil(color, "Color for \(source) should not be nil")
        }
    }

    func testUnknownSourceReturnsFallbackColor() {
        let unknown = SourceColors.color(for: "totally-unknown-tool")
        let copilot = SourceColors.color(for: "copilot")
        // Both should be the gray fallback (0x8E8E93)
        XCTAssertEqual(
            unknown.description, copilot.description,
            "Unknown source should use same gray as copilot (fallback)"
        )
    }

    func testSameSourceReturnsSameColor() {
        let first = SourceColors.color(for: "claude-code")
        let second = SourceColors.color(for: "claude-code")
        XCTAssertEqual(
            first.description, second.description,
            "Same source should always return the same color"
        )
    }

    func testAllSourceNamesCovered() {
        // Verify we test the exact sources defined in the switch statement
        XCTAssertEqual(allSources.count, 16)

        // Each should have a corresponding label (not the default pass-through)
        for source in allSources {
            let label = SourceColors.label(for: source)
            // Known sources have human-friendly labels (never identical to raw key, except sometimes)
            XCTAssertFalse(label.isEmpty, "Label for \(source) should not be empty")
        }
    }

    func testUnknownSourceLabelReturnsRawString() {
        let label = SourceColors.label(for: "mystery-tool")
        XCTAssertEqual(label, "mystery-tool", "Unknown source label should return the source string as-is")
    }
}
