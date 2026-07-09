import Foundation

/// Shared ISO-8601 relative-time labels (`now` / `5m` / `3h` / `2d` and ago variants).
/// Uses `EngramTimestampParser` so whole-second timestamps do not render blank.
enum RelativeTimeText {
    enum Style {
        case compact
        case ago
        case agoWithSeconds
    }

    static func format(_ iso: String, style: Style = .compact, now: Date = Date()) -> String {
        guard let date = EngramTimestampParser.date(from: iso) else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch style {
        case .compact:
            if seconds < 60 { return "now" }
            if seconds < 3600 { return "\(seconds / 60)m" }
            if seconds < 86400 { return "\(seconds / 3600)h" }
            return "\(seconds / 86400)d"
        case .ago:
            if seconds < 60 { return "now" }
            if seconds < 3600 { return "\(seconds / 60)m ago" }
            if seconds < 86400 { return "\(seconds / 3600)h ago" }
            return "\(seconds / 86400)d ago"
        case .agoWithSeconds:
            if seconds < 1 { return "now" }
            if seconds < 60 { return "\(seconds)s ago" }
            if seconds < 3600 { return "\(seconds / 60)m ago" }
            return "\(seconds / 3600)h ago"
        }
    }
}

enum TodayRelativeTime {
    static func format(_ iso: String, now: Date = Date()) -> String {
        RelativeTimeText.format(iso, style: .ago, now: now)
    }
}
