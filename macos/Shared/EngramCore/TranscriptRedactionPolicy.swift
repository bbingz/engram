import Foundation

/// Shared secret-redaction policy for transcript surfaces (MCP `get_session`,
/// export, and any other local transcript reads that must not leak credentials).
///
/// Default contract: apply redaction. Raw content requires an explicit opt-in at
/// the call site (e.g. MCP `include_raw: true`); there is no undocumented
/// unredacted default.
public enum TranscriptRedactionPolicy {
    // Compile patterns once per process. compactMap preserves the previous
    // behavior of silently skipping any pattern that fails to compile.
    private static let compiledPatterns: [NSRegularExpression] = {
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$)"#,
            #"(?i)\b(api[_-]?key|authorization|bearer|password|secret|credential|token)\b\s*[:=]\s*["']?[A-Za-z0-9_+=/.]{10,}["']?"#,
            #"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9_\-+=/.]{10,}"#,
            #"\b(sk-[A-Za-z0-9_\-]{10,}|ghp_[A-Za-z0-9_]{10,}|xox[baprs]-[A-Za-z0-9-]{10,})\b"#,
            #"\b(github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9_]{20,}|ghu_[A-Za-z0-9_]{20,}|ghs_[A-Za-z0-9_]{20,}|ghr_[A-Za-z0-9_]{20,})\b"#,
            #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
            #"\bnpm_[A-Za-z0-9]{10,}\b"#,
            #"\bxoxe-[A-Za-z0-9-]{10,}\b"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static let redactionToken = "[REDACTED]"

    public static func redact(_ content: String) -> String {
        compiledPatterns.reduce(content) { current, regex in
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: redactionToken
            )
        }
    }

    /// Sensitive byte ranges in the original UTF-8 content. Archive paging
    /// uses these ranges to replace a secret atomically while advancing its raw
    /// cursor past the complete match.
    public static func sensitiveUTF8Ranges(in content: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        for regex in compiledPatterns {
            for match in regex.matches(in: content, range: fullRange) {
                guard let stringRange = Range(match.range, in: content) else { continue }
                let lower = content.utf8.distance(
                    from: content.utf8.startIndex,
                    to: stringRange.lowerBound.samePosition(in: content.utf8)!
                )
                let upper = content.utf8.distance(
                    from: content.utf8.startIndex,
                    to: stringRange.upperBound.samePosition(in: content.utf8)!
                )
                ranges.append(lower..<upper)
            }
        }
        let sorted = ranges.sorted {
            $0.lowerBound == $1.lowerBound
                ? $0.upperBound < $1.upperBound
                : $0.lowerBound < $1.lowerBound
        }
        var merged: [Range<Int>] = []
        for range in sorted {
            guard let last = merged.last, range.lowerBound <= last.upperBound else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        }
        return merged
    }

    /// Sensitive ranges whose offsets stay aligned with the original bytes even
    /// when a transcript contains invalid UTF-8. Invalid bytes become one-byte
    /// ASCII placeholders in the scan view instead of three-byte U+FFFD scalars.
    public static func sensitiveUTF8Ranges(inUTF8 data: Data) -> [Range<Int>] {
        sensitiveUTF8Ranges(in: byteAlignedScanString(data))
    }

    /// True when the decoded suffix contains a PEM begin marker whose matching
    /// end marker has not been decoded yet.
    public static func hasUnclosedPrivateKey(in content: String) -> Bool {
        let pattern = #"-----BEGIN ([A-Z ]*PRIVATE KEY(?: BLOCK)?)-----"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.matches(in: content, range: fullRange).last,
              match.numberOfRanges > 1,
              let labelRange = Range(match.range(at: 1), in: content),
              let beginRange = Range(match.range, in: content)
        else {
            return false
        }
        let endMarker = "-----END \(content[labelRange])-----"
        return content[beginRange.upperBound...].range(of: endMarker) == nil
    }

    public static func hasUnclosedPrivateKey(inUTF8 data: Data) -> Bool {
        hasUnclosedPrivateKey(in: byteAlignedScanString(data))
    }

    private static func byteAlignedScanString(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var aligned = Data(capacity: bytes.count)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let width: Int
            switch first {
            case 0x00...0x7F: width = 1
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: width = 0
            }
            if width == 1 {
                aligned.append(first)
                index += 1
            } else if width > 1,
                      index + width <= bytes.count,
                      String(bytes: bytes[index ..< index + width], encoding: .utf8) != nil {
                aligned.append(contentsOf: bytes[index ..< index + width])
                index += width
            } else {
                aligned.append(UInt8(ascii: "?"))
                index += 1
            }
        }
        return String(decoding: aligned, as: UTF8.self)
    }

    public static func redactedSummary(_ content: String) -> String {
        String(redact(content).prefix(200))
    }

    public static func redactedTitle(_ content: String) -> String {
        String(redact(content).prefix(120))
    }
}
