import type { Hono } from 'hono';
import type {
  Message,
  SessionAdapter,
  SessionInfo,
  SourceName,
} from '../../adapters/types.js';
import { resolveAdapterForLocator } from '../../adapters/types.js';
import { getAdapter } from '../../core/bootstrap.js';
import type { Database } from '../../core/db.js';
import { buildResumeCommand } from '../../core/resume-coordinator.js';
import { isDefaultVisibleTranscriptMessage } from '../../core/transcript-visibility.js';
import { renderSessionMessagesHtml } from '../views.js';

type WebApp = Hono<{ Variables: { traceId: string } }>;

type IntegerParamResult =
  | { ok: true; value: number }
  | { ok: false; error: string };

type OptionalIntegerParamResult =
  | { ok: true; value: number | undefined }
  | { ok: false; error: string };

type PaginationResult =
  | { ok: true; offset: number; limit: number }
  | { ok: false; error: string };

async function readTranscriptPage(
  session: SessionInfo,
  offset: number,
  limit: number,
  resolveAdapter: (
    session: Pick<SessionInfo, 'source' | 'filePath'>,
  ) => SessionAdapter | undefined,
): Promise<{
  messages: Pick<Message, 'role' | 'content'>[];
  hasMore: boolean;
  nextOffset: number;
  error?: string;
}> {
  const adapter = resolveAdapter(session);
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
    let rawIndex = 0;
    let nextOffset = offset;
    let hasMore = false;
    for await (const msg of adapter.streamMessages(session.filePath)) {
      if (rawIndex < offset) {
        rawIndex++;
        continue;
      }
      rawIndex++;
      if (!isDefaultVisibleTranscriptMessage(msg, session.source)) continue;
      if (messages.length >= limit) {
        hasMore = true;
        break;
      }
      messages.push({ role: msg.role, content: msg.content });
      nextOffset = rawIndex;
    }
    return {
      messages,
      hasMore,
      nextOffset,
    };
  } catch {
    return {
      messages: [],
      hasMore: false,
      nextOffset: offset,
      error: 'Failed to read session',
    };
  }
}

