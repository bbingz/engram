import Foundation

/// A bounded, session-scoped Cursor legacy payload with frozen workspace ownership.
public struct ArchiveCursorLegacySession: Codable, Equatable, Sendable {
    public static let maximumEncodedByteCount: Int64 = 128 * 1024 * 1024
    public enum Storage: String, Codable, Sendable { case text, blob, null }
    public struct Row: Codable, Equatable, Sendable {
        public let rowID: Int64
        public let key: String
        public let value: Data?
        public let storage: Storage

        public init(rowID: Int64, key: String, value: Data?, storage: Storage? = nil) {
            self.rowID = rowID
            self.key = key
            self.value = value
            self.storage = storage ?? (value == nil ? .null : .text)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rowID == rhs.rowID && lhs.key.utf8.elementsEqual(rhs.key.utf8)
                && lhs.value == rhs.value && lhs.storage == rhs.storage
        }
    }
    public let kind: String
    public let logicalDatabaseLocator: String
    public let composerID: String
    public let cwd: String
    public let databaseGeneration: ArchiveSourceGeneration
    public let walGeneration: ArchiveSourceGeneration?
    public let composer: Row
    public let bubbles: [Row]
    public let rawPayloadByteCount: Int64
    public var logicalLocator: String { logicalDatabaseLocator + "?composer=" + composerID }
    /// SQLite's UTF-8 column_text followed by String(cString:), without parsing
    /// messages. The collector already converted TEXT values to logical UTF-8.
    public var nativePayloadByteCount: Int64 {
        ([composer] + bubbles).reduce(0) { total, row in
            guard let value = row.value else { return total }
            return total + Int64(String(decoding: value.prefix { $0 != 0 }, as: UTF8.self).utf8.count)
        }
    }

    public init(logicalDatabaseLocator: String, composerID: String, cwd: String,
                databaseGeneration: ArchiveSourceGeneration, walGeneration: ArchiveSourceGeneration?,
                composer: Row, bubbles: [Row]) throws {
        guard Self.normalizedAbsolutePath(logicalDatabaseLocator),
              logicalDatabaseLocator.hasSuffix("/state.vscdb"),
              !logicalDatabaseLocator.contains("?composer="),
              !composerID.isEmpty, composerID.utf8.count <= 4096, !composerID.utf8.contains(0),
              cwd.isEmpty || Self.normalizedAbsolutePath(cwd),
              databaseGeneration.mode & 0o170000 == 0o100000,
              walGeneration.map({ $0.mode & 0o170000 == 0o100000 }) ?? true,
              bubbles.count < 16384 else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.context")
        }
        let rows = [composer] + bubbles
        var rawBytes: Int64 = 0
        var keyBytes: Int64 = 0
        var rowIDs: Set<Int64> = []
        var keys: Set<Data> = []
        for row in rows {
            guard (row.storage == .null) == (row.value == nil), !row.key.utf8.contains(0),
                  rowIDs.insert(row.rowID).inserted, keys.insert(Data(row.key.utf8)).inserted else {
                throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.rows")
            }
            // Each running total is capped before the next addition.
            rawBytes += Int64(row.value?.count ?? 0)
            keyBytes += Int64(row.key.utf8.count)
            guard rawBytes <= 16 * 1024 * 1024, keyBytes <= 16 * 1024 * 1024 else {
                throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.byteBudget")
            }
        }
        guard composer.key.utf8.elementsEqual(("composerData:" + composerID).utf8),
              let value = composer.value,
              let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any],
              let embeddedID = object["composerId"] as? String,
              embeddedID.utf8.elementsEqual(composerID.utf8),
              (object["conversation"] as? [Any])?.isEmpty != false || bubbles.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.composer")
        }
        let prefix = "bubbleId:" + composerID + ":"
        var previousRowID: Int64?
        for row in bubbles {
            guard row.key.utf8.starts(with: prefix.utf8),
                  previousRowID.map({ row.rowID > $0 }) ?? true else {
                throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.bubbles")
            }
            previousRowID = row.rowID
        }
        self.kind = "cursorLegacyRowsV1"
        self.logicalDatabaseLocator = logicalDatabaseLocator
        self.composerID = composerID
        self.cwd = cwd
        self.databaseGeneration = databaseGeneration
        self.walGeneration = walGeneration
        self.composer = composer
        self.bubbles = bubbles
        self.rawPayloadByteCount = rawBytes
    }

    public func encodeCanonical() throws -> Data { try ArchiveCanonicalJSON.encode(self) }
    public static func decodeCanonical(_ bytes: Data) throws -> Self {
        // Raw rows permit 16 MiB values plus 16 MiB keys. JSON escaping and
        // base64 overhead have their own bound; never charge them as native size.
        guard Int64(bytes.count) <= Self.maximumEncodedByteCount else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.encodedBudget")
        }
        return try ArchiveCanonicalJSON.decode(Self.self, from: bytes)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalDatabaseLocator: fields.decode(String.self, forKey: .logicalDatabaseLocator),
            composerID: fields.decode(String.self, forKey: .composerID),
            cwd: fields.decode(String.self, forKey: .cwd),
            databaseGeneration: fields.decode(ArchiveSourceGeneration.self, forKey: .databaseGeneration),
            walGeneration: fields.decodeIfPresent(ArchiveSourceGeneration.self, forKey: .walGeneration),
            composer: fields.decode(Row.self, forKey: .composer),
            bubbles: fields.decode([Row].self, forKey: .bubbles)
        )
        guard try fields.decode(String.self, forKey: .kind) == kind,
              try fields.decode(Int64.self, forKey: .rawPayloadByteCount) == rawPayloadByteCount else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.binding")
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.logicalDatabaseLocator.utf8.elementsEqual(rhs.logicalDatabaseLocator.utf8)
            && lhs.composerID.utf8.elementsEqual(rhs.composerID.utf8)
            && lhs.cwd.utf8.elementsEqual(rhs.cwd.utf8)
            && lhs.databaseGeneration == rhs.databaseGeneration && lhs.walGeneration == rhs.walGeneration
            && lhs.composer == rhs.composer && lhs.bubbles == rhs.bubbles
    }

    fileprivate static func normalizedAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { return false }
        // Lexical only: archive locators must never resolve or inspect live paths.
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Manifest summary bound to the canonical scoped legacy body.
public struct ArchiveCursorLegacyContext: Codable, Equatable, Sendable {
    public let kind: String
    public let databaseLocator: String
    public let composerID: String
    public let cwd: String
    public let rawPayloadByteCount: Int64
    public let nativePayloadByteCount: Int64
    public let walGeneration: ArchiveSourceGeneration?
    public var logicalLocator: String { databaseLocator + "?composer=" + composerID }

