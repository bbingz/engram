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
}

public struct ArchiveReplayLayout: Codable, Equatable, Sendable {
    public let strategy: ArchiveReplayStrategy
    public let relativePaths: [String]

    public init(strategy: ArchiveReplayStrategy, relativePaths: [String]) throws {
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
        self.strategy = strategy
        self.relativePaths = relativePaths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            strategy: container.decode(ArchiveReplayStrategy.self, forKey: .strategy),
            relativePaths: container.decode([String].self, forKey: .relativePaths)
        )
    }

    private static func isNormalizedRelativePath(_ path: String) -> Bool {
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
        guard schemaVersion == Self.currentSchemaVersion else {
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
        guard generation.size == rawByteCount else {
            throw ArchiveV2ValidationError.generationSizeMismatch(
                expected: generation.size,
                actual: rawByteCount
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
