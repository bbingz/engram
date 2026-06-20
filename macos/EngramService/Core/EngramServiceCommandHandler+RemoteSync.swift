import Foundation
import GRDB
import EngramCoreWrite

// MARK: - Remote offload IPC DTOs

struct EngramServiceRemoteRehydrateRequest: Codable, Sendable {
    let sessionId: String
}

struct EngramServiceRemoteSyncCycleResponse: Codable, Sendable {
    let enabled: Bool
    let offloaded: Int
    let rehydrated: Int
    let reclaimedDisk: Bool
}

struct EngramServiceRemoteRehydrateResponse: Codable, Sendable {
    let enabled: Bool
    let rehydrated: Bool
}

struct EngramServiceRemoteSyncStatusResponse: Codable, Sendable {
    let enabled: Bool
    let backendKind: String
    let localCount: Int
    let offloadedCount: Int
    let pendingOffload: Int
    let pendingRehydrate: Int
}

// MARK: - Handlers

extension EngramServiceCommandHandler {
    /// Manually run one offload/rehydrate/reclaim cycle now (protected command).
    /// Returns enabled=false (a no-op) when remote offload is not configured.
    static func remoteOffloadNow(writerGate: ServiceWriterGate) async throws -> EngramServiceRemoteSyncCycleResponse {
        guard let coordinator = RemoteSyncCoordinator.makeIfEnabled(
            gate: writerGate,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return EngramServiceRemoteSyncCycleResponse(enabled: false, offloaded: 0, rehydrated: 0, reclaimedDisk: false)
        }
        let result = try await coordinator.runOnce()
        return EngramServiceRemoteSyncCycleResponse(
            enabled: true,
            offloaded: result.offloaded,
            rehydrated: result.rehydrated,
            reclaimedDisk: result.reclaimedDisk
        )
    }

    /// Force-rehydrate a single offloaded session now (protected command).
    static func remoteRehydrateNow(
        _ request: EngramServiceRemoteRehydrateRequest,
        writerGate: ServiceWriterGate
    ) async throws -> EngramServiceRemoteRehydrateResponse {
        guard let coordinator = RemoteSyncCoordinator.makeIfEnabled(
            gate: writerGate,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return EngramServiceRemoteRehydrateResponse(enabled: false, rehydrated: false)
        }
        let ok = try await coordinator.rehydrateNow(sessionId: request.sessionId)
        return EngramServiceRemoteRehydrateResponse(enabled: true, rehydrated: ok)
    }

    /// Read-only status: offload counts + pending queue depths + config (no token).
    static func remoteSyncStatus(writerGate: ServiceWriterGate) async throws -> EngramServiceRemoteSyncStatusResponse {
        let config = RemoteSyncConfig.read(environment: ProcessInfo.processInfo.environment)
        let counts = try await writerGate.performWriteCommand(name: "remoteSyncStatus") { writer in
            try writer.read { db -> [Int] in
                [
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE COALESCE(offload_state, 'local') = 'local'") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions WHERE offload_state = 'offloaded'") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offload_queue WHERE status IN ('pending', 'inflight')") ?? 0,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rehydrate_queue WHERE status IN ('pending', 'inflight')") ?? 0,
                ]
            }
        }.value
        return EngramServiceRemoteSyncStatusResponse(
            enabled: config.enabled,
            backendKind: config.backendKind,
            localCount: counts[0],
            offloadedCount: counts[1],
            pendingOffload: counts[2],
            pendingRehydrate: counts[3]
        )
    }
}
