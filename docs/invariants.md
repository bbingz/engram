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
- **Verified by** - `macos/EngramTests/DatabaseManagerTests.swift` (testListSessionsExcludesSkipTier, testSearchExcludesSkipAndLiteSessions, testListSessionsWithAllTiers, testCountSessionsExcludesSkipTier), `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (hybrid/semantic search cases), `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift` (testSourceHealthExcludesSkipTierSessions_repro, testSourceHealthCountsLiteTierSessions_repro, testSourceHealthExcludesSkipTierSessionsFromNumerator, testSourceHealthReportsEmptyWhenAllSessionsAreSkipTier), `macos/EngramCoreTests/StartupBackfillTests.swift` (testBackfillCodexNativeParentsDeletesFtsRowsWhenTierBecomesSkip).
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
- **Enforced by** - `macos/Shared/Service/UnixSocketEngramServiceTransport.swift`, `macos/Shared/Service/EngramServiceSocketIO.swift`, `macos/EngramService/Core/ServiceWriterGate.swift`, `docs/SECURITY.md`.
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

## 14. Superseded Insights Stay Off Agent-Facing Reads

- **Statement** - An insight whose `superseded_by` names an existing insight is never returned by an agent-facing `EngramMCP` read: `get_context`, `search`, `get_memory`, or `resources/list`. The predicate is applied when `insightsHasLifecycleColumns()` is true (all three of `superseded_by`, `insight_type`, `access_count` present) and omitted otherwise, which is safe because both writer paths add all four lifecycle columns inside a single transaction, so a partial-column state is unreachable. Rows whose `superseded_by` points at a deleted id are out of the partition and outside this invariant.
- **Enforced by** - `macos/EngramMCP/Core/MCPDatabase.swift`, `macos/EngramCoreWrite/Database/EngramMigrations.swift`.
- **Verified by** - `macos/EngramMCPTests/AuditMediumMCPReproTests.swift` (testGetContextExcludesSupersededInsights_repro, testSearchExcludesSupersededInsights_repro, testGetContextExcludesSupersededInsightsForCJKQuery_repro, testResourceCatalogExcludesSupersededInsights_repro, testGetMemoryRecencyFillsActiveMemoriesPastOverfetchWindow_repro).
- **Gate** - `none`.

## 15. MCP Dual-Era Protocol Honesty

- **Statement** - Stdio EngramMCP and any remote MCP surface negotiate the same dual-era protocol set, share the same tool registry era rules, and refuse unsupported protocol versions with honest errors rather than silently demoting or advertising a version they cannot serve.
- **Enforced by** - `macos/EngramMCP/Core/MCPStdioServer.swift`, `macos/EngramMCP/Core/MCPToolRegistry.swift`, `docs/mcp-protocol-alignment-design.md`, `docs/remote-mcp-2026-07-28-design.md`.
- **Verified by** - `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (testInitializeAcceptsOlderCodexProtocolVersion, testInitializeAcceptsCurrentCodexProtocolVersion, testInitializeNegotiatesUnknownProtocolVersionToLatest, testModernRequestWithUnsupportedVersionReturnsUnsupportedProtocolVersionError, testModernMetaWithNonStringVersionIsUnsupportedProtocolVersion_repro).
- **Gate** - `none`.

## External Service Ownership

- **Statement** - Once the App adopts an externally managed service, quitting, failed health probes, and manual reconnect do not signal or replace that service, acquire its writer locks, or remove its runtime secrets. Persisted index role pins external ownership before its initial probe, including an absent socket; cancelled or terminated App connection tasks cannot start later. Ordinary settings migration and user-initiated credential settings remain outside this lifecycle-only guarantee.
- **Enforced by** - `macos/Engram/Core/EngramServiceLauncher.swift` (adoptedConfiguration, startHealthMonitor, restart, stopIfOwned), `macos/Engram/App.swift`, `macos/Shared/EngramCore/RuntimeRoleSettings.swift`.
- **Verified by** - `macos/EngramTests/EngramServiceLauncherTests.swift` (testQuitPreservesAdoptedServiceAndItsRuntimeSecrets_repro, testAdoptedServiceProbeFailureRecoversWithoutShutdownOrReplacement_repro, testSuspendedAdoptedProbeCannotRestartAfterQuit_repro, testRestartOfAdoptedServiceOnlyReconnects_repro, testRuntimeRoleColdIndexCannotSpawnOrTouchLockAndSecrets_repro, testRuntimeRoleSuspendedInitialProbeCannotStartAfterQuit_repro), `macos/EngramTests/RuntimeRoleAppTests.swift` (testTerminatedIndexAppCannotRestartOrPublishLateStatus_repro).
- **Gate** - `none`.

