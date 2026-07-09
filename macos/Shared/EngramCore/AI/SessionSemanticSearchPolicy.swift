import Foundation

/// Ranking constants shared by MCP session search and
/// `EngramServiceReadProvider` semantic/hybrid search. Keep these values in
/// lockstep — hybrid parity tests assert both call sites use this type.
///
/// Coupling doc: `docs/mcp-semantic-search-design-2026-07.md`.
public enum SessionSemanticSearchPolicy {
    /// Reciprocal Rank Fusion constant (`RankFusion.rrf` default).
    public static let rrfK: Int = 60

    /// Brute-force KNN shortlist size before session collapse.
    public static func knnTopK(limit: Int) -> Int {
        max(limit * 4, limit)
    }

    /// Max `semantic_chunks` rows scanned for a search request.
    public static func candidateCap(requestLimit: Int) -> Int {
        max(200, min(requestLimit * 20, 2_000))
    }

    /// SQL fragment (alias `s` = sessions): searchable tiers only.
    /// `skip` is hidden noise; `lite` is list-visible but FTS/vector-excluded
    /// (match app + service keyword/semantic paths).
    public static let searchableTierSQL =
        "(s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))"
}
