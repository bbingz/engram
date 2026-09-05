import Foundation

public enum CollectorPublicationValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedRepresentation(String)
    case invalidValue(field: String)
    case invalidSHA256(field: String)
    case acknowledgementMismatch(field: String)
    case invalidCursor
    case cursorJournalMismatch
    case invalidPage(field: String)
}

public enum CollectorPublicationErrorCode: String, Codable, Sendable {
    case unauthorized
    case malformedRequest = "malformed_request"
    case notFound = "not_found"
    case sequenceConflict = "sequence_conflict"
    case cursorJournalMismatch = "cursor_journal_mismatch"
    case cursorAheadOfTail = "cursor_ahead_of_tail"
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case invalidContent = "invalid_content"
    case storageUnavailable = "storage_unavailable"
    case methodNotAllowed = "method_not_allowed"
    case internalError = "internal_error"
}

public enum CollectorPublicationProtocolLimits {
    public static let maxPublicationBytes = 2 * 1024
    public static let maxAcceptanceRecordBytes = 4 * 1024
    public static let maxPageBytes = 256 * 1024
    public static let defaultPageLimit = 50
    public static let maxPageItems = 100
    public static let maxCursorBytes = 256

    public static func validatedPageLimit(_ rawValue: String?) throws -> Int {
        do {
            return try ArchiveV2ProtocolLimits.validatedPageLimit(rawValue)
        } catch {
            throw CollectorPublicationValidationError.invalidValue(field: "limit")
        }
    }
}

/// Immutable collector intent. It is neither a server ACK nor an index-ready receipt.
public struct CollectorPublicationEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let machineID: String
    public let sourceInstanceID: String
    public let collectorEpoch: String
    public let sequence: Int64
    public let manifestSHA256: String
    public let representation: String

    public init(
        schemaVersion: Int = 1,
        machineID: String,
        sourceInstanceID: String,
        collectorEpoch: String,
        sequence: Int64,
        manifestSHA256: String,
        representation: String = "exact-source-v1"
    ) throws {
        try CollectorPublicationChecks.schema(schemaVersion)
        try CollectorPublicationChecks.uuid(machineID, field: "machineID")
        try CollectorPublicationChecks.uuid(sourceInstanceID, field: "sourceInstanceID")
        try CollectorPublicationChecks.uuid(collectorEpoch, field: "collectorEpoch")
        try CollectorPublicationChecks.positive(sequence, field: "sequence")
        try CollectorPublicationChecks.digest(manifestSHA256, field: "manifestSHA256")
        try CollectorPublicationChecks.representation(representation)
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.sourceInstanceID = sourceInstanceID
        self.collectorEpoch = collectorEpoch
        self.sequence = sequence
        self.manifestSHA256 = manifestSHA256
        self.representation = representation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            machineID: c.decode(String.self, forKey: .machineID),
            sourceInstanceID: c.decode(String.self, forKey: .sourceInstanceID),
            collectorEpoch: c.decode(String.self, forKey: .collectorEpoch),
            sequence: c.decode(Int64.self, forKey: .sequence),
            manifestSHA256: c.decode(String.self, forKey: .manifestSHA256),
            representation: c.decode(String.self, forKey: .representation)
        )
    }

    public func sha256() throws -> String {
        ArchiveV2Hash.sha256(try ArchiveCanonicalJSON.encode(self))
    }
}

/// Replica storage proof only; it never grants reclamation or HQ promotion authority.
public struct CollectorPublicationACK: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let serverID: String
    public let journalID: String
    public let arrivalOrdinal: Int64
    public let publicationSHA256: String
    public let manifestSHA256: String
    public let storedAt: String

    public init(
        schemaVersion: Int = 1,
        serverID: String,
        journalID: String,
        arrivalOrdinal: Int64,
        publicationSHA256: String,
        manifestSHA256: String,
        storedAt: String
    ) throws {
        try CollectorPublicationChecks.schema(schemaVersion)
        try CollectorPublicationChecks.serverID(serverID)
        try CollectorPublicationChecks.uuid(journalID, field: "journalID")
        try CollectorPublicationChecks.positive(arrivalOrdinal, field: "arrivalOrdinal")
        try CollectorPublicationChecks.digest(publicationSHA256, field: "publicationSHA256")
        try CollectorPublicationChecks.digest(manifestSHA256, field: "manifestSHA256")
        try CollectorPublicationChecks.timestamp(storedAt)
        self.schemaVersion = schemaVersion
        self.serverID = serverID
        self.journalID = journalID
        self.arrivalOrdinal = arrivalOrdinal
        self.publicationSHA256 = publicationSHA256
        self.manifestSHA256 = manifestSHA256
        self.storedAt = storedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            serverID: c.decode(String.self, forKey: .serverID),
            journalID: c.decode(String.self, forKey: .journalID),
            arrivalOrdinal: c.decode(Int64.self, forKey: .arrivalOrdinal),
            publicationSHA256: c.decode(String.self, forKey: .publicationSHA256),
            manifestSHA256: c.decode(String.self, forKey: .manifestSHA256),
            storedAt: c.decode(String.self, forKey: .storedAt)
        )
    }

    public func validate(
        against publication: CollectorPublicationEnvelope,
        expectedServerID: String
    ) throws {
        guard serverID == expectedServerID else {
            throw CollectorPublicationValidationError.acknowledgementMismatch(field: "serverID")
        }
        guard publicationSHA256 == (try publication.sha256()) else {
            throw CollectorPublicationValidationError.acknowledgementMismatch(field: "publicationSHA256")
        }
        guard manifestSHA256 == publication.manifestSHA256 else {
            throw CollectorPublicationValidationError.acknowledgementMismatch(field: "manifestSHA256")
        }
    }
}

