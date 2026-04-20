// src/core/project-move/paths.ts — shared path normalization helpers.
//
// Phase 4a rev3 (Codex Q3 + Gemini): expandHome was previously inlined in
// src/tools/project.ts but the CLI and batch runner bypassed it. Centralize
// so every boundary uses the same rule.

import { homedir } from 'node:os';

/**
 * Expand a leading `~` or `~/...` to the user's home directory.
 * AI agents (and users) frequently generate `~/path`; Node's fs rejects it
 * with ENOENT. Normalize at the MCP / CLI / batch boundaries.
 *
 * Does NOT resolve relative paths — that's `path.resolve`'s job. Pure `~`
 * handling so the behavior is trivially explainable.
 */
export function expandHome(p: string): string {
  if (!p) return p;
  if (p === '~') return homedir();
  if (p.startsWith('~/')) return `${homedir()}/${p.slice(2)}`;
  return p;
}
