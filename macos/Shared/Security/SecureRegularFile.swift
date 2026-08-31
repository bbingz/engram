import Darwin
import Foundation

public enum SecureRegularFile {
    public static let defaultMaximumBytes = 64 * 1024

    /// Opens an owner-only secret without following links or accepting shared inodes.
    public static func read(
        atPath path: String,
        maximumBytes: Int = defaultMaximumBytes,
        repairPermissions: Bool = false
    ) -> Data? {
        guard maximumBytes >= 0 else { return nil }
        guard let (directoryFD, name) = openPinnedParentDirectory(forPath: path) else {
            return nil
        }
        defer { close(directoryFD) }
        let fd = name.withCString {
            openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes
        else {
            return nil
        }
        if (info.st_mode & 0o777) != 0o600 {
            guard repairPermissions,
                  fchmod(fd, 0o600) == 0,
                  fstat(fd, &info) == 0,
                  (info.st_mode & 0o777) == 0o600
            else {
                return nil
            }
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes + 1))
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, min(bytes.count, maximumBytes + 1 - data.count))
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }

    /// Removes a same-user non-directory entry through a pinned parent fd.
    /// The target is never opened or followed, so symlink and hardlink
    /// leftovers can be scrubbed without touching their referents.
    @discardableResult
    public static func removeOwnerNonDirectory(atPath path: String) -> Bool {
        guard let (directoryFD, name) = openPinnedParentDirectory(forPath: path) else {
            return false
        }
        defer { close(directoryFD) }

        var info = stat()
        let statResult = name.withCString {
            fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if statResult != 0 { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) != S_IFDIR,
              info.st_uid == geteuid()
        else {
            return false
        }
        return name.withCString { unlinkat(directoryFD, $0, 0) } == 0
    }

    /// Atomically replaces an owner-only regular file without following the
    /// destination or its parent directory. The final inode is created 0600;
    /// no path-based chmod occurs after publication.
    public static func writeAtomically(
        _ data: Data,
        toPath path: String,
        maximumExistingBytes: Int = defaultMaximumBytes
    ) throws {
        guard maximumExistingBytes >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        guard let (directoryFD, name) = openPinnedParentDirectory(forPath: path) else {
            throw posixError()
        }
        defer { close(directoryFD) }

        var existingInfo = stat()
        let existingResult = name.withCString {
            fstatat(directoryFD, $0, &existingInfo, AT_SYMLINK_NOFOLLOW)
        }
        if existingResult == 0 {
            guard (existingInfo.st_mode & S_IFMT) == S_IFREG,
                  existingInfo.st_uid == geteuid(),
                  existingInfo.st_nlink == 1,
                  existingInfo.st_size >= 0,
                  existingInfo.st_size <= maximumExistingBytes
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else if errno != ENOENT {
            throw posixError()
        }

        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let temporaryFD = temporaryName.withCString {
            openat(
                directoryFD,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard temporaryFD >= 0 else { throw posixError() }
        var published = false
        defer {
            close(temporaryFD)
            if !published {
                temporaryName.withCString { _ = unlinkat(directoryFD, $0, 0) }
            }
        }

        guard fchmod(temporaryFD, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporaryFD,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(temporaryFD) == 0 else { throw posixError() }
        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                renameat(directoryFD, temporaryPointer, directoryFD, namePointer)
            }
        }
        guard renameResult == 0 else { throw posixError() }
        published = true
        _ = fsync(directoryFD)
    }

    private static func openPinnedParentDirectory(forPath path: String) -> (Int32, String)? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let directory = url.deletingLastPathComponent()
        let directoryFD: Int32
        if directory.lastPathComponent == "run",
           directory.deletingLastPathComponent().lastPathComponent == ".engram" {
            // docs/invariants.md #8: pin home -> .engram -> run one component
            // at a time so swapping the intermediate .engram entry cannot
            // redirect a secret or capability-token leaf operation.
            let home = directory.deletingLastPathComponent().deletingLastPathComponent()
            let homeFD = home.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard homeFD >= 0 else { return nil }
            defer { close(homeFD) }
            let rootFD = ".engram".withCString {
                openat(homeFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard rootFD >= 0 else { return nil }
            defer { close(rootFD) }
            directoryFD = "run".withCString {
                openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        } else {
            directoryFD = directory.path.withCString {
                open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard directoryFD >= 0 else { return nil }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid()
        else {
            close(directoryFD)
            return nil
        }
        return (directoryFD, name)
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
