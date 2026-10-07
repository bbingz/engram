import Darwin
import Foundation
import XCTest
@testable import EngramCollectorCore

/// P3 install tooling (docs/superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md §4.1):
/// the document rendered by scripts/render-collector-settings.mjs must pass the
/// collector settings parser. The committed fixture uses the placeholder home
/// /Users/example; the test rebinds it to a private temporary base.
final class CollectorRenderedSettingsFixtureTests: XCTestCase {
    func testRenderedSettingsFixtureIsAcceptedByCollectorSettingsParser() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = checkout.appendingPathComponent("tests/fixtures/collector-install/rendered-settings.json")
        let base = checkout.appendingPathComponent(".engram-rendered-settings-test-\(UUID().uuidString)")
        let state = base.appendingPathComponent(".engram-collector")
        for directory in [base, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let rendered = try String(contentsOf: fixture, encoding: .utf8)
        XCTAssertTrue(rendered.contains("\"/Users/example/"), "fixture must be rendered against the placeholder home")
        let document = rendered.replacingOccurrences(of: "/Users/example/", with: base.path + "/")
        let settings = base.appendingPathComponent("settings.json")
        try Data(document.utf8).write(to: settings)
        guard chmod(settings.path, 0o600) == 0 else { return XCTFail("settings fixture must be owner-only") }

        // The planner's --initialize-identity step precedes --initialize on a new host.
        let catalog = state.appendingPathComponent("identity/archive.sqlite")
        _ = try CollectorIdentityInitializer.create(at: catalog)

        // initialize loads the document through CollectorRuntimeConfiguration.load
        // and only then creates the spool; an invalid document throws first.
        XCTAssertNoThrow(try CollectorRuntime.initialize(settingsURL: settings))
        let spool = state.appendingPathComponent("spool/capture/archive.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.path), "accepted settings must yield an initialized spool")
    }
}
