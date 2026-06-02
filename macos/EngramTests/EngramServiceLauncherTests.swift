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

    func testServiceOutputLineBufferWaitsForCompleteJSONLines() throws {
        let buffer = ServiceOutputLineBuffer()

        XCTAssertEqual(buffer.append(Data(#"{"event":"indexed","#.utf8)), [])

        let firstChunk = Data((#""total":2,"todayParents":1}"# + "\n{\"event\":\"warning\"").utf8)
        let first = buffer.append(firstChunk)
        XCTAssertEqual(first.count, 1)
        let indexed = try JSONDecoder().decode(EngramServiceEvent.self, from: Data(first[0].utf8))
        XCTAssertEqual(indexed.event, "indexed")
        XCTAssertEqual(indexed.total, 2)
        XCTAssertEqual(indexed.todayParents, 1)

        let second = buffer.append(Data((#","message":"slow"}"# + "\n").utf8))
        XCTAssertEqual(second.count, 1)
        let warning = try JSONDecoder().decode(EngramServiceEvent.self, from: Data(second[0].utf8))
        XCTAssertEqual(warning.event, "warning")
        XCTAssertEqual(warning.message, "slow")
    }

    func testServiceStdoutDecoderFlushesWhenNewlineArrivesSeparately() {
        let buffer = ServiceOutputLineBuffer()
        let json = #"{"event":"indexed","total":4,"todayParents":2}"#

        XCTAssertEqual(
            EngramServiceLauncher.decodeServiceStdoutEvents(from: Data(json.utf8), lineBuffer: buffer),
            []
        )

        let events = EngramServiceLauncher.decodeServiceStdoutEvents(
            from: Data("\n".utf8),
            lineBuffer: buffer
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "indexed")
        XCTAssertEqual(events[0].total, 4)
        XCTAssertEqual(events[0].todayParents, 2)
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
    func testHealthMonitorKeepsProbingAndRecoversAfterBudgetExhausted() async throws {
        // R5-59: after the restart budget is spent the monitor must NOT stop
        // permanently — it keeps probing (with backoff) so the service can
        // recover without an app relaunch. Probe fails enough times to exhaust
        // the budget, then starts succeeding; we expect a running status after
        // the degraded one.
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: "/tmp/engram-recover-helper",
            socketPath: "/tmp/engram-recover.sock",
            databasePath: "/tmp/engram-recover.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()
        let gate = ProbeFailureGate(failuresBeforeRecovery: 3)

        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                if await gate.shouldFail() {
                    throw EngramServiceError.serviceUnavailable(message: "probe failed")
                }
                return .running(total: 7, todayParents: 1)
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        // Long enough to span the backoff after budget exhaustion and reach a
        // successful probe.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        launcher.stopIfOwned()

        XCTAssertTrue(recorder.statuses.contains { status in
            if case .degraded = status { return true }
            return false
        }, "expected a degraded status after budget exhaustion")
        XCTAssertTrue(recorder.statuses.contains { status in
            if case .running = status { return true }
            return false
        }, "monitor must recover to running after the service comes back")
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

    @MainActor
    func testStopIfOwnedDoesNotBlockMainRunLoopWhileChildStillRunning() async throws {
        // Regression: stopIfOwned() used to poll the child's exit with
        // Thread.sleep on the main actor, blocking the run loop for up to the
        // full 2s timeout. The bounded wait now suspends instead of blocking,
        // so the call must return promptly even while the child is alive.
        let executable = try makeSleeperExecutable()
        let launcher = EngramServiceLauncher()
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-stop.sock",
            databasePath: "/tmp/engram-stop.sqlite",
            foreground: false
        )

        try launcher.start(configuration: config)
        XCTAssertTrue(launcher.isRunning)

        let start = Date()
        launcher.stopIfOwned()
        let elapsed = Date().timeIntervalSince(start)

        // Must be near-instant, well under the 2s exit-wait budget.
        XCTAssertLessThan(elapsed, 0.5)
        // The launcher releases its reference immediately on shutdown.
        XCTAssertFalse(launcher.isRunning)
    }
}

@MainActor
private final class ServiceStatusRecorder {
    private(set) var statuses: [EngramServiceStatus] = []

    func append(_ status: EngramServiceStatus) {
        statuses.append(status)
    }
}

private actor ProbeFailureGate {
    private var remainingFailures: Int

    init(failuresBeforeRecovery: Int) {
        remainingFailures = failuresBeforeRecovery
    }

    func shouldFail() -> Bool {
        guard remainingFailures > 0 else { return false }
        remainingFailures -= 1
        return true
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
