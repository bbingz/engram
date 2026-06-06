// macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift
//
// Claude Code stores session JSONLs under
// `~/.claude/projects/<encoded-cwd>/`, where the encoded form replaces EVERY
// character NOT in `[A-Za-z0-9]` with `-` (real CC rule:
// `path.replace(/[^a-zA-Z0-9]/g, "-")` — no dash-collapsing, no case change).
// e.g. `/Users/bing/.config/x` → `-Users-bing--config-x`,
// `/Users/bing/-Code-/CCTV_Admin` → `-Users-bing--Code--CCTV-Admin`.
// Verified against 39/39 real on-disk Claude Code dirs (and 7/7 qoder dirs).
//
// The old `/`-and-`.`-only encoder silently diverged for `_`, space and any
// other punctuation, so migrating such a project left its session dir under a
// stale name that Claude Code never looks at (orphaned history). The encoding
// is lossy (distinct chars collapse to `-`) but one-way — we only ever encode.
//
// Iterates UTF-16 code units to match Node's no-`/u` regex semantics (an astral
// scalar maps to two `-`, identical to JS). If the encoded name exceeds 200
// UTF-16 code units, Claude Code truncates the encoded prefix to 200 units and
// appends a base36 Java-style 32-bit hash of the original path. Verified
// against Claude Code 2.1.165's bundled `Hj()` function.
import Foundation

public enum ClaudeCodeProjectDir {
    private static let maxEncodedUnits = 200

    /// Encode an absolute path into the directory name Claude Code uses
    /// under `~/.claude/projects/`. Caller is responsible for normalizing
    /// the input (e.g. stripping trailing slashes).
    public static func encode(_ absolutePath: String) -> String {
        let units = absolutePath.utf16.map { u -> UInt16 in
            let isAlnum = (u >= 48 && u <= 57) // 0-9
                || (u >= 65 && u <= 90) // A-Z
                || (u >= 97 && u <= 122) // a-z
            return isAlnum ? u : 45 // '-'
        }
        if units.count > maxEncodedUnits {
            let prefix = Array(units.prefix(maxEncodedUnits))
            return String(utf16CodeUnits: prefix, count: prefix.count) + "-" + hashSuffix(absolutePath)
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func hashSuffix(_ absolutePath: String) -> String {
        var hash: Int32 = 0
        for unit in absolutePath.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let value = Int64(hash)
        let magnitude = UInt64(value < 0 ? -value : value)
        return base36(magnitude)
    }

    private static func base36(_ value: UInt64) -> String {
        if value == 0 { return "0" }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var n = value
        var output = ""
        while n > 0 {
            output.insert(alphabet[Int(n % 36)], at: output.startIndex)
            n /= 36
        }
        return output
    }
}
