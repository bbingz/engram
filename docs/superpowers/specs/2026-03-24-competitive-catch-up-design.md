# Competitive Catch-Up — Design Spec

> **Date**: 2026-03-24
> **Scope**: 4 features across Node data layer + Swift UI, closing gaps vs Readout/Agent Sessions
> **Architecture**: Phase-based — Node data first, integration second, Swift UI third
> **Prerequisites**: None (all data sources already exist)

---

## Overview

| # | Feature | Layer | Phase |
|---|---------|-------|-------|
| F1 | Transcript Enhancement (tool call formatting + syntax highlighting + image preview) | Swift | 3 |
| F2 | Health Check Expansion (6 new categories + Swift Hygiene page) | Node + Swift | 1 + 3 |
| F3 | Cost Optimization Suggestions (rule engine + simulation) | Node | 1 |
| F4 | get_context Panoramic Aggregation | Node | 1 + 2 |

### Phase Structure

- **Phase 1** (Node data layer, 3 parallel tasks): health-rules.ts + cost-advisor.ts + get_context stub
- **Phase 2** (Integration + tests): Wire get_context to real health-rules + cost-advisor outputs
- **Phase 3** (Swift UI, 2 parallel tasks): Transcript enhancement + HygieneView

---

## F1: Transcript Enhancement (Swift — Phase 3)

### F1A: Tool Call Formatting

**Problem**: `toolCall` and `toolResult` messages render as raw text. Tool name, parameters, and output are indistinguishable.

**New files**:
- `Views/Transcript/ToolCallView.swift` — Structured tool call card
- `Views/Transcript/ToolResultView.swift` — Collapsible result card
- `Core/ToolCallParser.swift` — Regex parser for tool call format

**Modified files**:
- `ColorBarMessageView.swift` — Route toolCall/toolResult types to new views

**ToolCallView layout**:
```
┌─ 🔧 Read ──────────────────────────────────┐
│  file_path: /src/core/db.ts                 │
│  offset: 100                                │
│  limit: 50                                  │
└─────────────────────────────────────────────┘
```
- Parse tool name from existing regex patterns (`` `Read`: ``, `` `Edit(` ``, etc.)
- Parameters displayed as key-value pairs, not raw JSON
- Long values (>200 chars) collapsed by default, click to expand
- Copy button for full JSON

**ToolResultView layout**:
```
┌─ ◀ Read result ─── 1.2KB ─── Expand ▾ ────┐
│  (collapsed: first-line preview)            │
│  1  import { Database } from 'better...     │
└─────────────────────────────────────────────┘
```
- Auto-collapse when >5 lines, expand when ≤5
- Show output size in header
- Error output highlighted in red

**ToolCallParser design**:
- V1 supports Claude Code format only (`` `ToolName`: `` followed by JSON or key-value). This covers 80%+ of user sessions.
- Other sources (Codex, Gemini CLI) fallback to existing plain text rendering — zero risk.
- Parse failure always falls back to plain text.

### F1B: Code Syntax Highlighting

**Problem**: `CodeBlockView` uses monospaced font only, no color.

**New file**: `Core/SyntaxHighlighter.swift`

**Approach**: Built-in regex-based highlighter (no external dependencies).

**Supported languages** (5 high-frequency):
- Swift, TypeScript/JavaScript, Python, Bash, JSON

**Token categories** (6 colors):
- Keyword (purple), String (green), Comment (gray), Number (orange), Type (blue), Function call (yellow)

**Scope boundary**: Single-line token coloring only. No cross-line syntax analysis (template literals, multi-line strings, f-strings are NOT handled). Expected accuracy: ~80% for common patterns. Graceful degradation: unrecognized tokens render in default text color.

**Language detection**: From code fence marker (existing `language` field in `ContentSegment.codeBlock`). Unknown language → monospaced without color (current behavior).

**Output**: `AttributedString` consumed by existing `Text` view.

