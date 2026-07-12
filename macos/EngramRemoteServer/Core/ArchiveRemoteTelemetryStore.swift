import Darwin
import Foundation

struct ArchiveRemoteTelemetryObservation: Equatable, Sendable {
    let endpoint: String
    let method: String
    let statusCode: Int
    let durationMs: Double
    let requestBytes: Int64
    let responseBytes: Int64
    let archiveMutation: Bool

    init(
        endpoint: String,
        method: String,
        statusCode: Int,
        durationMs: Double,
        requestBytes: Int64,
        responseBytes: Int64,
        archiveMutation: Bool
    ) {
        self.endpoint = Self.allowedEndpoints.contains(endpoint) ? endpoint : "unknown"
        self.method = Self.allowedMethods.contains(method) ? method : "GET"
        self.statusCode = (100...599).contains(statusCode) ? statusCode : 500
        self.durationMs = durationMs.isFinite && durationMs >= 0 ? durationMs : 0
        self.requestBytes = max(0, requestBytes)
        self.responseBytes = max(0, responseBytes)
        self.archiveMutation = archiveMutation
    }

    private static let allowedEndpoints: Set<String> = [
        "object", "manifest", "receipt", "machines", "receipts", "status", "unknown",
    ]
    private static let allowedMethods: Set<String> = ["GET", "HEAD", "PUT", "DELETE"]
}

