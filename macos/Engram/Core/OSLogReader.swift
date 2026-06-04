// macos/Engram/Core/OSLogReader.swift
//
// OBS-C1 fix: the Observability views used to read the `logs`/`traces`/`metrics`
// SQLite tables, but the Swift runtime never writes those tables — it logs only
// through os_log (subsystems `com.engram.app` and `com.engram.service`). The
// panels therefore showed a perpetual "all clear" even during a real incident.
//
// This reader repoints those panels at the unified system log via
// `OSLogStore(scope: .currentProcessIdentifier)`, filtered to Engram's two
// subsystems. It surfaces what the runtime actually emits today. If the store
// cannot be opened, callers receive `OSLogReaderError.unavailable` so the UI can
// mark the panel "not available" instead of rendering a false all-clear.
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

    /// Map an `OSLogEntryLog.Level` to the textual level the UI filters on.
    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "info"
        case .error: return "warn"
        case .fault: return "error"
        case .undefined: return "info"
        @unknown default: return "info"
        }
    }

    private static func makeStore() throws -> OSLogStore {
        do {
            return try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            throw OSLogReaderError.unavailable(error.localizedDescription)
        }
    }

    /// Fetch recent Engram log entries (most recent last), optionally filtered by
    /// level ("All"/debug/info/warn/error) and module/category ("All" or category).
    static func recentLogs(
        level: String = "All",
        module: String = "All",
        hours: Double = 24,
        limit: Int = 200
    ) throws -> LogQueryResult {
        let store = try makeStore()
        let since = store.position(date: Date().addingTimeInterval(-hours * 3600))
        let predicate = NSPredicate(format: "subsystem IN %@", Array(engramSubsystems))
        let entries = try store.getEntries(at: since, matching: predicate)

        var result: [LogEntry] = []
        var modules = Set<String>()
        var nextId: Int64 = 0
        for entry in entries {
            guard let log = entry as? OSLogEntryLog,
                  engramSubsystems.contains(log.subsystem) else { continue }
            let lvl = levelString(log.level)
            let cat = log.category.isEmpty ? log.subsystem : log.category
            modules.insert(cat)
            if level != "All" && lvl != level { continue }
            if module != "All" && cat != module { continue }
            nextId += 1
            result.append(
                LogEntry(
                    id: nextId,
                    ts: ISO8601DateFormatter().string(from: log.date),
                    level: lvl,
                    module: cat,
                    message: log.composedMessage,
                    traceId: nil,
                    source: log.subsystem,
                    errorName: nil,
                    errorMessage: nil
                )
            )
        }
        // Keep most recent `limit` (entries arrive oldest→newest).
        if result.count > limit {
            result = Array(result.suffix(limit))
        }
        return LogQueryResult(entries: result, modules: modules.sorted())
    }

    /// Count error-level entries in the trailing window.
    static func countErrors(hours: Double = 24) throws -> Int {
        try recentLogs(level: "error", hours: hours, limit: Int.max).entries.count
    }

    /// Error counts grouped by module/category over the trailing window.
    static func errorsByModule(hours: Double = 24) throws -> [(module: String, count: Int)] {
        let errors = try recentLogs(level: "error", hours: hours, limit: Int.max).entries
        let grouped = Dictionary(grouping: errors, by: \.module).mapValues(\.count)
        return grouped.sorted { $0.value > $1.value }.map { (module: $0.key, count: $0.value) }
    }
}
