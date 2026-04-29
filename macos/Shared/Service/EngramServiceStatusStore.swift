import Foundation
import Observation

@MainActor
@Observable
final class EngramServiceStatusStore {
    var status: EngramServiceStatus = .stopped
    var totalSessions = 0
    var todayParentSessions = 0
    var lastSummarySessionId: String?
    var usageData: [EngramServiceUsageItem] = []
    var endpointHost: String?
    var endpointPort: Int?
    var embeddingStatus: String?
    var lastEventAt: Date?

    var displayString: String {
        switch status {
        case .stopped:
            return String(localized: "Stopped")
        case .starting:
            return String(localized: "Starting...")
        case .running(let total, _):
            return String(localized: "\(total) sessions indexed")
        case .degraded(let message):
            return String(localized: "Degraded: \(message)")
        case .error(let message):
            return String(localized: "Error: \(message)")
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func apply(_ newStatus: EngramServiceStatus) {
        lastEventAt = Date()
        status = newStatus
        if case .running(let total, let todayParents) = newStatus {
            totalSessions = total
            todayParentSessions = todayParents
        }
    }

    func apply(_ event: EngramServiceEvent) {
        lastEventAt = Date()

        switch event.event {
        case "ready", "indexed", "rescan", "sync_complete", "watcher_indexed":
            applyTotals(from: event)
        case "web_ready":
            endpointHost = event.host
            endpointPort = event.port
        case "summary_generated":
            applyTotals(from: event)
            lastSummarySessionId = event.sessionId
        case "usage":
            usageData = event.usage ?? []
        case "warning":
            status = .degraded(message: event.message ?? "Service warning")
        case "error":
            status = .error(message: event.message ?? "Unknown error")
        default:
            break
        }
    }

    private func applyTotals(from event: EngramServiceEvent) {
        if let total = event.total {
            totalSessions = total
        }
        if let todayParents = event.todayParents {
            todayParentSessions = todayParents
        }
        status = .running(total: totalSessions, todayParents: todayParentSessions)
    }
}