## Persisted Host Role Before Local Index Access

- **Statement** - The App and MCP resolve the same owner-only persisted role before local-index access. Collector, replica and invalid settings cannot open the local product DB or start a service through the App; they do not automatically migrate settings/credentials. Missing role preserves local behavior. This is a host-entry guard, not proof of a complete collector or source coverage.
- **Enforced by** - `macos/Shared/EngramCore/RuntimeRoleSettings.swift`, `macos/Engram/Core/AppEnvironment.swift`, `macos/Engram/App.swift`, `macos/Engram/Core/Database.swift`, `macos/EngramMCP/Core/MCPConfig.swift`, `macos/EngramMCP/Core/MCPToolRegistry.swift`.
- **Verified by** - `macos/EngramCoreTests/RuntimeRoleSettingsTests.swift`, `macos/EngramTests/RuntimeRoleAppTests.swift`, `macos/EngramTests/DatabaseManagerTests.swift`, `macos/EngramMCPTests/EngramMCPExecutableTests.swift` (runtime-role tests).
- **Gate** - `none`.

## Collector Capture Core Excludes Product Index Dependencies

- **Statement** - CollectorCore compiles only explicit capture/identity/privacy sources, a narrow shared metadata projection and GRDB, with no CoreRead/CoreWrite/Service/full-parser dependencies or product index tables. CoreWrite reuses the same five capture files, not a second implementation. The archive no-delete gate scans their new location with the same global unlink limits. This foundation does not yet guarantee a complete no-index collector executable.
- **Enforced by** - `macos/project.yml`, `macos/EngramCaptureShared/ArchiveCatalog.swift`, `macos/EngramCaptureShared/ExactSourceCapturer.swift`, `scripts/check-archive-v2-safety.sh`.
- **Verified by** - `macos/EngramCollectorCoreTests/CollectorTargetDependencyTests.swift`, `macos/EngramCollectorCoreTests/CollectorCaptureCoreTests.swift`, `tests/scripts/archive-v2-safety-gate.test.ts`.
- **Gate** - `none`.

## Collector Publication ACK Durability

- **Statement** - A collector capture ACK is issued only after one encrypted immutable acceptance record durably commits both the publication and its arrival identity. Restart rebuilds discovery from those records; uncertain storage or journal ownership fails closed. This ACK neither creates a legacy bound receipt nor proves parsing, keyword readiness, or reclamation authority. Publication intake is default OFF.
- **Enforced by** - `macos/EngramRemoteServer/Core/ArchiveStore.swift`, `macos/EngramRemoteServer/Core/ArchiveEnvelopeCodec.swift`, `macos/EngramRemoteServer/Core/ArchivePublicationRoutes.swift`, `macos/EngramRemoteServer/Core/ArchiveRoutes.swift`, `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift`.
- **Verified by** - `macos/EngramRemoteServerCoreTests/ArchivePublicationStoreTests.swift` (testFirstAcceptanceIsEncryptedImmutableAndIdenticalRetryReturnsOriginalACK, testAcceptedRecordSurvivesIndependentProcessRestart, testAcceptanceDirectoryFsyncFailureReconcilesTheOneRenamedRecord, testArrivalCursorReadsLaterSmallerDigestAndRemainsReusableAtEOF), `macos/EngramRemoteServerCoreTests/ArchivePublicationRouteTests.swift`, `macos/EngramRemoteServerCoreTests/CollectorPublicationModelTests.swift`.
- **Gate** - `none`.

## Durable Collector Intake Is Not Index Readiness

