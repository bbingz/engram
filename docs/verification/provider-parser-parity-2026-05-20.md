# Provider Parser Parity Verification - 2026-05-20

## Scope

This record covers the provider parser/parity pass requested after adding Antigravity CLI support. The goal is to keep Swift product parsing, HTTP/API reference views, and TypeScript fixture tooling aligned.

## Covered Providers

The parity gate currently covers these product sources:

- `antigravity`
- `claude-code`
- `cline`
- `codex`
- `commandcode`
- `copilot`
- `cursor`
- `gemini-cli`
- `iflow`
- `kimi`
- `opencode`
- `qoder`
- `qwen`
- `vscode`
- `windsurf`

MiniMax and Lobster AI are Claude-compatible derived sources. They intentionally share the Claude Code parser while being indexed under their own `source` values; Swift and Node tests cover that derived-source classification separately from the 15 independent fixture directories.

Antigravity CLI, Command Code, and Qoder are explicitly included in both the fixture checker and targeted adapter tests.

## Parser Contract

- Swift adapters under `macos/Shared/EngramCore/Adapters/Sources/` are the product parser implementation.
- TypeScript adapters remain dev/reference tooling for fixture generation and regression tests.
- `tests/fixtures/adapter-parity/**/success.expected.json` is the shared golden corpus for Swift adapter parity.
- `scripts/check-adapter-parity-fixtures.ts` fails when a covered provider has no success fixture, no malformed fixture, or a missing physical input file.
- HTTP/API reference rendering and the Swift App detail view do not share a compiled parser. Provider parser parity is guarded by `tests/fixtures/adapter-parity/**`; display classification parity is guarded by the shared `test-fixtures/transcript-display/system-classification-cases.json` corpus. Divergence should be fixed by adding or updating the relevant fixture first, then changing both implementations.

## Node 26 Native Dependency Note

The local checkout initially had stale `node_modules` with `better-sqlite3@11.10.0`, which cannot build against Node `v26.0.0`. The repository manifests already require `better-sqlite3@^12.10.0`, whose package metadata supports Node 26. Running `npm install` synchronized the local install state and restored SQLite-backed adapter tests.

## Verification

Fresh commands run on `/Users/bing/-Code-/engram`:

```bash
npm run check:adapter-parity-fixtures
npm test -- tests/adapters
npm test -- tests/scripts/stage2-fixture-generators.test.ts
npm run typecheck:test
npm run build
npm run knip
npm audit --json
npm test
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests/testSwiftAdaptersMatchNodeParityGoldensForAllProviders
xcodebuild test -project macos/Engram.xcodeproj -scheme Engram -destination 'platform=macOS' -only-testing:EngramTests/MessageParserTests
```

Results:

- `npm run check:adapter-parity-fixtures`: passed, `adapter parity fixtures ok`.
- Targeted Antigravity/Qoder/Command Code parser + fixture tests: passed, 5 files, 36 tests.
- HTTP transcript display parity tests: passed, 14 tests.
- `npm test -- tests/scripts/stage2-fixture-generators.test.ts`: passed, 6 tests.
- `npm run typecheck:test`: passed.
- `npm run build`: passed.
- `npm run knip`: passed.
- `npm test`: passed, 120 files, 1338 tests.
- `npm audit --json`: passed, 0 vulnerabilities.
- Swift adapter parity: passed, 1 selected test, 0 failures.
- Swift `AdapterParityTests`: passed, 15 selected tests, 0 failures.
- Swift display message parser tests: passed, 20 selected tests, 0 failures.

## Follow-up Rule

When adding or changing any provider parser:

1. Add or update the adapter parity fixture input and golden output.
2. Ensure `scripts/check-adapter-parity-fixtures.ts` names the provider.
3. Add or update the TypeScript adapter regression test.
4. Add or update Swift adapter parity coverage before shipping.
5. If transcript display rules change, update `test-fixtures/transcript-display/system-classification-cases.json` and keep the HTTP and Swift tests green.
