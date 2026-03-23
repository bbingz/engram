# SP3e: Test Coverage Expansion

**Date**: 2026-03-23
**Status**: Draft
**Scope**: Gap #7 — fill test coverage gaps across adapters, MCP tools, web API, indexer, viking, sync

## Approach

Pure test additions — no implementation changes. Tests verify existing behavior is correct. If a bug is discovered, it's documented in the test (e.g., `// BUG: crashes instead of returning null`) but not fixed in this spec.

## New Tests by Group

### Group A: Adapter Edge Cases + Copilot (8 tests)

**`tests/adapters/copilot.test.ts`** (new, 4 tests):
- `name` is `'copilot'`
- `parseSessionInfo` returns valid SessionInfo from events.jsonl + workspace.yaml fixture
- `streamMessages` yields messages from events.jsonl
- `streamMessages` with `limit` truncates output

Requires `tests/fixtures/copilot/` directory with:
- `session-1/events.jsonl` — minimal events (session.start, user.message, assistant.message)
- `session-1/workspace.yaml` — `id: test-1\ncwd: /tmp\ncreated_at: 2026-01-01T00:00:00Z`

**`tests/adapters/edge-cases.test.ts`** (extend, 4 tests):
- Binary/non-UTF8 content in JSONL → corrupted lines skipped, no crash
- `parseSessionInfo` throws (not returns null) → caller handles gracefully
- `streamMessages` throws mid-stream → partial messages still readable
- File deleted between `listSessionFiles` yield and `parseSessionInfo` call → returns null

### Group B: MCP Tool Error Responses (10 tests)

**`tests/tools/tool-errors.test.ts`** (new):
Tests at handler function level (not MCP dispatch layer):
- `handleGetSession` with nonexistent session ID → returns error content
- `handleGetSession` with nonexistent adapter → error
- `handleExport` with nonexistent session → error
- `handleSearch` with empty query → returns empty results (not crash)
- `handleSearch` with invalid mode → graceful handling
- `handleGetContext` with nonexistent cwd → returns context (may be empty)
- `handleStats` with no data → returns zero stats
- `handleGetCosts` with no cost data → returns empty
- `handleToolAnalytics` with no data → returns empty
- `handleLintConfig` with nonexistent cwd → returns error or empty results

### Group C: Indexer Error Paths (5 tests)

**`tests/core/indexer.test.ts`** (extend):
- Mock adapter where `parseSessionInfo` throws Error → file skipped, indexing continues
- Mock adapter where `streamMessages` throws mid-stream → file skipped, no crash
- Mock adapter where `detect()` returns false → adapter skipped entirely
- `indexFile` with path to nonexistent file → returns `{ indexed: false }`
- `indexAll` with mix of good and bad files → good files indexed, bad skipped, count correct

### Group D: Web API Error Responses (4 tests)

**`tests/web/api.test.ts`** (extend):
- POST to `/api/*` without bearer token (when token configured) → 401
- POST to `/api/log` with oversized message (>10000 chars) → truncated, still 200
- GET `/api/sessions/nonexistent-id` → 404 with error message
- Request with X-Trace-Id header → same ID returned in response header

### Group E: Viking + Sync Error Handling (6 tests)

**`tests/core/viking-bridge.test.ts`** (extend):
- Circuit breaker recovery: after TTL expires, next call succeeds → breaker resets
- HTTP 500 on push → retries, eventually throws
- Push with network error (fetch rejects) → graceful error, circuit breaker opens

**`tests/core/sync.test.ts`** (extend):
- Peer returns malformed JSON → sync fails gracefully, cursor not advanced
- Peer returns HTTP 500 → sync error, no crash
- Peer returns 401 → sync error, no crash

**Total: ~33 new tests**

## Files Changed

| File | Change |
|------|--------|
| `tests/adapters/copilot.test.ts` | New: 4 tests |
| `tests/fixtures/copilot/session-1/events.jsonl` | New: fixture |
| `tests/fixtures/copilot/session-1/workspace.yaml` | New: fixture |
| `tests/adapters/edge-cases.test.ts` | Extend: 4 tests |
| `tests/tools/tool-errors.test.ts` | New: 10 tests |
| `tests/core/indexer.test.ts` | Extend: 5 tests |
| `tests/web/api.test.ts` | Extend: 4 tests |
| `tests/core/viking-bridge.test.ts` | Extend: 3 tests |
| `tests/core/sync.test.ts` | Extend: 3 tests |

## Out of Scope

- Implementation fixes for any bugs discovered
- P2 items: large file (>1GB) testing, SQL injection fuzzing, concurrent request tests
- Usage probe adapter tests (`claude-usage-probe.ts`, `codex-usage-probe.ts`)
- Watcher tests (requires chokidar mocking, complex setup)
