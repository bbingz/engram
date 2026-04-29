// macos/EngramCoreWrite/ProjectMove/RecoverMigrations.swift
// Mirrors src/core/project-move/recover.ts (Node parity baseline).
//
// Read-only diagnostic over migration_log. Inspects non-terminal / failed
// rows (and optionally committed ones), probes the filesystem for both
// paths and any leftover `.engram-tmp-*` / `.engram-move-tmp-*` artifacts,
// and emits a human-readable recommendation per row. Never mutates.
import Foundation

public enum PathProbe: String, Equatable, Sendable {
    case exists
    case absent
    case unknown
}

public struct RecoverDiagnosis: Equatable, Sendable {
    public let migrationId: String
    public let state: String
    public let oldPath: String
    public let newPath: String
    public let startedAt: String
    public let finishedAt: String?
    public let error: String?
    public let oldPathExists: Bool
    public let newPathExists: Bool
    public let oldPathProbe: PathProbe
    public let newPathProbe: PathProbe
    public let tempArtifacts: [String]
    public let probeError: String?
    public let recommendation: String
}

public struct RecoverOptions {
    public var since: Date?
    public var includeCommitted: Bool

    public init(since: Date? = nil, includeCommitted: Bool = false) {
        self.since = since
        self.includeCommitted = includeCommitted
    }
}

public enum RecoverMigrations {
    /// Diagnose stuck migrations. Returns one entry per matching row
    /// (`fs_pending` / `fs_done` / `failed`, plus `committed` if requested).
    /// Pure read — never modifies anything.
    public static func diagnose(
        log: MigrationLogReader,
        options: RecoverOptions = RecoverOptions(),
        probePath: (String) -> PathProbe = defaultProbePath,
        readDirectory: (String) throws -> [String] = defaultReadDirectory
    ) throws -> [RecoverDiagnosis] {
        let states: [String] = options.includeCommitted
            ? [
                MigrationLogState.fsPending.rawValue,
                MigrationLogState.fsDone.rawValue,
                MigrationLogState.failed.rawValue,
                MigrationLogState.committed.rawValue,
            ]
            : [
                MigrationLogState.fsPending.rawValue,
                MigrationLogState.fsDone.rawValue,
                MigrationLogState.failed.rawValue,
            ]
        let rows = try log.list(states: states, since: options.since)

        return rows.map { row in
            let oldProbe = probePath(row.oldPath)
            let newProbe = probePath(row.newPath)
            let oldExists = oldProbe == .exists
            let newExists = newProbe == .exists
            let artifacts = scanTempArtifacts(
                oldPath: row.oldPath,
                newPath: row.newPath,
                readDirectory: readDirectory
            )
            return RecoverDiagnosis(
                migrationId: row.id,
                state: row.state,
                oldPath: row.oldPath,
                newPath: row.newPath,
                startedAt: row.startedAt,
                finishedAt: row.finishedAt,
                error: row.error,
                oldPathExists: oldExists,
                newPathExists: newExists,
                oldPathProbe: oldProbe,
                newPathProbe: newProbe,
                tempArtifacts: artifacts.paths,
                probeError: artifacts.error,
                recommendation: buildRecommendation(
                    state: row.state,
                    oldExists: oldExists,
                    newExists: newExists
                )
            )
        }
    }

