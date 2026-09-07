import Darwin
import Foundation

private enum ExplicitCredentialFileError: Error { case invalid }

/// Explicit file-only credentials. OFF never calls token, and a single pinned
/// snapshot supplies both references. No default-home or Keychain fallback.
public final class ExplicitCredentialFile: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var values: [String: String]?

    public init(url: URL?) { self.url = url }

    public func token(for reference: String) throws -> String {
        try lock.withLock {
            if values == nil {
                guard let url, let map = try JSONSerialization.jsonObject(with: Self.read(url.path)) as? [String: String] else {
                    throw ExplicitCredentialFileError.invalid
                }
                values = map
            }
            guard let value = values?[reference] else { throw ExplicitCredentialFileError.invalid }
            return value
        }
    }

    private static func read(_ path: String) throws -> Data {
        // Each ancestor is opened relative to the preceding pinned descriptor;
        // O_NOFOLLOW on just the leaf/direct parent would still allow aliases.
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), let name = components.last else { throw ExplicitCredentialFileError.invalid }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ExplicitCredentialFileError.invalid }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ExplicitCredentialFileError.invalid }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExplicitCredentialFileError.invalid }
        defer { close(descriptor) }
        var before = stat()
        let limit = 64 * 1024
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1, before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0, before.st_size <= limit else { throw ExplicitCredentialFileError.invalid }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, limit + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ExplicitCredentialFileError.invalid
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count <= limit, data.count == before.st_size, fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mode == after.st_mode, before.st_uid == after.st_uid,
              before.st_nlink == after.st_nlink, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ExplicitCredentialFileError.invalid
        }
        return data
    }
}
