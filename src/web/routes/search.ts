import type { Hono } from 'hono';
import type { SourceName } from '../../adapters/types.js';
import type { Database } from '../../core/db.js';
import type { EmbeddingClient } from '../../core/embeddings.js';
import type { MetricsCollector } from '../../core/metrics.js';
import type { VectorStore } from '../../core/vector-store.js';
import { handleSearch, type SearchDeps } from '../../tools/search.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

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

export function registerSearchRoutes(
  app: WebApp,
  deps: {
    db: Database;
    vectorStore?: VectorStore;
    embeddingClient?: EmbeddingClient;
    metrics?: MetricsCollector;
    parseOptionalPositiveIntParam: (
      name: string,
      raw: string | undefined,
      max: number,
    ) => OptionalIntegerParamResult;
  },
) {
  const semanticLimiter = createRateLimiter(30);
  const searchDeps: SearchDeps = {
    ...(deps.vectorStore && deps.embeddingClient
      ? {
          vectorStore: deps.vectorStore,
          embed: (text: string) => deps.embeddingClient!.embed(text),
        }
      : {}),
    metrics: deps.metrics,
  };

  app.get('/api/search/status', (c) => {
    const totalSessions = deps.db.countSessions();
    const embeddedCount = deps.vectorStore?.count() ?? 0;
    const available = !!(deps.vectorStore && deps.embeddingClient);
    return c.json({
      available,
      model: available ? deps.embeddingClient?.model : null,
      embeddedCount,
      totalSessions,
      progress:
        totalSessions > 0
          ? Math.round((embeddedCount / totalSessions) * 100)
          : 0,
    });
  });

  app.get('/api/search', async (c) => {
    const q = c.req.query('q') ?? '';
    const source = c.req.query('source') as SourceName | undefined;
    const project = c.req.query('project');
    const since = c.req.query('since');
    const limit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      100,
    );
    if (!limit.ok) return c.json({ error: limit.error }, 400);
    const mode = c.req.query('mode') as string | undefined;
    const agents = c.req.query('agents') as 'hide' | undefined;
    const tools = c.req.query('tools') as 'hide' | undefined;

    try {
      const result = await handleSearch(
        deps.db,
        {
          query: q,
          source,
          project,
          since,
          limit: limit.value,
          mode,
          agents,
          tools,
        },
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

  app.get('/api/search/semantic', async (c) => {
    if (!semanticLimiter()) {
      return c.json(
        { error: 'Rate limit exceeded — max 30 requests/minute' },
        429,
      );
    }
    if (!deps.vectorStore || !deps.embeddingClient) {
      return c.json(
        {
          error:
            'Semantic search not available — no embedding provider configured',
        },
        501,
      );
    }
    const q = c.req.query('q') ?? '';
    const limit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      100,
    );
    if (!limit.ok) return c.json({ error: limit.error }, 400);
    try {
      const result = await handleSearch(
        deps.db,
        { query: q, limit: limit.value ?? 10, mode: 'semantic' },
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
}
