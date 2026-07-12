import XCTest
@testable import Engram

final class ArchiveSettingsSectionTests: XCTestCase {
    private var macOSRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testArchiveSettingsShowsAuthoritativeReplicaStatusWithoutPolling() throws {
        let sourceURL = macOSRoot
            .appendingPathComponent("Engram/Views/Settings/ArchiveSettingsSection.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("archiveV2Status()"))
        for identifier in [
            "archiveSync_status",
            "archiveSync_progress",
            "archiveSync_hq",
            "archiveSync_m1",
            "archiveSync_hqDiagnostics",
            "archiveSync_m1Diagnostics",
            "archiveSync_hqRemoteTelemetry",
            "archiveSync_m1RemoteTelemetry",
            "archiveSync_lastCycle",
            "archiveSync_nextCycle",
            "archiveSync_unbound",
            "archiveSync_refresh",
        ] {
            XCTAssertTrue(source.contains(identifier), "Missing \(identifier)")
        }

        XCTAssertFalse(source.contains("Timer.publish"))
        XCTAssertFalse(source.contains("Task.sleep"))
        XCTAssertFalse(source.contains("ContinuousClock"))
        XCTAssertTrue(source.contains("syncRefreshGeneration"))
        XCTAssertTrue(source.contains("guard requestGeneration == syncRefreshGeneration"))
        XCTAssertEqual(source.components(separatedBy: ".task { await refresh() }").count - 1, 1)
        XCTAssertEqual(
            source.components(separatedBy: "await refresh(reportError: false)").count - 1,
            3,
            "Save, Run Now, and recovery drill refreshes must preserve their action result message"
        )
    }

    func testRemoteSummaryShowsOnlineTelemetryWithoutRawSymbols() throws {
        let revision = "0123456789abcdef0123456789abcdef01234567"
        let telemetry = try remoteTelemetry(
            replicaID: "hq",
            revision: revision,
            persistenceError: "snapshot_write_failed",
            recentErrors: [try remoteError(category: "storage_unavailable")]
        )

        let summary = ArchiveRemoteTelemetryPresentation.summary(
            replicaID: "hq",
            telemetry: telemetry,
            error: nil
        )

        XCTAssertTrue(summary.contains("HQ"))
        XCTAssertTrue(summary.contains(String(revision.prefix(8))))
        XCTAssertFalse(summary.contains(revision))
        XCTAssertTrue(summary.contains(String(localized: "Online")))
        XCTAssertTrue(summary.contains(":28"), "Snapshot time must be shown: \(summary)")
        XCTAssertTrue(summary.contains(":24"), "Last mutation time must be shown: \(summary)")
        for count in ["41", "3", "2", "64", "128"] {
            XCTAssertTrue(summary.contains(count), "Missing \(count) in \(summary)")
        }
        XCTAssertTrue(summary.contains(String(localized: "Storage unavailable")))
        XCTAssertTrue(summary.contains(String(localized: "Snapshot persistence failed")))
        XCTAssertFalse(summary.contains("storage_unavailable"))
        XCTAssertFalse(summary.contains("snapshot_write_failed"))
    }

    func testRemoteSummaryUsesUnavailableForOutOfRangeUptime() throws {
        let unavailable = String(localized: "Uptime unavailable")
        let wrappedUnavailable = String.localizedStringWithFormat(
            String(localized: "Uptime: %@"),
            unavailable
        )
        for uptimeSeconds in [Double(Int64.max) * 60, .greatestFiniteMagnitude] {
            let telemetry = try remoteTelemetry(
                replicaID: "hq",
                uptimeSeconds: uptimeSeconds
            )

            let summary = ArchiveRemoteTelemetryPresentation.summary(
                replicaID: "hq",
                telemetry: telemetry,
                error: nil
            )

            let parts = summary.components(separatedBy: " · ")
            XCTAssertEqual(parts.filter { $0 == unavailable }.count, 1)
            XCTAssertFalse(parts.contains(wrappedUnavailable))
        }
    }

    func testRemoteSummaryHandlesUnavailableAndPartialSuccessIndependently() throws {
        let hq = ArchiveRemoteTelemetryPresentation.summary(
            replicaID: "hq",
            telemetry: try remoteTelemetry(replicaID: "hq"),
            error: nil
        )
        let m1 = ArchiveRemoteTelemetryPresentation.summary(
            replicaID: "m1",
            telemetry: nil,
            error: "transport_timeout"
        )
        let missing = ArchiveRemoteTelemetryPresentation.summary(
            replicaID: "m1",
            telemetry: nil,
            error: nil
        )

        XCTAssertTrue(hq.contains("HQ"))
        XCTAssertTrue(hq.contains(String(localized: "Online")))
        XCTAssertTrue(m1.contains("M1"))
        XCTAssertTrue(m1.contains(String(localized: "Remote status unavailable")))
        XCTAssertTrue(m1.contains(String(localized: "Request timed out")))
        XCTAssertFalse(m1.contains("transport_timeout"))
        XCTAssertEqual(
            missing,
            ["M1", String(localized: "Remote status unavailable")].joined(separator: " · ")
        )
        XCTAssertFalse(missing.contains(String(localized: "Other remote error")))
    }

    func testRemoteErrorSymbolsAndSanitizedCategoriesNeverRenderRawValues() {
        let fetchSymbols = [
            "final_url_mismatch",
            "invalid_canonical_response",
            "invalid_request",
            "not_http_response",
            "redirect_rejected",
            "remote_telemetry_unavailable",
            "response_too_large",
            "telemetry_unsupported",
            "transport_cancelled",
            "transport_network",
            "transport_timeout",
            "transport_tls",
            "unexpected_status",
            "future_private_detail",
        ]
        for symbol in fetchSymbols {
            let presentation = ArchiveRemoteTelemetryPresentation.remoteErrorName(symbol)
            XCTAssertFalse(presentation.isEmpty)
            XCTAssertFalse(presentation.contains(symbol), "Leaked raw error symbol: \(symbol)")
        }

        let categories = [
            "unauthorized",
            "malformed_request",
            "not_found",
            "conflict",
            "payload_too_large",
            "invalid_content",
            "storage_unavailable",
            "internal_error",
            "future_private_detail",
        ]
        for category in categories {
            let presentation = ArchiveRemoteTelemetryPresentation.errorCategoryName(category)
            XCTAssertFalse(presentation.isEmpty)
            XCTAssertFalse(presentation.contains(category), "Leaked raw error category: \(category)")
        }
    }

    func testSyncPresentationPrioritizesConfigurationFailureOverDisabledRemote() throws {
        let status = try makeStatus(
            enabled: true,
            remoteReplicationEnabled: false,
            configurationError: "remote_credentials_unavailable"
        )

        XCTAssertEqual(ArchiveSyncPresentationState(status: status), .needsAttention)
    }

    func testSyncPresentationDistinguishesDisabledPendingAndComplete() throws {
        XCTAssertEqual(
            ArchiveSyncPresentationState(
                status: try makeStatus(enabled: false, localCaptureEnabled: false, remoteReplicationEnabled: false)
            ),
            .disabled
        )
        XCTAssertEqual(
            ArchiveSyncPresentationState(
                status: try makeStatus(remotePolicyEligibleCount: 8, dualReplicaVerifiedCount: 7)
            ),
            .inProgress
        )
        XCTAssertEqual(
            ArchiveSyncPresentationState(
                status: try makeStatus(remotePolicyEligibleCount: 8, dualReplicaVerifiedCount: 8)
            ),
            .complete
        )
        XCTAssertEqual(ArchiveSyncPresentationState(status: nil), .unavailable)
    }

    func testRetryReasonsGroupIntoFriendlyDeterministicCategories() throws {
        let grouped = ArchiveSyncRetryPresentation.group([
            try reason("transport_network", 2),
            try reason("remote_server_unavailable", 1),
            try reason("remote_auth_rejected", 1),
            try reason("local_object_missing", 2),
            try reason("remote_receipt_mismatch", 1),
            try reason("replica_configuration_failure", 1),
            try reason("future_symbol", 3),
        ])

        XCTAssertEqual(grouped, [
            ArchiveSyncRetryCategoryCount(category: .network, count: 3),
            ArchiveSyncRetryCategoryCount(category: .credentials, count: 1),
            ArchiveSyncRetryCategoryCount(category: .localArchive, count: 2),
            ArchiveSyncRetryCategoryCount(category: .remoteVerification, count: 1),
            ArchiveSyncRetryCategoryCount(category: .configuration, count: 1),
            ArchiveSyncRetryCategoryCount(category: .other, count: 3),
        ])
    }

    func testSyncPresentationOnlyEscalatesNonTransientRetryReasons() throws {
        let networkStatus = try makeStatus(
            replicas: [
                try replica(
                    "hq",
                    retryingCount: 1,
                    retryReasons: [try reason("transport_network", 1)]
                ),
                try replica("m1"),
            ]
        )
        let localFailureStatus = try makeStatus(
            replicas: [
                try replica(
                    "hq",
                    retryingCount: 1,
                    retryReasons: [try reason("local_object_missing", 1)]
                ),
                try replica("m1"),
            ]
        )

        XCTAssertEqual(ArchiveSyncPresentationState(status: networkStatus), .inProgress)
        XCTAssertEqual(ArchiveSyncPresentationState(status: localFailureStatus), .needsAttention)
    }

    func testEveryArchiveSettingsStringHasSimplifiedChineseTranslation() throws {
        let catalogURL = macOSRoot.appendingPathComponent("Engram/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let requiredKeys = [
            "%lld days",
            "%lld ms",
            "%lld unbound archives (not a sync failure)",
            "%@: %lld verified, %lld retrying, %lld queued, %lld quarantined",
            "%@ s",
            "%lld d, %lld hr",
            "%lld hr, %lld min",
            "%lld min",
            "Cancelled",
            "Configuration",
            "Credentials",
            "%@ recovery drill passed.",
            "Archive & Storage",
            "Archive Sync Status",
            "Archive synchronization complete",
            "Archive synchronization disabled",
            "Archive synchronization in progress",
            "Archive synchronization needs attention",
            "Automatic Local Reclamation",
            "Automatic reclamation disabled.",
            "Automatic reclamation enabled.",
            "Automatically reclaim old local transcripts",
            "Dual-copy verified: %lld of %lld",
            "Build: %@",
            "Client errors: %lld",
            "Conflict",
            "Disk free: %@",
            "Disk free: %@ of %@",
            "Disk free: unavailable",
            "Each drill restores and verifies one bounded archived transcript. It does not scan the entire archive.",
            "Error: %@ recovery drill failed.",
            "Error: archive status unavailable.",
            "Error: exact archive storage is disabled.",
            "Error: preview unavailable.",
            "Error: reclamation failed.",
            "Error: reclamation is paused until its safety gates are current.",
            "Error: reclamation run failed.",
            "Error: reclamation was cancelled.",
            "Error: save failed because the service is unavailable.",
            "Error: save failed. Verify both recovery drills are current and the service is available.",
            "Keep full local transcripts",
            "Internal server error",
            "Invalid content",
            "Invalid remote response",
            "Issue: %@",
            "Last pass %@ · %@ · verified %lld · retry %lld · quarantined %lld",
            "Lightweight Recovery Drills",
            "Local archive",
            "Last write: %@",
            "Last write: none",
            "Latest error: %@",
            "Latest error: none",
            "Network",
            "Network error",
            "Next background opportunity around %@",
            "Next retry: %@",
            "Oldest pending: %@",
            "Other",
            "Other remote error",
            "Malformed request",
            "Not found",
            "Online",
            "Payload too large",
            "Persistence: %@",
            "Preview",
            "Preview: %lld files, about %@.",
            "Recovery drills current",
            "Recovery drills required",
            "Remote verification",
            "Remote status unavailable",
            "Remote telemetry unavailable",
            "Request cancelled",
            "Request timed out",
            "Requests: %lld",
            "Retry reasons: %@",
            "Refresh Status",
            "Released %@.",
            "Run Now",
            "Save",
            "Search metadata and summaries remain local. Older source files and local archive objects are reclaimed only after both remote copies and both current recovery drills are verified.",
            "Sync status unavailable",
            "Server errors: %lld",
            "Snapshot: %@",
            "Snapshot persistence failed",
            "Storage unavailable",
            "TLS error",
            "Telemetry unsupported",
            "Unauthorized",
            "Unknown build",
            "Uptime: %@",
            "Uptime unavailable",
            "Verify HQ",
            "Verify M1",
        ]

        var missing: [String] = []
        for key in requiredKeys {
            guard
                let entry = strings[key] as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any],
                let chinese = localizations["zh-Hans"] as? [String: Any],
                let unit = chinese["stringUnit"] as? [String: Any],
                let value = unit["value"] as? String,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                missing.append(key)
                continue
            }
        }