/// The publication-keyed plaintext of the replica's single durable commit record.
public struct CollectorPublicationAcceptanceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let publication: CollectorPublicationEnvelope
    public let ack: CollectorPublicationACK

    public init(
        schemaVersion: Int = 1,
        publication: CollectorPublicationEnvelope,
        ack: CollectorPublicationACK
    ) throws {
        try CollectorPublicationChecks.schema(schemaVersion)
        try ack.validate(against: publication, expectedServerID: ack.serverID)
        self.schemaVersion = schemaVersion
        self.publication = publication
        self.ack = ack
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            publication: c.decode(CollectorPublicationEnvelope.self, forKey: .publication),
            ack: c.decode(CollectorPublicationACK.self, forKey: .ack)
        )
    }
}

/// Opaque to clients; zero is the beginning of this replica journal, not EOF.
public struct CollectorPublicationCursor: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let journalID: String
    public let afterArrivalOrdinal: Int64

    public init(schemaVersion: Int = 1, journalID: String, afterArrivalOrdinal: Int64) throws {
        try CollectorPublicationChecks.schema(schemaVersion)
        try CollectorPublicationChecks.uuid(journalID, field: "journalID")
        try CollectorPublicationChecks.nonnegative(afterArrivalOrdinal, field: "afterArrivalOrdinal")
        self.schemaVersion = schemaVersion
        self.journalID = journalID
        self.afterArrivalOrdinal = afterArrivalOrdinal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            journalID: c.decode(String.self, forKey: .journalID),
            afterArrivalOrdinal: c.decode(Int64.self, forKey: .afterArrivalOrdinal)
        )
    }

    public func encoded() throws -> String {
        try ArchiveCanonicalJSON.encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String) throws -> Self {
        do {
            try ArchiveV2ProtocolLimits.validateCursor(value)
            var base64 = value.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
            guard let bytes = Data(base64Encoded: base64) else {
                throw CollectorPublicationValidationError.invalidCursor
            }
            let cursor = try ArchiveCanonicalJSON.decode(Self.self, from: bytes)
            guard try cursor.encoded() == value else {
                throw CollectorPublicationValidationError.invalidCursor
            }
            return cursor
        } catch {
            throw CollectorPublicationValidationError.invalidCursor
        }
    }
}

public struct CollectorPublicationPage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let items: [CollectorPublicationAcceptanceRecord]
    public let afterCursor: String
    public let hasMore: Bool

    public init(
        schemaVersion: Int = 1,
        items: [CollectorPublicationAcceptanceRecord],
        afterCursor: String,
        hasMore: Bool
    ) throws {
        try CollectorPublicationChecks.schema(schemaVersion)
        guard items.count <= CollectorPublicationProtocolLimits.maxPageItems else {
            throw CollectorPublicationValidationError.invalidPage(field: "items.count")
        }
        let cursor = try CollectorPublicationCursor.decode(afterCursor)
        guard !items.isEmpty || !hasMore else {
            throw CollectorPublicationValidationError.invalidPage(field: "hasMore")
        }
        if let first = items.first, let last = items.last {
            guard items.allSatisfy({ $0.ack.serverID == first.ack.serverID }) else {
                throw CollectorPublicationValidationError.invalidPage(field: "serverID")
            }
            guard items.allSatisfy({ $0.ack.journalID == cursor.journalID }) else {
                throw CollectorPublicationValidationError.cursorJournalMismatch
            }
            guard zip(items, items.dropFirst()).allSatisfy({ $0.ack.arrivalOrdinal < $1.ack.arrivalOrdinal }) else {
                throw CollectorPublicationValidationError.invalidPage(field: "arrivalOrdinal")
            }
            guard Set(items.map { $0.ack.publicationSHA256 }).count == items.count else {
                throw CollectorPublicationValidationError.invalidPage(field: "publicationSHA256")
            }
            guard last.ack.arrivalOrdinal == cursor.afterArrivalOrdinal else {
                throw CollectorPublicationValidationError.invalidPage(field: "afterCursor")
            }
        }
        self.schemaVersion = schemaVersion
        self.items = items
        self.afterCursor = afterCursor
        self.hasMore = hasMore
        guard try ArchiveCanonicalJSON.encode(self).count <= CollectorPublicationProtocolLimits.maxPageBytes else {
            throw CollectorPublicationValidationError.invalidPage(field: "bytes")
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            items: c.decode([CollectorPublicationAcceptanceRecord].self, forKey: .items),
            afterCursor: c.decode(String.self, forKey: .afterCursor),
            hasMore: c.decode(Bool.self, forKey: .hasMore)
        )
    }

    public func validate(
        after requestCursor: CollectorPublicationCursor?,
        expectedServerID: String
    ) throws {
        try CollectorPublicationChecks.serverID(expectedServerID)
        let cursor = try CollectorPublicationCursor.decode(afterCursor)
        if let requestCursor, requestCursor.journalID != cursor.journalID {
            throw CollectorPublicationValidationError.cursorJournalMismatch
        }
        let start = requestCursor?.afterArrivalOrdinal ?? 0
        if let first = items.first {
            guard first.ack.serverID == expectedServerID else {
                throw CollectorPublicationValidationError.acknowledgementMismatch(field: "serverID")
            }
            guard first.ack.arrivalOrdinal > start else {
                throw CollectorPublicationValidationError.invalidPage(field: "arrivalOrdinal")
            }
        } else if cursor.afterArrivalOrdinal != start {
            throw CollectorPublicationValidationError.invalidPage(field: "afterCursor")
        }
    }
}

