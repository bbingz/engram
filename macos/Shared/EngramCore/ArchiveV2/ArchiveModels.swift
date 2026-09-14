import Foundation

public enum ArchiveV2ValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidValue(field: String)
    case invalidSHA256(field: String)
    case nonContiguousChunkOrdinal(expected: Int, actual: Int)
    case invalidChunkSize(expected: Int64, actual: Int64)
    case invalidChunkRawByteCount(ordinal: Int)
    case rawByteCountOverflow
    case aggregateRawByteCountMismatch(expected: Int64, actual: Int64)
    case generationSizeMismatch(expected: Int64, actual: Int64)
    case invalidReplayPathCount(expected: Int, actual: Int)
    case invalidReplayPath(String)
    case duplicateReplayPath(String)
    case receiptRequiresSessionID
    case receiptRequiresBoundManifest
    case receiptManifestMismatch(field: String)
}

public enum ArchiveV2ProtocolValidationError: Error, Equatable, Sendable {
    case invalidPageLimit
    case invalidCursor
    case tooManyPageItems
    case invalidMachineID
    case invalidReceiptSummary(field: String)
    case pageItemsNotStrictlyOrdered
    case emptyNonTerminalPage
}

public enum ArchiveV2ProtocolLimits {
    public static let maxObjectRawBytes = 8 * 1024 * 1024
    public static let maxManifestBytes = 1024 * 1024
    public static let maxReceiptBytes = 16 * 1024
    public static let maxPageBytes = 256 * 1024
    public static let maxCursorBytes = 256
    public static let maxErrorBytes = 4 * 1024
    public static let maxServerIDBytes = 128
    public static let defaultPageLimit = 50
    public static let maxPageItems = 100

    public static func validatedPageLimit(_ rawValue: String?) throws -> Int {
        guard let rawValue else { return defaultPageLimit }
        guard !rawValue.isEmpty,
              let value = Int(rawValue),
              String(value) == rawValue,
              (1...maxPageItems).contains(value) else {
            throw ArchiveV2ProtocolValidationError.invalidPageLimit
        }
        return value
    }

    public static func validateCursor(_ cursor: String?) throws {
        guard let cursor else { return }
        guard !cursor.isEmpty,
              cursor.utf8.count <= maxCursorBytes,
              cursor.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 95
              }) else {
            throw ArchiveV2ProtocolValidationError.invalidCursor
        }
    }
}

public struct ArchiveReceiptSummary: Codable, Equatable, Sendable {
    public let manifestSHA256: String
    public let receiptSHA256: String

    public init(manifestSHA256: String, receiptSHA256: String) throws {
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveV2ProtocolValidationError.invalidReceiptSummary(
                field: "manifestSHA256"
            )
        }
        guard ArchiveV2Hash.isValidSHA256(receiptSHA256) else {
            throw ArchiveV2ProtocolValidationError.invalidReceiptSummary(
                field: "receiptSHA256"
            )
        }
        self.manifestSHA256 = manifestSHA256
        self.receiptSHA256 = receiptSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            receiptSHA256: container.decode(String.self, forKey: .receiptSHA256)
        )
    }
}

public struct ArchiveMachinePage: Codable, Equatable, Sendable {
    public let machineIDs: [String]
    public let nextCursor: String?

    public init(machineIDs: [String], nextCursor: String?) throws {
        try ArchiveV2ProtocolLimits.validateCursor(nextCursor)
        guard machineIDs.count <= ArchiveV2ProtocolLimits.maxPageItems else {
            throw ArchiveV2ProtocolValidationError.tooManyPageItems
        }
        guard nextCursor == nil || !machineIDs.isEmpty else {
            throw ArchiveV2ProtocolValidationError.emptyNonTerminalPage
        }
        guard machineIDs.allSatisfy({ value in
            UUID(uuidString: value)?.uuidString == value
        }) else {
            throw ArchiveV2ProtocolValidationError.invalidMachineID
        }
        guard Self.isStrictlyOrdered(machineIDs) else {
            throw ArchiveV2ProtocolValidationError.pageItemsNotStrictlyOrdered
        }
        self.machineIDs = machineIDs
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            machineIDs: container.decode([String].self, forKey: .machineIDs),
            nextCursor: container.decodeIfPresent(String.self, forKey: .nextCursor)
        )
    }

    private static func isStrictlyOrdered(_ values: [String]) -> Bool {
        zip(values, values.dropFirst()).allSatisfy(<)
    }
}

public struct ArchiveReceiptPage: Codable, Equatable, Sendable {
    public let receipts: [ArchiveReceiptSummary]
    public let nextCursor: String?

    public init(receipts: [ArchiveReceiptSummary], nextCursor: String?) throws {
        try ArchiveV2ProtocolLimits.validateCursor(nextCursor)
        guard receipts.count <= ArchiveV2ProtocolLimits.maxPageItems else {
            throw ArchiveV2ProtocolValidationError.tooManyPageItems
        }
        guard nextCursor == nil || !receipts.isEmpty else {
            throw ArchiveV2ProtocolValidationError.emptyNonTerminalPage
        }
        let manifests = receipts.map(\.manifestSHA256)
        guard zip(manifests, manifests.dropFirst()).allSatisfy(<) else {
            throw ArchiveV2ProtocolValidationError.pageItemsNotStrictlyOrdered
        }
        self.receipts = receipts
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            receipts: container.decode([ArchiveReceiptSummary].self, forKey: .receipts),
            nextCursor: container.decodeIfPresent(String.self, forKey: .nextCursor)
        )
    }
}

public enum ArchiveReplayStrategy: String, Codable, Equatable, Sendable {
    case singleFile
    case fileSet
}

public struct ArchiveFileSetEntry: Codable, Equatable, Sendable {
    public let relativePath: String
    public let byteOffset: Int64
    public let rawByteCount: Int64
    public let wholeSourceSHA256: String
    public let generation: ArchiveSourceGeneration

