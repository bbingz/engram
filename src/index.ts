#!/usr/bin/env node
// src/index.ts
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { join } from 'path'

import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher } from './core/watcher.js'
import { setupProcessLifecycle } from './core/lifecycle.js'
import { ensureDataDirs, createAdapters } from './core/bootstrap.js'
import { SqliteVecStore } from './core/vector-store.js'
import { createEmbeddingClient } from './core/embeddings.js'
import { EmbeddingIndexer } from './core/embedding-indexer.js'
import { readFileSettings } from './core/config.js'
import type { GetContextDeps } from './tools/get_context.js'

import { listSessionsTool, handleListSessions } from './tools/list_sessions.js'
import { getSessionTool, handleGetSession } from './tools/get_session.js'
import { searchTool, handleSearch } from './tools/search.js'
import { projectTimelineTool, handleProjectTimeline } from './tools/project_timeline.js'
import { statsTool, handleStats } from './tools/stats.js'
import { getContextTool, handleGetContext } from './tools/get_context.js'
import { exportTool, handleExport } from './tools/export.js'
import { generateSummaryTool, handleGenerateSummary } from './tools/generate_summary.js'

const DB_DIR = ensureDataDirs()
const db = new Database(join(DB_DIR, 'index.sqlite'))
const adapters = createAdapters()
const adapterMap = Object.fromEntries(adapters.map(a => [a.name, a]))
const indexer = new Indexer(db, adapters)

// Vector store — may fail if sqlite-vec can't load
let vectorDeps: GetContextDeps = {}
let embeddingIndexer: EmbeddingIndexer | undefined
try {
  const vectorStore = new SqliteVecStore(db.getRawDb())
  const fileSettings = readFileSettings()
  const embeddingClient = createEmbeddingClient({
    ollamaUrl: 'http://localhost:11434',
    openaiApiKey: fileSettings.openaiApiKey,
  })
  vectorDeps = {
    vectorStore,
    embed: (text) => embeddingClient.embed(text),
  }
  embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
} catch {
  // sqlite-vec unavailable — get_context falls back to FTS5
}

const allTools = [
  listSessionsTool,
  getSessionTool,
  searchTool,
  projectTimelineTool,
  statsTool,
  getContextTool,
  exportTool,
  generateSummaryTool,
]

const server = new Server(
  { name: 'engram', version: '0.1.0' },
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
      result = await handleGetContext(db, a as { cwd: string }, vectorDeps)
    } else if (name === 'export') {
      const session = db.getSession(a.id as string)
      if (!session) return { content: [{ type: 'text', text: `Session not found: ${a.id}` }], isError: true }
      const adapter = adapterMap[session.source]
      if (!adapter) return { content: [{ type: 'text', text: `Unsupported source: ${session.source}` }], isError: true }
      result = await handleExport(db, adapter, a as { id: string; format?: string })
    } else if (name === 'generate_summary') {
      return await handleGenerateSummary(db, a as { sessionId: string })
    } else {
      return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true }
    }

    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] }
  } catch (err) {
    return { content: [{ type: 'text', text: `Error: ${String(err)}` }], isError: true }
  }
})

// 启动时建立索引
indexer.indexAll().then(async (count) => {
  if (count > 0) {
    process.stderr.write(`[engram] Indexed ${count} new sessions\n`)
  }
  if (embeddingIndexer) {
    await embeddingIndexer.indexAll().catch(() => {})
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