- **Statement** - Publication bytes, per-parser work, replica arrivals and checkpoint advancement share one inner savepoint. Identical replay cannot reset terminal work, and conflicting stream tuples quarantine nonterminal work without retracting last-good parsed/index-ready rows. Pending intake does not authorize parsing, source/epoch promotion or session/FTS writes.
- **Enforced by** - `macos/EngramCoreWrite/CaptureIngest/CaptureIngestLedger.swift`, `macos/EngramCoreWrite/CaptureIngest/CaptureIngestIdentity.swift`, `macos/EngramCoreWrite/Database/EngramMigrations.swift`.
- **Verified by** - `macos/EngramCoreTests/CaptureIngest/CaptureIngestLedgerTests.swift`, `macos/EngramCoreTests/CaptureIngest/CaptureIngestIdentityTests.swift`.
- **Gate** - `none`.

## Source and Epoch Authority Precedes Capture Replay

- **Statement** - Capture eligibility requires an explicitly provisioned machine/source-instance/root/parse-format binding and an approved epoch. Unknown streams, overlapping roots, unsupported shapes and unapproved epochs are quarantined without promoting last-good data. Legacy NULL parse formats remain unprovisioned; epoch changes use expected-binding checks and retain the selected format. This database contract does not expose an operator command or perform replay.
- **Enforced by** - `macos/EngramCoreWrite/CaptureIngest/CaptureIngestSourceRegistry.swift`, `macos/EngramCoreWrite/Database/EngramMigrations.swift`.
- **Verified by** - `macos/EngramCoreTests/CaptureIngest/CaptureIngestSourceRegistryTests.swift`.
- **Gate** - `none`.

## Local Privacy Proof Binds Captured Bytes and Current Format

- **Statement** - Upload eligibility uses the immutable captured generation, not a later live source read. The shared metadata projection (`SourceMetadataProjection.Format`, one case per collector root format: 17 as of 2026-10-02, not only Claude/Codex) preserves parser selection while retaining conflicting evidence for conservative withholding; per-format parser parity is guaranteed only where the verifying tests name that format. Proof binds capture/manifest/whole-source identity, project root, exclusion-policy revision/digest and the entire selected format; fresh policy and format are mandatory before upload. Unsupported, incomplete, conflicting or excluded evidence does not authorize transfer. This local proof neither proves an HQ replay nor retroactively removes remote bytes.
- **Enforced by** - `macos/EngramCollectorCore/CollectorPrivacyProof.swift`, `macos/Shared/EngramCore/Adapters/SourceMetadataProjection.swift`.
- **Verified by** - `macos/EngramCollectorCoreTests/CollectorPrivacyProofTests.swift`, `macos/EngramCoreTests/Adapters/SourceMetadataProjectionParityTests.swift`.
- **Gate** - `none`.

## Transcript Continuation Preserves Redacted UTF-8 Payloads

- **Statement** - The pure Service pager redacts every string field before fragmenting normalized message JSON at UTF-8 boundaries. Cursors bind session, immutable generation, projection, redaction revision, roles, ordinal, offset and payload digest; stale or unavailable snapshots fail explicitly. Encoded envelope sizing includes Data/base64 escaping and reserves framing headroom. The pager does not itself establish snapshot authority or expose an IPC command.
- **Enforced by** - `macos/EngramService/Core/ServiceTranscriptContinuation.swift`, `macos/Shared/Service/EngramServiceWebReadModels.swift`.
- **Verified by** - `macos/EngramServiceCoreTests/WebTranscriptContinuationTests.swift`, `macos/EngramServiceCoreTests/WebTranscriptWireTests.swift`.
- **Gate** - `none`.

## Web Reader and Editor Authority

