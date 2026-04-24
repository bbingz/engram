# Swift Single Stack Implementation Index

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` or `superpowers:subagent-driven-development` before implementing any stage document linked from this index.

**Goal:** Execute the Swift single-stack migration without drifting from the reviewed spec: ship Engram as a Swift-only macOS product, remove the Node daemon and duplicate MCP paths only after parity evidence is complete, and keep every intermediate revision buildable.

**Source spec:** `docs/superpowers/specs/2026-04-23-swift-single-stack-design.md`

**Parent plan:** `docs/superpowers/plans/2026-04-23-swift-single-stack-migration.md`

## Execution Order

Implement these plans in strict order:

1. `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-0-1-foundation.md`
2. `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-2-adapters-indexing.md`
3. `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-3-service-app.md`
4. `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-4-mcp-cli-project-ops.md`
5. `docs/superpowers/plans/implementation/2026-04-23-swift-single-stack-stage-5-cutover.md`

Do not start a later stage until the prior stage's acceptance gates pass in the same working tree. Do not treat partial local success as a stage gate.

## Global Invariants

- Node remains the migration reference through Stage 4.
- Stage 5 is the only stage allowed to delete Node runtime code, Node MCP code, app-local HTTP bridge code, bundled Node resources, or documented Node MCP setup paths.
- App UI and `EngramMCP` may import read-only core APIs only.
- Production writes must flow through one shared service writer reached through `EngramServiceClient`.
- `EngramCoreWrite` must not be importable by app UI targets, MCP targets, or shared app/MCP source trees.
- Mutating MCP tools and mutating CLI commands must fail closed when service IPC is unavailable.
- SQLite opens must verify WAL mode and a busy timeout compatible with the Node runtime baseline.
- `macos/project.yml` is the Xcode target graph source of truth; regenerate `macos/Engram.xcodeproj` with XcodeGen after edits.
- Generated Xcode project files may be inspected but not hand-edited.
- Every stage must leave `rtk npm run lint` and the relevant Swift tests passing.

## Blocking Gates

### Stage 0 to Stage 1

Stage 1 may begin only after these artifacts exist and contain concrete values:

- `docs/swift-single-stack/inventory.md`
- `docs/swift-single-stack/file-disposition.md`
- `docs/swift-single-stack/app-write-inventory.md`
- `docs/swift-single-stack/stage-gates.md`
- `docs/swift-single-stack/performance-baseline.md`
- `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`

The baseline JSON must contain every canonical schema key from the parent plan. Missing keys are a Stage 0 defect, not a Stage 1 repair opportunity.

### Stage 1 to Stage 2

Stage 2 may begin only after Swift core read parity, migration validation, WAL/busy-timeout checks, FTS rebuild checks, vector strategy tests, and baseline compare-only validation pass.

Stage 1 must not overwrite `docs/performance/baselines/2026-04-23-node-runtime-baseline.json` unless the command is explicitly run with `--force-baseline-update` and the stage gate document records why the Stage 0 baseline was defective.

### Stage 2 to Stage 3

Stage 3 may begin only after adapters and indexing pass fixture parity against Node-created goldens, including source-specific adapters, batch-size behavior, watcher semantics, parent detection snapshots, and startup backfills.

Production indexing write APIs must be under service-owned write modules before Stage 3 begins. Test-only sinks and doubles must not be added to production targets.

### Stage 3 to Stage 4

Stage 4 may begin only after real service IPC is implemented and tested. In-process transport is not enough for Stage 4.

There must be exactly one production `EngramDatabaseWriter` authority owned by the service writer gate. The app may connect to the service but must not open independent write-capable core paths.

### Stage 4 to Stage 5

Stage 5 may begin only after Swift MCP, Swift CLI, and project operations are parity-complete and all mutating paths use service IPC.

The `get_context` environment contract, project migration crash windows, CLI replacement table, and direct read-after-write behavior must be covered by tests before any deletion starts.

### Stage 5 Deletion Checkpoint

Deletion may begin only after these commands pass from the same commit:

```bash
rtk npm run lint
```

```bash
rtk npm test
```

```bash
rtk sh -lc 'cd macos && xcodegen generate'
```

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme Engram test -destination 'platform=macOS'
```

```bash
rtk xcodebuild -project macos/Engram.xcodeproj -scheme EngramMCPTests test -destination 'platform=macOS'
```

```bash
rtk scripts/verify-swift-only-cutover.sh
```

The cutover script must fail non-zero when parity, packaging, clean-checkout, or performance thresholds fail.

## Cross-Stage File Ownership

- Stage 0/1 owns baseline scripts, core target layout, DB repositories, migration validation, schema compatibility, WAL policy, FTS, vector strategy, and core read/write boundary creation.
- Stage 2 owns source adapters, parser limits, indexing batches, watcher events, parent detection, startup backfills, and adapter/indexing parity fixtures.
- Stage 3 owns `EngramService`, service IPC, service writer gate, app startup replacement, event stream replacement, app-side write removal, and service unavailable handling.
- Stage 4 owns Swift MCP routing, CLI replacement/deprecation, project operation commands, MCP golden fixtures, command contract parity, and user-facing CLI/MCP docs before deletion.
- Stage 5 owns deletion, packaging cleanup, final docs cleanup, precise grep gates, clean checkout validation, performance comparison, and rollback documentation.

When a stage needs a file from another stage, it may read it and add verification references, but it must not change the owning stage's semantic decision without updating the parent plan and rerunning that stage's gate.

## Verification Rhythm

For each implementation slice:

1. Read this index, the source spec, the parent plan, and the stage-specific implementation plan.
2. Run the smallest test that proves the current slice fails or lacks coverage.
3. Implement the slice.
4. Run the same test again and the stage-level lint/build subset.
5. Update the stage gate document only after the command output proves the gate.

At each stage boundary, run the full command set listed in the parent plan and record the exact command outputs in `docs/verification/swift-single-stack-cutover.md` or the stage-specific verification log named by the stage plan.

## Abort Rules

Stop the current stage and repair the owning earlier stage when any of these happen:

- A baseline or golden fixture is missing required keys.
- A mutating path can write without `EngramServiceClient`.
- `EngramMCP` can mutate when service IPC is unavailable.
- App UI or MCP targets import `EngramCoreWrite`.
- Node deletion is required before Stage 5 to make a test pass.
- Performance comparison tooling cannot produce a non-zero failure for threshold regressions.
- Clean checkout verification requires preinstalled `node_modules` or an existing `dist/` directory.

## Completion Criteria

The migration is complete only when Stage 5 passes from a clean checkout and the repository contains no shipped Node runtime, no duplicate MCP runtime, no app-local HTTP MCP bridge, no bundled Node resource, and no user-facing docs instructing users to run the Node MCP server.
