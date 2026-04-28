import Foundation
import Darwin
import XCTest

final class ServiceUnavailableMutatingToolTests: XCTestCase {
    func testSaveInsightFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbPath = temp.appendingPathComponent("should-not-exist.sqlite").path
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "save_insight",
            arguments: [
                "content": "must not be persisted without service socket",
                "wing": "engram",
                "room": "mcp-fail-closed",
            ],
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "save_insight", socketPath: socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), "save_insight must not open or write the DB")
    }

    func testProjectMoveDryRunFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbPath = temp.appendingPathComponent("should-not-exist.sqlite").path
        let socketPath = temp.appendingPathComponent("missing-service.sock").path
        let src = temp.appendingPathComponent("src-project").path
        let dst = temp.appendingPathComponent("dst-project").path

        let result = try callTool(
            name: "project_move",
            arguments: [
                "src": src,
                "dst": dst,
                "dry_run": true,
                "note": "fail closed dry run",
            ],
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "project_move", socketPath: socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), "project_move dry_run must not open or write the DB")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src), "project_move dry_run must not create source paths")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst), "project_move dry_run must not create destination paths")
    }

    func testGenerateSummaryFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "generate_summary",
            arguments: [
                "sessionId": "mcp-fixture-01",
            ],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "generate_summary", socketPath: socketPath)
    }

    func testLinkSessionsFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "link_sessions",
            arguments: [
                "targetDir": temp.appendingPathComponent("engram").path,
            ],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "link_sessions", socketPath: socketPath)
    }

    func testExportFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path
        let exportHome = temp.appendingPathComponent("home", isDirectory: true)
        let exportDir = exportHome.appendingPathComponent("codex-exports", isDirectory: true)

        let result = try callTool(
            name: "export",
            arguments: [
                "id": "mcp-transcript-01",
                "format": "json",
            ],
            environment: [
                "HOME": exportHome.path,
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "export", socketPath: socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDir.path), "export must not create files without service")
    }

    func testProjectArchiveFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "project_archive",
            arguments: [
                "src": temp.appendingPathComponent("archive-me").path,
                "dry_run": true,
            ],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "project_archive", socketPath: socketPath)
    }

    func testProjectUndoFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "project_undo",
            arguments: [
                "migration_id": "mig-123",
            ],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "project_undo", socketPath: socketPath)
    }

    func testProjectMoveBatchFailsClosedWithoutServiceSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let socketPath = temp.appendingPathComponent("missing-service.sock").path

        let result = try callTool(
            name: "project_move_batch",
            arguments: [
                "yaml": #"{"version":1,"operations":[{"src":"~/Old","dst":"~/New"}]}"#,
                "dry_run": true,
            ],
            environment: [
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "project_move_batch", socketPath: socketPath)
    }

    func testSaveInsightFailsClosedWithNonEngramSocket() throws {
        let temp = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dbPath = temp.appendingPathComponent("should-not-exist.sqlite").path
        let socketPath = temp.appendingPathComponent("dummy-service.sock").path
        let listener = try bindDummySocket(path: socketPath)
        defer { Darwin.close(listener) }
        acceptAndCloseOneConnection(listener)

        let result = try callTool(
            name: "save_insight",
            arguments: [
                "content": "must not be unlocked by a random socket",
                "wing": "engram",
            ],
            environment: [
                "ENGRAM_MCP_DB_PATH": dbPath,
                "ENGRAM_MCP_SERVICE_SOCKET": socketPath,
                "ENGRAM_MCP_DAEMON_BASE_URL": "http://127.0.0.1:9",
            ]
        )

        assertServiceUnavailable(result, tool: "save_insight", socketPath: socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath), "save_insight must not open or write the DB")
    }

    private func callTool(
        name: String,
        arguments: [String: Any],
        environment: [String: String]
    ) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executableURL()
        process.environment = ProcessInfo.processInfo.environment
            .merging(["TZ": "UTC"]) { _, new in new }
            .merging(environment) { _, new in new }

        let requestObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestObject)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        let firstLine = try XCTUnwrap(output.split(separator: "\n").first.map(String.init))
        let responseData = Data(firstLine.utf8)
        let json = try JSONSerialization.jsonObject(with: responseData)
        let response = try XCTUnwrap(json as? [String: Any])
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func assertServiceUnavailable(
        _ result: [String: Any],
        tool: String,
        socketPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result["isError"] as? Bool, true, file: file, line: line)
        let structured = result["structuredContent"] as? [String: Any]
        XCTAssertEqual(structured?["code"] as? String, "serviceUnavailable", file: file, line: line)
        XCTAssertEqual(structured?["tool"] as? String, tool, file: file, line: line)
        XCTAssertEqual(structured?["socketPath"] as? String, socketPath, file: file, line: line)
        XCTAssertEqual(
            structured?["message"] as? String,
            "EngramService is unavailable; mutating and operational MCP tools fail closed until the service socket is available.",
            file: file,
            line: line
        )
    }

    private func executableURL() -> URL {
        Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("EngramMCP")
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("eg-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bindDummySocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "Cannot create dummy Unix socket")
        try withSockAddr(path: path) { pointer, length in
            XCTAssertEqual(Darwin.bind(fd, pointer, length), 0)
        }
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        return fd
    }

    private func acceptAndCloseOneConnection(_ listener: Int32) {
        Thread {
            let connection = Darwin.accept(listener, nil, nil)
            if connection >= 0 {
                Darwin.close(connection)
            }
        }.start()
    }

    private func withSockAddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(path.utf8.count, maxPathLength)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    memset(destination, 0, maxPathLength)
                    strncpy(destination, source, maxPathLength - 1)
                }
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
