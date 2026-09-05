import XCTest
import GRDB

enum FixtureAssertions {
    @discardableResult
    static func requireRowCount(
        _ table: String,
        minimum: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let path = TestLaunchConfig.fixtureDBPath
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "Fixture DB missing: \(path)",
            file: file,
            line: line
        )

        let count = fixtureRowCount(
            table,
            path: path,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            count,
            minimum,
            "Fixture table \(table) should contain test data",
            file: file,
            line: line
        )
        return count
    }

    private static func fixtureRowCount(
        _ table: String,
        path: String,
        file: StaticString,
        line: UInt
    ) -> Int {
        do {
            let database = try DatabaseQueue()
            let immutableURI = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
            return try database.writeWithoutTransaction { db in
                try db.execute(
                    sql: "ATTACH DATABASE ? AS fixture",
                    arguments: [immutableURI]
                )
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM fixture.\(table.quotedDatabaseIdentifier)"
                ) ?? 0
            }
        } catch {
            XCTFail("Fixture DB query failed: \(error)", file: file, line: line)
            return 0
        }
    }
}
