import Darwin
import Foundation
import GRDB

extension CollectorSpoolGCSession {
    struct ExecutionReport: Codable {
        let runID: String
        let action: String
        var objects = 0
        var uniqueRawBytes: Int64 = 0
        var allocatedBytesObserved: Int64 = 0
        var restoredObjects = 0
        var referencedLogicalBytes: Int64 = 0
        var uniquePresentCandidateBytes: Int64 = 0
        var keptBytes: Int64 = 0
        var unknownOrphanBytes: Int64 = 0
        var existingQuarantineBytes: Int64 = 0
        var blockedCaptureCounts: [String: Int] = [:]
        var freeBytesBefore: Int64 = 0
        var freeBytesAfter: Int64 = 0
    }

    final class Work: @unchecked Sendable {
        let started = ProcessInfo.processInfo.systemUptime
        let base: Int64
        var bytes: Int64 = 0
        init(now: Int64) { base = now }
        var now: Int64 {
            let sum = base.addingReportingOverflow(Int64(ProcessInfo.processInfo.systemUptime - started))
            return sum.overflow ? Int64.max : sum.partialValue
        }
        func charge(_ count: Int64 = 0) throws {
            try Task.checkCancellation()
            guard count >= 0, count <= 256 * 1024 * 1024 * 1024 - bytes,
                  ProcessInfo.processInfo.systemUptime - started <= 300 else { throw CollectorSpoolGCError.budgetExceeded }
            bytes += count
        }
    }

    static func protectedSetHash(_ snapshot: Snapshot) throws -> String {
        guard let graph = snapshot.graph else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
        let captures = Set(graph.keep.flatMap { graph.refs[$0] ?? [] })
        let manifests = captures.compactMap { snapshot.catalog.captures[$0]?.digest }.sorted()
        return ArchiveV2Hash.sha256(Data((graph.keep.sorted().joined(separator: "\n") + "\n--manifests--\n" + manifests.joined(separator: "\n")).utf8))
    }

    static func referenceHash(_ digest: String, snapshot: Snapshot) throws -> String {
        guard let refs = snapshot.graph?.refs[digest] else { throw CollectorSpoolGCError.scopeChanged }
        let publications = snapshot.inventory.publications.values.filter { refs.contains($0.captureID) }.map(\.digest).sorted()
        return ArchiveV2Hash.sha256(Data((refs.sorted().joined(separator: "\n") + "\n--publications--\n" + publications.joined(separator: "\n")).utf8))
    }

    func configuration(_ settingsURL: URL) throws -> CollectorRuntimeConfiguration {
        guard let config = try CollectorRuntimeConfiguration.load(at: settingsURL),
              try CollectorMachineIdentityReader.canonicalExistingPath(config.shadowURL) == CollectorMachineIdentityReader.canonicalExistingPath(spoolRoot) else {
            throw CollectorSpoolGCError.scopeChanged
        }
        return config
    }

