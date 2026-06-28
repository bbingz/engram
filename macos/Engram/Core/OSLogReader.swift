// macos/Engram/Core/OSLogReader.swift
//
// OBS-C1 fix: the Observability views used to read the `logs`/`traces`/`metrics`
// SQLite tables, but the Swift runtime never writes those tables — it logs only
// through os_log (subsystems `com.engram.app` and `com.engram.service`). The
// panels therefore showed a perpetual "all clear" even during a real incident.
//
// This reader repoints those panels at the unified system log via
// `OSLogStore(scope: .system)` when available, filtered to Engram's two
// subsystems. If system-scope access is denied, it falls back to the current
// process store; if neither store can be opened, callers receive
// `OSLogReaderError.unavailable` so the UI can mark the panel "not available"
// instead of rendering a false all-clear.
import Foundation
import OSLog

enum OSLogReaderError: Error {
    /// `OSLogStore(scope: .currentProcessIdentifier)` is not accessible.
    case unavailable(String)
}

/// Reads Engram's own os_log entries from the unified log store.
///
/// All methods are blocking (`OSLogStore` enumeration is synchronous) and must be
/// called off the main thread — callers wrap them in `Task.detached`.
enum OSLogReader {
    static let engramSubsystems: Set<String> = ["com.engram.app", "com.engram.service"]
    private static let maxRecentLogEntries = 5_000

    /// Map an `OSLogEntryLog.Level` to the textual level the UI filters on.
    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "info"
        case .error: return "error"
        case .fault: return "error"
        case .undefined: return "info"
        @unknown default: return "info"
        }
    }

    private static func makeStore() throws -> OSLogStore {
        do {
            return try OSLogStore(scope: .system)
        } catch {
            do {
                return try OSLogStore(scope: .currentProcessIdentifier)
            } catch {
                throw OSLogReaderError.unavailable(error.localizedDescription)
            }
        }
    }

    private static func forEachEngramLog(hours: Double, _ body: (OSLogEntryLog) throws -> Void) throws {
        let store = try makeStore()
        let since = store.position(date: Date().addingTimeInterval(-hours * 3600))
        let predicate = NSPredicate(format: "subsystem IN %@", Array(engramSubsystems))
        let entries = try store.getEntries(at: since, matching: predicate)

        for entry in entries {
            guard let log = entry as? OSLogEntryLog,
                  engramSubsystems.contains(log.subsystem)
            else { continue }
            try body(log)
        }
    }

    /// Fetch recent Engram log entries (most recent last), optionally filtered by
    /// level ("All"/debug/info/error) and module/category ("All" or category).
    ///
    /// observability-4: there is intentionally no "warn" level. macOS unified
    /// logging stores os_log .warning at the .error log type, so `levelString`
    /// maps it to "error" and never returns "warn". A "warn" filter would always
    /// yield 0 rows, so callers must not offer it; warning-level entries surface
    /// under the "error" filter and are counted in the 24h error totals.
    static func recentLogs(
        level: String = "All",
        module: String = "All",
        hours: Double = 24,
        limit: Int = 200
    ) throws -> LogQueryResult {
        let safeLimit = min(max(limit, 0), maxRecentLogEntries)
        var result: [LogEntry] = []
        result.reserveCapacity(safeLimit)
        var modules = Set<String>()
        var nextId: Int64 = 0
        let timestampFormatter = ISO8601DateFormatter()
        try forEachEngramLog(hours: hours) { log in
            let lvl = levelString(log.level)
            let cat = log.category.isEmpty ? log.subsystem : log.category
            modules.insert(cat)
            guard level == "All" || lvl == level else { return }
            guard module == "All" || cat == module else { return }
            nextId += 1
            let entry = LogEntry(
                id: nextId,
                ts: timestampFormatter.string(from: log.date),
                level: lvl,
                module: cat,
                message: log.composedMessage,
                traceId: nil,
                source: log.subsystem,
                errorName: nil,
                errorMessage: nil
            )
            guard safeLimit > 0 else { return }
            if result.count == safeLimit {
                result.removeFirst()
            }
            result.append(entry)
        }
        return LogQueryResult(entries: result, modules: modules.sorted())
    }

    /// Count error-level entries in the trailing window.
    static func countErrors(hours: Double = 24) throws -> Int {
        var count = 0
        try forEachEngramLog(hours: hours) { log in
            if levelString(log.level) == "error" {
                count += 1
            }
        }
        return count
    }

    /// Error counts grouped by module/category over the trailing window.
    static func errorsByModule(hours: Double = 24) throws -> [(module: String, count: Int)] {
        var grouped: [String: Int] = [:]
        try forEachEngramLog(hours: hours) { log in
            guard levelString(log.level) == "error" else { return }
            let module = log.category.isEmpty ? log.subsystem : log.category
            grouped[module, default: 0] += 1
        }
        return grouped.sorted { $0.value > $1.value }.map { (module: $0.key, count: $0.value) }
    }
}
