import Foundation

enum MCPInsightsTool {
    static func result(database: MCPDatabase, since: String?) throws -> OrderedJSONValue {
        let effectiveSince = since ?? iso8601DaysAgo(7)
        let totalSpent = try database.totalCostSince(effectiveSince)
        let projectedMonthly = (totalSpent / 7.0) * 30.0

        let text = [
            "## Cost Insights",
            "",
            "**Period summary:** Spent \(currency(totalSpent)) · Projected monthly \(currency(projectedMonthly))",
            "",
            "No cost optimization suggestions for this period. Spending looks healthy!",
        ].joined(separator: "\n")

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

private func iso8601DaysAgo(_ days: Int) -> String {
    let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
