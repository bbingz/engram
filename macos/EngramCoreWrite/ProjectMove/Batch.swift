// macos/EngramCoreWrite/ProjectMove/Batch.swift
// Mirrors src/core/project-move/batch.ts (Node parity baseline) — JSON-only
// payload (no Yams SwiftPM dep). The Swift MCP boundary already carries
// JSON, so a YAML batch driver buys nothing for the new architecture; the
// Node CLI keeps its YAML loader for backwards compat with the parity tree
// in src/.
//
// Schema v1:
//   {
//     "version": 1,
//     "defaults": { "stop_on_error": bool, "dry_run": bool },   // optional
//     "operations": [
//       { "src": "/abs/path", "dst": "/abs/path", "note": "..." },
//       { "src": "/abs/path", "archive": true, "archive_to": "归档完成" }
//     ]
//   }
import Foundation

public struct BatchOperation: Equatable, Sendable {
    public var src: String
    public var dst: String?
    public var archive: Bool
    public var archiveTo: String?
    public var note: String?

    public init(
        src: String,
        dst: String? = nil,
        archive: Bool = false,
        archiveTo: String? = nil,
        note: String? = nil
    ) {
        self.src = src
        self.dst = dst
        self.archive = archive
        self.archiveTo = archiveTo
        self.note = note
    }
}

public struct BatchDefaults: Equatable, Sendable {
    public var stopOnError: Bool
    public var dryRun: Bool

    public init(stopOnError: Bool = true, dryRun: Bool = false) {
        self.stopOnError = stopOnError
        self.dryRun = dryRun
    }
}

public struct BatchDocument: Equatable, Sendable {
    public var version: Int
    public var defaults: BatchDefaults
    public var operations: [BatchOperation]

    public init(
        version: Int = 1,
        defaults: BatchDefaults = BatchDefaults(),
        operations: [BatchOperation]
    ) {
        self.version = version
        self.defaults = defaults
        self.operations = operations
    }
}

public struct BatchOperationFailure: Equatable, Sendable {
    public let operation: BatchOperation
    public let error: String
    public init(operation: BatchOperation, error: String) {
        self.operation = operation
        self.error = error
    }
}

public struct BatchResult: Equatable, Sendable {
    public var completed: [PipelineResult]
    public var failed: [BatchOperationFailure]
    public var skipped: [BatchOperation]

    public init(
        completed: [PipelineResult] = [],
        failed: [BatchOperationFailure] = [],
        skipped: [BatchOperation] = []
    ) {
        self.completed = completed
        self.failed = failed
        self.skipped = skipped
    }
}

public enum BatchError: Error, Equatable {
    case malformedJson(String)
    case unsupportedVersion(Int)
    case operationsMissing
    case operationInvalid(index: Int, reason: String)
    case continueFromUnsupported
}

public struct BatchOverrides: Sendable {
    public var homeDirectory: URL
    public var lockPath: String?
    public var force: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        lockPath: String? = nil,
        force: Bool = false
    ) {
        self.homeDirectory = homeDirectory
        self.lockPath = lockPath
        self.force = force
    }
}

public enum Batch {

    /// Parse a batch document from raw JSON bytes. Strict — rejects unknown
    /// schema versions, missing operations list, dst/archive XOR violations,
    /// and the reserved `continue_from` directive (silently parsing a
    /// control-flow keyword that doesn't actually skip is a UX trap that
    /// could re-run completed moves).
    public static func parseJSON(_ data: Data) throws -> BatchDocument {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw BatchError.malformedJson(error.localizedDescription)
        }
        guard let dict = raw as? [String: Any] else {
            throw BatchError.malformedJson("document must be a JSON object")
        }
        let version = (dict["version"] as? Int) ?? -1
        guard version == 1 else {
            throw BatchError.unsupportedVersion(version)
        }
        guard let opsRaw = dict["operations"] as? [Any] else {
            throw BatchError.operationsMissing
        }

        if let cf = dict["continue_from"] as? String, !cf.isEmpty {
            throw BatchError.continueFromUnsupported
        }

