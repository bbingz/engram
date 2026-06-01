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

    /// OBS-O2: callback invoked for each structured event the service prints to
    /// stdout (e.g. `index_error`). The status poll channel can only ever report
    /// `.running`, so indexing failures are otherwise invisible to the app. The
    /// launcher already drains stdout; here it parses the JSON line and forwards
    /// the decoded event so `App.swift` can reflect it in the status store.
    typealias EventSink = @MainActor @Sendable (EngramServiceEvent) -> Void

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var healthTask: Task<Void, Never>?
    private let healthIntervalNanoseconds: UInt64
    private let maximumRestartAttempts: Int
    private var onEvent: EventSink?

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

    func start(configuration: EngramServiceLaunchConfiguration, onEvent: EventSink? = nil) throws {
        if let onEvent { self.onEvent = onEvent }
        guard process?.isRunning != true else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: configuration.executablePath)
        proc.arguments = Self.arguments(for: configuration)
        var environment = ProcessInfo.processInfo.environment
        for key in ["aiApiKey", "titleApiKey"] {
            if let value = KeychainHelper.get(key), !value.isEmpty {
                environment["ENGRAM_KEYCHAIN_\(key)"] = value
            }
        }
        proc.environment = environment
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
        // [weak self] is intentional: `self` retains `healthTask`, so a strong
        // capture would create a retain cycle that keeps the launcher (and its
        // child process) alive past app teardown. The launcher is owned by the
        // app for its whole lifetime, so the only time `self` deallocs is when
        // the app is going away — at which point stopping the monitor is the
        // correct behavior.
        healthTask = Task { [weak self] in
            var restartAttempts = 0
            while !Task.isCancelled {
                // Exponential backoff once restarts start failing: probing/
                // restarting a wedged service every `interval` adds load without
                // helping. Backoff is capped so recovery latency stays bounded
                // and we keep probing forever (the service may come back), rather
                // than giving up permanently after the restart budget.
                let backoffMultiplier = UInt64(1) << UInt64(min(restartAttempts, 5))
                let sleepInterval = interval &* backoffMultiplier
                do {
                    try await Task.sleep(nanoseconds: sleepInterval)
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
                        // Budget exhausted: surface degraded status but keep the
                        // monitor alive (with backoff) so the service can recover
                        // without requiring an app relaunch.
                        restartAttempts += 1
                        await MainActor.run {
                            onStatus(.degraded(message: "EngramService health check failed after \(maxRestarts) restart attempts: \(message)"))
                        }
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
        if let process, process.isRunning {
            process.terminate()
            // Bounded wait so the old helper has actually released the
            // single-writer lock + socket before a restart spawns a new one;
            // otherwise the new process loses the lock race and exits. SIGTERM
            // on our own short-lived helper is honored quickly; cap the wait so
            // a wedged process can't block the main actor indefinitely.
            Self.waitForExit(process, timeout: 2.0)
        }
        process = nil
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            // Poll rather than blocking waitUntilExit(): a hung helper would
            // otherwise wedge the @MainActor caller forever.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func drain(pipe: Pipe, level: String) {
        let lineBuffer = ServiceOutputLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if level == "stderr" {
                if let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty {
                    EngramLogger.error("EngramService stderr: \(text)", module: .daemon)
                }
            } else {
                if let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty {
                    EngramLogger.debug("EngramService stdout: \(text)", module: .daemon)
                }
                // OBS-O2: parse structured events (one JSON object per line) and
                // forward them so indexing failures surface in the status store.
                for event in Self.decodeServiceStdoutEvents(from: data, lineBuffer: lineBuffer) {
                    Task { @MainActor [weak self] in
                        self?.onEvent?(event)
                    }
                }
            }
        }
    }

    nonisolated static func decodeServiceStdoutEvents(
        from data: Data,
        lineBuffer: ServiceOutputLineBuffer
    ) -> [EngramServiceEvent] {
        lineBuffer.append(data).compactMap { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.first == "{" else { return nil }
            do {
                return try JSONDecoder().decode(EngramServiceEvent.self, from: Data(trimmedLine.utf8))
            } catch {
                EngramLogger.error("EngramService stdout JSON decode failed: \(error); line=\(trimmedLine)", module: .daemon)
                return nil
            }
        }
    }
}

final class ServiceOutputLineBuffer {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !lineData.isEmpty else { continue }
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" {
                line.removeLast()
            }
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
