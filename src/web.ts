import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve as pathResolve } from 'node:path';
import { Hono } from 'hono';
import type { SessionAdapter, SourceName } from './adapters/types.js';
import type { AiAuditQuery, AiAuditWriter } from './core/ai-audit.js';
import { summarizeConversation } from './core/ai-client.js';
import { ensureDataDirs, getAdapter } from './core/bootstrap.js';
import type { FileSettings } from './core/config.js';
import { readFileSettings } from './core/config.js';
import { Database } from './core/db.js';
import type { EmbeddingClient } from './core/embeddings.js';
import type { LiveSessionMonitor } from './core/live-sessions.js';
import type { LogWriter } from './core/logger.js';
import type { MetricsCollector } from './core/metrics.js';
import { clearMockData, populateMockData } from './core/mock-data.js';
import type { BackgroundMonitor } from './core/monitor.js';
import {
  buildErrorEnvelope,
  type ErrorEnvelope,
  mapErrorStatus,
} from './core/project-move/retry-policy.js';
import { runWithContext } from './core/request-context.js';
import { buildResumeCommand } from './core/resume-coordinator.js';
import type { SyncEngine, SyncPeer } from './core/sync.js';
import type { TitleGenerator } from './core/title-generator.js';
import type { Tracer } from './core/tracer.js';
import { withSpan } from './core/tracer.js';
import type { UsageCollector } from './core/usage-collector.js';
import type { VectorStore } from './core/vector-store.js';
import { WATCHED_SOURCES } from './core/watcher.js';
import { handleGetCosts } from './tools/get_costs.js';
import { handleHandoff } from './tools/handoff.js';
import { handleLinkSessions } from './tools/link_sessions.js';
import { handleLintConfig, runAllHealthChecks } from './tools/lint_config.js';
import { handleSaveInsight } from './tools/save_insight.js';
import { handleSearch, type SearchDeps } from './tools/search.js';
import { handleStats } from './tools/stats.js';
import { handleToolAnalytics } from './tools/tool_analytics.js';
import {
  healthPage,
  layout,
  searchPage,
  sessionDetailPage,
  sessionListPage,
  settingsPage,
  statsPage,
} from './web/views.js';

function createRateLimiter(maxPerMinute: number) {
  const timestamps: number[] = [];
  return (): boolean => {
    const now = Date.now();
    while (timestamps.length > 0 && timestamps[0] < now - 60_000)
      timestamps.shift();
    if (timestamps.length >= maxPerMinute) return false;
    timestamps.push(now);
    return true;
  };
}

/** Round 4: retry_policy classification + error-envelope construction +
 *  message sanitization all live in src/core/project-move/retry-policy.ts
 *  so MCP (src/index.ts) and HTTP (here) share one implementation.
 *  Previously the two diverged — unknown errors got 'never' from MCP but
 *  'safe' from HTTP, and structured DirCollisionError fields were dropped. */
function mapProjectMoveError(err: unknown): ErrorEnvelope {
  return buildErrorEnvelope(err, { sanitize: true });
}

// Phase B Step 3: actor threads through to migration_log for audit. Originally
// actor==='mcp' also bypassed $HOME confinement ("MCP is a trusted local
// peer") but the 6-way review flagged this as weak defense-in-depth —
// trust was being derived from an unauthenticated body string, so any local
// process could self-declare as MCP and escape the guard. Reverted in Round
// 1 hotfix: actor is audit-only; every actor respects $HOME confinement.
// Invalid actor → hard 400 to keep the audit field honest.
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

function mapProjectMoveErrorStatus(err: unknown): 400 | 409 | 500 {
  return mapErrorStatus((err as Error)?.name);
}

/** Build a 400 validation-error envelope identical in shape to the
 *  orchestrator error envelope so the Swift client can decode uniformly
 *  (Codex minor #4). `retry_policy: 'never'` — client must fix input. */
function validationError(name: string, message: string): ErrorEnvelope {
  return { error: { name, message, retry_policy: 'never' } };
}

/** Normalize a user-supplied path: expand `~`, resolve `..` / `.` segments,
 *  require absolute, and confine to `$HOME` unless the caller explicitly
 *  opts out via settings. Matches the defense-in-depth already present on
 *  `/api/lint` (review follow-up Important #2 + Minor #11). Returns the
 *  canonicalized path on success.
 *
 *  The HOME confinement matters most when no bearer token is set — the
 *  HTTP layer is localhost-only, but any process on the box can still hit
 *  it. Restricting to $HOME caps the blast radius of a stray request to
 *  the user's own files. */
function normalizeHttpPath(
  raw: string | undefined,
  opts: { allowOutsideHome?: boolean } = {},
): { ok: true; path: string } | { ok: false; error: string } {
  if (!raw || typeof raw !== 'string') {
    return { ok: false, error: 'missing or non-string path' };
  }
  let p = raw;
  if (p === '~') p = homedir();
  else if (p.startsWith('~/')) p = `${homedir()}/${p.slice(2)}`;
  if (!p.startsWith('/')) {
    return {
      ok: false,
      error: `path must be absolute (got "${raw}"). Use /full/path/... or ~/rel/path.`,
    };
  }
  // Canonicalize — pathResolve collapses `..` / `.` so `~/../../etc/passwd`
  // becomes `/etc/passwd` and can be checked against $HOME honestly.
  const canonical = pathResolve(p);
  if (!opts.allowOutsideHome) {
    const home = homedir();
    if (canonical !== home && !canonical.startsWith(`${home}/`)) {
      return {
        ok: false,
        error: `path must live under ${home} (got "${canonical}"). Use the CLI for paths outside your home directory.`,
      };
    }
  }
  return { ok: true, path: canonical };
}

// --- CIDR access control ---

export function ipToUint32(ip: string): number {
  const parts = ip.split('.').map(Number);
  return (
    ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
  );
}

export function parseCIDR(cidr: string): { network: number; mask: number } {
  const [ip, prefixStr] = cidr.split('/');
  const prefix = Number(prefixStr ?? 32);
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  return { network: (ipToUint32(ip) & mask) >>> 0, mask };
}

