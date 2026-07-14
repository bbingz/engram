#!/usr/bin/env bash

set -euo pipefail

fixture_paths=(
  tests/fixtures/mcp-contract.sqlite
  tests/fixtures/mcp-runtime
  tests/fixtures/mcp-golden/README.md
  tests/fixtures/mcp-golden/initialize.result.json
  tests/fixtures/mcp-golden/tools.json
)

npm run generate:mcp-contract-fixtures
git diff --exit-code -- "${fixture_paths[@]}"

untracked="$(git ls-files --others --exclude-standard -- "${fixture_paths[@]}")"
if [[ -n "$untracked" ]]; then
  echo "Generated MCP contract fixtures contain untracked files:" >&2
  echo "$untracked" >&2
  exit 1
fi
