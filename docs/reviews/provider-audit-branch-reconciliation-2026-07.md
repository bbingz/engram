# Provider Audit Branch Reconciliation - July 2026

## Scope

Parked branch: `codex-provider-audit-remediation`

Current base: `main` at `677dff57` (Task 6 merge)

Merge base: `f9a236dc9e038d1afebf0f412ec30baf3a04d5bd`

Audited commits:

- `5013bab7` - Codex provider session-format audit + Claude critical/test/doc remediation
- `f5c3b545` - fix: remediate remaining Codex provider-audit findings (2nd pass)
- `005c90d2` - fix: clean up PR 94 adapter route follow-up
- `285453d7` - feat(sessions): session taxonomy filter + competitive-session closeout

Safety constraints followed: the parked branch was not checked out, merged,
rebased, reset, deleted, or cherry-picked. Inventory came from
`git log`, `git show`, and `git diff main...codex-provider-audit-remediation`.

Branch size: `git diff --stat main...codex-provider-audit-remediation` reports
193 files, 18,446 insertions, and 2,416 deletions. This is not a safe unit to
merge into current `main`.

## Summary

Only one small runtime fix was hand-ported: Claude Code transcripts that contain
valid JSONL but zero visible Engram messages now return the terminal
`noVisibleMessages` parse failure, and system-injected Claude user records are
dropped from streamed messages so counts match. The ported code/test footprint
before this report and changelog was 139 insertions and 4 deletions.

Large missing features from the parked branch remain intentionally unported:
Grok/Pi provider families, session taxonomy filters, runtime capability docs
gates, and broad Swift indexer repair semantics. Those should be re-specced from
current `main` instead of transplanted from this stale branch.

## Categorized Inventory

