# Engram

Cross-tool AI session aggregator: TypeScript MCP server + macOS SwiftUI menu bar app.

## Quick Reference

```bash
# TypeScript
npm run build          # tsc → dist/ (ES modules)
npm test               # vitest: 1276 tests, ~54s
npm run dev            # tsx: run without compile
npm run lint           # biome check (must pass — pre-commit enforced)
npm run lint:fix       # biome auto-fix
npm run knip           # dead code detection

# macOS (from macos/)
xcodegen generate      # regenerate .xcodeproj from project.yml
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build

# After changing src/, always: npm run build
# After adding/removing Swift files: xcodegen generate
```

## Architecture

```
src/
  adapters/    # SessionAdapter implementations (15 sources: codex, claude-code, cursor, etc.)
  core/        # indexer.ts, watcher.ts, config.ts, sync.ts, lifecycle.ts, session-tier.ts, parent-detection.ts, chunker.ts, vector-store.ts, embeddings.ts, bootstrap.ts (factories)
    db/        # Database modules: database.ts (facade), migration.ts, session-repo.ts, fts-repo.ts, metrics-repo.ts, index-job-repo.ts, sync-repo.ts, maintenance.ts, alias-repo.ts, insight-repo.ts, parent-link-repo.ts
    db.ts      # ESM re-export shim (preserves `import { Database } from '../core/db.js'`)
  tools/       # MCP tool handlers (19 tools: get_context, search, save_insight, list_sessions, get_session, get_memory, get_insights, get_costs, stats, tool_analytics, file_activity, etc.)
  web.ts       # Hono HTTP server + API endpoints
  index.ts     # MCP server entry — uses createMCPDeps() from bootstrap.ts
  daemon.ts    # Daemon entry — uses createDaemonDeps() + createShutdownHandler() from bootstrap.ts

macos/
  Engram/      # SwiftUI app (menu bar + main window)
    Core/      # IndexerProcess, Database (GRDB), DaemonClient, MCPServer, MessageParser
    Views/     # MainWindowView, SidebarView, PopoverView, SessionListView, SessionDetailView, SettingsView
      Pages/   # HomeView, SessionsPageView, SearchPageView, ActivityView, ProjectsView, TimelinePageView, etc.
      Settings/  # GeneralSettingsSection, AISettingsSection, NetworkSettingsSection, SourcesSettingsSection
      Transcript/  # ColorBarMessageView, TranscriptToolbar, TranscriptFindBar
      Workspace/   # ReposView, RepoDetailView, SparklineView, WorkGraphView
    Components/  # Theme, SourceColors, SessionCard, ExpandableSessionCard, FilterPills, KPICard, HeatmapGrid, etc.
    Models/    # Session, GitRepo, IndexedMessage, MessageTypeClassifier, Screen
  project.yml  # xcodegen config → generates Engram.xcodeproj
  scripts/build-node-bundle.sh  # Xcode prebuild: npm build → copy dist/ into app bundle
```

## Key Patterns

### Adapter Pattern
13 adapters (handling 15 sources) implement `SessionAdapter` from `src/adapters/types.ts`:
- `detect()` — check if tool's session dir exists
- `listSessionFiles()` — async generator yielding file paths
- `parseSessionInfo()` — extract metadata from session file
- `streamMessages()` — async generator yielding messages lazily

New adapters: create `src/adapters/<name>.ts`, register in `src/core/bootstrap.ts:createAdapters()`.

### Bootstrap Factories
`src/core/bootstrap.ts` centralizes initialization for both entry points:
- `createMCPDeps()` — db, adapters, tracer, settings, audit, indexer, vecDeps → used by `index.ts`
- `createDaemonDeps()` — extends MCPDeps + log, metrics, auditQuery, titleGenerator → used by `daemon.ts`
- `createShutdownHandler(resources)` — idempotent cleanup of timers, monitors, watcher, web server, db
- `initVectorDeps()` — sqlite-vec + embedding client + embedding indexer (returns null if unavailable)

### Database
- Node owns schema (`src/core/db.ts:migrate()`). Swift reads via GRDB (read-only pool).
- Swift writes only to extension tables: `favorites`, `tags`.
- Schema changes: add idempotent migration in `migrate()` (check `PRAGMA table_info` before `ALTER TABLE`).
- FTS: trigram tokenizer on `sessions_fts`. Version bump in `FTS_VERSION` forces full re-index.

