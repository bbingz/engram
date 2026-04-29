# Phase 2: Session Handoff + Replay + Command Palette — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add session handoff briefing (MCP tool + API), session replay timeline (API + Swift UI), and upgrade global search overlay to a unified command palette.

**Architecture:** Handoff uses the existing `get_context.ts` project resolution pattern (basename + alias expansion) to query recent sessions, read last user message, and format a markdown brief. Replay adds a timeline API that streams messages on-demand via existing adapters (no DB storage). Command palette refactors `GlobalSearchOverlay.swift` to mix static navigation commands with dynamic session search.

**Tech Stack:** TypeScript, SQLite (better-sqlite3), Vitest, Hono, SwiftUI (macOS 14+, GRDB)

**Spec:** `docs/superpowers/specs/2026-03-20-readout-inspired-features-design.md` — Phase 2 section

---

**Note:** Line numbers in this plan are approximate reference points from the time of writing. Earlier tasks modify files, causing line numbers to drift. Use function/method names to locate insertion points.

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `src/tools/handoff.ts` | MCP tool: generate session handoff brief for a project |
| `tests/tools/handoff.test.ts` | Unit + integration tests for handoff tool |
| `tests/integration/timeline.test.ts` | Integration test for session timeline API |
| `macos/Engram/Views/Replay/SessionReplayView.swift` | Replay UI with transport controls + density bar |
| `macos/Engram/Models/ReplayState.swift` | Replay state machine (`@Observable`) |
| `macos/Engram/Models/PaletteItem.swift` | Command palette item model + category enum |

### Modified Files
| File | Changes |
|------|---------|
| `src/index.ts:73-163` | Register `handoff` MCP tool in `allTools` + CallTool handler |
| `src/web.ts:253+` | Add `POST /api/handoff` and `GET /api/sessions/:id/timeline` endpoints |
| `macos/Engram/Views/SessionDetailView.swift:56-80` | Add "Handoff" and "Replay" buttons to TranscriptToolbar callbacks |
| `macos/Engram/Views/Transcript/TranscriptToolbar.swift:28-50` | Add handoff + replay action buttons to toolbar HStack |
| `macos/Engram/Views/GlobalSearchOverlay.swift` | Refactor to `CommandPalette.swift` — mixed commands + session search |
| `macos/Engram/Core/DaemonClient.swift:12-32` | Add `post()` method + `HandoffResponse`, `TimelineResponse` types |
| `macos/Engram/Models/Screen.swift:4-81` | No changes needed (replay is pushed via NavigationLink, not a Screen case) |

---

### Task 1: Create Handoff Tool Handler

**Files:**
- Create: `src/tools/handoff.ts`

- [ ] **Step 1: Write failing test**

