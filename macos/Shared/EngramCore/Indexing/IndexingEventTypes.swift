import Foundation

public struct AuthoritativeSessionSnapshot: Equatable, Sendable {
    public var id: String
    public var source: SourceName
    public var authoritativeNode: String
    public var syncVersion: Int
    public var snapshotHash: String
    public var indexedAt: String
    public var sourceLocator: String
    public var sizeBytes: Int64?
    public var startTime: String
    public var endTime: String?
    public var cwd: String
    public var project: String?
    public var model: String?
    public var messageCount: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int
    public var toolMessageCount: Int
    public var systemMessageCount: Int
    public var summary: String?
    public var summaryMessageCount: Int?
    public var origin: String?
    public var tier: SessionTier?
    public var agentRole: String?

    public init(
        id: String,
        source: SourceName,
        authoritativeNode: String,
        syncVersion: Int,
        snapshotHash: String,
        indexedAt: String,
        sourceLocator: String,
        sizeBytes: Int64? = nil,
        startTime: String,
        endTime: String? = nil,
        cwd: String,
        project: String? = nil,
        model: String? = nil,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        toolMessageCount: Int,
        systemMessageCount: Int,
        summary: String? = nil,
        summaryMessageCount: Int? = nil,
        origin: String? = nil,
        tier: SessionTier? = nil,
        agentRole: String? = nil
    ) {
        self.id = id
        self.source = source
        self.authoritativeNode = authoritativeNode
        self.syncVersion = syncVersion
        self.snapshotHash = snapshotHash
        self.indexedAt = indexedAt
        self.sourceLocator = sourceLocator
        self.sizeBytes = sizeBytes
        self.startTime = startTime
        self.endTime = endTime
        self.cwd = cwd
        self.project = project
        self.model = model
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.toolMessageCount = toolMessageCount
        self.systemMessageCount = systemMessageCount
        self.summary = summary
        self.summaryMessageCount = summaryMessageCount
        self.origin = origin
        self.tier = tier
        self.agentRole = agentRole
    }
}

public enum ChangeFlag: String, Codable, Equatable, Sendable {
    case syncPayloadChanged = "sync_payload_changed"
    case searchTextChanged = "search_text_changed"
    case embeddingTextChanged = "embedding_text_changed"
    case localStateChanged = "local_state_changed"
}

public struct SessionChangeSet: Equatable, Sendable {
    public var flags: Set<ChangeFlag>

    public init(flags: Set<ChangeFlag>) {
        self.flags = flags
    }
}

public enum SessionWriteAction: String, Codable, Equatable, Sendable {
    case merge
    case noop
    case skipped
    case failure
}

public struct SessionWriteResult: Equatable, Sendable {
    public var action: SessionWriteAction
    public var changeSet: SessionChangeSet

    public init(action: SessionWriteAction, changeSet: SessionChangeSet) {
        self.action = action
        self.changeSet = changeSet
    }
}

public enum IndexJobKind: String, Codable, Equatable, Sendable {
    case fts
    case embedding
}

public enum IndexingWriteReason: String, Codable, Equatable, Sendable {
    case initialScan = "initial_scan"
    case fileChanged = "file_changed"
    case rescan
    case sync
}

public struct SessionBatchItemResult: Equatable, Sendable {
    public var sessionId: String
    public var action: SessionWriteAction
    public var enqueuedJobs: [IndexJobKind]
    public var error: String?

    public init(sessionId: String, action: SessionWriteAction, enqueuedJobs: [IndexJobKind], error: String? = nil) {
        self.sessionId = sessionId
        self.action = action
        self.enqueuedJobs = enqueuedJobs
        self.error = error
    }
}

public struct SessionBatchUpsertResult: Equatable, Sendable {
    public var reason: IndexingWriteReason
    public var results: [SessionBatchItemResult]

    public init(reason: IndexingWriteReason, results: [SessionBatchItemResult]) {
        self.reason = reason
        self.results = results
    }
}
