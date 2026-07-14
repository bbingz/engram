# MCP Golden Fixtures

`initialize.result.json` and `tools.json` are generated from the native Swift MCP source by `npm run generate:mcp-contract-fixtures`.
All other JSON files are executable behavior snapshots owned by `EngramMCPExecutableTests`; the retired TypeScript handlers must not overwrite them.

Normalization rules:
- executable snapshots normalize random UUIDs and absolute fixture roots in the Swift test harness
- generated fixture timestamps come from fixed rows, not `now()`
- fixture DB is `tests/fixtures/mcp-contract.sqlite`; never use `~/.engram/index.sqlite` in contract tests
