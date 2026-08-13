import Foundation
import EngramCoreWrite

actor ServiceStatusMonitor {
    private let staleAfter: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSuccessAt: Date?
    private var lastFailure: (message: String, at: Date)?
    /// True after the service socket is listening (Wave 7C L03/S01 smoke).
    private var serviceReady = false
    /// Adaptive next-scan interval (seconds); published on running status.
    private var nextScanIntervalSeconds: Int?
    private let lastScanFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(staleAfter: TimeInterval = 10 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.staleAfter = staleAfter
        self.now = now
    }

    func recordServiceReady() {
        serviceReady = true
    }

    func recordSchedule(nextScanIntervalSeconds: Int) {
        self.nextScanIntervalSeconds = nextScanIntervalSeconds
    }

    func recordScanSuccess(at date: Date? = nil) {
        lastSuccessAt = date ?? now()
    }

    func recordScanFailure(_ message: String, at date: Date? = nil) {
        lastFailure = (message: message, at: date ?? now())
    }

    func status(indexStatus: EngramDatabaseIndexStatus) -> EngramServiceStatus {
        if let lastFailure, lastSuccessAt.map({ lastFailure.at >= $0 }) ?? true {
            return .degraded(message: "Last index scan failed: \(lastFailure.message)")
        }

        if let lastSuccessAt {
            let age = now().timeIntervalSince(lastSuccessAt)
            let effectiveStaleAfter = max(
                staleAfter,
                TimeInterval(nextScanIntervalSeconds ?? 0) * 2
            )
            if age > effectiveStaleAfter {
                return .degraded(message: "Last successful index scan is stale (\(Int(age))s old)")
            }
            return .running(
                total: indexStatus.total,
                todayParents: indexStatus.todayParents,
                nextScanIntervalSeconds: nextScanIntervalSeconds,
                lastScanAt: lastScanFormatter.string(from: lastSuccessAt)
            )
        }

        // After socket readiness, do not stay stuck on bare "starting" forever
        // while the initial scan is still in flight — expose schedule when known.
        // R2.P2.premature_today_parents_status: do not publish parent KPI from a
        // pre-backfill index snapshot; zero until the first successful scan.
        if serviceReady {
            return .running(
                total: indexStatus.total,
                todayParents: 0,
                nextScanIntervalSeconds: nextScanIntervalSeconds
            )
        }

        return .starting
    }
}
