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

    /// GRDB page size for full-corpus semantic scans.
    ///
    /// This is **not** a recency eligibility cap. Callers must stream every
    /// eligible `semantic_chunks` row in batches of this size and maintain a
    /// constant-memory top-K accumulator (see `accumulateTopK`).
    public static func candidateBatchSize(requestLimit: Int) -> Int {
        max(64, min(max(requestLimit * 20, 200), 512))
    }

    /// SQL fragment (alias `s` = sessions): searchable tiers only.
    /// `skip` is hidden noise; `lite` is list-visible but FTS/vector-excluded
    /// (match app + service keyword/semantic paths).
    public static let searchableTierSQL =
        "(s.tier IS NULL OR s.tier NOT IN ('skip', 'lite'))"

    /// Chunk hit retained while streaming the corpus (id + payload for collapse).
    public struct ScoredChunk: Sendable, Equatable {
        public let id: String
        public let score: Float
        public let sessionId: String
        public let text: String

        public init(id: String, score: Float, sessionId: String, text: String) {
            self.id = id
            self.score = score
            self.sessionId = sessionId
            self.text = text
        }
    }

    /// Insert `incoming` into `top` (highest score first), keeping at most `topK`.
    /// Constant memory: only `topK` entries are retained.
    public static func accumulateTopK(
        _ top: inout [ScoredChunk],
        incoming: ScoredChunk,
        topK: Int
    ) {
        guard topK > 0 else {
            top.removeAll(keepingCapacity: false)
            return
        }
        if top.count < topK {
            top.append(incoming)
            top.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.id < rhs.id
            }
            return
        }
        guard let worst = top.last else { return }
        // Strictly better score replaces the worst; ties keep the existing set
        // (deterministic, avoids thrashing on equal cosine scores).
        guard incoming.score > worst.score else { return }
        top[top.count - 1] = incoming
        top.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id < rhs.id
        }
    }
}
