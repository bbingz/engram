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
            #"(?i)\b(api[_-]?key|authorization|bearer|password|secret|credential|token)\b\s*[:=]\s*["']?[A-Za-z0-9_\-+=/.]{10,}["']?"#,
            #"(?i)\bAuthorization:\s*Bearer\s+[A-Za-z0-9_\-+=/.]{10,}"#,
            #"\b(sk-[A-Za-z0-9_\-]{10,}|ghp_[A-Za-z0-9_]{10,}|xox[baprs]-[A-Za-z0-9-]{10,})\b"#,
            #"\b(github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9_]{20,}|ghu_[A-Za-z0-9_]{20,}|ghs_[A-Za-z0-9_]{20,}|ghr_[A-Za-z0-9_]{20,})\b"#,
            #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
            #"\bnpm_[A-Za-z0-9]{10,}\b"#,
            #"\bxoxe-[A-Za-z0-9-]{10,}\b"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
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
}
