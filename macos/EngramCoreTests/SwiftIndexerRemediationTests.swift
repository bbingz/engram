import Foundation
import XCTest
@testable import EngramCoreRead
@testable import EngramCoreWrite

/// Regression coverage for the SwiftIndexer known-locator fast-path remediation:
///  (1) a `file_index_state` row older than `FileIndexState.currentSchemaVersion`
///      must force a real re-parse instead of silently re-recording the new
///      version, so the version bump actually flushes the old parser's stale
///      counts.
///  (2) a session whose stored `size_bytes` intentionally diverges from the raw
///      file size (Antigravity pb-size, Kimi shard sums, cross-source rows) must
///      NOT be re-parsed on every scan just because of that permanent mismatch.
///  (3) duplicate session ids straddling the 100-item write batch boundary must
///      be deduplicated once over the whole run (first-in-run wins).
final class SwiftIndexerRemediationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-indexer-remediation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    private func makeFile(_ name: String, contents: String, modifiedAt: Date? = nil) throws -> (path: String, stat: FileIndexStat) {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        let stat = try XCTUnwrap(FileIndexStat.directFileStat(locator: url.path))
        return (url.path, stat)
    }

    // (1) A stale-schema parse state must force a real re-parse. The known-locator
    // fast path used to re-record a fresh v2 state without parsing, consuming the
    // version bump and leaving the old counts in place.
    func testStaleSchemaVersionForcesReparseOnKnownLocatorFastPath() async throws {
        let file = try makeFile("stale-schema.jsonl", contents: #"{"role":"user","content":"hello"}"#)

        // Session size matches the file size → the size-based repair signal is
        // NOT what drives this test; the stale schema version is.
        var parseState = FileIndexState.success(source: .claudeCode, locator: file.path, stat: file.stat, now: Date())
        parseState.schemaVersion = FileIndexState.currentSchemaVersion - 1

        let sink = RemediationSink(
            knownIndexed: [
                file.path: KnownIndexedFileState(sizeBytes: file.stat.sizeBytes, indexedAt: "2999-01-01T00:00:00Z")
            ],
            knownParse: [file.path: parseState]
        )
        let adapter = RemediationCountingAdapter(source: .claudeCode, locator: file.path, sizeBytes: file.stat.sizeBytes)
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: true
        )

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(adapter.parseCount, 1, "stale schema version must force a re-parse, not a silent v2 re-record")
        // The re-parse records a fresh parse state at the current schema version.
        let recorded = try XCTUnwrap(sink.upsertedStates.last)
        XCTAssertEqual(recorded.schemaVersion, FileIndexState.currentSchemaVersion)
    }

    // (2) A present session whose stored size intentionally diverges from the raw
    // file size must not re-parse forever. The file is aged past the active-file
    // grace window so only the (now fixed) repair signal could trigger a parse.
    func testSizeDivergentCurrentSchemaRowDoesNotPerpetuallyReparse() async throws {
        let file = try makeFile(
            "divergent-size.jsonl",
            contents: #"{"role":"user","content":"hello"}"#,
            modifiedAt: Date(timeIntervalSince1970: 978_307_200) // 2001-01-01, well past the 120s grace
        )

        // Parse state is OK, identity matches, schema current.
        let parseState = FileIndexState.success(source: .antigravity, locator: file.path, stat: file.stat, now: Date())
        // Session size_bytes intentionally differs from the file size (pb-size).
        let sink = RemediationSink(
            knownIndexed: [
                file.path: KnownIndexedFileState(sizeBytes: file.stat.sizeBytes + 4_096, indexedAt: "2999-01-01T00:00:00Z")
            ],
            knownParse: [file.path: parseState]
        )
        let adapter = RemediationCountingAdapter(
            source: .antigravity,
            locator: file.path,
            sizeBytes: file.stat.sizeBytes + 4_096
        )
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: true
        )

        // Two consecutive runs: an expected size divergence must never accumulate
        // re-parses (the old behavior parsed once per scan → never converged).
        let first = try await indexer.indexAll()
        let second = try await indexer.indexAll()

        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(adapter.parseCount, 0, "expected size divergence must not force a re-parse")
    }

    // (2b) Boundary: a NON-divergent source whose present session has a genuine
    // stale size_bytes must STILL be repaired (real staleness detection must not
    // be broken by the divergent-source guard).
    func testSizeMismatchStillRepairsNonDivergentSource() async throws {
        let file = try makeFile(
            "stale-non-divergent.jsonl",
            contents: #"{"role":"user","content":"hello"}"#,
            modifiedAt: Date(timeIntervalSince1970: 978_307_200) // 2001-01-01, past the grace window
        )

        let parseState = FileIndexState.success(source: .codex, locator: file.path, stat: file.stat, now: Date())
        // Present session with a stale (mismatched) size for a source that tracks
        // the raw file size → this is a genuine staleness signal.
        let sink = RemediationSink(
            knownIndexed: [
                file.path: KnownIndexedFileState(sizeBytes: file.stat.sizeBytes + 7, indexedAt: "2999-01-01T00:00:00Z")
            ],
            knownParse: [file.path: parseState]
        )
        let adapter = RemediationCountingAdapter(source: .codex, locator: file.path, sizeBytes: file.stat.sizeBytes)
        let indexer = SwiftIndexer(
            sink: sink,
            adapters: [adapter],
            skipUnchangedFileLocators: true,
            skipKnownFileLocators: true
        )

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(adapter.parseCount, 1, "a stale present session on a file-size-tracking source must still repair")
    }

    // (3) Duplicate session ids that straddle the 100-item batch boundary must be
    // deduplicated once across the whole run, not per batch.
    func testDuplicateSessionIdAcrossBatchBoundaryDeduplicatesOnce() async throws {
        // 101 sessions: id "dup" at index 0 (batch 1) and index 100 (batch 2),
        // 99 unique ids in between. Per-batch dedup would write "dup" twice.
        var ids: [String] = ["dup"]
        ids.append(contentsOf: (1...99).map { "u\($0)" })
        ids.append("dup")
        XCTAssertEqual(ids.count, 101)

        let sink = RemediationSink()
        let adapter = RemediationBoundaryAdapter(ids: ids)
        let indexer = SwiftIndexer(sink: sink, adapters: [adapter])

        let indexed = try await indexer.indexAll()

        XCTAssertEqual(indexed, 100, "the boundary-straddling duplicate must be dropped once over the run")
        XCTAssertEqual(sink.upsertedSnapshotCount, 100)
    }
}