        var operations: [BatchOperation] = []
        for (idx, opRaw) in opsRaw.enumerated() {
            guard let op = opRaw as? [String: Any] else {
                throw BatchError.operationInvalid(
                    index: idx,
                    reason: "operation must be a JSON object"
                )
            }
            guard let src = op["src"] as? String, !src.isEmpty else {
                throw BatchError.operationInvalid(
                    index: idx,
                    reason: "src is required (non-empty string)"
                )
            }
            let hasDst: Bool
            let dst: String?
            if let s = op["dst"] as? String, !s.isEmpty {
                hasDst = true
                dst = s
            } else {
                hasDst = false
                dst = nil
            }
            let hasArchive = (op["archive"] as? Bool) == true
            if hasDst == hasArchive {
                throw BatchError.operationInvalid(
                    index: idx,
                    reason: "exactly one of dst|archive must be set"
                )
            }
            // Node accepts both `archive_to` and `archiveTo`; mirror that.
            let archiveTo = (op["archive_to"] as? String) ?? (op["archiveTo"] as? String)
            let note = op["note"] as? String
            operations.append(
                BatchOperation(
                    src: src,
                    dst: dst,
                    archive: hasArchive,
                    archiveTo: archiveTo,
                    note: note
                )
            )
        }

        let defaultsRaw = dict["defaults"] as? [String: Any] ?? [:]
        let stopOnError: Bool = {
            if let v = defaultsRaw["stop_on_error"] as? Bool { return v }
            if let v = defaultsRaw["stopOnError"] as? Bool { return v }
            return true
        }()
        let dryRun: Bool = {
            if let v = defaultsRaw["dry_run"] as? Bool { return v }
            if let v = defaultsRaw["dryRun"] as? Bool { return v }
            return false
        }()
        return BatchDocument(
            version: 1,
            defaults: BatchDefaults(stopOnError: stopOnError, dryRun: dryRun),
            operations: operations
        )
    }

    /// Run each operation sequentially. With `stopOnError` (default true),
    /// the first failure halts the run and remaining operations land in
    /// `skipped`; otherwise every operation runs and failures collect.
    public static func run(
        _ doc: BatchDocument,
        writer: EngramDatabaseWriter,
        overrides: BatchOverrides = BatchOverrides()
    ) async -> BatchResult {
        var result = BatchResult()
        var halted = false

        for op in doc.operations {
            if halted {
                result.skipped.append(op)
                continue
            }
            let src = ProjectPath.expandHome(
                op.src,
                homeDirectory: overrides.homeDirectory
            )
            var dst: String
            if let opDst = op.dst {
                dst = ProjectPath.expandHome(
                    opDst,
                    homeDirectory: overrides.homeDirectory
                )
            } else if op.archive {
                do {
                    let suggestion = try Archive.suggestTarget(
                        src: src,
                        options: ArchiveOptions(forceCategory: op.archiveTo)
                    )
                    dst = suggestion.dst
                    // SafeMoveDir requires the dst's parent to exist.
                    try FileManager.default.createDirectory(
                        atPath: (dst as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                } catch {
                    result.failed.append(
                        BatchOperationFailure(operation: op, error: errorText(error))
                    )
                    if doc.defaults.stopOnError { halted = true }
                    continue
                }
            } else {
                result.failed.append(
                    BatchOperationFailure(operation: op, error: "missing dst/archive")
                )
                if doc.defaults.stopOnError { halted = true }
                continue
            }

            do {
                let pipelineResult = try await ProjectMoveOrchestrator.run(
                    writer: writer,
                    options: RunProjectMoveOptions(
                        src: src,
                        dst: dst,
                        dryRun: doc.defaults.dryRun,
                        force: overrides.force,
                        archived: op.archive,
                        auditNote: op.note,
                        actor: .batch,
                        homeDirectory: overrides.homeDirectory,
                        lockPath: overrides.lockPath
                    )
                )
                result.completed.append(pipelineResult)
            } catch {
                result.failed.append(
                    BatchOperationFailure(operation: op, error: errorText(error))
                )
                if doc.defaults.stopOnError { halted = true }
            }
        }
        return result
    }

    // MARK: - internals

    private static func errorText(_ err: Error) -> String {
        if let pmErr = err as? ProjectMoveError {
            return pmErr.errorMessage
        }
        return (err as NSError).localizedDescription
    }
}
