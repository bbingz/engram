import type { Hono } from 'hono';
import type { Database } from '../../core/db.js';
import {
  buildErrorEnvelope,
  type ErrorEnvelope,
  mapErrorStatus,
} from '../../core/project-move/retry-policy.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

type NormalizedPathResult =
  | { ok: true; path: string }
  | { ok: false; error: string };

const KNOWN_ACTORS = ['cli', 'mcp', 'swift-ui', 'batch'] as const;
type KnownActor = (typeof KNOWN_ACTORS)[number];

function parseActor(
  raw: unknown,
): { ok: true; actor: KnownActor } | { ok: false; error: string } {
  if (raw === undefined || raw === null) return { ok: true, actor: 'swift-ui' };
  if (
    typeof raw !== 'string' ||
    !(KNOWN_ACTORS as readonly string[]).includes(raw)
  ) {
    return {
      ok: false,
      error: `actor must be one of: ${KNOWN_ACTORS.join(', ')}`,
    };
  }
  return { ok: true, actor: raw as KnownActor };
}

function mapProjectMoveError(err: unknown): ErrorEnvelope {
  return buildErrorEnvelope(err, { sanitize: true });
}

function mapProjectMoveErrorStatus(err: unknown): 400 | 409 | 500 {
  return mapErrorStatus((err as Error)?.name);
}

function validationError(name: string, message: string): ErrorEnvelope {
  return { error: { name, message, retry_policy: 'never' } };
}

