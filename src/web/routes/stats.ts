import type { Hono } from 'hono';
import type { Database } from '../../core/db.js';
import type { UsageCollector } from '../../core/usage-collector.js';
import { handleGetCosts } from '../../tools/get_costs.js';
import { handleStats } from '../../tools/stats.js';
import { handleToolAnalytics } from '../../tools/tool_analytics.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

export function registerStatsRoutes(
  app: WebApp,
  deps: {
    db: Database;
    usageCollector?: UsageCollector;
    parseOptionalPositiveIntParam: (
      name: string,
      raw: string | undefined,
      max: number,
    ) => OptionalIntegerParamResult;
  },
) {
  app.get('/api/stats', async (c) => {
    const since = c.req.query('since');
    const until = c.req.query('until');
    const group_by = c.req.query('group_by');
    const exclude_noise = c.req.query('exclude_noise') !== '0';

    const result = await handleStats(deps.db, {
      since,
      until,
      group_by,
      exclude_noise,
    });
    return c.json(result);
  });

  app.get('/api/costs', (c) => {
    const group_by = c.req.query('group_by');
    const since = c.req.query('since');
    const until = c.req.query('until');
    const result = handleGetCosts(deps.db, { group_by, since, until });
    return c.json(result);
  });

  app.get('/api/costs/sessions', (c) => {
    const rawLimit = parseInt(c.req.query('limit') || '20', 10);
    const limit = Math.min(
      Math.max(Number.isNaN(rawLimit) ? 20 : rawLimit, 1),
      100,
    );
    const rows = deps.db
      .getRawDb()
      .prepare(`
      SELECT c.*, s.source, s.project, s.start_time, s.summary
      FROM session_costs c JOIN sessions s ON c.session_id = s.id
      ORDER BY c.cost_usd DESC LIMIT ?
    `)
      .all(limit);
    return c.json({ sessions: rows });
  });

  app.get('/api/file-activity', (c) => {
    const project = c.req.query('project');
    const since = c.req.query('since');
    const limit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      500,
    );
    if (!limit.ok) return c.json({ error: limit.error }, 400);
    const result = deps.db.getFileActivity({
      project: project ?? undefined,
      since: since ?? undefined,
      limit: limit.value,
    });
    return c.json({ files: result, totalFiles: result.length });
  });

  app.get('/api/tool-analytics', (c) => {
    const project = c.req.query('project');
    const since = c.req.query('since');
    const group_by = c.req.query('group_by');
    const result = handleToolAnalytics(deps.db, { project, since, group_by });
    return c.json(result);
  });

  app.get('/api/usage', (c) => {
    const latest = deps.usageCollector?.getLatest() ?? [];
    return c.json({ usage: latest });
  });

  app.get('/api/repos', (c) => {
    const rows = deps.db
      .getRawDb()
      .prepare('SELECT * FROM git_repos ORDER BY last_commit_at DESC')
      .all();
    return c.json({ repos: rows });
  });
}
