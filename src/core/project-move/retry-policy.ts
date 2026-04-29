// src/core/project-move/retry-policy.ts
//
// Single source of truth for error → retry_policy classification + HTTP
// status mapping + message humanization. Previously lived duplicated in
// src/index.ts (MCP) and src/web.ts (HTTP), which drifted: unknown errors
// got 'never' from MCP but 'safe' from HTTP, and DirCollisionError's
// structured fields (sourceId/oldDir/newDir) were silently dropped by
// both layers. Round 4 extracted this so every caller — MCP, HTTP, and
// any future CLI/batch consumer — shares the same contract.

import type { SourceId } from './sources.js';

export type RetryPolicy = 'safe' | 'conditional' | 'wait' | 'never';

/** Map an error name to the retry_policy clients should follow.
 *  Unknown errors default to `'never'`: surfacing to the user is the
 *  safer default than encouraging a blind retry loop. */
export function classifyRetryPolicy(name: string | undefined): RetryPolicy {
  switch (name) {
    case 'LockBusyError':
      return 'wait';
    case 'ConcurrentModificationError':
      return 'conditional';
    case 'DirCollisionError':
    case 'SharedEncodingCollisionError':
    case 'UndoStaleError':
    case 'UndoNotAllowedError':
    case 'InvalidUtf8Error':
      return 'never';
    default:
      return 'never';
  }
}

/** Map an error name to the HTTP status code. 409 = conflict (state the
 *  user must resolve), 500 = genuine internal failure. */
export function mapErrorStatus(name: string | undefined): 400 | 409 | 500 {
  switch (name) {
    case 'LockBusyError':
    case 'DirCollisionError':
    case 'SharedEncodingCollisionError':
    case 'UndoNotAllowedError':
    case 'UndoStaleError':
      return 409;
    default:
      return 500;
  }
}

/** Humanize Node.js fs errors + strip orchestrator prefixes. Previously
 *  the ENOENT/EACCES/EEXIST patterns stopped at the first comma, which
 *  truncated paths containing commas (rare but legal — APFS allows them).
 *  Now the capture greedily consumes up to a closing single-quote or end
 *  of line. */
export function sanitizeProjectMoveMessage(raw: string): string {
  if (!raw) return 'Unknown error';
  let msg = raw;
  msg = msg.replace(/^runProjectMove:\s*/, '');
  msg = msg.replace(/^project-move:\s*/, '');
  if (/\bENOENT\b/.test(msg)) {
    msg = msg.replace(
      /ENOENT[^,]*,\s*([a-z]+)\s+'([^']+)'/,
      (_, op, path) => `File or directory not found: ${path.trim()} (${op})`,
    );
  }
  if (/\bEACCES\b/.test(msg)) {
    msg = msg.replace(
      /EACCES[^,]*,\s*([a-z]+)\s+'([^']+)'/,
      (_, op, path) => `Permission denied: ${path.trim()} (${op})`,
    );
  }
  if (/\bEEXIST\b/.test(msg)) {
    msg = msg.replace(
      /EEXIST[^,]*,\s*([a-z]+)\s+'([^']+)'/,
      (_, op, path) => `Path already exists: ${path.trim()} (${op})`,
    );
  }
  return msg.trim();
}

/** Structured fields pulled off the error instance for programmatic
 *  access by clients (Swift UI, MCP AI agents). Without these,
 *  DirCollisionError shows the user only a message — no way to display
 *  "conflict dir: X" as a separate UI element with a Copy button. */
export interface ErrorDetails {
  sourceId?: SourceId | string;
  oldDir?: string;
  newDir?: string;
  sharingCwds?: string[];
  migrationId?: string;
  state?: string;
  holder?: unknown;
}