- **Statement** - Web is off unless explicitly configured; when configured, RemoteServer mounts the authenticated read routes and the write routes together. The viewer credential must differ from every server bearer credential, and the optional editor credential must differ from the viewer and server credentials and is kept only as a digest. Every authenticated session can read, but only a session minted from the editor credential can write, and that authority ends at logout or expiry. Write routes pass the same exact-Host and `X-Engram-Web: 1` API validation as reads and additionally require an exact Origin; a viewer session or a missing Origin is rejected with 403 before the write surface is called. The read client sends only allowlisted typed commands and attaches no capability token. The write client rejects unlisted commands, attaches the local service capability token only to the Unix-socket request and never to HTTP JSON, and opens no IPC when the token is missing. Login throttling is one global five-attempt window with no per-client partition. This entry does not limit what an editor may change through the allowlisted writes, and it does not isolate a compromised RemoteServer process.
- **Enforced by** - `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`, `macos/EngramRemoteServer/Core/EngramRemoteWebConfig.swift`, `macos/EngramRemoteServer/Core/WebAuthSessionStore.swift`, `macos/EngramRemoteServer/Core/WebRequestBoundary.swift`, `macos/EngramRemoteServer/Core/WebWriteRoutes.swift`, `macos/Shared/Service/EngramServiceWebWriteClient.swift`.
- **Verified by** - `macos/EngramRemoteServerCoreTests/WebServerIntegrationTests.swift` (testWebConfigurationDefaultsOffAndExplicitValuesRoundTrip, testDefaultOffReturns404WithZeroFactoryCallsAndZeroRealSocketAccepts), `macos/EngramRemoteServerCoreTests/WebConfigTests.swift` (testViewerCredentialMustDifferFromEveryProvidedBearer, testOptionalEditorCredentialIsDistinctAndStoredOnlyAsDigest), `macos/EngramRemoteServerCoreTests/WebAuthSessionTests.swift` (testEditorAuthorityIsBoundToItsOwnSessionAndRevokedOnLogoutOrExpiry, testViewerOnlyConfigurationNeverGrantsWriteAuthority, testGlobalFiveAttemptWindowCountsBothFailedAndSuccessfulLogins), `macos/EngramRemoteServerCoreTests/WebAliasHTTPTests.swift` (testViewerPostIs403AndDoesNotCallWriteSurface, testEditorAddPreservesPathShapedAliasText), `macos/EngramRemoteServerCoreTests/WebProjectMigrationHTTPTests.swift` (testViewerCsrfAndDisabledEditorNeverReachProjectWriter), `macos/EngramRemoteServerCoreTests/WebRelationshipHTTPTests.swift` (testViewerAndMissingOriginCannotReachAnyRelationshipWriter), `macos/EngramRemoteServerCoreTests/WebAuthRouteTests.swift` (testAuthorityMismatchDuplicateHostAndForwardedSpoofingFailClosed, testAPIMarkerMustBeSingleExactOneForEveryAPIRequest), `macos/EngramRemoteServerCoreTests/WebReadClientTests.swift` (testMessagesSendsOnlyHardcodedCommandTypedDataUUIDAndNoCapability, testAllowlistRejectsExhaustiveLiveHandlerInventoryBeforeAnyIPC), `macos/EngramRemoteServerCoreTests/WebWriteClientTests.swift` (testAllowlistRejectsUnknownCommandsWithoutIPC, testAddAliasAttachesLocalTokenAndNeverPutsItOnHTTPJSON, testMissingTokenDoesNotOpenIPC).
- **Gate** - `none`.

## Optional AI Maintenance Does Not Gate Required Index Readiness

- **Statement** - Initial scan and periodic indexing do not await embedding providers. A separate bounded maintenance task starts after the required scan, checks provider configuration and cooldown before backlog queries, and retains existing retry/terminal semantics. Orderly shutdown explicitly cancels and joins that task before draining writers and checkpointing; optional work cannot retain writer ownership after the runner returns.
- **Enforced by** - `macos/EngramService/Core/EngramServiceRunner.swift`.
- **Verified by** - `macos/EngramServiceCoreTests/OptionalAIReadinessTests.swift`, `macos/EngramServiceCoreTests/EmbeddingGuardrailsTests.swift`, `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift`.
- **Gate** - `none`.

## Legacy Host Scan Runs Only in the Local Role

