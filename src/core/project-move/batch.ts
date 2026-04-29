// src/core/project-move/batch.ts — YAML-driven multi-migration runner.
//
// Schema v1 (frozen per Codex review feedback):
//   version: 1
//   defaults:                (optional)
//     stop_on_error: bool    (default: true)
//     dry_run: bool          (default: false)
//   operations:
//     - src: "/abs/path"
//       dst: "/abs/path"     (XOR with archive:true)
//       note: "..."          (optional, stored in migration_log.audit_note)
//     - src: "/abs/path"
//       archive: true        (auto-detects target via suggestArchiveTarget)
//       archive_to: "历史脚本" (optional, forces category)
//       note: "..."
//   continue_from: <migration-id>  (v1.1 — not yet wired; schema placeholder)

import { mkdir, readFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { parse as parseYaml } from 'yaml';
import type { Database } from '../db.js';
import { type ArchiveCategory, suggestArchiveTarget } from './archive.js';
import {
  type PipelineResult,
  type RunProjectMoveOpts,
  runProjectMove,
} from './orchestrator.js';
import { expandHome } from './paths.js';

interface BatchOperation {
  src: string;
  dst?: string;
  archive?: boolean;
  archiveTo?: ArchiveCategory;
  note?: string;
}

interface BatchDocument {
  version: number;
  defaults?: {
    stopOnError?: boolean;
    dryRun?: boolean;
  };
  operations: BatchOperation[];
  continueFrom?: string;
}

export interface BatchResult {
  completed: PipelineResult[];
  failed: Array<{ operation: BatchOperation; error: string }>;
  skipped: BatchOperation[];
}

export async function loadBatchFile(path: string): Promise<BatchDocument> {
  const text = await readFile(path, 'utf8');
  const raw = parseYaml(text) as Record<string, unknown>;
  return normalizeBatchDocument(raw);
}

export function normalizeBatchDocument(
  raw: Record<string, unknown>,
): BatchDocument {
  if (!raw || typeof raw !== 'object') {
    throw new Error('batch: document must be a YAML map');
  }
  if (raw.version !== 1) {
    throw new Error(
      `batch: unsupported schema version ${raw.version}, expected 1`,
    );
  }
  if (!Array.isArray(raw.operations)) {
    throw new Error('batch: `operations` must be a list');
  }
  const defaults = (raw.defaults ?? {}) as Record<string, unknown>;
  const operations: BatchOperation[] = raw.operations.map((o, idx) => {
    const op = o as Record<string, unknown>;
    if (typeof op.src !== 'string' || !op.src) {
      throw new Error(`batch.operations[${idx}]: src is required (string)`);
    }
    const hasDst = typeof op.dst === 'string' && !!op.dst;
    const hasArchive = op.archive === true;
    if (hasDst === hasArchive) {
      throw new Error(
        `batch.operations[${idx}]: exactly one of dst|archive must be set`,
      );
    }
    return {
      src: op.src,
      dst: hasDst ? (op.dst as string) : undefined,
      archive: hasArchive || undefined,
      archiveTo: (op.archive_to ?? op.archiveTo) as ArchiveCategory | undefined,
      note: typeof op.note === 'string' ? op.note : undefined,
    };
  });
  // v1 reserves `continue_from` but does not yet execute it. Gemini major #4
  // + Codex 4a: silently parsing a control-flow directive and ignoring it is
  // a UX trap (user would re-run already-completed moves). Throw loud.
  if (typeof raw.continue_from === 'string' && raw.continue_from) {
    throw new Error(
      'batch: `continue_from` is reserved in v1 but not yet executable. ' +
        'Remove it from the YAML or wait for a later version.',
    );
  }

  return {
    version: 1,
    defaults: {
      stopOnError: defaults.stop_on_error !== false, // default true
      dryRun: defaults.dry_run === true, // default false
    },
    operations,
    continueFrom: undefined,
  };
}

/**
 * Run a batch of project moves sequentially. `stopOnError` halts the whole
 * batch on first failure (default); otherwise each failure is collected
 * and the batch continues. Returns per-op results for the caller to render.
 */
export async function runBatch(
  db: Database,
  doc: BatchDocument,
  cliOpts: Pick<RunProjectMoveOpts, 'home' | 'lockPath' | 'force'> = {},
): Promise<BatchResult> {
  const stopOnError = doc.defaults?.stopOnError !== false;
  const dryRun = doc.defaults?.dryRun === true;
  const result: BatchResult = {
    completed: [],
    failed: [],
    skipped: [],
  };
  let halted = false;

  for (const op of doc.operations) {
    if (halted) {
      result.skipped.push(op);
      continue;
    }
    // Expand ~ in src (Codex Q3 + Gemini: AI often writes `~/proj` in YAML).
    const src = expandHome(op.src);
    let dst: string;
    if (op.dst) {
      dst = expandHome(op.dst);
    } else if (op.archive) {
      // self-review M4: honor archive_to override (parse already handles
      // it; runBatch previously dropped it on the floor).
      const suggestion = await suggestArchiveTarget(src, {
        forceCategory: op.archiveTo,
      });
      dst = suggestion.dst;
      // Codex Q10-2: ensure _archive/<category>/ exists — runProjectMove
      // calls safeMoveDir which won't create missing parents.
      await mkdir(dirname(dst), { recursive: true });
    } else {
      result.failed.push({ operation: op, error: 'missing dst/archive' });
      if (stopOnError) halted = true;
      continue;
    }

    try {
      const res = await runProjectMove(db, {
        ...cliOpts,
        src,
        dst,
        archived: op.archive === true,
        auditNote: op.note,
        actor: 'batch',
        dryRun,
      });
      result.completed.push(res);
    } catch (err) {
      result.failed.push({
        operation: op,
        error: (err as Error).message,
      });
      if (stopOnError) halted = true;
    }
  }
  return result;
}
