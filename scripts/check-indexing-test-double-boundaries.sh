#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if rg -n "TestIndexingWriteSink|FakeIndexingWriteSink|RecordingIndexingWriteSink|InMemoryIndexingWriteSink" \
  "$ROOT_DIR/macos/Engram" \
  "$ROOT_DIR/macos/EngramMCP" \
  "$ROOT_DIR/macos/EngramCLI" \
  "$ROOT_DIR/macos/EngramCoreRead" \
  "$ROOT_DIR/macos/EngramCoreWrite" \
  "$ROOT_DIR/macos/Shared" >/tmp/engram-indexing-test-double-boundary.txt; then
  cat /tmp/engram-indexing-test-double-boundary.txt
  echo "indexing test double leaked into production target sources" >&2
  exit 1
fi

echo "indexing test double boundaries ok"
