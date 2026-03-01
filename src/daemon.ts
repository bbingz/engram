// src/daemon.ts
// Stripped-down daemon: indexer + watcher only, no MCP server.
// Outputs JSON lines to stdout for the Swift app to parse.
// Usage: node dist/daemon.js [db-path]
import { homedir } from 'os'
import { join } from 'path'
import { mkdirSync } from 'fs'
import { Database } from './core/db.js'
import { Indexer } from './core/indexer.js'
import { startWatcher } from './core/watcher.js'
import { setupProcessLifecycle } from './core/lifecycle.js'
import { migrateDataDir } from './core/migrate.js'
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

migrateDataDir()
const DB_DIR = join(homedir(), '.engram')
mkdirSync(DB_DIR, { recursive: true })
mkdirSync(join(DB_DIR, 'cache', 'antigravity'), { recursive: true })
mkdirSync(join(DB_DIR, 'cache', 'windsurf'), { recursive: true })

const dbPath = process.argv[2] || join(DB_DIR, 'index.sqlite')
const db = new Database(dbPath)

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

const indexer = new Indexer(db, adapters)

function emit(obj: object): void {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

// Initial full scan
indexer.indexAll().then(indexed => {
  const total = db.countSessions()
  emit({ event: 'ready', indexed, total })
}).catch(err => {
  emit({ event: 'error', message: String(err) })
})

// File watcher (persistent — keeps process alive)
const watcher = startWatcher(adapters, indexer)

// Lifecycle: stdin/parent/signal layers, no idle timeout for daemon
setupProcessLifecycle({
  idleTimeoutMs: 0,
  onExit: () => { watcher?.close() },
})
