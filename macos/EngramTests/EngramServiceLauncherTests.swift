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

    func testLaunchEnvironmentBridgesKeychainSecretsThroughRuntimeFileOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-service-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secretsPath = root.appendingPathComponent("ai-secrets.json").path

        let environment = EngramServiceLauncher.environment(
            baseEnvironment: [
                "PATH": "/usr/bin",
                "ENGRAM_KEYCHAIN_aiApiKey": "inherited-summary-secret",
                "ENGRAM_KEYCHAIN_titleApiKey": "inherited-title-secret"
            ],
            runtimeAISecretsPath: secretsPath,
            keychainReader: { account in
                switch account {
                case "aiApiKey": return "summary-secret"
                case "titleApiKey": return "title-secret"
                default: return nil
                }
            }
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertNil(environment["ENGRAM_KEYCHAIN_aiApiKey"])
        XCTAssertNil(environment["ENGRAM_KEYCHAIN_titleApiKey"])
        XCTAssertFalse(environment.values.contains("inherited-summary-secret"))
        XCTAssertFalse(environment.values.contains("inherited-title-secret"))
        XCTAssertFalse(environment.values.contains("summary-secret"))
        XCTAssertFalse(environment.values.contains("title-secret"))
        XCTAssertEqual(environment["ENGRAM_RUNTIME_AI_SECRETS_PATH"], secretsPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: secretsPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["aiApiKey"], "summary-secret")
        XCTAssertEqual(object["titleApiKey"], "title-secret")
        let attrs = try FileManager.default.attributesOfItem(atPath: secretsPath)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
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
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
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
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 0
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

        let sawDegraded = await recorder.waitUntil(timeoutNanoseconds: 2_000_000_000) { statuses in
            statuses.contains { status in
                if case .degraded = status { return true }
                return false
            }
        }
        let recovered = await recorder.waitUntil(timeoutNanoseconds: 2_000_000_000) { statuses in
            statuses.contains { status in
                if case .running = status { return true }
                return false
            }
        }
        launcher.stopIfOwned()

        XCTAssertTrue(sawDegraded, "expected a degraded status after budget exhaustion")
        XCTAssertTrue(recovered, "monitor must recover to running after the service comes back")
    }

    @MainActor
    func testHealthMonitorDoesNotRestartDuringStartupGrace() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-startup-grace-\(UUID().uuidString)")
        let executable = try makeCountingSleeperExecutable(marker: marker)
        let launcher = EngramServiceLauncher(
            healthIntervalNanoseconds: 5_000_000,
            maximumRestartAttempts: 1,
            startupGraceNanoseconds: 250_000_000
        )
        let config = EngramServiceLaunchConfiguration(
            executablePath: executable.path,
            socketPath: "/tmp/engram-startup-grace.sock",
            databasePath: "/tmp/engram-startup-grace.sqlite",
            foreground: false
        )
        let recorder = ServiceStatusRecorder()

        try launcher.start(configuration: config)
        let markerWritten = await waitForFile(at: marker, timeoutNanoseconds: 500_000_000)
        XCTAssertTrue(markerWritten, "test helper should record its initial launch before health probing starts")
        launcher.startHealthMonitor(
            configuration: config,
            statusProbe: {
                throw EngramServiceError.serviceUnavailable(message: "socket not ready")
            },
            onStatus: { status in
                recorder.append(status)
            }
        )

        let sawStarting = await recorder.waitUntil(timeoutNanoseconds: 120_000_000) { statuses in
            statuses.contains(.starting)
        }
        launcher.stopIfOwned()

        let launches = (try? String(contentsOf: marker, encoding: .utf8))?
            .split(separator: "\n")
            .count ?? 0
        XCTAssertTrue(sawStarting, "startup probe failures should keep reporting starting during grace")
        XCTAssertEqual(launches, 1, "startup probe failures must not restart a legitimately slow service")
        XCTAssertFalse(recorder.statuses.contains { status in
            if case .degraded = status { return true }
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

    func waitUntil(
        timeoutNanoseconds: UInt64,
        predicate: ([EngramServiceStatus]) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if predicate(statuses) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate(statuses)
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

private func waitForFile(at url: URL, timeoutNanoseconds: UInt64) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return FileManager.default.fileExists(atPath: url.path)
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

private func makeCountingSleeperExecutable(marker: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-service-counting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    let executable = directory.appendingPathComponent("counting-sleeper.sh")
    try """
    #!/bin/sh
    printf 'start\\n' >> "\(marker.path)"
    sleep 5
    """.write(to: executable, atomically: true, encoding: .utf8)
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
