# Post-Merge Hygiene Design

## Goal

Close the remaining non-blocking inspector follow-ups that are small enough to
ship safely in the current PR: MCP contract fixture determinism and macOS signing
portability documentation.

## Scope

In scope:

- Keep `test-fixtures/test-index.sqlite` under the existing CI determinism gate.
- Add the same determinism gate for `tests/fixtures/mcp-contract.sqlite`,
  `tests/fixtures/mcp-golden`, and `tests/fixtures/mcp-runtime`.
- Remove nondeterministic writes from the MCP contract fixture generator.
- Document why `EngramTests` signing must match the host app and how forks
  override it.

Out of scope:

- Replacing committed SQLite fixtures with on-demand generation.
- Moving signing to `xcconfig` or environment-variable substitution.
- Reopening Option C / Node / HTTP / TypeScript-backed bridge work.
- Changing inspector DTO behavior, schema, migrations, or runtime architecture.

## Design

### MCP Contract Fixture Determinism

The existing CI fixture check only covers `test-fixtures/test-index.sqlite`.
`tests/fixtures/mcp-contract.sqlite` is consumed by Swift MCP parity and
performance tooling, but regeneration was not enforced by CI.

The generator already normalizes dynamic JSON output, but three shared-DB facts
still needed tightening: `save_insight` mutated `mcp-contract.sqlite` with a
random UUID before normalization, project aliases used SQLite `datetime('now')`,
and one transcript session stored the local checkout path. The fix is to build
the `save_insight` golden in an isolated temporary database, seed project aliases
with fixed timestamps, and store a repo-relative transcript path. The shared
contract database then contains only deterministic, checkout-neutral rows.

CI should run `npm run generate:mcp-contract-fixtures` and diff the committed
SQLite, golden JSON, and tracked runtime fixture directories. This turns local
reviewer noise into a real release gate. When the new gate exposes Swift MCP
contract drift, prefer bringing Swift MCP output into parity with the generated
contract over deleting fields from the generator.

### Signing Portability

`EngramTests` is a hosted XCTest bundle loaded into the hardened-runtime
`Engram.app` process. With signing enabled, the bundle and host app must use a
compatible Apple Developer Team or macOS rejects the load with a Team ID
mismatch.

The current PR keeps signing behavior unchanged. The portability fix is
documentation plus an inline `project.yml` comment: forks should mirror their
host app team on `EngramTests`, or override `DEVELOPMENT_TEAM` when invoking
`xcodebuild`. This avoids a risky signing-system refactor while preserving the
current green CI path.

## Validation

- `npm run generate:mcp-contract-fixtures` twice must leave
  `tests/fixtures/mcp-contract.sqlite`, `tests/fixtures/mcp-golden`, and
  `tests/fixtures/mcp-runtime` clean after the committed baseline is refreshed.
- `npx tsx scripts/generate-test-fixtures.ts` must still leave
  `test-fixtures/test-index.sqlite` clean.
- `npm run build` and `npm run lint` must pass.
- `cd macos && xcodegen generate` must be idempotent.
- A focused hosted Swift test should still pass with the project signing setup.

## Risks

- The committed `mcp-contract.sqlite` binary changes once because the previous
  baseline contained nondeterministic generator output. Future regenerations
  should be stable.
- Documentation-only signing portability does not remove the hardcoded team; it
  makes the required override explicit. A future `xcconfig` slice can remove the
  hardcoding if external contributor friction becomes real.
