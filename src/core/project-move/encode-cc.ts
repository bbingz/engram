// src/core/project-move/encode-cc.ts — Claude Code project-dir name encoding
//
// Claude Code stores session JSONLs under ~/.claude/projects/<encoded-cwd>/
// where `<encoded-cwd>` is the absolute cwd with every '/' replaced by '-'.
// Example: /Users/example/-Code-/engram → -Users-example--Code--engram
//
// This is a lossy encoding (consecutive slashes collapse ambiguously with
// existing dashes) but it is one-way — we only ever ENCODE, never decode.

/**
 * Encode an absolute path into the directory name Claude Code uses under
 * `~/.claude/projects/`. Mirrors `mvp.py:encode_cc()` exactly.
 *
 * @param absPath Absolute filesystem path, e.g. `/Users/example/-Code-/engram`
 * @returns Encoded dir name, e.g. `-Users-example--Code--engram`
 */
export function encodeCC(absPath: string): string {
  return absPath.replaceAll('/', '-');
}