    public init(session: ArchiveCursorLegacySession) throws {
        try self.init(databaseLocator: session.logicalDatabaseLocator, composerID: session.composerID,
            cwd: session.cwd, rawPayloadByteCount: session.rawPayloadByteCount,
            nativePayloadByteCount: session.nativePayloadByteCount, walGeneration: session.walGeneration)
    }

    public init(databaseLocator: String, composerID: String, cwd: String,
                rawPayloadByteCount: Int64, nativePayloadByteCount: Int64,
                walGeneration: ArchiveSourceGeneration?) throws {
        guard ArchiveCursorLegacySession.normalizedAbsolutePath(databaseLocator),
              databaseLocator.hasSuffix("/state.vscdb"), !databaseLocator.contains("?composer="),
              !composerID.isEmpty, composerID.utf8.count <= 4096, !composerID.utf8.contains(0),
              cwd.isEmpty || ArchiveCursorLegacySession.normalizedAbsolutePath(cwd),
              (1...16 * 1024 * 1024).contains(rawPayloadByteCount),
              nativePayloadByteCount >= 0, nativePayloadByteCount <= rawPayloadByteCount * 3,
              walGeneration.map({ $0.mode & 0o170000 == 0o100000 }) ?? true else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.context")
        }
        self.kind = "cursorLegacyRowsV1"
        self.databaseLocator = databaseLocator
        self.composerID = composerID
        self.cwd = cwd
        self.rawPayloadByteCount = rawPayloadByteCount
        self.nativePayloadByteCount = nativePayloadByteCount
        self.walGeneration = walGeneration
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard try fields.decode(String.self, forKey: .kind) == "cursorLegacyRowsV1" else {
            throw ArchiveV2ValidationError.invalidValue(field: "cursorLegacySession.kind")
        }
        try self.init(databaseLocator: fields.decode(String.self, forKey: .databaseLocator),
            composerID: fields.decode(String.self, forKey: .composerID),
            cwd: fields.decode(String.self, forKey: .cwd),
            rawPayloadByteCount: fields.decode(Int64.self, forKey: .rawPayloadByteCount),
            nativePayloadByteCount: fields.decode(Int64.self, forKey: .nativePayloadByteCount),
            walGeneration: fields.decodeIfPresent(ArchiveSourceGeneration.self, forKey: .walGeneration))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.databaseLocator.utf8.elementsEqual(rhs.databaseLocator.utf8)
            && lhs.composerID.utf8.elementsEqual(rhs.composerID.utf8) && lhs.cwd.utf8.elementsEqual(rhs.cwd.utf8)
            && lhs.rawPayloadByteCount == rhs.rawPayloadByteCount && lhs.nativePayloadByteCount == rhs.nativePayloadByteCount
            && lhs.walGeneration == rhs.walGeneration
    }
}