private final class RemediationSink: IndexingWriteSink {
    let knownIndexed: [String: KnownIndexedFileState]
    let knownParse: [String: FileIndexState]
    private(set) var upsertedStates: [FileIndexState] = []
    private(set) var upsertedSnapshotCount = 0

    init(
        knownIndexed: [String: KnownIndexedFileState] = [:],
        knownParse: [String: FileIndexState] = [:]
    ) {
        self.knownIndexed = knownIndexed
        self.knownParse = knownParse
    }

    func upsertBatch(
        _ snapshots: [AuthoritativeSessionSnapshot],
        reason: IndexingWriteReason
    ) throws -> SessionBatchUpsertResult {
        upsertedSnapshotCount += snapshots.count
        return SessionBatchUpsertResult(
            reason: reason,
            results: snapshots.map {
                SessionBatchItemResult(sessionId: $0.id, action: .merge, enqueuedJobs: [])
            }
        )
    }

    func knownIndexedFileStates(source: SourceName, locators: [String]) throws -> [String: KnownIndexedFileState] {
        knownIndexed.filter { locators.contains($0.key) }
    }

    func knownFileIndexStates(source: SourceName, locators: [String]) throws -> [String: FileIndexState] {
        knownParse.filter { locators.contains($0.key) }
    }

    func upsertFileIndexState(_ state: FileIndexState) throws {
        upsertedStates.append(state)
    }
}

private final class RemediationCountingAdapter: SessionAdapter {
    let source: SourceName
    let locator: String
    let sizeBytes: Int64
    private(set) var parseCount = 0

    init(source: SourceName = .claudeCode, locator: String, sizeBytes: Int64) {
        self.source = source
        self.locator = locator
        self.sizeBytes = sizeBytes
    }

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] { [locator] }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        parseCount += 1
        return .success(
            NormalizedSessionInfo(
                id: "remediation-session",
                source: source,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: sizeBytes
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hello"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool { true }
}

private final class RemediationBoundaryAdapter: SessionAdapter {
    let source: SourceName = .codex
    let ids: [String]

    init(ids: [String]) { self.ids = ids }

    func detect() async -> Bool { true }

    func listSessionLocators() async throws -> [String] {
        ids.indices.map { "synthetic://\($0)" }
    }

    func parseSessionInfo(locator: String) async throws -> AdapterParseResult<NormalizedSessionInfo> {
        let index = Int(locator.replacingOccurrences(of: "synthetic://", with: "")) ?? 0
        return .success(
            NormalizedSessionInfo(
                id: ids[index],
                source: source,
                startTime: "2026-04-24T00:00:00Z",
                cwd: "/repo",
                model: "synthetic",
                messageCount: 1,
                userMessageCount: 1,
                assistantMessageCount: 0,
                toolMessageCount: 0,
                systemMessageCount: 0,
                summary: "hello",
                filePath: locator,
                sizeBytes: 10
            )
        )
    }

    func streamMessages(
        locator: String,
        options: StreamMessagesOptions
    ) async throws -> AsyncThrowingStream<NormalizedMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(NormalizedMessage(role: .user, content: "hello"))
            continuation.finish()
        }
    }

    func isAccessible(locator: String) async -> Bool { true }
}