    public init(
        relativePath: String,
        byteOffset: Int64,
        rawByteCount: Int64,
        wholeSourceSHA256: String,
        generation: ArchiveSourceGeneration
    ) throws {
        guard ArchiveReplayLayout.isNormalizedRelativePath(relativePath),
              ArchiveReplayLayout.isBoundedRelativePath(relativePath) else {
            throw ArchiveV2ValidationError.invalidReplayPath(relativePath)
        }
        guard byteOffset >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "files.byteOffset")
        }
        guard rawByteCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "files.rawByteCount")
        }
        guard generation.mode & 0o170000 == 0o100000 else {
            throw ArchiveV2ValidationError.invalidValue(field: "files.generation.mode")
        }
        guard generation.size == rawByteCount else {
            throw ArchiveV2ValidationError.generationSizeMismatch(
                expected: generation.size,
                actual: rawByteCount
            )
        }
        guard ArchiveV2Hash.isValidSHA256(wholeSourceSHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "files.wholeSourceSHA256")
        }
        if rawByteCount == 0 {
            guard wholeSourceSHA256 == ArchiveV2Hash.sha256(Data()) else {
                throw ArchiveV2ValidationError.invalidSHA256(field: "files.wholeSourceSHA256")
            }
        }
        self.relativePath = relativePath
        self.byteOffset = byteOffset
        self.rawByteCount = rawByteCount
        self.wholeSourceSHA256 = wholeSourceSHA256
        self.generation = generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            byteOffset: container.decode(Int64.self, forKey: .byteOffset),
            rawByteCount: container.decode(Int64.self, forKey: .rawByteCount),
            wholeSourceSHA256: container.decode(String.self, forKey: .wholeSourceSHA256),
            generation: container.decode(ArchiveSourceGeneration.self, forKey: .generation)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case relativePath
        case byteOffset
        case rawByteCount
        case wholeSourceSHA256
        case generation
    }
}

/// Frozen off-tree VSCode configuration. A locator without bytes records absence;
/// no locator means workspace.json selected no external configuration. Callers
/// must fence the source generation during acquisition; replay never opens it.
public struct ArchiveVSCodeWorkspaceContext: Codable, Equatable, Sendable {
    public static let maximumContextBytes = 65_536
    public let kind: String
    public let configurationLocator: String?
    public let configurationGeneration: ArchiveSourceGeneration?
    public let configurationData: Data?
    public let configurationSHA256: String?

    public init(configurationLocator: String? = nil, configurationGeneration: ArchiveSourceGeneration? = nil,
                configurationData: Data? = nil, configurationSHA256: String? = nil) throws {
        if let configurationLocator {
            guard configurationLocator.hasPrefix("/"), configurationLocator.utf8.count <= 4096,
                  ArchiveReplayLayout.isNormalizedRelativePath(String(configurationLocator.dropFirst())) else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configurationLocator")
            }
        }
        if let configurationData, let configurationGeneration, let configurationSHA256 {
            guard configurationLocator != nil, configurationData.count <= Self.maximumContextBytes,
                  configurationGeneration.mode & 0o170000 == 0o100000,
                  configurationGeneration.size == Int64(configurationData.count),
                  ArchiveV2Hash.isValidSHA256(configurationSHA256),
                  ArchiveV2Hash.sha256(configurationData) == configurationSHA256 else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configuration")
            }
        } else {
            guard configurationData == nil, configurationGeneration == nil, configurationSHA256 == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configuration")
            }
        }
        kind = "vscodeWorkspace"
        self.configurationLocator = configurationLocator
        self.configurationGeneration = configurationGeneration
        self.configurationData = configurationData
        self.configurationSHA256 = configurationSHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "vscodeWorkspace" else {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.kind")
        }
        try self.init(configurationLocator: values.decodeIfPresent(String.self, forKey: .configurationLocator),
            configurationGeneration: values.decodeIfPresent(ArchiveSourceGeneration.self, forKey: .configurationGeneration),
            configurationData: values.decodeIfPresent(Data.self, forKey: .configurationData),
            configurationSHA256: values.decodeIfPresent(String.self, forKey: .configurationSHA256))
    }

    /// Binds the frozen off-tree bytes/absence to the exact workspace reference.
    /// Native folder precedence is preserved; malformed external references fail closed.
    public func validateWorkspaceData(_ data: Data?) throws {
        guard let data else {
            guard configurationLocator == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.workspace")
            }
            return
        }
        guard data.count <= Self.maximumContextBytes,
              let workspace = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.workspace")
        }
        var expected: String?
        if workspace["folder"] as? String == nil, let uri = workspace["configuration"] as? String {
            guard uri.hasPrefix("file://") else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configurationURI")
            }
            var encoded = String(uri.dropFirst(7))
            if encoded.hasPrefix("localhost/") { encoded = String(encoded.dropFirst(9)) }
            guard let path = encoded.removingPercentEncoding, path.hasPrefix("/"),
                  path.utf8.count <= 4096,
                  ArchiveReplayLayout.isNormalizedRelativePath(String(path.dropFirst())) else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configurationURI")
            }
            expected = path
        }
        guard expected.map({ Data($0.utf8) }) == configurationLocator.map({ Data($0.utf8) }) else {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.configurationReference")
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configurationLocator.map { Data($0.utf8) } == rhs.configurationLocator.map { Data($0.utf8) }
            && lhs.configurationGeneration == rhs.configurationGeneration
            && lhs.configurationData == rhs.configurationData && lhs.configurationSHA256 == rhs.configurationSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case kind, configurationLocator, configurationGeneration, configurationData, configurationSHA256
    }
}

/// Project-scoped projection of a native Gemini registry. The registry bytes
/// are not transported; the collector fences the recorded generation and hash.
public struct ArchiveGeminiProjectContext: Codable, Equatable, Sendable {
    public let kind: String
    public let projectName: String
    public let cwd: String
    public let registryLocator: String
    public let registryGeneration: ArchiveSourceGeneration
    public let registrySHA256: String

