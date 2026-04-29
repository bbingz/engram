# AI Summary Redesign Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify AI summary generation into the Node.js daemon with configurable multi-protocol support, prompt templates, preset tiers, and auto-summary.

**Architecture:** Delete Swift `AIClient.swift`. All AI calls go through `src/core/ai-client.ts` which supports OpenAI/Anthropic/Gemini protocols via raw `fetch()`. Daemon exposes `POST /api/summary` for Swift UI. Auto-summary uses debounce timers in the watcher pipeline.

**Tech Stack:** TypeScript (Node.js native `fetch`), Hono HTTP routes, SQLite (better-sqlite3), Swift/SwiftUI for settings UI.

**Spec:** `docs/superpowers/specs/2026-03-10-ai-summary-redesign.md`

---

## Chunk 1: Config, AI Client, and Preset Resolution

### Task 1: Expand FileSettings and add migration

**Files:**
- Modify: `src/core/config.ts`
- Test: `tests/core/config.test.ts` (new)

- [ ] **Step 1: Write the failing tests**

```typescript
// tests/core/config.test.ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'

// We'll test the migration and preset resolution logic
// Need to mock CONFIG_FILE — extract helpers as testable functions

describe('config', () => {
  describe('migrateSettings', () => {
    it('migrates openai provider fields to new schema', () => {
      const old = {
        aiProvider: 'openai',
        openaiApiKey: 'sk-test-123',
        openaiModel: 'gpt-4o',
        anthropicApiKey: 'ant-key',
        anthropicModel: 'claude-3-haiku',
      }
      const { migrateSettings } = await import('../../src/core/config.js')
      const migrated = migrateSettings(old)
      expect(migrated.aiProtocol).toBe('openai')
      expect(migrated.aiApiKey).toBe('sk-test-123')
      expect(migrated.aiModel).toBe('gpt-4o')
      // aiProvider selector removed, but per-provider keys kept for embeddings
      expect(migrated.aiProvider).toBeUndefined()
      expect(migrated.openaiApiKey).toBe('sk-test-123')
    })

    it('migrates anthropic provider fields', async () => {
      const old = { aiProvider: 'anthropic', anthropicApiKey: 'ant-key', anthropicModel: 'claude-3-haiku' }
      const { migrateSettings } = await import('../../src/core/config.js')
      const migrated = migrateSettings(old)
      expect(migrated.aiProtocol).toBe('anthropic')
      expect(migrated.aiApiKey).toBe('ant-key')
      expect(migrated.aiModel).toBe('claude-3-haiku')
    })

    it('skips migration when new fields already exist', async () => {
      const current = { aiProtocol: 'gemini', aiApiKey: 'gem-key', aiModel: 'gemini-pro' }
      const { migrateSettings } = await import('../../src/core/config.js')
      const migrated = migrateSettings(current)
      expect(migrated.aiProtocol).toBe('gemini')
      expect(migrated.aiApiKey).toBe('gem-key')
    })

    it('returns empty object for empty input', async () => {
      const { migrateSettings } = await import('../../src/core/config.js')
      expect(migrateSettings({})).toEqual({})
    })
  })

  describe('getBaseURL', () => {
    it('returns OpenAI default', async () => {
      const { getBaseURL } = await import('../../src/core/config.js')
      expect(getBaseURL({ aiProtocol: 'openai' })).toBe('https://api.openai.com')
    })

    it('returns Anthropic default', async () => {
      const { getBaseURL } = await import('../../src/core/config.js')
      expect(getBaseURL({ aiProtocol: 'anthropic' })).toBe('https://api.anthropic.com')
    })

    it('returns Gemini default', async () => {
      const { getBaseURL } = await import('../../src/core/config.js')
      expect(getBaseURL({ aiProtocol: 'gemini' })).toBe('https://generativelanguage.googleapis.com')
    })

    it('returns custom URL when set', async () => {
      const { getBaseURL } = await import('../../src/core/config.js')
      expect(getBaseURL({ aiProtocol: 'openai', aiBaseURL: 'http://localhost:11434' })).toBe('http://localhost:11434')
    })
  })

  describe('resolveSummaryConfig', () => {
    it('returns standard preset defaults with no overrides', async () => {
      const { resolveSummaryConfig } = await import('../../src/core/config.js')
      const config = resolveSummaryConfig({})
      expect(config.maxTokens).toBe(200)
      expect(config.temperature).toBe(0.3)
      expect(config.sampleFirst).toBe(20)
      expect(config.sampleLast).toBe(30)
      expect(config.truncateChars).toBe(500)
    })

    it('uses concise preset values', () => {
      const { resolveSummaryConfig } = await import('../../src/core/config.js')
      const config = resolveSummaryConfig({ summaryPreset: 'concise' })
      expect(config.maxTokens).toBe(100)
      expect(config.temperature).toBe(0.2)
      expect(config.sampleFirst).toBe(10)
      expect(config.sampleLast).toBe(15)
      expect(config.truncateChars).toBe(300)
    })

    it('uses detailed preset values', () => {
      const { resolveSummaryConfig } = await import('../../src/core/config.js')
      const config = resolveSummaryConfig({ summaryPreset: 'detailed' })
      expect(config.maxTokens).toBe(400)
      expect(config.sampleFirst).toBe(30)
      expect(config.sampleLast).toBe(50)
      expect(config.truncateChars).toBe(800)
    })

    it('custom maxTokens overrides preset', () => {
      const { resolveSummaryConfig } = await import('../../src/core/config.js')
      const config = resolveSummaryConfig({ summaryPreset: 'concise', summaryMaxTokens: 300 })
      expect(config.maxTokens).toBe(300)
      expect(config.temperature).toBe(0.2) // still from preset
    })

    it('advanced sampling overrides preset', () => {
      const { resolveSummaryConfig } = await import('../../src/core/config.js')
      const config = resolveSummaryConfig({ summarySampleFirst: 5, summarySampleLast: 10 })
      expect(config.sampleFirst).toBe(5)
      expect(config.sampleLast).toBe(10)
      expect(config.maxTokens).toBe(200) // still from default standard preset
    })
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/config.test.ts`
Expected: FAIL — `migrateSettings` and `resolveSummaryConfig` not exported

- [ ] **Step 3: Implement expanded config.ts**

