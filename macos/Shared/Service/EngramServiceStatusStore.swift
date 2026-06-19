import Foundation
import Observation

enum UsagePressureSeverity: Int, Equatable, Sendable {
    case attention = 1
    case critical = 2
}

struct UsagePressureSummary: Equatable, Sendable {
    let severity: UsagePressureSeverity
    let identity: String
    let message: String

    init(severity: UsagePressureSeverity, identity: String? = nil, message: String) {
        self.severity = severity
        self.message = message
        self.identity = identity ?? message
    }
}

private struct UsagePressureCandidate: Sendable {
    let summary: UsagePressureSummary
    let score: Double
    let windowPriority: Int
}

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

    var usagePressureSummary: UsagePressureSummary? {
        usageData.compactMap(Self.pressureSummaryCandidate).max(by: Self.isLowerPriorityUsage)?.summary
    }

    func apply(_ newStatus: EngramServiceStatus) {
        lastEventAt = Date()
        // The health monitor calls this every ~5s with the SAME value at idle.
        // @Observable fires observers on every assignment regardless of equality,
        // so unguarded writes re-trigger the always-on menu-bar observers (NSImage
        // rebuild + badge refresh) 12x/min for no change. Only write on a real
        // change so the idle status poll becomes free. (lastEventAt has no
        // observers, so its unconditional update costs nothing.)
        if status != newStatus { status = newStatus }
        if case .running(let total, let todayParents) = newStatus {
            if totalSessions != total { totalSessions = total }
            if todayParentSessions != todayParents { todayParentSessions = todayParents }
        }
    }

    func apply(_ event: EngramServiceEvent) {
        lastEventAt = Date()

        switch event.event {
        case "starting":
            status = .starting
        case "ready", "indexed", "rescan", "sync_complete", "watcher_indexed":
            applyTotals(from: event)
        case "web_ready":
            endpointHost = event.host
            endpointPort = event.port
        case "web_error":
            endpointHost = nil
            endpointPort = nil
            status = .degraded(message: "Web UI unavailable: \(event.message ?? "Unknown error")")
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

    func apply(_ response: EngramServiceRefreshUsageResponse) {
        lastEventAt = Date()
        let refreshedSources = Set((response.sources + response.pressure.map(\.source))
            .map(Self.normalizedToken)
            .filter { !$0.isEmpty })
        usageData = usageData.filter { item in
            guard Self.pressureSummaryCandidate(item) != nil else { return true }
            return !refreshedSources.contains(Self.normalizedToken(item.source))
        } + response.pressure
    }

    private func applyTotals(from event: EngramServiceEvent) {
        if let total = event.total, totalSessions != total {
            totalSessions = total
        }
        if let todayParents = event.todayParents, todayParentSessions != todayParents {
            todayParentSessions = todayParents
        }
        let newStatus = EngramServiceStatus.running(total: totalSessions, todayParents: todayParentSessions)
        if status != newStatus { status = newStatus }
    }

    private static func pressureSummaryCandidate(_ item: EngramServiceUsageItem) -> UsagePressureCandidate? {
        guard let severity = pressureSeverity(item.status) else { return nil }
        let status = normalizedUsageStatus(item.status) ?? "attention"
        let resetSuffix = item.resetAt.map { " · resets \(formattedResetAt($0))" } ?? ""
        let summary = UsagePressureSummary(
            severity: severity,
            identity: pressureIdentity(item),
            message: "Usage \(status): \(sourceLabel(item.source)) \(item.metric) \(formattedPressureValue(item))\(resetSuffix)"
        )
        return UsagePressureCandidate(
            summary: summary,
            score: pressureScore(item),
            windowPriority: windowPriority(item.metric)
        )
    }

    private static func isLowerPriorityUsage(_ lhs: UsagePressureCandidate, _ rhs: UsagePressureCandidate) -> Bool {
        if lhs.summary.severity != rhs.summary.severity {
            return lhs.summary.severity.rawValue < rhs.summary.severity.rawValue
        }
        if lhs.score != rhs.score {
            return lhs.score < rhs.score
        }
        if lhs.windowPriority != rhs.windowPriority {
            return lhs.windowPriority < rhs.windowPriority
        }
        return lhs.summary.message > rhs.summary.message
    }

    private static func pressureScore(_ item: EngramServiceUsageItem) -> Double {
        let metric = item.metric.lowercased()
        let value: Double
        if let limit = item.limit, limit > 0, item.unit != "%" {
            value = item.value / limit * 100
        } else {
            value = item.value
        }
        return metric.contains("remaining") ? 100 - value : value
    }

    private static func windowPriority(_ metric: String) -> Int {
        let metric = metric.lowercased()
        if metric.contains("5h") { return 2 }
        if metric.contains("weekly") || metric.contains("7d") { return 1 }
        return 0
    }

    private static func pressureSeverity(_ status: String?) -> UsagePressureSeverity? {
        switch normalizedUsageStatus(status) {
        case "critical":
            return .critical
        case "attention":
            return .attention
        default:
            return nil
        }
    }

    private static func normalizedUsageStatus(_ status: String?) -> String? {
        guard let status else { return nil }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func pressureIdentity(_ item: EngramServiceUsageItem) -> String {
        "\(normalizedToken(item.source)):\(normalizedToken(item.metric))"
    }

    private static func normalizedToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sourceLabel(_ source: String) -> String {
        let normalizedSource = normalizedToken(source)
        switch normalizedSource {
        case "claude-code": return "Claude Code"
        case "gemini-cli": return "Gemini"
        case "opencode": return "OpenCode"
        case "commandcode": return "Command Code"
        case "lobsterai": return "Lobster AI"
        case "vscode": return "VS Code"
        default:
            return normalizedSource
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func formattedUsageValue(_ value: Double, unit: String?, limit: Double? = nil) -> String {
        if let limit {
            return "\(String(format: "%.1f", value))/\(String(format: "%.1f", limit))\(unit ?? "")"
        }
        let rounded = value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
        switch unit {
        case "%", nil:
            return "\(rounded)%"
        case "tokens":
            return "\(rounded) tokens"
        case let unit?:
            return "\(rounded)\(unit)"
        }
    }

    private static func formattedPressureValue(_ item: EngramServiceUsageItem) -> String {
        let base = formattedUsageValue(item.value, unit: item.unit, limit: item.limit)
        guard isPercentUnit(item.unit),
              item.limit == nil,
              item.metric.lowercased().contains("remaining")
        else {
            return base
        }
        let used = min(100, max(0, 100 - item.value))
        return "\(base) (\(formattedUsageValue(used, unit: "%")) used)"
    }

    private static func isPercentUnit(_ unit: String?) -> Bool {
        unit == nil || unit == "%"
    }

    private static func formattedResetAt(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]

        guard let date = fractional.date(from: trimmed) ?? wholeSeconds.date(from: trimmed) else {
            return trimmed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }
}
