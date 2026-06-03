# Engram Code Review Issues

This document records the verified issues found during the 5-round multi-agent code review.

## Round 1: Data Layer (DB, Vector Store, Embeddings)

### `ts_node_expert` Findings

1. **Memory Leak & Event Loop Block (Node.js Best Practice)**
   - **File**: `src/core/embeddings.ts`
   - **Issue**: In `embedWithOllama`, a 60-second `setTimeout` is triggered to reset the `ollamaDown` flag on fetch failure. Missing `.unref()` prevents the process from exiting gracefully, and concurrent failures spawn redundant timeouts.
   - **Fix**: Add a guard and use `.unref()` on the timer.

2. **Unbounded Set Memory Leak**
   - **File**: `src/core/embedding-indexer.ts`
   - **Issue**: `EmbeddingIndexer` tracks processed sessions using an in-memory `Set<string>` (`this.indexed`) that only grows, leading to a memory leak in long-running instances.
   - **Fix**: Provide a `remove(sessionId)` method or replace the Set with an optimized SQL query for unindexed IDs.

3. **Async Pagination Race Condition (Skipped Records)**
   - **File**: `src/core/embedding-indexer.ts`
   - **Issue**: `indexAll()` uses offset-based pagination. Yielding to the event loop allows concurrent DB changes, altering the sort order and causing skipped or duplicate sessions.
   - **Fix**: Use cursor-based pagination (e.g., `WHERE updated_at > ?`) or exclusively query unindexed records.

4. **Transaction Thrashing Anti-Pattern (Performance)**
   - **File**: `src/core/vector-store.ts`
   - **Issue**: `upsertInsight` dynamically creates and executes a new transaction wrapper on every call instead of reusing a compiled one.
   - **Fix**: Declare `upsertInsightTxn` statically in `prepareStatements()`.

5. **Type Safety with Dynamic Imports**
   - **File**: `src/core/embeddings.ts`
   - **Issue**: `transformersPipeline` is explicitly typed as `any`, disabling downstream type checking.
   - **Fix**: Define a minimal explicit type or default to `unknown` and cast safely.

6. **Unsafe DB Return Assumptions (Type Safety)**
   - **File**: `src/core/vector-store.ts`
   - **Issue**: The code hard-casts DB responses (e.g., `as { ... }[]`), hiding runtime errors if the SQL schema shifts.
   - **Fix**: Parse raw rows through a lightweight schema validator (like Zod) or explicitly verify keys.

### `architecture_expert` Findings

1. **Storage Leak & "Ghost" Search Results (Lifecycle Misalignment)**
   - **Locations**: `src/core/db/session-repo.ts` (`deleteSession`) and `src/core/vector-store.ts`
   - **Issue**: Deleting a session does not cascade to `session_chunks`, `vec_sessions`, or `vec_chunks`. Orphaned vectors remain and surface in searches.
   - **Fix**: Implement manual deletion routines or database triggers to clean up virtual vector tables and chunks when sessions are deleted.

2. **Schema Migration Race Conditions**
   - **Location**: `src/core/db/migration.ts` (`runMigrations`)
   - **Issue**: Schema migrations lack `BEGIN IMMEDIATE` transactions, making them vulnerable to TOCTOU races in multi-process environments (causing crashes due to `duplicate column name`).
   - **Fix**: Wrap migration and check-and-modify logic in a proper database transaction with locking.

3. **Data Duplication & Divergence Risk for Insights**
   - **Locations**: `src/core/db/migration.ts` vs. `src/core/vector-store.ts`
   - **Issue**: Insight text is redundantly stored in `insights` and `memory_insights`. Relying on a fragile background sync could leave tables permanently out of sync on crashes.
   - **Fix**: Avoid duplicated storage; have `vector-store.ts` join directly against the `insights` table for metadata.

4. **Leaky Abstractions & Conflicting Schema Ownership**
   - **Locations**: `src/core/db/database.ts` and `src/core/vector-store.ts`
   - **Issue**: `SqliteVecStore` accesses the raw DB and performs uncoordinated migrations, colliding with `migration.ts` over the `metadata` table constraints (`value TEXT` vs `value TEXT NOT NULL`).
   - **Fix**: Centralize all schema migrations in `migration.ts` and stop exposing `getRawDb()`.

5. **Unsafe Synchronous VACUUM**
   - **Location**: `src/core/db/maintenance.ts` (`vacuumIfNeeded`)
   - **Issue**: Executing `VACUUM` synchronously blocks all queries, potentially causing widespread `SQLITE_BUSY` timeouts across processes.
   - **Fix**: Perform VACUUM out-of-band or via an auto-vacuum pragma instead of a synchronous block.