```typescript
// src/core/config.ts
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import type { SyncPeer } from './sync.js';

export interface FileSettings {
  // --- AI Provider (new unified fields) ---
  aiProtocol?: 'openai' | 'anthropic' | 'gemini';
  aiBaseURL?: string;
  aiApiKey?: string;
  aiModel?: string;

  // --- Summary prompt template ---
  summaryPrompt?: string;
  summaryLanguage?: string;
  summaryMaxSentences?: number;
  summaryStyle?: string;

  // --- Summary generation config ---
  summaryPreset?: 'concise' | 'standard' | 'detailed';
  summaryMaxTokens?: number;
  summaryTemperature?: number;
  summarySampleFirst?: number;
  summarySampleLast?: number;
  summaryTruncateChars?: number;

  // --- Auto-summary ---
  autoSummary?: boolean;
  autoSummaryCooldown?: number;
  autoSummaryMinMessages?: number;
  autoSummaryRefresh?: boolean;
  autoSummaryRefreshThreshold?: number;

  // --- Legacy AI fields (kept for embeddings) ---
  openaiApiKey?: string;
  openaiModel?: string;
  anthropicApiKey?: string;
  anthropicModel?: string;

  // --- Other existing fields ---
  ollamaUrl?: string;
  ollamaModel?: string;
  embeddingDimension?: number;
  nodejsPath?: string;
  httpPort?: number;
  httpHost?: string;
  httpAllowCIDR?: string[];
  syncNodeName?: string;
  syncPeers?: SyncPeer[];
  syncIntervalMinutes?: number;
  syncEnabled?: boolean;
}

const CONFIG_DIR = join(homedir(), '.engram');
const CONFIG_FILE = join(CONFIG_DIR, 'settings.json');

export function readFileSettings(): FileSettings {
  try {
    const content = readFileSync(CONFIG_FILE, 'utf-8');
    const raw = JSON.parse(content) as FileSettings;
    return migrateSettings(raw);
  } catch {
    return {};
  }
}

export function writeFileSettings(settings: FileSettings): void {
  mkdirSync(CONFIG_DIR, { recursive: true });
  const current = readFileSettings();
  const merged = { ...current, ...settings };
  writeFileSync(CONFIG_FILE, JSON.stringify(merged, null, 2), 'utf-8');
}

/** Migrate old per-provider fields to unified fields. Returns new object (does not mutate). */
export function migrateSettings(settings: Record<string, unknown>): FileSettings {
  const s = { ...settings } as FileSettings & { aiProvider?: string };

  // Already migrated or fresh install
  if (s.aiProtocol || !s.aiProvider) return s as FileSettings;

  // Migrate
  const provider = s.aiProvider as string;
  s.aiProtocol = provider === 'anthropic' ? 'anthropic' : 'openai';
  if (provider === 'openai' || !provider) {
    s.aiApiKey = s.openaiApiKey ?? '';
    s.aiModel = s.openaiModel ?? 'gpt-4o-mini';
  } else {
    s.aiApiKey = s.anthropicApiKey ?? '';
    s.aiModel = s.anthropicModel ?? 'claude-3-haiku-20240307';
  }

  // Remove only the selector field; keep per-provider keys for embeddings
  delete s.aiProvider;

  return s;
}

export interface ResolvedSummaryConfig {
  maxTokens: number;
  temperature: number;
  sampleFirst: number;
  sampleLast: number;
  truncateChars: number;
}

const PRESETS: Record<string, ResolvedSummaryConfig> = {
  concise:  { maxTokens: 100, temperature: 0.2, sampleFirst: 10, sampleLast: 15, truncateChars: 300 },
  standard: { maxTokens: 200, temperature: 0.3, sampleFirst: 20, sampleLast: 30, truncateChars: 500 },
  detailed: { maxTokens: 400, temperature: 0.4, sampleFirst: 30, sampleLast: 50, truncateChars: 800 },
};

/** Resolve three-tier config: preset → custom → advanced overrides. */
export function resolveSummaryConfig(settings: FileSettings): ResolvedSummaryConfig {
  const preset = PRESETS[settings.summaryPreset ?? 'standard'] ?? PRESETS.standard;
  return {
    maxTokens: settings.summaryMaxTokens ?? preset.maxTokens,
    temperature: settings.summaryTemperature ?? preset.temperature,
    sampleFirst: settings.summarySampleFirst ?? preset.sampleFirst,
    sampleLast: settings.summarySampleLast ?? preset.sampleLast,
    truncateChars: settings.summaryTruncateChars ?? preset.truncateChars,
  };
}

const DEFAULT_BASE_URLS: Record<string, string> = {
  openai: 'https://api.openai.com',
  anthropic: 'https://api.anthropic.com',
  gemini: 'https://generativelanguage.googleapis.com',
};

export function getBaseURL(settings: FileSettings): string {
  return settings.aiBaseURL || DEFAULT_BASE_URLS[settings.aiProtocol ?? 'openai'] || DEFAULT_BASE_URLS.openai;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/config.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/config.ts tests/core/config.test.ts
git commit -m "feat: expand FileSettings with AI summary config, presets, and migration"
```

---

### Task 2: Rewrite AI client with three-protocol support

**Files:**
- Rewrite: `src/core/ai-client.ts`
- Test: `tests/core/ai-client.test.ts` (new)

- [ ] **Step 1: Write the failing tests**

