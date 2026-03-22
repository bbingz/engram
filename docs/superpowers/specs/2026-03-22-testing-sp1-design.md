# Automated Testing Sub-project 1: Test Infrastructure + Swift Unit Tests + TS Coverage

**Date**: 2026-03-22
**Status**: Draft
**Scope**: Fixture DB, Swift unit tests (9 files, ~120 tests), TS coverage + gap filling, basic CI/CD
**Depends on**: Observability system (completed)
**Followed by**: Sub-project 2 (XCUITest UI automation + screenshot regression), Sub-project 3 (E2E + AI triage + release gating)

## Problem

Engram's TypeScript layer has 473 tests (vitest), but the macOS SwiftUI app (86 files, 12K+ LOC) has only 20 tests in one file. There is no fixture database, no schema version tracking, no CI/CD pipeline, and no test coverage measurement. When schema changes or Swift code breaks, nothing catches it until manual testing.

## Goals

1. Schema version tracking with fixture DB generation and CI validation
2. 9 Swift unit test files covering all testable core logic (~120 tests)
3. TypeScript test coverage measurement with gap filling (473 → ~520 tests, 65%+ coverage)
4. Basic CI/CD pipeline (TS tests + Swift unit tests + fixture validation)

## Non-Goals

- XCUITest UI automation (Sub-project 2)
- Screenshot comparison (Sub-project 2)
- E2E daemon→index→UI tests (Sub-project 3)
- AI-powered triage (Sub-project 3)
- Release gating (Sub-project 3)

---

## Layer 1: Fixture DB + Schema Version Management

### Schema Version Tracking

Add `SCHEMA_VERSION` as a named export in `src/core/db.ts`:

```typescript
export const SCHEMA_VERSION = 1
```

Store in a `metadata` table created during `migrate()`:

```sql
CREATE TABLE IF NOT EXISTS metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', '1');
```

Bump manually whenever schema changes. The constant and the stored value must match.

### Fixture Database Generator

`scripts/generate-test-fixtures.ts` — run via `tsx`:

- Creates a fresh SQLite file at `test-fixtures/test-index.sqlite`
- Uses the `Database` constructor from `src/core/db.ts` (same `migrate()` as production — guarantees identical schema including FTS5 trigram tokenizer)
- Disables WAL mode (`PRAGMA journal_mode=DELETE`) for single-file determinism
- Inserts 20 hardcoded seed sessions with explicit timestamps (no `Date.now()`, no PRNG):

| # | Source | Tier | Edge Case |
|---|--------|------|-----------|
| 1-2 | claude-code | normal | Standard sessions, 10+ messages |
| 3-4 | cursor | normal | Different project names |
| 5-6 | codex | lite | Low message count (2-3) |
| 7 | gemini-cli | premium | Has generated_title + summary |
| 8 | windsurf | normal | Long summary (2000 chars) |
| 9 | cline | normal | CJK: Chinese project name + Japanese summary |
| 10 | claude-code | skip | Agent subprocesses (has agent_role) |
| 11 | cursor | premium | Has auto-summary + high message count |
| 12 | codex | normal | Empty string project ("") |
| 13 | claude-code | normal | Null summary, null end_time (ongoing) |
| 14 | gemini-cli | normal | Zero messages (message_count = 0) |
| 15 | claude-code | normal | start_time == end_time |
| 16 | cursor | lite | Null project |
| 17 | windsurf | skip | Hidden (hidden_at set) |
| 18 | cline | normal | Custom name set |
| 19 | claude-code | normal | Very old session (2025-01-01) |
| 20 | codex | normal | Maximum tool_message_count (50) |

All timestamps are fixed ISO strings (e.g., `2026-01-15T10:00:00.000Z`). Running the generator twice produces byte-identical output.

Also seeds 3 favorites and 5 tags for testing extension table queries.

### Fixture Schema Checker

`scripts/check-fixture-schema.mjs`:

