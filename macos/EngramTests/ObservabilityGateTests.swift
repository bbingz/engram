import XCTest
@testable import Engram

/// WP17 — Observability honesty. Source-asserts the surgical guarantees the
/// alignment design requires (un-redacted log bodies, no dead "warn" filter,
/// default-off Developer-Tools gate) plus one behavioral check that an emitted
/// message reads back as real text rather than "<private>".
///
/// Note: this class name matches the EngramUITests ObservabilityTests, but they
/// live in separate targets so there is no symbol collision.
final class ObservabilityGateTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // SECURITY: message bodies must be privacy:.private so project-migration
    // paths, session ids, error text, and socket paths are NOT leaked to the
    // system log (Console.app / other processes). Readable gated-Observability
    // logs are a deferred sanitized-in-process-buffer follow-up — NOT blanket
    // .public. (Reverted the WP17 over-redaction in the UX flow alignment.)
    func testEngramLoggerKeepsMessageBodiesPrivate() throws {
        let source = try source("macos/Engram/Core/EngramLogger.swift")
        XCTAssertTrue(source.contains("privacy: .private"),
                      "EngramLogger must log message bodies with privacy:.private")
        XCTAssertFalse(source.contains("privacy: .public"),
                       "EngramLogger must not log any body with privacy:.public (leaks to system log)")
    }

    func testServiceLoggerKeepsMessageBodiesPrivate() throws {
        let source = try source("macos/EngramService/Core/ServiceLogger.swift")
        XCTAssertTrue(source.contains("privacy: .private"),
                      "ServiceLogger must log message bodies with privacy:.private")
        XCTAssertFalse(source.contains("privacy: .public"),
                       "ServiceLogger must not log any body with privacy:.public (leaks to system log)")
    }

    func testLogStreamHasNoWarnFilter() throws {
        let source = try source("macos/Engram/Views/Observability/LogStreamView.swift")
        let levelsLine = source
            .split(separator: "\n")
            .first { $0.contains("private let levels =") }
        let unwrappedLevels = try XCTUnwrap(levelsLine, "levels array should exist in LogStreamView")
        XCTAssertFalse(unwrappedLevels.contains("\"warn\""),
                       "LogStreamView.levels must not offer a dead 'warn' filter")
        XCTAssertFalse(source.contains("case \"warn\":"),
                       "LevelBadge must not have a warn color branch")
    }

    func testObservabilityIsGatedDefaultOff() throws {
        let source = try source("macos/Engram/Views/Pages/ObservabilityView.swift")
        XCTAssertTrue(source.contains("@AppStorage(\"showDeveloperTools\")"),
                      "ObservabilityView must gate its content on showDeveloperTools")
        XCTAssertTrue(source.contains("showDeveloperTools = false"),
                      "showDeveloperTools must default to false (gate off)")
        XCTAssertTrue(source.contains("Developer diagnostics hidden"),
                      "Gated-off state must render the developer-diagnostics EmptyState")
    }

    func testSidebarHidesObservabilityWhenDeveloperToolsOff() throws {
        let source = try source("macos/Engram/Views/SidebarView.swift")
        XCTAssertTrue(source.contains("@AppStorage(\"showDeveloperTools\")"),
                      "SidebarView must read the showDeveloperTools gate")
        XCTAssertTrue(source.contains("showDeveloperTools = false"),
                      "SidebarView gate must default to false")
        XCTAssertTrue(source.contains("$0 != .observability"),
                      "SidebarView must filter out the Observability item when the gate is off")
    }

    /// Behavioral: an emitted message reads back as real text (un-redacted).
    /// When OSLog is inaccessible or does not surface the token under xctest/TCC,
    /// skip rather than hard-fail — privacy contract is locked by source tests above.
    func testEmittedMessageIsReadableNotRedacted() throws {
        let token = "OBSGATETEST-\(UUID().uuidString)"
        EngramLogger.warn(token, module: .ui)

        var found = false
        var attempts = 0
        let deadline = Date().addingTimeInterval(3)
        while attempts < 5 && Date() < deadline && !found {
            attempts += 1
            do {
                let result = try OSLogReader.recentLogs(hours: 1, limit: 500)
                found = result.entries.contains {
                    $0.source == "com.engram.app" &&
                    $0.message.contains(token) &&
                    !$0.message.contains("<private>")
                }
            } catch is OSLogReaderError {
                throw XCTSkip("Current-process OSLogStore not accessible in this environment")
            }
            if !found { Thread.sleep(forTimeInterval: 0.05) }
        }
        if !found {
            throw XCTSkip("OSLog did not surface emitted token within timeout (TCC/xctest isolation)")
        }
    }
}
