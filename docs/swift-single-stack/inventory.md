# Swift Single-Stack Inventory

Stage0 inventory for removing the shipped Node MCP/daemon stack and converging on Swift stdio MCP plus native Swift service/core components.

## Runtime Components

| Component | Current role | Target disposition | Stage | Risk |
|---|---|---|---:|---|
| `src/index.ts` | Node stdio MCP server, tool registry, direct write fallback | Rewrite in `macos/EngramMCP`, then delete | 4/5 | High: public MCP contract and write semantics |
| `src/daemon.ts` | Node daemon startup, watcher, indexing, usage, web server | Rewrite as Swift service, then delete | 3/5 | High: broad runtime owner |
| `src/web.ts`, `src/web/views.ts` | Hono HTTP API and legacy web views | Replace with typed Swift service client/API or remove | 3/5 | High: many Swift views call `/api/*` |
| `src/core/db.ts`, `src/core/db/**/*.ts` | Schema, migrations, repositories, FTS, maintenance | Port to `EngramCoreRead`/`EngramCoreWrite` | 1/5 | Very high: DB compatibility and WAL policy |
| `src/adapters/**/*.ts` | Session parsers for current source set | Port to Swift adapters with fixture parity | 2/5 | High: source-format drift |
| `src/core/indexer.ts`, `src/core/watcher.ts`, `src/core/index-job-runner.ts` | Scan/watch/job processing | Port to Swift service writer | 2/3/5 | High: duplicate/missed indexing regressions |
| `src/core/project-move/**/*.ts` | Move/archive/undo/recover with compensation | Port to service-only commands | 4/5 | Very high: filesystem mutation and rollback |
| `src/tools/**/*.ts` | Public MCP handlers | Port read tools to Swift MCP/read core and writes to service | 4/5 | High: error and JSON-shape parity |
| `src/cli/**/*.ts` | Node terminal commands | Reimplement in `EngramCLI` or intentionally remove | 4/5 | Medium: user-facing command surface |
| AI/vector files under `src/core/ai-client.ts`, `auto-summary.ts`, `title-generator.ts`, `embeddings.ts`, `embedding-indexer.ts`, `vector-store.ts` | AI calls, embeddings, sqlite-vec | Port or explicitly defer with parity gate | 1/3/5 | High: provider/native extension strategy |

## Swift Components

| Component | Current role | Target disposition | Stage | Risk |
|---|---|---|---:|---|
| `macos/Engram/App.swift` | App entry, DB open, old MCP bridge startup, Node daemon launcher | Remove Node/app-local MCP ownership; start/use Swift service | 3/5 | High |
| `macos/Engram/Core/IndexerProcess.swift` | Launches bundled Node daemon and parses events | Replace with Swift service status/event model | 3/5 | High |
| `macos/Engram/Core/DaemonClient.swift`, `macos/Shared/Networking/DaemonHTTPClientCore.swift` | Generic HTTP client to Node daemon | Replace with typed `EngramServiceClient` | 3/4/5 | High |
| `macos/Engram/Core/MCPServer.swift`, `MCPTools.swift` | App-local MCP bridge over `/tmp/engram.sock` | Delete after stdio MCP is sole path | 3/5 | Medium-high |
| `macos/EngramMCP/**` | Current Swift stdio MCP helper | Keep and harden as final MCP target | 1/4/5 | High |
| `macos/EngramCLI/main.swift` | Bridges to app-local MCP socket | Rewrite as real Swift CLI or delete intentionally | 4/5 | Medium |
| `macos/project.yml` | XcodeGen source of build graph | Remove Node bundle phase; add core/service targets | 1/3/5 | High |

## Packaging And Dev Tooling

| Component | Current role | Target disposition | Stage | Risk |
|---|---|---|---:|---|
| `package.json` runtime metadata and deps | Defines shipped Node package/runtime | Remove from product runtime; keep only dev/reference tooling until cutover | 5 | High |
| `macos/scripts/build-node-bundle.sh` | Removed Node daemon/runtime copy script | Deleted | 5 | Closed |
| `macos/project.yml` `Bundle Node.js Daemon` phase | Removed App build dependency on npm/dist/node_modules | Removed through XcodeGen | 5 | Closed |
| `scripts/gen-mcp-contract-fixtures.ts` | Node source-of-truth golden generator | Keep as non-shipped reference or archive before deleting `src/` | 5 | High |
| `scripts/generate-test-fixtures.ts`, `scripts/check-fixture-schema.ts` | Node fixture/schema tooling | Keep as dev-only until Swift equivalents exist | 1/5 | Medium |
| Screenshot/baseline helper scripts | UI/dev tooling | Keep non-shipped | 5 | Low |

## Gaps To Close Before Deletion

- CLI command inventory is incomplete; map `src/cli/*` to Swift replacements or explicit removals before Stage4/5.
- Cascade gRPC parity for Windsurf/Antigravity needs a Swift protobuf/gRPC decision before adapter cutover.
- `scripts/gen-mcp-contract-fixtures.ts` imports live `src/*`; it cannot survive unchanged after Node source deletion.
- Product bundle scans must prove no `Contents/Resources/node/**`, `node_modules`, `dist/index.js`, or Node launcher phase remains.
