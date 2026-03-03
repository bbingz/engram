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
import { WindsurfAdapter } from '../adapters/windsurf.js'
import type { SessionAdapter, SourceName } from '../adapters/types.js'
import { SqliteVecStore } from './vector-store.js'
import { createEmbeddingClient } from './embeddings.js'
import { EmbeddingIndexer } from './embedding-indexer.js'
import type { EmbeddingClient } from './embeddings.js'
import type { Database } from './db.js'

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

export interface VectorDeps {
  vectorStore: SqliteVecStore
  embeddingClient: EmbeddingClient
  embeddingIndexer: EmbeddingIndexer
}

export function initVectorDeps(db: Database, openaiApiKey?: string): VectorDeps | null {
  try {
    const vectorStore = new SqliteVecStore(db.getRawDb())
    const embeddingClient = createEmbeddingClient({
      ollamaUrl: 'http://localhost:11434',
      openaiApiKey,
    })
    const embeddingIndexer = new EmbeddingIndexer(db, vectorStore, embeddingClient)
    return { vectorStore, embeddingClient, embeddingIndexer }
  } catch {
    return null
  }
}
