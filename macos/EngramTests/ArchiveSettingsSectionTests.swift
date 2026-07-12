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
        XCTAssertEqual(
            source.components(separatedBy: "await refresh(reportError: false)").count - 1,
            3,
            "Save, Run Now, and recovery drill refreshes must preserve their action result message"
        )
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

    func testEveryArchiveSettingsStringHasSimplifiedChineseTranslation() throws {
        let catalogURL = macOSRoot.appendingPathComponent("Engram/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        let requiredKeys = [
            "%lld days",
            "%lld unbound archives (not a sync failure)",
            "%@: %lld verified, %lld retrying, %lld queued, %lld quarantined",
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
            "Lightweight Recovery Drills",
            "Preview",
            "Preview: %lld files, about %@.",
            "Recovery drills current",
            "Recovery drills required",
            "Refresh Status",
            "Released %@.",
            "Run Now",
            "Save",
            "Search metadata and summaries remain local. Older source files and local archive objects are reclaimed only after both remote copies and both current recovery drills are verified.",
            "Sync status unavailable",
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
        dualReplicaVerifiedCount: Int = 0
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
            replicas: [try replica("hq"), try replica("m1")],
            singleReplicaVerifiedCount: 0,
            dualReplicaVerifiedCount: dualReplicaVerifiedCount,
            latestReceipts: [],
            lastCaptureError: nil,
            lastReplicationError: nil,
            cycleRunning: false,
            cycleCoalesced: false
        )
    }

    private func replica(_ replicaID: String) throws -> EngramServiceArchiveV2ReplicaStatus {
        try EngramServiceArchiveV2ReplicaStatus(
            replicaID: replicaID,
            queuedCount: 0,
            retryingCount: 0,
            quarantinedCount: 0,
            verifiedCount: 0
        )
    }
}