### `sqlite_expert` Findings

1. **Severe N+1 & Missing Transactions in `vector-store.ts`**
   - **Issue**: Vector deletion methods (e.g., `deleteChunksBySession`) execute multiple state-modifying statements outside of a transaction. The N+1 synchronous SQLite auto-commits cause massive bottlenecks and risk data divergence.
   - **Fix**: Wrap operations in `this.db.transaction()` and replace loop-based chunk deletions with batch `DELETE` queries (`DELETE FROM vec_chunks WHERE chunk_id IN ...`).

2. **O(N²) Correlated Subquery Bottleneck in `fts-repo.ts`**
   - **Issue**: The CJK fallback search (`searchSessionsLike`) uses a highly inefficient correlated subquery for grouping results (`SELECT MIN(f2.rowid)...`). This evaluates the `LIKE` full-text scan for every matched row, leading to quadratic time complexity.
   - **Fix**: Replace the correlated subquery with a window function (`ROW_NUMBER() OVER(PARTITION BY ...)`) in a derived table.

3. **Pagination Deadlock in `backfillParentLinks` (`maintenance.ts`)**
   - **Issue**: Fetches candidate subagents via `LIMIT 500`. If `validateParentLink` fails, it continues without updating session state, causing failed records to repeatedly match the query and eventually deadlocking the backfill loop.
   - **Fix**: Use `OFFSET` pagination or mark failed records with a flag (e.g., `link_checked_at`) to remove them from the candidate set.

4. **Inefficient Schema Polling in Hot Path (`database.ts`)**
   - **Issue**: `deleteIndexArtifacts` polls `sqlite_master` on every deletion to safely delete embeddings, adding metadata query overhead and potential schema locks.
   - **Fix**: Remove schema polling and wrap the deletion statement in a `try/catch` block to handle missing tables natively.

## Round 2: Indexing & Sync Pipeline (Background Tasks)

### `sqlite_expert` Findings

1. **Missing Transaction in `backfillCosts` (Risk of Permanent Data Loss)**
   - **Location**: `src/core/indexer.ts` -> `backfillCosts()` and `writeExtractedData()`
   - **Issue**: `writeExtractedData()` executes multiple DB insertions without a transaction wrapper when called from `backfillCosts()`. A crash mid-execution marks the session as having costs but skips backfilling tools and files permanently.
   - **Fix**: Wrap the database write operations inside `writeExtractedData` or `backfillCosts` in a `this.db.getRawDb().transaction()` block.

2. **N+1 Query Problems in Backfill Tasks**
   - **Location**: `src/core/indexer.ts` -> `backfillCounts()` and `backfillCosts()`
   - **Issue**: Queries loop over IDs to call `getSession(id)`, causing significant context-switching overhead between JS and SQLite bindings for thousands of records.
   - **Fix**: Modify queries to return full required fields directly or batch the `getSession` fetching using an `IN (...)` clause.

3. **Inefficient Uncached Prepared Statements**
   - **Location**: `src/core/indexer.ts` -> `generateTitleIfNeeded()`
   - **Issue**: New SQLite statements are prepared on every invocation. Since `better-sqlite3` does not cache them natively, this CPU-intensive operation tanks indexing throughput.
   - **Fix**: Move these queries into the `Database` wrapper and cache the prepared statements at startup.

4. **Redundant Map Allocation in `writeExtractedData`**
   - **Location**: `src/core/indexer.ts` -> `writeExtractedData()`
   - **Issue**: A loop pointlessly reconstructs a map using the exact same pre-formatted keys (`${path}\0${val.action}`).
   - **Fix**: Remove the mapping loop and pass the original `fileCounts` map directly.

### `ts_node_expert` Findings

1. **Unhandled Promise Rejections in Event Emitters**
   - **Location**: `src/core/watcher.ts`
   - **Issue**: `handleChange` is an async function attached to an event listener. If an awaited promise rejects, the unhandled rejection crashes Node (>= 15).
   - **Fix**: Wrap the entire body of `handleChange` in a `try/catch`.

2. **Uncaught Exception in Synchronous Listener**
   - **Location**: `src/core/watcher.ts`
   - **Issue**: `opts.shouldSkip?.(filePath)` is called outside the `try/catch` in the `unlink` listener. Exceptions here will crash the app.
   - **Fix**: Move the evaluation inside the `try/catch` block.

3. **False Negatives on Indexing Success**
   - **Location**: `src/core/indexer.ts`
   - **Issue**: `generateTitleIfNeeded` runs after session data is written to the database. If it fails (e.g., API error), it aborts the caller, tricking the system into marking the overall indexing step as failed (preventing UI updates).
   - **Fix**: Wrap title generation inside a `try/catch` so failures gracefully degrade.