    public init(projectName: String, cwd: String, registryLocator: String,
                registryGeneration: ArchiveSourceGeneration, registrySHA256: String) throws {
        guard !projectName.isEmpty, projectName != ".", projectName != "..",
              !projectName.contains("/"), !projectName.utf8.contains(0),
              projectName.utf8.count <= ArchiveReplayLayout.maximumRelativePathBytes else {
            throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.projectName")
        }
        guard cwd.hasPrefix("/"), !cwd.utf8.contains(0), cwd.utf8.count <= 4096 else {
            throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.cwd")
        }
        guard registryLocator.hasPrefix("/"), registryLocator.utf8.count <= 4096,
              ArchiveReplayLayout.isNormalizedRelativePath(String(registryLocator.dropFirst())) else {
            throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.registryLocator")
        }
        guard registryGeneration.mode & 0o170000 == 0o100000 else {
            throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.registryGeneration")
        }
        guard ArchiveV2Hash.isValidSHA256(registrySHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "geminiProjectContext.registrySHA256")
        }
        kind = "geminiProjectsRegistryProjection"
        self.projectName = projectName
        self.cwd = cwd
        self.registryLocator = registryLocator
        self.registryGeneration = registryGeneration
        self.registrySHA256 = registrySHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "geminiProjectsRegistryProjection" else {
            throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.kind")
        }
        try self.init(projectName: values.decode(String.self, forKey: .projectName),
            cwd: values.decode(String.self, forKey: .cwd),
            registryLocator: values.decode(String.self, forKey: .registryLocator),
            registryGeneration: values.decode(ArchiveSourceGeneration.self, forKey: .registryGeneration),
            registrySHA256: values.decode(String.self, forKey: .registrySHA256))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.projectName.utf8.elementsEqual(rhs.projectName.utf8)
            && lhs.cwd.utf8.elementsEqual(rhs.cwd.utf8)
            && lhs.registryLocator.utf8.elementsEqual(rhs.registryLocator.utf8)
            && lhs.registryGeneration == rhs.registryGeneration && lhs.registrySHA256 == rhs.registrySHA256
    }
}

/// Provenance of a scoped, reconstructed SQLite image. This is deliberately
/// distinct from a native file capture; generation remains the observed DB stat.
public struct ArchiveSQLiteSessionContext: Codable, Equatable, Sendable {
    public let kind: String
    public let databaseLocator: String
    public let nativeSessionID: String
    public let nativePayloadByteCount: Int64
    public let walGeneration: ArchiveSourceGeneration?

    public init(databaseLocator: String, nativeSessionID: String,
                nativePayloadByteCount: Int64, walGeneration: ArchiveSourceGeneration?) throws {
        guard databaseLocator.hasPrefix("/"), databaseLocator.utf8.count <= 4096,
              ArchiveReplayLayout.isNormalizedRelativePath(String(databaseLocator.dropFirst())),
              !databaseLocator.contains("::") else {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.databaseLocator")
        }
        guard !nativeSessionID.isEmpty, nativeSessionID.utf8.count <= 4096,
              !nativeSessionID.utf8.contains(0), !nativeSessionID.contains("::") else {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.nativeSessionID")
        }
        guard nativePayloadByteCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.nativePayloadByteCount")
        }
        if let walGeneration, walGeneration.mode & 0o170000 != 0o100000 {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.walGeneration")
        }
        kind = "opencodeSessionImage"
        self.databaseLocator = databaseLocator
        self.nativeSessionID = nativeSessionID
        self.nativePayloadByteCount = nativePayloadByteCount
        self.walGeneration = walGeneration
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "opencodeSessionImage" else {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.kind")
        }
        try self.init(databaseLocator: values.decode(String.self, forKey: .databaseLocator),
            nativeSessionID: values.decode(String.self, forKey: .nativeSessionID),
            nativePayloadByteCount: values.decode(Int64.self, forKey: .nativePayloadByteCount),
            walGeneration: values.decodeIfPresent(ArchiveSourceGeneration.self, forKey: .walGeneration))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.databaseLocator.utf8.elementsEqual(rhs.databaseLocator.utf8)
            && lhs.nativeSessionID.utf8.elementsEqual(rhs.nativeSessionID.utf8)
            && lhs.nativePayloadByteCount == rhs.nativePayloadByteCount && lhs.walGeneration == rhs.walGeneration
    }
}

/// Project-scoped projection of a native Kimi work_dirs registry. The registry
/// bytes are not transported; HQ synthesizes one `{path, last_session_id}` row.
public struct ArchiveKimiProjectContext: Codable, Equatable, Sendable {
    public let kind: String
    public let workspaceName: String
    public let nativeSessionID: String
    public let cwd: String
    public let registryLocator: String
    public let registryGeneration: ArchiveSourceGeneration
    public let registrySHA256: String

    public init(workspaceName: String, nativeSessionID: String, cwd: String, registryLocator: String,
                registryGeneration: ArchiveSourceGeneration, registrySHA256: String) throws {
        guard Self.isSafeComponent(workspaceName) else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.workspaceName")
        }
        guard Self.isSafeComponent(nativeSessionID) else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.nativeSessionID")
        }
        guard cwd.hasPrefix("/"), !cwd.utf8.contains(0), cwd.utf8.count <= 4096 else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.cwd")
        }
        guard registryLocator.hasPrefix("/"), registryLocator.utf8.count <= 4096,
              ArchiveReplayLayout.isNormalizedRelativePath(String(registryLocator.dropFirst())) else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.registryLocator")
        }
        guard registryGeneration.mode & 0o170000 == 0o100000 else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.registryGeneration")
        }
        guard ArchiveV2Hash.isValidSHA256(registrySHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "kimiProjectContext.registrySHA256")
        }
        kind = "kimiWorkDirsRegistryProjection"
        self.workspaceName = workspaceName
        self.nativeSessionID = nativeSessionID
        self.cwd = cwd
        self.registryLocator = registryLocator
        self.registryGeneration = registryGeneration
        self.registrySHA256 = registrySHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .kind) == "kimiWorkDirsRegistryProjection" else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext.kind")
        }
        try self.init(workspaceName: values.decode(String.self, forKey: .workspaceName),
            nativeSessionID: values.decode(String.self, forKey: .nativeSessionID),
            cwd: values.decode(String.self, forKey: .cwd),
            registryLocator: values.decode(String.self, forKey: .registryLocator),
            registryGeneration: values.decode(ArchiveSourceGeneration.self, forKey: .registryGeneration),
            registrySHA256: values.decode(String.self, forKey: .registrySHA256))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.workspaceName.utf8.elementsEqual(rhs.workspaceName.utf8)
            && lhs.nativeSessionID.utf8.elementsEqual(rhs.nativeSessionID.utf8)
            && lhs.cwd.utf8.elementsEqual(rhs.cwd.utf8)
            && lhs.registryLocator.utf8.elementsEqual(rhs.registryLocator.utf8)
            && lhs.registryGeneration == rhs.registryGeneration && lhs.registrySHA256 == rhs.registrySHA256
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.utf8.contains(0) && value.utf8.count <= ArchiveReplayLayout.maximumRelativePathBytes
    }
}

