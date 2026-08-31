import Darwin
import Foundation

/// Ensures product data subdirectories under `~/.engram` are mode 0700.
/// SEC-L3: live installs had `cache`/`exports`/`probes` at 0755, allowing
/// other local users to traverse and list filenames.
public enum EngramUserDataDirectory {
    /// Product subdirs that should never be group/other traversable.
    public static let protectedSubdirectoryNames: [String] = [
        "cache",
        "exports",
        "probes",
        "backups",
        "run",
        "archive-v2",
        "bin",
    ]

    /// Resolve the process home without allowing XCTest to fall through to the
    /// login user's production `~/.engram` tree (docs/invariants.md #6).
    public static func resolvedHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let isTestProcess = environment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestConfigurationFilePath"] != nil
        guard isTestProcess else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        for candidateEnvironment in [environment, processEnvironment] {
            for key in ["CFFIXED_USER_HOME", "HOME"] {
                if let path = candidateEnvironment[key], !path.isEmpty {
                    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                }
            }
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-tests-\(getpid())", isDirectory: true)
    }

    /// Create (if needed) and force `~/.engram/<name>` to mode 0700.
    @discardableResult
    public static func ensureSecureSubdirectory(
        _ name: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        _ = fileManager
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let homeFD = try openOwnedDirectory(atPath: homeDirectory.path)
        defer { close(homeFD) }
        let rootFD = try openOrCreateOwnedDirectory(named: ".engram", relativeTo: homeFD)
        defer { close(rootFD) }
        let directoryFD = try openOrCreateOwnedDirectory(named: name, relativeTo: rootFD)
        close(directoryFD)
        return directory
    }

    /// Repair modes on existing product subdirectories (no create for missing).
    public static func secureExistingProductSubdirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        _ = fileManager
        guard let homeFD = try? openOwnedDirectory(atPath: homeDirectory.path) else { return }
        defer { close(homeFD) }
        let rootFD = ".engram".withCString {
            openat(homeFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootFD >= 0 else { return }
        defer { close(rootFD) }
        guard isOwnedDirectory(rootFD) else { return }
        _ = fchmod(rootFD, 0o700)
        for name in protectedSubdirectoryNames {
            let directoryFD = name.withCString {
                openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard directoryFD >= 0 else { continue }
            if isOwnedDirectory(directoryFD) {
                _ = fchmod(directoryFD, 0o700)
            }
            close(directoryFD)
        }
    }

    private static func openOwnedDirectory(atPath path: String) throws -> Int32 {
        let fd = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw posixError() }
        guard isOwnedDirectory(fd) else {
            close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        return fd
    }

    private static func openOrCreateOwnedDirectory(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let result = name.withCString { mkdirat(parentFD, $0, mode_t(0o700)) }
        guard result == 0 || errno == EEXIST else { throw posixError() }
        let fd = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw posixError() }
        guard isOwnedDirectory(fd), fchmod(fd, 0o700) == 0 else {
            close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        return fd
    }

    private static func isOwnedDirectory(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
