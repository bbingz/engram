import CryptoKit
import Darwin
import Foundation
@testable import EngramRemoteServerCore
import XCTest

final class WebAliasHTTPTests: XCTestCase {
    private static let viewer = "d4-viewer"
    private static let editor = "d4-editor"
    private static let origin = "https://127.0.0.1"
    fileprivate static let host = "127.0.0.1"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("engram-d4-http-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testViewerPostIs403AndDoesNotCallWriteSurface() async throws {
        let recorder = AliasRecorder()
        try await withServer(write: recorder.surface(failOnCall: true)) { server in
            let cookie = try await Self.login(server, credential: Self.viewer)
            let response = try await server.request(
                "POST", "/web/api/settings/aliases",
                headers: Self.writeHeaders + [("Cookie", cookie)],
                body: Data(#"{"canonical":"project_1","alias":"/old/engram"}"#.utf8)
            )
            XCTAssertEqual(response.status, 403)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("capability_token"))
        }
        XCTAssertEqual(recorder.adds.count, 0)
        XCTAssertEqual(recorder.removes.count, 0)
    }

    func testEditorAddPreservesPathShapedAliasText() async throws {
        let recorder = AliasRecorder()
        let published = try XCTUnwrap(EngramServiceWebWriteValidation.publishedProjectKey("/old/engram"))
        recorder.addResult = try EngramServiceWebAliasMutationResponse(
            action: "add", alias: published, canonical: "project_1", changed: 1
        )
        try await withServer(write: recorder.surface()) { server in
            let cookie = try await Self.login(server, credential: Self.editor)
            let response = try await server.request(
                "POST", "/web/api/settings/aliases",
                headers: Self.writeHeaders + [("Cookie", cookie)],
                body: Data(#"{"canonical":"project_1","alias":"/old/engram"}"#.utf8)
            )
            XCTAssertEqual(response.status, 200)
            let body = try JSONDecoder().decode(EngramServiceWebAliasMutationResponse.self, from: response.body)
            XCTAssertEqual(body.action, "add")
            XCTAssertEqual(body.changed, 1)
            XCTAssertEqual(body.alias, published)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("capability_token"))
        }
        XCTAssertEqual(recorder.adds.map(\.alias), ["/old/engram"])
        XCTAssertEqual(recorder.adds.map(\.canonical), ["project_1"])
    }

