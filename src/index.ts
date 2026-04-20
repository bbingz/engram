#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
// src/index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { createMCPDeps } from './core/bootstrap.js';
import { setupProcessLifecycle } from './core/lifecycle.js';
import { createLogger } from './core/logger.js';
import {
  buildErrorEnvelope,
  humanizeForMcp,
} from './core/project-move/retry-policy.js';
import { runWithContext } from './core/request-context.js';
import { startWatcher } from './core/watcher.js';
import { exportTool, handleExport } from './tools/export.js';
import { handleFileActivity } from './tools/file_activity.js';
import {
  generateSummaryTool,
  handleGenerateSummary,
} from './tools/generate_summary.js';
import type { GetContextDeps } from './tools/get_context.js';
import { getContextTool, handleGetContext } from './tools/get_context.js';
import { getCostsTool, handleGetCosts } from './tools/get_costs.js';
import {
  getInsightsDefinition,
  handleGetInsights,
} from './tools/get_insights.js';
import { getMemoryTool, handleGetMemory } from './tools/get_memory.js';
import { getSessionTool, handleGetSession } from './tools/get_session.js';
import { handleHandoff, handoffTool } from './tools/handoff.js';
import { handleLinkSessions, linkSessionsTool } from './tools/link_sessions.js';
import { handleLintConfig, lintConfigTool } from './tools/lint_config.js';
import { handleListSessions, listSessionsTool } from './tools/list_sessions.js';
import { handleLiveSessions, liveSessionsTool } from './tools/live_sessions.js';
import {
  handleProjectArchive,
  handleProjectListMigrations,
  handleProjectMove,
  handleProjectMoveBatch,
  handleProjectRecover,
  handleProjectReview,
  handleProjectUndo,
  projectArchiveTool,
  projectListMigrationsTool,
  projectMoveBatchTool,
  projectMoveTool,
  projectRecoverTool,
  projectReviewTool,
  projectUndoTool,
} from './tools/project.js';
import {
  handleProjectTimeline,
  projectTimelineTool,
} from './tools/project_timeline.js';
import { handleSaveInsight, saveInsightTool } from './tools/save_insight.js';
import { handleSearch, type SearchDeps, searchTool } from './tools/search.js';
import { handleStats, statsTool } from './tools/stats.js';
import {
  handleToolAnalytics,
  toolAnalyticsTool,
} from './tools/tool_analytics.js';

const log = createLogger('mcp', { stderrJson: true });

const {
  db,
  adapters,
  adapterMap,
  settings: fileSettings,
  audit,
  tracer,
  indexer,
  indexJobRunner,
  vecDeps,
  vectorStore,
  embed,
} = createMCPDeps();
const vectorDeps: GetContextDeps = { vectorStore, embed };

const manageProjectAliasTool = {
  name: 'manage_project_alias',
  description:
    'Link two project names so sessions from one appear in queries for the other. ' +
    'Only use this for directories moved MANUALLY outside of engram ' +
    '(e.g. someone ran `mv` directly). Do NOT call after project_move — ' +
    'that tool already creates the alias automatically.',
  inputSchema: {
    type: 'object' as const,
    required: ['action'],
    properties: {
      action: {
        type: 'string',
        enum: ['add', 'remove', 'list'],
        description: 'Action to perform',
      },
      old_project: {
        type: 'string',
        description: 'Old project name (for add/remove)',
      },
      new_project: {
        type: 'string',
        description: 'New project name (for add/remove)',
      },
    },
    additionalProperties: false,
  },
};

const allTools = [
  listSessionsTool,
  getSessionTool,
  searchTool,
  projectTimelineTool,
  statsTool,
  getContextTool,
  exportTool,
  generateSummaryTool,
  manageProjectAliasTool,
  linkSessionsTool,
  getMemoryTool,
  saveInsightTool,
  getCostsTool,
  toolAnalyticsTool,
  handoffTool,
  liveSessionsTool,
  lintConfigTool,
  getInsightsDefinition,
  {
    name: 'file_activity',
    description:
      'Show most frequently edited/read files across sessions for a project. Helps understand project activity patterns.',
    inputSchema: {
      type: 'object' as const,
      properties: {
        project: { type: 'string', description: 'Filter by project name' },
        since: { type: 'string', description: 'ISO 8601 date filter' },
        limit: { type: 'number', description: 'Max results (default 50)' },
      },
    },
  },
  // Phase 4a: project directory operations. Ordering matters for AI tool
  // selection (first-seen heuristic) — high-intent actions first, diagnostic/
  // review tools last so AI doesn't "try review" instead of committing.
  projectMoveTool,
  projectArchiveTool,
  projectUndoTool,
  projectMoveBatchTool,
  projectListMigrationsTool,
  projectRecoverTool,
  projectReviewTool,
];

