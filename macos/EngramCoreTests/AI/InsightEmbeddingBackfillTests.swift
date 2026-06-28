import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

private struct FakeEmbeddingProvider: EmbeddingProvider {
    let model = "fake-model"
    let dimension = 3
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in VectorMath.l2Normalize([Float(text.count), 1, 0]) }
    }
}

final class InsightEmbeddingBackfillTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-embed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testBackfillEmbedsPendingInsightsExactlyOnce() async throws {
        let path = tempDir.appendingPathComponent("embed.sqlite").path
        let writer = try EngramDatabaseWriter(path: path)
        try writer.migrate()
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO insights (id, content, importance)
                VALUES ('i1', 'first insight content', 5), ('i2', 'second insight content here', 5)
            """)
        }

        let provider = FakeEmbeddingProvider()
        let first = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        XCTAssertEqual(first, .init(embedded: 2))

        try writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insight_embeddings"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dimension FROM embedding_meta WHERE id = 1"), 3)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT model FROM insight_embeddings WHERE insight_id = 'i1'"),
                "fake-model"
            )
            let blob: Data? = try Row.fetchOne(db, sql: "SELECT embedding FROM insight_embeddings WHERE insight_id = 'i1'")?["embedding"]
            XCTAssertEqual(VectorMath.decode(try XCTUnwrap(blob)).count, 3)
        }

        // Nothing pending on the second run.
        let second = try await InsightEmbeddingBackfill.run(writer: writer, provider: provider)
        XCTAssertEqual(second, .init(embedded: 0))
    }
}