Create `tests/tools/handoff.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { Database } from '../../src/core/db.js'
import { handleHandoff } from '../../src/tools/handoff.js'

describe('handoff', () => {
  let db: Database

  beforeAll(() => {
    db = new Database(':memory:')
    // Insert test sessions for "my-project"
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary)
      VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/home/user/my-project', 'my-project', 'claude-sonnet-4-6', 20, 8, 10, 1, 1, '/test/s1.jsonl', 5000, 'normal', 'Fixed authentication bug in login flow')
    `)
    db.getRawDb().exec(`
      INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary)
      VALUES ('s2', 'claude-code', '2026-03-20T08:00:00Z', '/home/user/my-project', 'my-project', 'claude-sonnet-4-6', 15, 5, 8, 1, 1, '/test/s2.jsonl', 3000, 'normal', 'Refactored database connection pooling')
    `)
    // Insert cost data for s1
    db.upsertSessionCost('s1', 'claude-sonnet-4-6', 100000, 5000, 50000, 10000, 0.42)
  })

  it('generates a brief for a known project', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.sessionCount).toBe(2)
    expect(result.brief).toContain('my-project')
    expect(result.brief).toContain('Fixed authentication bug')
  })

  it('includes cost data when available', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project' })
    expect(result.brief).toContain('$0.42')
  })

  it('returns empty brief for unknown project', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/unknown-project' })
    expect(result.sessionCount).toBe(0)
    expect(result.brief).toContain('No recent sessions')
  })

  it('uses specific sessionId when provided', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', sessionId: 's2' })
    expect(result.sessionCount).toBe(1)
    expect(result.brief).toContain('Refactored database')
  })

  it('generates plain format', async () => {
    const result = await handleHandoff(db, { cwd: '/home/user/my-project', format: 'plain' })
    expect(result.brief).not.toContain('##')
    expect(result.brief).not.toContain('**')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- tests/tools/handoff.test.ts`
Expected: FAIL — module `src/tools/handoff.js` not found.

- [ ] **Step 3: Implement handoff tool handler**

Create `src/tools/handoff.ts`:

```typescript
import { basename } from 'path'
import type { Database } from '../core/db.js'

export const handoffTool = {
  name: 'handoff',
  description: 'Generate a handoff brief for a project — summarizes recent sessions to help resume work.',
  inputSchema: {
    type: 'object' as const,
    required: ['cwd'],
    properties: {
      cwd: { type: 'string', description: 'Project directory (absolute path)' },
      sessionId: { type: 'string', description: 'Specific session to handoff (optional)' },
      format: { type: 'string', enum: ['markdown', 'plain'], description: 'Output format (default: markdown)' },
    },
    additionalProperties: false,
  },
}

export interface HandoffParams {
  cwd: string
  sessionId?: string
  format?: 'markdown' | 'plain'
}

interface SessionWithCost {
  id: string
  source: string
  startTime: string
  summary?: string
  model?: string
  messageCount: number
  project?: string
  costUsd?: number
}

export async function handleHandoff(
  db: Database,
  params: HandoffParams
): Promise<{ brief: string; sessionCount: number }> {
  const format = params.format ?? 'markdown'

  // 1. Resolve project name from cwd (same pattern as get_context.ts)
  const projectName = basename(params.cwd.replace(/\/$/, ''))
  const projectNames = db.resolveProjectAliases([projectName])

  // 2. Query recent sessions
  let sessions: SessionWithCost[]
  if (params.sessionId) {
    const s = db.getSession(params.sessionId)
    sessions = s ? [mapSession(s)] : []
  } else {
    const raw = db.listSessions({ projects: projectNames, limit: 10 })
    // Fallback: try cwd-based search if project name yields nothing
    if (raw.length === 0) {
      const fallback = db.listSessions({ project: params.cwd, limit: 10 })
      sessions = fallback.map(mapSession)
    } else {
      sessions = raw.map(mapSession)
    }
  }

  // 3. Join cost data for each session
  for (const s of sessions) {
    try {
      const costRow = db.getRawDb().prepare(
        'SELECT cost_usd FROM session_costs WHERE session_id = ?'
      ).get(s.id) as { cost_usd: number } | undefined
      if (costRow) s.costUsd = costRow.cost_usd
    } catch { /* no cost data */ }
  }

  // 4. Format brief
  if (sessions.length === 0) {
    return {
      brief: format === 'markdown'
        ? `## Handoff — ${projectName}\n\nNo recent sessions found for this project.`
        : `Handoff — ${projectName}\n\nNo recent sessions found for this project.`,
      sessionCount: 0,
    }
  }

  const mostRecent = sessions[0]
  const relativeTime = formatRelativeTime(mostRecent.startTime)

  if (format === 'markdown') {
    const lines: string[] = []
    lines.push(`## Handoff — ${projectName}`)
    lines.push(`**Last active**: ${relativeTime} via ${mostRecent.source} (${mostRecent.model || 'unknown'})`)
    lines.push(`**Recent sessions** (${sessions.length}):`)
    for (let i = 0; i < sessions.length; i++) {
      const s = sessions[i]
      const cost = s.costUsd != null ? `, $${s.costUsd.toFixed(2)}` : ''
      lines.push(`${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${cost}`)
    }
    lines.push('')
    if (mostRecent.summary) {
      lines.push(`**Last task**: ${mostRecent.summary.slice(0, 200)}`)
      const shortSummary = mostRecent.summary.slice(0, 60)
      lines.push(`**Suggested prompt**: "继续 ${shortSummary}"`)
    }
    return { brief: lines.join('\n'), sessionCount: sessions.length }
  }

  // Plain format
  const lines: string[] = []
  lines.push(`Handoff — ${projectName}`)
  lines.push(`Last active: ${relativeTime} via ${mostRecent.source} (${mostRecent.model || 'unknown'})`)
  lines.push(`Recent sessions (${sessions.length}):`)
  for (let i = 0; i < sessions.length; i++) {
    const s = sessions[i]
    const cost = s.costUsd != null ? `, $${s.costUsd.toFixed(2)}` : ''
    lines.push(`  ${i + 1}. [${s.source}] ${s.summary || 'No summary'} — ${s.messageCount} msgs${cost}`)
  }
  if (mostRecent.summary) {
    lines.push(`Last task: ${mostRecent.summary.slice(0, 200)}`)
  }
  return { brief: lines.join('\n'), sessionCount: sessions.length }
}

function mapSession(s: { id: string; source: string; startTime: string; summary?: string; model?: string; messageCount: number; project?: string }): SessionWithCost {
  return { id: s.id, source: s.source, startTime: s.startTime, summary: s.summary, model: s.model, messageCount: s.messageCount, project: s.project }
}

function formatRelativeTime(isoTime: string): string {
  const diffMs = Date.now() - new Date(isoTime).getTime()
  const minutes = Math.floor(diffMs / 60_000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npm test -- tests/tools/handoff.test.ts`
Expected: All pass.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass. No regressions.

- [ ] **Step 6: Commit**

```bash
git add src/tools/handoff.ts tests/tools/handoff.test.ts
git commit -m "feat: add handoff tool for session briefing"
```

---

### Task 2: Register Handoff in MCP Server + Web API

**Files:**
- Modify: `src/index.ts:73-163`
- Modify: `src/web.ts:253+`

- [ ] **Step 1: Register MCP tool in index.ts**

In `src/index.ts`, add imports at the top:
```typescript
import { handoffTool, handleHandoff } from './tools/handoff.js'
```

Add to the `allTools` array (around line 73-85, after `getMemoryTool`):
```typescript
handoffTool,
```

Add to the if-else chain in `CallToolRequestSchema` handler (around line 153-157, before the `else` fallback):
```typescript
} else if (name === 'handoff') {
  result = await handleHandoff(db, a as { cwd: string; sessionId?: string; format?: string })
```

- [ ] **Step 2: Add Web API endpoint in web.ts**

In `src/web.ts`, add import at the top:
```typescript
import { handleHandoff } from './tools/handoff.js'
```

After the existing `POST /api/summary` endpoint (around line 340), add:
```typescript
// Handoff brief generation
app.post('/api/handoff', async (c) => {
  const body = await c.req.json().catch(() => ({}))
  const cwd = (body as Record<string, unknown>).cwd as string | undefined
  if (!cwd) {
    return c.json({ error: 'Missing required field: cwd' }, 400)
  }
  const sessionId = (body as Record<string, unknown>).sessionId as string | undefined
  const format = (body as Record<string, unknown>).format as string | undefined
  try {
    const result = await handleHandoff(db, {
      cwd,
      sessionId,
      format: format as 'markdown' | 'plain' | undefined,
    })
    return c.json(result)
  } catch (err) {
    return c.json({ error: `Handoff failed: ${err}` }, 500)
  }
})
```

- [ ] **Step 3: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 4: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/index.ts src/web.ts
git commit -m "feat: register handoff tool in MCP server and add POST /api/handoff endpoint"
```

---

### Task 3: Session Timeline API

**Files:**
- Modify: `src/web.ts`
- Create: `tests/integration/timeline.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/integration/timeline.test.ts`:

```typescript
import { describe, it, expect, beforeAll } from 'vitest'
import { resolve } from 'path'
import { Database } from '../../src/core/db.js'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'
import type { SessionAdapter, Message } from '../../src/adapters/types.js'

// Reuse existing fixture
const FIXTURE = resolve(__dirname, '../fixtures/claude-code/basic.jsonl')

describe('session timeline', () => {
  let db: Database
  let adapter: ClaudeCodeAdapter

  beforeAll(async () => {
    db = new Database(':memory:')
    adapter = new ClaudeCodeAdapter()
    const info = await adapter.parseSessionInfo(FIXTURE)
    if (info) {
      db.getRawDb().prepare(`
        INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(info.id, info.source, info.startTime, info.cwd, info.project || '', info.model || '', info.messageCount, info.userMessageCount, info.assistantMessageCount, info.toolMessageCount, info.systemMessageCount, FIXTURE, info.sizeBytes, 'normal')
    }
  })

  it('builds timeline entries from session messages', async () => {
    const session = db.listSessions({ limit: 1 })[0]
    expect(session).toBeDefined()

    const entries: Array<{
      index: number
      role: string
      type: string
      preview: string
      timestamp?: string
      toolName?: string
      durationToNextMs?: number
    }> = []

    let idx = 0
    let prevTimestamp: string | undefined
    for await (const msg of adapter.streamMessages(session.filePath)) {
      const entry: typeof entries[0] = {
        index: idx,
        role: msg.role,
        type: msg.toolCalls?.length ? 'tool_use' : 'message',
        preview: msg.content.slice(0, 100),
        timestamp: msg.timestamp,
      }
      if (msg.toolCalls?.length) {
        entry.toolName = msg.toolCalls[0].name
      }
      if (prevTimestamp && msg.timestamp) {
        const gap = new Date(msg.timestamp).getTime() - new Date(prevTimestamp).getTime()
        if (entries.length > 0) entries[entries.length - 1].durationToNextMs = gap
      }
      prevTimestamp = msg.timestamp
      entries.push(entry)
      idx++
    }

    expect(entries.length).toBeGreaterThan(0)
    expect(entries[0].index).toBe(0)
    expect(entries[0].role).toBeDefined()
    expect(entries[0].preview.length).toBeLessThanOrEqual(100)
  })
})
```

- [ ] **Step 2: Run test to verify it passes (validates the pattern)**

Run: `npm test -- tests/integration/timeline.test.ts`
Expected: Pass — this validates the timeline construction logic before we wire it into the API.

- [ ] **Step 3: Add timeline endpoint in web.ts**

In `src/web.ts`, after the `GET /api/sessions/:id` endpoint (around line 176-182), add:

```typescript
// Session timeline for replay
app.get('/api/sessions/:id/timeline', async (c) => {
  const session = db.getSession(c.req.param('id'))
  if (!session) return c.json({ error: 'Session not found' }, 404)

  const adapter = opts?.adapters?.find(a => a.name === session.source)
  if (!adapter) return c.json({ error: `No adapter for source: ${session.source}` }, 500)

  const entries: Array<{
    index: number
    timestamp: string | undefined
    role: string
    type: string
    preview: string
    toolName?: string
    durationToNextMs?: number
    tokens?: { input: number; output: number }
  }> = []

  try {
    let idx = 0
    let prevTimestamp: string | undefined
    for await (const msg of adapter.streamMessages(session.filePath)) {
      const entry: typeof entries[0] = {
        index: idx,
        timestamp: msg.timestamp,
        role: msg.role,
        type: msg.toolCalls?.length ? 'tool_use' : 'message',
        preview: msg.content.slice(0, 100),
      }
      if (msg.toolCalls?.length) {
        entry.toolName = msg.toolCalls[0].name
      }
      if (msg.usage) {
        entry.tokens = {
          input: msg.usage.inputTokens,
          output: msg.usage.outputTokens,
        }
      }
      // Compute gap to previous entry
      if (prevTimestamp && msg.timestamp) {
        const gap = new Date(msg.timestamp).getTime() - new Date(prevTimestamp).getTime()
        if (entries.length > 0) entries[entries.length - 1].durationToNextMs = gap
      }
      prevTimestamp = msg.timestamp
      entries.push(entry)
      idx++
    }
  } catch (err) {
    return c.json({ error: `Failed to read session: ${err}` }, 500)
  }

  return c.json({
    sessionId: session.id,
    source: session.source,
    totalEntries: entries.length,
    entries,
  })
})
```

- [ ] **Step 4: Verify build**

Run: `npm run build`
Expected: Clean compile.

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/web.ts tests/integration/timeline.test.ts
git commit -m "feat: add GET /api/sessions/:id/timeline endpoint for session replay"
```

