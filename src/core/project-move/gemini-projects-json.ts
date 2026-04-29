// src/core/project-move/gemini-projects-json.ts — maintain the Gemini CLI
// project registry during a project move.
//
// Gemini CLI stores a `~/.gemini/projects.json` file mapping
// { absoluteCwd → projectBasename }. The adapter uses this reverse map to
// resolve a session file (`tmp/<basename>/chats/…`) back to its real cwd.
// If we rename the tmp dir but leave this file stale, the adapter either
// mis-resolves cwd or falls back to the basename string — silently
// detaching the migrated sessions from the renamed project.
//
// This module keeps the two sides in sync. The orchestrator calls
// `planGeminiProjectsJsonUpdate` BEFORE doing any FS work (preflight +
// collision probe). After the dir rename succeeds, it calls
// `applyGeminiProjectsJsonUpdate` to rewrite the JSON in-place atomically.
// Compensation reverses via `reverseGeminiProjectsJsonUpdate`.

import { rename as fsRename, readFile, writeFile } from 'node:fs/promises';
import { basename } from 'node:path';

/** Parsed shape of ~/.gemini/projects.json. Two formats observed in the wild:
 *    { "projects": { "<cwd>": "<name>", … } }   (current)
 *    { "<cwd>": "<name>", … }                    (legacy)
 *  We preserve whichever layout we read. */
interface ProjectsJsonShape {
  /** If the file had a top-level `projects` wrapper. */
  wrapped: boolean;
  map: Record<string, string>;
}

export interface GeminiProjectsJsonUpdatePlan {
  /** Absolute path to ~/.gemini/projects.json (may not exist yet). */
  filePath: string;
  /** The entry we'll rewrite. `null` if no entry for oldCwd — still
   *  valid (nothing to do), kept for uniform handling. */
  oldEntry: { cwd: string; name: string } | null;
  /** The replacement entry. */
  newEntry: { cwd: string; name: string };
  /** Snapshot of the file contents for compensation. `null` if file
   *  didn't exist — reverse will just delete our added entry. */
  originalText: string | null;
}

/**
 * Read projects.json if present; parse either wrapped or legacy layout.
 * Returns an empty map (wrapped=true) if file is missing — so callers can
 * still decide whether to write a new entry.
 */
async function loadProjectsJson(filePath: string): Promise<{
  shape: ProjectsJsonShape;
  originalText: string | null;
}> {
  let originalText: string | null;
  try {
    originalText = await readFile(filePath, 'utf8');
  } catch (err) {
    const e = err as { code?: string };
    if (e.code !== 'ENOENT') throw err;
    return { shape: { wrapped: true, map: {} }, originalText: null };
  }
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(originalText) as Record<string, unknown>;
  } catch (err) {
    throw new Error(
      `gemini-projects-json: ${filePath} is not valid JSON — ${
        (err as Error).message
      }`,
    );
  }
  const wrapped = obj && typeof obj === 'object' && 'projects' in obj;
  const rawMap = (wrapped ? obj.projects : obj) as Record<string, string>;
  const map: Record<string, string> = {};
  if (rawMap && typeof rawMap === 'object') {
    for (const [k, v] of Object.entries(rawMap)) {
      if (typeof v === 'string') map[k] = v;
    }
  }
  return { shape: { wrapped, map }, originalText };
}

/** Serialize back in the detected layout, preserving 2-space indent. */
function serialize(shape: ProjectsJsonShape): string {
  const top = shape.wrapped ? { projects: shape.map } : shape.map;
  return `${JSON.stringify(top, null, 2)}\n`;
}

/** Atomic write via temp + rename. Avoids partial-write corruption if the
 *  process dies mid-write (cheap insurance on a file adapters read eagerly). */
async function writeAtomic(filePath: string, text: string): Promise<void> {
  const tmp = `${filePath}.engram-tmp-${process.pid}-${Date.now()}`;
  await writeFile(tmp, text, 'utf8');
  await fsRename(tmp, filePath);
}

/**
 * Plan the projects.json update. Does NOT write anything — just figures
 * out what would change so the orchestrator can preflight collisions and
 * later apply/reverse atomically.
 *
 * Rules:
 *   - If an entry `oldCwd → <anything>` exists, we'll replace it with
 *     `newCwd → basename(newPath)`.
 *   - If no such entry exists, the new entry is still written (so the
 *     adapter can reverse-resolve the renamed dir). The `oldEntry=null`
 *     signals this to compensation.
 */
export async function planGeminiProjectsJsonUpdate(
  filePath: string,
  oldCwd: string,
  newCwd: string,
): Promise<GeminiProjectsJsonUpdatePlan> {
  const { shape, originalText } = await loadProjectsJson(filePath);
  const oldName = shape.map[oldCwd];
  return {
    filePath,
    oldEntry:
      typeof oldName === 'string' ? { cwd: oldCwd, name: oldName } : null,
    newEntry: { cwd: newCwd, name: basename(newCwd) },
    originalText,
  };
}

/**
 * Apply the planned update: remove the old entry (if any) and add the new
 * entry. Writes atomically. Caller must have already run the preflight
 * collision check (`collectOtherGeminiCwdsSharingBasename`).
 */
export async function applyGeminiProjectsJsonUpdate(
  plan: GeminiProjectsJsonUpdatePlan,
): Promise<void> {
  const { shape } = await loadProjectsJson(plan.filePath);
  if (plan.oldEntry) delete shape.map[plan.oldEntry.cwd];
  shape.map[plan.newEntry.cwd] = plan.newEntry.name;
  await writeAtomic(plan.filePath, serialize(shape));
}

/**
 * Reverse the update (compensation path). Restores the snapshot if we
 * captured one; otherwise deletes the entry we added.
 *
 * Round 4 (Gemini Minor): if engram created the projects.json file from
 * scratch AND removing our entry leaves an empty map, unlink the file
 * rather than leaving an empty shell on disk. This restores the exact
 * pre-migration state (Gemini CLI will lazily create the file again
 * when needed).
 */
export async function reverseGeminiProjectsJsonUpdate(
  plan: GeminiProjectsJsonUpdatePlan,
): Promise<void> {
  if (plan.originalText !== null) {
    await writeAtomic(plan.filePath, plan.originalText);
    return;
  }
  // Original file didn't exist — remove the entry we inserted.
  const { shape } = await loadProjectsJson(plan.filePath);
  delete shape.map[plan.newEntry.cwd];
  if (Object.keys(shape.map).length === 0) {
    // We created the file AND we're the only contributor — fully
    // restore the pre-migration state by unlinking it.
    const { unlink } = await import('node:fs/promises');
    try {
      await unlink(plan.filePath);
    } catch {
      // Best-effort cleanup; leaving an empty file behind is harmless.
    }
    return;
  }
  await writeAtomic(plan.filePath, serialize(shape));
}

/**
 * Collision probe (Gemini major #3): find other cwds in projects.json
 * that share the target basename but are NOT the project being moved.
 * If any exist, renaming the tmp dir would steal their sessions.
 *
 * Returns the list of conflicting cwds (empty = safe).
 */
export async function collectOtherGeminiCwdsSharingBasename(
  filePath: string,
  targetBasename: string,
  srcCwd: string,
): Promise<string[]> {
  const { shape } = await loadProjectsJson(filePath);
  const conflicts: string[] = [];
  for (const [cwd, name] of Object.entries(shape.map)) {
    if (name === targetBasename && cwd !== srcCwd) {
      conflicts.push(cwd);
    }
  }
  return conflicts;
}
