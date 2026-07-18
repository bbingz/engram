// macos/EngramCoreTests/ProjectMove/JsonlPatchTests.swift
// Mirrors tests/core/project-move/jsonl-patch.test.ts (Node parity baseline).
import Darwin
import Foundation
import XCTest
@testable import EngramCoreWrite

final class JsonlPatchTests: XCTestCase {
    /// Multi-100MB streaming repros are valuable but dominate CI wall-clock and
    /// have cancelled the 25m (even 45m) swift-unit job on some runners. Opt in
    /// with `ENGRAM_RUN_LARGE_IO=1`. Unit-level mid-stream terminator tests still
    /// cover R2 without the large-file path.
    private func skipUnlessLargeIOEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        if env["ENGRAM_RUN_LARGE_IO"] == "1" { return }
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            throw XCTSkip("large streaming JsonlPatch repros skipped on CI; set ENGRAM_RUN_LARGE_IO=1")
        }
    }

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
        let input = "\"cwd\": \"/Users/bing/项目/旧\", \"other\": \"保留\""
        let r = try patch(input, from: "/Users/bing/项目/旧", to: "/Users/bing/项目/新")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"cwd\": \"/Users/bing/项目/新\", \"other\": \"保留\"")
    }

    func testOldPathContainsUtf8() throws {
        let r = try patch("\"/项目/子目录\"", from: "/项目", to: "/proj")
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.text, "\"/proj/子目录\"")
    }

    func testDecomposedOldPathMatchesPrecomposedContent() throws {
        let oldNFC = "/tmp/CaféProject"
        let oldNFD = oldNFC.decomposedStringWithCanonicalMapping
        XCTAssertFalse(oldNFC.utf8.elementsEqual(oldNFD.utf8))

        let result = try JsonlPatch.patchBuffer(
            Data("\"\(oldNFC)/session\"".utf8),
            oldPath: oldNFD,
            newPath: "/tmp/Renamed"
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), "\"/tmp/Renamed/session\"")
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

    func testPatchFileStreamsFilesLargerThanOldInMemoryCap() throws {
        try skipUnlessLargeIOEnabled()
        let path = tmpRoot.appendingPathComponent("large.jsonl").path
        try "{\"cwd\":\"/old\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(JsonlPatch.maxInMemoryBytes + 4096))
        try handle.close()

        let count = try JsonlPatch.patchFile(at: path, oldPath: "/old", newPath: "/new")

        XCTAssertEqual(count, 1)
        let read = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let head = try read.read(upToCount: 64) ?? Data()
        try read.close()
        XCTAssertTrue(
            String(data: head, encoding: .utf8)?.contains("/new") == true,
            "expected patched path in file head"
        )
    }

    /// M12: path token straddling the 1 MiB streaming chunk cut must still patch.
    func testStreamingPatchCatchesNeedleAtChunkBoundary_repro() throws {
        try skipUnlessLargeIOEnabled()
        let path = tmpRoot.appendingPathComponent("boundary.jsonl").path
        let oldPath = "/Users/test/old-project-path"
        let newPath = "/Users/test/new-project-path"
        let chunk = 1024 * 1024
        // Place the needle so it straddles the first 1 MiB boundary.
        let prefixLen = chunk - (oldPath.utf8.count / 2)
        var data = Data(repeating: UInt8(ascii: "x"), count: prefixLen)
        data.append(Data("\"cwd\":\"\(oldPath)\"".utf8))
        data.append(Data(repeating: UInt8(ascii: "y"), count: 64 * 1024))
        // Force streaming path (> maxInMemoryBytes).
        let pad = Int(JsonlPatch.maxInMemoryBytes) + 1024 - data.count
        if pad > 0 {
            data.append(Data(repeating: UInt8(ascii: "z"), count: pad))
        }
        try data.write(to: URL(fileURLWithPath: path))

        let count = try JsonlPatch.patchFile(at: path, oldPath: oldPath, newPath: newPath)
        XCTAssertGreaterThanOrEqual(count, 1, "M12: boundary-straddling path must be patched")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains(newPath), "M12: new path must appear in output")
        XCTAssertFalse(text.contains(oldPath), "M12: old path must not remain")
    }

    /// R2: needle + non-terminator (`-`) across a streaming segment cut must NOT rewrite.
    /// Mid-stream `$` EOS previously treated `/proj` as terminated when the next
    /// byte (in carry) was `-`, corrupting `/proj-v2` → `/new-v2`.
    func testStreamingPatchDoesNotFalseMatchNeedleBeforeDashAcrossCut_repro() throws {
        try skipUnlessLargeIOEnabled()
        let path = tmpRoot.appendingPathComponent("false-match.jsonl").path
        let oldPath = "/Users/test/proj"
        let newPath = "/Users/test/moved"
        let protected = "\"cwd\":\"\(oldPath)-v2\""
        let chunk = 1024 * 1024
        // End the first 1 MiB process window exactly after `oldPath`, so the
        // following `-v2` lives in the carry / next read and mid-stream `$`
        // would historically false-match.
        let prefixLen = chunk - oldPath.utf8.count
        var data = Data(repeating: UInt8(ascii: "x"), count: prefixLen)
        data.append(Data(protected.utf8))
        data.append(Data(repeating: UInt8(ascii: "y"), count: 64 * 1024))
        let pad = Int(JsonlPatch.maxInMemoryBytes) + 1024 - data.count
        if pad > 0 {
            data.append(Data(repeating: UInt8(ascii: "z"), count: pad))
        }
        try data.write(to: URL(fileURLWithPath: path))

        let count = try JsonlPatch.patchFile(at: path, oldPath: oldPath, newPath: newPath)
        XCTAssertEqual(count, 0, "R2: path followed by '-' must not be rewritten")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains(protected), "R2: protected longer path must remain intact")
        XCTAssertFalse(text.contains(newPath), "R2: must not introduce rewritten path")
    }

    /// R2 positive control: same layout, but real terminator after the needle
    /// across the cut must still rewrite once the following `"` is visible.
    func testStreamingPatchRewritesWhenTerminatorFollowsAcrossCut_repro() throws {
        try skipUnlessLargeIOEnabled()
        let path = tmpRoot.appendingPathComponent("true-match.jsonl").path
        let oldPath = "/Users/test/proj"
        let newPath = "/Users/test/moved"
        let chunk = 1024 * 1024
        let prefixLen = chunk - oldPath.utf8.count
        var data = Data(repeating: UInt8(ascii: "x"), count: prefixLen)
        data.append(Data("\"cwd\":\"\(oldPath)\"".utf8))
        data.append(Data(repeating: UInt8(ascii: "y"), count: 64 * 1024))
        let pad = Int(JsonlPatch.maxInMemoryBytes) + 1024 - data.count
        if pad > 0 {
            data.append(Data(repeating: UInt8(ascii: "z"), count: pad))
        }
        try data.write(to: URL(fileURLWithPath: path))

        let count = try JsonlPatch.patchFile(at: path, oldPath: oldPath, newPath: newPath)
        XCTAssertGreaterThanOrEqual(count, 1, "R2: terminator after cut must still patch")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains(newPath), "R2: rewritten path must appear")
        XCTAssertFalse(text.contains("\"cwd\":\"\(oldPath)\""), "R2: old path token must not remain")
    }

    /// Unit: mid-stream buffer must not treat EOS as terminator.
    func testPatchBufferMidStreamDoesNotTreatEndAsTerminator_repro() throws {
        let input = Data("/a/b".utf8)
        let mid = try JsonlPatch.patchBuffer(
            input,
            oldPath: "/a/b",
            newPath: "/a/c",
            treatEndAsTerminator: false
        )
        XCTAssertEqual(mid.count, 0, "mid-stream must not match at artificial EOS")
        XCTAssertEqual(mid.data, input)

        let final = try JsonlPatch.patchBuffer(
            input,
            oldPath: "/a/b",
            newPath: "/a/c",
            treatEndAsTerminator: true
        )
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(String(data: final.data, encoding: .utf8), "/a/c")
    }


    func testPatchFileRejectsSymlinkSource() throws {
        let target = tmpRoot.appendingPathComponent("target.jsonl")
        try "\"cwd\":\"/old\"".write(to: target, atomically: true, encoding: .utf8)
        let link = tmpRoot.appendingPathComponent("link.jsonl")
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            throw XCTSkip("symlink permission denied: \(error.localizedDescription)")
        }

        XCTAssertThrowsError(
            try JsonlPatch.patchFile(at: link.path, oldPath: "/old", newPath: "/new")
        ) { error in
            guard case JsonlPatchError.ioError(let path, _, let message) = error else {
                return XCTFail("expected ioError, got \(error)")
            }
            XCTAssertEqual(path, link.path)
            XCTAssertTrue(message.lowercased().contains("symlink"), "unexpected message: \(message)")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "\"cwd\":\"/old\"")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testPatchFileTempFilesSetPermissionsAtCreation() throws {
        let source = try projectSource("EngramCoreWrite/ProjectMove/JsonlPatch.swift")

        XCTAssertFalse(source.contains("chmod(tmpPath"))
        XCTAssertFalse(source.contains("createFile(atPath: tmpPath, contents: nil)"))
        XCTAssertTrue(source.contains("attributes: [.posixPermissions:"))
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

    private func projectSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
