import XCTest
import GRDB
import Darwin
import Foundation
@testable import EngramServiceCore

/// Covers the round-7 security / IPC hardening:
/// - SEC-C2 project path confinement
/// - SEC-H1 capability-token authz
/// - SEC-H3 Library/Keychains sensitive-path blocking
/// - IPC-H2 oversized frame / snippet bounding
/// - IPC-M1 real request id on error
final class ServiceSecurityHardeningTests: XCTestCase {
    // MARK: - Helpers

    private func withTemporaryHome<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-sec-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeScope = ServiceCoreTestHomeScope(home: home)
        defer {
            homeScope.restore()
            try? FileManager.default.removeItem(at: home)
        }
        return try await body(home)
    }

    private func makePaths() throws -> (runtime: URL, socket: URL, database: URL) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-sec-ipc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let runtime = root.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return (
            runtime,
            runtime.appendingPathComponent("service.sock"),
            root.appendingPathComponent("service.sqlite")
        )
    }

    private func seedProjectFixture(at path: String, src: String) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY, source TEXT NOT NULL, start_time TEXT NOT NULL,
                  cwd TEXT NOT NULL DEFAULT '', file_path TEXT NOT NULL,
                  size_bytes INTEGER NOT NULL DEFAULT 0, indexed_at TEXT NOT NULL,
                  message_count INTEGER NOT NULL DEFAULT 0,
                  hidden_at TEXT, tier TEXT
                );
                CREATE TABLE migration_log (
                  id TEXT PRIMARY KEY, old_path TEXT NOT NULL, new_path TEXT NOT NULL,
                  old_basename TEXT NOT NULL, new_basename TEXT NOT NULL, state TEXT NOT NULL,
                  started_at TEXT NOT NULL, finished_at TEXT, archived INTEGER NOT NULL DEFAULT 0,
                  audit_note TEXT, actor TEXT NOT NULL DEFAULT 'app'
                );
                CREATE TABLE project_aliases (
                  alias TEXT NOT NULL, canonical TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (datetime('now')),
                  PRIMARY KEY (alias, canonical)
                );
            """)
        }
    }

    // MARK: - SEC-C2: project path confinement

    func testProjectMoveRejectsSourceOutsideHome() async throws {
        try await withTemporaryHome { _ in
            let paths = try makePaths()
            try seedProjectFixture(at: paths.database.path, src: "/etc")
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let handler = EngramServiceCommandHandler(writerGate: gate)

            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: "/etc/passwd-dir",
                    dst: "/tmp/elsewhere",
                    dryRun: true,
                    force: true, // force must NOT relax confinement
                    auditNote: nil,
                    actor: "test"
                ))
            )
            let response = await handler.handle(request)
            guard case .failure(_, let error) = response else {
                return XCTFail("Expected confinement rejection for out-of-home src")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
            XCTAssertTrue(error.message.contains("outside the home directory"), error.message)
        }
    }

    func testProjectMoveAcceptsInRootPaths(
    ) async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try seedProjectFixture(at: paths.database.path, src: home.path)
            let src = home.appendingPathComponent(".claude/projects/old", isDirectory: true)
            let dst = home.appendingPathComponent(".claude/projects/new", isDirectory: true)
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let handler = EngramServiceCommandHandler(writerGate: gate)

            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: src.path,
                    dst: dst.path,
                    dryRun: true, // dry-run avoids actual filesystem move
                    force: false,
                    auditNote: nil,
                    actor: "test"
                ))
            )
            let response = await handler.handle(request)
            // In-root paths must NOT be rejected with a confinement error.
            if case .failure(_, let error) = response {
                XCTAssertNotEqual(
                    error.name, "InvalidRequest",
                    "in-root path must pass confinement; got \(error.message)"
                )
                XCTAssertFalse(error.message.contains("outside the home directory"), error.message)
            }
        }
    }

    func testProjectMoveBatchRejectsAnyOutOfRootOperation() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try seedProjectFixture(at: paths.database.path, src: home.path)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let handler = EngramServiceCommandHandler(writerGate: gate)

            let json = """
            {"version":1,"operations":[
              {"src":"\(home.path)/.claude/projects/a","dst":"\(home.path)/.claude/projects/b"},
              {"src":"/var/root/secret","dst":"\(home.path)/.claude/projects/c"}
            ]}
            """
            let request = EngramServiceRequestEnvelope(
                command: "projectMoveBatch",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveBatchRequest(
                    yaml: json, dryRun: true, force: true, actor: "test"
                ))
            )
            let response = await handler.handle(request)
            guard case .failure(_, let error) = response else {
                return XCTFail("Expected batch rejection when one op is out-of-home")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
        }
    }

    // MARK: - SEC-H1: capability-token authz

    func testDestructiveCommandWithoutTokenIsUnauthorized() async throws {
        let paths = try makePaths()
        try seedProjectFixture(at: paths.database.path, src: "/tmp")
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        // Send a destructive command WITHOUT a capability token, bypassing the
        // client's auto-attach by talking to the transport with an explicit
        // envelope that has no token.
        let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        let request = EngramServiceRequestEnvelope(
            command: "setSessionHidden",
            payload: try JSONEncoder().encode(EngramServiceSessionHiddenRequest(sessionId: "s1", hidden: true)),
            capabilityToken: "wrong-token"
        )
        let response = try await transport.send(request, timeout: 2)
        guard case .failure(_, let error) = response else {
            return XCTFail("Expected unauthorized for missing/invalid token")
        }
        XCTAssertEqual(error.name, "Unauthorized")
        // IPC-M1: real request id flows back, not "unknown".
        XCTAssertEqual(response.requestId, request.requestId)
    }

    func testEveryMutatingCommandRequiresCapabilityToken() async throws {
        let paths = try makePaths()
        try seedProjectFixture(at: paths.database.path, src: "/tmp")
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            XCTFail("unauthorized mutating command reached handler: \(request.command)")
            return .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        try server.start()
        defer { server.stop() }

        let commands = [
            "generateSummary",
            "saveInsight",
            "deleteInsight",
            "manageProjectAlias",
            "confirmSuggestion",
            "dismissSuggestion",
            "addSessionRelation",
            "removeSessionRelation",
            "regenerateAllTitles",
            "projectMove",
            "projectArchive",
            "projectUndo",
            "projectMoveBatch",
            "setFavorite",
            "setSessionHidden",
            "setSourceEnabled",
            "renameSession",
            "hideEmptySessions",
            "linkSessions",
            "exportSession",
            "refreshUsage",
            "test.write_intent",
        ]

        for command in commands {
            let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
            let request = EngramServiceRequestEnvelope(
                command: command,
                payload: Data("{}".utf8),
                capabilityToken: "wrong-token"
            )
            let response = try await transport.send(request, timeout: 2)
            guard case .failure(_, let error) = response else {
                XCTFail("Expected unauthorized for \(command), got \(response)")
                continue
            }
            XCTAssertEqual(error.name, "Unauthorized", command)
        }
    }

    func testSessionRelationMutationsAreTokenProtectedButReadIsNot() {
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("addSessionRelation"))
        XCTAssertTrue(ServiceCapabilityToken.requiresToken("removeSessionRelation"))
        XCTAssertFalse(
            ServiceCapabilityToken.requiresToken("relatedSessions"),
            "relatedSessions is a read and must not require a capability token"
        )
    }

    func testSetSourceEnabledIsTokenProtectedButDisabledSourcesReadIsNot() {
        XCTAssertTrue(
            ServiceCapabilityToken.requiresToken("setSourceEnabled"),
            "setSourceEnabled mutates ingest state + hides sessions and must require a token"
        )
        XCTAssertFalse(
            ServiceCapabilityToken.requiresToken("disabledSources"),
            "disabledSources is a read and must not require a capability token"
        )
    }

    func testRelatedSessionsReadSucceedsWithoutCapabilityToken() async throws {
        let paths = try makePaths()
        try seedProjectFixture(at: paths.database.path, src: "/tmp")
        // The service read pool enforces WAL (readerConfiguration); seed it so the
        // read path can open the DB.
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let queue = try DatabaseQueue(path: paths.database.path, configuration: configuration)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, file_path, indexed_at) VALUES ('s1','codex','t','/tmp/s1','t')"
            )
        }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        // Talk to the transport with an explicit envelope carrying NO token; a
        // read command must still be served (returns empty, table absent).
        let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        let request = EngramServiceRequestEnvelope(
            command: "relatedSessions",
            payload: try JSONEncoder().encode(EngramServiceRelatedSessionsRequest(sessionId: "s1"))
        )
        let response = try await transport.send(request, timeout: 2)
        guard case .success(_, let data, _) = response else {
            return XCTFail("relatedSessions read should succeed without a token")
        }
        let decoded = try JSONDecoder().decode(EngramServiceRelatedSessionsResponse.self, from: data)
        XCTAssertEqual(decoded.ids, [])
    }

    func testCapabilityTokenFileIsWrittenWithOwnerOnlyPermissions() throws {
        let paths = try makePaths()
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        let token = try ServiceCapabilityToken.generateAndWrite(toPath: tokenPath)
        XCTAssertFalse(token.isEmpty)
        XCTAssertEqual(ServiceCapabilityToken.load(fromPath: tokenPath), token)
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms, 0o600)
    }

    func testWebUITokenFileIsWrittenWithOwnerOnlyPermissions() throws {
        let paths = try makePaths()
        let token = try XCTUnwrap(EngramServiceRunner.provisionWebToken(runtimeDirectory: paths.runtime))
        let tokenPath = paths.runtime.appendingPathComponent("webui.token").path

        XCTAssertEqual(try String(contentsOfFile: tokenPath, encoding: .utf8), token)
        let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms, 0o600)
    }

    func testClientAutoAttachedTokenAuthorizesDestructiveCommand() async throws {
        let paths = try makePaths()
        try seedProjectFixture(at: paths.database.path, src: "/tmp")
        // Seed a hideable session row.
        let queue = try DatabaseQueue(path: paths.database.path)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO sessions (id, source, start_time, file_path, indexed_at) VALUES ('s1','codex','t','/tmp/s1','t')"
            )
        }
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        // The transport auto-loads the token written next to the socket.
        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: paths.socket.path))
        try await client.setSessionHidden(sessionId: "s1", hidden: true)
        let hidden = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE id='s1' AND hidden_at IS NOT NULL") ?? 0
        }
        XCTAssertEqual(hidden, 1)
    }

    // MARK: - SEC-H3: Library/Keychains

    func testSensitivePathBlocksLibraryKeychains() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try seedProjectFixture(at: paths.database.path, src: home.path)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let handler = EngramServiceCommandHandler(writerGate: gate)

            // A move whose source lives under ~/Library/Keychains must be
            // refused as a protected location (the old compound-string form
            // never matched and left it exposed).
            let keychainSrc = home.appendingPathComponent("Library/Keychains/login.keychain-db").path
            let request = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: keychainSrc,
                    dst: home.appendingPathComponent(".claude/projects/x").path,
                    dryRun: true,
                    force: true,
                    auditNote: nil,
                    actor: "test"
                ))
            )
            let response = await handler.handle(request)
            guard case .failure(_, let error) = response else {
                return XCTFail("Library/Keychains source must be rejected")
            }
            XCTAssertEqual(error.name, "InvalidRequest")
            XCTAssertTrue(error.message.contains("protected location"), error.message)

            // Sanity: a normal in-root path is NOT flagged as protected.
            let okSrc = home.appendingPathComponent(".claude/projects/ok", isDirectory: true)
            try FileManager.default.createDirectory(at: okSrc, withIntermediateDirectories: true)
            let okRequest = EngramServiceRequestEnvelope(
                command: "projectMove",
                payload: try JSONEncoder().encode(EngramServiceProjectMoveRequest(
                    src: okSrc.path,
                    dst: home.appendingPathComponent(".claude/projects/ok2").path,
                    dryRun: true, force: false, auditNote: nil, actor: "test"
                ))
            )
            if case .failure(_, let error) = await handler.handle(okRequest) {
                XCTAssertFalse(error.message.contains("protected location"), error.message)
            }
        }
    }

    func testProjectPathConfinementRejectsSymlinkEscapingHome() async throws {
        try await withTemporaryHome { home in
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("engram-sec-outside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }

            let symlink = home.appendingPathComponent("project-link")
            try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: outside.path)

            XCTAssertThrowsError(
                try EngramServiceCommandHandler.validateProjectPathConfined(symlink.path, label: "source")
            ) { error in
                XCTAssertTrue("\(error)".contains("outside the home directory"), "\(error)")
            }
        }
    }

    // MARK: - IPC-H2: oversized snippet / writeFrame guard

    func testSearchSnippetTruncatedServerSide() {
        let huge = String(repeating: "x", count: 1_000_000)
        let truncated = SQLiteEngramServiceReadProvider.truncateSnippet(huge)
        XCTAssertNotNil(truncated)
        XCTAssertLessThanOrEqual(truncated!.count, SQLiteEngramServiceReadProvider.maxSnippetLength + 1)
        XCTAssertNil(SQLiteEngramServiceReadProvider.truncateSnippet(nil))
        XCTAssertEqual(SQLiteEngramServiceReadProvider.truncateSnippet("short"), "short")
    }

    func testWriteFrameRejectsOversizedPayload() throws {
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { fds.deallocate() }
        XCTAssertEqual(pipe(fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let oversize = Data(repeating: 0x41, count: UnixSocketEngramServiceTransport.maximumFrameLength + 1)
        XCTAssertThrowsError(try UnixSocketEngramServiceTransport.writeFrame(oversize, to: fds[1])) { error in
            guard case EngramServiceError.invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    // MARK: - IPC-M1: real request id on error path

    func testHandlerErrorPreservesRealRequestId() async throws {
        // A decodable-but-unsupported command must echo the real request id.
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
        let request = EngramServiceRequestEnvelope(command: "no.such.command")
        let response = try await transport.send(request, timeout: 2)
        XCTAssertEqual(response.requestId, request.requestId)
        guard case .failure = response else {
            return XCTFail("Expected failure for unsupported command")
        }
    }

    func testServerErrorResponseUsesUnknownWhenIdNotExtractable() {
        struct Boom: Error {}
        let response = UnixSocketServiceServer.errorResponse(for: Boom(), requestId: nil)
        XCTAssertEqual(response.requestId, "unknown")
        let realIdResponse = UnixSocketServiceServer.errorResponse(
            for: EngramServiceError.unauthorized(message: "no token"),
            requestId: "req-123"
        )
        XCTAssertEqual(realIdResponse.requestId, "req-123")
        if case .failure(_, let error) = realIdResponse {
            XCTAssertEqual(error.name, "Unauthorized")
        } else {
            XCTFail("Expected failure envelope")
        }
    }

    // MARK: - IPC-H1: accept loop keeps serving across many connections

    func testAcceptLoopKeepsAcceptingAcrossManyConnections() async throws {
        // Regression for the old `break`-on-every-accept-error behavior: the
        // listener must serve more than one connection. Each send opens and
        // closes a fresh socket, exercising the accept loop repeatedly.
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        for _ in 0..<8 {
            let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
            let request = EngramServiceRequestEnvelope(command: "status")
            let response = try await transport.send(request, timeout: 2)
            XCTAssertEqual(response.requestId, request.requestId)
            guard case .success = response else {
                return XCTFail("status must succeed on every connection")
            }
        }
    }

    func testFastClientHandlersDoNotLeaveCompletedTasksTracked() async throws {
        let paths = try makePaths()
        let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
        let handler = EngramServiceCommandHandler(writerGate: gate)
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            await handler.handle(request)
        }
        try server.start()
        defer { server.stop() }

        for _ in 0..<64 {
            let transport = UnixSocketEngramServiceTransport(socketPath: paths.socket.path)
            _ = try await transport.send(EngramServiceRequestEnvelope(command: "status"), timeout: 2)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(server.activeClientTaskCountForTesting(), 0)
    }

    func testAcceptLoopSourceHandlesTransientErrnoWithoutBreaking() throws {
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        // Transient errnos must `continue`, only socket-closed errnos exit.
        XCTAssertTrue(source.contains("case EINTR, ECONNABORTED"))
        XCTAssertTrue(source.contains("case EMFILE, ENFILE"))
        XCTAssertTrue(source.contains("case EBADF, EINVAL"))
    }

    private func serviceCoreSource(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
        while directory.lastPathComponent != "macos" {
            directory.deleteLastPathComponent()
        }
        return try String(contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

final class ServiceCoreTestHomeScope {
    private static let lock = NSLock()
    private let oldHome: String?
    private var restored = false

    init(home: URL) {
        Self.lock.lock()
        oldHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", home.path, 1)
    }

    func restore() {
        guard !restored else { return }
        restored = true
        if let oldHome {
            setenv("HOME", oldHome, 1)
        } else {
            unsetenv("HOME")
        }
        Self.lock.unlock()
    }

    deinit {
        restore()
    }
}
