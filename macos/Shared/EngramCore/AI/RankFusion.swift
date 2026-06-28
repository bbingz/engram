import Foundation

/// Reciprocal Rank Fusion: combine several ranked id lists (e.g. keyword FTS and
/// vector KNN) into one ranking without needing comparable raw scores.
/// `score(id) = Σ 1 / (k + rank)`, rank starting at 1. Ties break by first
/// appearance so the result is deterministic.
public enum RankFusion {
    public static func rrf(_ rankings: [[String]], k: Int = 60) -> [(id: String, score: Double)] {
        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var counter = 0
        for list in rankings {
            for (rank, id) in list.enumerated() {
                if firstSeen[id] == nil {
                    firstSeen[id] = counter
                    counter += 1
                }
                scores[id, default: 0] += 1.0 / Double(k + rank + 1)
            }
        }
        return scores.keys
            .map { (id: $0, score: scores[$0]!) }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : (firstSeen[lhs.id]! < firstSeen[rhs.id]!)
            }
    }
}
