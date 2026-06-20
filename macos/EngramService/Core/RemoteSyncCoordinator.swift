import Foundation
import EngramCoreWrite

/// Opt-in configuration for the remote session-offload loop. Default OFF, read
/// from `~/.engram/settings.json` (env overrides for tests/dev), mirroring the
/// web-UI opt-in posture.
public struct RemoteSyncConfig: Sendable {
    public let enabled: Bool
    /// "local" → `LocalDirectoryBackend` (dir/NAS mount); "http" → the self-hosted
    /// `engram-remote` server via `EngramRemoteBackend`.
    public let backendKind: String
    public let serverURL: URL?
    public let storeRoot: URL
    public let policy: OffloadPolicy
    public let offloadBatch: Int
    public let rehydrateBatch: Int
    /// VACUUM only when at least this many free pages have accumulated, so the
    /// expensive rebuild runs occasionally (after real purges), not every cycle.
    public let vacuumFreelistThreshold: Int

    public init(
        enabled: Bool,
        storeRoot: URL,
        policy: OffloadPolicy,
        offloadBatch: Int,
        rehydrateBatch: Int,
        vacuumFreelistThreshold: Int,
        backendKind: String = "local",
        serverURL: URL? = nil
    ) {
        self.enabled = enabled
        self.backendKind = backendKind
        self.serverURL = serverURL
        self.storeRoot = storeRoot
        self.policy = policy
        self.offloadBatch = offloadBatch
        self.rehydrateBatch = rehydrateBatch
        self.vacuumFreelistThreshold = vacuumFreelistThreshold
    }

    public static func read(environment: [String: String]) -> RemoteSyncConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultRoot = home.appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("offload-store", isDirectory: true)

        var settings: [String: Any] = [:]
        let settingsURL = home.appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = object
        }

        let enabled: Bool = {
            if let env = environment["ENGRAM_REMOTE_OFFLOAD_ENABLED"] {
                return ["1", "true", "yes"].contains(env.lowercased())
            }
            return (settings["remoteOffloadEnabled"] as? Bool) ?? false
        }()

        let storeRoot: URL = {
            if let env = environment["ENGRAM_REMOTE_OFFLOAD_STORE"], !env.isEmpty {
                return URL(fileURLWithPath: env)
            }
            if let path = settings["remoteOffloadStoreRoot"] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return defaultRoot
        }()

        let coldAgeDays = (settings["remoteOffloadColdAgeDays"] as? Int) ?? 90
        let backendKind = (environment["ENGRAM_REMOTE_OFFLOAD_BACKEND"]
            ?? settings["remoteOffloadBackend"] as? String
            ?? "local").lowercased()
        let serverURL = (environment["ENGRAM_REMOTE_OFFLOAD_SERVER_URL"]
            ?? settings["remoteOffloadServerURL"] as? String)
            .flatMap { URL(string: $0) }
        return RemoteSyncConfig(
            enabled: enabled,
            storeRoot: storeRoot,
            policy: OffloadPolicy(coldAgeDays: coldAgeDays),
            offloadBatch: (settings["remoteOffloadBatch"] as? Int) ?? 20,
            rehydrateBatch: (settings["remoteRehydrateBatch"] as? Int) ?? 20,
            vacuumFreelistThreshold: (settings["remoteOffloadVacuumFreelistPages"] as? Int) ?? 4_000,
            backendKind: backendKind,
            serverURL: serverURL
        )
    }
}

/// Drives one offload/rehydrate/reclaim cycle through the single-writer gate.
/// Each DB mutation is its own `performWriteCommand` so the gate is RELEASED
/// across the network PUT/GET (which run strictly between gated writes). The FTS
/// purge happens only after a confirmed remote PUT.
public struct RemoteSyncCoordinator: Sendable {
    private let gate: ServiceWriterGate
    private let backend: any RemoteStorageBackend
    private let config: RemoteSyncConfig
    private let peer: String

