// macos/EngramCoreTests/ProjectMove/EncodeClaudeCodeDirTests.swift
// Mirrors tests/core/project-move/encode-cc.test.ts (Node parity baseline).
import XCTest
@testable import EngramCoreWrite

final class EncodeClaudeCodeDirTests: XCTestCase {
    func testReplacesEverySlashWithDash() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/-Code-/engram"),
            "-Users-bing--Code--engram"
        )
    }

    func testRootPath() {
        XCTAssertEqual(ClaudeCodeProjectDir.encode("/"), "-")
    }

    func testConsecutiveSlashesAreLossy() {
        XCTAssertEqual(ClaudeCodeProjectDir.encode("/a//b"), "-a--b")
    }

    func testPreservesDashesAndUnderscores() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/john_doe/my-proj"),
            "-Users-john_doe-my-proj"
        )
    }

    func testReplacesDotsWithDash() {
        // Real Claude Code encodes BOTH '/' and '.' to '-'. A leading dot in a
        // hidden dir segment produces a doubled dash from the preceding '/'.
        // Verified against ~/.claude/projects/-Users-bing--config-superpowers-…
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/.config/superpowers"),
            "-Users-bing--config-superpowers"
        )
    }

    func testReplacesInteriorDotsWithDash() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/node-v18.2.0"),
            "-Users-bing-node-v18-2-0"
        )
    }

    func testHandlesSpaces() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/my proj"),
            "-Users-bing-my proj"
        )
    }

    func testTrailingSlashBecomesTrailingDash() {
        // Naive replace by design — caller normalizes input.
        XCTAssertEqual(ClaudeCodeProjectDir.encode("/a/b/"), "-a-b-")
    }

    func testEmptyStringPassesThrough() {
        XCTAssertEqual(ClaudeCodeProjectDir.encode(""), "")
    }
}
