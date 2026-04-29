# Readout-Inspired Features — Design Spec

> **Date**: 2026-03-20
> **Scope**: 9 features across 3 phases, all TypeScript-first (Node side) with macOS/Web as consumers
> **Architecture**: A — Core logic in Node (MCP tools + Web API + DB), Swift reads via DaemonClient HTTP

---

## Overview

Inspired by Readout.app's feature analysis, this spec adds 9 capabilities to Engram:

| # | Feature | Phase | Layer | New MCP Tool |
|---|---------|-------|-------|-------------|
| 1 | Cost Tracking | 1 | DB + Indexer + API | `get_costs` |
| 2 | Tool Analytics | 1 | DB + Indexer + API | `tool_analytics` |
| 3 | Session Handoff | 2 | Tool + API | `handoff` |
| 4 | Session Replay | 2 | API + Swift | — |
| 5 | Command Palette | 2 | Swift only | — |
| 6 | Live Sessions | 3 | Daemon + API | `live_sessions` |
| 7 | Background Monitor | 3 | Daemon + API | — |
| 8 | MockData | 3 | Dev tooling | — |
| 9 | CLAUDE.md Linter | 3 | Tool + API | `lint_config` |

---

## Phase 1: Data Layer Enhancement

### 1. Cost Tracking

**Data source**: Claude Code session files contain `message.usage` on every assistant message:
```json
{
  "usage": {
    "input_tokens": 2,
    "cache_creation_input_tokens": 2012,
    "cache_read_input_tokens": 21795,
    "output_tokens": 8,
    "service_tier": "standard"
  }
}
```
Other sources (iflow, gemini, codex) currently lack token data — will be added as they become available.

**DB migration** — new table `session_costs` (separate from sessions to avoid conflict with snapshot write path):
```sql
CREATE TABLE IF NOT EXISTS session_costs (
  session_id TEXT PRIMARY KEY,
  model TEXT,
  input_tokens INTEGER DEFAULT 0,
  output_tokens INTEGER DEFAULT 0,
  cache_read_tokens INTEGER DEFAULT 0,
  cache_creation_tokens INTEGER DEFAULT 0,
  cost_usd REAL DEFAULT 0,
  computed_at TEXT,
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
```
Separate table because `AuthoritativeSessionSnapshot` / `upsertAuthoritativeSnapshot()` would otherwise overwrite these columns on every re-index cycle. `session_costs` is written independently after message streaming completes.

**Message interface change** (`src/adapters/types.ts`):
```typescript
export interface Message {
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp?: string
  toolCalls?: ToolCall[]
  usage?: TokenUsage
  // Note: model is on SessionInfo, not per-message. Cost computation uses session.model.
}

export interface TokenUsage {
  inputTokens: number
  outputTokens: number
  cacheReadTokens?: number
  cacheCreationTokens?: number
}
```

**Adapter change**: Claude Code adapter's `streamMessages()` extracts `message.usage` fields into `Message.usage`. Tool_use blocks populate both `content` (as text, for backward compat) AND `toolCalls` (as structured data). Other adapters unchanged.

**Indexer change**: After streaming all messages, sum token counts and compute cost:
```typescript
// In indexer.ts, after message streaming loop:
const cost = computeCost(session.model, totalInputTokens, totalOutputTokens, cacheReadTokens, cacheCreationTokens)
// INSERT OR REPLACE INTO session_costs (session_id, model, input_tokens, ..., cost_usd, computed_at)
// VALUES (?, ?, ?, ..., ?, datetime('now'))
```
This is independent of the snapshot write path — `session_costs` is a separate table.

