# TESTS KNOWLEDGE BASE

## OVERVIEW
`tests/` contains Vitest coverage, generated fixtures, MCP golden contracts,
adapter/indexer parity data, web/API tests, script tests, and shared test
utilities. Swift targets consume several fixture folders from here.

## STRUCTURE
```
- core/                 # TS DB/search/project-move/indexer tests
- adapters/             # TS adapter regression tests
- tools/                # MCP/tool handler tests
- web/                  # historical/dev web API tests
- scripts/              # CI/release/screenshot/tooling tests
- fixtures/             # generated and hand-curated fixture roots
- integration/          # broader retained TS integration checks
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| MCP contract goldens | `fixtures/mcp-golden/` | Normalized UUID/timestamp outputs; backed by generated contract DB. |
| Adapter parity | `fixtures/adapter-parity/` | One provider folder per source with `success.expected.json`. |
| Indexer parity | `fixtures/indexer-parity/` | Generated parity fixture sets, including parent detection. |
| Runtime fixture project | `fixtures/mcp-runtime/` | Includes nested `CLAUDE.md` test data; do not treat as repo instructions. |
| CI workflow tests | `scripts/ci-workflow.test.ts`, `scripts/build-release-script.test.ts` | Enforce workflow and bundle hygiene invariants. |
| Project move tests | `core/project-move/` | TS retained coverage for move/archive/undo/recover parity. |

## CONVENTIONS
- Prefer real fixtures for parser and contract behavior.
- Generated fixture READMEs document provenance and normalization rules; update generators before refreshing outputs.
- `tests/fixtures/**` is intentionally excluded from normal formatting assumptions.
- Golden outputs may normalize UUIDs to `<generated-uuid>` and timestamps to fixed values.
- UI screenshot baselines live under `macos/EngramUITests/baselines`, not here.
- Swift tests import `tests/fixtures` as resources through `macos/project.yml`.

## ANTI-PATTERNS
- Do not edit generated goldens casually when a generator or schema changed.
- Do not count fixture `CLAUDE.md` files as active repo instructions.
- Do not treat `coverage/` output as source or fixture truth.
- Do not replace fixture-backed parser tests with mock-only coverage.

## COMMANDS
```bash
npm test
npm run test:coverage
npm run typecheck:test
npm run check:adapter-parity-fixtures
npm run generate:mcp-contract-fixtures
npm run generate:adapter-parity-fixtures
npm run generate:parent-detection-fixtures
npm run generate:indexer-parity-fixtures
npm run check:fixtures
```
