import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

final class WatcherSemanticsTests: XCTestCase {
    func testWatchRulesMirrorNodeRootsAndIgnoredPaths() throws {
        let home = "/tmp/engram-home"

        XCTAssertEqual(
            WatchPathRules.watchEntries(home: home),
            [
                WatchEntry(path: "/tmp/engram-home/.codex/sessions", source: .codex),
                WatchEntry(path: "/tmp/engram-home/.codex/archived_sessions", source: .codex),
                WatchEntry(path: "/tmp/engram-home/.claude/projects", source: .claudeCode),
                WatchEntry(path: "/tmp/engram-home/.gemini/tmp", source: .geminiCli),
                WatchEntry(path: "/tmp/engram-home/.gemini/antigravity", source: .antigravity),
                WatchEntry(path: "/tmp/engram-home/.iflow/projects", source: .iflow),
                WatchEntry(path: "/tmp/engram-home/.qwen/projects", source: .qwen),
                WatchEntry(path: "/tmp/engram-home/.kimi/sessions", source: .kimi),
                WatchEntry(path: "/tmp/engram-home/.pi/agent/sessions", source: .pi),
                WatchEntry(path: "/tmp/engram-home/.cline/data/tasks", source: .cline)
            ]
        )
        XCTAssertTrue(WatchPathRules.watchedSources.contains(.codex))
        XCTAssertTrue(WatchPathRules.watchedSources.contains(.claudeCode))
        XCTAssertTrue(WatchPathRules.isIgnored("/tmp/engram-home/.gemini/tmp/proj/tool-outputs/run_shell_command_1.txt"))
        XCTAssertTrue(WatchPathRules.isIgnored("/tmp/repo/node_modules/pkg/index.js"))
        XCTAssertTrue(WatchPathRules.isIgnored("/tmp/repo/.DS_Store"))
        XCTAssertFalse(WatchPathRules.isIgnored("/tmp/engram-home/.codex/sessions/session.jsonl"))
        XCTAssertEqual(WatchPathRules.source(for: "/tmp/engram-home/.codex/archived_sessions/rollout.jsonl", home: home), .codex)

        let fixture = try WatchBatchConfig.load(
            from: repoRoot().appendingPathComponent("tests/fixtures/adapter-parity/batch-sizes.json")
        )
        XCTAssertEqual(fixture.writeStabilityMilliseconds, 2_000)
        XCTAssertEqual(fixture.pollMilliseconds, 500)
        XCTAssertEqual(fixture.maxDrainBatchSize, 500)
    }

    func testWriteStabilityCoalescesDuplicatesAndDrainsMaxBatchFromFixture() async throws {
        let home = "/tmp/engram-home"
        let clock = ManualWatcherClock()
        let indexer = RecordingWatchIndexer()
        let watcher = SessionWatcher(
            home: home,
            indexer: indexer,
            orphanMarker: RecordingWatchOrphanMarker(),
            clock: clock,
            config: WatchBatchConfig(writeStabilityMilliseconds: 2_000, pollMilliseconds: 500, maxDrainBatchSize: 500)
        )

        try await watcher.observe(.changed(path: "\(home)/.codex/sessions/dup.jsonl", sizeBytes: 10, modifiedAtMilliseconds: 1))
        try await watcher.observe(.changed(path: "\(home)/.codex/sessions/dup.jsonl", sizeBytes: 11, modifiedAtMilliseconds: 2))
        for idx in 0..<500 {
            try await watcher.observe(.added(path: "\(home)/.codex/sessions/\(idx).jsonl", sizeBytes: Int64(idx + 1), modifiedAtMilliseconds: 3))
        }

        clock.nowMilliseconds = 1_999
        let notReady = try await watcher.drainReady()
        XCTAssertTrue(notReady.isEmpty)
        XCTAssertTrue(indexer.indexedFiles.isEmpty)

        clock.nowMilliseconds = 2_002
        let firstBatch = try await watcher.drainReady()
        XCTAssertEqual(firstBatch.count, 500)
        XCTAssertEqual(indexer.indexedFiles.count, 500)

        let secondBatch = try await watcher.drainReady()
        XCTAssertEqual(secondBatch.count, 1)
        XCTAssertEqual(indexer.indexedFiles.count, 501)
        XCTAssertEqual(indexer.indexedFiles.filter { $0.path.hasSuffix("dup.jsonl") }.count, 1)
    }

