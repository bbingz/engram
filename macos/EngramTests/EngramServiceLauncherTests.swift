import XCTest
@testable import Engram

final class EngramServiceLauncherTests: XCTestCase {
    func testProductionEnvironmentStartsServiceHelperWithoutNodeDaemonArguments() {
        let environment = AppEnvironment.production

        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertTrue(environment.autoStartService)
        XCTAssertEqual(
            environment.serviceSocketPath,
            UnixSocketEngramServiceTransport.defaultSocketPath()
        )

        let configuration = environment.serviceLaunchConfiguration(bundle: .main)
        let arguments = EngramServiceLauncher.arguments(for: configuration)

        XCTAssertTrue(configuration.executablePath.hasSuffix("EngramService"))
        XCTAssertEqual(configuration.socketPath, environment.serviceSocketPath)
        XCTAssertEqual(configuration.databasePath, environment.dbPath)
        XCTAssertFalse(configuration.foreground)
        XCTAssertFalse(arguments.contains { argument in
            argument.contains("node")
                || argument.contains("daemon.js")
                || argument.contains("EngramMCP")
                || argument.contains("MCPServer")
        })
    }

    func testDataDirEnvironmentKeepsProductionServiceStartupWithoutNodeDaemon() {
        let environment = AppEnvironment.fromCommandLine(
            arguments: ["Engram", "--data-dir", "/tmp/engram-data"],
            environment: [:]
        )

        XCTAssertEqual(environment.dbPath, "/tmp/engram-data/index.sqlite")
        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertTrue(environment.autoStartService)
        XCTAssertEqual(
            environment.serviceSocketPath,
            AppEnvironment.production.serviceSocketPath
        )
    }

    func testTestEnvironmentDoesNotStartAnyOwnedRuntimeProcess() {
        let environment = AppEnvironment.test(fixturePath: "/tmp/test.sqlite")

        XCTAssertFalse(environment.autoStartDaemon)
        XCTAssertFalse(environment.autoStartService)
    }

    func testBuildArgumentsContainServiceSocketAndDatabasePathOnly() {
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/EngramService",
            socketPath: "/tmp/engram.sock",
            databasePath: "/tmp/index.sqlite",
            foreground: true
        )

        let arguments = EngramServiceLauncher.arguments(for: config)

        XCTAssertEqual(arguments, [
            "--service-socket", "/tmp/engram.sock",
            "--database-path", "/tmp/index.sqlite",
            "--foreground"
        ])
        XCTAssertFalse(arguments.contains { $0.contains("node") || $0.contains("daemon.js") })
    }

    func testDefaultConfigurationUsesEngramRunSocketAndServiceHelperName() {
        let home = URL(fileURLWithPath: "/tmp/engram-home", isDirectory: true)
        let config = EngramServiceLaunchConfiguration.default(
            homeDirectory: home,
            databasePath: "/tmp/custom.sqlite",
            bundle: .main
        )

        XCTAssertTrue(config.executablePath.hasSuffix("EngramService"))
        XCTAssertEqual(config.socketPath, "/tmp/engram-home/.engram/run/engram-service.sock")
        XCTAssertEqual(config.databasePath, "/tmp/custom.sqlite")
    }
}