| Delta | Source commits | Classification | Evidence | Action |
| --- | --- | --- | --- | --- |
| Stale durability snapshots (`.memory`, parked `CHANGELOG.md` history) | `5013bab7`, `f5c3b545`, `005c90d2`, `285453d7` | obsolete | `AGENTS.md:23-27` excludes `.memory` from source-of-truth drift checks; current changelog already has July 8 wave entries at `CHANGELOG.md:8-44`. | Do not port. Current changelog gets only this task's fresh entry. |
| Settings/source catalog drift around existing 17 sources | `5013bab7`, `f5c3b545` | superseded | Current Swift source enum has 17 sources at `macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-21`; factory registers those adapters, including `minimax` and `lobsterai`, at `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:7-32`; app catalog mirrors the same 17 at `macos/Engram/Models/SourceCatalog.swift:18-44`. | Do not port duplicate catalog edits. |
| File-index terminal/retry/schema decision primitives | `5013bab7`, `f5c3b545` | superseded | Current tests already cover terminal failure skip, retry backoff, schema mismatch, and known-locator state backfill at `macos/EngramCoreTests/IndexerParityTests.swift:588-652` and `macos/EngramCoreTests/IndexerParityTests.swift:698-732`. | Do not port duplicate primitive tests. |
| Claude Code empty-visible-message parser behavior and system-injection stream filtering | `f5c3b545` | ported | Added `ParserFailure.noVisibleMessages` at `macos/Shared/EngramCore/Adapters/SessionAdapter.swift:197-214`; Claude parser now returns it when visible message count is zero and drops system-injected user records from streaming at `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:193-215` and `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:414-430`. Regression tests are at `macos/EngramCoreTests/AdapterMessageCountTests.swift:1044-1158`. | Hand-ported by patch, not cherry-pick. |
| Terminal handling for the new empty-visible parse failure across index paths | `f5c3b545` | ported | File parse state marks `noVisibleMessages` terminal at `macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:184-232`; FTS and instruction-backfill terminal classifiers include it at `macos/EngramCoreWrite/Indexing/IndexJobRunner.swift:249-268` and `macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:664-672`. | Hand-ported with compile coverage. |
| Snapshot locator freshness / lower-sync local refresh | `f5c3b545` | valuable-missing | Current main has same-sync/same-hash moved-locator handling and file path refresh evidence at `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:91-128` and `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift:345-353`, but the parked branch adds a separate lower-sync freshness gate (`shouldAcceptLowerSyncLocalLocatorRefresh`) plus 129 lines of new tests. | Not ported. This changes merge semantics and should get a focused current-main spec/test pass. |
| SwiftIndexer run-scoped dedup, OK-parse repair, divergent source-size handling, and schema-version v2 bump | `f5c3b545` | valuable-missing | Current `SwiftIndexer.indexAll` writes per 100-item batch without a run-scoped `seenSessionIds` set at `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:44-88`, and known-locator fast paths remain at `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:166-208`. The parked branch adds 67 code lines and `SwiftIndexerRemediationTests.swift` with 305 test lines. | Not ported. Too broad for the 300-line low-risk hand-port window. |
| Grok and Pi provider adapter families, fixtures, and docs | `5013bab7`, `f5c3b545` | valuable-missing | Parked branch adds `GrokAdapter.swift`, `PiAdapter.swift`, TS adapters/tests, parity fixtures, and docs. Current `SourceName` and `SessionAdapterFactory.defaultAdapters()` still expose 17 sources only (`SessionAdapter.swift:3-21`, `SessionAdapterFactory.swift:7-32`). | Not ported. Re-spec provider families from current Swift-first adapter conventions. |
| New Claude-compatible provider source IDs (`mimo`, `doubao`, `glm`, `deepseek`) and related badge/display behavior | `5013bab7`, `f5c3b545` | valuable-missing | Parked branch extends `SourceName` and UI display/badge rules. Current enum has no such source IDs (`SessionAdapter.swift:3-21`), while current originator normalization already exists at `SessionAdapter.swift:23-32` and is used by Codex/Gemini adapters (`CodexAdapter.swift:418-439`, `GeminiCliAdapter.swift:132-153`). | Not ported. Depends on absent provider-source model. |
| Runtime capability checker and MCP/docs count assertions | `285453d7` | valuable-missing | Parked branch adds `scripts/check-runtime-capabilities.ts` and `tests/docs/runtime-capabilities.test.ts` expecting the expanded source/tool matrix. Current `package.json:9-29` has no `check:runtime-capabilities` script and current sources remain 17. | Not ported. Useful as a future guard after source/tool counts are re-baselined on current main. |
| Session taxonomy filter and competitive-session UI closeout | `285453d7` | valuable-missing | Parked branch adds `SessionTaxonomy.swift`, `SessionTaxonomyBadge.swift`, new UI filters/pages changes, and 166 lines of taxonomy tests. Current source tree has no `SessionTaxonomy` symbols in source-of-truth paths. | Not ported. Large UI/data model feature, explicitly outside the hand-port window. |
| TS bootstrap/web route cleanup | `005c90d2`, parts of `f5c3b545` | obsolete | Product runtime is Swift app/service/MCP and TS is retained tooling only (`AGENTS.md:7-11`, `AGENTS.md:55-70`). The parked commit edits `src/core/bootstrap.ts` and `src/web/routes/sessions.ts`, not shipped Swift runtime paths. | Do not port in this reconciliation. Revisit only as a TS tooling task. |
| Provider session-format audit document and broad source-format doc rewrites | `5013bab7`, `f5c3b545` | valuable-missing | Parked branch adds `docs/reviews/provider-session-format-audit-2026-06-30.md` and rewrites most `docs/session-formats/*` files. The branch snapshot predates several July mainline changes and includes provider IDs absent from current main. | Not ported wholesale. Use as reference material for a fresh docs audit. |

## Verification

Local verification performed after the hand-port:

- `cd macos && xcodebuild build -project Engram.xcodeproj -scheme EngramCoreTests -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO` passed.
- `xcrun xctest -XCTest AdapterMessageCountTests ~/Library/Developer/Xcode/DerivedData/Engram-apkspuobooepqkdrdnbizljrophn/Build/Products/Debug/EngramCoreTests.xctest` passed 41 tests.

Earlier direct `xcodebuild test ... -only-testing:EngramCoreTests/AdapterMessageCountTests`
invocations were interrupted after they remained silent with only the parent
`xcodebuild` process alive and no compiler or `xctest` child. The direct
`xcrun xctest` run used the freshly built test bundle and passed.

## Branch Deletion Recommendation

Do not merge or cherry-pick `codex-provider-audit-remediation` wholesale. After
this reconciliation PR is merged, the parked branch can be deleted if the user
does not need it as historical reference for the deferred large features above.
If Grok/Pi, session taxonomy, runtime capability gates, or broad indexer repairs
are wanted, create fresh branches from current `main` with scoped specs instead
of reviving the parked branch.