export function registerSessionRoutes(
  app: WebApp,
  deps: {
    db: Database;
    adapters?: SessionAdapter[];
    detailPageSize: number;
    parsePaginationParams: (
      rawOffset: string | undefined,
      rawLimit: string | undefined,
      defaultLimit: number,
      maxLimit: number,
    ) => PaginationResult;
    parseOptionalPositiveIntParam: (
      name: string,
      raw: string | undefined,
      max: number,
    ) => OptionalIntegerParamResult;
    parseNonNegativeInteger: (
      name: string,
      raw: string | undefined,
    ) => IntegerParamResult;
  },
) {
  function resolveAdapter(
    session: Pick<SessionInfo, 'source' | 'filePath'>,
  ): SessionAdapter | undefined {
    if (deps.adapters?.length) {
      return resolveAdapterForLocator(
        deps.adapters,
        session.source,
        session.filePath,
      );
    }
    return getAdapter(session.source, session.filePath);
  }

  app.get('/api/sessions', (c) => {
    const source = c.req.query('source') as SourceName | undefined;
    const project = c.req.query('project');
    const since = c.req.query('since');
    const until = c.req.query('until');
    const pagination = deps.parsePaginationParams(
      c.req.query('offset'),
      c.req.query('limit'),
      20,
      100,
    );
    if (!pagination.ok) return c.json({ error: pagination.error }, 400);

    const sessions = deps.db.listSessions({
      source,
      project,
      since,
      until,
      limit: pagination.limit,
      offset: pagination.offset,
    });
    return c.json({
      sessions,
      offset: pagination.offset,
      limit: pagination.limit,
      hasMore: sessions.length === pagination.limit,
    });
  });

  app.get('/api/sessions/:id', (c) => {
    const session = deps.db.getSession(c.req.param('id'));
    if (!session) {
      return c.json({ error: 'Session not found' }, 404);
    }
    return c.json(session);
  });

  app.get('/api/sessions/:id/messages', async (c) => {
    const session = deps.db.getSession(c.req.param('id'));
    if (!session) return c.json({ error: 'Session not found' }, 404);

    const pagination = deps.parsePaginationParams(
      c.req.query('offset'),
      c.req.query('limit'),
      deps.detailPageSize,
      200,
    );
    if (!pagination.ok) return c.json({ error: pagination.error }, 400);

    const page = await readTranscriptPage(
      session,
      pagination.offset,
      pagination.limit,
      resolveAdapter,
    );
    if (page.error) return c.json({ error: page.error }, 500);

    return c.json({
      html: renderSessionMessagesHtml(session, page.messages),
      offset: pagination.offset,
      limit: pagination.limit,
      count: page.messages.length,
      hasMore: page.hasMore,
      nextOffset: page.nextOffset,
    });
  });

  app.post('/api/sessions/:id/link', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ parentId: string }>();
    if (!body?.parentId) return c.json({ error: 'parentId required' }, 400);
    const validation = deps.db.validateParentLink(sessionId, body.parentId);
    if (validation !== 'ok') return c.json({ error: validation }, 400);
    deps.db.setParentSession(sessionId, body.parentId, 'manual');
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/link', (c) => {
    const sessionId = c.req.param('id');
    deps.db.clearParentSession(sessionId);
    return c.json({ ok: true });
  });

  app.post('/api/sessions/:id/confirm-suggestion', (c) => {
    const sessionId = c.req.param('id');
    const result = deps.db.confirmSuggestion(sessionId);
    if (!result.ok) return c.json({ error: result.error }, 400);
    return c.json({ ok: true });
  });

  app.delete('/api/sessions/:id/suggestion', async (c) => {
    const sessionId = c.req.param('id');
    const body = await c.req.json<{ suggestedParentId: string }>();
    if (!body?.suggestedParentId)
      return c.json({ error: 'suggestedParentId required' }, 400);
    const cleared = deps.db.clearSuggestedParent(
      sessionId,
      body.suggestedParentId,
    );
    if (!cleared) return c.json({ error: 'stale-suggestion' }, 409);
    return c.json({ ok: true });
  });

  app.get('/api/sessions/:id/children', (c) => {
    const parentId = c.req.param('id');
    const pagination = deps.parsePaginationParams(
      c.req.query('offset'),
      c.req.query('limit'),
      20,
      100,
    );
    if (!pagination.ok) return c.json({ error: pagination.error }, 400);
    const confirmed = deps.db.childSessions(
      parentId,
      pagination.limit,
      pagination.offset,
    );
    const suggested = deps.db.suggestedChildSessions(parentId);
    return c.json({ confirmed, suggested });
  });

  app.get('/api/sessions/:id/timeline', async (c) => {
    const session = deps.db.getSession(c.req.param('id'));
    if (!session) return c.json({ error: 'Session not found' }, 404);

    const adapter = resolveAdapter(session);
    if (!adapter)
      return c.json({ error: `No adapter for source: ${session.source}` }, 500);

    const limit = deps.parseOptionalPositiveIntParam(
      'limit',
      c.req.query('limit'),
      500,
    );
    if (!limit.ok) return c.json({ error: limit.error }, 400);
    const offset = c.req.query('offset')
      ? deps.parseNonNegativeInteger('offset', c.req.query('offset'))
      : ({ ok: true, value: 0 } as const);
    if (!offset.ok) return c.json({ error: offset.error }, 400);

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
    const collectTarget =
      limit.value !== undefined ? limit.value + 1 : undefined;

    try {
      let idx = 0;
      let collected = 0;
      let prevTimestamp: string | undefined;
      for await (const msg of adapter.streamMessages(session.filePath)) {
        if (idx < offset.value) {
          idx++;
          prevTimestamp = msg.timestamp;
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
    } catch {
      return c.json({ error: 'Failed to read session' }, 500);
    }

    const hasMore = limit.value !== undefined && entries.length > limit.value;
    if (hasMore) entries.pop();

    return c.json({
      sessionId: session.id,
      source: session.source,
      totalEntries: session.messageCount || entries.length,
      entries,
      ...(offset.value > 0 ? { offset: offset.value } : {}),
      ...(limit.value !== undefined ? { limit: limit.value, hasMore } : {}),
    });
  });

  app.post('/api/session/:id/resume', (c) => {
    const session = deps.db.getSession(c.req.param('id'));
    if (!session) return c.json({ error: 'Session not found', hint: '' }, 404);
    const result = buildResumeCommand(
      session.source,
      session.id,
      session.cwd ?? '',
    );
    return c.json(result);
  });
}
