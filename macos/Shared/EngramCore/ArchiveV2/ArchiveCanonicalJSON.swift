import Foundation

public enum ArchiveCanonicalJSONError: Error, Equatable, Sendable {
    case nonCanonicalEncoding
}

public enum ArchiveCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let decoded = try JSONDecoder().decode(type, from: data)
        guard try encode(decoded) == data else {
            throw ArchiveCanonicalJSONError.nonCanonicalEncoding
        }
        return decoded
    }
}
