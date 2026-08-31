import Darwin
import XCTest
@testable import Engram

final class UnixSocketTransportTests: XCTestCase {
    func testResolvedSocketPathUsesFileManagerHomeInsteadOfHOMEOverride_repro() throws {
        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.resolvedSocketPath(
                environment: ["HOME": "/tmp/engram-split-home"]
            ),
            UnixSocketEngramServiceTransport.defaultSocketPath()
        )
    }

    func testResolvedSocketPathRejectsRelativeAndBlankOverrides_repro() throws {
        let fallback = UnixSocketEngramServiceTransport.defaultSocketPath()
        XCTAssertThrowsError(
            try UnixSocketEngramServiceTransport.resolvedSocketPath(
                environment: ["ENGRAM_MCP_SERVICE_SOCKET": "relative/service.sock"]
            )
        )
        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.resolvedSocketPath(
                environment: ["ENGRAM_SERVICE_SOCKET": "   "]
            ),
            fallback
        )
    }

    func testResolvedSocketPathExpandsLeadingTildeAgainstFileManagerHome_repro() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.resolvedSocketPath(
                environment: ["ENGRAM_SERVICE_SOCKET": "  ~/.engram/custom.sock  "]
            ),
            home.appendingPathComponent(".engram/custom.sock").path
        )
        XCTAssertEqual(
            UnixSocketEngramServiceTransport.normalizedAbsolutePath("~/index.sqlite"),
            home.appendingPathComponent("index.sqlite").path
        )
    }

    func testMissingSocketReturnsServiceUnavailable() async throws {
        let socketPath = temporarySocketPath()
        let transport = UnixSocketEngramServiceTransport(socketPath: socketPath)
        let request = EngramServiceRequestEnvelope(command: "status")

        do {
            _ = try await transport.send(request, timeout: 1)
            XCTFail("Expected serviceUnavailable")
        } catch let error as EngramServiceError {
            guard case .serviceUnavailable = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
        }
    }

    func testEventsStreamRidesOutTransientUnavailable() async throws {
        // No service is listening -> connectSocket throws serviceUnavailable. The
        // status stream must yield a degraded 'warning' event and keep polling
        // (ipc-4) instead of finishing-throwing on the first failed poll, so it
        // self-heals when the service comes back.
        let transport = UnixSocketEngramServiceTransport(socketPath: temporarySocketPath())
        var iterator = transport.events().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(
            first?.event,
            "warning",
            "events() must degrade, not terminate, on a transient outage"
        )
    }

    func testEventsStreamRidesOutTransportClosedDuringRestart() async throws {
        let socketPath = temporarySocketPath()
        let listener = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
        defer {
            close(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        Task.detached {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                close(client)
            }
        }

        let transport = UnixSocketEngramServiceTransport(socketPath: socketPath)
        var iterator = transport.events().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(
            first?.event,
            "warning",
            "events() must degrade, not terminate, when a restarting service closes the socket"
        )
    }

    func testSecureRuntimeDirectoryCreatesFreshWith0700() throws {
        let home = temporaryDirectory()
        let runDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home)

        var info = stat()
        XCTAssertEqual(lstat(runDirectory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o077, 0)
    }

    func testSecureRuntimeDirectoryRepairsLegacyPermissions() throws {
        let home = temporaryDirectory()
        let rootDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        let runDirectory = rootDirectory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        chmod(rootDirectory.path, 0o755)
        chmod(runDirectory.path, 0o755)

        XCTAssertEqual(try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home), runDirectory)

        var rootInfo = stat()
        var runInfo = stat()
        XCTAssertEqual(lstat(rootDirectory.path, &rootInfo), 0)
        XCTAssertEqual(lstat(runDirectory.path, &runInfo), 0)
        XCTAssertEqual(rootInfo.st_mode & 0o077, 0)
        XCTAssertEqual(runInfo.st_mode & 0o077, 0)
    }

    func testSecureRuntimeDirectoryDoesNotScanProductRootLeftovers_repro() throws {
        let home = temporaryDirectory()
        let rootDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        chmod(rootDirectory.path, 0o700)
        let outside = home.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let cache = rootDirectory.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)

        let runDirectory = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home)

        XCTAssertTrue(FileManager.default.fileExists(atPath: runDirectory.path))
        var info = stat()
        XCTAssertEqual(lstat(cache.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testCustomSocketParentAllowsUnrelatedSymlinkWithoutScanning_repro() throws {
        let project = temporaryDirectory()
        chmod(project.path, 0o700)
        let outside = project.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("sentinel".utf8).write(to: outside)
        let unrelated = project.appendingPathComponent("unrelated-link")
        try FileManager.default.createSymbolicLink(at: unrelated, withDestinationURL: outside)

        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(at: project),
            project
        )
        var info = stat()
        XCTAssertEqual(lstat(unrelated.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testDedicatedRuntimeDirectoryUsesPinnedFDForRepairAndEnumeration_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Shared/Service/UnixSocketEngramServiceTransport.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private static func ensureSecureRuntimeDirectory")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "static func frameDeadline", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("fchmod(directoryFD, 0o700)"))
        XCTAssertTrue(body.contains("fdopendir"))
        XCTAssertTrue(body.contains("readdir"))
        XCTAssertTrue(body.contains("validateRuntimeDirectoryLeftovers(\n                directoryFD"))
        XCTAssertFalse(body.contains("contentsOfDirectory"))
    }

    func testDedicatedRuntimeDirectoryCreatesThroughPinnedParentFD_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Shared/Service/UnixSocketEngramServiceTransport.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private static func ensureSecureRuntimeDirectory")?.lowerBound)
        let end = try XCTUnwrap(source.range(of: "private static func validateRuntimeDirectory", range: start..<source.endIndex)?.lowerBound)
        let body = source[start..<end]

        XCTAssertTrue(body.contains("mkdirat(parentFD"))
        XCTAssertTrue(body.contains("openat(parentFD"))
        XCTAssertFalse(body.contains("createDirectory"))
    }

    func testSecureRuntimeDirectorySafelyRemovesSymlinkLeftover_repro() throws {
        let home = temporaryDirectory()
        let rootDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        let runDirectory = rootDirectory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(rootDirectory.path, 0o700)
        chmod(runDirectory.path, 0o700)
        let outside = home.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: runDirectory.appendingPathComponent("cmd.token"),
            withDestinationURL: outside
        )

        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home),
            runDirectory
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        var info = stat()
        XCTAssertEqual(lstat(runDirectory.appendingPathComponent("cmd.token").path, &info), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    func testSecureRuntimeDirectorySafelyRemovesHardlinkedKnownLeftover_repro() throws {
        let home = temporaryDirectory()
        let rootDirectory = home.appendingPathComponent(".engram", isDirectory: true)
        let runDirectory = rootDirectory.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(rootDirectory.path, 0o700)
        chmod(runDirectory.path, 0o700)
        let peer = home.appendingPathComponent("peer-token")
        let original = Data("shared-token".utf8)
        try original.write(to: peer)
        let token = runDirectory.appendingPathComponent("cmd.token")
        XCTAssertEqual(link(peer.path, token.path), 0)

        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home),
            runDirectory
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: token.path))
        XCTAssertEqual(try Data(contentsOf: peer), original)
    }

    func testDedicatedRuntimeDirectoryCleansNamespacedSidecarLinks_repro() throws {
        let home = temporaryDirectory()
        let runDirectory = home
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(runDirectory.deletingLastPathComponent().path, 0o700)
        chmod(runDirectory.path, 0o700)
        let outside = home.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let sidecars = ["custom.sock.cmd.token", "custom.sock.ai-secrets.json"]
        for name in sidecars {
            try FileManager.default.createSymbolicLink(
                at: runDirectory.appendingPathComponent(name),
                withDestinationURL: outside
            )
        }

        XCTAssertEqual(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home),
            runDirectory
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        for name in sidecars {
            var info = stat()
            XCTAssertEqual(lstat(runDirectory.appendingPathComponent(name).path, &info), -1)
            XCTAssertEqual(errno, ENOENT)
        }
    }

    func testCustomSocketParentFailsClosedWithoutChmodOrUnlink_repro() throws {
        let project = temporaryDirectory()
        chmod(project.path, 0o755)
        let outside = project.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("sentinel".utf8).write(to: outside)
        let unrelated = project.appendingPathComponent("unrelated-link")
        try FileManager.default.createSymbolicLink(at: unrelated, withDestinationURL: outside)

        XCTAssertThrowsError(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(at: project)
        )

        var projectInfo = stat()
        var linkInfo = stat()
        XCTAssertEqual(lstat(project.path, &projectInfo), 0)
        XCTAssertEqual(projectInfo.st_mode & 0o777, 0o755)
        XCTAssertEqual(lstat(unrelated.path, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testDedicatedRuntimeDirectoryRefusesUnknownSymlinkWithoutUnlinking_repro() throws {
        let home = temporaryDirectory()
        let runDirectory = home
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(runDirectory.deletingLastPathComponent().path, 0o700)
        chmod(runDirectory.path, 0o700)
        let outside = home.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let unknown = runDirectory.appendingPathComponent("unrelated-link")
        try FileManager.default.createSymbolicLink(at: unknown, withDestinationURL: outside)

        XCTAssertThrowsError(
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(homeDirectory: home)
        )

        var linkInfo = stat()
        XCTAssertEqual(lstat(unknown.path, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testConnectSocketRejectsSymlinkPath_repro() throws {
        let root = temporaryDirectory()
        let realPath = root.appendingPathComponent("real.sock").path
        let aliasPath = root.appendingPathComponent("alias.sock").path
        let listener = try UnixSocketEngramServiceTransport.bindSocket(path: realPath)
        defer { close(listener) }
        try FileManager.default.createSymbolicLink(atPath: aliasPath, withDestinationPath: realPath)

        XCTAssertThrowsError(try UnixSocketEngramServiceTransport.connectSocket(path: aliasPath)) { error in
            guard case EngramServiceError.serviceUnavailable = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
        }
    }

    func testBindSocketRejectsNonSocketPath() throws {
        let socketPath = temporarySocketPath()
        try "not a socket".write(toFile: socketPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)) { error in
            guard case EngramServiceError.serviceUnavailable = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testBindSocketRejectsWorldWritableRuntimeDirectory() throws {
        let directory = temporaryDirectory()
        chmod(directory.path, 0o777)
        let socketPath = directory.appendingPathComponent("s.sock").path

        XCTAssertThrowsError(try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)) { error in
            guard case EngramServiceError.serviceUnavailable = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
        }
    }

    func testFrameDeadlineHonorsLongRequestTimeout() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let deadline = UnixSocketEngramServiceTransport.frameDeadline(
            requestTimeout: 600,
            now: now
        )

        XCTAssertEqual(deadline.timeIntervalSince(now), 600, accuracy: 0.001)
    }

    func testRoundTripDecodesTypedStatus() async throws {
        let socketPath = temporarySocketPath()
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { request in
            let status = try JSONEncoder().encode(EngramServiceStatus.running(total: 9, todayParents: 2))
            return try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(requestId: request.requestId, result: status)
            )
        }
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: socketPath))
        let status = try await client.status()
        XCTAssertEqual(status, .running(total: 9, todayParents: 2))
    }

    func testEventsPollStatusInsteadOfFinishingEmpty() async throws {
        let socketPath = temporarySocketPath()
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { request in
            let status = try JSONEncoder().encode(EngramServiceStatus.running(total: 12, todayParents: 3))
            return try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(requestId: request.requestId, result: status)
            )
        }
        defer { server.stop() }

        let transport = UnixSocketEngramServiceTransport(socketPath: socketPath)
        var iterator = transport.events().makeAsyncIterator()
        let event = try await iterator.next()

        XCTAssertEqual(event?.event, "indexed")
        XCTAssertEqual(event?.total, 12)
        XCTAssertEqual(event?.todayParents, 3)
        transport.close()
    }

    func testEventsPreserveStartingStatusInsteadOfWarning() async throws {
        let socketPath = temporarySocketPath()
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { request in
            let status = try JSONEncoder().encode(EngramServiceStatus.starting)
            return try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(requestId: request.requestId, result: status)
            )
        }
        defer { server.stop() }

        let transport = UnixSocketEngramServiceTransport(socketPath: socketPath)
        var iterator = transport.events().makeAsyncIterator()
        let event = try await iterator.next()

        XCTAssertEqual(event?.event, "starting")
        XCTAssertNil(event?.message)
        transport.close()
    }

    func testLargeResponseCrossesFrameBoundary() async throws {
        let socketPath = temporarySocketPath()
        let largeTitle = String(repeating: "a", count: 128 * 1024)
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { request in
            let response = EngramServiceSearchResponse(items: [.init(id: "large", title: largeTitle)])
            return try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(
                    requestId: request.requestId,
                    result: try JSONEncoder().encode(response)
                )
            )
        }
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: socketPath))
        let response = try await client.search(.init(query: "large", mode: "keyword", limit: 1))
        XCTAssertEqual(response.items.first?.title?.count, largeTitle.count)
    }

    func testConcurrentReadCommandsResolveIndependently() async throws {
        let socketPath = temporarySocketPath()
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { request in
            let total = request.command == "status" ? 11 : 22
            let status = try JSONEncoder().encode(EngramServiceStatus.running(total: total, todayParents: 1))
            return try JSONEncoder().encode(
                EngramServiceResponseEnvelope.success(requestId: request.requestId, result: status)
            )
        }
        defer { server.stop() }

        let transport = UnixSocketEngramServiceTransport(socketPath: socketPath)
        let client = EngramServiceClient(transport: transport, defaultTimeout: 5)

        async let first = client.status()
        async let second = client.status()

        let statuses = try await [first, second]
        XCTAssertEqual(Set(statuses.map { status in
            if case .running(let total, _, _, _) = status { return total }
            return -1
        }), [11])
    }

    func testMalformedFrameMapsToInvalidRequest() async throws {
        let socketPath = temporarySocketPath()
        let server = try UnixSocketFixtureServer(socketPath: socketPath) { _ in
            Data("not-json".utf8)
        }
        defer { server.stop() }

        let client = EngramServiceClient(transport: UnixSocketEngramServiceTransport(socketPath: socketPath))
        do {
            _ = try await client.status()
            XCTFail("Expected invalidRequest")
        } catch let error as EngramServiceError {
            guard case .invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    func testReadFrameRejectsOversizedPayloadBeforeReadingBody() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        var length = UInt32(UnixSocketEngramServiceTransport.maximumFrameLength + 1).bigEndian
        withUnsafeBytes(of: &length) { buffer in
            XCTAssertEqual(write(fds[0], buffer.baseAddress, buffer.count), buffer.count)
        }

        XCTAssertThrowsError(try UnixSocketEngramServiceTransport.readFrame(from: fds[1])) { error in
            guard case EngramServiceError.invalidRequest = error else {
                return XCTFail("Expected invalidRequest, got \(error)")
            }
        }
    }

    func testUnresponsiveSocketHonorsTimeout() async throws {
        let socketPath = temporarySocketPath()
        let listener = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
        defer {
            close(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        Task.detached {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                close(client)
            }
        }

        let client = EngramServiceClient(
            transport: UnixSocketEngramServiceTransport(socketPath: socketPath),
            defaultTimeout: 0.1
        )
        do {
            _ = try await client.status()
            XCTFail("Expected serviceUnavailable")
        } catch let error as EngramServiceError {
            guard case .serviceUnavailable = error else {
                return XCTFail("Expected serviceUnavailable, got \(error)")
            }
        }
    }
}

private final class UnixSocketFixtureServer: @unchecked Sendable {
    private let socketPath: String
    private let fd: Int32
    private let acceptQueue = DispatchQueue(label: "UnixSocketFixtureServer.accept", qos: .userInitiated)
    private let handlerQueue = DispatchQueue(
        label: "UnixSocketFixtureServer.handlers",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(
        socketPath: String,
        handler: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data
    ) throws {
        self.socketPath = socketPath
        self.fd = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
        let fd = self.fd
        let handlerQueue = self.handlerQueue
        self.acceptQueue.async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                handlerQueue.async {
                    defer { close(client) }
                    do {
                        let data = try UnixSocketEngramServiceTransport.readFrame(from: client)
                        let request = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: data)
                        try UnixSocketEngramServiceTransport.writeFrame(try handler(request), to: client)
                    } catch {}
                }
            }
        }
    }

    func stop() {
        close(fd)
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}

private func temporaryDirectory() -> URL {
    let suffix = UUID().uuidString.prefix(8)
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("eg-\(suffix)", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}

private func temporarySocketPath() -> String {
    let directory = temporaryDirectory()
    return directory.appendingPathComponent("s.sock").path
}
