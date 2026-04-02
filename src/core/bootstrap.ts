// src/core/bootstrap.ts
// Shared initialization for both MCP server (index.ts) and daemon (daemon.ts).
import { homedir } from 'os'
import { join } from 'path'
import { mkdirSync } from 'fs'
import { migrateDataDir } from './migrate.js'
import { CodexAdapter } from '../adapters/codex.js'
import { ClaudeCodeAdapter } from '../adapters/claude-code.js'
import { GeminiCliAdapter } from '../adapters/gemini-cli.js'
import { OpenCodeAdapter } from '../adapters/opencode.js'
import { IflowAdapter } from '../adapters/iflow.js'
import { QwenAdapter } from '../adapters/qwen.js'
import { KimiAdapter } from '../adapters/kimi.js'
import { ClineAdapter } from '../adapters/cline.js'
import { CursorAdapter } from '../adapters/cursor.js'
import { VsCodeAdapter } from '../adapters/vscode.js'
import { AntigravityAdapter } from '../adapters/antigravity.js'
import { CopilotAdapter } from '../adapters/copilot.js'
import { WindsurfAdapter } from '../adapters/windsurf.js'
import type { SessionAdapter, SourceName } from '../adapters/types.js'
import { SqliteVecStore } from './vector-store.js'
import { createEmbeddingClient } from './embeddings.js'
import { EmbeddingIndexer } from './embedding-indexer.js'
import type { EmbeddingClient } from './embeddings.js'
import type { Database } from './db.js'
import type { FileSettings } from './config.js'
import { VikingBridge } from './viking-bridge.js'
import type { Logger } from './logger.js'
import type { MetricsCollector } from './metrics.js'
import type { Tracer } from './tracer.js'

export const ENGRAM_DIR = join(homedir(), '.engram')

export function ensureDataDirs(): string {
  migrateDataDir()
  mkdirSync(join(ENGRAM_DIR, 'cache', 'antigravity'), { recursive: true })
  mkdirSync(join(ENGRAM_DIR, 'cache', 'windsurf'), { recursive: true })
  return ENGRAM_DIR
}

export function createAdapters(): SessionAdapter[] {
  return [
    new CodexAdapter(),
    new ClaudeCodeAdapter(),
    new GeminiCliAdapter(),
    new OpenCodeAdapter(),
    new IflowAdapter(),
    new QwenAdapter(),
    new KimiAdapter(),
    new CopilotAdapter(),
    new ClineAdapter(),
    new CursorAdapter(),
    new VsCodeAdapter(),
    new AntigravityAdapter(),
    new WindsurfAdapter(),
  ]
}

const adapters = createAdapters()
const adapterMap = new Map(adapters.map(a => [a.name, a]))

export function getAdapter(name: string): SessionAdapter | undefined {
  return adapterMap.get(name as SourceName)
}

// --- Viking bridge factory ---

export function initViking(settings: FileSettings, opts?: { log?: Logger; metrics?: MetricsCollector; tracer?: Tracer }): VikingBridge | null {
  if (settings.viking?.enabled && settings.viking.url && settings.viking.apiKey) {
    return new VikingBridge(settings.viking.url, settings.viking.apiKey, {
      agentId: settings.viking.agentId,
      ...opts,
    })
  }
  return null
}

export interface VectorDeps {
  vectorStore: SqliteVecStore
  embeddingClient: EmbeddingClient
  embeddingIndexer: EmbeddingIndexer
}

export interface VectorDepsOptions {
  openaiApiKey?: string
  ollamaUrl?: string
  ollamaModel?: string
  embeddingDimension?: number
}

export function initVectorDeps(db: Database, opts: VectorDepsOptions = {}): VectorDeps | null {
  try {
    const dimension = opts.embeddingDimension ?? 768
    const vectorStore = new SqliteVecStore(db.getRawDb(), dimension)
    const embeddingClient = createEmbeddingClient({
      ollamaUrl: opts.ollamaUrl,
      ollamaModel: opts.ollamaModel,
      openaiApiKey: opts.openaiApiKey,
      dimension,
    })
    const embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
    return { vectorStore, embeddingClient, embeddingIndexer }
  } catch {
    return null
  }
}
