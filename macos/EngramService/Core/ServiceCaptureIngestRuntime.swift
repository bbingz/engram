import Foundation
import CoreFoundation
import Darwin
import EngramCoreRead
import EngramCoreWrite

/// Cold composition root. A host that starts OFF requires a restart to enable
/// intake; an installed runtime still revalidates policy before every operation.
actor ServiceCaptureIngestRuntime {
    static let parserRevision = "swift-capture-v1"

    nonisolated let metadataProducer: any ServiceWebMetadataProviding
    nonisolated let transcriptProvider: any ServiceWebTranscriptSnapshotProviding

    private let normalizedReader: ServiceWebNormalizedTranscriptSnapshotProvider
    private let consumer: ServiceCapturePublicationConsumer
    private let replay: ServiceCaptureIngestWorker
    private let gate: ServiceWriterGate
    private let settingsURL: URL
    private var loops: [Task<Void, Never>] = []
    private var sealed = false
    private var metadataClosed = false
    private var transcriptClosed = false

    private init(gate: ServiceWriterGate, settingsURL: URL,
                 consumer: ServiceCapturePublicationConsumer, replay: ServiceCaptureIngestWorker,
                 metadataProducer: ServiceWebMetadataProducer,
                 transcriptProvider: ServiceWebNormalizedTranscriptSnapshotProvider) {
        self.gate = gate
        self.settingsURL = settingsURL
        self.consumer = consumer
        self.replay = replay
        self.metadataProducer = metadataProducer
        self.transcriptProvider = transcriptProvider
        self.normalizedReader = transcriptProvider
    }

    static func make(
        gate: ServiceWriterGate,
        databasePath: String,
        settingsURL: URL,
        credentialLoader: @escaping @Sendable (String) throws -> String? = {
            try ArchiveCredentialStore().loadToken(replicaID: $0)
        }
    ) throws -> ServiceCaptureIngestRuntime? {
        guard settings(at: settingsURL) != nil else { return nil }
        let root = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            .appendingPathComponent("capture-ingest", isDirectory: true)
        let casRoot = root.appendingPathComponent("cas", isDirectory: true)
        let stageRoot = root.appendingPathComponent("stage", isDirectory: true)
        for directory in [root, casRoot, stageRoot] { try ensureOwnerDirectory(directory) }
        let cas = try ImmutableArchiveCAS(root: casRoot)
        let freshPolicy: @Sendable () -> ServiceCaptureIngestParserPolicy? = { policy(at: settingsURL) }
        let webPolicy: @Sendable () -> ServiceWebMetadataPolicy? = {
            guard let current = freshPolicy() else { return nil }
            return ServiceWebMetadataPolicy(parserRevision: current.parserRevision,
                enabledSources: current.enabledSources)
        }
        let metadata = try ServiceWebMetadataProducer(databasePath: databasePath, policy: webPolicy)
        let transcript: ServiceWebNormalizedTranscriptSnapshotProvider
        do {
            transcript = try ServiceWebNormalizedTranscriptSnapshotProvider(databasePath: databasePath, policy: webPolicy)
        } catch {
            try? metadata.stop()
            throw error
        }
        let consumer = ServiceCapturePublicationConsumer(gate: gate, cas: cas,
            configuration: { settings(at: settingsURL)?.configuration }, policy: freshPolicy,
            credential: credentialLoader)
        let replay = ServiceCaptureIngestWorker(gate: gate, cas: cas, stagingParent: stageRoot,
            policy: freshPolicy, unixClock: { Int64(Date().timeIntervalSince1970) })
        return ServiceCaptureIngestRuntime(gate: gate, settingsURL: settingsURL,
            consumer: consumer, replay: replay, metadataProducer: metadata, transcriptProvider: transcript)
    }

    /// Shared fresh policy admission for intake, replay, readiness and readers.
    /// This read-only function must not repair settings or touch credentials.
    static func policy(at settingsURL: URL) -> ServiceCaptureIngestParserPolicy? {
        settings(at: settingsURL)?.policy
    }

    func start() async {
        guard !sealed, loops.isEmpty else { return }
        let consumer = consumer
        let replay = replay
        let gate = gate
        let settingsURL = settingsURL
        loops = [
            Self.loop(interval: .seconds(2)) { _ = try await consumer.runOnce() },
            Self.loop(interval: .milliseconds(250)) { _ = try await replay.step() },
            Self.loop(interval: .milliseconds(250)) {
                guard Self.policy(at: settingsURL) != nil else { return }
                _ = try await gate.performWriteCommand(name: "captureIngestFTSReadiness") { writer in
                    guard Self.policy(at: settingsURL) != nil else { return false }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    let runner = IndexJobRunner(writer: writer, adapters: [], capturePolicy: {
                        guard let policy = Self.policy(at: settingsURL) else { return nil }
                        return CaptureFTSReadinessPolicy(parserRevision: policy.parserRevision,
                            enabledSources: policy.enabledSources, deadline: deadline)
                    })
                    _ = try await runner.runRecoverableJobsOnce()
                    return true
                }
            },
        ]
    }

    func stop() async {
        sealed = true
        let joining = loops
        joining.forEach { $0.cancel() }
        await consumer.stop()
        try? await replay.stop()
        for task in joining { await task.value }
        loops.removeAll()
    }

    /// Runner calls this only after stopping IPC admission and draining handlers.
    func closeReaders() throws {
        if !metadataClosed {
            try metadataProducer.stop()
            metadataClosed = true
        }
        if !transcriptClosed {
            try normalizedReader.stop()
            transcriptClosed = true
        }
    }

    private static func loop(interval: Duration,
                             operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        Task {
            await ServiceWriterGate.$preserveAcceptedWriteProducer.withValue(false) {
                while !Task.isCancelled {
                    do { try await operation() }
                    catch is CancellationError { break }
                    catch { /* Persisted work stays retryable; other loops must keep progressing. */ }
                    do { try await Task.sleep(for: interval) }
                    catch { break }
                }
            }
        }
    }

    private struct Settings {
        let configuration: ServiceCaptureIngestConfiguration
        let policy: ServiceCaptureIngestParserPolicy
    }

    private static func settings(at url: URL) -> Settings? {
        guard let bytes = SecureRegularFile.read(atPath: url.path,
            maximumBytes: RuntimeRoleSettings.maximumBytes, repairPermissions: false),
              let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let configuration = try? ServiceCaptureIngestConfiguration.decode(settings: root),
              ["hq", "m1"].contains(configuration.credentialID) else { return nil }
        if let value = root["runtimeRole"] {
            guard let role = value as? String, role == "local" || role == "index" else { return nil }
        }
        let migrated: Bool
        if let value = root[ArchivedDefaultOffSources.settingsMigrationKey] {
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { return nil }
            migrated = flag
        } else { migrated = false }
        var disabled = ArchivedDefaultOffSources.ids
        if let value = root["disabledSources"] {
            guard let sources = value as? [String] else { return nil }
            disabled = Set(sources)
            if !migrated { disabled.formUnion(ArchivedDefaultOffSources.ids) }
        }
        return Settings(configuration: configuration, policy: ServiceCaptureIngestParserPolicy(
            parserRevision: parserRevision,
            enabledSources: Set(SourceName.allCases.filter { !disabled.contains($0.rawValue) })))
    }

    private static func ensureOwnerDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw ImmutableArchiveCASError.io(operation: "mkdir-capture-runtime", code: errno)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o777) == 0o700 else {
            throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ImmutableArchiveCASError.unsafeExistingPath(url.path) }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_uid == geteuid(), (opened.st_mode & 0o777) == 0o700 else {
            throw ImmutableArchiveCASError.unsafeExistingPath(url.path)
        }
        guard fsync(descriptor) == 0 else {
            throw ImmutableArchiveCASError.io(operation: "fsync-capture-runtime", code: errno)
        }
    }
}
