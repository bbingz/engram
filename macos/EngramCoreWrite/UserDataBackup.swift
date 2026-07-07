import Foundation
import GRDB
import os

public enum UserDataBackupRunStatus: Sendable, Equatable {
    case created
    case skippedFreshBackup
    case failedValidation
}

public struct UserDataBackupRunResult: Sendable, Equatable {
    public let status: UserDataBackupRunStatus
    public let backupURL: URL?
    public let deletedOldBackups: Int

    public init(status: UserDataBackupRunStatus, backupURL: URL?, deletedOldBackups: Int = 0) {
        self.status = status
        self.backupURL = backupURL
        self.deletedOldBackups = deletedOldBackups
    }
}

public enum UserDataBackupError: Error, LocalizedError, Sendable {
    case backupDirectoryEscapesHome
    case backupDirectoryTraversesSymlink
    case backupFileMissing
    case backupQuickCheckFailed(String)
    case missingBackupMeta(String)
    case invalidBackupMeta(String)
    case rowCountMismatch(table: String, expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .backupDirectoryEscapesHome:
            "backup directory must stay within HOME"
        case .backupDirectoryTraversesSymlink:
            "backup directory must not traverse symlinks"
        case .backupFileMissing:
            "backup file is missing"
        case .backupQuickCheckFailed(let value):
            "backup quick_check failed: \(value)"
        case .missingBackupMeta(let key):
            "backup metadata missing key \(key)"
        case .invalidBackupMeta(let key):
            "backup metadata key \(key) is not an integer"
        case let .rowCountMismatch(table, expected, actual):
            "backup row count mismatch for \(table): expected \(expected), got \(actual)"
        }
    }
}

public enum UserDataBackup {
    public typealias ValidationHook = @Sendable (URL) throws -> Void

    public static let backupFilePrefix = "user-data-"
    public static let backupFileSuffix = ".sqlite"
    public static let defaultMinimumIntervalSeconds: TimeInterval = 24 * 60 * 60
    public static let retainedBackupCount = 7

    private static let log = os.Logger(subsystem: "com.engram.service", category: "user-data-backup")
    private static let metadataKeys: [(key: String, table: String)] = [
        ("row_count_insights", "insights"),
        ("row_count_sessions", "sessions"),
        ("row_count_session_local_state", "session_local_state"),
        ("row_count_project_aliases", "project_aliases"),
        ("row_count_migration_log", "migration_log"),
        ("row_count_favorites", "favorites"),
        ("row_count_session_relations", "session_relations")
    ]

    public static func backupDirectory(environment: [String: String]) throws -> URL {
        if let override = environment["ENGRAM_BACKUP_DIR"], !override.isEmpty {
            let overrideURL = URL(
                fileURLWithPath: lexicallyNormalizedPath(URL(fileURLWithPath: override, isDirectory: true).path),
                isDirectory: true
            )
            try prepareDirectory(overrideURL, enforceHomeContainment: false)
            return overrideURL
        }

        let homeURL = URL(
            fileURLWithPath: lexicallyNormalizedPath(FileManager.default.homeDirectoryForCurrentUser.path),
            isDirectory: true
        )
        let backupURL = homeURL
            .appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        guard backupURL.path.hasPrefix(homeURL.path + "/") else {
            throw UserDataBackupError.backupDirectoryEscapesHome
        }
        try prepareDirectory(backupURL, enforceHomeContainment: true, homeURL: homeURL)
        return backupURL
    }

