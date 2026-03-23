// macos/EngramTests/TestHelpers.swift
import XCTest
import GRDB
@testable import Engram

// MARK: - Database Table Creation

/// Create a minimal sessions table (plus FTS and observability tables)
/// matching the daemon's schema so DatabaseManager.open() can apply its
/// idempotent migrations.
func createSessionsTable(at path: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT,
                cwd TEXT NOT NULL DEFAULT '',
                project TEXT,
                model TEXT,
                message_count INTEGER NOT NULL DEFAULT 0,
                user_message_count INTEGER NOT NULL DEFAULT 0,
                assistant_message_count INTEGER NOT NULL DEFAULT 0,
                tool_message_count INTEGER NOT NULL DEFAULT 0,
                system_message_count INTEGER NOT NULL DEFAULT 0,
                summary TEXT,
                file_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL DEFAULT 0,
                indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
                agent_role TEXT,
                hidden_at TEXT,
                custom_name TEXT,
                tier TEXT,
                generated_title TEXT
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
                session_id UNINDEXED,
                content,
                tokenize='trigram case_sensitive 0'
            );

            -- Observability tables (matches daemon schema: ts, trace_id, error_name, error_message)
            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
                level TEXT NOT NULL DEFAULT 'info',
                module TEXT NOT NULL,
                trace_id TEXT,
                span_id TEXT,
                message TEXT NOT NULL,
                data TEXT,
                error_name TEXT,
                error_message TEXT,
                error_stack TEXT,
                source TEXT NOT NULL DEFAULT 'daemon'
            );
            CREATE TABLE IF NOT EXISTS traces (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trace_id TEXT NOT NULL,
                span_id TEXT NOT NULL UNIQUE,
                parent_span_id TEXT,
                name TEXT NOT NULL,
                module TEXT NOT NULL,
                start_ts TEXT NOT NULL,
                end_ts TEXT,
                duration_ms INTEGER,
                status TEXT NOT NULL DEFAULT 'ok',
                attributes TEXT,
                source TEXT NOT NULL CHECK (source IN ('daemon', 'app'))
            );
            CREATE TABLE IF NOT EXISTS metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                type TEXT NOT NULL CHECK (type IN ('counter', 'gauge', 'histogram')),
                value REAL NOT NULL,
                tags TEXT,
                ts TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS metrics_hourly (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                hour TEXT NOT NULL,
                count INTEGER NOT NULL,
                sum REAL NOT NULL,
                min REAL NOT NULL,
                max REAL NOT NULL,
                p95 REAL,
                tags TEXT,
                UNIQUE(name, type, hour, tags)
            );
        """)
    }
}

// MARK: - Test Data Insertion

/// Insert a test session with all 20 columns into the database via raw SQL.
func insertTestSession(at path: String,
                       id: String = "test-session-001",
                       source: String = "claude-code",
                       project: String? = "engram",
                       startTime: String = "2026-03-20T10:00:00Z",
                       endTime: String? = "2026-03-20T11:00:00Z",
                       messageCount: Int = 20,
                       userMessageCount: Int = 10,
                       assistantMessageCount: Int = 8,
                       toolMessageCount: Int = 2,
                       tier: String? = "normal",
                       summary: String? = "Test session summary",
                       generatedTitle: String? = nil,
                       agentRole: String? = nil,
                       hiddenAt: String? = nil,
                       customName: String? = nil) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            INSERT OR REPLACE INTO sessions (
                id, source, start_time, end_time, cwd, project, model,
                message_count, user_message_count, assistant_message_count,
                tool_message_count, system_message_count, summary, file_path,
                size_bytes, indexed_at, agent_role, hidden_at, custom_name, tier,
                generated_title
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'), ?, ?, ?, ?, ?)
        """, arguments: [
            id, source, startTime, endTime, "/Users/test/project", project, "sonnet",
            messageCount, userMessageCount, assistantMessageCount,
            toolMessageCount, 0, summary, "/tmp/test.jsonl",
            50000, agentRole, hiddenAt, customName, tier,
            generatedTitle
        ])
    }
}

/// Insert a test log entry for observability tests.
func insertTestLog(at path: String,
                   level: String = "info",
                   module: String = "test",
                   message: String = "Test log message",
                   source: String = "daemon",
                   ts: String? = nil) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        if let ts {
            try db.execute(sql: """
                INSERT INTO logs (ts, level, module, message, source)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [ts, level, module, message, source])
        } else {
            try db.execute(sql: """
                INSERT INTO logs (level, module, message, source)
                VALUES (?, ?, ?, ?)
            """, arguments: [level, module, message, source])
        }
    }
}

/// Insert content into the sessions_fts table for search tests.
func insertFTSContent(at path: String,
                      sessionId: String,
                      content: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO sessions_fts (session_id, content)
            VALUES (?, ?)
        """, arguments: [sessionId, content])
    }
}

// MARK: - Convenience

/// Create a temporary database with the sessions table already set up,
/// and return the DatabaseManager + path for use in tests.
@MainActor
func createTempDatabase() throws -> (DatabaseManager, String) {
    let tempDir = FileManager.default.temporaryDirectory
    let path = tempDir.appendingPathComponent("test-\(UUID().uuidString).sqlite").path
    try createSessionsTable(at: path)
    let db = DatabaseManager(path: path)
    try db.open()
    return (db, path)
}

/// Remove a temporary database and its WAL/SHM files.
func cleanupTempDatabase(at path: String) {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + "-wal")
    try? FileManager.default.removeItem(atPath: path + "-shm")
}
