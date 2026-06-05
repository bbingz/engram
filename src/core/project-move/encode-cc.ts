// src/core/project-move/encode-cc.ts — Claude Code project-dir name encoding
//
// Dev/reference baseline mirroring the Swift product encoder
// (macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift). Claude Code
// stores session JSONLs under ~/.claude/projects/<encoded-cwd>/ where
// `<encoded-cwd>` replaces EVERY character not in [A-Za-z0-9] with '-'.
// Example: /Users/bing/-Code-/CCTV_Admin → -Users-bing--Code--CCTV-Admin.
//
// This is a lossy encoding (distinct chars collapse to '-') but one-way — we
// only ever ENCODE, never decode.

/**
 * Encode an absolute path into the directory name Claude Code uses under
 * `~/.claude/projects/`. Matches CC's `path.replace(/[^a-zA-Z0-9]/g, '-')`.
 *
 * @param absPath Absolute filesystem path, e.g. `/Users/bing/-Code-/engram`
 * @returns Encoded dir name, e.g. `-Users-bing--Code--engram`
 */
export function encodeCC(absPath: string): string {
  return absPath.replace(/[^a-zA-Z0-9]/g, '-');
}
