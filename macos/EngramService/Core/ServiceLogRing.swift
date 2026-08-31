// macos/EngramService/Core/ServiceLogRing.swift
import Foundation

/// In-process, ephemeral ring buffer of SANITIZED service log lines. Mirrors
/// `ServiceTelemetryCollector`: bounded, NOT persisted (resets on every service
/// restart), and summarized through the `serviceLogs` read command. This is the
/// readable counterpart to the `privacy: .private` os_log stream — the os_log
/// line stays private; a sanitized copy is teed here so the gated Observability
/// "Logs" tab has real text instead of `<private>` placeholders.
///
/// Every message is passed through `ServiceLogSanitizer.redact` BEFORE storage,
/// so the buffer never holds a raw path / id / email / error tail. There is no
/// time eviction — only capacity (default 500).
final class ServiceLogRing: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private let coverageStartedAt: String
    private var lines: [ServiceLogLineDTO] = []
    private var errorLines: [ServiceLogLineDTO] = []
    private var nextSequence: UInt64 = 0
    private var linesTruncated = false
    private var errorLinesTruncated = false

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
        self.coverageStartedAt = Self.isoNow()
    }

    /// Record one log line. The message is sanitized here, so callers can pass
    /// the raw (already `.private`-logged) text. Oldest lines are evicted once
    /// capacity is exceeded.
    func record(level: String, category: String, message: String) {
        let timestamp = Self.isoNow()
        let sanitizedMessage = ServiceLogSanitizer.redact(message)
        lock.withLock {
            nextSequence &+= 1
            let line = ServiceLogLineDTO(
                sequence: nextSequence,
                timestamp: timestamp,
                level: level,
                category: category,
                message: sanitizedMessage
            )
            lines.append(line)
            if lines.count > capacity {
                linesTruncated = true
                lines.removeFirst(lines.count - capacity)
            }
            if level == "error" {
                errorLines.append(line)
                if errorLines.count > capacity {
                    errorLinesTruncated = true
                    errorLines.removeFirst(errorLines.count - capacity)
                }
            }
        }
    }

    /// Newest-first snapshot, optionally filtered by level and/or category and
    /// capped at `limit` (nil = capacity).
    func snapshot(level: String? = nil, category: String? = nil, limit: Int? = nil) -> ServiceLogSnapshot {
        lock.withLock {
            let cap = limit.map { max(0, $0) } ?? capacity
            if level == nil {
                let retainedErrors = errorLines.reversed().filter { line in
                    category.map { line.category == $0 } ?? true
                }
                var selected = Array(retainedErrors.prefix(cap))
                if selected.count < cap {
                    for line in lines.reversed() where category.map({ line.category == $0 }) ?? true {
                        guard !selected.contains(line) else { continue }
                        selected.append(line)
                        if selected.count == cap { break }
                    }
                }
                selected.sort { $0.timestamp > $1.timestamp }
                return ServiceLogSnapshot(
                    lines: selected,
                    coverageStartedAt: coverageStartedAt,
                    isTruncated: linesTruncated || errorLinesTruncated
                        || lines.count > cap || errorLines.count > cap
                )
            }
            let source = level == "error" ? errorLines : lines
            let sourceTruncated = level == "error" ? errorLinesTruncated : linesTruncated
            var ordered = source.reversed().filter { line in
                (level.map { line.level == $0 } ?? true) && (category.map { line.category == $0 } ?? true)
            }
            let limitTruncated = ordered.count > cap
            if ordered.count > cap {
                ordered = Array(ordered.prefix(cap))
            }
            return ServiceLogSnapshot(
                lines: Array(ordered),
                coverageStartedAt: coverageStartedAt,
                isTruncated: sourceTruncated || limitTruncated
            )
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
