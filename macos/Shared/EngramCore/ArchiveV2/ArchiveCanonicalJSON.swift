import Foundation

public enum ArchiveCanonicalJSONError: Error, Equatable, Sendable {
    case nonCanonicalEncoding
}

public enum ArchiveCanonicalJSON {
    private static let needsUTF8KeySortFixup: Bool = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(value)
        guard needsUTF8KeySortFixup else {
            return encoded
        }
        return LegacyJSONKeyCanonicalizer.canonicalize(encoded)
    }

    public static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let decoded = try JSONDecoder().decode(type, from: data)
        guard try encode(decoded) == data else {
            throw ArchiveCanonicalJSONError.nonCanonicalEncoding
        }
        return decoded
    }
}

// On macOS < 14, NSJSONSerialization (.sortedKeys) sorts object keys case-insensitively
// (e.g. "capturedAt" before "captureID", "chunks" before "chunkSize") instead of
// swift-foundation's UTF-8 lexicographical code-unit order. Re-sort object keys by
// UTF-8 byte order without altering any string, number, boolean, or null token bytes.
private enum LegacyJSONKeyCanonicalizer {
    static func canonicalize(_ data: Data) -> Data {
        let bytes = Array(data)
        var index = 0
        guard let out = try? parseValue(bytes, index: &index), index == bytes.count else {
            return data
        }
        return Data(out)
    }

    private static func parseValue(_ bytes: [UInt8], index: inout Int) throws -> [UInt8] {
        guard index < bytes.count else { throw ArchiveCanonicalJSONError.nonCanonicalEncoding }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try parseObject(bytes, index: &index)
        case UInt8(ascii: "["):
            return try parseArray(bytes, index: &index)
        case UInt8(ascii: "\""):
            let start = index
            try skipString(bytes, index: &index)
            return Array(bytes[start..<index])
        default:
            let start = index
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: ",") || b == UInt8(ascii: "}") || b == UInt8(ascii: "]") {
                    break
                }
                index += 1
            }
            return Array(bytes[start..<index])
        }
    }

    private static func parseObject(_ bytes: [UInt8], index: inout Int) throws -> [UInt8] {
        index += 1
        if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
            index += 1
            return [UInt8(ascii: "{"), UInt8(ascii: "}")]
        }
        var entries: [(key: String, rawKey: [UInt8], rawValue: [UInt8])] = []
        while true {
            let keyStart = index
            try skipString(bytes, index: &index)
            let rawKey = Array(bytes[keyStart..<index])
            let decodedKey = (try? JSONDecoder().decode(String.self, from: Data(rawKey)))
                ?? String(decoding: rawKey, as: UTF8.self)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw ArchiveCanonicalJSONError.nonCanonicalEncoding
            }
            index += 1
            let rawValue = try parseValue(bytes, index: &index)
            entries.append((decodedKey, rawKey, rawValue))
            guard index < bytes.count else { throw ArchiveCanonicalJSONError.nonCanonicalEncoding }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                break
            } else {
                throw ArchiveCanonicalJSONError.nonCanonicalEncoding
            }
        }
        entries.sort { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        var out: [UInt8] = [UInt8(ascii: "{")]
        for (i, entry) in entries.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            out.append(contentsOf: entry.rawKey)
            out.append(UInt8(ascii: ":"))
            out.append(contentsOf: entry.rawValue)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    private static func parseArray(_ bytes: [UInt8], index: inout Int) throws -> [UInt8] {
        index += 1
        if index < bytes.count && bytes[index] == UInt8(ascii: "]") {
            index += 1
            return [UInt8(ascii: "["), UInt8(ascii: "]")]
        }
        var out: [UInt8] = [UInt8(ascii: "[")]
        var first = true
        while true {
            if !first { out.append(UInt8(ascii: ",")) }
            first = false
            let elem = try parseValue(bytes, index: &index)
            out.append(contentsOf: elem)
            guard index < bytes.count else { throw ArchiveCanonicalJSONError.nonCanonicalEncoding }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                break
            } else {
                throw ArchiveCanonicalJSONError.nonCanonicalEncoding
            }
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    private static func skipString(_ bytes: [UInt8], index: inout Int) throws {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
            throw ArchiveCanonicalJSONError.nonCanonicalEncoding
        }
        index += 1
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if b == UInt8(ascii: "\"") {
                index += 1
                return
            }
            index += 1
        }
        throw ArchiveCanonicalJSONError.nonCanonicalEncoding
    }
}
