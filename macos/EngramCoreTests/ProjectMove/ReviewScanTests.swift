// macos/EngramCoreTests/ProjectMove/ReviewScanTests.swift
// Mirrors tests/core/project-move/review.test.ts (Node parity baseline).
import Foundation
import GRDB
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
            ".gemini/antigravity-cli/brain",
            ".gemini/antigravity",
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
            ".claude/projects/-Users-bing--Code--engram/x.jsonl"
        )
        try write("{\"cwd\":\"/old/path\"}", to: ownCc)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertTrue(r.own.contains(ownCc.path))
        XCTAssertEqual(r.other, [])
    }

    func testCcDifferentProjectDirHitClassifiedAsOther() throws {
        let otherCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-bing--Code--unrelated/y.jsonl"
        )
        try write("{\"mentioned\":\"/old/path\"}", to: otherCc)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/bing/-Code-/engram",
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
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertTrue(r.own.contains(codexFile.path))
        XCTAssertEqual(r.other, [])
    }

    func testOpenCodeSqliteDirectoryHitsCountAsOwnResidualRefs() throws {
        let dbPath = tmpHome
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
            .appendingPathComponent("opencode.db")
        let queue = try DatabaseQueue(path: dbPath.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY,
                directory TEXT,
                time_archived INTEGER
            )
            """)
            try db.execute(
                sql: "INSERT INTO session (id, directory) VALUES (?, ?)",
                arguments: ["open-1", "/old/path"]
            )
            try db.execute(
                sql: "INSERT INTO session (id, directory) VALUES (?, ?)",
                arguments: ["open-2", "/old/path/nested"]
            )
            try db.execute(
                sql: "INSERT INTO session (id, directory) VALUES (?, ?)",
                arguments: ["open-nfd", "/old/café".decomposedStringWithCanonicalMapping]
            )
            try db.execute(
                sql: "INSERT INTO session (id, directory) VALUES (?, ?)",
                arguments: ["open-other", "/old/path-lookalike"]
            )
        }

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )

        XCTAssertEqual(r.own, [
            "\(dbPath.path)::session:open-1:directory",
            "\(dbPath.path)::session:open-2:directory",
        ])
        XCTAssertEqual(r.other, [])

        let unicode = ReviewScan.run(
            oldPath: "/old/café",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(unicode.own, [
            "\(dbPath.path)::session:open-nfd:directory",
        ])
        XCTAssertEqual(unicode.other, [])
    }

    func testAntigravityLegacyHitsCountAsOwn() throws {
        let legacyFile = tmpHome.appendingPathComponent(
            ".gemini/antigravity/conversations/legacy.jsonl"
        )
        try write("{\"cwd\":\"/old/path\"}", to: legacyFile)

        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )

        XCTAssertTrue(r.own.contains(legacyFile.path))
        XCTAssertEqual(r.other, [])
    }

    func testEmptyWhenNothingReferencesOldPath() throws {
        try write(
            "{\"cwd\":\"/other\"}",
            to: tmpHome.appendingPathComponent(".codex/sessions/rollout.jsonl")
        )
        let r = ReviewScan.run(
            oldPath: "/old/path",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(r.own, [])
        XCTAssertEqual(r.other, [])
    }

    func testMixedOwnAndOtherCoexist() throws {
        let ownCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-bing--Code--engram/a.jsonl"
        )
        let otherCc = tmpHome.appendingPathComponent(
            ".claude/projects/-Users-bing--Code--unrelated/b.jsonl"
        )
        let codexFile = tmpHome.appendingPathComponent(
            ".codex/sessions/c.jsonl"
        )
        try write("{\"cwd\":\"/old\"}", to: ownCc)
        try write("{\"ref\":\"/old\"}", to: otherCc)
        try write("{\"cwd\":\"/old\"}", to: codexFile)

        let r = ReviewScan.run(
            oldPath: "/old",
            newPath: "/Users/bing/-Code-/engram",
            homeDirectory: tmpHome
        )
        XCTAssertEqual(r.own.sorted(), [ownCc.path, codexFile.path].sorted())
        XCTAssertEqual(r.other, [otherCc.path])
    }
}