        XCTAssertEqual(missing, [], "Missing zh-Hans Archive settings translations: \(missing)")

        for key in requiredKeys where key.contains("%") {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let chinese = try XCTUnwrap(localizations["zh-Hans"] as? [String: Any])
            let unit = try XCTUnwrap(chinese["stringUnit"] as? [String: Any])
            let value = try XCTUnwrap(unit["value"] as? String)
            XCTAssertEqual(
                formatSignature(value),
                formatSignature(key),
                "Localized format arguments differ for \(key)"
            )
        }
    }

    private func formatSignature(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|@)"#)
        let range = NSRange(value.startIndex..., in: value)
        var implicitIndex = 1
        return regex.matches(in: value, range: range).map { match in
            let explicitRange = Range(match.range(at: 1), in: value)
            let index: Int
            if let explicitRange, let explicit = Int(value[explicitRange]) {
                index = explicit
            } else {
                index = implicitIndex
                implicitIndex += 1
            }
            let typeRange = Range(match.range(at: 2), in: value)!
            return "\(index):\(value[typeRange])"
        }
        .sorted()
    }

    private func makeStatus(
        enabled: Bool = true,
        localCaptureEnabled: Bool = true,
        remoteReplicationEnabled: Bool = true,
        configurationError: String? = nil,
        remotePolicyEligibleCount: Int = 0,
        dualReplicaVerifiedCount: Int = 0,
        replicas: [EngramServiceArchiveV2ReplicaStatus]? = nil
    ) throws -> EngramServiceArchiveV2StatusResponse {
        try EngramServiceArchiveV2StatusResponse(
            enabled: enabled,
            localCaptureEnabled: localCaptureEnabled,
            remoteReplicationEnabled: remoteReplicationEnabled,
            configurationError: configurationError,
            capturedCount: 0,
            boundCount: 0,
            unboundCount: 0,
            remotePolicyUnknownCount: 0,
            remotePolicyEligibleCount: remotePolicyEligibleCount,
            remotePolicyExcludedCount: 0,
            unsupportedLocatorCount: 0,
            unsafeLocatorCount: 0,
            replicas: replicas ?? [try replica("hq"), try replica("m1")],
            singleReplicaVerifiedCount: 0,
            dualReplicaVerifiedCount: dualReplicaVerifiedCount,
            latestReceipts: [],
            lastCaptureError: nil,
            lastReplicationError: nil,
            cycleRunning: false,
            cycleCoalesced: false
        )
    }

    private func replica(
        _ replicaID: String,
        retryingCount: Int = 0,
        retryReasons: [EngramServiceArchiveV2RetryReasonCount] = []
    ) throws -> EngramServiceArchiveV2ReplicaStatus {
        try EngramServiceArchiveV2ReplicaStatus(
            replicaID: replicaID,
            queuedCount: 0,
            retryingCount: retryingCount,
            quarantinedCount: 0,
            verifiedCount: 0,
            retryReasons: retryReasons
        )
    }

    private func reason(
        _ symbol: String,
        _ count: Int
    ) throws -> EngramServiceArchiveV2RetryReasonCount {
        try EngramServiceArchiveV2RetryReasonCount(symbol: symbol, count: count)
    }

    private func remoteTelemetry(
        replicaID: String,
        revision: String = "abcdef0123456789abcdef0123456789abcdef01",
        uptimeSeconds: Double = 5_408,
        persistenceError: String? = nil,
        recentErrors: [EngramServiceArchiveV2RemoteError] = []
    ) throws -> EngramServiceArchiveV2RemoteTelemetry {
        try EngramServiceArchiveV2RemoteTelemetry(
            serverID: replicaID,
            sourceRevision: revision,
            snapshotAt: "2026-07-12T17:28:00.000Z",
            uptimeSeconds: uptimeSeconds,
            diskAvailableBytes: 64 * 1_024 * 1_024 * 1_024,
            diskTotalBytes: 128 * 1_024 * 1_024 * 1_024,
            requestCount: 41,
            clientErrorCount: 3,
            serverErrorCount: 2,
            lastArchiveMutationAt: "2026-07-12T17:24:00.000Z",
            persistenceError: persistenceError,
            endpoints: [],
            recentErrors: recentErrors
        )
    }

    private func remoteError(category: String) throws -> EngramServiceArchiveV2RemoteError {
        try EngramServiceArchiveV2RemoteError(
            timestamp: "2026-07-12T17:27:00.000Z",
            endpoint: "object",
            method: "PUT",
            statusCode: 507,
            category: category
        )
    }
}