export function ipMatchesCIDR(
  ip: string,
  cidrs: Array<{ network: number; mask: number }>,
): boolean {
  // Always allow loopback
  if (ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1')
    return true;
  // Normalize IPv4-mapped IPv6
  const v4 = ip.startsWith('::ffff:') ? ip.slice(7) : ip;
  if (v4.includes(':')) return false; // IPv6 not supported for CIDR matching
  const addr = ipToUint32(v4);
  return cidrs.some((c) => (addr & c.mask) >>> 0 === c.network);
}

export function createApp(
  db: Database,
  opts?: {
    vectorStore?: VectorStore;
    embeddingClient?: EmbeddingClient;
    syncEngine?: SyncEngine;
    syncPeers?: SyncPeer[];
    settings?: FileSettings;
    adapters?: SessionAdapter[];
    usageCollector?: UsageCollector;
    titleGenerator?: TitleGenerator;
    liveMonitor?: LiveSessionMonitor;
    backgroundMonitor?: BackgroundMonitor;
    logWriter?: LogWriter;
    metrics?: MetricsCollector;
    tracer?: Tracer;
    audit?: AiAuditWriter;
    auditQuery?: AiAuditQuery;
  },
) {
  type Variables = { traceId: string };
  const app = new Hono<{ Variables: Variables }>();
  const settings = opts?.settings ?? readFileSettings();
  const semanticLimiter = createRateLimiter(30);

  // CIDR access control — only active when listening beyond localhost
  const host = settings.httpHost ?? '127.0.0.1';
  if (host !== '127.0.0.1' && settings.httpAllowCIDR?.length) {
    const allowedCIDRs = settings.httpAllowCIDR.map(parseCIDR);
    type ConnInfoFn = (c: unknown) => { remote: { address?: string } };
    let _getConnInfo: ConnInfoFn | null = null;
    app.use('*', async (c, next) => {
      if (!_getConnInfo) {
        const mod = await import('@hono/node-server/conninfo');
        _getConnInfo = mod.getConnInfo as unknown as ConnInfoFn;
      }
      const clientIP = _getConnInfo(c)?.remote?.address ?? '127.0.0.1';
      if (!ipMatchesCIDR(clientIP, allowedCIDRs)) {
        return c.text('Forbidden', 403);
      }
      await next();
    });
  }

  // Security headers + CORS
  app.use('*', async (c, next) => {
    c.header('X-Content-Type-Options', 'nosniff');
    c.header('X-Frame-Options', 'DENY');
    const origin = c.req.header('origin');
    if (origin) {
      try {
        const url = new URL(origin);
        const isLocal =
          url.hostname === '127.0.0.1' ||
          url.hostname === 'localhost' ||
          url.hostname === '::1';
        // SECURITY: Allows any localhost port — acceptable for local dev tool.
        // For production deployments, bind to specific interface and use bearer auth.
        if (!isLocal) {
          return c.text('CORS rejected', 403);
        }
        // Set CORS headers for valid localhost origins
        c.header('Access-Control-Allow-Origin', origin);
        c.header(
          'Access-Control-Allow-Methods',
          'GET, POST, PUT, DELETE, PATCH, OPTIONS',
        );
        c.header(
          'Access-Control-Allow-Headers',
          'Content-Type, Authorization, X-Trace-Id',
        );
        if (c.req.method === 'OPTIONS') {
          return new Response(null, { status: 204 });
        }
      } catch {
        return c.text('CORS rejected', 403);
      }
    }
    await next();
  });

  // Trace propagation middleware — extract or generate X-Trace-Id for cross-process correlation
  app.use('*', async (c, next) => {
    const requestId = c.req.header('x-trace-id') ?? randomUUID();
    c.set('traceId', requestId);
    c.header('X-Trace-Id', requestId);
    return runWithContext({ requestId, source: 'http' }, () => next());
  });

  // Request tracing — creates a span for every HTTP request
  if (opts?.tracer) {
    const tracerRef = opts.tracer;
    app.use('*', async (c, next) => {
      const pathPrefix = c.req.path.split('/').slice(0, 3).join('/');
      await withSpan(
        tracerRef,
        `http.${c.req.method}.${pathPrefix}`,
        'http',
        async (span) => {
          await next();
          span.setAttribute('status', c.res.status);
        },
      );
    });
  }

  // Request metrics middleware
  if (opts?.metrics) {
    const metricsRef = opts.metrics;
    app.use('*', async (c, next) => {
      const start = Date.now();
      await next();
      metricsRef.counter('http.requests', 1, {
        method: c.req.method,
        path: c.req.path.split('/').slice(0, 3).join('/'),
      });
      metricsRef.histogram('http.duration_ms', Date.now() - start, {
        method: c.req.method,
      });
      if (c.res.status >= 400) {
        metricsRef.counter('http.error_count', 1, {
          status: String(c.res.status),
          path: c.req.path.split('/').slice(0, 3).join('/'),
        });
      }
    });
  }

  // Bearer token auth on write endpoints — scoped to /api/* only.
  // Codex major #1: when the caller did NOT inject a `settings` object, the
  // token is re-read per request so the user can rotate it in settings.json
  // without restarting the daemon. When `settings` IS injected (tests, or
  // non-file-backed deployments), the snapshot is used so tests stay
  // deterministic.
  //
  // 401 responses use a JSON envelope (same shape as validation errors) so
  // clients like the Swift DaemonClient can decode uniformly instead of
  // falling through to a generic HTTP error.
  const injectedSettings = opts?.settings;
  const resolveBearerToken = (): string | undefined => {
    if (injectedSettings) return injectedSettings.httpBearerToken;
    return readFileSettings().httpBearerToken;
  };
  const unauthorizedJson = () =>
    ({
      error: {
        name: 'Unauthorized',
        message: 'Invalid or missing bearer token',
        retry_policy: 'never',
      },
    }) as const;

  if (settings.httpBearerToken) {
    const WRITE_METHODS = new Set(['POST', 'PUT', 'DELETE', 'PATCH']);
    app.use('/api/*', async (c, next) => {
      if (WRITE_METHODS.has(c.req.method)) {
        const currentToken = resolveBearerToken();
        if (!currentToken) {
          // Token was removed at runtime — treat as open (local-dev default).
          await next();
          return;
        }
        const auth = c.req.header('authorization');
        if (auth !== `Bearer ${currentToken}`) {
          return c.json(unauthorizedJson(), 401);
        }
      }
      await next();
    });
  }

  // Bearer auth for /api/ai/* GET endpoints (audit data may contain sensitive content).
  if (settings.httpBearerToken) {
    app.use('/api/ai/*', async (c, next) => {
      const currentToken = resolveBearerToken();
      if (!currentToken) {
        await next();
        return;
      }
      const auth = c.req.header('authorization');
      if (auth !== `Bearer ${currentToken}`) {
        return c.json(unauthorizedJson(), 401);
      }
      await next();
    });
  }

  // --- AI Audit API ---
  app.get('/api/ai/audit', (c) => {
    if (!opts?.auditQuery)
      return c.json({ error: 'Audit not configured' }, 501);
    const q = c.req.query();
    const limit = q.limit ? parseInt(q.limit, 10) : 50;
    const offset = q.offset ? parseInt(q.offset, 10) : 0;
    const result = opts.auditQuery.list({
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
      limit,
      offset,
    });
    return c.json({ ...result, limit, offset });
  });

  app.get('/api/ai/audit/:id', (c) => {
    if (!opts?.auditQuery)
      return c.json({ error: 'Audit not configured' }, 501);
    const record = opts.auditQuery.get(parseInt(c.req.param('id'), 10));
    if (!record) return c.json({ error: 'not found' }, 404);
    return c.json(record);
  });

  app.get('/api/ai/stats', (c) => {
    if (!opts?.auditQuery)
      return c.json({ error: 'Audit not configured' }, 501);
    const q = c.req.query();
    return c.json(
      opts.auditQuery.stats({
        from: q.from || undefined,
        to: q.to || undefined,
      }),
    );
  });

  app.get('/api/sync/status', (c) => {
    return c.json({
      nodeName: settings.syncNodeName ?? 'unnamed',
      sessionCount: db.countSessions(),
      timestamp: new Date().toISOString(),
    });
  });

  // Sync: sessions since timestamp
  app.get('/api/sync/sessions', (c) => {
    const limit = parseInt(c.req.query('limit') ?? '100', 10);
    const cursorIndexedAt = c.req.query('cursor_indexed_at');
    const cursorId = c.req.query('cursor_id');

    let sessions:
      | ReturnType<typeof db.listSessionsSince>
      | ReturnType<typeof db.listSessionsAfterCursor>;
    if (cursorIndexedAt && cursorId) {
      sessions = db.listSessionsAfterCursor(
        { indexedAt: cursorIndexedAt, sessionId: cursorId },
        limit,
      );
    } else {
      const since = c.req.query('since');
      if (!since) return c.json({ error: 'since parameter required' }, 400);
      sessions = db.listSessionsSince(since, limit);
    }

    return c.json({ sessions });
  });

  // Sync: manual trigger (re-reads peers from config to pick up Swift UI changes)
  app.post('/api/sync/trigger', async (c) => {
    if (!opts?.syncEngine) {
      return c.json({ error: 'Sync not configured' }, 501);
    }
    const freshSettings = readFileSettings();
    const freshPeers = freshSettings.syncPeers ?? opts.syncPeers ?? [];
    if (!freshPeers.length) {
      return c.json({ error: 'No peers configured' }, 400);
    }
    const peerName = c.req.query('peer');
    const peers = peerName
      ? freshPeers.filter((p) => p.name === peerName)
      : freshPeers;

    const results = await opts.syncEngine.syncAllPeers(peers);
    return c.json({ results });
  });

  // General status
  app.get('/api/status', async (c) => {
    const totalSessions = db.countSessions();
    const sources = db.listSources();
    const projects = db.listProjects();
    const embeddedCount = opts?.vectorStore?.count() ?? 0;
    const embeddingAvailable = !!(opts?.vectorStore && opts?.embeddingClient);
    return c.json({
      totalSessions,
      sourceCount: sources.length,
      projectCount: projects.length,
      sources,
      projects,
      embeddingAvailable,
      embeddedCount,
    });
  });

  // Session list
  app.get('/api/sessions', (c) => {
    const source = c.req.query('source') as SourceName | undefined;
    const project = c.req.query('project');
    const origin = c.req.query('origin');
    const since = c.req.query('since');
    const until = c.req.query('until');
    const limitParam = c.req.query('limit');
    const offsetParam = c.req.query('offset');

    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 20, 100);
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0;

    const sessions = db.listSessions({
      source,
      project,
      origin,
      since,
      until,
      limit,
      offset,
    });
    return c.json({
      sessions,
      offset,
      limit,
      hasMore: sessions.length === limit,
    });
  });

  // Session detail
  app.get('/api/sessions/:id', (c) => {
    const session = db.getSession(c.req.param('id'));
    if (!session) {
      return c.json({ error: 'Session not found' }, 404);
    }
    return c.json(session);
  });

  // --- Parent link management ---

  app.post('/api/sessions/:id/link', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ parentId: string }>();
    if (!body?.parentId) return c.json({ error: 'parentId required' }, 400);
    const validation = db.validateParentLink(sessionId, body.parentId);
    if (validation !== 'ok') return c.json({ error: validation }, 400);
    db.setParentSession(sessionId, body.parentId, 'manual');
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/link', (c) => {
    const sessionId = c.req.param('id');
    db.clearParentSession(sessionId);
    return c.json({ ok: true });
  });

  app.post('/api/sessions/:id/confirm-suggestion', (c) => {
    const sessionId = c.req.param('id');
    const result = db.confirmSuggestion(sessionId);
    if (!result.ok) return c.json({ error: result.error }, 400);
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/suggestion', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ suggestedParentId: string }>();
    if (!body?.suggestedParentId)
      return c.json({ error: 'suggestedParentId required' }, 400);
    const cleared = db.clearSuggestedParent(sessionId, body.suggestedParentId);
    if (!cleared) return c.json({ error: 'stale-suggestion' }, 409);
    return c.json({ ok: true });
  });

  app.get('/api/sessions/:id/children', (c) => {
    const parentId = c.req.param('id');
    const limitParam = c.req.query('limit');
    const offsetParam = c.req.query('offset');
    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 20, 100);
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0;
    const confirmed = db.childSessions(parentId, limit, offset);
    const suggested = db.suggestedChildSessions(parentId);
    return c.json({ confirmed, suggested });
  });

  // Session timeline for replay
  app.get('/api/sessions/:id/timeline', async (c) => {
    const session = db.getSession(c.req.param('id'));
    if (!session) return c.json({ error: 'Session not found' }, 404);

    const adapter = opts?.adapters?.find((a) => a.name === session.source);
    if (!adapter)
      return c.json({ error: `No adapter for source: ${session.source}` }, 500);

    const limitParam = c.req.query('limit');
    const offsetParam = c.req.query('offset');
    const limit = limitParam ? parseInt(limitParam, 10) : undefined;
    if (limit !== undefined && (Number.isNaN(limit) || limit < 1))
      return c.json({ error: 'limit must be a positive integer' }, 400);
    const clampedLimit = limit !== undefined ? Math.min(limit, 500) : undefined;
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0;
    if (Number.isNaN(offset) || offset < 0)
      return c.json({ error: 'offset must be a non-negative integer' }, 400);

    const entries: Array<{
      index: number;
      timestamp: string | undefined;
      role: string;
      type: string;
      preview: string;
      toolName?: string;
      durationToNextMs?: number;
      tokens?: { input: number; output: number };
    }> = [];

    // When limit is set, collect limit + 1 entries to determine hasMore accurately.
    // If we get limit + 1, pop the last and set hasMore = true.
    const collectTarget =
      clampedLimit !== undefined ? clampedLimit + 1 : undefined;

    try {
      let idx = 0;
      let collected = 0;
      let prevTimestamp: string | undefined;
      for await (const msg of adapter.streamMessages(session.filePath)) {
        if (idx < offset) {
          idx++;
          prevTimestamp = msg.timestamp;
          // NOTE: durationToNextMs for the first entry after offset > 0 will be
          // computed relative to the last skipped message's timestamp, which is
          // correct. However the skipped entry itself won't have durationToNextMs
          // set — acceptable limitation for v1 pagination.
          continue;
        }
        if (collectTarget !== undefined && collected >= collectTarget) {
          break;
        }
        const entry: (typeof entries)[0] = {
          index: idx,
          timestamp: msg.timestamp,
          role: msg.role,
          type:
            msg.role === 'tool'
              ? 'tool_result'
              : msg.toolCalls?.length
                ? 'tool_use'
                : 'message',
          preview: msg.content.slice(0, 100),
        };
        if (msg.toolCalls?.length) {
          entry.toolName = msg.toolCalls[0].name;
        }
        if (msg.usage) {
          entry.tokens = {
            input: msg.usage.inputTokens,
            output: msg.usage.outputTokens,
          };
        }
        // Compute gap to previous entry
        if (prevTimestamp && msg.timestamp) {
          const gap =
            new Date(msg.timestamp).getTime() -
            new Date(prevTimestamp).getTime();
          if (entries.length > 0)
            entries[entries.length - 1].durationToNextMs = gap;
        }
        prevTimestamp = msg.timestamp;
        entries.push(entry);
        idx++;
        collected++;
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500);
    }

    // If we collected more than the requested limit, there are more entries
    const hasMore = clampedLimit !== undefined && entries.length > clampedLimit;
    if (hasMore) entries.pop();

    return c.json({
      sessionId: session.id,
      source: session.source,
      totalEntries: session.messageCount || entries.length,
      entries,
      ...(offset > 0 ? { offset } : {}),
      ...(clampedLimit !== undefined ? { limit: clampedLimit, hasMore } : {}),
    });
  });

  // Session resume — detect CLI tool and build resume command
  app.post('/api/session/:id/resume', (c) => {
    const session = db.getSession(c.req.param('id'));
    if (!session) return c.json({ error: 'Session not found', hint: '' }, 404);
    const result = buildResumeCommand(
      session.source,
      session.id,
      session.cwd ?? '',
    );
    return c.json(result);
  });

  // Embedding status endpoint
  app.get('/api/search/status', (c) => {
    const totalSessions = db.countSessions();
    const embeddedCount = opts?.vectorStore?.count() ?? 0;
    const available = !!(opts?.vectorStore && opts?.embeddingClient);
    return c.json({
      available,
      model: available ? opts?.embeddingClient?.model : null,
      embeddedCount,
      totalSessions,
      progress:
        totalSessions > 0
          ? Math.round((embeddedCount / totalSessions) * 100)
          : 0,
    });
  });

  // Hybrid search (FTS + semantic)
  const searchDeps: SearchDeps = {
    ...(opts?.vectorStore && opts?.embeddingClient
      ? {
          vectorStore: opts.vectorStore,
          embed: (text: string) => opts!.embeddingClient!.embed(text),
        }
      : {}),
    metrics: opts?.metrics,
  };

  app.get('/api/search', async (c) => {
    const q = c.req.query('q') ?? '';
    const source = c.req.query('source') as SourceName | undefined;
    const project = c.req.query('project');
    const since = c.req.query('since');
    const limitParam = c.req.query('limit');
    const limit = limitParam ? parseInt(limitParam, 10) : undefined;
    const mode = c.req.query('mode') as string | undefined;
    const agents = c.req.query('agents') as 'hide' | undefined;
    const tools = c.req.query('tools') as 'hide' | undefined;

    try {
      const result = await handleSearch(
        db,
        { query: q, source, project, since, limit, mode, agents, tools },
        searchDeps,
      );
      return c.json(result);
    } catch (err) {
      return c.json({
        results: [],
        query: q,
        searchModes: [],
        warning: `Search failed: ${String(err)}`,
      });
    }
  });

  // Semantic search (backward compat — delegates to hybrid with mode=semantic)
  app.get('/api/search/semantic', async (c) => {
    if (!semanticLimiter()) {
      return c.json(
        { error: 'Rate limit exceeded — max 30 requests/minute' },
        429,
      );
    }
    if (!opts?.vectorStore || !opts?.embeddingClient) {
      return c.json(
        {
          error:
            'Semantic search not available — no embedding provider configured',
        },
        501,
      );
    }
    const q = c.req.query('q') ?? '';
    const limitParam = c.req.query('limit');
    const limit = limitParam ? parseInt(limitParam, 10) : 10;
    try {
      const result = await handleSearch(
        db,
        { query: q, limit, mode: 'semantic' },
        searchDeps,
      );
      return c.json(result);
    } catch (err) {
      return c.json({
        results: [],
        query: q,
        searchModes: [],
        warning: `Search failed: ${String(err)}`,
      });
    }
  });

  // Stats
  app.get('/api/stats', async (c) => {
    const since = c.req.query('since');
    const until = c.req.query('until');
    const group_by = c.req.query('group_by');
    const exclude_noise = c.req.query('exclude_noise') !== '0'; // default: true

    const result = await handleStats(db, {
      since,
      until,
      group_by,
      exclude_noise,
    });
    return c.json(result);
  });

  // Cost tracking API
  app.get('/api/costs', (c) => {
    const group_by = c.req.query('group_by');
    const since = c.req.query('since');
    const until = c.req.query('until');
    const result = handleGetCosts(db, { group_by, since, until });
    return c.json(result);
  });

  app.get('/api/costs/sessions', (c) => {
    const rawLimit = parseInt(c.req.query('limit') || '20', 10);
    const limit = Math.min(
      Math.max(Number.isNaN(rawLimit) ? 20 : rawLimit, 1),
      100,
    );
    const rows = db
      .getRawDb()
      .prepare(`
      SELECT c.*, s.source, s.project, s.start_time, s.summary
      FROM session_costs c JOIN sessions s ON c.session_id = s.id
      ORDER BY c.cost_usd DESC LIMIT ?
    `)
      .all(limit);
    return c.json({ sessions: rows });
  });

  // File activity API
  app.get('/api/file-activity', (c) => {
    const project = c.req.query('project');
    const since = c.req.query('since');
    const limit = c.req.query('limit')
      ? parseInt(c.req.query('limit')!, 10)
      : undefined;
    const result = db.getFileActivity({
      project: project ?? undefined,
      since: since ?? undefined,
      limit,
    });
    return c.json({ files: result, totalFiles: result.length });
  });

  // Tool analytics API
  app.get('/api/tool-analytics', (c) => {
    const project = c.req.query('project');
    const since = c.req.query('since');
    const group_by = c.req.query('group_by');
    const result = handleToolAnalytics(db, { project, since, group_by });
    return c.json(result);
  });

  // Usage snapshots
  app.get('/api/usage', (c) => {
    const latest = opts?.usageCollector?.getLatest() ?? [];
    return c.json({ usage: latest });
  });

  app.get('/api/repos', (c) => {
    const rows = db
      .getRawDb()
      .prepare('SELECT * FROM git_repos ORDER BY last_commit_at DESC')
      .all();
    return c.json({ repos: rows });
  });

  // Project aliases
  app.get('/api/project-aliases', (c) => {
    return c.json(db.listProjectAliases());
  });

  app.post('/api/project-aliases', async (c) => {
    const body = (await c.req.json()) as { alias?: string; canonical?: string };
    if (!body.alias || !body.canonical)
      return c.json({ error: 'alias and canonical required' }, 400);
    db.addProjectAlias(body.alias, body.canonical);
    return c.json({ added: { alias: body.alias, canonical: body.canonical } });
  });

  app.delete('/api/project-aliases', async (c) => {
    const body = (await c.req.json()) as { alias?: string; canonical?: string };
    if (!body.alias || !body.canonical)
      return c.json({ error: 'alias and canonical required' }, 400);
    db.removeProjectAlias(body.alias, body.canonical);
    return c.json({
      removed: { alias: body.alias, canonical: body.canonical },
    });
  });

  // --- Project migration API (powers Swift UI: Rename / Archive / Undo) ---
  // Writes (POST) require bearer auth via the generic /api/* middleware above.
  // The orchestrator enforces its own single-writer lock, so concurrent POSTs
  // will fail with LockBusyError (returned as HTTP 409) instead of corrupting.

  // GET /api/project/migrations — recent migrations (defaults to committed
  // only, limit 20). Used by UndoSheet to pick a row to reverse.
  //
  // Round 4 Critical: previously fetched `limit` rows THEN filtered by
  // state in JS. With state='committed' and limit=5, if the 5 most
  // recent rows included any failed/pending ones, the user saw a
  // truncated list even though many committed ones existed further
  // back. listMigrations already supports state filtering — push it in.
  app.get('/api/project/migrations', (c) => {
    const limit = Math.min(
      Math.max(parseInt(c.req.query('limit') ?? '20', 10) || 20, 1),
      100,
    );
    const stateFilter = c.req.query('state'); // undefined = all states
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
    const rows = db.listMigrations({
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
    const raw = db.getRawDb();
    const rows = raw
      .prepare(
        `SELECT DISTINCT cwd FROM sessions
         WHERE project = @project AND cwd IS NOT NULL AND cwd != ''
         ORDER BY cwd`,
      )
      .all({ project }) as Array<{ cwd: string }>;
    return c.json({ project, cwds: rows.map((r) => r.cwd) });
  });

  // POST /api/project/move — run a move (or dry-run).
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
    const srcResolved = normalizeHttpPath(body.src);
    const dstResolved = normalizeHttpPath(body.dst);
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
      './core/project-move/orchestrator.js'
    );
    try {
      const result = await runProjectMove(db, {
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

  // POST /api/project/undo — reverse a committed migration.
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
    const { undoMigration } = await import('./core/project-move/undo.js');
    try {
      const result = await undoMigration(db, body.migrationId, {
        force: body.force === true,
        actor: actorResult.actor,
      });
      return c.json(result);
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });

  // POST /api/project/archive — auto-suggest + move to _archive/<category>/.
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
    const srcResolved = normalizeHttpPath(body.src);
    if (!srcResolved.ok) {
      return c.json(
        validationError('InvalidPath', `src: ${srcResolved.error}`),
        400,
      );
    }
    const { runProjectMove } = await import(
      './core/project-move/orchestrator.js'
    );
    const { suggestArchiveTarget } = await import(
      './core/project-move/archive.js'
    );
    try {
      // Round 4 Critical (reviewer C1): archive.ts now owns alias
      // normalization — pass the raw string in, suggestArchiveTarget
      // will throw on unknowns with a consistent message. Previously
      // this cast-through-`as never` produced _archive/archived-done/
      // folders with English names instead of /归档完成/.
      const suggestion = await suggestArchiveTarget(srcResolved.path, {
        forceCategory: body.archiveTo,
      });
      // Round 4 Critical (Codex #4): only create the _archive/<cat>/
      // parent dir on a real run. A dry-run used to mkdir unconditionally
      // which left empty `_archive/<cat>/` folders on the FS even when
      // the user only wanted a preview.
      if (body.dryRun !== true) {
        const { mkdir } = await import('node:fs/promises');
        const { dirname } = await import('node:path');
        await mkdir(dirname(suggestion.dst), { recursive: true });
      }
      const result = await runProjectMove(db, {
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

  // POST /api/project/move-batch — run a YAML-described batch of moves.
  // Round 2 M3 (6-way review follow-up): previously project_move_batch was
  // the last write tool still bypassing the single-writer discipline —
  // dispatched directly in index.ts. Route it through daemon too. The
  // `actor` field is fixed to 'batch' inside runBatch() per operation; no
  // need to accept it on the HTTP body. $HOME confinement isn't enforced
  // here because paths come from the YAML document itself (parsed inside
  // runBatch via expandHome); the batch entrypoint is intentionally
  // permissive to match the CLI variant.
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
    const { parse: parseYaml } = await import('yaml');
    const { normalizeBatchDocument, runBatch } = await import(
      './core/project-move/batch.js'
    );
    try {
      const raw = parseYaml(body.yaml) as Record<string, unknown>;
      const doc = normalizeBatchDocument(raw);
      if (body.dryRun === true) {
        doc.defaults = { ...doc.defaults, dryRun: true };
      }
      const result = await runBatch(db, doc, { force: body.force === true });
      return c.json(result);
    } catch (err) {
      return c.json(mapProjectMoveError(err), mapProjectMoveErrorStatus(err));
    }
  });

  // --- Summary API ---
  app.post('/api/summary', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const sessionId = (body as Record<string, unknown>).sessionId as
      | string
      | undefined;
    if (!sessionId) {
      return c.json({ error: 'Missing required field: sessionId' }, 400);
    }

    const session = db.getSession(sessionId);
    if (!session) {
      return c.json({ error: `Session not found: ${sessionId}` }, 404);
    }

    const currentSettings = readFileSettings();
    if (!currentSettings.aiApiKey) {
      return c.json(
        { error: 'API key not configured. Please set it in Settings.' },
        500,
      );
    }

    const adapter = opts?.adapters?.find((a) => a.name === session.source);
    if (!adapter) {
      return c.json({ error: `No adapter for source: ${session.source}` }, 500);
    }

    const messages: Array<{ role: string; content: string }> = [];
    try {
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content });
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500);
    }

    if (messages.length === 0) {
      return c.json({ error: 'No messages in session' }, 400);
    }

    try {
      const summary = await summarizeConversation(messages, currentSettings, {
        audit: opts?.audit,
        sessionId,
      });
      if (!summary) {
        return c.json({ error: 'Empty response from AI' }, 500);
      }
      db.updateSessionSummary(sessionId, summary, messages.length);
      return c.json({ summary });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return c.json({ error: msg }, 500);
    }
  });

  // --- Insight write (single-writer routing for save_insight MCP tool) ---
  // Round 3 (6-way review S1 follow-up): uses the same {error:{name,message,
  // retry_policy}} envelope shape as /api/project/* so Swift clients + MCP's
  // shouldFallbackToDirect see one contract, not two.
  app.post('/api/insight', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as Record<
      string,
      unknown
    >;
    const content = typeof body.content === 'string' ? body.content : undefined;
    if (!content) {
      return c.json(
        validationError('MissingParam', 'content (string) required'),
        400,
      );
    }
    try {
      const result = await handleSaveInsight(
        {
          content,
          wing: typeof body.wing === 'string' ? body.wing : undefined,
          room: typeof body.room === 'string' ? body.room : undefined,
          importance:
            typeof body.importance === 'number' ? body.importance : undefined,
          source_session_id:
            typeof body.source_session_id === 'string'
              ? body.source_session_id
              : undefined,
        },
        {
          db,
          vecStore: opts?.vectorStore ?? null,
          embedder: opts?.embeddingClient ?? null,
        },
      );
      return c.json(result);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      // handleSaveInsight throws plain Error for validation failures — map
      // onto the shared envelope. Known validation messages get 400 with
      // retry_policy='never'; anything else is a 500 server-side error
      // (retry_policy='safe' = client may retry).
      const isValidation =
        msg.startsWith('Content ') || msg.includes('requires either');
      if (isValidation) {
        return c.json(validationError('InvalidInsight', msg), 400);
      }
      return c.json(
        {
          error: {
            name: 'InsightSaveFailed',
            message: msg,
            retry_policy: 'safe',
          },
        },
        500,
      );
    }
  });

  // --- Handoff brief generation ---
  app.post('/api/handoff', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const cwd = (body as Record<string, unknown>).cwd as string | undefined;
    if (!cwd) {
      return c.json({ error: 'Missing required field: cwd' }, 400);
    }
    const sessionId = (body as Record<string, unknown>).sessionId as
      | string
      | undefined;
    const format = (body as Record<string, unknown>).format as
      | string
      | undefined;
    const validFormats = ['markdown', 'plain'];
    if (format && !validFormats.includes(format)) {
      return c.json(
        {
          error: `Invalid format: ${format}. Must be one of: ${validFormats.join(', ')}`,
        },
        400,
      );
    }
    try {
      const result = await handleHandoff(
        db,
        {
          cwd,
          sessionId,
          format: format as 'markdown' | 'plain' | undefined,
        },
        opts?.adapters,
      );
      return c.json(result);
    } catch (err) {
      return c.json({ error: `Handoff failed: ${err}` }, 500);
    }
  });

  // --- Link sessions API ---
  app.post('/api/link-sessions', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const targetDir = (body as Record<string, unknown>).targetDir as
      | string
      | undefined;
    if (!targetDir) {
      return c.json({ error: 'Missing required field: targetDir' }, 400);
    }
    try {
      const result = await handleLinkSessions(db, { targetDir });
      return c.json(result);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return c.json({ error: msg }, 500);
    }
  });

  // --- Title generation ---
  app.post('/api/session/:id/generate-title', async (c) => {
    if (!opts?.titleGenerator)
      return c.json({ error: 'Title generation not configured' }, 400);
    const id = c.req.param('id');
    const session = db.getSession(id);
    if (!session) return c.json({ error: 'Session not found' }, 404);

    const adapter = opts?.adapters?.find((a) => a.name === session.source);
    if (!adapter)
      return c.json({ error: `No adapter for source: ${session.source}` }, 500);

    const messages: { role: string; content: string }[] = [];
    try {
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content });
        if (messages.length >= 6) break;
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500);
    }

    const title = await opts.titleGenerator.generate(messages);
    if (!title)
      return c.json({ error: 'Title generation returned empty result' }, 500);

    db.getRawDb()
      .prepare('UPDATE sessions SET generated_title = ? WHERE id = ?')
      .run(title, id);
    return c.json({ title });
  });

  app.post('/api/titles/regenerate-all', async (c) => {
    if (!opts?.titleGenerator)
      return c.json({ error: 'Title generation not configured' }, 400);

    const titleGenerator = opts.titleGenerator;
    const adapters = opts.adapters;

    // Get sessions needing titles
    const sessions = db
      .getRawDb()
      .prepare(`
      SELECT id, source, file_path, message_count, tier
      FROM sessions
      WHERE (generated_title IS NULL OR generated_title = '')
        AND message_count >= 2
        AND (tier IS NULL OR tier NOT IN ('skip', 'lite'))
      ORDER BY start_time DESC
      LIMIT 500
    `)
      .all() as {
      id: string;
      source: string;
      file_path: string;
      message_count: number;
      tier: string | null;
    }[];

    const count = sessions.length;

    // Run in background (don't await)
    (async () => {
      let generated = 0;
      const isOllama =
        (titleGenerator as unknown as { config?: { provider?: string } }).config
          ?.provider === 'ollama';

      for (const session of sessions) {
        try {
          if (!session.file_path) continue;

          const adapter = adapters?.find((a) => a.name === session.source);
          if (!adapter) continue;

          const messages: { role: string; content: string }[] = [];
          try {
            for await (const msg of adapter.streamMessages(session.file_path)) {
              if (
                (msg.role === 'user' || msg.role === 'assistant') &&
                msg.content.trim()
              ) {
                messages.push({ role: msg.role, content: msg.content });
              }
              if (messages.length >= 6) break;
            }
          } catch {
            continue;
          }

          if (messages.length < 2) continue;

          const title = await titleGenerator.generate(messages);
          if (title) {
            db.getRawDb()
              .prepare('UPDATE sessions SET generated_title = ? WHERE id = ?')
              .run(title, session.id);
            generated++;
          }

          // Rate limit: 1 req/sec for non-Ollama providers
          if (!isOllama) {
            await new Promise((r) => setTimeout(r, 1000));
          }
        } catch (err) {
          console.error(`[title-regen] Error for ${session.id}:`, err);
        }
      }
      console.log(
        `[title-regen] Completed: ${generated}/${count} titles generated`,
      );
    })();

    return c.json({
      status: 'started',
      total: count,
      message: `Regenerating titles for ${count} sessions in background`,
    });
  });

  // --- Health dashboard ---
  const HOME = homedir();
  const SOURCE_PATHS: Record<string, string> = {
    'claude-code': join(HOME, '.claude/projects'),
    codex: join(HOME, '.codex/sessions'),
    'gemini-cli': join(HOME, '.gemini/tmp'),
    opencode: join(HOME, '.local/share/opencode/opencode.db'),
    iflow: join(HOME, '.iflow/projects'),
    qwen: join(HOME, '.qwen/projects'),
    kimi: join(HOME, '.kimi/sessions'),
    cline: join(HOME, '.cline/data/tasks'),
    cursor: join(
      HOME,
      'Library/Application Support/Cursor/User/globalStorage/state.vscdb',
    ),
    vscode: join(
      HOME,
      'Library/Application Support/Code/User/workspaceStorage',
    ),
    antigravity: join(HOME, '.gemini/antigravity/daemon'),
    windsurf: join(HOME, '.codeium/windsurf/daemon'),
    copilot: join(HOME, '.copilot/session-state'),
  };
  const DERIVED_SOURCES: Record<string, string> = {
    lobsterai: 'claude-code',
    minimax: 'claude-code',
  };

  async function getHealthData() {
    const sourceStats = db.getSourceStats();

    const sources = sourceStats.map((s) => {
      const derivedFrom = DERIVED_SOURCES[s.source];
      const path = SOURCE_PATHS[derivedFrom ?? s.source] ?? '';
      return {
        name: s.source,
        sessionCount: s.sessionCount,
        latestIndexed: s.latestIndexed,
        path: path.replace(HOME, '~'),
        pathExists: path ? existsSync(path) : false,
        watcherType: WATCHED_SOURCES.has(s.source) ? 'watching' : 'polling',
        derived: !!derivedFrom,
        derivedFrom: derivedFrom ?? null,
        dailyCounts: s.dailyCounts,
      };
    });

    const now = Date.now();
    const oneDayMs = 24 * 60 * 60 * 1000;
    const activeSources = sourceStats.filter((s) => {
      const latest = new Date(s.latestIndexed).getTime();
      return now - latest < oneDayMs;
    }).length;

    return {
      sources,
      summary: {
        totalSources: sourceStats.length,
        activeSources,
        lastIndexed:
          sourceStats.length > 0
            ? sourceStats.reduce((a, b) =>
                a.latestIndexed > b.latestIndexed ? a : b,
              ).latestIndexed
            : null,
      },
    };
  }

  app.get('/api/health/sources', async (c) => {
    return c.json(await getHealthData());
  });

  // Active sources with adapter info
  app.get('/api/sources', async (c) => {
    const sources = db.listSources();
    const stats = db.getSourceStats();
    const statsMap = new Map(stats.map((s) => [s.source, s]));
    return c.json(
      sources.map((source) => ({
        name: source,
        sessionCount: statsMap.get(source)?.sessionCount ?? 0,
        latestIndexed: statsMap.get(source)?.latestIndexed ?? null,
      })),
    );
  });

  // Skills from Claude Code config
  app.get('/api/skills', async (c) => {
    const results: {
      name: string;
      description: string;
      path: string;
      scope: string;
    }[] = [];
    const home = homedir();

    // Global commands from settings
    try {
      const settingsPath = join(home, '.claude', 'settings.json');
      const raw = await readFile(settingsPath, 'utf-8');
      const settings = JSON.parse(raw);
      if (settings.customCommands) {
        for (const [name, cmd] of Object.entries(settings.customCommands)) {
          results.push({
            name,
            description: String(cmd).slice(0, 100),
            path: settingsPath,
            scope: 'global',
          });
        }
      }
    } catch {
      /* no settings */
    }

    // Plugin skills
    const pluginsDir = join(home, '.claude', 'plugins', 'cache');
    try {
      const vendors = await readdir(pluginsDir);
      for (const vendor of vendors) {
        const vendorPath = join(pluginsDir, vendor);
        const vendorStat = await stat(vendorPath).catch(() => null);
        if (!vendorStat?.isDirectory()) continue;
        const items = await readdir(vendorPath, { recursive: true });
        for (const item of items) {
          if (
            typeof item === 'string' &&
            item.endsWith('.md') &&
            !item.includes('node_modules')
          ) {
            try {
              const content = await readFile(join(vendorPath, item), 'utf-8');
              const nameMatch = content.match(/^name:\s*(.+)$/m);
              const descMatch = content.match(/^description:\s*(.+)$/m);
              if (nameMatch) {
                results.push({
                  name: nameMatch[1].trim(),
                  description: descMatch?.[1]?.trim() ?? '',
                  path: join(vendorPath, item).replace(home, '~'),
                  scope: 'plugin',
                });
              }
            } catch {
              /* skip unreadable */
            }
          }
        }
      }
    } catch {
      /* no plugins dir */
    }

    return c.json(results);
  });

  // Memory files across Claude Code projects
  app.get('/api/memory', async (c) => {
    const results: {
      name: string;
      project: string;
      path: string;
      sizeBytes: number;
      preview: string;
    }[] = [];
    const home = homedir();
    const projectsDir = join(home, '.claude', 'projects');

    try {
      const projects = await readdir(projectsDir);
      for (const project of projects) {
        const memoryDir = join(projectsDir, project, 'memory');
        try {
          const files = await readdir(memoryDir);
          for (const file of files) {
            if (!file.endsWith('.md')) continue;
            const filePath = join(memoryDir, file);
            const fileStat = await stat(filePath).catch(() => null);
            if (!fileStat?.isFile()) continue;
            const content = await readFile(filePath, 'utf-8').catch(() => '');
            results.push({
              name: file,
              project: project.replace(/-/g, '/'),
              path: filePath.replace(home, '~'),
              sizeBytes: fileStat.size,
              preview: content.slice(0, 200),
            });
          }
        } catch {
          /* no memory dir for this project */
        }
      }
    } catch {
      /* no projects dir */
    }

    return c.json(results);
  });

  // Hooks from Claude Code settings
  app.get('/api/hooks', async (c) => {
    const results: { event: string; command: string; scope: string }[] = [];
    const home = homedir();

    for (const scope of ['global', 'project'] as const) {
      const path =
        scope === 'global'
          ? join(home, '.claude', 'settings.json')
          : join(home, '.claude', 'settings.local.json');
      try {
        const raw = await readFile(path, 'utf-8');
        const settings = JSON.parse(raw);
        if (settings.hooks) {
          for (const [event, handlers] of Object.entries(settings.hooks)) {
            if (Array.isArray(handlers)) {
              for (const handler of handlers) {
                const cmd =
                  typeof handler === 'string'
                    ? handler
                    : ((handler as { command?: string }).command ??
                      JSON.stringify(handler));
                results.push({ event, command: cmd, scope });
              }
            }
          }
        }
      } catch {
        /* no settings file */
      }
    }

    return c.json(results);
  });

  app.get('/health', async (c) => {
    return c.html(healthPage(await getHealthData()));
  });

  app.get('/api/hygiene', async (c) => {
    const force = c.req.query('force') === 'true';
    const result = await runAllHealthChecks(db, { force, scope: 'global' });
    return c.json(result);
  });

  // UUID lookup redirect
  app.get('/goto', (c) => {
    const id = (c.req.query('id') ?? '').trim();
    if (id && db.getSession(id)) {
      return c.redirect(`/session/${encodeURIComponent(id)}`);
    }
    return c.redirect('/');
  });

  // HTML routes
  app.get('/', (c) => {
    const sourceParam = c.req.query('source') || '';
    const projectParam = c.req.query('project') || '';
    const originParam = c.req.query('origin') || '';
    const selectedSources = sourceParam
      ? sourceParam.split(',').filter(Boolean)
      : [];
    const selectedProjects = projectParam
      ? projectParam.split(',').filter(Boolean)
      : [];
    const selectedOrigins = originParam
      ? originParam.split(',').filter(Boolean)
      : [];
    const limitParam = c.req.query('limit');
    const offsetParam = c.req.query('offset');
    const agentsParam = c.req.query('agents') as
      | 'hide'
      | 'only'
      | 'all'
      | undefined;
    const agents =
      agentsParam === 'all'
        ? undefined
        : agentsParam === 'only'
          ? 'only'
          : 'hide'; // default: hide agents
    const limit = Math.min(limitParam ? parseInt(limitParam, 10) : 50, 100);
    const offset = offsetParam ? parseInt(offsetParam, 10) : 0;

    const sessions = db.listSessions({
      sources: selectedSources,
      projects: selectedProjects,
      origins: selectedOrigins,
      limit,
      offset,
      agents,
    });
    const total = db.countSessions({
      sources: selectedSources,
      projects: selectedProjects,
      origins: selectedOrigins,
      agents,
    });
    const sources = db.listSources();
    const projects = db.listProjects();
    const origins = db.listOrigins();

    return c.html(
      sessionListPage(sessions, {
        offset,
        limit,
        hasMore: sessions.length === limit,
        total,
        selectedSources,
        sources,
        agents,
        selectedProjects,
        projects,
        selectedOrigins,
        origins,
      }),
    );
  });

  app.get('/search', (c) => {
    const recent = db.listSessions({ limit: 5 });
    return c.html(searchPage(recent));
  });

  app.get('/stats', async (c) => {
    const groupBy = c.req.query('group_by') ?? 'source';
    const excludeNoise = c.req.query('exclude_noise') !== '0'; // default: true
    const result = await handleStats(db, {
      group_by: groupBy,
      exclude_noise: excludeNoise,
    });
    return c.html(
      statsPage(result.groups, result.totalSessions, groupBy, excludeNoise),
    );
  });

  app.get('/settings', (c) => {
    return c.html(
      settingsPage({
        nodeName: settings.syncNodeName ?? 'unnamed',
        peers: settings.syncPeers ?? [],
        totalSessions: db.countSessions(),
        sources: db.listSources(),
        port: settings.httpPort ?? 3457,
        aliases: db.listProjectAliases(),
      }),
    );
  });

  app.get('/session/:id', async (c) => {
    const session = db.getSession(c.req.param('id'));
    if (!session)
      return c.html(layout('Not Found', '<h2>Session not found</h2>'), 404);
    const adapter = getAdapter(session.source);
    const messages: { role: string; content: string }[] = [];
    if (adapter) {
      try {
        for await (const msg of adapter.streamMessages(session.filePath)) {
          messages.push({ role: msg.role, content: msg.content });
        }
      } catch {
        // File may not exist (e.g. deleted or on another machine)
      }
    }
    return c.html(sessionDetailPage(session, messages));
  });

  // --- Live Sessions API ---
  // TODO: SSE endpoint (deferred) — add GET /api/live/stream that pushes live session
  // updates and monitor alerts via Server-Sent Events instead of polling.
  app.get('/api/live', (c) => {
    const raw = opts?.liveMonitor?.getSessions() ?? [];
    // Filter out agent/subagent noise
    const filtered = raw.filter((s) => {
      // Skip subagent sessions (claude-code spawns into subagents/ dir)
      if (s.filePath.includes('/subagents/')) return false;
      // Skip sessions in the global "-" project dir (typically system/preamble)
      if (s.filePath.includes('/.claude/projects/-/')) return false;
      return true;
    });
    // Enrich with DB data (title, project, model) and filter by tier
    const sessions = filtered
      .map((s) => {
        const dbRow = s.filePath
          ? (db
              .getRawDb()
              .prepare(
                'SELECT generated_title, summary, project, model, tier, agent_role FROM sessions WHERE file_path = ? LIMIT 1',
              )
              .get(s.filePath) as
              | {
                  generated_title?: string;
                  summary?: string;
                  project?: string;
                  model?: string;
                  tier?: string;
                  agent_role?: string;
                }
              | undefined)
          : undefined;
        // Skip sessions with skip tier or agent role in DB
        if (dbRow?.tier === 'skip' || dbRow?.agent_role) return null;
        return {
          ...s,
          title:
            dbRow?.generated_title ??
            dbRow?.summary?.slice(0, 60) ??
            s.title ??
            undefined,
          project:
            s.project ||
            dbRow?.project ||
            (s.cwd ? s.cwd.split('/').pop() : undefined),
          model: s.model || dbRow?.model || undefined,
        };
      })
      .filter(Boolean) as typeof raw;

    // Deduplicate: same source + project → keep most recent only
    const deduped = new Map<string, (typeof sessions)[0]>();
    for (const s of sessions) {
      const key = `${s.source}:${s.project || s.cwd || s.filePath}`;
      const existing = deduped.get(key);
      if (!existing || s.lastModifiedAt > existing.lastModifiedAt) {
        deduped.set(key, s);
      }
    }
    const result = [...deduped.values()];
    return c.json({ sessions: result, count: result.length });
  });

  // --- Monitor Alerts API ---
  app.get('/api/monitor/alerts', (c) => {
    const alerts = opts?.backgroundMonitor?.getAlerts() ?? [];
    const undismissed = alerts.filter((a) => !a.dismissed);
    return c.json({ alerts: undismissed, total: alerts.length });
  });

  app.post('/api/monitor/alerts/:id/dismiss', (c) => {
    const id = c.req.param('id');
    opts?.backgroundMonitor?.dismissAlert(id);
    return c.json({ dismissed: id });
  });

  // --- Dev Mode API ---
  app.post('/api/dev/mock', async (c) => {
    if (!settings.devMode)
      return c.json({ error: 'Dev mode not enabled' }, 403);
    const stats = await populateMockData(db);
    return c.json(stats);
  });

  app.delete('/api/dev/mock', (c) => {
    if (!settings.devMode)
      return c.json({ error: 'Dev mode not enabled' }, 403);
    const cleared = clearMockData(db);
    return c.json({ cleared });
  });

  // --- Config Linter API ---
  app.post('/api/lint', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const cwd = (body as Record<string, unknown>).cwd as string | undefined;
    if (!cwd) return c.json({ error: 'cwd required' }, 400);

    // Validate: must be absolute path
    if (!cwd.startsWith('/'))
      return c.json({ error: 'cwd must be an absolute path' }, 400);

    // Defense-in-depth: reject paths outside $HOME
    const home = homedir();
    if (!cwd.startsWith(`${home}/`) && cwd !== home) {
      return c.json({ error: 'cwd must be within the home directory' }, 400);
    }

    // Validate: must exist as a directory
    try {
      const s = await stat(cwd);
      if (!s.isDirectory())
        return c.json({ error: 'cwd is not a directory' }, 400);
    } catch {
      return c.json({ error: 'cwd does not exist' }, 400);
    }

    const result = await handleLintConfig({ cwd });
    return c.json(result);
  });

  // Observability: accept log forwarding from Swift app
  app.post('/api/log', async (c) => {
    let body: {
      level?: string;
      module?: string;
      message?: string;
      data?: Record<string, unknown>;
      traceId?: string;
      error?: string;
    };
    try {
      body = await c.req.json();
    } catch {
      return c.json({ ok: false }, 400);
    }

    const VALID_LEVELS = new Set(['debug', 'info', 'warn', 'error']);
    if (!body.level || !body.module || !body.message)
      return c.json({ ok: false }, 400);
    if (!VALID_LEVELS.has(body.level))
      return c.json({ ok: false, error: 'invalid level' }, 400);

    if (opts?.logWriter) {
      // Use traceId from body (Swift-provided) or fall back to the request header trace ID
      const traceId = body.traceId ?? c.get('traceId');
      opts.logWriter.write({
        level: body.level as 'debug' | 'info' | 'warn' | 'error',
        module: body.module,
        message:
          typeof body.message === 'string'
            ? body.message.slice(0, 10000)
            : String(body.message),
        data: body.data,
        error: body.error
          ? { name: 'AppError', message: body.error }
          : undefined,
        traceId,
        source: 'app',
      });
    }
    return c.json({ ok: true });
  });

  return app;
}

// CLI entry point
const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith('/web.js') ||
  process.argv[1]?.endsWith('/web.ts');
if (isMain) {
  const { serve } = await import('@hono/node-server');
  const DB_DIR = ensureDataDirs();
  const db = new Database(join(DB_DIR, 'index.sqlite'));
  const settings = readFileSettings();
  const port = settings.httpPort ?? 3457;
  const host = settings.httpHost ?? '127.0.0.1';
  const app = createApp(db, { settings });

  if (host !== '127.0.0.1' && !settings.httpBearerToken) {
    process.stderr.write(
      '[engram-web] WARNING: Binding to ' +
        host +
        ' without bearer token. All GET endpoints are unauthenticated.\n',
    );
    process.stderr.write(
      '[engram-web] Set httpBearerToken in ~/.engram/settings.json to protect your data.\n',
    );
  }

  serve({ fetch: app.fetch, port, hostname: host }, (info) => {
    process.stderr.write(
      `[engram-web] Listening on http://${host}:${info.port}\n`,
    );
  });
}
