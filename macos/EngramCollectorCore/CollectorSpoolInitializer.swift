import Darwin
import Foundation
import GRDB

/// Explicit installation step. Only a new, private spool is created; existing
/// stores are never repaired, migrated, copied or replaced. On failure, retain
/// the partial directory for inspection and require a new destination.
enum CollectorSpoolInitializer {
    static func create(root: URL, identityCatalog: URL, beforeDatabaseOpen: ((URL) throws -> Void)? = nil) throws {
        let components = try CollectorPOSIXDirectoryAccess.components(root.path)
        let identityComponents = try CollectorPOSIXDirectoryAccess.components(identityCatalog.path)
        let identityParent = Array(identityComponents.dropLast())
        guard !components.starts(with: identityParent), !identityParent.starts(with: components),
              let name = components.last else { throw CollectorRuntimeError.invalidConfiguration }
        let parent = try CollectorPOSIXDirectoryAccess.openAbsolute(components: Array(components.dropLast()))
        defer { CollectorPOSIXDirectoryAccess.close(parent.descriptor) }
        guard parent.info.st_uid == geteuid(), parent.info.st_mode & 0o022 == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        // Borrowed identity is read before any filesystem mutation. This never
        // allocates a different machine identity for an already archived host.
        let machineID = try CollectorMachineIdentityReader.read(from: identityCatalog)
        guard mkdirat(parent.descriptor, name, 0o700) == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
        let descriptor = try CollectorPOSIXDirectoryAccess.openComponent(name, parent: parent.descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(descriptor) }
        let identity = try CollectorPOSIXDirectoryAccess.identity(CollectorPOSIXDirectoryAccess.directoryStat(descriptor))
        func fence() throws {
            let route = try CollectorPOSIXDirectoryAccess.openAbsolute(components: components)
            defer { CollectorPOSIXDirectoryAccess.close(route.descriptor) }
            guard route.info.st_uid == geteuid(), route.info.st_mode & 0o077 == 0,
                  try CollectorPOSIXDirectoryAccess.identity(route.info) == identity else {
                throw CollectorRuntimeError.invalidConfiguration
            }
        }
        try fence()
        try createDatabase(at: root.appendingPathComponent("archive.sqlite"), parent: descriptor, beforeOpen: beforeDatabaseOpen) { db in
            try db.execute(sql: "CREATE TABLE archive_metadata(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID")
            try db.execute(sql: "INSERT INTO archive_metadata VALUES ('machine_id', ?)", arguments: [machineID])
        }
        try fence()
        guard mkdirat(descriptor, "capture", 0o700) == 0 else { throw CollectorRuntimeError.invalidConfiguration }
        let capture = try CollectorPOSIXDirectoryAccess.openComponent("capture", parent: descriptor)
        defer { CollectorPOSIXDirectoryAccess.close(capture) }
        let captureRoot = root.appendingPathComponent("capture")
        try createDatabase(at: captureRoot.appendingPathComponent("archive.sqlite"), parent: capture, beforeOpen: beforeDatabaseOpen) { db in
            try ArchiveCatalogMigrations.migrate(db, machineID: machineID)
        }
        // A fresh rollback-journal catalog is valid input to the existing
        // runtime. Its owned ArchiveCatalog enables WAL after strict preflight.
        // No transferred SQLite seed or metadata restoration is involved.
        for directory in ["objects", "manifests", "tmp"] {
            guard mkdirat(capture, directory, 0o700) == 0 else { throw CollectorRuntimeError.invalidConfiguration }
            if directory != "tmp" {
                let child = try CollectorPOSIXDirectoryAccess.openComponent(directory, parent: capture)
                defer { CollectorPOSIXDirectoryAccess.close(child) }
                guard mkdirat(child, "sha256", 0o700) == 0, fsync(child) == 0 else {
                    throw CollectorRuntimeError.invalidConfiguration
                }
            }
        }
        try fence()
        guard try CollectorMachineIdentityReader.read(from: identityCatalog, expectedMachineID: machineID) == machineID,
              fsync(capture) == 0, fsync(descriptor) == 0, fsync(parent.descriptor) == 0 else {
            throw CollectorRuntimeError.invalidConfiguration
        }
    }

    private static func createDatabase(at url: URL, parent: Int32, beforeOpen: ((URL) throws -> Void)?, migrate: (Database) throws -> Void) throws {
        let descriptor = openat(parent, "archive.sqlite", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CollectorRuntimeError.invalidConfiguration }
        defer { _ = Darwin.close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw CollectorRuntimeError.invalidConfiguration }
        try beforeOpen?(url)
        let expected = original
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        configuration.busyMode = .timeout(0.5)
        configuration.prepareDatabase { db in
            // Check the opened SQLite connection before executing schema SQL.
            // A later directory fence alone cannot undo a wrong-file write.
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
        // O_EXCL above is the only main-file creator. SQLite may not create a
        // different file if the configured path was replaced in the meantime.
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
