import Foundation

/// Batch project move. Optional `operationId` enables cooperative cancel via
/// `cancelProjectMoveBatch` between operations (Wave 7C M05).
struct EngramServiceProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let yaml: String
    let dryRun: Bool
    let force: Bool
    let actor: String?
    let operationId: String?

    init(yaml: String, dryRun: Bool, force: Bool, actor: String?, operationId: String? = nil) {
        self.yaml = yaml
        self.dryRun = dryRun
        self.force = force
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case yaml
        case dryRun = "dry_run"
        case force
        case actor
        case operationId = "operation_id"
    }
}

struct EngramServiceCancelProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let operationId: String

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
    }
}

struct EngramServiceCancelProjectMoveBatchResponse: Codable, Equatable, Sendable {
    let accepted: Bool
}

struct EngramServiceProjectMigrationsRequest: Codable, Equatable, Sendable {
    let state: String?
    let limit: Int
}

struct EngramServiceProjectMigrationsResponse: Codable, Equatable, Sendable {
    let migrations: [EngramServiceMigrationLogEntry]
}

struct EngramServiceMigrationLogEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let oldPath: String
    let newPath: String
    let oldBasename: String
    let newBasename: String
    let state: String
    let startedAt: String
    let finishedAt: String?
    let archived: Bool
    let auditNote: String?
    let actor: String
    let detail: [String: EngramServiceJSONValue]?
}

struct EngramServiceProjectCwdsRequest: Codable, Equatable, Sendable {
    let project: String
}

struct EngramServiceProjectCwdsResponse: Codable, Equatable, Sendable {
    let project: String
    let cwds: [String]
}