    public init(gate: ServiceWriterGate, backend: any RemoteStorageBackend, config: RemoteSyncConfig, peer: String) {
        self.gate = gate
        self.backend = backend
        self.config = config
        self.peer = peer
    }

    /// Build a coordinator backed by a local directory store when offload is
    /// enabled; returns nil when disabled or the store cannot be created. The
    /// HTTP `EngramRemoteBackend` (self-hosted server) is the future drop-in here.
    public static func makeIfEnabled(
        gate: ServiceWriterGate,
        environment: [String: String]
    ) -> RemoteSyncCoordinator? {
        let config = RemoteSyncConfig.read(environment: environment)
        guard config.enabled else { return nil }
        let peer = environment["ENGRAM_REMOTE_OFFLOAD_PEER"] ?? ProcessInfo.processInfo.hostName

        let backend: (any RemoteStorageBackend)?
        switch config.backendKind {
        case "http":
            // Self-hosted server. URL from settings (non-secret); bearer token from
            // Keychain (or env for headless), never from settings.json.
            guard let url = config.serverURL else { return nil }
            let token = environment["ENGRAM_REMOTE_OFFLOAD_TOKEN"] ?? RemoteCredentialStore.loadToken()
            guard let token, !token.isEmpty else { return nil }
            backend = try? EngramRemoteBackend(baseURL: url, token: token)
        default:
            backend = try? LocalDirectoryBackend(root: config.storeRoot)
        }
        guard let backend else { return nil }
        return RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: peer)
    }

    public struct CycleResult: Sendable, Equatable {
        public let offloaded: Int
        public let rehydrated: Int
        public let reclaimedDisk: Bool
    }

    public func runOnce(now: Date = Date()) async throws -> CycleResult {
        // Reclaim inflight jobs orphaned by a crashed/cancelled prior cycle (only
        // rows stale past the threshold, so a concurrent manual trigger is safe).
        _ = try await gate.performWriteCommand(name: "remoteRequeueStale") { writer in
            try writer.write { db in try OffloadRepo.requeueStaleInflight(db) }
        }
        let offloaded = try await drainOffload(now: now)
        let rehydrated = try await drainRehydrate()
        let reclaimed = try await reclaimDiskIfNeeded()
        return CycleResult(offloaded: offloaded, rehydrated: rehydrated, reclaimedDisk: reclaimed)
    }

    /// Enqueue (if offloaded) and immediately drain a single session's rehydrate.
    /// Returns true if a rehydrate was enqueued or completed this call.
    public func rehydrateNow(sessionId: String) async throws -> Bool {
        let enqueued = try await gate.performWriteCommand(name: "remoteRehydrateEnqueue") { writer in
            try writer.write { db in try OffloadRepo.enqueueRehydrate(db, sessionId: sessionId) }
        }.value
        let drained = try await drainRehydrate()
        return enqueued || drained > 0
    }

    private func drainOffload(now: Date) async throws -> Int {
        _ = try await gate.performWriteCommand(name: "remoteOffloadEnqueue") { writer in
            try writer.write { db in
                let eligible = try OffloadRepo.candidateRows(db, limit: 500)
                    .filter { config.policy.isEligible($0, now: now) }
                    .sorted { config.policy.score($0, now: now) > config.policy.score($1, now: now) }
                    .map(\.id)
                return try OffloadRepo.enqueueOffload(db, sessionIds: eligible, generation: nil)
            }
        }

        let claimed = try await gate.performWriteCommand(name: "remoteOffloadClaim") { writer in
            try writer.write { db in try OffloadRepo.claimPendingOffload(db, limit: config.offloadBatch) }
        }.value

        var done = 0
        for job in claimed {
            do {
                let inputs = try await gate.performWriteCommand(name: "remoteOffloadRead") { writer in
                    try writer.read { db in try OffloadRepo.bundleInputs(db, sessionId: job.sessionId) }
                }.value
                guard let inputs else {
                    _ = try await gate.performWriteCommand(name: "remoteOffloadFail") { writer in
                        try writer.write { db in
                            try OffloadRepo.failOffload(db, queueId: job.queueId, error: "session row missing")
                        }
                    }
                    continue
                }

                let bundle = BundleCodec.makeBundle(
                    sessionId: job.sessionId,
                    ftsContents: inputs.ftsContents,
                    summary: inputs.summary,
                    summaryMessageCount: inputs.summaryMessageCount,
                    messageCount: inputs.messageCount,
                    userMessageCount: inputs.userMessageCount,
                    assistantMessageCount: inputs.assistantMessageCount,
                    toolMessageCount: inputs.toolMessageCount,
                    systemMessageCount: inputs.systemMessageCount
                )
                let key = BundleCodec.contentKey(bundle)
                let data = try BundleCodec.encode(bundle)

                // Network — OUTSIDE the write gate.
                let exists = try await backend.head(key: key)
                if !exists { try await backend.put(key: key, data: data) }

                let shadow = OffloadShadow.line(
                    title: inputs.generatedTitle,
                    project: inputs.project,
                    summary: inputs.summary,
                    sessionId: job.sessionId
                )
                _ = try await gate.performWriteCommand(name: "remoteOffloadCommit") { writer in
                    try writer.write { db in
                        try OffloadRepo.commitOffloaded(
                            db,
                            queueId: job.queueId,
                            sessionId: job.sessionId,
                            expectedSyncVersion: inputs.syncVersion,
                            remoteKey: key,
                            contentHash: bundle.contentHash,
                            shadowLine: shadow,
                            peer: peer
                        )
                    }
                }
                done += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch RemoteSyncError.offloadStale {
                // Re-indexed/removed mid-flight: re-queue and re-capture next cycle
                // (not a failure — no purge happened, no attempts charged).
                _ = try? await gate.performWriteCommand(name: "remoteOffloadRequeue") { writer in
                    try writer.write { db in try OffloadRepo.requeueOffload(db, queueId: job.queueId) }
                }
            } catch {
                _ = try? await gate.performWriteCommand(name: "remoteOffloadFail") { writer in
                    try writer.write { db in try OffloadRepo.failOffload(db, queueId: job.queueId, error: "\(error)") }
                }
            }
        }
        return done
    }

    private func drainRehydrate() async throws -> Int {
        let claimed = try await gate.performWriteCommand(name: "remoteRehydrateClaim") { writer in
            try writer.write { db in try OffloadRepo.claimPendingRehydrate(db, limit: config.rehydrateBatch) }
        }.value

        var done = 0
        for job in claimed {
            do {
                let key = try await gate.performWriteCommand(name: "remoteRehydrateRead") { writer in
                    try writer.read { db in try OffloadRepo.latestRemoteKey(db, sessionId: job.sessionId) }
                }.value
                guard let key else {
                    _ = try await gate.performWriteCommand(name: "remoteRehydrateFail") { writer in
                        try writer.write { db in
                            try OffloadRepo.failRehydrate(db, queueId: job.queueId, error: "no remote key in ledger")
                        }
                    }
                    continue
                }
                let data = try await backend.get(key: key)
                let bundle = try BundleCodec.decode(data, expectedSessionId: job.sessionId)
                _ = try await gate.performWriteCommand(name: "remoteRehydrateCommit") { writer in
                    try writer.write { db in try OffloadRepo.commitRehydrated(db, queueId: job.queueId, bundle: bundle, peer: peer) }
                }
                done += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                _ = try? await gate.performWriteCommand(name: "remoteRehydrateFail") { writer in
                    try writer.write { db in try OffloadRepo.failRehydrate(db, queueId: job.queueId, error: "\(error)") }
                }
            }
        }
        return done
    }

    private func reclaimDiskIfNeeded() async throws -> Bool {
        let free = try await gate.performWriteCommand(name: "remoteReclaimProbe") { writer in
            try writer.freelistPageCount()
        }.value
        guard free >= config.vacuumFreelistThreshold else { return false }
        _ = try await gate.performWriteCommand(name: "remoteVacuum") { writer in
            try writer.vacuum()
        }
        return true
    }
}
