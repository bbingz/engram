# Popover 项目标签 + 索引健康度 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add project name tags to popover session list and build an index health dashboard (popover summary + Web UI detail page).

**Architecture:** Feature 1 is a pure SwiftUI layout change in `PopoverView.swift`. Feature 2 adds a `getSourceStats()` DB method, a `/api/health/sources` API endpoint, a `/health` Web UI page, and a popover health summary row in Swift.

**Tech Stack:** Swift 5.9 (SwiftUI, GRDB), TypeScript (Hono, better-sqlite3), Vitest, HTML/CSS

**Spec:** `docs/superpowers/specs/2026-03-17-popover-project-tag-and-health-dashboard.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `macos/Engram/Views/PopoverView.swift` | Modify | Rearrange `timelineRow()` layout; add health summary row |
| `src/core/db.ts` | Modify | Add `getSourceStats()` method |
| `src/web.ts` | Modify | Add `GET /api/health/sources` endpoint and `/health` HTML route |
| `src/web/views.ts` | Modify | Add `healthPage()` render function |
| `macos/Engram/Core/Database.swift` | Modify | Add `sourceStats()` read-only query |
| `tests/core/db-health.test.ts` | Create | Tests for `getSourceStats()` |

---

## Chunk 1: Popover 项目标签 (Swift only)

### Task 1: Rearrange timelineRow layout

**Files:**
- Modify: `macos/Engram/Views/PopoverView.swift:114-136`

- [ ] **Step 1: Modify `timelineRow()` — replace source label with project name, move source to right**

Change the existing `timelineRow` method from:

```swift
private func timelineRow(_ session: Session) -> some View {
    HStack(spacing: 6) {
        Circle()
            .fill(SourceDisplay.color(for: session.source))
            .frame(width: 4, height: 4)
        Text(SourceDisplay.label(for: session.source))
            .font(.caption2)
            .foregroundStyle(SourceDisplay.color(for: session.source))
            .frame(width: 58, alignment: .leading)
        Text(session.displayTitle)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer()
        Text(relativeTime(session.startTime))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
        NotificationCenter.default.post(name: .openWindow, object: SessionBox(session))
    }
}
```

To:

```swift
private func timelineRow(_ session: Session) -> some View {
    HStack(spacing: 6) {
        Circle()
            .fill(SourceDisplay.color(for: session.source))
            .frame(width: 4, height: 4)
        Text(session.project ?? "—")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.tail)
        Text(session.displayTitle)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer()
        Text(SourceDisplay.label(for: session.source))
            .font(.caption2)
            .foregroundStyle(SourceDisplay.color(for: session.source))
        Text(relativeTime(session.startTime))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
        NotificationCenter.default.post(name: .openWindow, object: SessionBox(session))
    }
}
```

- [ ] **Step 2: Build macOS app to verify**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Visual check**

Launch Engram from DerivedData, open popover, verify:
- Project name on left (truncated if long)
- Source label on right with color
- Time on far right
- Sessions without project show `—`

- [ ] **Step 4: Commit**

```bash
git add macos/Engram/Views/PopoverView.swift
git commit -m "feat(popover): show project name on left, move source label to right"
```

---

## Chunk 2: Backend — getSourceStats + Health API

### Task 2: Add `getSourceStats()` to Database

**Files:**
- Modify: `src/core/db.ts`
- Create: `tests/core/db-health.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// tests/core/db-health.test.ts
import { describe, it, expect, afterEach } from 'vitest'
import { mkdtempSync, rmSync } from 'fs'
import { join } from 'path'
import { tmpdir } from 'os'
import { Database } from '../../src/core/db.js'

