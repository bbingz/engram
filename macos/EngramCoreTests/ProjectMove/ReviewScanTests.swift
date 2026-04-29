// macos/EngramCoreTests/ProjectMove/ReviewScanTests.swift
// Mirrors tests/core/project-move/review.test.ts (Node parity baseline).
import Foundation
import XCTest
@testable import EngramCoreWrite

final class ReviewScanTests: XCTestCase {
    private var tmpHome: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-review-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        let dirs = [
            ".claude/projects",
            ".codex/sessions",
            ".gemini/tmp",
            ".local/share/opencode",
            ".antigravity",
            ".copilot",
        ]
        for sub in dirs {
            try FileManager.default.createDirectory(
                at: tmpHome.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let tmpHome {
            try? FileManager.default.removeItem(at: tmpHome)
        }
        try super.tearDownWithError()
    }

    private func write(_ content: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: path, atomically: true, encoding: .utf8)
    }

    func testCcOwnDirHitClassifiedAsOwn() throws {
        let ownCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-example--Code--engram/x.jsonl"
        )
        try write("{\"cwd\":\"/old/path\"}", to: ownCc)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/example/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertTrue(r.own.contains(ownCc.path))
        XCTAssertEqual(r.other, [])
    }

    func testCcDifferentProjectDirHitClassifiedAsOther() throws {
        let otherCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-example--Code--unrelated/y.jsonl"
        )
        try write("{\"mentioned\":\"/old/path\"}", to: otherCc)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/example/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(r.own, [])
        XCTAssertTrue(r.other.contains(otherCc.path))
    }

    func testNonCcSourceHitsAlwaysCountAsOwn() throws {
        let codexFile = tmpHome.appendingPathComponent(
            ".codex/sessions/rollout.jsonl"
        )
        try write("{\"cwd\":\"/old/path\"}", to: codexFile)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/example/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertTrue(r.own.contains(codexFile.path))
        XCTAssertEqual(r.other, [])
    }

    func testEmptyWhenNothingReferencesOldPath() throws {
        try write(
            "{\"cwd\":\"/other\"}",
            to: tmpHome.appendingPathComponent(".codex/sessions/rollout.jsonl")
        )
        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/example/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(r.own, [])
        XCTAssertEqual(r.other, [])
    }

    func testMixedOwnAndOtherCoexist() throws {
        let ownCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-example--Code--engram/a.jsonl"
        )
        let otherCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-example--Code--unrelated/b.jsonl"
        )
        let codexFile = tmpHome.appendingPathComponent(
            ".codex/sessions/c.jsonl"
        )
        try write("{\"cwd\":\"/old\"}", to: ownCc)
        try write("{\"ref\":\"/old\"}", to: otherCc)
        try write("{\"cwd\":\"/old\"}", to: codexFile)

        let r = ReviewScan.run(
            oldPath: "/old",
            newPath: "/Users/example/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(r.own.sorted(), [ownCc.path, codexFile.path].sorted())
        XCTAssertEqual(r.other, [otherCc.path])
    }
}
