import Darwin
import CryptoKit
import EngramCoreRead
import Foundation

public enum ArchiveSourceReclaimerError: Error, Equatable, Sendable {
    case invalidIntent
    case staleIntent
    case sourceTooLarge
    case unsafePath
    case pathCollision
    case generationChanged
    case ioFailure(operation: String, code: Int32)
}

public struct ArchiveSourceReclaimResult: Equatable, Sendable {
    public let manifestSHA256: String
    public let releasedBytes: Int64
}

struct ArchiveSourceReclaimerTestHooks: Sendable {
    let afterPlan: (@Sendable (URL) throws -> Void)?
    let afterRename: (@Sendable (URL) throws -> Void)?
    let afterDeletePlan: (@Sendable (URL) throws -> Void)?
    let fsyncDirectory: (@Sendable (URL) throws -> Void)?

    init(
        afterPlan: (@Sendable (URL) throws -> Void)? = nil,
        afterRename: (@Sendable (URL) throws -> Void)? = nil,
        afterDeletePlan: (@Sendable (URL) throws -> Void)? = nil,
        fsyncDirectory: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.afterPlan = afterPlan
        self.afterRename = afterRename
        self.afterDeletePlan = afterDeletePlan
        self.fsyncDirectory = fsyncDirectory
    }
}

public struct ArchiveSourceReclaimer: Sendable {
    public static let maximumSourceBytes: Int64 = 256 * 1_024 * 1_024

    private let catalog: ArchiveCatalog
    private let testHooks: ArchiveSourceReclaimerTestHooks

    public init(catalog: ArchiveCatalog) {
        self.init(catalog: catalog, testHooks: ArchiveSourceReclaimerTestHooks())
    }

    init(catalog: ArchiveCatalog, testHooks: ArchiveSourceReclaimerTestHooks) {
        self.catalog = catalog
        self.testHooks = testHooks
    }

    public func planAndReclaim(
        intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        try validateIdentity(intent: intent, capture: capture)
        switch intent.phase {
        case .eligible:
            return try plan(intent: intent, capture: capture)
        case .quarantinePlanned, .sourceQuarantined, .sourceDeletePlanned:
            return try recover(intent: intent, capture: capture)
        default:
            throw ArchiveSourceReclaimerError.staleIntent
        }
    }

    public func recover(
        intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        try validateIdentity(intent: intent, capture: capture)
        guard let quarantineURL = try quarantineURL(for: intent) else {
            throw ArchiveSourceReclaimerError.invalidIntent
        }
        let sourceURL = URL(fileURLWithPath: intent.locator)
        switch intent.phase {
        case .quarantinePlanned:
            let sourceExists = pathExists(sourceURL)
            let quarantineExists = pathExists(quarantineURL)
            switch (sourceExists, quarantineExists) {
            case (true, false):
                do {
                    try verifySource(sourceURL, capture: capture)
                } catch {
                    try pause(intent, error: "generation_changed")
                    throw error
                }
                try renameExclusive(sourceURL, quarantineURL)
                try syncParent(of: sourceURL)
                try testHooks.afterRename?(quarantineURL)
                let quarantined = try transition(
                    intent,
                    to: .sourceQuarantined,
                    quarantinePath: quarantineURL.path
                )
                return try finish(quarantined, capture: capture)
            case (false, true):
                try syncParent(of: quarantineURL)
                let quarantined = try transition(
                    intent,
                    to: .sourceQuarantined,
                    quarantinePath: quarantineURL.path
                )
                return try finish(quarantined, capture: capture)
            default:
                try pause(intent, error: "quarantine_collision")
                throw ArchiveSourceReclaimerError.pathCollision
            }
        case .sourceQuarantined:
            guard !pathExists(sourceURL), pathExists(quarantineURL) else {
                try pause(intent, error: "quarantine_collision")
                throw ArchiveSourceReclaimerError.pathCollision
            }
            return try finish(intent, capture: capture)
        case .sourceDeletePlanned:
            guard !pathExists(sourceURL) else {
                try pause(intent, error: "quarantine_collision")
                throw ArchiveSourceReclaimerError.pathCollision
            }
            if pathExists(quarantineURL) {
                return try finishDeletePlanned(intent, capture: capture)
            }
            try syncParent(of: quarantineURL)
            return try commitDeleted(intent, capture: capture)
        default:
            throw ArchiveSourceReclaimerError.staleIntent
        }
    }

