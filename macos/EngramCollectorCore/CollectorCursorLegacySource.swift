import Darwin
import Foundation
import SQLite3

/// Scoped raw rows only. Workspace ownership must be frozen before upload.
enum CollectorCursorLegacySource {
    enum LegacyError: Error, Equatable {
        case unavailable, invalidComposer, ambiguousScope, unsupportedSchema, exceededBudget, sourceChanged
    }
    typealias Row = ArchiveCursorLegacySession.Row
    struct ExportedRows {
        let composerID: String
        let composer: Row
        let bubbles: [Row]
        let rawPayloadByteCount: Int64
        let databaseGeneration: ArchiveSourceGeneration
        let walGeneration: ArchiveSourceGeneration?
    }
    struct DiscoveredComposers: Equatable, Sendable {
        let composerIDs: [String]
        let databaseGeneration: ArchiveSourceGeneration
        let walGeneration: ArchiveSourceGeneration?
    }
    struct Budget {
        var maximumOutputBytes: Int64 = 16 * 1024 * 1024
        var maximumRows: Int = 16384
        var maximumSQLiteSteps: Int64 = 1_000_000
        var snapshot: CollectorSQLiteSnapshotLease.Budget = .init()
    }
    struct TestHooks {
        var beforeSQLiteOpen: ((URL) throws -> Void)?
        var afterRowsRead: (() throws -> Void)?
        var snapshot: CollectorSQLiteSnapshotLease.TestHooks = .init()
    }
    static func exportRows(
        globalStorageRoot: URL, composerID: String, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init()
    ) throws -> ExportedRows {
        try Task.checkCancellation()
        guard !composerID.isEmpty, !composerID.utf8.contains(0) else { throw LegacyError.invalidComposer }
        guard budget.maximumOutputBytes > 0, budget.maximumRows > 0, budget.maximumSQLiteSteps > 0,
              Int64(composerID.utf8.count) <= budget.maximumOutputBytes else { throw LegacyError.exceededBudget }
        let clock = try LegacyReadClock(budget)
        do {
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: globalStorageRoot, databaseName: "state.vscdb", stagingParent: stagingParent,
                budget: budget.snapshot, testHooks: testHooks.snapshot
            ) { snapshot in
                try readRows(snapshot: snapshot, composerID: composerID, budget: budget,
                    testHooks: testHooks, clock: clock)
            }
        } catch let error as CollectorSQLiteSnapshotError {
            switch error {
            case .exceededBudget: throw LegacyError.exceededBudget
            case .sourceChanged, .unsafePath: throw LegacyError.sourceChanged
            case .unavailable: throw LegacyError.unavailable
            }
        }
    }

    static func listComposerIDs(
        globalStorageRoot: URL, stagingParent: URL, after: String? = nil, limit: Int,
        budget: Budget = .init(), testHooks: TestHooks = .init()
    ) throws -> DiscoveredComposers {
        try Task.checkCancellation()
        guard budget.maximumOutputBytes > 0, budget.maximumRows > 0, budget.maximumSQLiteSteps > 0 else {
            throw LegacyError.exceededBudget
        }
        let clock = try LegacyReadClock(budget)
        do {
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: globalStorageRoot, databaseName: "state.vscdb", stagingParent: stagingParent,
                budget: budget.snapshot, testHooks: testHooks.snapshot
            ) { snapshot in
                let ids = try composerIDs(
                    snapshot: snapshot, after: after, limit: limit,
                    budget: budget, testHooks: testHooks, clock: clock)
                return DiscoveredComposers(
                    composerIDs: ids,
                    databaseGeneration: snapshot.databaseGeneration,
                    walGeneration: snapshot.walGeneration)
            }
        } catch let error as CollectorSQLiteSnapshotError {
            switch error {
            case .exceededBudget: throw LegacyError.exceededBudget
            case .sourceChanged, .unsafePath: throw LegacyError.sourceChanged
            case .unavailable: throw LegacyError.unavailable
            }
        }
    }

    /// Key-only page on an existing lease so a later `readRows` can reuse the image.
    static func composerIDs(
        snapshot: CollectorSQLiteSnapshotLease.Snapshot, after: String?, limit: Int,
        budget: Budget, testHooks: TestHooks, clock: LegacyReadClock
    ) throws -> [String] {
        try Task.checkCancellation()
        guard budget.maximumOutputBytes > 0, budget.maximumRows > 0,
              (0...64).contains(limit), limit <= budget.maximumRows else { throw LegacyError.exceededBudget }
        if let after { try validateComposerIdentity(after) }
        try testHooks.beforeSQLiteOpen?(snapshot.privateDatabaseURL)
        // A prior page on this lease may have created a private WAL index.
        // Main/WAL bytes stay bound; forbid only unexpected members.
        try snapshot.validateSQLitePair()
        let reader = try Reader(snapshot: snapshot, budget: budget, clock: clock)
        defer { reader.close() }
        let ids = limit == 0 ? [] : try reader.pageComposerIDs(after: after, limit: limit)
        try testHooks.afterRowsRead?()
        try clock.check()
        try snapshot.validateSQLitePair()
        try snapshot.validateSourcePair()
        return ids
    }

    private static func validateComposerIdentity(_ id: String) throws {
        guard !id.isEmpty, !id.utf8.contains(0), id.utf8.count <= 4096 else { throw LegacyError.invalidComposer }
    }

    /// Read rows from an existing lease so ownership uses the same global image.
    static func readRows(
        snapshot: CollectorSQLiteSnapshotLease.Snapshot, composerID: String,
        budget: Budget, testHooks: TestHooks, clock: LegacyReadClock
    ) throws -> ExportedRows {
        guard !composerID.isEmpty, !composerID.utf8.contains(0) else { throw LegacyError.invalidComposer }
        guard budget.maximumOutputBytes > 0, budget.maximumRows > 0,
              Int64(composerID.utf8.count) <= budget.maximumOutputBytes else { throw LegacyError.exceededBudget }
        try testHooks.beforeSQLiteOpen?(snapshot.privateDatabaseURL)
        // A prior `composerIDs` on this lease may have created a private WAL
        // index. Main/WAL bytes stay bound; forbid only unexpected members.
        try snapshot.validateSQLitePair()
        let reader = try Reader(snapshot: snapshot, budget: budget, clock: clock)
        defer { reader.close() }
        let composerKey = "composerData:" + composerID
        let composers = try reader.rows(
            "SELECT rowid, key, value FROM cursorDiskKV WHERE key COLLATE BINARY = ? LIMIT 2",
            bindings: [composerKey], maximumRows: 2
        )
        guard composers.count == 1, let composer = composers.first,
              composer.key.utf8.elementsEqual(composerKey.utf8), let raw = composer.value,
              let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let embeddedID = object["composerId"] as? String,
              embeddedID.utf8.elementsEqual(composerID.utf8) else { throw LegacyError.invalidComposer }
        let embedded = (object["conversation"] as? [Any])?.isEmpty == false
        let prefix = "bubbleId:" + composerID + ":"
        var bubbles: [Row] = []
        if !embedded {
            // Rowid traversal avoids a value-bearing temporary sort. VM and
            // wall-clock budgets bound scans even in large shared stores.
            bubbles = try reader.rows(
                "SELECT rowid, key, value FROM cursorDiskKV NOT INDEXED " +
                "WHERE key COLLATE BINARY >= ? AND key COLLATE BINARY < ? ORDER BY rowid",
                bindings: [prefix, "bubbleId:" + composerID + ";"],
                maximumRows: budget.maximumRows - 1, initialBytes: Int64(raw.count)
            )
            for bubble in bubbles {
                let key = Array(bubble.key.utf8)
                guard key.starts(with: prefix.utf8) else { throw LegacyError.ambiguousScope }
                // A colon can delimit either a composer ID or a bubble ID.
                // Only an actual competing composer makes this row ambiguous.
                for index in key.indices where index >= 9 && key[index] == 58 {
                    let candidateBytes = key[9..<index]
                    if candidateBytes.elementsEqual(composerID.utf8) { continue }
                    guard let candidate = String(bytes: candidateBytes, encoding: .utf8) else {
                        throw LegacyError.ambiguousScope
                    }
                    if try reader.composerExists(candidate) { throw LegacyError.ambiguousScope }
                }
            }
        }
        try testHooks.afterRowsRead?()
        try clock.check()
        try snapshot.validateSQLitePair()
        try snapshot.validateSourcePair()
        return ExportedRows(composerID: composerID, composer: composer, bubbles: bubbles,
            rawPayloadByteCount: Int64(raw.count) + bubbles.reduce(0) { $0 + Int64($1.value?.count ?? 0) },
            databaseGeneration: snapshot.databaseGeneration, walGeneration: snapshot.walGeneration)
    }

    /// Only the two fixed ownership keys are admitted; message rows stay opaque.
    static func readOwnershipIndex(
        snapshot: CollectorSQLiteSnapshotLease.Snapshot, key: String, budget: Budget,
        clock: LegacyReadClock, beforeSQLiteOpen: ((URL) throws -> Void)?
    ) throws -> Data? {
        guard ["composer.composerData", "composer.composerHeaders"].contains(key) else {
            throw LegacyError.unsupportedSchema
        }
        try beforeSQLiteOpen?(snapshot.privateDatabaseURL)
        try snapshot.validateSQLitePair()
        let reader = try Reader(snapshot: snapshot, budget: budget, clock: clock, ownershipTable: true)
        defer { reader.close() }
        guard reader.hasTable else { return nil }
        let statement = try reader.prepare("SELECT key, value FROM ItemTable WHERE key COLLATE BINARY = ? LIMIT 2",
            bindings: [key])
        defer { sqlite3_finalize(statement) }
        guard try reader.step(statement) == SQLITE_ROW else { return nil }
        guard try reader.string(statement, 0).utf8.elementsEqual(key.utf8) else { throw LegacyError.unsupportedSchema }
        let raw = try reader.bytes(statement, 1)
        guard try reader.step(statement) == SQLITE_DONE else { throw LegacyError.unsupportedSchema }
        try snapshot.validateSQLitePair()
        return raw
    }

    private final class Reader {
        let db: OpaquePointer
        let budget: Budget
        let clock: LegacyReadClock
        private(set) var hasTable = false

        init(snapshot: CollectorSQLiteSnapshotLease.Snapshot, budget: Budget, clock: LegacyReadClock,
             ownershipTable: Bool = false) throws {
            self.budget = budget
            self.clock = clock
            let url = snapshot.privateDatabaseURL
            let path = snapshot.walGeneration == nil ? url.absoluteString + "?immutable=1" : url.path
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | (snapshot.walGeneration == nil ? SQLITE_OPEN_URI : 0)
            var opened: OpaquePointer?
            let status = sqlite3_open_v2(path, &opened, flags, nil)
            guard status == SQLITE_OK, let opened else {
                if let opened { sqlite3_close(opened) }
                throw LegacyError.unavailable
            }
            db = opened
            do {
                sqlite3_busy_timeout(db, 0)
                // SQLite's record limit also charges keys, headers and schema.
                // Bound that allocation separately; rows() enforces raw output.
                let recordPayload = min(budget.maximumOutputBytes, (Int64(Int32.max) - 4096) / 2)
                _ = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(recordPayload * 2 + 4096))
                _ = sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 4096)
                sqlite3_progress_handler(db, 1, { context in
                    guard let context else { return 1 }
                    return Unmanaged<LegacyReadClock>.fromOpaque(context).takeUnretainedValue().tick()
                }, Unmanaged.passUnretained(clock).toOpaque())
                let settings = sqlite3_exec(db,
                    "PRAGMA query_only=ON; PRAGMA temp_store=MEMORY; PRAGMA trusted_schema=OFF", nil, nil, nil)
                guard settings == SQLITE_OK else { try clock.fail(settings) }
                let table = ownershipTable ? "ItemTable" : "cursorDiskKV"
                let schema = try prepare("PRAGMA main.table_list('\(table)')")
                defer { sqlite3_finalize(schema) }
                let tableStatus = try step(schema)
                if ownershipTable && tableStatus == SQLITE_DONE { return }
                guard tableStatus == SQLITE_ROW,
                      try string(schema, 0) == "main", try string(schema, 1) == table,
                      try string(schema, 2) == "table", sqlite3_column_int(schema, 3) == 2,
                      (ownershipTable || sqlite3_column_int(schema, 4) == 0),
                      try step(schema) == SQLITE_DONE else { throw LegacyError.unsupportedSchema }
                let columns = try prepare("PRAGMA main.table_info('\(table)')")
                defer { sqlite3_finalize(columns) }
                var names: [String] = []
                while try step(columns) == SQLITE_ROW {
                    guard names.count < 2 else { throw LegacyError.unsupportedSchema }
                    names.append(try string(columns, 1))
                }
                guard names == ["key", "value"] else { throw LegacyError.unsupportedSchema }
                hasTable = true
                if ownershipTable {
                    guard sqlite3_set_authorizer(db, { _, operation, first, second, database, _ in
                        if operation == SQLITE_SELECT { return SQLITE_OK }
                        if operation == SQLITE_READ, let first, let second, let database,
                           String(cString: database) == "main", String(cString: first) == "ItemTable",
                           ["key", "value"].contains(String(cString: second)) { return SQLITE_OK }
                        return SQLITE_DENY
                    }, nil) == SQLITE_OK else { throw LegacyError.unavailable }
                } else {
                    guard sqlite3_set_authorizer(db, { _, operation, first, second, database, _ in
                        if operation == SQLITE_SELECT { return SQLITE_OK }
                        if operation == SQLITE_FUNCTION, let second,
                           String(cString: second) == "substr" { return SQLITE_OK }
                        if operation == SQLITE_READ, let first, let second, let database,
                           String(cString: database) == "main", String(cString: first) == "cursorDiskKV",
                           ["key", "value", "ROWID"].contains(String(cString: second)) { return SQLITE_OK }
                        return SQLITE_DENY
                    }, nil) == SQLITE_OK else { throw LegacyError.unavailable }
                }
                try snapshot.validateSQLitePair()
            } catch {
                close()
                throw error
            }
        }

        func close() {
            sqlite3_set_authorizer(db, nil, nil)
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_close(db)
        }

        func prepare(_ sql: String, bindings: [String] = []) throws -> OpaquePointer {
            try clock.check()
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard status == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                try clock.fail(status)
            }
            do {
                for (offset, binding) in bindings.enumerated() {
                    let status = binding.withCString {
                        sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(clamping: binding.utf8.count),
                            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                    guard status == SQLITE_OK else { try clock.fail(status) }
                }
                return statement
            } catch { sqlite3_finalize(statement); throw error }
        }

        func step(_ statement: OpaquePointer) throws -> Int32 {
            try clock.check()
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { try clock.fail(status) }
            return status
        }

        func bytes(_ statement: OpaquePointer, _ column: Int32) throws -> Data? {
            let type = sqlite3_column_type(statement, column)
            if type == SQLITE_NULL { return nil }
            guard type == SQLITE_TEXT || type == SQLITE_BLOB else { throw LegacyError.unsupportedSchema }
            // TEXT is the logical UTF-8 payload even in a UTF-16 database.
            // BLOB and embedded NUL bytes remain opaque and length-delimited.
            let pointer: UnsafeRawPointer? = type == SQLITE_TEXT
                ? sqlite3_column_text(statement, column).map { UnsafeRawPointer($0) }
                : sqlite3_column_blob(statement, column)
            let count = Int(sqlite3_column_bytes(statement, column))
            guard Int64(count) <= budget.maximumOutputBytes else { throw LegacyError.exceededBudget }
            guard count > 0 else { return Data() }
            guard let pointer else { throw LegacyError.unavailable }
            return Data(bytes: pointer, count: count)
        }

        func string(_ statement: OpaquePointer, _ column: Int32) throws -> String {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                  let raw = try bytes(statement, column), !raw.contains(0),
                  let result = String(data: raw, encoding: .utf8) else { throw LegacyError.unsupportedSchema }
            return result
        }

        func rows(_ sql: String, bindings: [String], maximumRows: Int, initialBytes: Int64 = 0) throws -> [Row] {
            let statement = try prepare(sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }
            var result: [Row] = []
            var total = initialBytes
            var keyBytes: Int64 = 0
            while try step(statement) == SQLITE_ROW {
                guard result.count < maximumRows else { throw LegacyError.exceededBudget }
                let key = try string(statement, 1)
                let type = sqlite3_column_type(statement, 2)
                let value = try bytes(statement, 2)
                let next = total.addingReportingOverflow(Int64(value?.count ?? 0))
                let keys = keyBytes.addingReportingOverflow(Int64(key.utf8.count))
                guard !next.overflow, next.partialValue <= budget.maximumOutputBytes,
                      !keys.overflow, keys.partialValue <= budget.maximumOutputBytes else { throw LegacyError.exceededBudget }
                total = next.partialValue
                keyBytes = keys.partialValue
                result.append(Row(rowID: sqlite3_column_int64(statement, 0), key: key, value: value,
                    storage: type == SQLITE_NULL ? .null : (type == SQLITE_BLOB ? .blob : .text)))
            }
            return result
        }

        func composerExists(_ id: String) throws -> Bool {
            let statement = try prepare("SELECT key FROM cursorDiskKV WHERE key COLLATE BINARY = ? LIMIT 1",
                bindings: ["composerData:" + id])
            defer { sqlite3_finalize(statement) }
            return try step(statement) == SQLITE_ROW
        }

        func pageComposerIDs(after: String?, limit: Int) throws -> [String] {
            let prefix = Data("composerData:".utf8)
            let lower = after.map { "composerData:" + $0 } ?? "composerData:"
            let comparison = after == nil ? ">=" : ">"
            let statement = try prepare(
                """
                SELECT c.key FROM cursorDiskKV c
                WHERE c.key COLLATE BINARY \(comparison) ? AND c.key COLLATE BINARY < ?
                  AND (c.value IS NOT NULL
                    OR EXISTS (SELECT 1 FROM cursorDiskKV duplicate
                      WHERE duplicate.key COLLATE BINARY = c.key AND duplicate.rowid != c.rowid)
                    OR EXISTS (SELECT 1 FROM cursorDiskKV bubble
                      WHERE bubble.key COLLATE BINARY >= ('bubbleId:' || substr(c.key, 14) || ':')
                        AND bubble.key COLLATE BINARY < ('bubbleId:' || substr(c.key, 14) || ';')))
                ORDER BY c.key COLLATE BINARY LIMIT ?
                """,
                bindings: [lower, "composerData;"]
            )
            defer { sqlite3_finalize(statement) }
            // A unique NULL composer with no bubbles is a deletion marker, not
            // a conversation. Filter it before LIMIT so it cannot stop paging.
            // Keep orphan bubbles and duplicate keys visible to existing refusal checks.
            // Peek one past LIMIT so a twin key on the page edge cannot be
            // skipped by the exclusive after cursor.
            guard sqlite3_bind_int64(statement, 3, Int64(limit) + 1) == SQLITE_OK else { throw LegacyError.unavailable }
            var ids: [String] = []
            var previousKey: Data?
            var total: Int64 = 0
            while try step(statement) == SQLITE_ROW {
                let key = try textKey(statement, 0)
                if let previousKey, previousKey == key { throw LegacyError.ambiguousScope }
                guard key.starts(with: prefix) else { throw LegacyError.invalidComposer }
                let id = key.dropFirst(prefix.count)
                guard !id.isEmpty, !id.contains(0), id.count <= 4096,
                      let composerID = String(data: Data(id), encoding: .utf8),
                      composerID.utf8.elementsEqual(id) else { throw LegacyError.invalidComposer }
                previousKey = key
                guard ids.count < limit else { break }
                let next = total.addingReportingOverflow(Int64(id.count))
                guard !next.overflow, next.partialValue <= budget.maximumOutputBytes else {
                    throw LegacyError.exceededBudget
                }
                total = next.partialValue
                ids.append(composerID)
            }
            return ids
        }

        func textKey(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { throw LegacyError.unsupportedSchema }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count <= 13 + 4096 else { throw LegacyError.invalidComposer }
            guard count > 0 else { return Data() }
            guard let pointer = sqlite3_column_text(statement, column).map({ UnsafeRawPointer($0) }) else {
                throw LegacyError.unavailable
            }
            return Data(bytes: pointer, count: count)
        }
    }
}

