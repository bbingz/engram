import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve as pathResolve } from 'node:path';
import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import type { Message, SessionAdapter, SessionInfo } from './adapters/types.js';
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
import type { ErrorEnvelope } from './core/project-move/retry-policy.js';
import { runWithContext } from './core/request-context.js';
import type { SyncEngine, SyncPeer } from './core/sync.js';
import type { TitleGenerator } from './core/title-generator.js';
import type { Tracer } from './core/tracer.js';
import { withSpan } from './core/tracer.js';
import type { UsageCollector } from './core/usage-collector.js';
import type { VectorStore } from './core/vector-store.js';
import { WATCHED_SOURCES } from './core/watcher.js';
import { handleHandoff } from './tools/handoff.js';
import { handleLinkSessions } from './tools/link_sessions.js';
import { handleLintConfig, runAllHealthChecks } from './tools/lint_config.js';
import { loadBoundedMessages } from './tools/message-loader.js';
import { handleSaveInsight } from './tools/save_insight.js';
import { handleStats } from './tools/stats.js';
import { registerAiAuditRoutes } from './web/routes/ai-audit.js';
import { registerProjectAliasRoutes } from './web/routes/project-aliases.js';
import { registerProjectMigrationRoutes } from './web/routes/project-migrations.js';
import { registerSearchRoutes } from './web/routes/search.js';
import { registerSessionRoutes } from './web/routes/sessions.js';
import { registerStatsRoutes } from './web/routes/stats.js';
import { registerSyncRoutes } from './web/routes/sync.js';
import {
  healthPage,
  layout,
  searchPage,
  sessionDetailPage,
  sessionListPage,
  settingsPage,
  statsPage,
} from './web/views.js';

/** Build a 400 validation-error envelope identical in shape to the
 *  orchestrator error envelope so the Swift client can decode uniformly
 *  (Codex minor #4). `retry_policy: 'never'` — client must fix input. */
function validationError(name: string, message: string): ErrorEnvelope {
  return { error: { name, message, retry_policy: 'never' } };
}

const WRITE_METHODS = new Set(['POST', 'PUT', 'DELETE', 'PATCH']);
const MAX_API_BODY_BYTES = 256 * 1024;

type IntegerParamResult =
  | { ok: true; value: number }
  | { ok: false; error: string };

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

type LiveSessionsPayload = {
  sessions: ReturnType<LiveSessionMonitor['getSessions']>;
  count: number;
};

function liveSessionsPayload(
  db: Database,
  liveMonitor?: LiveSessionMonitor,
): LiveSessionsPayload {
  const raw = liveMonitor?.getSessions() ?? [];
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

  // Deduplicate: same source + project -> keep most recent only
  const deduped = new Map<string, (typeof sessions)[0]>();
  for (const s of sessions) {
    const key = `${s.source}:${s.project || s.cwd || s.filePath}`;
    const existing = deduped.get(key);
    if (!existing || s.lastModifiedAt > existing.lastModifiedAt) {
      deduped.set(key, s);
    }
  }
  const result = [...deduped.values()];
  return { sessions: result, count: result.length };
}

