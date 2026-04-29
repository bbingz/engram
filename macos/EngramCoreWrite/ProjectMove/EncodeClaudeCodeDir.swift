// macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift
// Mirrors src/core/project-move/encode-cc.ts (Node parity baseline).
//
// Claude Code stores session JSONLs under
// `~/.claude/projects/<encoded-cwd>/`, where the encoded form is the
// absolute cwd with every `/` replaced by `-`. The encoding is lossy
// (consecutive slashes collapse with existing dashes) but one-way — we
// only ever encode, never decode.
import Foundation

public enum ClaudeCodeProjectDir {
    /// Encode an absolute path into the directory name Claude Code uses
    /// under `~/.claude/projects/`. Caller is responsible for normalizing
    /// the input (e.g. stripping trailing slashes) — the encoding is a
    /// naive replace, matching mvp.py:encode_cc().
    public static func encode(_ absolutePath: String) -> String {
        absolutePath.replacingOccurrences(of: "/", with: "-")
    }
}
