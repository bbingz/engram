import Foundation
import GRDB

/// The existing owner serializes recovery, readers, new materialization and GC.
/// No credential, replica transport, service control or implicit finalization.
final class CollectorSpoolGCSession: @unchecked Sendable {
    struct RecoveryReport: Codable {
        var legacyAbsentObjects = 0
        var legacyAbsentBytes: Int64 = 0
        var restoredObjects = 0
        var legacyReferenceSHA256 = ArchiveV2Hash.sha256(Data())
    }
    struct Snapshot {
        let inventory: CollectorSpoolGCPreview.Inventory
        let catalog: CollectorSpoolGCPreview.Catalog
        let graph: CollectorSpoolGCPreview.Graph?
        let authority: String
        var hash: String { ArchiveV2Hash.sha256(Data((inventory.fingerprint + catalog.fingerprint + authority).utf8)) }
    }
    let owner: CollectorInventoryOwner
    let catalog: ArchiveCatalog
    let spoolRoot: URL
    let files: CollectorSpoolGCFiles

    // Internal deterministic fault boundary. The CLI never supplies a hook.
    var transitionHook: ((String, String) throws -> Void)?
    struct SimulatedCrash: Error {}

    init(owner: CollectorInventoryOwner, catalog: ArchiveCatalog, spoolRoot: URL) throws {
        guard try CollectorMachineIdentityReader.canonicalExistingPath(owner.spoolGCRoot())
            == CollectorMachineIdentityReader.canonicalExistingPath(spoolRoot) else { throw CollectorSpoolGCError.unsafePath }
        self.owner = owner; self.catalog = catalog; self.spoolRoot = spoolRoot
        files = try CollectorSpoolGCFiles(root: spoolRoot)
        try owner.installSpoolGCAdmission { [weak self] queue in
            guard let self else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
            try self.admitManagedReads(queue, now: Int64(Date().timeIntervalSince1970))
        }
    }