export function registerProjectMigrationRoutes(
  app: WebApp,
  deps: {
    db: Database;
    parseOptionalPositiveIntParam: (
      name: string,
      raw: string | undefined,
      max: number,
    ) => OptionalIntegerParamResult;
    normalizeHttpPath: (raw: string | undefined) => NormalizedPathResult;
  },
) {
  // GET /api/project/migrations — recent migrations (defaults to committed
  // only, limit 20). Used by UndoSheet to pick a row to reverse.
  app.get('/api/project/migrations', (c) => {
    const parsedLimit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      100,
    );
    if (!parsedLimit.ok) {
      return c.json(validationError('InvalidParam', parsedLimit.error), 400);
    }
    const limit = parsedLimit.value ?? 20;
    const stateFilter = c.req.query('state');
    const validStates = ['fs_pending', 'fs_done', 'committed', 'failed'];
    if (stateFilter && !validStates.includes(stateFilter)) {
      return c.json(
        validationError(
          'InvalidParam',
          `state must be one of ${validStates.join(', ')}`,
        ),
        400,
      );
    }
    const rows = deps.db.listMigrations({
      limit,
      state: stateFilter as
        | 'fs_pending'
        | 'fs_done'
        | 'committed'
        | 'failed'
        | undefined,
    });
    return c.json({ migrations: rows });
  });

  // GET /api/project/cwds?project=<name> — distinct cwds for a project
  // grouping. MVP assumes most projects map to a single cwd; multi-cwd
  // cases let the UI present a picker.
  app.get('/api/project/cwds', (c) => {
    const project = c.req.query('project');
    if (!project) {
      return c.json(
        validationError('MissingParam', 'project query param required'),
        400,
      );
    }
    const raw = deps.db.getRawDb();
    const rows = raw
      .prepare(
        `SELECT DISTINCT cwd FROM sessions
         WHERE project = @project AND cwd IS NOT NULL AND cwd != ''
         ORDER BY cwd`,
      )
      .all({ project }) as Array<{ cwd: string }>;
    return c.json({ project, cwds: rows.map((r) => r.cwd) });
  });

  app.post('/api/project/move', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as {
      src?: string;
      dst?: string;
      dryRun?: boolean;
      force?: boolean;
      auditNote?: string;
      actor?: string;
    };
    if (!body.src || !body.dst) {
      return c.json(
        validationError('MissingParam', 'src and dst required'),
        400,
      );
    }
    const actorResult = parseActor(body.actor);
    if (!actorResult.ok) {
      return c.json(validationError('InvalidActor', actorResult.error), 400);
    }
    const srcResolved = deps.normalizeHttpPath(body.src);
    const dstResolved = deps.normalizeHttpPath(body.dst);
    if (!srcResolved.ok) {
      return c.json(
        validationError('InvalidPath', `src: ${srcResolved.error}`),
        400,
      );
    }
    if (!dstResolved.ok) {
      return c.json(
        validationError('InvalidPath', `dst: ${dstResolved.error}`),
        400,
      );
    }
    const { runProjectMove } = await import(
      '../../core/project-move/orchestrator.js'
    );
    try {
      const result = await runProjectMove(deps.db, {
        src: srcResolved.path,
        dst: dstResolved.path,
        dryRun: body.dryRun === true,
        force: body.force === true,
        auditNote: body.auditNote,
        actor: actorResult.actor,
      });
      return c.json(result);
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });

  app.post('/api/project/undo', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as {
      migrationId?: string;
      force?: boolean;
      actor?: string;
    };
    if (!body.migrationId) {
      return c.json(
        validationError('MissingParam', 'migrationId required'),
        400,
      );
    }
    const actorResult = parseActor(body.actor);
    if (!actorResult.ok) {
      return c.json(validationError('InvalidActor', actorResult.error), 400);
    }
    const { undoMigration } = await import('../../core/project-move/undo.js');
    try {
      const result = await undoMigration(deps.db, body.migrationId, {
        force: body.force === true,
        actor: actorResult.actor,
      });
      return c.json(result);
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });

  app.post('/api/project/archive', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as {
      src?: string;
      archiveTo?: string;
      force?: boolean;
      dryRun?: boolean;
      auditNote?: string;
      actor?: string;
    };
    if (!body.src)
      return c.json(validationError('MissingParam', 'src required'), 400);
    const actorResult = parseActor(body.actor);
    if (!actorResult.ok) {
      return c.json(validationError('InvalidActor', actorResult.error), 400);
    }
    const srcResolved = deps.normalizeHttpPath(body.src);
    if (!srcResolved.ok) {
      return c.json(
        validationError('InvalidPath', `src: ${srcResolved.error}`),
        400,
      );
    }
    const { runProjectMove } = await import(
      '../../core/project-move/orchestrator.js'
    );
    const { suggestArchiveTarget } = await import(
      '../../core/project-move/archive.js'
    );
    try {
      const suggestion = await suggestArchiveTarget(srcResolved.path, {
        forceCategory: body.archiveTo,
      });
      if (body.dryRun !== true) {
        const { mkdir } = await import('node:fs/promises');
        const { dirname } = await import('node:path');
        await mkdir(dirname(suggestion.dst), { recursive: true });
      }
      const result = await runProjectMove(deps.db, {
        src: srcResolved.path,
        dst: suggestion.dst,
        archived: true,
        force: body.force === true,
        dryRun: body.dryRun === true,
        auditNote: body.auditNote ?? `archive: ${suggestion.reason}`,
        actor: actorResult.actor,
      });
      return c.json({ ...result, suggestion });
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });

  app.post('/api/project/move-batch', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as {
      yaml?: string;
      dryRun?: boolean;
      force?: boolean;
    };
    if (!body.yaml || typeof body.yaml !== 'string') {
      return c.json(
        validationError('MissingParam', 'yaml (string) required'),
        400,
      );
    }
    const { parseBatchYaml } = await import('../../tools/project.js');
    const { normalizeBatchDocument, runBatch } = await import(
      '../../core/project-move/batch.js'
    );
    try {
      const raw = parseBatchYaml(body.yaml);
      const doc = normalizeBatchDocument(raw);
      if (body.dryRun === true) {
        doc.defaults = { ...doc.defaults, dryRun: true };
      }
      const result = await runBatch(deps.db, doc, {
        force: body.force === true,
      });
      return c.json(result);
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });
}
