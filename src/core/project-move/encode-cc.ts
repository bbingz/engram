// src/core/project-move/encode-cc.ts — Claude Code project-dir name encoding
//
// Dev/reference baseline mirroring the Swift product encoder
// (macos/EngramCoreWrite/ProjectMove/EncodeClaudeCodeDir.swift). Claude Code
// stores session JSONLs under ~/.claude/projects/<encoded-cwd>/ where
// `<encoded-cwd>` replaces EVERY character not in [A-Za-z0-9] with '-'.
// Example: /Users/bing/-Code-/CCTV_Admin → -Users-bing--Code--CCTV-Admin.
// If the encoded name exceeds 200 UTF-16 code units, Claude Code truncates the
// encoded prefix to 200 units and appends a base36 Java-style 32-bit hash of
// the original path. Verified against Claude Code 2.1.165's bundled `Hj()`.
//
// This is a lossy encoding (distinct chars collapse to '-') but one-way — we
// only ever ENCODE, never decode.

const MAX_ENCODED_UNITS = 200;

function claudePathHash(absPath: string): string {
  let hash = 0;
  for (let i = 0; i < absPath.length; i += 1) {
    hash = ((hash << 5) - hash + absPath.charCodeAt(i)) | 0;
  }
  return Math.abs(hash).toString(36);
}

/**
 * Encode an absolute path into the directory name Claude Code uses under
 * `~/.claude/projects/`. Matches CC's `path.replace(/[^a-zA-Z0-9]/g, '-')`.
 *
 * @param absPath Absolute filesystem path, e.g. `/Users/bing/-Code-/engram`
 * @returns Encoded dir name, e.g. `-Users-bing--Code--engram`
 */
export function encodeCC(absPath: string): string {
  const encoded = absPath.replace(/[^a-zA-Z0-9]/g, '-');
  if (encoded.length <= MAX_ENCODED_UNITS) return encoded;
  return `${encoded.slice(0, MAX_ENCODED_UNITS)}-${claudePathHash(absPath)}`;
}
