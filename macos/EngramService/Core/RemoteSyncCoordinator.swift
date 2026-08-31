import Foundation
import EngramCoreWrite
import GRDB

/// Opt-in configuration for the remote session-offload loop. Feature default
/// OFF (`remoteOffloadEnabled`), read from `~/.engram/settings.json` (env
/// overrides for tests/dev). TLS policy is independent and fail-closed.
public struct RemoteSyncConfig: Sendable {
    public let enabled: Bool
    /// "local" → `LocalDirectoryBackend` (dir/NAS mount); "http" → the self-hosted
    /// `engram-remote` server via `EngramRemoteBackend`.
    public let backendKind: String
    public let serverURL: URL?
    /// When true, the HTTP backend forces HTTPS for every non-loopback host.
    /// Product default is **true** (SEC-H1 fail-closed via
    /// `remoteOffloadRequireTLS`). Explicit false remains allowed for trusted
    /// private / Tailscale cleartext ops.
    public let requireTLS: Bool
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
        serverURL: URL? = nil,
        requireTLS: Bool = true
    ) {
        self.enabled = enabled
        self.backendKind = backendKind
        self.serverURL = serverURL
        self.requireTLS = requireTLS
        self.storeRoot = storeRoot
        self.policy = policy
        self.offloadBatch = offloadBatch
        self.rehydrateBatch = rehydrateBatch
        self.vacuumFreelistThreshold = vacuumFreelistThreshold
    }

    public static func read(
        environment: [String: String],
        // Invariant 6: tests inject a temporary home and never touch ~/.engram.
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> RemoteSyncConfig {
        let home = homeDirectory
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
        let requireTLS: Bool = {
            // SEC-H1: fail closed — require TLS unless explicitly disabled for a
            // trusted private/Tailscale path. Env still wins for headless ops.
            if let env = environment["ENGRAM_REMOTE_OFFLOAD_REQUIRE_TLS"] {
                let normalized = env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !["0", "false", "no"].contains(normalized)
            }
            return (settings["remoteOffloadRequireTLS"] as? Bool) ?? true
        }()
        return RemoteSyncConfig(
            enabled: enabled,
            storeRoot: storeRoot,
            policy: OffloadPolicy(coldAgeDays: coldAgeDays),
            offloadBatch: (settings["remoteOffloadBatch"] as? Int) ?? 20,
            rehydrateBatch: (settings["remoteRehydrateBatch"] as? Int) ?? 20,
            vacuumFreelistThreshold: (settings["remoteOffloadVacuumFreelistPages"] as? Int) ?? 4_000,
            backendKind: backendKind,
            serverURL: serverURL,
            requireTLS: requireTLS
        )
    }

    static func homeDirectory(environment: [String: String]) -> URL {
        let processEnvironment = ProcessInfo.processInfo.environment
        let isTestProcess = environment["XCTestConfigurationFilePath"] != nil
            || processEnvironment["XCTestConfigurationFilePath"] != nil
        if isTestProcess {
            if let path = environment["CFFIXED_USER_HOME"], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            // docs/invariants.md #6: XCTest callers that omit an injected
            // fixed home must never fall through to the process user home.
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "engram-tests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        // docs/invariants.md #6: test entry points set both variables because
        // Darwin's FileManager home can ignore a HOME-only override.
        for key in ["CFFIXED_USER_HOME", "HOME"] {
            if let path = environment[key], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Opt-in HQ live publish / daily-Mac live ingest. Independent of
/// `remoteOffloadEnabled` so HQ can publish without arming `runOnce` / FTS
/// collapse. Peer identity is fail-closed: no hostname fallback.
public struct LiveIngestConfig: Sendable {
    public let publishEnabled: Bool
    public let ingestEnabled: Bool
    public let resolvedPeer: String?
    public let sources: [String]
    public let intervalSeconds: Int
    public let publishBatch: Int

    public init(
        publishEnabled: Bool,
        ingestEnabled: Bool,
        resolvedPeer: String?,
        sources: [String],
        intervalSeconds: Int,
        publishBatch: Int
    ) {
        self.publishEnabled = publishEnabled
        self.ingestEnabled = ingestEnabled
        self.resolvedPeer = resolvedPeer
        self.sources = sources
        self.intervalSeconds = intervalSeconds
        self.publishBatch = publishBatch
    }

    public var isArmed: Bool { publishEnabled || ingestEnabled }

    /// Mac pull identity: when ingest is on, `liveIngestSources` must be exactly
    /// one entry equal to the resolved peer. Publish-only needs the peer only.
    public var isLiveIdentityValid: Bool {
        guard let peer = resolvedPeer, !peer.isEmpty else { return false }
        if publishEnabled, ingestEnabled, sources.contains(peer) {
            return false
        }
        if ingestEnabled {
            return sources.count == 1 && sources[0] == peer
        }
        return true
    }

    public static func read(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LiveIngestConfig {
        var settings: [String: Any] = [:]
        let settingsURL = homeDirectory.appendingPathComponent(".engram", isDirectory: true)
            .appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = object
        }

        let publishEnabled = Self.envAllowlist(environment["ENGRAM_LIVE_PUBLISH_ENABLED"])
            ?? (settings["livePublishEnabled"] as? Bool)
            ?? false
        let ingestEnabled = Self.envAllowlist(environment["ENGRAM_LIVE_INGEST_ENABLED"])
            ?? (settings["liveIngestEnabled"] as? Bool)
            ?? false
        let resolvedPeer = Self.resolvePublishPeer(environment: environment, settings: settings)
        let sources: [String] = {
            if let env = environment["ENGRAM_LIVE_INGEST_SOURCES"], !env.isEmpty {
                return env.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            }
            if let list = settings["liveIngestSources"] as? [String] {
                return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            return []
        }()
        let rawInterval = Self.envInt(environment["ENGRAM_LIVE_INGEST_INTERVAL_SECONDS"])
            ?? (settings["liveIngestIntervalSeconds"] as? Int)
            ?? 900
        let rawBatch = Self.envInt(environment["ENGRAM_LIVE_PUBLISH_BATCH"])
            ?? (settings["livePublishBatch"] as? Int)
            ?? 50
        return LiveIngestConfig(
            publishEnabled: publishEnabled,
            ingestEnabled: ingestEnabled,
            resolvedPeer: resolvedPeer,
            sources: sources,
            intervalSeconds: min(900, max(300, rawInterval)),
            publishBatch: max(1, rawBatch)
        )
    }

    /// `ENGRAM_LIVE_INGEST_PEER` → `liveIngestPeerId` → `ENGRAM_REMOTE_OFFLOAD_PEER`.
    /// Empty at every step ⇒ nil. Never `ProcessInfo.hostName`.
    public static func resolvePublishPeer(
        environment: [String: String],
        settings: [String: Any]
    ) -> String? {
        let candidates = [
            environment["ENGRAM_LIVE_INGEST_PEER"],
            settings["liveIngestPeerId"] as? String,
            environment["ENGRAM_REMOTE_OFFLOAD_PEER"],
        ]
        for raw in candidates {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func envAllowlist(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        return ["1", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func envInt(_ raw: String?) -> Int? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }
}

/// Drives one offload/rehydrate/reclaim cycle through the single-writer gate.
/// Each DB mutation is its own `performWriteCommand` so the gate is RELEASED
/// across the network PUT/GET (which run strictly between gated writes). The FTS
/// purge happens only after a confirmed remote PUT or a verified existing bundle.
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
    /// enabled; returns nil when disabled or required configuration is absent.
    /// Backend validation/initialization errors are surfaced to callers.
    public static func makeIfEnabled(
        gate: ServiceWriterGate,
        environment: [String: String]
    ) throws -> RemoteSyncCoordinator? {
        let config = RemoteSyncConfig.read(
            environment: environment,
            homeDirectory: RemoteSyncConfig.homeDirectory(environment: environment)
        )
        guard config.enabled else { return nil }
        let peer = environment["ENGRAM_REMOTE_OFFLOAD_PEER"] ?? ProcessInfo.processInfo.hostName
        guard let backend = try makeBackend(config: config, environment: environment) else { return nil }
        return RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: peer)
    }

    /// Build the same HTTP/local backend as offload, but arm when live publish
    /// or ingest is on — even if `remoteOffloadEnabled` is false. Callers must
    /// never register `runOnce` / `drainOffload` on this coordinator.
    public static func makeLiveIfEnabled(
        gate: ServiceWriterGate,
        environment: [String: String]
    ) throws -> RemoteSyncCoordinator? {
        let home = RemoteSyncConfig.homeDirectory(environment: environment)
        let config = RemoteSyncConfig.read(environment: environment, homeDirectory: home)
        let live = LiveIngestConfig.read(environment: environment, homeDirectory: home)
        guard live.isArmed, live.isLiveIdentityValid, let peer = live.resolvedPeer else { return nil }
        guard let backend = try makeBackend(config: config, environment: environment) else { return nil }
        return RemoteSyncCoordinator(gate: gate, backend: backend, config: config, peer: peer)
    }

    private static func makeBackend(
        config: RemoteSyncConfig,
        environment: [String: String]
    ) throws -> (any RemoteStorageBackend)? {
        switch config.backendKind {
        case "http":
            // Self-hosted server. URL from settings (non-secret); bearer token from
            // Keychain (or env for headless), never from settings.json.
            guard let url = config.serverURL else { return nil }
            let token = environment["ENGRAM_REMOTE_OFFLOAD_TOKEN"] ?? RemoteCredentialStore.loadToken()
            guard let token, !token.isEmpty else { return nil }
            return try EngramRemoteBackend(baseURL: url, token: token, requireTLS: config.requireTLS)
        default:
            return try LocalDirectoryBackend(root: config.storeRoot)
        }
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

                // Network — OUTSIDE the write gate. HEAD is only an optimization;
                // an existing bundle is fetched and verified before commit.
                try await backend.ensureDurable(bundle: bundle)

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
                    try writer.write { db in
                        try OffloadRepo.commitRehydrated(
                            db,
                            queueId: job.queueId,
                            bundle: bundle,
                            expectedSyncVersion: job.syncVersion ?? 0,
                            peer: peer
                        )
                    }
                }
                done += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch RemoteSyncError.offloadStale {
                _ = try? await gate.performWriteCommand(name: "remoteRehydrateRequeue") { writer in
                    try writer.write { db in try OffloadRepo.requeueRehydrate(db, queueId: job.queueId) }
                }
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

// MARK: - Layer 2: per-project session-record sync (manual, preview-first)

/// Read-only summary of what a project sync WOULD do, for the confirm-first UX.
/// Counts plus a small title sample; no writes happen to produce it.
public struct ProjectSyncPreview: Codable, Sendable, Equatable {
    /// One actionable session in the preview: its real session id plus a display
    /// title (so a UI can key rows by a stable id, not a possibly-duplicate title).
    public struct Sample: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// "push" or "pull".
    public let direction: String
    public let project: String
    /// Sessions that would be uploaded (push) or imported (pull).
    public let actionable: Int
    /// Sessions already present remotely (push) / already imported & current (pull).
    public let skipped: Int
    /// Up to ~10 actionable sessions (real id + display title), for display.
    public let samples: [Sample]

    public init(direction: String, project: String, actionable: Int, skipped: Int, samples: [Sample]) {
        self.direction = direction
        self.project = project
        self.actionable = actionable
        self.skipped = skipped
        self.samples = samples
    }
}

extension RemoteSyncCoordinator {
    private static let previewSampleLimit = 10

    /// Push every local-origin session of `project` to the hub, then republish this
    /// peer's manifest. Network I/O (head/put) runs OUTSIDE the gate; only the
    /// `publishOnlyCommit` ledger write is gated. Re-running is a no-op for unchanged
    /// content (head skips the blob; publishOnlyCommit dedups per content hash).
    public func pushProject(project: String, cwd: String) async throws -> (uploaded: Int, skipped: Int) {
        let candidates = try await gate.performWriteCommand(name: "syncPushRead") { writer in
            try writer.read { db in try OffloadRepo.pushCandidates(db, project: project, cwd: cwd) }
        }.value

        var uploaded = 0
        var skipped = 0
        for candidate in candidates {
            let bundle = BundleCodec.makeBundle(
                sessionId: candidate.id,
                ftsContents: candidate.ftsContents,
                summary: candidate.summary,
                summaryMessageCount: candidate.summaryMessageCount,
                messageCount: candidate.messageCount,
                userMessageCount: candidate.userMessageCount,
                assistantMessageCount: candidate.assistantMessageCount,
                toolMessageCount: candidate.toolMessageCount,
                systemMessageCount: candidate.systemMessageCount,
                tier: candidate.tier,
                agentRole: candidate.agentRole,
                parentSessionId: candidate.parentSessionId,
                suggestedParentId: candidate.suggestedParentId
            )
            let key = BundleCodec.contentKey(bundle)
            let data = try BundleCodec.encode(bundle)
            // Network — OUTSIDE the write gate.
            let exists = try await backend.head(key: key)
            if exists {
                skipped += 1
            } else {
                try await backend.put(key: key, data: data)
                uploaded += 1
            }
            _ = try await gate.performWriteCommand(name: "syncPublishCommit") { writer in
                try writer.write { db in
                    try OffloadRepo.publishOnlyCommit(
                        db,
                        sessionId: candidate.id,
                        remoteKey: key,
                        remoteSessionId: candidate.id,
                        contentHash: bundle.contentHash,
                        peer: peer
                    )
                }
            }
        }

        // Republish this peer's manifest. The blob is per-peer (one
        // `catalog.<peer>.manifest`), so a multi-project peer must MERGE: keep other
        // projects' entries and replace only THIS project's slice. A full-replace
        // would make every previously-pushed project undiscoverable to all peers.
        let entries = try await gate.performWriteCommand(name: "syncManifestRead") { writer in
            try writer.read { db in
                try OffloadRepo.publishedManifestEntries(db, project: project, cwd: cwd, peer: peer)
            }
        }.value
        let manifestKey = ManifestCodec.manifestKey(peer: peer)
        // Entries published under THIS `project` all carry `entry.project == project`
        // (publishedManifestEntries normalizes it), so "other projects' entries" are
        // exactly those whose project differs — keep them, drop this project's old
        // slice (so locally-removed sessions also disappear from the manifest).
        // Network GET runs OUTSIDE the write gate, like the PUT below.
        //
        // FAIL-CLOSED: only an explicit "no manifest yet" (bundleNotFound) starts from
        // an empty slice. A transient GET error (5xx/timeout) or a corrupt/undecodable
        // existing manifest must NOT be swallowed — that would re-publish a manifest
        // holding ONLY this project and drop every other project from discovery. We
        // let those errors propagate so the push fails (it is idempotent; the user
        // retries) rather than silently destroying other projects' discoverability.
        var preserved: [SyncManifestEntry] = []
        do {
            let existingData = try await backend.get(key: manifestKey)
            let existing = try ManifestCodec.decode(existingData)
            preserved = existing.entries.filter {
                ($0.project ?? "").lowercased() != project.lowercased()
            }
        } catch RemoteSyncError.bundleNotFound {
            preserved = []
        }
        let manifest = SyncManifest(
            peer: peer, updatedAt: Self.timestamp(), entries: preserved + entries
        )
        let manifestData = try ManifestCodec.encode(manifest)
        try await backend.put(key: manifestKey, data: manifestData)

        return (uploaded, skipped)
    }

    /// Pull peer-published sessions of `project` from the hub catalog and import any
    /// that are new or changed. Skips this peer's own manifest (no echo) and entries
    /// whose content hash already matches the imported row. Network I/O outside the
    /// gate; each import committed in its own gated write.
    public func pullProject(project: String) async throws -> (imported: Int, skipped: Int) {
        let catalogData = try await backend.catalog()
        let manifests = try ManifestCodec.decodeCatalog(catalogData)

        var imported = 0
        var skipped = 0
        for manifest in manifests where manifest.peer != peer {
            let scopedEntries = manifest.entries.filter { Self.matchesProject($0, project: project) }
            let publishableEntries = scopedEntries.filter(Self.isPublishable)
            skipped += scopedEntries.count - publishableEntries.count

            // Invariants 2/3: a peer manifest is the authoritative project slice.
            // Withdraw rows that disappeared or became skip/subagent/children; do
            // not upgrade or retain hidden sessions just because they were imported.
            _ = try await gate.performWriteCommand(name: "syncImportRetract") { writer in
                try writer.write { db in
                    try ImportRepo.retractImportedSessions(
                        db,
                        peer: manifest.peer,
                        project: project,
                        retainingRemoteSessionIds: Set(publishableEntries.map(\.sessionId))
                    )
                }
            }

            for entry in publishableEntries {
                let needs = try await gate.performWriteCommand(name: "syncImportCheck") { writer in
                    try writer.read { db in
                        try ImportRepo.needsImport(db, peer: manifest.peer, entry: entry)
                    }
                }.value
                guard needs else { skipped += 1; continue }
                let data = try await backend.get(key: entry.remoteKey)
                let bundle = try BundleCodec.decode(data, expectedSessionId: entry.sessionId)
                guard bundle.contentHash == entry.contentHash else {
                    throw RemoteSyncError.contentHashMismatch(
                        expected: entry.contentHash,
                        actual: bundle.contentHash
                    )
                }
                _ = try await gate.performWriteCommand(name: "syncImportCommit") { writer in
                    try writer.write { db in
                        try ImportRepo.commitImported(db, entry: entry, peer: manifest.peer, bundle: bundle)
                    }
                }
                imported += 1
            }
        }
        return (imported, skipped)
    }

    /// READ-ONLY dry run: how many sessions a push/pull would act on, with sample
    /// titles. Performs network HEAD (push) / catalog GET (pull) but NO writes.
    public func previewProjectSync(
        project: String, cwd: String, direction: String
    ) async throws -> ProjectSyncPreview {
        if direction == "push" {
            let candidates = try await gate.performWriteCommand(name: "syncPreviewPushRead") { writer in
                try writer.read { db in try OffloadRepo.pushCandidates(db, project: project, cwd: cwd) }
            }.value
            var actionable: [ProjectSyncPreview.Sample] = []
            var skipped = 0
            for candidate in candidates {
                let bundle = BundleCodec.makeBundle(
                    sessionId: candidate.id,
                    ftsContents: candidate.ftsContents,
                    summary: candidate.summary,
                    summaryMessageCount: candidate.summaryMessageCount,
                    messageCount: candidate.messageCount,
                    userMessageCount: candidate.userMessageCount,
                    assistantMessageCount: candidate.assistantMessageCount,
                    toolMessageCount: candidate.toolMessageCount,
                    systemMessageCount: candidate.systemMessageCount,
                    tier: candidate.tier,
                    agentRole: candidate.agentRole,
                    parentSessionId: candidate.parentSessionId,
                    suggestedParentId: candidate.suggestedParentId
                )
                let exists = try await backend.head(key: BundleCodec.contentKey(bundle))
                if exists {
                    skipped += 1
                } else {
                    actionable.append(.init(id: candidate.id, title: candidate.title ?? candidate.id))
                }
            }
            return ProjectSyncPreview(
                direction: "push", project: project, actionable: actionable.count,
                skipped: skipped, samples: Array(actionable.prefix(Self.previewSampleLimit))
            )
        }

        // pull preview
        let catalogData = try await backend.catalog()
        let manifests = try ManifestCodec.decodeCatalog(catalogData)
        var actionable: [ProjectSyncPreview.Sample] = []
        var skipped = 0
        for manifest in manifests where manifest.peer != peer {
            for entry in manifest.entries where Self.matchesProject(entry, project: project) {
                guard Self.isPublishable(entry) else { skipped += 1; continue }
                let needs = try await gate.performWriteCommand(name: "syncPreviewImportCheck") { writer in
                    try writer.read { db in
                        try ImportRepo.needsImport(db, peer: manifest.peer, entry: entry)
                    }
                }.value
                if needs {
                    actionable.append(.init(id: entry.sessionId, title: entry.title ?? entry.sessionId))
                } else {
                    skipped += 1
                }
            }
        }
        return ProjectSyncPreview(
            direction: "pull", project: project, actionable: actionable.count,
            skipped: skipped, samples: Array(actionable.prefix(Self.previewSampleLimit))
        )
    }

    /// Case-insensitive project match for a manifest entry (project values are
    /// inconsistently cased across adapters; an entry carries no cwd).
    private static func matchesProject(_ entry: SyncManifestEntry, project: String) -> Bool {
        (entry.project ?? "").lowercased() == project.lowercased()
    }

    private static func isPublishable(_ entry: SyncManifestEntry) -> Bool {
        entry.tier?.lowercased() != "skip"
            && entry.agentRole == nil
            && entry.parentSessionId?.isEmpty != false
            && entry.suggestedParentId?.isEmpty != false
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    public struct LivePublishResult: Sendable, Equatable {
        public let uploaded: Int
        public let skipped: Int
        public let publishedEntries: Int
        public let complete: Bool
        public let hasMorePublishableRows: Bool
        public let generation: Int
        public let seq: Int
    }

    public struct LivePullResult: Sendable, Equatable {
        public let imported: Int
        public let skipped: Int
        public let occupancySkipped: Int
        public let retracted: Int
        public let shrinkGuardLatched: Bool
    }

    public func publishLivePeer(batch: Int = 50, completeWalk: Bool = true) async throws -> LivePublishResult {
        do {
            return try await publishLivePeerImpl(batch: batch, completeWalk: completeWalk)
        } catch let error as CancellationError {
            throw error
        } catch {
            await recordLiveOperationError(peer: peer, error: "publish_failed")
            throw error
        }
    }

    private func publishLivePeerImpl(batch: Int, completeWalk: Bool) async throws -> LivePublishResult {
        let pageSize = max(1, batch)
        let initialCursor = try await gate.performReadCommand(name: "livePublishCursor") { writer in
            try writer.read { db in
                (
                    try LiveIngestMetadata.get(db, LiveIngestMetadata.afterStartKey(peer: peer)),
                    try LiveIngestMetadata.get(db, LiveIngestMetadata.afterIdKey(peer: peer))
                )
            }
        }.value
        var afterStart: String? = nil
        var afterId: String? = nil

        var uploaded = 0
        var skipped = 0
        var lastPageCount = 0
        var encounteredStaleSnapshot = false
        repeat {
            let pageAfterStart = afterStart
            let pageAfterId = afterId
            let page = try await gate.performReadCommand(name: "livePublishRead") { writer in
                try writer.read { db in
                    try OffloadRepo.livePublishCandidates(
                        db,
                        limit: pageSize,
                        afterStart: pageAfterStart,
                        afterId: pageAfterId,
                        peer: peer,
                        onlyChanged: !completeWalk
                    )
                }
            }.value
            lastPageCount = page.count
            for candidate in page {
                guard candidate.ftsSnapshotReady else {
                    encounteredStaleSnapshot = true
                    continue
                }
                if candidate.bundleIsCurrent, candidate.publishedContentHash != nil {
                    skipped += 1
                    continue
                }
                let bundle = BundleCodec.makeBundle(
                    sessionId: candidate.id,
                    ftsContents: candidate.ftsContents,
                    summary: candidate.summary,
                    summaryMessageCount: candidate.summaryMessageCount,
                    messageCount: candidate.messageCount,
                    userMessageCount: candidate.userMessageCount,
                    assistantMessageCount: candidate.assistantMessageCount,
                    toolMessageCount: candidate.toolMessageCount,
                    systemMessageCount: candidate.systemMessageCount,
                    tier: candidate.tier,
                    agentRole: candidate.agentRole,
                    parentSessionId: candidate.parentSessionId,
                    suggestedParentId: candidate.suggestedParentId
                )
                let key = BundleCodec.contentKey(bundle)
                if candidate.publishedContentHash == bundle.contentHash {
                    skipped += 1
                } else {
                    let data = try BundleCodec.encode(bundle)
                    if try await backend.head(key: key) {
                        skipped += 1
                    } else {
                        try await backend.put(key: key, data: data)
                        uploaded += 1
                    }
                }
                let committed = try await gate.performWriteCommand(name: "livePublishCommit") { writer in
                    try writer.write { db in
                        let committed = try OffloadRepo.commitLivePublishedSnapshot(
                            db,
                            sessionId: candidate.id,
                            remoteKey: key,
                            contentHash: bundle.contentHash,
                            peer: peer,
                            expectedSyncVersion: candidate.syncVersion,
                            expectedSnapshotHash: candidate.snapshotHash
                        )
                        if committed {
                            try OffloadRepo.compactLivePublishLedger(
                                db, peer: peer, sessionId: candidate.id
                            )
                        }
                        return committed
                    }
                }.value
                encounteredStaleSnapshot = encounteredStaleSnapshot || !committed
            }
            if let last = page.last {
                afterStart = last.startTime
                afterId = last.id
            }
            if !completeWalk { break }
        } while lastPageCount == pageSize

        let remaining = try await gate.performReadCommand(name: "livePublishRemaining") { writer in
            try writer.read { db in
                let remainingReady = try OffloadRepo.livePublishCandidates(
                    db,
                    limit: 1,
                    peer: peer,
                    includeFtsContents: false,
                    onlyChanged: true
                )
                return (
                    hasReady: !remainingReady.isEmpty,
                    hasUnready: try OffloadRepo.hasUnreadyLivePublishCandidates(db)
                )
            }
        }.value
        let complete = !remaining.hasReady && !remaining.hasUnready && !encounteredStaleSnapshot
        let publishedState = try await gate.performReadCommand(name: "livePublishAssemble") { writer in
            try writer.read { db in
                (
                    entries: try OffloadRepo.livePublishedEntries(db, peer: peer),
                    retractionSessionIds: try OffloadRepo.livePublishedRetractionSessionIds(
                        db, peer: peer
                    )
                )
            }
        }.value
        let entries = publishedState.entries
        let retractionSessionIds = publishedState.retractionSessionIds

        let previousHead = try await loadLiveHead(peer: peer)
        if let previousHead {
            let previousManifestData = try await backend.get(key: previousHead.manifestKey)
            let actualHash = ManifestCodec.liveManifestContentHash(previousManifestData)
            guard actualHash == previousHead.contentHash else {
                throw RemoteSyncError.contentHashMismatch(
                    expected: previousHead.contentHash,
                    actual: actualHash
                )
            }
            let previousManifest = try ManifestCodec.decodeLiveManifest(previousManifestData)
            // Keep an already-complete head visible while a bounded dirty-row
            // sweep is incomplete. A complete sweep may reuse only
            // a complete head; otherwise it must publish the completeness edge.
            if previousManifest.entries == entries, !complete || previousHead.complete {
                if previousHead.complete {
                    try await finalizeCompleteLivePublish(
                        generation: previousHead.generation,
                        manifestKey: previousHead.manifestKey,
                        desiredAfterStart: complete ? nil : afterStart,
                        desiredAfterId: complete ? nil : afterId,
                        retractionSessionIds: retractionSessionIds
                    )
                } else {
                    try await persistLivePublishCursorIfNeeded(
                        initialStart: initialCursor.0,
                        initialId: initialCursor.1,
                        afterStart: afterStart,
                        afterId: afterId,
                        complete: complete
                    )
                }
                return LivePublishResult(
                    uploaded: uploaded,
                    skipped: skipped,
                    publishedEntries: entries.count,
                    complete: complete,
                    hasMorePublishableRows: remaining.hasReady,
                    generation: previousHead.generation,
                    seq: previousHead.seq
                )
            }
        }
        let seq = (previousHead?.seq ?? -1) + 1
        let lastCompleteGeneration = try await gate.performReadCommand(name: "livePublishGen") { writer in
            try writer.read { db in
                Int(try LiveIngestMetadata.get(db, LiveIngestMetadata.publishGenerationKey(peer: peer)) ?? "") ?? 0
            }
        }.value
        let generation = complete ? lastCompleteGeneration + 1 : lastCompleteGeneration

        var withdrawnCount = 0
        let previousCompleteKey = try await gate.performReadCommand(name: "livePublishPrevComplete") { writer in
            try writer.read { db in
                try LiveIngestMetadata.get(db, LiveIngestMetadata.currentCompleteKey(peer: peer))
            }
        }.value
        if complete, let previousCompleteKey {
            do {
                let prevData = try await backend.get(key: previousCompleteKey)
                let previous = try ManifestCodec.decodeLiveManifest(prevData)
                let currentIds = Set(entries.map(\.sessionId))
                withdrawnCount = previous.entries.filter { !currentIds.contains($0.sessionId) }.count
            } catch RemoteSyncError.bundleNotFound {
                withdrawnCount = 0
            }
        }

        let manifest = SyncManifest(peer: peer, updatedAt: Self.timestamp(), entries: entries)
        let manifestData = try ManifestCodec.encodeLiveManifest(manifest)
        let manifestKey = LiveIngestKeys.manifest(peer: peer, generation: generation, seq: seq)
        let head = LiveIngestHead(
            peer: peer,
            generation: generation,
            seq: seq,
            complete: complete,
            entryCount: entries.count,
            manifestKey: manifestKey,
            contentHash: ManifestCodec.liveManifestContentHash(manifestData),
            withdrawnCount: withdrawnCount
        )
        try await backend.put(key: manifestKey, data: manifestData)
        try await backend.put(key: LiveIngestKeys.head(peer: peer), data: try ManifestCodec.encodeLiveHead(head))

        let publishedAfterStart = afterStart
        let publishedAfterId = afterId
        if complete {
            try await finalizeCompleteLivePublish(
                generation: generation,
                manifestKey: manifestKey,
                desiredAfterStart: nil,
                desiredAfterId: nil,
                retractionSessionIds: retractionSessionIds
            )
        } else {
            let staleKeys = try await gate.performWriteCommand(name: "livePublishMeta") { writer in
                try writer.write { db in
                    var stale: [String] = []
                    if let previousIncomplete = try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.previousIncompleteKey(peer: peer)
                    ) {
                        stale.append(previousIncomplete)
                    }
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.previousIncompleteKey(peer: peer))
                    if let currentIncomplete = try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.lastIncompleteKey(peer: peer)
                    ) {
                        try LiveIngestMetadata.set(
                            db, LiveIngestMetadata.previousIncompleteKey(peer: peer), currentIncomplete
                        )
                    }
                    if let publishedAfterStart {
                        try LiveIngestMetadata.set(
                            db,
                            LiveIngestMetadata.afterStartKey(peer: peer),
                            publishedAfterStart
                        )
                    }
                    if let publishedAfterId {
                        try LiveIngestMetadata.set(
                            db,
                            LiveIngestMetadata.afterIdKey(peer: peer),
                            publishedAfterId
                        )
                    }
                    try LiveIngestMetadata.set(db, LiveIngestMetadata.lastIncompleteKey(peer: peer), manifestKey)
                    return stale.filter { $0 != manifestKey }
                }
            }.value
            for key in staleKeys {
                try await backend.delete(key: key)
            }
        }

        return LivePublishResult(
            uploaded: uploaded,
            skipped: skipped,
            publishedEntries: entries.count,
            complete: complete,
            hasMorePublishableRows: remaining.hasReady,
            generation: generation,
            seq: seq
        )
    }

    public func pullLivePeer(peer sourcePeer: String) async throws -> LivePullResult {
        do {
            return try await pullLivePeerImpl(peer: sourcePeer)
        } catch let error as CancellationError {
            throw error
        } catch let error as RemoteSyncError {
            switch error {
            case .liveShrinkGuardLatched, .livePeerMismatch, .liveManifestKeyMismatch:
                throw error
            default:
                await recordLiveOperationError(peer: sourcePeer, error: "pull_failed")
                throw error
            }
        } catch {
            await recordLiveOperationError(peer: sourcePeer, error: "pull_failed")
            throw error
        }
    }

    private func pullLivePeerImpl(peer sourcePeer: String) async throws -> LivePullResult {
        let head: LiveIngestHead
        do {
            head = try ManifestCodec.decodeLiveHead(
                try await backend.get(key: LiveIngestKeys.head(peer: sourcePeer))
            )
        } catch RemoteSyncError.bundleNotFound {
            return LivePullResult(imported: 0, skipped: 0, occupancySkipped: 0, retracted: 0, shrinkGuardLatched: false)
        }
        guard head.peer == sourcePeer else {
            try await recordLivePullError(peer: sourcePeer, error: "head_peer_mismatch")
            throw RemoteSyncError.livePeerMismatch(expected: sourcePeer, actual: head.peer)
        }
        let expectedManifestKey = LiveIngestKeys.manifest(
            peer: sourcePeer,
            generation: head.generation,
            seq: head.seq
        )
        guard head.manifestKey == expectedManifestKey else {
            try await recordLivePullError(peer: sourcePeer, error: "manifest_key_mismatch")
            throw RemoteSyncError.liveManifestKeyMismatch(
                expected: expectedManifestKey,
                actual: head.manifestKey
            )
        }

        let priorState = try await gate.performReadCommand(name: "livePullGenerationProbe") { writer in
            try writer.read { db in
                let lastGeneration = Int(
                    try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.lastGenerationKey(peer: sourcePeer)
                    ) ?? ""
                )
                let lastSeq = Int(
                    try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.lastSeqKey(peer: sourcePeer)
                    ) ?? ""
                )
                let latched = try LiveIngestMetadata.get(
                    db, LiveIngestMetadata.shrinkGuardLatchedKey(peer: sourcePeer)
                ) == "1"
                return (lastGeneration, lastSeq, latched)
            }
        }.value
        let isStaleHead = if let lastGeneration = priorState.0 {
            head.generation < lastGeneration
                || (head.generation == lastGeneration
                    && priorState.1.map { head.seq < $0 } == true)
        } else {
            false
        }
        if isStaleHead {
            try await recordLivePullError(peer: sourcePeer, error: "stale_generation")
            return LivePullResult(
                imported: 0,
                skipped: head.entryCount,
                occupancySkipped: 0,
                retracted: 0,
                shrinkGuardLatched: priorState.2
            )
        }

        let manifestData = try await backend.get(key: head.manifestKey)
        let actualHash = ManifestCodec.liveManifestContentHash(manifestData)
        guard actualHash == head.contentHash else {
            throw RemoteSyncError.contentHashMismatch(expected: head.contentHash, actual: actualHash)
        }
        let manifest = try ManifestCodec.decodeLiveManifest(manifestData)
        guard manifest.peer == sourcePeer else {
            try await recordLivePullError(peer: sourcePeer, error: "manifest_peer_mismatch")
            throw RemoteSyncError.livePeerMismatch(expected: sourcePeer, actual: manifest.peer)
        }
        let publishable = manifest.entries.filter(Self.isPublishable)
        let skippedHidden = manifest.entries.count - publishable.count

        let snapshot = try await gate.performReadCommand(name: "livePullProbe") { writer in
            try writer.read { db in
                let importedIds = try ImportRepo.importedPeerSessionIds(db, peer: sourcePeer)
                return (importedIds, priorState.2)
            }
        }.value
        let retaining = Set(publishable.map(\.sessionId))
        let retainingLocal = Set(retaining.map { ImportRepo.importedLocalId(peer: sourcePeer, sessionId: $0) })
        let retractCount = snapshot.0.filter { !retainingLocal.contains($0) }.count
        let cap = max(50, snapshot.0.count / 10)

        if head.complete, !snapshot.1, retractCount > cap {
            _ = try await gate.performWriteCommand(name: "livePullLatch") { writer in
                try writer.write { db in
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.shrinkGuardLatchedKey(peer: sourcePeer), "1"
                    )
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer), "shrink_guard"
                    )
                }
            }
            throw RemoteSyncError.liveShrinkGuardLatched(sourcePeer)
        }

        var imported = 0
        var skipped = skippedHidden
        var occupancySkipped = 0
        var hadBundleFailure = false
        for entry in publishable {
            let decision = try await gate.performReadCommand(name: "livePullCheck") { writer in
                try writer.read { db in
                    if try ImportRepo.localOriginOccupiesNativeId(db, nativeSessionId: entry.sessionId) {
                        return "occupy"
                    }
                    return try ImportRepo.needsImport(db, peer: sourcePeer, entry: entry) ? "import" : "skip"
                }
            }.value
            if decision == "occupy" {
                occupancySkipped += 1
                continue
            }
            if decision == "skip" {
                skipped += 1
                continue
            }
            let bundle: RemoteSessionBundle
            do {
                let data = try await backend.get(key: entry.remoteKey)
                bundle = try BundleCodec.decode(data, expectedSessionId: entry.sessionId)
                guard bundle.contentHash == entry.contentHash else {
                    throw RemoteSyncError.contentHashMismatch(
                        expected: entry.contentHash,
                        actual: bundle.contentHash
                    )
                }
            } catch RemoteSyncError.bundleNotFound {
                hadBundleFailure = true
                skipped += 1
                continue
            } catch RemoteSyncError.contentHashMismatch {
                hadBundleFailure = true
                skipped += 1
                continue
            }
            let committed = try await gate.performWriteCommand(name: "livePullCommit") { writer in
                try writer.write { db in
                    try ImportRepo.commitImportedIfNativeUnoccupied(
                        db,
                        entry: entry,
                        peer: sourcePeer,
                        bundle: bundle
                    )
                }
            }.value
            if committed {
                imported += 1
            } else {
                occupancySkipped += 1
            }
        }

        var retracted = 0
        var latched = snapshot.1
        let allowRetract = head.complete && !hadBundleFailure && (!latched || retractCount <= cap)
        if allowRetract {
            retracted = try await gate.performWriteCommand(name: "livePullRetract") { writer in
                try writer.write { db in
                    let removed = try ImportRepo.retractImportedPeerSessions(
                        db, peer: sourcePeer, retainingRemoteSessionIds: retaining
                    )
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.shrinkGuardLatchedKey(peer: sourcePeer))
                    return removed
                }
            }.value
            latched = false
        }

        let finalOccupancySkipped = occupancySkipped
        let finalHadBundleFailure = hadBundleFailure
        _ = try await gate.performWriteCommand(name: "livePullMeta") { writer in
            try writer.write { db in
                try LiveIngestMetadata.set(
                    db, LiveIngestMetadata.lastPullAtKey(peer: sourcePeer), Self.timestamp()
                )
                try LiveIngestMetadata.set(
                    db, LiveIngestMetadata.lastGenerationKey(peer: sourcePeer), String(head.generation)
                )
                try LiveIngestMetadata.set(
                    db, LiveIngestMetadata.lastSeqKey(peer: sourcePeer), String(head.seq)
                )
                if finalOccupancySkipped > 0 {
                    let prior = Int(
                        try LiveIngestMetadata.get(db, LiveIngestMetadata.occupancySkippedKey(peer: sourcePeer)) ?? ""
                    ) ?? 0
                    try LiveIngestMetadata.set(
                        db,
                        LiveIngestMetadata.occupancySkippedKey(peer: sourcePeer),
                        String(prior + finalOccupancySkipped)
                    )
                }
                let lastError = try LiveIngestMetadata.get(
                    db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer)
                )
                if finalHadBundleFailure, lastError != "shrink_guard" {
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer), "bundle_failure"
                    )
                } else if !finalHadBundleFailure, lastError != "shrink_guard" {
                    try LiveIngestMetadata.remove(
                        db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer)
                    )
                }
            }
        }

        return LivePullResult(
            imported: imported,
            skipped: skipped,
            occupancySkipped: occupancySkipped,
            retracted: retracted,
            shrinkGuardLatched: latched
        )
    }

    public func resetLiveIngestShrinkGuard(peer sourcePeer: String) async throws {
        try await Self.resetLiveIngestShrinkGuard(peer: sourcePeer, gate: gate)
    }

    public static func resetLiveIngestShrinkGuard(
        peer sourcePeer: String,
        gate: ServiceWriterGate
    ) async throws {
        _ = try await gate.performWriteCommand(name: "liveIngestResetShrinkGuard") { writer in
            try writer.write { db in
                try LiveIngestMetadata.remove(db, LiveIngestMetadata.shrinkGuardLatchedKey(peer: sourcePeer))
                if try LiveIngestMetadata.get(db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer)) == "shrink_guard" {
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.lastErrorKey(peer: sourcePeer))
                }
            }
        }
    }

    private func loadLiveHead(peer: String) async throws -> LiveIngestHead? {
        do {
            return try ManifestCodec.decodeLiveHead(try await backend.get(key: LiveIngestKeys.head(peer: peer)))
        } catch RemoteSyncError.bundleNotFound {
            return nil
        }
    }

    private func recordLivePullError(peer: String, error: String) async throws {
        _ = try await gate.performWriteCommand(name: "livePullError") { writer in
            try writer.write { db in
                try LiveIngestMetadata.set(
                    db,
                    LiveIngestMetadata.lastErrorKey(peer: peer),
                    error
                )
            }
        }
    }

    private func recordLiveOperationError(peer: String, error: String) async {
        _ = try? await gate.performWriteCommand(name: "liveOperationError") { writer in
            try writer.write { db in
                try LiveIngestMetadata.set(
                    db,
                    LiveIngestMetadata.lastErrorKey(peer: peer),
                    error
                )
            }
        }
    }

    private func persistLivePublishCursorIfNeeded(
        initialStart: String?,
        initialId: String?,
        afterStart: String?,
        afterId: String?,
        complete: Bool
    ) async throws {
        let desiredStart = complete ? nil : afterStart
        let desiredId = complete ? nil : afterId
        guard desiredStart != initialStart || desiredId != initialId else { return }
        _ = try await gate.performWriteCommand(name: "livePublishCursorUpdate") { writer in
            try writer.write { db in
                if let desiredStart {
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.afterStartKey(peer: peer), desiredStart
                    )
                } else {
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.afterStartKey(peer: peer))
                }
                if let desiredId {
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.afterIdKey(peer: peer), desiredId
                    )
                } else {
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.afterIdKey(peer: peer))
                }
            }
        }
    }

    private func finalizeCompleteLivePublish(
        generation: Int,
        manifestKey: String,
        desiredAfterStart: String?,
        desiredAfterId: String?,
        retractionSessionIds: [String]
    ) async throws {
        let needsFinalize = try await gate.performReadCommand(name: "livePublishFinalizeProbe") { writer in
            try writer.read { db in
                let metadataAligned =
                    try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.publishGenerationKey(peer: peer)
                    ) == String(generation)
                    && LiveIngestMetadata.get(
                        db, LiveIngestMetadata.currentCompleteKey(peer: peer)
                    ) == manifestKey
                    && LiveIngestMetadata.get(
                        db, LiveIngestMetadata.afterStartKey(peer: peer)
                    ) == desiredAfterStart
                    && LiveIngestMetadata.get(
                        db, LiveIngestMetadata.afterIdKey(peer: peer)
                    ) == desiredAfterId
                return !metadataAligned || !retractionSessionIds.isEmpty
            }
        }.value
        guard needsFinalize else { return }

        let staleKeys = try await gate.performWriteCommand(name: "livePublishMeta") { writer in
            try writer.write { db in
                var stale: [String] = []
                let currentComplete = try LiveIngestMetadata.get(
                    db, LiveIngestMetadata.currentCompleteKey(peer: peer)
                )
                if currentComplete != manifestKey {
                    if let previousIncomplete = try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.previousIncompleteKey(peer: peer)
                    ) {
                        stale.append(previousIncomplete)
                    }
                    try LiveIngestMetadata.remove(
                        db, LiveIngestMetadata.previousIncompleteKey(peer: peer)
                    )
                    if let currentIncomplete = try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.lastIncompleteKey(peer: peer)
                    ) {
                        try LiveIngestMetadata.set(
                            db,
                            LiveIngestMetadata.previousIncompleteKey(peer: peer),
                            currentIncomplete
                        )
                    }
                    if let previousComplete = try LiveIngestMetadata.get(
                        db, LiveIngestMetadata.previousCompleteKey(peer: peer)
                    ) {
                        stale.append(previousComplete)
                    }
                    if let currentComplete {
                        try LiveIngestMetadata.set(
                            db,
                            LiveIngestMetadata.previousCompleteKey(peer: peer),
                            currentComplete
                        )
                    } else {
                        try LiveIngestMetadata.remove(
                            db, LiveIngestMetadata.previousCompleteKey(peer: peer)
                        )
                    }
                }
                try LiveIngestMetadata.set(
                    db, LiveIngestMetadata.publishGenerationKey(peer: peer), String(generation)
                )
                try LiveIngestMetadata.set(
                    db, LiveIngestMetadata.currentCompleteKey(peer: peer), manifestKey
                )
                if let desiredAfterStart {
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.afterStartKey(peer: peer), desiredAfterStart
                    )
                } else {
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.afterStartKey(peer: peer))
                }
                if let desiredAfterId {
                    try LiveIngestMetadata.set(
                        db, LiveIngestMetadata.afterIdKey(peer: peer), desiredAfterId
                    )
                } else {
                    try LiveIngestMetadata.remove(db, LiveIngestMetadata.afterIdKey(peer: peer))
                }
                try LiveIngestMetadata.remove(db, LiveIngestMetadata.lastIncompleteKey(peer: peer))
                try OffloadRepo.acknowledgeLivePublishedRetractions(
                    db,
                    peer: peer,
                    sessionIds: retractionSessionIds
                )
                return stale.filter { $0 != manifestKey }
            }
        }.value
        for key in staleKeys {
            try await backend.delete(key: key)
        }
    }
}

