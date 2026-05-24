// src/core/project-move/jsonl-patch.ts — byte-level path rewriter for JSONL
//
// 1:1 translation of mvp.py:patch_file. Semantics:
//   - Replace every occurrence of `oldPath` with `newPath` where the match
//     is followed by a path-terminator character (or end-of-input).
//   - Terminators: " ' / \ < > ] ) } backtick whitespace EOF
//   - NOT terminators (by design, to protect /path/name.bak, /path/name-v2,
//     /path/name_suffix from being truncated): . , ; - _ and alphanumerics.
//
// **Code rule (Gemini/Codex review):** this module MUST NOT call JSON.parse
// on the input. It operates at byte-level through Buffer/UTF-8 string round-
// trip so Python mvp and TS produce byte-identical output (diff-test invariant).

import { createReadStream } from 'node:fs';
import {
  chmod,
  open,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { dirname } from 'node:path';

/**
 * Strict UTF-8 decoder — throws on malformed sequences instead of silently
 * replacing with U+FFFD. Required for byte-parity with Python mvp.py:
 * if we can't be byte-identical, we must refuse to write rather than
 * corrupt the file's original bytes.
 */
const STRICT_UTF8_DECODER = new TextDecoder('utf-8', { fatal: true });

export class InvalidUtf8Error extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InvalidUtf8Error';
  }
}

/**
 * Path-terminator lookahead — regex literal (not constructed from strings)
 * to avoid double-escape hazards. Matches one of:
 *   "  '  /  \  <  >  ]  )  }  backtick  whitespace  end-of-input
 *
 * Excludes: . , ; - _ and alphanumerics (so `/path/file.bak` / `/path-v2`
 * / `/path_dir` don't false-positive).
 */
