import Darwin
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

    @MainActor
    func testHealthMonitorRestartsThenMarksDegradedAfterBudget() async throws {
        let executable = try makeSleeperExecutable()
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-health.sock",
            databasePath: "/tmp/engram-health.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                throw EngramServiceError.serviceUnavailable(message: "probe failed")
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        try await Task.sleep(nanoseconds: 80_000_000)
        launcher.stopIfOwned()

        XCTAssertTrue(recorder.statuses.contains(.starting))
        XCTAssertTrue(recorder.statuses.contains { status in
            if case .degraded(let message) = status {
                return message.contains("after 1 restart attempts")
            }
            return false
        })
    }

    @MainActor
    func testLauncherDrainsServiceOutputPipes() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-output-\(UUID().uuidString)")
        let executable = try makeNoisyExecutable(marker: marker)
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-output.sock",
            databasePath: "/tmp/engram-output.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        launcher.stopIfOwned()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

@MainActor
private final class ServiceStatusRecorder {
    private(set) var statuses: [EngramServiceStatus] = []

    func append(_ status: EngramServiceStatus) {
        statuses.append(status)
    }
}

private func makeSleeperExecutable() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-launcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("sleeper.sh")
    try "#!/bin/sh\nsleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}

private func makeNoisyExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-noisy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("noisy.sh")
    try """
    #!/bin/sh
    i=0
    while [ "$i" -lt 5000 ]; do
      printf '%0200d\\n' "$i"
      i=$((i + 1))
    done
    touch "\(marker.path)"
    sleep 5
    """.write(to: executable, atomically: true, encoding: .utf8)
    chmod(executable.path, 0o700)
    return executable
}
