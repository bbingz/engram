import Darwin
import Foundation

final class UnixSocketServiceServer: @unchecked Sendable {
    typealias Handler = @Sendable (EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope

    private static let maximumConcurrentClients = 32
    private static let clientTimeoutSeconds: TimeInterval = 10

    private let socketPath: String
    private let handler: Handler
    private let connectionLimiter = ServiceConnectionLimiter(value: maximumConcurrentClients)
    private var fd: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        guard fd < 0 else { return }
        fd = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
        let fd = fd
        let handler = handler
        let connectionLimiter = connectionLimiter

        acceptTask = Task.detached {
            while !Task.isCancelled {
                await connectionLimiter.wait()
                let client = accept(fd, nil, nil)
                if client < 0 {
                    await connectionLimiter.signal()
                    break
                }
                try? UnixSocketEngramServiceTransport.disableSigPipe(client)
                try? UnixSocketEngramServiceTransport.setSocketTimeout(client, seconds: Self.clientTimeoutSeconds)
                Task.detached {
                    defer {
                        close(client)
                        Task { await connectionLimiter.signal() }
                    }
                    do {
                        let frame = try UnixSocketEngramServiceTransport.readFrame(from: client)
                        let request = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: frame)
                        let response = await handler(request)
                        try UnixSocketEngramServiceTransport.writeFrame(try JSONEncoder().encode(response), to: client)
                    } catch {
                        let response = EngramServiceResponseEnvelope.failure(
                            requestId: "unknown",
                            error: EngramServiceErrorEnvelope(
                                name: "InvalidRequest",
                                message: error.localizedDescription,
                                retryPolicy: "never"
                            )
                        )
                        try? UnixSocketEngramServiceTransport.writeFrame(try JSONEncoder().encode(response), to: client)
                    }
                }
            }
        }
    }

    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        _ = unlink(socketPath)
    }

    deinit {
        stop()
    }
}

private actor ServiceConnectionLimiter {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
