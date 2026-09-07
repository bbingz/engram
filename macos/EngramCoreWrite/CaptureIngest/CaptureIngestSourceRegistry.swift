import Foundation
import GRDB
import EngramCoreRead

public enum CaptureIngestSourceRegistryError: Error, Equatable, Sendable {
    case invalidMachineID
    case invalidSourceInstanceID
    case invalidEpoch
    case invalidConfiguredRoot
    case invalidSourceParseFormat
    case parseFormatNotProvisioned
    case sourceInstanceConflict
    case overlappingRoot
    case unregisteredSourceInstance
    case staleBinding
    case epochPreviouslyApproved
    case authorityGenerationOverflow
    case invalidStoredBinding
}

public enum CaptureIngestParseFormat: String, Equatable, Sendable {
    case claudeDefault
    case claudeCustomProfile
    case codex
}

public struct CaptureIngestSourceBinding: Equatable, Sendable {
    public let machineID: String
    public let sourceInstanceID: String
    public let source: SourceName
    public let parseFormat: CaptureIngestParseFormat
    public let configuredRoot: String
    public let approvedEpoch: String
    public let authorityGeneration: Int64

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machineID.utf8.elementsEqual(rhs.machineID.utf8)
            && lhs.sourceInstanceID.utf8.elementsEqual(rhs.sourceInstanceID.utf8)
            && lhs.source == rhs.source
            && lhs.parseFormat == rhs.parseFormat
            && lhs.configuredRoot.utf8.elementsEqual(rhs.configuredRoot.utf8)
            && lhs.approvedEpoch.utf8.elementsEqual(rhs.approvedEpoch.utf8)
            && lhs.authorityGeneration == rhs.authorityGeneration
    }
}

public enum CaptureIngestQuarantineReason: String, Equatable, Sendable {
    case unknownSourceInstance = "unknown_source_instance"
    case manifestMismatch = "manifest_mismatch"
    case unsupportedCaptureShape = "unsupported_capture_shape"
    case invalidLocator = "invalid_locator"
    case sourceMismatch = "source_mismatch"
    case locatorOutsideRoot = "locator_outside_root"
    case epochNotApproved = "epoch_not_approved"
    case ambiguousSourceMapping = "ambiguous_source_mapping"
    case parseFormatNotProvisioned = "parse_format_not_provisioned"
}

public enum CaptureIngestEligibility: Equatable, Sendable {
    case eligible(CaptureIngestSourceBinding)
    case quarantined(CaptureIngestQuarantineReason)
}

public struct CaptureIngestEpochTransition: Equatable, Sendable {
    public let previousEpoch: String?
    public let approvedEpoch: String
    public let authorityGeneration: Int64
    public let approvedAt: String
}

/// Publications are immutable envelopes; ledger tasks are counted separately
/// per parser revision. Neither count is a logical-session or readiness count.
public struct CaptureIngestEpochBacklog: Equatable, Sendable {
    public let publicationCount: Int64
    public let ledgerTaskCounts: [String: Int64]
}

public struct CaptureIngestEpochDryRun: Equatable, Sendable {
    public let current: CaptureIngestSourceBinding
    public let candidateEpoch: String
    public let candidateWasPreviouslyApproved: Bool
    public let currentBacklog: CaptureIngestEpochBacklog
    public let candidateBacklog: CaptureIngestEpochBacklog
}

