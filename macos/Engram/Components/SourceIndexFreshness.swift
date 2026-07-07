import Foundation

enum SourceIndexFreshnessState: Equatable {
    case fresh
    case aging
    case stale
    case unknown
}

enum SourceIndexFreshness {
    private static let freshLimit: TimeInterval = 24 * 60 * 60
    private static let agingLimit: TimeInterval = 7 * 24 * 60 * 60

    static func classify(_ latestIndexed: String?, now: Date = Date()) -> SourceIndexFreshnessState {
        guard let age = ageSeconds(latestIndexed, now: now) else { return .unknown }
        if age <= freshLimit { return .fresh }
        if age <= agingLimit { return .aging }
        return .stale
    }

    static func relativeAgeText(_ latestIndexed: String?, now: Date = Date()) -> String {
        guard let age = ageSeconds(latestIndexed, now: now) else { return "Unknown" }
        if age < 60 { return "just now" }
        if age < 60 * 60 { return "\(Int(age / 60))m ago" }
        if age <= freshLimit { return "\(Int(age / (60 * 60)))h ago" }
        return "\(Int(age / (24 * 60 * 60)))d ago"
    }

    private static func ageSeconds(_ latestIndexed: String?, now: Date) -> TimeInterval? {
        guard let indexedAt = parsedSQLiteUTCDate(latestIndexed) else { return nil }
        return max(0, now.timeIntervalSince(indexedAt))
    }

    private static func parsedSQLiteUTCDate(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter.date(from: raw)
    }
}