    func admitManagedReads(_ queue: DatabaseQueue, now: Int64) throws {
        guard try queue.read({ try CollectorSpoolGCJournal.hasState($0) }) else { return }
        guard let graph = try snapshot(queue).graph else { return }
        for digest in graph.admissionKeep.sorted() {
            guard let row = try queue.read({ try CollectorSpoolGCJournal.residency($0, digest) }) else { continue }
            if try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: row["raw_bytes"]) != nil {
                if (row["state"] as String) != "resident" { try queue.write { try CollectorSpoolGCJournal.markResident($0, digest: digest, now: now) } }
                continue
            }
            if (row["state"] as String) == "evicted" { throw CollectorSpoolGCError.spoolRestoreRequired }
            let run: String = row["run_id"]
            guard let object = try queue.read({ try CollectorSpoolGCJournal.rows($0, runID: run).first { ($0["digest"] as String) == digest } }) else {
                throw CollectorSpoolGCError.spoolIntegrityBlocked
            }
            try restoreRow(queue, row: object, now: now)
        }
    }

    func snapshot(_ queue: DatabaseQueue, evidence: CollectorSpoolGCPreview.Evidence? = nil) throws -> Snapshot {
        let inventory = try queue.read { try CollectorSpoolGCPreview.readInventory($0) }
        let authority = try queue.read { db in
            try CollectorSpoolGCPreview.fingerprint([
                CollectorSpoolGCPreview.rows(db, "collector_streams", order: "root_id,root_revision,effective_source"),
                CollectorSpoolGCPreview.rows(db, "collector_root_bindings", order: "root_id,root_revision")])
        }
        let captures = try catalog.withSpoolGCRead { try CollectorSpoolGCPreview.readCatalog($0, machine: inventory.machine, allowEmpty: true) }
        if captures.captures.isEmpty {
            guard inventory.publications.isEmpty else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
            return Snapshot(inventory: inventory, catalog: captures, graph: nil, authority: authority)
        }
        return Snapshot(inventory: inventory, catalog: captures,
            graph: try CollectorSpoolGCPreview.graph(inventory, captures, evidence: evidence), authority: authority)
    }

    func residencyCount() throws -> Int {
        try owner.withSpoolGC { queue in try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_spool_object_residency") ?? 0 } }
    }

    func recover(now: Int64, inspectUntracked: Bool = false) throws -> RecoveryReport {
        guard now >= 0 else { throw CollectorSpoolGCError.invalidInput }
        return try owner.withSpoolGC { queue in
            guard try inspectUntracked || queue.read({ try CollectorSpoolGCJournal.hasState($0) }) else {
                return RecoveryReport()
            }
            let work = Work(now: now)
            let initial = try snapshot(queue)
            var report = RecoveryReport()
            let journal = try queue.read { try CollectorSpoolGCJournal.rows($0) }
            for row in journal {
                try work.charge()
                let state: String = row["state"], digest: String = row["digest"]
                switch state {
                case "quarantinePrepared", "restorePrepared":
                    try restoreRow(queue, row: row, now: now, work: work); report.restoredObjects += 1
                case "quarantined":
                    let path: String = row["quarantine_path"], size: Int64 = row["raw_bytes"]
                    guard try files.verify(path, digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) }) != nil else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
                    if initial.graph?.admissionKeep.contains(digest) == true {
                        try restoreRow(queue, row: row, now: now, work: work); report.restoredObjects += 1
                    }
                case "unlinkPrepared":
                    // Never retry unlink at startup. Existing bytes restore;
                    // absent bytes require a recorded, verified final intent.
                    try recoverUnlinkIntent(queue, row: row, now: now, work: work)
                case "cancelled", "evicted": break
                default: throw CollectorSpoolGCError.unsupportedSchema
                }
            }
            var legacy = Data()
            let journalDigests = Set(journal.map { $0["digest"] as String })
            if let graph = initial.graph {
                for digest in graph.refs.keys.sorted() {
                    try work.charge()
                    let size = graph.sizes[digest]!, refs = graph.refs[digest]!
                    let state = try queue.read { try CollectorSpoolGCJournal.residency($0, digest) }
                    let tracked = state != nil || journalDigests.contains(digest)
                    // Only GC-owned loss can fail whole-spool admission. Untracked
                    // loss remains the base reader/publication's responsibility.
                    if !tracked && (!inspectUntracked || !refs.isSubset(of: graph.dualACKedCaptures)) { continue }
                    if try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size, hash: false) != nil { continue }
                    if let state {
                        let status: String = state["state"]
                        if status == "quarantined", !graph.admissionKeep.contains(digest) { continue }
                        if status == "evicted", !graph.admissionKeep.contains(digest) { continue }
                        throw CollectorSpoolGCError.spoolIntegrityBlocked
                    }
                    guard !tracked else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
                    report.legacyAbsentObjects += 1
                    let sum = report.legacyAbsentBytes.addingReportingOverflow(size)
                    guard !sum.overflow else { throw CollectorSpoolGCError.budgetExceeded }
                    report.legacyAbsentBytes = sum.partialValue
                    legacy.append(Data((digest + ":" + refs.sorted().joined(separator: ",") + "\n").utf8))
                }
            }
            guard try snapshot(queue).hash == initial.hash else { throw CollectorSpoolGCError.scopeChanged }
            report.legacyReferenceSHA256 = ArchiveV2Hash.sha256(legacy)
            return report
        }
    }

    func prepareRead(_ digest: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try owner.withSpoolGC { queue in
            guard let row = try queue.read({ try CollectorSpoolGCJournal.residency($0, digest) }) else { return }
            let state: String = row["state"], size: Int64 = row["raw_bytes"]
            if try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size) != nil {
                if state != "resident" { try queue.write { try CollectorSpoolGCJournal.markResident($0, digest: digest, now: now) } }
                return
            }
            if state == "evicted" { throw CollectorSpoolGCError.spoolRestoreRequired }
            let run: String = row["run_id"]
            guard let object = try queue.read({ try CollectorSpoolGCJournal.rows($0, runID: run).first { ($0["digest"] as String) == digest } }) else {
                throw CollectorSpoolGCError.spoolIntegrityBlocked
            }
            try restoreRow(queue, row: object, now: now)
        }
    }

    func materialized(_ digest: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try owner.withSpoolGC { queue in
            guard let row = try queue.read({ try CollectorSpoolGCJournal.residency($0, digest) }) else { return }
            guard try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: row["raw_bytes"]) != nil else {
                throw CollectorSpoolGCError.spoolIntegrityBlocked
            }
            try queue.write { try CollectorSpoolGCJournal.markResident($0, digest: digest, now: now) }
        }
    }

    func restore(runID: String, now: Int64) throws -> Int {
        guard UUID(uuidString: runID) != nil, now >= 0 else { throw CollectorSpoolGCError.invalidInput }
        return try owner.withSpoolGC { queue in
            guard try queue.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM collector_gc_runs WHERE run_id=?)", arguments: [runID]) }) == true else {
                throw CollectorSpoolGCError.unknownRun
            }
            let work = Work(now: now)
            var count = 0
            for row in try queue.read({ try CollectorSpoolGCJournal.rows($0, runID: runID) }) {
                let state: String = row["state"]
                if state == "cancelled" { continue }
                if state == "evicted" { throw CollectorSpoolGCError.spoolRestoreRequired }
                try restoreRow(queue, row: row, now: now, work: work); count += 1
            }
            return count
        }
    }

    func restoreRow(_ queue: DatabaseQueue, row: Row, now: Int64, work supplied: Work? = nil) throws {
        let work = supplied ?? Work(now: now)
        try work.charge()
        let digest: String = row["digest"], size: Int64 = row["raw_bytes"], run: String = row["run_id"]
        let path: String = row["quarantine_path"]
        guard try path == CollectorSpoolGCFiles.quarantine(digest, runID: run) else { throw CollectorSpoolGCError.unsafePath }
        let resident = try CollectorSpoolGCFiles.resident(digest)
        let original = try files.verify(resident, digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) })
        let quarantined = try files.verify(path, digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) })
        guard original != nil || quarantined != nil else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
        try queue.write { db in
            try db.execute(sql: "UPDATE collector_gc_objects SET state='restorePrepared',verified_at=? WHERE run_id=? AND digest=? AND state!='evicted'",
                arguments: [now, run, digest])
            guard db.changesCount == 1 else { throw CollectorSpoolGCError.scopeChanged }
        }
        if original == nil, let quarantined {
            try work.charge(size); try work.charge(size)
            try files.move(path, to: resident, digest: digest, expected: quarantined) }
        try queue.write { try CollectorSpoolGCJournal.markResident($0, digest: digest, now: now) }
    }

    func recoverUnlinkIntent(_ queue: DatabaseQueue, row: Row, now: Int64, work supplied: Work? = nil) throws {
        let work = supplied ?? Work(now: now)
        try work.charge()
        let digest: String = row["digest"], size: Int64 = row["raw_bytes"], path: String = row["quarantine_path"]
        if try files.verify(path, digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) }) != nil {
            try restoreRow(queue, row: row, now: now, work: work); return
        }
        if try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) }) != nil {
            try queue.write { try CollectorSpoolGCJournal.markResident($0, digest: digest, now: now) }; return
        }
        let runID: String = row["run_id"], verifiedAt: Int64 = row["verified_at"]
        guard let bytes: Data = row["unlink_evidence_bytes"], let hash: String = row["unlink_approval_hash"],
              ArchiveV2Hash.sha256(bytes) == hash,
              let approval = try? ArchiveCanonicalJSON.decode(CollectorSpoolGCApproval.self, from: bytes),
              (try? approval.validateTime(now: verifiedAt)) != nil,
              approval.action == "finalize", approval.runID == runID,
              approval.spoolIdentity == files.scopeIdentity,
              try path == CollectorSpoolGCFiles.quarantine(digest, runID: runID),
              let run = try queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM collector_gc_runs WHERE run_id=?", arguments: [runID]) }),
              (run["machine_id"] as String) == approval.machineID,
              verifiedAt >= (run["hold_until"] as Int64), size <= approval.maxBytes, approval.maxObjects > 0,
              let residency = try queue.read({ try CollectorSpoolGCJournal.residency($0, digest) }),
              (residency["run_id"] as String) == runID, (residency["state"] as String) == "unlinkPrepared",
              (residency["generation"] as Int64) == (row["residency_generation"] as Int64) else {
            throw CollectorSpoolGCError.spoolIntegrityBlocked
        }
        try completeEviction(queue, runID: runID, digest: digest, bytes: size, now: now)
    }
}