    private func plan(
        intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        guard capture.rawByteCount <= Self.maximumSourceBytes else {
            try pause(intent, error: "source_too_large")
            throw ArchiveSourceReclaimerError.sourceTooLarge
        }
        let sourceURL = URL(fileURLWithPath: intent.locator)
        try verifySource(sourceURL, capture: capture)
        let quarantineURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".engram-reclaim-\(String(intent.manifestSHA256.prefix(16)))-\(UUID().uuidString.lowercased())"
        )
        let planned = try transition(
            intent,
            to: .quarantinePlanned,
            quarantinePath: quarantineURL.path
        )
        try testHooks.afterPlan?(quarantineURL)
        try renameExclusive(sourceURL, quarantineURL)
        try syncParent(of: sourceURL)
        try testHooks.afterRename?(quarantineURL)
        let quarantined = try transition(
            planned,
            to: .sourceQuarantined,
            quarantinePath: quarantineURL.path
        )
        return try finish(quarantined, capture: capture)
    }

    private func finish(
        _ intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        guard let quarantineURL = try quarantineURL(for: intent) else {
            throw ArchiveSourceReclaimerError.invalidIntent
        }
        let verified: VerifiedFile
        do {
            verified = try openVerifiedSource(quarantineURL, capture: capture)
            try Task.checkCancellation()
        } catch is CancellationError {
            try restoreOrPause(intent, quarantineURL: quarantineURL, error: "cancelled")
            throw CancellationError()
        } catch {
            try restoreOrPause(intent, quarantineURL: quarantineURL, error: "generation_changed")
            throw ArchiveSourceReclaimerError.generationChanged
        }
        defer { _ = Darwin.close(verified.fd) }
        let deletePlanned = try transition(
            intent,
            to: .sourceDeletePlanned,
            quarantinePath: quarantineURL.path
        )
        try testHooks.afterDeletePlan?(quarantineURL)
        do {
            try revalidate(verified, at: quarantineURL)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try restoreOrPause(deletePlanned, quarantineURL: quarantineURL, error: "generation_changed")
            throw ArchiveSourceReclaimerError.generationChanged
        }
        return try unlinkAndCommit(deletePlanned, quarantineURL: quarantineURL, capture: capture)
    }

    private func finishDeletePlanned(
        _ intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        guard let quarantineURL = try quarantineURL(for: intent) else {
            throw ArchiveSourceReclaimerError.invalidIntent
        }
        let verified = try openVerifiedSource(quarantineURL, capture: capture)
        defer { _ = Darwin.close(verified.fd) }
        try revalidate(verified, at: quarantineURL)
        try Task.checkCancellation()
        return try unlinkAndCommit(intent, quarantineURL: quarantineURL, capture: capture)
    }

    private func unlinkAndCommit(
        _ intent: ArchiveReclamationIntent,
        quarantineURL: URL,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        guard Darwin.unlink(quarantineURL.path) == 0 else {
            let code = errno
            throw ArchiveSourceReclaimerError.ioFailure(operation: "unlink", code: code)
        }
        try syncParent(of: quarantineURL)
        return try commitDeleted(intent, capture: capture)
    }

    private func commitDeleted(
        _ intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws -> ArchiveSourceReclaimResult {
        let deleted = try transition(intent, to: .sourceDeleted, quarantinePath: nil,
                                     releasedSourceBytes: capture.rawByteCount)
        return ArchiveSourceReclaimResult(
            manifestSHA256: deleted.manifestSHA256,
            releasedBytes: capture.rawByteCount
        )
    }

    private func restoreOrPause(
        _ intent: ArchiveReclamationIntent,
        quarantineURL: URL,
        error: String
    ) throws {
        let sourceURL = URL(fileURLWithPath: intent.locator)
        if !pathExists(sourceURL) {
            do {
                try renameExclusive(quarantineURL, sourceURL)
                try syncParent(of: sourceURL)
            } catch {
                try pause(intent, error: "quarantine_collision")
                throw ArchiveSourceReclaimerError.pathCollision
            }
        }
        try pause(intent, error: pathExists(sourceURL) && pathExists(quarantineURL)
            ? "quarantine_collision"
            : error)
    }

    private func validateIdentity(
        intent: ArchiveReclamationIntent,
        capture: ArchiveCapture
    ) throws {
        guard intent.captureID == capture.captureID,
              intent.locator == capture.locator,
              capture.rawByteCount >= 0 else {
            throw ArchiveSourceReclaimerError.invalidIntent
        }
        let sourceURL = URL(fileURLWithPath: intent.locator)
        guard sourceURL.path == intent.locator,
              sourceURL.path.hasPrefix("/"),
              !intent.locator.utf8.contains(0) else {
            throw ArchiveSourceReclaimerError.unsafePath
        }
    }

    private func quarantineURL(for intent: ArchiveReclamationIntent) throws -> URL? {
        guard let path = intent.quarantinePath else { return nil }
        let sourceURL = URL(fileURLWithPath: intent.locator)
        let quarantineURL = URL(fileURLWithPath: path)
        guard quarantineURL.path == path,
              quarantineURL.deletingLastPathComponent().path
                == sourceURL.deletingLastPathComponent().path,
              quarantineURL.lastPathComponent.hasPrefix(".engram-reclaim-") else {
            throw ArchiveSourceReclaimerError.unsafePath
        }
        return quarantineURL
    }

    private func verifySource(_ url: URL, capture: ArchiveCapture) throws {
        guard capture.rawByteCount <= Self.maximumSourceBytes else {
            throw ArchiveSourceReclaimerError.sourceTooLarge
        }
        let verified = try openVerifiedSource(url, capture: capture)
        _ = Darwin.close(verified.fd)
    }

    private struct VerifiedFile {
        let fd: Int32
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mtime: timespec
        let mode: mode_t
    }

    private func openVerifiedSource(
        _ url: URL,
        capture: ArchiveCapture
    ) throws -> VerifiedFile {
        guard capture.rawByteCount <= Self.maximumSourceBytes else {
            throw ArchiveSourceReclaimerError.sourceTooLarge
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw ArchiveSourceReclaimerError.generationChanged
        }
        var transferOwnership = false
        defer {
            if !transferOwnership { _ = Darwin.close(fd) }
        }
        var before = stat()
        var pathBefore = stat()
        guard Darwin.fstat(fd, &before) == 0,
              Darwin.lstat(url.path, &pathBefore) == 0,
              Self.matchesStableIdentity(before, pathBefore),
              Self.matchesCapture(before, capture.generation) else {
            throw ArchiveSourceReclaimerError.generationChanged
        }
        var hasher = SHA256()
        var remaining = Int64(before.st_size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while remaining > 0 {
            try Task.checkCancellation()
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ArchiveSourceReclaimerError.generationChanged
            }
            hasher.update(data: Data(buffer[0..<count]))
            remaining -= Int64(count)
        }
        try Task.checkCancellation()
        var after = stat()
        var pathAfter = stat()
        guard Darwin.fstat(fd, &after) == 0,
              Darwin.lstat(url.path, &pathAfter) == 0,
              Self.matchesStableIdentity(before, after),
              Self.matchesStableIdentity(after, pathAfter),
              Self.hexDigest(hasher.finalize()) == capture.wholeSourceSHA256 else {
            throw ArchiveSourceReclaimerError.generationChanged
        }
        transferOwnership = true
        return VerifiedFile(
            fd: fd,
            device: after.st_dev,
            inode: after.st_ino,
            size: after.st_size,
            mtime: after.st_mtimespec,
            mode: after.st_mode
        )
    }

    private func revalidate(_ verified: VerifiedFile, at url: URL) throws {
        var descriptor = stat()
        var path = stat()
        guard Darwin.fstat(verified.fd, &descriptor) == 0,
              Darwin.lstat(url.path, &path) == 0,
              descriptor.st_dev == verified.device,
              descriptor.st_ino == verified.inode,
              descriptor.st_size == verified.size,
              Self.nanoseconds(descriptor.st_mtimespec) == Self.nanoseconds(verified.mtime),
              descriptor.st_mode == verified.mode,
              Self.matchesStableIdentity(descriptor, path) else {
            throw ArchiveSourceReclaimerError.generationChanged
        }
    }

    private func transition(
        _ intent: ArchiveReclamationIntent,
        to phase: ArchiveReclamationPhase,
        quarantinePath: String?,
        releasedSourceBytes: Int64? = nil
    ) throws -> ArchiveReclamationIntent {
        guard try catalog.transitionReclamationIntent(
            manifestSHA256: intent.manifestSHA256,
            from: intent.phase,
            to: phase,
            expectedClaimGeneration: intent.claimGeneration,
            quarantinePath: quarantinePath,
            updatedAt: Self.timestamp(),
            releasedSourceBytes: releasedSourceBytes
        ), let updated = try catalog.reclamationIntent(
            manifestSHA256: intent.manifestSHA256
        ) else {
            throw ArchiveSourceReclaimerError.staleIntent
        }
        return updated
    }

    private func pause(_ intent: ArchiveReclamationIntent, error: String) throws {
        guard try catalog.transitionReclamationIntent(
            manifestSHA256: intent.manifestSHA256,
            from: intent.phase,
            to: .paused,
            expectedClaimGeneration: intent.claimGeneration,
            quarantinePath: intent.quarantinePath,
            updatedAt: Self.timestamp(),
            lastError: error
        ) else {
            throw ArchiveSourceReclaimerError.staleIntent
        }
    }

    private func syncParent(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if let hook = testHooks.fsyncDirectory {
            try hook(parent)
            return
        }
        let fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ArchiveSourceReclaimerError.ioFailure(operation: "open-parent", code: errno)
        }
        defer { _ = Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else {
            throw ArchiveSourceReclaimerError.ioFailure(operation: "fsync-parent", code: errno)
        }
    }

    private func renameExclusive(_ source: URL, _ destination: URL) throws {
        guard Darwin.renameatx_np(
            AT_FDCWD,
            source.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            if code == EEXIST { throw ArchiveSourceReclaimerError.pathCollision }
            throw ArchiveSourceReclaimerError.ioFailure(operation: "rename", code: code)
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return Darwin.lstat(url.path, &info) == 0
    }

    private static func matchesCapture(
        _ info: stat,
        _ expected: ArchiveSourceGeneration
    ) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && Int64(info.st_dev) == expected.device
            && Int64(info.st_ino) == expected.inode
            && Int64(info.st_size) == expected.size
            && nanoseconds(info.st_mtimespec) == expected.mtimeNs
            && Int64(info.st_mode) == expected.mode
    }

    private static func matchesStableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        (lhs.st_mode & S_IFMT) == S_IFREG
            && (rhs.st_mode & S_IFMT) == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && nanoseconds(lhs.st_mtimespec) == nanoseconds(rhs.st_mtimespec)
            && lhs.st_mode == rhs.st_mode
    }

    private static func nanoseconds(_ value: timespec) -> Int64? {
        let (seconds, multiplyOverflow) = Int64(value.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = seconds.addingReportingOverflow(Int64(value.tv_nsec))
        return multiplyOverflow || addOverflow ? nil : result
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
