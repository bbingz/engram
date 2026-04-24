import Foundation

struct FileIdentity: Equatable, Sendable {
    var sizeBytes: Int64
    var modificationDate: Date?
    var resourceIdentifier: String?
}

struct ParserLimits: Equatable, Sendable {
    static let `default` = ParserLimits()

    var maxFileBytes: Int64
    var maxLineBytes: Int
    var maxMessages: Int

    init(
        maxFileBytes: Int64 = 100 * 1024 * 1024,
        maxLineBytes: Int = 8 * 1024 * 1024,
        maxMessages: Int = 10_000
    ) {
        self.maxFileBytes = maxFileBytes
        self.maxLineBytes = maxLineBytes
        self.maxMessages = maxMessages
    }

    func fileIdentity(for url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let values = try url.resourceValues(
            forKeys: [
                .fileResourceIdentifierKey
            ]
        )
        let identifier = values.fileResourceIdentifier.map { String(describing: $0) }
        let size = attributes[.size] as? NSNumber
        let modificationDate = attributes[.modificationDate] as? Date
        return FileIdentity(
            sizeBytes: size?.int64Value ?? 0,
            modificationDate: modificationDate,
            resourceIdentifier: identifier
        )
    }

    func isSameFileIdentity(_ before: FileIdentity, _ after: FileIdentity) -> Bool {
        before == after
    }

    func validateFileSize(_ identity: FileIdentity) -> ParserFailure? {
        identity.sizeBytes > maxFileBytes ? .fileTooLarge : nil
    }
}
