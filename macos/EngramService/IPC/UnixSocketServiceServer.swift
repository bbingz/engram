import Darwin
import Foundation
import os

final class UnixSocketServiceServer: Sendable {
    typealias Handler = @Sendable (EngramServiceRequestEnvelope) async -> EngramServiceResponseEnvelope

    private static let maximumConcurrentClients = 32
    private static let clientTimeoutSeconds: TimeInterval = 10
    private static let blockingIOQueue = DispatchQueue(
        label: "com.engram.service.ipc.blocking-io",
        qos: .userInitiated,
        attributes: .concurrent
    )

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

        // SEC-H1: write a fresh per-launch capability token next to the socket
        // before we begin accepting connections. Trusted same-user clients read
        // this 0600 file and attach it to destructive requests. This happens
        // only for a newly-bound listener; repeated start() calls on an already
        // running server must not invalidate the token used by current clients.
        let tokenPath = ServiceCapabilityToken.path(forSocketPath: socketPath)
        let capabilityToken: String
        do {
            capabilityToken = try ServiceCapabilityToken.generateAndWrite(toPath: tokenPath)
        } catch {
            state.withLock { state in
                if state.descriptor == descriptor {
                    state.descriptor = -1
                }
            }
            close(descriptor)
            _ = unlink(socketPath)
            throw error
        }

        let handler = handler
        let connectionLimiter = connectionLimiter
        let state = state
        let serviceEuid = geteuid()
        ServiceLogger.notice("ipc listener ready path=\(socketPath)", category: .ipc)

