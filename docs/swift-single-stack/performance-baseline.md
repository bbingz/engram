# Performance Baseline

Stage0 canonical baseline path: `docs/performance/baselines/2026-04-23-node-runtime-baseline.json`.

## Machine Metadata

- `gitCommit`: `571fd979b422ea700984e598a46d6aac67e0c8ed`
- `macOSVersion`: `26.4.1`
- `cpuArchitecture`: `arm64`
- `nodeVersion`: `v25.9.0`
- `captureMode`: `node-direct-tools-v1`

## Fixture Paths

- `fixtureDbPath`: `tests/fixtures/mcp-contract.sqlite`
- `fixtureCorpusPath`: `tests/fixtures`
- `sessionFixtureRoot`: `test-fixtures/sessions`

## Checksums

- Baseline JSON sha256: `f88aed6b1164d5d96d07aac27bfec6e9c8f59a0b87314f35078c290d64ad0899`
- Fixture DB sha256: `75ccd6c507af229a865c7d25c05f7af4029e0b18f445e7db1b9aa82ce99ab2b7`

## Capture Command

```bash
rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --out docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Result: exited `0` and created the canonical baseline.

## Compare-Only Command

```bash
rtk sh -lc 'before=$(shasum -a 256 docs/performance/baselines/2026-04-23-node-runtime-baseline.json tests/fixtures/mcp-contract.sqlite | tr "\n" ";"); ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json; after=$(shasum -a 256 docs/performance/baselines/2026-04-23-node-runtime-baseline.json tests/fixtures/mcp-contract.sqlite | tr "\n" ";"); test "$before" = "$after"'
```

Result: exited `0`; baseline and fixture DB checksums were unchanged.

Comparison output:

```json
{
  "baseline": "2026-04-23T02:58:12.716Z",
  "current": "2026-04-23T02:58:21.597Z",
  "searchP95DeltaMs": -2.074,
  "getContextP95DeltaMs": -1.933,
  "coldDbOpenDeltaMs": -0.354,
  "coldAppLaunchToDaemonReadyDeltaMs": -1.541
}
```

## Existing Baseline Refusal

```bash
rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 1 --out docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

Result: exited non-zero and printed `Baseline exists; use --compare-only or --force-baseline-update with --reason`.

## Scope Note

This Stage0 baseline measures the current Node direct-tool read path against deterministic fixture copies. It does not represent final Swift service IPC, final Swift MCP stdio launch, or packaged app launch metrics; those require Stage3/Stage4 harnesses before product cutover.
