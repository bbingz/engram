# App Review Remediation Closeout — 2026-05-07

## Commit Slices

- `6be3a753 fix: fail closed for legacy write and HTTP paths`
- `e1653907 fix: unify primary session visibility`
- `3237f0cc feat: add project analytics dashboard`
- `199233df perf: reduce large session indexing pressure`
- `d8a10b0a chore: harden CI and release gates`

## Decisions

- Legacy Node MCP direct DB writes are rollback-only behind `mcpAllowDirectWriteFallback`; default write behavior fails closed if the daemon/service boundary is unavailable.
- HTTP content-bearing reads require bearer auth whenever `httpBearerToken` is configured, and standalone non-localhost HTTP requires both `httpAllowCIDR` and `httpBearerToken`.
- Default user-visible session surfaces use the primary-visible predicate: not hidden, no confirmed parent, no suggested parent, and not `skip` tier.
- Project analytics ownership is split deliberately: Node owns pricing metadata in the `metadata` table, Swift owns read-only aggregate rendering through `DatabaseManager.projectAnalytics`.
- Large transcript/session handling avoids full repeated parsing where practical: adapter windowing for `get_session`, a Swift "Load More" transcript path, coalesced daemon recovery work, and an indexer in-flight file guard.
- Release validation scans only actual `otool -L` dependency rows with `awk '/^\t/'`; universal binary architecture headers can contain local paths and must not be treated as dependency leaks.

## Verification

- `npm run build`: passed.
- `npm run typecheck:test`: passed.
- `npm run lint`: passed.
- `npm test`: 116 files, 1308 tests passed.
- `ENGRAM_TEAM_ID=J25GS8J4XM macos/scripts/build-release.sh`: passed, exported Developer ID universal app.
- `/Applications/Engram.app` was replaced with the release export and verified with `codesign --verify --deep --strict --verbose=4`.
- Release zip: `macos/build/EngramRelease/Engram-1.0-universal.unnotarized.zip`.
- Release zip SHA256: `befe0ec1b478e6118e153866feba432c1cae232c0d9be22a9a72efb780cb4feb`.

## Remaining Risk

- Notarization did not run because this machine has no `EngramNotary` notarytool keychain profile configured.
- The installed app is Developer ID signed by `zhibing zhao (J25GS8J4XM)` and locally accepted as `Unnotarized Developer ID`; distribution to other machines still needs notarization.
