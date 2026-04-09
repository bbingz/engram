#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
// src/index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { AiAuditWriter } from './core/ai-audit.js';
import {
  createAdapters,
  ensureDataDirs,
  initVectorDeps,
  initViking,
} from './core/bootstrap.js';
import { DEFAULT_AI_AUDIT_CONFIG, readFileSettings } from './core/config.js';
import { Database } from './core/db.js';
import { IndexJobRunner } from './core/index-job-runner.js';
import { Indexer } from './core/indexer.js';
import { setupProcessLifecycle } from './core/lifecycle.js';
import { createLogger } from './core/logger.js';
import { runWithContext } from './core/request-context.js';
import { Tracer, TraceWriter } from './core/tracer.js';
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
  handleProjectTimeline,
  projectTimelineTool,
} from './tools/project_timeline.js';
import { handleSearch, type SearchDeps, searchTool } from './tools/search.js';
import { handleStats, statsTool } from './tools/stats.js';
import {
  handleToolAnalytics,
  toolAnalyticsTool,
} from './tools/tool_analytics.js';

const log = createLogger('mcp', { stderrJson: true });

const DB_DIR = ensureDataDirs();
const db = new Database(join(DB_DIR, 'index.sqlite'));
const traceWriter = new TraceWriter(db.raw);
const tracer = new Tracer(traceWriter);
const adapters = createAdapters();
const adapterMap = Object.fromEntries(adapters.map((a) => [a.name, a]));

// Settings + Viking bridge — must come before indexer so it can dual-write
const fileSettings = readFileSettings();
const auditConfig = { ...DEFAULT_AI_AUDIT_CONFIG, ...fileSettings.aiAudit };
const audit = new AiAuditWriter(db.getRawDb(), auditConfig);
const vikingBridge = initViking(fileSettings, { audit });
const authoritativeNode = fileSettings.syncNodeName || 'local';

// Apply tier-based noise filter
db.noiseFilter = fileSettings.noiseFilter ?? 'hide-skip';

const indexer = new Indexer(db, adapters, {
  viking: vikingBridge,
  vikingAutoPush: fileSettings.viking?.autoPush ?? false,
  authoritativeNode,
});

// Vector store — may fail if sqlite-vec can't load
const vecDeps = initVectorDeps(db, {
  openaiApiKey: fileSettings.openaiApiKey,
  ollamaUrl: fileSettings.ollamaUrl,
  ollamaModel: fileSettings.ollamaModel,
  embeddingDimension: fileSettings.embeddingDimension,
  audit,
});
const vectorDeps: GetContextDeps = vecDeps
  ? {
      vectorStore: vecDeps.vectorStore,
      embed: (text) => vecDeps.embeddingClient.embed(text),
    }
  : {};
const indexJobRunner = new IndexJobRunner(
  db,
  vecDeps?.vectorStore,
  vecDeps?.embeddingClient,
);

const manageProjectAliasTool = {
  name: 'manage_project_alias',
  description:
    'Link two project names so sessions from one appear in queries for the other. Use when a project directory has been moved or renamed.',
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
];

const server = new Server(
  { name: 'engram', version: '0.1.0' },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: allTools,
}));

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
    viking: vikingBridge,
    log,
    tracer,
  };
  return handleSearch(db, a as { query: string; mode?: string }, sDeps);
});

toolRegistry.set('get_context', async (a) => {
  const ctxDeps: GetContextDeps = { ...vectorDeps, viking: vikingBridge, log };
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
  handleGetMemory(a as { query: string }, { viking: vikingBridge, log }),
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

      return {
        content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
      };
    } catch (err) {
      span.setError(err as Error);
      return {
        content: [{ type: 'text', text: `Error: ${String(err)}` }],
        isError: true,
      };
    }
  });
});

// 启动时建立索引
indexer
  .indexAll()
  .then(async (count) => {
    if (count > 0) {
      process.stderr.write(`[engram] Indexed ${count} new sessions\n`);
    }
    await indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: best-effort in MCP server mode
  })
  .catch(() => {}); // intentional: indexing failure is non-fatal for MCP server

// 启动文件监听
const watcher = startWatcher(adapters, indexer, {
  onIndexed: () => {
    indexJobRunner.runRecoverableJobs().catch(() => {}); // intentional: fire-and-forget background job
  },
});

const transport = new StdioServerTransport();
await server.connect(transport);

// Multi-layer process lifecycle — MUST be after transport connects
// so that stdin.resume() doesn't race with StdioServerTransport's stdin reader.
({ heartbeat } = setupProcessLifecycle({
  onExit: () => {
    watcher?.close();
  },
}));
