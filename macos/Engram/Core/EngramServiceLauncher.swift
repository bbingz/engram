import Foundation

struct EngramServiceLaunchConfiguration: Equatable {
    let executablePath: String
    let socketPath: String
    let databasePath: String
    let foreground: Bool

    static func `default`(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        databasePath: String,
        bundle: Bundle = .main
    ) -> EngramServiceLaunchConfiguration {
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("EngramService")
        let socketPath = UnixSocketEngramServiceTransport.defaultSocketPath(homeDirectory: homeDirectory)
        return EngramServiceLaunchConfiguration(
            executablePath: helperURL.path,
            socketPath: socketPath,
            databasePath: databasePath,
            foreground: false
        )
    }
}

@MainActor
final class EngramServiceLauncher {
    typealias StatusProbe = @Sendable () async throws -> EngramServiceStatus
    typealias StatusSink = @MainActor @Sendable (EngramServiceStatus) -> Void

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var healthTask: Task<Void, Never>?
    private let healthIntervalNanoseconds: UInt64
    private let maximumRestartAttempts: Int

    init(
        healthIntervalNanoseconds: UInt64 = 5_000_000_000,
        maximumRestartAttempts: Int = 3
    ) {
        self.healthIntervalNanoseconds = healthIntervalNanoseconds
        self.maximumRestartAttempts = maximumRestartAttempts
    }

    nonisolated static func arguments(for configuration: EngramServiceLaunchConfiguration) -> [String] {
        var arguments = [
            "--service-socket", configuration.socketPath,
            "--database-path", configuration.databasePath
        ]
        if configuration.foreground {
            arguments.append("--foreground")
        }
        return arguments
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start(configuration: EngramServiceLaunchConfiguration) throws {
        guard process?.isRunning != true else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: configuration.executablePath)
        proc.arguments = Self.arguments(for: configuration)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        drain(pipe: stdoutPipe, level: "stdout")
        drain(pipe: stderrPipe, level: "stderr")
        try proc.run()
        process = proc
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func startHealthMonitor(
        configuration: EngramServiceLaunchConfiguration,
        statusProbe: @escaping StatusProbe,
        onStatus: @escaping StatusSink
    ) {
        healthTask?.cancel()
        let interval = healthIntervalNanoseconds
        let maxRestarts = maximumRestartAttempts
        healthTask = Task { [weak self] in
            var restartAttempts = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }

                do {
                    let status = try await statusProbe()
                    await MainActor.run {
                        onStatus(status)
                    }
                    restartAttempts = 0
                } catch is CancellationError {
                    return
                } catch {
                    let message = error.localizedDescription
                    if restartAttempts < maxRestarts {
                        restartAttempts += 1
                        await MainActor.run {
                            guard let self else { return }
                            self.stopProcessOnly()
                            do {
                                try self.start(configuration: configuration)
                                onStatus(.starting)
                            } catch {
                                onStatus(.degraded(message: "EngramService restart failed: \(error.localizedDescription)"))
                            }
                        }
                    } else {
                        await MainActor.run {
                            onStatus(.degraded(message: "EngramService health check failed after \(maxRestarts) restart attempts: \(message)"))
                        }
                        return
                    }
                }
            }
        }
    }

    func stopIfOwned() {
        healthTask?.cancel()
        healthTask = nil
        stopProcessOnly()
    }

    private func stopProcessOnly() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        process?.terminate()
        process = nil
    }

    private func drain(pipe: Pipe, level: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { return }
            if level == "stderr" {
                EngramLogger.error("EngramService stderr: \(text)", module: .daemon)
            } else {
                EngramLogger.debug("EngramService stdout: \(text)", module: .daemon)
            }
        }
    }
}