const ENGRAM_INSTRUCTIONS = `Engram is a cross-tool AI session aggregator. Key tools:
- search: Full-text + semantic search across all AI coding sessions (15+ tools)
- get_context: Auto-extract relevant project history for your current task
- save_insight: Save important decisions, lessons, and knowledge for future sessions
- get_memory: Retrieve previously saved insights and cross-session knowledge
- get_session: Read full conversation transcript of any session
- list_sessions: Browse sessions with filters (source, project, date)
- project_move / project_archive / project_undo: move or rename a project directory
    while keeping all AI session history reachable (patches cwd in 6 tool stores,
    renames Claude Code encoded dir, updates DB, creates alias). Use dry_run:true
    first to preview impact.

Best practices:
1. Call get_context at the start of a task to see what's been done before
2. Use save_insight to preserve important decisions that should persist
3. Verify facts from memory before acting on them — memories can be stale
4. Cite session IDs when referencing past work`;

const server = new Server(
  { name: 'engram', version: '0.1.0' },
  { capabilities: { tools: {} }, instructions: ENGRAM_INSTRUCTIONS },
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  heartbeat();
  return { tools: allTools };
});

let heartbeat = () => {}; // assigned after transport connects

// --- Tool Registry Pattern (replaces 95-line if/else chain) ---

type ToolHandler = (
  args: Record<string, unknown>,
) => Promise<unknown> | unknown;

const toolRegistry = new Map<string, ToolHandler>();

toolRegistry.set('list_sessions', (a) => handleListSessions(db, a, { log }));
toolRegistry.set('project_timeline', (a) =>
  handleProjectTimeline(db, a as { project: string }, { log }),
);
toolRegistry.set('stats', (a) => handleStats(db, a, { log }));
toolRegistry.set('link_sessions', (a) =>
  handleLinkSessions(db, a as { targetDir: string }, { log }),
);
toolRegistry.set('get_costs', (a) =>
  handleGetCosts(
    db,
    a as { group_by?: string; since?: string; until?: string },
    { log },
  ),
);
toolRegistry.set('tool_analytics', (a) =>
  handleToolAnalytics(
    db,
    a as { project?: string; since?: string; group_by?: string },
    { log },
  ),
);
toolRegistry.set('live_sessions', () => handleLiveSessions(null, { log }));
toolRegistry.set('file_activity', (a) =>
  handleFileActivity(
    db,
    a as { project?: string; since?: string; limit?: number },
    { log },
  ),
);

toolRegistry.set('get_session', async (a) => {
  const session = db.getSession(a.id as string);
  if (!session)
    return {
      _early: true,
      content: [{ type: 'text', text: `Session not found: ${a.id}` }],
      isError: true,
    };
  const adapter = adapterMap[session.source];
  if (!adapter)
    return {
      _early: true,
      content: [
        { type: 'text', text: `Unsupported source: ${session.source}` },
      ],
      isError: true,
    };
  return handleGetSession(
    db,
    adapter,
    a as { id: string; page?: number; roles?: string[] },
    { log },
  );
});

toolRegistry.set('export', async (a) => {
  const session = db.getSession(a.id as string);
  if (!session)
    return {
      _early: true,
      content: [{ type: 'text', text: `Session not found: ${a.id}` }],
      isError: true,
    };
  const adapter = adapterMap[session.source];
  if (!adapter)
    return {
      _early: true,
      content: [
        { type: 'text', text: `Unsupported source: ${session.source}` },
      ],
      isError: true,
    };
  return handleExport(db, adapter, a as { id: string; format?: string }, {
    log,
  });
});

toolRegistry.set('search', async (a) => {
  const sDeps: SearchDeps = {
    ...(vecDeps
      ? {
          vectorStore: vecDeps.vectorStore,
          embed: (text: string) => vecDeps.embeddingClient.embed(text),
        }
      : {}),
    log,
    tracer,
  };
  return handleSearch(db, a as { query: string; mode?: string }, sDeps);
});

