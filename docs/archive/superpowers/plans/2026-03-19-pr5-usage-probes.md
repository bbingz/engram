# PR5: Usage Probe System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collect AI tool usage/quota data (Claude, Codex) and display in Popover (compact, most-urgent) and main window Sources page (full detail).

**Architecture:** New `UsageProbe` interface in adapter layer, `UsageCollector` scheduler in daemon, `usage_snapshots` table in SQLite. Daemon emits `usage` events via stdout JSON. Swift reads DB + events to render progress bars. Phase 1: Claude (OAuth + tmux fallback) and Codex (tmux probe).

**Tech Stack:** TypeScript, SQLite, tmux (probe), OAuth (Claude), SwiftUI progress bars

**Spec:** `docs/superpowers/specs/2026-03-19-eight-prs-learning-from-agent-sessions-design.md` (PR5 section)

---

## File Structure

### New Files (Node)
| File | Responsibility |
|------|---------------|
| `src/core/usage-probe.ts` | UsageProbe interface + UsageSnapshot type |
| `src/core/usage-collector.ts` | Timer-based scheduler, calls probes, writes DB + emits events |
| `src/adapters/claude-usage-probe.ts` | Claude: OAuth API call, tmux fallback |
| `src/adapters/codex-usage-probe.ts` | Codex: tmux headless /status probe |
| `tests/usage-collector.test.ts` | Test collector scheduling and DB writes |

### New Files (Swift)
| File | Responsibility |
|------|---------------|
| `macos/Engram/Views/Usage/UsageBarView.swift` | Single usage bar: label + progress + percentage |
| `macos/Engram/Views/Usage/PopoverUsageSection.swift` | Popover usage section: compact (method B) with Show All toggle |

### Modified Files
| File | Changes |
|------|---------|
| `src/core/db.ts` | Add `usage_snapshots` table migration |
| `src/web.ts` | Add `GET /api/usage` endpoint |
| `src/daemon.ts` | Start UsageCollector after indexer ready |
| `macos/Engram/Core/IndexerProcess.swift` | Parse `usage` events from daemon stdout |
| `macos/Engram/Views/PopoverView.swift` | Add PopoverUsageSection at bottom |
| `macos/Engram/Views/Pages/SourcePulseView.swift` | Add full usage display (method A) |

---

## Task 1: UsageProbe Interface + DB Migration

- [ ] **Step 1: Create src/core/usage-probe.ts**

```typescript
export interface UsageSnapshot {
  source: string
  metric: string      // "opus_5h", "opus_weekly", "sonnet_5h", "spark_5h", "spark_weekly"
  value: number       // 0-100 percentage
  resetAt?: string    // ISO timestamp
  collectedAt: string
}

export interface UsageProbe {
  source: string
  interval: number    // ms between probes
  probe(): Promise<UsageSnapshot[]>
}
```

- [ ] **Step 2: Add migration in db.ts**

```typescript
// In migrate() function, add:
db.exec(`
  CREATE TABLE IF NOT EXISTS usage_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,
    metric TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT DEFAULT '%',
    reset_at TEXT,
    collected_at TEXT NOT NULL
  )
`)
db.exec(`CREATE INDEX IF NOT EXISTS idx_usage_latest ON usage_snapshots(source, metric, collected_at DESC)`)
```

- [ ] **Step 3: Add GET /api/usage endpoint in web.ts**

Return latest snapshot per (source, metric) pair.

- [ ] **Step 4: Tests + commit**

`git commit -m "feat(probes): add UsageProbe interface, DB migration, and API endpoint"`

---

## Task 2: Claude Usage Probe

- [ ] **Step 1: Create src/adapters/claude-usage-probe.ts**

OAuth path: read `~/.claude/credentials.json`, call usage API endpoint. Parse response into UsageSnapshot array (opus_5h, opus_weekly, sonnet_5h, spark_5h, spark_weekly).

Tmux fallback: if no OAuth token, spawn headless tmux session in `~/.engram/probes/claude/`, run `claude /usage`, parse text output. Clean up tmux session after.

- [ ] **Step 2: Tests with mocked responses**
- [ ] **Step 3: Commit**

`git commit -m "feat(probes): add Claude usage probe with OAuth + tmux fallback"`

---

## Task 3: Codex Usage Probe

- [ ] **Step 1: Create src/adapters/codex-usage-probe.ts**

Tmux probe: spawn headless session in `~/.engram/probes/codex/`, run `codex /status`, parse output for usage metrics.

- [ ] **Step 2: Tests + commit**

`git commit -m "feat(probes): add Codex usage probe via tmux"`

---

## Task 4: UsageCollector Scheduler

- [ ] **Step 1: Create src/core/usage-collector.ts**

Timer-based scheduler. For each registered probe, runs at its configured interval. Writes snapshots to DB. Emits `{ event: "usage", data: [...] }` to stdout. Graceful: probe failure → log warning, skip, retry next interval.

- [ ] **Step 2: Wire into daemon.ts**

Start collector after initial indexing is complete. Register Claude + Codex probes.

- [ ] **Step 3: Tests + commit**

`git commit -m "feat(probes): add UsageCollector scheduler and wire into daemon"`

---

## Task 5: Swift — Parse Usage Events

- [ ] **Step 1: Add usage event parsing in IndexerProcess.swift**

Parse `{ event: "usage", data: [...] }` events. Store latest values in `@Published var usageData: [UsageSnapshot]`.

- [ ] **Step 2: Add UsageSnapshot model in Swift**

Simple struct matching the JSON shape.

- [ ] **Step 3: Commit**

`git commit -m "feat(probes): parse usage events in IndexerProcess"`

---

## Task 6: Popover Usage Display (Method B)

- [ ] **Step 1: Create UsageBarView**

Reusable: label (50pt) + progress bar (flexible) + percentage text.

- [ ] **Step 2: Create PopoverUsageSection**

"USAGE" header + Show All toggle. Collapsed: one bar per model showing highest-% window. Expanded: grouped cards per model with all windows + reset time.

- [ ] **Step 3: Add to PopoverView bottom**

Insert `PopoverUsageSection` above the settings area in PopoverView.

- [ ] **Step 4: Build, test, commit**

`git commit -m "feat(probes): add usage display to Popover (compact + expand)"`

---

## Task 7: Sources Page Full Display (Method A)

- [ ] **Step 1: Add full usage section to SourcePulseView**

Dual-line bars per model: top line (thick) = 5h window, bottom line (thin) = weekly. >80% = red.

- [ ] **Step 2: Build, test, commit**

`git commit -m "feat(probes): add full usage display to Sources page"`

---

## Task 8: Final Verification

- [ ] **Step 1: npm test — all pass**
- [ ] **Step 2: npm run build**
- [ ] **Step 3: Start daemon, verify usage events appear in stdout**
- [ ] **Step 4: Open Engram, verify Popover shows usage bars**
- [ ] **Step 5: Final commit**

`git commit -m "feat(probes): PR5 complete — usage monitoring with Popover + Sources display"`