public struct ArchiveReplayLayout: Codable, Equatable, Sendable {
    public static let maximumFileSetDependencies = 64
    public static let maximumRelativePathBytes = 1023
    public static let maximumRelativePathDepth = 32

    public let strategy: ArchiveReplayStrategy
    public let relativePaths: [String]
    public let entrypointRelativePath: String?
    public let files: [ArchiveFileSetEntry]?
    public let absentRelativePaths: [String]?
    public let vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext?
    public let geminiProjectContext: ArchiveGeminiProjectContext?
    public let kimiProjectContext: ArchiveKimiProjectContext?
    public let sqliteSession: ArchiveSQLiteSessionContext?
    public let cursorLegacySession: ArchiveCursorLegacyContext?

    public init(strategy: ArchiveReplayStrategy, relativePaths: [String],
                sqliteSession: ArchiveSQLiteSessionContext? = nil,
                cursorLegacySession: ArchiveCursorLegacyContext? = nil) throws {
        guard strategy == .singleFile else {
            throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.strategy")
        }
        var uniquePaths = Set<String>()
        for path in relativePaths where !uniquePaths.insert(path).inserted {
            throw ArchiveV2ValidationError.duplicateReplayPath(path)
        }
        guard relativePaths.count == 1 else {
            throw ArchiveV2ValidationError.invalidReplayPathCount(
                expected: 1,
                actual: relativePaths.count
            )
        }
        for path in relativePaths {
            guard Self.isNormalizedRelativePath(path) else {
                throw ArchiveV2ValidationError.invalidReplayPath(path)
            }
        }
        if sqliteSession != nil, relativePaths != ["session.sqlite"] {
            throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession.relativePaths")
        }
        if cursorLegacySession != nil,
           sqliteSession != nil || relativePaths != ["session.cursor-legacy.json"] {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.relativePaths")
        }
        self.strategy = strategy
        self.relativePaths = relativePaths
        self.entrypointRelativePath = nil
        self.files = nil
        self.absentRelativePaths = nil
        self.vscodeWorkspaceContext = nil
        self.geminiProjectContext = nil
        self.kimiProjectContext = nil
        self.sqliteSession = sqliteSession
        self.cursorLegacySession = cursorLegacySession
    }

