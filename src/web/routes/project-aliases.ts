import type { Hono } from 'hono';
import type { Database } from '../../core/db.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;
type ProjectAliasDatabase = Pick<
  Database,
  'listProjectAliases' | 'addProjectAlias' | 'removeProjectAlias'
>;

type ProjectAliasBody = { alias?: string; canonical?: string };

export function registerProjectAliasRoutes(
  app: WebApp,
  deps: { db: ProjectAliasDatabase },
) {
  app.get('/api/project-aliases', (c) => {
    return c.json(deps.db.listProjectAliases());
  });

  app.post('/api/project-aliases', async (c) => {
    const body = (await c.req.json()) as ProjectAliasBody;
    if (!body.alias || !body.canonical)
      return c.json({ error: 'alias and canonical required' }, 400);
    deps.db.addProjectAlias(body.alias, body.canonical);
    return c.json({ added: { alias: body.alias, canonical: body.canonical } });
  });

  app.delete('/api/project-aliases', async (c) => {
    const body = (await c.req.json()) as ProjectAliasBody;
    if (!body.alias || !body.canonical)
      return c.json({ error: 'alias and canonical required' }, 400);
    deps.db.removeProjectAlias(body.alias, body.canonical);
    return c.json({
      removed: { alias: body.alias, canonical: body.canonical },
    });
  });
}