**Pricing** — new `src/core/pricing.ts`:
```typescript
export const MODEL_PRICING: Record<string, ModelPrice> = {
  'claude-opus-4-6':     { input: 15,  output: 75, cacheRead: 1.5,  cacheWrite: 18.75 },
  'claude-sonnet-4-6':   { input: 3,   output: 15, cacheRead: 0.3,  cacheWrite: 3.75 },
  'claude-sonnet-4-5':   { input: 3,   output: 15, cacheRead: 0.3,  cacheWrite: 3.75 },
  'claude-haiku-4-5':    { input: 0.8, output: 4,  cacheRead: 0.08, cacheWrite: 1 },
  'gpt-4o':              { input: 2.5, output: 10, cacheRead: 1.25, cacheWrite: 2.5 },
  'gpt-4o-mini':         { input: 0.15, output: 0.6, cacheRead: 0.075, cacheWrite: 0.15 },
  'gpt-4.1':             { input: 2,   output: 8,  cacheRead: 0.5,  cacheWrite: 2 },
  'gemini-2.0-flash':    { input: 0.1, output: 0.4, cacheRead: 0.025, cacheWrite: 0.1 },
  'gemini-2.5-pro':      { input: 1.25, output: 10, cacheRead: 0.31, cacheWrite: 1.25 },
}

export interface ModelPrice {
  input: number    // per 1M input tokens
  output: number   // per 1M output tokens
  cacheRead: number
  cacheWrite: number
}

// Settings override: settings.customPricing: Record<string, ModelPrice>
export function computeCost(model: string, input: number, output: number, cacheRead: number, cacheCreation: number, customPricing?: Record<string, ModelPrice>): number
```
Fuzzy model matching: `claude-sonnet-4-5-20250929` → match `claude-sonnet-4-5` by prefix. Unknown models return `cost_usd = 0` with a logged warning (consistent with "adapters silently skip failures" convention).

**MCP tool** — `get_costs`:
```typescript
{
  name: 'get_costs',
  inputSchema: {
    properties: {
      group_by: { type: 'string', enum: ['model', 'source', 'project', 'day'] },
      since: { type: 'string', description: 'ISO 8601' },
      until: { type: 'string', description: 'ISO 8601' },
    }
  }
}
// Returns: { totalCostUsd, totalInputTokens, totalOutputTokens, breakdown: [{ key, costUsd, inputTokens, outputTokens, sessionCount }] }
```

**Web API**:
- `GET /api/costs?group_by=model&since=2026-03-01` — cost summary
- `GET /api/costs/sessions?limit=20&sort=cost_desc` — top sessions by cost

**Backfill**: On first daemon startup after migration, existing sessions have no `session_costs` rows. Add a dedicated `backfillCosts()` method in indexer (matching existing `backfillCounts()` / `backfillTiers()` pattern) that runs on startup: query sessions with no `session_costs` row and `tier != 'skip'`, re-read source files to extract usage data, and insert cost rows. Rate-limited to avoid I/O storms.

---

### 2. Tool Analytics

**DB migration** — new table `session_tools`:
```sql
CREATE TABLE IF NOT EXISTS session_tools (
  session_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  call_count INTEGER DEFAULT 0,
  PRIMARY KEY (session_id, tool_name),
  FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_session_tools_name ON session_tools(tool_name);
```

**Indexer change**: During message streaming, collect tool_use names:
```typescript
const toolCounts = new Map<string, number>()
for await (const msg of adapter.streamMessages(filePath)) {
  // existing processing...
  if (msg.toolCalls) {
    for (const tc of msg.toolCalls) {
      toolCounts.set(tc.name, (toolCounts.get(tc.name) || 0) + 1)
    }
  }
}
// Batch insert into session_tools
```

**Adapter change**: Claude Code adapter populates `msg.toolCalls` from content array items where `type === 'tool_use'`:
```typescript
// In streamMessages(), for assistant messages with content array:
const toolCalls = content
  .filter(c => c.type === 'tool_use')
  .map(c => ({ name: c.name, input: JSON.stringify(c.input).slice(0, 500) }))
if (toolCalls.length > 0) msg.toolCalls = toolCalls
```

**File path extraction**: For `Edit`, `Write`, `Read` tool calls, extract `file_path` from input. Store top-N edited files per session in a separate query (no new table — aggregate from session_tools + re-read on demand).

**MCP tool** — `tool_analytics`:
```typescript
{
  name: 'tool_analytics',
  inputSchema: {
    properties: {
      project: { type: 'string' },
      since: { type: 'string' },
      group_by: { type: 'string', enum: ['tool', 'session', 'project'] },
    }
  }
}
// Returns: { tools: [{ name, callCount, sessionCount }], totalCalls, uniqueTools }
```

**Web API**:
- `GET /api/tool-analytics?project=engram&since=2026-03-01` — tool usage frequency
- `GET /api/tool-analytics/files?project=engram` — most edited files (extracted from Edit/Write/Read inputs)

**Backfill**: Same startup pattern as cost — `backfillToolAnalytics()` runs on daemon startup, re-reads session files for sessions with no `session_tools` rows and `tier != 'skip'`.

---

