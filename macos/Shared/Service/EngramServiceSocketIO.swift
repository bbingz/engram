import Darwin
import Foundation

enum EngramServiceSocketIO {
    static let maximumFrameLength = 256 * 1024
    static let maximumExchangeTimeoutSeconds: TimeInterval = 24 * 60 * 60
    static let maximumFrameDurationSeconds: TimeInterval = 30

    struct ExchangeTestHooks: Sendable {
        let beforeDescriptorPublication: (@Sendable (Int32) async -> Void)?

        init(beforeDescriptorPublication: (@Sendable (Int32) async -> Void)? = nil) {
            self.beforeDescriptorPublication = beforeDescriptorPublication
        }
    }

    static func exchange(
        _ request: Data,
        socketPath: String,
        totalTimeout: TimeInterval,
        testHooks: ExchangeTestHooks = .init()
    ) async throws -> Data {
        let started = ContinuousClock.now
        guard totalTimeout.isFinite, totalTimeout > 0,
              totalTimeout <= maximumExchangeTimeoutSeconds else {
            throw EngramServiceError.invalidRequest(message: "Invalid service exchange timeout")
        }
        return try await exchange(
            request, socketPath: socketPath,
            policy: .total(started.advanced(by: .seconds(totalTimeout))), testHooks: testHooks
        )
    }

    /// Existing clients retain a fresh whole-frame budget for each direction,
    /// plus their configured inactivity timeout. Only the raw API is total-time bounded.
    static func exchangeLegacy(_ request: Data, socketPath: String, timeout: TimeInterval) async throws -> Data {
        try await exchange(request, socketPath: socketPath, policy: .legacy(timeout), testHooks: .init())
    }

    private enum ExchangePolicy: Sendable {
        case total(ContinuousClock.Instant)
        case legacy(TimeInterval)
    }

