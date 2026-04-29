// src/tools/project.ts — MCP tools for project directory operations.
//
// These mirror the CLI in src/cli/project.ts but:
//   - Take structured JSON input instead of argv
//   - Return structured result objects (no ANSI, no prompts)
//   - AI agent must be explicit: `force`/`dry_run` default false
//   - Batch input is inline YAML text (not a file path — MCP env may not
//     share FS with the Engram process in future multi-host setups)

import { mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { parse as parseYaml } from 'yaml';
import type { Database } from '../core/db.js';
import type { Logger } from '../core/logger.js';
import {
  type ArchiveCategory,
  normalizeArchiveCategory,
  suggestArchiveTarget,
} from '../core/project-move/archive.js';
import {
  normalizeBatchDocument,
  runBatch,
} from '../core/project-move/batch.js';
import { checkGitDirty } from '../core/project-move/git-dirty.js';
import {
  buildDryRunPlan,
  type PipelineResult,
  runProjectMove,
} from '../core/project-move/orchestrator.js';
import { expandHome } from '../core/project-move/paths.js';
import {
  diagnoseStuckMigrations,
  type RecoverDiagnosis,
} from '../core/project-move/recover.js';
import { reviewScan } from '../core/project-move/review.js';
import { undoMigration } from '../core/project-move/undo.js';

type ToolHandlerOpts = { log?: Logger };

// ---------- project_move ----------

export const projectMoveTool = {
  name: 'project_move',
  description:
    '⚠️ Cannot run concurrently with other project_* tools; execute sequentially. ' +
    'Move a project directory and keep all AI session history reachable. ' +
    'Patches cwd references in Claude Code / Codex / Gemini / iFlow / ' +
    'OpenCode / Antigravity / Copilot session files, renames per-project ' +
    'directories for every source that groups by project (Claude Code ' +
    "encoded cwd, Gemini basename, iFlow encoded), syncs Gemini's " +
    'projects.json, updates engram DB, and creates a project alias. ' +
    'Transactional with compensation on failure.\n\n' +
    'USAGE RULES:\n' +
    '- ALWAYS call with dry_run:true first to preview (unless user explicitly said "just do it").\n' +
    '- Do NOT use this for archiving old/unused projects — use project_archive instead.\n' +
    "- NEVER set force:true unless the user EXPLICITLY typed the word 'force' " +
    '(or equivalent: "override git check"). Do NOT auto-retry with force after a git-dirty failure.\n' +
    '- After a successful move, TELL THE USER the returned migrationId so they can undo later.\n' +
    '- Paths MUST be absolute (or use ~/...; we expand it for you).',
  inputSchema: {
    type: 'object' as const,
    required: ['src', 'dst'],
    properties: {
      src: {
        type: 'string',
        description:
          'Absolute source path (e.g. /Users/example/-Code-/MyProject). ~-prefix accepted.',
      },
      dst: {
        type: 'string',
        description:
          'Absolute destination path (e.g. /Users/example/-Code-/MyProject-v2). ~-prefix accepted.',
      },
      dry_run: {
        type: 'boolean',
        description: 'Plan only, no side effects',
        default: false,
      },
      force: {
        type: 'boolean',
        description: 'Bypass git-dirty warning on source',
        default: false,
      },
      note: {
        type: 'string',
        description: 'Audit note stored in migration_log',
      },
    },
    additionalProperties: false,
  },
};

export async function handleProjectMove(
  db: Database,
  params: {
    src: string;
    dst: string;
    dry_run?: boolean;
    force?: boolean;
    note?: string;
  },
  opts?: ToolHandlerOpts,
): Promise<PipelineResult & { resolved?: { src: string; dst: string } }> {
  opts?.log?.info('project_move', { src: params.src, dst: params.dst });
  const src = expandHome(params.src);
  const dst = expandHome(params.dst);
  const result = await runProjectMove(db, {
    src,
    dst,
    dryRun: params.dry_run,
    force: params.force,
    auditNote: params.note,
    actor: 'mcp',
  });
  // Echo resolved paths when ~ was expanded so the AI can confirm it's
  // operating on the same directory the user meant (Gemini M7 path-hallucination
  // prevention). Only attached when expansion actually happened.
  if (src !== params.src || dst !== params.dst) {
    return { ...result, resolved: { src, dst } };
  }
  return result;
}

// ---------- project_archive ----------

export const projectArchiveTool = {
  name: 'project_archive',
  description:
    '⚠️ Cannot run concurrently with other project_* tools; execute sequentially. ' +
    'Archive a project by moving it under _archive/ with auto-suggested ' +
    'category:\n' +
    '  - 历史脚本 (historical-scripts): YYYYMMDD- prefixed one-shot scripts\n' +
    '  - 空项目 (empty-project): empty or README-only directories\n' +
    '  - 归档完成 (archived-done): finished git repos with substantive content\n\n' +
    'USAGE RULES:\n' +
    '- Use dry_run:true first to preview the suggested target.\n' +
    '- Pass `to` to override the heuristic (required for ambiguous projects). Accepts either CJK names or English aliases above.\n' +
    "- NEVER set force:true unless user EXPLICITLY typed the word 'force'.\n" +
    '- After a successful archive, TELL THE USER the returned migrationId.',
  inputSchema: {
    type: 'object' as const,
    required: ['src'],
    properties: {
      src: {
        type: 'string',
        description:
          'Absolute source path (e.g. /Users/example/-Code-/OldScript). ~-prefix accepted.',
      },
      to: {
        type: 'string',
        enum: [
          '历史脚本',
          '空项目',
          '归档完成',
          'historical-scripts',
          'empty-project',
          'archived-done',
        ],
        description:
          'Force archive category (bypasses heuristic, required for ambiguous projects). CJK or English alias both accepted. NOTE: "archived-done" means a finished project to put away, NOT "a completed task".',
      },
      dry_run: {
        type: 'boolean',
        description: 'Plan only, returns suggested target without moving',
        default: false,
      },
      force: {
        type: 'boolean',
        description: 'Bypass git-dirty warning',
        default: false,
      },
      note: {
        type: 'string',
        description: 'Audit note stored in migration_log',
      },
    },
    additionalProperties: false,
  },
};

export async function handleProjectArchive(
  db: Database,
  params: {
    src: string;
    to?: string; // accept either CJK or English alias
    dry_run?: boolean;
    force?: boolean;
    note?: string;
  },
  opts?: ToolHandlerOpts,
): Promise<
  PipelineResult & {
    archive: { category: ArchiveCategory; reason: string; dst: string };
  }
> {
  opts?.log?.info('project_archive', { src: params.src, to: params.to });
  // Round 4: normalization now lives in archive.ts (normalizeArchiveCategory)
  // so HTTP / MCP / CLI all route English aliases through one shared map.
  // Pass `params.to` through — suggestArchiveTarget will throw on unknown
  // values with a consistent message.
  const forceCategory = normalizeArchiveCategory(params.to);
  if (params.to && !forceCategory) {
    throw new Error(
      `project_archive: unknown category '${params.to}'. ` +
        'Expected one of: 历史脚本/空项目/归档完成 or historical-scripts/empty-project/archived-done.',
    );
  }
  const src = expandHome(params.src);
  if (params.dry_run) {
    // Codex Q4: reuse orchestrator.buildDryRunPlan so future PipelineResult
    // field additions don't drift. Also run the real git check so the AI
    // sees accurate git-dirty info before committing to the archive.
    const git = await checkGitDirty(src);
    const suggestion = await suggestArchiveTarget(src, { forceCategory });
    const plan = await buildDryRunPlan(
      {
        src,
        dst: suggestion.dst,
        archived: true,
      },
      git,
    );
    return {
      ...plan,
      // Round 2 S2 — match the committed-path shape: include dst.
      archive: {
        category: suggestion.category,
        reason: suggestion.reason,
        dst: suggestion.dst,
      },
    };
  }
  const suggestion = await suggestArchiveTarget(src, { forceCategory });
  // Ensure _archive/<category>/ exists — safeMoveDir's fs.rename won't
  // create missing parents, and it's unambiguously fine to create bucket
  // directories for archive operations (user explicitly chose to archive).
  await mkdir(dirname(suggestion.dst), { recursive: true });
  const result = await runProjectMove(db, {
    src,
    dst: suggestion.dst,
    archived: true,
    auditNote: params.note ?? `archive: ${suggestion.reason}`,
    force: params.force,
    actor: 'mcp',
  });
  return {
    ...result,
    // Round 2 S2 (6-way review follow-up): include dst so MCP callers see
    // where the project actually ended up — AI agents need this to reference
    // the archived location in follow-up prompts. Direct-path and HTTP-path
    // now both carry this field.
    archive: {
      category: suggestion.category,
      reason: suggestion.reason,
      dst: suggestion.dst,
    },
  };
}

// ---------- project_review ----------

export const projectReviewTool = {
  name: 'project_review',
  description:
    'Scan all 7 AI session roots for residual references to an old project ' +
    "path. Classifies hits into `own` (in the migrated project's own spaces " +
    '— real leftovers) vs `other` (historical mentions in unrelated ' +
    'conversations — left alone by design).',
  inputSchema: {
    type: 'object' as const,
    required: ['old_path', 'new_path'],
    properties: {
      old_path: { type: 'string', description: 'Absolute old path' },
      new_path: {
        type: 'string',
        description: 'Absolute new path (used to identify own-scope CC dir)',
      },
      max_items: {
        type: 'number',
        description:
          'Cap own/other arrays (default 100). Response includes `truncated` if applied.',
        default: 100,
      },
    },
    additionalProperties: false,
  },
};

interface TruncatedReviewResult {
  own: string[];
  other: string[];
  truncated?: { own: number; other: number };
}

/** Cap per-array paths so MCP responses don't bloat on large projects
 *  (Codex Q4). AI gets a flag + total count to decide whether to drill down. */
const REVIEW_MAX_ITEMS = 100;

export async function handleProjectReview(
  params: { old_path: string; new_path: string; max_items?: number },
  opts?: ToolHandlerOpts,
): Promise<TruncatedReviewResult> {
  opts?.log?.info('project_review', {
    old: params.old_path,
    new: params.new_path,
  });
  const r = await reviewScan(expandHome(params.old_path), {
    newPath: expandHome(params.new_path),
  });
  const cap = params.max_items ?? REVIEW_MAX_ITEMS;
  if (r.own.length <= cap && r.other.length <= cap) return r;
  return {
    own: r.own.slice(0, cap),
    other: r.other.slice(0, cap),
    truncated: {
      own: Math.max(0, r.own.length - cap),
      other: Math.max(0, r.other.length - cap),
    },
  };
}

// ---------- project_undo ----------

export const projectUndoTool = {
  name: 'project_undo',
  description:
    '⚠️ Cannot run concurrently with other project_* tools; execute sequentially. ' +
    'Reverse a committed project-move migration. Records a new log row with ' +
    'rolled_back_of pointing at the original. Refuses if the migration is ' +
    'not in state=committed (use project_recover for failed/stuck).\n\n' +
    'USAGE RULES:\n' +
    '- Does NOT support dry_run — the reversal is itself symmetric.\n' +
    "- NEVER set force:true unless user EXPLICITLY typed 'force'.\n" +
    '- Tell the user the new migrationId.\n' +
    '- If the migration is stale (later migration overlaid the newPath), this throws UndoStaleError; do not retry.',
  inputSchema: {
    type: 'object' as const,
    required: ['migration_id'],
    properties: {
      migration_id: {
        type: 'string',
        description: 'Migration id returned from an earlier project_move',
      },
      force: {
        type: 'boolean',
        description: 'Bypass git-dirty warning on the current destination',
        default: false,
      },
    },
    additionalProperties: false,
  },
};

export async function handleProjectUndo(
  db: Database,
  params: { migration_id: string; force?: boolean },
  opts?: ToolHandlerOpts,
): Promise<PipelineResult> {
  opts?.log?.info('project_undo', { migrationId: params.migration_id });
  return undoMigration(db, params.migration_id, {
    force: params.force,
    actor: 'mcp',
  });
}

// ---------- project_list_migrations ----------

export const projectListMigrationsTool = {
  name: 'project_list_migrations',
  description:
    'List recent project-move migrations with state, paths, counts, and ' +
    'timestamps. Used to find a migration_id for undo/recover, or to build ' +
    'the daily audit table.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      limit: { type: 'number', default: 20 },
      since: {
        type: 'string',
        description: 'ISO timestamp — only rows started after this',
      },
    },
    additionalProperties: false,
  },
};

