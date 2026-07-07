# Engram

Cross-tool AI session aggregator: native macOS SwiftUI app + Swift
`EngramService`/`EngramMCP` runtime. TypeScript remains development,
reference, fixture, and regression-test material; it is not the shipped app
runtime.

## Quick Reference

```bash
# TypeScript dev/reference tooling
npm run build          # tsc → dist/ (ES modules)
npm test               # vitest regression suite
npm run lint           # biome check (must pass — pre-commit enforced)
npm run lint:fix       # biome auto-fix
npm run knip           # dead code detection

# macOS (from macos/)
xcodegen generate      # regenerate .xcodeproj from project.yml
xcodebuild -project Engram.xcodeproj -scheme Engram -configuration Debug build

# After changing TypeScript dev/reference code: npm run build
# After adding/removing Swift files: xcodegen generate
```

## Architecture

```
src/
  adapters/    # TypeScript reference parsers and fixture generators
  core/        # TypeScript reference DB/search/project-move logic and tests
  tools/       # TypeScript reference MCP tool handlers
  cli/         # Retained developer/reference subcommands

macos/
  Engram/      # SwiftUI app (menu bar + main window)
    Core/      # App lifecycle, read models, GRDB read facades, service launcher/status
    Views/     # MainWindowView, SidebarView, PopoverView, SessionListView, SessionDetailView, SettingsView
      Pages/   # HomeView, SessionsPageView, SearchPageView, ActivityView, ProjectsView, TimelinePageView, etc.
      Settings/  # GeneralSettingsSection, AISettingsSection, SourcesSettingsSection
      Transcript/  # ColorBarMessageView, TranscriptToolbar, TranscriptFindBar
      Workspace/   # ReposView, RepoDetailView, SparklineView, WorkGraphView
    Components/  # Theme, SourceColors, SessionCard, ExpandableSessionCard, FilterPills, KPICard, HeatmapGrid, etc.
    Models/    # Session, GitRepo, IndexedMessage, MessageTypeClassifier, Screen
  Shared/
    EngramCore/       # Shared Swift models/adapters
    Service/          # EngramServiceClient, transport, DTOs, mocks
  EngramCoreRead/     # GRDB read repositories/facades
  EngramCoreWrite/    # schema, migrations, indexer, writer-owned maintenance
  EngramService/      # Unix-socket service helper process
  EngramMCP/          # Native Swift MCP stdio helper
  project.yml  # xcodegen config → generates Engram.xcodeproj
```

## Key Patterns

### Adapter Pattern
Swift adapters under `macos/Shared/EngramCore/Adapters/Sources/` are the
current product parsers. TypeScript adapters under `src/adapters/` are retained
as reference/dev fixtures and regression coverage.

New product adapters should be added in Swift first, wired into the Swift
indexer/bootstrap path, and covered by Swift parity tests. Only update
TypeScript when a retained fixture generator or regression test still depends
on the old reference surface.

### Service Runtime
`Engram.app` launches and talks to the native `EngramService` helper over a
secure Unix socket. `EngramMCP` is the native stdio helper used by MCP clients.

- `EngramServiceRunner` owns service startup, schema/indexing, maintenance, and
  command dispatch.
- `EngramServiceCommandHandler` owns service commands, including project
  move/archive/undo/batch through the Swift project migration pipeline.
- App and MCP write paths must go through `EngramServiceClient` /
  `ServiceWriterGate`; do not add new direct app/MCP SQLite writers.
- `LegacyDaemonBridge`, `DaemonClient`, `DaemonHTTPClientCore`, app-local
  `MCPServer`, and the Node bundle phase are removed from the product path.

### Database
- Swift owns the product schema and writes through `EngramCoreWrite` /
  `EngramService`.
- App and read-only MCP paths use `EngramCoreRead` / GRDB read repositories.
- TypeScript DB code remains reference/dev tooling and tests; do not use it as
  the source of truth for Swift-only schema defaults.
- The old `scripts/db/check-swift-schema-compat.ts` gate was deleted on
  2026-05-08. Do not reintroduce Node schema compatibility as a Swift-only
  validation gate unless a current cross-runtime support requirement is
  explicitly restored.
- Schema changes: add idempotent Swift migrations and focused Swift tests. Keep
  fixture/dev TypeScript tests updated only where retained tooling depends on
  them.
- FTS: trigram tokenizer on `sessions_fts`. Product full re-index is governed
  by `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`
  `expectedVersion`; `src/core/db/fts-rebuild-policy.ts` is retained only for
  TypeScript reference tooling.

