import XCTest

final class ModuleBoundaryTests: XCTestCase {
    func testAppMCPAndCLIDoNotDependOnWriteCore() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let script = "\(repoRoot)/scripts/check-swift-module-boundaries.sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]

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
