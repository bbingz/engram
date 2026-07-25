import Foundation

enum MCPInsightsTool {
    /// Minimum calendar-day span required before projecting a monthly pace.
    /// Shorter windows amplify noise (row 3).
    static let minimumProjectionWindowDays = 3

    static func result(database: MCPDatabase, since: String?) throws -> OrderedJSONValue {
        let now = contextNow()
        let effectiveSince = since ?? iso8601String(daysAgo: 7, from: now)

        let windowDays: Int
        let windowParseFailed: Bool
        if let sinceDate = parseISO8601(effectiveSince) {
            windowDays = max(calendarDayCount(from: sinceDate, to: now), 0)
            windowParseFailed = false
        } else {
            windowDays = 0
            windowParseFailed = true
        }

        let totalSpent = try database.totalCostSince(effectiveSince)
        let topModels = try database.topCostGroupsSince(effectiveSince, groupBy: "model", limit: 3)
        let topSources = try database.topCostGroupsSince(effectiveSince, groupBy: "source", limit: 3)

        let projected: Double?
        if windowParseFailed {
            projected = nil
        } else if windowDays >= minimumProjectionWindowDays {
            projected = (totalSpent / Double(windowDays)) * 30.0
        } else {
            projected = nil
        }

        var suggestions: [String] = []
        if let top = topModels.first, totalSpent > 0 {
            let share = top.cost / totalSpent * 100
            if share >= 50 {
                suggestions.append("Model concentration: \(top.key) accounts for \(percent(share)) of spend; review whether lower-cost models are acceptable for routine review or summarization tasks.")
            }
        }
        if let top = topSources.first, totalSpent > 0 {
            let share = top.cost / totalSpent * 100
            if share >= 50 {
                suggestions.append("Provider concentration: \(top.key) accounts for \(percent(share)) of spend; compare equivalent work across providers before scaling repeated workflows.")
            }
        }
        // Only emit the $50 pace advice when we have an honest projection.
        if let projectedMonthly = projected, projectedMonthly > 50 {
            suggestions.append("Monthly pace: current \(windowDays)-day spend projects to \(currency(projectedMonthly)); set a weekly review threshold before long-running multi-agent work.")
        }
        if suggestions.isEmpty {
            suggestions.append("No high-confidence optimization suggestions from current spend distribution.")
        }

        let periodSummary: String
        if let projectedMonthly = projected {
            // Non-withhold line stays byte-identical to the pre-fix format so the
            // empty-costs golden keeps matching (only the $Y number moves).
            periodSummary = "**Period summary:** Spent \(currency(totalSpent)) · Projected monthly \(currency(projectedMonthly))"
        } else if windowParseFailed {
            periodSummary = "**Period summary:** Spent \(currency(totalSpent)) · Projected monthly: withheld (could not parse `since`)"
        } else {
            periodSummary = "**Period summary:** Spent \(currency(totalSpent)) over \(windowDays) day(s) · Projected monthly: withheld (window under 3 days — too short to project)"
        }

        let text = ([
            "## Cost Insights",
            "",
            periodSummary,
            "",
            "### Suggestions",
        ] + suggestions.map { "- \($0)" }).joined(separator: "\n")

        return .object([
            ("content", .array([
                .object([
                    ("type", .string("text")),
                    ("text", .string(text)),
                ]),
            ])),
        ])
    }

    /// Calendar-day span from `from` to `to` in UTC gregorian.
    /// Time zone is fixed to UTC so window length matches ISO-8601 `since`
    /// strings (also formatted in UTC) and does not drift with device locale.
    static func calendarDayCount(from: Date, to: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

private func currency(_ value: Double) -> String {
    "$" + String(format: "%.2f", value)
}

private func percent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

private func iso8601String(daysAgo days: Int, from now: Date) -> String {
    let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) ?? now
    return iso8601String(date)
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func parseISO8601(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    return formatter.date(from: raw) ?? fallback.date(from: raw)
}
