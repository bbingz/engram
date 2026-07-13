import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB

struct ClaudeCodeProfileStatusTestHooks: Sendable {
    let scanBoundary: (@Sendable (URL) -> Void)?

    init(scanBoundary: (@Sendable (URL) -> Void)? = nil) {
        self.scanBoundary = scanBoundary
    }

    static let none = ClaudeCodeProfileStatusTestHooks()
}

final class ClaudeCodeProfileService: @unchecked Sendable {
    typealias StatusResponse = EngramServiceClaudeCodeProfilesStatusResponse
    typealias StatusOperation = @Sendable () -> StatusResponse
    typealias StatusBlockingExecutor = @Sendable (@escaping StatusOperation) async -> StatusResponse

    private final class StatusCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        func check() throws {
            if lock.withLock({ cancelled }) {
                throw CancellationError()
            }
        }
    }

    private struct DiscoveredCounts {
        var files = 0
        var sourceBytes: Int64 = 0

        mutating func addFile(byteCount: Int64) {
            files = files == Int.max ? Int.max : files + 1
            let (sum, overflow) = sourceBytes.addingReportingOverflow(max(0, byteCount))
            sourceBytes = overflow ? Int64.max : sum
        }
    }

    private static let statusBlockingQueue = DispatchQueue(
        label: "com.engram.service.claude-profile-status.blocking",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let defaultStatusBlockingExecutor: StatusBlockingExecutor = { operation in
        await executeStatusOffCooperativePool(operation)
    }

    private let profileResolver: ClaudeCodeProfileResolver
    private let writerGate: ServiceWriterGate
    private let archiveCatalog: ArchiveCatalog?
    private let settingsURL: URL
    private let signalDrainer: @Sendable () async -> Void
    private let statusBlockingExecutor: StatusBlockingExecutor
    private let statusTestHooks: ClaudeCodeProfileStatusTestHooks

    init(
        profileResolver: ClaudeCodeProfileResolver,
        writerGate: ServiceWriterGate,
        archiveCatalog: ArchiveCatalog?,
        settingsURL: URL,
        signalDrainer: @escaping @Sendable () async -> Void,
        statusBlockingExecutor: @escaping StatusBlockingExecutor = ClaudeCodeProfileService.defaultStatusBlockingExecutor,
        statusTestHooks: ClaudeCodeProfileStatusTestHooks = .none
    ) {
        self.profileResolver = profileResolver
        self.writerGate = writerGate
        self.archiveCatalog = archiveCatalog
        self.settingsURL = settingsURL
        self.signalDrainer = signalDrainer
        self.statusBlockingExecutor = statusBlockingExecutor
        self.statusTestHooks = statusTestHooks
    }

    func status() async -> EngramServiceClaudeCodeProfilesStatusResponse {
        let cancellation = StatusCancellation()
        if Task.isCancelled {
            cancellation.cancel()
        }
        return await withTaskCancellationHandler {
            await statusBlockingExecutor { [self] in
                do {
                    return try buildStatus(cancellation: cancellation)
                } catch is CancellationError {
                    return Self.cancelledStatus
                } catch {
                    return Self.cancelledStatus
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func buildStatus(
        cancellation: StatusCancellation
    ) throws -> EngramServiceClaudeCodeProfilesStatusResponse {
        try cancellation.check()
        let resolution = profileResolver.resolve()
        try cancellation.check()
        let database = Self.readOnlyDatabase(path: writerGate.databasePath)
        try cancellation.check()
        var rows: [EngramServiceClaudeCodeProfileStatus] = []
        rows.reserveCapacity(min(resolution.profiles.count, 128))
        for profile in resolution.profiles.prefix(128) {
            try cancellation.check()
            rows.append(
                try makeStatusRow(
                    profile: profile,
                    database: database,
                    cancellation: cancellation
                )
            )
        }

        // Resolver output and service-owned metrics satisfy the wire invariants.
        // A violation here is a programmer error, not a recoverable runtime state.
        return try! EngramServiceClaudeCodeProfilesStatusResponse(
            autoDiscover: resolution.settings.autoDiscover,
            customProjectsRoots: resolution.settings.customProjectsRoots,
            profiles: rows,
            configurationError: resolution.configurationError
        )
    }

    func configure(
        _ request: EngramServiceConfigureClaudeCodeProfilesRequest
    ) async throws -> EngramServiceClaudeCodeProfilesStatusResponse {
        let roots: [String]
        do {
            roots = try profileResolver.validateCustomProjectsRoots(request.customProjectsRoots)
        } catch {
            throw EngramServiceError.invalidRequest(message: "invalid_claude_code_profiles")
        }

        do {
            try SecureSettingsFileWriter.mutateJSON(at: settingsURL) { object in
                object["claudeCodeProfiles"] = [
                    "autoDiscover": request.autoDiscover,
                    "customProjectsRoots": roots,
                ]
            }
        } catch {
            throw EngramServiceError.serviceUnavailable(message: "settings_write_failed")
        }

        await signalDrainer()
        return await status()
    }

    private func makeStatusRow(
        profile: ClaudeCodeProfile,
        database: DatabaseQueue?,
        cancellation: StatusCancellation
    ) throws -> EngramServiceClaudeCodeProfileStatus {
        try cancellation.check()
        var rowError: String?
        let discovered: DiscoveredCounts
        if profile.available {
            do {
                discovered = try Self.discoveredCounts(
                    projectsRoot: URL(fileURLWithPath: profile.projectsRoot, isDirectory: true),
                    cancellation: cancellation,
                    testHooks: statusTestHooks
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                discovered = DiscoveredCounts()
                rowError = "profile_scan_unavailable"
            }
        } else {
            discovered = DiscoveredCounts()
            rowError = "profile_unavailable"
        }

        var indexedLocatorCount = 0
        var archiveCounts = ArchiveClaudeProfileStatusCounts(
            capturedCount: 0,
            ignoredEmptyCaptureCount: 0,
            hqVerifiedCount: 0,
            m1VerifiedCount: 0
        )
        do {
            try cancellation.check()
            guard let database else {
                throw DatabaseError(message: "status database unavailable")
            }
            indexedLocatorCount = try database.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM file_index_state
                    WHERE source = 'claude-code'
                      AND parse_status = 'ok'
                      AND schema_version = ?
                      AND (
                        locator = ?
                        OR substr(locator, 1, length(?) + 1) = ? || '/'
                      )
                    """,
                    arguments: [
                        FileIndexState.currentSchemaVersion,
                        profile.projectsRoot,
                        profile.projectsRoot,
                        profile.projectsRoot,
                    ]
                ) ?? 0
            }
            try cancellation.check()
            if let archiveCatalog {
                archiveCounts = try archiveCatalog.claudeProfileStatusCounts(
                    canonicalProjectsRoot: profile.projectsRoot
                )
                try cancellation.check()
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            indexedLocatorCount = 0
            archiveCounts = ArchiveClaudeProfileStatusCounts(
                capturedCount: 0,
                ignoredEmptyCaptureCount: 0,
                hqVerifiedCount: 0,
                m1VerifiedCount: 0
            )
            rowError = "status_database_unavailable"
        }

        return try! EngramServiceClaudeCodeProfileStatus(
            id: profile.id,
            displayName: profile.displayName,
            projectsRoot: profile.projectsRoot,
            origin: profile.origin.rawValue,
            available: profile.available,
            sourceReclamationAllowed: profile.sourceReclamationAllowed,
            discoveredFileCount: discovered.files,
            discoveredSourceBytes: discovered.sourceBytes,
            indexedLocatorCount: indexedLocatorCount,
            capturedCount: archiveCounts.capturedCount,
            ignoredEmptyCaptureCount: archiveCounts.ignoredEmptyCaptureCount,
            hqVerifiedCount: archiveCounts.hqVerifiedCount,
            m1VerifiedCount: archiveCounts.m1VerifiedCount,
            error: rowError
        )
    }

    private static func readOnlyDatabase(path: String) -> DatabaseQueue? {
        var configuration = Configuration()
        configuration.readonly = true
        return try? DatabaseQueue(path: path, configuration: configuration)
    }

    static func executeStatusOffCooperativePool(
        _ operation: @escaping StatusOperation
    ) async -> StatusResponse {
        await withCheckedContinuation { continuation in
            statusBlockingQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static let cancelledStatus = try! EngramServiceClaudeCodeProfilesStatusResponse(
        autoDiscover: true,
        customProjectsRoots: [],
        profiles: [],
        configurationError: "status_cancelled"
    )

    private static func discoveredCounts(
        projectsRoot: URL,
        cancellation: StatusCancellation,
        testHooks: ClaudeCodeProfileStatusTestHooks
    ) throws -> DiscoveredCounts {
        var counts = DiscoveredCounts()
        for project in try directChildren(
            of: projectsRoot,
            includingHidden: true,
            cancellation: cancellation
        ) {
            try visitBoundary(project, cancellation: cancellation, testHooks: testHooks)
            guard try isDirectory(project, cancellation: cancellation) else { continue }
            for entry in try directChildren(
                of: project,
                includingHidden: false,
                cancellation: cancellation
            ) {
                try visitBoundary(entry, cancellation: cancellation, testHooks: testHooks)
                if entry.pathExtension == "jsonl" {
                    counts.addFile(
                        byteCount: try sourceByteCount(entry, cancellation: cancellation)
                    )
                    continue
                }

                let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                guard (try? isDirectory(subagents, cancellation: cancellation)) == true else {
                    try cancellation.check()
                    continue
                }
                for subagent in try directChildren(
                    of: subagents,
                    includingHidden: false,
                    cancellation: cancellation
                ) where subagent.pathExtension == "jsonl" {
                    try visitBoundary(subagent, cancellation: cancellation, testHooks: testHooks)
                    counts.addFile(
                        byteCount: try sourceByteCount(subagent, cancellation: cancellation)
                    )
                }
            }
        }
        return counts
    }

    private static func directChildren(
        of directory: URL,
        includingHidden: Bool,
        cancellation: StatusCancellation
    ) throws -> [URL] {
        try cancellation.check()
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: options
        )
        try cancellation.check()
        var nonSymlinks: [URL] = []
        nonSymlinks.reserveCapacity(children.count)
        for child in children {
            try cancellation.check()
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
                nonSymlinks.append(child)
            }
        }
        return nonSymlinks.sorted { $0.path < $1.path }
    }

    private static func visitBoundary(
        _ url: URL,
        cancellation: StatusCancellation,
        testHooks: ClaudeCodeProfileStatusTestHooks
    ) throws {
        try cancellation.check()
        testHooks.scanBoundary?(url)
        try cancellation.check()
    }

    private static func isDirectory(
        _ url: URL,
        cancellation: StatusCancellation
    ) throws -> Bool {
        try cancellation.check()
        let result = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try cancellation.check()
        return result
    }

    private static func sourceByteCount(
        _ url: URL,
        cancellation: StatusCancellation
    ) throws -> Int64 {
        try cancellation.check()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try cancellation.check()
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
