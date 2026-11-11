import Darwin
import Foundation
import GRDB

/// Phase B1 inspection only. This type has no writer, owner, credential loader,
/// network client, CAS constructor, or reclamation capability.
public enum CollectorSpoolGCPreview {
    public enum Failure: String, Error {
        case invalidInput, unsupportedSchema, incompleteGraph, emptyGraph, emptyKeepSet
        case keepSetFloorViolation, invalidManifest, invalidPublication, invalidEvidence
        case unsafeObject, missingProtectedObject, inputChanged, resourceLimit
    }

    public struct Bucket: Codable {
        public let reason: String
        public var objects: Int = 0
        public var bytes: Int64 = 0
    }

    public struct Report: Codable {
        public let schemaVersion: Int
        public let previewOnly: Bool
        public let provisional: Bool
        public let actionableBytes: Int64
        public let captureCount: Int
        public let referencedObjects: Int
        public let protectedObjects: Int
        public let presentBytes: Int64
        public let missingReferencedBytes: Int64
        public let missingProtectedByACK: [Bucket]
        public let potentialBytesBeforeProofAndEscrow: Int64
        public let budgetedPotentialBytes: Int64
        public let budgetedPotentialObjects: Int
        public let blocked: [String]
        public let unverified: [String]
        public let firstBlockingGate: [Bucket]
        public let captureFirstBlockingGate: [String: Int]
        public let sharedPinCauses: [Bucket]
        public let inventoryFingerprint: String
        public let catalogFingerprint: String
        public let centralEvidenceSHA256: String?

        public func bytes(_ reason: String) -> Int64 { firstBlockingGate.first { $0.reason == reason }?.bytes ?? 0 }
    }

    // Order is part of the report contract; buckets are mutually exclusive.
    static let gateOrder = ["latest", "dirty_k6", "withheld", "local_content_unavailable", "pending", "inflight",
                            "not_dual_acked", "central_evidence_missing", "central_parsed_skip", "central_other",
                            "duplicate_unprovable", "shared_pinned", "proof_missing", "escrow"]
    private static let maximumRows = 250_000
    private static let maximumMetadataBytes = 256 * 1024 * 1024
    private static let maximumReferences = 2_000_000

    public static func spoolRoot(settingsURL: URL) throws -> URL {
        guard let data = SecureRegularFile.read(atPath: settingsURL.path, maximumBytes: RuntimeRoleSettings.maximumBytes, repairPermissions: false),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["runtimeRole"] as? String == "collector",
              let block = document["collector"] as? [String: Any], block["enabled"] as? Bool == true,
              let path = block["shadowRoot"] as? String,
              CollectorMachineIdentityReader.isAbsoluteLexicalPath(path) else { throw Failure.invalidInput }
        return URL(fileURLWithPath: path)
    }

    public static func run(spoolRoot: URL, centralEvidence: URL? = nil,
                           maxBytes: Int64 = 256 * 1024 * 1024, maxObjects: Int = 128) throws -> Report {
        guard maxBytes >= 0, maxObjects >= 0, spoolRoot.isFileURL,
              (try? CollectorMachineIdentityReader.canonicalExistingPath(spoolRoot)) != nil else { throw Failure.invalidInput }
        let inventoryURL = spoolRoot.appendingPathComponent("inventory/inventory.sqlite")
        let catalogURL = spoolRoot.appendingPathComponent("capture/archive.sqlite")
        let evidence = try centralEvidence.map(Evidence.load)
        let inventory = try readInventory(inventoryURL)
        let catalog = try readCatalog(catalogURL, machine: inventory.machine)
        let report = try evaluate(inventory, catalog, spoolRoot: spoolRoot, evidence: evidence, maxBytes: maxBytes, maxObjects: maxObjects)
        // Two stores are not one transaction. Re-read both complete inputs; any
        // change invalidates the estimate, never becomes a mixed apply plan.
        guard try readInventory(inventoryURL).fingerprint == inventory.fingerprint,
              try readCatalog(catalogURL, machine: inventory.machine).fingerprint == catalog.fingerprint else { throw Failure.inputChanged }
        return report
    }

