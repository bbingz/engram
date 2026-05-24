import Foundation

enum MCPInsightsTool {
    static func result(database: MCPDatabase, since: String?) throws -> OrderedJSONValue {
        let effectiveSince = since ?? iso8601DaysAgo(7)
        let totalSpent = try database.totalCostSince(effectiveSince)
        let projectedMonthly = (totalSpent / 7.0) * 30.0
        let topModels = try database.topCostGroupsSince(effectiveSince, groupBy: "model", limit: 3)
        let topSources = try database.topCostGroupsSince(effectiveSince, groupBy: "source", limit: 3)

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
        if projectedMonthly > 50 {
            suggestions.append("Monthly pace: current 7-day spend projects to \(currency(projectedMonthly)); set a weekly review threshold before long-running multi-agent work.")
        }
        if suggestions.isEmpty {
            suggestions.append("No high-confidence optimization suggestions from current spend distribution.")
        }

        let text = ([
            "## Cost Insights",
            "",
            "**Period summary:** Spent \(currency(totalSpent)) · Projected monthly \(currency(projectedMonthly))",
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
}

private func currency(_ value: Double) -> String {
    "$" + String(format: "%.2f", value)
}

private func percent(_ value: Double) -> String {
    String(format: "%.0f%%", value)
}

private func iso8601DaysAgo(_ days: Int) -> String {
    let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
