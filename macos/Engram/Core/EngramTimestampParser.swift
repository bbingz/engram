import Foundation

enum EngramTimestampParser {
    private static let lock = NSLock()

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISOFormatter = ISO8601DateFormatter()

    private static let sqliteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func date(from value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let normalized = normalizedISOFraction(raw)
        lock.lock()
        defer { lock.unlock() }
        return fractionalISOFormatter.date(from: normalized)
            ?? plainISOFormatter.date(from: raw)
            ?? sqliteFormatter.date(from: raw)
    }

    static func isoString(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return plainISOFormatter.string(from: date)
    }

    static func localDateKey(from value: String, calendar: Calendar = .current) -> String {
        guard let date = date(from: value) else {
            return String(value.prefix(10))
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return String(value.prefix(10))
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func normalizedISOFraction(_ value: String) -> String {
        guard let dotIndex = value.firstIndex(of: ".") else { return value }
        let suffixStart = value.index(after: dotIndex)
        var cursor = suffixStart
        while cursor < value.endIndex, value[cursor].isNumber {
            cursor = value.index(after: cursor)
        }
        let fraction = value[suffixStart..<cursor]
        guard fraction.count > 3 else { return value }
        return String(value[..<suffixStart] + fraction.prefix(3) + value[cursor...])
    }
}
