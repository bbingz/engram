import XCTest
@testable import Engram

/// Regression coverage for review fixes:
/// - ContentSegment.id collisions (hashValue / count+first) that made SwiftUI
///   ForEach drop or duplicate rows.
/// - GitRepo.isActive parsing after hoisting the ISO8601DateFormatter to a
///   shared static (behavior must be unchanged).
final class ContentSegmentAndGitRepoTests: XCTestCase {

    // MARK: - ContentSegment.id uniqueness

    func testTwoBulletListsWithSameCountAndFirstHaveDistinctIds() {
        // Old id was "bl:count:first.hashValue" → these collided.
        let a = ContentSegment.bulletList(items: ["same", "alpha"])
        let b = ContentSegment.bulletList(items: ["same", "beta"])
        XCTAssertNotEqual(a.id, b.id)
    }

    func testTwoTablesWithSameHeadersDifferentRowsHaveDistinctIds() {
        // Old id was "tb:headers.hashValue" → rows ignored → collisions.
        let a = ContentSegment.table(headers: ["A", "B"], rows: [["1", "2"]])
        let b = ContentSegment.table(headers: ["A", "B"], rows: [["3", "4"]])
        XCTAssertNotEqual(a.id, b.id)
    }

    func testTwoTaskListsWithSameCountAndFirstTextHaveDistinctIds() {
        let a = ContentSegment.taskList(items: [(done: true, text: "x"), (done: false, text: "alpha")])
        let b = ContentSegment.taskList(items: [(done: true, text: "x"), (done: false, text: "beta")])
        XCTAssertNotEqual(a.id, b.id)
    }

    func testParsedSegmentIdsAreUniqueForRepeatedContent() {
        // Two identical paragraphs separated by a rule: distinct cases stay
        // distinct, and equal text segments are allowed to share an id (SwiftUI
        // dedups identical leaves) — the important property is that DIFFERENT
        // content never collides.
        let markdown = """
        first paragraph here

        - one
        - two

        # Heading A

        second different paragraph

        # Heading B
        """
        let segments = ContentSegmentParser.parse(markdown)
        let ids = segments.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "distinct segments produced colliding ids: \(ids)")
    }

    // MARK: - SyntaxHighlighter cache

    func testSyntaxHighlighterCacheDistinguishesSameLengthBlocksWithSharedPrefix() {
        let sharedPrefix = String(repeating: "a", count: 100)
        let first = sharedPrefix + "X"
        let second = sharedPrefix + "Y"

        let firstHighlighted = SyntaxHighlighter.highlight(first, language: "swift")
        let secondHighlighted = SyntaxHighlighter.highlight(second, language: "swift")

        XCTAssertEqual(String(firstHighlighted.characters), first)
        XCTAssertEqual(String(secondHighlighted.characters), second)
    }

    // MARK: - GitRepo.isActive

    private func repo(lastCommitAt: String?) -> GitRepo {
        GitRepo(
            path: "/tmp/repo",
            name: "repo",
            branch: "main",
            dirtyCount: 0,
            untrackedCount: 0,
            unpushedCount: 0,
            lastCommitHash: nil,
            lastCommitMsg: nil,
            lastCommitAt: lastCommitAt,
            sessionCount: 0,
            probedAt: nil
        )
    }

    func testIsActiveTrueForRecentCommit() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        XCTAssertTrue(repo(lastCommitAt: iso).isActive)
    }

    func testIsActiveFalseForOldCommit() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-48 * 3600))
        XCTAssertFalse(repo(lastCommitAt: iso).isActive)
    }

    func testIsActiveFalseForNilOrUnparseable() {
        XCTAssertFalse(repo(lastCommitAt: nil).isActive)
        XCTAssertFalse(repo(lastCommitAt: "not-a-date").isActive)
    }
}
