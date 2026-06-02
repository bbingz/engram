import EngramCoreRead
import EngramCoreWrite
import GRDB
import XCTest

final class SchemaCompatibilityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-schema-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testManifestKeepsBaseAndLazyVectorTablesSeparate() {
        XCTAssertFalse(SchemaManifest.baseTables.contains("vec_sessions"))
        XCTAssertFalse(SchemaManifest.baseTables.contains("vec_chunks"))
        XCTAssertFalse(SchemaManifest.baseTables.contains("vec_insights"))
        XCTAssertTrue(SchemaManifest.lazyVectorTables.contains("vec_sessions"))
        XCTAssertEqual(SchemaManifest.lazyVectorMetadataKeys, ["vec_dimension", "vec_model"])
        XCTAssertEqual(SchemaManifest.schemaVersion, 1)
        XCTAssertEqual(SchemaManifest.ftsVersion, "3")
    }

    func testMigratedSchemaCoversManifestBaseTables() throws {
        // Pure-Swift schema gate: migrate a fresh DB and assert the manifest's
        // declared base tables/metadata are present, and that no lazy vector
        // table leaks into the base schema. Replaces the removed Node schema
        // gate (CLAUDE.md, 2026-05-08) so the product/runtime path is the
        // single source of truth.
        let writer = try EngramDatabaseWriter(path: tempDir.appendingPathComponent("schema.sqlite").path)
        try writer.migrate()

        let snapshot = try writer.read { db in
            try SchemaIntrospection.snapshot(db)
        }

        let missing = SchemaManifest.baseTables.subtracting(snapshot.tableNames)
        XCTAssertTrue(missing.isEmpty, "missing base tables: \(missing.sorted())")
        XCTAssertTrue(SchemaManifest.requiredMetadataKeys.isSubset(of: snapshot.metadataKeys))
        XCTAssertFalse(snapshot.tableNames.contains("vec_sessions"))
    }
}