    public init(
        strategy: ArchiveReplayStrategy,
        relativePaths: [String],
        entrypointRelativePath: String,
        files: [ArchiveFileSetEntry],
        absentRelativePaths: [String],
        vscodeWorkspaceContext: ArchiveVSCodeWorkspaceContext? = nil,
        geminiProjectContext: ArchiveGeminiProjectContext? = nil,
        kimiProjectContext: ArchiveKimiProjectContext? = nil
    ) throws {
        guard strategy == .fileSet else {
            throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.strategy")
        }
        guard !files.isEmpty else {
            throw ArchiveV2ValidationError.invalidReplayPathCount(
                expected: 1,
                actual: 0
            )
        }
        let dependencyCount = files.count + absentRelativePaths.count
        guard dependencyCount <= Self.maximumFileSetDependencies else {
            throw ArchiveV2ValidationError.invalidReplayPathCount(
                expected: Self.maximumFileSetDependencies,
                actual: dependencyCount
            )
        }
        guard relativePaths.count == files.count,
              zip(relativePaths, files).allSatisfy({ path, file in
                  path.utf8.elementsEqual(file.relativePath.utf8)
              }) else {
            throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.relativePaths")
        }
        guard relativePaths.contains(where: { $0.utf8.elementsEqual(entrypointRelativePath.utf8) }) else {
            throw ArchiveV2ValidationError.invalidReplayPath(entrypointRelativePath)
        }

        for (previous, next) in zip(relativePaths, relativePaths.dropFirst()) {
            guard previous.utf8.lexicographicallyPrecedes(next.utf8) else {
                throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.relativePaths")
            }
        }

        var cursor: Int64 = 0
        for file in files {
            guard file.byteOffset == cursor else {
                throw ArchiveV2ValidationError.invalidValue(field: "files.byteOffset")
            }
            let (next, overflow) = cursor.addingReportingOverflow(file.rawByteCount)
            guard !overflow else {
                throw ArchiveV2ValidationError.rawByteCountOverflow
            }
            cursor = next
        }

        for path in absentRelativePaths {
            guard Self.isNormalizedRelativePath(path),
                  Self.isBoundedRelativePath(path) else {
                throw ArchiveV2ValidationError.invalidReplayPath(path)
            }
        }
        for (index, path) in absentRelativePaths.enumerated() where index > 0 {
            let previous = absentRelativePaths[index - 1]
            guard previous.utf8.lexicographicallyPrecedes(path.utf8) else {
                throw ArchiveV2ValidationError.invalidValue(field: "absentRelativePaths")
            }
        }

        let declared = relativePaths + absentRelativePaths
        try Self.validateDisjointDeclaredPaths(declared)
        if [vscodeWorkspaceContext != nil, geminiProjectContext != nil, kimiProjectContext != nil].filter({ $0 }).count > 1 {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
        }
        if let context = vscodeWorkspaceContext {
            try Self.validateClosedVSCodeFileSet(entrypoint: entrypointRelativePath,
                files: files, absent: absentRelativePaths, context: context)
        }
        if let context = geminiProjectContext {
            guard entrypointRelativePath.split(separator: "/").first?.utf8.elementsEqual(context.projectName.utf8) == true else {
                throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext.projectName")
            }
        }
        if let context = kimiProjectContext {
            try Self.validateClosedKimiFileSet(
                entrypoint: entrypointRelativePath,
                present: relativePaths,
                absent: absentRelativePaths,
                context: context
            )
        }

        self.strategy = strategy
        self.relativePaths = relativePaths
        self.entrypointRelativePath = entrypointRelativePath
        self.files = files
        self.absentRelativePaths = absentRelativePaths
        self.vscodeWorkspaceContext = vscodeWorkspaceContext
        self.geminiProjectContext = geminiProjectContext
        self.kimiProjectContext = kimiProjectContext
        self.sqliteSession = nil
        self.cursorLegacySession = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let strategy = try container.decode(ArchiveReplayStrategy.self, forKey: .strategy)
        let relativePaths = try container.decode([String].self, forKey: .relativePaths)
        switch strategy {
        case .singleFile:
            if container.contains(.entrypointRelativePath)
                || container.contains(.files)
                || container.contains(.absentRelativePaths)
                || container.contains(.vscodeWorkspaceContext)
                || container.contains(.geminiProjectContext)
                || container.contains(.kimiProjectContext) {
                throw ArchiveV2ValidationError.invalidValue(field: "replayLayout")
            }
            try self.init(strategy: strategy, relativePaths: relativePaths,
                sqliteSession: container.decodeIfPresent(ArchiveSQLiteSessionContext.self, forKey: .sqliteSession),
                cursorLegacySession: container.decodeIfPresent(ArchiveCursorLegacyContext.self, forKey: .cursorLegacySession))
        case .fileSet:
            guard !container.contains(.sqliteSession), !container.contains(.cursorLegacySession) else {
                throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession")
            }
            try self.init(
                strategy: strategy,
                relativePaths: relativePaths,
                entrypointRelativePath: container.decode(String.self, forKey: .entrypointRelativePath),
                files: container.decode([ArchiveFileSetEntry].self, forKey: .files),
                absentRelativePaths: container.decode([String].self, forKey: .absentRelativePaths),
                vscodeWorkspaceContext: container.decodeIfPresent(ArchiveVSCodeWorkspaceContext.self, forKey: .vscodeWorkspaceContext),
                geminiProjectContext: container.decodeIfPresent(ArchiveGeminiProjectContext.self, forKey: .geminiProjectContext),
                kimiProjectContext: container.decodeIfPresent(ArchiveKimiProjectContext.self, forKey: .kimiProjectContext)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strategy, forKey: .strategy)
        try container.encode(relativePaths, forKey: .relativePaths)
        try container.encodeIfPresent(sqliteSession, forKey: .sqliteSession)
        try container.encodeIfPresent(cursorLegacySession, forKey: .cursorLegacySession)
        if strategy == .fileSet {
            guard let entrypointRelativePath,
                  let files,
                  let absentRelativePaths else {
                throw ArchiveV2ValidationError.invalidValue(field: "replayLayout")
            }
            try container.encode(entrypointRelativePath, forKey: .entrypointRelativePath)
            try container.encode(files, forKey: .files)
            try container.encode(absentRelativePaths, forKey: .absentRelativePaths)
            try container.encodeIfPresent(vscodeWorkspaceContext, forKey: .vscodeWorkspaceContext)
            try container.encodeIfPresent(geminiProjectContext, forKey: .geminiProjectContext)
            try container.encodeIfPresent(kimiProjectContext, forKey: .kimiProjectContext)
        }
    }

    private static func validateClosedVSCodeFileSet(
        entrypoint: String, files: [ArchiveFileSetEntry], absent: [String], context: ArchiveVSCodeWorkspaceContext
    ) throws {
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[1] == "chatSessions", parts[2].hasSuffix(".jsonl"),
              parts[2].utf8.count > 6 else {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.entrypoint")
        }
        let workspacePath = parts[0] + "/workspace.json"
        let present = files.map(\.relativePath)
        let declared = Set((present + absent).map { Data($0.utf8) })
        guard declared == Set([Data(entrypoint.utf8), Data(workspacePath.utf8)]),
              present.contains(where: { $0.utf8.elementsEqual(entrypoint.utf8) }),
              context.configurationLocator == nil || present.contains(where: { $0.utf8.elementsEqual(workspacePath.utf8) }),
              files.filter({ $0.relativePath.utf8.elementsEqual(workspacePath.utf8) })
                .allSatisfy({ $0.rawByteCount <= ArchiveVSCodeWorkspaceContext.maximumContextBytes }) else {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.files")
        }
    }

    static func isNormalizedRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    static func isBoundedRelativePath(_ path: String) -> Bool {
        guard path.utf8.count <= maximumRelativePathBytes else { return false }
        let depth = path.split(separator: "/", omittingEmptySubsequences: false).count
        return depth <= maximumRelativePathDepth
    }

    private static func validateDisjointDeclaredPaths(_ paths: [String]) throws {
        var seen = [String: String]()
        for path in paths {
            guard isNormalizedRelativePath(path), isBoundedRelativePath(path) else {
                throw ArchiveV2ValidationError.invalidReplayPath(path)
            }
            let key = aliasKey(path)
            if let existing = seen[key] {
                throw ArchiveV2ValidationError.duplicateReplayPath(existing)
            }
            for otherKey in seen.keys {
                if isComponentPrefix(otherKey, of: key) || isComponentPrefix(key, of: otherKey) {
                    throw ArchiveV2ValidationError.invalidReplayPath(path)
                }
            }
            seen[key] = path
        }
    }

    private static func validateClosedKimiFileSet(
        entrypoint: String,
        present: [String],
        absent: [String],
        context: ArchiveKimiProjectContext
    ) throws {
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] == "context.jsonl",
              parts[0].utf8.elementsEqual(context.workspaceName.utf8),
              parts[1].utf8.elementsEqual(context.nativeSessionID.utf8) else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
        }
        let prefixBytes = Array((parts[0] + "/" + parts[1] + "/").utf8)
        let primary = parts[0] + "/" + parts[1] + "/context.jsonl"
        let wire = parts[0] + "/" + parts[1] + "/wire.jsonl"
        guard present.contains(where: { $0.utf8.elementsEqual(primary.utf8) }),
              !absent.contains(where: { $0.utf8.elementsEqual(primary.utf8) }) else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
        }
        let wirePresent = present.contains { $0.utf8.elementsEqual(wire.utf8) }
        let wireAbsent = absent.contains { $0.utf8.elementsEqual(wire.utf8) }
        guard wirePresent != wireAbsent else {
            throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
        }
        var identities = Set<KimiShardIdentity>()
        for path in present + absent {
            guard path.utf8.starts(with: prefixBytes) else {
                throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
            }
            let name = String(decoding: path.utf8.dropFirst(prefixBytes.count), as: UTF8.self)
            guard !name.isEmpty, !name.contains("/") else {
                throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
            }
            if name == "context.jsonl" || name == "wire.jsonl" { continue }
            guard absent.allSatisfy({ !$0.utf8.elementsEqual(path.utf8) }),
                  let identity = kimiShardIdentity(name), identities.insert(identity).inserted else {
                throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
            }
        }
    }

    private struct KimiShardIdentity: Hashable {
        let family: String
        let index: Int
    }

    private static func kimiShardIdentity(_ filename: String) -> KimiShardIdentity? {
        guard filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        if stem.hasPrefix("context_sub_") {
            guard let index = Int(stem.dropFirst("context_sub_".count)) else { return nil }
            return KimiShardIdentity(family: "context_sub", index: index)
        }
        if stem.hasPrefix("context_") {
            guard let index = Int(stem.dropFirst("context_".count)) else { return nil }
            return KimiShardIdentity(family: "context", index: index)
        }
        return nil
    }

    private static func aliasKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isComponentPrefix(_ parent: String, of child: String) -> Bool {
        let parentParts = parent.split(separator: "/", omittingEmptySubsequences: false)
        let childParts = child.split(separator: "/", omittingEmptySubsequences: false)
        return childParts.count > parentParts.count
            && Array(childParts.prefix(parentParts.count)) == Array(parentParts)
    }

    private enum CodingKeys: String, CodingKey {
        case strategy
        case relativePaths
        case entrypointRelativePath
        case files
        case absentRelativePaths
        case vscodeWorkspaceContext
        case geminiProjectContext
        case kimiProjectContext
        case sqliteSession
        case cursorLegacySession
    }
}