## Phase 2: UX Enhancement

### 3. Session Handoff

**MCP tool** — `handoff`:
```typescript
{
  name: 'handoff',
  inputSchema: {
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project directory (absolute path)' },
      sessionId: { type: 'string', description: 'Specific session to handoff (optional)' },
      format: { type: 'string', enum: ['markdown', 'plain'], default: 'markdown' },
    }
  }
}
```

**Brief generation** (`src/tools/handoff.ts`):
```typescript
export async function handleHandoff(db: Database, params: HandoffParams): Promise<{ brief: string; sessionCount: number }> {
  // 1. Resolve project name from cwd via resolveProjectName(), then expand aliases via db.listProjectAliases()
  // 2. Query recent sessions for all matching project names
  // 3. For each session: summary, source, duration, model, cost (joined from session_costs)
  // 3. Read last user message from most recent session (the "what was I doing" context)
  // 4. Format into brief template
}
```

**Brief template**:
```markdown
## Handoff — {project}
**Last active**: {relativeTime} via {source} ({model})
**Recent sessions** ({count}):
1. [{source}] {summary} — {duration}, {messageCount} msgs, ${cost}
2. ...

**Last task**: {lastUserMessage, truncated to 200 chars}
**Suggested prompt**: "继续 {lastUserMessage summary}"
```

**Web API**: `POST /api/handoff` with `{ cwd, sessionId?, format? }`

**macOS**: "Handoff" button in SessionDetailView toolbar → calls daemon API → copies brief to clipboard + shows toast "Brief copied". Optional: "Handoff to Terminal" button opens Terminal.app with clipboard pre-filled.

---

### 4. Session Replay

**Web API** — `GET /api/sessions/:id/timeline`:
```typescript
interface TimelineResponse {
  sessionId: string
  source: string
  totalEntries: number
  entries: TimelineEntry[]
}

interface TimelineEntry {
  index: number
  timestamp: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  type: 'message' | 'tool_use' | 'tool_result' | 'thinking'
  preview: string          // first 100 chars of content
  toolName?: string        // for tool_use entries
  durationToNextMs?: number // gap to next entry
  tokens?: { input: number; output: number }
}
```

Implementation: Uses existing `adapter.streamMessages()` to read the session, maps each message to a TimelineEntry with timestamp and preview. No DB storage needed — reads source file on demand.

**Swift** — new `Views/Replay/SessionReplayView.swift`:

```
State machine: idle → loading → ready ⇄ playing → done
                                  ↕
                               paused
```

Properties:
```swift
@Observable class ReplayState {
    var entries: [TimelineEntry] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var playbackSpeed: Double = 1.0  // 0.5x, 1x, 2x, 4x
    var status: ReplayStatus = .idle

    func load(sessionId: String) async    // GET /api/sessions/:id/timeline
    func play()                            // start auto-advance
    func pause()
    func stepForward()
    func stepBackward()
    func seekTo(index: Int)
    func seekToFraction(_ fraction: CGFloat)
}
```

UI layout:
```
┌─────────────────────────────────────┐
│  ◀  ▶▶  ⏸   [====●========] 23/147 │  Controls + scrubber
│  1.5x  ⏱ 3:42                       │  Speed + elapsed
├─────────────────────────────────────┤
│  Message content (scrollable)        │  Current entry rendered
│  with tool calls highlighted         │
├─────────────────────────────────────┤
│  ░░░████░░░░░████████░░░░░░░░░░░░░░ │  Density bar (message distribution)
└─────────────────────────────────────┘
```

Entry point: "Replay" button in SessionDetailView → NavigationLink to SessionReplayView.

---

### 5. Command Palette

Upgrade existing `GlobalSearchOverlay.swift` (⌘K) to a unified Command Palette.

**New model** — `Models/PaletteItem.swift`:
```swift
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String         // SF Symbol name
    let category: PaletteCategory
    let shortcut: String?    // "⌘1", "⌘R"
    let action: () -> Void
}

enum PaletteCategory: String, CaseIterable {
    case navigation = "Navigation"
    case action = "Actions"
    case session = "Sessions"
}
```

**Data sources**:
1. **Static commands** (registered at app launch):
   - Navigation: all Screen cases → "Go to {page name}" with icons
   - Actions: "Refresh Index" (⌘R), "Open Settings" (⌘,), "Toggle Sidebar"
