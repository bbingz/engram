import Foundation
import GRDB

/// Availability gate for session-level semantic / hybrid search.
///
/// Vectors are **usable** only when `embedding_meta` records a single
/// model+dimension and at least one `semantic_chunks` row matches that
/// model/dim with a non-null embedding BLOB. Callers must not advertise or
/// serve semantic/hybrid modes when `isUsable` is false.
///
/// Design: `docs/mcp-semantic-search-design-2026-07.md`.
public enum SessionVectorSearchAvailability {
    public struct Snapshot: Equatable, Sendable {
        public let isUsable: Bool
        public let model: String?
        public let dimension: Int?

        public init(isUsable: Bool, model: String? = nil, dimension: Int? = nil) {
            self.isUsable = isUsable
            self.model = model
            self.dimension = dimension
        }

        public static let unavailable = Snapshot(isUsable: false)
    }

    /// Why semantic/hybrid cannot run for a request (distinct user-facing reasons).
    public enum SemanticDegradeReason: String, Sendable, Equatable {
        case providerUnavailable
        case corpusMissing
        case modelMismatch
        case breakerOpen
        case embedFailed

        public var serviceWarning: String {
            serviceWarning(detail: nil)
        }

        public func serviceWarning(detail: String?) -> String {
            switch self {
            case .providerUnavailable:
                return "Semantic search unavailable: embedding provider is not configured; returning keyword results only."
            case .corpusMissing:
                return "Semantic search unavailable: session embedding corpus is missing or empty; returning keyword results only."
            case .modelMismatch:
                if let detail, !detail.isEmpty {
                    return "Semantic search unavailable: embedding model mismatch (\(detail)); returning keyword results only."
                }
                return "Semantic search unavailable: embedding model mismatch (configured model does not match embedding_meta); returning keyword results only."
            case .breakerOpen:
                return "Semantic search unavailable: embedding circuit breaker is open; returning keyword results only."
            case .embedFailed:
                if let detail, !detail.isEmpty {
                    return "Semantic search unavailable: query embedding failed (\(detail)); returning keyword results only."
                }
                return "Semantic search unavailable: query embedding failed; returning keyword results only."
            }
        }

        /// `get_memory` degrade copy — must name the actual reason (M07).
        public var memoryWarning: String {
            memoryWarning(detail: nil)
        }

        public func memoryWarning(detail: String?) -> String {
            switch self {
            case .providerUnavailable:
                return "No embedding provider — keyword-matched insights ranked by importance and recency."
            case .corpusMissing:
                return "Insight embeddings are missing — keyword-matched insights ranked by importance and recency."
            case .modelMismatch:
                if let detail, !detail.isEmpty {
                    return "Embedding model mismatch (\(detail)) — keyword-matched insights ranked by importance and recency."
                }
                return "Embedding model mismatch — keyword-matched insights ranked by importance and recency."
            case .breakerOpen:
                return "Embedding circuit breaker is open — keyword-matched insights ranked by importance and recency."
            case .embedFailed:
                if let detail, !detail.isEmpty {
                    return "Query embedding failed (\(detail)) — keyword-matched insights ranked by importance and recency."
                }
                return "Query embedding failed — keyword-matched insights ranked by importance and recency."
            }
        }

        /// Stable machine-readable code for service/MCP clients (H07 / M06 / M07).
        public var structuredCode: String {
            switch self {
            case .providerUnavailable:
                return "embeddingProviderUnavailable"
            case .corpusMissing:
                return "embeddingCorpusMissing"
            case .modelMismatch:
                // Match MCP SearchError structured code.
                return "embeddingModelMismatch"
            case .breakerOpen:
                return "embeddingCircuitOpen"
            case .embedFailed:
                return "embeddingFailed"
            }
        }
    }

    /// Result of comparing the configured query embedding model against stored meta.
    public enum QueryCompatibility: Equatable, Sendable {
        case compatible(model: String, dimension: Int)
        case corpusUnavailable
        case modelMismatch(
            configuredModel: String,
            configuredDimension: Int,
            storedModel: String,
            storedDimension: Int
        )
    }

    /// H07: require exact model **and** dimension equality before generating a
    /// query embedding. Same-dimension different-model is a hard mismatch.
    public static func queryCompatibility(
        configuredModel: String,
        configuredDimension: Int,
        snapshot: Snapshot
    ) -> QueryCompatibility {
        let cfgModel = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard snapshot.isUsable,
              let storedModel = snapshot.model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !storedModel.isEmpty,
              let storedDim = snapshot.dimension,
              storedDim > 0 else {
            return .corpusUnavailable
        }
        if cfgModel == storedModel, configuredDimension == storedDim {
            return .compatible(model: storedModel, dimension: storedDim)
        }
        return .modelMismatch(
            configuredModel: cfgModel,
            configuredDimension: configuredDimension,
            storedModel: storedModel,
            storedDimension: storedDim
        )
    }

    /// Read-only probe of a database file. Missing/unreadable DB → unavailable.
    public static func probe(databasePath: String) -> Snapshot {
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
            return try queue.read { db in
                try probe(db: db)
            }
        } catch {
            return .unavailable
        }
    }

    public static func probe(db: Database) throws -> Snapshot {
        guard try tableExists("embedding_meta", db: db),
              try tableExists("semantic_chunks", db: db) else {
            return .unavailable
        }

        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT model, dimension
            FROM embedding_meta
            WHERE id = 1
            LIMIT 1
            """
        ) else {
            return .unavailable
        }

        let model = (row["model"] as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dimension = row["dimension"] as Int?
        guard let model, !model.isEmpty, let dimension, dimension > 0 else {
            return .unavailable
        }

        let hasCompatibleChunk = try Int.fetchOne(
            db,
            sql: """
            SELECT 1
            FROM semantic_chunks
            WHERE embedding IS NOT NULL
              AND model = ?
              AND dim = ?
            LIMIT 1
            """,
            arguments: [model, dimension]
        ) != nil

        guard hasCompatibleChunk else {
            return Snapshot(isUsable: false, model: model, dimension: dimension)
        }

        return Snapshot(isUsable: true, model: model, dimension: dimension)
    }

    private static func tableExists(_ name: String, db: Database) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            arguments: [name]
        ) != nil
    }
}