    public static func validateBackup(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UserDataBackupError.backupFileMissing
        }
        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
            guard quickCheck.lowercased() == "ok" else {
                throw UserDataBackupError.backupQuickCheckFailed(quickCheck)
            }
            for item in metadataKeys {
                let raw = try String.fetchOne(
                    db,
                    sql: "SELECT value FROM backup_meta WHERE key = ?",
                    arguments: [item.key]
                )
                guard let raw else { throw UserDataBackupError.missingBackupMeta(item.key) }
                guard let expected = Int(raw) else { throw UserDataBackupError.invalidBackupMeta(item.key) }
                let actual = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(item.table)") ?? -1
                guard expected == actual else {
                    throw UserDataBackupError.rowCountMismatch(
                        table: item.table,
                        expected: expected,
                        actual: actual
                    )
                }
            }
        }
    }

    static func backupFileURL(in directory: URL, now: Date) -> URL {
        directory.appendingPathComponent("\(backupFilePrefix)\(formatTimestamp(now))\(backupFileSuffix)")
    }

    static func availableBackupFileURL(in directory: URL, now: Date) -> URL {
        var candidateDate = now
        for _ in 0..<60 {
            let url = backupFileURL(in: directory, now: candidateDate)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            candidateDate = candidateDate.addingTimeInterval(1)
        }
        return backupFileURL(in: directory, now: candidateDate)
    }

    static func temporaryBackupFileURL(for backupURL: URL) -> URL {
        backupURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(backupURL.lastPathComponent).tmp-\(UUID().uuidString)")
    }

    static func parseBackupDate(from fileName: String) -> Date? {
        guard fileName.hasPrefix(backupFilePrefix),
              fileName.hasSuffix(backupFileSuffix) else {
            return nil
        }
        let start = fileName.index(fileName.startIndex, offsetBy: backupFilePrefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -backupFileSuffix.count)
        return timestampFormatter().date(from: String(fileName[start..<end]))
    }

    static func minimumInterval(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["ENGRAM_BACKUP_MIN_INTERVAL_SECONDS"],
              let value = TimeInterval(raw),
              value >= 0 else {
            return defaultMinimumIntervalSeconds
        }
        return value
    }

    static func newestValidBackup(in directory: URL) throws -> (url: URL, date: Date)? {
        let backups = try matchingBackups(in: directory).sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.url.lastPathComponent > rhs.url.lastPathComponent }
            return lhs.date > rhs.date
        }
        for backup in backups {
            do {
                try validateBackup(at: backup.url)
                return backup
            } catch {
                continue
            }
        }
        return nil
    }

    static func rotateBackups(in directory: URL) throws -> Int {
        let backups = try matchingBackups(in: directory).filter { backup in
            (try? validateBackup(at: backup.url)) != nil
        }.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.url.lastPathComponent > rhs.url.lastPathComponent }
            return lhs.date > rhs.date
        }
        var deleted = 0
        for backup in backups.dropFirst(retainedBackupCount) {
            try FileManager.default.removeItem(at: backup.url)
            deleted += 1
        }
        return deleted
    }

    private static func matchingBackups(in directory: URL) throws -> [(url: URL, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard let date = parseBackupDate(from: url.lastPathComponent) else { return nil }
            return (url, date)
        }
    }

    private static func prepareDirectory(
        _ directory: URL,
        enforceHomeContainment: Bool,
        homeURL: URL? = nil
    ) throws {
        if enforceHomeContainment, let homeURL {
            guard directory.path.hasPrefix(homeURL.path + "/") else {
                throw UserDataBackupError.backupDirectoryEscapesHome
            }
            try rejectSymlinkAncestors(from: directory, through: homeURL)
        } else {
            try rejectSymlinkAncestors(from: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPermissions(path: directory.path, mode: 0o700)
        if enforceHomeContainment, let homeURL {
            try rejectSymlinkAncestors(from: directory, through: homeURL)
        } else {
            try rejectSymlinkAncestors(from: directory)
        }
    }

    private static func rejectSymlinkAncestors(from url: URL, through boundary: URL? = nil) throws {
        var currentPath = lexicallyNormalizedPath(url.path)
        let boundaryPath = boundary.map { lexicallyNormalizedPath($0.path) }
        while true {
            var info = stat()
            if lstat(currentPath, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else {
                    throw UserDataBackupError.backupDirectoryTraversesSymlink
                }
            } else if errno != ENOENT {
                throw UserDataBackupError.backupDirectoryTraversesSymlink
            }
            if let boundaryPath, currentPath == boundaryPath { break }
            let parentPath = (currentPath as NSString).deletingLastPathComponent
            guard !parentPath.isEmpty, parentPath != currentPath else { break }
            currentPath = parentPath
        }
    }

    private static func lexicallyNormalizedPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty, components.last != ".." {
                    components.removeLast()
                } else if !absolute {
                    components.append(String(component))
                }
            default:
                components.append(String(component))
            }
        }
        let joined = components.joined(separator: "/")
        if absolute {
            return joined.isEmpty ? "/" : "/\(joined)"
        }
        return joined.isEmpty ? "." : joined
    }

    private static func setPermissions(path: String, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter().string(from: date)
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    static func logValidationFailure(_ error: Error, backupURL: URL) {
        log.error(
            "user data backup validation failed for \(backupURL.path, privacy: .private): \(String(describing: error), privacy: .private)"
        )
    }
}

