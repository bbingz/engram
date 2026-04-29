import Darwin
import XCTest
@testable import Engram

final class UnixSocketTransportTests: XCTestCase {
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
        await transport.close()
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
        let client = EngramServiceClient(transport: transport)

        async let first = client.status()
        async let second = client.status()

        let statuses = try await [first, second]
        XCTAssertEqual(Set(statuses.map { status in
            if case .running(let total, _) = status { return total }
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
        try withUnsafeBytes(of: &length) { buffer in
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
                Thread.sleep(forTimeInterval: 1)
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
    private let task: Task<Void, Never>
    private let decoder = JSONDecoder()

    init(
        socketPath: String,
        handler: @escaping @Sendable (EngramServiceRequestEnvelope) throws -> Data
    ) throws {
        self.socketPath = socketPath
        self.fd = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
        let fd = self.fd
        let decoder = self.decoder
        self.task = Task.detached {
            while !Task.isCancelled {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Task.detached {
                    defer { close(client) }
                    do {
                        let data = try UnixSocketEngramServiceTransport.readFrame(from: client)
                        let request = try decoder.decode(EngramServiceRequestEnvelope.self, from: data)
                        try UnixSocketEngramServiceTransport.writeFrame(try handler(request), to: client)
                    } catch {
                        close(client)
                    }
                }
            }
        }
    }

    func stop() {
        task.cancel()
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
