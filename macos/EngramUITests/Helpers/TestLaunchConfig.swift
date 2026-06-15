import XCTest

enum TestLaunchConfig {
    case mainWindow
    case popover
    case darkMode

    /// Fixture DB path — tries bundle resources first, then env var, then project-relative
    static let fixtureDBPath: String = {
        if let envPath = ProcessInfo.processInfo.environment["FIXTURE_DB_PATH"] {
            return envPath
        }
        let bundle = Bundle(for: BundleAnchor.self)
        if let bundlePath = bundle.path(forResource: "test-index", ofType: "sqlite", inDirectory: "test-fixtures") {
            return bundlePath
        }
        return "test-fixtures/test-index.sqlite"
    }()

    private class BundleAnchor {}

    static let localizationArguments = [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
    ]

    func configure(_ app: XCUIApplication) {
        app.launchArguments += [
            "--test-mode",
            "--fixture-db", Self.fixtureDBPath,
            "--mock-daemon",
            "--fixed-date", "2026-01-15T10:00:00Z",
            // Observability is gated behind the `showDeveloperTools` setting,
            // which defaults OFF for real users (SidebarView filters it out).
            // The navigation/observability UI tests still traverse that page, so
            // enable the gate through the NSUserDefaults argument domain — the
            // same `-key value` mechanism as `localizationArguments` below.
            "-showDeveloperTools", "YES",
        ] + Self.localizationArguments

        switch self {
        case .mainWindow:
            app.launchArguments += ["--window-size", "1024x681", "--appearance", "light"]
        case .popover:
            app.launchArguments += ["--popover-standalone"]
        case .darkMode:
            app.launchArguments += ["--window-size", "1024x681", "--appearance", "dark"]
        }
    }
}