### Process Lifecycle
- Product runtime: `Engram.app` launches `EngramService`; MCP clients spawn
  `EngramMCP`.
- `EngramService` logs directly through `os_log` subsystem
  `com.engram.service`.
- Do not add product startup paths that shell out to `node`, run `npm`, or copy
  `dist`/`node_modules` into the app bundle.
- Historical TypeScript MCP, daemon, and HTTP/Web entrypoints were deleted; do
  not recreate product startup paths through Node.

### Session Tiering
Product tiering is computed in
`macos/Shared/EngramCore/Indexing/SessionTier.swift`; the TypeScript
`src/core/session-tier.ts` file is a reference/parity mirror only.

4 product tiers: `skip` / `lite` / `normal` / `premium`.
- `skip`: hidden/noise tier; index artifacts are removed and keyword search excludes it.
- `lite`: FTS only.
- `normal` / `premium`: FTS plus embedding job eligibility when embedding text changes.
UI/read-path filters hide `skip` sessions consistently; `lite` remains visible in list surfaces but is intentionally excluded from keyword search.

### Local Semantic Search
The shipped Swift service supports keyword search by default and opt-in
semantic/hybrid search when an embedding provider is configured. Semantic search
uses product-side stored embedding BLOBs with brute-force cosine KNN; hybrid
requests fuse keyword and semantic results with RRF. The old product-side
sqlite-vec probe/rebuild-policy scaffolding has been removed because it had no
runtime callers and did not drive the active Swift embedding path.

Hybrid search (TS reference): FTS5 (trigram) + sqlite-vec (vector embeddings) + RRF fusion. All local, no external services.
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
  5. **Layer 3 (manual)**: Swift service IPC commands. App callers use
     `EngramServiceClient.setParentSession`, `confirmSuggestion`, and
     `dismissSuggestion`; service handling lives in
     `EngramServiceCommandHandler`.
- Orphan trigger: `trg_sessions_parent_cascade` nullifies children on parent deletion + resets tier for re-evaluation.
- Tier lifecycle: subagent sessions always stay `skip` (accessed through parent, not independently); unlinked children get tier reset to NULL for re-evaluation. `downgradeSubagentTiers()` on daemon startup fixes any incorrectly upgraded sessions.
- Dispatch-pattern sessions without a parent get `agent_role = COALESCE(agent_role, 'dispatched')` → `tier = 'skip'`.
- `src/core/parent-detection.ts`: `DETECTION_VERSION` (bump to trigger re-evaluation), dispatch patterns + `PROBE_REGEXES`, `scoreCandidate()` (4h half-life, CWD classification, soft end_time handling), `pickBestCandidate()` (returns none/suggest/ambiguous decisions; runner-up scores within 90% of best become review-only ambiguous suggestions).
- `src/core/db/maintenance.ts`: `backfillCodexOriginator()` (reads file first 16KB for history), `resetStaleDetections()` (version-gated re-evaluation), `backfillSuggestedParents()` (no end_time SQL filter — scoring handles it; includes hidden parents).
- `src/core/db/parent-link-repo.ts`: validation (self-link, existence, depth=1), CRUD, child queries.
- `src/core/db/session-repo.ts`: `countTodayParentSessions()` for menu bar badge.
- Daemon startup order: `downgradeSubagentTiers → backfillParentLinks → resetStaleDetections → backfillCodexOriginator → backfillSuggestedParents`.
- Swift startup/indexing also runs `StartupBackfills.backfillPolycliProviderParents`
  before suggested-parent scoring. It classifies Polycli-launched provider
  sessions from `qwen`, `kimi`, `pi`, `copilot`, `opencode`, and `gemini-cli`
  as dispatched/skip when the prompt is a health ping, review probe, stage-fact
  probe, or same-cwd near-concurrent provider child.
- `SwiftIndexer.isSkippableFirstUserMessages` skips known Polycli probe
  prompts (`ping`, `POLYCLI_HEALTH_OK`, `No tools. Review...`, `No tools.
  Stage ... facts...`) so provider health/review children do not surface as
  independent sessions.
- OpenCode session size is measured per payload/session, not by assigning the
  whole SQLite DB file size to every session.
- Swift UI: `ExpandableSessionCard` with disclosure triangle + `CompactChildRow`. Used in HomeView, SessionsPageView, SessionListView, TimelinePageView.
- All three views filter `parent_session_id IS NULL AND suggested_parent_id IS NULL` for top-level display.
- Menu bar badge: shows today's parent session count (not total), via `todayParents` field in daemon events.

