#!/usr/bin/env node
// src/index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { homedir } from 'os'
import { join } from 'path'
import { mkdirSync } from 'fs'

import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher } from './core/watcher.js'
import { setupProcessLifecycle } from './core/lifecycle.js'
import { CodexAdapter } from './adapters/codex.js'
import { ClaudeCodeAdapter } from './adapters/claude-code.js'
import { GeminiCliAdapter } from './adapters/gemini-cli.js'
import { OpenCodeAdapter } from './adapters/opencode.js'
import { IflowAdapter } from './adapters/iflow.js'
import { QwenAdapter } from './adapters/qwen.js'
import { KimiAdapter } from './adapters/kimi.js'
import { ClineAdapter } from './adapters/cline.js'
import { CursorAdapter } from './adapters/cursor.js'
import { VsCodeAdapter } from './adapters/vscode.js'
import { AntigravityAdapter } from './adapters/antigravity.js'
import { WindsurfAdapter } from './adapters/windsurf.js'

import { listSessionsTool, handleListSessions } from './tools/list_sessions.js'
import { getSessionTool, handleGetSession } from './tools/get_session.js'
import { searchTool, handleSearch } from './tools/search.js'
import { projectTimelineTool, handleProjectTimeline } from './tools/project_timeline.js'
import { statsTool, handleStats } from './tools/stats.js'
import { getContextTool, handleGetContext } from './tools/get_context.js'
import { exportTool, handleExport } from './tools/export.js'

const DB_DIR = join(homedir(), '.coding-memory')
mkdirSync(DB_DIR, { recursive: true })
mkdirSync(join(homedir(), '.coding-memory', 'cache', 'antigravity'), { recursive: true })
mkdirSync(join(homedir(), '.coding-memory', 'cache', 'windsurf'), { recursive: true })
const db = new Database(join(DB_DIR, 'index.sqlite'))

const adapters = [
  new CodexAdapter(),
  new ClaudeCodeAdapter(),
  new GeminiCliAdapter(),
  new OpenCodeAdapter(),
  new IflowAdapter(),
  new QwenAdapter(),
  new KimiAdapter(),
  new ClineAdapter(),
  new CursorAdapter(),
  new VsCodeAdapter(),
  new AntigravityAdapter(),
  new WindsurfAdapter(),
]

const adapterMap = Object.fromEntries(adapters.map(a => [a.name, a]))
const indexer = new Indexer(db, adapters)

const allTools = [
  listSessionsTool,
  getSessionTool,
  searchTool,
  projectTimelineTool,
  statsTool,
  getContextTool,
  exportTool,
]

const server = new Server(
  { name: 'coding-memory', version: '0.1.0' },
  { capabilities: { tools: {} } }
)

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: allTools,
}))

let heartbeat = () => {} // assigned after transport connects

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  heartbeat()
  const { name, arguments: args } = request.params
  const a = (args ?? {}) as Record<string, unknown>

  try {
    let result: unknown

    if (name === 'list_sessions') {
      result = await handleListSessions(db, a)
    } else if (name === 'get_session') {
      const session = db.getSession(a.id as string)
      if (!session) return { content: [{ type: 'text', text: `Session not found: ${a.id}` }], isError: true }
      const adapter = adapterMap[session.source]
      if (!adapter) return { content: [{ type: 'text', text: `Unsupported source: ${session.source}` }], isError: true }
      result = await handleGetSession(db, adapter, a as { id: string; page?: number; roles?: string[] })
    } else if (name === 'search') {
      result = await handleSearch(db, a as { query: string })
    } else if (name === 'project_timeline') {
      result = await handleProjectTimeline(db, a as { project: string })
    } else if (name === 'stats') {
      result = await handleStats(db, a)
    } else if (name === 'get_context') {
      result = await handleGetContext(db, a as { cwd: string })
    } else if (name === 'export') {
      const session = db.getSession(a.id as string)
      if (!session) return { content: [{ type: 'text', text: `Session not found: ${a.id}` }], isError: true }
      const adapter = adapterMap[session.source]
      if (!adapter) return { content: [{ type: 'text', text: `Unsupported source: ${session.source}` }], isError: true }
      result = await handleExport(db, adapter, a as { id: string; format?: string })
    } else {
      return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true }
    }

    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
  } catch (err) {
    return { content: [{ type: 'text', text: `Error: ${String(err)}` }], isError: true }
  }
})

// 启动时建立索引
indexer.indexAll().then(count => {
  if (count > 0) {
    process.stderr.write(`[coding-memory] Indexed ${count} new sessions\n`)
  }
}).catch(() => {})

// 启动文件监听
const watcher = startWatcher(adapters, indexer)

const transport = new StdioServerTransport()
await server.connect(transport)

// Multi-layer process lifecycle — MUST be after transport connects
// so that stdin.resume() doesn't race with StdioServerTransport's stdin reader.
;({ heartbeat } = setupProcessLifecycle({
  onExit: () => { watcher?.close() },
}))