toolRegistry.set('get_context', async (a) => {
  const ctxDeps: GetContextDeps = { ...vectorDeps, log };
  const ctx = await handleGetContext(
    db,
    a as {
      cwd: string;
      task?: string;
      max_tokens?: number;
      detail?: 'abstract' | 'overview' | 'full';
      sort_by?: 'recency' | 'score';
      include_environment?: boolean;
    },
    ctxDeps,
  );
  return { _early: true, content: [{ type: 'text', text: ctx.contextText }] };
});

toolRegistry.set('generate_summary', async (a) => {
  return {
    _early: true,
    ...(await handleGenerateSummary(db, a as { sessionId: string }, {
      log,
      audit,
    })),
  };
});

toolRegistry.set('manage_project_alias', async (a) => {
  const action = a.action as string;
  if (action === 'list') return db.listProjectAliases();
  if (action === 'add') {
    if (!a.old_project || !a.new_project)
      return {
        _early: true,
        content: [
          { type: 'text', text: 'old_project and new_project required' },
        ],
        isError: true,
      };
    db.addProjectAlias(a.old_project as string, a.new_project as string);
    return { added: { alias: a.old_project, canonical: a.new_project } };
  }
  if (action === 'remove') {
    if (!a.old_project || !a.new_project)
      return {
        _early: true,
        content: [
          { type: 'text', text: 'old_project and new_project required' },
        ],
        isError: true,
      };
    db.removeProjectAlias(a.old_project as string, a.new_project as string);
    return { removed: { alias: a.old_project, canonical: a.new_project } };
  }
  return {
    _early: true,
    content: [{ type: 'text', text: `Unknown action: ${action}` }],
    isError: true,
  };
});

toolRegistry.set('get_memory', async (a) =>
  handleGetMemory(a as { query: string }, {
    vecStore: vecDeps?.vectorStore,
    embedder: vecDeps?.embeddingClient ?? null,
    db,
    log,
  }),
);

toolRegistry.set('save_insight', async (a) =>
  handleSaveInsight(
    a as { content: string; wing?: string; room?: string; importance?: number },
    {
      vecStore: vecDeps?.vectorStore,
      embedder: vecDeps?.embeddingClient ?? null,
      db,
      log,
    },
  ),
);

toolRegistry.set('handoff', async (a) =>
  handleHandoff(
    db,
    a as { cwd: string; sessionId?: string; format?: 'markdown' | 'plain' },
    adapters,
    { log },
  ),
);

toolRegistry.set('lint_config', async (a) => {
  if (!a.cwd)
    return {
      _early: true,
      content: [{ type: 'text', text: 'cwd parameter required' }],
      isError: true,
    };
  return handleLintConfig({ cwd: a.cwd as string }, { log });
});

toolRegistry.set('get_insights', async (a) => {
  return {
    _early: true,
    ...(await handleGetInsights(db, fileSettings, a as { since?: string })),
  };
});

// Phase 4a — project_* tools (thin wrappers over orchestrator/undo/recover/batch)
toolRegistry.set('project_move', (a) =>
  handleProjectMove(
    db,
    a as {
      src: string;
      dst: string;
      dry_run?: boolean;
      force?: boolean;
      note?: string;
    },
    { log },
  ),
);
toolRegistry.set('project_archive', (a) =>
  handleProjectArchive(
    db,
    a as {
      src: string;
      to?: '历史脚本' | '空项目' | '归档完成';
      force?: boolean;
      note?: string;
    },
    { log },
  ),
);
toolRegistry.set('project_review', (a) =>
  handleProjectReview(a as { old_path: string; new_path: string }, { log }),
);
toolRegistry.set('project_undo', (a) =>
  handleProjectUndo(db, a as { migration_id: string; force?: boolean }, {
    log,
  }),
);
toolRegistry.set('project_list_migrations', (a) =>
  handleProjectListMigrations(db, a as { limit?: number; since?: string }, {
    log,
  }),
);
toolRegistry.set('project_recover', (a) =>
  handleProjectRecover(
    db,
    a as { since?: string; include_committed?: boolean },
    { log },
  ),
);
toolRegistry.set('project_move_batch', (a) =>
  handleProjectMoveBatch(db, a as { yaml: string; force?: boolean }, { log }),
);

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  heartbeat();
  const { name, arguments: args } = request.params;
  const a = (args ?? {}) as Record<string, unknown>;

  const requestId = randomUUID();
  return runWithContext({ requestId, source: 'mcp' }, async () => {
    const span = tracer.startSpan(`tool.${name}`, 'mcp');
    try {
      const handler = toolRegistry.get(name);
      if (!handler) {
        span.setAttribute('tool_error', 'unknown_tool');
        span.end();
        return {
          content: [{ type: 'text', text: `Unknown tool: ${name}` }],
          isError: true,
        };
      }

      const result = await handler(a);
      span.end();

      // Check for early return (tools that already formatted their response)
      if ((result as { _early?: boolean })._early) {
        const { _early, ...response } = result as Record<string, unknown> & {
          _early: boolean;
        };
        return response;
      }

      // Emit structuredContent on success too so AI clients get typed
      // access to `migrationId`, `totalFilesPatched`, etc. without re-parsing
      // the text blob (Codex follow-up important #2 — previously only the
      // error path populated structuredContent).
      return {
        content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
        structuredContent: result as Record<string, unknown>,
      };
    } catch (err) {
      span.setError(err as Error);

      // Round 4: retry_policy + structured-details extraction + message
      // humanization all delegate to the shared retry-policy module so
      // MCP and HTTP produce the same envelope. Previously this switch
      // and the one in src/web.ts drifted (unknown-error default was
      // 'never' here but 'safe' over HTTP), and DirCollisionError's
      // sourceId/newDir were silently dropped by both layers.
      const structured = buildErrorEnvelope(err, { sanitize: false });
      const humanText = humanizeForMcp(err);
      return {
        content: [{ type: 'text', text: humanText }],
        isError: true,
        structuredContent: structured,
        _structuredError: structured.error,
      };
    }
  });
});