**Modified file**: `ContentSegmentViews.swift` — `CodeBlockView` calls `SyntaxHighlighter.highlight()`. For large code blocks, consider `NSAttributedString` + `NSTextView` wrapper if SwiftUI `Text(AttributedString)` performance is poor (optimization, not blocking).

### F1C: Image Preview

**Problem**: base64 images and file path images in messages are not rendered at all.

**New files**:
- `Views/Transcript/InlineImageView.swift` — Thumbnail + click-to-expand
- ContentSegmentParser changes for `.image` segment type

**Detection strategy**:
- **base64**: Match `data:image/(png|jpeg|gif|webp);base64,` prefix → detect in ALL message types
- **File paths**: Match absolute paths ending in `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif` → detect **only in toolResult messages** (avoids false positives from discussion text like "save to screenshot.png")

**Size limit**: Max 1MB decoded size. Exceeding shows "Image too large to preview" placeholder.

**Rendering**:
- Thumbnail: max width 400pt, aspect ratio preserved
- Click: expand in sheet/popover (not NSPanel — simpler)
- base64 → `NSImage(data:)`, file path → `NSImage(contentsOfFile:)`
- Missing file → gray placeholder with "Image unavailable" text

**Modified files**:
- `Core/ContentSegmentParser.swift` — New `.image(source:)` segment type. Parse order: code blocks first, then images, then text (images inside code blocks NOT rendered as images). Note: the `ContentSegment` enum's `id` computed property needs a new case for `.image` to satisfy `Identifiable`.
- `Views/ContentSegmentViews.swift` — Route `.image` case to `InlineImageView`

---

## F2: Health Check Expansion (Node + Swift — Phase 1 + 3)

### F2-Node: Health Rules Engine

**New file**: `src/core/health-rules.ts`

**Architecture**: Standalone rule engine. Called by `lint_config.ts` and `get_context.ts`. Does not modify existing `lintConfig()` logic — CLAUDE.md validation stays in `lint_config.ts`.

**10 categories** (existing 4 migrated from `runHealthChecks()` + 6 new):

| # | Category | Source | Severity | Implementation |
|---|----------|--------|----------|----------------|
| 1 | Stale branches | existing | info | `git branch --merged` via `execFile` |
| 2 | Large uncommitted | existing | warning | `git status --porcelain` via `execFile` |
| 3 | Zombie daemon | existing | warning | `pgrep` engram daemon |
| 4 | .env security | **new** | error | Scan git_repos cwds for `.env*` files not in `.gitignore`. Covers `.env`, `.env.local`, `.env.production`, etc. |
| 5 | Zombie processes | **new** | warning | `pgrep -f` headless node/python >2h. **Whitelist exclusions**: engram daemon PID, patterns matching `next dev`, `vite`, `webpack-dev-server`, `nuxt`, `remix dev` |
| 6 | Worktree health | **new** | warning | `git worktree list`, detect orphan (path not found) and dirty worktrees |
| 7 | Dependency security | **new** | error/warning | `npm audit --json` on repos with package.json. **Only repos with active sessions in last 7 days.** Results cached 30 min independently. |
| 8 | Git stash buildup | **new** | info | `git stash list`, report if >5 stashes |
| 9 | Branch divergence | **new** | warning | `git log --left-right --count HEAD...@{u}`, report if both ahead AND behind >0 |
| 10 | CLAUDE.md lint | existing (ref only) | error/warning | Stays in `lint_config.ts`. `health-rules.ts` calls `lintConfig()` and merges issues into unified output. |

**Note**: Only checks #1-3 are migrated from `runHealthChecks()` in `lint_config.ts`. Check #10 (CLAUDE.md lint) stays in `lint_config.ts`; `health-rules.ts` calls it and includes the result.

**Interface**:

