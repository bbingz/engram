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

    func testReplacesUnderscoresWithDash() {
        // Real Claude Code maps EVERY non-[A-Za-z0-9] char to '-', so '_'
        // becomes '-' (existing '-' is preserved as identity).
        // Verified on disk: /Users/bing/-Code-/CCTV_Admin lives under
        // -Users-bing--Code--CCTV-Admin (underscore -> dash).
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/john_doe/my-proj"),
            "-Users-john-doe-my-proj"
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
        // A space is non-[A-Za-z0-9] -> '-'. Verified on disk:
        // "/Users/bing/Library/Application Support/..." lives under
        // "-Users-bing-Library-Application-Support-...".
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/my proj"),
            "-Users-bing-my-proj"
        )
    }

    /// Real-corpus regression: expected dir names are hardcoded literals (NOT
    /// recomputed via the encoder) so they lock the output against the encoder
    /// regressing back to the `/`-and-`.`-only rule. Entries are real
    /// cwd/project-dir pairs captured from ~/.claude/projects.
    func testRealCorpusDivergentPaths() {
        let cases: [(cwd: String, dir: String)] = [
            ("/Users/bing/-Code-/CCTV_Admin", "-Users-bing--Code--CCTV-Admin"),
            ("/Users/bing/-Code-/java_charge", "-Users-bing--Code--java-charge"),
            ("/Users/bing/-Code-/Service_Asset", "-Users-bing--Code--Service-Asset"),
            (
                "/Users/bing/-NetWork-/mac_Book_Pro_Debug",
                "-Users-bing--NetWork--mac-Book-Pro-Debug"
            ),
            (
                "/Users/bing/Library/Application Support/CodexBar/ClaudeProbe",
                "-Users-bing-Library-Application-Support-CodexBar-ClaudeProbe"
            ),
        ]
        for c in cases {
            XCTAssertEqual(ClaudeCodeProjectDir.encode(c.cwd), c.dir, "cwd=\(c.cwd)")
        }
    }

    func testTrailingSlashBecomesTrailingDash() {
        // Naive replace by design — caller normalizes input.
        XCTAssertEqual(ClaudeCodeProjectDir.encode("/a/b/"), "-a-b-")
    }

    func testEmptyStringPassesThrough() {
        XCTAssertEqual(ClaudeCodeProjectDir.encode(""), "")
    }

    func testKeepsExactly200EncodedUTF16CodeUnitsUnchanged() {
        let path = "/Users/bing/" + String(repeating: "a", count: 188)
        let expected = "-Users-bing-" + String(repeating: "a", count: 188)
        XCTAssertEqual(path.utf16.count, 200)
        XCTAssertEqual(ClaudeCodeProjectDir.encode(path), expected)
    }

    func testTruncatesEncodedNamesLongerThan200UTF16CodeUnitsWithHashSuffix() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/" + String(repeating: "a", count: 189)),
            "-Users-bing-" + String(repeating: "a", count: 188) + "-fqx13c"
        )
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/-Code-/" + String(repeating: "Project_", count: 35)),
            "-Users-bing--Code--Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Project-Proje-6bilpn"
        )
    }

    func testUsesJavaScriptUTF16CodeUnitSemanticsForLongEmojiPaths() {
        XCTAssertEqual(
            ClaudeCodeProjectDir.encode("/Users/bing/-Code-/" + String(repeating: "emoji🙂", count: 35)),
            "-Users-bing--Code--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--emoji--uooe3s"
        )
    }
}