public struct ArchiveSourceGeneration: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: Int64
    public let size: Int64
    public let mtimeNs: Int64
    public let ctimeNs: Int64
    public let mode: Int64

    public init(
        device: Int64,
        inode: Int64,
        size: Int64,
        mtimeNs: Int64,
        ctimeNs: Int64,
        mode: Int64
    ) throws {
        guard device >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "generation.device")
        }
        guard inode >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "generation.inode")
        }
        guard size >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "generation.size")
        }
        guard mode > 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "generation.mode")
        }
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            device: container.decode(Int64.self, forKey: .device),
            inode: container.decode(Int64.self, forKey: .inode),
            size: container.decode(Int64.self, forKey: .size),
            mtimeNs: container.decode(Int64.self, forKey: .mtimeNs),
            ctimeNs: container.decode(Int64.self, forKey: .ctimeNs),
            mode: container.decode(Int64.self, forKey: .mode)
        )
    }
}

public struct ArchiveChunkReference: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let rawSHA256: String
    public let rawByteCount: Int64

    public init(ordinal: Int, rawSHA256: String, rawByteCount: Int64) throws {
        guard ordinal >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "chunks.ordinal")
        }
        guard ArchiveV2Hash.isValidSHA256(rawSHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "chunks.rawSHA256")
        }
        guard rawByteCount > 0 else {
            throw ArchiveV2ValidationError.invalidChunkRawByteCount(ordinal: ordinal)
        }
        self.ordinal = ordinal
        self.rawSHA256 = rawSHA256
        self.rawByteCount = rawByteCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ordinal: container.decode(Int.self, forKey: .ordinal),
            rawSHA256: container.decode(String.self, forKey: .rawSHA256),
            rawByteCount: container.decode(Int64.self, forKey: .rawByteCount)
        )
    }
}

