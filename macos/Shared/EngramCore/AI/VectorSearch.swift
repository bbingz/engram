import Foundation

/// Brute-force cosine KNN over a candidate set. For a local personal corpus
/// (thousands of vectors, optionally pre-filtered by FTS/project) this is fast
/// enough (sub-millisecond) and avoids a native ANN dependency. Vectors are
/// stored L2-normalized, so cosine is a dot product.
public enum VectorSearch {
    public struct Candidate: Sendable {
        public let id: String
        public let vector: [Float]
        public init(id: String, vector: [Float]) {
            self.id = id
            self.vector = vector
        }
    }

    public struct Hit: Sendable, Equatable {
        public let id: String
        public let score: Float
        public init(id: String, score: Float) {
            self.id = id
            self.score = score
        }
    }

    public static func knn(query: [Float], candidates: [Candidate], topK: Int) -> [Hit] {
        guard !query.isEmpty, topK > 0, !candidates.isEmpty else { return [] }
        let scored = candidates.map { Hit(id: $0.id, score: VectorMath.cosine(query, $0.vector)) }
        return Array(scored.sorted { $0.score > $1.score }.prefix(topK))
    }
}
