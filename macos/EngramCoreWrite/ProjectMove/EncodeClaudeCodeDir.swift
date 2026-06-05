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
// scalar maps to two `-`, identical to JS). Does NOT implement CC's
// >200-code-unit truncate+hash branch (unreachable for real paths — the longest
// real dir name observed is 86 chars).
import Foundation

public enum ClaudeCodeProjectDir {
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
        return String(utf16CodeUnits: units, count: units.count)
    }
}
