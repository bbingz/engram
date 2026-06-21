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
//
// Layer 2 (per-project session sync) wire DTOs live in the Shared target
// (EngramServiceModels.swift) so the app/MCP client and protocol can reference
// them too — EngramServiceCore compiles both the handler and Shared/Service.

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

    /// READ-ONLY dry run for a per-project push/pull. Returns enabled=false (a
    /// no-op) when remote offload is not configured. `direction` is "push" or
    /// "pull"; defaults to "push".
    static func remoteProjectSyncPreview(
        _ request: EngramServiceRemoteProjectSyncRequest,
        writerGate: ServiceWriterGate
    ) async throws -> EngramServiceRemoteProjectSyncPreviewResponse {
        let dir = request.direction == "pull" ? "pull" : "push"
        guard let coordinator = RemoteSyncCoordinator.makeIfEnabled(
            gate: writerGate,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return EngramServiceRemoteProjectSyncPreviewResponse(
                enabled: false, direction: dir, project: request.project,
                sessions: [], toPush: 0, toPull: 0, skip: 0
            )
        }
        let preview = try await coordinator.previewProjectSync(
            project: request.project,
            cwd: request.cwd ?? "",
            direction: dir
        )
        let action = dir == "pull" ? "pull" : "push"
        let sessions = preview.samples.map {
            EngramServiceRemoteProjectSyncPreviewResponse.SessionPreview(id: $0.id, title: $0.title, action: action)
        }
        return EngramServiceRemoteProjectSyncPreviewResponse(
            enabled: true,
            direction: dir,
            project: preview.project,
            sessions: sessions,
            toPush: dir == "push" ? preview.actionable : 0,
            toPull: dir == "pull" ? preview.actionable : 0,
            skip: preview.skipped
        )
    }

    /// Push one project's local-origin sessions to the hub (protected command).
    /// Returns enabled=false (a no-op) when remote offload is not configured.
    static func remotePushProject(
        _ request: EngramServiceRemoteProjectSyncRequest,
        writerGate: ServiceWriterGate
    ) async throws -> EngramServiceRemotePushProjectResponse {
        guard let coordinator = RemoteSyncCoordinator.makeIfEnabled(
            gate: writerGate,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return EngramServiceRemotePushProjectResponse(enabled: false, uploaded: 0, skipped: 0)
        }
        let result = try await coordinator.pushProject(project: request.project, cwd: request.cwd ?? "")
        return EngramServiceRemotePushProjectResponse(enabled: true, uploaded: result.uploaded, skipped: result.skipped)
    }

    /// Pull one project's peer-published sessions from the hub (protected command).
    /// Returns enabled=false (a no-op) when remote offload is not configured.
    static func remotePullProject(
        _ request: EngramServiceRemoteProjectSyncRequest,
        writerGate: ServiceWriterGate
    ) async throws -> EngramServiceRemotePullProjectResponse {
        guard let coordinator = RemoteSyncCoordinator.makeIfEnabled(
            gate: writerGate,
            environment: ProcessInfo.processInfo.environment
        ) else {
            return EngramServiceRemotePullProjectResponse(enabled: false, imported: 0, skipped: 0)
        }
        let result = try await coordinator.pullProject(project: request.project)
        return EngramServiceRemotePullProjectResponse(enabled: true, imported: result.imported, skipped: result.skipped)
    }
}
