import XCTest

final class ModuleBoundaryTests: XCTestCase {
    func testDefaultHomeCallersUseHermeticResolver_repro() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected: [(String, String)] = [
            ("EngramService/Core/EngramServiceReadProvider.swift", "EngramUserDataDirectory.resolvedHomeDirectory()"),
            ("EngramService/Core/ArchiveReclamationCoordinator.swift", "EngramUserDataDirectory.resolvedHomeDirectory(environment: environment)"),
            ("EngramService/Core/EngramServiceRunner.swift", "let serviceHome = isTestProcess"),
            ("EngramCoreWrite/UserDataBackup.swift", "EngramUserDataDirectory.resolvedHomeDirectory(environment: environment)"),
        ]

        for (relativePath, requiredText) in expected {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(source.contains(requiredText), "\(relativePath) must use the hermetic home resolver")
        }
    }
    func testWriteCoreBoundaryAllowsOnlyMCPProjectReviewImport_repro() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let script = "\(repoRoot)/scripts/check-swift-module-boundaries.sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        // Ensure common tools (dirname, xcodegen) resolve under xctest.
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" + path
        process.environment = env

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("swift module boundaries ok"), text)
    }
}
