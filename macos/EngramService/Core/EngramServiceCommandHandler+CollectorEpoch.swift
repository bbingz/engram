import EngramCoreWrite
import Foundation
import GRDB

/// HQ operator surface for collector epoch authority (W4.7). Invariant
/// "Collector Epoch Approval Is A Local Operator Action": approval runs only
/// here, index-role only, with the exact expected binding, through the writer
/// gate. The dry run changes nothing. Neither command is on a Web allowlist or
/// on EngramServiceClientProtocol.
extension EngramServiceCommandHandler {
    func collectorEpochDryRunResponse(
        _ request: EngramServiceCollectorEpochDryRunRequest,
        settingsURL: URL
    ) async throws -> EngramServiceCollectorEpochDryRunResponse {
        try Self.mapCollectorEpochRefusal {
            _ = try ServiceCaptureSourceAuthority.requireIndexCaptureAdmission(at: settingsURL)
        }
        let result = try await writerGate.performReadCommand(name: "collectorEpochDryRun") { writer in
            try Self.mapCollectorEpochRefusal {
                try writer.read { db in
                    let dryRun = try CaptureIngestSourceRegistry.dryRunEpoch(
                        db, machineID: request.machineID, sourceInstanceID: request.sourceInstanceID,
                        candidateEpoch: request.candidateEpoch
                    )
                    let observed = try CaptureIngestSourceRegistry.observedUnapprovedEpochs(
                        db, machineID: request.machineID, sourceInstanceID: request.sourceInstanceID
                    )
                    return EngramServiceCollectorEpochDryRunResponse(
                        dryRun: true,
                        current: Self.collectorEpochBinding(dryRun.current),
                        candidateEpoch: dryRun.candidateEpoch,
                        candidateWasPreviouslyApproved: dryRun.candidateWasPreviouslyApproved,
                        currentBacklog: Self.collectorEpochBacklog(dryRun.currentBacklog),
                        candidateBacklog: Self.collectorEpochBacklog(dryRun.candidateBacklog),
                        observedUnapprovedEpochs: observed.map {
                            EngramServiceCollectorObservedEpoch(
                                collectorEpoch: $0.epoch, publicationCount: $0.publicationCount
                            )
                        }
                    )
                }
            }
        }
        return result.value
    }

    func collectorApproveEpochResponse(
        _ request: EngramServiceCollectorApproveEpochRequest,
        settingsURL: URL
    ) async throws -> ServiceWriterGateResult<EngramServiceCollectorApproveEpochResponse> {
        try Self.mapCollectorEpochRefusal {
            _ = try ServiceCaptureSourceAuthority.requireIndexCaptureAdmission(at: settingsURL)
        }
        let result = try await writerGate.performWriteCommand(name: "collectorApproveEpoch") { writer in
            try Self.mapCollectorEpochRefusal {
                try writer.write { db in
                    // Same double check as ServiceCaptureSourceAuthority.provision:
                    // role and enabled source are re-read inside the write.
                    let policy = try ServiceCaptureSourceAuthority.requireIndexCaptureAdmission(at: settingsURL)
                    guard let current = try CaptureIngestSourceRegistry.binding(
                        db, machineID: request.machineID, sourceInstanceID: request.sourceInstanceID
                    ) else {
                        throw CaptureIngestSourceRegistryError.unregisteredSourceInstance
                    }
                    guard policy.enabledSources.contains(current.source) else {
                        throw ServiceCaptureSourceAuthorityError.sourceDisabled
                    }
                    let next = try CaptureIngestSourceRegistry.approveEpoch(
                        db, machineID: request.machineID, sourceInstanceID: request.sourceInstanceID,
                        candidateEpoch: request.candidateEpoch, expectedEpoch: request.expectedEpoch,
                        expectedAuthorityGeneration: request.expectedAuthorityGeneration
                    )
                    return EngramServiceCollectorApproveEpochResponse(
                        previousEpoch: request.expectedEpoch,
                        previousAuthorityGeneration: request.expectedAuthorityGeneration,
                        current: Self.collectorEpochBinding(next)
                    )
                }
            }
        }
        ServiceLogger.notice(
            "collectorApproveEpoch approved machine=\(request.machineID) instance=\(request.sourceInstanceID) "
                + "generation=\(request.expectedAuthorityGeneration)->\(result.value.current.authorityGeneration)",
            category: .writer
        )
        return result
    }

    private static func collectorEpochBinding(
        _ binding: CaptureIngestSourceBinding
    ) -> EngramServiceCollectorEpochBinding {
        EngramServiceCollectorEpochBinding(
            machineID: binding.machineID, sourceInstanceID: binding.sourceInstanceID,
            source: binding.source.rawValue, parseFormat: binding.parseFormat.rawValue,
            configuredRoot: binding.configuredRoot, approvedEpoch: binding.approvedEpoch,
            authorityGeneration: binding.authorityGeneration
        )
    }

    private static func collectorEpochBacklog(
        _ backlog: CaptureIngestEpochBacklog
    ) -> EngramServiceCollectorEpochBacklog {
        EngramServiceCollectorEpochBacklog(
            publicationCount: backlog.publicationCount, ledgerTaskCounts: backlog.ledgerTaskCounts
        )
    }

    /// Registry and authority refusals become one structured, non-retryable
    /// envelope; cancellation and service errors pass through unchanged.
    private static func mapCollectorEpochRefusal<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CaptureIngestSourceRegistryError {
            throw collectorEpochRefused(String(describing: error))
        } catch let error as ServiceCaptureSourceAuthorityError {
            throw collectorEpochRefused(String(describing: error))
        }
    }

    private static func collectorEpochRefused(_ reason: String) -> EngramServiceError {
        .commandFailed(
            name: "CollectorEpochRefused", message: reason, retryPolicy: "never",
            details: ["reason": .string(reason)]
        )
    }
}
