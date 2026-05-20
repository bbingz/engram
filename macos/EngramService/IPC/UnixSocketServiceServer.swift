import Darwin
import Foundation
import os

final class UnixSocketServiceServer: Sendable {
    typealias Handler = @Sendable (EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope

    private static let maximumConcurrentClients = 32
    private static let clientTimeoutSeconds: TimeInterval = 10

    private let socketPath: String
    private let handler: Handler
    private let connectionLimiter = ServiceConnectionLimiter(value: maximumConcurrentClients)
    private let state = OSAllocatedUnfairLock(initialState: UnixSocketServerState())

    init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        let descriptor = try state.withLock { state -> Int32? in
            guard state.descriptor < 0 else { return nil }
            let descriptor = try UnixSocketEngramServiceTransport.bindSocket(path: socketPath)
            state.descriptor = descriptor
            return descriptor
        }
        guard let descriptor else { return }

        let handler = handler
        let connectionLimiter = connectionLimiter
        let state = state

        let acceptTask = Task.detached {
            while !Task.isCancelled {
                do {
                    try await connectionLimiter.wait()
                } catch {
                    break
                }

                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    await connectionLimiter.signal()
                    break
                }
                try? UnixSocketEngramServiceTransport.disableSigPipe(client)
                try? UnixSocketEngramServiceTransport.setSocketTimeout(client, seconds: Self.clientTimeoutSeconds)
                let clientId = UUID()
                let clientTask = Task.detached {
                    defer {
                        close(client)
                        state.withLock { state in
                            _ = state.clientTasks.removeValue(forKey: clientId)
                        }
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
                let shouldContinue = state.withLock { state in
                    guard state.descriptor == descriptor else { return false }
                    state.clientTasks[clientId] = clientTask
                    return true
                }
                if !shouldContinue {
                    clientTask.cancel()
                }
            }
        }

        let taskToCancel = state.withLock { state -> Task<Void, Never>? in
            guard state.descriptor == descriptor else { return acceptTask }
            state.acceptTask = acceptTask
            return nil
        }
        taskToCancel?.cancel()
    }

    func stop() {
        let snapshot = state.withLock { state -> UnixSocketServerStateSnapshot in
            let snapshot = UnixSocketServerStateSnapshot(
                descriptor: state.descriptor,
                acceptTask: state.acceptTask,
                clientTasks: Array(state.clientTasks.values)
            )
            state.descriptor = -1
            state.acceptTask = nil
            state.clientTasks.removeAll()
            return snapshot
        }

        snapshot.acceptTask?.cancel()
        for task in snapshot.clientTasks {
            task.cancel()
        }
        if snapshot.descriptor >= 0 {
            close(snapshot.descriptor)
        }
        _ = unlink(socketPath)
    }

    deinit {
        stop()
    }
}

private struct UnixSocketServerState: Sendable {
    var descriptor: Int32 = -1
    var acceptTask: Task<Void, Never>?
    var clientTasks: [UUID: Task<Void, Never>] = [:]
}

private struct UnixSocketServerStateSnapshot: Sendable {
    var descriptor: Int32
    var acceptTask: Task<Void, Never>?
    var clientTasks: [Task<Void, Never>]
}

private actor ServiceConnectionLimiter {
    private var permits: Int
    private var waiters: [Waiter] = []

    init(value: Int) {
        permits = value
    }

    func wait() async throws {
        if permits > 0 {
            permits -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }
}
