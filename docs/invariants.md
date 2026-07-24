# Invariants

Invariants are properties that must survive every change; each entry names where the property is enforced and which test verifies it. PRs touching an invariant must keep these anchors current. `scripts/check-invariants-ledger.sh` validates backticked repo paths and runs allowlisted behavioral gates from `scripts/invariant-gates.json` (exact `["bash","scripts/<repo-owned>.sh"]` argv only — never markdown-to-shell). Humans remain responsible for checking semantic meaning beyond the executable gates.

## 1. Single-Writer Discipline

- **Statement** - The app, MCP, and CLI never open a second SQLite writer; product writes go through `EngramServiceClient` and are serialized by `ServiceWriterGate`.
- **Enforced by** - `macos/Shared/Service/EngramServiceClient.swift`, `macos/EngramService/Core/ServiceWriterGate.swift`, `scripts/check-app-mcp-cli-direct-writes.sh`.
- **Verified by** - `tests/scripts/product-boundary-scripts.test.ts` (product-boundary wrapper for `scripts/check-app-mcp-cli-direct-writes.sh`).
- **Gate** - `macos-vitest` in `.github/workflows/test.yml`.

## 2. Subagent Sessions Stay Skip

- **Statement** - Subagent, dispatch, and noise sessions stay `tier='skip'`; parent-link operations such as setParentSession do not upgrade child sessions out of skip.
- **Enforced by** - `macos/EngramService/Core/EngramServiceCommandHandler.swift`, `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`, `macos/Shared/EngramCore/Indexing/SessionTier.swift`.
- **Verified by** - `macos/EngramCoreTests/StartupBackfillTests.swift` (testDowngradeSubagentTiersAndRemoveFTSRows, testReconcileSkipTierDeletesStaleArtifactsWithoutTouchingTierOrNonSkip, testBackfillCodexNativeParentsLinksVendorStampedChild_repro, testBackfillCodexNativeParentsUsesTopLevelParentThreadIdFallback), `macos/EngramTests/AgentsViewTests.swift` (testExpandableSessionCardHasNoSetParentHook).
- **Gate** - `none`.

## 3. Tier Visibility

