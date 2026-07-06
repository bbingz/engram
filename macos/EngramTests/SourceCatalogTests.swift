import XCTest
@testable import Engram

final class SourceCatalogTests: XCTestCase {
    // MARK: - Catalog shape

    func testCatalogHasSeventeenEntries() {
        XCTAssertEqual(SourceCatalog.all.count, 17)
    }

    func testArchivedDefaultOffCatalogEntriesAreExplicit() {
        let archived = Set(SourceCatalog.all.filter(\.archivedByDefault).map(\.id))

        XCTAssertEqual(archived, ArchivedDefaultOffSources.ids)
        XCTAssertEqual(archived, ["cline", "iflow", "lobsterai"])
        XCTAssertFalse(archived.contains("minimax"), "minimax is active and must not be default-off archived")
    }

    func testCatalogIDsAreUnique() {
        let ids = SourceCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryCatalogIDResolvesThroughLongLabel() {
        for entry in SourceCatalog.all {
            let label = SourceColors.longLabel(for: entry.id)
            XCTAssertFalse(label.isEmpty, "\(entry.id) has no display label")
            // A resolved id maps to a human name, not the raw id passthrough.
            XCTAssertNotEqual(label, entry.id, "\(entry.id) falls through to its raw id")
        }
    }

    func testCacheOnlyIsTrueExactlyForLiveSyncDisabledSources() {
        let cacheOnly = Set(SourceCatalog.all.filter(\.cacheOnly).map(\.id))
        XCTAssertEqual(cacheOnly, LiveSyncDisabledSources.ids)
        XCTAssertEqual(cacheOnly, ["windsurf", "antigravity"])
    }

    // MARK: - Merge / overlay

    private func liveSource(_ id: String, sessions: Int, health: String) -> EngramServiceSourceInfo {
        EngramServiceSourceInfo(
            name: id,
            sessionCount: sessions,
            latestIndexed: "2026-06-21T00:00:00Z",
            searchCoveragePercent: 100,
            healthStatus: health
        )
    }

    func testMergeCoversAllCatalogIDs() {
        let live = [
            liveSource("claude-code", sessions: 12, health: "healthy"),
            liveSource("codex", sessions: 4, health: "healthy"),
        ]
        let rows = SourcePulseView.mergedSourceRows(catalog: SourceCatalog.all, live: live)

        // Every catalog id is present, in catalog order, exactly once.
        XCTAssertEqual(rows.map(\.id), SourceCatalog.all.map(\.id))
    }

    func testMergeMarksDetectedSourcesWithLiveHealth() {
        let live = [liveSource("claude-code", sessions: 12, health: "healthy")]
        let rows = SourcePulseView.mergedSourceRows(catalog: SourceCatalog.all, live: live)

        guard case let .detected(info)? = rows.first(where: { $0.id == "claude-code" }) else {
            return XCTFail("claude-code should be a detected row")
        }
        XCTAssertEqual(info.sessionCount, 12)
        XCTAssertEqual(info.healthStatus, "healthy")
    }

    func testMergeMarksUndetectedCatalogSourcesNotDetected() {
        // No live rows at all → every catalog source is catalog-only.
        let rows = SourcePulseView.mergedSourceRows(catalog: SourceCatalog.all, live: [])

        guard case let .catalogOnly(entry)? = rows.first(where: { $0.id == "windsurf" }) else {
            return XCTFail("windsurf should be catalog-only when no live row exists")
        }
        XCTAssertEqual(entry.defaultPath, "~/.engram/cache/windsurf")
        XCTAssertTrue(entry.cacheOnly)
    }

    func testMergeAppendsLiveSourcesMissingFromCatalog() {
        let live = [liveSource("ghost-source", sessions: 1, health: "healthy")]
        let rows = SourcePulseView.mergedSourceRows(catalog: SourceCatalog.all, live: live)

        XCTAssertEqual(rows.count, SourceCatalog.all.count + 1)
        XCTAssertEqual(rows.last?.id, "ghost-source")
    }

    func testSourceRowsSplitActiveAndArchivedDefaultOffGroups() {
        let live = [
            liveSource("minimax", sessions: 234, health: "healthy"),
            liveSource("cline", sessions: 3, health: "healthy"),
        ]

        let groups = SourcePulseView.groupedSourceRows(catalog: SourceCatalog.all, live: live)

        XCTAssertEqual(groups.map(\.id), ["active", "archived"])
        let activeIDs = groups.first(where: { $0.id == "active" })?.rows.map(\.id) ?? []
        let archivedIDs = groups.first(where: { $0.id == "archived" })?.rows.map(\.id) ?? []
        XCTAssertTrue(activeIDs.contains("minimax"))
        XCTAssertFalse(activeIDs.contains("cline"))
        XCTAssertEqual(Set(archivedIDs), ["cline", "iflow", "lobsterai"])
    }
}
