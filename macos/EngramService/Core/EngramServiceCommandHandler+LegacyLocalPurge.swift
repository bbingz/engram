import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB

// docs/invariants.md "Legacy Local-Origin Purge Is An Explicit Operator Action":
// both commands run only on a service whose startup role is `index`; preview is
// a gated read, apply is one gated write transaction bound to the approved plan.
extension EngramServiceCommandHandler {
    func legacyLocalPurgePreviewResponse() async throws
        -> ServiceWriterGateResult<EngramServiceLegacyLocalPurgePreviewResponse>
    {
        try requireLegacyLocalPurgeIndexRole()
        return try await writerGate.performReadCommand(name: "legacyLocalPurgePreview") { writer in
            Self.legacyLocalPurgePreview(try writer.read { try LegacyLocalSessionPurge.report($0) })
        }
    }

    func legacyLocalPurgeApplyResponse(
        _ request: EngramServiceLegacyLocalPurgeApplyRequest
    ) async throws -> ServiceWriterGateResult<EngramServiceLegacyLocalPurgeApplyResponse> {
        try requireLegacyLocalPurgeIndexRole()
        let purgedAt = ISO8601DateFormatter().string(from: Date())
        do {
            return try await writerGate.performWriteCommand(name: "legacyLocalPurgeApply") { writer in
                let result = try writer.write { db in
                    try LegacyLocalSessionPurge.purge(
                        db,
                        expectedSessionCount: request.expectedSessionCount,
                        expectedPlanToken: request.expectedPlanToken,
                        purgedAt: purgedAt
                    )
                }
                return EngramServiceLegacyLocalPurgeApplyResponse(
                    planToken: result.planToken,
                    sessionsDeleted: result.sessionsDeleted,
                    deleted: result.deleted,
                    auditKey: result.auditKey,
                    purgedAt: result.purgedAt
                )
            }
        } catch let error as LegacyLocalSessionPurge.PurgeError {
            throw EngramServiceError.invalidRequest(message: Self.legacyLocalPurgeMessage(error))
        }
    }

    private func requireLegacyLocalPurgeIndexRole() throws {
        guard runtimeRole == .index else {
            throw EngramServiceError.invalidRequest(
                message: "legacy local purge requires runtimeRole index"
            )
        }
    }

    static func legacyLocalPurgePreview(
        _ report: LegacyLocalSessionPurge.Report
    ) -> EngramServiceLegacyLocalPurgePreviewResponse {
        EngramServiceLegacyLocalPurgePreviewResponse(
            predicateVersion: report.predicateVersion,
            sessionCount: report.sessionCount,
            planToken: report.planToken,
            sources: report.sources.map {
                EngramServiceLegacyLocalPurgeSourceSummary(
                    source: $0.source,
                    sessions: $0.sessions,
                    newestIndexedAt: $0.newestIndexedAt,
                    newestStartTime: $0.newestStartTime
                )
            },
            blocking: report.blocking,
            derived: report.derived,
            retained: report.retained,
            captureBoundExcluded: report.captureBoundExcluded,
            otherLocalOriginSessions: report.otherLocalOriginSessions,
            purgeAllowed: report.purgeAllowed
        )
    }

    private static func legacyLocalPurgeMessage(_ error: LegacyLocalSessionPurge.PurgeError) -> String {
        switch error {
        case .planChanged(let sessionCount, let planToken):
            return "legacy local purge plan changed: sessions=\(sessionCount) token=\(planToken)"
        case .blockingDependents(let counts):
            let detail = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return "legacy local purge refused: user-state dependents \(detail)"
        case .nothingToPurge:
            return "legacy local purge has nothing to purge"
        case .notInTransaction, .verificationFailed:
            return "legacy local purge verification failed"
        }
    }
}

extension EngramServiceRunner {
    static let legacyLocalPurgeReportFlag = "--legacy-local-purge-report"

    /// Returns the database path when argv asks for the offline report. The
    /// only accepted shape is `--legacy-local-purge-report --database-path ABS`.
    static func legacyLocalPurgeReportDatabasePath(arguments: [String]) throws -> String? {
        guard arguments.contains(legacyLocalPurgeReportFlag) else { return nil }
        guard arguments.count == 3,
              arguments[0] == legacyLocalPurgeReportFlag,
              arguments[1] == "--database-path",
              let path = try engramServiceAbsoluteArgumentValue(after: "--database-path", in: arguments) else {
            throw EngramServiceError.invalidRequest(
                message: "usage: EngramService --legacy-local-purge-report --database-path ABS"
            )
        }
        return path
    }

    /// Offline dry-run for a backup copy: opens the file read-only (never
    /// creates it) and prints the same report the live preview returns.
    static func legacyLocalPurgeReportJSON(databasePath: String) throws -> String {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: databasePath, configuration: configuration)
        let report = try queue.read { try LegacyLocalSessionPurge.report($0) }
        try queue.close()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}
