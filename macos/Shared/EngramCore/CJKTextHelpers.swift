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
