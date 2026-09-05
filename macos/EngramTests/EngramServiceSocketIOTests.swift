import Darwin
import Foundation
import XCTest
@testable import Engram

final class EngramServiceSocketIOTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("e-io-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    func testRawExchangePreservesBytesAndNeverAddsACapabilityToken() async throws {
        let path = socketPath()
        let tokenPath = path + ".cmd.token"
        let sentinel = Data("fixture-token-must-not-be-loaded".utf8)
        try sentinel.write(to: URL(fileURLWithPath: tokenPath))
        let request = try JSONEncoder().encode(EngramServiceRequestEnvelope(command: "shutdown"))
        let response = Data("opaque-response-bytes".utf8)
        let fixture = try SocketIOFixture(path: path) { fd in
            let received = try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 1)
            XCTAssertEqual(received, request)
            let decoded = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: received)
            XCTAssertNil(decoded.capabilityToken)
            try UnixSocketEngramServiceTransport.writeFrame(response, to: fd, requestTimeout: 1)
        }
        defer { fixture.stop() }

        let actual = try await EngramServiceSocketIO.exchange(request, socketPath: path, totalTimeout: 1)

        XCTAssertEqual(actual, response)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tokenPath)), sentinel)
    }

    func testRawExchangeAcceptsExactlyTheMaximumFrameInBothDirections() async throws {
        let bytes = Data(repeating: 0x5A, count: 256 * 1024)
        let path = socketPath()
        let fixture = try SocketIOFixture(path: path) { fd in
            XCTAssertEqual(try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 2), bytes)
            try UnixSocketEngramServiceTransport.writeFrame(bytes, to: fd, requestTimeout: 2)
        }
        defer { fixture.stop() }

        let actual = try await EngramServiceSocketIO.exchange(bytes, socketPath: path, totalTimeout: 2)

        XCTAssertEqual(actual, bytes)
    }

    func testRawExchangeRejectsEmptyAndOversizedRequestsBeforeOpeningSocket() async {
        let publications = SocketIOCounter()
        for request in [Data(), Data(repeating: 0, count: 256 * 1024 + 1)] {
            await assertServiceError(.invalidRequest) {
                try await EngramServiceSocketIO.exchange(
                    request, socketPath: self.socketPath(), totalTimeout: 1,
                    testHooks: .init(beforeDescriptorPublication: { _ in publications.increment() })
                )
            }
        }
        XCTAssertEqual(publications.value, 0)
    }

    func testRawExchangeRejectsInvalidTimeoutsBeforeOpeningSocket() async {
        let publications = SocketIOCounter()
        let invalid: [TimeInterval] = [
            0, -1, .nan, .infinity, -.infinity,
            EngramServiceSocketIO.maximumExchangeTimeoutSeconds + 1, .greatestFiniteMagnitude,
        ]
        for timeout in invalid {
            await assertServiceError(.invalidRequest) {
                try await EngramServiceSocketIO.exchange(
                    Data([1]), socketPath: self.socketPath(), totalTimeout: timeout,
                    testHooks: .init(beforeDescriptorPublication: { _ in publications.increment() })
                )
            }
        }
        XCTAssertEqual(publications.value, 0)
    }

    func testRawExchangeRejectsInvalidPathsBeforeOpeningSocket() async {
        let publications = SocketIOCounter()
        for path in ["", "relative.sock", "/tmp/fixture.sock\0hidden", "/" + String(repeating: "a", count: 256)] {
            await assertServiceError(.invalidRequest) {
                try await EngramServiceSocketIO.exchange(
                    Data([1]), socketPath: path, totalTimeout: 1,
                    testHooks: .init(beforeDescriptorPublication: { _ in publications.increment() })
                )
            }
        }
        XCTAssertEqual(publications.value, 0)
    }

    func testRawExchangeRejectsMissingAndRegularPathsWithoutMutatingThem() async throws {
        let path = socketPath()
        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(Data([1]), socketPath: path, totalTimeout: 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let sentinel = Data("keep-existing-file".utf8)
        try sentinel.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o644), 0)

        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(Data([1]), socketPath: path, totalTimeout: 1)
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), sentinel)
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
    }

    func testRawExchangeRejectsSymlinkAndNonOwnerOnlySocketWithoutRepair() async throws {
        let path = socketPath()
        let fixture = try SocketIOFixture(path: path) { _ in }
        defer { fixture.stop() }
        let alias = directory.appendingPathComponent("alias.sock").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)

        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(Data([1]), socketPath: alias, totalTimeout: 1)
        }
        var linkInfo = stat()
        XCTAssertEqual(lstat(alias, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)

        XCTAssertEqual(chmod(path, 0o666), 0)
        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(Data([1]), socketPath: path, totalTimeout: 1)
        }
        var socketInfo = stat()
        XCTAssertEqual(lstat(path, &socketInfo), 0)
        XCTAssertEqual(socketInfo.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o666)
    }

    func testRawExchangeRejectsInvalidIncomingLengthWithoutWaitingForBody() async throws {
        for (index, length) in [UInt32(0), UInt32(256 * 1024 + 1), UInt32.max].enumerated() {
            let path = socketPath("length-\(index).sock")
            let fixture = try SocketIOFixture(path: path) { fd in
                _ = try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 1)
                var prefix = length.bigEndian
                try withUnsafeBytes(of: &prefix) { try Self.writePeerBytes($0, to: fd) }
            }
            defer { fixture.stop() }
            await assertServiceError(.invalidRequest) {
                try await EngramServiceSocketIO.exchange(Data([1]), socketPath: path, totalTimeout: 0.5)
            }
        }
    }

    func testRawExchangeTotalDeadlineStopsAContinuouslyTricklingFrame() async throws {
        let path = socketPath()
        let fixture = try SocketIOFixture(path: path) { fd in
            _ = try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 1)
            var prefix = UInt32(100).bigEndian
            var bytes = withUnsafeBytes(of: &prefix) { Array($0) }
            bytes += [UInt8](repeating: 0x61, count: 100)
            for byte in bytes {
                try Data([byte]).withUnsafeBytes { try Self.writePeerBytes($0, to: fd) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        defer { fixture.stop() }
        let start = ContinuousClock.now

        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(Data([1]), socketPath: path, totalTimeout: 0.15)
        }

        XCTAssertLessThan(Self.elapsed(since: start), 1, "progress must not renew the total deadline")
    }

    func testRawExchangeTotalDeadlineBoundsBlockedWrites() async throws {
        let path = socketPath()
        let release = DispatchSemaphore(value: 0)
        let fixture = try SocketIOFixture(path: path) { _ in
            _ = release.wait(timeout: .now() + 2)
        }
        defer { release.signal(); fixture.stop() }
        let start = ContinuousClock.now

        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(
                Data(repeating: 1, count: 256 * 1024), socketPath: path, totalTimeout: 0.15,
                testHooks: .init(beforeDescriptorPublication: { fd in
                    var bytes: Int32 = 1024
                    XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bytes, socklen_t(MemoryLayout.size(ofValue: bytes))), 0)
                })
            )
        }

        XCTAssertLessThan(Self.elapsed(since: start), 1)
    }

    func testRawExchangeDeadlineAlreadyRunsBeforeDescriptorPublication() async throws {
        let path = socketPath()
        let fixture = try SocketIOFixture(path: path) { fd in
            _ = try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 1)
            try UnixSocketEngramServiceTransport.writeFrame(Data([9]), to: fd, requestTimeout: 1)
        }
        defer { fixture.stop() }

        await assertServiceError(.serviceUnavailable) {
            try await EngramServiceSocketIO.exchange(
                Data([1]), socketPath: path, totalTimeout: 0.05,
                testHooks: .init(beforeDescriptorPublication: { _ in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                })
            )
        }
    }

    func testCancellationBeforeDescriptorPublicationIsRememberedAndClosesOwnedFD() async throws {
        let path = socketPath()
        let fixture = try SocketIOFixture(path: path) { _ in }
        defer { fixture.stop() }
        let arrived = expectation(description: "descriptor created but not published")
        let gate = SocketIOAsyncGate(arrived: arrived)
        let task = Task {
            try await EngramServiceSocketIO.exchange(
                Data([1]), socketPath: path, totalTimeout: 2,
                testHooks: .init(beforeDescriptorPublication: { fd in await gate.suspend(descriptor: fd) })
            )
        }
        await fulfillment(of: [arrived], timeout: 2)
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("expected cancellation after pre-publication cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        if let fd = await gate.descriptor {
            XCTAssertEqual(fcntl(fd, F_GETFD), -1, "the task must close the descriptor it created")
            XCTAssertEqual(errno, EBADF)
        } else {
            XCTFail("the deterministic pre-publication hook was not reached")
        }
    }

    func testAlreadyCancelledExchangeNeverCreatesDescriptor() async throws {
        let entered = expectation(description: "task parked before exchange")
        let gate = SocketIOAsyncGate(arrived: entered)
        let publications = SocketIOCounter()
        let path = socketPath()
        let task = Task {
            await gate.suspend()
            return try await EngramServiceSocketIO.exchange(
                Data([1]), socketPath: path, totalTimeout: 2,
                testHooks: .init(beforeDescriptorPublication: { _ in publications.increment() })
            )
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("expected an already-cancelled exchange to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertEqual(publications.value, 0)
    }

    func testGeneralTransportCancellationStillClosesAnInFlightPeerPromptly() async throws {
        let path = socketPath()
        let received = expectation(description: "general client request arrived")
        let closed = expectation(description: "general client cancellation closed peer")
        let fixture = try SocketIOFixture(path: path) { fd in
            _ = try UnixSocketEngramServiceTransport.readFrame(from: fd, requestTimeout: 1)
            try UnixSocketEngramServiceTransport.setSocketTimeout(fd, seconds: 3)
            received.fulfill()
            var byte: UInt8 = 0
            while true {
                let count = recv(fd, &byte, 1, 0)
                if count < 0, errno == EINTR { continue }
                if count == 0 { closed.fulfill() }
                break
            }
        }
        defer { fixture.stop() }
        let transport = UnixSocketEngramServiceTransport(socketPath: path)
        let task = Task {
            try await transport.send(EngramServiceRequestEnvelope(command: "fixture-read"), timeout: 600)
        }
        await fulfillment(of: [received], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancelled general transport send")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await fulfillment(of: [closed], timeout: 1)
    }

    func testWireEnvelopeExtractionPreservesExistingKeysAndDataEncoding() throws {
        let request = EngramServiceRequestEnvelope(
            requestId: "fixture-request", command: "fixture-read", payload: Data([1, 2, 3]), capabilityToken: "fixture-token"
        )
        let bytes = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["request_id", "kind", "command", "payload", "capability_token"])
        XCTAssertEqual(object["payload"] as? String, "AQID")
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: bytes), request)

        let success = EngramServiceResponseEnvelope.success(
            requestId: "fixture-request", result: Data([4, 5, 6]), databaseGeneration: 7
        )
        let successBytes = try JSONEncoder().encode(success)
        let successObject = try XCTUnwrap(JSONSerialization.jsonObject(with: successBytes) as? [String: Any])
        XCTAssertEqual(successObject["database_generation"] as? Int, 7)
        XCTAssertEqual(successObject["result"] as? String, "BAUG")
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: successBytes), success)

        let failure = EngramServiceResponseEnvelope.failure(
            requestId: "fixture-request",
            error: .init(name: "fixture_error", message: "safe", retryPolicy: "never", details: ["complete": .bool(true)])
        )
        let failureBytes = try JSONEncoder().encode(failure)
        XCTAssertEqual(try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: failureBytes), failure)
    }

    private enum ExpectedServiceError { case invalidRequest, serviceUnavailable }

    private func assertServiceError(
        _ expected: ExpectedServiceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Data
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as EngramServiceError {
            switch (expected, error) {
            case (.invalidRequest, .invalidRequest), (.serviceUnavailable, .serviceUnavailable): break
            default: XCTFail("unexpected service error \(error)", file: file, line: line)
            }
            XCTAssertFalse(error.localizedDescription.contains(directory.path), file: file, line: line)
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
        }
    }

    private func socketPath(_ filename: String = "s.sock") -> String {
        directory.appendingPathComponent(filename).path
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private static func writePeerBytes(_ bytes: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PeerClosed() }
            offset += count
        }
    }

    private struct PeerClosed: Error {}
}