```typescript
// Extends existing HealthIssue from lint_config.ts (preserves `kind` field name for compatibility)
interface HealthIssue {
  kind: string;          // 'env_audit' | 'zombie_process' | 'worktree' | ... (existing field name)
  severity: 'error' | 'warning' | 'info';
  message: string;       // Human-readable description
  detail?: string;       // Extended detail (existing field, preserved)
  repo?: string;         // Associated repo path (new)
  action?: string;       // Suggested fix command, e.g., "git stash drop" (new)
}

// Shell command executor — injectable for testing (avoids violating "no mocking" convention)
type ShellExecutor = (cmd: string, args: string[], options: { timeout: number; cwd?: string }) => Promise<string>;

async function runAllHealthChecks(db: Database, options?: {
  force?: boolean;       // Bypass 5-min cache
  exec?: ShellExecutor;  // Inject for testing (default: child_process.execFile wrapper)
}): Promise<{
  issues: HealthIssue[];
  score: number;         // 0-100 (100 = all clean)
  checkedAt: string;     // ISO timestamp
}>
```

**Execution strategy**:
- All shell commands via `execFile()` with array arguments (NOT `exec()` with string interpolation) — prevents shell injection from repo paths with special characters
- 10s timeout per command, failure silently skipped (logged at warn level)
- Git checks run on all repos in `git_repos` table, parallelized via `Promise.allSettled()`
- `npm audit` only on repos with sessions in last 7 days, cached 30 min independently
- Overall result cached 5 min, bypassed with `force: true`

**Modifications to existing code**:
- `lint_config.ts`: Remove `runHealthChecks()` body, replace with call to `health-rules.ts:runAllHealthChecks()`. Keep `lintConfig()` unchanged.
- `monitor.ts`: `BackgroundMonitor` calls `runAllHealthChecks()` on its 10-min cycle. Severe issues (error severity) trigger alerts.
- `web.ts`: New endpoint `GET /api/hygiene?force=true|false` → calls `runAllHealthChecks()` (avoids collision with existing `GET /api/health/sources`)
- `monitor.ts` integration: `BackgroundMonitor.check()` adds `await runAllHealthChecks(this.db)` call, emits alerts for error-severity issues via existing `this.db` reference

### F2-Swift: Hygiene Page

**New files**:
- `Views/Pages/HygieneView.swift` — Main page
- `Models/HygieneModel.swift` — Observable data model

**Modified files**:
- `Models/Screen.swift` — Add `.hygiene` case
- `Views/SidebarView.swift` — Add "Hygiene" entry under Analytics section
- `Views/ContentView.swift` — Route `.hygiene` → `HygieneView`
- Note: `project.yml` does NOT need modification — `sources: - path: Engram` auto-discovers all Swift files. Only `xcodegen generate` is needed to regenerate `.xcodeproj`.

**Layout** (KPI Dashboard pattern, consistent with HomeView):

```
┌─────────────────────────────────────────────┐
│  🏥 Hygiene Score          Last checked: 2m │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
│  │  87  │ │  2   │ │  3   │ │  1   │       │
│  │Score │ │Errors│ │Warns │ │ Info │       │
│  └──────┘ └──────┘ └──────┘ └──────┘       │
├─────────────────────────────────────────────┤
│  ▼ Errors (2)                               │
│  ┌─ .env security ────────── repo-a ──────┐ │
│  │ ⚠ .env not in .gitignore               │ │
│  │ 💡 echo '.env' >> .gitignore  [Copy]    │ │
│  └────────────────────────────────────────┘ │
│                                             │
│  ▼ Warnings (3)                             │
│  ┌─ Zombie processes ────────────────────┐  │
│  │ ⚠ 2 headless node processes (>2h)     │  │
│  │ 💡 kill 12345 67890            [Copy]  │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ▸ Info (1) (collapsed by default)          │
├─────────────────────────────────────────────┤
│  Empty state: "All clean!" + green check    │
└─────────────────────────────────────────────┘
```

**Interactions**:
- Refresh button → `GET /api/hygiene?force=true`
- Action suggestion → copy command to clipboard (no destructive execution)
- Errors expanded by default, Info collapsed
- Skeleton loading during initial fetch (consistent with other pages)

**Data flow**:
- `HygieneModel` (`@Observable`) holds `issues`, `score`, `checkedAt`, `isLoading`
- Calls `DaemonClient.fetchHealthChecks(force:)` → `GET /api/hygiene`
- Cache: respects daemon 5-min cache; user refresh sends `force=true`