public struct ArchiveSourceManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let rawChunkSize: Int64 = 8 * 1024 * 1024

    public let schemaVersion: Int
    public let captureID: String
    public let machineID: String
    public let source: String
    public let locator: String
    public let sessionID: String?
    public let capturedAt: String
    public let generation: ArchiveSourceGeneration
    public let wholeSourceSHA256: String
    public let rawByteCount: Int64
    public let chunkSize: Int64
    public let chunks: [ArchiveChunkReference]
    public let replayLayout: ArchiveReplayLayout

    public init(
        schemaVersion: Int = ArchiveSourceManifest.currentSchemaVersion,
        captureID: String,
        machineID: String,
        source: String,
        locator: String,
        sessionID: String?,
        capturedAt: String,
        generation: ArchiveSourceGeneration,
        wholeSourceSHA256: String,
        rawByteCount: Int64,
        chunkSize: Int64 = ArchiveSourceManifest.rawChunkSize,
        chunks: [ArchiveChunkReference],
        replayLayout: ArchiveReplayLayout
    ) throws {
        if schemaVersion != 7, replayLayout.vscodeWorkspaceContext != nil {
            throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext.schemaVersion")
        }
        if schemaVersion != 6, replayLayout.cursorLegacySession != nil {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.schemaVersion")
        }
        switch schemaVersion {
        case Self.currentSchemaVersion:
            guard replayLayout.strategy == .singleFile, replayLayout.sqliteSession == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.strategy")
            }
        case 2:
            guard replayLayout.geminiProjectContext == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext")
            }
            guard replayLayout.kimiProjectContext == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
            }
            guard replayLayout.strategy == .fileSet else {
                throw ArchiveV2ValidationError.unsupportedSchemaVersion(schemaVersion)
            }
            guard sessionID == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "sessionID")
            }
        case 3:
            guard source == "gemini-cli", sessionID == nil,
                  replayLayout.strategy == .fileSet, replayLayout.geminiProjectContext != nil,
                  replayLayout.kimiProjectContext == nil else {
                throw ArchiveV2ValidationError.invalidValue(field: "geminiProjectContext")
            }
        case 4:
            guard source == "opencode", sessionID == nil, replayLayout.strategy == .singleFile,
                  let context = replayLayout.sqliteSession,
                  locator.utf8.elementsEqual((context.databaseLocator + "::" + context.nativeSessionID).utf8),
                  generation.mode & 0o170000 == 0o100000,
                  rawByteCount > 0, context.nativePayloadByteCount <= rawByteCount else {
                throw ArchiveV2ValidationError.invalidValue(field: "sqliteSession")
            }
        case 5:
            guard source == "kimi", sessionID == nil, replayLayout.strategy == .fileSet,
                  locator.hasPrefix("/"), locator.utf8.count <= 4096,
                  ArchiveReplayLayout.isNormalizedRelativePath(String(locator.dropFirst())),
                  replayLayout.geminiProjectContext == nil, replayLayout.sqliteSession == nil,
                  replayLayout.kimiProjectContext != nil,
                  let entrypoint = replayLayout.entrypointRelativePath,
                  replayLayout.files?.contains(where: {
                      $0.relativePath.utf8.elementsEqual(entrypoint.utf8)
                  }) == true,
                  locator.utf8.suffix(entrypoint.utf8.count + 1).elementsEqual(("/" + entrypoint).utf8)
            else {
                throw ArchiveV2ValidationError.invalidValue(field: "kimiProjectContext")
            }
        case 6:
            guard source == "cursor", sessionID == nil, replayLayout.strategy == .singleFile,
                  let context = replayLayout.cursorLegacySession,
                  locator.utf8.elementsEqual(context.logicalLocator.utf8),
                  generation.mode & 0o170000 == 0o100000,
                  rawByteCount > 0, rawByteCount <= ArchiveCursorLegacySession.maximumEncodedByteCount,
                  context.rawPayloadByteCount <= rawByteCount else {
                throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession")
            }
        case 7:
            guard source == "vscode", sessionID == nil, replayLayout.strategy == .fileSet,
                  replayLayout.vscodeWorkspaceContext != nil,
                  locator.hasPrefix("/"), locator.utf8.count <= 4096,
                  ArchiveReplayLayout.isNormalizedRelativePath(String(locator.dropFirst())),
                  let entrypoint = replayLayout.entrypointRelativePath,
                  locator.utf8.suffix(entrypoint.utf8.count + 1).elementsEqual(("/" + entrypoint).utf8) else {
                throw ArchiveV2ValidationError.invalidValue(field: "vscodeWorkspaceContext")
            }
        default:
            throw ArchiveV2ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "captureID")
        }
        try Self.validateMachineID(machineID)
        guard !source.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "source")
        }
        guard !locator.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "locator")
        }
        if let sessionID, sessionID.isEmpty {
            throw ArchiveV2ValidationError.invalidValue(field: "sessionID")
        }
        guard !capturedAt.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "capturedAt")
        }
        guard ArchiveV2Hash.isValidSHA256(wholeSourceSHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "wholeSourceSHA256")
        }
        guard rawByteCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "rawByteCount")
        }
        guard chunkSize == Self.rawChunkSize else {
            throw ArchiveV2ValidationError.invalidChunkSize(
                expected: Self.rawChunkSize,
                actual: chunkSize
            )
        }
        if schemaVersion == Self.currentSchemaVersion {
            guard generation.size == rawByteCount else {
                throw ArchiveV2ValidationError.generationSizeMismatch(
                    expected: generation.size,
                    actual: rawByteCount
                )
            }
        } else if schemaVersion != 4 && schemaVersion != 6 {
            try Self.validateFileSetTransport(
                generation: generation,
                rawByteCount: rawByteCount,
                replayLayout: replayLayout
            )
        }
        try Self.validateChunks(
            chunks,
            rawByteCount: rawByteCount,
            chunkSize: chunkSize,
            wholeSourceSHA256: wholeSourceSHA256
        )

        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.machineID = machineID
        self.source = source
        self.locator = locator
        self.sessionID = sessionID
        self.capturedAt = capturedAt
        self.generation = generation
        self.wholeSourceSHA256 = wholeSourceSHA256
        self.rawByteCount = rawByteCount
        self.chunkSize = chunkSize
        self.chunks = chunks
        self.replayLayout = replayLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            captureID: container.decode(String.self, forKey: .captureID),
            machineID: container.decode(String.self, forKey: .machineID),
            source: container.decode(String.self, forKey: .source),
            locator: container.decode(String.self, forKey: .locator),
            sessionID: container.decodeIfPresent(String.self, forKey: .sessionID),
            capturedAt: container.decode(String.self, forKey: .capturedAt),
            generation: container.decode(ArchiveSourceGeneration.self, forKey: .generation),
            wholeSourceSHA256: container.decode(String.self, forKey: .wholeSourceSHA256),
            rawByteCount: container.decode(Int64.self, forKey: .rawByteCount),
            chunkSize: container.decode(Int64.self, forKey: .chunkSize),
            chunks: container.decode([ArchiveChunkReference].self, forKey: .chunks),
            replayLayout: container.decode(ArchiveReplayLayout.self, forKey: .replayLayout)
        )
    }

    private static func validateMachineID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else {
            throw ArchiveV2ValidationError.invalidValue(field: "machineID")
        }
    }

    private static func validateFileSetTransport(
        generation: ArchiveSourceGeneration,
        rawByteCount: Int64,
        replayLayout: ArchiveReplayLayout
    ) throws {
        guard let files = replayLayout.files,
              let entrypoint = replayLayout.entrypointRelativePath,
              let primary = files.first(where: {
                  $0.relativePath.utf8.elementsEqual(entrypoint.utf8)
              }) else {
            throw ArchiveV2ValidationError.invalidValue(field: "replayLayout.entrypointRelativePath")
        }
        guard primary.generation == generation else {
            throw ArchiveV2ValidationError.invalidValue(field: "generation")
        }
        var sum: Int64 = 0
        for file in files {
            let (next, overflow) = sum.addingReportingOverflow(file.rawByteCount)
            guard !overflow else {
                throw ArchiveV2ValidationError.rawByteCountOverflow
            }
            sum = next
        }
        guard sum == rawByteCount else {
            throw ArchiveV2ValidationError.aggregateRawByteCountMismatch(
                expected: rawByteCount,
                actual: sum
            )
        }
    }

    private static func validateChunks(
        _ chunks: [ArchiveChunkReference],
        rawByteCount: Int64,
        chunkSize: Int64,
        wholeSourceSHA256: String
    ) throws {
        if chunks.isEmpty {
            guard rawByteCount == 0 else {
                throw ArchiveV2ValidationError.aggregateRawByteCountMismatch(
                    expected: rawByteCount,
                    actual: 0
                )
            }
            guard wholeSourceSHA256 == ArchiveV2Hash.sha256(Data()) else {
                throw ArchiveV2ValidationError.invalidSHA256(field: "wholeSourceSHA256")
            }
            return
        }

        var aggregate: Int64 = 0
        for (expectedOrdinal, chunk) in chunks.enumerated() {
            guard chunk.ordinal == expectedOrdinal else {
                throw ArchiveV2ValidationError.nonContiguousChunkOrdinal(
                    expected: expectedOrdinal,
                    actual: chunk.ordinal
                )
            }
            let isFinal = expectedOrdinal == chunks.count - 1
            guard chunk.rawByteCount <= chunkSize,
                  isFinal || chunk.rawByteCount == chunkSize else {
                throw ArchiveV2ValidationError.invalidChunkRawByteCount(
                    ordinal: chunk.ordinal
                )
            }
            let (next, overflow) = aggregate.addingReportingOverflow(chunk.rawByteCount)
            guard !overflow else {
                throw ArchiveV2ValidationError.rawByteCountOverflow
            }
            aggregate = next
        }
        guard aggregate == rawByteCount else {
            throw ArchiveV2ValidationError.aggregateRawByteCountMismatch(
                expected: rawByteCount,
                actual: aggregate
            )
        }
    }
}