private final class SocketIOFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private let listener: Int32
    private let path: String
    private var client: Int32?
    private var stopped = false

    init(path: String, handler: @escaping @Sendable (Int32) throws -> Void) throws {
        self.path = path
        listener = try UnixSocketEngramServiceTransport.bindSocket(path: path)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else { return }
            lock.lock()
            guard !stopped else {
                close(accepted)
                lock.unlock()
                return
            }
            client = accepted
            lock.unlock()
            defer {
                lock.lock()
                client = nil
                close(accepted)
                lock.unlock()
            }
            do {
                try UnixSocketEngramServiceTransport.disableSigPipe(accepted)
                try UnixSocketEngramServiceTransport.setSocketTimeout(accepted, seconds: 1)
                try handler(accepted)
            } catch {}
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if let client { _ = Darwin.shutdown(client, SHUT_RDWR) }
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        close(listener)
        lock.unlock()
        _ = group.wait(timeout: .now() + 3)
        try? FileManager.default.removeItem(atPath: path)
    }
}

private actor SocketIOAsyncGate {
    let arrived: XCTestExpectation
    private(set) var descriptor: Int32?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(arrived: XCTestExpectation) { self.arrived = arrived }

    func suspend(descriptor: Int32? = nil) async {
        self.descriptor = descriptor
        arrived.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class SocketIOCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
