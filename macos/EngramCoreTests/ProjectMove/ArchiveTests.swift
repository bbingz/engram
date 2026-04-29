// macos/EngramCoreTests/ProjectMove/ArchiveTests.swift
// Mirrors tests/core/project-move/archive.test.ts. Locks down the four
// suggestion rules (YYYYMMDD prefix, empty, has-git, ambiguous) plus the
// alias-normalization map that prevents the HTTP layer from leaking
// English category names into the on-disk folder structure.
import Foundation
import XCTest
@testable import EngramCoreWrite

final class ArchiveTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
    }

    // MARK: - normalizeCategory

    func testNormalizeAcceptsCanonicalCJKAndEnglishAliases() {
        XCTAssertEqual(Archive.normalizeCategory("历史脚本"), .historicalScripts)
        XCTAssertEqual(Archive.normalizeCategory("空项目"), .emptyProject)
        XCTAssertEqual(Archive.normalizeCategory("归档完成"), .archivedDone)

        XCTAssertEqual(Archive.normalizeCategory("historical-scripts"), .historicalScripts)
        XCTAssertEqual(Archive.normalizeCategory("empty-project"), .emptyProject)
        XCTAssertEqual(Archive.normalizeCategory("archived-done"), .archivedDone)

        // Soft backwards-compat aliases (not in MCP schema enum).
        XCTAssertEqual(Archive.normalizeCategory("empty"), .emptyProject)
        XCTAssertEqual(Archive.normalizeCategory("completed"), .archivedDone)

        XCTAssertNil(Archive.normalizeCategory(nil))
        XCTAssertNil(Archive.normalizeCategory(""))
        XCTAssertNil(Archive.normalizeCategory("nonsense"))
    }

    // MARK: - rule 1: YYYYMMDD prefix

    func testYYYYMMDDPrefixSuggestsHistoricalScripts() throws {
        let src = try makeFixture(name: "20260101-cleanup-script")
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .historicalScripts)
        XCTAssertTrue(s.dst.hasSuffix("_archive/历史脚本/20260101-cleanup-script"))
        XCTAssertTrue(s.reason.contains("YYYYMMDD"))
    }

    func testNonDigitDatePrefixDoesNotTrigger() throws {
        // Letters in the date slot must NOT match — only 8 digits.
        let src = try makeFixture(name: "abcd0101-something", contents: ["main.swift"])
        // make it look substantive so we don't fall into rule-2/4
        try writeFile(src + "/main.swift", "// code")
        try makeGitDir(src)
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .archivedDone)
    }

    // MARK: - rule 2: empty / README-only

    func testEmptyDirectorySuggestsEmptyProject() throws {
        let src = try makeFixture(name: "shell")
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .emptyProject)
        XCTAssertTrue(s.reason.contains("empty"))
    }

    func testReadmeOnlyDirectorySuggestsEmptyProject() throws {
        let src = try makeFixture(name: "doc-only")
        try writeFile(src + "/README.md", "# placeholder")
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .emptyProject)
        XCTAssertTrue(s.reason.contains("README"))
    }

    func testReadmeCaseInsensitive() throws {
        let src = try makeFixture(name: "doc-mixed")
        try writeFile(src + "/readme.txt", "# placeholder")
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .emptyProject)
    }

    // MARK: - rule 3: has-git substantive

    func testHasGitWithContentSuggestsArchivedDone() throws {
        let src = try makeFixture(name: "real-project")
        try writeFile(src + "/main.swift", "code")
        try makeGitDir(src)
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .archivedDone)
        XCTAssertTrue(s.reason.contains("git repository"))
    }

    func testGitFileWorktreeAcceptedAsArchivedDone() throws {
        let src = try makeFixture(name: "worktree-project")
        try writeFile(src + "/main.swift", "code")
        // .git as regular file = worktree marker
        try writeFile(src + "/.git", "gitdir: /elsewhere/.git/worktrees/worktree-project")
        let s = try Archive.suggestTarget(src: src)
        XCTAssertEqual(s.category, .archivedDone)
        XCTAssertTrue(s.reason.contains("worktree"))
    }

    // MARK: - rule 4: ambiguous

    func testAmbiguousProjectThrowsWithoutForceCategory() throws {
        let src = try makeFixture(name: "no-git-no-empty")
        try writeFile(src + "/main.swift", "code")
        XCTAssertThrowsError(try Archive.suggestTarget(src: src)) { err in
            guard case ArchiveError.ambiguousProject(_, let nonDot, let hasGit) = err else {
                return XCTFail("expected ambiguousProject, got \(err)")
            }
            XCTAssertEqual(nonDot, 1)
            XCTAssertFalse(hasGit)
        }
    }

    // MARK: - forceCategory

    func testForceCategoryBypassesHeuristics() throws {
        let src = try makeFixture(name: "no-git-no-empty")
        try writeFile(src + "/main.swift", "code")
        let s = try Archive.suggestTarget(
            src: src,
            options: ArchiveOptions(forceCategory: "归档完成")
        )
        XCTAssertEqual(s.category, .archivedDone)
        XCTAssertTrue(s.dst.contains("/_archive/归档完成/"))
        XCTAssertTrue(s.reason.contains("user-specified"))
    }

    func testForceCategoryAcceptsEnglishAlias() throws {
        let src = try makeFixture(name: "anything")
        let s = try Archive.suggestTarget(
            src: src,
            options: ArchiveOptions(forceCategory: "archived-done")
        )
        // English alias normalizes to CJK on disk → produces 归档完成 path,
        // matches Round-4 fix that prevented English-named folders.
        XCTAssertEqual(s.category, .archivedDone)
        XCTAssertTrue(s.dst.contains("/_archive/归档完成/"), "got dst: \(s.dst)")
    }

    func testForceCategoryRejectsUnknown() throws {
        let src = try makeFixture(name: "anything")
        XCTAssertThrowsError(
            try Archive.suggestTarget(
                src: src,
                options: ArchiveOptions(forceCategory: "garbage")
            )
        ) { err in
            guard case ArchiveError.unknownForceCategory(let v) = err else {
                return XCTFail("expected unknownForceCategory, got \(err)")
            }
            XCTAssertEqual(v, "garbage")
        }
    }

    // MARK: - skipProbe + custom archiveRoot

    func testSkipProbeReturnsArchivedDoneDefault() throws {
        let s = try Archive.suggestTarget(
            src: tempRoot.appendingPathComponent("nonexistent").path,
            options: ArchiveOptions(skipProbe: true)
        )
        XCTAssertEqual(s.category, .archivedDone)
        XCTAssertTrue(s.reason.contains("probe skipped"))
    }

    func testCustomArchiveRoot() throws {
        let src = try makeFixture(name: "shell")
        let s = try Archive.suggestTarget(
            src: src,
            options: ArchiveOptions(archiveRoot: "/custom/_arc")
        )
        XCTAssertEqual(s.dst, "/custom/_arc/空项目/shell")
    }

    func testTrailingSlashInSrcStripped() throws {
        let src = try makeFixture(name: "shell")
        let withSlash = src + "//"
        let s = try Archive.suggestTarget(src: withSlash)
        // Basename must come from the un-slashed path.
        XCTAssertTrue(s.dst.hasSuffix("/shell"))
    }

    func testCannotReadSourceThrows() {
        // Probe a path that doesn't exist (no skipProbe, no force).
        XCTAssertThrowsError(
            try Archive.suggestTarget(src: "/no/such/path/orig")
        ) { err in
            guard case ArchiveError.cannotReadSource = err else {
                return XCTFail("expected cannotReadSource, got \(err)")
            }
        }
    }

    // MARK: - helpers

    private func makeFixture(name: String, contents: [String] = []) throws -> String {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in contents {
            try writeFile(dir.appendingPathComponent(entry).path, "x")
        }
        return dir.path
    }

    private func writeFile(_ path: String, _ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func makeGitDir(_ src: String) throws {
        let gitDir = (src as NSString).appendingPathComponent(".git")
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try writeFile((gitDir as NSString).appendingPathComponent("HEAD"), "ref: refs/heads/main")
    }
}