---

## F3: Cost Optimization Suggestions (Node — Phase 1)

### New file: `src/core/cost-advisor.ts`

**Architecture**: Pure functional rule engine. Input = DB query results. Output = suggestion list. No DB writes, no side effects.

**Data dependencies** (all existing):
- `session_costs` — per-model/day token and cost data
- `session_tools` — tool call counts
- `sessions` — session metadata

**Interface**:

```typescript
interface CostSuggestion {
  rule: string;           // 'opus_overuse' | 'low_cache' | ...
  severity: 'high' | 'medium' | 'low';
  title: string;          // One-line title
  detail: string;         // Detailed analysis
  savings?: {
    current: number;      // Current cost (USD)
    projected: number;    // Projected cost after optimization (USD)
    percent: number;      // Savings percentage
    period: 'daily' | 'weekly' | 'monthly';
  };
  topItems?: Array<{
    name: string;         // Model/project/session ID
    value: number;        // Cost or token count
  }>;
}

async function getCostSuggestions(db: Database, config: FileSettings, options?: {
  since?: string;         // ISO timestamp, default: 7 days ago
}): Promise<{
  suggestions: CostSuggestion[];
  summary: {
    totalSpent: number;       // Total in time window (USD)
    projectedMonthly: number; // Extrapolated monthly spend
    potentialSavings: number; // Sum of all suggestion savings
  };
}>
```

**8 rules with simulation**:

| # | Rule | Trigger | Suggestion | Simulation |
|---|------|---------|------------|------------|
| 1 | Opus overuse | Opus cost >70% of total | "Use Sonnet for shorter sessions" | Calculate savings for Opus sessions with <20 messages only (complex sessions excluded). Multiply those sessions' tokens by Sonnet pricing. |
| 2 | Low cache rate | cache_read/(input+cache_read) <30%, **Anthropic models only** | "Optimize prompt caching" | Simulate 80% cache hit → projected savings |
| 3 | Over budget | 7-day daily avg > dailyBudget | "Daily avg $X exceeds $Y budget" | Monthly projection extrapolation |
| 4 | Project hotspot | Single project >50% of total cost | "Project Z = N% of spend" | List top 3 models within that project |
| 5 | Model efficiency | ≥2 models used | "Model A: $X/msg, Model B: $Y/msg" | Cost-per-message ranking |
| 6 | Expensive sessions | Single session >$5 AND >200K tokens | "Session Z cost $X, consider splitting" | Top 5 most expensive sessions |
| 7 | Week-over-week spike | This week > last week × 1.5 | "Costs up N% week-over-week" | Daily trend with inflection point |
| 8 | Output imbalance | output_tokens/input_tokens >3, **excluding sessions with >10 Write/Edit tool calls** | "High output ratio, possible verbose generation" | Per-model input/output breakdown |

