# AI Summary Redesign

## Problem

1. **Duplicated logic** — `AIClient.swift` and `ai-client.ts` implement identical API call logic independently
2. **Hardcoded prompt** — Chinese-only, no user customization
3. **Limited provider support** — Only OpenAI and Anthropic, fixed endpoints
4. **Manual-only** — No auto-summary; user must click per session

## Design

### 1. Unified Architecture: All AI Calls via Node.js Daemon

Delete `macos/Engram/Core/AIClient.swift`. Swift UI calls the daemon's HTTP API instead of making direct API calls.

**New daemon routes:**
- `POST /api/summary` `{ sessionId }` — generate summary for a session, returns `{ summary }`
- `GET /api/summary/status` — optional, query auto-summary queue status

**MCP tool** `generate_summary` reuses the same core function.

**Flow:**
```
Swift UI click ✨ → POST /api/summary { sessionId } → daemon generates → returns summary
Settings UI → writes settings.json → daemon reads on next call
```

### 2. Three-Protocol AI Client

Rewrite `src/core/ai-client.ts` with a unified provider interface:

```typescript
interface AIProvider {
  baseURL: string       // user-configurable, defaults to official endpoint
  apiKey: string
  model: string
  protocol: 'openai' | 'anthropic' | 'gemini'
}
```

**Protocol implementations:**
- **OpenAI-compatible** — `POST {baseURL}/v1/chat/completions`. Covers OpenAI, DeepSeek, Qwen, Ollama, Groq, etc.
- **Anthropic** — `POST {baseURL}/v1/messages` with `x-api-key` + `anthropic-version` headers.
- **Gemini-compatible** — `POST {baseURL}/v1beta/models/{model}:generateContent` with `key` query param.

User selects protocol, fills baseURL (has default), apiKey, model name.

### 3. Prompt Template System

**Default template:**
```
请用不超过 {{maxSentences}} 句话，以 {{language}} 总结以下 AI 编程对话的核心内容。
总结应包括：1) 主要讨论的问题或任务 2) 达成的结论、解决方案或关键成果
{{style}}
保持简洁。
```

**Template variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `language` | `中文` | Output language |
| `maxSentences` | `3` | Max sentences in summary |
| `style` | (empty) | Optional style instruction, e.g. "技术向" |

Rendering: simple string replacement in code. Conditional logic (e.g. omit style line if empty) handled in code, not in a template engine. No external template dependencies.

User can change variable values only, or fully replace the `summaryPrompt` template.

### 4. Three-Tier Progressive Configuration

**Preset tiers (default experience):**

| Tier | maxTokens | temperature | Sampling | Use case |
|------|-----------|-------------|----------|----------|
| Concise | 100 | 0.2 | first 10 + last 15 | Quick browse |
| Standard | 200 | 0.3 | first 20 + last 30 | **Default** |
| Detailed | 400 | 0.4 | first 30 + last 50 | Deep review |

