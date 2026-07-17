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
    nonisolated private static let runtimeAISecretsEnvironmentKey = "ENGRAM_RUNTIME_AI_SECRETS_PATH"

    typealias StatusProbe = @Sendable () async throws -> EngramServiceStatus
    typealias StatusSink = @MainActor @Sendable (EngramServiceStatus) -> Void

    /// OBS-O2: callback invoked for each structured event the service prints to
    /// stdout (e.g. `index_error`). The status poll channel can only ever report
    /// `.running`, so indexing failures are otherwise invisible to the app. The
    /// launcher already drains stdout; here it parses the JSON line and forwards
    /// the decoded event so `App.swift` can reflect it in the status store.
    typealias EventSink = @MainActor @Sendable (EngramServiceEvent) -> Void

    private var process: Process?
    /// Socket path of the currently launched helper — used to scrub
    /// `ai-secrets.json` on stop (SEC-H2).
    private var processSocketPath: String?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var healthTask: Task<Void, Never>?
    private let healthIntervalNanoseconds: UInt64
    private let startupGraceNanoseconds: UInt64
    private let maximumRestartAttempts: Int
    private var onEvent: EventSink?

    init(
        healthIntervalNanoseconds: UInt64 = 5_000_000_000,
        maximumRestartAttempts: Int = 3,
        startupGraceNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.healthIntervalNanoseconds = healthIntervalNanoseconds
        self.startupGraceNanoseconds = startupGraceNanoseconds
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

    nonisolated static func environment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runtimeAISecretsPath: String? = nil,
        keychainReader: (String) -> String? = { _ in nil }
    ) -> [String: String] {
        var environment = baseEnvironment.filter { key, _ in
            !key.hasPrefix("ENGRAM_KEYCHAIN_") && key != runtimeAISecretsEnvironmentKey
        }
        if let runtimeAISecretsPath,
           writeRuntimeAISecrets(toPath: runtimeAISecretsPath, keychainReader: keychainReader) {
            environment[runtimeAISecretsEnvironmentKey] = runtimeAISecretsPath
        }
        return environment
    }

    nonisolated static func runtimeAISecretsPath(forSocketPath socketPath: String) -> String {
        URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ai-secrets.json")
            .path
    }

    @discardableResult
    nonisolated static func writeRuntimeAISecrets(
        toPath path: String,
        keychainReader: (String) -> String?
    ) -> Bool {
        var secrets: [String: String] = [:]
        for account in ["aiApiKey", "titleApiKey", "embeddingApiKey"] {
            if let value = keychainReader(account), !value.isEmpty {
                secrets[account] = value
            }
        }

        let fileManager = FileManager.default
        if secrets.isEmpty {
            try? fileManager.removeItem(atPath: path)
            return false
        }

        let url = URL(fileURLWithPath: path)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
            guard fileManager.createFile(
                atPath: path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// SEC-H2: remove the plaintext Keychain bridge file. Prefer overwrite-then-
    /// unlink so residual secret bytes are not left on a reusable temp name.
    nonisolated static func removeRuntimeAISecrets(atPath path: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            let zeros = Data(repeating: 0, count: min(size.intValue, 64 * 1024))
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: zeros)
                try? handle.truncate(atOffset: UInt64(zeros.count))
                try? handle.synchronize()
            }
        }
        try? fileManager.removeItem(atPath: path)
    }

    /// SEC-H2: scrub secrets next to the service socket (production bridge path).
    nonisolated func scrubRuntimeAISecrets(forSocketPath socketPath: String) {
        Self.removeRuntimeAISecrets(atPath: Self.runtimeAISecretsPath(forSocketPath: socketPath))
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
        proc.environment = Self.environment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            runtimeAISecretsPath: Self.runtimeAISecretsPath(forSocketPath: configuration.socketPath),
            keychainReader: KeychainHelper.get
        )
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        drain(pipe: stdoutPipe, level: "stdout")
        drain(pipe: stderrPipe, level: "stderr")
        try proc.run()
        process = proc
        processSocketPath = configuration.socketPath
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
        let startupGrace = startupGraceNanoseconds
        // [weak self] is intentional: `self` retains `healthTask`, so a strong
        // capture would create a retain cycle that keeps the launcher (and its
        // child process) alive past app teardown. The launcher is owned by the
        // app for its whole lifetime, so the only time `self` deallocs is when
        // the app is going away — at which point stopping the monitor is the
        // correct behavior.
        healthTask = Task { [weak self] in
            var restartAttempts = 0
            var startupGraceDeadline = Self.startupGraceDeadline(after: startupGrace)
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
                    startupGraceDeadline = nil
                } catch is CancellationError {
                    return
                } catch {
                    let message = error.localizedDescription
                    if Self.isWithinStartupGrace(startupGraceDeadline) {
                        await MainActor.run {
                            onStatus(.starting)
                        }
                        continue
                    }
                    if restartAttempts < maxRestarts {
                        restartAttempts += 1
                        guard let self else { return }
                        // Await the bounded shutdown so the old helper releases
                        // its single-writer lock + socket before the new process
                        // spawns. The wait suspends (Task.sleep) instead of
                        // blocking, so the main run loop stays responsive.
                        await self.stopProcessOnly()
                        await MainActor.run {
                            do {
                                try self.start(configuration: configuration)
                                onStatus(.starting)
                                startupGraceDeadline = Self.startupGraceDeadline(after: startupGrace)
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

    /// Single restart sequencing point: stop the running helper (releasing its
    /// single-writer lock + socket), spawn a fresh process, and re-arm the
    /// health monitor with a fresh startup grace. Reuses the existing
    /// stopProcessOnly/start/startHealthMonitor primitives — no new process
    /// logic. Surfaces `.starting` then `.running` on success, or `.error` if
    /// `start()` throws (e.g. helper binary missing).
    func restart(
        configuration: EngramServiceLaunchConfiguration,
        statusProbe: @escaping StatusProbe,
        onStatus: @escaping StatusSink,
        onEvent: EventSink? = nil
    ) async {
        await stopProcessOnly()
        do {
            try start(configuration: configuration, onEvent: onEvent)
            onStatus(.starting)
            startHealthMonitor(
                configuration: configuration,
                statusProbe: statusProbe,
                onStatus: onStatus
            )
        } catch {
            onStatus(.error(message: error.localizedDescription))
        }
    }

    nonisolated private static func startupGraceDeadline(after nanoseconds: UInt64) -> ContinuousClock.Instant? {
        guard nanoseconds > 0 else { return nil }
        return ContinuousClock.now + .nanoseconds(Int(nanoseconds))
    }

    nonisolated private static func isWithinStartupGrace(_ deadline: ContinuousClock.Instant?) -> Bool {
        guard let deadline else { return false }
        return ContinuousClock.now < deadline
    }

    func stopIfOwned() {
        healthTask?.cancel()
        healthTask = nil
        // SEC-H2: drop the plaintext AI secrets bridge as soon as we intend to
        // stop the helper. Token file cleanup is owned by the service process;
        // the bridge file is owned by the app launcher.
        if let socketPath = processSocketPath {
            scrubRuntimeAISecrets(forSocketPath: socketPath)
        }
        // Send SIGTERM synchronously, but never block the main run loop waiting
        // for exit. On quit we don't need the lock-release ordering a restart
        // needs, so the bounded wait runs as a fire-and-forget task whose
        // suspension points keep the run loop free.
        guard let terminating = terminateProcess() else { return }
        Task { await Self.waitForExit(terminating, timeout: 2.0) }
    }

    private func stopProcessOnly() async {
        if let socketPath = processSocketPath {
            scrubRuntimeAISecrets(forSocketPath: socketPath)
        }
        guard let terminating = terminateProcess() else { return }
        // Bounded wait so the old helper has actually released the
        // single-writer lock + socket before a restart spawns a new one;
        // otherwise the new process loses the lock race and exits. SIGTERM
        // on our own short-lived helper is honored quickly; cap the wait so
        // a wedged process can't block the caller indefinitely.
        await Self.waitForExit(terminating, timeout: 2.0)
    }

    /// Tears down the pipes, sends SIGTERM, and returns the still-running
    /// process so the (bounded) exit wait can happen at a later suspension
    /// point. The launcher releases its reference immediately so `isRunning`
    /// reflects the shutdown without waiting.
    private func terminateProcess() -> Process? {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        let terminating = process
        process = nil
        processSocketPath = nil
        guard let terminating, terminating.isRunning else { return nil }
        terminating.terminate()
        return terminating
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            // Suspend rather than block the caller: `Task.sleep` frees the run
            // loop between polls so a hung helper can never wedge the main actor.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func drain(pipe: Pipe, level: String) {
        let lineBuffer = ServiceOutputLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
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
