# Performance Baselines

`2026-04-23-node-runtime-baseline.json` is the Stage0 baseline for the current Node direct-tool read path. It measures from temporary fixture copies, not from `~/.engram/index.sqlite`.

Refresh intentionally:

```bash
rtk ./scripts/measure-swift-single-stack-baseline.sh --force-baseline-update --reason "short reason"
```

Compare without rewriting:

```bash
rtk ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts --fixture-db tests/fixtures/mcp-contract.sqlite --fixture-root tests/fixtures --session-fixture-root test-fixtures/sessions --iterations 50 --compare-only docs/performance/baselines/2026-04-23-node-runtime-baseline.json
```

This baseline does not claim to measure final Swift service IPC or app launch. Those metrics should be added as Stage3/Stage4 service and app harnesses become available.