- Imports `SCHEMA_VERSION` from `../src/core/db.js` (via tsx — already a devDependency)
- Opens `test-fixtures/test-index.sqlite` read-only
- Reads `SELECT value FROM metadata WHERE key = 'schema_version'`
- Compares. Mismatch → exit 1 with clear error message.

### Shared Fixture Directory

`test-fixtures/` at project root:

- `test-index.sqlite` — generated fixture DB
- `sessions/` — JSONL fixture files (moved from `tests/fixtures/`)
  - Organized by source: `claude-code/`, `cursor/`, `codex/`, etc.

Both TS (`vitest.config.ts` updated paths) and Swift (`project.yml` resource reference) read from here.

### Git Handling

`.gitattributes`:
```
*.sqlite binary
```

Fixture committed directly (< 100KB). No LFS needed.

### CI Validation

Two checks run in parallel:
1. `check-fixture-schema.mjs` — version number match
2. Regenerate fixture + `git diff --exit-code test-fixtures/test-index.sqlite` — catches seed logic drift

---

## Layer 2: project.yml Test Targets

### EngramTests (unit tests)

```yaml
EngramTests:
  type: bundle.unit-test
  platform: macOS
  deploymentTarget: "14.0"
  sources:
    - path: EngramTests
  resources:
    - path: ../test-fixtures
      type: folder
  dependencies:
    - target: Engram
  settings:
    SWIFT_VERSION: "5.9"
    TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Engram.app/Contents/MacOS/Engram"
    BUNDLE_LOADER: "$(TEST_HOST)"
```

### EngramUITests (placeholder for Sub-project 2)

```yaml
EngramUITests:
  type: bundle.ui-testing
  platform: macOS
  deploymentTarget: "14.0"
  sources:
    - path: EngramUITests
  dependencies:
    - target: Engram
  settings:
    SWIFT_VERSION: "5.9"
```

After updating `project.yml`, run `xcodegen generate` to regenerate `.xcodeproj`.

---

## Layer 3: Swift Unit Tests

### Test Helpers (shared)

Extract from existing `DatabaseManagerTests.swift` into `EngramTests/TestHelpers.swift`:

- `createSessionsTable(at: String)` — creates minimal sessions + sessions_fts tables
- `insertTestSession(at:id:source:project:...)` — parameterized session insertion
- `createTempDatabase() -> (DatabaseManager, String)` — creates temp DB, returns manager + path for cleanup

`EngramTests/MockURLProtocol.swift`:

- Subclass of `URLProtocol` for intercepting `URLSession` requests
- Configurable response (status code, body, error)
- Used with `URLSessionConfiguration.ephemeral` (injected into `DaemonClient`)

### Test Files

**1. `DatabaseManagerTests.swift`** (expand 20 → 35 tests)

New tests to add:
- FTS search returns matching sessions
- FTS with CJK content (Chinese, Japanese) — tests LIKE fallback
- Tier filtering edge cases (null tier treated as normal)
- Observability table queries: `fetchLogs`, `errorsByModule24h`, `fetchTraces`, `observabilityTableCounts`
- Stats with empty database
- Multiple source filter combinations

**2. `MessageParserTests.swift`** (15 tests)

Test each source format's JSONL parsing:
- claude-code: `type`/`message` format
- cursor: `role`/`content` format
- codex: structured message format
- gemini-cli: specific field structure
- Malformed JSON line → skip, continue
- Empty file → empty result
- Mixed valid/invalid lines → only valid returned
- UTF-8 BOM handling
- Lines > 1MB → skip (OOM protection)

Uses real JSONL fixtures from `test-fixtures/sessions/`.

**3. `MessageTypeClassifierTests.swift`** (10 tests)

- `tool_use` detection
- `tool_result` detection
- `thinking` block detection
- `error` message detection
- `system` message detection
- Plain `assistant` text
- Plain `user` text
- Edge: empty content → defaults to type based on role
- Edge: content with multiple indicators → first match wins
- Edge: nil content → unknown

