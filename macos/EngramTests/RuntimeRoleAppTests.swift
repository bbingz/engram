import AppKit
import Darwin
import XCTest
@testable import Engram

final class RuntimeRoleAppTests: XCTestCase {
    private var root: URL!
    private var settings: URL { root.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-role-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testSettingsIOAndRoleResolutionShareExactPathPriority() {
        for environment in [
            ["ENGRAM_SETTINGS_PATH": settings.path, "CFFIXED_USER_HOME": root.path, "HOME": "/ignored"],
            ["ENGRAM_SETTINGS_PATH": "", "CFFIXED_USER_HOME": root.path, "HOME": "/ignored"],
            ["HOME": root.path],
            ["XCTestConfigurationFilePath": "/test/config", "HOME": "/must-not-be-used"],
            [:],
        ] {
            XCTAssertEqual(RuntimeRoleSettings.settingsURL(environment: environment), resolveEngramSettingsURL(environment: environment))
        }
        let testURL = RuntimeRoleSettings.settingsURL(environment: [:])
        XCTAssertTrue(testURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testSpotlightStyleLaunchReadsPersistedRoleBeforeStartup_repro() throws {
        for (value, role) in [("collector", EngramRuntimeRole.collector), ("replica", .replica), ("index", .index)] {
            try write("{\"runtimeRole\":\"\(value)\"}")
            let environment = makeEnvironment()
            XCTAssertEqual(environment.runtimeRole, role)
            XCTAssertEqual(environment.autoStartService, role == .index)
            XCTAssertEqual(environment.serviceLaunchConfiguration().runtimeRole, role)
            XCTAssertFalse(environment.isTestMode)
        }
    }

    func testDataDirectoryOverrideCannotBypassPersistedCollectorRole_repro() throws {
        try write(#"{"runtimeRole":"collector"}"#)
        let environment = makeEnvironment(arguments: ["Engram", "--data-dir", root.appendingPathComponent("other").path])
        XCTAssertEqual(environment.runtimeRole, .collector)
        XCTAssertFalse(environment.autoStartService)
        XCTAssertEqual(environment.serviceLaunchConfiguration().runtimeRole, .collector)
    }

    func testInvalidRoleFailsClosedInsteadOfSelectingLocal_repro() throws {
        for document in [#"{"runtimeRole":null}"#, "not-json"] {
            try write(document)
            let environment = makeEnvironment()
            XCTAssertEqual(environment.runtimeRole, .invalidSettings)
            XCTAssertFalse(environment.autoStartService)
            XCTAssertFalse(environment.networkEnabled)
            XCTAssertEqual(environment.serviceLaunchConfiguration().runtimeRole, .invalidSettings)
        }
    }

    func testExplicitFixtureModeRemainsLocalAndDoesNotReadHostSettings() throws {
        try write(#"{"runtimeRole":"replica"}"#)
        let fixture = root.appendingPathComponent("fixture.sqlite").path
        let environment = makeEnvironment(arguments: ["Engram", "--test-mode", "--fixture-db", fixture])
        XCTAssertEqual(environment.runtimeRole, .local)
        XCTAssertEqual(environment.dbPath, fixture)
        XCTAssertTrue(environment.isTestMode)
        XCTAssertFalse(environment.autoStartService)
        let host = AppEnvironment.fromCommandLine(arguments: ["Engram"], environment: [
            "XCTestConfigurationFilePath": "/test/config", "ENGRAM_SETTINGS_PATH": settings.path,
        ])
        XCTAssertEqual(host.runtimeRole, .local)
        XCTAssertEqual(host.dbPath, "")
    }

    @MainActor
    func testBlockedRolesCannotAutomaticallyMigrateSettingsOrKeychain_repro() {
        for role in [EngramRuntimeRole.collector, .replica, .invalidSettings] {
            var environment = makeEnvironment()
            environment.runtimeRole = role
            let delegate = AppDelegate(environment: environment)
            var migrations = 0
            delegate.performAutomaticSettingsMigrations(
                migrateKeys: { migrations += 1 }, removeDeprecated: { migrations += 1 }
            )
            XCTAssertEqual(migrations, 0, "\(role)")
        }
    }

    @MainActor
    func testLocalMigrationAndFixtureIsolationRemainCompatible() {
        let delegate = AppDelegate(environment: makeEnvironment())
        var migrations = 0
        delegate.performAutomaticSettingsMigrations(
            migrateKeys: { migrations += 1 }, removeDeprecated: { migrations += 1 }
        )
        XCTAssertEqual(migrations, 2)
        AppDelegate(environment: .test(fixturePath: "")).performAutomaticSettingsMigrations(
            migrateKeys: { migrations += 1 }, removeDeprecated: { migrations += 1 }
        )
        XCTAssertEqual(migrations, 2)
    }

    @MainActor
    func testTerminatedIndexAppCannotRestartOrPublishLateStatus_repro() async throws {
        var environment = makeEnvironment()
        environment.runtimeRole = .index
        let delegate = AppDelegate(environment: environment)
        let notification = Notification(name: NSApplication.willTerminateNotification)
        delegate.applicationWillTerminate(notification)
        let statusAtQuit = delegate.serviceStatusStore.status
        delegate.restartService()
        XCTAssertEqual(delegate.serviceStatusStore.status, statusAtQuit)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(delegate.serviceStatusStore.status, statusAtQuit)
        delegate.applicationWillTerminate(notification)

        let queuedDelegate = AppDelegate(environment: environment)
        queuedDelegate.restartService()
        queuedDelegate.applicationWillTerminate(notification)
        let queuedStatusAtQuit = queuedDelegate.serviceStatusStore.status
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queuedDelegate.serviceStatusStore.status, queuedStatusAtQuit)
        queuedDelegate.applicationWillTerminate(notification)
    }

    func testUnavailableAppEntryPointsGuardBeforeLocalViewsAndRestart_repro() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Engram/App.swift"), encoding: .utf8
        )
        XCTAssertTrue(source.contains("if appDelegate.environment.runtimeRole.allowsLocalIndex"), "Settings must not construct local DB or credential views on blocked hosts")
        for name in ["func applicationDidFinishLaunching", "func applicationShouldHandleReopen", "func restartService", "private func showOnboarding"] {
            let start = try XCTUnwrap(source.range(of: name))
            let body = source[start.lowerBound...].prefix(500)
            XCTAssertTrue(body.contains("guard environment.runtimeRole.allowsLocalIndex"), name)
        }
    }

    private func makeEnvironment(arguments: [String] = ["Engram"]) -> AppEnvironment {
        AppEnvironment.fromCommandLine(arguments: arguments, environment: [
            "ENGRAM_SETTINGS_PATH": settings.path,
            "CFFIXED_USER_HOME": root.path,
            "HOME": root.path,
        ])
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: settings)
        XCTAssertEqual(chmod(settings.path, 0o600), 0)
    }
}