function extractDetails(err: unknown): ErrorDetails | undefined {
  if (!err || typeof err !== 'object') return undefined;
  const e = err as Record<string, unknown> & { name?: string };
  const out: ErrorDetails = {};
  let any = false;
  if (typeof e.sourceId === 'string') {
    out.sourceId = e.sourceId;
    any = true;
  }
  if (typeof e.oldDir === 'string') {
    out.oldDir = e.oldDir;
    any = true;
  }
  if (typeof e.newDir === 'string') {
    out.newDir = e.newDir;
    any = true;
  }
  if (typeof e.dir === 'string' && e.name === 'SharedEncodingCollisionError') {
    // dir is the "logical" shared dir — expose as oldDir for UI consistency
    out.oldDir = e.dir;
    any = true;
  }
  if (Array.isArray(e.sharingCwds)) {
    out.sharingCwds = e.sharingCwds.filter((x) => typeof x === 'string');
    any = true;
  }
  if (typeof e.migrationId === 'string') {
    out.migrationId = e.migrationId;
    any = true;
  }
  if (typeof e.state === 'string' && e.name === 'UndoNotAllowedError') {
    out.state = e.state;
    any = true;
  }
  return any ? out : undefined;
}

/** Canonical error envelope returned over HTTP AND embedded in MCP
 *  structuredContent. Clients decode optional `details` for structured
 *  access; `message` remains the human fallback. */
export interface ErrorEnvelope {
  error: {
    name: string;
    message: string;
    retry_policy: RetryPolicy;
    details?: ErrorDetails;
  };
}

export function buildErrorEnvelope(
  err: unknown,
  opts: { sanitize?: boolean } = {},
): ErrorEnvelope {
  const e = err as Error & { name?: string };
  const name = e?.name ?? 'Error';
  const rawMessage = e?.message ?? String(err);
  const message = opts.sanitize
    ? sanitizeProjectMoveMessage(rawMessage)
    : rawMessage;
  const retry_policy = classifyRetryPolicy(name);
  const details = extractDetails(err);
  return {
    error: {
      name,
      message,
      retry_policy,
      ...(details ? { details } : {}),
    },
  };
}

/** MCP-specific humanization — multi-line guidance directing an AI agent
 *  on whether to retry, what to tell the user, and how to resolve the
 *  condition. Used as the `text` field in MCP error responses, while
 *  structuredContent carries the same envelope as HTTP. */
export function humanizeForMcp(err: unknown): string {
  const e = err as Error & { name?: string };
  const name = e?.name ?? 'Error';
  const base = e?.message ?? String(err);
  switch (name) {
    case 'LockBusyError':
      return (
        'Another project-move is already running. Wait 5–10 seconds, then retry — but only if YOU did not start the other one. Never launch project_* tools in parallel.\n' +
        base
      );
    case 'ConcurrentModificationError':
      return (
        'A session file was modified while engram was patching it (another AI client likely wrote to it). Ask the user to stop editing the affected project in other tools, then retry once. Do NOT retry blindly.\n' +
        base
      );
    case 'UndoStaleError':
      return (
        'This migration can no longer be safely undone — its newPath is no longer owned by it (a later migration or manual edit overlaid it). Do not retry; tell the user.\n' +
        base
      );
    case 'UndoNotAllowedError':
      return (
        'Undo is only allowed for committed migrations. Use project_recover to diagnose failed/stuck ones.\n' +
        base
      );
    case 'InvalidUtf8Error':
      return (
        'A session file is not valid UTF-8; engram refused to patch to avoid data loss. The user must manually inspect/fix the file before retrying.\n' +
        base
      );
    case 'DirCollisionError':
      return (
        'The target directory already exists on disk for one of the session sources (see details.sourceId/newDir). Another project is using that path — engram refuses to overwrite. Tell the user to move the target aside (or pick a different destination) and retry.\n' +
        base
      );
    case 'SharedEncodingCollisionError':
      return (
        'The target dir is shared by multiple projects because this source uses a lossy encoding (e.g. iFlow/Gemini basename-per-project). Renaming would silently steal sessions from the other projects listed in details.sharingCwds. Do not retry; the user must manually separate the dirs.\n' +
        base
      );
    default:
      return `${name}: ${base}`;
  }
}
