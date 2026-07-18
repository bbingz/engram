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

    /// Create (if needed) and force `~/.engram/<name>` to mode 0700.
    @discardableResult
    public static func ensureSecureSubdirectory(
        _ name: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard (info.st_mode & 0o077) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return directory
    }

    /// Repair modes on existing product subdirectories (no create for missing).
    public static func secureExistingProductSubdirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let root = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
        if fileManager.fileExists(atPath: root.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        for name in protectedSubdirectoryNames {
            let path = root.appendingPathComponent(name, isDirectory: true).path
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }
}
