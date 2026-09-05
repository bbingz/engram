import XCTest
import GRDB

private final class TemporaryUITestHomeObserver: NSObject, XCTestObservation {
    static let shared = TemporaryUITestHomeObserver()
    private var homes: [(root: URL, fixtureWriter: DatabaseQueue, defaultsSuite: String)] = []
    private let lock = NSLock()

    func register(_ root: URL, fixtureWriter: DatabaseQueue, defaultsSuite: String) {
        lock.lock()
        homes.append((root, fixtureWriter, defaultsSuite))
        lock.unlock()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        var pending = homes
        homes.removeAll()
        lock.unlock()
        let roots = pending.map(\.root)
        let defaultsSuites = pending.map(\.defaultsSuite)
        // Close the temporary writer before removing its WAL/SHM directory.
        pending.removeAll()
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        for suite in defaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}

enum TestLaunchConfig {
    case mainWindow
    case popover
    case darkMode
    case onboarding

    static var bundledFixtureDBPath: String? {
        let bundle = Bundle(for: BundleAnchor.self)
        return bundle.path(forResource: "test-index", ofType: "sqlite")
            ?? bundle.path(forResource: "test-index", ofType: "sqlite", inDirectory: "test-fixtures")
    }

    /// Fixture DB path — tries env var first, then bundle resources, then project-relative.
    static let fixtureDBPath: String = {
        if let envPath = ProcessInfo.processInfo.environment["FIXTURE_DB_PATH"] {
            return envPath
        }
        if let bundlePath = bundledFixtureDBPath {
            return bundlePath
        }
        return "test-fixtures/test-index.sqlite"
    }()

    private class BundleAnchor {}

    static let localizationArguments = [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
    ]

    func configure(
        _ app: XCUIApplication,
        appLanguage: String = "english",
        localizationArguments: [String] = TestLaunchConfig.localizationArguments
    ) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("engram-ui-home-\(UUID().uuidString)", isDirectory: true)
        let defaultsSuite = "com.engram.app.ui-test.\(UUID().uuidString)"
        // Invariant 6: establish the closed environment and test-mode gate
        // before any fallible fixture setup. XCTFail does not stop a test whose
        // continueAfterFailure remains true, so every early return must still
        // be incapable of launching against production HOME.
        app.launchEnvironment = [
            "HOME": home.path,
            "CFFIXED_USER_HOME": home.path,
            "CFPREFERENCES_AVOID_DAEMON": "1",
            "TMPDIR": home.path,
            "ENGRAM_SETTINGS_PATH": home.appendingPathComponent("missing-settings.json").path,
            "ENGRAM_RUNTIME_AI_SECRETS_PATH": home.appendingPathComponent("missing-ai-secrets.json").path,
            "ENGRAM_EMBEDDING_API_KEY": "",
            "ENGRAM_EMBEDDING_BASE_URL": "",
            "ENGRAM_EMBEDDING_MODEL": "",
            "ENGRAM_EMBEDDING_DIM": "",
            "ENGRAM_EMBEDDING_INCLUDE_DIMENSIONS": "",
            "ENGRAM_DIR": home.appendingPathComponent(".engram", isDirectory: true).path,
            "ENGRAM_UI_TEST_DEFAULTS_SUITE": defaultsSuite,
        ]
        app.launchArguments += [
            "--test-mode",
        ]
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            XCTFail("Could not create hermetic UI-test home: \(error)")
            return
        }
        let fixtureURL = home.appendingPathComponent("test-index.sqlite")
        let fixtureSessionsURL = home.appendingPathComponent("sessions", isDirectory: true)
        do {
            let sourceFixtureURL = URL(fileURLWithPath: Self.fixtureDBPath)
            try FileManager.default.copyItem(
                at: sourceFixtureURL,
                to: fixtureURL
            )
            try FileManager.default.copyItem(
                at: sourceFixtureURL.deletingLastPathComponent()
                    .appendingPathComponent("sessions", isDirectory: true),
                to: fixtureSessionsURL
            )
            let fixtureWriter = try DatabaseQueue(path: fixtureURL.path)
            try fixtureWriter.writeWithoutTransaction { db in
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
                XCTAssertEqual(mode?.lowercased(), "wal", "UI fixture must use WAL mode")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
                try db.execute(sql: "CREATE TABLE ui_fixture_keepalive (value INTEGER NOT NULL)")
            }
            TemporaryUITestHomeObserver.shared.register(
                home,
                fixtureWriter: fixtureWriter,
                defaultsSuite: defaultsSuite
            )
        } catch {
            XCTFail("Could not prepare hermetic UI-test fixture: \(error)")
            return
        }
        app.launchArguments += [
            "--fixture-db", fixtureURL.path,
            "--mock-daemon",
            "--fixed-date", "2026-01-15T10:00:00Z",
            // LocalizedRoot follows the app-owned preference, so pin its
            // argument-domain value as well as Apple's process locale.
            "-appLanguage", appLanguage,
            // Observability is gated behind the `showDeveloperTools` setting,
            // which defaults OFF for real users (SidebarView filters it out).
            // The navigation/observability UI tests still traverse that page, so
            // enable the gate through the NSUserDefaults argument domain — the
            // same `-key value` mechanism as `localizationArguments` below.
            "-showDeveloperTools", "YES",
        ] + localizationArguments

        switch self {
        case .mainWindow:
            app.launchArguments += ["--window-size", "1024x681", "--appearance", "light"]
        case .popover:
            app.launchArguments += ["--popover-standalone"]
        case .darkMode:
            app.launchArguments += ["--window-size", "1024x681", "--appearance", "dark"]
        case .onboarding:
            app.launchArguments += ["--show-onboarding", "--appearance", "light"]
        }
    }
}
