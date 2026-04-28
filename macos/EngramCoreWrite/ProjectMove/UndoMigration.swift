// macos/EngramCoreWrite/ProjectMove/UndoMigration.swift
// Mirrors src/core/project-move/undo.ts (Node parity baseline).
//
// Splits the Node `undoMigration` function into a pure pre-flight stage
// (`prepareReverseRequest`) plus the orchestrator call. Stage 3 ships
// the pre-flight + error types. Stage 4 wires the actual reverse-move
// invocation through the ported orchestrator.
import Foundation

public struct UndoNotAllowedError: ProjectMoveError, Equatable {
    public let migrationId: String
    public let state: String

    public init(migrationId: String, state: String) {
        self.migrationId = migrationId
        self.state = state
    }

    public var errorName: String { "UndoNotAllowedError" }
    public var errorMessage: String {
        "undoMigration: cannot undo migration \(migrationId) in state '\(state)'. " +
        "Only 'committed' migrations can be undone. Run `engram project recover` " +
        "for non-terminal or failed migrations."
    }
    public var errorDetails: ErrorDetails? {
        ErrorDetails(migrationId: migrationId, state: state)
    }
}

public struct UndoStaleError: ProjectMoveError, Equatable {
    public let migrationId: String
    public let reason: String

    public init(migrationId: String, reason: String) {
        self.migrationId = migrationId
        self.reason = reason
    }

    public var errorName: String { "UndoStaleError" }
    public var errorMessage: String {
        "undoMigration: refusing to undo \(migrationId) — \(reason). " +
        "The migration is no longer the last one touching these paths. " +
        "Undo the later migrations first, or manually restore from backup."
    }
    public var errorDetails: ErrorDetails? {
        ErrorDetails(migrationId: migrationId)
    }
}

public enum UndoMigrationError: Error, Equatable {
    case notFound(migrationId: String)
}

public struct ReverseMoveRequest: Equatable, Sendable {
    /// The migration we're rolling back. Recorded into the new
    /// migration_log row's `rolled_back_of` column.
    public let originalMigrationId: String
    /// Source path for the reverse move = the original migration's `newPath`.
    public let src: String
    /// Destination path for the reverse move = the original migration's `oldPath`.
    public let dst: String

    public init(originalMigrationId: String, src: String, dst: String) {
        self.originalMigrationId = originalMigrationId
        self.src = src
        self.dst = dst
    }
}

public enum UndoMigration {
    /// Validate that `migrationId` is in a state allowing undo, that its
    /// `newPath` still exists, and that the affected sessions still point
    /// at it. On success, returns the swapped src/dst the orchestrator
    /// should run with `rolled_back_of = migrationId`.
    ///
    /// This is the pure pre-flight half of Node's `undoMigration`. The
    /// actual reverse run lands in Stage 4 once the orchestrator has been
    /// ported and can accept this request shape.
    public static func prepareReverseRequest(
        migrationId: String,
        log: MigrationLogReader,
        sessions: SessionByIdReader,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> ReverseMoveRequest {
        guard let original = try log.find(migrationId: migrationId) else {
            throw UndoMigrationError.notFound(migrationId: migrationId)
        }
        if original.state != MigrationLogState.committed.rawValue {
            throw UndoNotAllowedError(migrationId: migrationId, state: original.state)
        }

        guard fileExists(original.newPath) else {
            throw UndoStaleError(
                migrationId: migrationId,
                reason: "newPath (\(original.newPath)) no longer exists — " +
                    "it was likely moved by a later migration"
            )
        }

        if let firstAffected = original.affectedSessionIds.first {
            if let snapshot = try sessions.session(id: firstAffected),
               let cwd = snapshot.cwd,
               cwd != original.newPath {
                let preview = String(firstAffected.prefix(8))
                throw UndoStaleError(
                    migrationId: migrationId,
                    reason: "session \(preview) cwd is now \(cwd), not \(original.newPath)"
                )
            }
        }

        return ReverseMoveRequest(
            originalMigrationId: migrationId,
            src: original.newPath,
            dst: original.oldPath
        )
    }
}
