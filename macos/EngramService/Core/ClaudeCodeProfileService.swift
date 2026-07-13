import EngramCoreRead
import EngramCoreWrite
import Foundation
import GRDB

final class ClaudeCodeProfileService: @unchecked Sendable {
    private struct DiscoveredCounts {
        var files = 0
        var sourceBytes: Int64 = 0

        mutating func addFile(byteCount: Int64) {
            files = files == Int.max ? Int.max : files + 1
            let (sum, overflow) = sourceBytes.addingReportingOverflow(max(0, byteCount))
            sourceBytes = overflow ? Int64.max : sum
        }
    }

    private let profileResolver: ClaudeCodeProfileResolver
    private let writerGate: ServiceWriterGate
    private let archiveCatalog: ArchiveCatalog?
    private let settingsURL: URL
    private let signalDrainer: @Sendable () async -> Void

    init(
        profileResolver: ClaudeCodeProfileResolver,
        writerGate: ServiceWriterGate,
        archiveCatalog: ArchiveCatalog?,
        settingsURL: URL,
        signalDrainer: @escaping @Sendable () async -> Void
    ) {
        self.profileResolver = profileResolver
        self.writerGate = writerGate
        self.archiveCatalog = archiveCatalog
        self.settingsURL = settingsURL
        self.signalDrainer = signalDrainer
    }

    func status() async -> EngramServiceClaudeCodeProfilesStatusResponse {
        let resolution = profileResolver.resolve()
        let database = Self.readOnlyDatabase(path: writerGate.databasePath)
        let rows = resolution.profiles.prefix(128).map { profile in
            makeStatusRow(profile: profile, database: database)
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
        database: DatabaseQueue?
    ) -> EngramServiceClaudeCodeProfileStatus {
        var rowError: String?
        let discovered: DiscoveredCounts
        if profile.available {
            do {
                discovered = try Self.discoveredCounts(
                    projectsRoot: URL(fileURLWithPath: profile.projectsRoot, isDirectory: true)
                )
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
            if let archiveCatalog {
                archiveCounts = try archiveCatalog.claudeProfileStatusCounts(
                    canonicalProjectsRoot: profile.projectsRoot
                )
            }
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

    private static func discoveredCounts(projectsRoot: URL) throws -> DiscoveredCounts {
        var counts = DiscoveredCounts()
        for project in try directChildren(of: projectsRoot, includingHidden: true)
            where try isDirectory(project)
        {
            for entry in try directChildren(of: project, includingHidden: false) {
                if entry.pathExtension == "jsonl" {
                    counts.addFile(byteCount: try sourceByteCount(entry))
                    continue
                }

                let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                guard (try? isDirectory(subagents)) == true else { continue }
                for subagent in try directChildren(of: subagents, includingHidden: false)
                    where subagent.pathExtension == "jsonl"
                {
                    counts.addFile(byteCount: try sourceByteCount(subagent))
                }
            }
        }
        return counts
    }

    private static func directChildren(
        of directory: URL,
        includingHidden: Bool
    ) throws -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includingHidden ? [] : [.skipsHiddenFiles]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: options
        )
        .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        .sorted { $0.path < $1.path }
    }

    private static func isDirectory(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    private static func sourceByteCount(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
