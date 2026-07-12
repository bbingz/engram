import XCTest

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
    }
}