function sseEvent(event: string, data: unknown): string {
  return `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
}

function parsePositiveInteger(
  name: string,
  raw: string | undefined,
): IntegerParamResult {
  if (raw === undefined || !/^\d+$/.test(raw)) {
    return { ok: false, error: `${name} must be a positive integer` };
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) {
    return { ok: false, error: `${name} must be a positive integer` };
  }
  return { ok: true, value };
}

function parseNonNegativeInteger(
  name: string,
  raw: string | undefined,
): IntegerParamResult {
  if (raw === undefined || !/^\d+$/.test(raw)) {
    return { ok: false, error: `${name} must be a non-negative integer` };
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    return { ok: false, error: `${name} must be a non-negative integer` };
  }
  return { ok: true, value };
}

export function parseOptionalPositiveIntParam(
  name: string,
  raw: string | undefined,
  max: number,
): OptionalIntegerParamResult {
  if (raw === undefined) return { ok: true, value: undefined };
  const parsed = parsePositiveInteger(name, raw);
  if (!parsed.ok) return parsed;
  return { ok: true, value: Math.min(parsed.value, max) };
}

export function parsePaginationParams(
  rawOffset: string | undefined,
  rawLimit: string | undefined,
  defaultLimit: number,
  maxLimit: number,
): { ok: true; offset: number; limit: number } | { ok: false; error: string } {
  const offset = rawOffset
    ? parseNonNegativeInteger('offset', rawOffset)
    : ({ ok: true, value: 0 } as const);
  if (!offset.ok) return { ok: false, error: offset.error };

  const limit = rawLimit
    ? parsePositiveInteger('limit', rawLimit)
    : ({ ok: true, value: defaultLimit } as const);
  if (!limit.ok) return { ok: false, error: limit.error };

  return {
    ok: true,
    offset: offset.value,
    limit: Math.min(limit.value, maxLimit),
  };
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
  const detailPageSize = 50;

  function resolveAdapter(source: string): SessionAdapter | undefined {
    return opts?.adapters?.find((a) => a.name === source) ?? getAdapter(source);
  }

  async function readTranscriptPage(
    session: SessionInfo,
    offset: number,
    limit: number,
  ): Promise<{
    messages: Pick<Message, 'role' | 'content'>[];
    hasMore: boolean;
    nextOffset: number;
    error?: string;
  }> {
    const adapter = resolveAdapter(session.source);
    if (!adapter) {
      return {
        messages: [],
        hasMore: false,
        nextOffset: offset,
        error: `No adapter for source: ${session.source}`,
      };
    }

    const messages: Pick<Message, 'role' | 'content'>[] = [];
    try {
      let visibleSeen = 0;
      for await (const msg of adapter.streamMessages(session.filePath)) {
        if (msg.role !== 'user' && msg.role !== 'assistant') continue;
        if (visibleSeen < offset) {
          visibleSeen++;
          continue;
        }
        messages.push({ role: msg.role, content: msg.content });
        visibleSeen++;
        if (messages.length > limit) break;
      }
    } catch {
      return {
        messages: [],
        hasMore: false,
        nextOffset: offset,
        error: 'Failed to read session',
      };
    }

    const hasMore = messages.length > limit;
    if (hasMore) messages.length = limit;
    return {
      messages,
      hasMore,
      nextOffset: offset + messages.length,
    };
  }

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

  app.use(
    '/api/*',
    bodyLimit({
      maxSize: MAX_API_BODY_BYTES,
      onError: (c) => c.json({ error: 'Request body too large' }, 413),
    }),
  );

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
  registerAiAuditRoutes(app, {
    auditQuery: opts?.auditQuery,
    parsePaginationParams,
    parsePositiveInteger,
  });

  // Sync: reference TypeScript API retained for migration/dev tooling
  registerSyncRoutes(app, {
    db,
    nodeName: settings.syncNodeName,
    syncEngine: opts?.syncEngine,
    syncPeers: opts?.syncPeers,
    parseOptionalPositiveIntParam,
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

  // Sessions
  registerSessionRoutes(app, {
    db,
    adapters: opts?.adapters,
    detailPageSize,
    parsePaginationParams,
    parseOptionalPositiveIntParam,
    parseNonNegativeInteger,
  });

  // Search
  registerSearchRoutes(app, {
    db,
    vectorStore: opts?.vectorStore,
    embeddingClient: opts?.embeddingClient,
    metrics: opts?.metrics,
    parseOptionalPositiveIntParam,
  });

  // Stats and analytics
  registerStatsRoutes(app, {
    db,
    usageCollector: opts?.usageCollector,
    parseOptionalPositiveIntParam,
  });

  // Project aliases
  registerProjectAliasRoutes(app, { db });

  // Project migration API (powers Swift UI: Rename / Archive / Undo)
  registerProjectMigrationRoutes(app, {
    db,
    parseOptionalPositiveIntParam,
    normalizeHttpPath,
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

    // Bounded sliding-window load so a huge session can't OOM the server;
    // summary sampling only consumes the head+tail anyway.
    let messages: Array<{ role: string; content: string }>;
    let totalSeen: number;
    try {
      const loaded = await loadBoundedMessages(
        adapter.streamMessages(session.filePath),
      );
      messages = loaded.messages;
      totalSeen = loaded.totalSeen;
    } catch {
      return c.json({ error: 'Failed to read session' }, 500);
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
      db.updateSessionSummary(sessionId, summary, totalSeen);
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
        msg.startsWith('Content ') ||
        msg.includes('requires either') ||
        msg.startsWith('source_session_id ');
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
    } catch {
      return c.json({ error: 'Handoff failed' }, 500);
    }
  });

  // --- Link sessions API ---
  app.post('/api/link-sessions', async (c) => {
    const body = await c.req.json().catch(() => ({}));
    const rawTargetDir = (body as Record<string, unknown>).targetDir as
      | string
      | undefined;
    if (!rawTargetDir) {
      return c.json({ error: 'Missing required field: targetDir' }, 400);
    }
    // link_sessions creates directories + symlinks under targetDir, so an
    // unconfined path lets any localhost process scatter symlinks anywhere on
    // the filesystem. Confine to $HOME the same way the other write endpoints
    // (/api/project/*, /api/lint) do.
    const norm = normalizeHttpPath(rawTargetDir);
    if (!norm.ok) {
      return c.json({ error: norm.error }, 400);
    }
    try {
      const result = await handleLinkSessions(db, { targetDir: norm.path });
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
    } catch {
      return c.json({ error: 'Failed to read session' }, 500);
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
    qoder: join(HOME, '.qoder/projects'),
    kimi: join(HOME, '.kimi/sessions'),
    commandcode: join(HOME, '.commandcode/projects'),
    cline: join(HOME, '.cline/data/tasks'),
    cursor: join(
      HOME,
      'Library/Application Support/Cursor/User/globalStorage/state.vscdb',
    ),
    vscode: join(
      HOME,
      'Library/Application Support/Code/User/workspaceStorage',
    ),
    antigravity: join(HOME, '.gemini/antigravity-cli/brain'),
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
    const selectedSources = sourceParam
      ? sourceParam.split(',').filter(Boolean)
      : [];
    const selectedProjects = projectParam
      ? projectParam.split(',').filter(Boolean)
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
    const pagination = parsePaginationParams(offsetParam, limitParam, 50, 100);
    if (!pagination.ok) return c.text(pagination.error, 400);

    const sessions = db.listSessions({
      sources: selectedSources,
      projects: selectedProjects,
      limit: pagination.limit,
      offset: pagination.offset,
      agents,
    });
    const total = db.countSessions({
      sources: selectedSources,
      projects: selectedProjects,
      agents,
    });
    const sources = db.listSources();
    const projects = db.listProjects();

    return c.html(
      sessionListPage(sessions, {
        offset: pagination.offset,
        limit: pagination.limit,
        hasMore: sessions.length === pagination.limit,
        total,
        selectedSources,
        sources,
        agents,
        selectedProjects,
        projects,
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
    const page = await readTranscriptPage(session, 0, detailPageSize);
    return c.html(
      sessionDetailPage(session, page.messages, {
        offset: 0,
        limit: detailPageSize,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset,
        error: page.error,
      }),
    );
  });

  // --- Live Sessions API ---
  app.get('/api/live', (c) => {
    return c.json(liveSessionsPayload(db, opts?.liveMonitor));
  });

  app.get('/api/live/events', () => {
    const payload = liveSessionsPayload(db, opts?.liveMonitor);
    return new Response(sseEvent('live', payload), {
      headers: {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
      },
    });
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

    const norm = normalizeHttpPath(cwd);
    if (!norm.ok) {
      return c.json({ error: norm.error }, 400);
    }

    // Validate: must exist as a directory
    try {
      const s = await stat(norm.path);
      if (!s.isDirectory())
        return c.json({ error: 'cwd is not a directory' }, 400);
    } catch {
      return c.json({ error: 'cwd does not exist' }, 400);
    }

    const result = await handleLintConfig({ cwd: norm.path });
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

    // Bound the free-form `data` blob — it's persisted verbatim, so an
    // oversized payload would bloat the log store / memory. Drop it with a
    // marker rather than rejecting the whole log line. 64KB is generous for
    // structured diagnostic context.
    const MAX_LOG_DATA_BYTES = 64 * 1024;
    let safeData = body.data;
    if (safeData !== undefined) {
      let oversized = false;
      try {
        oversized =
          Buffer.byteLength(JSON.stringify(safeData), 'utf8') >
          MAX_LOG_DATA_BYTES;
      } catch {
        // Non-serializable (e.g. circular) — treat as unusable.
        oversized = true;
      }
      if (oversized) {
        safeData = { _truncated: true, reason: 'data exceeded 64KB limit' };
      }
    }

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
        data: safeData,
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
