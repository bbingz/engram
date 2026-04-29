// macos/EngramCoreTests/ProjectMove/JsonlPatchTests.swift
// Mirrors tests/core/project-move/jsonl-patch.test.ts (Node parity baseline).
import Darwin
import Foundation
import XCTest
@testable import EngramCoreWrite

final class JsonlPatchTests: XCTestCase {
    // MARK: - patchBuffer: idempotent / symmetric

    func testRunningSamePatchTwiceIsNoOpOnSecondRun() throws {
        let once = try patch("\"/a/foo/x\"", from: "/a/foo", to: "/a/bar")
        XCTAssertEqual(once.text, "\"/a/bar/x\"")
        XCTAssertEqual(once.count, 1)
        let twice = try patch(once.text, from: "/a/foo", to: "/a/bar")
        XCTAssertEqual(twice.text, once.text)
        XCTAssertEqual(twice.count, 0)
    }

    func testSymmetricForwardThenReverseRestoresBytes() throws {
        let original = "\"/a/foo/x\""
        let forward = try patch(original, from: "/a/foo", to: "/a/bar").text
        let back = try patch(forward, from: "/a/bar", to: "/a/foo").text
        XCTAssertEqual(back, original)
    }

    // MARK: - prefix boundary

    func testDoesNotMatchPrefixWithDashSuffix() throws {
        let input = "\"/foo/bar-baz\""
        let r = try patch(input, from: "/foo/bar", to: "/foo/new")
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.text, input)
    }

    func testDoesNotMatchPrefixOfLongerName() throws {
        let r = try patch("\"/foo/barbar/x\"", from: "/foo/bar", to: "/foo/new")
        XCTAssertEqual(r.count, 0)
    }

    func testMatchesWhenFollowedBySlash() throws {
        let r = try patch("\"/foo/bar/x\"", from: "/foo/bar", to: "/foo/new")
        XCTAssertEqual(r.text, "\"/foo/new/x\"")
        XCTAssertEqual(r.count, 1)
    }

    // MARK: - terminator chars

    func testMatchesWhenFollowedByEachTerminator() throws {
        let cases: [(name: String, input: String)] = [
            ("double quote", "\"/a/b\"rest"),
            ("single quote", "'/a/b'rest"),
            ("slash", "\"/a/b/x\""),
            ("backslash", "\"/a/b\\x\""),
            ("less-than", "\"/a/b<x\""),
            ("greater-than", "\"/a/b>x\""),
            ("close-bracket", "\"/a/b]rest"),
            ("close-paren", "\"/a/b)rest"),
            ("close-brace", "\"/a/b}rest"),
            ("backtick", "\"/a/b`rest"),
            ("space", "/a/b rest"),
            ("tab", "/a/b\trest"),
            ("newline", "/a/b\nrest"),
        ]
        for (name, input) in cases {
            let r = try patch(input, from: "/a/b", to: "/a/c")
            XCTAssertEqual(r.count, 1, "expected match after \(name)")
            XCTAssertEqual(
                r.text,
                input.replacingOccurrences(of: "/a/b", with: "/a/c"),
                "after \(name)"
            )
        }
    }

    func testMatchesAtEndOfInput() throws {
        let r = try patch("/a/b", from: "/a/b", to: "/a/c")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "/a/c")
    }

    // MARK: - exclusion chars

    func testDoesNotMatchExclusionFollowers() throws {
        let inputs = [
            "/a/b.bak",
            "/a/b,x",
            "/a/b;x",
            "/a/b-baz",
            "/a/b_x",
            "/a/b9x",
            "/a/bX",
        ]
        for input in inputs {
            let r = try patch(input, from: "/a/b", to: "/a/c")
            XCTAssertEqual(r.count, 0, "should not match in: \(input)")
        }
    }

    // MARK: - UTF-8

    func testPreservesChineseSurroundingContext() throws {
        let input = "\"cwd\": \"/Users/example/项目/旧\", \"other\": \"保留\""
        let r = try patch(input, from: "/Users/example/项目/旧", to: "/Users/example/项目/新")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"cwd\": \"/Users/example/项目/新\", \"other\": \"保留\"")
    }

    func testOldPathContainsUtf8() throws {
        let r = try patch("\"/项目/子目录\"", from: "/项目", to: "/proj")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"/proj/子目录\"")
    }

    func testFourByteEmojiPassesThroughUnchanged() throws {
        let input = Data("\"/a/foo/sparkle-✨\"".utf8)
        let r = try JsonlPatch.patchBuffer(input, oldPath: "/a/foo", newPath: "/a/bar")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(String(data: r.data, encoding: .utf8), "\"/a/bar/sparkle-✨\"")
    }

    // MARK: - LIKE wildcard literal

    func testUnderscoreInPathTreatedLiterally() throws {
        let r = try patch(
            "\"/Users/john_doe/proj\"",
            from: "/Users/john_doe",
            to: "/Users/john_doe-new"
        )
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"/Users/john_doe-new/proj\"")
    }

    // MARK: - regex metachar escape

    func testEscapesDotInOldPath() throws {
        // If '.' were unescaped regex, '/a.b' would match '/aXb'.
        XCTAssertEqual(
            try patch("\"/aXb/c\"", from: "/a.b", to: "/z").count,
            0
        )
    }

    func testEscapesPlusAndDollar() throws {
        let r = try patch("\"/weird+$path/x\"", from: "/weird+$path", to: "/normal")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"/normal/x\"")
    }

    // MARK: - multiple occurrences

    func testReplacesAllOccurrences() throws {
        let r = try patch("\"/a/b/1\" \"/a/b/2\" \"/a/b/3\"", from: "/a/b", to: "/z")
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.text, "\"/z/1\" \"/z/2\" \"/z/3\"")
    }

    // MARK: - empty / no-op

    func testNoOccurrencesReturnsZeroAndOriginalBytes() throws {
        let input = Data("no match here".utf8)
        let r = try JsonlPatch.patchBuffer(input, oldPath: "/a/b", newPath: "/a/c")
        XCTAssertEqual(r.count, 0)
        XCTAssertEqual(r.data, input)
    }

    // MARK: - invalid UTF-8

    func testThrowsOnLoneContinuationByte() {
        var bytes = Data("/a/foo ".utf8)
        bytes.append(0xff)
        bytes.append(contentsOf: " rest".utf8)
        XCTAssertThrowsError(
            try JsonlPatch.patchBuffer(bytes, oldPath: "/a/foo", newPath: "/a/bar")
        ) { err in
            guard let utf8 = err as? InvalidUtf8Error else {
                return XCTFail("expected InvalidUtf8Error, got \(err)")
            }
            XCTAssertEqual(utf8.errorName, "InvalidUtf8Error")
        }
    }

    func testThrowsOnTruncatedMultibyte() {
        var bytes = Data("\"/a/foo/".utf8)
        bytes.append(contentsOf: [0xf0, 0x9f, 0x98]) // missing final byte of emoji
        XCTAssertThrowsError(
            try JsonlPatch.patchBuffer(bytes, oldPath: "/a/foo", newPath: "/a/bar")
        ) { err in
            XCTAssertTrue(err is InvalidUtf8Error)
        }
    }

    // MARK: - autoFixDotQuote

    func testAutoFixDotQuoteReplacesSentenceEndPattern() {
        let r = JsonlPatch.autoFixDotQuote(
            Data("Migrated to /a/foo.\"".utf8),
            oldPath: "/a/foo",
            newPath: "/a/bar"
        )
        XCTAssertEqual(String(data: r.data, encoding: .utf8), "Migrated to /a/bar.\"")
        XCTAssertEqual(r.count, 1)
    }

    func testAutoFixDotQuoteCountsMultipleMatches() {
        let r = JsonlPatch.autoFixDotQuote(
            Data("/a/foo.\" then /a/foo.\" again".utf8),
            oldPath: "/a/foo",
            newPath: "/a/bar"
        )
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(
            String(data: r.data, encoding: .utf8),
            "/a/bar.\" then /a/bar.\" again"
        )
    }

    func testAutoFixDotQuoteDoesNotMatchBareOldPath() {
        let r = JsonlPatch.autoFixDotQuote(
            Data("/a/foo and /a/foo/x".utf8),
            oldPath: "/a/foo",
            newPath: "/a/bar"
        )
        XCTAssertEqual(r.count, 0)
    }

    func testAutoFixDotQuoteIsLiteralRegardlessOfTrailingChar() {
        // mvp.py's auto_fix is literal byte replace of `<old>."`; whatever
        // follows is left untouched. /a/foo."bar → /a/bar."bar.
        let r = JsonlPatch.autoFixDotQuote(
            Data("/a/foo.\"bar".utf8),
            oldPath: "/a/foo",
            newPath: "/a/bar"
        )
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(String(data: r.data, encoding: .utf8), "/a/bar.\"bar")
    }

    // MARK: - patchFile (CAS)

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-patchfile-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    func testPatchFileHappyPath() throws {
        let path = tmpRoot.appendingPathComponent("a.jsonl").path
        try "\"cwd\":\"/old\"".write(toFile: path, atomically: true, encoding: .utf8)

        let count = try JsonlPatch.patchFile(at: path, oldPath: "/old", newPath: "/new")

        XCTAssertEqual(count, 1)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "\"cwd\":\"/new\"")
    }

    func testPatchFileZeroReplacementsWritesNothing() throws {
        let path = tmpRoot.appendingPathComponent("a.jsonl").path
        let original = "no match here"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let count = try JsonlPatch.patchFile(at: path, oldPath: "/old", newPath: "/new")

        XCTAssertEqual(count, 0)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testConcurrentModificationErrorContractFields() {
        // The CAS race path inside `patchFile` is hard to drive
        // deterministically through the synchronous Foundation file APIs
        // without dependency injection (the Node version exploits
        // `queueMicrotask` between the async readFile and the second
        // stat). The race itself is a single mtime-equality check whose
        // wiring is exercised by Stage 4 orchestrator integration tests.
        // For now we assert the error type carries the contract fields
        // clients depend on.
        let err = ConcurrentModificationError(
            filePath: "/tmp/x", oldMtime: 1000, newMtime: 2000
        )
        XCTAssertEqual(err.errorName, "ConcurrentModificationError")
        XCTAssertEqual(err.filePath, "/tmp/x")
        XCTAssertEqual(err.oldMtime, 1000)
        XCTAssertEqual(err.newMtime, 2000)
        XCTAssertEqual(
            RetryPolicyClassifier.classify(errorName: err.errorName),
            .conditional
        )
    }

    // MARK: - helpers

    private func patch(
        _ data: String,
        from oldPath: String,
        to newPath: String
    ) throws -> (text: String, count: Int) {
        let res = try JsonlPatch.patchBuffer(
            Data(data.utf8), oldPath: oldPath, newPath: newPath
        )
        return (String(data: res.data, encoding: .utf8) ?? "", res.count)
    }
}