---

### Task 4: Swift — DaemonClient Extensions

**Files:**
- Modify: `macos/Engram/Core/DaemonClient.swift`

- [ ] **Step 1: Add `post()` method and response types**

In `DaemonClient.swift`, after the existing `fetch()` method (around line 22), add a generic POST method and the response types:

```swift
func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
    let url = URL(string: "\(baseURL)\(path)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
        throw DaemonClientError.httpError(
            (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }
    return try JSONDecoder().decode(T.self, from: data)
}
```

After the `MARK: - API Response Types` section, add:

```swift
// MARK: - Handoff Types

struct HandoffRequest: Encodable {
    let cwd: String
    var sessionId: String?
    var format: String?
}

struct HandoffResponse: Decodable {
    let brief: String
    let sessionCount: Int
}

// MARK: - Timeline Types

struct TimelineEntry: Decodable, Identifiable {
    var id: Int { index }
    let index: Int
    let timestamp: String?
    let role: String
    let type: String
    let preview: String
    let toolName: String?
    let durationToNextMs: Int?
    let tokens: TimelineTokens?
}

struct TimelineTokens: Decodable {
    let input: Int
    let output: Int
}

struct TimelineResponse: Decodable {
    let sessionId: String
    let source: String
    let totalEntries: Int
    let entries: [TimelineEntry]
}
```

