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
- Swift App, Swift MCP, Swift Service export, and Swift HTTP transcript rendering all use the same visible-message contract: only non-empty `user` / `assistant` messages are rendered as transcript body. Tool, system, event, and subagent notification rows remain available for indexing/statistics/diagnostics, but are not returned as ordinary transcript messages. Provider parser parity is guarded by `tests/fixtures/adapter-parity/**`; surface parity is covered by Swift HTTP/MCP/export tests that exercise the same Command Code and Antigravity cases.

## Node 26 Native Dependency Note

The local checkout initially had stale `node_modules` with `better-sqlite3@11.10.0`, which cannot build against Node `v26.0.0`. The repository manifests already require `better-sqlite3@^12.10.0`, whose package metadata supports Node 26. Running `npm install` synchronized the local install state and restored SQLite-backed adapter tests.

## Verification

Fresh commands run from the remediation branch worktree:

```bash
npm run check:adapter-parity-fixtures
npm test -- tests/adapters/antigravity.test.ts tests/adapters/commandcode.test.ts tests/adapters/qoder.test.ts tests/scripts/stage2-fixture-generators.test.ts tests/web/api.test.ts tests/web/server.test.ts
npm test -- tests/scripts/stage2-fixture-generators.test.ts
npm run typecheck:test
npm run build
npm run knip
npm audit --audit-level=high --json
npm test
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramCoreTests -destination 'platform=macOS' -only-testing:EngramCoreTests/AdapterParityTests/testSwiftAdaptersMatchNodeParityGoldensForAllProviders
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramMCPTests -destination 'platform=macOS' -only-testing:EngramMCPTests/EngramMCPExecutableTests/testSourceSchemasCoverEveryKnownProvider -only-testing:EngramMCPTests/EngramMCPExecutableTests/testGetSessionFiltersToolMessagesLikeSwiftDisplay -only-testing:EngramMCPTests/EngramMCPExecutableTests/testGetSessionReadsAntigravityLegacySourceThroughAdapterRegistry
xcodebuild test -project macos/Engram.xcodeproj -scheme EngramServiceCore -destination 'platform=macOS' -only-testing:EngramServiceCoreTests/EngramServiceIPCTests/testExportSessionFiltersToolMessagesLikeSwiftDisplay -only-testing:EngramServiceCoreTests/EngramWebUIServerTests/testTranscriptDisplayFiltersToolMessagesLikeSwiftApp
```

Results:

- `npm run check:adapter-parity-fixtures`: passed, `adapter parity fixtures ok`.
- Targeted Antigravity/Qoder/Command Code parser + fixture + HTTP tests: passed, 6 files, 115 tests.
- HTTP transcript display parity tests: passed through Swift ServiceCore selected tests and Node web tests.
- `npm test -- tests/scripts/stage2-fixture-generators.test.ts`: passed, 9 tests.
- `npm run typecheck:test`: passed.
- `npm run build`: passed.
- `npm run knip`: passed.
- `npm test`: passed, 120 files, 1342 tests.
- `npm audit --audit-level=high --json`: passed, 0 high/critical vulnerabilities.
- Swift adapter parity + indexer regressions: passed, 2 selected tests, 0 failures.
- Swift MCP executable transcript/source schema tests: passed, 3 selected tests, 0 failures.
- Swift ServiceCore export/HTTP transcript tests: passed, 2 selected tests, 0 failures.

## Follow-up Rule

When adding or changing any provider parser:

1. Add or update the adapter parity fixture input and golden output.
2. Ensure `scripts/check-adapter-parity-fixtures.ts` names the provider.
3. Add or update the TypeScript adapter regression test.
4. Add or update Swift adapter parity coverage before shipping.
5. If transcript display rules change, update `test-fixtures/transcript-display/system-classification-cases.json` and keep the HTTP and Swift tests green.

## Polycli Review

Two Polycli review rounds were run against the provider/parser parity changes. Round 1 used `gemini`, `claude`, `copilot`, `minimax`, `cmd`, and `agy`; Round 2 re-ran the same practical set, with `claude` retried using a focused diff after the first broad second-round run timed out.

Round 2 actionable results:

- `copilot`: found a real Qoder parent-detection bug for project-level `subagents/` outside `/Users`; fixed in Swift and TypeScript.
- `gemini`: found whitespace-only transcript messages still leaking through MCP/export and blank assistant tool-call stats being skipped; both fixed.
- `claude`: found plain blank assistant messages inflating assistant counts, noop cost-row model refresh regression, and worktree name leaking into the generated Xcode project; all fixed.
- `cmd` and `minimax`: remaining claims were either covered by tests or intentional product behavior.
- `agy`: completed read-only exploration without a final actionable finding.

The final verification pass after absorbing Round 2 issues is the command set above.