// One-shot heal of empty file_path rows on startup. Mirrors the daemon's
// equivalent call; needed because daemon may not be running (MCP-only mode).
try {
  const fixed = db.backfillFilePaths();
  if (fixed > 0) {
    process.stderr.write(`[engram] backfilled ${fixed} empty file_path rows\n`);
  }
} catch {
  // intentional: backfill failure must not block MCP startup
}

// Clean up stale project-move migrations (crashed mid-way, stuck pending)
try {
  const stale = db.cleanupStaleMigrations();
  if (stale > 0) {
    process.stderr.write(
      `[engram] marked ${stale} stale migrations as failed (crashed mid-move)\n`,
    );
  }
} catch {
  // intentional: cleanup failure must not block startup
}

// 启动时建立索引
indexer
  .indexAll()
  .then(async (count) => {
    if (count > 0) {
      process.stderr.write(`[engram] Indexed ${count} new sessions\n`);
    }
    await indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: best-effort in MCP server mode

    // Background orphan scan — non-blocking. Uses adapter.isAccessible so
    // virtual-path adapters (opencode/cursor) don't get false-positives.
    setImmediate(() => {
      db.detectOrphans(adapters)
        .then((r) => {
          if (r.newlyFlagged > 0 || r.confirmed > 0 || r.recovered > 0) {
            process.stderr.write(
              `[engram] orphan scan: +${r.newlyFlagged} flagged, +${r.confirmed} confirmed, ${r.recovered} recovered (of ${r.scanned})\n`,
            );
          }
        })
        .catch(() => {}); // intentional: orphan scan must not break MCP
    });
  })
  .catch(() => {}); // intentional: indexing failure is non-fatal for MCP server

// 启动文件监听
const watcher = startWatcher(adapters, indexer, {
  // During an in-flight project move, chokidar fires unlink(old)+add(new).
  // We must skip BOTH: don't orphan the old path (move is intentional), AND
  // don't index the new path (JSONL cwd patch may not be done yet — indexing
  // would re-persist the pre-patch cwd). Applies to add, change, unlink.
  shouldSkip: (filePath) => db.hasPendingMigrationFor(filePath),
  onIndexed: () => {
    indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: fire-and-forget background job
  },
  onUnlink: (filePath) => {
    // Source-side cleanup (Claude Code subagent GC, rm -rf, etc.) — mark orphan, don't delete.
    db.markOrphanByPath(filePath, 'cleaned_by_source');
  },
});

const transport = new StdioServerTransport();
await server.connect(transport);

// Multi-layer process lifecycle — MUST be after transport connects
// so that stdin.resume() doesn't race with StdioServerTransport's stdin reader.
// Idle timeout disabled for MCP server: Claude Code manages the process lifecycle
// via stdin close. The 5-min default caused premature exits during normal
// conversation gaps, leading to "MCP server disconnected" errors.
({ heartbeat } = setupProcessLifecycle({
  idleTimeoutMs: 0,
  onExit: () => {
    watcher?.close();
  },
}));
