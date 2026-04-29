// macos/EngramCoreWrite/ProjectMove/MigrationLogTypes.swift
// Shared data + protocols for migration_log queries used by Undo and
// Recover. The actual GRDB-backed implementation lands in Stage 4 when
// the orchestrator wires write paths; for now Stage 3 modules accept
// these protocols so they can be unit-tested with mocks.
import Foundation

public enum MigrationLogState: String, Equatable, CaseIterable, Sendable {
    case fsPending = "fs_pending"
    case fsDone = "fs_done"
    case committed
    case failed
}

public struct MigrationLogRecord: Equatable, Sendable {
    public let id: String
    /// Raw state string from `migration_log.state`. Compared against
    /// `MigrationLogState.committed.rawValue` etc.; left as `String` so
    /// unexpected values from the DB don't crash the reader.
    public let state: String
    public let oldPath: String
    public let newPath: String
    public let startedAt: String
    public let finishedAt: String?
    public let error: String?
    public let rolledBackOf: String?
    /// Session IDs pulled out of the `detail` JSON column (key
    /// `affectedSessionIds`). Empty if `detail` is missing or doesn't
    /// carry the field.
    public let affectedSessionIds: [String]

    public init(
        id: String,
        state: String,
        oldPath: String,
        newPath: String,
        startedAt: String,
        finishedAt: String? = nil,
        error: String? = nil,
        rolledBackOf: String? = nil,
        affectedSessionIds: [String] = []
    ) {
        self.id = id
        self.state = state
        self.oldPath = oldPath
        self.newPath = newPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.rolledBackOf = rolledBackOf
        self.affectedSessionIds = affectedSessionIds
    }
}

public protocol MigrationLogReader: Sendable {
    func find(migrationId: String) throws -> MigrationLogRecord?
    func list(states: [String], since: Date?) throws -> [MigrationLogRecord]
}

public struct SessionSnapshot: Equatable, Sendable {
    public let id: String
    public let cwd: String?

    public init(id: String, cwd: String?) {
        self.id = id
        self.cwd = cwd
    }
}

public protocol SessionByIdReader: Sendable {
    func session(id: String) throws -> SessionSnapshot?
}
