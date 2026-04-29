// macos/EngramCoreTests/ProjectMove/SessionSourcesTests.swift
// Mirrors tests/core/project-move/sources.test.ts (Node parity baseline).
import Foundation
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

    func testRootsReturnsCanonicalEightInOrder() {
        let roots = SessionSources.roots(homeDirectory: URL(fileURLWithPath: "/home/test"))
        let ids = roots.map(\.id)
        XCTAssertEqual(ids, [
            .claudeCode, .codex, .geminiCli, .iflow,
            .pi,
            .opencode, .antigravity, .copilot,
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
            roots.first(where: { $0.id == .pi })?.path,
            "/home/test/.pi/agent/sessions"
        )
    }

    func testEncodeProjectDirSetForGroupedSourcesOnly() {
        let roots = SessionSources.roots(homeDirectory: URL(fileURLWithPath: "/h"))
        let withEncoder = roots.filter { $0.encodeProjectDir != nil }.map(\.id)
        XCTAssertEqual(withEncoder, [.claudeCode, .geminiCli, .iflow, .pi])

        let cc = roots.first { $0.id == .claudeCode }?.encodeProjectDir
        XCTAssertEqual(cc?("/Users/a/b/proj"), "-Users-a-b-proj")

        let gemini = roots.first { $0.id == .geminiCli }?.encodeProjectDir
        XCTAssertEqual(gemini?("/Users/a/b/proj"), "proj")

        let iflow = roots.first { $0.id == .iflow }?.encodeProjectDir
        XCTAssertEqual(iflow?("/Users/a/b/proj"), "-Users-a-b-proj")

        let pi = roots.first { $0.id == .pi }?.encodeProjectDir
        XCTAssertEqual(pi?("/Users/a/b/proj"), "--Users-a-b-proj--")
    }

    func testEncodePiMirrorsPiCliSessionDirectoryEncoding() {
        XCTAssertEqual(
            SessionSources.encodePi("/Users/example/-Code-/polycli"),
            "--Users-example--Code--polycli--"
        )
    }

    // MARK: - encodeIflow

    func testEncodeIflowStripsLeadingTrailingDashesPerSegment() {
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/example/-Code-/coding-memory"),
            "-Users-example-Code-coding-memory"
        )
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/example/-Code-/engram"),
            "-Users-example-Code-engram"
        )
        XCTAssertEqual(
            SessionSources.encodeIflow("/Users/example/-Code-/WebSite_GLM"),
            "-Users-example-Code-WebSite_GLM"
        )
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

    // MARK: - findReferencingFiles

    func testFindMatchesLiteralByteSubstring() throws {
        try "{\"cwd\":\"/Users/example/foo\"}".write(
            to: tmpRoot.appendingPathComponent("a.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "{\"cwd\":\"/Users/example/bar\"}".write(
            to: tmpRoot.appendingPathComponent("b.jsonl"),
            atomically: true, encoding: .utf8
        )
        try "nothing interesting".write(
            to: tmpRoot.appendingPathComponent("c.jsonl"),
            atomically: true, encoding: .utf8
        )

        let hits = SessionSources.findReferencingFiles(
            root: tmpRoot.path,
            needle: "/Users/example/foo"
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