- **Statement** - `skip` sessions are hidden from normal read surfaces; `lite` sessions remain visible in lists but are excluded from keyword search results.
- **Enforced by** - `macos/Shared/EngramCore/Indexing/SessionTier.swift`, `macos/EngramService/Core/EngramServiceReadProvider.swift`, `macos/Engram/Core/Database.swift`, `macos/EngramMCP/Core/MCPDatabase.swift`, `macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift` (keyword + semantic tier filter SQL shared with service/MCP).
- **Verified by** - `macos/EngramTests/DatabaseManagerTests.swift` (testListSessionsExcludesSkipTier, testSearchExcludesSkipAndLiteSessions, testListSessionsWithAllTiers, testCountSessionsExcludesSkipTier), `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (hybrid/semantic search cases), `macos/EngramCoreTests/StartupBackfillTests.swift` (testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip).
- **Gate** - `none`.

## 4. Parent-Detection Parity Triple Lock

- **Statement** - Swift `ParentDetection.detectionVersion`, retained TypeScript `DETECTION_VERSION`, and the generated fixture version must stay equal.
- **Enforced by** - `macos/Shared/EngramCore/Indexing/ParentDetection.swift`, `src/core/parent-detection.ts`, `tests/fixtures/parent-detection/detection-version.json`.
- **Verified by** - `macos/EngramTests/ParentDetectionParityTests.swift` (testDetectionVersionAndFixtureCasesMatchNodeReference).
- **Gate** - `none`.

## 5. FTS Full Rebuild Versioning

- **Statement** - Product FTS full re-index happens only when `FTSRebuildPolicy.expectedVersion` changes.
- **Enforced by** - `macos/EngramCoreWrite/Database/FTSRebuildPolicy.swift`.
- **Verified by** - `macos/EngramCoreTests/Database/FTSRebuildPolicyTests.swift` (testOldFTSVersionRebuildPreservesSessionMetadata, testCurrentFTSVersionIsNoOp, testFreshEmptyDatabaseMarksCurrentVersionWithoutShadowRebuild, testRebuildReopensCompletedFtsJobsForReindex).
- **Gate** - `none`.

## 6. Tests Avoid Production Engram Data

- **Statement** - Tests must not read or write the production `~/.engram`; they use temp directories and test-specific `ENGRAM_BACKUP_DIR` values.
- **Enforced by** - `AGENTS.md`, `CLAUDE.md`, `macos/EngramCoreTests/UserDataBackupTests.swift`.
- **Verified by** - `macos/EngramCoreTests/UserDataBackupTests.swift` (testBackupRoundTripCapturesOnlyIrreplaceableUserRows, testBackupDirectoryRejectsSymlinkAncestor).
- **Gate** - `none`.

## 7. Bundle Hygiene Excludes Node Artifacts

- **Statement** - Release app bundles contain no Node runtime artifacts: `node`, `node_modules`, `dist`, `daemon.js`, `index.js`, or `web.js`.
- **Enforced by** - `macos/scripts/release-verify.sh`.
- **Verified by** - `tests/scripts/build-release-script.test.ts` (hygiene-only mode tests).
- **Gate** - `swift-unit` hygiene step in `.github/workflows/test.yml`.

## 8. Service Socket Security

- **Statement** - The service socket uses a private runtime directory, owner-only socket permissions, capability-token authorization for mutating commands, and current-user local socket confinement.
- **Enforced by** - `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`, `macos/EngramService/Core/ServiceWriterGate.swift`, `docs/SECURITY.md`.
- **Verified by** - `macos/EngramServiceCoreTests/ServiceSecurityHardeningTests.swift` (testDestructiveCommandWithoutTokenIsUnauthorized, testEveryMutatingCommandRequiresCapabilityToken, testCapabilityTokenFileIsWrittenWithOwnerOnlyPermissions, testClientAutoAttachedTokenAuthorizesDestructiveCommand).
- **Gate** - `none`.

## 9. Startup Backfills Are Ordered and Idempotent

- **Statement** - Startup backfills are version-gated and idempotent; the Codex model-label backfill runs before the session cost backfill so relabeled rows get correct costs.
- **Enforced by** - `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`.
- **Verified by** - `macos/EngramCoreTests/StartupBackfillTests.swift` (testBackfillCodexModelLabelsVersionGatePreventsSecondScan, testCodexModelBackfillRunsBeforeCostBackfillAndRecomputesRelabeledCost, testRunInitialScanEmitsNodeCompatibleStartupEventsInOrder, testBackfillCodexNativeParentsVersionGatePreventsSecondSweep, testBackfillCodexNativeParentsIsIdempotentOverAlreadyLinkedRows).
- **Gate** - `none`.

## 10. Manual Unlink Is Respected

- **Statement** - `link_source='manual'` with a NULL parent means explicitly unlinked; parent backfills and rescoring must not relink those rows.
- **Enforced by** - `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`, `src/core/db/maintenance.ts`.
- **Verified by** - `macos/EngramCoreTests/StartupBackfillTests.swift` (testBackfillParentLinksUsesPathAndPreservesManualLinks, testResetStaleDetectionsStoresVersionAndSkipsManualLinks, testBackfillCodexNativeParentsPreservesManualUnlink), `tests/core/maintenance.test.ts` (manual-link preservation cases).
- **Gate** - `none`.

## 11. Sessions Schema Migrations Are Idempotent

- **Statement** - Session schema migrations are idempotent; adding a sessions column requires both the inline CREATE TABLE shape and the additive sessions-column migration list to stay aligned.
- **Enforced by** - `macos/EngramCoreWrite/Database/EngramMigrations.swift`.
- **Verified by** - `macos/EngramCoreTests/Database/MigrationRunnerTests.swift` (testCreatesFreshCurrentSchema, testMigrationIsIdempotentAcrossRepeatedRuns, testPreservesExistingSessionRows).
- **Gate** - `none`.

## 12. EngramMCP Is Read-Only Except Service IPC Writes

- **Statement** - `EngramMCP` opens direct GRDB access read-only and routes mutating tool behavior through the service IPC client instead of direct SQLite writes.
- **Enforced by** - `macos/EngramMCP/Core/MCPDatabase.swift`, `macos/EngramMCP/Core/MCPToolRegistry.swift`, `scripts/check-app-mcp-cli-direct-writes.sh`.
- **Verified by** - `tests/scripts/product-boundary-scripts.test.ts` (direct-write boundary wrapper), `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (testSaveInsightMatchesGoldenViaServiceSocket, testDeleteInsightRoutesThroughServiceSocket, testHideSessionRoutesThroughServiceSocket, testNativeProjectOperationsRouteThroughTheService).
- **Gate** - `macos-vitest` in `.github/workflows/test.yml`.

## 13. JSONL Tail Checkpoints Stop at Complete Lines

- **Statement** - Append-tail checkpoints advance `file_index_state.parsed_offset` only to a newline-complete JSONL boundary and persist a bounded boundary hash for that offset; boundary mismatch, shrink, or unprovable merge context must fall back to full reparse.
- **Enforced by** - `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift`, `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift`, `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`.
- **Verified by** - `macos/EngramCoreTests/IndexerParseOnceTests.swift` (testClaudeCodeTailParseAppendMatchesFullReindex, testClaudeCodeTailParseNoTrailingNewlineFallsBackWithoutDoubleCounting, testClaudeCodeTailParseNoVisibleCompleteTailFallsBackAndRefreshesSize, testClaudeCodeTailParseRewriteInPlaceFallsBackToFullReparse, testClaudeCodeTailParseTruncationFallsBackToFullReparse, testClaudeCodeTailParseDoesNotAdvancePastPartialLineAndLaterIndexesIt).
- **Gate** - `none`.

## Unverified Anchors

None.