- **Statement** - Only an EngramService whose persisted role is `local` (including a missing settings file) runs the legacy scan of host source files: the initial scan, periodic `indexRecentSessions`, and the Archive V2 backlog drainer. `index`, `collector`, `replica` and invalid settings give those paths no adapters, whatever `ENGRAM_DISABLED_SOURCES` or settings `disabledSources` say, so an index host does not store a local-origin copy of a session it also receives through capture ingest. The role is read once at startup. Before reading it, the service sets an owner-owned, single-link regular settings file of at most 1 MiB to mode 0600 (the repair its settings readers already made); the App and MCP never repair and fail closed. A gated initial scan leaves the usage-parser backfill version pending. A disabled scan is reported once in the service log ring, at error level with the failed check for invalid settings. Capture-ingest policy, source authority and `setSourceEnabled` still read settings only. Existing local-origin rows are neither removed nor rewritten.
- **Enforced by** - `macos/EngramService/Core/EngramServiceRunner.swift`, `macos/Shared/EngramCore/RuntimeRoleSettings.swift`.
- **Verified by** - `macos/EngramServiceCoreTests/ServiceCaptureIngestRuntimeTests.swift` (testIndexRoleLegacyScanNeverStoresHostSessionTwice_repro), `macos/EngramServiceCoreTests/EngramServiceIPCTests.swift` (testLegacyScanEnvironmentRunsOnlyForLocalRole), `macos/EngramServiceCoreTests/ServiceTelemetryTests.swift` (testGatedRoleInitialScanLeavesUsageParserBackfillPending_repro).
- **Gate** - `none`.

## Collector Root Binding Survives Device Renumbering Only

- **Statement** - A stored collector root binding is rebound in place only when the live root differs from it in `st_dev` alone; inode, `st_gen` and a known birth time must all match. Any other identity change keeps the root suspended and never joins the original stream, and the rebind leaves root revision, source instance, epoch and sequence unchanged. The bootstrap scan, the Gemini/Kimi registry check and the Cursor-modern/VSCode captured-dependency checks treat a device-only file difference as unchanged, while capture IDs and manifests keep the device. This does not cover every fingerprint: the Cursor legacy observer and Cursor-modern event fingerprints still include the device, so a renumbering re-captures the legacy Cursor state database once and re-dirties each Cursor-modern session on its first event, and captures in flight at the reboot are re-captured. A root suspended for an identity change is reported on stderr whenever the suspended set changes; publication delivery continues. A real mount renumbering is not exercised by tests, which rewrite the stored device instead.
- **Enforced by** - `macos/EngramCollectorCore/CollectorPOSIXRootEnumerator.swift`, `macos/EngramCollectorCore/CollectorInventoryOwner.swift`, `macos/EngramCollectorCore/CollectorInventoryStore.swift`, `macos/EngramCollectorCore/CollectorRuntime.swift`.
- **Verified by** - `macos/EngramCollectorCoreTests/CollectorInventoryOwnerTests.swift` (testDeviceRenumberingKeepsRootBoundAndEnumerating_repro, testDeviceRenumberingRuleStillRejectsDifferentInodeOrBirthTime, testDeviceRenumberingDoesNotDirtyUnchangedFiles_repro), `macos/EngramServiceCoreTests/CollectorRuntimeTests.swift` (testDeviceRenumberingRebindsAndCapturesWithoutRepublishing_repro, testRootIdentitySuspensionIsReportedOnceAndRuntimeKeepsRunning).
- **Gate** - `none`.

## Collector Event Loss Is A Root-Local Gap

- **Statement** - An event-stream loss (overflow, kernel or user drop, structural flag, budget) records a durable gap that forces a full walk of that root only. It never ends the collector process and never rewrites the stored checkpoint. After a loss gap is durable, that coordinator does not replay the same stored history again; a new process still tries a stale checkpoint once. Only a stored checkpoint whose FSEvents epoch differs from the live epoch stops the runtime, and it never rebases the checkpoint. A process-ending failure is reported as one stderr line naming the error type and case, without payload. A real history truncation is not exercised by tests, which inject the loss through a fake stream.
- **Enforced by** - `macos/EngramCollectorCore/CollectorRuntime.swift`, `macos/EngramCollectorCore/CollectorEventCoordinator.swift`, `macos/EngramCollector/main.swift`.
- **Verified by** - `macos/EngramCollectorCoreTests/CollectorEventCoordinatorTests.swift` (testReplayLossFromStoredCheckpointConvergesWithoutReplayingItAgain_repro, testRestartResumesOnlyDurableCheckpointAndEpochMismatchCannotRebase), `macos/EngramServiceCoreTests/CollectorRuntimeTests.swift` (testReplayLossDuringStartKeepsRuntimeAndOtherRootsRunning_repro, testNativeEpochChangeStillStopsRuntimeWithoutRebasingCheckpoint, testFailureReasonNamesErrorTypeAndCaseWithoutPayload).
- **Gate** - `none`.

## Unverified Anchors

None.
