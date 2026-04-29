# File Disposition

Disposition list for the Node-to-Swift single-stack migration. This file is intentionally action-oriented: later implementation agents should be able to pick a row and know the required end state.

| Path / glob | Disposition | Migration action | Stage | Gate |
|---|---|---|---:|---|
| `src/index.ts` | Delete after replacement | Port all MCP tool contracts to `macos/EngramMCP`; route mutating tools through service IPC | 4/5 | Swift MCP goldens match Node; no direct DB fallback |
| `src/daemon.ts` | Delete after replacement | Port startup, watcher, indexing, observability, sync, and web API responsibilities to Swift service | 3/5 | App no longer launches Node; service smoke passes |
| `src/web.ts`, `src/web/views.ts` | Delete or archive | Replace each `/api/*` caller with typed Swift service commands/read APIs | 3/5 | Raw daemon endpoint scan clean |
| `src/core/db.ts`, `src/core/db/**/*.ts` | Replace | Split Swift read/write repositories; preserve schema, migrations, FTS behavior | 1/5 | DB parity tests and fixture schema checks pass |
| `src/adapters/**/*.ts` | Replace | Port parsers and drift handling to Swift | 2/5 | Adapter fixture parity for all sources |
| `src/adapters/grpc/cascade-client.ts` | Replace/defer | Select Swift gRPC/protobuf implementation or defer source support explicitly | 2 | Cascade fixture spike accepted |
| `src/core/indexer.ts`, `src/core/watcher.ts`, `src/core/index-job-runner.ts` | Replace | Port scan/watch/job semantics into service writer | 2/3 | Indexing fixture and non-watchable rescan tests pass |
| `src/core/project-move/**/*.ts` | Replace | Port move/archive/undo/recover/review to service commands with compensation | 4 | Dry-run/live/undo/recover parity tests pass |
| `src/tools/**/*.ts` | Replace | Port read tools to Swift MCP/read core; mutating tools to fail-closed service IPC | 4 | MCP golden suite passes |
| `src/cli/**/*.ts` | Replace/remove intentionally | Implement supported commands in `macos/EngramCLI` | 4/5 | Bare `engram` command behavior documented and tested |
| `src/core/ai-client.ts`, `auto-summary.ts`, `title-generator.ts` | Replace/defer | Port provider requests, settings, keychain/audit behavior | 3 | Summary/title UI and MCP tests pass |
| `src/core/embeddings.ts`, `embedding-indexer.ts`, `vector-store.ts` | Replace/defer | Port embedding and vector search strategy | 1/3/5 | Semantic/vector parity gate or documented deferral |
| `src/core/usage-*`, `src/adapters/*-usage-probe.ts` | Replace | Port usage probes and events | 3 | UI usage payload parity |
| `src/core/live-sessions.ts`, `monitor.ts`, `health-rules.ts`, `alert-rules.ts`, `git-probe.ts`, `sync.ts` | Replace | Port health/live/sync loops to Swift service | 3 | Service event/status tests pass |
| `src/core/logger.ts`, `metrics.ts`, `tracer.ts`, `ai-audit.ts` | Replace | Port observability schema and writes | 3 | Service side-effect parity tests pass |
| `src/types/huggingface-transformers.d.ts` | Delete | Remove with TS embedding implementation | 5 | No TS product runtime |
| `scripts/gen-mcp-contract-fixtures.ts` | Keep dev-only or archive | Freeze Node reference generator outside shipped runtime or rewrite in Swift | 5 | Clean product checkout does not require Node |
| `scripts/perf/capture-node-baseline.ts` | Keep dev-only during migration | Capture Node direct-tool baseline from temp fixture copies | 0/5 | Baseline compare-only passes |
| `scripts/measure-swift-single-stack-baseline.sh` | Keep dev-only during migration | Wrapper around Node baseline capture | 0/5 | Emits validated JSON |
| `macos/scripts/build-node-bundle.sh` | Deleted | Removed Node bundle production | 5 | Bundle scan clean |
| `macos/scripts/copy-mcp-helper.sh` | Keep | Continue bundling Swift `EngramMCP` helper | 4/5 | Helper signing/package gate |
| `macos/Engram/Core/MCPServer.swift`, `MCPTools.swift` | Delete | Remove app-local MCP bridge | 3/5 | No `/tmp/engram.sock` MCP dependency |
| `macos/Engram/Core/IndexerProcess.swift` | Replace/delete | Replace Node process wrapper with Swift service state | 3/5 | App never launches `node/daemon.js` |
| `macos/Engram/Core/DaemonClient.swift`, `macos/Shared/Networking/DaemonHTTPClientCore.swift` | Replace | Remove generic HTTP affordance | 3/4 | Raw endpoint scan clean |
| `macos/EngramMCP/**` | Keep/rewrite | Final shipped MCP helper | 1/4 | Read core + service IPC split complete |
| `macos/project.yml` | Updated | Node phase removed; service/core targets retained | 1/3/5 | Regenerated project has no Node phase |
