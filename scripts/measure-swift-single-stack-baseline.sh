#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT_DIR/docs/performance/baselines/2026-04-23-node-runtime-baseline.json}"
ITERATIONS="${ITERATIONS:-50}"

cd "$ROOT_DIR"

exec ./node_modules/.bin/tsx scripts/perf/capture-node-baseline.ts \
  --out "$OUT" \
  --fixture-db "$ROOT_DIR/tests/fixtures/mcp-contract.sqlite" \
  --fixture-root "$ROOT_DIR/tests/fixtures" \
  --session-fixture-root "$ROOT_DIR/test-fixtures/sessions" \
  --iterations "$ITERATIONS" \
  "$@"
