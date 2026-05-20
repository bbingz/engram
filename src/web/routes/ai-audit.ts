import type { Hono } from 'hono';
import type { AiAuditQuery } from '../../core/ai-audit.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;

type IntegerParamResult =
  | { ok: true; value: number }
  | { ok: false; error: string };

type PaginationResult =
  | { ok: true; offset: number; limit: number }
  | { ok: false; error: string };

export function registerAiAuditRoutes(
  app: WebApp,
  deps: {
    auditQuery?: AiAuditQuery;
    parsePaginationParams: (
      rawOffset: string | undefined,
      rawLimit: string | undefined,
      defaultLimit: number,
      maxLimit: number,
    ) => PaginationResult;
    parsePositiveInteger: (
      name: string,
      raw: string | undefined,
    ) => IntegerParamResult;
  },
) {
  app.get('/api/ai/audit', (c) => {
    if (!deps.auditQuery) return c.json({ error: 'Audit not configured' }, 501);
    const q = c.req.query();
    const pagination = deps.parsePaginationParams(q.offset, q.limit, 50, 500);
    if (!pagination.ok) return c.json({ error: pagination.error }, 400);
    const result = deps.auditQuery.list({
      caller: q.caller || undefined,
      model: q.model || undefined,
      sessionId: q.sessionId || undefined,
      from: q.from || undefined,
      to: q.to || undefined,
      hasError:
        q.hasError === 'true'
          ? true
          : q.hasError === 'false'
            ? false
            : undefined,
      limit: pagination.limit,
      offset: pagination.offset,
    });
    return c.json({
      ...result,
      limit: pagination.limit,
      offset: pagination.offset,
    });
  });

  app.get('/api/ai/audit/:id', (c) => {
    if (!deps.auditQuery) return c.json({ error: 'Audit not configured' }, 501);
    const id = deps.parsePositiveInteger('id', c.req.param('id'));
    if (!id.ok) return c.json({ error: id.error }, 400);
    const record = deps.auditQuery.get(id.value);
    if (!record) return c.json({ error: 'not found' }, 404);
    return c.json(record);
  });

  app.get('/api/ai/stats', (c) => {
    if (!deps.auditQuery) return c.json({ error: 'Audit not configured' }, 501);
    const q = c.req.query();
    return c.json(
      deps.auditQuery.stats({
        from: q.from || undefined,
        to: q.to || undefined,
      }),
    );
  });
}