4. **Infinite Loop Vulnerability in Chunker**
   - **Location**: `src/core/chunker.ts`
   - **Issue**: If `overlap` >= `maxChars`, the `step` becomes `0` or negative. The `for` loop will spin infinitely, causing a complete thread lock and OOM.
   - **Fix**: Clamp `overlap` safely (`Math.min(overlap, windowSize - 1)`) and ensure `step` is at least `1`.

5. **Event Loop Starvation**
   - **Location**: `src/core/indexer.ts`
   - **Issue**: `backfillCounts()` processes thousands of sessions synchronously inside a loop without yielding, which locks the event loop.
   - **Fix**: Add a short timeout (`await new Promise(r => setImmediate(r))`) in the fallback loop.

6. **TypeScript Best Practices & Edge Cases**
   - **Location**: `src/core/indexer.ts`
   - **Issues**:
     - `Indexer.FILE_TOOLS` uses loose `Record<string, string>`. Should be `Record<string, 'read' | 'edit' | 'write'>`.
     - `fileCounts` uses brittle composite string keys (`${fp}\0${action}`) instead of typed nested Maps.
     - `stat(filePath)` indiscriminately swallows errors (like `ENOENT`) which hides real filesystem sync issues.

### `architecture_expert` Findings

1. **Architectural Flaw: Full-Text Search (FTS) Message Loss**
   - **Location**: `src/core/indexer.ts` and `src/core/index-job-runner.ts`
   - **Issue**: `Indexer` parses messages but delegates FTS population to `IndexJobRunner`, which explicitly overwrites FTS content with only metadata. Chat messages become completely unsearchable.
   - **Fix**: Have `indexer.ts` explicitly call `this.db.indexSessionContent(...)` during its synchronous DB transaction to preserve the full conversational content in the FTS table.

2. **Race Condition: Concurrent File Parsing in Watcher**
   - **Location**: `src/core/watcher.ts` and `src/core/indexer.ts`
   - **Issue**: `handleChange` does not debounce concurrent invocations. If a file is rapidly updated (LLM streaming), older slower parses can overwrite the DB state with stale snapshot data during the synchronous write phase.
   - **Fix**: Implement a per-file mutex or sequential queue to ensure `indexFile` executes strictly sequentially for any given `filePath`.

3. **Retry Mechanic Flaw: Permanent Data Loss on Transient Read Errors**
   - **Location**: `src/core/indexer.ts` (`backfillCosts` method)
   - **Issue**: If `streamMessages` throws a transient error (e.g., file lock), the `catch` block intentionally writes `0` for all costs. This marks the session as processed and permanently excludes it from future backfills.
   - **Fix**: Do not write zero-costs on stream failures; allow the error to bubble or leave the row unwritten so it can be retried later.

4. **Retry Mechanic Flaw: Silent Chunk Skips in Embeddings**
   - **Location**: `src/core/index-job-runner.ts` (`indexChunks` method)
   - **Issue**: If `this.client.embed(chunk.text)` returns `undefined` (due to transient API rate limits), the chunk is silently omitted without failing the job, permanently excluding it from vector search.
   - **Fix**: Throw an explicit error if `emb` is undefined to fail the entire job, triggering the built-in retry mechanic.

## Round 3: Adapters (Log Parsers)

### `ts_node_expert` Findings

1. **Memory Leaks / Sync IO in Hot Paths**
   - **`antigravity.ts`**: Uses `await readFile(filePath)` and then slices the string to read the first 50KB. For huge transcript JSONL files, this buffers the entire file into memory synchronously. **Fix**: Use a filehandle (`fs/promises.open`) to read exactly 50KB into a buffer.
   - **`cursor.ts`**: Uses `.all()` on `better-sqlite3` queries to fetch rows from `cursorDiskKV` (which holds massive JSON payloads). This buffers all results simultaneously. **Fix**: Use `.iterate()` instead for lazy evaluation.

2. **Unhandled Promise Rejections & Stream Errors**
   - **`claude-code.ts`**: `readdir` loop lacks inner `try/catch`. If one project directory fails to read (e.g., permissions), the outer loop aborts, skipping all remaining valid projects. **Fix**: Wrap `readdir` in an inner try/catch.
   - **All Adapters**: File streams passed to `readline` do not have `.on('error')` listeners. Node can crash on unhandled stream errors if the underlying file errors mid-read. **Fix**: Attach `.on('error', () => {})` to streams.

