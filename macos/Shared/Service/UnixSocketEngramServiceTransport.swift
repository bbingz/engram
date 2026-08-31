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
            try Self.writeFrame(encoded, to: fd, requestTimeout: socketTimeout)
            let responseData = try Self.readFrame(from: fd, requestTimeout: socketTimeout)
            do {
                return try JSONDecoder().decode(EngramServiceResponseEnvelope.self, from: responseData)
            } catch {
                throw EngramServiceError.invalidRequest(message: "Malformed service response: \(error.localizedDescription)")
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                fdBox.shutdownIfOpen()
                task.cancel()
            }
            try Task.checkCancellation()
            return response
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
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
                        // a degraded event and keep polling so this poll stream
                        // self-heals. NOTE: the app no longer consumes events() —
                        // status/badge freshness now rides solely on the launcher's
                        // health monitor (startHealthMonitor). This 5s poll stream
                        // is retained only for tests and any non-app consumer.
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

    func close() {}

    /// Transient errors the status stream should ride out (yield degraded +
    /// retry) rather than terminate on — the socket briefly disappears during a
    /// service restart and connect can time out under load.
    private static func isTransientStreamError(_ error: Error) -> Bool {
        if case EngramServiceError.serviceUnavailable = error { return true }
        if case EngramServiceError.transportClosed = error { return true }
        return false
    }

    private static func event(from status: EngramServiceStatus) -> EngramServiceEvent {
        switch status {
        case .running(let total, let todayParents, _, _):
            return EngramServiceEvent(event: "indexed", total: total, todayParents: todayParents)
        case .degraded(let message):
            return EngramServiceEvent(event: "warning", message: message)
        case .error(let message):
            return EngramServiceEvent(event: "error", message: message)
        case .starting:
            return EngramServiceEvent(event: "starting")
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

    static func resolvedSocketPath(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        for key in ["ENGRAM_MCP_SERVICE_SOCKET", "ENGRAM_SERVICE_SOCKET"] {
            guard let rawValue = environment[key] else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let normalized = normalizedAbsolutePath(value, homeDirectory: homeDirectory) else {
                throw EngramServiceError.invalidRequest(message: "\(key) requires a non-empty absolute path")
            }
            return normalized
        }
        return defaultSocketPath(homeDirectory: homeDirectory)
    }

    static func normalizedAbsolutePath(
        _ value: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.utf8.contains(0) else {
            return nil
        }
        let expanded: String
        if value.hasPrefix("~/") {
            expanded = homeDirectory
                .appendingPathComponent(String(value.dropFirst(2)))
                .path
        } else {
            expanded = value
        }
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
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

    @discardableResult
    static func secureRuntimeDirectory(at directory: URL) throws -> URL {
        // Custom socket parents are caller-owned directories. Validate them,
        // but never enumerate, chmod, or unlink their contents as if they were
        // Engram's dedicated ~/.engram/run directory.
        try validateRuntimeDirectory(directory, label: "custom socket parent directory")
        return directory
    }

    private static func ensureSecureRuntimeDirectory(_ directory: URL, label: String) throws {
        // docs/invariants.md #8: socket-adjacent state stays owner-only and
        // rejects unsafe leftovers on every launch, not only after chmod repair.
        let parent = directory.deletingLastPathComponent()
        let name = directory.lastPathComponent
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot open parent of \(label)")
        }
        defer { Darwin.close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == geteuid()
        else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat parent of \(label)")
        }
        let createResult = name.withCString { mkdirat(parentFD, $0, mode_t(0o700)) }
        guard createResult == 0 || errno == EEXIST else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot create \(label)")
        }
        let directoryFD = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot open \(label)")
        }
        defer { Darwin.close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid()
        else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat \(label)")
        }
        guard fchmod(directoryFD, 0o700) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot secure \(label)")
        }
        // docs/invariants.md #8: only the dedicated runtime directory owns
        // socket-adjacent leftovers. Product subdirectories under ~/.engram and
        // caller-owned custom socket parents are not runtime cleanup domains.
        if label == "service runtime directory" {
            try validateRuntimeDirectoryLeftovers(
                directoryFD: directoryFD,
                label: label,
                cleanupKnownRuntimeLeftovers: true
            )
        }
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

    private static let knownRuntimeLeftoverNames: Set<String> = [
        "cmd.token",
        "ai-secrets.json",
        "webui.token",
        "engram-service.lock",
    ]

    private static func isKnownRuntimeLeftoverName(_ name: String) -> Bool {
        knownRuntimeLeftoverNames.contains(name)
            || name.hasSuffix(".cmd.token")
            || name.hasSuffix(".ai-secrets.json")
    }

    private static func validateRuntimeDirectoryLeftovers(
        directoryFD: Int32,
        label: String,
        cleanupKnownRuntimeLeftovers: Bool
    ) throws {
        let scanFD = dup(directoryFD)
        guard scanFD >= 0, let directoryStream = fdopendir(scanFD) else {
            if scanFD >= 0 { Darwin.close(scanFD) }
            throw EngramServiceError.serviceUnavailable(message: "Cannot scan \(label)")
        }
        defer { closedir(directoryStream) }
        while let entry = readdir(directoryStream) {
            let name = directoryEntryName(entry)
            if name == "." || name == ".." { continue }
            var info = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                throw EngramServiceError.serviceUnavailable(
                    message: "\(label.capitalized) contains an unsafe leftover"
                )
            }
            let kind = info.st_mode & S_IFMT
            if cleanupKnownRuntimeLeftovers,
               isKnownRuntimeLeftoverName(name),
               info.st_uid == geteuid(),
               kind == S_IFLNK || kind == S_IFIFO || kind == S_IFREG && info.st_nlink != 1 {
                let unlinkResult = name.withCString { unlinkat(directoryFD, $0, 0) }
                guard unlinkResult == 0 else {
                    throw EngramServiceError.serviceUnavailable(
                        message: "\(label.capitalized) contains an unsafe leftover"
                    )
                }
                continue
            }
            guard kind != S_IFLNK,
                  kind != S_IFIFO,
                  info.st_uid == geteuid() else {
                throw EngramServiceError.serviceUnavailable(
                    message: "\(label.capitalized) contains an unsafe leftover"
                )
            }
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    static func frameDeadline(requestTimeout: TimeInterval?, now: Date = Date()) -> Date {
        let requested = requestTimeout ?? maximumFrameDurationSeconds
        return now.addingTimeInterval(max(maximumFrameDurationSeconds, requested))
    }

    static func writeFrame(_ data: Data, to fd: Int32, requestTimeout: TimeInterval? = nil) throws {
        // Symmetric guard with readFrame: reject oversized payloads before the
        // UInt32 length cast so a too-large frame is a clean error rather than
        // a silently truncated / overflowed length prefix.
        guard data.count > 0, data.count <= maximumFrameLength else {
            throw EngramServiceError.invalidRequest(
                message: "Service frame length \(data.count) exceeds maximum \(maximumFrameLength)"
            )
        }
        let deadline = frameDeadline(requestTimeout: requestTimeout)
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: fd, deadline: deadline) }
        try data.withUnsafeBytes { try writeAll($0, to: fd, deadline: deadline) }
    }

    static func readFrame(from fd: Int32, requestTimeout: TimeInterval? = nil) throws -> Data {
        // One deadline for the entire frame (length prefix + body), so a peer
        // that trickles bytes can't keep the per-syscall timeout perpetually
        // satisfied while stalling the whole frame. Long-running request/response
        // pairs opt into a longer wall-clock frame budget through requestTimeout.
        let deadline = frameDeadline(requestTimeout: requestTimeout)
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
        var socketInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == geteuid(),
              (socketInfo.st_mode & 0o077) == 0 else {
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
            var peerEuid: uid_t = 0
            var peerEgid: gid_t = 0
            guard getpeereid(fd, &peerEuid, &peerEgid) == 0,
                  peerEuid == geteuid() else {
                throw EngramServiceError.serviceUnavailable(message: "EngramService peer identity mismatch")
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