### Process Lifecycle
`setupProcessLifecycle()` MUST be called AFTER `server.connect(transport)` — stdin race with StdioServerTransport.
- MCP server: `idleTimeoutMs: 0` — Claude Code manages lifecycle via stdin close. Do NOT re-enable idle timeout (causes premature disconnect).
- Daemon: has its own signal-based shutdown, does NOT use `setupProcessLifecycle`.

### Session Tiering
4 tiers in `src/core/session-tier.ts`: `skip` / `lite` / `normal` / `premium`.
- skip = DB only (noise, preamble, agent subprocesses)
- lite = +FTS indexing
- normal = +embedding
- premium = +auto-summary
UI noise filter uses `buildTierFilter()` / `isTierHidden()`. Swift filters via `tier != 'skip'`.

### Local Semantic Search
Hybrid search: FTS5 (trigram) + sqlite-vec (vector embeddings) + RRF fusion. All local, no external services.
- `src/core/vector-store.ts`: session-level + chunk-level + insight vectors via sqlite-vec
- `src/core/chunker.ts`: message-boundary-first chunking for fine-grained retrieval
- `src/core/embeddings.ts`: provider strategy — Ollama (default) | OpenAI | Transformers.js (opt-in)
- `src/tools/save_insight.ts`: active memory write (agents save curated knowledge)
- `src/core/db/insight-repo.ts`: text-only insight storage with FTS (works without embedding provider)
- Model tracking: dimension/model changes trigger automatic rebuild of vector tables

### Insight Degradation UX
Two storage layers for insights: `insights` table (text+FTS, always available) and `memory_insights` (vector, requires sqlite-vec).
- save_insight: input validation (min 10 chars, max 50KB, trim); text-only dedup via normalized comparison; default importance = 5
- save_insight: no embedding → text-only save with warning; with embedding → dual-write (vector + text)
- `source_session_id` wired through both stores; `deleteInsight()` helper deletes from both
- get_memory/search/get_context: no embedding → FTS keyword fallback from `insights` table
- Daemon backfills: promotes text-only insights to embedded when provider becomes available
- Daemon maintenance: `reconcileInsights()` fixes has_embedding/memory_insights divergence on startup
- CJK queries use LIKE fallback (same as session FTS)

### Agent Session Grouping
Parent-child session linking: agent sessions (dispatched by Claude Code to Gemini/Codex) are grouped under their parent.
- `parent_session_id`: confirmed link. `suggested_parent_id`: Layer 2 heuristic (advisory).
- `link_source`: `'path'` (Layer 1) or `'manual'` (user-confirmed). `'manual'` with NULL parent = explicitly unlinked.
- Four detection layers:
  1. **Layer 1 (path)**: Claude Code subagents — parse parent ID from `/subagents/` file path. Deterministic.
  2. **Layer 1b (originator)**: Codex `session_meta.originator === "Claude Code"` → auto `agentRole: 'dispatched'`. Deterministic.
  3. **Layer 1c (sidecar)**: Gemini plugin writes `{sessionId}.engram.json` sidecar with `parentSessionId`. Deterministic.
  4. **Layer 2 (heuristic)**: Dispatch pattern matching + temporal/cwd scoring. Advisory → `suggested_parent_id`.
  5. **Layer 3 (manual)**: HTTP API endpoints at `POST/DELETE /api/sessions/:id/link`, `POST /api/sessions/:id/confirm-suggestion`, `DELETE /api/sessions/:id/suggestion`.