    private static func exchange(
        _ request: Data,
        socketPath: String,
        policy: ExchangePolicy,
        testHooks: ExchangeTestHooks
    ) async throws -> Data {
        let owner = SocketDescriptorOwner()
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try validateFrameLength(request.count)
                try validateSocketPath(socketPath)
                try validateSocketInode(socketPath)
                let fd = try makeSocket()
                // Close is owned by this operation, including cancellation before publication.
                defer { owner.closeOwned(fd) }
                await testHooks.beforeDescriptorPublication?(fd)
                try owner.publish(fd)
                return try await withCheckedThrowingContinuation { continuation in
                    // Blocking poll is kept off the cooperative executor. Cancellation
                    // is checked through the owner because this worker is not a Swift task.
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let cancelled: @Sendable () -> Bool = { owner.isCancelled }
                            var connectBudget = IOBudget(
                                deadline: { if case .total(let deadline) = policy { return deadline }; return nil }(),
                                cancelled: cancelled
                            )
                            // This exchange owns the fd until close. Darwin AF_UNIX
                            // sends can block despite MSG_DONTWAIT without O_NONBLOCK.
                            try connect(fd, path: socketPath, budget: &connectBudget, restoreOriginalFlags: false)
                            let result: Data
                            switch policy {
                            case .total(let deadline):
                                var budget = IOBudget(deadline: deadline, cancelled: cancelled)
                                try writeFrame(request, to: fd, budget: &budget)
                                result = try readFrame(from: fd, budget: &budget)
                            case .legacy(let timeout):
                                try setSocketTimeout(fd, seconds: timeout)
                                var writeBudget = try legacyBudget(fd, timeout: timeout, operation: SO_SNDTIMEO, cancelled: cancelled)
                                try writeFrame(request, to: fd, budget: &writeBudget)
                                var readBudget = try legacyBudget(fd, timeout: timeout, operation: SO_RCVTIMEO, cancelled: cancelled)
                                result = try readFrame(from: fd, budget: &readBudget)
                            }
                            try connectBudget.check()
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                owner.cancel()
            }
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func frameDeadline(requestTimeout: TimeInterval?, now: Date = Date()) -> Date {
        now.addingTimeInterval(max(maximumFrameDurationSeconds, requestTimeout ?? maximumFrameDurationSeconds))
    }

    static func writeFrame(_ data: Data, to fd: Int32, requestTimeout: TimeInterval? = nil) throws {
        // Keep this ahead of socket inspection: invalid lengths never reach I/O.
        try validateFrameLength(data.count)
        var budget = try legacyBudget(fd, timeout: requestTimeout, operation: SO_SNDTIMEO)
        try writeFrame(data, to: fd, budget: &budget)
    }

    static func readFrame(from fd: Int32, requestTimeout: TimeInterval? = nil) throws -> Data {
        var budget = try legacyBudget(fd, timeout: requestTimeout, operation: SO_RCVTIMEO)
        return try readFrame(from: fd, budget: &budget)
    }

    private static func writeFrame(_ data: Data, to fd: Int32, budget: inout IOBudget) throws {
        try validateFrameLength(data.count)
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: fd, budget: &budget) }
        try data.withUnsafeBytes { try writeAll($0, to: fd, budget: &budget) }
    }

    private static func readFrame(from fd: Int32, budget: inout IOBudget) throws -> Data {
        let lengthData = try readExact(count: 4, from: fd, budget: &budget)
        let length = lengthData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // Validate the untrusted prefix before allocating its body.
        try validateFrameLength(Int(length))
        return try readExact(count: Int(length), from: fd, budget: &budget)
    }

    private static func validateFrameLength(_ length: Int) throws {
        guard length > 0, length <= maximumFrameLength else {
            throw EngramServiceError.invalidRequest(message: "Invalid service frame length")
        }
    }

    private struct IOBudget {
        let deadline: ContinuousClock.Instant?
        var idleDeadline: ContinuousClock.Instant?
        let inactivity: TimeInterval?
        let cancelled: @Sendable () -> Bool

        init(
            deadline: ContinuousClock.Instant?,
            inactivity: TimeInterval? = nil,
            cancelled: @escaping @Sendable () -> Bool = { false }
        ) {
            self.deadline = deadline
            self.inactivity = inactivity
            self.idleDeadline = inactivity.map { ContinuousClock.now.advanced(by: .seconds($0)) }
            self.cancelled = cancelled
        }

        func check() throws {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            let now = ContinuousClock.now
            if let deadline, now >= deadline { throw timeoutError() }
            if let idleDeadline, now >= idleDeadline { throw timeoutError() }
        }

        mutating func progressed() {
            if let inactivity { idleDeadline = ContinuousClock.now.advanced(by: .seconds(inactivity)) }
        }

        func pollMilliseconds() throws -> Int32 {
            try check()
            let now = ContinuousClock.now
            // Also observe cancellation when shutdown cannot wake an unconnected fd.
            var seconds = 0.05
            for limit in [deadline, idleDeadline].compactMap({ $0 }) {
                let duration = now.duration(to: limit).components
                seconds = min(seconds, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            }
            return Int32(max(1, ceil(seconds * 1_000)))
        }

        private func timeoutError() -> EngramServiceError {
            .serviceUnavailable(message: "Service socket deadline exceeded")
        }
    }

    private static func legacyBudget(
        _ fd: Int32,
        timeout: TimeInterval?,
        operation: Int32,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> IOBudget {
        let duration = max(maximumFrameDurationSeconds, timeout ?? maximumFrameDurationSeconds)
        guard duration.isFinite, duration < TimeInterval(Int64.max) else {
            throw EngramServiceError.invalidRequest(message: "Invalid service frame timeout")
        }
        var value = timeval()
        var size = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(fd, SOL_SOCKET, operation, &value, &size) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot inspect service socket timeout")
        }
        let inactivity = Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        return IOBudget(
            deadline: ContinuousClock.now.advanced(by: .seconds(duration)),
            inactivity: inactivity > 0 ? inactivity : nil, cancelled: cancelled
        )
    }

    private static func waitForReady(_ fd: Int32, events: Int16, budget: inout IOBudget) throws {
        while true {
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, try budget.pollMilliseconds())
            let pollError = errno
            try budget.check()
            if result < 0, pollError == EINTR { continue }
            guard result >= 0 else {
                throw EngramServiceError.transportClosed(message: "Service socket poll failed")
            }
            if result == 0 { continue }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                throw EngramServiceError.transportClosed(message: "Service socket closed")
            }
            // Let recv/send or SO_ERROR resolve HUP/ERR, including buffered bytes.
            return
        }
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to fd: Int32, budget: inout IOBudget) throws {
        var offset = 0
        while offset < bytes.count {
            try budget.check()
            // Do not toggle caller-owned O_NONBLOCK: the server can concurrently
            // peek this same fd from its disconnect watcher.
            let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == ETIMEDOUT {
                throw EngramServiceError.serviceUnavailable(message: "Service socket deadline exceeded")
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try waitForReady(fd, events: Int16(POLLOUT), budget: &budget)
                continue
            }
            guard count > 0 else {
                throw EngramServiceError.transportClosed(message: "Service socket write failed")
            }
            offset += count
            budget.progressed()
        }
        try budget.check()
    }

    private static func readExact(count: Int, from fd: Int32, budget: inout IOBudget) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try budget.check()
                let received = Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, MSG_DONTWAIT)
                if received < 0, errno == EINTR { continue }
                if received < 0, errno == ETIMEDOUT {
                    throw EngramServiceError.serviceUnavailable(message: "Service socket deadline exceeded")
                }
                if received < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitForReady(fd, events: Int16(POLLIN), budget: &budget)
                    continue
                }
                guard received > 0 else {
                    throw EngramServiceError.transportClosed(message: "Service socket closed")
                }
                offset += received
                budget.progressed()
            }
        }
        try budget.check()
        return data
    }

    static func connectSocket(path: String) throws -> Int32 {
        try validateSocketPath(path)
        try validateSocketInode(path)
        let fd = try makeSocket()
        do {
            var budget = IOBudget(deadline: nil)
            try connect(fd, path: path, budget: &budget)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot create service socket")
        }
        do {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket")
            }
            try disableSigPipe(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func validateSocketPath(_ path: String) throws {
        let address = sockaddr_un()
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw EngramServiceError.invalidRequest(message: "Invalid service socket path")
        }
    }

    private static func validateSocketInode(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "EngramService socket is unavailable")
        }
    }

    private static func connect(
        _ fd: Int32, path: String, budget: inout IOBudget, restoreOriginalFlags: Bool = true
    ) throws {
        try budget.check()
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket")
        }
        try withSockAddr(path: path) { pointer, length in
            let result = Darwin.connect(fd, pointer, length)
            if result != 0 {
                guard errno == EINPROGRESS || errno == EALREADY || errno == EINTR || errno == EAGAIN else {
                    throw EngramServiceError.serviceUnavailable(message: "Cannot connect to EngramService")
                }
                try waitForReady(fd, events: Int16(POLLOUT), budget: &budget)
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                    throw EngramServiceError.serviceUnavailable(message: "Cannot connect to EngramService")
                }
            }
        }
        try budget.check()
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw EngramServiceError.serviceUnavailable(message: "EngramService peer identity mismatch")
        }
        if restoreOriginalFlags, fcntl(fd, F_SETFL, originalFlags) != 0 {
            throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket")
        }
    }

    static func setSocketTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds < TimeInterval(Int.max) else {
            throw EngramServiceError.invalidRequest(message: "Invalid service socket timeout")
        }
        guard seconds > 0 else { return }
        let whole = floor(seconds)
        var timeout = timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket timeout")
        }
    }

    static func disableSigPipe(_ fd: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket")
        }
    }

    static func withSockAddr<T>(
        path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        try validateSocketPath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strncpy(destination, source, capacity - 1)
                }
            }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// Cancellation borrows a descriptor only while holding the same lock as close.
/// Its terminal flag survives cancellation before publication; it never closes
/// a borrowed fd that the OS could already have recycled for another operation.
private final class SocketDescriptorOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var fd: Int32?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func publish(_ descriptor: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        fd = descriptor
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let fd { _ = Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func closeOwned(_ descriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        fd = nil
        Darwin.close(descriptor)
    }
}
