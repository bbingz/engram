import Darwin
import Foundation

final class UnixSocketEngramServiceTransport: EngramServiceTransport, Sendable {
    static let maximumFrameLength = 256 * 1024

    /// Whole-frame wall-clock budget. The per-syscall SO_RCVTIMEO/SO_SNDTIMEO
    /// only bounds a single read()/write(); a peer that trickles one byte just
    /// before each timeout window keeps every syscall "making progress" and can
    /// stretch a single frame across `maximumFrameLength` iterations. Track a
    /// deadline for the whole frame so a slow-loris peer is cut off regardless
    /// of per-syscall progress.
    static let maximumFrameDurationSeconds: TimeInterval = 30

    private let socketPath: String
    private let connectTimeout: TimeInterval

    init(socketPath: String = UnixSocketEngramServiceTransport.defaultSocketPath(), connectTimeout: TimeInterval = 2) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
    }

    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope {
        let socketTimeout = timeout ?? connectTimeout
        let socketPath = self.socketPath
        // Attach the per-launch capability token for destructive commands so
        // the service can authorize them. Non-destructive commands are left
        // untouched. An already-populated token (e.g. from tests) is preserved.
        let outboundRequest: EngramServiceRequestEnvelope
        if request.capabilityToken == nil,
           ServiceCapabilityToken.requiresToken(request.command),
           let token = ServiceCapabilityToken.load(
               fromPath: ServiceCapabilityToken.path(forSocketPath: socketPath)
           ) {
            outboundRequest = EngramServiceRequestEnvelope(
                requestId: request.requestId,
                kind: request.kind,
                command: request.command,
                payload: request.payload,
                capabilityToken: token
            )
        } else {
            outboundRequest = request
        }
        // Hold the fd in a box so the cancellation handler can shutdown the
        // socket from outside the detached task. shutdown() unblocks any
        // pending read/write, lets `defer { close }` fire promptly, and
        // closes the fd-leak window that opened when the parent Task got
        // cancelled mid-I/O.
        let fdBox = FdBox()
        let task = Task.detached(priority: .userInitiated) {
            () throws -> EngramServiceResponseEnvelope in
            let fd = try Self.connectSocket(path: socketPath)
            fdBox.store(fd)
            defer {
                fdBox.clear()
                Darwin.close(fd)
            }
            try Self.setSocketTimeout(fd, seconds: socketTimeout)

            let encoded = try JSONEncoder().encode(outboundRequest)
            try Self.writeFrame(encoded, to: fd)
            let responseData = try Self.readFrame(from: fd)
            do {
                return try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: responseData)
            } catch {
                throw EngramServiceError.invalidRequest(message: "Malformed service response: \(error.localizedDescription)")
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            fdBox.shutdownIfOpen()
            task.cancel()
        }
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let request = EngramServiceRequestEnvelope(command: "status")
                        let response = try await send(request, timeout: connectTimeout)
                        guard response.requestId == request.requestId else {
                            throw EngramServiceError.invalidRequest(
                                message: "Response request id \(response.requestId) did not match \(request.requestId)"
                            )
                        }
                        switch response {
                        case .success(_, let result, _):
                            let status = try JSONDecoder().decode(EngramServiceStatus.self, from: result)
                            continuation.yield(Self.event(from: status))
                        case .failure(_, let error):
                            throw error.asError()
                        }
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch {
                        // Transient connectivity errors (the socket file is gone
                        // during a service restart, or a connect timeout under
                        // load) must NOT permanently end the status stream. Yield
                        // a degraded event and keep polling so the snappy 5s
                        // status/badge path self-heals instead of relying solely
                        // on the launcher's health monitor.
                        if Self.isTransientStreamError(error) {
                            continuation.yield(EngramServiceEvent(event: "warning", message: "Service unavailable"))
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func close() async {}

    /// Transient errors the status stream should ride out (yield degraded +
    /// retry) rather than terminate on — the socket briefly disappears during a
    /// service restart and connect can time out under load.
    private static func isTransientStreamError(_ error: Error) -> Bool {
        if case EngramServiceError.serviceUnavailable = error { return true }
        return false
    }

    private static func event(from status: EngramServiceStatus) -> EngramServiceEvent {
        switch status {
        case .running(let total, let todayParents):
            return EngramServiceEvent(event: "indexed", total: total, todayParents: todayParents)
        case .degraded(let message):
            return EngramServiceEvent(event: "warning", message: message)
        case .error(let message):
            return EngramServiceEvent(event: "error", message: message)
        case .starting:
            return EngramServiceEvent(event: "warning", message: "Service starting")
        case .stopped:
            return EngramServiceEvent(event: "error", message: "Service stopped")
        }
    }

    static func defaultSocketPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("engram-service.sock")
            .path
    }

    @discardableResult
    static func secureRuntimeDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let rootDirectory = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
        let runDirectory = homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)

        try ensureSecureRuntimeDirectory(rootDirectory, label: "service root directory")
        try ensureSecureRuntimeDirectory(runDirectory, label: "service runtime directory")
        return runDirectory
    }

    private static func ensureSecureRuntimeDirectory(_ directory: URL, label: String) throws {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try validateRuntimeDirectory(directory, label: label)
            return
        }

        try validateRuntimeDirectoryShapeAndOwner(directory, label: label)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat \(label)")
        }
        if (info.st_mode & 0o077) != 0 {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try validateRuntimeDirectory(directory, label: label)
    }

    private static func validateRuntimeDirectory(_ directory: URL, label: String) throws {
        try validateRuntimeDirectoryShapeAndOwner(directory, label: label)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat \(label)")
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) must be mode 0700")
        }
    }

    private static func validateRuntimeDirectoryShapeAndOwner(_ directory: URL, label: String) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat \(label)")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) path is not a directory")
        }
        guard (info.st_mode & S_IFLNK) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) must not be a symlink")
        }
        guard info.st_uid == geteuid() else {
            throw EngramServiceError.serviceUnavailable(message: "\(label.capitalized) is owned by another user")
        }
    }

    static func writeFrame(_ data: Data, to fd: Int32) throws {
        // Symmetric guard with readFrame: reject oversized payloads before the
        // UInt32 length cast so a too-large frame is a clean error rather than
        // a silently truncated / overflowed length prefix.
        guard data.count > 0, data.count <= maximumFrameLength else {
            throw EngramServiceError.invalidRequest(
                message: "Service frame length \(data.count) exceeds maximum \(maximumFrameLength)"
            )
        }
        let deadline = Date().addingTimeInterval(maximumFrameDurationSeconds)
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: fd, deadline: deadline) }
        try data.withUnsafeBytes { try writeAll($0, to: fd, deadline: deadline) }
    }

    static func readFrame(from fd: Int32) throws -> Data {
        // One deadline for the entire frame (length prefix + body), so a peer
        // that trickles bytes can't keep the per-syscall timeout perpetually
        // satisfied while stalling the whole frame.
        let deadline = Date().addingTimeInterval(maximumFrameDurationSeconds)
        let lengthData = try readExact(count: 4, from: fd, deadline: deadline)
        let length = lengthData.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length > 0, length <= maximumFrameLength else {
            throw EngramServiceError.invalidRequest(message: "Invalid service frame length \(length)")
        }
        return try readExact(count: Int(length), from: fd, deadline: deadline)
    }

    static func connectSocket(path: String) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngramServiceError.serviceUnavailable(message: "EngramService socket is unavailable")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot create service socket")
        }
        do {
            try Self.disableSigPipe(fd)
            try withSockAddr(path: path) { pointer, length in
                guard Darwin.connect(fd, pointer, length) == 0 else {
                    throw EngramServiceError.serviceUnavailable(message: "Cannot connect to EngramService")
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func setSocketTimeout(_ fd: Int32, seconds: TimeInterval) throws {
        guard seconds > 0 else { return }
        let wholeSeconds = floor(seconds)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((seconds - wholeSeconds) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        let receiveResult = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, size)
        }
        guard receiveResult == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot set service socket receive timeout")
        }
        let sendResult = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, size)
        }
        guard sendResult == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot set service socket send timeout")
        }
    }

    static func disableSigPipe(_ fd: Int32) throws {
        var enabled: Int32 = 1
        let result = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot configure service socket")
        }
    }

    static func bindSocket(path: String) throws -> Int32 {
        let socketURL = URL(fileURLWithPath: path)
        let parentDirectory = socketURL.deletingLastPathComponent()
        try validateRuntimeDirectory(parentDirectory, label: "service socket directory")
        try removeStaleSocket(at: path)
        try validateRuntimeDirectory(parentDirectory, label: "service socket directory")

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot create service socket")
        }
        do {
            try withSockAddr(path: path) { pointer, length in
                try validateRuntimeDirectory(parentDirectory, label: "service socket directory")
                guard Darwin.bind(fd, pointer, length) == 0 else {
                    throw EngramServiceError.serviceUnavailable(message: "Cannot bind EngramService socket")
                }
            }
            // SEC-M1: restrict the socket inode to the owner (0600). The parent
            // directory is already 0700, but tightening the socket itself stops
            // any other local user from connecting even if the directory mode
            // ever loosened. macOS does not honor fchmod() on an AF_UNIX socket
            // fd, so chmod() the bound path instead.
            guard chmod(path, 0o600) == 0 else {
                throw EngramServiceError.serviceUnavailable(message: "Cannot restrict EngramService socket permissions")
            }
            guard listen(fd, 16) == 0 else {
                throw EngramServiceError.serviceUnavailable(message: "Cannot listen on EngramService socket")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else {
                throw EngramServiceError.serviceUnavailable(message: "Cannot inspect existing service socket")
            }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw EngramServiceError.serviceUnavailable(message: "Refusing to remove non-socket service path")
        }
        try FileManager.default.removeItem(atPath: path)
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32, deadline: Date?) throws {
        var offset = 0
        while offset < buffer.count {
            try checkFrameDeadline(deadline, operation: "write")
            let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written < 0, errno == EINTR {
                continue
            }
            if written < 0, isTimeoutErrno(errno) {
                throw EngramServiceError.serviceUnavailable(message: "Service socket write timed out")
            }
            guard written > 0 else {
                throw EngramServiceError.transportClosed(message: "Service socket write failed")
            }
            offset += written
        }
    }

    private static func readExact(count: Int, from fd: Int32, deadline: Date?) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try checkFrameDeadline(deadline, operation: "read")
                let readCount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if readCount < 0, errno == EINTR {
                    continue
                }
                if readCount < 0, isTimeoutErrno(errno) {
                    throw EngramServiceError.serviceUnavailable(message: "Service socket read timed out")
                }
                guard readCount > 0 else {
                    throw EngramServiceError.transportClosed(message: "Service socket closed")
                }
                offset += readCount
            }
        }
        return data
    }

    /// Throw once the whole-frame wall-clock deadline has passed. Checked before
    /// each blocking syscall so a peer that keeps each individual read()/write()
    /// "progressing" still gets cut off when the frame as a whole stalls.
    private static func checkFrameDeadline(_ deadline: Date?, operation: String) throws {
        guard let deadline, Date() >= deadline else { return }
        throw EngramServiceError.serviceUnavailable(
            message: "Service socket \(operation) exceeded the per-frame deadline"
        )
    }

    private static func isTimeoutErrno(_ value: Int32) -> Bool {
        value == EAGAIN || value == EWOULDBLOCK || value == ETIMEDOUT
    }

    private static func withSockAddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            throw EngramServiceError.invalidRequest(message: "Service socket path is too long")
        }

        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    memset(destination, 0, maxPathLength)
                    strncpy(destination, source, maxPathLength - 1)
                }
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

/// Holds an fd shared between a detached I/O task and an outer cancellation
/// handler. On cancellation we shutdown() the fd from the handler so the
/// detached task's blocking read/write returns immediately and runs its
/// `defer { close(fd) }`, instead of leaking the fd until socket timeout.
private final class FdBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?

    func store(_ value: Int32) {
        lock.lock()
        defer { lock.unlock() }
        fd = value
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        fd = nil
    }

    func shutdownIfOpen() {
        lock.lock()
        defer { lock.unlock() }
        if let value = fd {
            _ = Darwin.shutdown(value, SHUT_RDWR)
        }
    }
}