2. **Dynamic sessions** (searched when query.count >= 2):
   - Calls `DaemonClient.search(query:)` → maps results to PaletteItems
   - Shows: session title/summary, source icon, relative time

**Matching**:
- Commands: case-insensitive prefix match on title
- Sessions: delegated to daemon search API (FTS + semantic)

**Refactor scope**: `GlobalSearchOverlay.swift` → rename to `CommandPalette.swift`, expand from search-only to command+search. Keep ⌘K keybinding.

---

## Phase 3: Monitoring & DX

### 6. Live Sessions

**New module** — `src/core/live-sessions.ts`:

```typescript
export interface LiveSession {
  source: SourceName
  sessionId?: string
  project?: string
  cwd: string
  filePath: string          // the actively-modified .jsonl file
  startedAt: string         // session start time from first line
  model?: string
  currentActivity?: string  // "Reading src/auth.ts"
  lastModifiedAt: string    // file mtime — the liveness signal
}

export class LiveSessionMonitor {
  private sessions: Map<number, LiveSession> = new Map()
  private interval: NodeJS.Timeout | null = null

  start(intervalMs = 5000): void    // start polling
  stop(): void
  getSessions(): LiveSession[]

  private async scan(): Promise<void> {
    // Detect live sessions via recently-modified session files (avoids fragile ps/lsof):
    // 1. For each watched source dir, find .jsonl files modified in last 60 seconds
    //    (reuse watcher's source path list from WATCHED_SOURCES)
    // 2. For each recently-modified file, read last few lines to extract:
    //    - latest tool_use name → currentActivity ("Reading src/auth.ts")
    //    - model from latest assistant message
    //    - cwd/project from session header
    // 3. Match to existing session in DB for metadata (project, tier)
    // 4. Update this.sessions map (add new, remove stale files >60s inactive)
  }
}
```

**Detection strategy** (file-based, not process-based — avoids fragile ps/lsof/grep):
- Scan watched source directories for `.jsonl` files modified in last 60 seconds
- Reuses `WATCHED_SOURCES` path list from watcher infrastructure
- Read tail of active session file for latest tool_use → current activity string
- A session file not modified for >60s is considered "ended"
- No PID tracking needed — file mtime is the source of truth

**Daemon integration**: `LiveSessionMonitor` started alongside indexer/watcher in `daemon.ts`. Exposed via:

**Web API**:
- `GET /api/live` — snapshot of current live sessions
- `GET /api/live/stream` — SSE endpoint, pushes updates every 5s:
  ```
  event: update
  data: {"sessions": [...]}
  ```

**MCP tool** — `live_sessions`:
```typescript
{
  name: 'live_sessions',
  inputSchema: { properties: {} }
}
// Returns: { sessions: LiveSession[], count: number }
```

**macOS**:
- `SourcePulseView` (existing empty page) filled with live session cards
- Menu bar badge: show count of active sessions on the status item
- Each card: source icon, project name, current activity, duration, "Open Session" button

---

### 7. Background Monitor

**New module** — `src/core/monitor.ts`:

```typescript
export interface MonitorAlert {
  id: string
  category: 'cost_threshold' | 'long_session' | 'high_error_rate' | 'unpushed_commits'
  severity: 'info' | 'warning' | 'critical'
  title: string
  detail: string
  timestamp: string
  dismissed: boolean
}

export class BackgroundMonitor {
  private alerts: MonitorAlert[] = []
  private interval: NodeJS.Timeout | null = null

  start(db: Database, config: MonitorConfig, intervalMs = 600_000): void  // every 10 min
  stop(): void
  getAlerts(): MonitorAlert[]
  dismissAlert(id: string): void

  private async check(db: Database, config: MonitorConfig): Promise<void> {
    // 1. Cost check: SELECT SUM(cost_usd) FROM sessions WHERE start_time >= today
    //    → if > config.dailyCostBudget → alert
    // 2. Long session: query live sessions, any running > config.longSessionMinutes
    //    → warning alert
    // 3. Error rate: recent sessions with high tool_message_count relative to total
    //    → info alert
    // 4. Unpushed commits: for active projects, `git rev-list @{u}..HEAD --count`
    //    → warning if > 10
  }
}

export interface MonitorConfig {
  enabled: boolean
  dailyCostBudget?: number        // USD, default 20
  longSessionMinutes?: number     // default 180
  notifyOnCostThreshold?: boolean // default true
  notifyOnLongSession?: boolean   // default true
}
```