```typescript
// tests/core/ai-client.test.ts
import { describe, it, expect } from 'vitest'

describe('ai-client', () => {
  describe('renderPromptTemplate', () => {
    it('renders default template with variables', () => {
      const { renderPromptTemplate } = await import('../../src/core/ai-client.js')
      const result = renderPromptTemplate({})
      expect(result).toContain('3 句话')
      expect(result).toContain('中文')
      expect(result).not.toContain('{{')
    })

    it('substitutes custom language and sentence count', () => {
      const { renderPromptTemplate } = await import('../../src/core/ai-client.js')
      const result = renderPromptTemplate({ summaryLanguage: 'English', summaryMaxSentences: 5 })
      expect(result).toContain('5')
      expect(result).toContain('English')
    })

    it('includes style line when provided', () => {
      const { renderPromptTemplate } = await import('../../src/core/ai-client.js')
      const result = renderPromptTemplate({ summaryStyle: '技术向' })
      expect(result).toContain('技术向')
    })

    it('removes style line when empty', () => {
      const { renderPromptTemplate } = await import('../../src/core/ai-client.js')
      const result = renderPromptTemplate({ summaryStyle: '' })
      // No empty line where style would be
      expect(result).not.toContain('\n\n\n')
    })

    it('uses custom prompt template', () => {
      const { renderPromptTemplate } = await import('../../src/core/ai-client.js')
      const result = renderPromptTemplate({
        summaryPrompt: 'Summarize in {{language}}, max {{maxSentences}} sentences.',
        summaryLanguage: 'Japanese',
        summaryMaxSentences: 2,
      })
      expect(result).toBe('Summarize in Japanese, max 2 sentences.')
    })
  })

  describe('sampleMessages', () => {
    it('returns all messages when under limit', () => {
      const { sampleMessages } = await import('../../src/core/ai-client.js')
      const msgs = Array.from({ length: 10 }, (_, i) => ({ role: 'user', content: `msg ${i}` }))
      const result = sampleMessages(msgs, 20, 30, 500)
      expect(result).toHaveLength(10)
    })

    it('samples first N + last M when over limit', () => {
      const { sampleMessages } = await import('../../src/core/ai-client.js')
      const msgs = Array.from({ length: 100 }, (_, i) => ({ role: 'user', content: `msg ${i}` }))
      const result = sampleMessages(msgs, 10, 15, 500)
      expect(result).toHaveLength(25)
      expect(result[0].content).toBe('msg 0')
      expect(result[9].content).toBe('msg 9')
      expect(result[10].content).toBe('msg 85')
      expect(result[24].content).toBe('msg 99')
    })

    it('truncates message content', () => {
      const { sampleMessages } = await import('../../src/core/ai-client.js')
      const msgs = [{ role: 'user', content: 'a'.repeat(1000) }]
      const result = sampleMessages(msgs, 20, 30, 100)
      expect(result[0].content.length).toBeLessThanOrEqual(103) // 100 + '...'
    })
  })

  describe('buildRequestBody', () => {
    const conversationText = '[user] Hello\n\n[assistant] Hi there'

    it('builds OpenAI request body', () => {
      const { buildRequestBody } = await import('../../src/core/ai-client.js')
      const body = buildRequestBody('openai', 'Summarize this.', conversationText, {
        model: 'gpt-4o-mini', maxTokens: 200, temperature: 0.3,
      })
      expect(body.model).toBe('gpt-4o-mini')
      expect(body.messages).toHaveLength(2)
      expect(body.messages[0].role).toBe('system')
      expect(body.max_tokens).toBe(200)
    })

    it('builds Anthropic request body', () => {
      const { buildRequestBody } = await import('../../src/core/ai-client.js')
      const body = buildRequestBody('anthropic', 'Summarize this.', conversationText, {
        model: 'claude-3-haiku', maxTokens: 200, temperature: 0.3,
      })
      expect(body.model).toBe('claude-3-haiku')
      expect(body.system).toBe('Summarize this.')
      expect(body.messages).toHaveLength(1)
      expect(body.max_tokens).toBe(200)
    })

    it('builds Gemini request body', () => {
      const { buildRequestBody } = await import('../../src/core/ai-client.js')
      const body = buildRequestBody('gemini', 'Summarize this.', conversationText, {
        model: 'gemini-pro', maxTokens: 200, temperature: 0.3,
      })
      expect(body.contents).toBeDefined()
      expect(body.systemInstruction).toBeDefined()
      expect(body.generationConfig.maxOutputTokens).toBe(200)
    })
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/ai-client.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement three-protocol AI client**

```typescript
// src/core/ai-client.ts
import type { FileSettings, ResolvedSummaryConfig } from './config.js'
import { resolveSummaryConfig, getBaseURL } from './config.js'

export interface ConversationMessage {
  role: string
  content: string
}

const DEFAULT_TEMPLATE = `请用不超过 {{maxSentences}} 句话，以 {{language}} 总结以下 AI 编程对话的核心内容。
总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果
{{style}}
保持简洁。`

/** Render prompt template with variable substitution. Exported for testing. */
export function renderPromptTemplate(settings: FileSettings): string {
  const template = settings.summaryPrompt || DEFAULT_TEMPLATE
  const language = settings.summaryLanguage ?? '中文'
  const maxSentences = settings.summaryMaxSentences ?? 3
  const style = settings.summaryStyle ?? ''

  let rendered = template
    .replace(/\{\{language\}\}/g, language)
    .replace(/\{\{maxSentences\}\}/g, String(maxSentences))
    .replace(/\{\{style\}\}/g, style ? `风格要求：${style}` : '')

  // Remove lines that are blank after substitution
  rendered = rendered.split('\n').filter(line => line.trim() !== '').join('\n')
  return rendered
}

/** Sample first+last messages and truncate. Exported for testing. */
export function sampleMessages(
  messages: ConversationMessage[],
  sampleFirst: number,
  sampleLast: number,
  truncateChars: number,
): ConversationMessage[] {
  const total = sampleFirst + sampleLast
  const sampled = messages.length <= total
    ? messages
    : [...messages.slice(0, sampleFirst), ...messages.slice(-sampleLast)]

  return sampled.map(m => ({
    role: m.role,
    content: m.content.length > truncateChars
      ? m.content.slice(0, truncateChars) + '...'
      : m.content,
  }))
}

/** Build protocol-specific request body. Exported for testing. */
export function buildRequestBody(
  protocol: string,
  systemPrompt: string,
  conversationText: string,
  opts: { model: string; maxTokens: number; temperature: number },
) {
  const userContent = `请总结以下对话：\n\n${conversationText}`

  if (protocol === 'anthropic') {
    return {
      model: opts.model,
      max_tokens: opts.maxTokens,
      temperature: opts.temperature,
      system: systemPrompt,
      messages: [{ role: 'user', content: userContent }],
    }
  }

  if (protocol === 'gemini') {
    return {
      systemInstruction: { parts: [{ text: systemPrompt }] },
      contents: [{ role: 'user', parts: [{ text: userContent }] }],
      generationConfig: {
        maxOutputTokens: opts.maxTokens,
        temperature: opts.temperature,
      },
    }
  }

  // OpenAI-compatible (default)
  return {
    model: opts.model,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userContent },
    ],
    max_tokens: opts.maxTokens,
    temperature: opts.temperature,
  }
}

