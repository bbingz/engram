import type { Hono } from 'hono';
import { readFileSettings } from '../../core/config.js';
import type { Database } from '../../core/db.js';
import type { SyncEngine, SyncPeer } from '../../core/sync.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;
type SyncDatabase = Pick<
  Database,
  'countSessions' | 'listSessionsAfterCursor' | 'listSessionsSince'
>;

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

export function registerSyncRoutes(
  app: WebApp,
  deps: {
    db: SyncDatabase;
    nodeName?: string;
    syncEngine?: SyncEngine;
    syncPeers?: SyncPeer[];
    parseOptionalPositiveIntParam: (
      name: string,
      raw: string | undefined,
      max: number,
    ) => OptionalIntegerParamResult;
  },
) {
  app.get('/api/sync/status', (c) => {
    return c.json({
      nodeName: deps.nodeName ?? 'unnamed',
      sessionCount: deps.db.countSessions(),
      timestamp: new Date().toISOString(),
    });
  });

  app.get('/api/sync/sessions', (c) => {
    const limit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      500,
    );
    if (!limit.ok) return c.json({ error: limit.error }, 400);
    const resolvedLimit = limit.value ?? 100;
    const cursorIndexedAt = c.req.query('cursor_indexed_at');
    const cursorId = c.req.query('cursor_id');

    if (cursorIndexedAt && cursorId) {
      return c.json({
        sessions: deps.db.listSessionsAfterCursor(
          { indexedAt: cursorIndexedAt, sessionId: cursorId },
          resolvedLimit,
        ),
      });
    }

    const since = c.req.query('since');
    if (!since) return c.json({ error: 'since parameter required' }, 400);
    return c.json({
      sessions: deps.db.listSessionsSince(since, resolvedLimit),
    });
  });

  app.post('/api/sync/trigger', async (c) => {
    if (!deps.syncEngine) {
      return c.json({ error: 'Sync not configured' }, 501);
    }
    const freshSettings = readFileSettings();
    const freshPeers = freshSettings.syncPeers ?? deps.syncPeers ?? [];
    if (!freshPeers.length) {
      return c.json({ error: 'No peers configured' }, 400);
    }
    const peerName = c.req.query('peer');
    const peers = peerName
      ? freshPeers.filter((p) => p.name === peerName)
      : freshPeers;

    const results = await deps.syncEngine.syncAllPeers(peers);
    return c.json({ results });
  });
}
