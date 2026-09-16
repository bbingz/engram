import Darwin
import Foundation
import SQLite3

enum CollectorOpenCodeSourceError: Error, Equatable {
    case unavailable
    case unsafePath
    case sourceChanged
    case missingSession
    case invalidSession
    case unsupportedSchema
    case exceededBudget
}

/// A scoped native database image, not a byte-exact copy of the source DB.
/// Archive transport must identify this derived representation explicitly.
enum CollectorOpenCodeSource {
    struct Snapshot {
        let image: Data
        let sessionID: String
        let cwd: String
        let nativePayloadByteCount: Int64
        let databaseGeneration: ArchiveSourceGeneration
        let walGeneration: ArchiveSourceGeneration?
    }

    struct Budget {
        var maximumByteCount: Int64 = 16 * 1024 * 1024
        var maximumRows: Int = 100_000
        var maximumSQLiteSteps: Int = 1_000_000
        var maximumSnapshotByteCount: Int64 = 1024 * 1024 * 1024
        var maximumCopyByteCount: Int64 = 16 * 1024 * 1024
        var maximumLeaseMilliseconds: Int = 5_000
    }

    struct TestHooks {
        var afterSessionRead: (() throws -> Void)?
        var afterPrivateMainCopy: (() throws -> Void)?
        var afterSourceDescriptorsOpened: (() throws -> Void)?
        var willOpenSQLite: ((URL) throws -> Void)?
        var didStageSourceFile: ((String, Bool, Int64) -> Void)?
        var forceStreamingCopy: Bool = false
    }

    final class SnapshotLease {
        fileprivate let state: OpenCodeSnapshotLeaseState

        fileprivate init(state: OpenCodeSnapshotLeaseState) {
            self.state = state
        }

        var databaseGeneration: ArchiveSourceGeneration { state.databaseGeneration }
        var walGeneration: ArchiveSourceGeneration? { state.walGeneration }

        func sessionIDs(after: String? = nil, limit: Int = 64) throws -> [String] {
            try state.requireActive()
            return try CollectorOpenCodeSource.sessionIDs(state: state, after: after, limit: limit)
        }

        func snapshot(sessionID: String) throws -> Snapshot {
            try state.requireActive()
            return try CollectorOpenCodeSource.exportImage(state: state, sessionID: sessionID)
        }
    }

    /// A bounded observation used to schedule work; the later lease establishes capture provenance.
    static func observe(root: URL) throws -> (
        databaseGeneration: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?
    ) {
        do { return try CollectorSQLiteSnapshotLease.observe(root: root, databaseName: "opencode.db") }
        catch let error as CollectorSQLiteSnapshotError { throw physicalSnapshotError(error) }
    }