const LIST_MIGRATIONS_MAX = 200;

export function handleProjectListMigrations(
  db: Database,
  params: { limit?: number; since?: string },
  opts?: ToolHandlerOpts,
) {
  opts?.log?.info('project_list_migrations', { limit: params.limit });
  const requested = params.limit ?? 20;
  const limit = Math.min(Math.max(1, requested), LIST_MIGRATIONS_MAX);
  return db.listMigrations({
    limit,
    since: params.since,
  });
}

// ---------- project_recover ----------

export const projectRecoverTool = {
  name: 'project_recover',
  description:
    'Diagnose stuck or failed migrations. Reads migration_log rows in ' +
    'state fs_pending/fs_done/failed, probes the filesystem, and returns a ' +
    'per-migration recommendation. Advisory — does NOT modify anything.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      since: { type: 'string', description: 'ISO timestamp filter' },
      include_committed: {
        type: 'boolean',
        description:
          'Also inspect committed migrations (usually unnecessary; costs FS probes)',
        default: false,
      },
    },
    additionalProperties: false,
  },
};

export async function handleProjectRecover(
  db: Database,
  params: { since?: string; include_committed?: boolean },
  opts?: ToolHandlerOpts,
): Promise<RecoverDiagnosis[]> {
  opts?.log?.info('project_recover', {});
  return diagnoseStuckMigrations(db, {
    since: params.since,
    includeCommitted: params.include_committed,
  });
}