function buildURL(protocol: string, baseURL: string, model: string): string {
  if (protocol === 'anthropic') return `${baseURL}/v1/messages`
  if (protocol === 'gemini') return `${baseURL}/v1beta/models/${model}:generateContent`
  return `${baseURL}/v1/chat/completions`
}

function buildHeaders(protocol: string, apiKey: string): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (protocol === 'anthropic') {
    headers['x-api-key'] = apiKey
    headers['anthropic-version'] = '2023-06-01'
  } else if (protocol === 'gemini') {
    // Gemini uses query param for auth, added in buildURL caller
  } else {
    headers['Authorization'] = `Bearer ${apiKey}`
  }
  return headers
}

function extractResponseText(protocol: string, json: unknown): string {
  const data = json as Record<string, unknown>
  if (protocol === 'anthropic') {
    const content = (data.content as Array<{ type: string; text: string }>)?.[0]
    return content?.type === 'text' ? content.text.trim() : ''
  }
  if (protocol === 'gemini') {
    const candidates = data.candidates as Array<{ content: { parts: Array<{ text: string }> } }>
    return candidates?.[0]?.content?.parts?.[0]?.text?.trim() ?? ''
  }
  // OpenAI
  const choices = data.choices as Array<{ message: { content: string } }>
  return choices?.[0]?.message?.content?.trim() ?? ''
}

/** Main entry point: generate a summary from messages using settings. */
export async function summarizeConversation(
  messages: ConversationMessage[],
  settings: FileSettings,
): Promise<string> {
  const protocol = settings.aiProtocol ?? 'openai'
  const apiKey = settings.aiApiKey ?? ''
  const model = settings.aiModel ?? 'gpt-4o-mini'
  const baseURL = getBaseURL(settings)

  if (!apiKey) throw new Error('No API key configured')

  const config = resolveSummaryConfig(settings)
  const sampled = sampleMessages(messages, config.sampleFirst, config.sampleLast, config.truncateChars)
  const conversationText = sampled
    .map(m => `[${m.role}] ${m.content}`)
    .join('\n\n')

  const systemPrompt = renderPromptTemplate(settings)
  const body = buildRequestBody(protocol, systemPrompt, conversationText, {
    model, maxTokens: config.maxTokens, temperature: config.temperature,
  })

  let url = buildURL(protocol, baseURL, model)
  if (protocol === 'gemini') url += `?key=${apiKey}`

  const headers = buildHeaders(protocol, apiKey)
  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  })

  if (!response.ok) {
    const text = await response.text()
    throw new Error(`AI API error (${response.status}): ${text.slice(0, 200)}`)
  }

  const json = await response.json()
  return extractResponseText(protocol, json)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/ai-client.test.ts`
Expected: PASS

- [ ] **Step 5: Rewrite generate_summary.ts** (must be in same commit to avoid build breakage — old code imports removed `SummarizeOptions`)

```typescript
// src/tools/generate_summary.ts
import type { Database } from '../core/db.js'
import { getAdapter } from '../core/bootstrap.js'
import { summarizeConversation } from '../core/ai-client.js'
import { readFileSettings } from '../core/config.js'

export const generateSummaryTool = {
  name: 'generate_summary',
  description: 'Generate an AI summary for a conversation session',
  inputSchema: {
    type: 'object' as const,
    properties: {
      sessionId: {
        type: 'string',
        description: 'The session ID to summarize',
      },
    },
    required: ['sessionId'],
    additionalProperties: false,
  },
}

export async function handleGenerateSummary(
  db: Database,
  params: { sessionId: string },
) {
  const { sessionId } = params

  const session = db.getSession(sessionId)
  if (!session) {
    return {
      content: [{ type: 'text' as const, text: `Session not found: ${sessionId}` }],
      isError: true,
    }
  }

  const settings = readFileSettings()
  if (!settings.aiApiKey) {
    return {
      content: [{ type: 'text' as const, text: 'API key not configured. Please set it in Settings.' }],
      isError: true,
    }
  }

  const adapter = getAdapter(session.source)
  if (!adapter) {
    return {
      content: [{ type: 'text' as const, text: `No adapter available for source: ${session.source}` }],
      isError: true,
    }
  }

  const messages: Array<{ role: string; content: string }> = []
  try {
    for await (const msg of adapter.streamMessages(session.filePath)) {
      messages.push({ role: msg.role, content: msg.content })
    }
  } catch (error) {
    return {
      content: [{ type: 'text' as const, text: `Failed to read session messages: ${error}` }],
      isError: true,
    }
  }

  if (messages.length === 0) {
    return {
      content: [{ type: 'text' as const, text: 'No messages found in session' }],
      isError: true,
    }
  }

  try {
    const summary = await summarizeConversation(messages, settings)
    if (!summary) {
      return {
        content: [{ type: 'text' as const, text: 'Failed to generate summary: empty response from AI' }],
        isError: true,
      }
    }

    db.updateSessionSummary(sessionId, summary)

    return {
      content: [{ type: 'text' as const, text: summary }],
      metadata: { sessionId, messageCount: messages.length },
    }
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error)
    return {
      content: [{ type: 'text' as const, text: `Failed to generate summary: ${msg}` }],
      isError: true,
    }
  }
}
```

- [ ] **Step 6: Build and verify no type errors**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 7: Run all tests**

Run: `npx vitest run tests/core/ai-client.test.ts tests/core/config.test.ts`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/core/ai-client.ts src/tools/generate_summary.ts tests/core/ai-client.test.ts
git commit -m "feat: rewrite ai-client with three-protocol support, prompt templates, and updated generate_summary tool"
```

---

## Chunk 2: HTTP API Route and Auto-Summary

### Task 4: Add POST /api/summary route

**Files:**
- Modify: `src/web.ts`
- Modify: `src/daemon.ts`
- Test: `tests/web/server.test.ts` (add test)

- [ ] **Step 1: Add test for the new route**

Add to `tests/web/server.test.ts`:

