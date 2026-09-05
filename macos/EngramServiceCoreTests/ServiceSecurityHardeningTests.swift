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
    /// R1.nit non-constant-time-token-compare — equality helper must reject
    /// mismatches and accept exact matches without early string `==`.
    func testCapabilityTokenConstantTimeEquals_repro() {
        XCTAssertTrue(ServiceCapabilityToken.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(ServiceCapabilityToken.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(ServiceCapabilityToken.constantTimeEquals(nil, "abc"))
        XCTAssertFalse(ServiceCapabilityToken.constantTimeEquals("ab", "abc"))
        XCTAssertFalse(ServiceCapabilityToken.constantTimeEquals("abcd", "abc"))
    }

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

    func testProjectPathConfinementRejectsHomeDirectoryItself() async throws {
        try await withTemporaryHome { home in
            XCTAssertThrowsError(
                try EngramServiceCommandHandler.validateProjectPathConfined(home.path, label: "source"),
                "Project path confinement must reject the home directory itself"
            ) { error in
                XCTAssertTrue("\(error)".contains("home directory root"), "\(error)")
            }
        }
    }

    func testProjectPathConfinementExpandsTildeAgainstConfiguredHome_repro() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-confined-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        }

        XCTAssertNoThrow(
            try EngramServiceCommandHandler.validateProjectPathConfined("~/project", label: "source")
        )
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
            guard case .success(_, let data, _) = response else {
                if case .failure(_, let error) = response {
                    return XCTFail("in-root path must pass confinement; got \(error.name): \(error.message)")
                }
                return XCTFail("in-root path must pass confinement")
            }
            let decoded = try JSONDecoder().decode(EngramServiceProjectMoveResult.self, from: data)
            let perSource = try XCTUnwrap(decoded.perSource)
            XCTAssertFalse(perSource.isEmpty)
            XCTAssertTrue(
                perSource.allSatisfy { $0.root == home.path || $0.root.hasPrefix(home.path + "/") },
                "project move dry-run must scan the confined home, got roots: \(perSource.map(\.root))"
            )
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

        // SEC-L1: generate the matrix from protectedCommands itself so remote/
        // archive/parent-link mutators cannot drift out of the socket gate test.
        let commands = ServiceCapabilityToken.protectedCommands.sorted()
        XCTAssertFalse(commands.isEmpty)
        XCTAssertGreaterThanOrEqual(
            commands.count,
            30,
            "protectedCommands matrix should cover full mutator set, got \(commands.count)"
        )

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

    // MARK: - SEC-L2: peer euid + socket 0600

    func testPeerIsAuthorizedRequiresMatchingEuid() throws {
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { fds.deallocate() }
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        let selfEuid = geteuid()
        XCTAssertTrue(
            UnixSocketServiceServer.peerIsAuthorized(fds[0], serviceEuid: selfEuid),
            "same-euid peer over socketpair must authorize"
        )
        // Any other euid must fail closed. Use 0 (root) when we are not root,
        // otherwise pick a non-self synthetic id.
        let otherEuid: uid_t = selfEuid == 0 ? 501 : 0
        XCTAssertFalse(
            UnixSocketServiceServer.peerIsAuthorized(fds[0], serviceEuid: otherEuid),
            "mismatched service euid must reject the peer"
        )
        // Closed/invalid fd must not authorize.
        XCTAssertFalse(UnixSocketServiceServer.peerIsAuthorized(-1, serviceEuid: selfEuid))
    }

    func testBoundSocketIsOwnerOnly0600() throws {
        let paths = try makePaths()
        let server = UnixSocketServiceServer(socketPath: paths.socket.path) { request in
            .success(requestId: request.requestId, result: Data("{}".utf8))
        }
        try server.start()
        defer { server.stop() }

        var info = stat()
        XCTAssertEqual(stat(paths.socket.path, &info), 0, "bound socket must exist")
        let mode = info.st_mode & 0o777
        XCTAssertEqual(
            mode,
            0o600,
            String(format: "SEC-L2: service socket must be 0600, got %o", mode)
        )
    }

    // MARK: - SEC-L5: resume CLI locator prefers absolute known paths

    func testDefaultCommandLocatorPrefersKnownAbsolutePathsOverPATH() {
        let pathPoison = "/tmp/engram-poisoned-\(UUID().uuidString.prefix(8))"
        let knownHomebrew = "/opt/homebrew/bin/claude"
        let knownLocal = "/usr/local/bin/claude"
        let poisoned = "\(pathPoison)/claude"
        let env = ["PATH": "\(pathPoison):/usr/bin"]

        // Only the known Homebrew path is "executable" — poisoned PATH entry is ignored
        // for selection order even though it appears first in PATH.
        let resolved = SQLiteEngramServiceReadProvider.defaultCommandLocator(
            "claude",
            environment: env,
            isExecutable: { path in
                path == knownHomebrew || path == knownLocal || path == poisoned
            }
        )
        XCTAssertEqual(
            resolved,
            knownHomebrew,
            "SEC-L5: preferred absolute install path must win over an earlier PATH entry"
        )

        // When no preferred absolute path is executable, fall back to PATH order.
        let pathOnly = SQLiteEngramServiceReadProvider.defaultCommandLocator(
            "claude",
            environment: env,
            isExecutable: { $0 == poisoned }
        )
        XCTAssertEqual(pathOnly, poisoned)

        XCTAssertNil(
            SQLiteEngramServiceReadProvider.defaultCommandLocator(
                "claude",
                environment: env,
                isExecutable: { _ in false }
            )
        )
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

    func testCapabilityTokenRecoversSymlinkDestinationWithoutTouchingReferent_repro() throws {
        let paths = try makePaths()
        let outside = paths.runtime.deletingLastPathComponent().appendingPathComponent("outside-token")
        try Data("sentinel".utf8).write(to: outside)
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        try FileManager.default.createSymbolicLink(atPath: tokenPath, withDestinationPath: outside.path)

        let token = try ServiceCapabilityToken.generateAndWrite(toPath: tokenPath)
        XCTAssertEqual(ServiceCapabilityToken.load(fromPath: tokenPath), token)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        var info = stat()
        XCTAssertEqual(lstat(tokenPath, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
    }

    func testCapabilityTokenRecoversOwnedHardlinkLeftover_repro() throws {
        let paths = try makePaths()
        let peer = paths.runtime.deletingLastPathComponent().appendingPathComponent("peer-token")
        let original = Data("shared-token".utf8)
        try original.write(to: peer)
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        XCTAssertEqual(link(peer.path, tokenPath), 0)

        let token = try ServiceCapabilityToken.generateAndWrite(toPath: tokenPath)

        XCTAssertEqual(ServiceCapabilityToken.load(fromPath: tokenPath), token)
        XCTAssertEqual(try Data(contentsOf: peer), original)
        var info = stat()
        XCTAssertEqual(lstat(tokenPath, &info), 0)
        XCTAssertEqual(info.st_nlink, 1)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testCapabilityTokenUsesDirfdPinnedAtomicWriter_repro() throws {
        let source = try serviceCoreSource("Shared/Service/ServiceCapabilityToken.swift")
        let start = try XCTUnwrap(source.range(of: "static func generateAndWrite")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "static func load", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("SecureRegularFile.writeAtomically"))
        XCTAssertFalse(body.contains("lstat(path"))
        XCTAssertFalse(body.contains("open(path"))
    }

    func testCapabilityTokenReaderPinsParentDirectoryBeforeOpeningLeaf_repro() throws {
        let source = try serviceCoreSource("Shared/Security/SecureRegularFile.swift")
        let start = try XCTUnwrap(source.range(of: "public static func read")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "public static func writeAtomically", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(source.contains("O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertTrue(body.contains("openat(directoryFD"))
        XCTAssertFalse(body.contains("lstat(path"))
        XCTAssertFalse(body.contains("open($0, O_RDONLY"))
    }

    func testCapabilityTokenStopUsesPinnedDirectoryUnlink_repro() throws {
        let source = try serviceCoreSource("EngramService/IPC/UnixSocketServiceServer.swift")
        let start = try XCTUnwrap(source.range(of: "func stop()")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "func drainClientHandlers", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("ServiceCapabilityToken.remove"))
        XCTAssertFalse(body.contains("unlink(ServiceCapabilityToken.path"))
    }

    func testCapabilityTokenLoadRejectsUnsafeFiles_repro() throws {
        let paths = try makePaths()
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        let tokenURL = URL(fileURLWithPath: tokenPath)
        try Data("secret-token".utf8).write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tokenPath)
        XCTAssertNil(ServiceCapabilityToken.load(fromPath: tokenPath))

        try FileManager.default.removeItem(at: tokenURL)
        let outside = paths.runtime.deletingLastPathComponent().appendingPathComponent("outside-load-token")
        try Data("linked-token".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: tokenPath, withDestinationPath: outside.path)
        XCTAssertNil(ServiceCapabilityToken.load(fromPath: tokenPath))
    }

    func testCapabilityTokenLoadRejectsFIFOPromptly_repro() throws {
        let paths = try makePaths()
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: paths.socket.path)
        XCTAssertEqual(mkfifo(tokenPath, S_IRUSR | S_IWUSR), 0)
        let returned = expectation(description: "FIFO token read returned")
        DispatchQueue.global().async {
            XCTAssertNil(ServiceCapabilityToken.load(fromPath: tokenPath))
            returned.fulfill()
        }

        let result = XCTWaiter.wait(for: [returned], timeout: 0.2)
        XCTAssertEqual(result, .completed, "secret readers must not block opening a FIFO")
        if result != .completed {
            let writer = open(tokenPath, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
    }

    func testWriterLockRejectsSymlinkDestination_repro() throws {
        let paths = try makePaths()
        let outside = paths.runtime.deletingLastPathComponent().appendingPathComponent("outside-lock")
        try Data("sentinel".utf8).write(to: outside)
        let lockPath = paths.runtime.appendingPathComponent("engram-service.lock")
        try FileManager.default.createSymbolicLink(atPath: lockPath.path, withDestinationPath: outside.path)

        XCTAssertThrowsError(
            try ServiceWriterGate(
                databasePath: paths.database.path,
                runtimeDirectory: paths.runtime
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testRunnerRemovesLegacyWebUIToken() throws {
        let root = try makePaths().runtime.deletingLastPathComponent()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let runtime = home.appendingPathComponent(".engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let tokenURL = runtime.appendingPathComponent("webui.token")
        try "legacy-secret".write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)

        try EngramServiceRunner.removeLegacyWebUIToken(
            runtimeDirectory: runtime,
            homeDirectory: home
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
    }

    func testRunnerDoesNotRemoveLegacyTokenFromCustomSocketDirectory_repro() throws {
        let paths = try makePaths()
        let tokenURL = paths.runtime.appendingPathComponent("webui.token")
        try Data("unrelated-token".utf8).write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)

        try EngramServiceRunner.removeLegacyWebUIToken(runtimeDirectory: paths.runtime)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path))
        XCTAssertEqual(try Data(contentsOf: tokenURL), Data("unrelated-token".utf8))
    }

    func testRunnerLegacyTokenCleanupUnlinksSymlinkWithoutFollowingIt_repro() throws {
        let root = try makePaths().runtime.deletingLastPathComponent()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let runtime = home.appendingPathComponent(".engram/run", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim")
        try Data("preserve".utf8).write(to: victim)
        let tokenURL = runtime.appendingPathComponent("webui.token")
        try FileManager.default.createSymbolicLink(atPath: tokenURL.path, withDestinationPath: victim.path)

        try EngramServiceRunner.removeLegacyWebUIToken(
            runtimeDirectory: runtime,
            homeDirectory: home
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("preserve".utf8))
        var info = stat()
        XCTAssertEqual(lstat(tokenURL.path, &info), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    func testRunnerLegacyTokenCleanupUsesPinnedParentWalk_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EngramService/Core/EngramServiceRunner.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "static func removeLegacyWebUIToken")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private static func parseUsageTokenLimitsJSON", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("SecureRegularFile.removeOwnerNonDirectory"))
        XCTAssertFalse(body.contains("open(\n            dedicatedRuntimeDirectory.path"))
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

    /// invariant: sensitive-path denylist is case-folded (RETRO-P2-DENYLIST-CASE).
    /// APFS default volumes are case-insensitive; exact-case denylist matching let
    /// `.SSH` / `library/keychains` spellings bypass the guard on non-existent dst paths.
    func testSensitivePathBlocksCaseVariants_repro() async throws {
        try await withTemporaryHome { home in
            let paths = try makePaths()
            try seedProjectFixture(at: paths.database.path, src: home.path)
            let gate = try ServiceWriterGate(databasePath: paths.database.path, runtimeDirectory: paths.runtime)
            let handler = EngramServiceCommandHandler(writerGate: gate)
            let dst = home.appendingPathComponent(".claude/projects/x").path

            func assertProtected(_ src: String, label: String) async {
                let request = EngramServiceRequestEnvelope(
                    command: "projectMove",
                    payload: try! JSONEncoder().encode(EngramServiceProjectMoveRequest(
                        src: src,
                        dst: dst,
                        dryRun: true,
                        force: true,
                        auditNote: nil,
                        actor: "test"
                    ))
                )
                let response = await handler.handle(request)
                guard case .failure(_, let error) = response else {
                    return XCTFail("\(label) must be rejected as protected location")
                }
                XCTAssertEqual(error.name, "InvalidRequest", label)
                XCTAssertTrue(
                    error.message.contains("protected location"),
                    "\(label): \(error.message)"
                )
            }

            // Case-folded single-component denylist (.ssh family).
            await assertProtected(
                home.appendingPathComponent(".SSH/id_rsa").path,
                label: ".SSH"
            )
            // Case-folded multi-component sequence (Library/Keychains).
            await assertProtected(
                home.appendingPathComponent("library/keychains/login.keychain-db").path,
                label: "library/keychains"
            )
            await assertProtected(
                home.appendingPathComponent("LIBRARY/KEYCHAINS/login.keychain-db").path,
                label: "LIBRARY/KEYCHAINS"
            )
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
    private let oldValues: [String: String?]
    private var restored = false

    init(home: URL) {
        Self.lock.lock()
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            XCTFail("Failed to create hermetic test home at \(home.path): \(error)")
        }
        let keys = ["HOME", "CFFIXED_USER_HOME", "TMPDIR"]
        oldValues = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
        // docs/invariants.md #6: Darwin's FileManager ignores HOME-only changes.
        for key in keys {
            setenv(key, home.path, 1)
        }
    }

    func restore() {
        guard !restored else { return }
        restored = true
        for (key, oldValue) in oldValues {
            if let oldValue {
                setenv(key, oldValue, 1)
            } else {
                unsetenv(key)
            }
        }
        Self.lock.unlock()
    }

    deinit {
        restore()
    }
}