/// Database-only authority. The local authenticated Service command is the
/// future caller of mutations; this module neither exposes HTTP nor reads a
/// client's filesystem. Eligibility assumes replay verified the chunk bytes.
public enum CaptureIngestSourceRegistry {
    static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS capture_ingest_source_registry (
                machine_id TEXT NOT NULL,
                source_instance_id TEXT NOT NULL,
                source TEXT NOT NULL,
                parse_format TEXT,
                configured_root TEXT NOT NULL,
                approved_epoch TEXT NOT NULL,
                authority_generation INTEGER NOT NULL CHECK (authority_generation > 0),
                created_at TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (machine_id, source_instance_id),
                UNIQUE (machine_id, source, configured_root)
            );
            CREATE TABLE IF NOT EXISTS capture_ingest_epoch_history (
                machine_id TEXT NOT NULL,
                source_instance_id TEXT NOT NULL,
                previous_epoch TEXT,
                approved_epoch TEXT NOT NULL,
                authority_generation INTEGER NOT NULL CHECK (authority_generation > 0),
                approved_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (machine_id, source_instance_id, authority_generation),
                UNIQUE (machine_id, source_instance_id, approved_epoch),
                FOREIGN KEY (machine_id, source_instance_id)
                    REFERENCES capture_ingest_source_registry(machine_id, source_instance_id)
            );
            """)
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(capture_ingest_source_registry)")
        if !columns.contains(where: { ($0["name"] as String) == "parse_format" }) {
            try db.execute(sql: "ALTER TABLE capture_ingest_source_registry ADD COLUMN parse_format TEXT")
        }
    }

    public static func binding(
        _ db: Database, machineID: String, sourceInstanceID: String
    ) throws -> CaptureIngestSourceBinding? {
        try validateIdentity(machineID: machineID, sourceInstanceID: sourceInstanceID)
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM capture_ingest_source_registry WHERE machine_id = ? AND source_instance_id = ?
            """, arguments: [machineID, sourceInstanceID]) else { return nil }
        return try storedBinding(db, row: row)
    }

    public static func provision(
        _ db: Database, machineID: String, sourceInstanceID: String,
        source: SourceName, parseFormat: CaptureIngestParseFormat, configuredRoot: String, initialEpoch: String
    ) throws -> CaptureIngestSourceBinding {
        try validateIdentity(machineID: machineID, sourceInstanceID: sourceInstanceID)
        try validateEpoch(initialEpoch)
        guard isCanonicalAbsolutePath(configuredRoot) else {
            throw CaptureIngestSourceRegistryError.invalidConfiguredRoot
        }
        guard isCompatible(source: source, parseFormat: parseFormat) else {
            throw CaptureIngestSourceRegistryError.invalidSourceParseFormat
        }
        var result = CaptureIngestSourceBinding(
            machineID: machineID, sourceInstanceID: sourceInstanceID, source: source, parseFormat: parseFormat,
            configuredRoot: configuredRoot, approvedEpoch: initialEpoch, authorityGeneration: 1
        )
        try db.inSavepoint {
            if let current = try binding(db, machineID: machineID, sourceInstanceID: sourceInstanceID) {
                guard current.source == source, current.parseFormat == parseFormat,
                      exact(current.configuredRoot, configuredRoot), exact(current.approvedEpoch, initialEpoch) else {
                    throw CaptureIngestSourceRegistryError.sourceInstanceConflict
                }
                result = current
                return .commit
            }
            for registeredRoot in try registeredRoots(db, machineID: machineID, source: source) {
                guard !rootsOverlap(registeredRoot, configuredRoot) else {
                    throw CaptureIngestSourceRegistryError.overlappingRoot
                }
            }
            try db.execute(sql: """
                INSERT INTO capture_ingest_source_registry(
                    machine_id, source_instance_id, source, parse_format, configured_root, approved_epoch, authority_generation
                ) VALUES (?, ?, ?, ?, ?, ?, 1)
                """, arguments: [machineID, sourceInstanceID, source.rawValue, parseFormat.rawValue, configuredRoot, initialEpoch])
            try appendHistory(db, binding: result, previousEpoch: nil)
            return .commit
        }
        return result
    }

    public static func eligibility(
        _ db: Database, publication: CollectorPublicationEnvelope, verifiedManifest: ArchiveSourceManifest
    ) throws -> CaptureIngestEligibility {
        // Hash the original canonical manifest. Only the legacy manifest UUID
        // is normalized for identity comparison, matching the W2 receiver.
        guard exact(ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(verifiedManifest)), publication.manifestSHA256),
              let manifestMachine = UUID(uuidString: verifiedManifest.machineID)?.uuidString,
              exact(manifestMachine, publication.machineID) else {
            return .quarantined(.manifestMismatch)
        }
        guard exact(publication.representation, "exact-source-v1"), verifiedManifest.sessionID == nil,
              let source = SourceName(rawValue: verifiedManifest.source),
              source == .claudeCode || source == .codex,
              verifiedManifest.replayLayout.strategy == .singleFile,
              verifiedManifest.replayLayout.relativePaths.count == 1 else {
            return .quarantined(.unsupportedCaptureShape)
        }
        let locator = verifiedManifest.locator
        guard isCanonicalAbsolutePath(locator) else { return .quarantined(.invalidLocator) }
        let current: CaptureIngestSourceBinding
        do {
            guard let resolved = try binding(
                db, machineID: publication.machineID, sourceInstanceID: publication.sourceInstanceID
            ) else { return .quarantined(.unknownSourceInstance) }
            current = resolved
        } catch CaptureIngestSourceRegistryError.parseFormatNotProvisioned {
            return .quarantined(.parseFormatNotProvisioned)
        }
        guard current.source == source else { return .quarantined(.sourceMismatch) }
        guard isDescendant(locator, of: current.configuredRoot) else { return .quarantined(.locatorOutsideRoot) }
        let matching = try registeredRoots(db, machineID: publication.machineID, source: source)
            .filter { isDescendant(locator, of: $0) }
        guard matching.count == 1 else { return .quarantined(.ambiguousSourceMapping) }
        guard exact(current.approvedEpoch, publication.collectorEpoch) else { return .quarantined(.epochNotApproved) }
        return .eligible(current)
    }

    public static func history(
        _ db: Database, machineID: String, sourceInstanceID: String
    ) throws -> [CaptureIngestEpochTransition] {
        try validateIdentity(machineID: machineID, sourceInstanceID: sourceInstanceID)
        return try Row.fetchAll(db, sql: """
            SELECT previous_epoch, approved_epoch, authority_generation, approved_at
            FROM capture_ingest_epoch_history WHERE machine_id = ? AND source_instance_id = ?
            ORDER BY authority_generation
            """, arguments: [machineID, sourceInstanceID]).map { row in
                let previous: String? = row["previous_epoch"]
                let approved: String = row["approved_epoch"]
                let generation: Int64 = row["authority_generation"]
                let approvedAt: String = row["approved_at"]
                guard previous.map(isCanonicalUUID) ?? true, isCanonicalUUID(approved),
                      generation > 0, !approvedAt.isEmpty else {
                    throw CaptureIngestSourceRegistryError.invalidStoredBinding
                }
                return CaptureIngestEpochTransition(
                    previousEpoch: previous, approvedEpoch: approved,
                    authorityGeneration: generation, approvedAt: approvedAt
                )
            }
    }

    public static func dryRunEpoch(
        _ db: Database, machineID: String, sourceInstanceID: String, candidateEpoch: String
    ) throws -> CaptureIngestEpochDryRun {
        try validateEpoch(candidateEpoch)
        guard let current = try binding(db, machineID: machineID, sourceInstanceID: sourceInstanceID) else {
            throw CaptureIngestSourceRegistryError.unregisteredSourceInstance
        }
        let transitions = try history(db, machineID: machineID, sourceInstanceID: sourceInstanceID)
        return CaptureIngestEpochDryRun(
            current: current, candidateEpoch: candidateEpoch,
            candidateWasPreviouslyApproved: transitions.contains { exact($0.approvedEpoch, candidateEpoch) },
            currentBacklog: try backlog(db, binding: current, epoch: current.approvedEpoch),
            candidateBacklog: try backlog(db, binding: current, epoch: candidateEpoch)
        )
    }

    public static func approveEpoch(
        _ db: Database, machineID: String, sourceInstanceID: String,
        candidateEpoch: String, expectedEpoch: String, expectedAuthorityGeneration: Int64
    ) throws -> CaptureIngestSourceBinding {
        try validateEpoch(candidateEpoch)
        try validateEpoch(expectedEpoch)
        var result: CaptureIngestSourceBinding?
        try db.inSavepoint {
            guard let current = try binding(db, machineID: machineID, sourceInstanceID: sourceInstanceID) else {
                throw CaptureIngestSourceRegistryError.unregisteredSourceInstance
            }
            guard exact(current.approvedEpoch, expectedEpoch),
                  expectedAuthorityGeneration > 0, current.authorityGeneration == expectedAuthorityGeneration else {
                throw CaptureIngestSourceRegistryError.staleBinding
            }
            let transitions = try history(db, machineID: machineID, sourceInstanceID: sourceInstanceID)
            guard !transitions.contains(where: { exact($0.approvedEpoch, candidateEpoch) }) else {
                throw CaptureIngestSourceRegistryError.epochPreviouslyApproved
            }
            guard current.authorityGeneration < Int64.max else {
                throw CaptureIngestSourceRegistryError.authorityGenerationOverflow
            }
            let next = CaptureIngestSourceBinding(
                machineID: current.machineID, sourceInstanceID: current.sourceInstanceID, source: current.source,
                parseFormat: current.parseFormat,
                configuredRoot: current.configuredRoot, approvedEpoch: candidateEpoch,
                authorityGeneration: current.authorityGeneration + 1
            )
            try db.execute(sql: """
                UPDATE capture_ingest_source_registry
                SET approved_epoch = ?, authority_generation = ?, updated_at = datetime('now')
                WHERE machine_id = ? AND source_instance_id = ? AND approved_epoch = ? AND authority_generation = ?
                """, arguments: [
                    candidateEpoch, next.authorityGeneration, machineID, sourceInstanceID,
                    expectedEpoch, expectedAuthorityGeneration,
                ])
            guard db.changesCount == 1 else { throw CaptureIngestSourceRegistryError.staleBinding }
            try appendHistory(db, binding: next, previousEpoch: current.approvedEpoch)
            result = next
            return .commit
        }
        guard let result else { throw CaptureIngestSourceRegistryError.invalidStoredBinding }
        return result
    }

    private static func appendHistory(_ db: Database, binding: CaptureIngestSourceBinding, previousEpoch: String?) throws {
        try db.execute(sql: """
            INSERT INTO capture_ingest_epoch_history(
                machine_id, source_instance_id, previous_epoch, approved_epoch, authority_generation
            ) VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                binding.machineID, binding.sourceInstanceID, previousEpoch, binding.approvedEpoch, binding.authorityGeneration,
            ])
    }

    private static func registeredRoots(_ db: Database, machineID: String, source: SourceName) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM capture_ingest_source_registry WHERE machine_id = ? AND source = ?
            ORDER BY configured_root, source_instance_id
            """, arguments: [machineID, source.rawValue]).map { try validatedStoredRoot(db, row: $0) }
    }

    private static func storedBinding(_ db: Database, row: Row) throws -> CaptureIngestSourceBinding {
        let root = try validatedStoredRoot(db, row: row)
        let rawFormat: String? = row["parse_format"]
        guard let rawFormat else { throw CaptureIngestSourceRegistryError.parseFormatNotProvisioned }
        guard let parseFormat = CaptureIngestParseFormat(rawValue: rawFormat),
              let source = SourceName(rawValue: row["source"]),
              isCompatible(source: source, parseFormat: parseFormat) else {
            throw CaptureIngestSourceRegistryError.invalidStoredBinding
        }
        return CaptureIngestSourceBinding(
            machineID: row["machine_id"], sourceInstanceID: row["source_instance_id"], source: source, parseFormat: parseFormat,
            configuredRoot: root, approvedEpoch: row["approved_epoch"], authorityGeneration: row["authority_generation"]
        )
    }

    /// A legacy NULL format still reserves its root, but cannot make that row
    /// eligible. Inspect root authority without requiring a parsed binding.
    private static func validatedStoredRoot(_ db: Database, row: Row) throws -> String {
        let machineID: String = row["machine_id"]
        let instanceID: String = row["source_instance_id"]
        let rawSource: String = row["source"]
        let root: String = row["configured_root"]
        let epoch: String = row["approved_epoch"]
        let generation: Int64 = row["authority_generation"]
        guard isCanonicalUUID(machineID), isCanonicalUUID(instanceID), isCanonicalUUID(epoch),
              isCanonicalAbsolutePath(root), SourceName(rawValue: rawSource) != nil, generation > 0 else {
            throw CaptureIngestSourceRegistryError.invalidStoredBinding
        }
        let historyEpoch = try String.fetchOne(db, sql: """
            SELECT approved_epoch FROM capture_ingest_epoch_history
            WHERE machine_id = ? AND source_instance_id = ? AND authority_generation = ?
            """, arguments: [machineID, instanceID, generation])
        guard let historyEpoch, exact(historyEpoch, epoch) else {
            throw CaptureIngestSourceRegistryError.invalidStoredBinding
        }
        return root
    }

    private static func backlog(
        _ db: Database, binding: CaptureIngestSourceBinding, epoch: String
    ) throws -> CaptureIngestEpochBacklog {
        let arguments: StatementArguments = [binding.machineID, binding.sourceInstanceID, epoch]
        let publications = try Int64.fetchOne(db, sql: """
            SELECT COUNT(*) FROM capture_ingest_publications
            WHERE machine_id = ? AND source_instance_id = ? AND collector_epoch = ?
            """, arguments: arguments) ?? 0
        let statuses: [CaptureIngestStatus] = [.pending, .processing, .parsed, .indexReady, .retryableFailure, .quarantined]
        var tasks = Dictionary(uniqueKeysWithValues: statuses.map { ($0.rawValue, Int64(0)) })
        for row in try Row.fetchAll(db, sql: """
            SELECT l.status, COUNT(*) AS task_count FROM capture_ingest_ledger l
            JOIN capture_ingest_publications p ON p.publication_sha256 = l.publication_sha256
            WHERE p.machine_id = ? AND p.source_instance_id = ? AND p.collector_epoch = ? GROUP BY l.status
            """, arguments: arguments) {
            let status: String = row["status"]
            guard tasks[status] != nil else { throw CaptureIngestSourceRegistryError.invalidStoredBinding }
            tasks[status] = row["task_count"]
        }
        return CaptureIngestEpochBacklog(publicationCount: publications, ledgerTaskCounts: tasks)
    }

    private static func validateIdentity(machineID: String, sourceInstanceID: String) throws {
        guard isCanonicalUUID(machineID) else { throw CaptureIngestSourceRegistryError.invalidMachineID }
        guard isCanonicalUUID(sourceInstanceID) else { throw CaptureIngestSourceRegistryError.invalidSourceInstanceID }
    }

    private static func validateEpoch(_ epoch: String) throws {
        guard isCanonicalUUID(epoch) else { throw CaptureIngestSourceRegistryError.invalidEpoch }
    }

    private static func isCompatible(source: SourceName, parseFormat: CaptureIngestParseFormat) -> Bool {
        switch parseFormat {
        case .claudeDefault, .claudeCustomProfile:
            return source == .claudeCode
        case .codex:
            return source == .codex
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let canonical = UUID(uuidString: value)?.uuidString else { return false }
        return exact(canonical, value)
    }

    private static func exact(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.count > 1, bytes.first == 47, !bytes.contains(0) else { return false }
        return bytes.dropFirst().split(separator: 47, omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46])
        }
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let pathBytes = Array(path.utf8)
        let rootBytes = Array(root.utf8)
        return pathBytes.count > rootBytes.count && pathBytes.starts(with: rootBytes) && pathBytes[rootBytes.count] == 47
    }

    private static func rootsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        exact(lhs, rhs) || isDescendant(lhs, of: rhs) || isDescendant(rhs, of: lhs)
    }
}
