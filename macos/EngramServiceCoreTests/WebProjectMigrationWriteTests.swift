import Darwin
import Foundation
import XCTest
import EngramCoreWrite
@testable import EngramServiceCore

final class WebProjectMigrationWriteTests: XCTestCase {
    func testHomeDirectoryPathPrefersFixedHomeOnlyInTestProcess() {
        let fixed = "/tmp/engram-d15-fixed-home"
        let home = "/tmp/engram-d15-real-home"
        XCTAssertEqual(
            EngramServiceCommandHandler.homeDirectoryPath(environment: [
                "XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration",
                "CFFIXED_USER_HOME": fixed,
                "HOME": home,
            ]),
            URL(fileURLWithPath: fixed, isDirectory: true).standardizedFileURL.path
        )
        XCTAssertEqual(
            EngramServiceCommandHandler.homeDirectoryPath(environment: [
                "XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration",
                "HOME": home,
            ]),
            URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.path
        )
    }

    func testOutsideHomeIsConfinementAndDoesNotMove() async throws {
        try await withIsolatedFixedHome { home in
            let paths = try makePaths()
            try migrate(paths.database)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let operationId = UUID().uuidString
            do {
                _ = try await EngramServiceCommandHandler.webProjectMove(
                    EngramServiceWebProjectMoveRequest(
                        src: "/etc/passwd",
                        dst: home.appendingPathComponent("Code/out").path,
                        dryRun: true,
                        operationId: operationId
                    ),
                    writerGate: gate
                )
                XCTFail("outside-home src must fail confinement")
            } catch let error as EngramServiceError {
                guard case .commandFailed(let name, let message, let retry, _) = error else {
                    return XCTFail("expected commandFailed, got \(error)")
                }
                XCTAssertEqual(name, "WebProjectConfinement")
                XCTAssertEqual(retry, "never")
                XCTAssertTrue(message.contains("home directory"), message)
            }
        }
    }

    func testDryRunThenCommitThenUndoOnIsolatedFixture() async throws {
        try skipIfGitMissing()
        try await withIsolatedFixedHome { home in
            let (src, dst) = try makeProjectPair(home: home, name: "alpha")
            let paths = try makePaths()
            try migrate(paths.database)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let preview = try await EngramServiceCommandHandler.webProjectMove(
                EngramServiceWebProjectMoveRequest(
                    src: src, dst: dst, dryRun: true, operationId: UUID().uuidString
                ),
                writerGate: gate
            )
            XCTAssertEqual(preview.value.scope, "serverFilesystem")
            XCTAssertEqual(preview.value.result.state, "dry-run")
            XCTAssertTrue(FileManager.default.fileExists(atPath: src))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dst))

            let committed = try await EngramServiceCommandHandler.webProjectMove(
                EngramServiceWebProjectMoveRequest(
                    src: src, dst: dst, dryRun: false, operationId: UUID().uuidString
                ),
                writerGate: gate
            )
            XCTAssertEqual(committed.value.result.state, "committed")
            XCTAssertFalse(committed.value.result.migrationId.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: src))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dst))

            let undone = try await EngramServiceCommandHandler.webProjectUndo(
                EngramServiceWebProjectUndoRequest(
                    migrationId: committed.value.result.migrationId,
                    operationId: UUID().uuidString
                ),
                writerGate: gate
            )
            XCTAssertEqual(undone.value.result.state, "committed")
            XCTAssertTrue(FileManager.default.fileExists(atPath: src))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dst))
        }
    }

    func testBatchCancelAndReplayStayInsideWebNamespace() async throws {
        try skipIfGitMissing()
        try await withIsolatedFixedHome { home in
            let (src, dst) = try makeProjectPair(home: home, name: "batch")
            let paths = try makePaths()
            try migrate(paths.database)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let yaml = """
            {"version":1,"operations":[{"src":"\(src)","dst":"\(dst)"}]}
            """
            let operationId = UUID().uuidString
            let first = try await EngramServiceCommandHandler.webProjectMoveBatch(
                EngramServiceWebProjectMoveBatchRequest(
                    yaml: yaml, dryRun: true, operationId: operationId
                ),
                writerGate: gate
            )
            let replay = try await EngramServiceCommandHandler.webProjectMoveBatch(
                EngramServiceWebProjectMoveBatchRequest(
                    yaml: yaml, dryRun: true, operationId: operationId
                ),
                writerGate: gate
            )
            XCTAssertEqual(first.value.operationId, operationId)
            XCTAssertEqual(replay.value.operationId, operationId)
            XCTAssertEqual(first.value.result, replay.value.result)
            XCTAssertTrue(FileManager.default.fileExists(atPath: src))

            let nativeId = operationId
            ProjectMoveBatchCancelRegistry.shared.remove(operationId: nativeId)
            _ = ProjectMoveBatchCancelRegistry.shared.beginOrJoin(
                operationId: nativeId, fingerprint: "native-only"
            )
            let cancelled = try EngramServiceCommandHandler.webCancelProjectMoveBatch(
                EngramServiceWebCancelProjectMoveBatchRequest(operationId: operationId)
            )
            XCTAssertTrue(cancelled.accepted)
            XCTAssertFalse(ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: nativeId))
            XCTAssertTrue(
                ProjectMoveBatchCancelRegistry.shared.shouldStop(operationId: "web-project:\(operationId)")
            )
            ProjectMoveBatchCancelRegistry.shared.remove(operationId: nativeId)
            ProjectMoveBatchCancelRegistry.shared.remove(operationId: "web-project:\(operationId)")
        }
    }

    private func withIsolatedFixedHome(_ body: (URL) async throws -> Void) async throws {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-d15-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let previous = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", home.path, 1)
        defer {
            if let previous {
                setenv("CFFIXED_USER_HOME", previous, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
            try? FileManager.default.removeItem(at: home)
        }
        try await body(home)
    }

    private func makePaths() throws -> (runtime: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-d15-db-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return (runtime, root.appendingPathComponent("index.sqlite"))
    }

    private func migrate(_ url: URL) throws {
        let writer = try EngramDatabaseWriter(path: url.path)
        try writer.migrate()
    }

    private func makeProjectPair(home: URL, name: String) throws -> (String, String) {
        let src = home.appendingPathComponent("Code/\(name)", isDirectory: true)
        let dst = home.appendingPathComponent("Code/\(name)-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeGitRepo(at: src)
        let encoded = ClaudeCodeProjectDir.encode(src.path)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (src.path, dst.path)
    }

    private func makeGitRepo(at url: URL) throws {
        try "print(\"hi\")\n".write(to: url.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        try runGit(at: url, ["init", "-q"])
        try runGit(at: url, ["config", "user.email", "t@t"])
        try runGit(at: url, ["config", "user.name", "t"])
        try runGit(at: url, ["add", "."])
        try runGit(at: url, ["commit", "-qm", "init"])
    }

    private func runGit(at url: URL, _ arguments: [String]) throws {
        let process = Process()
        process.currentDirectoryURL = url
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(arguments.joined(separator: " ")) failed")
        }
    }

    private func skipIfGitMissing() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { throw XCTSkip("git is not available") }
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("git is not available") }
    }
}
