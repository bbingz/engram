# Stage Gates

These gates define when each migration stage can advance. They are intentionally concrete so future implementation agents can verify without relying on memory from earlier sessions.

## Stage0 Baseline

- `rtk npm test -- tests/scripts/capture-node-baseline.test.ts` passes.
- `rtk sh -lc 'test -f docs/swift-single-stack/inventory.md'` exits `0`.
- `rtk sh -lc 'test -f docs/swift-single-stack/file-disposition.md'` exits `0`.
- `rtk sh -lc 'test -f docs/swift-single-stack/app-write-inventory.md'` exits `0`.
- `rtk sh -lc 'test -f docs/swift-single-stack/baseline-inventory.md'` exits `0`.
- `rtk sh -lc 'test -f docs/swift-single-stack/performance-baseline.md'` exits `0`.
- `rtk sh -lc 'test -f docs/performance/baselines/2026-04-23-node-runtime-baseline.json'` exits `0`.
- `rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json` exits successfully and does not modify fixtures.
- Stage0 docs exist: `inventory.md`, `file-disposition.md`, `app-write-inventory.md`, `baseline-inventory.md`, `node-behavior-snapshots.md`, `performance-baseline.md`, `stage-gates.md`.
- Baseline JSON contains finite numeric metrics and `p95 >= p50` for measured tool latency.

## Stage1 Core Read/DB

- Swift read core can open a fixture copy read-only and run schema migrations only through write core/service code.
- FTS behavior preserves current Node fallback semantics, including CJK `LIKE` fallback and keyword length behavior.
- Vector schema compatibility is explicitly split into base schema and lazy vector availability.
- DB parity tests run on temp fixture copies only.
- `rtk sh -lc 'cd macos && xcodegen generate'` exits `0`.
- `rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramCoreTests test -destination 'platform=macOS'` exits `0`.
- `rtk npm run lint` exits `0`.
- Node deletion remains forbidden before Stage5.

## Stage2 Adapters And Indexing

- All adapter fixtures have Swift parity tests.
- Write-capable indexer, watcher, session writer, and sink logic live in service/write core, not app UI or MCP read paths.
- Non-watchable source rescan behavior is covered by a deterministic service test.
- FTS jobs do not clear existing full-message chunks when falling back.

## Stage3 Service Cutover

- App uses typed `EngramServiceClient`; generic Node `DaemonClient` and raw `/api/*` callsites are eliminated or isolated behind temporary compatibility shims with explicit deletion tasks.
- App no longer launches bundled `node/daemon.js`.
- App production code has no direct shared-index DB writer scan hits outside approved service/write core.
- Read-after-write UI flows pass against the Swift service.

## Stage4 MCP/CLI Cutover

- Swift `EngramMCP` matches Node goldens for read tools.
- Mutating MCP tools route through service IPC and fail closed when service is unavailable.
- `EngramCLI` has explicit supported-command tests or an intentional removal document for omitted Node CLI commands, such as `docs/swift-single-stack/cli-replacement-table.md`.
- Production MCP calls do not depend on in-process app-local `/tmp/engram.sock` bridge.

## Stage5 Node Removal

Current status on 2026-04-24: not complete. The macOS product no longer ships
the Node daemon bundle, but the repository still retains TypeScript `src/**`,
Node fixture/build tooling, and project move/archive/undo/batch is explicitly
disabled in the Swift MCP/UI until a native migration pipeline is ported.

- Product clean checkout can build/package without running npm or shipping `node_modules`.
- Bundle scan proves no `Contents/Resources/node/**`, `node/daemon.js`, `dist/index.js`, or Node launcher phase.
- `src/**` product runtime and Node build phases are deleted or archived as non-shipped fixture reference.
- Rollback plan lists every changed path and has been verified from a clean checkout.