    static func validateKeepSet(graph: Set<String>, keep: Set<String>, floor: Set<String>) throws {
        guard !graph.isEmpty else { throw Failure.emptyGraph }
        guard !keep.isEmpty else { throw Failure.emptyKeepSet }
        guard floor.isSubset(of: keep), keep.isSubset(of: graph) else { throw Failure.keepSetFloorViolation }
    }

    struct Capture {
        let manifest: ArchiveSourceManifest
        let digest: String
        let status: String
    }
    struct Catalog {
        let captures: [String: Capture]
        let fingerprint: String
    }
    struct Publication {
        let captureID: String
        let digest: String
        let root: String
        let revision: Int64
        let path: String
        let envelope: CollectorPublicationEnvelope
    }
    struct Inventory {
        let machine: String
        let publications: [String: Publication]
        let replicas: [String: [Row]]
        let locators: [LocatorKey: Row]
        let roots: [String: Row]
        let reservedRoots: Set<String>
        let fingerprint: String
    }
    struct LocatorKey: Hashable {
        let root: String
        let revision: Int64
        let path: String
    }
    struct CentralRow: Codable {
        let publicationSHA256: String
        let manifestSHA256: String
        let machineID: String
        let sourceInstanceID: String
        let collectorEpoch: String
        let sequence: Int64
        let status: String
        let failureCode: String?
        let hasRetainedGeneration: Bool
    }
    struct Evidence: Codable {
        let schemaVersion: Int
        let generatedAt: String
        let parserRevision: String
        let publications: [CentralRow]
        var digest: String?

        static func load(_ url: URL) throws -> Self {
            guard let bytes = SecureRegularFile.read(atPath: url.path, maximumBytes: maximumMetadataBytes, repairPermissions: false),
                  var result = try? JSONDecoder().decode(Self.self, from: bytes), result.schemaVersion == 1,
                  result.parserRevision == "swift-capture-v1", result.publications.count <= maximumRows,
                  let timestamp = ISO8601DateFormatter().date(from: result.generatedAt),
                  Date().timeIntervalSince(timestamp) >= -300, Date().timeIntervalSince(timestamp) <= 86_400,
                  Set(result.publications.map(\.publicationSHA256)).count == result.publications.count,
                  result.publications.allSatisfy({ ArchiveV2Hash.isValidSHA256($0.publicationSHA256) && ArchiveV2Hash.isValidSHA256($0.manifestSHA256) })
            else { throw Failure.invalidEvidence }
            result.digest = ArchiveV2Hash.sha256(bytes)
            return result
        }
    }

    static func value<T: DatabaseValueConvertible>(_ row: Row, _ column: String, as type: T.Type = T.self) throws -> T {
        guard row.hasColumn(column) else { throw Failure.unsupportedSchema }
        let raw: DatabaseValue = row[column]
        guard let result = T.fromDatabaseValue(raw) else { throw Failure.invalidInput }
        return result
    }