private enum LiveIngestMetadata {
    static func shrinkGuardLatchedKey(peer: String) -> String { "live_ingest.\(peer).shrink_guard_latched" }
    static func lastPullAtKey(peer: String) -> String { "live_ingest.\(peer).last_pull_at" }
    static func lastGenerationKey(peer: String) -> String { "live_ingest.\(peer).last_generation" }
    static func lastSeqKey(peer: String) -> String { "live_ingest.\(peer).last_seq" }
    static func occupancySkippedKey(peer: String) -> String { "live_ingest.\(peer).occupancy_skipped" }
    static func lastErrorKey(peer: String) -> String { "live_ingest.\(peer).last_error" }
    static func publishGenerationKey(peer: String) -> String { "live_publish.\(peer).last_generation" }
    static func afterStartKey(peer: String) -> String { "live_publish.\(peer).after_start" }
    static func afterIdKey(peer: String) -> String { "live_publish.\(peer).after_id" }
    static func currentCompleteKey(peer: String) -> String { "live_publish.\(peer).current_complete_key" }
    static func previousCompleteKey(peer: String) -> String { "live_publish.\(peer).previous_complete_key" }
    static func lastIncompleteKey(peer: String) -> String { "live_publish.\(peer).last_incomplete_key" }
    static func previousIncompleteKey(peer: String) -> String { "live_publish.\(peer).previous_incomplete_key" }

    static func get(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [key])
    }

    static func set(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    static func remove(_ db: Database, _ key: String) throws {
        try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [key])
    }
}