        let acceptTask = Task.detached {
            while !Task.isCancelled {
                do {
                    try await connectionLimiter.wait()
                } catch {
                    break
                }

                let client: Int32
                do {
                    client = try await Self.acceptClientOffCooperativePool(from: descriptor)
                } catch let error as AcceptFailure {
                    await connectionLimiter.signal()
                    let acceptErrno = error.code
                    // IPC-H1: do not tear down the listener on transient errors.
                    switch acceptErrno {
                    case EINTR, ECONNABORTED:
                        // Interrupted / aborted before completion — retry now.
                        continue
                    case EMFILE, ENFILE:
                        // Descriptor exhaustion — back off briefly, then retry.
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    case EBADF, EINVAL:
                        // Listener was closed by stop(); exit the loop.
                        return
                    default:
                        // Unknown transient error: retry rather than wedging the
                        // whole service on a single failed accept.
                        continue
                    }
                } catch {
                    await connectionLimiter.signal()
                    continue
                }
                // SEC-H1: reject peers whose effective uid differs from the
                // service euid. A Unix socket inherits the directory/inode
                // permissions, but an explicit getpeereid check is a hard gate.
                if !Self.peerIsAuthorized(client, serviceEuid: serviceEuid) {
                    close(client)
                    await connectionLimiter.signal()
                    continue
                }
                try? UnixSocketEngramServiceTransport.disableSigPipe(client)
                do {
                    // The receive timeout is the ONLY bound on the blocking
                    // readFrame below. If it can't be armed, reject the
                    // connection rather than spawn a client task that could
                    // block forever and permanently leak its connection-limiter
                    // permit (32 such leaks wedge ALL future connections).
                    try UnixSocketEngramServiceTransport.setSocketTimeout(client, seconds: Self.clientTimeoutSeconds)
                } catch {
                    close(client)
                    await connectionLimiter.signal()
                    continue
                }
                let clientId = UUID()
                let startGate = ClientTaskStartGate()
                let clientTask = Task.detached {
                    // The gate returns false when the task was cancelled before
                    // release(). That happens only in the !shouldContinue branch
                    // below, where the accept loop has already closed the fd and
                    // signalled the connection limiter. Return WITHOUT arming the
                    // cleanup defer so the fd is not double-closed and the permit
                    // is not double-signalled.
                    guard await startGate.wait() else { return }
                    defer {
                        close(client)
                        state.withLock { state in
                            _ = state.clientTasks.removeValue(forKey: clientId)
                        }
                        Task { await connectionLimiter.signal() }
                    }
                    // IPC-M1: two-stage decode so an error reply can carry the
                    // real request id when the envelope was decodable. Falling
                    // back to "unknown" only when no id is extractable avoids
                    // tripping the client's response-id match guard.
                    var decodedRequestId: String?
                    do {
                        let frame = try await Self.readFrameOffCooperativePool(from: client)
                        let request = try JSONDecoder().decode(EngramServiceRequestEnvelope.self, from: frame)
                        decodedRequestId = request.requestId
                        // SEC-H1: destructive commands require a matching token.
                        if ServiceCapabilityToken.requiresToken(request.command),
                           request.capabilityToken != capabilityToken {
                            throw EngramServiceError.unauthorized(
                                message: "Missing or invalid capability token for \(request.command)"
                            )
                        }
                        let response = await handler(request)
                        try await Self.writeFrameOffCooperativePool(try JSONEncoder().encode(response), to: client)
                    } catch {
                        let response = Self.errorResponse(for: error, requestId: decodedRequestId)
                        try? await Self.writeFrameOffCooperativePool(try JSONEncoder().encode(response), to: client)
                    }
                }
                let shouldContinue = state.withLock { state in
                    guard state.descriptor == descriptor else { return false }
                    state.clientTasks[clientId] = clientTask
                    return true
                }
                if !shouldContinue {
                    // stop() flipped the listener between accept() and
                    // registration; the parked clientTask's defer never runs, so
                    // release its fd + permit here or 32 leaks wedge all clients.
                    clientTask.cancel()
                    close(client)
                    await connectionLimiter.signal()
                } else {
                    await startGate.release()
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
            shutdown(snapshot.descriptor, SHUT_RDWR)
            close(snapshot.descriptor)
        }
        _ = unlink(socketPath)
        // SEC-H1: remove the per-launch capability token so a stale token from
        // a previous launch cannot be reused against a future one.
        _ = unlink(ServiceCapabilityToken.path(forSocketPath: socketPath))
    }

    deinit {
        stop()
    }

    func activeClientTaskCountForTesting() -> Int {
        state.withLock { state in state.clientTasks.count }
    }

    /// SEC-H1: verify the connected peer's effective uid matches the service.
    static func peerIsAuthorized(_ fd: Int32, serviceEuid: uid_t) -> Bool {
        var peerEuid: uid_t = 0
        var peerEgid: gid_t = 0
        guard getpeereid(fd, &peerEuid, &peerEgid) == 0 else {
            return false
        }
        return peerEuid == serviceEuid
    }

    /// IPC-M1: build an error reply, preferring the decoded request id and only
    /// falling back to "unknown" when no id is available. Maps known service
    /// errors to their envelope names so e.g. unauthorized stays unauthorized.
    static func errorResponse(
        for error: Error,
        requestId: String?
    ) -> EngramServiceResponseEnvelope {
        let resolvedId = requestId ?? "unknown"
        if let serviceError = error as? EngramServiceError {
            return .failure(requestId: resolvedId, error: Self.errorEnvelope(serviceError))
        }
        return .failure(
            requestId: resolvedId,
            error: EngramServiceErrorEnvelope(
                name: "InvalidRequest",
                message: error.localizedDescription,
                retryPolicy: "never"
            )
        )
    }

    private static func errorEnvelope(_ error: EngramServiceError) -> EngramServiceErrorEnvelope {
        switch error {
        case .serviceUnavailable(let message):
            return EngramServiceErrorEnvelope(name: "ServiceUnavailable", message: message, retryPolicy: "safe")
        case .transportClosed(let message):
            return EngramServiceErrorEnvelope(name: "TransportClosed", message: message, retryPolicy: "safe")
        case .invalidRequest(let message):
            return EngramServiceErrorEnvelope(name: "InvalidRequest", message: message, retryPolicy: "never")
        case .unauthorized(let message):
            return EngramServiceErrorEnvelope(name: "Unauthorized", message: message, retryPolicy: "never")
        case .writerBusy(let message):
            return EngramServiceErrorEnvelope(name: "WriterBusy", message: message, retryPolicy: "safe")
        case .unsupportedProvider(let provider):
            return EngramServiceErrorEnvelope(
                name: "UnsupportedProvider",
                message: "Unsupported provider: \(provider)",
                retryPolicy: "none",
                details: ["provider": .string(provider)]
            )
        case .commandFailed(let name, let message, let retryPolicy, let details):
            return EngramServiceErrorEnvelope(name: name, message: message, retryPolicy: retryPolicy, details: details)
        }
    }

    private static func readFrameOffCooperativePool(from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            blockingIOQueue.async {
                do {
                    continuation.resume(returning: try UnixSocketEngramServiceTransport.readFrame(from: fd))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func writeFrameOffCooperativePool(_ data: Data, to fd: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            blockingIOQueue.async {
                do {
                    try UnixSocketEngramServiceTransport.writeFrame(data, to: fd)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func acceptClientOffCooperativePool(from descriptor: Int32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            blockingIOQueue.async {
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    continuation.resume(throwing: AcceptFailure(code: errno))
                } else {
                    continuation.resume(returning: client)
                }
            }
        }
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

private struct AcceptFailure: Error, Sendable {
    let code: Int32
}

private actor ClientTaskStartGate {
    private var released = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// Returns true when release() ran (the task may proceed), false when the
    /// waiting task was cancelled before release. A plain continuation has no
    /// cancellation handler, so without this a task cancelled between accept()
    /// and registration would park here forever — its `defer` (close + permit
    /// signal) would never run and the connection-limiter permit would leak.
    func wait() async -> Bool {
        if released { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
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