    func testPrefixedAliasPathIsRejectedWithoutWriterCall() async throws {
        let recorder = AliasRecorder()
        try await withServer(write: recorder.surface(failOnCall: true)) { server in
            let cookie = try await Self.login(server, credential: Self.editor)
            let response = try await server.request(
                "POST", "/web/api/settings/aliases/extra",
                headers: Self.writeHeaders + [("Cookie", cookie)],
                body: Data(#"{"canonical":"project_1","alias":"/old/engram"}"#.utf8)
            )
            XCTAssertEqual(response.status, 405)
        }
        XCTAssertEqual(recorder.adds.count, 0)
        XCTAssertEqual(recorder.removes.count, 0)
    }

    func testOversizedAndUnknownKeyBodiesAre400() async throws {
        let recorder = AliasRecorder()
        try await withServer(write: recorder.surface(failOnCall: true)) { server in
            let cookie = try await Self.login(server, credential: Self.editor)
            let oversized = Data(
                #"{"canonical":"project_1","alias":""#.utf8
                    + [UInt8](repeating: 0x61, count: 4096)
                    + Data(#""}"#.utf8)
            )
            XCTAssertGreaterThan(oversized.count, 4096)
            let large = try await server.request(
                "POST", "/web/api/settings/aliases",
                headers: Self.writeHeaders + [("Cookie", cookie)],
                body: oversized
            )
            XCTAssertEqual(large.status, 400)
            let unknown = try await server.request(
                "POST", "/web/api/settings/aliases",
                headers: Self.writeHeaders + [("Cookie", cookie)],
                body: Data(#"{"canonical":"project_1","alias":"/old/engram","extra":1}"#.utf8)
            )
            XCTAssertEqual(unknown.status, 400)
        }
        XCTAssertEqual(recorder.adds.count, 0)
    }

    private func withServer(
        write: WebWriteRoutes.Surface,
        operation: (D4HTTPServer) async throws -> Void
    ) async throws {
        let app = try EngramRemoteServerApp(
            config: config(),
            webReadClientFactory: { _ in
                WebReadRoutes.messagesOnly({ _ in throw EngramServiceWebReadClientError.unavailable })
            },
            webWriteClientFactory: { _ in write }
        )
        let server = try await D4HTTPServer(app: app)
        do { try await operation(server) } catch {
            do { try await server.stop() } catch { XCTFail("Server cleanup failed: \(error)") }
            throw error
        }
        try await server.stop()
    }

    private func config() throws -> EngramRemoteServerConfig {
        try EngramRemoteServerConfig(
            host: "127.0.0.1", port: 0, storeRoot: directory.appendingPathComponent("legacy"),
            bearerToken: "d4-bearer", atRestKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            web: try EngramRemoteWebConfig(
                origin: Self.origin, viewerCredential: Self.viewer,
                serverBearerCredentials: ["d4-bearer"], editorCredential: Self.editor
            ),
            webServiceSocketPath: directory.appendingPathComponent("service.sock").path
        )
    }

    private static var writeHeaders: [(String, String)] {
        [("X-Engram-Web", "1"), ("Origin", origin), ("Content-Type", "application/json")]
    }

    private static func login(_ server: D4HTTPServer, credential: String) async throws -> String {
        let body = Data("{\"credential\":\"\(credential)\"}".utf8)
        let response = try await server.request(
            "POST", "/web/api/auth", headers: writeHeaders, body: body
        )
        XCTAssertEqual(response.status, 204)
        return try XCTUnwrap(response.header("set-cookie")?.split(separator: ";").first.map(String.init))
    }
}

private final class AliasRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var addCalls: [EngramServiceWebAddAliasRequest] = []
    private var removeCalls: [EngramServiceWebRemoveAliasRequest] = []
    var addResult: EngramServiceWebAliasMutationResponse?
    var adds: [EngramServiceWebAddAliasRequest] { lock.lock(); defer { lock.unlock() }; return addCalls }
    var removes: [EngramServiceWebRemoveAliasRequest] { lock.lock(); defer { lock.unlock() }; return removeCalls }

    func surface(failOnCall: Bool = false) -> WebWriteRoutes.Surface {
        WebWriteRoutes.Surface(
            addAlias: { request in
                if failOnCall { XCTFail("Write surface must not run") }
                self.lock.lock(); self.addCalls.append(request); self.lock.unlock()
                return try XCTUnwrap(self.addResult)
            },
            removeAlias: { request in
                if failOnCall { XCTFail("Write surface must not run") }
                self.lock.lock(); self.removeCalls.append(request); self.lock.unlock()
                throw EngramServiceWebWriteClientError.unavailable
            }
        )
    }
}

final class D4HTTPServer: @unchecked Sendable {
    let port: Int
    private let state = D4ServerState()
    private let task: Task<Void, Never>

    init(app: EngramRemoteServerApp) async throws {
        let state = state
        let task = Task {
            do { try await app.run(onBound: { state.bound($0) }); state.finished(.success(())) }
            catch { state.finished(.failure(error)) }
        }
        do { port = try await state.awaitPort() }
        catch {
            task.cancel()
            do { try await Task.detached { try await state.awaitCompletion() }.value }
            catch { XCTFail("Failed startup cleanup: \(error)") }
            throw error
        }
        self.task = task
    }

    func stop() async throws {
        task.cancel()
        let state = state
        try await Task.detached { try await state.awaitCompletion() }.value
    }

    func request(_ method: String, _ path: String, headers: [(String, String)] = [], body: Data = Data()) async throws -> D4HTTPResponse {
        try D4HTTPResponse.exchange(port: port, method: method, path: path, headers: headers, body: body)
    }
}

final class D4ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var completion: Result<Void, Error>?
    private var portWaiters: [CheckedContinuation<Int, Error>] = []
    private var doneWaiters: [CheckedContinuation<Void, Error>] = []

    func bound(_ port: Int) {
        lock.lock()
        self.port = port
        let waiters = portWaiters
        portWaiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: port) }
    }

    func finished(_ result: Result<Void, Error>) {
        lock.lock()
        completion = result
        let portWaiters = portWaiters
        let doneWaiters = doneWaiters
        self.portWaiters = []
        self.doneWaiters = []
        lock.unlock()
        for waiter in portWaiters {
            if case .failure(let error) = result { waiter.resume(throwing: error) }
            else { waiter.resume(throwing: D4Failure("Server exited before binding")) }
        }
        for waiter in doneWaiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    func awaitPort() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let port { lock.unlock(); continuation.resume(returning: port); return }
            if let completion {
                lock.unlock()
                if case .failure(let error) = completion { continuation.resume(throwing: error) }
                else { continuation.resume(throwing: D4Failure("Server exited before binding")) }
                return
            }
            portWaiters.append(continuation)
            lock.unlock()
        }
    }

    func awaitCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                switch completion {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
                return
            }
            doneWaiters.append(continuation)
            lock.unlock()
        }
    }
}

struct D4HTTPResponse: Sendable {
    let status: Int
    let headers: [String: [String]]
    let body: Data
    func header(_ name: String) -> String? { headers[name.lowercased()]?.first }

    static func exchange(port: Int, method: String, path: String, headers: [(String, String)], body: Data) throws -> Self {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw D4Failure("Cannot create HTTP test socket") }
        defer { close(fd) }
        try EngramServiceSocketIO.disableSigPipe(fd)
        try EngramServiceSocketIO.setSocketTimeout(fd, seconds: 3)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw D4Failure("Invalid loopback") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw D4Failure("HTTP connect failed: \(errno)") }
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(WebAliasHTTPTests.host)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        var bytes = Data(request.utf8)
        bytes.append(body)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw D4Failure("HTTP write failed") }
                offset += count
            }
        }
        var incoming = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            incoming.append(chunk, count: count)
        }
        guard let headerEnd = incoming.range(of: Data("\r\n\r\n".utf8)) else { throw D4Failure("HTTP headers missing") }
        let head = String(decoding: incoming[incoming.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first, let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            throw D4Failure("HTTP status missing")
        }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }
        return Self(status: status, headers: headers, body: Data(incoming[headerEnd.upperBound...]))
    }
}

struct D4Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
