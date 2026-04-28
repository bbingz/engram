// macos/EngramCoreTests/ProjectMove/GitDirtyTests.swift
// Mirrors tests/core/project-move/git-dirty.test.ts (Node parity baseline).
//
// Uses real `git` CLI; tests are skipped if git isn't available. Each test
// builds a fresh tmp repo with a deterministic config (committer name/email
// set, default branch left to git's default — porcelain output doesn't
// depend on branch name).
import Foundation
import XCTest
@testable import EngramCoreWrite

final class GitDirtyTests: XCTestCase {
    private var tmpRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engram-git-dirty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        try super.tearDownWithError()
    }

    func testReportsNonRepoForPlainDirectory() async throws {
        let proj = tmpRoot.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "hi".write(to: proj.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)

        let result = await GitDirty.check(proj.path)

        XCTAssertFalse(result.isGitRepo)
        XCTAssertFalse(result.dirty)
        XCTAssertFalse(result.untrackedOnly)
        XCTAssertEqual(result.porcelain, "")
    }

    func testReportsCleanRepoAsNotDirty() async throws {
        try Self.skipIfGitMissing()
        let proj = try makeRepo()

        let result = await GitDirty.check(proj.path)

        XCTAssertTrue(result.isGitRepo)
        XCTAssertFalse(result.dirty)
        XCTAssertFalse(result.untrackedOnly)
    }

    func testDirtyRepoDistinguishesUntrackedOnly() async throws {
        try Self.skipIfGitMissing()
        let proj = try makeRepo()

        // Untracked-only state.
        try "hi".write(
            to: proj.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        let untracked = await GitDirty.check(proj.path)
        XCTAssertTrue(untracked.dirty)
        XCTAssertTrue(untracked.untrackedOnly, "porcelain=\(untracked.porcelain)")

        // Modify a tracked file as well — no longer untrackedOnly.
        try "changed".write(
            to: proj.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let mixed = await GitDirty.check(proj.path)
        XCTAssertTrue(mixed.dirty)
        XCTAssertFalse(mixed.untrackedOnly, "porcelain=\(mixed.porcelain)")
    }

    // MARK: - helpers

    private func makeRepo() throws -> URL {
        let proj = tmpRoot.appendingPathComponent("proj-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "base".write(
            to: proj.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Self.runGit(at: proj, ["init", "-q"])
        try Self.runGit(at: proj, ["config", "user.email", "t@t"])
        try Self.runGit(at: proj, ["config", "user.name", "t"])
        try Self.runGit(at: proj, ["add", "."])
        try Self.runGit(at: proj, ["commit", "-qm", "init"])
        return proj
    }

    private static func runGit(at directory: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "GitDirtyTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"]
            )
        }
    }

    private static func skipIfGitMissing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw XCTSkip("git CLI not available")
            }
        } catch {
            throw XCTSkip("git CLI not available: \(error.localizedDescription)")
        }
    }
}
