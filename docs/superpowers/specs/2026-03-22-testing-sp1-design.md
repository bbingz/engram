# Automated Testing Sub-project 1: Test Infrastructure + Swift Unit Tests + TS Coverage

**Date**: 2026-03-22
**Status**: Draft
**Scope**: Fixture DB, Swift unit tests (9 files, ~120 tests), TS coverage + gap filling, basic CI/CD
**Depends on**: Observability system (completed)
**Followed by**: Sub-project 2 (XCUITest UI automation + screenshot regression), Sub-project 3 (E2E + AI triage + release gating)

## Problem

Engram's TypeScript layer has 473 tests (vitest), but the macOS SwiftUI app (91 files, ~44K LOC) has only 20 tests in one file. There is no fixture database, no schema version tracking, no CI/CD pipeline, and no test coverage measurement. When schema changes or Swift code breaks, nothing catches it until manual testing.

## Goals

1. Schema version tracking with fixture DB generation and CI validation
2. 9 Swift unit test files covering all testable core logic (~120 tests)
3. TypeScript test coverage measurement with gap filling (473 → ~508 tests, 65%+ coverage)
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

Store in the existing `metadata` table (already used by `fts_version`) during `migrate()`:

```sql
-- metadata table already exists (created for fts_version)
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

`scripts/check-fixture-schema.ts` — run via `tsx`:

- Imports `SCHEMA_VERSION` from `../src/core/db.js`
- Opens `test-fixtures/test-index.sqlite` read-only via better-sqlite3
- Reads `SELECT value FROM metadata WHERE key = 'schema_version'`
- Compares. Mismatch → exit 1 with clear error message.

### Shared Fixture Directory

`test-fixtures/` at project root:

- `test-index.sqlite` — generated fixture DB
- `sessions/` — JSONL fixture files for Swift tests (subset copied from `tests/fixtures/`)
  - Organized by source: `claude-code/`, `codex/`, `gemini-cli/`, etc.
  - Note: existing TS fixtures stay in `tests/fixtures/` to avoid mass path updates in 473 tests

Both TS (via existing `tests/fixtures/`) and Swift (`project.yml` resource reference to `test-fixtures/`) access their respective fixtures.

### Git Handling

`.gitattributes`:
```
*.sqlite binary
```

Fixture committed directly (< 100KB). No LFS needed.

### CI Validation

Two checks run in parallel:
1. `check-fixture-schema.ts` — version number match
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
      # XcodeGen resolves paths relative to project.yml (macos/), so ../test-fixtures → project root.
      # Verify with: xcodegen generate && grep test-fixtures Engram.xcodeproj/project.pbxproj
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
- Observability table queries: `fetchLogs`, `errorsByModule24h`, `fetchTraces`, `observabilityTableCounts` (Note: observability tables are created by the Node daemon's migrate(), not by DatabaseManager.open(). Test setup must create these tables via raw SQL.)
- Stats with empty database
- Multiple source filter combinations

**2. `MessageParserTests.swift`** (15 tests)

Test each source format's parsing:
- claude-code: `type`/`message` JSONL format
- codex: structured JSONL message format
- gemini-cli: specific field structure
- Note: cursor uses `.vscdb` (SQLite), not JSONL — test cursor parsing separately with a `.vscdb` fixture if available
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
- Edge: empty string content + assistant role → .assistant

**4. `StreamingJSONLReaderTests.swift`** (10 tests)

- Reads well-formed JSONL file
- Handles UTF-8 correctly (CJK characters)
- Empty file → empty sequence
- File not found → error
- Malformed JSON lines → skipped
- Very long lines → handled without OOM
- Partial last line (no trailing newline) → still parsed
- Stop iteration early (break mid-sequence) — no resource leak
- Concurrent reads don't interfere
- Binary/non-text content → graceful failure

**5. `SessionModelTests.swift`** (10 tests)

- `init` from DB row
- `displayTitle` computed property: custom_name > generated_title > summary > "Untitled"
- `formattedSize` returns human-readable size string
- `sizeCategory` returns correct category for various sizes
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
- Parse summary_generated event
- Parse web_ready event with port
- Handle process unexpected exit

**7. `DaemonClientTests.swift`** (10 tests)

**Prerequisite**: Modify `DaemonClient` to accept an optional `URLSession` parameter:
```swift
init(port: Int = 3457, session: URLSession = .shared)
```
Currently `DaemonClient` hardcodes `URLSession.shared`. This change enables `MockURLProtocol` injection for testing without affecting production behavior (default is `.shared`).

Tests use `MockURLProtocol` via injected `URLSessionConfiguration.ephemeral` session.

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

### Gap Filling (~35 net-new tests)

Note: some target files already exist. Where noted, expand with new tests (check for duplicates first).

**`tests/core/db.test.ts`** (expand — file exists, add ~5 new tests):
- `SCHEMA_VERSION` matches metadata table value
- Observability tables exist with correct columns
- `metrics_hourly` UNIQUE constraint works
- Close is idempotent
- Schema migration adds new tables to existing DB

**`tests/core/lifecycle.test.ts`** (3 tests):
- Signal handlers registered without throwing
- Idle timeout calls cleanup callback
- Parent process check handles missing PID

**`tests/core/config.test.ts`** (expand — file exists, add ~2 new tests):
- `observability` config block parsed correctly
- Write + read roundtrip for new fields

**`tests/web/api.test.ts`** (10 tests):

Testing approach: Use Hono's built-in `app.request()` method (no real HTTP server needed). Create app via `createApp(db)` with in-memory DB, then call `app.request('/health')` etc. This avoids port conflicts and is faster than starting a real server.

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

**`tests/core/auto-summary.test.ts`** (expand — file exists, add ~2 new tests):
- Uses `vi.useFakeTimers()` for time control
- Cooldown prevents re-trigger within window (if not already covered)

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

Total: 473 + ~35 net-new = ~508 tests. Target coverage: 65%+ lines, 55%+ functions.

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
- xcodebuild test -project Engram.xcodeproj -scheme Engram -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Note: `EngramTests` is part of the `Engram` scheme's test plan (XcodeGen default). Use `-scheme Engram`, not `-scheme EngramTests`. Add a `schemes:` entry in `project.yml` if a separate test scheme is needed later.

**Job 3: `fixture-check`** (ubuntu-latest, ~1 min)
```
- uses: actions/checkout@v4
- uses: actions/setup-node@v4
- npm ci
- npm run build
- npx tsx scripts/check-fixture-schema.ts
- npx tsx scripts/generate-test-fixtures.ts
- git diff --exit-code test-fixtures/test-index.sqlite
```

### Cache Strategy

macOS runners are expensive (~$0.08/min). Aggressive caching saves 1-2 min per run:

- **Node modules**: `actions/setup-node@v4` with `cache: 'npm'` (built-in)
- **SPM packages**: `actions/cache@v4` on `~/Library/Developer/Xcode/DerivedData/**/SourcePackages`
  - Key: `spm-${{ hashFiles('macos/Engram.xcodeproj/project.pbxproj') }}`
- **Homebrew (xcodegen)**: `actions/cache@v4` on `~/Library/Caches/Homebrew`
  - Key: `brew-xcodegen-${{ runner.os }}`

### macOS Runner Notes

- `macos-15` has Xcode 16+ pre-installed
- GRDB resolves via SPM (cached per above)
- No code signing needed for test-only builds (`CODE_SIGNING_ALLOWED=NO`) — prevents keychain prompts
- `xcodegen` installed via Homebrew (cached per above)

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Swift unit tests | 120+ tests across 9 files, all passing |
| TS tests | 508+ tests, all passing |
| TS coverage | lines ≥ 60%, branches ≥ 50%, functions ≥ 55% |
| CI pipeline | 3 jobs, all green on PR, < 8 min total |
| Fixture DB | Deterministic, schema-validated, < 100KB |
| Zero flaky tests | 2-week observation: no random failures across CI runs. Initial validation: 3 consecutive green runs on same commit. |
