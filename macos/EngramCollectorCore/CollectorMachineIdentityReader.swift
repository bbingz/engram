import Darwin
import Foundation
import GRDB

public enum CollectorMachineIdentityError: Error, Equatable, Sendable {
    case unavailable
    case unsafePath
    case invalidMachineID
    case identityMismatch(expected: String, actual: String)
    case walSidecarsUnavailable
    case writableSharedMemory
}

public enum CollectorMachineIdentityReader {
    /// Reads an already provisioned catalog. It never creates a catalog, runs a
    /// migration, allocates an identity, or repairs filesystem permissions.
    public static func read(from catalogURL: URL, expectedMachineID: String? = nil) throws -> String {
        if let expectedMachineID, UUID(uuidString: expectedMachineID) == nil {
            throw CollectorMachineIdentityError.invalidMachineID
        }
        let value: String
        do {
            value = try withReadOnlyDatabase(from: catalogURL) { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT CASE WHEN typeof(value) = 'text' AND length(CAST(value AS BLOB)) = 36
                                THEN value ELSE NULL END AS machine_id
                    FROM archive_metadata WHERE key = 'machine_id' LIMIT 2
                    """)
                guard rows.count == 1, let value: String = rows[0]["machine_id"], UUID(uuidString: value) != nil else {
                    throw CollectorMachineIdentityError.invalidMachineID
                }
                return value
            }
        } catch let error as CollectorMachineIdentityError { throw error }
        catch { throw CollectorMachineIdentityError.unavailable }
        if let expectedMachineID, expectedMachineID != value {
            throw CollectorMachineIdentityError.identityMismatch(expected: expectedMachineID, actual: value)
        }
        return value
    }

    /// Shared strict opener for existing collector databases. No migration,
    /// owner lock, writable mapping, sidecar repair, or immutable live-WAL view.
    static func withReadOnlyDatabase<T>(from catalogURL: URL, _ body: (Database) throws -> T) throws -> T {
        guard catalogURL.isFileURL,
              isAbsoluteLexicalPath(catalogURL.path) else {
            throw CollectorMachineIdentityError.unsafePath
        }
        try validateDirectory(catalogURL.deletingLastPathComponent())
        let expected = try fileIdentity(catalogURL)
        let canonicalPath = try canonicalExistingPath(catalogURL)
        let descriptor = Darwin.open(catalogURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CollectorMachineIdentityError.unavailable }
        defer { _ = Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, expected.matches(opened) else {
            throw CollectorMachineIdentityError.unsafePath
        }

        // SQLite may initialize missing WAL/SHM files even for a READONLY main
        // connection. Refuse that repair path instead of using immutable=1,
        // which is not a safe view of a concurrently maintained WAL database.
        var header = [UInt8](repeating: 0, count: 20)
        let count = header.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        let usesWAL = count == header.count && (header[18] == 2 || header[19] == 2)
        if usesWAL {
            for suffix in ["-wal", "-shm"] {
                do { _ = try fileIdentity(URL(fileURLWithPath: catalogURL.path + suffix)) }
                catch { throw CollectorMachineIdentityError.walSidecarsUnavailable }
            }
        }

        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(0.5)
        // GRDB applies this pragma before prepareDatabase. This metadata-only
        // reader needs no foreign keys and must probe SHM before any SQL.
        configuration.foreignKeysEnabled = false
        guard var components = URLComponents(url: catalogURL, resolvingAgainstBaseURL: false) else {
            throw CollectorMachineIdentityError.unsafePath
        }
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "readonly_shm", value: "1")]
        guard let readOnlyURI = components.url?.absoluteString else {
            throw CollectorMachineIdentityError.unsafePath
        }
        configuration.prepareDatabase { db in
            guard sqlite3_db_readonly(db.sqliteConnection, "main") == 1,
                  let filename = sqlite3_db_filename(db.sqliteConnection, "main"),
                  String(cString: filename) == canonicalPath,
                  sqlite3_uri_boolean(filename, "readonly_shm", 0) == 1 else {
                throw CollectorMachineIdentityError.unsafePath
            }
            try validateOpenedDatabase(db, url: catalogURL, expected: expected)
            if usesWAL { try validateReadOnlySharedMemory(db) }
        }
        let database: DatabaseQueue
        do { database = try DatabaseQueue(path: readOnlyURI, configuration: configuration) }
        catch let error as CollectorMachineIdentityError { throw error }
        catch { throw CollectorMachineIdentityError.unavailable }

        defer { try? database.close() }
        return try database.read { db in
            try validateOpenedDatabase(db, url: catalogURL, expected: expected)
            let result = try body(db)
            try validateOpenedDatabase(db, url: catalogURL, expected: expected)
            return result
        }
    }

    /// Foundation can shorten real /private paths to their standard macOS
    /// aliases. Compare against realpath first; accept its Foundation spelling
    /// too, but never an arbitrary symlink spelling supplied by the caller.
    static func canonicalExistingPath(_ url: URL) throws -> String {
        guard url.isFileURL, isAbsoluteLexicalPath(url.path),
              let pointer = Darwin.realpath(url.path, nil) else { throw CollectorMachineIdentityError.unsafePath }
        defer { Darwin.free(pointer) }
        let path = String(cString: pointer)
        guard url.path == path || url.path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
            throw CollectorMachineIdentityError.unsafePath
        }
        return path
    }

    static func isAbsoluteLexicalPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func verifyShadowIfPresent(at shadowRoot: URL, machineID: String) throws {
        guard UUID(uuidString: machineID) != nil else { throw CollectorMachineIdentityError.invalidMachineID }
        guard shadowRoot.isFileURL,
              isAbsoluteLexicalPath(shadowRoot.path) else {
            throw CollectorMachineIdentityError.unsafePath
        }
        var info = stat()
        if lstat(shadowRoot.path, &info) != 0 {
            guard errno == ENOENT else { throw CollectorMachineIdentityError.unavailable }
            return
        }
        try validateDirectory(shadowRoot)
        _ = try read(from: shadowRoot.appendingPathComponent("archive.sqlite"), expectedMachineID: machineID)
    }

    private struct FileIdentity: Sendable {
        let device: dev_t
        let inode: ino_t

        func matches(_ info: stat) -> Bool {
            info.st_dev == device && info.st_ino == inode && CollectorMachineIdentityReader.isSafeFile(info)
        }
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CollectorMachineIdentityError.unavailable }
        guard isSafeFile(info) else { throw CollectorMachineIdentityError.unsafePath }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func isSafeFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0 && (info.st_mode & 0o400) != 0
    }

    private static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & 0o077) == 0, (info.st_mode & 0o500) == 0o500 else {
            throw CollectorMachineIdentityError.unsafePath
        }
    }

    private static func validateOpenedDatabase(_ db: Database, url: URL, expected: FileIdentity) throws {
        var moved: CInt = 0
        let result = sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
        var info = stat()
        guard result == SQLITE_OK, moved == 0, lstat(url.path, &info) == 0, expected.matches(info) else {
            throw CollectorMachineIdentityError.unsafePath
        }
    }

    private static func validateReadOnlySharedMemory(_ db: Database) throws {
        var file: UnsafeMutablePointer<sqlite3_file>?
        guard sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK,
              let file, let methods = file.pointee.pMethods,
              methods.pointee.iVersion >= 2, let map = methods.pointee.xShmMap,
              let unmap = methods.pointee.xShmUnmap else {
            throw CollectorMachineIdentityError.unavailable
        }
        // SQLite's WAL-index regions are 32 KiB. Extend=0 cannot grow an
        // existing region. A READONLY main connection may still reuse this
        // process's pre-existing writable SHM node, despite readonly_shm=1.
        // Reject that topology before GRDB's format/schema validation runs.
        var region: UnsafeMutableRawPointer?
        // The probe owns this temporary mapping, including on rejection.
        // SQLite remaps it when the subsequent query owns the WAL connection.
        defer { _ = unmap(file, 0) }
        let result = map(file, 0, 32 * 1024, 0, &region)
        if result == SQLITE_OK { throw CollectorMachineIdentityError.writableSharedMemory }
        guard result == SQLITE_READONLY, region != nil else {
            throw CollectorMachineIdentityError.unavailable
        }
    }
}