- [ ] **Step 2: Verify Xcode build**

Run from `macos/`:
```bash
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Core/DaemonClient.swift
git commit -m "feat: add post() method, HandoffResponse, and TimelineResponse to DaemonClient"
```

---

### Task 5: Swift — Handoff Button in SessionDetailView

**Files:**
- Modify: `macos/Engram/Views/Transcript/TranscriptToolbar.swift`
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Add handoff callback to TranscriptToolbar**

In `TranscriptToolbar.swift`, add a new callback property after the existing ones (around line 23, after `onNavNext`):

```swift
var onHandoff: (() -> Void)? = nil
```

In the toolbar `body` HStack, after the existing copy button and before `Spacer()` or the view mode picker, add:

```swift
if let onHandoff {
    Button(action: onHandoff) {
        Image(systemName: "arrow.right.doc.on.clipboard")
            .font(.system(size: 13))
    }
    .buttonStyle(.plain)
    .help("Generate handoff brief and copy to clipboard")
}
```

- [ ] **Step 2: Wire handoff action in SessionDetailView**

In `SessionDetailView.swift`, add a state variable for handoff (around line 17, after `isSummarizing`):

```swift
@State private var handoffToast: String? = nil
```

In the `TranscriptToolbar(...)` call (around line 58-80), add the `onHandoff` parameter:

```swift
onHandoff: { Task { await performHandoff() } }
```

Add the `performHandoff()` method to `SessionDetailView` (after `generateSummary()`):

```swift
func performHandoff() async {
    guard let port = indexer.port else { return }
    let url = URL(string: "http://127.0.0.1:\(port)/api/handoff")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10

    let payload: [String: String] = [
        "cwd": session.cwd,
        "sessionId": session.id,
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let brief = json["brief"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brief, forType: .string)
            handoffToast = "Brief copied to clipboard"
            // Auto-dismiss toast
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                handoffToast = nil
            }
        }
    } catch {
        // silently fail
    }
}
```

Add a toast overlay at the bottom of the `VStack` in `body` (just before `.background`):

```swift
.overlay(alignment: .bottom) {
    if let toast = handoffToast {
        Text(toast)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut, value: handoffToast)
    }
}
```

- [ ] **Step 3: Verify Xcode build**

Run from `macos/`:
```bash
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Transcript/TranscriptToolbar.swift macos/Engram/Views/SessionDetailView.swift
git commit -m "feat: add handoff button to session toolbar — generates brief and copies to clipboard"
```

---

### Task 6: Swift — ReplayState Model

**Files:**
- Create: `macos/Engram/Models/ReplayState.swift`

- [ ] **Step 1: Create the replay state machine**

Create `macos/Engram/Models/ReplayState.swift`:

```swift
// macos/Engram/Models/ReplayState.swift
import Foundation

enum ReplayStatus: Equatable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case done
    case error(String)
}

@Observable
class ReplayState {
    var entries: [TimelineEntry] = []
    var currentIndex: Int = 0
    var isPlaying: Bool = false
    var playbackSpeed: Double = 1.0
    var status: ReplayStatus = .idle

    private var playTask: Task<Void, Never>?
    private var daemonPort: Int

    init(port: Int = 3457) {
        self.daemonPort = port
    }

    var currentEntry: TimelineEntry? {
        guard currentIndex >= 0 && currentIndex < entries.count else { return nil }
        return entries[currentIndex]
    }

    var progress: Double {
        guard entries.count > 1 else { return 0 }
        return Double(currentIndex) / Double(entries.count - 1)
    }

    var elapsedTime: String {
        guard let first = entries.first?.timestamp,
              let current = currentEntry?.timestamp,
              let start = parseISO(first),
              let now = parseISO(current) else { return "0:00" }
        let seconds = Int(now.timeIntervalSince(start))
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    var totalTime: String {
        guard let first = entries.first?.timestamp,
              let last = entries.last?.timestamp,
              let start = parseISO(first),
              let end = parseISO(last) else { return "0:00" }
        let seconds = Int(end.timeIntervalSince(start))
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Actions

    func load(sessionId: String) async {
        status = .loading
        entries = []
        currentIndex = 0

        do {
            let url = URL(string: "http://127.0.0.1:\(daemonPort)/api/sessions/\(sessionId)/timeline")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                status = .error("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            let decoded = try JSONDecoder().decode(TimelineResponse.self, from: data)
            entries = decoded.entries
            status = entries.isEmpty ? .done : .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func play() {
        guard status == .ready || status == .paused else { return }
        isPlaying = true
        status = .playing

        playTask = Task { @MainActor in
            while isPlaying && currentIndex < entries.count - 1 {
                let delay: UInt64
                if let durationMs = entries[currentIndex].durationToNextMs, durationMs > 0 {
                    // Scale by playback speed, cap at 3 seconds real-time
                    let scaled = min(Double(durationMs) / playbackSpeed, 3000)
                    delay = UInt64(scaled * 1_000_000) // ms to ns
                } else {
                    delay = UInt64(500_000_000 / playbackSpeed) // 500ms default
                }

                try? await Task.sleep(nanoseconds: delay)
                guard isPlaying else { break }
                currentIndex += 1
            }

            if currentIndex >= entries.count - 1 {
                status = .done
            } else {
                status = .paused
            }
            isPlaying = false
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
        if status == .playing { status = .paused }
    }

    func stepForward() {
        pause()
        if currentIndex < entries.count - 1 {
            currentIndex += 1
            status = .ready
        }
    }

    func stepBackward() {
        pause()
        if currentIndex > 0 {
            currentIndex -= 1
            status = .ready
        }
    }

    func seekTo(index: Int) {
        pause()
        currentIndex = max(0, min(index, entries.count - 1))
        status = currentIndex >= entries.count - 1 ? .done : .ready
    }

    func seekToFraction(_ fraction: CGFloat) {
        let index = Int(fraction * CGFloat(entries.count - 1))
        seekTo(index: index)
    }

    // MARK: - Helpers

    private func parseISO(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }
}
```