- Orphan trigger: `trg_sessions_parent_cascade` nullifies children on parent deletion + resets tier for re-evaluation.
- Tier lifecycle: subagent sessions always stay `skip` (accessed through parent, not independently); unlinked children get tier reset to NULL for re-evaluation. `downgradeSubagentTiers()` on daemon startup fixes any incorrectly upgraded sessions.
- Dispatch-pattern sessions without a parent get `agent_role = COALESCE(agent_role, 'dispatched')` → `tier = 'skip'`.
- `src/core/parent-detection.ts`: `DETECTION_VERSION` (bump to trigger re-evaluation), dispatch patterns + `PROBE_REGEXES`, `scoreCandidate()` (4h half-life, CWD classification, soft end_time handling), `pickBestCandidate()` (best-score wins, no ambiguity rejection).
- `src/core/db/maintenance.ts`: `backfillCodexOriginator()` (reads file first 16KB for history), `resetStaleDetections()` (version-gated re-evaluation), `backfillSuggestedParents()` (no end_time SQL filter — scoring handles it; includes hidden parents).
- `src/core/db/parent-link-repo.ts`: validation (self-link, existence, depth=1), CRUD, child queries.
- `src/core/db/session-repo.ts`: `countTodayParentSessions()` for menu bar badge.
- Daemon startup order: `downgradeSubagentTiers → backfillParentLinks → resetStaleDetections → backfillCodexOriginator → backfillSuggestedParents`.
- Swift UI: `ExpandableSessionCard` with disclosure triangle + `CompactChildRow`. Used in HomeView, SessionsPageView, SessionListView, TimelinePageView.
- All three views filter `parent_session_id IS NULL AND suggested_parent_id IS NULL` for top-level display.
- Menu bar badge: shows today's parent session count (not total), via `todayParents` field in daemon events.

### Daemon ↔ Swift Communication
- Daemon writes JSON lines to stdout: `{ event: "ready", indexed: N, total: M, todayParents: P }`
- Initial `ready.todayParents` must be emitted only after parent-link / tier backfills complete, so the menu bar badge starts with the authoritative parent-session count.
- Swift `IndexerProcess` parses these events via pipe, exposes `totalSessions` and `todayParentSessions`
- Daemon stderr → `os_log` (`com.engram.app:daemon`, viewable in Console.app)

## Conventions

- **Language**: TypeScript (strict, ES2022, Node16 modules) + Swift 5.9 (macOS 14+)
- **Linting**: Biome (enforced via pre-commit hook: husky + lint-staged). `npm run lint` must pass.
- **Imports**: Use `node:` prefix for Node.js builtins (`node:fs`, `node:path`, etc.)
- **Constants**: UPPER_SNAKE_CASE (`WATCHED_SOURCES`, `NOISE_FILTER_SQL`)
- **Error handling**: Adapters silently skip failures; DB errors propagate; tools return `isError: true`
- **Tests**: Vitest with real fixtures in `tests/fixtures/<adapter>/`. No mocking — real file I/O.
- **Comments**: Chinese comments are intentional, keep them as-is
- **Swift DB reads**: Use `nonisolated` + `readInBackground` for all DatabaseManager read methods. Views call via `Task.detached { ... }.value` (see PopoverView.loadData as pattern).

## Build Output

- Xcode builds to: `~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/{Debug,Release}/Engram.app`
- Do NOT use `macos/build/` — stale cache, gitignored
- Bundle includes: `Contents/Resources/node/{daemon.js, ...dist files, node_modules/}`
- Deploy to `/Applications`: must `rm -rf` first, then `cp -R`. `cp -R` silently skips running binaries.

## Data

- SQLite DB: `~/.engram/index.sqlite` (WAL mode)
- Settings: `~/.engram/settings.json`
- Session sources: `~/.claude/projects/`, `~/.codex/sessions/`, `~/.gemini/`, etc.

## What NOT To Do

- Don't modify generated `Engram.xcodeproj` directly — edit `project.yml` and run `xcodegen generate`
- Don't commit `.sqlite` files, `node_modules/`, or `dist/`
- Don't add `summary_message_count` column — it already exists (migration is idempotent)
- Don't use `String(value)` for potentially undefined values in TS — use `(value as string) || ''`
- Don't add new DatabaseManager read methods without `nonisolated` — they'll block the main thread
- Don't use `hashValue` for cache keys — use the value itself (hash collisions are real)
- Don't skip `npm run lint` — pre-commit hook enforces it; CI enforces it too
- Don't mix vectors from different embedding models in the same vector space — use explicit provider selection
- Don't add legacy external semantic-search integrations — use local sqlite-vec + FTS5 instead
- Don't re-enable idle timeout for MCP server (`idleTimeoutMs` in index.ts) — causes premature disconnect
- Don't add db methods directly to db.ts — add to the appropriate module in `src/core/db/`, facade in `database.ts` delegates
- Don't upgrade subagent tier from `skip` — subagent content is accessed through parent sessions, not independently. `setParentSession()` must NOT modify tier

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