3. **TS Strict Typing (Unsafe `any` & `JSON.parse` casts)**
   - **`antigravity.ts`, `windsurf.ts`, `cursor.ts`, `claude-code.ts`**: These adapters explicitly cast `JSON.parse(row.value)` as specific object types. If a value is primitive (like `null` or a string), destructuring or property access throws `TypeError`.
   - **Fix**: Parse as `unknown` and validate the object type (`typeof data === 'object' && data !== null`) before accessing keys.

### `architecture_expert` Findings

1. **State Management: Database Connection Leaks across Async Boundaries**
   - **Location**: `src/adapters/cursor.ts` and `src/adapters/opencode.ts`
   - **Issue**: `streamMessages()` holds an open SQLite connection while yielding through an `async *` generator. If consumers suspend or read slowly, the synchronous DB connection remains locked across multiple event loop ticks, potentially causing read-lock starvation.
   - **Fix**: Since the query uses `.all()`, the dataset is already buffered in memory. Close the DB connection *before* entering the `for` loop to yield.

2. **Error Boundaries: Non-atomic Cache Writes Cause Permanent Corruption**
   - **Location**: `src/adapters/antigravity.ts` and `src/adapters/windsurf.ts`
   - **Issue**: The adapters write directly to local JSONL cache files. If interrupted mid-write, the file corrupts. Since cache validity relies only on `mtime`, the system will attempt to parse the corrupted file forever, permanently erasing the session from view.
   - **Fix**: Write to a temporary file and use `fs.rename` for atomic file creation. Implement more robust cache validation.

3. **Separation of Concerns: Read/Write Entanglement and Sync Side-Effects**
   - **Location**: `src/adapters/*` (e.g., `antigravity.ts`, `windsurf.ts`)
   - **Issue**: `listSessionFiles()`, which implies a read-only list operation, secretly performs expensive I/O and initiates network calls via `.sync()`. Furthermore, presentation layer concerns (markdown formatting, tool filtering) are hardcoded into adapters.
   - **Fix**: Extract synchronization into a dedicated manager and decouple formatting logic so adapters remain strictly data extractors.

## Round 4: API & Tools Layer (`src/web.ts`, `src/web/`, `src/tools/`)

### `architecture_expert` Findings

1. **Separation of Concerns & Modularity**
   - **Inline Business Logic**: High-level business logic (file crawling, LLM orchestration) is hardcoded directly inside Hono route handlers (e.g., `/api/titles/regenerate-all`, `/api/summary`).
   - **Leaked MCP Definitions**: MCP tool schemas and logic (`manage_project_alias`, `hide_session`) are hardcoded into the setup sequence in `src/index.ts` instead of being modularized in `src/tools/`.
   - **Fix**: Move route business logic into controller modules, and unify all MCP tool registrations into `src/tools/`.

2. **Error Boundaries & API Resilience**
   - **Missing Global Error Boundary**: The Hono app lacks an `app.onError` middleware. Uncaught exceptions fall through to Hono's default handler, returning plain-text errors that violate the JSON API contract expected by clients.
   - **Fix**: Implement a global `app.onError` middleware to catch and format exceptions into standardized JSON envelopes.

3. **State Management & Concurrency**
   - **Unmanaged Background Tasks**: `/api/titles/regenerate-all` spawns an untracked background IIFE promise. Concurrent hits to this endpoint will spin up duplicate LLM polling loops. Rejections inside the IIFE crash the process.
   - **Fix**: Offload title regeneration to the existing `BackgroundMonitor` or job runner, and implement a mutex to prevent redundant execution.

### `ts_node_expert` Findings

1. **Error Handling: Unhandled Hono API Errors**
   - **Issue**: Missing global `app.onError` in `src/web.ts` means unhandled request errors (like JSON parsing) default to plain-text 500s instead of standard JSON envelopes.
   - **Fix**: Add a global `app.onError` to catch and format exceptions safely as JSON.

2. **Type Safety & Insecure Payload Parsing**
   - **Issue**: API routes use blind `c.req.json<Type>()` casting. Passing invalid payload structures (e.g., objects where strings are expected) bypasses truthiness checks but crashes `better-sqlite3` later.
   - **Fix**: Use Zod or basic runtime type guards (`typeof body.parentId === 'string'`) to validate shapes before trusting payload data.

3. **Error Handling & Memory Leaks in Streams**
   - **Location**: `src/tools/export.ts`
   - **Issue**: `handleExport` writes to a stream awaiting `once(stream, 'finish')` without handling `'error'` events. Disk errors will crash Node.js or cause indefinite hangs and memory leaks.
   - **Fix**: Use modern Node stream abstractions like `pipeline` or `finished` from `node:stream/promises`.