**Custom (overrides preset's two knobs):**
- `maxTokens`: 50–1000
- `temperature`: 0–1

**Custom Advanced (full sampling control):**
- `sampleFirst`: first N messages
- `sampleLast`: last N messages
- `truncateChars`: truncate each message to N chars

**Resolution logic:** Load preset defaults, then overlay any non-null custom fields.

### 5. Auto-Summary Trigger

**Debounce timer in watcher pipeline:**

```
File change → indexer indexes → reset session's debounce timer (5 min default)
                                    ↓ timeout fires
                              Has summary? → yes → skip
                                    ↓ no
                              Messages >= threshold? → no → skip
                                    ↓ yes
                              Generate summary → write DB → emit event
```

**Rules:**
- Triggers once per session by default. Once a summary exists, skip.
- Optional "periodic refresh" mode: if enabled, regenerate when message count grows by N since last generation.
- Cooldown configurable, default 5 minutes of inactivity = session ended.
- Silently skipped if no API key is configured.

**Event:** `{ event: "summary_generated", sessionId, summary }` emitted on stdout. Swift `IndexerProcess` listens and notifies UI to refresh.

### 6. Settings Schema

All settings in `~/.engram/settings.json`:

```json
{
  "aiProtocol": "openai",
  "aiBaseURL": null,
  "aiApiKey": "",
  "aiModel": "gpt-4o-mini",

  "summaryPrompt": null,
  "summaryLanguage": "中文",
  "summaryMaxSentences": 3,
  "summaryStyle": "",

  "summaryPreset": "standard",
  "summaryMaxTokens": null,
  "summaryTemperature": null,
  "summarySampleFirst": null,
  "summarySampleLast": null,
  "summaryTruncateChars": null,

  "autoSummary": false,
  "autoSummaryCooldown": 5,
  "autoSummaryMinMessages": 4,
  "autoSummaryRefresh": false,
  "autoSummaryRefreshThreshold": 20
}
```

Default baseURLs by protocol:
- `openai` → `https://api.openai.com`
- `anthropic` → `https://api.anthropic.com`
- `gemini` → `https://generativelanguage.googleapis.com`

### 7. Settings UI (Swift SettingsView)

Redesigned "AI Summary" section with progressive disclosure:

**Provider:**
- Protocol picker (OpenAI / Anthropic / Gemini)
- Base URL text field (pre-filled with protocol default)
- API Key (SecureField)
- Model name text field

**Prompt:**
- Language dropdown (common languages + custom)
- Max Sentences stepper
- Style text field (optional)
- Expandable "Custom Prompt" for full template editing

**Generation:**
- Preset picker (Concise / Standard / Detailed)
- Expandable "Custom" section: maxTokens slider, temperature slider
- Expandable "Advanced" section: sampleFirst, sampleLast, truncateChars fields

**Auto Summary:**
- Toggle: auto-generate summaries
- Cooldown minutes field
- Min messages field
- Toggle: periodically refresh
- Refresh threshold field (shown when refresh is on)

## Implementation Notes

### Settings Migration

The old fields (`aiProvider`, `openaiApiKey`, `openaiModel`, `anthropicApiKey`, `anthropicModel`) must be migrated on first run. In `config.ts`, when `readFileSettings()` detects old fields but no new ones:
- Map `aiProvider` → `aiProtocol`
- Map `{provider}ApiKey` → `aiApiKey` (from whichever provider was active)
- Map `{provider}Model` → `aiModel`
- Write the migrated settings, remove old fields

### HTTP API Details

`POST /api/summary` is **synchronous** — blocks until the AI API responds (typically 2–10s). Returns:
- Success: `200 { summary: string }`
- Error: `400 { error: string }` (missing sessionId), `500 { error: string }` (no API key, AI API failure)

Swift client uses `URLSession` with a 30s timeout. The daemon port is read from `IndexerProcess.port` (already tracked when daemon emits `web_ready` event).

The route handler needs access to adapters for reading session messages. Extend `createApp(db, opts)` to accept `adapters` in opts.

### Watcher Interface Change

`WatcherOptions.onIndexed` callback signature changes from `() => void` to `(sessionId: string, messageCount: number) => void`. The `indexFile` return type changes from `boolean` to `{ indexed: boolean, sessionId?: string, messageCount?: number }`.

### Auto-Summary Race Condition

If a user manually generates a summary (via UI button → `POST /api/summary`) while the debounce timer is counting down, the manual call writes the summary to DB. When the timer fires, it checks `has summary? → yes → skip`. No race condition — the DB check is the single source of truth.

For the "periodic refresh" mode, store `summaryMessageCount` in the sessions table to track the message count at last summary generation.

### DaemonEvent Struct Update

Add optional fields to `DaemonEvent` in `IndexerProcess.swift`:
- `sessionId: String?`
- `summary: String?`

Handle `"summary_generated"` event by reloading the affected session.

### Preset Defaults (complete)

| Tier | maxTokens | temperature | sampleFirst | sampleLast | truncateChars |
|------|-----------|-------------|-------------|------------|---------------|
| Concise | 100 | 0.2 | 10 | 15 | 300 |
| Standard | 200 | 0.3 | 20 | 30 | 500 |
| Detailed | 400 | 0.4 | 30 | 50 | 800 |

### Embedding Independence

The `openaiApiKey` field is still used independently by `src/core/embeddings.ts` for vector embeddings. The new `aiApiKey` is solely for summary generation. Both can coexist in settings.json — embeddings continue to read `openaiApiKey`.

### Template Style Handling

When `summaryStyle` is empty, the entire `{{style}}` line is removed from the prompt (not replaced with empty string). The rendering code strips any line that resolves to whitespace-only after variable substitution.

## Files Changed

### Delete
- `macos/Engram/Core/AIClient.swift`

### Rewrite
- `src/core/ai-client.ts` — three-protocol client with template rendering
- `src/core/config.ts` — expanded FileSettings interface
- `src/tools/generate_summary.ts` — use new ai-client, add preset resolution

### New
- `src/core/auto-summary.ts` — debounce timer manager, integrates with watcher

### Modify
- `src/web.ts` — add `POST /api/summary` route
- `src/daemon.ts` — init auto-summary manager, pass to watcher, handle events
- `src/core/watcher.ts` — hook auto-summary after indexing
- `macos/Engram/Views/SettingsView.swift` — redesigned AI Summary section
- `macos/Engram/Views/SessionDetailView.swift` — call daemon HTTP API instead of AIClient
- `macos/Engram/Core/IndexerProcess.swift` — handle `summary_generated` event
