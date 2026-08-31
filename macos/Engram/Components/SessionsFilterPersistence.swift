import Foundation

/// Pure mapping for Sessions page filter persistence (`sessions.*` AppStorage keys).
/// Keeps Optional source as an empty-string sentinel and falls back when a stored
/// source is no longer present in the live catalog.
enum SessionsFilterPersistence {
    static let sessionFilterKey = "sessions.sessionFilter"
    static let timeFilterKey = "sessions.timeFilter"
    static let sourceFilterKey = "sessions.sourceFilter"
    /// Wave 6C-1 (design §9): HQ-machine-only filter on the Sessions page.
    /// Plain Bool — AppStorage supplies the default, no sanitizer needed.
    static let hqOnlyKey = "sessions.hqOnly"

    static let sessionOptions = ["All", "Starred"]
    static let timeOptions = ["Today", "This Week", "This Month", "All Time"]

    static func sanitizeSessionFilter(_ raw: String) -> String {
        sessionOptions.contains(raw) ? raw : "All"
    }

    static func sanitizeTimeFilter(_ raw: String) -> String {
        timeOptions.contains(raw) ? raw : "All Time"
    }

    /// Empty / whitespace storage means "All Sources" (nil filter).
    static func optionalSource(from storage: String) -> String? {
        let trimmed = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func storage(from source: String?) -> String {
        source ?? ""
    }

    /// When `available` is non-empty and the stored source is missing from it,
    /// fall back to nil so the page does not show an empty result set.
    /// While `available` is still empty (pre-load), keep the stored preference.
    static func resolvedSource(stored: String, available: [String]) -> String? {
        guard let source = optionalSource(from: stored) else { return nil }
        if available.isEmpty { return source }
        return available.contains(source) ? source : nil
    }

    static func sanitizedSourceStorage(stored: String, available: [String]) -> String {
        storage(from: resolvedSource(stored: stored, available: available))
    }
}