4. **Performance: N+1 DB Queries & Loop Preparation**
   - **Location**: `src/web.ts`
   - **Issue**: `liveSessionsPayload` compiles a `.prepare()` query dynamically inside a `.map()` loop, adding unnecessary overhead per iteration.
   - **Fix**: Hoist the `.prepare()` statement or batch query using an `IN (...)` clause.

5. **Silent Error Swallowing**
   - **Location**: `src/tools/lint_config.ts`
   - **Issue**: `readPackageJsonScripts` catches `JSON.parse` syntax errors and returns `null` silently, hiding invalid user config.
   - **Fix**: Log a warning or push an explicit `LintIssue` about the invalid JSON.

## Round 5: CLI, Daemon & Integration

### `architecture_expert` Findings

1. **Signal Orchestration & Graceful Shutdown (Data Loss Risk)**
   - **Locations**: `src/daemon.ts` and `src/core/lifecycle.ts`
   - **Issue**: Process exits (`process.exit(0)`) are called synchronously during SIGINT/TERM without awaiting the shutdown of the Hono web server or ongoing asynchronous tasks. This instantly aborts mid-flight write operations and database queries, bypassing application rollback logic and risking severe data corruption.
   - **Fix**: Implement an asynchronous shutdown sequence. Await `webServer.close()` and provide a grace period for active background tasks to finish or cleanly abort before closing the database connection and exiting.

2. **Architectural Boundary: The "Fail-Closed" Fallback is Dead Code**
   - **Locations**: `src/index.ts` and `src/core/daemon-client.ts`
   - **Issue**: Project mutation tools (`project_move`, etc.) have local fallback execution blocks (`handleProjectMove`) in `src/index.ts` intended to run if the Daemon is unreachable. However, the configuration `failClosedProjectMutationTools` hardcodes these tools to `strict = true`, making the fallback check unconditionally fail.
   - **Fix**: Delete the unreachable direct execution logic to clarify the architectural intent that these operations are strictly "fail-closed".

3. **Systemic Single-Writer Constraint Violations (Split Brain)**
   - **Locations**: `src/index.ts` (`hide_session`, `delete_insight`)
   - **Issue**: Despite the Phase B "single-writer" architecture requiring all writes to be routed through the Daemon, several tools execute direct local writes against the DB from within the MCP server process. This blatantly bypasses the `mcpStrictSingleWriter` setting, leading to concurrent SQLite writes and `SQLITE_BUSY` errors.
   - **Fix**: Remove direct writes from the MCP process for these tools and implement proper Daemon HTTP endpoints for them.

### `ts_node_expert` Findings

1. **Abrupt Daemon Shutdown & Process Exits**
   - **Location**: `src/daemon.ts`
   - **Issue**: `wrappedShutdown` calls `process.exit(0)` synchronously, abandoning asynchronous teardowns for `webServer.close()` and file watchers. This leads to dropped HTTP requests and incomplete WAL flushes.
   - **Fix**: Return an async function from `createShutdownHandler` that `await`s the server/watcher closures before exiting.

2. **Unsafe Child Process Execution**
   - **Location**: `src/cli/resume.ts`
   - **Issue**: `spawnSync` is used to launch interactive AI CLIs, blocking the Node event loop and mishandling OS signals like SIGINT, leading to orphaned processes.
   - **Fix**: Use async `spawn` with `stdio: 'inherit'` and handle OS signals properly.

3. **Unhandled Promise Rejections in CLI Dispatcher**
   - **Location**: `src/cli/index.ts`
   - **Issue**: Dynamic imports for CLI subcommands lack `.catch()`. If an import fails or throws synchronously, it crashes the process with a raw stack trace.
   - **Fix**: Append `.catch(...)` to all dynamic import chains to gracefully handle and log errors.

4. **Synchronous Crash on Malformed IPC Emission**
   - **Location**: `src/daemon.ts` (`emit`)
   - **Issue**: `JSON.stringify(obj)` is called synchronously for IPC. Circular references inside error objects will throw a `TypeError`, instantly crashing the Daemon.
   - **Fix**: Wrap IPC serialization in a `try/catch` block and fallback to an error event payload.

5. **Testing Infrastructure Gaps**
   - **Location**: `tests/core/monitor.test.ts`, `tests/core/live-sessions.test.ts`
   - **Issue**: Missing `afterAll` hooks to close DB connections cause SQLite handle leaks and flaky "database is locked" errors. Background `setInterval` timers are leaked if tests fail mid-execution.
   - **Fix**: Use `afterAll(() => db.close())` and properly tear down `.stop()` timers in `afterEach`.