    /// Default path-existence probe. ENOENT and ENOTDIR map to `.absent`;
    /// any other failure (EACCES, ELOOP, EIO) maps to `.unknown` so the
    /// caller doesn't conflate "couldn't tell" with "confirmed missing".
    public static func defaultProbePath(_ path: String) -> PathProbe {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return .exists
        } catch let err as CocoaError where err.code == .fileNoSuchFile {
            return .absent
        } catch let err as NSError where err.domain == NSCocoaErrorDomain
            && err.code == NSFileReadNoSuchFileError {
            return .absent
        } catch let err as NSError where err.domain == NSPOSIXErrorDomain
            && (err.code == Int(ENOENT) || err.code == Int(ENOTDIR)) {
            return .absent
        } catch {
            return .unknown
        }
    }

    /// Default directory listing — wraps `FileManager.contentsOfDirectory`
    /// so callers can override with a fake for tests.
    public static func defaultReadDirectory(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    // MARK: - internals

    private static func scanTempArtifacts(
        oldPath: String,
        newPath: String,
        readDirectory: (String) throws -> [String]
    ) -> (paths: [String], error: String?) {
        let oldParent = (oldPath as NSString).deletingLastPathComponent
        let newParent = (newPath as NSString).deletingLastPathComponent
        let oldBasename = (oldPath as NSString).lastPathComponent
        let newBasename = (newPath as NSString).lastPathComponent

        let parents = Array(Set([oldParent, newParent]))
            .filter { !$0.isEmpty && $0 != "/" && $0 != "." }
            .sorted()

        var found: [String] = []
        var errors: [String] = []
        for parent in parents {
            do {
                let entries = try readDirectory(parent)
                for name in entries {
                    if name.hasPrefix(".engram-tmp-")
                        || name.hasPrefix(".engram-move-tmp-")
                        || name.hasPrefix("\(newBasename).engram-move-tmp-")
                        || name.hasPrefix("\(oldBasename).engram-move-tmp-")
                    {
                        found.append("\(parent)/\(name)")
                    }
                }
            } catch {
                errors.append("\(parent): \(error.localizedDescription)")
            }
        }
        return (
            found.sorted(),
            errors.isEmpty ? nil : errors.joined(separator: "; ")
        )
    }

    private static func buildRecommendation(
        state: String,
        oldExists: Bool,
        newExists: Bool
    ) -> String {
        switch state {
        case MigrationLogState.committed.rawValue:
            if newExists && !oldExists { return "OK — move completed as logged." }
            if oldExists && !newExists {
                return "Anomaly — log says committed but src still exists. " +
                    "Investigate manually; consider `engram project undo <id>`."
            }
            return "Anomaly — both or neither paths present. Investigate."

        case MigrationLogState.fsPending.rawValue:
            if oldExists && !newExists {
                return "FS untouched. Safe to ignore; retry the move when ready. " +
                    "The stale log row auto-fails after 24h."
            }
            if oldExists && newExists {
                return "Both paths exist — partial fs.cp may have occurred. " +
                    "Inspect new path; remove it manually if bogus."
            }
            if !oldExists && newExists {
                return "Move seems to have actually succeeded; DB log did not catch up. " +
                    "Manual fix: UPDATE migration_log SET state='committed' WHERE id=<this>. " +
                    "Then re-run `engram project move` to sync DB cwd/source_locator."
            }
            return "Neither path exists — something catastrophic happened. " +
                "Restore from backup."

        case MigrationLogState.fsDone.rawValue:
            if !oldExists && newExists {
                return "FS move succeeded; DB commit failed mid-way. " +
                    "To finish: either (a) mv the new path back to the old path and retry " +
                    "`engram project move`, or (b) mark the migration committed " +
                    "directly — connect to ~/.engram/index.sqlite and run " +
                    "`UPDATE migration_log SET state='committed' WHERE id='<this>'`, " +
                    "then run `engram project review <oldPath> <newPath>` to check " +
                    "residual refs. Re-running `engram project move <oldPath> <newPath>` " +
                    "as-is WILL NOT work (src gone, dst exists)."
            }
            if oldExists && newExists {
                return "Both paths exist — FS work may have been partially undone. " +
                    "Inspect both; prefer manual mv back over retry."
            }
            return "Unexpected state. Investigate manually."

        case MigrationLogState.failed.rawValue:
            if oldExists && !newExists {
                return "Compensation succeeded — src is back where it started. " +
                    "Safe to ignore and retry later."
            }
            if !oldExists && newExists {
                return "FS move completed but DB commit failed and compensation did not " +
                    "reverse the FS. Either (a) manually mv new → old then retry " +
                    "`engram project move`, or (b) mark committed directly: " +
                    "`UPDATE migration_log SET state='committed' WHERE id='<this>'` " +
                    "then `engram project review`."
            }
            if oldExists && newExists {
                return "Both paths exist — compensation ran partially. Inspect, " +
                    "then `engram project move` (or manual mv) to reach a consistent state."
            }
            return "Neither path exists — likely data loss. Restore from backup."

        default:
            return "Unknown state"
        }
    }
}