### Service ↔ Swift Communication
- App and MCP communicate with `EngramService` through framed JSON over a Unix
  socket via `UnixSocketEngramServiceTransport`.
- `UnixSocketEngramServiceTransport.events()` polls service status and maps it
  into app events for indexed counts and `todayParents`.
- Initial parent-session counts must be emitted only after parent-link / tier /
  provider-parent backfills complete.

### Local Service Security
- Swift production runtime is the authority: `EngramService` owns writes and
  exposes a Unix socket in a private runtime directory (`0700` parent, `0600`
  socket where the platform applies mode bits). Clients must pass the service
  capability token and peer-UID checks must match the current user.
- The Swift product does not serve an HTTP transcript Web UI. Product startup,
  app traffic, and MCP traffic should go through the Swift service stack.

## Conventions

- **Language**: TypeScript (strict, ES2022, Node16 modules) + Swift 5.9 (macOS 14+)
- **Linting**: Biome (enforced via pre-commit hook: husky + lint-staged). `npm run lint` must pass.
- **Imports**: Use `node:` prefix for Node.js builtins (`node:fs`, `node:path`, etc.)
- **Constants**: UPPER_SNAKE_CASE (`WATCHED_SOURCES`, `NOISE_FILTER_SQL`)
- **Error handling**: Adapters silently skip failures; DB errors propagate; tools return `isError: true`
- **Tests**: Vitest with real fixtures in `tests/fixtures/<adapter>/` for parser/DB
  behavior. Focused module mocks are acceptable for external service boundaries
  and failure injection when real file I/O would not exercise the contract.
- **Comments**: Chinese comments are intentional, keep them as-is
- **Swift DB reads**: Use `nonisolated` + `readInBackground` for all DatabaseManager read methods. Views call via `Task.detached { ... }.value` (see PopoverView.loadData as pattern).

## Build Output

- Xcode builds to: `~/Library/Developer/Xcode/DerivedData/Engram-*/Build/Products/{Debug,Release}/Engram.app`
- Do NOT use `macos/build/` — stale cache, gitignored
- Bundle must not include `Contents/Resources/node`, `node_modules`, `dist`,
  `daemon.js`, `index.js`, or `web.js`.
- Deploy to `/Applications`: must `rm -rf` first, then `cp -R`. `cp -R` silently skips running binaries.

## Data

- SQLite DB: `~/.engram/index.sqlite` (WAL mode)
- Settings: `~/.engram/settings.json`
- Session sources: `~/.claude/projects/`, `~/.codex/sessions/`, `~/.gemini/`, etc.
- `SessionAdapterFactory.defaultAdapters()` registers 17 source adapters: 14 are
  active by default and 3 (`cline`, `iflow`, `lobsterai`) are archived
  default-off sources that keep parser/fixture coverage but are not scanned until
  enabled from Sources > Archived. `minimax` remains active by default.
  Windsurf is cache-only in Swift; Antigravity is cache/transcript-only in Swift.
  Windsurf reads existing cache files under `~/.engram/cache/windsurf`;
  Antigravity reads Antigravity CLI brain transcripts and any legacy cache
  already present. "17 sources" is the adapter count, not the default-on source
  count or a live-gRPC source count.

## What NOT To Do

- Don't modify generated `Engram.xcodeproj` directly — edit `project.yml` and run `xcodegen generate`
- Don't commit `.sqlite` files, `node_modules/`, or `dist/`
- Don't add `summary_message_count` column — it already exists (migration is idempotent)
- Don't use `String(value)` for potentially undefined values in TS — use `(value as string) || ''`
- Don't add new DatabaseManager read methods without `nonisolated` — they'll block the main thread
- Don't use `hashValue` for cache keys — use the value itself (hash collisions are real)
- Don't skip `npm run lint` — pre-commit hook enforces it; CI enforces it too
- Don't mix vectors from different embedding models in the same vector space — use explicit provider selection
- Don't add Viking/OpenViking code — it was removed (2026-04-13). Use local sqlite-vec + FTS5 instead
- Don't re-enable idle timeout for MCP server (`idleTimeoutMs` in index.ts) — causes premature disconnect
- Don't add db methods directly to db.ts — add to the appropriate module in `src/core/db/`, facade in `database.ts` delegates
- Don't upgrade subagent tier from `skip` — subagent content is accessed through parent sessions, not independently. `setParentSession()` must NOT modify tier
- Don't add Node schema compatibility or Node bundle checks as current
  Swift-only gates. Historical migration plans may mention them; active CI must
  validate the Swift product/runtime path.

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
