import Foundation

enum EngramServiceWebProjectValidation {
    static let operationPrefix = "web-project:"
    static let maximumBatchBytes = 256 * 1_024
    static let maximumBatchOperations = 100
    static let capturedScope = "captured"
    static let serverFilesystemScope = "serverFilesystem"
    static let maximumLocationLabelBytes = 1_024
    static let knownMigrationStates: Set<String> = [
        "fs_pending", "fs_done", "committed", "failed", "rolled_back", "dry-run", "cancelled",
    ]

    static func publishedOperationId(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(!trimmed.hasPrefix(operationPrefix))
        try EngramServiceWebMetadataValidation.uuid(trimmed)
        return trimmed
    }

    static func namespacedOperationId(_ value: String) throws -> String {
        operationPrefix + (try publishedOperationId(value))
    }

    static func confinedPath(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try EngramServiceWebMetadataValidation.require(
            !trimmed.isEmpty
                && trimmed.utf8.count <= 4_096
                && !trimmed.utf8.contains(0)
                && trimmed.hasPrefix("/")
        )
        return trimmed
    }

    static func migrationState(_ value: String?) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        try EngramServiceWebMetadataValidation.token(value, maximumBytes: 32)
        try EngramServiceWebMetadataValidation.require(knownMigrationStates.contains(value))
        return value
    }

    static func migrationLimit(_ value: Int) throws -> Int {
        try EngramServiceWebMetadataValidation.require((1...200).contains(value))
        return value
    }

    static func locationLabel(_ value: String) throws {
        try EngramServiceWebMetadataValidation.text(
            value, maximumBytes: maximumLocationLabelBytes, allowEmpty: false
        )
        try EngramServiceWebMetadataValidation.require(
            !value.contains("/") && !value.contains("\\") && !value.contains("~")
        )
    }
}

struct EngramServiceWebProjectCwdsRequest: Codable, Equatable, Sendable {
    let projectKey: String
    let limit: Int
    let snapshotId: String?
    let cursor: String?

