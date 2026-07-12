import Darwin
import EngramCoreWrite
import Foundation
import GRDB

actor ArchiveReclamationCoordinator {
    static let maximumCandidatesPerCycle = 10
    static let maximumSourceBytesPerCycle: Int64 = 256 * 1_024 * 1_024

    private struct ProductState: Sendable {
        let lastActivityNs: Int64
        let isLive: Bool
        let isFavorite: Bool
    }

    private struct CandidateCursorPayload: Codable {
        let boundAt: String
        let manifestSHA256: String
    }

    private let settingsURL: URL
    private let environment: [String: String]
    private let catalog: ArchiveCatalog
    private let sourceReclaimer: ArchiveSourceReclaimer
    private let casEvictor: ArchiveCASEvictor
    private let productPool: DatabasePool
    private var cycleTask: Task<EngramServiceArchiveReclamationRunResponse, Never>?
    private var lastError: String?

    init(
        settingsURL: URL,
        environment: [String: String],
        databasePath: String,
        catalog: ArchiveCatalog,
        cas: ImmutableArchiveCAS
    ) throws {
        self.settingsURL = settingsURL
        self.environment = environment
        self.catalog = catalog
        sourceReclaimer = ArchiveSourceReclaimer(catalog: catalog)
        casEvictor = ArchiveCASEvictor(catalog: catalog, cas: cas)
        var configuration = Configuration()
        configuration.readonly = true
        productPool = try DatabasePool(path: databasePath, configuration: configuration)
    }

    func status(now: Date = Date()) -> EngramServiceArchiveReclamationStatusResponse {
        let settings = loadSettings()
        return .init(
            enabled: settings.reclamation.enabled,
            hotWindowDays: settings.reclamation.hotWindowDays,
            configurationError: settings.reclamationConfigurationError?.rawValue,
            recoveryLeaseCurrent: recoveryLeases(now: now) != nil,
            cycleRunning: cycleTask != nil,
            lastError: lastError
        )
    }

    func preview(now: Date = Date()) -> EngramServiceArchiveReclamationPreviewResponse {
        do {
            let evaluations = try evaluateCandidates(now: now)
            var eligible = 0
            var bytes: Int64 = 0
            var blockers: [String: Int] = [:]
            for (candidate, decision, _) in evaluations {
                switch decision {
                case .eligible:
                    eligible += 1
                    bytes += candidate.capture.rawByteCount
                case .blocked(let blocker):
                    blockers[blocker.rawValue, default: 0] += 1
                }
            }
            return .init(eligibleCount: eligible, estimatedSourceBytes: bytes, blockedCounts: blockers)
        } catch {
            return .init(eligibleCount: 0, estimatedSourceBytes: 0, blockedCounts: ["preview_unavailable": 1])
        }
    }

    func updateSettings(
        _ request: EngramServiceArchiveReclamationUpdateSettingsRequest,
        now: Date = Date()
    ) throws -> EngramServiceArchiveReclamationStatusResponse {
        let current = loadSettings().reclamation.hotWindowDays
        let hotWindowDays = request.hotWindowDays ?? current
        guard ArchiveReclamationSettings.supportedHotWindowDays.contains(hotWindowDays) else {
            throw EngramServiceError.invalidRequest(message: "Invalid archive reclamation hot window")
        }
        if request.enabled, recoveryLeases(now: now) == nil {
            throw EngramServiceError.invalidRequest(message: "Current recovery drills are required before enabling reclamation")
        }
        try SecureSettingsFileWriter.mutateJSON(at: settingsURL) { object in
            object["archiveReclamation"] = [
                "enabled": request.enabled,
                "hotWindowDays": hotWindowDays,
            ]
        }
        lastError = nil
        return status(now: now)
    }

    func runNow(now: Date = Date()) async -> EngramServiceArchiveReclamationRunResponse {
        if let cycleTask {
            let result = await cycleTask.value
            return .init(
                accepted: result.accepted,
                coalesced: true,
                sourceFilesReclaimed: result.sourceFilesReclaimed,
                casObjectsEvicted: result.casObjectsEvicted,
                releasedBytes: result.releasedBytes,
                error: result.error
            )
        }
        let task = Task { [self] in executeCycle(now: now) }
        cycleTask = task
        let result = await task.value
        cycleTask = nil
        return result
    }

    func runAutomatically(now: Date = Date()) async {
        guard loadSettings().reclamation.enabled else { return }
        _ = await runNow(now: now)
    }

    private func executeCycle(now: Date) -> EngramServiceArchiveReclamationRunResponse {
        let settings = loadSettings()
        guard settings.reclamation.enabled,
              settings.reclamationConfigurationError == nil,
              recoveryLeases(now: now) != nil else {
            return response(error: "reclamation_paused")
        }
        do {
            var sourceCount = 0
            var casCount = 0
            var released: Int64 = 0
            var sourceBudget = Self.maximumSourceBytesPerCycle

            let casSnapshot = try catalog.reclamationIntents(
                phases: [.sourceDeleted],
                limit: Self.maximumCandidatesPerCycle
            )
            let recovery = try catalog.reclamationIntents(
                phases: [.quarantinePlanned, .sourceQuarantined, .sourceDeletePlanned],
                limit: Self.maximumCandidatesPerCycle
            )
            for intent in recovery {
                guard sourceCount < Self.maximumCandidatesPerCycle,
                      let capture = try catalog.capture(captureID: intent.captureID),
                      capture.rawByteCount <= sourceBudget else { continue }
                let result = try sourceReclaimer.recover(intent: intent, capture: capture)
                sourceCount += 1
                sourceBudget -= result.releasedBytes
                released += result.releasedBytes
            }

            for (candidate, decision, _) in try evaluateCandidates(now: now, advanceCursor: true) {
                guard sourceCount < Self.maximumCandidatesPerCycle,
                      case .eligible = decision,
                      candidate.capture.rawByteCount <= sourceBudget else { continue }
                let intent = try catalog.upsertReclamationIntent(
                    manifestSHA256: candidate.binding.manifestSHA256,
                    captureID: candidate.capture.captureID,
                    sessionID: candidate.binding.sessionID,
                    locator: candidate.capture.locator,
                    updatedAt: Self.timestamp(now)
                )
                let result = try sourceReclaimer.planAndReclaim(intent: intent, capture: candidate.capture)
                sourceCount += 1
                sourceBudget -= result.releasedBytes
                released += result.releasedBytes
            }

            var casBudget = ArchiveCASEvictor.maximumBytesPerCycle
            for intent in casSnapshot where casBudget > 0 {
                let result = try casEvictor.evictEligibleObjects(
                    for: intent.manifestSHA256,
                    now: now,
                    maximumBytes: casBudget
                )
                casCount += result.evictedObjects
                casBudget -= result.releasedBytes
                released += result.releasedBytes
            }
            lastError = nil
            return .init(accepted: true, coalesced: false, sourceFilesReclaimed: sourceCount, casObjectsEvicted: casCount, releasedBytes: released, error: nil)
        } catch is CancellationError {
            lastError = "cancelled"
            return response(error: "cancelled")
        } catch {
            lastError = "reclamation_failure"
            return response(error: "reclamation_failure")
        }
    }

    private func evaluateCandidates(
        now: Date,
        advanceCursor: Bool = false
    ) throws -> [(ArchiveReclamationCatalogCandidate, ArchiveReclamationDecision, ProductState)] {
        let settings = loadSettings()
        let leases = recoveryLeases(now: now) ?? [:]
        let nowNs = Self.nanoseconds(now)
        let context = ArchiveReclamationContext(
            enabled: settings.reclamation.enabled && settings.reclamationConfigurationError == nil,
            hotWindowDays: settings.reclamation.hotWindowDays,
            nowNs: nowNs,
            recoveryLeaseVerifiedAtNs: leases
        )
        let storedCursor = try reclamationCursor()
        var page = try catalog.reclamationCandidates(limit: 1_000, after: storedCursor)
        if page.isEmpty, storedCursor != nil {
            page = try catalog.reclamationCandidates(limit: 1_000)
        }
        if advanceCursor, let last = page.last?.binding {
            let payload = CandidateCursorPayload(
                boundAt: last.boundAt,
                manifestSHA256: last.manifestSHA256
            )
            _ = try catalog.storeArchiveCursorCheckpoint(
                JSONEncoder().encode(payload),
                for: .reclamationCycle,
                updatedAt: Self.timestamp(now)
            )
        }
        return try page.compactMap { candidate in
            guard let state = try productState(sessionID: candidate.binding.sessionID) else { return nil }
            let policyCandidate = ArchiveReclamationCandidate(
                source: candidate.capture.source,
                lastActivityNs: state.lastActivityNs,
                isLive: state.isLive,
                isFavorite: state.isFavorite,
                generationMatchesCapture: Self.generationMatches(candidate.capture),
                verifiedReceiptReplicaIDs: candidate.verifiedReplicaIDs,
                hasNewerCapture: candidate.hasNewerCapture,
                hasActiveOperation: candidate.hasActiveOperation,
                sourceByteCount: candidate.capture.rawByteCount
            )
            return (candidate, ArchiveReclamationPolicy.evaluate(candidate: policyCandidate, context: context), state)
        }
    }

    private func reclamationCursor() throws -> ArchiveBindingCursor? {
        guard let checkpoint = try catalog.archiveCursorCheckpoint(for: .reclamationCycle) else {
            return nil
        }
        let payload = try JSONDecoder().decode(CandidateCursorPayload.self, from: checkpoint.payload)
        return ArchiveBindingCursor(
            boundAt: payload.boundAt,
            manifestSHA256: payload.manifestSHA256
        )
    }

    private func productState(sessionID: String) throws -> ProductState? {
        try productPool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.start_time, s.end_time,
                  EXISTS(SELECT 1 FROM favorites f WHERE f.session_id = s.id) AS favorite
                FROM sessions s WHERE s.id = ?
                """, arguments: [sessionID]) else { return nil }
            let start: String = row["start_time"]
            let end: String? = row["end_time"]
            guard let activity = Self.date(end ?? start) else { return nil }
            return ProductState(
                lastActivityNs: Self.nanoseconds(activity),
                isLive: end == nil,
                isFavorite: (row["favorite"] as Int) != 0
            )
        }
    }

    private func recoveryLeases(now: Date) -> [String: Int64]? {
        var result: [String: Int64] = [:]
        for replicaID in ArchiveCatalog.currentReplicaIDs {
            guard let lease = try? catalog.recoveryLease(replicaID: replicaID),
                  let verifiedAt = Self.date(lease.verifiedAt),
                  verifiedAt <= now,
                  now.timeIntervalSince(verifiedAt) <= ArchiveCASEvictor.recoveryLeaseLifetime else {
                return nil
            }
            result[replicaID] = Self.nanoseconds(verifiedAt)
        }
        return result
    }

    private func loadSettings() -> ArchiveV2Settings {
        ArchiveV2Settings.load(settingsURL: settingsURL, environment: environment)
    }

    private func response(error: String) -> EngramServiceArchiveReclamationRunResponse {
        .init(accepted: false, coalesced: false, sourceFilesReclaimed: 0, casObjectsEvicted: 0, releasedBytes: 0, error: error)
    }

    private static func generationMatches(_ capture: ArchiveCapture) -> Bool {
        var info = stat()
        guard lstat(capture.locator, &info) == 0 else { return false }
        let generation = capture.generation
        return Int64(info.st_dev) == generation.device
            && Int64(info.st_ino) == generation.inode
            && Int64(info.st_size) == generation.size
            && Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec) == generation.mtimeNs
            && Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec) == generation.ctimeNs
            && Int64(info.st_mode) == generation.mode
    }

    private static func nanoseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
