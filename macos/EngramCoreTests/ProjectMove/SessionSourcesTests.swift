// macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift
// Mirrors tests/core/project-move/sources.test.ts (Node parity baseline).
import Foundation
import Darwin
import XCTest
@testable import EngramCoreWrite

final class SessionSourcesTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-sources-\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - getSourceRoots

    func testRootsReturnsCanonicalTenInOrder() {
        let roots = SessionSources.roots(homeDirectory: URL(fileURLWithPath: "/home/test"))
        let ids = roots.map(\.id)
        XCTAssertEqual(ids, [
            .claudeCode, .codex, .geminiCli, .iflow,
            .qoder, .opencode, .antigravity, .antigravityLegacy, .commandcode, .copilot,
        ])
        XCTAssertEqual(
            roots.first(where: { $0.id == .copilot })?.path,
            "/home/test/.copilot"
        )
        XCTAssertEqual(
            roots.first(where: { $0.id == .iflow })?.path,
            "/home/test/.iflow/projects"
        )
        XCTAssertEqual(
            roots.first(where: { $0.id == .qoder })?.path,
            "/home/test/.qoder/projects"
        )
        XCTAssertEqual(
            roots.first(where: { $0.id == .commandcode })?.path,
            "/home/test/.commandcode/projects"
        )
        XCTAssertEqual(
            roots.first(where: { $0.id == .antigravity })?.path,
            "/home/test/.gemini/antigravity-cli/brain"
        )
        XCTAssertEqual(
            roots.first(where: { $0.id == .antigravityLegacy })?.path,
            "/home/test/.gemini/antigravity"
        )
    }

    func testEncodeProjectDirSetForGroupedSourcesOnly() {
        let roots = SessionSources.roots(homeDirectory: URL(fileURLWithPath: "/h"))
        let withEncoder = roots.filter { $0.encodeProjectDir != nil }.map(\.id)
        XCTAssertEqual(withEncoder, [.claudeCode, .geminiCli, .iflow, .qoder])

        let cc = roots.first { $0.id == .claudeCode }?.encodeProjectDir
        XCTAssertEqual(cc?("/Users/a/b/proj"), "-Users-a-b-proj")

        let gemini = roots.first { $0.id == .geminiCli }?.encodeProjectDir
        XCTAssertEqual(gemini?("/Users/a/b/proj"), "proj")
        // Gemini slugifies the basename: lowercase, '_' → '-', strip wrapping
        // dashes. Verified against real ~/.gemini/projects.json values.
        XCTAssertEqual(gemini?("/Users/bing/-Code-"), "code")
        XCTAssertEqual(gemini?("/Users/bing/-Code-/WebSite_Gemini"), "website-gemini")
        XCTAssertEqual(gemini?("/Users/bing/-Code-/java_charge"), "java-charge")

        let iflow = roots.first { $0.id == .iflow }?.encodeProjectDir
        XCTAssertEqual(iflow?("/Users/a/b/proj"), "-Users-a-b-proj")

        let qoder = roots.first { $0.id == .qoder }?.encodeProjectDir
        XCTAssertEqual(qoder?("/Users/a/b/proj"), "-Users-a-b-proj")
    }

    // MARK: - encodeIflow

    func testEncodeIflowStripsLeadingTrailingDashesPerSegment() {
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/bing/-Code-/coding-memory"),
            "-Users-bing-Code-coding-memory"
        )
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/bing/-Code-/engram"),
            "-Users-bing-Code-engram"
        )
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/bing/-Code-/WebSite_GLM"),
            "-Users-bing-Code-WebSite_GLM"
        )
    }

    func testEncodeIflowCollidesForLeadingTrailingDashes() {
        XCTAssertEqual(
            SessionSources.encodeIflow("/a/-foo-/p"),
            SessionSources.encodeIflow("/a/foo/p")
        )
    }

    func testCollectOtherIflowCwdsSharingEncodedDir() throws {
        let target = SessionSources.encodeIflow("/a/foo/p")
        let projectDir = tmpRoot.appendingPathComponent(target, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try """
        {"sessionId":"src","cwd":"/a/-foo-/p","type":"summary"}
        {"sessionId":"other","cwd":"/a/foo/p","type":"summary"}
        """.write(to: projectDir.appendingPathComponent("session-1.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SessionSources.collectOtherIflowCwdsSharingEncodedDir(
                root: tmpRoot.path,
                targetEncodedDir: target,
                srcCwd: "/a/-foo-/p"
            ),
            ["/a/foo/p"]
        )
    }

    // MARK: - encodeGemini

    func testEncodeGeminiSlugifiesBasename() {
        // lowercase + strip wrapping dashes
        XCTAssertEqual(SessionSources.encodeGemini("/Users/bing/-Code-"), "code")
        // lowercase only
        XCTAssertEqual(
            SessionSources.encodeGemini("/Users/bing/-NetWork-/Screen-disconnet-erro"),
            "screen-disconnet-erro"
        )
        // '_' → '-' plus lowercase
        XCTAssertEqual(
            SessionSources.encodeGemini("/Users/bing/-Code-/WebSite_Gemini"),
            "website-gemini"
        )
        XCTAssertEqual(
            SessionSources.encodeGemini("/Users/bing/-Code-/mac_Book_Pro_Debug"),
            "mac-book-pro-debug"
        )
    }

    func testEncodeGeminiStripsWrappingDashesAfterUnderscoreSwap() {
        // Underscore-to-dash happens before wrapping-dash strip, so a
        // leading/trailing underscore must not survive as an edge dash.
        XCTAssertEqual(SessionSources.encodeGemini("/a/_foo_"), "foo")
    }

    // MARK: - walkSessionFiles

    func testWalkYieldsJsonlAndJsonOnly() throws {
        try "x".write(
            to: tmpRoot.appendingPathComponent("session.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "x".write(
            to: tmpRoot.appendingPathComponent("config.json"),
            atomically: true, encoding: .utf8
        )
        try "x".write(
            to: tmpRoot.appendingPathComponent("readme.md"),
            atomically: true, encoding: .utf8
        )
        try "x".write(
            to: tmpRoot.appendingPathComponent("binary.bin"),
            atomically: true, encoding: .utf8
        )

        var seen: [String] = []
        SessionSources.walkSessionFiles(root: tmpRoot.path) { seen.append($0) }
        seen.sort()
        XCTAssertEqual(seen, [
            tmpRoot.appendingPathComponent("config.json").path,
            tmpRoot.appendingPathComponent("session.jsonl").path,
        ].sorted())
    }

    func testWalkRecursesIntoSubdirectories() throws {
        let deep = tmpRoot.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "x".write(
            to: deep.appendingPathComponent("x.jsonl"),
            atomically: true, encoding: .utf8
        )
        var seen: [String] = []
        SessionSources.walkSessionFiles(root: tmpRoot.path) { seen.append($0) }
        XCTAssertEqual(seen, [deep.appendingPathComponent("x.jsonl").path])
    }

    func testWalkDoesNotFollowSymlinks() throws {
        let real = tmpRoot.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(
            to: real.appendingPathComponent("x.jsonl"),
            atomically: true, encoding: .utf8
        )
        do {
            try FileManager.default.createSymbolicLink(
                at: tmpRoot.appendingPathComponent("link"),
                withDestinationURL: real
            )
        } catch {
            throw XCTSkip("symlink permission denied")
        }
        var seen: [String] = []
        SessionSources.walkSessionFiles(root: tmpRoot.path) { seen.append($0) }
        XCTAssertEqual(seen, [real.appendingPathComponent("x.jsonl").path])
    }

    func testWalkSilentForNonExistentRoot() {
        var seen: [String] = []
        SessionSources.walkSessionFiles(root: "/does/not/exist/at/all") {
            seen.append($0)
        }
        XCTAssertTrue(seen.isEmpty)
    }

    func testWalkReportsTooLargeFiles() throws {
        try "x".write(
            to: tmpRoot.appendingPathComponent("small.jsonl"),
            atomically: true, encoding: .utf8
        )
        try String(repeating: "x", count: 100).write(
            to: tmpRoot.appendingPathComponent("big.jsonl"),
            atomically: true, encoding: .utf8
        )

        var issues: [WalkIssue] = []
        var seen: [String] = []
        SessionSources.walkSessionFiles(
            root: tmpRoot.path,
            maxFileBytes: 10,
            onIssue: { issues.append($0) }
        ) {
            seen.append($0)
        }

        XCTAssertEqual(seen, [tmpRoot.appendingPathComponent("small.jsonl").path])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].reason, .tooLarge)
        XCTAssertEqual(issues[0].path, tmpRoot.appendingPathComponent("big.jsonl").path)
    }

    func testWalkDoesNotApplyOld128MiBCapByDefault() throws {
        let big = tmpRoot.appendingPathComponent("big.jsonl")
        try "{\"cwd\":\"/old\"}\n".write(to: big, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(JsonlPatch.maxInMemoryBytes + 4096))
        try handle.close()

        var issues: [WalkIssue] = []
        var seen: [String] = []
        SessionSources.walkSessionFiles(
            root: tmpRoot.path,
            onIssue: { issues.append($0) }
        ) {
            seen.append($0)
        }

        XCTAssertEqual(seen, [big.path])
        XCTAssertTrue(issues.isEmpty)
    }

    func testWalkReportsSymlinks() throws {
        let real = tmpRoot.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let realFile = real.appendingPathComponent("x.jsonl")
        try "x".write(to: realFile, atomically: true, encoding: .utf8)
        let link = tmpRoot.appendingPathComponent("link.jsonl")
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        } catch {
            throw XCTSkip("symlink permission denied")
        }

        var issues: [WalkIssue] = []
        SessionSources.walkSessionFiles(
            root: tmpRoot.path,
            onIssue: { issues.append($0) }
        ) { _ in }

        let symlinkIssue = issues.first { $0.reason == .skippedSymlink }
        XCTAssertNotNil(symlinkIssue)
        XCTAssertEqual(symlinkIssue?.path, link.path)
    }

    func testWalkReportsNonRegularFiles() throws {
        let fifo = tmpRoot.appendingPathComponent("pipe.jsonl")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw XCTSkip("mkfifo failed: \(String(cString: strerror(errno)))")
        }

        var issues: [WalkIssue] = []
        var seen: [String] = []
        SessionSources.walkSessionFiles(
            root: tmpRoot.path,
            onIssue: { issues.append($0) }
        ) {
            seen.append($0)
        }

        XCTAssertTrue(seen.isEmpty)
        let issue = issues.first { $0.path == fifo.path }
        XCTAssertEqual(issue?.reason, .skippedNonRegular)
    }

    // MARK: - findReferencingFiles

    func testFindMatchesLiteralByteSubstring() throws {
        try "{\"cwd\":\"/Users/bing/foo\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/Users/bing/bar\"}".write(
            to: tmpRoot.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "nothing interesting".write(
            to: tmpRoot.appendingPathComponent("c.jsonl"),
            atomically: true, encoding: .utf8
        )

        let hits = SessionSources.findReferencingFiles(
            root: tmpRoot.path,
            needle: "/Users/bing/foo"
        )
        XCTAssertEqual(hits, [tmpRoot.appendingPathComponent("a.jsonl").path])
    }

    func testFindHandlesUtf8Needles() throws {
        try "{\"cwd\":\"/项目/旧\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/other\"}".write(
            to: tmpRoot.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        let hits = SessionSources.findReferencingFiles(root: tmpRoot.path, needle: "/项目/旧")
        XCTAssertEqual(hits, [tmpRoot.appendingPathComponent("a.jsonl").path])
    }

    func testFindMatchesNfdPathTextWhenCallerPassesNfcNeedle() throws {
        let nfc = "/Users/bing/café"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        try "{\"cwd\":\"\(nfd)\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/other\"}".write(
            to: tmpRoot.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        let hits = SessionSources.findReferencingFiles(root: tmpRoot.path, needle: nfc)
        XCTAssertEqual(hits, [tmpRoot.appendingPathComponent("a.jsonl").path])
    }

    func testFindMatchesNfcPathTextWhenCallerPassesNfdNeedle() throws {
        let nfc = "/Users/bing/café"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        try "{\"cwd\":\"\(nfc)\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/other\"}".write(
            to: tmpRoot.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        let hits = SessionSources.findReferencingFiles(root: tmpRoot.path, needle: nfd)
        XCTAssertEqual(hits, [tmpRoot.appendingPathComponent("a.jsonl").path])
    }

    func testFindReturnsEmptyForEmptyNeedle() throws {
        try "x".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            SessionSources.findReferencingFiles(root: tmpRoot.path, needle: ""),
            []
        )
    }

    func testFindRecursesIntoSubdirs() throws {
        let sub = tmpRoot.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "{\"cwd\":\"/proj/alpha\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/proj/alpha\"}".write(
            to: sub.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/proj/beta\"}".write(
            to: tmpRoot.appendingPathComponent("c.jsonl"),
            atomically: true, encoding: .utf8
        )

        let hits = SessionSources.findReferencingFiles(
            root: tmpRoot.path,
            needle: "/proj/alpha"
        )
        XCTAssertEqual(hits.sorted(), [
            tmpRoot.appendingPathComponent("a.jsonl").path,
            sub.appendingPathComponent("b.jsonl").path,
        ].sorted())
    }

    func testFindReturnsEmptyForNonExistentRoot() {
        XCTAssertEqual(
            SessionSources.findReferencingFiles(
                root: "/does/not/exist/engram-test",
                needle: "/any"
            ),
            []
        )
    }
}