**4. `StreamingJSONLReaderTests.swift`** (10 tests)

- Reads well-formed JSONL file
- Handles UTF-8 correctly (CJK characters)
- Empty file → empty sequence
- File not found → error
- Malformed JSON lines → skipped
- Very long lines → handled without OOM
- Partial last line (no trailing newline) → still parsed
- Cancellation mid-stream
- Concurrent reads don't interfere
- Binary/non-text content → graceful failure

**5. `SessionModelTests.swift`** (10 tests)

- `init` from DB row
- `displayTitle` computed property: custom_name > generated_title > source fallback
- `duration` computed from start_time/end_time
- `duration` nil when end_time is nil
- Sorting by start_time descending
- Equatable: same id = equal
- Hashable: can be used in Set
- Edge: zero messages session
- Edge: very old session (2025 date)
- Source-specific icon mapping

**6. `IndexerProcessTests.swift`** (10 tests)

- Parse `{"event":"ready","indexed":10,"total":50}` status line
- Parse `{"event":"error","message":"..."}` error event
- Parse `{"event":"watcher_indexed","total":51}` watcher event
- Handle malformed JSON line → ignore
- Handle empty stdout line → ignore
- `autoStart=false` prevents process launch (via AppEnvironment.test)
- Multiple status events → latest state wins
- Parse viking_status event
- Parse web_ready event with port
- Handle process unexpected exit

**7. `DaemonClientTests.swift`** (10 tests)

DaemonClient accepts `init(port:session:)` for dependency injection. Tests use `MockURLProtocol`.

- `fetch()` sends GET with X-Trace-Id header
- `post()` sends correct Content-Type and body
- `fetch()` 404 → throws appropriate error
- `fetch()` network error → throws
- `fetch()` timeout → throws
- Response JSON parsing
- `delete()` sends DELETE method
- Custom port used in URL construction
- Empty response body → handled
- Concurrent requests don't deadlock

**8. `SourceColorsTests.swift`** (5 tests)

- All known sources map to non-nil color
- Unknown source → fallback color (not crash)
- Color consistency: same source → same color (deterministic)
- All 15 source names covered
- Color is not clear/transparent

**9. `ThemeTests.swift`** (5 tests)

- Spacing constants are positive
- Font sizes are reasonable (8-48 pt range)
- Color constants are non-nil
- `formatTimestamp` formats ISO string to readable form
- `formatTimestamp` handles malformed input → returns original string

### Test Lifecycle

- All tests use `setUpWithError()` / `tearDownWithError()` (not `setUp()`)
- Each test gets its own temp DB path (UUID in filename)
- Temp files cleaned up in `tearDownWithError()` (including `-wal`, `-shm`)
- No dependency on running daemon process
- No network calls (DaemonClient tests use MockURLProtocol)

---

## Layer 4: TypeScript Test Coverage + Gap Filling

### Coverage Configuration

Install `@vitest/coverage-v8` as devDependency.

`vitest.config.ts` additions:

```typescript
coverage: {
  provider: 'v8',
  include: ['src/**'],
  exclude: ['src/cli/index.ts', 'src/cli/resume.ts', 'src/daemon.ts'],
  thresholds: {
    lines: 60,
    branches: 50,
    functions: 55,
  },
  reporter: ['text', 'lcov'],
}
```

`package.json` additions:

```json
"test:coverage": "vitest run --coverage"
```

### Gap Filling (~47 new tests)

**`tests/core/db.test.ts`** (8 tests):
- `migrate()` creates all expected tables
- `migrate()` is idempotent (run twice, no error)
- `SCHEMA_VERSION` matches metadata table value
- Observability tables exist with correct columns
- `metrics_hourly` UNIQUE constraint works
- Session count with various filters
- WAL mode enabled
- Close is idempotent

