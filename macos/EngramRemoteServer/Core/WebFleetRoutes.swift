import Foundation
import Hummingbird

/// Operator-only, out-of-band observations. No SSH, disk traversal, SQLite
/// writes, or remote probes may run on the HTTP request path.
enum WebFleetRoutes {
    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let generatedAt: Int64
        let machines: [Machine]
        let central: Central?
    }
    struct Machine: Codable, Sendable {
        let id: String
        let label: String
        let role: String
        let status: String
        let machineId: String?
        let observedAt: Int64?
        let lastAttemptAt: Int64
        let processes: [Process]
        let disk: Disk?
        let storage: [Storage]
        let capture: Capture?
        let roots: [Root]
        let replicas: [Replica]
        let errors: [String]
    }
    struct Process: Codable, Sendable {
        let name: String
        let state: String
        let pid: Int64?
        let revision: String?
    }
    struct Disk: Codable, Sendable { let totalBytes: Int64; let freeBytes: Int64 }
    struct Storage: Codable, Sendable { let name: String; let usedBytes: Int64?; let observedAt: Int64 }
    struct Capture: Codable, Sendable {
        let publications: Int64
        let capturedLocators: Int64
        let dirtyLocators: Int64
        let coolingLocators: Int64
        let unavailableLocators: Int64
        let lastCaptureAt: Int64?
    }
    struct Root: Codable, Sendable {
        let id: String
        let source: String
        let locators: Int64
        let captured: Int64
        let dirty: Int64
        let cooling: Int64
        let unavailable: Int64
        let scanning: Bool
        let scanLag: Int64
        let scanFailed: Bool
        let epochStatus: String
    }
    struct Replica: Codable, Sendable {
        let id: String
        let pending: Int64
        let inflight: Int64
        let acknowledged: Int64
        let withheld: Int64
        let failed: Int64
    }
    struct Central: Codable, Sendable {
        let observedAt: Int64
        let machines: [CentralMachine]
        let ftsPending: Int64
        let ftsFailed: Int64
    }
    struct CentralMachine: Codable, Sendable {
        let machineId: String
        let sessions: Int64
        let visibleSessions: Int64
        let publications: Int64
        let pending: Int64
        let processing: Int64
        let parsed: Int64
        let indexReady: Int64
        let retryable: Int64
        let quarantined: Int64
    }
    enum Invalid: Error { case snapshot }

    static func read(path: String?) throws -> Snapshot {
        guard let path,
              let bytes = SecureRegularFile.read(atPath: path, maximumBytes: 1_048_576, repairPermissions: false) else {
            throw Invalid.snapshot
        }
        let value = try JSONDecoder().decode(Snapshot.self, from: bytes)
        try validate(value)
        return value
    }

    static func validate(_ s: Snapshot) throws {
        func require(_ ok: Bool) throws { if !ok { throw Invalid.snapshot } }
        func count(_ values: Int64...) throws {
            try require(values.allSatisfy { (0...9_007_199_254_740_991).contains($0) })
        }
        func time(_ value: Int64) throws { try require((0...253_402_300_799).contains(value)) }
        func label(_ value: String) throws {
            try require(!value.isEmpty && value.utf8.count <= 256
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        }
        try require(s.schemaVersion == 1 && s.machines.count <= 64
            && Set(s.machines.map(\.id)).count == s.machines.count)
        try time(s.generatedAt)
        for m in s.machines {
            try label(m.id); try label(m.label)
            try require(["collector", "index", "replica"].contains(m.role)
                && ["ok", "unreachable"].contains(m.status))
            if let mid = m.machineId { try require(UUID(uuidString: mid) != nil) }
            try time(m.lastAttemptAt)
            if let observed = m.observedAt { try time(observed) }
            try require(m.status != "ok" || m.observedAt != nil)
            try require(m.status != "unreachable" || (m.observedAt == nil && m.capture == nil
                && m.disk == nil && m.processes.isEmpty && m.roots.isEmpty && m.storage.isEmpty && m.replicas.isEmpty))
            try require(m.processes.count <= 16 && m.storage.count <= 16 && m.roots.count <= 128
                && m.replicas.count <= 16 && m.errors.count <= 16)
            try require(Set(m.roots.map(\.id)).count == m.roots.count
                && Set(m.replicas.map(\.id)).count == m.replicas.count)
            for p in m.processes {
                try label(p.name); try require(["running", "stopped", "unknown"].contains(p.state))
                if let pid = p.pid { try count(pid) }
                if let rev = p.revision {
                    try require(rev.utf8.count == 40 && rev.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
                }
            }
            if let d = m.disk { try count(d.totalBytes, d.freeBytes); try require(d.freeBytes <= d.totalBytes) }
            for d in m.storage { try label(d.name); try time(d.observedAt); if let bytes = d.usedBytes { try count(bytes) } }
            if let c = m.capture {
                try count(c.publications, c.capturedLocators, c.dirtyLocators, c.coolingLocators, c.unavailableLocators)
                if let stamp = c.lastCaptureAt { try time(stamp) }
                try require(c.coolingLocators <= c.dirtyLocators && c.unavailableLocators <= c.dirtyLocators)
            }
            for r in m.roots {
                try label(r.id); try label(r.source)
                try count(r.locators, r.captured, r.dirty, r.cooling, r.unavailable, r.scanLag)
                try require(r.captured <= r.locators && r.dirty <= r.locators
                    && r.cooling <= r.dirty && r.unavailable <= r.dirty
                    && ["match", "mismatch", "noCheckpoint", "unknown"].contains(r.epochStatus))
            }
            for r in m.replicas { try label(r.id); try count(r.pending, r.inflight, r.acknowledged, r.withheld, r.failed) }
            try require(m.errors.allSatisfy { ["inventoryUnavailable", "captureCatalogUnavailable", "diskUnavailable", "probeUnavailable"].contains($0) })
        }
        if let c = s.central {
            try time(c.observedAt); try count(c.ftsPending, c.ftsFailed)
            try require(c.machines.count <= 64 && Set(c.machines.map(\.machineId)).count == c.machines.count)
            for m in c.machines {
                try require(UUID(uuidString: m.machineId) != nil)
                try count(m.sessions, m.visibleSessions, m.publications, m.pending, m.processing,
                          m.parsed, m.indexReady, m.retryable, m.quarantined)
                try require(m.visibleSessions <= m.sessions)
            }
        }
    }

    static func mount<Context: RequestContext>(on router: Router<Context>, path: String?) {
        router.get("/web/api/fleet") { request, _ in
            guard !request.uri.string.contains("?") && !request.uri.string.contains("#") else {
                return Response(status: .badRequest)
            }
            // File reads happen off the request event loop. Output is re-encoded
            // from the allowlisted DTO, never returned as opaque operator JSON.
            do {
                let snapshot = try await Task.detached { try read(path: path) }.value
                let data = try JSONEncoder().encode(snapshot)
                return EngramRemoteServerApp.json(data)
            } catch {
                return Response(status: .serviceUnavailable)
            }
        }
    }
}
