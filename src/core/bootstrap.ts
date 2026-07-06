// src/core/bootstrap.ts
// Shared initialization for retained TypeScript MCP-compatible tooling.

import { mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { AntigravityAdapter } from '../adapters/antigravity.js';
import { ClaudeCodeAdapter } from '../adapters/claude-code.js';
import { ClineAdapter } from '../adapters/cline.js';
import { CodexAdapter } from '../adapters/codex.js';
import { CommandCodeAdapter } from '../adapters/commandcode.js';
import { CopilotAdapter } from '../adapters/copilot.js';
import { CursorAdapter } from '../adapters/cursor.js';
import { GeminiCliAdapter } from '../adapters/gemini-cli.js';
import { IflowAdapter } from '../adapters/iflow.js';
import { KimiAdapter } from '../adapters/kimi.js';
import { OpenCodeAdapter } from '../adapters/opencode.js';
import { QoderAdapter } from '../adapters/qoder.js';
import { QwenAdapter } from '../adapters/qwen.js';
import type { SessionAdapter, SourceName } from '../adapters/types.js';
import { VsCodeAdapter } from '../adapters/vscode.js';
import { WindsurfAdapter } from '../adapters/windsurf.js';
import { AiAuditWriter } from './ai-audit.js';
import type { FileSettings } from './config.js';
import { DEFAULT_AI_AUDIT_CONFIG, readFileSettings } from './config.js';
import { Database } from './db.js';
import { EmbeddingIndexer } from './embedding-indexer.js';
import type { EmbeddingClient } from './embeddings.js';
import { createEmbeddingClient } from './embeddings.js';
import { IndexJobRunner } from './index-job-runner.js';
import { Indexer } from './indexer.js';
import { migrateDataDir } from './migrate.js';
import { Tracer, TraceWriter } from './tracer.js';
import type { VectorStore } from './vector-store.js';
import { SqliteVecStore } from './vector-store.js';

const ENGRAM_DIR = join(homedir(), '.engram');

function ensureDataDirs(): string {
  migrateDataDir();
  mkdirSync(join(ENGRAM_DIR, 'cache', 'antigravity'), { recursive: true });
  mkdirSync(join(ENGRAM_DIR, 'cache', 'windsurf'), { recursive: true });
  return ENGRAM_DIR;
}

function createAdapters(): SessionAdapter[] {
  return [
    new CodexAdapter(),
    new ClaudeCodeAdapter(),
    new GeminiCliAdapter(),
    new OpenCodeAdapter(),
    new IflowAdapter(),
    new QwenAdapter(),
    new QoderAdapter(),
    new KimiAdapter(),
    new CommandCodeAdapter(),
    new CopilotAdapter(),
    new ClineAdapter(),
    new CursorAdapter(),
    new VsCodeAdapter(),
    new AntigravityAdapter(),
    new WindsurfAdapter(),
  ];
}

const adapters = createAdapters();
const adapterMap = new Map(adapters.map((a) => [a.name, a]));

export function getAdapter(name: string): SessionAdapter | undefined {
  return adapterMap.get(name as SourceName);
}

interface VectorDeps {
  vectorStore: SqliteVecStore;
  embeddingClient: EmbeddingClient;
  embeddingIndexer: EmbeddingIndexer;
}

interface VectorDepsOptions {
  openaiApiKey?: string;
  ollamaUrl?: string;
  ollamaModel?: string;
  embeddingDimension?: number;
  embeddingProvider?: 'ollama' | 'openai' | 'transformers';
  audit?: AiAuditWriter;
}

function initVectorDeps(
  db: Database,
  opts: VectorDepsOptions = {},
): VectorDeps | null {
  try {
    const dimension = opts.embeddingDimension ?? 768;
    const vectorStore = new SqliteVecStore(db.raw, dimension);
    const embeddingClient = createEmbeddingClient({
      provider: opts.embeddingProvider,
      ollamaUrl: opts.ollamaUrl,
      ollamaModel: opts.ollamaModel,
      openaiApiKey: opts.openaiApiKey,
      dimension,
      audit: opts.audit,
    });
    const embeddingIndexer = new EmbeddingIndexer(
      db,
      vectorStore,
      embeddingClient,
    );
    return { vectorStore, embeddingClient, embeddingIndexer };
  } catch {
    return null;
  }
}

// --- MCP Dependencies Factory ---

interface MCPDeps {
  db: Database;
  adapters: SessionAdapter[];
  adapterMap: Record<string, SessionAdapter>;
  settings: FileSettings;
  audit: AiAuditWriter;
  tracer: Tracer;
  traceWriter: TraceWriter;
  indexer: Indexer;
  indexJobRunner: IndexJobRunner;
  vecDeps: VectorDeps | null;
  vectorStore?: VectorStore;
  embed?: (text: string) => Promise<Float32Array | null>;
  embeddingClient?: EmbeddingClient;
}

export function createMCPDeps(opts?: { dbPath?: string }): MCPDeps {
  const dbDir = ensureDataDirs();
  const dbPath = opts?.dbPath ?? join(dbDir, 'index.sqlite');

  const db = new Database(dbPath);
  const traceWriter = new TraceWriter(db.raw);
  const tracer = new Tracer(traceWriter);
  const mcpAdapters = createAdapters();
  const adapterMap = Object.fromEntries(mcpAdapters.map((a) => [a.name, a]));

  const settings = readFileSettings();
  const auditConfig = { ...DEFAULT_AI_AUDIT_CONFIG, ...settings.aiAudit };
  const audit = new AiAuditWriter(db.raw, auditConfig);
  const authoritativeNode = 'local';

  // Apply tier-based noise filter
  db.noiseFilter = settings.noiseFilter ?? 'hide-skip';

  const indexer = new Indexer(db, mcpAdapters, { authoritativeNode });

  // Vector store — may fail if sqlite-vec can't load
  const vecDeps = initVectorDeps(db, {
    openaiApiKey: settings.openaiApiKey,
    ollamaUrl: settings.ollamaUrl,
    ollamaModel: settings.ollamaModel,
    embeddingDimension: settings.embeddingDimension,
    audit,
  });

  const indexJobRunner = new IndexJobRunner(
    db,
    vecDeps?.vectorStore,
    vecDeps?.embeddingClient,
  );

  return {
    db,
    adapters: mcpAdapters,
    adapterMap,
    settings,
    audit,
    tracer,
    traceWriter,
    indexer,
    indexJobRunner,
    vecDeps,
    vectorStore: vecDeps?.vectorStore,
    embed: vecDeps
      ? (text: string) => vecDeps.embeddingClient.embed(text)
      : undefined,
    embeddingClient: vecDeps?.embeddingClient,
  };
}