final class LegacyReadClock {
    let deadline: UInt64
    var remaining: Int64
    var exhausted = false

    init(_ budget: CollectorCursorLegacySource.Budget) throws {
        guard budget.snapshot.maximumLeaseMilliseconds > 0 else { throw CollectorCursorLegacySource.LegacyError.exceededBudget }
        let duration = UInt64(budget.snapshot.maximumLeaseMilliseconds).multipliedReportingOverflow(by: 1_000_000)
        let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW).addingReportingOverflow(duration.partialValue)
        guard !duration.overflow, !end.overflow else { throw CollectorCursorLegacySource.LegacyError.exceededBudget }
        deadline = end.partialValue
        remaining = budget.maximumSQLiteSteps
    }

    func check() throws {
        try Task.checkCancellation()
        guard !exhausted, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) <= deadline else {
            throw CollectorCursorLegacySource.LegacyError.exceededBudget
        }
    }

    func tick() -> Int32 {
        do {
            try check()
            guard remaining > 0 else { exhausted = true; return 1 }
            remaining -= 1
            return 0
        } catch { return 1 }
    }

    func fail(_ status: Int32) throws -> Never {
        try check()
        if status == SQLITE_TOOBIG { throw CollectorCursorLegacySource.LegacyError.exceededBudget }
        if status == SQLITE_AUTH || status == SQLITE_ERROR { throw CollectorCursorLegacySource.LegacyError.unsupportedSchema }
        throw CollectorCursorLegacySource.LegacyError.unavailable
    }
}