actor ArchiveRemoteTelemetryStore {
    typealias SnapshotWriter = @Sendable (Data, URL) throws -> Void

    static let flushInterval: TimeInterval = 60
    static let telemetryDirectoryName = ".telemetry"
    static let snapshotFileName = "status-v1.json"

    private struct EndpointState: Sendable {
        var requestCount: Int64 = 0
        var errorCount: Int64 = 0
        var totalDurationMs: Double = 0
        var maximumDurationMs: Double = 0
        var requestBytes: Int64 = 0
        var responseBytes: Int64 = 0

        init() {}

        init(_ endpoint: ArchiveRemoteTelemetryEndpoint) {
            requestCount = endpoint.requestCount
            errorCount = endpoint.errorCount
            totalDurationMs = endpoint.totalDurationMs
            maximumDurationMs = endpoint.maximumDurationMs
            requestBytes = endpoint.requestBytes
            responseBytes = endpoint.responseBytes
        }

        mutating func apply(_ observation: ArchiveRemoteTelemetryObservation) {
            requestCount = Self.adding(requestCount, 1)
            if observation.statusCode >= 400 {
                errorCount = Self.adding(errorCount, 1)
            }
            totalDurationMs = Self.adding(totalDurationMs, observation.durationMs)
            maximumDurationMs = max(maximumDurationMs, observation.durationMs)
            requestBytes = Self.adding(requestBytes, observation.requestBytes)
            responseBytes = Self.adding(responseBytes, observation.responseBytes)
        }

        private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : value
        }

        private static func adding(_ lhs: Double, _ rhs: Double) -> Double {
            let value = lhs + rhs
            return value.isFinite ? value : .greatestFiniteMagnitude
        }
    }

    private struct State: Sendable {
        var requestCount: Int64 = 0
        var successCount: Int64 = 0
        var clientErrorCount: Int64 = 0
        var serverErrorCount: Int64 = 0
        var requestBytes: Int64 = 0
        var responseBytes: Int64 = 0
        var lastArchiveMutationAt: String?
        var persistenceError: String?
        var endpoints: [String: EndpointState] = [:]
        var recentErrors: [ArchiveRemoteTelemetryError] = []
        var dirty = false
        var lastPersistedAt: Date

        init(lastPersistedAt: Date) {
            self.lastPersistedAt = lastPersistedAt
        }

        init(snapshot: ArchiveRemoteTelemetrySnapshot, lastPersistedAt: Date) {
            requestCount = snapshot.requestCount
            successCount = snapshot.successCount
            clientErrorCount = snapshot.clientErrorCount
            serverErrorCount = snapshot.serverErrorCount
            requestBytes = snapshot.requestBytes
            responseBytes = snapshot.responseBytes
            lastArchiveMutationAt = snapshot.lastArchiveMutationAt
            endpoints = Dictionary(uniqueKeysWithValues: snapshot.endpoints.map {
                ($0.endpoint, EndpointState($0))
            })
            recentErrors = snapshot.recentErrors
            self.lastPersistedAt = lastPersistedAt
        }

        mutating func apply(
            _ observation: ArchiveRemoteTelemetryObservation,
            timestamp: String
        ) {
            requestCount = Self.adding(requestCount, 1)
            switch observation.statusCode {
            case ..<400:
                successCount = Self.adding(successCount, 1)
            case 400..<500:
                clientErrorCount = Self.adding(clientErrorCount, 1)
            default:
                serverErrorCount = Self.adding(serverErrorCount, 1)
            }
            requestBytes = Self.adding(requestBytes, observation.requestBytes)
            responseBytes = Self.adding(responseBytes, observation.responseBytes)
            endpoints[observation.endpoint, default: EndpointState()].apply(observation)
            if observation.archiveMutation && observation.statusCode < 300 {
                lastArchiveMutationAt = timestamp
            }
            if let category = Self.errorCategory(for: observation.statusCode),
               let error = try? ArchiveRemoteTelemetryError(
                   timestamp: timestamp,
                   endpoint: observation.endpoint,
                   method: observation.method,
                   statusCode: observation.statusCode,
                   category: category
               ) {
                recentErrors.append(error)
                if recentErrors.count > ArchiveRemoteTelemetrySnapshot.maximumErrors {
                    recentErrors.removeFirst(
                        recentErrors.count - ArchiveRemoteTelemetrySnapshot.maximumErrors
                    )
                }
            }
            dirty = true
        }

        private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (value, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : value
        }

        private static func errorCategory(for statusCode: Int) -> String? {
            switch statusCode {
            case ..<400:
                nil
            case 401, 403:
                "unauthorized"
            case 404:
                "not_found"
            case 409:
                "conflict"
            case 413:
                "payload_too_large"
            case 415, 422:
                "invalid_content"
            case 507:
                "storage_unavailable"
            case 400..<500:
                "malformed_request"
            default:
                "internal_error"
            }
        }
    }

    private let archiveRoot: URL
    private let telemetryDirectory: URL
    private let snapshotFile: URL
    private let serverID: String
    private let sourceRevision: String
    private let processStartedAt: Date
    private let now: @Sendable () -> Date
    private let snapshotWriter: SnapshotWriter
    private var state: State

    init(
        archiveRoot: URL,
        serverID: String,
        sourceRevision: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try self.init(
            archiveRoot: archiveRoot,
            serverID: serverID,
            sourceRevision: sourceRevision,
            now: now,
            snapshotWriter: { data, url in
                try Self.defaultSnapshotWriter(data, url)
            }
        )
    }

    init(
        archiveRoot: URL,
        serverID: String,
        sourceRevision: String,
        now: @escaping @Sendable () -> Date,
        snapshotWriter: @escaping SnapshotWriter
    ) throws {
        let root = archiveRoot.standardizedFileURL
        let directory = root.appendingPathComponent(
            Self.telemetryDirectoryName,
            isDirectory: true
        )
        let file = directory.appendingPathComponent(Self.snapshotFileName)
        let startedAt = now()
        _ = try ArchiveRemoteTelemetrySnapshot(
            serverID: serverID,
            sourceRevision: sourceRevision,
            processStartedAt: Self.timestamp(startedAt),
            snapshotAt: Self.timestamp(startedAt),
            uptimeSeconds: 0,
            diskAvailableBytes: nil,
            diskTotalBytes: nil,
            requestCount: 0,
            successCount: 0,
            clientErrorCount: 0,
            serverErrorCount: 0,
            requestBytes: 0,
            responseBytes: 0,
            lastArchiveMutationAt: nil,
            persistenceError: nil,
            endpoints: [],
            recentErrors: []
        )

        self.archiveRoot = root
        self.telemetryDirectory = directory
        self.snapshotFile = file
        self.serverID = serverID
        self.sourceRevision = sourceRevision
        self.processStartedAt = startedAt
        self.now = now
        self.snapshotWriter = snapshotWriter

        let directoryIsSafe = Self.prepareTelemetryDirectory(directory)
        if directoryIsSafe,
           let snapshot = Self.loadSnapshot(from: file),
           snapshot.serverID == serverID {
            state = State(snapshot: snapshot, lastPersistedAt: startedAt)
        } else {
            state = State(lastPersistedAt: startedAt)
        }
        if !directoryIsSafe {
            state.persistenceError = "snapshot_write_failed"
        }
    }

    func record(_ observation: ArchiveRemoteTelemetryObservation) {
        let observedAt = now()
        state.apply(observation, timestamp: Self.timestamp(observedAt))
        if observedAt.timeIntervalSince(state.lastPersistedAt) >= Self.flushInterval {
            persistBestEffort(at: observedAt)
        }
    }

    func status(forcePersist: Bool) -> ArchiveRemoteTelemetrySnapshot {
        let snapshotAt = now()
        if forcePersist && state.dirty {
            persistBestEffort(at: snapshotAt)
        }
        return makeSnapshot(at: snapshotAt, persistenceError: state.persistenceError)
    }

    static func defaultSnapshotWriter(_ data: Data, _ url: URL) throws {
        guard data.count <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes,
              isSafeTelemetryDirectory(url.deletingLastPathComponent()) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var existing = stat()
        if Darwin.lstat(url.path, &existing) == 0 {
            guard isOwnedRegularFile(existing) else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else if errno != ENOENT {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var final = stat()
        guard Darwin.lstat(url.path, &final) == 0,
              isOwnedRegularFile(final),
              Int(final.st_mode & 0o777) == 0o600 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func persistBestEffort(at date: Date) {
        state.lastPersistedAt = date
        do {
            let snapshot = makeSnapshot(at: date, persistenceError: nil)
            let data = try ArchiveCanonicalJSON.encode(snapshot)
            guard data.count <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try snapshotWriter(data, snapshotFile)
            state.persistenceError = nil
            state.dirty = false
        } catch {
            state.persistenceError = "snapshot_write_failed"
        }
    }

    private func makeSnapshot(
        at date: Date,
        persistenceError: String?
    ) -> ArchiveRemoteTelemetrySnapshot {
        let disk = Self.diskCapacity(for: archiveRoot)
        let endpoints: [ArchiveRemoteTelemetryEndpoint] = state.endpoints.keys
            .sorted().compactMap { name in
            guard let value = state.endpoints[name] else { return nil }
            return try? ArchiveRemoteTelemetryEndpoint(
                endpoint: name,
                requestCount: value.requestCount,
                errorCount: value.errorCount,
                totalDurationMs: value.totalDurationMs,
                maximumDurationMs: value.maximumDurationMs,
                requestBytes: value.requestBytes,
                responseBytes: value.responseBytes
            )
            }
        return try! ArchiveRemoteTelemetrySnapshot(
            serverID: serverID,
            sourceRevision: sourceRevision,
            processStartedAt: Self.timestamp(processStartedAt),
            snapshotAt: Self.timestamp(date),
            uptimeSeconds: max(0, date.timeIntervalSince(processStartedAt)),
            diskAvailableBytes: disk.available,
            diskTotalBytes: disk.total,
            requestCount: state.requestCount,
            successCount: state.successCount,
            clientErrorCount: state.clientErrorCount,
            serverErrorCount: state.serverErrorCount,
            requestBytes: state.requestBytes,
            responseBytes: state.responseBytes,
            lastArchiveMutationAt: state.lastArchiveMutationAt,
            persistenceError: persistenceError,
            endpoints: endpoints,
            recentErrors: state.recentErrors
        )
    }

    private static func prepareTelemetryDirectory(_ url: URL) -> Bool {
        if Darwin.mkdir(url.path, S_IRWXU) != 0, errno != EEXIST {
            return false
        }
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              Darwin.chmod(url.path, S_IRWXU) == 0 else {
            return false
        }
        var final = stat()
        return Darwin.lstat(url.path, &final) == 0
            && (final.st_mode & S_IFMT) == S_IFDIR
            && final.st_uid == geteuid()
            && Int(final.st_mode & 0o777) == 0o700
    }

    private static func loadSnapshot(from url: URL) -> ArchiveRemoteTelemetrySnapshot? {
        var pathInfo = stat()
        guard Darwin.lstat(url.path, &pathInfo) == 0,
              isOwnedRegularFile(pathInfo),
              Int(pathInfo.st_mode & 0o777) == 0o600,
              pathInfo.st_size >= 0,
              pathInfo.st_size <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes else {
            return nil
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var descriptorInfo = stat()
        guard Darwin.fstat(descriptor, &descriptorInfo) == 0,
              isOwnedRegularFile(descriptorInfo),
              sameFile(pathInfo, descriptorInfo),
              let data = try? handle.read(
                  upToCount: ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes + 1
              ),
              data.count <= ArchiveRemoteTelemetrySnapshot.maximumEncodedBytes else {
            return nil
        }
        var finalInfo = stat()
        guard Darwin.lstat(url.path, &finalInfo) == 0,
              sameFile(descriptorInfo, finalInfo) else {
            return nil
        }
        return try? ArchiveCanonicalJSON.decode(
            ArchiveRemoteTelemetrySnapshot.self,
            from: data
        )
    }

    private static func isSafeTelemetryDirectory(_ url: URL) -> Bool {
        var info = stat()
        return Darwin.lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && Int(info.st_mode & 0o777) == 0o700
    }

    private static func isOwnedRegularFile(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid()
            && info.st_nlink == 1
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func diskCapacity(for url: URL) -> (available: Int64?, total: Int64?) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: url.path
        ) else {
            return (nil, nil)
        }
        let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value
        guard let available, available >= 0,
              let total, total >= 0,
              available <= total else {
            return (nil, nil)
        }
        return (available, total)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
