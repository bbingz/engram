import XCTest
@testable import Engram

final class SessionTaxonomyTests: XCTestCase {
    func testClassifiesSubagentByAgentRoleAndSubagentPath() {
        XCTAssertTrue(
            SessionTaxonomyTag.subagent.matches(
                session(id: "agent-role", agentRole: "subagent"),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
        XCTAssertTrue(
            SessionTaxonomyTag.subagent.matches(
                session(id: "path", filePath: "/tmp/root/subagents/child.jsonl"),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
    }

    func testClassifiesWorkflowFromConfirmedChildCount() {
        let parent = session(id: "parent")

        XCTAssertTrue(
            SessionTaxonomyTag.workflow.matches(
                parent,
                confirmedChildCount: 2,
                suggestedChildCount: 0
            )
        )
    }

    func testHiddenHygieneStateIsNotProviderArchivedTaxonomy() {
        XCTAssertEqual(
            SessionTaxonomy.tags(
                for: session(id: "hidden", hiddenAt: "2026-07-02T01:00:00Z"),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            ),
            []
        )
    }

    func testClassifiesCodexArchivedSessionPathAsSideAndArchived() {
        XCTAssertEqual(
            SessionTaxonomy.tags(
                for: session(
                    id: "codex-archived",
                    filePath: "/Users/test/.codex/archived_sessions/rollout-2026-07-02T01-00-00-019f.jsonl"
                ),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            ),
            [.side, .archived]
        )
    }

    func testClassifiesOrphanSubagentWithoutAnyParent() {
        let orphan = session(id: "orphan", agentRole: "subagent")
        let suggested = session(id: "suggested", agentRole: "subagent", suggestedParentId: "parent")
        let confirmed = session(id: "confirmed", agentRole: "subagent", parentSessionId: "parent")

        XCTAssertTrue(
            SessionTaxonomyTag.orphan.matches(
                orphan,
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
        XCTAssertFalse(
            SessionTaxonomyTag.orphan.matches(
                suggested,
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
        XCTAssertFalse(
            SessionTaxonomyTag.orphan.matches(
                confirmed,
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
    }

    func testClassifiesSuggestedParentForParentCandidatesAndChildSuggestions() {
        XCTAssertTrue(
            SessionTaxonomyTag.suggestedParent.matches(
                session(id: "candidate"),
                confirmedChildCount: 0,
                suggestedChildCount: 1
            )
        )
        XCTAssertTrue(
            SessionTaxonomyTag.suggestedParent.matches(
                session(id: "child", suggestedParentId: "candidate"),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
    }

    func testSideTaxonomyMatchesReadOnlyCodexSideShape() {
        XCTAssertTrue(
            SessionTaxonomyTag.side.isSupported
        )
        XCTAssertTrue(
            SessionTaxonomyTag.side.matches(
                session(id: "side", filePath: "/Users/test/.codex/archived_sessions/side-019f.jsonl"),
                confirmedChildCount: 0,
                suggestedChildCount: 0
            )
        )
    }

    func testSessionDetailRendersTaxonomyBadges() throws {
        let sourcePath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Engram/Views/SessionDetailView.swift")
        let source = try String(contentsOf: sourcePath)

        XCTAssertTrue(source.contains("taxonomyBadgesSection"))
        XCTAssertTrue(source.contains("SessionTaxonomyBadges("))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(\"detail_taxonomyBadges\")"))
    }

    private func session(
        id: String,
        agentRole: String? = nil,
        hiddenAt: String? = nil,
        parentSessionId: String? = nil,
        suggestedParentId: String? = nil,
        filePath: String? = nil
    ) -> Session {
        Session(
            id: id,
            source: "codex",
            startTime: "2026-07-02T01:00:00Z",
            endTime: nil,
            cwd: "/tmp/engram",
            project: "engram",
            model: nil,
            messageCount: 2,
            userMessageCount: 1,
            assistantMessageCount: 1,
            systemMessageCount: 0,
            summary: nil,
            filePath: filePath ?? "/tmp/\(id).jsonl",
            sourceLocator: nil,
            sizeBytes: 128,
            indexedAt: "2026-07-02T01:00:00Z",
            agentRole: agentRole,
            hiddenAt: hiddenAt,
            customName: nil,
            tier: nil,
            toolMessageCount: 0,
            generatedTitle: id,
            parentSessionId: parentSessionId,
            suggestedParentId: suggestedParentId,
            linkSource: nil,
            qualityScore: nil
        )
    }
}
