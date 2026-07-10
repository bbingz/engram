import Foundation

/// Single source of truth for the 5-factor `sessions.quality_score` formula
/// (turn ratio / tool / density / project / volume). Used by incremental
/// snapshot indexing and startup score backfill — must stay bit-identical.
public enum SessionQualityScore {
    /// Bump when the formula changes so startup can recompute non-zero scores.
    public static let formulaVersion = "1"
    public static let formulaVersionMetadataKey = "quality_score_formula_version"

    public static func compute(
        userCount: Int,
        assistantCount: Int,
        toolCount: Int,
        systemCount: Int,
        startTime: String?,
        endTime: String?,
        project: String?
    ) -> Int {
        let total = userCount + assistantCount + toolCount + systemCount
        var turnScore = 0.0
        if userCount > 0, assistantCount > 0, total > 0 {
            turnScore = min(30, (Double(min(userCount, assistantCount)) / Double(total)) * 30)
        }

        var toolScore = 0.0
        if assistantCount > 0 {
            toolScore = min(25, (Double(toolCount) / Double(assistantCount)) * 50)
        }

        let duration = durationMinutes(startTime: startTime, endTime: endTime)
        let densityScore: Double
        if duration < 1 {
            densityScore = 0
        } else if duration <= 5 {
            densityScore = (duration / 5) * 20
        } else if duration <= 60 {
            densityScore = 20
        } else if duration <= 180 {
            densityScore = 20 - ((duration - 60) / 120) * 10
        } else {
            densityScore = 10
        }

        let projectScore = project == nil ? 0.0 : 15.0
        let volumeScore = min(10, Double(userCount + assistantCount + toolCount) / 5)
        return max(0, min(100, Int((turnScore + toolScore + densityScore + projectScore + volumeScore).rounded())))
    }

    private static func durationMinutes(startTime: String?, endTime: String?) -> Double {
        guard let startTime,
              let endTime,
              let start = parseDate(startTime),
              let end = parseDate(endTime)
        else {
            return 0
        }
        return end.timeIntervalSince(start) / 60
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