**`tests/core/lifecycle.test.ts`** (3 tests):
- Signal handlers registered without throwing
- Idle timeout calls cleanup callback
- Parent process check handles missing PID

**`tests/core/config.test.ts`** (5 tests):
- Read settings with defaults
- Read settings with overrides
- `observability` config block parsed correctly
- Missing settings file → defaults
- Write + read roundtrip

**`tests/web/api.test.ts`** (10 tests):
- GET /health returns 200
- POST /api/log with valid body → 200
- POST /api/log with invalid level → 400
- POST /api/log with malformed JSON → 400
- POST /api/log with missing fields → 400
- OPTIONS preflight → correct CORS headers
- GET /api/sessions → returns list
- GET /api/sessions/:id → returns session or 404
- X-Trace-Id header propagated in response
- Unknown route → 404

**`tests/cli/utils.test.ts`** (5 tests):
- `parseDuration('30m')` → correct timestamp
- `parseDuration('1h')` → correct timestamp
- `parseDuration('7d')` → correct timestamp
- `parseDuration('')` → throws
- `parseDuration('1x')` → throws

**`tests/core/auto-summary.test.ts`** (5 tests):
- Uses `vi.useFakeTimers()` for time control
- Cooldown prevents re-trigger within window
- `minMessages` threshold respected
- Session with existing summary → `hasSummary` returns true
- `onSessionIndexed` triggers callback when conditions met

**`tests/adapters/edge-cases.test.ts`** (8 tests):
- Empty JSONL file → 0 messages
- File not found → skip (no throw)
- Corrupted JSON line → skip line, continue
- File with only whitespace → 0 messages
- Very large message (>1MB content) → still parsed
- Session directory doesn't exist → `detect()` returns false
- Adapter `listSessionFiles()` on empty dir → empty generator
- Mixed valid/invalid session files → valid ones processed

**`tests/core/db-migration.test.ts`** (3 tests):
- Fresh DB gets all tables
- Existing DB with old schema gets new tables added
- Migration is idempotent across multiple opens

Total: 473 + 47 = ~520 tests. Target coverage: 65%+ lines, 55%+ functions.

---

## Layer 5: CI/CD Pipeline

### `.github/workflows/test.yml`

Triggers: PR to main, push to main.

3 parallel jobs:

**Job 1: `typescript`** (ubuntu-latest, ~3 min)
```
- uses: actions/checkout@v4
- uses: actions/setup-node@v4 (node 20)
- npm ci
- npm run build
- npm test
- npm run test:coverage
- Upload coverage report as artifact
```

**Job 2: `swift-unit`** (macos-15, ~5 min)
```
- uses: actions/checkout@v4
- brew install xcodegen (if not cached)
- cd macos && xcodegen generate
- xcodebuild test -project Engram.xcodeproj -scheme EngramTests -destination 'platform=macOS'
```

**Job 3: `fixture-check`** (ubuntu-latest, ~1 min)
```
- uses: actions/checkout@v4
- uses: actions/setup-node@v4
- npm ci
- npm run build
- npx tsx scripts/check-fixture-schema.mjs
- npx tsx scripts/generate-test-fixtures.ts
- git diff --exit-code test-fixtures/test-index.sqlite
```

### macOS Runner Notes

- `macos-15` has Xcode 16+ pre-installed
- GRDB resolves via SPM (cached by GitHub Actions)
- No code signing needed for test-only builds (`CODE_SIGNING_ALLOWED=NO`)
- `xcodegen` installed via Homebrew (cache `~/Library/Caches/Homebrew`)

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Swift unit tests | 120+ tests across 9 files, all passing |
| TS tests | 520+ tests, all passing |
| TS coverage | lines ≥ 60%, branches ≥ 50%, functions ≥ 55% |
| CI pipeline | 3 jobs, all green on PR, < 8 min total |
| Fixture DB | Deterministic, schema-validated, < 100KB |
| Zero flaky tests | No time-dependent or order-dependent failures |