    init(projectKey: String, limit: Int = 50, snapshotId: String? = nil, cursor: String? = nil) throws {
        try EngramServiceWebMetadataValidation.projectIdentity(projectKey)
        try EngramServiceWebMetadataValidation.pageRequest(
            limit: limit, snapshotId: snapshotId, cursor: cursor
        )
        self.projectKey = projectKey
        self.limit = limit
        self.snapshotId = snapshotId
        self.cursor = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                projectKey: try container.decode(String.self, forKey: .projectKey),
                limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
                snapshotId: try container.decodeIfPresent(String.self, forKey: .snapshotId),
                cursor: try container.decodeIfPresent(String.self, forKey: .cursor)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .projectKey, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectCwdItem: Codable, Equatable, Sendable {
    let key: String
    let label: String

    init(key: String, label: String) throws {
        try EngramServiceWebMetadataValidation.projectIdentity(key)
        try EngramServiceWebProjectValidation.locationLabel(label)
        self.key = key
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                key: try container.decode(String.self, forKey: .key),
                label: try container.decode(String.self, forKey: .label)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectCwdsResponse: Codable, Equatable, Sendable {
    let snapshotId: String
    let observedAt: Int64
    let scope: String
    let projectKey: String
    let totalCount: Int
    let items: [EngramServiceWebProjectCwdItem]
    let nextCursor: String?

    init(
        snapshotId: String,
        observedAt: Int64,
        scope: String = EngramServiceWebProjectValidation.capturedScope,
        projectKey: String,
        totalCount: Int,
        items: [EngramServiceWebProjectCwdItem],
        nextCursor: String?
    ) {
        self.snapshotId = snapshotId
        self.observedAt = observedAt
        self.scope = scope
        self.projectKey = projectKey
        self.totalCount = totalCount
        self.items = items
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            snapshotId: try container.decode(String.self, forKey: .snapshotId),
            observedAt: try container.decode(Int64.self, forKey: .observedAt),
            scope: try container.decode(String.self, forKey: .scope),
            projectKey: try container.decode(String.self, forKey: .projectKey),
            totalCount: try container.decode(Int.self, forKey: .totalCount),
            items: try container.decode([EngramServiceWebProjectCwdItem].self, forKey: .items),
            nextCursor: try container.decodeIfPresent(String.self, forKey: .nextCursor)
        )
        typealias V = EngramServiceWebMetadataValidation
        try V.page(snapshotId: snapshotId, count: items.count, nextCursor: nextCursor)
        try V.time(observedAt)
        try V.count(Int64(totalCount))
        try V.projectIdentity(projectKey)
        try V.require(scope.utf8.elementsEqual(EngramServiceWebProjectValidation.capturedScope.utf8))
        try V.require(totalCount >= items.count && Set(items.map { Data($0.key.utf8) }).count == items.count)
    }
}

struct EngramServiceWebProjectMigrationsRequest: Codable, Equatable, Sendable {
    let state: String?
    let limit: Int

    init(state: String? = nil, limit: Int = 50) throws {
        self.state = try EngramServiceWebProjectValidation.migrationState(state)
        self.limit = try EngramServiceWebProjectValidation.migrationLimit(limit)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                state: try container.decodeIfPresent(String.self, forKey: .state),
                limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 50
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .limit, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectMigrationsResponse: Codable, Equatable, Sendable {
    let scope: String
    let migrations: [EngramServiceMigrationLogEntry]

    init(
        scope: String = EngramServiceWebProjectValidation.serverFilesystemScope,
        migrations: [EngramServiceMigrationLogEntry]
    ) throws {
        try EngramServiceWebMetadataValidation.require(
            scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8)
        )
        try EngramServiceWebMetadataValidation.require(migrations.count <= 200)
        self.scope = scope
        self.migrations = migrations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                scope: try container.decode(String.self, forKey: .scope),
                migrations: try container.decode([EngramServiceMigrationLogEntry].self, forKey: .migrations)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .scope, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectMoveRequest: Codable, Equatable, Sendable {
    let src: String
    let dst: String
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let operationId: String

    init(
        src: String,
        dst: String,
        dryRun: Bool,
        force: Bool = false,
        auditNote: String? = nil,
        operationId: String
    ) throws {
        self.src = try EngramServiceWebProjectValidation.confinedPath(src, label: "source")
        self.dst = try EngramServiceWebProjectValidation.confinedPath(dst, label: "destination")
        self.dryRun = dryRun
        self.force = force
        self.auditNote = try auditNote.map(Self.note)
        self.operationId = try EngramServiceWebProjectValidation.publishedOperationId(operationId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                src: try container.decode(String.self, forKey: .src),
                dst: try container.decode(String.self, forKey: .dst),
                dryRun: try container.decode(Bool.self, forKey: .dryRun),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false,
                auditNote: try container.decodeIfPresent(String.self, forKey: .auditNote),
                operationId: try container.decode(String.self, forKey: .operationId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .src, in: container, debugDescription: "invalid"
            )
        }
    }

    private static func note(_ value: String) throws -> String {
        try EngramServiceWebMetadataValidation.trimmed(value, maximumBytes: 512)
        return value
    }

    enum CodingKeys: String, CodingKey {
        case src, dst, force
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceWebProjectArchiveRequest: Codable, Equatable, Sendable {
    let src: String
    let archiveTo: String?
    let dryRun: Bool
    let force: Bool
    let auditNote: String?
    let operationId: String

    init(
        src: String,
        archiveTo: String? = nil,
        dryRun: Bool,
        force: Bool = false,
        auditNote: String? = nil,
        operationId: String
    ) throws {
        self.src = try EngramServiceWebProjectValidation.confinedPath(src, label: "source")
        self.archiveTo = try archiveTo.map {
            try EngramServiceWebMetadataValidation.trimmed($0, maximumBytes: 128)
            return $0
        }
        self.dryRun = dryRun
        self.force = force
        self.auditNote = try auditNote.map {
            try EngramServiceWebMetadataValidation.trimmed($0, maximumBytes: 512)
            return $0
        }
        self.operationId = try EngramServiceWebProjectValidation.publishedOperationId(operationId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                src: try container.decode(String.self, forKey: .src),
                archiveTo: try container.decodeIfPresent(String.self, forKey: .archiveTo),
                dryRun: try container.decode(Bool.self, forKey: .dryRun),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false,
                auditNote: try container.decodeIfPresent(String.self, forKey: .auditNote),
                operationId: try container.decode(String.self, forKey: .operationId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .src, in: container, debugDescription: "invalid"
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case src, force
        case archiveTo = "archive_to"
        case dryRun = "dry_run"
        case auditNote = "audit_note"
        case operationId = "operation_id"
    }
}

struct EngramServiceWebProjectUndoRequest: Codable, Equatable, Sendable {
    let migrationId: String
    let force: Bool
    let operationId: String

    init(migrationId: String, force: Bool = false, operationId: String) throws {
        try EngramServiceWebMetadataValidation.trimmed(migrationId, maximumBytes: 128)
        self.migrationId = migrationId
        self.force = force
        self.operationId = try EngramServiceWebProjectValidation.publishedOperationId(operationId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                migrationId: try container.decode(String.self, forKey: .migrationId),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false,
                operationId: try container.decode(String.self, forKey: .operationId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .migrationId, in: container, debugDescription: "invalid"
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case force
        case migrationId = "migration_id"
        case operationId = "operation_id"
    }
}

struct EngramServiceWebProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let yaml: String
    let dryRun: Bool
    let force: Bool
    let operationId: String

    init(yaml: String, dryRun: Bool, force: Bool = false, operationId: String) throws {
        try EngramServiceWebMetadataValidation.require(
            !yaml.isEmpty
                && yaml.utf8.count <= EngramServiceWebProjectValidation.maximumBatchBytes
                && !yaml.utf8.contains(0)
        )
        self.yaml = yaml
        self.dryRun = dryRun
        self.force = force
        self.operationId = try EngramServiceWebProjectValidation.publishedOperationId(operationId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                yaml: try container.decode(String.self, forKey: .yaml),
                dryRun: try container.decode(Bool.self, forKey: .dryRun),
                force: try container.decodeIfPresent(Bool.self, forKey: .force) ?? false,
                operationId: try container.decode(String.self, forKey: .operationId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .yaml, in: container, debugDescription: "invalid"
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case yaml, force
        case dryRun = "dry_run"
        case operationId = "operation_id"
    }
}

struct EngramServiceWebCancelProjectMoveBatchRequest: Codable, Equatable, Sendable {
    let operationId: String

    init(operationId: String) throws {
        self.operationId = try EngramServiceWebProjectValidation.publishedOperationId(operationId)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(operationId: try container.decode(String.self, forKey: .operationId))
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .operationId, in: container, debugDescription: "invalid"
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
    }
}

struct EngramServiceWebProjectMoveResponse: Codable, Equatable, Sendable {
    let scope: String
    let operationId: String
    let result: EngramServiceProjectMoveResult

    init(
        scope: String = EngramServiceWebProjectValidation.serverFilesystemScope,
        operationId: String,
        result: EngramServiceProjectMoveResult
    ) throws {
        try EngramServiceWebMetadataValidation.require(
            scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8)
        )
        try EngramServiceWebMetadataValidation.uuid(operationId)
        self.scope = scope
        self.operationId = operationId
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                scope: try container.decode(String.self, forKey: .scope),
                operationId: try container.decode(String.self, forKey: .operationId),
                result: try container.decode(EngramServiceProjectMoveResult.self, forKey: .result)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .scope, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectMoveBatchResponse: Codable, Equatable, Sendable {
    let scope: String
    let operationId: String
    let result: EngramServiceJSONValue

    init(
        scope: String = EngramServiceWebProjectValidation.serverFilesystemScope,
        operationId: String,
        result: EngramServiceJSONValue
    ) throws {
        try EngramServiceWebMetadataValidation.require(
            scope.utf8.elementsEqual(EngramServiceWebProjectValidation.serverFilesystemScope.utf8)
        )
        try EngramServiceWebMetadataValidation.uuid(operationId)
        self.scope = scope
        self.operationId = operationId
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                scope: try container.decode(String.self, forKey: .scope),
                operationId: try container.decode(String.self, forKey: .operationId),
                result: try container.decode(EngramServiceJSONValue.self, forKey: .result)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .scope, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebCancelProjectMoveBatchResponse: Codable, Equatable, Sendable {
    let accepted: Bool
    let operationId: String

    init(accepted: Bool, operationId: String) throws {
        try EngramServiceWebMetadataValidation.uuid(operationId)
        self.accepted = accepted
        self.operationId = operationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            self = try Self(
                accepted: try container.decode(Bool.self, forKey: .accepted),
                operationId: try container.decode(String.self, forKey: .operationId)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .operationId, in: container, debugDescription: "invalid"
            )
        }
    }
}

struct EngramServiceWebProjectFailure: Codable, Equatable, Sendable {
    let category: String
    let retry: String
    let message: String

    static func parse(
        name: String,
        message: String,
        retryPolicy: String?
    ) -> EngramServiceWebProjectFailure? {
        let category: String
        let retry: String
        switch name {
        case "WebProjectConfinement":
            category = "confinement"
            retry = "never"
        case "WebProjectInvalid":
            category = "invalid"
            retry = "never"
        case "WebProjectConflict":
            category = "conflict"
            retry = "never"
        case "WebProjectCancelled":
            category = "cancelled"
            retry = "never"
        case "WebProjectCapacity":
            category = "capacity"
            retry = "later"
        case "WebProjectUnavailable":
            category = "unavailable"
            retry = "later"
        default:
            return nil
        }
        return EngramServiceWebProjectFailure(
            category: category,
            retry: retryPolicy ?? retry,
            message: message
        )
    }
}
