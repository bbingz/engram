// macos/EngramCoreTests/ProjectMove/EncodeClaudeCodeDirTests.swift
// Mirrors tests/core/project-move/encode-cc.test.ts (Node parity baseline).
import XCTest
@testable import EngramCoreWrite

final class EncodeClaudeCodeDirTests: XCTestCase {
    func testReplacesEverySlashWithDash() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/example/-Code-/engram"),
            "-Users-example--Code--engram"
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

    func testHandlesSpaces() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/example/my proj"),
            "-Users-example-my proj"
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