struct EngramServiceProjectMoveRequest: Codable, Equatable, Sendable {
    let src: String
    let dst: String
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        src: String,
        dst: String,
        dryRun: Bool,
        force: Bool,
        auditNote: String?,
        actor: String?,
        operationId: String? = nil
    ) {
        self.src = src
        self.dst = dst
        self.dryRun = dryRun
        self.force = force
        self.auditNote = auditNote
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case src, dst, force, actor
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceProjectArchiveRequest: Codable, Equatable, Sendable {
    let src: String
    let archiveTo: String?
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        src: String,
        archiveTo: String?,
        dryRun: Bool,
        force: Bool,
        auditNote: String?,
        actor: String?,
        operationId: String? = nil
    ) {
        self.src = src
        self.archiveTo = archiveTo
        self.dryRun = dryRun
        self.force = force
        self.auditNote = auditNote
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case src, force, actor
        case archiveTo = "archive_to"
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceProjectUndoRequest: Codable, Equatable, Sendable {
    let migrationId: String
    let force: Bool
    let actor: String?
    /// Stable client operation id for cancel/reconnect/idempotence (Wave 8 long-ops).
    let operationId: String?

    init(
        migrationId: String,
        force: Bool,
        actor: String?,
        operationId: String? = nil
    ) {
        self.migrationId = migrationId
        self.force = force
        self.actor = actor
        self.operationId = operationId
    }

    enum CodingKeys: String, CodingKey {
        case force, actor
        case migrationId = "migration_id"
        case operationId = "operation_id"
    }
}

struct EngramServiceProjectMoveResult: Codable, Equatable, Sendable {
    struct ReviewBlock: Codable, Equatable, Sendable {
        let own: [String]
        let other: [String]
    }

    struct ManifestEntry: Codable, Equatable, Identifiable, Sendable {
        let path: String
        let occurrences: Int
        var id: String { path }
    }

    struct PerSource: Codable, Equatable, Identifiable, Sendable {
        struct WalkIssue: Codable, Equatable, Sendable, Identifiable {
            let path: String
            let reason: String
            let detail: String?
            var id: String { "\(reason)::\(path)" }
        }

        let id: String
        let root: String
        let filesPatched: Int
        let occurrences: Int
        let issues: [WalkIssue]?
    }

    struct SkippedDir: Codable, Equatable, Identifiable, Sendable {
        let sourceId: String
        let reason: String
        let dir: String?
        var id: String { "\(sourceId)::\(dir ?? reason)" }
    }

    struct ArchiveSuggestion: Codable, Equatable, Sendable {
        let category: String?
        let dst: String
        let reason: String
    }

    let migrationId: String
    let state: String
    let moveStrategy: String?
    let ccDirRenamed: Bool
    let renamedDirs: [String]?
    let totalFilesPatched: Int
    let totalOccurrences: Int
    let sessionsUpdated: Int
    let aliasCreated: Bool
    let review: ReviewBlock
    let git: GitStatus?
    let manifest: [ManifestEntry]?
    let perSource: [PerSource]?
    let skippedDirs: [SkippedDir]?
    let suggestion: ArchiveSuggestion?

    private enum CodingKeys: String, CodingKey {
        case migrationId
        case state
        case moveStrategy
        case ccDirRenamed
        case renamedDirs
        case totalFilesPatched
        case totalOccurrences
        case sessionsUpdated
        case aliasCreated
        case review
        case git
        case manifest
        case perSource
        case skippedDirs
        case suggestion
        case archive
    }

    init(
        migrationId: String,
        state: String,
        moveStrategy: String? = nil,
        ccDirRenamed: Bool,
        renamedDirs: [String]? = nil,
        totalFilesPatched: Int,
        totalOccurrences: Int,
        sessionsUpdated: Int,
        aliasCreated: Bool,
        review: ReviewBlock,
        git: GitStatus? = nil,
        manifest: [ManifestEntry]? = nil,
        perSource: [PerSource]? = nil,
        skippedDirs: [SkippedDir]? = nil,
        suggestion: ArchiveSuggestion? = nil
    ) {
        self.migrationId = migrationId
        self.state = state
        self.moveStrategy = moveStrategy
        self.ccDirRenamed = ccDirRenamed
        self.renamedDirs = renamedDirs
        self.totalFilesPatched = totalFilesPatched
        self.totalOccurrences = totalOccurrences
        self.sessionsUpdated = sessionsUpdated
        self.aliasCreated = aliasCreated
        self.review = review
        self.git = git
        self.manifest = manifest
        self.perSource = perSource
        self.skippedDirs = skippedDirs
        self.suggestion = suggestion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        migrationId = try container.decode(String.self, forKey: .migrationId)
        state = try container.decode(String.self, forKey: .state)
        moveStrategy = try container.decodeIfPresent(String.self, forKey: .moveStrategy)
        ccDirRenamed = try container.decode(Bool.self, forKey: .ccDirRenamed)
        renamedDirs = try container.decodeIfPresent([String].self, forKey: .renamedDirs)
        totalFilesPatched = try container.decode(Int.self, forKey: .totalFilesPatched)
        totalOccurrences = try container.decode(Int.self, forKey: .totalOccurrences)
        sessionsUpdated = try container.decode(Int.self, forKey: .sessionsUpdated)
        aliasCreated = try container.decode(Bool.self, forKey: .aliasCreated)
        review = try container.decode(ReviewBlock.self, forKey: .review)
        git = try container.decodeIfPresent(GitStatus.self, forKey: .git)
        manifest = try container.decodeIfPresent([ManifestEntry].self, forKey: .manifest)
        perSource = try container.decodeIfPresent([PerSource].self, forKey: .perSource)
        skippedDirs = try container.decodeIfPresent([SkippedDir].self, forKey: .skippedDirs)
        suggestion = try container.decodeIfPresent(ArchiveSuggestion.self, forKey: .suggestion)
            ?? container.decodeIfPresent(ArchiveSuggestion.self, forKey: .archive)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(migrationId, forKey: .migrationId)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(moveStrategy, forKey: .moveStrategy)
        try container.encode(ccDirRenamed, forKey: .ccDirRenamed)
        try container.encodeIfPresent(renamedDirs, forKey: .renamedDirs)
        try container.encode(totalFilesPatched, forKey: .totalFilesPatched)
        try container.encode(totalOccurrences, forKey: .totalOccurrences)
        try container.encode(sessionsUpdated, forKey: .sessionsUpdated)
        try container.encode(aliasCreated, forKey: .aliasCreated)
        try container.encode(review, forKey: .review)
        try container.encodeIfPresent(git, forKey: .git)
        try container.encodeIfPresent(manifest, forKey: .manifest)
        try container.encodeIfPresent(perSource, forKey: .perSource)
        try container.encodeIfPresent(skippedDirs, forKey: .skippedDirs)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
    }

    struct GitStatus: Codable, Equatable, Sendable {
        let isGitRepo: Bool
        let dirty: Bool
        let untrackedOnly: Bool
        let porcelain: String
    }
}
