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
actor ServiceLogRing {
    private let capacity: Int
    private var lines: [ServiceLogLineDTO] = []

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Record one log line. The message is sanitized here, so callers can pass
    /// the raw (already `.private`-logged) text. Oldest lines are evicted once
    /// capacity is exceeded.
    func record(level: String, category: String, message: String) {
        lines.append(
            ServiceLogLineDTO(
                timestamp: Self.isoNow(),
                level: level,
                category: category,
                message: ServiceLogSanitizer.redact(message)
            )
        )
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    /// Newest-first snapshot, optionally filtered by level and/or category and
    /// capped at `limit` (nil = capacity).
    func snapshot(level: String? = nil, category: String? = nil, limit: Int? = nil) -> ServiceLogSnapshot {
        var ordered = lines.reversed().filter { line in
            (level.map { line.level == $0 } ?? true) && (category.map { line.category == $0 } ?? true)
        }
        let cap = limit.map { max(0, $0) } ?? capacity
        if ordered.count > cap {
            ordered = Array(ordered.prefix(cap))
        }
        return ServiceLogSnapshot(lines: Array(ordered))
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
