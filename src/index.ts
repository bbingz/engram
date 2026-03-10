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
import { ensureDataDirs, createAdapters, initVectorDeps } from './core/bootstrap.js'
import { readFileSettings } from './core/config.js'
import type { GetContextDeps } from './tools/get_context.js'

import { listSessionsTool, handleListSessions } from './tools/list_sessions.js'
import { getSessionTool, handleGetSession } from './tools/get_session.js'
import { searchTool, handleSearch, type SearchDeps } from './tools/search.js'
import { projectTimelineTool, handleProjectTimeline } from './tools/project_timeline.js'
import { statsTool, handleStats } from './tools/stats.js'
import { getContextTool, handleGetContext } from './tools/get_context.js'
import { exportTool, handleExport } from './tools/export.js'
import { generateSummaryTool, handleGenerateSummary } from './tools/generate_summary.js'
import { linkSessionsTool, handleLinkSessions } from './tools/link_sessions.js'

const DB_DIR = ensureDataDirs()
const db = new Database(join(DB_DIR, 'index.sqlite'))
const adapters = createAdapters()
const adapterMap = Object.fromEntries(adapters.map(a => [a.name, a]))
const indexer = new Indexer(db, adapters)

// Vector store — may fail if sqlite-vec can't load
const fileSettings = readFileSettings()
const vecDeps = initVectorDeps(db, {
  openaiApiKey: fileSettings.openaiApiKey,
  ollamaUrl: fileSettings.ollamaUrl,
  ollamaModel: fileSettings.ollamaModel,
  embeddingDimension: fileSettings.embeddingDimension,
})
const vectorDeps: GetContextDeps = vecDeps
  ? { vectorStore: vecDeps.vectorStore, embed: (text) => vecDeps.embeddingClient.embed(text) }
  : {}

const manageProjectAliasTool = {
  name: 'manage_project_alias',
  description: 'Link two project names so sessions from one appear in queries for the other. Use when a project directory has been moved or renamed.',
  inputSchema: {
    type: 'object' as const,
    required: ['action'],
    properties: {
      action: { type: 'string', enum: ['add', 'remove', 'list'], description: 'Action to perform' },
      old_project: { type: 'string', description: 'Old project name (for add/remove)' },
      new_project: { type: 'string', description: 'New project name (for add/remove)' },
    },
    additionalProperties: false,
  },
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
  manageProjectAliasTool,
  linkSessionsTool,
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
      const sDeps: SearchDeps = vecDeps
        ? { vectorStore: vecDeps.vectorStore, embed: (text) => vecDeps.embeddingClient.embed(text) }
        : {}
      result = await handleSearch(db, a as { query: string; mode?: string }, sDeps)
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
    } else if (name === 'manage_project_alias') {
      const action = a.action as string
      if (action === 'list') {
        result = db.listProjectAliases()
      } else if (action === 'add') {
        if (!a.old_project || !a.new_project) return { content: [{ type: 'text', text: 'old_project and new_project required' }], isError: true }
        db.addProjectAlias(a.old_project as string, a.new_project as string)
        result = { added: { alias: a.old_project, canonical: a.new_project } }
      } else if (action === 'remove') {
        if (!a.old_project || !a.new_project) return { content: [{ type: 'text', text: 'old_project and new_project required' }], isError: true }
        db.removeProjectAlias(a.old_project as string, a.new_project as string)
        result = { removed: { alias: a.old_project, canonical: a.new_project } }
      } else {
        return { content: [{ type: 'text', text: `Unknown action: ${action}` }], isError: true }
      }
    } else if (name === 'link_sessions') {
      result = await handleLinkSessions(db, a as { targetDir: string })
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
  if (vecDeps) {
    await vecDeps.embeddingIndexer.indexAll().catch(() => {})
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
