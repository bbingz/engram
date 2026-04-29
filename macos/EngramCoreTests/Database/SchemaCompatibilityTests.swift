import EngramCoreRead
import EngramCoreWrite
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

    func testNodeReferenceSchemaEmissionCoversManifestBaseTables() throws {
        let output = tempDir.appendingPathComponent("node-schema.json")
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(repoRoot)/node_modules/.bin/tsx")
        process.arguments = [
            "scripts/db/emit-current-schema.ts",
            "--out",
            output.path,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        let tables = json?["tables"] as? [String: Any] ?? [:]
        let missing = SchemaManifest.baseTables.subtracting(Set(tables.keys))
        XCTAssertTrue(missing.isEmpty, "missing base tables: \(missing.sorted())")
        XCTAssertNil(tables["vec_sessions"])
    }
}
