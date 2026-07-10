import EngramCoreRead
import Foundation
import GRDB
import XCTest

/// Wave 8A lane 1A unit coverage for H07 model equality helpers, M09
/// constant-memory top-K accumulation, and shared semantic policy contracts.
final class SessionSemanticSearchIntegrityTests: XCTestCase {
    // MARK: - H07 query compatibility

    func testQueryCompatibilityRequiresExactModelAndDimensionMatch() {
        let snapshot = SessionVectorSearchAvailability.Snapshot(
            isUsable: true,
            model: "model-a",
            dimension: 3
        )

        let mismatch = SessionVectorSearchAvailability.queryCompatibility(
            configuredModel: "model-b",
            configuredDimension: 3,
            snapshot: snapshot
        )
        guard case let .modelMismatch(cfgModel, cfgDim, storedModel, storedDim) = mismatch else {
            return XCTFail("expected modelMismatch, got \(mismatch)")
        }
        XCTAssertEqual(cfgModel, "model-b")
        XCTAssertEqual(cfgDim, 3)
        XCTAssertEqual(storedModel, "model-a")
        XCTAssertEqual(storedDim, 3)

        let compatible = SessionVectorSearchAvailability.queryCompatibility(
            configuredModel: "model-a",
            configuredDimension: 3,
            snapshot: snapshot
        )
        guard case let .compatible(model, dimension) = compatible else {
            return XCTFail("expected compatible, got \(compatible)")
        }
        XCTAssertEqual(model, "model-a")
        XCTAssertEqual(dimension, 3)
    }

    func testQueryCompatibilityReportsCorpusUnavailableWhenSnapshotUnusable() {
        let result = SessionVectorSearchAvailability.queryCompatibility(
            configuredModel: "model-a",
            configuredDimension: 3,
            snapshot: .unavailable
        )
        XCTAssertEqual(result, .corpusUnavailable)
    }

    // MARK: - M09 constant-memory top-K

    func testAccumulateTopKKeepsHighestScoresAndBoundedSize() {
        var top: [SessionSemanticSearchPolicy.ScoredChunk] = []
        let chunks: [(String, Float)] = [
            ("a", 0.1),
            ("b", 0.9),
            ("c", 0.5),
            ("d", 0.95),
            ("e", 0.4),
        ]
        for (id, score) in chunks {
            SessionSemanticSearchPolicy.accumulateTopK(
                &top,
                incoming: SessionSemanticSearchPolicy.ScoredChunk(
                    id: id,
                    score: score,
                    sessionId: id,
                    text: id
                ),
                topK: 3
            )
            XCTAssertLessThanOrEqual(top.count, 3)
        }
        XCTAssertEqual(top.map(\.id), ["d", "b", "c"])
        XCTAssertEqual(top.map(\.score), [0.95, 0.9, 0.5])
    }

    func testCandidateBatchSizeIsBoundedAndNotRecencyEligibilityCap() {
        // Batch size may grow with request limit but must stay a paging size,
        // not a hard corpus eligibility ceiling (former max was 2000).
        let small = SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: 5)
        let large = SessionSemanticSearchPolicy.candidateBatchSize(requestLimit: 100)
        XCTAssertGreaterThanOrEqual(small, 64)
        XCTAssertLessThanOrEqual(small, 512)
        XCTAssertLessThanOrEqual(large, 512)
        XCTAssertGreaterThanOrEqual(large, small)
    }

    func testSemanticDegradeReasonWarningsNameConcreteCause() {
        XCTAssertTrue(
            SessionVectorSearchAvailability.SemanticDegradeReason.providerUnavailable
                .serviceWarning
                .localizedCaseInsensitiveContains("provider")
        )
        XCTAssertTrue(
            SessionVectorSearchAvailability.SemanticDegradeReason.corpusMissing
                .serviceWarning
                .localizedCaseInsensitiveContains("corpus")
        )
        XCTAssertTrue(
            SessionVectorSearchAvailability.SemanticDegradeReason.modelMismatch
                .serviceWarning(detail: "configured model-b vs stored model-a")
                .localizedCaseInsensitiveContains("model-b")
        )
        XCTAssertTrue(
            SessionVectorSearchAvailability.SemanticDegradeReason.breakerOpen
                .serviceWarning
                .localizedCaseInsensitiveContains("breaker")
        )
        XCTAssertTrue(
            SessionVectorSearchAvailability.SemanticDegradeReason.breakerOpen
                .memoryWarning
                .localizedCaseInsensitiveContains("breaker")
        )
        XCTAssertFalse(
            SessionVectorSearchAvailability.SemanticDegradeReason.breakerOpen
                .memoryWarning
                .localizedCaseInsensitiveContains("No embedding provider")
        )
        XCTAssertEqual(
            SessionVectorSearchAvailability.SemanticDegradeReason.modelMismatch.structuredCode,
            "embeddingModelMismatch"
        )
    }

    // MARK: - Availability probe still requires matching corpus

    func testProbeIsUsableOnlyWithMetaAndCompatibleChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-avail-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE embedding_meta (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  provider TEXT, model TEXT, dimension INTEGER,
                  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE TABLE semantic_chunks (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL,
                  chunk_index INTEGER NOT NULL,
                  text TEXT NOT NULL,
                  embedding BLOB,
                  model TEXT,
                  dim INTEGER,
                  created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO embedding_meta (id, provider, model, dimension)
                VALUES (1, 'test', 'model-a', 3);
                """)
        }
        XCTAssertFalse(SessionVectorSearchAvailability.probe(databasePath: url.path).isUsable)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO semantic_chunks(id, session_id, chunk_index, text, embedding, model, dim)
                VALUES ('c0', 's0', 0, 't', ?, 'model-a', 3)
                """,
                arguments: [VectorMath.encode([1, 0, 0])]
            )
        }
        let usable = SessionVectorSearchAvailability.probe(databasePath: url.path)
        XCTAssertTrue(usable.isUsable)
        XCTAssertEqual(usable.model, "model-a")
        XCTAssertEqual(usable.dimension, 3)
    }
}
