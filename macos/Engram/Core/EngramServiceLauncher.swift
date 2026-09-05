import Foundation
import Darwin

struct EngramServiceLaunchConfiguration: Equatable {
    let executablePath: String
    let socketPath: String
    let databasePath: String
    let foreground: Bool
    var runtimeRole: EngramRuntimeRole = .local

    static func `default`(
        homeDirectory: URL = EngramUserDataDirectory.resolvedHomeDirectory(),
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
    // Cooperative shutdown can spend up to SQLite's 30s busy timeout leaving
    // an in-flight writer before it releases the process lock. Restart callers
    // suspend for that window plus the existing 2s handler drain; quit remains
    // fire-and-forget and never escalates to SIGKILL.
    nonisolated private static let cooperativeRestartShutdownTimeout: TimeInterval = 32.0

    typealias StatusProbe = @Sendable () async throws -> EngramServiceStatus
    typealias StatusSink = @MainActor @Sendable (EngramServiceStatus) -> Void

    /// OBS-O2: callback invoked for each structured event the service prints to
    /// stdout (e.g. `index_error`). The status poll channel can only ever report
    /// `.running`, so indexing failures are otherwise invisible to the app. The
    /// launcher already drains stdout; here it parses the JSON line and forwards
    /// the decoded event so `App.swift` can reflect it in the status store.
    typealias EventSink = @MainActor @Sendable (EngramServiceEvent) -> Void

    private var process: Process?
    /// docs/invariants.md (External Service Ownership): a serving socket
    /// discovered at launch belongs to its external supervisor.
    /// Track the connection without taking ownership of its process or secrets.
    private var adoptedConfiguration: EngramServiceLaunchConfiguration?
    private var adoptedServiceAvailable = false
    private var lifecycleGeneration = UUID()
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
    private var onUnexpectedExit: StatusSink?

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
        let standardized = URL(fileURLWithPath: socketPath).standardizedFileURL.path
        let defaultSocket = URL(
            fileURLWithPath: UnixSocketEngramServiceTransport.defaultSocketPath()
        ).standardizedFileURL.path
        if standardized == defaultSocket {
            return URL(fileURLWithPath: standardized)
                .deletingLastPathComponent()
                .appendingPathComponent("ai-secrets.json")
                .path
        }
        return standardized + ".ai-secrets.json"
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

        if secrets.isEmpty {
            if isOwnedRuntimeAISecretsPath(path) {
                removeRuntimeAISecrets(atPath: path)
            }
            return false
        }

        let url = URL(fileURLWithPath: path)
        var directorySecured = false
        var data: Data?
        do {
            let directory = url.deletingLastPathComponent()
            // Secret refresh owns only its sidecar. Runtime directory creation
            // and stale socket/lock cleanup belong to service startup; scanning
            // siblings here can delete a live lock or reject an unrelated FIFO.
            try UnixSocketEngramServiceTransport.secureRuntimeDirectory(at: directory)
            directorySecured = true
            let encoded = try JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys])
            data = encoded
            try SecureRegularFile.writeAtomically(encoded, toPath: path)
            return true
        } catch {
            guard directorySecured, let data, isOwnedRuntimeAISecretsPath(path) else {
                return false
            }
            removeRuntimeAISecrets(atPath: path)
            do {
                try SecureRegularFile.writeAtomically(data, toPath: path)
                return true
            } catch {
                removeRuntimeAISecrets(atPath: path)
            }
            return false
        }
    }

    /// Rebuild the running service's Keychain bridge. Unlike
    /// `writeRuntimeAISecrets`, an empty Keychain is a successful refresh when
    /// the owned bridge is absent or can be removed.
    @discardableResult
    nonisolated static func refreshRuntimeAISecrets(
        toPath path: String,
        keychainReader: (String) -> String?
    ) -> Bool {
        var secrets: [String: String] = [:]
        for account in ["aiApiKey", "titleApiKey", "embeddingApiKey"] {
            if let value = keychainReader(account), !value.isEmpty {
                secrets[account] = value
            }
        }
        guard !secrets.isEmpty else {
            guard isOwnedRuntimeAISecretsPath(path) else { return false }
            var info = stat()
            if lstat(path, &info) != 0, errno == ENOENT {
                return true
            }
            return SecureRegularFile.removeOwnerNonDirectory(atPath: path)
        }
        return writeRuntimeAISecrets(toPath: path) { secrets[$0] }
    }

    /// SEC-H2: remove the plaintext Keychain bridge without following a
    /// caller-controlled leaf or parent.
    nonisolated static func removeRuntimeAISecrets(atPath path: String) {
        _ = SecureRegularFile.removeOwnerNonDirectory(atPath: path)
    }

    nonisolated private static func isDedicatedRuntimeAISecretsPath(_ path: String) -> Bool {
        let expected = URL(
            fileURLWithPath: UnixSocketEngramServiceTransport.defaultSocketPath()
        )
        .deletingLastPathComponent()
        .appendingPathComponent("ai-secrets.json")
        .standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path == expected
    }

    nonisolated private static func isOwnedRuntimeAISecretsPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return isDedicatedRuntimeAISecretsPath(path)
            || name != "ai-secrets.json" && name.hasSuffix(".ai-secrets.json")
    }

    /// SEC-H2: scrub secrets next to the service socket (production bridge path).
    nonisolated func scrubRuntimeAISecrets(forSocketPath socketPath: String) {
        Self.removeRuntimeAISecrets(atPath: Self.runtimeAISecretsPath(forSocketPath: socketPath))
    }

    var isRunning: Bool {
        process?.isRunning == true || (adoptedConfiguration != nil && adoptedServiceAvailable)
    }

    func start(configuration: EngramServiceLaunchConfiguration, onEvent: EventSink? = nil) throws {
        guard configuration.runtimeRole == .local else {
            throw EngramServiceError.serviceUnavailable(message: configuration.runtimeRole == .index
                ? "EngramService is externally managed; reconnect instead of starting a helper"
                : configuration.runtimeRole.unavailableMessage)
        }
        if let onEvent { self.onEvent = onEvent }
        guard adoptedConfiguration == nil else {
            throw EngramServiceError.serviceUnavailable(
                message: "EngramService is externally managed; reconnect instead of starting a helper"
            )
        }
        guard process?.isRunning != true else { return }
        try Self.prepareIsolatedDataDirectory(configuration: configuration)
        // docs/invariants.md #1: probe the service-owned process lock before
        // spawning so a cooperatively terminating helper is not raced by a
        // short-lived replacement that loses the lock and exits successfully.
        try Self.assertServiceProcessLockAvailable(socketPath: configuration.socketPath)
        let proc = Process()
        let writerBusyObservation = ServiceWriterBusyObservation()
        let runtimeAISecretsPath = Self.runtimeAISecretsPath(forSocketPath: configuration.socketPath)
        proc.executableURL = URL(fileURLWithPath: configuration.executablePath)
        proc.arguments = Self.arguments(for: configuration)
        proc.environment = Self.environment(
            baseEnvironment: ProcessInfo.processInfo.environment,
            runtimeAISecretsPath: runtimeAISecretsPath,
            keychainReader: KeychainHelper.get
        )
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        drain(pipe: stdoutPipe, level: "stdout")
        drain(pipe: stderrPipe, level: "stderr", writerBusyObservation: writerBusyObservation)
        proc.terminationHandler = { [weak self, weak proc] _ in
            Self.removeRuntimeAISecrets(atPath: runtimeAISecretsPath)
            guard let proc else { return }
            let stderrHandle = stderrPipe.fileHandleForReading
            stderrHandle.readabilityHandler = nil
            try? stderrPipe.fileHandleForWriting.close()
            let trailingStderr = writerBusyObservation.drainToEnd(from: stderrHandle)
            if let text = String(data: trailingStderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty {
                EngramLogger.error("EngramService stderr: \(text)", module: .daemon)
            }
            let writerBusyDetected = writerBusyObservation.detected
            Task { @MainActor [weak self] in
                guard let self, self.process === proc else { return }
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                if proc.terminationStatus == 0, writerBusyDetected {
                    self.onUnexpectedExit?(.degraded(
                        message: "EngramService is still shutting down; replacement not started"
                    ))
                } else {
                    self.onUnexpectedExit?(
                        .error(message: "EngramService exited unexpectedly (status \(proc.terminationStatus))")
                    )
                }
            }
        }
        try runProcess(proc, runtimeAISecretsPath: runtimeAISecretsPath)
        process = proc
        processSocketPath = configuration.socketPath
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func runProcess(_ process: Process, runtimeAISecretsPath: String) throws {
        do {
            try process.run()
        } catch {
            Self.removeRuntimeAISecrets(atPath: runtimeAISecretsPath)
            throw error
        }
    }

    nonisolated private static func assertServiceProcessLockAvailable(socketPath: String) throws {
        let runtimeDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        let standardizedSocketPath = URL(fileURLWithPath: socketPath).standardizedFileURL.path
        let defaultSocketPath = URL(
            fileURLWithPath: UnixSocketEngramServiceTransport.defaultSocketPath()
        ).standardizedFileURL.path
        if standardizedSocketPath == defaultSocketPath {
            _ = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(
                homeDirectory: runtimeDirectory.deletingLastPathComponent().deletingLastPathComponent()
            )
        } else {
            var directoryInfo = stat()
            guard lstat(runtimeDirectory.path, &directoryInfo) == 0 else {
                throw EngramServiceError.serviceUnavailable(
                    message: "Cannot stat service socket directory"
                )
            }
            // Test/fake helpers historically use the shared system temp
            // directory. A real ServiceWriterGate rejects that directory, so
            // there is no valid service lock to probe until one already exists.
            if (directoryInfo.st_mode & 0o077) != 0,
               !FileManager.default.fileExists(
                   atPath: runtimeDirectory.appendingPathComponent("engram-service.lock").path
               ) {
                return
            }
            _ = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(at: runtimeDirectory)
        }
        let lockPath = runtimeDirectory.appendingPathComponent("engram-service.lock").path
        let fd = open(
            lockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw EngramServiceError.writerBusy(
                message: "Cannot probe EngramService writer lock"
            )
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              fchmod(fd, S_IRUSR | S_IWUSR) == 0
        else {
            throw EngramServiceError.writerBusy(
                message: "Cannot secure EngramService writer lock probe"
            )
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw EngramServiceError.writerBusy(
                message: "EngramService is still shutting down"
            )
        }
        flock(fd, LOCK_UN)
    }

    nonisolated private static func prepareIsolatedDataDirectory(
        configuration: EngramServiceLaunchConfiguration
    ) throws {
        let dataDirectory = URL(fileURLWithPath: configuration.databasePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        let runtimeDirectory = URL(fileURLWithPath: configuration.socketPath)
            .deletingLastPathComponent()
            .standardizedFileURL
        guard runtimeDirectory.path == dataDirectory
            .appendingPathComponent("run", isDirectory: true)
            .standardizedFileURL.path
        else {
            return
        }

        for directory in [dataDirectory, runtimeDirectory] {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw EngramServiceError.serviceUnavailable(
                    message: "Cannot create isolated service runtime directory"
                )
            }
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(),
                  chmod(directory.path, 0o700) == 0
            else {
                throw EngramServiceError.serviceUnavailable(
                    message: "Cannot secure isolated service runtime directory"
                )
            }
        }
        _ = try UnixSocketEngramServiceTransport.secureRuntimeDirectory(at: runtimeDirectory)
    }

    func startHealthMonitor(
        configuration: EngramServiceLaunchConfiguration,
        statusProbe: @escaping StatusProbe,
        onStatus: @escaping StatusSink,
        onEvent: EventSink? = nil
    ) {
        guard configuration.runtimeRole.allowsLocalIndex else {
            onStatus(.error(message: configuration.runtimeRole.unavailableMessage))
            return
        }
        if configuration.runtimeRole == .index, adoptedConfiguration == nil {
            guard process?.isRunning != true else {
                onStatus(.error(message: "Cannot adopt an App-owned helper as externally managed"))
                return
            }
            adoptedConfiguration = configuration
            adoptedServiceAvailable = false
        }
        if let onEvent { self.onEvent = onEvent }
        healthTask?.cancel()
        onUnexpectedExit = onStatus
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
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if self?.adoptedConfiguration != nil {
                            self?.adoptedServiceAvailable = true
                        }
                        onStatus(status)
                    }
                    restartAttempts = 0
                    startupGraceDeadline = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = error.localizedDescription
                    guard let self else { return }
                    if self.adoptedConfiguration != nil {
                        self.adoptedServiceAvailable = false
                        restartAttempts += 1
                        onStatus(.degraded(
                            message: "EngramService is externally managed; waiting for it to recover: \(message)"
                        ))
                        continue
                    }
                    let helperIsRunning = self.isRunning
                    if Self.isWithinStartupGrace(startupGraceDeadline), helperIsRunning {
                        await MainActor.run {
                            onStatus(.starting)
                        }
                        continue
                    }
                    if Self.isWithinStartupGrace(startupGraceDeadline), !helperIsRunning {
                        // A launched helper that already exited is not merely
                        // slow to open its socket. Surface the failure now and
                        // never grant respawns a fresh startup grace window.
                        startupGraceDeadline = nil
                        await MainActor.run {
                            onStatus(.error(message: "EngramService exited during startup: \(message)"))
                        }
                    }
                    if restartAttempts < maxRestarts {
                        restartAttempts += 1
                        // Await the bounded shutdown so the old helper releases
                        // its single-writer lock + socket before the new process
                        // spawns. The wait suspends (Task.sleep) instead of
                        // blocking, so the main run loop stays responsive.
                        let mayStartReplacement = await self.stopProcessOnly()
                        await MainActor.run {
                            guard mayStartReplacement else {
                                onStatus(.degraded(
                                    message: "EngramService is still shutting down; replacement not started"
                                ))
                                return
                            }
                            do {
                                try self.start(configuration: configuration, onEvent: self.onEvent)
                                onStatus(.starting)
                            } catch {
                                if engramServiceWriterBusyMessage(error) != nil {
                                    onStatus(.degraded(
                                        message: "EngramService is still shutting down; replacement not started"
                                    ))
                                } else {
                                    onStatus(.degraded(message: "EngramService restart failed: \(error.localizedDescription)"))
                                }
                            }
                        }
                    } else {
                        // Budget exhausted: keep probing, and keep attempting to
                        // spawn a helper when there is no live process. A dead
                        // child cannot recover merely because its socket is polled.
                        restartAttempts += 1
                        if helperIsRunning {
                            await MainActor.run {
                                onStatus(.degraded(message: "EngramService health check failed after \(maxRestarts) restart attempts: \(message)"))
                            }
                        } else {
                            let mayStartReplacement = await self.stopProcessOnly()
                            await MainActor.run {
                                guard mayStartReplacement else {
                                    onStatus(.degraded(
                                        message: "EngramService is still shutting down; replacement not started"
                                    ))
                                    return
                                }
                                do {
                                    try self.start(configuration: configuration, onEvent: self.onEvent)
                                    onStatus(.starting)
                                } catch {
                                    if engramServiceWriterBusyMessage(error) != nil {
                                        onStatus(.degraded(
                                            message: "EngramService is still shutting down; replacement not started"
                                        ))
                                    } else {
                                        onStatus(.degraded(message: "EngramService restart failed: \(error.localizedDescription)"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func startOrAdopt(
        configuration: EngramServiceLaunchConfiguration,
        statusProbe: @escaping StatusProbe,
        onStatus: @escaping StatusSink,
        onEvent: EventSink? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        guard configuration.runtimeRole.allowsLocalIndex else {
            onStatus(.error(message: configuration.runtimeRole.unavailableMessage))
            return
        }
        if configuration.runtimeRole == .index, adoptedConfiguration == nil {
            guard process?.isRunning != true else {
                onStatus(.error(message: "Cannot adopt an App-owned helper as externally managed"))
                return
            }
            // Pin external ownership before the initial probe can suspend or
            // fail. An absent socket never grants permission to spawn a writer.
            adoptedConfiguration = configuration
            adoptedServiceAvailable = false
        }
        if adoptedConfiguration != nil {
            await restart(
                configuration: configuration,
                statusProbe: statusProbe,
                onStatus: onStatus,
                onEvent: onEvent
            )
            return
        }
        if let status = try? await statusProbe() {
            guard !Task.isCancelled, lifecycleGeneration == generation else { return }
            if let onEvent { self.onEvent = onEvent }
            if process?.isRunning != true {
                adoptedConfiguration = configuration
                adoptedServiceAvailable = true
                process = nil
                processSocketPath = nil
            }
            onStatus(status)
            startHealthMonitor(
                configuration: configuration,
                statusProbe: statusProbe,
                onStatus: onStatus,
                onEvent: onEvent
            )
            return
        }

        guard !Task.isCancelled, lifecycleGeneration == generation else { return }
        do {
            try start(configuration: configuration, onEvent: onEvent)
            onStatus(.starting)
        } catch {
            guard engramServiceWriterBusyMessage(error) != nil else {
                onStatus(.error(message: error.localizedDescription))
                return
            }
            onStatus(.degraded(
                message: "EngramService is still shutting down; replacement not started"
            ))
        }
        startHealthMonitor(
            configuration: configuration,
            statusProbe: statusProbe,
            onStatus: onStatus,
            onEvent: onEvent
        )
    }

    /// Single restart sequencing point: stop the running helper (releasing its
    /// single-writer lock + socket), spawn a fresh process, and re-arm the
    /// health monitor with a fresh startup grace. Reuses the existing
    /// stopProcessOnly/start/startHealthMonitor primitives — no new process
    /// logic. Surfaces `.starting` then `.running` on success, or `.error` if
    /// `start()` throws (e.g. helper binary missing). An externally managed
    /// service only reconnects; its supervisor owns restart and replacement.
    func restart(
        configuration: EngramServiceLaunchConfiguration,
        statusProbe: @escaping StatusProbe,
        onStatus: @escaping StatusSink,
        onEvent: EventSink? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        lifecycleGeneration = generation
        guard configuration.runtimeRole.allowsLocalIndex else {
            onStatus(.error(message: configuration.runtimeRole.unavailableMessage))
            return
        }
        if configuration.runtimeRole == .index, adoptedConfiguration == nil {
            guard process?.isRunning != true else {
                onStatus(.error(message: "Cannot adopt an App-owned helper as externally managed"))
                return
            }
            adoptedConfiguration = configuration
            adoptedServiceAvailable = false
        }
        if adoptedConfiguration != nil {
            healthTask?.cancel()
            healthTask = nil
            do {
                let status = try await statusProbe()
                guard !Task.isCancelled, lifecycleGeneration == generation, adoptedConfiguration != nil else { return }
                adoptedServiceAvailable = true
                onStatus(status)
            } catch {
                guard !Task.isCancelled, lifecycleGeneration == generation, adoptedConfiguration != nil else { return }
                adoptedServiceAvailable = false
                onStatus(.degraded(
                    message: "EngramService is externally managed; waiting for it to recover: \(error.localizedDescription)"
                ))
            }
            startHealthMonitor(
                configuration: configuration,
                statusProbe: statusProbe,
                onStatus: onStatus,
                onEvent: onEvent
            )
            return
        }
        let stopped = await stopProcessOnly()
        guard !Task.isCancelled, lifecycleGeneration == generation else { return }
        guard stopped else {
            onStatus(.degraded(message: "EngramService is still shutting down; replacement not started"))
            return
        }
        do {
            try start(configuration: configuration, onEvent: onEvent)
            onStatus(.starting)
            startHealthMonitor(
                configuration: configuration,
                statusProbe: statusProbe,
                onStatus: onStatus,
                onEvent: onEvent
            )
        } catch {
            if engramServiceWriterBusyMessage(error) != nil {
                onStatus(.degraded(
                    message: "EngramService is still shutting down; replacement not started"
                ))
                startHealthMonitor(
                    configuration: configuration,
                    statusProbe: statusProbe,
                    onStatus: onStatus,
                    onEvent: onEvent
                )
            } else {
                onStatus(.error(message: error.localizedDescription))
            }
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
        lifecycleGeneration = UUID()
        adoptedServiceAvailable = false
        healthTask?.cancel()
        healthTask = nil
        if adoptedConfiguration != nil {
            adoptedConfiguration = nil
            return
        }
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
        if let terminating = terminateProcess() {
            Task { await Self.waitForExit(terminating, timeout: 2.0) }
            return
        }
    }

    @discardableResult
    private func stopProcessOnly() async -> Bool {
        guard adoptedConfiguration == nil else { return false }
        if let socketPath = processSocketPath {
            scrubRuntimeAISecrets(forSocketPath: socketPath)
        }
        guard let terminating = terminateProcess() else {
            return process?.isRunning != true
        }
        // Bounded wait so the old helper has actually released the
        // single-writer lock + socket before a restart spawns a new one;
        // otherwise the new process loses the lock race and exits. SIGTERM
        // on our own short-lived helper is honored quickly; cap the wait so
        // a wedged process can't block the caller indefinitely.
        await Self.waitForExit(
            terminating,
            timeout: Self.cooperativeRestartShutdownTimeout
        )
        // docs/invariants.md #1: retaining a still-live helper prevents a
        // replacement from racing it for the service's single-writer lock.
        return !terminating.isRunning
    }

    /// Tears down the pipes, sends SIGTERM, and returns the still-running
    /// process so the (bounded) exit wait can happen at a later suspension
    /// point. Keep the reference until it exits so callers cannot mistake a
    /// delayed cooperative shutdown for permission to spawn a replacement.
    private func terminateProcess() -> Process? {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        let terminating = process
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

    private func drain(
        pipe: Pipe,
        level: String,
        writerBusyObservation: ServiceWriterBusyObservation? = nil
    ) {
        let lineBuffer = ServiceOutputLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = writerBusyObservation?.readAvailableData(from: handle)
                ?? handle.availableData
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

private final class ServiceWriterBusyObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var suffix = Data()
    private var hasDetected = false

    var detected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasDetected
    }

    func readAvailableData(from handle: FileHandle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = handle.availableData
        appendLocked(data)
        return data
    }

    func drainToEnd(from handle: FileHandle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var drained = Data()
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            drained.append(data)
            appendLocked(data)
        }
        return drained
    }

    private func appendLocked(_ data: Data) {
        guard !hasDetected else { return }
        suffix.append(data)
        if suffix.count > 1_024 {
            suffix = suffix.suffix(1_024)
        }
        hasDetected = String(decoding: suffix, as: UTF8.self)
            .contains("another instance owns the writer lock; exiting")
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