    /// Inspect relational ownership in captured bytes only. Message JSON remains opaque.
    static func privacyMetadata(
        image: Data, nativeSessionID: String, budget: Budget
    ) throws -> (cwd: String, nativePayloadByteCount: Int64) {
        try Task.checkCancellation()
        try validateBudget(budget)
        guard Int64(image.count) <= budget.maximumByteCount else {
            throw CollectorOpenCodeSourceError.exceededBudget
        }
        guard image.count >= 100, image.starts(with: Data("SQLite format 3\0".utf8)), image[18] == 1, image[19] == 1 else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        let clock = try LeaseClock(milliseconds: budget.maximumLeaseMilliseconds)
        let progress = ProgressState(maximum: budget.maximumSQLiteSteps, clock: clock)
        var buffer = image
        return try buffer.withUnsafeMutableBytes { bytes in
            let db = try open(":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                progress: progress, lengthLimit: budget.maximumByteCount)
            defer { close(db) }
            // The buffer stays alive until after close; READONLY does not transfer ownership.
            guard sqlite3_deserialize(db, "main", bytes.bindMemory(to: UInt8.self).baseAddress,
                sqlite3_int64(bytes.count), sqlite3_int64(bytes.count), UInt32(SQLITE_DESERIALIZE_READONLY)) == SQLITE_OK else {
                throw CollectorOpenCodeSourceError.invalidSession
            }
            try exec(db, "PRAGMA query_only = ON")
            try exec(db, "PRAGMA temp_store = MEMORY")
            let schema = try prepare(db, "SELECT type, name, sql FROM sqlite_schema")
            defer { sqlite3_finalize(schema) }
            var tables = Set<String>()
            while try step(schema) == SQLITE_ROW {
                let type = try columnSessionID(schema, 0)
                let name = try columnSessionID(schema, 1)
                if type == "index", sqlite3_column_type(schema, 2) == SQLITE_NULL { continue }
                guard type == "table", ["session", "message", "part"].contains(name),
                      !(try columnSessionID(schema, 2)).uppercased().contains("CREATE VIRTUAL TABLE") else {
                    throw CollectorOpenCodeSourceError.invalidSession
                }
                tables.insert(name)
            }
            guard tables == Set(["session", "message", "part"]) else {
                throw CollectorOpenCodeSourceError.unsupportedSchema
            }
            let pageSize = try scalarInteger(db, "PRAGMA page_size")
            let pageCount = try scalarInteger(db, "PRAGMA page_count")
            let geometry = pageSize.multipliedReportingOverflow(by: pageCount)
            guard !geometry.overflow, geometry.partialValue == Int64(image.count),
                  try scalarInteger(db, "PRAGMA freelist_count") == 0 else {
                throw CollectorOpenCodeSourceError.invalidSession
            }
            let sessionCount = try scalarInteger(db, "SELECT count(*) FROM session")
            let messageCount = try scalarInteger(db, "SELECT count(*) FROM message")
            let partCount = try scalarInteger(db, "SELECT count(*) FROM part")
            guard sessionCount == 1 else { throw CollectorOpenCodeSourceError.invalidSession }
            var rows: Int64 = 0
            for count in [sessionCount, messageCount, partCount] {
                let next = rows.addingReportingOverflow(count)
                guard !next.overflow, count >= 0, next.partialValue <= Int64(budget.maximumRows) else {
                    throw CollectorOpenCodeSourceError.exceededBudget
                }
                rows = next.partialValue
            }
            let session = try prepare(db, "SELECT id, directory FROM session LIMIT 2")
            defer { sqlite3_finalize(session) }
            guard try step(session) == SQLITE_ROW,
                  try columnSessionID(session, 0).utf8.elementsEqual(nativeSessionID.utf8) else {
                throw CollectorOpenCodeSourceError.invalidSession
            }
            let cwd = try columnSessionID(session, 1)
            let foreignMessage = try prepare(db, """
                SELECT 1 FROM message WHERE typeof(id) != 'text' OR typeof(session_id) != 'text'
                    OR session_id != ? COLLATE BINARY LIMIT 1
                """)
            defer { sqlite3_finalize(foreignMessage) }
            try bindText(foreignMessage, 1, nativeSessionID)
            guard try step(foreignMessage) == SQLITE_DONE,
                  try scalarInteger(db, "SELECT count(DISTINCT id COLLATE BINARY) FROM message") == messageCount,
                  try scalarInteger(db, """
                      SELECT count(*) FROM part p WHERE typeof(p.message_id) != 'text' OR NOT EXISTS
                          (SELECT 1 FROM message m WHERE m.id = p.message_id COLLATE BINARY)
                      """) == 0 else {
                throw CollectorOpenCodeSourceError.invalidSession
            }
            var payload: Int64 = 0
            for table in ["message", "part"] {
                let count = try scalarInteger(db, "SELECT coalesce(sum(length(CAST(data AS BLOB))), 0) FROM \(table)")
                let next = payload.addingReportingOverflow(count)
                guard !next.overflow, count >= 0, next.partialValue <= Int64(image.count) else {
                    throw CollectorOpenCodeSourceError.invalidSession
                }
                payload = next.partialValue
            }
            try clock.check()
            return (cwd, payload)
        }
    }

    private static func scalarInteger(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func withSnapshotLease<T>(
        root: URL, stagingParent: URL, budget: Budget = .init(), testHooks: TestHooks = .init(),
        _ body: (SnapshotLease) throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        try validateBudget(budget)
        let clock = try LeaseClock(milliseconds: budget.maximumLeaseMilliseconds)
        do {
            return try CollectorSQLiteSnapshotLease.withSnapshot(
                root: root, databaseName: "opencode.db", stagingParent: stagingParent,
                budget: .init(maximumSnapshotByteCount: budget.maximumSnapshotByteCount,
                    maximumCopyByteCount: budget.maximumCopyByteCount,
                    maximumLeaseMilliseconds: budget.maximumLeaseMilliseconds),
                testHooks: .init(afterSourceDescriptorsOpened: testHooks.afterSourceDescriptorsOpened,
                    afterPrivateMainCopy: testHooks.afterPrivateMainCopy,
                    beforeSnapshotUse: testHooks.willOpenSQLite,
                    didStageSourceFile: testHooks.didStageSourceFile,
                    forceStreamingCopy: testHooks.forceStreamingCopy)
            ) { snapshot in
                try clock.check()
                let state = OpenCodeSnapshotLeaseState(
                    budget: budget, testHooks: testHooks, clock: clock,
                    databaseGeneration: snapshot.databaseGeneration, walGeneration: snapshot.walGeneration
                )
                let handle = try open(
                    snapshot.privateDatabaseURL.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW,
                    progress: state.progress, lengthLimit: budget.maximumByteCount
                )
                do { try exec(handle, "PRAGMA query_only = ON") }
                catch { close(handle); throw error }
                state.handle = handle
                defer { state.invalidate() }
                return try body(SnapshotLease(state: state))
            }
        } catch let error as CollectorSQLiteSnapshotError {
            throw physicalSnapshotError(error)
        }
    }

    private static func physicalSnapshotError(_ error: CollectorSQLiteSnapshotError) -> CollectorOpenCodeSourceError {
        switch error {
        case .unavailable: return .unavailable
        case .unsafePath: return .unsafePath
        case .sourceChanged: return .sourceChanged
        case .exceededBudget: return .exceededBudget
        }
    }

    static func snapshot(
        root: URL, sessionID: String, stagingParent: URL,
        budget: Budget = .init(), testHooks: TestHooks = .init()
    ) throws -> Snapshot {
        try validateSessionID(sessionID)
        return try withSnapshotLease(
            root: root, stagingParent: stagingParent, budget: budget, testHooks: testHooks
        ) { lease in
            try lease.snapshot(sessionID: sessionID)
        }
    }

    private static func sessionIDs(
        state: OpenCodeSnapshotLeaseState, after: String?, limit: Int
    ) throws -> [String] {
        try state.clock.check()
        guard (0...64).contains(limit) else { throw CollectorOpenCodeSourceError.exceededBudget }
        if limit == 0 { return [] }
        if let after { try validateSessionID(after) }
        guard let db = state.handle else { throw CollectorOpenCodeSourceError.unavailable }
        try requireTable(db, "session")
        let columns = try tableInfo(db, "session")
        guard columns.contains(where: { $0.name == "id" }) else {
            throw CollectorOpenCodeSourceError.unsupportedSchema
        }
        let archived = columns.contains(where: { $0.name == "time_archived" })
        var clauses: [String] = []
        if after != nil { clauses.append("\(try quote("id")) > ? COLLATE BINARY") }
        if archived { clauses.append("\(try quote("time_archived")) IS NULL") }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT \(try quote("id")) FROM \(try quote("session"))\(whereSQL) \
            ORDER BY \(try quote("id")) COLLATE BINARY LIMIT ?
            """
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        if let after {
            try bindText(statement, index, after)
            index += 1
        }
        guard sqlite3_bind_int(statement, index, Int32(limit)) == SQLITE_OK else {
            throw CollectorOpenCodeSourceError.unavailable
        }
        var ids: [String] = []
        while true {
            try state.clock.check()
            let status = try step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CollectorOpenCodeSourceError.unavailable }
            let id = try columnSessionID(statement, 0)
            try validateSessionID(id)
            ids.append(id)
        }
        return ids
    }

    private static func exportImage(state: OpenCodeSnapshotLeaseState, sessionID: String) throws -> Snapshot {
        try state.clock.check()
        try validateSessionID(sessionID)
        guard let db = state.handle else { throw CollectorOpenCodeSourceError.unavailable }
        _ = sqlite3_limit(
            db, SQLITE_LIMIT_LENGTH, Int32(clamping: min(max(state.budget.maximumByteCount, 0), Int64(Int32.max)))
        )
        return try export(
            source: db, sessionID: sessionID, budget: state.budget, testHooks: state.testHooks,
            progress: state.progress, databaseGeneration: state.databaseGeneration,
            walGeneration: state.walGeneration, clock: state.clock
        )
    }

    private static func export(
        source: OpaquePointer, sessionID: String, budget: Budget, testHooks: TestHooks,
        progress: ProgressState, databaseGeneration: ArchiveSourceGeneration,
        walGeneration: ArchiveSourceGeneration?, clock: LeaseClock
    ) throws -> Snapshot {
        try clock.check()
        try exec(source, "BEGIN")
        var rollback = true
        defer {
            if rollback { sqlite3_exec(source, "ROLLBACK", nil, nil, nil) }
        }
        try requireTable(source, "session")
        try requireTable(source, "message")
        try requireTable(source, "part")
        let sessionColumns = try tableInfo(source, "session")
        let messageColumns = try tableInfo(source, "message")
        let partColumns = try tableInfo(source, "part")
        guard sessionColumns.contains(where: { $0.name == "id" }),
              messageColumns.contains(where: { $0.name == "session_id" }),
              messageColumns.contains(where: { $0.name == "id" }),
              partColumns.contains(where: { $0.name == "message_id" }) else {
            throw CollectorOpenCodeSourceError.unsupportedSchema
        }
        var rows = 0
        var retained: Int64 = 0
        var payload: Int64 = 0
        let session = try readSession(
            source, sessionID: sessionID, columns: sessionColumns, budget: budget, rows: &rows, retained: &retained
        )
        try testHooks.afterSessionRead?()
        try clock.check()
        let messages = try readChildren(
            source, table: "message", columns: messageColumns, key: "session_id", value: sessionID,
            budget: budget, rows: &rows, retained: &retained, payload: &payload, clock: clock
        )
        let messageIDs = try identifiers(messages, columns: messageColumns)
        var parts: [Row] = []
        parts.reserveCapacity(messageIDs.count)
        for messageID in messageIDs {
            try clock.check()
            parts.append(contentsOf: try readChildren(
                source, table: "part", columns: partColumns, key: "message_id", value: messageID,
                budget: budget, rows: &rows, retained: &retained, payload: &payload, clock: clock
            ))
        }
        try exec(source, "ROLLBACK")
        rollback = false
        try clock.check()
        let image = try materialize(
            session: session, messages: messages, parts: parts,
            sessionColumns: sessionColumns, messageColumns: messageColumns, partColumns: partColumns,
            budget: budget, progress: progress
        )
        return Snapshot(
            image: image, sessionID: sessionID, cwd: session.cwd, nativePayloadByteCount: payload,
            databaseGeneration: databaseGeneration, walGeneration: walGeneration
        )
    }

    private static func readSession(
        _ db: OpaquePointer, sessionID: String, columns: [Column], budget: Budget,
        rows: inout Int, retained: inout Int64
    ) throws -> SessionRow {
        let sql = "SELECT * FROM \(try quote(columns.table)) WHERE \(try quote("id")) = ? LIMIT 2"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, sessionID)
        let first = try stepRow(statement, columns: columns, budget: budget, retained: &retained)
        guard let first else { throw CollectorOpenCodeSourceError.missingSession }
        if try step(statement) == SQLITE_ROW { throw CollectorOpenCodeSourceError.invalidSession }
        try consumeRow(1, budget: budget, rows: &rows)
        if let archived = cell(first, "time_archived", columns: columns), archived.isNull == false {
            throw CollectorOpenCodeSourceError.missingSession
        }
        guard let id = text(first, "id", columns: columns), id.utf8.elementsEqual(sessionID.utf8) else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        return SessionRow(cells: first, cwd: text(first, "directory", columns: columns) ?? "")
    }

    private static func readChildren(
        _ db: OpaquePointer, table: String, columns: [Column], key: String, value: String,
        budget: Budget, rows: inout Int, retained: inout Int64, payload: inout Int64, clock: LeaseClock
    ) throws -> [Row] {
        var order: [String] = []
        if columns.contains(where: { $0.name == "time_created" }) { order.append("\(try quote("time_created")) ASC") }
        if columns.contains(where: { $0.name == "id" }) { order.append("\(try quote("id")) ASC") }
        let orderSQL = order.isEmpty ? "" : " ORDER BY " + order.joined(separator: ",")
        let sql = "SELECT * FROM \(try quote(table)) WHERE \(try quote(key)) = ?\(orderSQL)"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, value)
        var result: [Row] = []
        while true {
            try clock.check()
            let status = try step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw CollectorOpenCodeSourceError.unavailable }
            let row = try cells(statement, columns: columns, budget: budget, retained: &retained)
            try consumeRow(1, budget: budget, rows: &rows)
            try addNativePayload(row, columns: columns, payload: &payload)
            result.append(row)
        }
    }

    private static func materialize(
        session: SessionRow, messages: [Row], parts: [Row],
        sessionColumns: [Column], messageColumns: [Column], partColumns: [Column],
        budget: Budget, progress: ProgressState
    ) throws -> Data {
        var dest: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &dest, flags, nil) == SQLITE_OK, let dest else {
            throw CollectorOpenCodeSourceError.unavailable
        }
        defer { close(dest) }
        installProgress(dest, progress)
        try createTable(dest, sessionColumns)
        try createTable(dest, messageColumns)
        try createTable(dest, partColumns)
        try insert(dest, table: "session", columns: sessionColumns, rows: [session.cells])
        try insert(dest, table: "message", columns: messageColumns, rows: messages)
        try insert(dest, table: "part", columns: partColumns, rows: parts)
        var size: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(dest, "main", &size, 0), size >= 0 else {
            throw CollectorOpenCodeSourceError.unavailable
        }
        defer { sqlite3_free(bytes) }
        guard size <= budget.maximumByteCount else { throw CollectorOpenCodeSourceError.exceededBudget }
        return Data(bytes: bytes, count: Int(size))
    }

    private static func createTable(_ db: OpaquePointer, _ columns: [Column]) throws {
        let body = try columns.map { "\(try quote($0.name))" }.joined(separator: ",")
        let keys = columns.filter { $0.primaryKey > 0 }.sorted { $0.primaryKey < $1.primaryKey }
        let primary = keys.isEmpty ? "" : ",PRIMARY KEY(\(try keys.map { try quote($0.name) }.joined(separator: ",")))"
        try exec(db, "CREATE TABLE \(try quote(columns.table)) (\(body)\(primary))")
    }

    private static func insert(_ db: OpaquePointer, table: String, columns: [Column], rows: [Row]) throws {
        guard !rows.isEmpty else { return }
        let names = try columns.map { try quote($0.name) }.joined(separator: ",")
        let marks = Array(repeating: "?", count: columns.count).joined(separator: ",")
        let sql = "INSERT INTO \(try quote(table)) (\(names)) VALUES (\(marks))"
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        for row in rows {
            try Task.checkCancellation()
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            for (index, value) in row.enumerated() {
                try bind(statement, index + 1, value)
            }
            guard try step(statement) == SQLITE_DONE else { throw CollectorOpenCodeSourceError.unavailable }
        }
    }

    private static func tableInfo(_ db: OpaquePointer, _ table: String) throws -> [Column] {
        let statement = try prepare(db, "PRAGMA table_info(\(try quote(table)))")
        defer { sqlite3_finalize(statement) }
        var columns: [Column] = []
        while true {
            let status = try step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CollectorOpenCodeSourceError.unavailable }
            guard let name = sqlite3_column_text(statement, 1) else {
                throw CollectorOpenCodeSourceError.unsupportedSchema
            }
            columns.append(Column(
                table: table, name: String(cString: name), primaryKey: sqlite3_column_int(statement, 5)
            ))
        }
        if columns.isEmpty { throw CollectorOpenCodeSourceError.unsupportedSchema }
        return columns
    }

    private static func requireTable(_ db: OpaquePointer, _ name: String) throws {
        let statement = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bindText(statement, 1, name)
        guard try step(statement) == SQLITE_ROW else { throw CollectorOpenCodeSourceError.unsupportedSchema }
    }

    private static func identifiers(_ rows: [Row], columns: [Column]) throws -> [String] {
        try rows.map { row in
            guard let id = text(row, "id", columns: columns), !id.isEmpty else {
                throw CollectorOpenCodeSourceError.invalidSession
            }
            return id
        }
    }

    private static func cells(
        _ statement: OpaquePointer, columns: [Column], budget: Budget, retained: inout Int64
    ) throws -> Row {
        let count = Int(sqlite3_column_count(statement))
        guard count == columns.count else { throw CollectorOpenCodeSourceError.unsupportedSchema }
        var row: Row = []
        row.reserveCapacity(count)
        for index in 0..<count {
            let extra = retainedBytes(statement, Int32(index))
            try accumulate(extra, into: &retained, budget: budget)
            row.append(try cell(statement, Int32(index)))
        }
        return row
    }

    private static func stepRow(
        _ statement: OpaquePointer, columns: [Column], budget: Budget, retained: inout Int64
    ) throws -> Row? {
        let status = try step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw CollectorOpenCodeSourceError.unavailable }
        return try cells(statement, columns: columns, budget: budget, retained: &retained)
    }

    private static func cell(_ statement: OpaquePointer, _ index: Int32) throws -> Cell {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(columnBytes(statement, index))
        case SQLITE_BLOB:
            return .blob(columnBytes(statement, index))
        default:
            return .null
        }
    }

    private static func retainedBytes(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER, SQLITE_FLOAT:
            return 8
        case SQLITE_TEXT, SQLITE_BLOB:
            return Int64(sqlite3_column_bytes(statement, index))
        default:
            return 0
        }
    }

    private static func columnBytes(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        if count == 0 { return Data() }
        if let pointer = sqlite3_column_blob(statement, index) {
            return Data(bytes: pointer, count: count)
        }
        if let pointer = sqlite3_column_text(statement, index) {
            return Data(bytes: pointer, count: count)
        }
        return Data()
    }

    private static func columnSessionID(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let pointer = sqlite3_column_text(statement, index) else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        let bytes = Data(bytes: pointer, count: count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
        return value
    }

    private static func bind(_ statement: OpaquePointer, _ index: Int, _ cell: Cell) throws {
        let status: Int32
        switch cell {
        case .null:
            status = sqlite3_bind_null(statement, Int32(index))
        case .integer(let value):
            status = sqlite3_bind_int64(statement, Int32(index), value)
        case .real(let value):
            status = sqlite3_bind_double(statement, Int32(index), value)
        case .text(let bytes):
            status = bytes.withUnsafeBytes { buffer in
                sqlite3_bind_text(statement, Int32(index), buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(bytes.count), transient)
            }
        case .blob(let bytes):
            status = bytes.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, Int32(index), buffer.baseAddress, Int32(bytes.count), transient)
            }
        }
        guard status == SQLITE_OK else { throw CollectorOpenCodeSourceError.unavailable }
    }

    private static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) throws {
        let status = value.utf8CString.withUnsafeBufferPointer { buffer in
            sqlite3_bind_text(statement, index, buffer.baseAddress, Int32(value.utf8.count), transient)
        }
        guard status == SQLITE_OK else { throw CollectorOpenCodeSourceError.unavailable }
    }

    private static func addNativePayload(_ row: Row, columns: [Column], payload: inout Int64) throws {
        guard let index = columns.firstIndex(where: { $0.name == "data" }) else { return }
        let next = payload.addingReportingOverflow(Int64(row[index].byteCount))
        guard !next.overflow else { throw CollectorOpenCodeSourceError.exceededBudget }
        payload = next.partialValue
    }

    private static func accumulate(_ extra: Int64, into total: inout Int64, budget: Budget) throws {
        let next = total.addingReportingOverflow(extra)
        guard !next.overflow, extra >= 0, next.partialValue <= budget.maximumByteCount else {
            throw CollectorOpenCodeSourceError.exceededBudget
        }
        total = next.partialValue
    }

    private static func consumeRow(_ count: Int, budget: Budget, rows: inout Int) throws {
        let next = rows.addingReportingOverflow(count)
        guard !next.overflow, next.partialValue <= budget.maximumRows else {
            throw CollectorOpenCodeSourceError.exceededBudget
        }
        rows = next.partialValue
    }

    private static func cell(_ row: Row, _ name: String, columns: [Column]) -> Cell? {
        guard let index = columns.firstIndex(where: { $0.name == name }) else { return nil }
        return row[index]
    }

    private static func text(_ row: Row, _ name: String, columns: [Column]) -> String? {
        cell(row, name, columns: columns)?.text
    }

    private static func open(
        _ path: String, flags: Int32, progress: ProgressState, lengthLimit: Int64
    ) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw CollectorOpenCodeSourceError.unavailable
        }
        sqlite3_busy_timeout(handle, 500)
        let capped = Int32(clamping: min(max(lengthLimit, 0), Int64(Int32.max)))
        _ = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, capped)
        installProgress(handle, progress)
        return handle
    }

    private static func close(_ handle: OpaquePointer) {
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close(handle)
    }

    private static func installProgress(_ handle: OpaquePointer, _ progress: ProgressState) {
        let pointer = Unmanaged.passUnretained(progress).toOpaque()
        sqlite3_progress_handler(handle, 1, { context in
            guard let context else { return 1 }
            return Unmanaged<ProgressState>.fromOpaque(context).takeUnretainedValue().tick()
        }, pointer)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw interruptOrUnavailable(db)
        }
        return statement
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw interruptOrUnavailable(db) }
    }

    private static func step(_ statement: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(statement)
        if status == SQLITE_TOOBIG { throw CollectorOpenCodeSourceError.exceededBudget }
        if status == SQLITE_INTERRUPT || status == SQLITE_ERROR {
            throw interruptOrUnavailable(sqlite3_db_handle(statement))
        }
        return status
    }

    private static func interruptOrUnavailable(_ db: OpaquePointer?) -> Error {
        if Task.isCancelled { return CancellationError() }
        if let db {
            let code = sqlite3_errcode(db)
            if code == SQLITE_INTERRUPT { return CollectorOpenCodeSourceError.exceededBudget }
            if code == SQLITE_TOOBIG { return CollectorOpenCodeSourceError.exceededBudget }
        }
        return CollectorOpenCodeSourceError.unavailable
    }

    private static func quote(_ name: String) throws -> String {
        guard !name.isEmpty, !name.utf8.contains(0) else { throw CollectorOpenCodeSourceError.unsupportedSchema }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func validateSessionID(_ value: String) throws {
        guard (1...256).contains(value.utf8.count), !value.utf8.contains(0),
              !value.contains("/"), value != ".", value != ".." else {
            throw CollectorOpenCodeSourceError.invalidSession
        }
    }

    private static func validateBudget(_ budget: Budget) throws {
        guard budget.maximumByteCount >= 0, budget.maximumRows >= 0, budget.maximumSQLiteSteps >= 0,
              budget.maximumSnapshotByteCount >= 0, budget.maximumCopyByteCount >= 0,
              budget.maximumLeaseMilliseconds >= 0 else {
            throw CollectorOpenCodeSourceError.exceededBudget
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class OpenCodeSnapshotLeaseState {
    let budget: CollectorOpenCodeSource.Budget
    let testHooks: CollectorOpenCodeSource.TestHooks
    let clock: LeaseClock
    let databaseGeneration: ArchiveSourceGeneration
    let walGeneration: ArchiveSourceGeneration?
    var handle: OpaquePointer?
    var closed = false
    let progress: ProgressState

    init(
        budget: CollectorOpenCodeSource.Budget, testHooks: CollectorOpenCodeSource.TestHooks,
        clock: LeaseClock, databaseGeneration: ArchiveSourceGeneration,
        walGeneration: ArchiveSourceGeneration?
    ) {
        self.budget = budget
        self.testHooks = testHooks
        self.clock = clock
        self.databaseGeneration = databaseGeneration
        self.walGeneration = walGeneration
        self.progress = ProgressState(maximum: budget.maximumSQLiteSteps, clock: clock)
    }

    func requireActive() throws {
        guard !closed, handle != nil else { throw CollectorOpenCodeSourceError.unavailable }
        try clock.check()
    }

    func invalidate() {
        closed = true
        if let handle {
            sqlite3_progress_handler(handle, 0, nil, nil)
            sqlite3_close(handle)
            self.handle = nil
        }
    }
}

private struct Column {
    let table: String
    let name: String
    let primaryKey: Int32
}

private extension [Column] {
    var table: String { self[0].table }
}

private enum Cell {
    case null
    case integer(Int64)
    case real(Double)
    case text(Data)
    case blob(Data)

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var text: String? {
        switch self {
        case .text(let bytes): return String(data: bytes, encoding: .utf8)
        default: return nil
        }
    }

    var byteCount: Int {
        switch self {
        case .text(let bytes), .blob(let bytes): return bytes.count
        default: return 0
        }
    }
}

private typealias Row = [Cell]

private struct SessionRow {
    let cells: Row
    let cwd: String
}

private final class LeaseClock {
    let deadline: UInt64

    init(milliseconds: Int) throws {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now != 0 else { throw CollectorOpenCodeSourceError.unavailable }
        let add = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        let sum = now.addingReportingOverflow(add.partialValue)
        guard !add.overflow, !sum.overflow else { throw CollectorOpenCodeSourceError.exceededBudget }
        deadline = sum.partialValue
    }

    var expired: Bool {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline
    }

    func check() throws {
        try Task.checkCancellation()
        if expired { throw CollectorOpenCodeSourceError.exceededBudget }
    }
}

private final class ProgressState {
    var count = 0
    let maximum: Int
    let clock: LeaseClock?

    init(maximum: Int, clock: LeaseClock? = nil) {
        self.maximum = maximum
        self.clock = clock
    }

    func tick() -> Int32 {
        if Task.isCancelled { return 1 }
        if clock?.expired == true { return 1 }
        if count >= maximum { return 1 }
        count += 1
        return 0
    }
}
