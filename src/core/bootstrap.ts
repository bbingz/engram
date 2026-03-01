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
import type { SessionAdapter } from '../adapters/types.js'

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
