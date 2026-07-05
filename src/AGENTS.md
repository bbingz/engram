# TYPESCRIPT KNOWLEDGE BASE

## OVERVIEW
`src/` is retained TypeScript dev/reference tooling. It supports fixtures,
regression tests, historical MCP/web/daemon entrypoints, and parity mirrors; it
is not the shipped macOS product runtime.

## STRUCTURE
```
- adapters/          # TS reference parsers and fixture support
- core/              # TS reference DB/search/project-move/indexer logic
- tools/             # TS MCP tool handlers retained for compatibility/tests
- cli/               # retained project/resume command entrypoints
- web.ts             # historical/dev HTTP surface
- index.ts           # historical/dev MCP entrypoint
- daemon.ts          # historical/dev daemon entrypoint
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Project move parity | `core/project-move/` | TS mirror for retained tooling and regression coverage. |
| DB/reference logic | `core/db/`, `core/database.ts` | Dev/reference path; Swift owns product schema/writes. |
| Vectors/embeddings | `core/vector-store.ts`, `core/embeddings.ts` | Reference semantic design; not product Swift search. |
| MCP-compatible handlers | `tools/` | JSON handlers and retained contract coverage. |
| CLI entrypoints | `cli/project.ts`, `cli/resume.ts` | Developer/reference commands. |
| Web reference | `web.ts`, `web/` | Historical/dev-only surface; the Swift product no longer serves the HTTP transcript Web UI. |

## CONVENTIONS
- Use strict ES2022/Node16 modules and `node:` prefixes for Node built-ins.
- Biome formats with 2 spaces and single quotes.
- `src/**` should avoid explicit `any`; `tests/**` and `scripts/**` have looser overrides.
- Constants use existing `UPPER_SNAKE_CASE` style.
- DB methods belong in the appropriate `src/core/db/*` module; `database.ts` is a facade.
- Settings/keychain code must avoid shelling to `security`; it can trigger dialogs in MCP/daemon contexts.
- Keep TS changes tied to retained tooling, fixture generators, regression tests, or compatibility contracts.

## ANTI-PATTERNS
- Do not treat `src/index.ts`, `src/daemon.ts`, or `src/web.ts` as shipped runtime.
- Do not use TS DB code as source of truth for Swift-only schema defaults.
- Do not re-enable MCP idle timeout in `src/index.ts`.
- Do not set project move/archive `force: true` unless the user explicitly asked for force/override.
- Do not add Viking/OpenViking code paths; that path was removed.

## COMMANDS
```bash
npm run build
npm run lint
npm run lint:fix
npm run knip
npm run typecheck:test
npm test
npm test -- tests/core/logger.test.ts
npm run generate:fixtures
npm run check:fixtures
```