public struct CollectorPublicationCapabilities: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let serverID: String
    public let publicationSchemaVersions: [Int]
    public let representations: [String]
    public let maxPublicationBytes: Int
    public let maxAcceptanceRecordBytes: Int
    public let maxPageBytes: Int
    public let defaultPageLimit: Int
    public let maxPageItems: Int
    public let maxCursorBytes: Int

    public init(serverID: String) throws {
        try CollectorPublicationChecks.serverID(serverID)
        self.schemaVersion = 1
        self.serverID = serverID
        self.publicationSchemaVersions = [1]
        self.representations = ["exact-source-v1"]
        self.maxPublicationBytes = CollectorPublicationProtocolLimits.maxPublicationBytes
        self.maxAcceptanceRecordBytes = CollectorPublicationProtocolLimits.maxAcceptanceRecordBytes
        self.maxPageBytes = CollectorPublicationProtocolLimits.maxPageBytes
        self.defaultPageLimit = CollectorPublicationProtocolLimits.defaultPageLimit
        self.maxPageItems = CollectorPublicationProtocolLimits.maxPageItems
        self.maxCursorBytes = CollectorPublicationProtocolLimits.maxCursorBytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try CollectorPublicationChecks.schema(c.decode(Int.self, forKey: .schemaVersion))
        try self.init(serverID: c.decode(String.self, forKey: .serverID))
        guard try c.decode([Int].self, forKey: .publicationSchemaVersions) == publicationSchemaVersions,
              try c.decode([String].self, forKey: .representations) == representations,
              try c.decode(Int.self, forKey: .maxPublicationBytes) == maxPublicationBytes,
              try c.decode(Int.self, forKey: .maxAcceptanceRecordBytes) == maxAcceptanceRecordBytes,
              try c.decode(Int.self, forKey: .maxPageBytes) == maxPageBytes,
              try c.decode(Int.self, forKey: .defaultPageLimit) == defaultPageLimit,
              try c.decode(Int.self, forKey: .maxPageItems) == maxPageItems,
              try c.decode(Int.self, forKey: .maxCursorBytes) == maxCursorBytes else {
            throw CollectorPublicationValidationError.invalidValue(field: "capabilities")
        }
    }
}

private enum CollectorPublicationChecks {
    static func schema(_ value: Int) throws {
        guard value == 1 else {
            throw CollectorPublicationValidationError.unsupportedSchemaVersion(value)
        }
    }

    static func uuid(_ value: String, field: String) throws {
        guard UUID(uuidString: value)?.uuidString == value else {
            throw CollectorPublicationValidationError.invalidValue(field: field)
        }
    }

    static func positive(_ value: Int64, field: String) throws {
        guard value > 0 else {
            throw CollectorPublicationValidationError.invalidValue(field: field)
        }
    }

    static func nonnegative(_ value: Int64, field: String) throws {
        guard value >= 0 else {
            throw CollectorPublicationValidationError.invalidValue(field: field)
        }
    }

    static func digest(_ value: String, field: String) throws {
        guard ArchiveV2Hash.isValidSHA256(value) else {
            throw CollectorPublicationValidationError.invalidSHA256(field: field)
        }
    }

    static func representation(_ value: String) throws {
        guard value == "exact-source-v1" else {
            throw CollectorPublicationValidationError.unsupportedRepresentation(value)
        }
    }

    static func serverID(_ value: String) throws {
        guard !value.isEmpty,
              value != ".", value != "..",
              value.utf8.count <= ArchiveV2ProtocolLimits.maxServerIDBytes,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }) else {
            throw CollectorPublicationValidationError.invalidValue(field: "serverID")
        }
    }

    static func timestamp(_ value: String) throws {
        guard value.utf8.count == 24 else {
            throw CollectorPublicationValidationError.invalidValue(field: "storedAt")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw CollectorPublicationValidationError.invalidValue(field: "storedAt")
        }
    }
}