    /// Check current native heads, never historical candidate generations. Unknown
    /// projected mappings stay blocked; no native recapture grants GC authority.
    func nativeHash(_ queue: DatabaseQueue, snapshot: Snapshot, config: CollectorRuntimeConfiguration,
                    captures: Set<String>) throws -> String {
        let publications = snapshot.inventory.publications.values.filter { captures.contains($0.captureID) }
        for publication in publications {
            guard let source = snapshot.catalog.captures[publication.captureID]?.manifest.source,
                  let stream = try queue.read({ try Row.fetchOne($0, sql: "SELECT source_instance_id,collector_epoch FROM collector_streams WHERE root_id=? AND root_revision=? AND effective_source=?", arguments: [publication.root, publication.revision, source]) }),
                  (stream["source_instance_id"] as String) == publication.envelope.sourceInstanceID,
                  (stream["collector_epoch"] as String) == publication.envelope.collectorEpoch else { throw CollectorSpoolGCError.scopeChanged }
        }
        let keys = Set(publications.map { CollectorSpoolGCPreview.LocatorKey(root: $0.root, revision: $0.revision, path: $0.path) })
        var evidence = Data()
        for key in keys.sorted(by: { ($0.root, $0.revision, $0.path) < ($1.root, $1.revision, $1.path) }) {
            guard let root = config.rootConfigurations.first(where: { $0.rootID == key.root && $0.revision == key.revision }),
                  let locator = snapshot.inventory.locators[key], let headID: String = locator["last_capture_id"],
                  let head = snapshot.catalog.captures[headID],
                  head.manifest.locator == root.rootPath + "/" + key.path,
                  let binding = try queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM collector_root_bindings WHERE root_id=? AND root_revision=?", arguments: [key.root, key.revision]) }) else {
                throw CollectorSpoolGCError.scopeChanged
            }
            let opened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(root.rootPath))
            defer { close(opened.descriptor) }
            let identity = try CollectorPOSIXDirectoryAccess.identity(opened.info)
            guard identity.device == (binding["device"] as Int64), identity.inode == (binding["inode"] as Int64),
                  Int64(identity.generation) == (binding["generation"] as Int64), identity.birthSeconds == (binding["birth_seconds"] as Int64),
                  identity.birthNanoseconds == (binding["birth_nanoseconds"] as Int64) else { throw CollectorSpoolGCError.scopeChanged }
            let nativeEpoch = try CollectorNativeEventStream.currentEpoch(binding: .init(configuration: root, expectedIdentity: identity))
            guard let storedRoot = snapshot.inventory.roots[key.root],
                  let storedEpoch: String = storedRoot["event_epoch"], storedEpoch == nativeEpoch else { throw CollectorSpoolGCError.scopeChanged }
            evidence.append(Data((nativeEpoch + "\n").utf8))
            evidence.append(Data("\(key.root):\(key.revision):\(key.path):\(identity.device):\(identity.inode):\(identity.generation):\(identity.birthSeconds):\(identity.birthNanoseconds)\n".utf8))
            let layout = head.manifest.replayLayout
            guard layout.sqliteSession == nil, layout.cursorLegacySession == nil,
                  layout.vscodeWorkspaceContext == nil, layout.geminiProjectContext == nil, layout.kimiProjectContext == nil else {
                throw CollectorSpoolGCError.scopeChanged
            }
            if layout.strategy == .singleFile {
                let current = try CollectorPublicationWorker.sourceGeneration(root: root, relativePath: key.path)
                guard current == head.manifest.generation,
                      let observed: String = locator["observed_generation"],
                      try observed == "stat-v1:" + String(decoding: ArchiveCanonicalJSON.encode(current), as: UTF8.self) else {
                    throw CollectorSpoolGCError.scopeChanged
                }
                evidence.append(try ArchiveCanonicalJSON.encode(current))
            } else {
                guard let entrypoint = layout.entrypointRelativePath, let parts = layout.files,
                      key.path == entrypoint || key.path.hasSuffix("/" + entrypoint) else { throw CollectorSpoolGCError.scopeChanged }
                let prefix = String(key.path.dropLast(entrypoint.count))
                for part in parts {
                    let current = try CollectorPublicationWorker.sourceGeneration(root: root, relativePath: prefix + part.relativePath)
                    guard current == part.generation else { throw CollectorSpoolGCError.scopeChanged }
                    evidence.append(try ArchiveCanonicalJSON.encode(current))
                }
                for absent in layout.absentRelativePaths ?? [] {
                    do {
                        _ = try CollectorPublicationWorker.sourceGeneration(root: root, relativePath: prefix + absent)
                        throw CollectorSpoolGCError.scopeChanged
                    } catch let error as POSIXError where error.code == .ENOENT {
                        evidence.append(Data(("absent:" + prefix + absent + "\n").utf8))
                    }
                }
            }
            let reopened = try CollectorPOSIXDirectoryAccess.openAbsolute(components: CollectorPOSIXDirectoryAccess.components(root.rootPath))
            defer { close(reopened.descriptor) }
            guard try CollectorPOSIXDirectoryAccess.identity(reopened.info) == identity else { throw CollectorSpoolGCError.scopeChanged }
        }
        return ArchiveV2Hash.sha256(evidence)
    }

    struct Checked {
        let snapshot: Snapshot
        let config: CollectorRuntimeConfiguration
        let captures: Set<String>
        let candidates: [String]
    }

    func check(_ queue: DatabaseQueue, approval: CollectorSpoolGCApproval, settingsURL: URL, work: Work) throws -> Checked {
        try work.charge(); try approval.validateTime(now: work.now)
        let config = try configuration(settingsURL)
        let current = try snapshot(queue, evidence: approval.central)
        guard approval.machineID == current.inventory.machine, approval.spoolIdentity == files.scopeIdentity,
              approval.scopeSHA256 == current.hash,
              try CollectorMachineIdentityReader.read(from: config.identityURL) == current.inventory.machine,
              approval.configurationSHA256 == ArchiveV2Hash.sha256(config.authorityBytes),
              try approval.policySHA256 == config.freshPolicy(at: settingsURL).sha256() else { throw CollectorSpoolGCError.scopeChanged }
        for replica in approval.replicas {
            guard config.replicas.contains(where: { $0.serverID == replica.serverID && $0.baseURL == replica.endpoint }) else {
                throw CollectorSpoolGCError.proofMissing
            }
        }
        guard let graph = current.graph else {
            return Checked(snapshot: current, config: config, captures: [], candidates: [])
        }
        let candidates = Set(graph.refs.keys).subtracting(graph.keep).sorted { left, right in
            let a = graph.refs[left]!.map { current.catalog.captures[$0]!.manifest.capturedAt }.max()!
            let b = graph.refs[right]!.map { current.catalog.captures[$0]!.manifest.capturedAt }.max()!
            return (a, left) < (b, right)
        }
        let captures = Set(candidates.flatMap { graph.refs[$0]! })
        do {
            guard try nativeHash(queue, snapshot: current, config: config, captures: captures) == approval.nativeSHA256 else {
                throw CollectorSpoolGCError.scopeChanged
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // Unreadable/missing native state cannot prove continued eligibility.
            // Normalize native-read failures so finalize restores local quarantine.
            throw CollectorSpoolGCError.scopeChanged
        }
        let protectedCaptures = Set(graph.keep.flatMap { graph.refs[$0]! })
        let protectedManifests = Set(protectedCaptures.map { current.catalog.captures[$0]!.digest })
        guard try Self.protectedSetHash(current) == approval.escrow.protectedSetSHA256,
              graph.keep.isSubset(of: Set(approval.escrow.objects)),
              protectedManifests.isSubset(of: Set(approval.escrow.manifests)) else { throw CollectorSpoolGCError.escrowMissing }
        return Checked(snapshot: current, config: config, captures: captures, candidates: candidates)
    }

    func measure(_ queue: DatabaseQueue, checked: Checked, report: inout ExecutionReport, work: Work) throws {
        guard let graph = checked.snapshot.graph else { return }
        func sum(_ values: [Int64]) throws -> Int64 {
            try values.reduce(0) { total, next in
                let value = total.addingReportingOverflow(next)
                guard next >= 0, !value.overflow else { throw CollectorSpoolGCError.budgetExceeded }
                return value.partialValue
            }
        }
        let objects = try files.census { try work.charge() }
        report.referencedLogicalBytes = try sum(checked.snapshot.catalog.captures.values.map { $0.manifest.rawByteCount })
        report.keptBytes = try sum(graph.keep.map { graph.sizes[$0]! })
        report.uniquePresentCandidateBytes = try sum(checked.candidates.compactMap { objects[$0]?.bytes })
        report.unknownOrphanBytes = try sum(objects.filter { graph.refs[$0.key] == nil }.map { $0.value.bytes })
        report.blockedCaptureCounts = Dictionary(grouping: graph.captureReasons.values, by: { $0 }).mapValues(\.count)
        var quarantine: [Int64] = []
        for row in try queue.read({ try CollectorSpoolGCJournal.rows($0) }) {
            try work.charge()
            let digest: String = row["digest"], path: String = row["quarantine_path"], runID: String = row["run_id"]
            guard try path == CollectorSpoolGCFiles.quarantine(digest, runID: runID) else { throw CollectorSpoolGCError.unsafePath }
            if let identity = try files.verify(path, digest: digest, bytes: row["raw_bytes"], hash: false) { quarantine.append(identity.bytes) }
        }
        report.existingQuarantineBytes = try sum(quarantine)
    }

    func verifyProtected(_ checked: Checked, work: Work) throws {
        guard let graph = checked.snapshot.graph else { return }
        // Verify every manifest file too, including unselected/unpublished captures.
        for capture in checked.snapshot.catalog.captures.values {
            let encoded = try ArchiveCanonicalJSON.encode(capture.manifest)
            let relative = "capture/manifests/sha256/\(capture.digest.prefix(2))/\(capture.digest).json"
            guard try files.verify(relative, digest: capture.digest, bytes: Int64(encoded.count), consume: { try work.charge(Int64($0.count)) }) != nil else {
                throw CollectorSpoolGCError.spoolIntegrityBlocked
            }
        }
        for digest in graph.keep.sorted() {
            guard try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: graph.sizes[digest]!,
                consume: { try work.charge(Int64($0.count)) }) != nil else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
        }
    }

    func verifyProof(_ queue: DatabaseQueue, _ approval: CollectorSpoolGCApproval, checked: Checked, digests: [String],
                     paths: [String: String], settingsURL: URL, work: Work) throws {
        let state = checked.snapshot, graph = state.graph!
        let captures = Set(digests.flatMap { graph.refs[$0] ?? [] })
        let evicted = try queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT digest FROM collector_spool_object_residency WHERE state='evicted'"))
        }
        let cas = try ImmutableArchiveCAS(root: spoolRoot.appendingPathComponent("capture")).withCollectorVerificationRead { [self] digest, maximum in
            guard let size = graph.sizes[digest] else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
            try work.charge(size)
            if paths[digest] == nil, evicted.contains(digest),
               try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size, hash: false) == nil {
                throw CollectorSpoolGCError.spoolRestoreRequired
            }
            return try files.read(paths[digest] ?? CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size, maximumBytes: maximum)
        }
        let policy = try checked.config.freshPolicy(at: settingsURL)
        for id in captures.sorted() {
            try work.charge()
            guard let capture = try catalog.capture(captureID: id), let value = state.catalog.captures[id] else {
                throw CollectorSpoolGCError.spoolIntegrityBlocked
            }
            let publications = state.inventory.publications.values.filter { $0.captureID == id }
            for publication in publications {
                guard let format = checked.config.rootFormats[publication.root],
                      case .eligible(let proof) = try CollectorPrivacyProof.assess(
                        capture: ArchiveCaptureResult(capture: capture, manifest: value.manifest), cas: cas, format: format, policy: policy,
                        limits: CollectorPrivacyProof.limits(format: format, maximumSourceBytes: checked.config.budgets.maxCaptureBytes)),
                      proof.isCurrent(for: ArchiveCaptureResult(capture: capture, manifest: value.manifest), policy: policy, format: format) else {
                    throw CollectorSpoolGCError.privacyWithheld
                }
                for replica in approval.replicas {
                    guard let ackRow = state.inventory.replicas[publication.digest]?.first(where: { ($0["replica_id"] as String) == replica.serverID }),
                          let ackBytes: Data = ackRow["ack_bytes"] else { throw CollectorSpoolGCError.proofMissing }
                    let ack = try ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: ackBytes)
                    let record = try CollectorPublicationAcceptanceRecord(publication: publication.envelope, ack: ack)
                    guard ack.journalID == replica.journalID,
                          replica.acceptanceSHA256[publication.digest] == ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(record)),
                          replica.manifests[value.digest] == value.manifest.wholeSourceSHA256,
                          value.manifest.chunks.allSatisfy({ replica.objects[$0.rawSHA256] == $0.rawByteCount }) else {
                        throw CollectorSpoolGCError.proofMissing
                    }
                }
            }
        }
    }

    @discardableResult
    func apply(approval: CollectorSpoolGCApproval?, settingsURL: URL, now: Int64) throws -> ExecutionReport {
        guard let approval else { throw CollectorSpoolGCError.proofMissing }
        guard approval.action == "apply" else { throw CollectorSpoolGCError.invalidEvidence }
        let work = Work(now: now)
        return try owner.withSpoolGC { queue in
            let checked = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
            var report = ExecutionReport(runID: approval.runID, action: "quarantine")
            guard let graph = checked.snapshot.graph else { return report }
            try measure(queue, checked: checked, report: &report, work: work)
            guard try queue.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_gc_runs WHERE run_id=?", arguments: [approval.runID]) }) == 0 else {
                throw CollectorSpoolGCError.scopeChanged
            }
            try verifyProtected(checked, work: work)
            var selected: [String] = [], identities: [String: CollectorSpoolGCFiles.Identity] = [:]
            for digest in checked.candidates {
                try work.charge()
                let size = graph.sizes[digest]!
                guard selected.count < approval.maxObjects, size <= approval.maxBytes - report.uniqueRawBytes else { continue }
                guard let identity = try files.verify(CollectorSpoolGCFiles.resident(digest), digest: digest, bytes: size,
                    consume: { try work.charge(Int64($0.count)) }) else { continue }
                if let row = try queue.read({ try CollectorSpoolGCJournal.residency($0, digest) }), (row["state"] as String) != "resident" {
                    throw CollectorSpoolGCError.scopeChanged
                }
                selected.append(digest); identities[digest] = identity
                report.uniqueRawBytes += size; report.allocatedBytesObserved += identity.allocatedBytes
            }
            guard !selected.isEmpty else { return report }
            try verifyProof(queue, approval, checked: checked, digests: selected, paths: [:], settingsURL: settingsURL, work: work)
            report.freeBytesBefore = try files.availableBytes()
            guard report.freeBytesBefore >= max(64 * 1024 * 1024, checked.config.budgets.minimumFreeDiskBytes) else {
                throw CollectorSpoolGCError.budgetExceeded
            }
            let bytes = try approval.bytes(), approvalHash = ArchiveV2Hash.sha256(bytes)
            _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO collector_gc_runs(run_id,machine_id,scope_hash,approval_hash,evidence_bytes,state,created_at,hold_until,max_bytes,max_objects,reserved_bytes,reserved_objects)
                    VALUES (?,?,?,?,?,'prepared',?,?,?,?,?,?)
                    """, arguments: [approval.runID, approval.machineID, approval.scopeSHA256, approvalHash, bytes,
                        work.now, work.now + approval.holdSeconds, approval.maxBytes, approval.maxObjects, report.uniqueRawBytes, selected.count])
                for digest in selected {
                    let generation = try CollectorSpoolGCJournal.residency(db, digest).map { ($0["generation"] as Int64) } ?? 0
                    guard generation < Int64.max else { throw CollectorSpoolGCError.budgetExceeded }
                    let path = try CollectorSpoolGCFiles.quarantine(digest, runID: approval.runID)
                    try db.execute(sql: """
                        INSERT INTO collector_gc_objects(run_id,digest,raw_bytes,reference_hash,quarantine_path,identity_bytes,state,residency_generation,verified_at)
                        VALUES (?,?,?,?,?,?,'quarantinePrepared',?,?)
                        """, arguments: [approval.runID, digest, graph.sizes[digest]!, try Self.referenceHash(digest, snapshot: checked.snapshot), path,
                            try ArchiveCanonicalJSON.encode(identities[digest]!), generation + 1, work.now])
                    try db.execute(sql: """
                        INSERT INTO collector_spool_object_residency(digest,raw_bytes,state,run_id,quarantine_path,evidence_hash,verified_at,generation)
                        VALUES (?,?,'quarantinePrepared',?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET
                        raw_bytes=excluded.raw_bytes,state=excluded.state,run_id=excluded.run_id,quarantine_path=excluded.quarantine_path,
                        evidence_hash=excluded.evidence_hash,verified_at=excluded.verified_at,generation=excluded.generation
                        """, arguments: [digest, graph.sizes[digest]!, approval.runID, path, approvalHash, work.now, generation + 1])
                }
            }
            do {
                try transitionHook?("reserved", "")
                for digest in selected {
                    _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                    try transitionHook?("beforeRename", digest)
                    _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                    try files.move(CollectorSpoolGCFiles.resident(digest), to: CollectorSpoolGCFiles.quarantine(digest, runID: approval.runID), digest: digest, expected: identities[digest]!)
                    try transitionHook?("afterRename", digest)
                    _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                    try queue.write { db in
                        try CollectorSpoolGCJournal.setState(db, runID: approval.runID, digest: digest, from: "quarantinePrepared", to: "quarantined", now: work.now)
                        try db.execute(sql: "UPDATE collector_gc_runs SET state='quarantined',hold_until=MAX(hold_until,?) WHERE run_id=?",
                            arguments: [work.now + approval.holdSeconds, approval.runID])
                    }
                    try transitionHook?("quarantined", digest)
                    report.objects += 1
                }
                try verifyProtected(checked, work: work)
                _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                report.freeBytesAfter = try files.availableBytes()
                return report
            } catch is SimulatedCrash { throw SimulatedCrash() }
            catch {
                try restoreIncomplete(queue, runID: approval.runID, now: work.now)
                throw error
            }
        }
    }

    func restoreIncomplete(_ queue: DatabaseQueue, runID: String, now: Int64) throws {
        for row in try queue.read({ try CollectorSpoolGCJournal.rows($0, runID: runID) }) {
            if ["quarantinePrepared", "quarantined", "restorePrepared", "unlinkPrepared"].contains(row["state"] as String) {
                if (row["state"] as String) == "unlinkPrepared" { try recoverUnlinkIntent(queue, row: row, now: now) }
                else { try restoreRow(queue, row: row, now: now) }
            }
        }
    }

    @discardableResult
    func finalize(approval: CollectorSpoolGCApproval?, settingsURL: URL, now: Int64) throws -> ExecutionReport {
        guard let approval else { throw CollectorSpoolGCError.proofMissing }
        guard approval.action == "finalize" else { throw CollectorSpoolGCError.invalidEvidence }
        let work = Work(now: now)
        return try owner.withSpoolGC { queue in
            try approval.validateTime(now: work.now)
            guard let run = try queue.read({ try Row.fetchOne($0, sql: "SELECT * FROM collector_gc_runs WHERE run_id=?", arguments: [approval.runID]) }) else {
                throw CollectorSpoolGCError.unknownRun
            }
            guard work.now >= (run["hold_until"] as Int64) else { throw CollectorSpoolGCError.holdNotElapsed }
            let checked: Checked
            do { checked = try check(queue, approval: approval, settingsURL: settingsURL, work: work) }
            catch let error as CollectorSpoolGCError where error == .scopeChanged || error == .privacyWithheld {
                try restoreIncomplete(queue, runID: approval.runID, now: work.now)
                throw error
            }
            guard let graph = checked.snapshot.graph else { throw CollectorSpoolGCError.spoolIntegrityBlocked }
            var report = ExecutionReport(runID: approval.runID, action: "finalize")
            try measure(queue, checked: checked, report: &report, work: work)
            var selected: [Row] = [], paths: [String: String] = [:]
            for row in try queue.read({ try CollectorSpoolGCJournal.rows($0, runID: approval.runID) }) {
                let state: String = row["state"], digest: String = row["digest"]
                if state == "cancelled" || state == "evicted" { continue }
                guard state == "quarantined" else { throw CollectorSpoolGCError.scopeChanged }
                let residency = try queue.read { try CollectorSpoolGCJournal.residency($0, digest) }
                guard let residency, (residency["generation"] as Int64) == (row["residency_generation"] as Int64),
                      (residency["run_id"] as String) == approval.runID, (residency["state"] as String) == "quarantined" else {
                    throw CollectorSpoolGCError.scopeChanged
                }
                if try !checked.candidates.contains(digest) || Self.referenceHash(digest, snapshot: checked.snapshot) != (row["reference_hash"] as String) {
                    try restoreRow(queue, row: row, now: work.now); report.restoredObjects += 1; continue
                }
                let size: Int64 = row["raw_bytes"]
                guard size == graph.sizes[digest], size <= approval.maxBytes - report.uniqueRawBytes, selected.count < approval.maxObjects else {
                    throw CollectorSpoolGCError.budgetExceeded
                }
                selected.append(row); paths[digest] = row["quarantine_path"]; report.uniqueRawBytes += size
            }
            let finalizedCount = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM collector_gc_objects WHERE run_id=? AND state='evicted'", arguments: [approval.runID]) ?? 0 }
            guard (run["finalized_bytes"] as Int64) <= approval.maxBytes,
                  report.uniqueRawBytes <= approval.maxBytes - (run["finalized_bytes"] as Int64),
                  finalizedCount <= approval.maxObjects, selected.count <= approval.maxObjects - finalizedCount,
                  report.uniqueRawBytes <= (run["reserved_bytes"] as Int64), selected.count <= (run["reserved_objects"] as Int) else {
                throw CollectorSpoolGCError.budgetExceeded
            }
            try verifyProtected(checked, work: work)
            guard !selected.isEmpty else { return report }
            do {
                try verifyProof(queue, approval, checked: checked, digests: selected.map { $0["digest"] }, paths: paths, settingsURL: settingsURL, work: work)
            } catch let error as CollectorSpoolGCError where error == .privacyWithheld {
                try restoreIncomplete(queue, runID: approval.runID, now: work.now)
                throw error
            }
            let bytes = try approval.bytes(), hash = ArchiveV2Hash.sha256(bytes)
            report.freeBytesBefore = try files.availableBytes()
            guard report.freeBytesBefore >= max(64 * 1024 * 1024, checked.config.budgets.minimumFreeDiskBytes) else { throw CollectorSpoolGCError.budgetExceeded }
            do {
                for row in selected {
                    let digest: String = row["digest"], size: Int64 = row["raw_bytes"], path: String = row["quarantine_path"]
                    guard try path == CollectorSpoolGCFiles.quarantine(digest, runID: approval.runID),
                          let identity = try files.verify(path, digest: digest, bytes: size, consume: { try work.charge(Int64($0.count)) }),
                          identity == (try ArchiveCanonicalJSON.decode(CollectorSpoolGCFiles.Identity.self, from: row["identity_bytes"])) else {
                        throw CollectorSpoolGCError.scopeChanged
                    }
                    _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                    try queue.write { db in
                        try CollectorSpoolGCJournal.setState(db, runID: approval.runID, digest: digest, from: "quarantined", to: "unlinkPrepared", now: work.now)
                        try db.execute(sql: "UPDATE collector_gc_objects SET unlink_approval_hash=?,unlink_evidence_bytes=? WHERE run_id=? AND digest=?",
                            arguments: [hash, bytes, approval.runID, digest])
                    }
                    try transitionHook?("unlinkPrepared", digest)
                    try files.finalizeUnlink(path, digest: digest, expected: identity) {
                        _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                        try queue.read { db in
                            guard let resident = try CollectorSpoolGCJournal.residency(db, digest),
                                  (resident["state"] as String) == "unlinkPrepared", (resident["run_id"] as String) == approval.runID,
                                  (resident["generation"] as Int64) == (row["residency_generation"] as Int64),
                                  try String.fetchOne(db, sql: "SELECT unlink_approval_hash FROM collector_gc_objects WHERE run_id=? AND digest=? AND state='unlinkPrepared'",
                                    arguments: [approval.runID, digest]) == hash else { throw CollectorSpoolGCError.scopeChanged }
                        }
                    }
                    try transitionHook?("afterUnlink", digest)
                    try completeEviction(queue, runID: approval.runID, digest: digest, bytes: size, now: work.now)
                    report.objects += 1; report.allocatedBytesObserved += identity.allocatedBytes
                    _ = try check(queue, approval: approval, settingsURL: settingsURL, work: work)
                    try transitionHook?("evicted", digest)
                }
                try verifyProtected(checked, work: work)
                report.freeBytesAfter = try files.availableBytes()
                return report
            } catch is SimulatedCrash { throw SimulatedCrash() }
            catch {
                try restoreIncomplete(queue, runID: approval.runID, now: work.now)
                throw error
            }
        }
    }

    func completeEviction(_ queue: DatabaseQueue, runID: String, digest: String, bytes: Int64, now: Int64) throws {
        try queue.write { db in
            try CollectorSpoolGCJournal.setState(db, runID: runID, digest: digest, from: "unlinkPrepared", to: "evicted", now: now)
            try db.execute(sql: "UPDATE collector_gc_runs SET finalized_bytes=finalized_bytes+?,state='finalized' WHERE run_id=? AND finalized_bytes<=reserved_bytes-?",
                arguments: [bytes, runID, bytes])
            guard db.changesCount == 1 else { throw CollectorSpoolGCError.budgetExceeded }
        }
    }
}