const PATH_TERMINATOR_LOOKAHEAD = /(?=["'/\\<>\])}`\s]|$)/;

/** Escape regex metacharacters so `oldPath` is matched literally. */
function escapeRegex(literal: string): string {
  return literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Build the path-rewrite regex for a given old path. Keep it local to
 * each patch call (patchBuffer is pure; no global state).
 */
function buildRegex(oldPath: string): RegExp {
  return new RegExp(
    escapeRegex(oldPath) + PATH_TERMINATOR_LOOKAHEAD.source,
    'g',
  );
}

export interface PatchResult {
  buffer: Buffer;
  count: number;
}

/**
 * Replace `oldPath` with `newPath` in the buffer, preserving all other bytes.
 * Returns a new buffer + the number of replacements made.
 *
 * mvp.py equivalent: `patch_file(file, old, new)` body excluding the file I/O.
 */
export function patchBuffer(
  data: Buffer,
  oldPath: string,
  newPath: string,
): PatchResult {
  if (oldPath === '' || oldPath === newPath) {
    return { buffer: data, count: 0 };
  }
  // Strict decode — invalid UTF-8 bytes would be silently mangled into
  // U+FFFD by Buffer.toString, breaking byte-parity with Python mvp.py.
  // Refuse to touch the file rather than corrupt it.
  let text: string;
  try {
    text = STRICT_UTF8_DECODER.decode(data);
  } catch (err) {
    throw new InvalidUtf8Error(
      `patchBuffer: input is not valid UTF-8 (${(err as Error).message})`,
    );
  }
  const { text: out, count } = patchText(text, oldPath, newPath);
  if (count === 0) return { buffer: data, count: 0 };
  return { buffer: Buffer.from(out, 'utf8'), count };
}

function patchText(
  text: string,
  oldPath: string,
  newPath: string,
): { text: string; count: number } {
  const primary = buildRegex(oldPath);
  let count = 0;
  let out = text.replace(primary, () => {
    count++;
    return newPath;
  });
  // Round 4 (Codex #3): macOS HFS+ stores filenames in NFD; an AI CLI
  // running on such a volume may also write the *path* in NFD into its
  // JSONL. If the user typed the rename target in NFC (common), the
  // primary regex will miss those occurrences. Retry with an NFD-form
  // needle as a fallback — the replacement stays NFC so the FS wins
  // the tie (consumers open files by NFC path anyway).
  const oldNfd = oldPath.normalize('NFD');
  if (oldNfd !== oldPath) {
    const secondary = buildRegex(oldNfd);
    out = out.replace(secondary, () => {
      count++;
      return newPath;
    });
  }
  return { text: out, count };
}

function patchTextWithDotQuote(
  text: string,
  oldPath: string,
  newPath: string,
): { text: string; count: number } {
  const first = patchText(text, oldPath, newPath);
  const needle = `${oldPath}."`;
  if (!first.text.includes(needle)) return first;
  let count = first.count;
  const out = first.text.split(needle).join(`${newPath}."`);
  count += first.text.split(needle).length - 1;
  return { text: out, count };
}

/**
 * Replace `<oldPath>."` with `<newPath>."` — mvp.py:auto_fix_dot_quote.
 *
 * Rationale: the main regex excludes `.` from terminators to preserve
 * `.bak` / `.py` paths. But a `.` followed by `"` cannot be a filename
 * extension — it's a sentence-end quote. Safe to fix after the fact.
 */
export function autoFixDotQuote(
  data: Buffer,
  oldPath: string,
  newPath: string,
): PatchResult {
  const needle = Buffer.from(`${oldPath}."`, 'utf8');
  const replacement = Buffer.from(`${newPath}."`, 'utf8');
  if (data.indexOf(needle) === -1) return { buffer: data, count: 0 };

  // Use split/join on the buffer representation via bytes. Node's Buffer
  // doesn't have replaceAll, so we manually build.
  const parts: Buffer[] = [];
  let cursor = 0;
  let count = 0;
  while (cursor <= data.length) {
    const hit = data.indexOf(needle, cursor);
    if (hit === -1) {
      parts.push(data.subarray(cursor));
      break;
    }
    parts.push(data.subarray(cursor, hit));
    parts.push(replacement);
    cursor = hit + needle.length;
    count++;
  }
  return { buffer: Buffer.concat(parts), count };
}

/** Max size we'll patch in-memory before switching to streaming I/O. */
const MAX_IN_MEMORY_BYTES = 128 * 1024 * 1024; // 128 MiB

export class ConcurrentModificationError extends Error {
  constructor(filePath: string, oldMtime: number, newMtime: number) {
    super(
      `patchFile: ${filePath} was modified during patch (mtime ${oldMtime} → ${newMtime}). ` +
        'Another process wrote to the file between read and rename. ' +
        'Safe fallback: retry later; orchestrator should retry with exponential backoff.',
    );
    this.name = 'ConcurrentModificationError';
  }
}

/**
 * Combined path-rewrite: main regex (path-terminator aware) + dot-quote
 * fallback. Round 4 Critical: previously the orchestrator ran the dot-quote
 * sweep as a SEPARATE read-write pass bypassing CAS, which could overwrite
 * concurrent writes. Folding it into patchBuffer keeps the transformation
 * atomic AND makes it automatically reversible by compensation (since
 * compensation replays patchFile with src/dst swapped).
 */
export function patchBufferWithDotQuote(
  data: Buffer,
  oldPath: string,
  newPath: string,
): PatchResult {
  const first = patchBuffer(data, oldPath, newPath);
  // autoFixDotQuote still works on the remaining pattern — after the main
  // regex, any `<oldPath>."` that slipped through (path-terminator regex
  // excludes `.` to preserve `.bak`) gets caught here.
  const second = autoFixDotQuote(first.buffer, oldPath, newPath);
  return {
    buffer: second.buffer,
    count: first.count + second.count,
  };
}

/**
 * Read, patch, write a single file atomically with compare-and-swap mtime
 * protection. Uses `<file>.engram-tmp-<pid>-<rand>` + rename.
 *
 * Concurrency protocol (Gemini blocker #2): Captures `mtimeMs` at read time,
 * re-stats immediately before rename. If they differ, another process wrote
 * to the file during our patch — we abort rather than silently overwriting
 * (and losing) the concurrent writer's appended data.
 *
 * The caller (orchestrator) should retry on `ConcurrentModificationError`
 * with a short backoff, OR acquire the global `.project-move.lock` and
 * advise users not to have AI CLIs open on the affected project.
 *
 * Returns the number of replacements (0 = not touched, no write, no CAS check).
 * mvp.py equivalent: `patch_file(file, old, new)` including I/O (but mvp.py
 * has no CAS — it silently clobbers; this is the improvement).
 *
 * Round 4: uses `patchBufferWithDotQuote` so the dot-quote fallback sweep
 * happens within the same CAS window as the main rewrite — previously the
 * orchestrator ran the dot-quote pass separately and bypassed CAS.
 */
export async function patchFile(
  filePath: string,
  oldPath: string,
  newPath: string,
): Promise<number> {
  const stBefore = await stat(filePath);
  const before = snapshot(stBefore);
  if (stBefore.size > MAX_IN_MEMORY_BYTES) {
    return await patchFileStreaming(filePath, oldPath, newPath, stBefore);
  }

  const buf = await readFile(filePath);
  const res = patchBufferWithDotQuote(buf, oldPath, newPath);
  if (res.count === 0) return 0;

  // Re-stat BEFORE we write — if the file changed since we read it, bail out.
  assertUnchanged(filePath, before, await stat(filePath));

  const tmp = tempPath(filePath);
  await writeFile(tmp, res.buffer);
  await chmod(tmp, stBefore.mode & 0o777).catch(() => {});

  // Final CAS — one more stat right before rename to close the gap between
  // the check above and the rename below.
  try {
    assertUnchanged(filePath, before, await stat(filePath));
  } catch (err) {
    await unlink(tmp).catch(() => {});
    throw err;
  }
  await rename(tmp, filePath);
  await fsyncPath(dirname(filePath)).catch(() => {});
  return res.count;
}

type FileSnapshot = {
  dev: number;
  ino: number;
  size: number;
  mtimeMs: number;
};

function snapshot(st: Awaited<ReturnType<typeof stat>>): FileSnapshot {
  return {
    dev: Number(st.dev),
    ino: Number(st.ino),
    size: Number(st.size),
    mtimeMs: Number(st.mtimeMs),
  };
}

function assertUnchanged(
  filePath: string,
  before: FileSnapshot,
  after: Awaited<ReturnType<typeof stat>>,
) {
  const next = snapshot(after);
  if (
    next.dev !== before.dev ||
    next.ino !== before.ino ||
    next.size !== before.size ||
    next.mtimeMs !== before.mtimeMs
  ) {
    throw new ConcurrentModificationError(
      filePath,
      before.mtimeMs,
      next.mtimeMs,
    );
  }
}

function tempPath(filePath: string): string {
  return `${filePath}.engram-tmp-${process.pid}-${Math.random()
    .toString(36)
    .slice(2, 8)}`;
}

function streamingCarryChars(oldPath: string): number {
  return Math.max(oldPath.length, oldPath.normalize('NFD').length) + 4;
}

async function fsyncPath(path: string) {
  const handle = await open(path, 'r');
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function patchFileStreaming(
  filePath: string,
  oldPath: string,
  newPath: string,
  stBefore: Awaited<ReturnType<typeof stat>>,
): Promise<number> {
  const before = snapshot(stBefore);
  const tmp = tempPath(filePath);
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const carryChars = streamingCarryChars(oldPath);
  let carry = '';
  let total = 0;
  let out: Awaited<ReturnType<typeof open>> | undefined;
  const mode = Number(stBefore.mode) & 0o777;

  try {
    out = await open(tmp, 'wx', mode);
    await chmod(tmp, mode).catch(() => {});

    for await (const chunk of createReadStream(filePath, {
      highWaterMark: 1024 * 1024,
    })) {
      let decoded: string;
      try {
        decoded = decoder.decode(chunk as Buffer, { stream: true });
      } catch (err) {
        throw new InvalidUtf8Error(
          `patchFile: input is not valid UTF-8 (${(err as Error).message})`,
        );
      }
      const working = carry + decoded;
      if (working.length <= carryChars) {
        carry = working;
        continue;
      }
      const processText = working.slice(0, working.length - carryChars);
      carry = working.slice(working.length - carryChars);
      const patched = patchTextWithDotQuote(processText, oldPath, newPath);
      total += patched.count;
      await out.write(Buffer.from(patched.text, 'utf8'));
    }

    const finalText = decoder.decode();
    const patchedTail = patchTextWithDotQuote(
      carry + finalText,
      oldPath,
      newPath,
    );
    total += patchedTail.count;
    await out.write(Buffer.from(patchedTail.text, 'utf8'));
    await out.sync();
    await out.close();
    out = undefined;

    if (total === 0) {
      await unlink(tmp).catch(() => {});
      return 0;
    }

    assertUnchanged(filePath, before, await stat(filePath));
    await rename(tmp, filePath);
    await fsyncPath(dirname(filePath)).catch(() => {});
    return total;
  } catch (err) {
    await out?.close().catch(() => {});
    await unlink(tmp).catch(() => {});
    throw err;
  }
}
