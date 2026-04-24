import Foundation
import EngramCoreRead

public protocol WatcherClock: AnyObject {
    var nowMilliseconds: Int { get }
}

public final class SystemWatcherClock: WatcherClock {
    public init() {}

    public var nowMilliseconds: Int {
        Int(Date().timeIntervalSince1970 * 1_000)
    }
}

public struct WatchIndexRequest: Equatable, Hashable, Sendable {
    public var source: SourceName
    public var path: String

    public init(source: SourceName, path: String) {
        self.source = source
        self.path = path
    }
}

public struct SessionWatchIndexResult: Equatable, Sendable {
    public var indexed: Bool
    public var sessionId: String?
    public var messageCount: Int?
    public var tier: SessionTier?

    public init(indexed: Bool, sessionId: String? = nil, messageCount: Int? = nil, tier: SessionTier? = nil) {
        self.indexed = indexed
        self.sessionId = sessionId
        self.messageCount = messageCount
        self.tier = tier
    }
}

public enum SessionWatchOrphanReason: String, Equatable, Sendable {
    case cleanedBySource = "cleaned_by_source"
    case fileDeleted = "file_deleted"
}

public enum SessionWatchFileEvent: Equatable, Sendable {
    case added(path: String, sizeBytes: Int64, modifiedAtMilliseconds: Int)
    case changed(path: String, sizeBytes: Int64, modifiedAtMilliseconds: Int)
    case unlinked(path: String)
    case directoryRenamed(oldPath: String, newPath: String)
    case symlinkTargetChanged(path: String)
}

public enum SessionWatchEvent: Equatable, Sendable {
    case indexed(path: String, source: SourceName, sessionId: String?)
    case orphaned(path: String, sessions: Int)
    case subtreeRescan(path: String, source: SourceName)
}

public protocol SessionWatchIndexing: AnyObject {
    func indexFile(source: SourceName, path: String) async throws -> SessionWatchIndexResult
    func rescanSubtree(source: SourceName, root: String) async throws
}

public protocol SessionWatchOrphanMarking: AnyObject {
    func markOrphanByPath(_ path: String, reason: SessionWatchOrphanReason) throws -> Int
}

public final class SessionWatcher {
    private struct PendingPath {
        var path: String
        var source: SourceName
        var sizeBytes: Int64
        var modifiedAtMilliseconds: Int
        var readyAtMilliseconds: Int
        var sequence: Int
    }

    private let home: String
    private let indexer: any SessionWatchIndexing
    private let orphanMarker: any SessionWatchOrphanMarking
    private let shouldSkip: (String) -> Bool
    private let clock: any WatcherClock
    private let config: WatchBatchConfig
    private var pending: [String: PendingPath] = [:]
    private var nextSequence = 0

    public init(
        home: String = NSHomeDirectory(),
        indexer: any SessionWatchIndexing,
        orphanMarker: any SessionWatchOrphanMarking,
        shouldSkip: @escaping (String) -> Bool = { _ in false },
        clock: any WatcherClock = SystemWatcherClock(),
        config: WatchBatchConfig = WatchBatchConfig()
    ) {
        self.home = home
        self.indexer = indexer
        self.orphanMarker = orphanMarker
        self.shouldSkip = shouldSkip
        self.clock = clock
        self.config = config
    }

    @discardableResult
    public func observe(_ event: SessionWatchFileEvent) async throws -> [SessionWatchEvent] {
        switch event {
        case .added(let path, let sizeBytes, let modifiedAtMilliseconds),
             .changed(let path, let sizeBytes, let modifiedAtMilliseconds):
            enqueueStablePath(path: path, sizeBytes: sizeBytes, modifiedAtMilliseconds: modifiedAtMilliseconds)
            return []
        case .unlinked(let path):
            pending.removeValue(forKey: path)
            guard !shouldSkip(path) else { return [] }
            let touched = try orphanMarker.markOrphanByPath(path, reason: .cleanedBySource)
            return touched > 0 ? [.orphaned(path: path, sessions: touched)] : []
        case .directoryRenamed(_, let newPath):
            guard !shouldSkip(newPath),
                  !WatchPathRules.isIgnored(newPath),
                  let source = WatchPathRules.source(for: newPath, home: home)
            else {
                return []
            }
            try await indexer.rescanSubtree(source: source, root: newPath)
            return [.subtreeRescan(path: newPath, source: source)]
        case .symlinkTargetChanged:
            return []
        }
    }

    @discardableResult
    public func drainReady() async throws -> [SessionWatchEvent] {
        let ready = pending.values
            .filter { $0.readyAtMilliseconds <= clock.nowMilliseconds }
            .sorted { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.path < rhs.path
                }
                return lhs.sequence < rhs.sequence
            }
            .prefix(config.maxDrainBatchSize)

        var events: [SessionWatchEvent] = []
        for item in ready {
            pending.removeValue(forKey: item.path)
            guard !shouldSkip(item.path) else { continue }
            let result = try await indexer.indexFile(source: item.source, path: item.path)
            if result.indexed {
                events.append(.indexed(path: item.path, source: item.source, sessionId: result.sessionId))
            }
        }
        return events
    }

    private func enqueueStablePath(path: String, sizeBytes: Int64, modifiedAtMilliseconds: Int) {
        guard !shouldSkip(path),
              !WatchPathRules.isIgnored(path),
              let source = WatchPathRules.source(for: path, home: home)
        else {
            return
        }

        if let existing = pending[path] {
            pending[path] = PendingPath(
                path: path,
                source: source,
                sizeBytes: sizeBytes,
                modifiedAtMilliseconds: modifiedAtMilliseconds,
                readyAtMilliseconds: clock.nowMilliseconds + config.writeStabilityMilliseconds,
                sequence: existing.sequence
            )
        } else {
            pending[path] = PendingPath(
                path: path,
                source: source,
                sizeBytes: sizeBytes,
                modifiedAtMilliseconds: modifiedAtMilliseconds,
                readyAtMilliseconds: clock.nowMilliseconds + config.writeStabilityMilliseconds,
                sequence: nextSequence
            )
            nextSequence += 1
        }
    }
}