**Settings** (`~/.engram/settings.json`):
```json
{
  "monitor": {
    "enabled": true,
    "dailyCostBudget": 20,
    "longSessionMinutes": 180,
    "notifyOnCostThreshold": true,
    "notifyOnLongSession": true
  }
}
```

**Daemon integration**: Started in `daemon.ts` after indexer. Alerts emitted as JSON events to stdout:
```json
{ "event": "alert", "alert": { "category": "cost_threshold", "title": "Daily cost exceeded $20", ... } }
```

**Swift**: `IndexerProcess` parses alert events → `UNUserNotificationCenter.add()` for system notifications. AlertBanner component (already exists) shows in-app alerts.

**Web API**: `GET /api/monitor/alerts` — current alert list (in-memory, not persisted).

---

### 8. MockData

**New module** — `src/core/mock-data.ts`:

```typescript
export async function populateMockData(db: Database): Promise<MockStats>
export async function clearMockData(db: Database): Promise<number>

interface MockStats {
  sessions: number
  tools: number
  costUsd: number
}
```

**Generation strategy**:
```typescript
// 50 sessions across 30 days:
// - Sources: claude-code (40%), codex (15%), gemini-cli (10%), cursor (10%), others (25%)
// - Projects: 5 fictional projects ("weather-api", "chat-app", "ml-pipeline", "docs-site", "infra-tools")
// - Models: claude-sonnet-4-6 (50%), claude-opus-4-6 (20%), gpt-4o (15%), gemini-2.0-flash (15%)
// - Message counts: 5-200 per session (normal distribution)
// - Token counts: proportional to message count × model typical output
// - Tiers: 60% normal, 20% lite, 10% premium, 10% skip
// - Tool analytics: Read (30%), Bash (25%), Edit (15%), Write (10%), Grep (8%), Glob (5%), other (7%)

// All mock sessions:
//   file_path = '__mock__/{uuid}.jsonl'  (sentinel prefix, doesn't point to real file)
//   origin = 'local' (normal default — origin is for sync, not mock tagging)
```

**Trigger**:
- CLI: `node dist/daemon.js --mock`
- Web API: `POST /api/dev/mock` (returns MockStats)
- Web API: `DELETE /api/dev/mock` (clears mock data)
- Setting: `devMode: true` in settings.json enables `/api/dev/*` endpoints

**Safety**: All mock data identified by `file_path LIKE '__mock__%'` (the `origin` column is reserved for multi-machine sync identity, not data source tagging). Cleanup: `DELETE FROM sessions WHERE file_path LIKE '__mock__%'` — cascading FKs handle `session_tools` and `session_costs` automatically.

---

### 9. CLAUDE.md Linter

**New tool** — `src/tools/lint_config.ts`:

```typescript
export const lintConfigTool = {
  name: 'lint_config',
  inputSchema: {
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project root directory' },
    }
  }
}

export interface LintIssue {
  file: string          // which config file has the issue
  line: number
  severity: 'error' | 'warning' | 'info'
  message: string       // "Referenced file `src/old.ts` does not exist"
  suggestion?: string   // "Did you mean `src/new.ts`?"
}

export async function handleLintConfig(params: { cwd: string }): Promise<{ issues: LintIssue[]; score: number }>
```