```typescript
describe('POST /api/summary', () => {
  it('returns 400 when sessionId is missing', async () => {
    const res = await app.request('/api/summary', { method: 'POST', body: JSON.stringify({}) , headers: { 'Content-Type': 'application/json' }})
    expect(res.status).toBe(400)
    const json = await res.json()
    expect(json.error).toContain('sessionId')
  })

  it('returns 404 when session not found', async () => {
    const res = await app.request('/api/summary', {
      method: 'POST',
      body: JSON.stringify({ sessionId: 'nonexistent-id' }),
      headers: { 'Content-Type': 'application/json' },
    })
    expect(res.status).toBe(404)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/web/server.test.ts`
Expected: FAIL — route not found (404 for POST)

- [ ] **Step 3: Add route to web.ts**

Add to `createApp` function, after existing API routes. Update the `opts` type to include `adapters`:

In `src/web.ts`, update the `createApp` signature:

```typescript
export function createApp(db: Database, opts?: {
  vectorStore?: VectorStore
  embeddingClient?: EmbeddingClient
  syncEngine?: SyncEngine
  syncPeers?: SyncPeer[]
  settings?: FileSettings
  adapters?: SessionAdapter[]  // NEW
}) {
```

Add the import at top:

```typescript
import type { SessionAdapter } from './adapters/types.js'
import { summarizeConversation } from './core/ai-client.js'
```

Add the route (before HTML routes):

```typescript
  // --- Summary API ---
  app.post('/api/summary', async (c) => {
    const body = await c.req.json().catch(() => ({}))
    const sessionId = (body as Record<string, unknown>).sessionId as string | undefined
    if (!sessionId) {
      return c.json({ error: 'Missing required field: sessionId' }, 400)
    }

    const session = db.getSession(sessionId)
    if (!session) {
      return c.json({ error: `Session not found: ${sessionId}` }, 404)
    }

    const currentSettings = readFileSettings()
    if (!currentSettings.aiApiKey) {
      return c.json({ error: 'API key not configured. Please set it in Settings.' }, 500)
    }

    // Find adapter for this session's source
    const adapter = opts?.adapters?.find(a => a.name === session.source)
    if (!adapter) {
      return c.json({ error: `No adapter for source: ${session.source}` }, 500)
    }

    // Read messages
    const messages: Array<{ role: string; content: string }> = []
    try {
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content })
      }
    } catch (err) {
      return c.json({ error: `Failed to read session: ${err}` }, 500)
    }

    if (messages.length === 0) {
      return c.json({ error: 'No messages in session' }, 400)
    }

    try {
      const summary = await summarizeConversation(messages, currentSettings)
      if (!summary) {
        return c.json({ error: 'Empty response from AI' }, 500)
      }
      db.updateSessionSummary(sessionId, summary)
      return c.json({ summary })
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      return c.json({ error: msg }, 500)
    }
  })
```

- [ ] **Step 4: Pass adapters from daemon.ts**

In `src/daemon.ts`, update the `createApp` call:

```typescript
const app = createApp(db, {
  vectorStore: vecDeps?.vectorStore,
  embeddingClient: vecDeps?.embeddingClient,
  syncEngine,
  syncPeers,
  settings,
  adapters,  // ADD THIS
})
```

- [ ] **Step 5: Run tests**

Run: `npx vitest run tests/web/server.test.ts`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/web.ts src/daemon.ts tests/web/server.test.ts
git commit -m "feat: add POST /api/summary HTTP route for Swift UI"
```

---

### Task 5: Add summaryMessageCount column to DB

**Files:**
- Modify: `src/core/db.ts`

- [ ] **Step 1: Add column and update method**

In `src/core/db.ts`, add to the schema migration section (after existing `ALTER TABLE` statements):

```typescript
try { this.db.exec('ALTER TABLE sessions ADD COLUMN summary_message_count INTEGER') } catch {}
```

Add method:

```typescript
updateSessionSummary(id: string, summary: string, messageCount?: number): void {
  if (messageCount !== undefined) {
    this.db.prepare('UPDATE sessions SET summary = ?, summary_message_count = ? WHERE id = ?').run(summary, messageCount, id)
  } else {
    this.db.prepare('UPDATE sessions SET summary = ? WHERE id = ?').run(summary, id)
  }
}
```

- [ ] **Step 2: Build and verify**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add src/core/db.ts
git commit -m "feat: add summary_message_count column for auto-summary refresh tracking"
```

---

### Task 6: Implement auto-summary manager

**Files:**
- Create: `src/core/auto-summary.ts`
- Test: `tests/core/auto-summary.test.ts` (new)

- [ ] **Step 1: Write the failing tests**

```typescript
// tests/core/auto-summary.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

describe('AutoSummaryManager', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('fires callback after cooldown when session has no summary', async () => {
    const { AutoSummaryManager } = await import('../../src/core/auto-summary.js')
    const onTrigger = vi.fn().mockResolvedValue(undefined)
    const hasSummary = vi.fn().mockReturnValue(false)
    const mgr = new AutoSummaryManager({
      cooldownMs: 1000,
      minMessages: 2,
      onTrigger,
      hasSummary,
    })

    mgr.onSessionIndexed('session-1', 5)
    expect(onTrigger).not.toHaveBeenCalled()

    vi.advanceTimersByTime(1000)
    // Allow microtask queue to flush
    await vi.advanceTimersByTimeAsync(0)

    expect(hasSummary).toHaveBeenCalledWith('session-1')
    expect(onTrigger).toHaveBeenCalledWith('session-1')
  })

  it('resets timer on repeated indexing', async () => {
    const { AutoSummaryManager } = await import('../../src/core/auto-summary.js')
    const onTrigger = vi.fn().mockResolvedValue(undefined)
    const hasSummary = vi.fn().mockReturnValue(false)
    const mgr = new AutoSummaryManager({
      cooldownMs: 1000,
      minMessages: 2,
      onTrigger,
      hasSummary,
    })

    mgr.onSessionIndexed('session-1', 5)
    vi.advanceTimersByTime(800)
    mgr.onSessionIndexed('session-1', 8) // reset
    vi.advanceTimersByTime(800)
    expect(onTrigger).not.toHaveBeenCalled() // only 800ms since reset

    vi.advanceTimersByTime(200)
    await vi.advanceTimersByTimeAsync(0)
    expect(onTrigger).toHaveBeenCalledTimes(1)
  })

  it('skips when session already has summary', async () => {
    const { AutoSummaryManager } = await import('../../src/core/auto-summary.js')
    const onTrigger = vi.fn().mockResolvedValue(undefined)
    const hasSummary = vi.fn().mockReturnValue(true)
    const mgr = new AutoSummaryManager({
      cooldownMs: 1000,
      minMessages: 2,
      onTrigger,
      hasSummary,
    })

    mgr.onSessionIndexed('session-1', 5)
    vi.advanceTimersByTime(1000)
    await vi.advanceTimersByTimeAsync(0)

    expect(hasSummary).toHaveBeenCalledWith('session-1')
    expect(onTrigger).not.toHaveBeenCalled()
  })

  it('skips when message count below threshold', async () => {
    const { AutoSummaryManager } = await import('../../src/core/auto-summary.js')
    const onTrigger = vi.fn().mockResolvedValue(undefined)
    const hasSummary = vi.fn().mockReturnValue(false)
    const mgr = new AutoSummaryManager({
      cooldownMs: 1000,
      minMessages: 10,
      onTrigger,
      hasSummary,
    })

    mgr.onSessionIndexed('session-1', 3)
    vi.advanceTimersByTime(1000)
    await vi.advanceTimersByTimeAsync(0)

    expect(onTrigger).not.toHaveBeenCalled()
  })

  it('cleanup clears all timers', () => {
    const { AutoSummaryManager } = await import('../../src/core/auto-summary.js')
    const onTrigger = vi.fn().mockResolvedValue(undefined)
    const hasSummary = vi.fn().mockReturnValue(false)
    const mgr = new AutoSummaryManager({
      cooldownMs: 1000,
      minMessages: 2,
      onTrigger,
      hasSummary,
    })

    mgr.onSessionIndexed('session-1', 5)
    mgr.cleanup()
    vi.advanceTimersByTime(2000)

    expect(onTrigger).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/core/auto-summary.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement AutoSummaryManager**

```typescript
// src/core/auto-summary.ts

