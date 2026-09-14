import CryptoKit
import Foundation

public enum ArchiveV2Hash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func isValidSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Incremental member hashes for an already validated file-set byte layout.
/// Retains a SHA-256 state only; callers keep their existing chunk-size bounds.
public struct ArchiveFileSetByteVerifier {
    private let files: [ArchiveFileSetEntry]
    private var index = 0
    private var memberByteCount: Int64 = 0
    private var hasher = SHA256()

    public init(layout: ArchiveReplayLayout) throws {
        guard layout.strategy == .fileSet, let files = layout.files, !files.isEmpty else {
            throw ArchiveV2ValidationError.invalidValue(field: "fileSet.layout")
        }
        self.files = files
    }

    public mutating func append(_ bytes: Data) throws {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            try advanceCompletedMembers()
            guard index < files.count else {
                throw ArchiveV2ValidationError.invalidValue(field: "fileSet.byteCount")
            }
            let remaining = files[index].rawByteCount - memberByteCount
            let count = Int(min(remaining, Int64(bytes.distance(from: offset, to: bytes.endIndex))))
            let end = bytes.index(offset, offsetBy: count)
            hasher.update(data: bytes[offset..<end])
            memberByteCount += Int64(count)
            offset = end
        }
        try advanceCompletedMembers()
    }

    public mutating func finish() throws {
        try advanceCompletedMembers()
        guard index == files.count else {
            throw ArchiveV2ValidationError.invalidValue(field: "fileSet.byteCount")
        }
    }

    private mutating func advanceCompletedMembers() throws {
        while index < files.count, memberByteCount == files[index].rawByteCount {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == files[index].wholeSourceSHA256 else {
                throw ArchiveV2ValidationError.invalidSHA256(field: "files.wholeSourceSHA256")
            }
            index += 1
            memberByteCount = 0
            hasher = SHA256()
        }
    }
}
