import Darwin
import Foundation
import GRDB

/// First-host identity catalog only. Creates a previously absent parent
/// directory and `archive.sqlite`. Never repairs, replaces, or allocates a
/// second identity for an existing catalog.
public enum CollectorIdentityInitializer {
    public static func create(at catalogURL: URL) throws -> String {
        guard catalogURL.isFileURL,
              catalogURL.lastPathComponent == "archive.sqlite",
              ArchiveSourceDescriptor.normalizedAbsolutePath(catalogURL.path) == catalogURL.path,
              catalogURL.resolvingSymlinksInPath().standardizedFileURL.path == catalogURL.path else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let components = try CollectorPOSIXDirectoryAccess.components(catalogURL.path)
        guard components.last == "archive.sqlite",
              "/" + components.joined(separator: "/") == catalogURL.path else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let parentComponents = Array(components.dropLast())
        guard let parentName = parentComponents.last else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let ancestorComponents = Array(parentComponents.dropLast())
        let ancestor = try CollectorPOSIXDirectoryAccess.openAbsolute(components: ancestorComponents)
        defer { CollectorPOSIXDirectoryAccess.close(ancestor.descriptor) }
        guard ancestor.info.st_uid == geteuid(), ancestor.info.st_mode & 0o022 == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        try requireCanonicalDirectory(path: "/" + ancestorComponents.joined(separator: "/"), info: ancestor.info)

        var existing = stat()
        let existed = parentName.withCString {
            fstatat(ancestor.descriptor, $0, &existing, AT_SYMLINK_NOFOLLOW)
        }
        guard existed != 0, errno == ENOENT else {
            throw CollectorRuntimeError.invalidConfiguration
        }

        guard parentName.withCString({ mkdirat(ancestor.descriptor, $0, 0o700) }) == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let parent = try CollectorPOSIXDirectoryAccess.openComponent(parentName, parent: ancestor.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(parent) }
        let parentIdentity = try CollectorPOSIXDirectoryAccess.identity(
            CollectorPOSIXDirectoryAccess.directoryStat(parent)
        )
        func fence() throws {
            let route = try CollectorPOSIXDirectoryAccess.openAbsolute(components: parentComponents)
            defer { CollectorPOSIXDirectoryAccess.close(route.descriptor) }
            guard route.info.st_uid == geteuid(), route.info.st_mode & 0o077 == 0,
                  try CollectorPOSIXDirectoryAccess.identity(route.info) == parentIdentity else {
                throw CollectorRuntimeError.invalidConfiguration
            }
            var named = stat()
            guard parentName.withCString({
                fstatat(ancestor.descriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  named.st_dev == route.info.st_dev, named.st_ino == route.info.st_ino else {
                throw CollectorRuntimeError.invalidConfiguration
            }
        }
        try fence()
        let machineID = UUID().uuidString
        guard UUID(uuidString: machineID)?.uuidString == machineID else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        try createDatabase(at: catalogURL, parent: parent) { db in
            try db.execute(sql: """
                CREATE TABLE archive_metadata(
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID
                """)
            try db.execute(
                sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)",
                arguments: [machineID]
            )
        }
        try fence()
        guard fsync(parent) == 0, fsync(ancestor.descriptor) == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        guard let resolved = Darwin.realpath(catalogURL.path, nil) else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let canonical = String(cString: resolved)
        Darwin.free(resolved)
        guard canonical == catalogURL.path,
              try CollectorMachineIdentityReader.read(from: catalogURL, expectedMachineID: machineID) == machineID else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        return machineID
    }

    private static func requireCanonicalDirectory(path: String, info: stat) throws {
        guard path.hasPrefix("/"),
              ArchiveSourceDescriptor.normalizedAbsolutePath(path) == path,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == path,
              let resolved = Darwin.realpath(path, nil) else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let canonical = String(cString: resolved)
        Darwin.free(resolved)
        var named = stat()
        guard canonical == path, lstat(path, &named) == 0,
              named.st_dev == info.st_dev, named.st_ino == info.st_ino,
              named.st_mode & S_IFMT == S_IFDIR else {
            throw CollectorRuntimeError.invalidConfiguration
        }
    }

    private static func createDatabase(at url: URL, parent: Int32, migrate: (Database) throws -> Void) throws {
        let descriptor = openat(parent, "archive.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CollectorRuntimeError.invalidConfiguration }
        defer { _ = Darwin.close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw CollectorRuntimeError.invalidConfiguration }
        let expected = original
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(0.5)
        configuration.prepareDatabase { db in
            var routed = stat()
            var heldName = stat()
            var moved: Int32 = 0
            guard lstat(url.path, &routed) == 0,
                  fstatat(parent, "archive.sqlite", &heldName, AT_SYMLINK_NOFOLLOW) == 0,
                  routed.st_dev == expected.st_dev, routed.st_ino == expected.st_ino,
                  heldName.st_dev == expected.st_dev, heldName.st_ino == expected.st_ino,
                  routed.st_mode & S_IFMT == S_IFREG, routed.st_uid == geteuid(),
                  routed.st_nlink == 1, routed.st_mode & 0o077 == 0,
                  sqlite3_db_readonly(db.sqliteConnection, "main") == 0,
                  sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
                  moved == 0 else { throw CollectorRuntimeError.invalidConfiguration }
        }
        var uri = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        uri.queryItems = [URLQueryItem(name: "mode", value: "rw")]
        let database = try DatabaseQueue(path: uri.url!.absoluteString, configuration: configuration)
        do {
            try database.write(migrate)
            try database.close()
        } catch {
            try? database.close()
            throw error
        }
        var current = stat()
        guard fstatat(parent, "archive.sqlite", &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              current.st_mode & S_IFMT == S_IFREG, current.st_uid == geteuid(),
              current.st_nlink == 1, current.st_mode & 0o077 == 0, fsync(descriptor) == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
    }
}