// ---------- project_move_batch ----------

export const projectMoveBatchTool = {
  name: 'project_move_batch',
  description:
    '⚠️ Cannot run concurrently with other project_* tools; execute sequentially. ' +
    'Run multiple project moves sequentially from an inline YAML document. ' +
    'Schema v1: version + defaults(stop_on_error, dry_run) + operations ' +
    '[{src, dst|archive:true, archive_to?, note?}]. Halts on first error by ' +
    'default. Use top-level `dry_run: true` to preview the entire batch ' +
    'without side effects (overrides YAML defaults).',
  inputSchema: {
    type: 'object' as const,
    required: ['yaml'],
    properties: {
      yaml: {
        type: 'string',
        description: 'Inline YAML document conforming to schema v1',
      },
      dry_run: {
        type: 'boolean',
        description:
          'If true, all operations run as dry-run regardless of YAML defaults. Useful for previewing a full batch without editing the YAML.',
        default: false,
      },
      force: {
        type: 'boolean',
        description: 'Bypass git-dirty warning on every operation',
        default: false,
      },
    },
    additionalProperties: false,
  },
};

export async function handleProjectMoveBatch(
  db: Database,
  params: { yaml: string; dry_run?: boolean; force?: boolean },
  opts?: ToolHandlerOpts,
) {
  opts?.log?.info('project_move_batch', { bytes: params.yaml.length });
  const raw = parseYaml(params.yaml) as Record<string, unknown>;
  const doc = normalizeBatchDocument(raw);
  // Top-level dry_run overrides the YAML's defaults.dry_run — lets AI
  // preview a batch without modifying the document.
  if (params.dry_run) {
    doc.defaults = { ...doc.defaults, dryRun: true };
  }
  return runBatch(db, doc, { force: params.force });
}
