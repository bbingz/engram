import Darwin
import Foundation

final class UnixSocketEngramServiceTransport: EngramServiceTransport, @unchecked Sendable {
    private let socketPath: String
    private let connectTimeout: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(socketPath: String = UnixSocketEngramServiceTransport.defaultSocketPath(), connectTimeout: TimeInterval = 2) {
        self.socketPath = socketPath
        self.connectTimeout = connectTimeout
    }

    func send(
        _ request: EngramServiceRequestEnvelope,
        timeout: TimeInterval?
    ) async throws -> EngramServiceResponseEnvelope {
        let socketTimeout = timeout ?? connectTimeout
        return try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path: self.socketPath)
            defer { Darwin.close(fd) }
            try Self.setSocketTimeout(fd, seconds: socketTimeout)

            let encoded = try self.encoder.encode(request)
            try Self.writeFrame(encoded, to: fd)
            let responseData = try Self.readFrame(from: fd)
            do {
                return try self.decoder.decode(EngramServiceResponseEnvelope.self, from: responseData)
            } catch {
                throw EngramServiceError.invalidRequest(message: "Malformed service response: \(error.localizedDescription)")
            }
        }.value
    }

    func events() -> AsyncThrowingStream<EngramServiceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func close() async {}

    static func defaultSocketPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("engram-service.sock")
            .path
    }

    @discardableResult
    static func secureRuntimeDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let runDirectory = homeDirectory
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: runDirectory.path) {
            try fileManager.createDirectory(
                at: runDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var info = stat()
        guard lstat(runDirectory.path, &info) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot stat service runtime directory")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime path is not a directory")
        }
        guard (info.st_mode & S_IFLNK) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime directory must not be a symlink")
        }
        guard info.st_uid == geteuid() else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime directory is owned by another user")
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Service runtime directory must be mode 0700")
        }
        return runDirectory
    }

    static func writeFrame(_ data: Data, to fd: Int32) throws {
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: fd) }
        try data.withUnsafeBytes { try writeAll($0, to: fd) }
    }

    static func readFrame(from fd: Int32) throws -> Data {
        let lengthData = try readExact(count: 4, from: fd)
        let length = lengthData.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length > 0, length <= 32 * 1024 * 1024 else {
            throw EngramServiceError.invalidRequest(message: "Invalid service frame length \(length)")
        }
        return try readExact(count: Int(length), from: fd)
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EngramServiceError.serviceUnavailable(message: "Cannot create service socket")
        }
        do {
            try? FileManager.default.removeItem(atPath: path)
            try withSockAddr(path: path) { pointer, length in
                guard Darwin.bind(fd, pointer, length) == 0 else {
                    throw EngramServiceError.serviceUnavailable(message: "Cannot bind EngramService socket")
                }
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

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written < 0, isTimeoutErrno(errno) {
                throw EngramServiceError.serviceUnavailable(message: "Service socket write timed out")
            }
            guard written > 0 else {
                throw EngramServiceError.transportClosed(message: "Service socket write failed")
            }
            offset += written
        }
    }

    private static func readExact(count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
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