    func testUnlinkUsesProjectMoveSkipAndMarksOrphansOnlyWhenTouched() async throws {
        let home = "/tmp/engram-home"
        let marker = RecordingWatchOrphanMarker()
        marker.touchedByPath["\(home)/.codex/sessions/known.jsonl"] = 2
        let watcher = SessionWatcher(
            home: home,
            indexer: RecordingWatchIndexer(),
            orphanMarker: marker,
            shouldSkip: { $0.contains("moving") }
        )
        var events: [SessionWatchEvent] = []

        events += try await watcher.observe(.unlinked(path: "\(home)/.codex/sessions/moving.jsonl"))
        events += try await watcher.observe(.unlinked(path: "\(home)/.codex/sessions/unknown.jsonl"))
        events += try await watcher.observe(.unlinked(path: "\(home)/.codex/sessions/known.jsonl"))

        XCTAssertEqual(marker.markedPaths, ["\(home)/.codex/sessions/unknown.jsonl", "\(home)/.codex/sessions/known.jsonl"])
        XCTAssertEqual(events, [.orphaned(path: "\(home)/.codex/sessions/known.jsonl", sessions: 2)])
    }

    func testDirectoryRenameTriggersSubtreeRescanAndSymlinkTargetChangesAreIgnored() async throws {
        let home = "/tmp/engram-home"
        let indexer = RecordingWatchIndexer()
        let watcher = SessionWatcher(home: home, indexer: indexer, orphanMarker: RecordingWatchOrphanMarker())

        let events = try await watcher.observe(
            .directoryRenamed(
                oldPath: "\(home)/.claude/projects/old",
                newPath: "\(home)/.claude/projects/new"
            )
        )
        let ignored = try await watcher.observe(.symlinkTargetChanged(path: "\(home)/.claude/projects/link"))

        XCTAssertEqual(indexer.rescannedSubtrees, [WatchIndexRequest(source: .claudeCode, path: "\(home)/.claude/projects/new")])
        XCTAssertEqual(events, [.subtreeRescan(path: "\(home)/.claude/projects/new", source: .claudeCode)])
        XCTAssertTrue(ignored.isEmpty)
    }

    func testNonWatchableRescannerIndexesOnlyNonWatchedSourcesAndEmitsRescan() async throws {
        let indexer = RecordingNonWatchableIndexer(indexed: 3)
        let jobs = RecordingNonWatchableJobs()
        let rescanner = NonWatchableSourceRescanner(
            allSources: [.codex, .cursor, .vscode, .windsurf, .copilot],
            indexer: indexer,
            indexJobRunner: jobs,
            totalCount: { 30 },
            todayParentCount: { 4 }
        )

        let events = try await rescanner.rescanNow()

        XCTAssertEqual(indexer.sources, [.cursor, .vscode, .windsurf, .copilot])
        XCTAssertEqual(events, [StartupBackfillEvent(event: "rescan", payload: ["indexed": .int(3), "total": .int(30), "todayParents": .int(4)])])
        XCTAssertEqual(jobs.recoverableRuns, 1)
        XCTAssertEqual(NonWatchableSourceRescanner.defaultIntervalMilliseconds, 600_000)
    }
}

private func repoRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class ManualWatcherClock: WatcherClock {
    var nowMilliseconds = 0
}

private final class RecordingWatchIndexer: SessionWatchIndexing {
    var indexedFiles: [WatchIndexRequest] = []
    var rescannedSubtrees: [WatchIndexRequest] = []

    func indexFile(source: SourceName, path: String) async throws -> SessionWatchIndexResult {
        indexedFiles.append(WatchIndexRequest(source: source, path: path))
        return SessionWatchIndexResult(indexed: true, sessionId: URL(fileURLWithPath: path).lastPathComponent)
    }

    func rescanSubtree(source: SourceName, root: String) async throws {
        rescannedSubtrees.append(WatchIndexRequest(source: source, path: root))
    }
}

private final class RecordingWatchOrphanMarker: SessionWatchOrphanMarking {
    var touchedByPath: [String: Int] = [:]
    var markedPaths: [String] = []

    func markOrphanByPath(_ path: String, reason: SessionWatchOrphanReason) throws -> Int {
        XCTAssertEqual(reason, .cleanedBySource)
        markedPaths.append(path)
        return touchedByPath[path] ?? 0
    }
}

private final class RecordingNonWatchableIndexer: NonWatchableIndexing {
    var indexed: Int
    var sources: Set<SourceName> = []

    init(indexed: Int) {
        self.indexed = indexed
    }

    func indexAll(sources: Set<SourceName>) async throws -> Int {
        self.sources = sources
        return indexed
    }
}

private final class RecordingNonWatchableJobs: NonWatchableIndexJobRunning {
    var recoverableRuns = 0

    func runRecoverableJobs() async {
        recoverableRuns += 1
    }
}