**Key corrections from self-review**:
- Rule 1: Only simulates savings for short sessions (<20 messages), not all Opus usage
- Rule 2: Filtered to Anthropic models only (others don't support caching)
- Rule 8: Threshold raised to >3 (from >2), excludes code-generation-heavy sessions
- Default time window: 7 days, configurable via `since` parameter

**Pricing data**: Reuses `src/core/pricing.ts` existing model pricing tables for simulation calculations.

**Query patterns**:
- Aggregate model breakdown: `getCostsSummary({ groupBy: 'model', since })` (existing function)
- Per-session with message count (for Rule 1 short session filter): `SELECT c.*, s.message_count FROM session_costs c JOIN sessions s ON c.session_id = s.id WHERE c.model LIKE 'claude-%opus%' AND s.message_count < 20`
- Cache rate (Rule 2): `SELECT SUM(cache_read_tokens) as cache_read, SUM(input_tokens) as input FROM session_costs WHERE model LIKE 'claude-%'`
- Budget threshold: `config.monitor?.dailyCostBudget ?? config.costAlerts?.dailyBudget` (FileSettings type, both optional paths)
- Tool call counts (Rule 8): `SELECT tool_name, SUM(call_count) FROM session_tools WHERE session_id = ? GROUP BY tool_name`

### New MCP tool: `get_insights`

**File**: `src/tools/get_insights.ts`

```typescript
// Tool definition
{
  name: 'get_insights',
  description: 'Get actionable cost optimization suggestions with savings estimates',
  inputSchema: {
    type: 'object',
    properties: {
      since: { type: 'string', description: 'ISO timestamp, default 7 days' }
    }
  }
}
```

Wraps `getCostSuggestions()` output as MCP tool response. Boundary with `get_context`: `get_insights` = detailed cost analysis with full simulation data; `get_context` environment includes only suggestion summaries (title + severity + savings estimate).

---

## F4: get_context Panoramic Aggregation (Node — Phase 1 stub + Phase 2 integration)

### Modified file: `src/tools/get_context.ts`

**Current environment data** (already implemented):
- `liveSessions` — active sessions with activity level
- `costToday` — today's cost by model
- `topTools` — top 10 tools in last 7 days
- `activeAlerts` — non-dismissed alerts
- `healthIssues` — basic health check output

**New environment data blocks** (5 additions):

```typescript
interface EnvironmentContext {
  // === Existing (unchanged) ===
  liveSessions: Array<{ id, source, project, activity }>;
  costToday: { total: number; byModel: Record<string, number> };
  topTools: Array<{ tool: string; count: number }>;
  activeAlerts: Array<{ rule, severity, message }>;

  // === Upgraded ===
  healthIssues: HealthIssue[];  // Now from health-rules.ts full 10-category output

  // === New ===
  gitRepos: Array<{
    name: string;
    branch: string;
    dirtyCount: number;
    unpushedCount: number;
  }>;  // Only repos with dirty>0 OR unpushed>0. Max 10.

  fileHotspots: Array<{
    path: string;
    editCount: number;
    sessionCount: number;
  }>;  // Top 10 most-edited files, last 7 days. From session_files table.

  recentErrors: Array<{
    module: string;
    message: string;
    count: number;
    lastSeen: string;
  }>;  // From `logs` table, level='error', last 24h, grouped by module+message, top 5.
      // Note: add compound index `CREATE INDEX IF NOT EXISTS idx_logs_level_ts ON logs(level, ts)` in migration for query efficiency.

  costSuggestions: Array<{
    rule: string;
    title: string;
    severity: string;
    savings?: { current: number; projected: number; percent: number };
  }>;  // Summary only (no detail field). From cost-advisor. Max 5.

  configStatus: {
    score: number;          // 0-100 from lintConfig()
    errorCount: number;
    warningCount: number;
  };  // Project aliases excluded (noise for AI context).
}
```

**Key corrections from self-review**:
- `recentErrors`: Source changed from sessions table (no error flag) to `logs` table `level='error'`. Grouped by module+message to deduplicate, returns count + lastSeen.
- `configStatus`: Removed `projectAliases` field (noise for context prompt).
- Token budget: Reserved 30% of `max_tokens` for environment, 70% for session content. Estimated environment size: 2000-2500 tokens with full data.

**detail-level gating**:

| detail level | Environment data returned |
|-------------|--------------------------|
| `abstract` | `costToday` + `activeAlerts` only (~200 tokens) |
| `overview` | All fields, items truncated to top 5 each (~1500 tokens) |
| `full` | All fields, full limits (10 repos, 10 files, 5 errors, 5 suggestions) (~2500 tokens) |

**Execution**:
- All new queries run in `Promise.all()` alongside existing queries
- Per-query timeout: 2s. Timed-out queries return `null` (field omitted from response)
- Failed queries logged at warn level, do not block response

**Phase 1 (stub)**: Add the new fields to the response type. Populate with placeholder queries (`SELECT ... FROM git_repos WHERE dirty_count > 0 LIMIT 10`, etc.). `costSuggestions` returns empty array (cost-advisor not yet integrated).

**Phase 2 (integration)**: Wire `costSuggestions` to real `getCostSuggestions()` output. Wire `healthIssues` to real `runAllHealthChecks()`. Verify token budget with real data.

---

## Testing Strategy

| Component | Test Type | Scope |
|-----------|-----------|-------|
| `health-rules.ts` | Vitest unit | Inject `ShellExecutor` stub (not mocking — dependency injection via function parameter, consistent with project "no mocking" convention). One test per category (10 tests). Test score calculation. Test cache behavior. Test shell injection safety (path with special chars). |
| `cost-advisor.ts` | Vitest unit | Fixture data for each rule (8 tests). Test simulation math accuracy. Test edge cases (no data, single model, zero cost). Test Anthropic-only filter for cache rule. |
| `get_insights` tool | Vitest integration | Call tool handler with test DB, verify response schema. |
| `get_context` upgrade | Vitest integration | Call with `include_environment: true`, verify new fields present and typed correctly. Test detail-level gating (abstract/overview/full). Test timeout behavior. |
| `GET /api/hygiene` | Vitest integration | HTTP endpoint returns correct schema. Test `force` parameter. |
| Swift views (F1 + F2) | Manual verification | ToolCallView renders tool name + params. SyntaxHighlighter colors keywords. InlineImageView shows thumbnails. HygieneView displays issues. |

**Test count estimate**: ~30-35 new tests (Node side). Swift side manual only (XCUITest optional, non-blocking).

---

## File Inventory

### New files (10)

| File | Phase | Feature |
|------|-------|---------|
| `src/core/health-rules.ts` | 1 | F2 |
| `src/core/cost-advisor.ts` | 1 | F3 |
| `src/tools/get_insights.ts` | 1 | F3 |
| `macos/Engram/Views/Transcript/ToolCallView.swift` | 3 | F1A |
| `macos/Engram/Views/Transcript/ToolResultView.swift` | 3 | F1A |
| `macos/Engram/Core/ToolCallParser.swift` | 3 | F1A |
| `macos/Engram/Core/SyntaxHighlighter.swift` | 3 | F1B |
| `macos/Engram/Views/Transcript/InlineImageView.swift` | 3 | F1C |
| `macos/Engram/Views/Pages/HygieneView.swift` | 3 | F2 |
| `macos/Engram/Models/HygieneModel.swift` | 3 | F2 |

### Modified files (11)

| File | Phase | Change |
|------|-------|--------|
| `src/tools/lint_config.ts` | 1 | Replace `runHealthChecks()` body with call to health-rules |
| `src/core/monitor.ts` | 1 | Call `runAllHealthChecks()` in monitor cycle |
| `src/web.ts` | 1 | Add `GET /api/hygiene` endpoint |
| `src/tools/get_context.ts` | 1+2 | Add 5 new environment data blocks |
| `src/core/db.ts` | 1 | Add compound index `idx_logs_level_ts ON logs(level, ts)` in `migrate()` |
| `src/index.ts` | 1 | Register `get_insights` tool definition AND add handler clause in `CallToolRequestSchema` handler |
| `macos/Engram/Views/Transcript/ColorBarMessageView.swift` | 3 | Add `case .toolCall:` and `case .toolResult:` branches before `default` in the switch statement. New views receive `indexed.message.content` for parsing by `ToolCallParser`. |
| `macos/Engram/Views/ContentSegmentViews.swift` | 3 | Add `.image` case + syntax highlighting in CodeBlockView |
| `macos/Engram/Core/ContentSegmentParser.swift` | 3 | Add `.image` segment detection |
| `macos/Engram/Models/Screen.swift` | 3 | Add `.hygiene` case |
| `macos/Engram/Views/SidebarView.swift` + `ContentView.swift` | 3 | Hygiene navigation entry + routing |

### Post-change requirements
- `npm run build` after Phase 1 + 2
- `xcodegen generate` in `macos/` after Phase 3
- `npm test` to verify existing 616 tests still pass + new tests
