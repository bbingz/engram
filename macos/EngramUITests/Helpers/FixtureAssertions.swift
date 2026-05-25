import XCTest

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

        let count = sqliteScalar(
            "SELECT COUNT(*) FROM \(table);",
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

    private static func sqliteScalar(
        _ query: String,
        path: String,
        file: StaticString,
        line: UInt
    ) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path, query]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            XCTFail("Failed to run sqlite3: \(error)", file: file, line: line)
            return 0
        }

        let errorOutput = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "sqlite3 fixture query failed: \(errorOutput)",
            file: file,
            line: line
        )

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(output) ?? 0
    }
}
