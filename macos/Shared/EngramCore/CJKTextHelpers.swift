import Foundation

/// FTS search text helpers shared between the app's `DatabaseManager`
/// (Engram target, via the `Shared` source path) and the service's
/// `SQLiteEngramServiceReadProvider` (EngramCoreRead, via `Shared/EngramCore`).
/// Both compile this one source, so the offline and online search paths can no
/// longer drift apart with verbatim copies.
public enum CJKText {
    /// The SQLite trigram tokenizer windows on bytes, so CJK/Hangul (multi-byte)
    /// produces cross-character garbage trigrams. Detect these scripts so the
    /// caller can fall back to LIKE substring matching.
    public static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x2E80...0x9FFF).contains(s.value) ||
            (0xF900...0xFAFF).contains(s.value) ||
            (0xFE30...0xFE4F).contains(s.value) ||
            (0x1100...0x11FF).contains(s.value) ||   // Hangul Jamo
            (0xAC00...0xD7FF).contains(s.value)      // Hangul Syllables + Jamo Ext-B
        }
    }

    /// Escape `\`, `%`, `_` for use with `LIKE ? ESCAPE '\'`.
    public static func escapeLikePattern(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for ch in value {
            if ch == "\\" || ch == "%" || ch == "_" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    /// Build a safe FTS5 MATCH string from raw user input: each whitespace token
    /// is wrapped in a double-quoted phrase (internal quotes doubled), so FTS5
    /// special characters (`"`, `(`, `*`, `:`, `^`, `-`, `OR`/`AND`/`NEAR` …) are
    /// matched literally instead of parsed as query syntax (which throws). Tokens
    /// are space-joined, preserving multi-word implicit-AND semantics.
    public static func ftsMatchQuery(_ raw: String) -> String {
        let tokens = ftsMatchTerms(raw)
        guard !tokens.isEmpty else { return "\"\"" }
        return tokens.joined(separator: " ")
    }

    public static func ftsMatchTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    }

    /// Terms that can participate in the shipped trigram/LIKE search plan.
    /// A one-character Latin term has neither a useful trigram nor an acceptably
    /// selective LIKE fallback, so omit it while preserving the remaining
    /// implicit-AND terms. CJK remains searchable at any length.
    public static func searchableTerms(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { containsCJK($0) || $0.count >= 2 }
    }

    public static func ftsMatchTerms(_ rawTokens: [String]) -> [String] {
        rawTokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    }

    /// FTS5 trigram cannot represent one-character Latin terms, and LIKE on
    /// those terms causes severe substring over-recall. CJK stays eligible at
    /// any length; two-character Latin terms keep the existing LIKE fallback.
    public static func hasUnsupportedLatinToken(_ raw: String) -> Bool {
        raw.split(whereSeparator: { $0.isWhitespace }).contains { token in
            !containsCJK(String(token)) && token.count < 2
        }
    }

    /// Build a match-centered, `<mark>`-highlighted preview for the CJK/LIKE
    /// search path, where FTS5 `snippet()` is unavailable (LIKE is not a MATCH
    /// query). Windows `content` around the first case-insensitive occurrence of
    /// `query` and wraps every occurrence within that window in `<mark>…</mark>`.
    /// Returns nil when the query is empty or not found, so the caller falls back
    /// to the plain content.
    public static func cjkHighlightedSnippet(content: String, query: String, window: Int = 40) -> String? {
        guard !query.isEmpty,
              let first = content.range(of: query, options: .caseInsensitive) else {
            return nil
        }
        let lower = content.index(first.lowerBound, offsetBy: -window, limitedBy: content.startIndex)
            ?? content.startIndex
        let upper = content.index(first.upperBound, offsetBy: window, limitedBy: content.endIndex)
            ?? content.endIndex
        var highlighted = ""
        var rest = content[lower..<upper]
        while let match = rest.range(of: query, options: .caseInsensitive) {
            highlighted += rest[..<match.lowerBound]
            highlighted += "<mark>"
            highlighted += rest[match]
            highlighted += "</mark>"
            rest = rest[match.upperBound...]
        }
        highlighted += rest
        let prefixEllipsis = lower > content.startIndex ? "…" : ""
        let suffixEllipsis = upper < content.endIndex ? "…" : ""
        return prefixEllipsis + highlighted + suffixEllipsis
    }

    /// Highlight the complete mixed query when it appears contiguously, then
    /// fall back to individual terms. Shared by service and offline app search.
    public static func highlightedSnippet(content: String, query: String) -> String? {
        let content = removingHighlightMarks(from: content)
        if let exact = cjkHighlightedSnippet(content: content, query: query) {
            return exact
        }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var windows: [Range<String.Index>] = terms.compactMap { term in
            guard let hit = content.range(of: term, options: .caseInsensitive) else { return nil }
            let lower = content.index(hit.lowerBound, offsetBy: -40, limitedBy: content.startIndex)
                ?? content.startIndex
            let upper = content.index(hit.upperBound, offsetBy: 40, limitedBy: content.endIndex)
                ?? content.endIndex
            return lower..<upper
        }.sorted { $0.lowerBound < $1.lowerBound }
        guard !windows.isEmpty else { return nil }

        var merged: [Range<String.Index>] = []
        for window in windows {
            if let last = merged.last, window.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, window.upperBound)
            } else {
                merged.append(window)
            }
        }
        windows.removeAll(keepingCapacity: false)

        return merged.map { window in
            let prefix = window.lowerBound > content.startIndex ? "…" : ""
            let suffix = window.upperBound < content.endIndex ? "…" : ""
            return prefix + highlightTerms(in: content[window], terms: terms) + suffix
        }.joined(separator: " … ")
    }

    private static func highlightTerms(in content: Substring, terms: [String]) -> String {
        var output = ""
        var rest = content
        while !rest.isEmpty {
            let next = terms.compactMap { term in
                rest.range(of: term, options: .caseInsensitive).map { (range: $0, term: term) }
            }.min {
                if $0.range.lowerBound == $1.range.lowerBound {
                    return $0.term.count > $1.term.count
                }
                return $0.range.lowerBound < $1.range.lowerBound
            }
            guard let next else {
                output += rest
                break
            }
            output += rest[..<next.range.lowerBound]
            output += "<mark>" + rest[next.range] + "</mark>"
            rest = rest[next.range.upperBound...]
        }
        return output
    }

    public static func removingHighlightMarks(from content: String) -> String {
        content
            .replacingOccurrences(of: "<mark>", with: "")
            .replacingOccurrences(of: "</mark>", with: "")
    }
}

/// SQLite tuning constants shared between the app read pool
/// (`DatabaseManager.openReadOnlyPool`) and the service connection policy
/// (`SQLiteConnectionPolicy`) so the two cannot silently drift.
public enum SharedDBConfig {
    /// Per-connection page cache in KiB (used with the negative `cache_size`
    /// convention: `PRAGMA cache_size = -cacheSizeKiB`). ~16 MiB keeps hot FTS
    /// b-tree pages resident across queries on the hundreds-of-MB index DB.
    public static let cacheSizeKiB = 16_000
}