describe('getSourceStats', () => {
  let db: Database
  let tmpDir: string

  afterEach(() => { db?.close(); if (tmpDir) rmSync(tmpDir, { recursive: true }) })

  it('returns per-source stats with daily counts', () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'db-health-'))
    db = new Database(join(tmpDir, 'test.sqlite'))

    // Insert sessions across different sources and days
    const now = new Date()
    const today = now.toISOString()
    const yesterday = new Date(now.getTime() - 86400000).toISOString()
    const weekAgo = new Date(now.getTime() - 7 * 86400000).toISOString()

    db.upsertSession({
      id: 's1', source: 'claude-code', filePath: '/tmp/s1', cwd: '/tmp',
      startTime: today, messageCount: 5, userMessageCount: 3,
      assistantMessageCount: 2, toolMessageCount: 0, systemMessageCount: 0,
      sizeBytes: 100,
    } as any)
    db.upsertSession({
      id: 's2', source: 'claude-code', filePath: '/tmp/s2', cwd: '/tmp',
      startTime: yesterday, messageCount: 3, userMessageCount: 2,
      assistantMessageCount: 1, toolMessageCount: 0, systemMessageCount: 0,
      sizeBytes: 80,
    } as any)
    db.upsertSession({
      id: 's3', source: 'codex', filePath: '/tmp/s3', cwd: '/tmp',
      startTime: weekAgo, messageCount: 2, userMessageCount: 1,
      assistantMessageCount: 1, toolMessageCount: 0, systemMessageCount: 0,
      sizeBytes: 50,
    } as any)

    const stats = db.getSourceStats()
    expect(stats).toHaveLength(2)

    const claude = stats.find(s => s.source === 'claude-code')!
    expect(claude.sessionCount).toBe(2)
    expect(claude.latestIndexed).toBeDefined()
    expect(claude.dailyCounts).toHaveLength(7)

    const codex = stats.find(s => s.source === 'codex')!
    expect(codex.sessionCount).toBe(1)
  })

  it('returns empty array when no sessions', () => {
    tmpDir = mkdtempSync(join(tmpdir(), 'db-health-'))
    db = new Database(join(tmpDir, 'test.sqlite'))
    expect(db.getSourceStats()).toEqual([])
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/core/db-health.test.ts`
Expected: FAIL — `db.getSourceStats is not a function`

- [ ] **Step 3: Implement `getSourceStats()`**

Add to `src/core/db.ts` after the `listSources()` method:

```typescript
  getSourceStats(): { source: string; sessionCount: number; latestIndexed: string; dailyCounts: number[] }[] {
    // Per-source aggregate
    const sourceRows = this.db.prepare(`
      SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
      FROM sessions WHERE hidden_at IS NULL
      GROUP BY source ORDER BY count DESC
    `).all() as { source: string; count: number; latest_indexed: string }[]

    if (sourceRows.length === 0) return []

    // 7-day daily counts per source
    const dailyRows = this.db.prepare(`
      SELECT source, date(start_time) as day, COUNT(*) as count
      FROM sessions
      WHERE hidden_at IS NULL AND start_time >= date('now', '-7 days')
      GROUP BY source, date(start_time)
    `).all() as { source: string; day: string; count: number }[]

    // Build date range for last 7 days
    const days: string[] = []
    for (let i = 6; i >= 0; i--) {
      const d = new Date(Date.now() - i * 86400000)
      days.push(d.toISOString().slice(0, 10))
    }

    // Index daily counts by source
    const dailyMap = new Map<string, Map<string, number>>()
    for (const row of dailyRows) {
      if (!dailyMap.has(row.source)) dailyMap.set(row.source, new Map())
      dailyMap.get(row.source)!.set(row.day, row.count)
    }

    return sourceRows.map(row => ({
      source: row.source,
      sessionCount: row.count,
      latestIndexed: row.latest_indexed ?? '',
      dailyCounts: days.map(d => dailyMap.get(row.source)?.get(d) ?? 0),
    }))
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/core/db-health.test.ts`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/core/db.ts tests/core/db-health.test.ts
git commit -m "feat(db): add getSourceStats() for index health dashboard"
```

---

### Task 3: Add `/api/health/sources` endpoint and `/health` page

**Files:**
- Modify: `src/web.ts`
- Modify: `src/web/views.ts`

- [ ] **Step 1: Add `SOURCE_PATHS` map and `/api/health/sources` endpoint to `src/web.ts`**

Add imports at top:

```typescript
import { existsSync } from 'fs'
import { join } from 'path'
import { homedir } from 'os'
import { WATCHED_SOURCES } from './core/watcher.js'
```

Add before the UUID lookup redirect section:

```typescript
  // Source path map (matches watcher.ts watchEntries and macOS dataSources)
  const HOME = homedir()
  const SOURCE_PATHS: Record<string, string> = {
    'claude-code': join(HOME, '.claude/projects'),
    'codex': join(HOME, '.codex/sessions'),
    'gemini-cli': join(HOME, '.gemini/tmp'),
    'opencode': join(HOME, '.local/share/opencode/opencode.db'),
    'iflow': join(HOME, '.iflow/projects'),
    'qwen': join(HOME, '.qwen/projects'),
    'kimi': join(HOME, '.kimi/sessions'),
    'cline': join(HOME, '.cline/data/tasks'),
    'cursor': join(HOME, 'Library/Application Support/Cursor/User/globalStorage/state.vscdb'),
    'vscode': join(HOME, 'Library/Application Support/Code/User/workspaceStorage'),
    'antigravity': join(HOME, '.gemini/antigravity/daemon'),
    'windsurf': join(HOME, '.codeium/windsurf/daemon'),
    'copilot': join(HOME, '.copilot/session-state'),
  }
  const DERIVED_SOURCES: Record<string, string> = {
    'lobsterai': 'claude-code',
    'minimax': 'claude-code',
  }

  app.get('/api/health/sources', async (c) => {
    const sourceStats = db.getSourceStats()

    const sources = sourceStats.map(s => {
      const derivedFrom = DERIVED_SOURCES[s.source]
      const path = SOURCE_PATHS[derivedFrom ?? s.source] ?? ''
      return {
        name: s.source,
        sessionCount: s.sessionCount,
        latestIndexed: s.latestIndexed,
        path: path.replace(HOME, '~'),
        pathExists: path ? existsSync(path) : false,
        watcherType: WATCHED_SOURCES.has(s.source) ? 'watching' : 'polling',
        derived: !!derivedFrom,
        derivedFrom: derivedFrom ?? null,
        dailyCounts: s.dailyCounts,
      }
    })

    // Viking status (if configured)
    let viking: Record<string, unknown> | null = null
    if (opts?.viking) {
      try {
        const available = await opts.viking.checkAvailable()
        if (available) {
          const queueRes = await fetch(`${(opts.viking as any).baseUrl}/api/v1/observer/queue`, {
            headers: { Authorization: `Bearer ${(opts.viking as any).headers?.Authorization?.replace('Bearer ', '') ?? ''}` },
            signal: AbortSignal.timeout(5000),
          }).then(r => r.json()).catch(() => null)
          const vlmRes = await fetch(`${(opts.viking as any).baseUrl}/api/v1/observer/vlm`, {
            headers: { Authorization: `Bearer ${(opts.viking as any).headers?.Authorization?.replace('Bearer ', '') ?? ''}` },
            signal: AbortSignal.timeout(5000),
          }).then(r => r.json()).catch(() => null)
          viking = { available: true, queue: queueRes?.result?.status ?? null, vlm: vlmRes?.result?.status ?? null }
        } else {
          viking = { available: false }
        }
      } catch { viking = { available: false } }
    }

    const now = Date.now()
    const oneDayMs = 24 * 60 * 60 * 1000
    const activeSources = sourceStats.filter(s => {
      const latest = new Date(s.latestIndexed).getTime()
      return now - latest < oneDayMs
    }).length

    return c.json({
      sources,
      viking,
      summary: {
        totalSources: sourceStats.length,
        activeSources,
        lastIndexed: sourceStats.length > 0
          ? sourceStats.reduce((a, b) => a.latestIndexed > b.latestIndexed ? a : b).latestIndexed
          : null,
      },
    })
  })
```

Note: Accessing `opts.viking` private fields (`baseUrl`, `headers`) — need to expose a getter. Add to `VikingBridge` class in `src/core/viking-bridge.ts`:

```typescript
  /** Base URL for direct API access (used by health dashboard) */
  get url(): string { return this.baseUrl; }
  get apiKey(): string { return this.headers['Authorization']?.replace('Bearer ', '') ?? ''; }
```

Then replace the `(opts.viking as any).baseUrl` casts with `opts.viking.url` and `opts.viking.apiKey`.

- [ ] **Step 2: Add `/health` HTML route**

In `src/web.ts`, add after the `/stats` HTML route:

```typescript
  app.get('/health', async (c) => {
    const healthRes = await fetch(`http://localhost:${settings.httpPort ?? 3457}/api/health/sources`)
    const healthData = await healthRes.json()
    return c.html(healthPage(healthData))
  })
```

- [ ] **Step 3: Add `healthPage()` to `src/web/views.ts`**

Add the `healthPage` export. This renders the source table with 7-day sparklines, diagnostics, and Viking status. The function receives the JSON from `/api/health/sources` and returns HTML string using the existing `layout()` wrapper.

```typescript
export function healthPage(data: any): string {
  const { sources, viking, summary } = data

  const rows = sources.map((s: any) => {
    const latestDate = new Date(s.latestIndexed)
    const ageMs = Date.now() - latestDate.getTime()
    const ageHours = ageMs / 3600000
    const status = ageHours < 24 ? '🟢' : ageHours < 168 ? '🟡' : '⚪'
    const statusLabel = ageHours < 24 ? 'Active' : ageHours < 168 ? 'Stale' : 'Inactive'
    const ago = ageHours < 1 ? `${Math.round(ageMs / 60000)}m ago`
      : ageHours < 24 ? `${Math.round(ageHours)}h ago`
      : `${Math.round(ageHours / 24)}d ago`

    const maxDaily = Math.max(...s.dailyCounts, 1)
    const sparkline = s.dailyCounts.map((c: number) => {
      const h = Math.round((c / maxDaily) * 20)
      return `<div style="width:8px;height:${h}px;background:var(--accent);border-radius:1px;"></div>`
    }).join('')

    const derived = s.derived ? `<span style="color:#888;font-size:11px;">(via ${s.derivedFrom})</span>` : ''

    return `<tr>
      <td><strong>${s.name}</strong> ${derived}</td>
      <td>${s.sessionCount}</td>
      <td>${ago}</td>
      <td><div style="display:flex;align-items:end;gap:2px;height:20px;">${sparkline}</div></td>
      <td>${status} ${statusLabel}</td>
      <td style="font-size:11px;color:#888;">${s.path || '—'} ${s.pathExists ? '✅' : '❌'}</td>
      <td style="font-size:11px;color:#888;">${s.watcherType}</td>
    </tr>`
  }).join('\n')

  const vikingSection = viking ? `
    <h3>OpenViking</h3>
    <p>${viking.available ? '🟢 Connected' : '🔴 Unreachable'}</p>
    ${viking.queue ? `<pre style="font-size:12px;overflow-x:auto;">${viking.queue}</pre>` : ''}
    ${viking.vlm ? `<pre style="font-size:12px;overflow-x:auto;">${viking.vlm}</pre>` : ''}
  ` : '<h3>OpenViking</h3><p>⚪ Not configured</p>'

  return layout('Index Health', `
    <h2>Index Health Dashboard</h2>
    <p style="color:#888;">${summary.activeSources}/${summary.totalSources} sources active · last indexed ${summary.lastIndexed ? new Date(summary.lastIndexed).toLocaleString() : 'never'}</p>

    <table style="width:100%;border-collapse:collapse;margin:20px 0;">
      <thead>
        <tr style="text-align:left;border-bottom:1px solid #333;">
          <th>Source</th><th>Sessions</th><th>Last Indexed</th><th>7-Day</th><th>Status</th><th>Path</th><th>Watcher</th>
        </tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>

    ${vikingSection}
  `)
}
```

- [ ] **Step 4: Add url/apiKey getters to VikingBridge**

In `src/core/viking-bridge.ts`, add public getters:

```typescript
  get url(): string { return this.baseUrl; }
  get apiKey(): string { return this.headers['Authorization']?.replace('Bearer ', '') ?? ''; }
```

- [ ] **Step 5: Build and verify**

Run: `npm run build`
Expected: Clean compile

- [ ] **Step 6: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add src/web.ts src/web/views.ts src/core/viking-bridge.ts
git commit -m "feat(web): add /api/health/sources endpoint and /health dashboard page"
```

---

## Chunk 3: Popover 健康摘要 (Swift)

### Task 4: Add health summary row to popover

**Files:**
- Modify: `macos/Engram/Views/PopoverView.swift`
- Modify: `macos/Engram/Core/Database.swift`

- [ ] **Step 1: Add `sourceStats()` to DatabaseManager**

In `macos/Engram/Core/Database.swift`, add a method to `DatabaseManager`:

```swift
    struct SourceStat {
        let source: String
        let count: Int
        let latestIndexed: String
    }

    nonisolated func sourceStats() throws -> [SourceStat] {
        try readInBackground { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
                FROM sessions WHERE hidden_at IS NULL
                GROUP BY source
            """)
            return rows.map { row in
                SourceStat(
                    source: row["source"],
                    count: row["count"],
                    latestIndexed: row["latest_indexed"] ?? ""
                )
            }
        }
    }
```

- [ ] **Step 2: Add health summary to PopoverView**

In `PopoverView.swift`, add state variables:

```swift
@State private var activeSourceCount: Int = 0
@State private var totalSourceCount: Int = 0
@State private var lastIndexedAgo: String = ""
```

Add a health summary view after `statsSection`:

```swift
    private var healthSummary: some View {
        HStack(spacing: 4) {
            Text("\(activeSourceCount)/\(totalSourceCount) sources active")
                .font(.caption2)
                .foregroundStyle(activeSourceCount == totalSourceCount ? .green : .secondary)
            Text("·")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("last \(lastIndexedAgo)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .onTapGesture {
            if let url = URL(string: "http://localhost:\(httpPort)/health") {
                NSWorkspace.shared.open(url)
            }
        }
    }
```

Insert `healthSummary` into the `body` after `statsSection`.

- [ ] **Step 3: Load health data in `loadData()`**

In the existing `loadData()` method, add after other data loading:

```swift
// Health summary
if let stats = try? db.sourceStats() {
    let now = Date()
    let oneDaySec: TimeInterval = 86400
    let active = stats.filter { stat in
        guard !stat.latestIndexed.isEmpty,
              let date = ISO8601DateFormatter().date(from: stat.latestIndexed) else { return false }
        return now.timeIntervalSince(date) < oneDaySec
    }.count

    let latest = stats.compactMap { stat -> Date? in
        guard !stat.latestIndexed.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: stat.latestIndexed)
    }.max()

    await MainActor.run {
        activeSourceCount = active
        totalSourceCount = stats.count
        if let latest {
            let interval = now.timeIntervalSince(latest)
            if interval < 60 { lastIndexedAgo = "now" }
            else if interval < 3600 { lastIndexedAgo = "\(Int(interval / 60))m" }
            else if interval < 86400 { lastIndexedAgo = "\(Int(interval / 3600))h" }
            else { lastIndexedAgo = "\(Int(interval / 86400))d" }
        }
    }
}
```

- [ ] **Step 4: Build macOS app**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Visual check**

Launch Engram, open popover, verify:
- Health summary row shows "X/Y sources active · last Zm"
- Clicking it opens Web UI `/health` page in browser

- [ ] **Step 6: Commit**

```bash
git add macos/Engram/Views/PopoverView.swift macos/Engram/Core/Database.swift
git commit -m "feat(popover): add index health summary row with source stats"
```

---

### Task 5: Final verification

- [ ] **Step 1: Full TypeScript build and tests**

Run: `npm run build && npm test`
Expected: Clean compile, all tests pass

- [ ] **Step 2: macOS build**

Run: `cd macos && xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: End-to-end check**

1. Launch Engram app
2. Popover: verify project tags and health summary
3. Click health summary → browser opens `/health`
4. Verify source table, sparklines, diagnostics, Viking status