export interface AutoSummaryOptions {
  cooldownMs: number
  minMessages: number
  onTrigger: (sessionId: string) => Promise<void>
  hasSummary: (sessionId: string) => boolean
}

export class AutoSummaryManager {
  private timers = new Map<string, ReturnType<typeof setTimeout>>()
  private messageCounts = new Map<string, number>()
  private opts: AutoSummaryOptions

  constructor(opts: AutoSummaryOptions) {
    this.opts = opts
  }

  onSessionIndexed(sessionId: string, messageCount: number): void {
    this.messageCounts.set(sessionId, messageCount)

    // Reset debounce timer
    const existing = this.timers.get(sessionId)
    if (existing) clearTimeout(existing)

    const timer = setTimeout(() => {
      this.timers.delete(sessionId)
      this.tryGenerate(sessionId).catch(() => {})
    }, this.opts.cooldownMs)

    this.timers.set(sessionId, timer)
  }

  private async tryGenerate(sessionId: string): Promise<void> {
    const count = this.messageCounts.get(sessionId) ?? 0
    if (count < this.opts.minMessages) return
    if (this.opts.hasSummary(sessionId)) return

    await this.opts.onTrigger(sessionId)
  }

  cleanup(): void {
    for (const timer of this.timers.values()) {
      clearTimeout(timer)
    }
    this.timers.clear()
    this.messageCounts.clear()
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/core/auto-summary.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/core/auto-summary.ts tests/core/auto-summary.test.ts
git commit -m "feat: add AutoSummaryManager with debounce timer"
```

---

### Task 7: Wire auto-summary into watcher and daemon

**Files:**
- Modify: `src/core/watcher.ts`
- Modify: `src/core/indexer.ts`
- Modify: `src/daemon.ts`

- [ ] **Step 1: Update watcher callback signature**

In `src/core/watcher.ts`:

```typescript
export interface WatcherOptions {
  onIndexed?: (sessionId: string, messageCount: number) => void
}
```

Update `handleChange`:

```typescript
const handleChange = async (filePath: string) => {
  for (const [watchPath, adapter] of Object.entries(watchMap)) {
    if (filePath.startsWith(watchPath)) {
      const result = await indexer.indexFile(adapter, filePath)
      if (result.indexed && result.sessionId) {
        opts?.onIndexed?.(result.sessionId, result.messageCount ?? 0)
      }
      break
    }
  }
}
```

- [ ] **Step 2: Update indexer.indexFile return type**

In `src/core/indexer.ts`, change `indexFile` return type:

```typescript
async indexFile(adapter: SessionAdapter, filePath: string): Promise<{ indexed: boolean; sessionId?: string; messageCount?: number }> {
  try {
    let fileSize = 0
    try { fileSize = (await stat(filePath)).size } catch { /* virtual path */ }

    const info = await adapter.parseSessionInfo(filePath)
    if (!info) return { indexed: false }

    if (info.cwd && !info.project) {
      info.project = await resolveProjectName(info.cwd)
    }

    this.db.upsertSession({ ...info, sizeBytes: info.sizeBytes || fileSize })

    const messages: { role: string; content: string }[] = []
    for await (const msg of adapter.streamMessages(filePath)) {
      if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
        messages.push({ role: msg.role, content: msg.content })
      }
    }
    if (messages.length > 0) {
      this.db.indexSessionContent(info.id, messages, info.summary)
    }

    return { indexed: true, sessionId: info.id, messageCount: info.messageCount ?? messages.length }
  } catch {
    return { indexed: false }
  }
}
```

- [ ] **Step 3: Wire auto-summary in daemon.ts**

In `src/daemon.ts`, add after the watcher setup:

```typescript
import { AutoSummaryManager } from './core/auto-summary.js'
import { summarizeConversation } from './core/ai-client.js'
```

Replace the watcher setup and add auto-summary:

```typescript
// Auto-summary manager (only active when configured)
let autoSummary: AutoSummaryManager | undefined
if (settings.autoSummary && settings.aiApiKey) {
  autoSummary = new AutoSummaryManager({
    cooldownMs: (settings.autoSummaryCooldown ?? 5) * 60 * 1000,
    minMessages: settings.autoSummaryMinMessages ?? 4,
    hasSummary: (id) => {
      const s = db.getSession(id)
      if (!s?.summary) return false
      if (!settings.autoSummaryRefresh) return true
      // Refresh mode: check if message count grew enough
      const threshold = settings.autoSummaryRefreshThreshold ?? 20
      const lastCount = (s as Record<string, unknown>).summaryMessageCount as number | undefined
      return lastCount !== undefined && s.messageCount - lastCount < threshold
    },
    onTrigger: async (sessionId) => {
      const session = db.getSession(sessionId)
      if (!session) return
      const adapter = adapters.find(a => a.name === session.source)
      if (!adapter) return

      const messages: Array<{ role: string; content: string }> = []
      for await (const msg of adapter.streamMessages(session.filePath)) {
        messages.push({ role: msg.role, content: msg.content })
      }
      if (messages.length === 0) return

      try {
        const currentSettings = readFileSettings()
        const summary = await summarizeConversation(messages, currentSettings)
        if (summary) {
          db.updateSessionSummary(sessionId, summary, messages.length)
          emit({ event: 'summary_generated', sessionId, summary, total: db.countSessions() })
        }
      } catch { /* silently skip */ }
    },
  })
}

// File watcher
const watcher = startWatcher(adapters, indexer, {
  onIndexed: (sessionId, messageCount) => {
    const total = db.countSessions()
    emit({ event: 'watcher_indexed', total })
    autoSummary?.onSessionIndexed(sessionId, messageCount)
  },
})
```

Add cleanup in `shutdown()`:

```typescript
function shutdown() {
  clearInterval(rescanTimer)
  if (syncTimer) clearInterval(syncTimer)
  autoSummary?.cleanup()
  watcher?.close()
  webServer.close()
  db.close()
  process.exit(0)
}
```

- [ ] **Step 4: Build and verify**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 5: Run all tests**

Run: `npx vitest run`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add src/core/watcher.ts src/core/indexer.ts src/daemon.ts
git commit -m "feat: wire auto-summary into watcher/daemon pipeline"
```

---

## Chunk 3: Swift UI Changes

### Task 8: Update IndexerProcess to handle summary_generated event

**Files:**
- Modify: `macos/Engram/Core/IndexerProcess.swift`

- [ ] **Step 1: Add fields to DaemonEvent**

```swift
struct DaemonEvent: Decodable {
    let event: String
    let indexed: Int?
    let total: Int?
    let message: String?
    let sessionId: String?   // NEW
    let summary: String?     // NEW
    let port: Int?           // NEW — for web_ready event
    let host: String?        // NEW — for web_ready event
}
```

- [ ] **Step 2: Add published properties and handle new events**

Add to `IndexerProcess`:

```swift
@Published var lastSummarySessionId: String?
@Published var port: Int?
```

Update `handleEvent`:

```swift
private func handleEvent(_ event: DaemonEvent) {
    switch event.event {
    case "ready", "indexed", "rescan", "sync_complete", "watcher_indexed":
        if let n = event.total {
            totalSessions = n
            status = .running(total: n)
        }
    case "web_ready":
        port = event.port
    case "summary_generated":
        if let n = event.total {
            totalSessions = n
            status = .running(total: n)
        }
        lastSummarySessionId = event.sessionId
    case "error":
        status = .error(event.message ?? "Unknown error")
    default:
        break
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Core/IndexerProcess.swift
git commit -m "feat: handle summary_generated daemon event in IndexerProcess"
```

---

### Task 9: Replace AIClient.swift with HTTP calls in SessionDetailView

**Files:**
- Delete: `macos/Engram/Core/AIClient.swift`
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Rewrite generateSummary() in SessionDetailView**

Replace the existing `generateSummary()` function:

```swift
func generateSummary() async {
    guard !messages.isEmpty else { return }
    isSummarizing = true
    summaryError = nil

    // Call daemon HTTP API
    let port = indexer.port ?? 3457
    guard let url = URL(string: "http://127.0.0.1:\(port)/api/summary") else {
        summaryError = "Invalid daemon URL"
        isSummarizing = false
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30

    let payload: [String: String] = ["sessionId": session.id]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        if let httpResponse, httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let summary = json["summary"] as? String, !summary.isEmpty {
                currentSummary = summary
                // DB is already updated by daemon, just refresh local state
            } else {
                summaryError = "Empty response from AI"
            }
        } else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorMsg = json?["error"] as? String ?? "Unknown error (HTTP \(httpResponse?.statusCode ?? 0))"
            summaryError = errorMsg
        }
    } catch {
        summaryError = "Network error: \(error.localizedDescription)"
    }

    isSummarizing = false
}
```

Also add `@EnvironmentObject var indexer: IndexerProcess` if not already present (check existing state variables).

- [ ] **Step 2: Delete AIClient.swift**

```bash
rm macos/Engram/Core/AIClient.swift
```

- [ ] **Step 3: Regenerate Xcode project**

Run: `cd macos && xcodegen generate`

- [ ] **Step 4: Build and verify**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add -A macos/
git commit -m "feat: replace AIClient.swift with daemon HTTP calls for summary generation"
```

---

### Task 10: Redesign AI Summary section in SettingsView

**Files:**
- Modify: `macos/Engram/Views/SettingsView.swift`

- [ ] **Step 1: Replace state variables and AI Summary section**

Remove old state variables:
```swift
// DELETE these:
@State private var aiProvider: String = "openai"
@State private var openaiApiKey: String = ""
@State private var openaiModel: String = "gpt-4o-mini"
@State private var anthropicApiKey: String = ""
@State private var anthropicModel: String = "claude-3-haiku-20240307"
```

Add new state variables:
```swift
// AI Summary settings
@State private var aiProtocol: String = "openai"
@State private var aiBaseURL: String = ""
@State private var aiApiKey: String = ""
@State private var aiModel: String = "gpt-4o-mini"

// Prompt template
@State private var summaryLanguage: String = "中文"
@State private var summaryMaxSentences: Int = 3
@State private var summaryStyle: String = ""
@State private var summaryPrompt: String = ""
@State private var showCustomPrompt: Bool = false

// Generation config
@State private var summaryPreset: String = "standard"
@State private var summaryMaxTokens: Int = 200
@State private var summaryTemperature: Double = 0.3
@State private var showCustomGeneration: Bool = false
@State private var summarySampleFirst: Int = 20
@State private var summarySampleLast: Int = 30
@State private var summaryTruncateChars: Int = 500
@State private var showAdvancedGeneration: Bool = false

// Auto-summary
@State private var autoSummary: Bool = false
@State private var autoSummaryCooldown: Int = 5
@State private var autoSummaryMinMessages: Int = 4
@State private var autoSummaryRefresh: Bool = false
@State private var autoSummaryRefreshThreshold: Int = 20
```

Replace the "AI Summary" section in body with:

```swift
Section("AI Summary") {
    // Provider
    Picker("Protocol", selection: $aiProtocol) {
        Text("OpenAI").tag("openai")
        Text("Anthropic").tag("anthropic")
        Text("Gemini").tag("gemini")
    }
    .pickerStyle(.segmented)

    HStack {
        Text("Base URL")
        Spacer()
        TextField("Default", text: $aiBaseURL)
            .frame(width: 260)
            .multilineTextAlignment(.trailing)
    }
    Text(defaultBaseURL(for: aiProtocol))
        .font(.caption2)
        .foregroundStyle(.tertiary)

    HStack {
        Text("API Key")
        Spacer()
        SecureField("Required", text: $aiApiKey)
            .frame(width: 260)
            .multilineTextAlignment(.trailing)
    }

    HStack {
        Text("Model")
        Spacer()
        TextField("gpt-4o-mini", text: $aiModel)
            .frame(width: 260)
            .multilineTextAlignment(.trailing)
    }
}

Section("Summary Prompt") {
    Picker("Language", selection: $summaryLanguage) {
        Text("中文").tag("中文")
        Text("English").tag("English")
        Text("日本語").tag("日本語")
    }

    Stepper("Max Sentences: \(summaryMaxSentences)", value: $summaryMaxSentences, in: 1...10)

    HStack {
        Text("Style")
        Spacer()
        TextField("Optional, e.g. 技术向", text: $summaryStyle)
            .frame(width: 260)
            .multilineTextAlignment(.trailing)
    }

    DisclosureGroup("Custom Prompt", isExpanded: $showCustomPrompt) {
        TextEditor(text: $summaryPrompt)
            .font(.system(.body, design: .monospaced))
            .frame(height: 80)
        Text("Variables: {{language}}, {{maxSentences}}, {{style}}")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

Section("Generation") {
    Picker("Preset", selection: $summaryPreset) {
        Text("Concise").tag("concise")
        Text("Standard").tag("standard")
        Text("Detailed").tag("detailed")
    }
    .pickerStyle(.segmented)

    DisclosureGroup("Custom", isExpanded: $showCustomGeneration) {
        HStack {
            Text("Max Tokens")
            Spacer()
            TextField("200", value: $summaryMaxTokens, format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
        HStack {
            Text("Temperature")
            Spacer()
            Slider(value: $summaryTemperature, in: 0...1, step: 0.1)
                .frame(width: 160)
            Text(String(format: "%.1f", summaryTemperature))
                .font(.caption)
                .frame(width: 30)
        }
    }

    DisclosureGroup("Advanced", isExpanded: $showAdvancedGeneration) {
        HStack {
            Text("Sample First")
            Spacer()
            TextField("20", value: $summarySampleFirst, format: .number)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
            Text("messages")
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Sample Last")
            Spacer()
            TextField("30", value: $summarySampleLast, format: .number)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
            Text("messages")
                .foregroundStyle(.secondary)
        }
        HStack {
            Text("Truncate")
            Spacer()
            TextField("500", value: $summaryTruncateChars, format: .number)
                .frame(width: 60)
                .multilineTextAlignment(.trailing)
            Text("chars/msg")
                .foregroundStyle(.secondary)
        }
    }
}

Section("Auto Summary") {
    Toggle("Auto-generate summaries", isOn: $autoSummary)
    if autoSummary {
        Stepper("Cooldown: \(autoSummaryCooldown) min", value: $autoSummaryCooldown, in: 1...30)
        Stepper("Min messages: \(autoSummaryMinMessages)", value: $autoSummaryMinMessages, in: 1...50)
        Toggle("Periodically refresh", isOn: $autoSummaryRefresh)
        if autoSummaryRefresh {
            Stepper("Refresh after \(autoSummaryRefreshThreshold) new messages",
                    value: $autoSummaryRefreshThreshold, in: 5...100, step: 5)
        }
    }
}
```

- [ ] **Step 2: Update saveAISettings / loadAISettings**

Update the save/load functions to use the new field names, writing all fields to `~/.engram/settings.json`. The `onChange` modifiers should call the updated save function.

- [ ] **Step 3: Add helper function**

```swift
private func defaultBaseURL(for proto: String) -> String {
    switch proto {
    case "anthropic": return "Default: https://api.anthropic.com"
    case "gemini": return "Default: https://generativelanguage.googleapis.com"
    default: return "Default: https://api.openai.com"
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Views/SettingsView.swift
git commit -m "feat: redesign AI Summary settings with provider/prompt/preset/auto sections"
```

---

## Chunk 4: Cleanup and Remove SDK Dependencies

### Task 11: Remove unused OpenAI and Anthropic SDK imports

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Check if SDKs are still used elsewhere**

Search for `openai` and `@anthropic-ai/sdk` imports across all `src/` files. The `openai` package is used in `src/core/embeddings.ts` for embedding generation — **keep it**. The `@anthropic-ai/sdk` is only used in the old `ai-client.ts` — **remove it**.

Run: `grep -r "from '@anthropic-ai/sdk'" src/` and `grep -r "from 'openai'" src/`

- [ ] **Step 2: Remove @anthropic-ai/sdk from package.json**

```bash
npm uninstall @anthropic-ai/sdk
```

- [ ] **Step 3: Build and run all tests**

Run: `npm run build && npx vitest run`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: remove unused @anthropic-ai/sdk dependency"
```

---

### Task 12: Final integration test

**Files:**
- No new files — manual verification

- [ ] **Step 1: Build TypeScript**

Run: `npm run build`
Expected: No errors

- [ ] **Step 2: Run all tests**

Run: `npx vitest run`
Expected: All pass

- [ ] **Step 3: Build macOS app**

Run: `cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Launch app and verify Settings UI**

Run: `open /path/to/DerivedData/Engram.app`
- Open Settings → verify new AI Summary sections render correctly
- Fill in an API key → verify it saves to `~/.engram/settings.json`
- Click sparkles button on a session → verify summary generates via HTTP API

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete AI Summary redesign — unified client, templates, presets, auto-summary"
```
