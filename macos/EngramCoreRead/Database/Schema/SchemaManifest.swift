import Foundation

public enum SchemaManifest {
    public static let schemaVersion = 1
    public static let ftsVersion = "3"

    public static let baseTables: Set<String> = [
        "sessions",
        "sessions_fts",
        "sync_state",
        "metadata",
        "project_aliases",
        "session_local_state",
        "session_index_jobs",
        "migration_log",
        "usage_snapshots",
        "git_repos",
        "session_costs",
        "session_tools",
        "session_files",
        "logs",
        "traces",
        "metrics",
        "metrics_hourly",
        "alerts",
        "ai_audit_log",
        "insights",
        "insights_fts",
        "memory_insights",
    ]

    public static let lazyVectorTables: Set<String> = [
        "session_embeddings",
        "session_chunks",
        "vec_sessions",
        "vec_chunks",
        "vec_insights",
    ]

    public static let lazyVectorMetadataKeys: Set<String> = [
        "vec_dimension",
        "vec_model",
    ]

    public static let requiredMetadataKeys: Set<String> = [
        "schema_version",
        "fts_version",
    ]
}
