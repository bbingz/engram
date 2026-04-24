import Darwin
import Foundation

final class UnixSocketServiceServer: @unchecked Sendable {
    typealias Handler = @Sendable (EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope

    private let socketPath: String
    private let handler: Handler
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
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
        let decoder = decoder
        let encoder = encoder
        let handler = handler

        acceptTask = Task.detached {
            while !Task.isCancelled {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                try? UnixSocketEngramServiceTransport.disableSigPipe(client)
                Task.detached {
                    defer { close(client) }
                    do {
                        let frame = try UnixSocketEngramServiceTransport.readFrame(from: client)
                        let request = try decoder.decode(EngramServiceRequestEnvelope.self, from: frame)
                        let response = await handler(request)
                        try UnixSocketEngramServiceTransport.writeFrame(try encoder.encode(response), to: client)
                    } catch {
                        let response = EngramServiceResponseEnvelope.failure(
                            requestId: "unknown",
                            error: EngramServiceErrorEnvelope(
                                name: "InvalidRequest",
                                message: error.localizedDescription,
                                retryPolicy: "never"
                            )
                        )
                        try? UnixSocketEngramServiceTransport.writeFrame(try encoder.encode(response), to: client)
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
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    deinit {
        stop()
    }
}
