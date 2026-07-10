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
            if age > staleAfter {
                return .degraded(message: "Last successful index scan is stale (\(Int(age))s old)")
            }
            return .running(
                total: indexStatus.total,
                todayParents: indexStatus.todayParents,
                nextScanIntervalSeconds: nextScanIntervalSeconds
            )
        }

        // After socket readiness, do not stay stuck on bare "starting" forever
        // while the initial scan is still in flight — expose schedule when known.
        if serviceReady {
            return .running(
                total: indexStatus.total,
                todayParents: indexStatus.todayParents,
                nextScanIntervalSeconds: nextScanIntervalSeconds
            )
        }

        return .starting
    }
}