- [ ] **Step 2: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Models/ReplayState.swift macos/project.yml
git commit -m "feat: add ReplayState observable model with state machine for session replay"
```

---

### Task 7: Swift — SessionReplayView

**Files:**
- Create: `macos/Engram/Views/Replay/SessionReplayView.swift`

- [ ] **Step 1: Create the replay view**

Create directory `macos/Engram/Views/Replay/` if it does not exist, then create `SessionReplayView.swift`:

```swift
// macos/Engram/Views/Replay/SessionReplayView.swift
import SwiftUI

struct SessionReplayView: View {
    let sessionId: String
    let sessionSource: String

    @State private var state = ReplayState()

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Transport Controls
            HStack(spacing: 12) {
                // Step backward
                Button { state.stepBackward() } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(state.currentIndex <= 0)

                // Play / Pause
                Button {
                    if state.isPlaying {
                        state.pause()
                    } else if state.status == .done {
                        state.seekTo(index: 0)
                        state.play()
                    } else {
                        state.play()
                    }
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(state.status == .loading || state.status == .idle)

                // Step forward
                Button { state.stepForward() } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .disabled(state.currentIndex >= state.entries.count - 1)

                Divider().frame(height: 16)

                // Scrubber
                if state.entries.count > 1 {
                    Slider(
                        value: Binding(
                            get: { state.progress },
                            set: { state.seekToFraction($0) }
                        ),
                        in: 0...1
                    )
                    .frame(minWidth: 120)
                }

                Text("\(state.currentIndex + 1)/\(state.entries.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                Divider().frame(height: 16)

                // Speed control
                Menu {
                    ForEach([0.5, 1.0, 2.0, 4.0], id: \.self) { speed in
                        Button("\(speed, specifier: "%.1f")x") {
                            state.playbackSpeed = speed
                        }
                    }
                } label: {
                    Text("\(state.playbackSpeed, specifier: "%.1f")x")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Elapsed / Total
                Text("\(state.elapsedTime) / \(state.totalTime)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // MARK: - Content Area
            if state.status == .loading {
                ProgressView("Loading timeline...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.status == .idle {
                ContentUnavailableView {
                    Label("Session Replay", systemImage: "play.circle")
                } description: {
                    Text("Loading...")
                }
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let entry = state.currentEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // Entry header
                        HStack(spacing: 6) {
                            RoleBadge(role: entry.role, type: entry.type)
                            if let toolName = entry.toolName {
                                Text(toolName)
                                    .font(.system(size: 11, weight: .medium).monospaced())
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.purple.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            if let ts = entry.timestamp {
                                Text(String(ts.prefix(19)))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            if let tokens = entry.tokens {
                                Text("↓\(tokens.input) ↑\(tokens.output)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Message content
                        Text(entry.preview)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let durationMs = entry.durationToNextMs, durationMs > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9))
                                Text(formatDuration(durationMs))
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                        }
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableView {
                    Label("Empty Session", systemImage: "tray")
                } description: {
                    Text("This session has no messages to replay.")
                }
            }

            Divider()

            // MARK: - Density Bar
            if !state.entries.isEmpty {
                DensityBar(entries: state.entries, currentIndex: state.currentIndex) { index in
                    state.seekTo(index: index)
                }
                .frame(height: 24)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
        }
        .task {
            await state.load(sessionId: sessionId)
        }
    }

    private var errorMessage: String? {
        if case .error(let msg) = state.status { return msg }
        return nil
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}

// MARK: - Role Badge

struct RoleBadge: View {
    let role: String
    let type: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    private var label: String {
        switch role {
        case "user": return "USER"
        case "assistant": return type == "tool_use" ? "TOOL" : "ASSISTANT"
        case "system": return "SYSTEM"
        case "tool": return "RESULT"
        default: return role.uppercased()
        }
    }

    private var color: Color {
        switch role {
        case "user": return .blue
        case "assistant": return type == "tool_use" ? .purple : .green
        case "system": return .gray
        case "tool": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Density Bar

struct DensityBar: View {
    let entries: [TimelineEntry]
    let currentIndex: Int
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.1))

                // Entry blocks
                ForEach(entries) { entry in
                    let x = geo.size.width * CGFloat(entry.index) / CGFloat(max(entries.count - 1, 1))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: entry))
                        .frame(width: max(2, geo.size.width / CGFloat(entries.count)), height: barHeight(for: entry))
                        .position(x: x, y: geo.size.height / 2)
                }

                // Current position indicator
                if !entries.isEmpty {
                    let x = geo.size.width * CGFloat(currentIndex) / CGFloat(max(entries.count - 1, 1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: geo.size.height)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let fraction = location.x / geo.size.width
                let index = Int(fraction * CGFloat(entries.count - 1))
                onSeek(max(0, min(index, entries.count - 1)))
            }
        }
    }

    private func barColor(for entry: TimelineEntry) -> Color {
        switch entry.role {
        case "user": return .blue.opacity(0.5)
        case "assistant": return entry.type == "tool_use" ? .purple.opacity(0.5) : .green.opacity(0.5)
        case "tool": return .orange.opacity(0.5)
        default: return .gray.opacity(0.3)
        }
    }

    private func barHeight(for entry: TimelineEntry) -> CGFloat {
        // Scale height by content length (preview is capped at 100 chars)
        let base: CGFloat = 8
        let scale = CGFloat(entry.preview.count) / 100.0
        return base + scale * 12
    }
}
```

- [ ] **Step 2: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Views/Replay/SessionReplayView.swift macos/project.yml
git commit -m "feat: add SessionReplayView with transport controls and density bar"
```

---

### Task 8: Swift — Replay Button in SessionDetailView

**Files:**
- Modify: `macos/Engram/Views/Transcript/TranscriptToolbar.swift`
- Modify: `macos/Engram/Views/SessionDetailView.swift`

- [ ] **Step 1: Add replay callback to TranscriptToolbar**

In `TranscriptToolbar.swift`, after the `onHandoff` property:

```swift
var onReplay: (() -> Void)? = nil
```

In the toolbar HStack, next to the handoff button:

```swift
if let onReplay {
    Button(action: onReplay) {
        Image(systemName: "play.circle")
            .font(.system(size: 13))
    }
    .buttonStyle(.plain)
    .help("Replay session timeline")
}
```

- [ ] **Step 2: Wire replay navigation in SessionDetailView**

In `SessionDetailView.swift`, add state:

```swift
@State private var showReplay = false
```

In the `TranscriptToolbar(...)` call, add:

```swift
onReplay: { showReplay = true }
```

Wrap the existing `VStack` body in a conditional or use `.sheet`:

At the top of `body`, replace the outer `VStack` with:

```swift
var body: some View {
    VStack(spacing: 0) {
        if showReplay {
            // Replay mode
            HStack(spacing: 8) {
                Button {
                    showReplay = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to Transcript")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(12)
                Spacer()
            }
            SessionReplayView(sessionId: session.id, sessionSource: session.source)
        } else {
            // Normal transcript view (existing code)
            transcriptContent
        }
    }
    // ... existing modifiers
}
```

Extract the existing transcript body into a computed property:

```swift
@ViewBuilder
private var transcriptContent: some View {
    TranscriptToolbar(
        // ... existing parameters ...
        onHandoff: { Task { await performHandoff() } },
        onReplay: { showReplay = true }
    )
    // ... rest of existing body content ...
}
```

**Implementation note:** The exact refactoring depends on the current structure. The key is: when `showReplay` is true, show `SessionReplayView` with a back button. When false, show the existing transcript. This avoids adding a new `Screen` enum case — replay is a local navigation state within the detail view.

- [ ] **Step 3: Verify Xcode build**

```bash
cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/Transcript/TranscriptToolbar.swift macos/Engram/Views/SessionDetailView.swift
git commit -m "feat: add replay button to session toolbar with inline replay mode"
```

---

### Task 9: Swift — PaletteItem Model

**Files:**
- Create: `macos/Engram/Models/PaletteItem.swift`

- [ ] **Step 1: Create the palette item model**

Create `macos/Engram/Models/PaletteItem.swift`:

```swift
// macos/Engram/Models/PaletteItem.swift
import SwiftUI

enum PaletteCategory: String, CaseIterable {
    case navigation = "Navigation"
    case action = "Actions"
    case session = "Sessions"
}

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String           // SF Symbol name
    let category: PaletteCategory
    let shortcut: String?      // e.g. "⌘1", "⌘R"
    let action: () -> Void

    // Navigation commands — one per Screen case
    static func navigationCommands(onNavigate: @escaping (Screen) -> Void) -> [PaletteItem] {
        Screen.allCases.map { screen in
            PaletteItem(
                id: "nav-\(screen.rawValue)",
                title: "Go to \(screen.title)",
                subtitle: nil,
                icon: screen.icon,
                category: .navigation,
                shortcut: nil,
                action: { onNavigate(screen) }
            )
        }
    }

    // Action commands
    static func actionCommands(
        onRefresh: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) -> [PaletteItem] {
        [
            PaletteItem(
                id: "action-refresh",
                title: "Refresh Index",
                subtitle: "Re-index all session sources",
                icon: "arrow.clockwise",
                category: .action,
                shortcut: "⌘R",
                action: onRefresh
            ),
            PaletteItem(
                id: "action-settings",
                title: "Open Settings",
                subtitle: nil,
                icon: "gear",
                category: .action,
                shortcut: "⌘,",
                action: onSettings
            ),
        ]
    }

    // Convert search results to palette items
    static func fromSearchHit(
        id: String,
        title: String,
        source: String,
        snippet: String,
        date: String,
        onSelect: @escaping () -> Void
    ) -> PaletteItem {
        PaletteItem(
            id: "session-\(id)",
            title: title,
            subtitle: "[\(source)] \(snippet)",
            icon: iconForSource(source),
            category: .session,
            shortcut: nil,
            action: onSelect
        )
    }

    private static func iconForSource(_ source: String) -> String {
        switch source {
        case "claude-code": return "brain"
        case "codex":       return "terminal"
        case "cursor":      return "cursorarrow.rays"
        case "gemini-cli":  return "sparkle"
        case "copilot":     return "person.2"
        default:            return "bubble.left.and.bubble.right"
        }
    }
}
```

- [ ] **Step 2: Run xcodegen and verify build**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add macos/Engram/Models/PaletteItem.swift macos/project.yml
git commit -m "feat: add PaletteItem model with navigation, action, and session categories"
```

---

### Task 10: Swift — Command Palette (Refactor GlobalSearchOverlay)

**Files:**
- Modify: `macos/Engram/Views/GlobalSearchOverlay.swift` (rename content to CommandPalette)

- [ ] **Step 1: Refactor GlobalSearchOverlay to CommandPalette**

Replace the contents of `macos/Engram/Views/GlobalSearchOverlay.swift` with the command palette implementation. The file stays at the same path to avoid breaking references, but the struct is renamed to `CommandPalette`:

```swift
// macos/Engram/Views/CommandPalette.swift (was GlobalSearchOverlay.swift)
import SwiftUI

struct CommandPalette: View {
    @Binding var isVisible: Bool
    @EnvironmentObject var indexer: IndexerProcess
    @State private var query = ""
    @State private var staticItems: [PaletteItem] = []
    @State private var sessionItems: [PaletteItem] = []
    @State private var isSearching = false
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    let onSelectSession: (String) -> Void
    let onNavigate: (Screen) -> Void

    private var filteredItems: [PaletteItem] {
        if query.isEmpty {
            return staticItems
        }
        let q = query.lowercased()
        let matchingCommands = staticItems.filter {
            $0.title.lowercased().contains(q)
        }
        return matchingCommands + sessionItems
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Type a command or search sessions...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .onSubmit { executeSelected() }
                    .onChange(of: query) { _, newValue in
                        selectedIndex = 0
                        if newValue.count >= 2 {
                            searchSessions(query: newValue)
                        } else {
                            sessionItems = []
                        }
                    }
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Text("⌘K")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Button { isVisible = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            if !filteredItems.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Group by category
                            let grouped = Dictionary(grouping: filteredItems, by: { $0.category })
                            let order: [PaletteCategory] = [.navigation, .action, .session]

                            ForEach(order, id: \.self) { category in
                                if let items = grouped[category], !items.isEmpty {
                                    Text(category.rawValue.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 8)
                                        .padding(.bottom, 2)

                                    ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                                        let globalIndex = filteredItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                        Button {
                                            item.action()
                                            isVisible = false
                                        } label: {
                                            HStack(spacing: 8) {
                                                Image(systemName: item.icon)
                                                    .frame(width: 20)
                                                    .foregroundStyle(
                                                        item.category == .session ? .purple : .secondary
                                                    )
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(item.title)
                                                        .font(.system(size: 13, weight: .medium))
                                                    if let subtitle = item.subtitle {
                                                        Text(subtitle)
                                                            .font(.system(size: 11))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer()
                                                if let shortcut = item.shortcut {
                                                    Text(shortcut)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                globalIndex == selectedIndex
                                                    ? Color.accentColor.opacity(0.1)
                                                    : Color.clear
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .id(item.id)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if newIndex < filteredItems.count {
                            proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.15), radius: 10)
        .padding(.horizontal, 40)
        .padding(.top, 4)
        .onAppear {
            isFocused = true
            buildStaticItems()
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            executeSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            isVisible = false
            return .handled
        }
    }

    // MARK: - Private

    private func buildStaticItems() {
        staticItems = PaletteItem.navigationCommands(onNavigate: { screen in
            onNavigate(screen)
            isVisible = false
        }) + PaletteItem.actionCommands(
            onRefresh: {
                // Trigger reindex via daemon
                if let port = indexer.port {
                    Task {
                        let url = URL(string: "http://127.0.0.1:\(port)/api/reindex")!
                        _ = try? await URLSession.shared.data(from: url)
                    }
                }
            },
            onSettings: {
                onNavigate(.settings)
            }
        )
    }

    private func executeSelected() {
        guard selectedIndex < filteredItems.count else { return }
        filteredItems[selectedIndex].action()
        isVisible = false
    }

    private func searchSessions(query: String) {
        guard let port = indexer.port else { return }
        isSearching = true
        Task {
            do {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let url = URL(string: "http://127.0.0.1:\(port)/api/search?q=\(encoded)&limit=8")!
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rawResults = json["results"] as? [[String: Any]] {
                    sessionItems = rawResults.compactMap { r in
                        guard let session = r["session"] as? [String: Any],
                              let id = session["id"] as? String else { return nil }
                        let title = (session["summary"] as? String)
                            ?? (session["project"] as? String)
                            ?? "Untitled"
                        let source = (session["source"] as? String) ?? ""
                        let snippet = (r["snippet"] as? String) ?? ""
                        let date = (session["startTime"] as? String)
                            .map { String($0.prefix(10)) } ?? ""
                        return PaletteItem.fromSearchHit(
                            id: id,
                            title: title,
                            source: source,
                            snippet: snippet.isEmpty ? date : snippet,
                            date: date,
                            onSelect: {
                                onSelectSession(id)
                                isVisible = false
                            }
                        )
                    }
                }
            } catch {
                // silently fail
            }
            isSearching = false
        }
    }
}

// MARK: - Backward Compatibility

typealias GlobalSearchOverlay = CommandPalette
```

Note the `typealias GlobalSearchOverlay = CommandPalette` at the bottom — this preserves backward compatibility with any caller that still references the old name. The file should be renamed to `CommandPalette.swift` but only after updating all references.

- [ ] **Step 2: Update all references from GlobalSearchOverlay to CommandPalette**

Search the codebase for `GlobalSearchOverlay` usage. Each call site must be updated to use `CommandPalette` and pass the new `onNavigate` parameter.

The typical call site pattern:

```swift
// Old:
GlobalSearchOverlay(isVisible: $showSearch, onSelectSession: { id in ... })

// New:
CommandPalette(
    isVisible: $showSearch,
    onSelectSession: { id in ... },
    onNavigate: { screen in selectedScreen = screen }
)
```

Find and update all call sites. The `typealias` provides a safety net during migration, but explicit updates are preferred.

- [ ] **Step 3: Rename file**

```bash
cd macos && git mv Engram/Views/GlobalSearchOverlay.swift Engram/Views/CommandPalette.swift
```

Then run `xcodegen generate` to update the project.

- [ ] **Step 4: Verify Xcode build**

```bash
cd macos && xcodegen generate && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add macos/Engram/Views/CommandPalette.swift macos/project.yml
git add -u  # catch the deletion of GlobalSearchOverlay.swift
git commit -m "feat: refactor GlobalSearchOverlay into CommandPalette with mixed commands and session search"
```

---

### Task 11: TypeScript Tests — Full Integration Verification

**Files:**
- Run all tests

- [ ] **Step 1: Run full TypeScript test suite**

Run: `npm test`
Expected: All tests pass (existing + new handoff + timeline tests).

- [ ] **Step 2: Verify build**

Run: `npm run build`
Expected: Clean compile, no errors.

- [ ] **Step 3: Verify MCP tool list includes handoff**

Run: `node -e "const {handoffTool} = require('./dist/tools/handoff.js'); console.log(JSON.stringify(handoffTool, null, 2))"`
Expected: Prints the handoff tool schema with `name: 'handoff'`, `required: ['cwd']`.

- [ ] **Step 4: Verify API endpoints respond**

Start daemon in background, then test:
```bash
# Start daemon
node dist/daemon.js &
DAEMON_PID=$!
sleep 2

# Test handoff endpoint
curl -s -X POST http://127.0.0.1:3457/api/handoff -H 'Content-Type: application/json' -d '{"cwd":"/tmp/test"}' | jq .

# Test timeline endpoint (replace SESSION_ID with a real one)
curl -s http://127.0.0.1:3457/api/sessions/test/timeline | jq .

kill $DAEMON_PID
```
Expected: Handoff returns `{ brief: "...", sessionCount: 0 }` for unknown project. Timeline returns 404 for unknown session.

- [ ] **Step 5: Commit (if any fixes needed)**

```bash
git add -A
git commit -m "fix: integration test adjustments for Phase 2 features"
```

---

### Task 12: Xcode Full Build Verification

**Files:**
- All Swift files from Tasks 4-10

- [ ] **Step 1: Regenerate Xcode project**

```bash
cd macos && xcodegen generate
```

- [ ] **Step 2: Full build**

```bash
xcodebuild -project macos/Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Launch and verify**

Launch from DerivedData:
```bash
open ~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/Debug/Engram.app
```

Verify:
1. Press ⌘K — command palette opens with navigation commands
2. Type "Go to" — navigation commands filter
3. Type "auth" or any keyword (>2 chars) — session search results appear below commands
4. Open a session detail — handoff button (clipboard icon) visible in toolbar
5. Click handoff button — toast shows "Brief copied to clipboard"
6. Replay button (play.circle icon) visible in toolbar
7. Click replay — timeline loads, transport controls functional

- [ ] **Step 4: Commit project.yml if changed**

```bash
git add macos/project.yml
git commit -m "chore: update project.yml for Phase 2 Swift files"
```

---

## Verification Checklist

After all tasks complete:

- [ ] `npm test` — all tests pass (existing + new handoff + timeline tests)
- [ ] `npm run build` — clean compile
- [ ] New MCP tool appears in `ListToolsRequestSchema` response: `handoff`
- [ ] `POST /api/handoff` with `{ "cwd": "/path/to/project" }` returns brief with session count
- [ ] `POST /api/handoff` with `{ "cwd": "/path/to/project", "sessionId": "..." }` returns single-session brief
- [ ] `GET /api/sessions/:id/timeline` returns `TimelineResponse` with entries array
- [ ] `GET /api/sessions/nonexistent/timeline` returns 404
- [ ] Xcode builds cleanly with `xcodebuild -configuration Debug`
- [ ] ⌘K opens command palette with navigation commands + dynamic session search
- [ ] Handoff button in session toolbar copies brief to clipboard
- [ ] Replay button opens inline replay view with transport controls
- [ ] Replay density bar shows message distribution and responds to clicks
- [ ] Replay play/pause/step/seek controls work correctly
- [ ] Speed control (0.5x, 1x, 2x, 4x) affects playback timing
- [ ] `typealias GlobalSearchOverlay = CommandPalette` preserves backward compat during migration