public struct ArchiveServerReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let serverID: String
    public let machineID: String
    public let sessionID: String
    public let captureID: String
    public let manifestSHA256: String
    public let wholeSourceSHA256: String
    public let objectCount: Int
    public let rawByteCount: Int64
    public let storedAt: String

    public init(
        schemaVersion: Int = ArchiveServerReceipt.currentSchemaVersion,
        serverID: String,
        machineID: String,
        sessionID: String,
        captureID: String,
        manifestSHA256: String,
        wholeSourceSHA256: String,
        objectCount: Int,
        rawByteCount: Int64,
        storedAt: String
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ArchiveV2ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !serverID.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "serverID")
        }
        guard UUID(uuidString: machineID) != nil else {
            throw ArchiveV2ValidationError.invalidValue(field: "machineID")
        }
        guard !sessionID.isEmpty else {
            throw ArchiveV2ValidationError.receiptRequiresSessionID
        }
        guard ArchiveV2Hash.isValidSHA256(captureID) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "captureID")
        }
        guard ArchiveV2Hash.isValidSHA256(manifestSHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "manifestSHA256")
        }
        guard ArchiveV2Hash.isValidSHA256(wholeSourceSHA256) else {
            throw ArchiveV2ValidationError.invalidSHA256(field: "wholeSourceSHA256")
        }
        guard objectCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "objectCount")
        }
        guard rawByteCount >= 0 else {
            throw ArchiveV2ValidationError.invalidValue(field: "rawByteCount")
        }
        guard (objectCount == 0) == (rawByteCount == 0) else {
            throw ArchiveV2ValidationError.invalidValue(field: "objectCount")
        }
        guard Self.isCanonicalTimestamp(storedAt) else {
            throw ArchiveV2ValidationError.invalidValue(field: "storedAt")
        }
        self.schemaVersion = schemaVersion
        self.serverID = serverID
        self.machineID = machineID
        self.sessionID = sessionID
        self.captureID = captureID
        self.manifestSHA256 = manifestSHA256
        self.wholeSourceSHA256 = wholeSourceSHA256
        self.objectCount = objectCount
        self.rawByteCount = rawByteCount
        self.storedAt = storedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            serverID: container.decode(String.self, forKey: .serverID),
            machineID: container.decode(String.self, forKey: .machineID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            captureID: container.decode(String.self, forKey: .captureID),
            manifestSHA256: container.decode(String.self, forKey: .manifestSHA256),
            wholeSourceSHA256: container.decode(String.self, forKey: .wholeSourceSHA256),
            objectCount: container.decode(Int.self, forKey: .objectCount),
            rawByteCount: container.decode(Int64.self, forKey: .rawByteCount),
            storedAt: container.decode(String.self, forKey: .storedAt)
        )
    }

    public func validate(againstCanonicalManifestBytes manifestBytes: Data) throws {
        let manifest = try ArchiveCanonicalJSON.decode(
            ArchiveSourceManifest.self,
            from: manifestBytes
        )
        guard let manifestSessionID = manifest.sessionID else {
            throw ArchiveV2ValidationError.receiptRequiresBoundManifest
        }
        guard machineID == manifest.machineID else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "machineID")
        }
        guard sessionID == manifestSessionID else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "sessionID")
        }
        guard captureID == manifest.captureID else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "captureID")
        }
        guard manifestSHA256 == ArchiveV2Hash.sha256(manifestBytes) else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "manifestSHA256")
        }
        guard wholeSourceSHA256 == manifest.wholeSourceSHA256 else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(
                field: "wholeSourceSHA256"
            )
        }
        guard objectCount == manifest.chunks.count else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "objectCount")
        }
        guard rawByteCount == manifest.rawByteCount else {
            throw ArchiveV2ValidationError.receiptManifestMismatch(field: "rawByteCount")
        }
    }

    private static func isCanonicalTimestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 24,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              bytes[19] == 46,
              bytes[23] == 90 else {
            return false
        }
        let separators = Set([4, 7, 10, 13, 16, 19, 23])
        guard bytes.indices.allSatisfy({ index in
            separators.contains(index) || (48...57).contains(bytes[index])
        }) else {
            return false
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
