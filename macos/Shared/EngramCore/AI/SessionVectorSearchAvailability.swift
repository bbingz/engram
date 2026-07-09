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
