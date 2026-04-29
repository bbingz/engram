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
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePath = repoRoot.appendingPathComponent("test-fixtures/test-index.sqlite").path
        if FileManager.default.fileExists(atPath: sourcePath) {
            return sourcePath
        }
        return "test-fixtures/test-index.sqlite"
    }()

    private class BundleAnchor {}

    func configure(_ app: XCUIApplication) {
        app.launchArguments += [
            "--test-mode",
            "--fixture-db", Self.fixtureDBPath,
            "--mock-daemon",
            "--fixed-date", "2026-01-15T10:00:00Z",
        ]

        switch self {
        case .mainWindow:
            app.launchArguments += ["--window-size", "1280x800"]
        case .popover:
            app.launchArguments += ["--popover-standalone"]
        case .darkMode:
            app.launchArguments += ["--window-size", "1280x800", "--appearance", "dark"]
        }
    }
}