public extension EngramDatabaseWriter {
    @discardableResult
    func runUserDataBackupIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        validationHook: UserDataBackup.ValidationHook = { _ in }
    ) throws -> UserDataBackupRunResult {
        let directory = try UserDataBackup.backupDirectory(environment: environment)
        let minInterval = UserDataBackup.minimumInterval(environment: environment)
        if let newest = try UserDataBackup.newestValidBackup(in: directory),
           now.timeIntervalSince(newest.date) < minInterval {
            return UserDataBackupRunResult(status: .skippedFreshBackup, backupURL: newest.url)
        }

        let backupURL = UserDataBackup.availableBackupFileURL(in: directory, now: now)
        let temporaryURL = UserDataBackup.temporaryBackupFileURL(for: backupURL)
        let payload = try read { db in
            try UserDataBackupPayload.fetch(from: db)
        }
        do {
            try payload.write(to: temporaryURL, createdAt: now)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        do {
            try UserDataBackup.validateBackup(at: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            UserDataBackup.logValidationFailure(error, backupURL: backupURL)
            return UserDataBackupRunResult(status: .failedValidation, backupURL: backupURL)
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try FileManager.default.moveItem(at: temporaryURL, to: backupURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        do {
            try validationHook(backupURL)
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            UserDataBackup.logValidationFailure(error, backupURL: backupURL)
            return UserDataBackupRunResult(status: .failedValidation, backupURL: backupURL)
        }
        let deleted = try UserDataBackup.rotateBackups(in: directory)
        return UserDataBackupRunResult(status: .created, backupURL: backupURL, deletedOldBackups: deleted)
    }
}

private struct UserDataBackupPayload {
    let sourceSchemaVersion: String
    let insights: [InsightRow]
    let sessions: [SessionUserRow]
    let sessionLocalStates: [SessionLocalStateRow]
    let projectAliases: [ProjectAliasRow]
    let migrationLogs: [MigrationLogRow]
    let favorites: [FavoriteRow]
    let sessionRelations: [SessionRelationRow]

    static func fetch(from db: Database) throws -> UserDataBackupPayload {
        UserDataBackupPayload(
            sourceSchemaVersion: try String.fetchOne(
                db,
                sql: "SELECT value FROM metadata WHERE key = 'schema_version'"
            ) ?? "unknown",
            insights: try InsightRow.fetchAll(db),
            sessions: try SessionUserRow.fetchAll(db),
            sessionLocalStates: try SessionLocalStateRow.fetchAll(db),
            projectAliases: try ProjectAliasRow.fetchAll(db),
            migrationLogs: try MigrationLogRow.fetchAll(db),
            favorites: try FavoriteRow.fetchAll(db),
            sessionRelations: try SessionRelationRow.fetchAll(db)
        )
    }

    func write(to url: URL, createdAt: Date) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try createSchema(db)
            for row in insights { try row.insert(into: db) }
            for row in sessions { try row.insert(into: db) }
            for row in sessionLocalStates { try row.insert(into: db) }
            for row in projectAliases { try row.insert(into: db) }
            for row in migrationLogs { try row.insert(into: db) }
            for row in favorites { try row.insert(into: db) }
            for row in sessionRelations { try row.insert(into: db) }
            try writeMeta(db, createdAt: createdAt)
        }
    }

    private func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE insights (
              id TEXT PRIMARY KEY,
              content TEXT NOT NULL,
              wing TEXT,
              room TEXT,
              source_session_id TEXT,
              importance INTEGER,
              has_embedding INTEGER,
              created_at TEXT,
              insight_type TEXT,
              superseded_by TEXT,
              last_accessed_at TEXT,
              access_count INTEGER
            );
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              parent_session_id TEXT,
              link_source TEXT,
              hidden_at TEXT,
              custom_name TEXT
            );
            CREATE TABLE session_local_state (
              session_id TEXT PRIMARY KEY,
              hidden_at TEXT,
              custom_name TEXT
            );
            CREATE TABLE project_aliases (
              alias TEXT NOT NULL,
              canonical TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (alias, canonical)
            );
            CREATE TABLE migration_log (
              id TEXT PRIMARY KEY,
              old_path TEXT NOT NULL,
              new_path TEXT NOT NULL,
              old_basename TEXT NOT NULL,
              new_basename TEXT NOT NULL,
              state TEXT NOT NULL,
              files_patched INTEGER NOT NULL,
              occurrences INTEGER NOT NULL,
              sessions_updated INTEGER NOT NULL,
              alias_created INTEGER NOT NULL,
              cc_dir_renamed INTEGER NOT NULL,
              started_at TEXT NOT NULL,
              finished_at TEXT,
              dry_run INTEGER NOT NULL,
              rolled_back_of TEXT,
              audit_note TEXT,
              archived INTEGER NOT NULL,
              actor TEXT NOT NULL,
              detail TEXT,
              error TEXT
            );
            CREATE TABLE favorites (
              session_id TEXT PRIMARY KEY,
              created_at TEXT NOT NULL
            );
            CREATE TABLE session_relations (
              a_id TEXT NOT NULL,
              b_id TEXT NOT NULL,
              created_at TEXT NOT NULL,
              PRIMARY KEY (a_id, b_id)
            );
            CREATE TABLE backup_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)
    }

    private func writeMeta(_ db: Database, createdAt: Date) throws {
        let createdAtString = ISO8601DateFormatter().string(from: createdAt)
        let values: [(String, String)] = [
            ("source_schema_version", sourceSchemaVersion),
            ("created_at", createdAtString),
            ("row_count_insights", "\(insights.count)"),
            ("row_count_sessions", "\(sessions.count)"),
            ("row_count_session_local_state", "\(sessionLocalStates.count)"),
            ("row_count_project_aliases", "\(projectAliases.count)"),
            ("row_count_migration_log", "\(migrationLogs.count)"),
            ("row_count_favorites", "\(favorites.count)"),
            ("row_count_session_relations", "\(sessionRelations.count)")
        ]
        for (key, value) in values {
            try db.execute(
                sql: "INSERT INTO backup_meta(key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}

private func backupTableExists(_ db: Database, _ table: String) throws -> Bool {
    try Bool.fetchOne(
        db,
        sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        arguments: [table]
    ) ?? false
}

private struct InsightRow {
    let id: String
    let content: String
    let wing: String?
    let room: String?
    let sourceSessionID: String?
    let importance: Int?
    let hasEmbedding: Int?
    let createdAt: String?
    let insightType: String?
    let supersededBy: String?
    let lastAccessedAt: String?
    let accessCount: Int?

    static func fetchAll(_ db: Database) throws -> [InsightRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, content, wing, room, source_session_id, importance, has_embedding,
              created_at, insight_type, superseded_by, last_accessed_at, access_count
            FROM insights
            ORDER BY id
            """)
        return rows.map { row in
            InsightRow(
                id: row["id"],
                content: row["content"],
                wing: row["wing"] as String?,
                room: row["room"] as String?,
                sourceSessionID: row["source_session_id"] as String?,
                importance: row["importance"] as Int?,
                hasEmbedding: row["has_embedding"] as Int?,
                createdAt: row["created_at"] as String?,
                insightType: row["insight_type"] as String?,
                supersededBy: row["superseded_by"] as String?,
                lastAccessedAt: row["last_accessed_at"] as String?,
                accessCount: row["access_count"] as Int?
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO insights(
              id, content, wing, room, source_session_id, importance, has_embedding,
              created_at, insight_type, superseded_by, last_accessed_at, access_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, content, wing, room, sourceSessionID, importance, hasEmbedding,
                createdAt, insightType, supersededBy, lastAccessedAt, accessCount
            ]
        )
    }
}

private struct SessionUserRow {
    let id: String
    let parentSessionID: String?
    let linkSource: String?
    let hiddenAt: String?
    let customName: String?

    static func fetchAll(_ db: Database) throws -> [SessionUserRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id,
              CASE WHEN link_source = 'manual' THEN parent_session_id END AS parent_session_id,
              CASE WHEN link_source = 'manual' THEN link_source END AS link_source,
              hidden_at,
              custom_name
            FROM sessions
            WHERE link_source = 'manual'
               OR hidden_at IS NOT NULL
               OR custom_name IS NOT NULL
            ORDER BY id
            """)
        return rows.map { row in
            SessionUserRow(
                id: row["id"],
                parentSessionID: row["parent_session_id"] as String?,
                linkSource: row["link_source"] as String?,
                hiddenAt: row["hidden_at"] as String?,
                customName: row["custom_name"] as String?
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sessions(id, parent_session_id, link_source, hidden_at, custom_name)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [id, parentSessionID, linkSource, hiddenAt, customName]
        )
    }
}

private struct SessionLocalStateRow {
    let sessionID: String
    let hiddenAt: String?
    let customName: String?

    static func fetchAll(_ db: Database) throws -> [SessionLocalStateRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT session_id, hidden_at, custom_name
            FROM session_local_state
            WHERE hidden_at IS NOT NULL OR custom_name IS NOT NULL
            ORDER BY session_id
            """)
        return rows.map { row in
            SessionLocalStateRow(
                sessionID: row["session_id"],
                hiddenAt: row["hidden_at"] as String?,
                customName: row["custom_name"] as String?
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO session_local_state(session_id, hidden_at, custom_name)
            VALUES (?, ?, ?)
            """,
            arguments: [sessionID, hiddenAt, customName]
        )
    }
}

private struct ProjectAliasRow {
    let alias: String
    let canonical: String
    let createdAt: String

    static func fetchAll(_ db: Database) throws -> [ProjectAliasRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT alias, canonical, created_at
            FROM project_aliases
            ORDER BY alias, canonical
            """)
        return rows.map { row in
            ProjectAliasRow(
                alias: row["alias"],
                canonical: row["canonical"],
                createdAt: row["created_at"]
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO project_aliases(alias, canonical, created_at) VALUES (?, ?, ?)",
            arguments: [alias, canonical, createdAt]
        )
    }
}

private struct MigrationLogRow {
    let id: String
    let oldPath: String
    let newPath: String
    let oldBasename: String
    let newBasename: String
    let state: String
    let filesPatched: Int
    let occurrences: Int
    let sessionsUpdated: Int
    let aliasCreated: Int
    let ccDirRenamed: Int
    let startedAt: String
    let finishedAt: String?
    let dryRun: Int
    let rolledBackOf: String?
    let auditNote: String?
    let archived: Int
    let actor: String
    let detail: String?
    let error: String?

    static func fetchAll(_ db: Database) throws -> [MigrationLogRow] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, old_path, new_path, old_basename, new_basename, state, files_patched,
              occurrences, sessions_updated, alias_created, cc_dir_renamed, started_at,
              finished_at, dry_run, rolled_back_of, audit_note, archived, actor, detail, error
            FROM migration_log
            ORDER BY started_at, id
            """)
        return rows.map { row in
            MigrationLogRow(
                id: row["id"],
                oldPath: row["old_path"],
                newPath: row["new_path"],
                oldBasename: row["old_basename"],
                newBasename: row["new_basename"],
                state: row["state"],
                filesPatched: row["files_patched"],
                occurrences: row["occurrences"],
                sessionsUpdated: row["sessions_updated"],
                aliasCreated: row["alias_created"],
                ccDirRenamed: row["cc_dir_renamed"],
                startedAt: row["started_at"],
                finishedAt: row["finished_at"] as String?,
                dryRun: row["dry_run"],
                rolledBackOf: row["rolled_back_of"] as String?,
                auditNote: row["audit_note"] as String?,
                archived: row["archived"],
                actor: row["actor"],
                detail: row["detail"] as String?,
                error: row["error"] as String?
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO migration_log(
              id, old_path, new_path, old_basename, new_basename, state, files_patched,
              occurrences, sessions_updated, alias_created, cc_dir_renamed, started_at,
              finished_at, dry_run, rolled_back_of, audit_note, archived, actor, detail, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                id, oldPath, newPath, oldBasename, newBasename, state, filesPatched,
                occurrences, sessionsUpdated, aliasCreated, ccDirRenamed, startedAt,
                finishedAt, dryRun, rolledBackOf, auditNote, archived, actor, detail, error
            ]
        )
    }
}

private struct FavoriteRow {
    let sessionID: String
    let createdAt: String

    static func fetchAll(_ db: Database) throws -> [FavoriteRow] {
        guard try backupTableExists(db, "favorites") else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT session_id, created_at
            FROM favorites
            ORDER BY session_id
            """)
        return rows.map { row in
            FavoriteRow(
                sessionID: row["session_id"],
                createdAt: row["created_at"]
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO favorites(session_id, created_at) VALUES (?, ?)",
            arguments: [sessionID, createdAt]
        )
    }
}

private struct SessionRelationRow {
    let aID: String
    let bID: String
    let createdAt: String

    static func fetchAll(_ db: Database) throws -> [SessionRelationRow] {
        guard try backupTableExists(db, "session_relations") else { return [] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT a_id, b_id, created_at
            FROM session_relations
            ORDER BY a_id, b_id
            """)
        return rows.map { row in
            SessionRelationRow(
                aID: row["a_id"],
                bID: row["b_id"],
                createdAt: row["created_at"]
            )
        }
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO session_relations(a_id, b_id, created_at) VALUES (?, ?, ?)",
            arguments: [aID, bID, createdAt]
        )
    }
}