    static func rows(_ db: Database, _ table: String, order: String) throws -> [Row] {
        // All names are static literals supplied below, never CLI input.
        guard let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), count <= maximumRows else { throw Failure.resourceLimit }
        let lengths = try db.columns(in: table).map { column in
            "COALESCE(length(CAST(\"\(column.name.replacingOccurrences(of: "\"", with: "\"\""))\" AS BLOB)),0)"
        }.joined(separator: "+")
        guard let bytes = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(\(lengths)),0) FROM \(table)"),
              bytes >= 0, bytes <= maximumMetadataBytes else { throw Failure.resourceLimit }
        let values = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order) LIMIT \(maximumRows + 1)")
        guard values.count <= maximumRows else { throw Failure.resourceLimit }
        return values
    }

    static func fingerprint(_ groups: [[Row]]) throws -> String {
        var data = Data()
        for group in groups {
            data.append(Data("\(group.count):".utf8))
            for row in group {
                for (_, v) in row {
                    let bytes: Data
                    switch v.storage {
                    case .null: bytes = Data("n".utf8)
                    case .int64(let x): bytes = Data("i\(x)".utf8)
                    case .double(let x): bytes = Data("d\(x.bitPattern)".utf8)
                    case .string(let x): bytes = Data("s".utf8) + Data(x.utf8)
                    case .blob(let x): bytes = Data("b".utf8) + x
                    }
                    guard data.count <= maximumMetadataBytes - bytes.count else { throw Failure.resourceLimit }
                    data.append(Data("\(bytes.count):".utf8)); data.append(bytes)
                }
            }
        }
        return ArchiveV2Hash.sha256(data)
    }

    private static func readInventory(_ url: URL) throws -> Inventory {
        try CollectorMachineIdentityReader.withReadOnlyDatabase(from: url) { try readInventory($0) }
    }

    static func readInventory(_ db: Database) throws -> Inventory {
            let metadata = try rows(db, "collector_metadata", order: "key")
            let values = try Dictionary(uniqueKeysWithValues: metadata.map { (try value($0, "key", as: String.self), try value($0, "value", as: String.self)) })
            guard values["schema_version"] == "2", values["publication_schema_version"] == "11",
                  let machine = values["machine_id"], UUID(uuidString: machine) != nil else { throw Failure.unsupportedSchema }
            let roots = try rows(db, "collector_roots", order: "root_id")
            let locators = try rows(db, "collector_locators", order: "root_id,root_revision,relative_path")
            let pubs = try rows(db, "collector_publications", order: "publication_digest")
            let replicas = try rows(db, "collector_publication_replicas", order: "publication_digest,replica_id")
            let reservations = try rows(db, "collector_capture_reservations", order: "id")
            var publications: [String: Publication] = [:], replicaMap: [String: [Row]] = [:]
            for row in pubs {
                let bytes: Data = try value(row, "canonical_bytes")
                guard bytes.count <= CollectorPublicationProtocolLimits.maxPublicationBytes,
                      let envelope = try? ArchiveCanonicalJSON.decode(CollectorPublicationEnvelope.self, from: bytes) else { throw Failure.invalidPublication }
                let digest: String = try value(row, "publication_digest")
                guard try envelope.sha256() == digest, envelope.machineID == machine,
                      envelope.manifestSHA256 == (try value(row, "manifest_sha256", as: String.self)),
                      envelope.sourceInstanceID == (try value(row, "source_instance_id", as: String.self)),
                      envelope.collectorEpoch == (try value(row, "collector_epoch", as: String.self)),
                      envelope.sequence == (try value(row, "sequence", as: Int64.self)) else { throw Failure.invalidPublication }
                publications[digest] = Publication(captureID: try value(row, "capture_id"), digest: digest,
                    root: try value(row, "root_id"), revision: try value(row, "root_revision"), path: try value(row, "relative_path"), envelope: envelope)
            }
            for row in replicas { replicaMap[try value(row, "publication_digest"), default: []].append(row) }
            var locatorMap: [LocatorKey: Row] = [:], rootMap: [String: Row] = [:]
            for row in locators {
                locatorMap[LocatorKey(root: try value(row, "root_id"), revision: try value(row, "root_revision"), path: try value(row, "relative_path"))] = row
            }
            for row in roots { rootMap[try value(row, "root_id")] = row }
            return Inventory(machine: machine, publications: publications, replicas: replicaMap, locators: locatorMap, roots: rootMap,
                reservedRoots: Set(try reservations.map { try value($0, "root_id", as: String.self) }),
                fingerprint: try fingerprint([metadata.filter { ($0["key"] as String) != "active_owner_run_id" && ($0["key"] as String) != "gc_schema_version" }, roots, locators, pubs, replicas, reservations]))
    }

    private static func readCatalog(_ url: URL, machine: String) throws -> Catalog {
        try CollectorMachineIdentityReader.withReadOnlyDatabase(from: url) { try readCatalog($0, machine: machine) }
    }

    static func readCatalog(_ db: Database, machine: String, allowEmpty: Bool = false) throws -> Catalog {
            guard try String.fetchOne(db, sql: "SELECT value FROM archive_metadata WHERE key='machine_id'") == machine,
                  try String.fetchOne(db, sql: "SELECT value FROM archive_metadata WHERE key='schema_version'") == "5" else { throw Failure.unsupportedSchema }
            let raw = try rows(db, "archive_captures", order: "capture_id")
            guard allowEmpty || !raw.isEmpty else { throw Failure.emptyGraph }
            var captures: [String: Capture] = [:], totalBytes = 0, references = 0
            for row in raw {
                let bytes: Data = try value(row, "unbound_manifest_bytes")
                totalBytes += bytes.count
                guard !bytes.isEmpty, bytes.count <= ArchiveV2ProtocolLimits.maxManifestBytes,
                      totalBytes <= maximumMetadataBytes else { throw Failure.resourceLimit }
                guard let manifest = try? ArchiveCanonicalJSON.decode(ArchiveSourceManifest.self, from: bytes), manifest.sessionID == nil else { throw Failure.invalidManifest }
                let digest: String = try value(row, "unbound_manifest_sha256")
                guard try ArchiveV2Hash.sha256(bytes) == digest, manifest.machineID == machine,
                      manifest.captureID == (try value(row, "capture_id", as: String.self)),
                      manifest.source == (try value(row, "source", as: String.self)),
                      manifest.locator == (try value(row, "locator", as: String.self)),
                      manifest.wholeSourceSHA256 == (try value(row, "whole_source_sha256", as: String.self)),
                      manifest.rawByteCount == (try value(row, "raw_byte_count", as: Int64.self)),
                      manifest.chunkSize == (try value(row, "chunk_size", as: Int64.self)),
                      manifest.capturedAt == (try value(row, "captured_at", as: String.self)) else { throw Failure.invalidManifest }
                for (column, expected) in [("generation_device", manifest.generation.device), ("generation_inode", manifest.generation.inode),
                                           ("generation_size", manifest.generation.size), ("generation_mtime_ns", manifest.generation.mtimeNs),
                                           ("generation_ctime_ns", manifest.generation.ctimeNs), ("generation_mode", manifest.generation.mode)] {
                    guard try value(row, column, as: Int64.self) == expected else { throw Failure.invalidManifest }
                }
                references += manifest.chunks.count
                guard references <= maximumReferences else { throw Failure.resourceLimit }
                captures[manifest.captureID] = Capture(manifest: manifest, digest: digest, status: try value(row, "status"))
            }
            return Catalog(captures: captures, fingerprint: try fingerprint([raw]))
    }

    static func publicationBlock(_ p: Publication, _ inventory: Inventory) throws -> String? {
        let replicas = inventory.replicas[p.digest] ?? []
        var reasons = Set<String>()
        if try replicas.count != 2 || Set( replicas.map { try value($0, "replica_id", as: String.self) }) != ["hq", "m1"] { reasons.insert("not_dual_acked") }
        for row in replicas {
            let error: String? = try value(row, "last_error")
            let state: String = try value(row, "state")
            if error == "privacyWithheld" { reasons.insert("withheld") }
            if error == "localContentUnavailable" { reasons.insert("local_content_unavailable") }
            if state == "pending" || state == "inflight" { reasons.insert(state) }
            if state != "acknowledged" || error != nil { reasons.insert("not_dual_acked") }
            if state == "acknowledged" {
                let bytes: Data? = try value(row, "ack_bytes")
                guard let bytes, bytes.count <= CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes,
                      let ack = try? ArchiveCanonicalJSON.decode(CollectorPublicationACK.self, from: bytes),
                      (try? ack.validate(against: p.envelope, expectedServerID: value(row, "replica_id"))) != nil else {
                    reasons.insert("not_dual_acked"); continue
                }
            }
        }
        return gateOrder.first { reasons.contains($0) }
    }

    struct Graph {
        let refs: [String: Set<String>]
        let sizes: [String: Int64]
        let keep: Set<String>
        let admissionKeep: Set<String>
        let captureReasons: [String: String]
        let dualACKedCaptures: Set<String>
    }

    static func graph(_ inventory: Inventory, _ catalog: Catalog, evidence: Evidence?) throws -> Graph {
        let publications = Dictionary(grouping: inventory.publications.values, by: \.captureID)
        guard Set(publications.keys).isSubset(of: Set(catalog.captures.keys)) else { throw Failure.incompleteGraph }
        let latest = Set(try inventory.locators.values.compactMap { try value($0, "last_capture_id", as: String?.self) })
        guard latest.isSubset(of: Set(catalog.captures.keys)) else { throw Failure.incompleteGraph }
        let central = Dictionary(uniqueKeysWithValues: (evidence?.publications ?? []).map { ($0.publicationSHA256, $0) })
        var refs: [String: Set<String>] = [:], sizes: [String: Int64] = [:], captureReasons: [String: String] = [:]
        var floor = Set<String>(), keep = Set<String>(), dualACKedCaptures = Set<String>(), admissionKeep = Set<String>()
        for (id, capture) in catalog.captures {
            let digests = Set(capture.manifest.chunks.map(\.rawSHA256))
            for chunk in capture.manifest.chunks {
                if let length = sizes[chunk.rawSHA256], length != chunk.rawByteCount { throw Failure.invalidManifest }
                sizes[chunk.rawSHA256] = chunk.rawByteCount
                refs[chunk.rawSHA256, default: []].insert(id)
            }
            let pubs = publications[id] ?? []
            if !pubs.isEmpty, try pubs.allSatisfy({ try publicationBlock($0, inventory) == nil }) {
                dualACKedCaptures.insert(id)
            }
            var reasons = Set<String>()
            if latest.contains(id) { reasons.insert("latest"); floor.formUnion(digests) }
            if pubs.isEmpty { reasons.insert("not_dual_acked"); floor.formUnion(digests) }
            if capture.status != "captured" { reasons.insert("not_dual_acked"); floor.formUnion(digests) }
            for p in pubs {
                guard p.envelope.manifestSHA256 == capture.digest else { throw Failure.invalidPublication }
                if let blocked = try publicationBlock(p, inventory) { reasons.insert(blocked); floor.formUnion(digests) }
                let key = LocatorKey(root: p.root, revision: p.revision, path: p.path)
                if let root = inventory.roots[p.root], let locator = inventory.locators[key] {
                    let last: String? = try value(locator, "last_capture_id")
                    let head = last.flatMap { publications[$0] } ?? []
                    let superseded = head.contains { $0.root == p.root && $0.revision == p.revision && $0.path == p.path
                        && $0.envelope.sourceInstanceID == p.envelope.sourceInstanceID && $0.envelope.collectorEpoch == p.envelope.collectorEpoch
                        && $0.envelope.sequence > p.envelope.sequence }
                    if try value(root, "root_revision", as: Int64.self) != p.revision
                        || value(root, "requested_revision", as: Int64.self) != value(root, "completed_revision", as: Int64.self)
                        || value(root, "active_scan_id", as: String?.self) != nil || value(root, "last_scan_failure", as: String?.self) != nil
                        || value(locator, "dirty_revision", as: Int64.self) != value(locator, "acknowledged_revision", as: Int64.self)
                        || value(locator, "claim_owner_run_id", as: String?.self) != nil || value(locator, "last_error", as: String?.self) != nil
                        || value(locator, "retry_not_before", as: Int64?.self) != nil || inventory.reservedRoots.contains(p.root)
                        || (!latest.contains(id) && !superseded) {
                        reasons.insert("dirty_k6"); floor.formUnion(digests)
                    }
                } else { reasons.insert("dirty_k6"); floor.formUnion(digests) }
                guard evidence != nil else { reasons.insert("central_evidence_missing"); continue }
                guard let row = central[p.digest], row.manifestSHA256 == capture.digest, row.machineID == inventory.machine,
                      row.sourceInstanceID == p.envelope.sourceInstanceID, row.collectorEpoch == p.envelope.collectorEpoch,
                      row.sequence == p.envelope.sequence else { reasons.insert("central_other"); continue }
                if row.status == "parsed" { reasons.insert("central_parsed_skip") }
                else if row.status == "quarantined", row.failureCode == "quarantine.cross_machine_duplicate" { reasons.insert("duplicate_unprovable") }
                else if row.status != "index_ready" || !row.hasRetainedGeneration || !(row.failureCode ?? "").isEmpty { reasons.insert("central_other") }
            }
            if latest.contains(id) || !dualACKedCaptures.contains(id) || capture.status != "captured" {
                admissionKeep.formUnion(digests)
            }
            if let reason = gateOrder.first(where: { reasons.contains($0) }) {
                captureReasons[id] = reason; keep.formUnion(digests)
            }
        }
        try validateKeepSet(graph: Set(refs.keys), keep: keep, floor: floor)
        return Graph(refs: refs, sizes: sizes, keep: keep, admissionKeep: admissionKeep,
            captureReasons: captureReasons, dualACKedCaptures: dualACKedCaptures)
    }

    private static func evaluate(_ inventory: Inventory, _ catalog: Catalog, spoolRoot: URL,
                                 evidence: Evidence?, maxBytes: Int64, maxObjects: Int) throws -> Report {
        let graph = try graph(inventory, catalog, evidence: evidence)
        let refs = graph.refs, sizes = graph.sizes, keep = graph.keep
        let captureReasons = graph.captureReasons, dualACKedCaptures = graph.dualACKedCaptures
        var buckets = Dictionary(uniqueKeysWithValues: gateOrder.map { ($0, Bucket(reason: $0)) })
        var sharedCauses = Dictionary(uniqueKeysWithValues: gateOrder.map { ($0, Bucket(reason: $0)) })
        var present: Int64 = 0, missing: Int64 = 0, potential: Int64 = 0, budgeted: Int64 = 0, count = 0
        var missingProtected = Bucket(reason: "dual_acked")
        for digest in refs.keys.sorted() {
            let ids = refs[digest]!, size = sizes[digest]!
            let object = spoolRoot.appendingPathComponent("capture/objects/sha256/\(digest.prefix(2))/\(digest)")
            guard let length = try objectLength(object) else {
                // Preview distinguishes historical absence from new savings.
                // No non-ACKed reference may use this reporting exception.
                guard ids.isSubset(of: dualACKedCaptures) else { throw Failure.missingProtectedObject }
                if keep.contains(digest) {
                    missingProtected.objects += 1
                    missingProtected.bytes = try add(missingProtected.bytes, size)
                }
                missing = try add(missing, size); continue
            }
            guard length == size else { throw Failure.unsafeObject }
            present = try add(present, size)
            let pinned = ids.compactMap { captureReasons[$0] }
            let underlying = gateOrder.first(where: { pinned.contains($0) })
            let shared = !pinned.isEmpty && pinned.count < ids.count
            let reason = shared ? "shared_pinned" : (underlying ?? "proof_missing")
            buckets[reason]!.objects += 1; buckets[reason]!.bytes = try add(buckets[reason]!.bytes, size)
            if shared, let underlying {
                sharedCauses[underlying]!.objects += 1; sharedCauses[underlying]!.bytes = try add(sharedCauses[underlying]!.bytes, size)
            }
            if pinned.isEmpty {
                potential = try add(potential, size)
                if count < maxObjects, size <= maxBytes - budgeted { budgeted += size; count += 1 }
            }
        }
        return Report(schemaVersion: 1, previewOnly: true, provisional: true, actionableBytes: 0,
            captureCount: catalog.captures.count, referencedObjects: refs.count, protectedObjects: keep.count,
            presentBytes: present, missingReferencedBytes: missing,
            missingProtectedByACK: [missingProtected, Bucket(reason: "not_dual_acked")],
            potentialBytesBeforeProofAndEscrow: potential,
            budgetedPotentialBytes: budgeted, budgetedPotentialObjects: count,
            blocked: (evidence == nil ? ["central_evidence_missing"] : []) + ["proof_missing", "escrow"],
            unverified: ["replica_fixity", "escrow_coverage", "current_privacy_policy", "live_native_state", "object_content_hashes", "physical_allocated_bytes", "unreferenced_files"],
            firstBlockingGate: gateOrder.map { buckets[$0]! },
            captureFirstBlockingGate: Dictionary(grouping: catalog.captures.keys.map { captureReasons[$0] ?? "proof_missing" }, by: { $0 }).mapValues(\.count),
            sharedPinCauses: gateOrder.compactMap { sharedCauses[$0]!.objects > 0 ? sharedCauses[$0] : nil },
            inventoryFingerprint: inventory.fingerprint, catalogFingerprint: catalog.fingerprint, centralEvidenceSHA256: evidence?.digest)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let sum = lhs.addingReportingOverflow(rhs)
        guard rhs >= 0, !sum.overflow else { throw Failure.resourceLimit }
        return sum.partialValue
    }

    private static func objectLength(_ url: URL) throws -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw Failure.unsafeObject
        }
        guard (try? CollectorMachineIdentityReader.canonicalExistingPath(url)) != nil, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0 else { throw Failure.unsafeObject }
        return Int64(info.st_size)
    }
}