**Check pipeline**:
```typescript
async function handleLintConfig({ cwd }) {
  const issues: LintIssue[] = []

  // 1. Discover config files
  const configFiles = await findConfigFiles(cwd)
  // Scans: CLAUDE.md, .claude/CLAUDE.md, AGENTS.md, .cursorrules, etc.

  for (const configFile of configFiles) {
    const content = await readFile(configFile)
    const lines = content.split('\n')

    for (const [lineNum, line] of lines.entries()) {
      // 2. Extract backtick references: `src/foo.ts`, `npm run build`, etc.
      const refs = extractBacktickRefs(line)

      for (const ref of refs) {
        // 3. Check file references
        if (looksLikeFilePath(ref)) {
          const exists = await fileExists(path.join(cwd, ref))
          if (!exists) {
            const suggestion = await findSimilarFile(cwd, ref)  // fuzzy match
            issues.push({ file: configFile, line: lineNum + 1, severity: 'error',
              message: `Referenced file \`${ref}\` does not exist`,
              suggestion: suggestion ? `Did you mean \`${suggestion}\`?` : undefined })
          }
        }

        // 4. Check npm script references
        if (looksLikeNpmScript(ref)) {
          const pkgJson = await readPackageJson(cwd)
          if (pkgJson && !pkgJson.scripts?.[ref]) {
            issues.push({ file: configFile, line: lineNum + 1, severity: 'warning',
              message: `npm script \`${ref}\` not found in package.json` })
          }
        }
      }
    }

    // 5. Check for duplicate/conflicting instructions across config levels
    // (compare project CLAUDE.md vs user CLAUDE.md for contradictions)
  }

  // Score: 100 - (errors * 10) - (warnings * 3) - (info * 1), min 0
  const score = Math.max(0, 100 - issues.reduce((s, i) =>
    s + (i.severity === 'error' ? 10 : i.severity === 'warning' ? 3 : 1), 0))

  return { issues, score }
}
```

**Web API**: `POST /api/lint` with `{ cwd }` — returns same `{ issues, score }`.

---

## Cross-Cutting Concerns

### DB Migration Strategy
All migrations in `src/core/db.ts:migrate()` using existing idempotent pattern:
```typescript
// Check column exists before ALTER TABLE
const cols = db.prepare('PRAGMA table_info(sessions)').all()
if (!cols.find(c => c.name === 'input_tokens')) {
  db.exec('ALTER TABLE sessions ADD COLUMN input_tokens INTEGER DEFAULT 0')
}
```

### Backfill Strategy
After adding new columns/tables, existing sessions need backfill:
1. Enqueue sessions with `input_tokens = 0` into `session_index_jobs` with action `'backfill'`
2. Backfill worker reads source file, extracts usage/tool data, updates DB
3. Run as background task in daemon, rate-limited to avoid I/O storms

### MCP Tool Registration
New tools registered in `src/index.ts` alongside existing ones. Pattern: import handler from `src/tools/*.ts`, add to `server.setRequestHandler(ListToolsRequestSchema, ...)`.

### macOS Integration
All new features consumed via DaemonClient HTTP calls. No direct DB writes from Swift. New pages added to `SidebarView.swift` navigation and `Screen` enum.

### Settings Integration
`MonitorConfig` type added to `FileSettings` in `src/core/config.ts` as `monitor?: MonitorConfig` for type safety.

### Testing Strategy
- Unit tests: pricing computation, mock data generation, lint checks
- Integration tests: cost/tool data extraction from fixture files — add at least one Claude Code fixture with `message.usage` data to `tests/fixtures/claude-code/`
- API tests: new endpoints with mock DB
- Follow existing Vitest patterns with real fixtures (no mocking)

### Files to Create
```
src/core/pricing.ts           # Model pricing + cost computation
src/core/live-sessions.ts     # Process detection + live monitoring
src/core/monitor.ts           # Background alerts
src/core/mock-data.ts         # Demo data generation
src/tools/get_costs.ts        # Cost tracking MCP tool
src/tools/tool_analytics.ts   # Tool usage MCP tool
src/tools/handoff.ts          # Session handoff MCP tool
src/tools/live_sessions.ts    # Live sessions MCP tool
src/tools/lint_config.ts      # Config linter MCP tool

macos/Engram/Views/Replay/SessionReplayView.swift   # Replay UI
macos/Engram/Models/ReplayState.swift               # Replay state machine
macos/Engram/Models/PaletteItem.swift                # Command palette model
```

### Files to Modify
```
src/adapters/types.ts          # Add TokenUsage, model to Message
src/adapters/claude-code.ts    # Extract usage + toolCalls from messages
src/core/db.ts                 # New tables: session_costs + session_tools
src/core/config.ts             # Add MonitorConfig to FileSettings
src/core/indexer.ts            # Accumulate tokens/tools during indexing
src/index.ts                   # Register new MCP tools
src/daemon.ts                  # Start LiveSessionMonitor + BackgroundMonitor
src/web.ts                     # New API endpoints

macos/Engram/Views/GlobalSearchOverlay.swift → CommandPalette.swift
macos/Engram/Views/Pages/SourcePulseView.swift     # Fill with live sessions
macos/Engram/Views/SessionDetailView.swift          # Add Handoff + Replay buttons
macos/Engram/Models/Screen.swift                    # Add replay screen
macos/Engram/Core/DaemonClient.swift                # New API calls
macos/Engram/Views/Settings/GeneralSettingsSection.swift  # Monitor config
```
