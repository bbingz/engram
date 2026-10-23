# Engram development reconciliation — 2026-10-23

## Baseline and counting rules

- Baseline: local `main` and live `origin/main` both
  `5216ff3a61202b4c113b1e20799a03ad7e7df706` (`git ls-remote`, 2026-10-23).
- Implementation checkout: `.worktrees/leader-loop-20261023`, branch
  `codex/leader-loop-20261023`. The main checkout's untracked
  `.grok/workflows/engram-session-status.rhai` is unrelated and preserved.
- Canonical ownership remains `docs/TODO.md` (engineering),
  `docs/followups.md` (verification/residuals), and `docs/roadmap.md` (product).
  This dated report supplies routing and evidence, not a second backlog.
- Inventory covers all 21 files in `docs/superpowers/plans`, 24 specs, root
  design documents, the lifecycle/relaunch plans, current follow-ups, and
  their explicitly referenced closeout/checklist records. Archives, generated
  reports, fixtures, and historical review findings are not new work queues.
- The 397 literal unchecked markers in the 21 plans include procedural steps
  and even checkbox examples. They are **not 397 outstanding deliverables**.
  Count one named residual/product decision, deduplicate repeated IDs, and
  retain deployment and real-host acceptance separately from implementation.
- Live GitHub query: 0 open issues and 6 open dependency PRs (#490–#495).
  Baseline Tests [39366050861](https://github.com/bbingz/engram/actions/runs/39366050861)
  and CodeQL [39366050927](https://github.com/bbingz/engram/actions/runs/39366050927)
  succeeded at this baseline. They do not validate this branch.

## Development loop

Owner requested continuous project leadership on 2026-10-23. For each batch:
refresh current source and worktree; choose a bounded confirmed item; capture
a failing behavioral regression; make the minimum fix; run focused and
affected contract checks; review the diff; update canonical status and
CHANGELOG/MEMO; select the next item. A failed check is not completion.

Local development and tests are authorized. Push, PR publication, merge,
deployment, service restart, production configuration/data writes, public
release, and reboot remain separate actions requiring task-specific owner
authorization. No local Docker. No production database is a test fixture.
The active goal is the continuation mechanism for this conversation; no
background daemon, scheduler, or unattended external-write loop was installed.

Leadership default after reliability: finish the software side of collector
cutover and Web authority honesty, then improve human search and measured
value visibility, then evaluate opt-in memory automation. Write acceptance
criteria before schema/adapter-wide changes. Existing explicit exclusions
(native sqlite-vec, removed corpus mining, remote deletion, new release
channels) are not silently overturned. Routine implementation choices within
the selected local batch do not need repeated owner confirmation.

## First engineering queue

| Order | Canonical item | Current evidence / disposition | Completion verifier |
|---|---|---|---|
| 1 | `cutover-role-surface-1` | Fixed locally; 215 MCP executable tests passed after 8 expected RED assertions. `MCPToolRegistry.tools` still returned 27 definitions for collector/replica/invalid roles while calls were refused. | Executable legacy/modern `tools/list` returns an empty list; local/index/default catalogs remain usable; direct calls still fail before DB/service access. |
| 2 | `collector-settings-write-flake-1` | Fixed locally: complete sibling file, 0600 before rename; all 85 runtime tests passed. Hosted recurrence unmeasured. | Publish a complete owner-only fixture atomically; exercise invalid configuration reload without transient JSON/permission failures. |
| 3 | `collector-test-fixture-leak-1` | Fixed locally: deferred fixture removal; affected test passed. | Match fixture cleanup pattern and run the affected test. |
| 4 | `collector-blocked-root-backoff-1` | Fixed locally; final 87 runtime tests passed after behavioral RED and scheduler negative control. Per-root monotonic backoff, capped at 60 seconds, preserves healthy-root progress and recovery. | Deterministic clock/recovery tests, healthy-root progress, bounded blocked attempts. |
| 5 | Round-12 secrets cluster | Existing fixes verified locally for the summarized scope; part of the 210-test App GREEN below. No redundant production patch. | Filesystem/secret failure cases, empty-key policy and injected-home/socket routing. |
| 6 | `session-detail-id-*` | Live-navigation/favorite residuals closed locally. Mounted transcript verification found and fixed stale paging cleanup/duplicate scheduling; initial/result/index cancellation passed the tested interleavings. | Five mounted tests passed five iterations; final-harness negative control failed 17 expected assertions; restored final 72 transcript tests passed. No full UI/production claim. |
| 7 | `cutover-web-editor-hardening-1` | Project-operation actor propagation and endpoint/key reuse fixed locally. Alias audit storage now implemented below; credential throttle remains an accepted design residual. | Actor/dispatcher receipts below. Endpoint batch: 26 service, 24 HTTP/IPC/UI-route and 181 JS tests passed after RED; fake keys only. |
| 8 | Collector CPU work | One parent acceptance item, not separate counts for every hotspot. Publication, idle-turn, stuck-dirty and startup leads remain below. | Profile the changed path before tuning; retain CPU <=2% / RSS <=150 MiB real-host acceptance separately. |

## Completed local batch: blocked-root retry backoff

- Scope: runtime scheduling only; preserve coordinator loss persistence, scan
  fences, source identities, fail-closed filesystem checks and upload workers.
- On blocked bootstrap, postpone that root's restart and new capture by 1, 2,
  4, 8, 16, 32, then at most 60 seconds on a monotonic clock. A healthy root
  can continue its own scan/capture/publication. Existing durable publications
  remain eligible for the independent upload loops.
- Partial re-walk progress does not reset the accumulated delay; a completed
  scan does. Fresh process start retries immediately; no schema or persisted
  deadline is introduced. Missing/replaced root handling keeps its own guard.
- A cooling root must not make the resident capture scheduler spin on its
  pending loss/recovery signal. Retry becomes eligible at the deadline and is
  observed at the existing cheap-wake cadence (at most one second), subject to
  work already in progress. Cancellation still interrupts normal waits.
- Acceptance: deterministic clock tests prove bounded stream/revision churn,
  delay cap, healthy-root ACKs, permission recovery, reset and restart;
  resident-loop regression proves no hot capture spin during the delay.
- Verification: behavioral RED produced 24 expected assertions; omitting the
  cooling-root mailbox filter made the resident regression fail. After restoring
  the filter, all 87 runtime tests passed. Lint and the invariant ledger passed.
  Logs and xcresults: `/tmp/engram-leader-backoff-20261023/`; final result is
  `green-final.xcresult`. Next batch is current-source security/UI adjudication.
- Risk: a newly readable blocked root can wait up to the remaining 60-second
  delay plus scheduler/work latency. No CPU target or host recovery claim is
  made without a separately authorized real-host receipt.

## Current-source adjudication: secrets and session identity

The September `.grok/all-confirmed-remediation-ledger-2026-09-02.md` records
W1/W7/W9 remediation and explains why the August blanket-open text was stale.
That record was only a navigation lead; the decisions below use current source
and fresh tests at local commit `414b7c18`.

| Summarized claim | Verdict / current evidence |
|---|---|
| Runtime-secret writes/cleanup follow caller-controlled paths or own unrelated siblings | OVERTURNED for the described current paths. `EngramServiceLauncher.writeRuntimeAISecrets` validates the runtime parent; `SecureRegularFile` pins directory FDs and uses no-follow read/write/unlink operations. Custom socket sidecars are namespaced. Tests exercise leaf/intermediate symlinks, hardlinks, failed publication and unrelated siblings. |
| AI key deletion/save failures are reported as successful | OVERTURNED. `APIKeyPersistencePolicy` checks settings writes/deletion; `reconcilingRuntimeBridgeRefresh` preserves marker failures and reports bridge failures. Empty unavailable keys are preserved until explicit clearing. Policy and call-site tests passed; no real Keychain was used. |
| Settings refresh/default test DB falls through to the login user's runtime | OVERTURNED for the reported entry paths. App/menu/main-window Settings pass the resolved socket to `AISettingsSection`; default DB uses `EngramUserDataDirectory.resolvedHomeDirectory`. Injected socket/source-wiring and temporary-home regression passed. This is not a fresh whole-suite filesystem-access audit. |
| Live navigation and delayed favorite reads lack identity guards | OVERTURNED. Popover/SourcePulse complete captured nil-resolution tokens; favorites compare generation and invalidate it on successful toggle/disappear. Current navigation/predicate/source-wiring tests passed. |
| Every transcript apply is identity-fenced | NARROWED by the mounted-view batch below. Existing cancellation checks protect the tested initial success/error, page/error and delayed index applications. The actual reproduced defect was unowned paging cleanup plus duplicate scheduling; both fixed locally. This is bounded concurrency evidence, not an exhaustive proof of every UI interleaving. |

Fresh validation: `xcodebuild test`, scheme `EngramTests`, isolated
`CFFIXED_USER_HOME` and `TEST_RUNNER_CFFIXED_USER_HOME`, same DerivedData as
above, passed 210 tests: AISettingsSection 36, selected launcher 19,
UnixSocketTransport 32, injected-home DB 1, HomePopoverActions 43,
TodayWorkbenchScope 39 and TranscriptFind 40. No production code changed;
there is no newly claimed RED. Logs, exact selectors and xcresult:
`/tmp/engram-leader-residuals-20261023/app-{command.txt,residuals.log,residuals.xcresult}`
(command file is `app-command.txt`). No mounted UI/render, hosted or live
credential test was run. The next batch implemented Web project audit actor propagation (below);
the former fixed actor enum required a bounded identity value, not DTO
forwarding alone.

## Web project audit actor batch

The [phase-2 addendum](../superpowers/specs/2026-10-23-web-project-audit-actor-addendum.md)
recorded a baseline correction: alias add/remove had no audit-log writer
or actor field. The later alias-audit batch below closes that separate design. This batch
covers the four existing project audit paths only, with no schema migration.
RemoteServer injects the bound editor identity (credential fallback web-editor)
after browser-key validation, typed IPC carries it with the existing capability
token, and Service writes it through the native pipeline/batch override. Actor
is included in replay fingerprints. Native actor parsing/defaults stay intact.

RED: 8 HTTP identity assertions, and 8 service assertions covering malformed
actor decoding, audit readback and cross-actor replay. GREEN: 60 Web HTTP/auth/IPC tests, 29 service/project-registry tests and 34
native batch/store tests passed. Lint and invariant gates also passed. Evidence: `/tmp/engram-leader-web-actor-20261023/`.
Continuation found the dispatcher still rejected actor despite the component
GREEN at `6d30437a`. The four optional IPC field allowlists are now updated.
The audit/replay test now uses the real Web client/socket/dispatcher/storage:
it failed before the fix, then passed with all 18 selected service tests.
Evidence: `/tmp/engram-leader-web-dispatch-20261023/`. This supersedes the prior
component-only evidence for complete service dispatch.
No browser/render, hosted or production verification. Both RemoteServer and
Service must be updated before claiming attribution on a host; an old Service
may ignore the additive actor field. Existing historical rows are untouched.

## Completed local batch: Web AI endpoint credential boundary

Confirmed and reproduced the Web editor changing an endpoint while retaining
the service credential. The existing locked settings mutation now rejects the
whole patch if a changed effective destination can reuse an existing key.
Comparison includes full paths, summary-to-embedding fallback, legacy title
casing/defaults and title-provider changes; disabled providers and env URL
overrides do not bypass the guard. Relevant stored values/markers, env keys,
runtime sidecars and markerless Keychain metadata participate. Unknown secret
state fails closed. Keychain lookup requests attributes with interaction disabled,
not secret data. Credential-free endpoint editing and unrelated edits remain.

The structured IPC refusal maps to HTTP 409, preserving the draft and explicitly
saying nothing was saved. Verification includes the real capability-protected Web
client/socket/dispatcher and unchanged file bytes, independent HTTP error mapping,
and executable page-JS correction/retry behavior. RED: two service assertions plus
one UI regression. GREEN: 26 service, 24 HTTP/client/UI-route, 181 JS tests; lint and
invariant gates passed. Evidence: `/tmp/engram-leader-web-endpoint-20261023/`.
No real Keychain, outbound AI request, rendered browser, all-target suite, hosted
or production acceptance. This is not DNS/redirect pinning or isolation from a
trusted local settings writer.

Credential-throttle adjudication: current source and 47 fresh auth session/route
tests confirm the shared five-attempt window and its availability limitation.
The accepted [identity-auth design](../superpowers/specs/2026-10-08-web-tailscale-identity-auth-design.md)
explicitly parks per-client credential throttling. There is no trusted client
address contract in the credential route; arbitrary forwarded/identity headers
must not become throttle keys. Preserve this design item until client/proxy
provenance and a global guessing budget are defined. No auth-code change.
Receipt: `auth-adjudication.{log,xcresult}` in the same evidence directory.
The following batch completed the mounted-view transcript investigation.

## Completed local batch: transcript paging ownership

Mounted SessionDetailView tests held non-cooperative parsing/index completion
across A-B and A-B-A switches. Existing initial success/error and index-apply
cancellation guards passed. Old page/all/copy cleanup, however, cleared a new
session's busy state and let a duplicate action cancel its valid page. Two actions
before the task started also both entered. The minimal runtime change sets busy
before scheduling, assigns a fresh load token, invalidates it on switch/disappear,
and lets only its owner release busy/task state.

The DEBUG-only instance hooks exercise actual mounted State and actions with
fake transcripts, mock service and captured clipboard output. Snapshot-observer
timeouts were diagnosed and replaced with on-demand mounted State reads; retain
those failures in the evidence directory. Final five mounted tests passed five
iterations (25 executions). Removing both runtime protections with that final
harness failed 17 expected assertions; restoring them passed all 72 selected
transcript tests. Lint/invariants/project-drift/diff checks passed.
Release arm64/x86_64 build passed; binary inspection confirms test hooks only
in the Debug dylib, not the Release executable (`build-receipt.json`). Evidence:
`/tmp/engram-leader-transcript-20261023/`; details in CHANGELOG. No hosted or
production acceptance, exhaustive UI stress or real-parser/clipboard end-to-end
claim. `session-detail-id-3` closes locally for this reproduced/verified scope.
The following batch completed `r11-dropped-2` transport-error mapping verification.

## Completed local batch: legacy request-body error verification

Replaced the source-string check with four production-router behavioral tests.
Injected streams prove partial read errors return 503, accumulated oversize bodies
return 413, and failed bundle uploads neither create blobs nor replace existing
ciphertext. Exact-limit uploads and MCP initialize pass. MCP error envelopes
separate transport failure, size failure and malformed complete JSON; auth/Origin
refusals do not read the stream. The router, body collector and storage are real;
only the inbound transport stream is controlled, with temporary stores/fake keys.

Temporarily restoring the historical catch-all mapping failed five expected
assertions in the two error tests. Restoring unchanged production source passed
all 28 server tests. Lint and invariant/module/convention gates passed. Evidence:
`/tmp/engram-leader-body-20261023/` (`negative-control`, `green-final`, lint and
invariant logs/xcresults). No hosted/production or real socket-disconnect claim.
`r11-dropped-2` closes locally. The following batch measured and optimized a
Cursor legacy observation hotspot; quiet-host CPU/RSS acceptance remains
separately authorized.

## Measured local batch: Cursor observation digest formatting

An isolated Release XCTest used 64/512/2048 synthetic workspaces, pages of 1/64,
and three rounds of 50 pages. Process CPU excludes fixture setup. A five-second
sample during a 2048-workspace/64-item loop attributed 699/3738 stacks to digest
`String(format:)` calls. The shared SHA-256 function now converts the digest with
a fixed hex lookup table, retaining its exact lowercase 64-byte representation.
No directory cache, filesystem check, observer cadence or capture authority changed.

The 2048-workspace/64-item median fell 6.824 -> 5.245 CPU ms/page (23.1%); the
64-workspace/64-item case fell 2.982 -> 1.536 (48.5%). At one item per page the
2048 case improved only 3.1%, preserving enumeration/stat work as a residual.
The optimized sample has zero formatting stacks among 3764 samples. These are
synthetic path measurements, not whole Collector CPU/RSS or production acceptance.
The 512-workspace baseline varied 3.49-6.37 ms; do not generalize its larger delta.
Temporary profile instrumentation was removed; its exact method, command, input
counts, logs, samples, binary hashes and comparison JSON remain under
`/tmp/engram-leader-cursor-perf-20261023/`. Correctness receipt is in CHANGELOG.
The following batch defined and implemented alias audit storage/transaction/
retention semantics with failure-path acceptance. Host cutover
and the comparable 30-minute resource window remain external acceptance work.

## Completed local batch: transactional Web alias audit

The [alias design](../superpowers/specs/2026-10-23-web-alias-audit-design.md)
adds a dedicated diagnostic table, not project migration records. HTTP supplies
the editor session actor after browser-key validation; additive DTOs and the real
capability dispatcher forward it. Missing actor uses web-editor. A changed exact
pair records action, actor, published identities and UTC time in the mutation's
transaction. Repeated/no-op/refused writes create no rows. Audit insert or retention
failure rolls back the business mutation. The latest 10,000 transitions are kept
by insertion ID; raw paths and request bodies are not retained in this history.

RED: Service 20 failures including four missing-table errors; HTTP four missing
actor assertions. GREEN: 13 Service tests (including real HTTP/socket/dispatcher/SQL
and capability-socket attribution), 46 HTTP/client/auth/project tests, 20 migration
tests. Insertion/pruning triggers prove rollback; 10,000 seeded rows prove retention
across clock rollback; old/repeated migration preserves aliases/history. Lint and
invariants passed. Receipt: `/tmp/engram-leader-alias-audit-20261023/`.
No all-target, hosted, rendered-browser or production upgrade claim. Upgrade Service
before RemoteServer: old Service rejects actor on aliases; old RemoteServer with
new Service works with web-editor attribution. Native alias and permanent audit
history are explicitly outside this log. Credential throttle remains the accepted
provenance/design residual. The following batch adjudicated the foreground UI
test-harness failure policy (`mcp-hermetic-1`), before product search.

## UI harness failure-policy adjudication

Current `TestLaunchConfig.configure` installs isolated HOME/fixed-home, settings,
secret paths and test mode before any fallible setup. All 27 configure call sites
have `continueAfterFailure = false` in the test or its setup. The old claim that
the suite still lacks fail-fast policy is stale; the helper uses XCTFail + return,
so a caller's XCTest failure policy remains part of the behavioral contract.

A temporary injected missing-fixture test used a distinct App bundle identifier
and no actual app.launch statement. Xcode built it, but the UI runner failed to
initialize with LocalAuthentication Code=-4, "System authentication is running."
The test body never ran. This proves neither stop-before-launch nor continuation;
the negative control and normal foreground smoke were not run. No authentication
process was changed and no immediate retry was attempted. All four backed-up files
were checked against HEAD and restored byte-for-byte; the worktree was then clean.

After restoration, both existing `MCPActivationOnboardingTests` source-policy
regressions passed in isolated fixed homes. They verify source ordering/wiring,
not foreground behavior. Evidence: `/tmp/engram-leader-ui-harness-20261023/`,
`failure-stop.{log,xcresult}`, `source-policy.{log,xcresult}` and original backups.
The residual stays open only for foreground acceptance when the runner can start.
The following product-search batch continued without changing this policy.

## Completed local batch: human keyword ranking consistency

Lifecycle 3.4's missing-BM25/CJK/facet premise was stale: Service already used
FTS rank, windowed highlights and CJK trigram routing; SearchPage already had
source/project/time/origin filters. The actual reproducible gaps were that both
readers ranked by only the first term, and App offline search routed all CJK to
zero-rank LIKE. A short-first query such as AI needle discarded needle relevance.

The [ranking contract](../superpowers/specs/2026-10-23-keyword-ranking-design.md)
keeps session-level AND and sums each term's existing best-row rank in canonical
token order. Time descending and ID ascending break ties before the result limit
and final projection. App search/searchWithSnippets now use Service's scalar-count
trigram/LIKE routing. No schema/index rebuild, UI layout, embedding or new facet.
Service's short-term candidate cap remains an explicit recall limitation; native
MCP's separate ranking policy is outside this human-search contract.

After fixing an initial missing-await test compile error, behavioral RED produced
72 expected ranking assertions across three real App/Service shared-fixture tests.
GREEN: 163 App data/search tests and 63 Service search/semantic/insight/Web tests,
zero failures. Six term permutations, cross-message matching, rank-before-limit,
stable ties, Latin/Chinese/Japanese/Korean, highlights, both Service FTS layouts,
filters, busy handling and semantic fallback passed. Lint/invariants passed.
Receipt: `/tmp/engram-leader-keyword-ranking-20261023/`. No all-target, rendered UI,
hosted, production-corpus relevance/latency or deployment acceptance. Lifecycle 3.4
stays partial: title/quality/recency weighting and value/lifecycle facets need
separate contracts. Next product batch: adjudicate existing value-score/band UI
and access/outcome signals before selecting a measured visibility improvement.

## Collector / cutover residuals (all named rows routed)

| Item | Current disposition / next action |
|---|---|
| `cutover-feed-stalled-1` | Recovery implemented and deployment recorded; reboot/real-host recovery remains unverified this session. Do not label the October 2 outage current. |
| `cutover-hq-local-gap-1` | HQ collector/canary/central-index/Web acceptance remains operational work. Runbook R2–R10 includes credential/root steps and host mutations. |
| `codex-resume-window-1` | `CodexAdapter(modifiedSince:)` and repros exist. Old-host backlog recovery/deployment needs fresh host evidence; never restart the old stack merely to close this row. |
| `collector-stuck-dirty-locators-1` | Vanished never-captured half fixed. Present-but-uncapturable Copilot/Kimi members remain an unverified cause, not a proven parser defect. |
| `collector-blocked-root-backoff-1` | Closed locally; behavioral/runtime evidence above. Deployment and real-host CPU acceptance remain separate. |
| `collector-start-cost-1` | Full startup walk cost remains unmeasured; startup must not be confused with steady-state CPU. |
| `collector-epoch-change-scope-1` | Root-local suspension implemented in #481; Daily deployment recorded October 18. Retain real-host trigger verification separately. |
| `collector-epoch-producer-1` | Same-instance epoch rotation implemented in #481; manual inventory wipe still loses identity by accepted design. Real revision-bump recovery remains unexercised. |
| `collector-epoch-authority-file-1` | Existing owner decision is runbook-only: update `initialEpoch` before next restart. Revisit before first real approval; no silent authority relaxation. |
| `collector-revision-bump-staged-1` | Drain pending publications before revision bump. Old-revision staged publication handling remains a design/operational limitation. |
| `collector-publication-cost-1` | Shared privacy proof and `memchr` landed. Remaining byte scans/CAS reads are low-priority measured-performance candidates. |
| `collector-idle-turn-cost-1` | Frontier/ancestor/vanished-locator fixes landed. Local digest formatting optimization measured above; legacy enumeration/stat and modern-peer discovery costs plus comparable quiet-host receipt remain. |
| `collector-settings-write-flake-1` | Closed locally; hosted recurrence not claimed. |
| `collector-test-fixture-leak-1` | Closed locally; no historical temp cleanup. |
| `cutover-install-tooling-1` | P3 scripts/templates exist (#454); old claim of no tooling is stale. First real-host install/upgrade/rollback remains unverified. |
| `cutover-web-editor-hardening-1` | Project actor, alias audit and endpoint credential batches above; credential throttle remains an accepted design residual. Tailscale mode does not prove credential-mode behavior safe. |
| `cutover-role-surface-1` | First batch passed locally; no deployment claim. |

Additional cutover gates: configure and verify `webReaderURL` on each intended
host; deploy/probe current HQ epoch CLI/Service together when authorized;
obtain per-source capture → dual receipt → HQ index → Web proof for the 19
sources / 17 collector root formats; retain D3 cache/PB exceptions; decide M1
collector inclusion after fresh source evidence. Local synthetic success does
not satisfy these host receipts. Daily's last comparable recorded CPU window
was 5.847% (October 18), while October 19's 34.6% active-workload window is not
a comparable quiet-state receipt. Neither is a current runtime measurement.

## Other residuals (all nonterminal families routed)

| Canonical family | Remaining scope |
|---|---|
| Live ingest SLA | Unique natural session through HQ publish and App/MCP search, including post-reboot path, before claiming 16-minute SLA. |
| Live enable / token / helper / first publish | Restart-on-first-enable contract, ad-hoc helper credentials, independent helper lifetime, and initial-scan gating are recorded operational constraints; refresh on the intended host. |
| Live launchd / boot / hardening | Old jobs were installed; reboot without console login, injected degraded sentinel, duplicate start, and executed rollback were not proven. Cutover may retire these jobs; decide applicability before testing. |
| `live-ingest-settings-repro-1` | Already closed locally; not a new implementation task. |
| Live hard-delete retract / manifest GC retry | Conditional: only promote if a periodic hard-delete producer or storage-hygiene need appears. |
| `live-session-scan-timeout-1` | Data path fixed historically; unlocked menu rendering acceptance remains. |
| `startup-initial-scan-latency-1` | Historical Daily local-Service startup symptom; check whether that retired role still applies before optimizing or probing it. |
| Project-move stale-break claim | TS reference-only crash recovery needs an ownership-safe delete design; do not weaken fail-closed locking. |
| Round-12 `mcp-hermetic-1` | Source policy present and two source tests passed; foreground failure-injection acceptance blocked before test execution by system authentication. Details above; no new product defect proven. |
| Round-12 `live-export-terminal-*` | Warp cleanup and Terminal/iTerm/Ghostty cancellation need real terminal integration testing. |
| Round-12 `workitem-localtime-1` / `xcodeproj-untracked-*` | Fixes are on the verified remote-main baseline (`00bb5809`); “local, not pushed” is stale. Tests are not rerun by a Git history check. |
| Round-12 `r11-dropped-2` | Closed locally: production-router injected body failures, limits, auth ordering and storage non-mutation passed; historical-mapping negative control failed five expected assertions. Details above; real transport-disconnect/host verification remains unclaimed. |
| `ALIAS-P2` | Conditional same-basename ghost removal; only reopen with a repro. OPS-ALIAS-001 is closed, not authorization to rewrite production aliases. |
| Blind-audit A1–D1 | Old stacked-PR table is implementation history, not an open-PR queue. Only a newly reproduced residual is promoted; no current open implementation PR is hidden there. |
| `ARCH-001` | A/B/C/D shipped. Full CoreRead pool/DTO migration remains structural investment. |
| `R6` | Writer-gate availability redesign deferred; current long FS+patch gate is an integrity choice. |
| Accepted security residuals | SEC-M4/M5/I1/I2/L4 and release/TS-only notes remain explicit product/threat-model decisions, not automatic remediation. |
| Archive discovery | ARCHIVE-DISCOVERY-001 needs durable restart/event-loss design; no safe prefix-limit patch. Collector inventory does not automatically fix the legacy archive coordinator. |
| Additional archive exporters | Each virtual/composite/database-backed source needs canonical source-set and delete-original/replay-equivalence proof. |
| Remote archive GC/erasure | Separate design, backup/restore and explicit destructive-operation authorization; API stays immutable. |
| UI restyle / launcher flake | October 19 deferred deeper Home/Search/Timeline/Activity restyle. Launcher full-suite timing failure was observed and passed alone; reproduce before changing it. |

## Product roadmap reconciliation

The historical table had 12 decision rows. One is already implemented
(`ai_audit_log` body redaction); four are partly implemented (human search, value-band UI,
plugin integration and Grok/Pi/provider work). Lifecycle 3.2 was parked in its source plan but
missing from the table; it is now explicitly routed. The resulting table has
13 rows: **12 open or conditional product families, 1 implemented family**.
These are not 12 ready-to-code defects.

1. Value score evolution, measured thresholds, and outcome/access signals.
2. Human search beyond the all-term/CJK ranking batch and existing basic filters:
   title/quality/recency weighting and value/lifecycle facets remain.
3. Tool-result normalization plus structured summary job.
4. Value band UI now implemented locally in cards and Sessions table cells;
   `value_override` remains open. Reused existing <=35 / >=60 bands and shared
   score function; 31 App/model/read/render tests plus two score tests passed.
   Four bilingual light/dark component renders inspected; no full-page interaction
   or production claim. Receipt: `/tmp/engram-leader-value-bands-20261023/`.
5. Embedding-cosine insight supersession.
6. Opt-in automatic insight extraction.
7. Native sqlite-vec: conditional only on measured bottleneck and explicit
   architecture decision; current repo instructions prohibit introducing it.
8. Corpus/rule mining: intentionally removed, not accidentally unfinished.
9. Plugin Stop/SessionEnd insight capture and distribution channels:
   SessionStart hook already exists; no release/channel publication authorized.
10. Remaining provider taxonomy/capability choices: Grok/Pi adapters already
    register in `SessionAdapterFactory`; do not rebuild them from archive.
11. Sources/Settings navigation consolidation.
12. Lifecycle-state/shadow-archive model (not Archive V2 source reclamation).

`ServiceAIAuditRecorder.record` already writes via `ServiceWriterGate`, gates
bodies with `logBodies`, redacts before truncating, and has
`ServiceAIAuditRecordTests.testLogBodiesStoresRedactedTruncatedTextWhileWebKeepsFlagsOnly`.
This closes the old “no Swift writer/body-redaction” assumption, not a broad
security audit. Historical retention-cadence assumptions must be reconsidered
now that a live writer exists.

## Dependency maintenance lane

Live open PRs on October 23: #490 lint-staged 17.6.0, #491 pixelmatch 8.0.0,
#492 openai 7.38.0, #493 @types/node 26.6.5, #494 tsx 4.23.15, #495 CodeQL
Actions group. These are PR titles, not independently approved upgrade
recommendations. Inspect exact diffs and required checks before selecting a
batch; treat pixelmatch's major version and immutable Actions pins separately.
No dependency bump is bundled into the MCP fix.

## Verification record

- Read-only baseline: Git status/history/worktrees, live main SHA, issue/PR
  inventory and main CI conclusions.
- Real-binary historical gate rechecked live:
  [39098816343](https://github.com/bbingz/engram/actions/runs/39098816343),
  success at `10f5ab21f876b73b768a4a940165d41cc0dfc3bd`; workflow and runner
  exist on the baseline. This closes stale “no recorded gate” prose, not
  current-branch or real-host acceptance.
- Current branch: 215 MCP executable tests and 94 service tests passed
  (85 collector runtime, 1 publication, 8 AI audit). The MCP RED run first
  failed eight expected assertions. `npm run lint` passed with 1 existing
  warning / 40 infos; invariant-ledger/module-boundary/Swift-convention checks
  and 72 local document links passed. Commands/logs are in `CHANGELOG.md`.
  Other source-existence and historical receipts are not freshly run tests.
- No production state readback, host mutation, release, UI rendering, or full
  all-target regression has been performed for this reconciliation.

## Plan-by-plan routing appendix

Each implementation plan is listed once. “Exists” is source/navigation evidence,
not proof that every historical acceptance criterion was rerun.

| Plan | Current route |
|---|---|
| [2026-06-04-followup-remediation](../superpowers/plans/2026-06-04-followup-remediation.md) | Historical remediation; residuals use current followups, not checkbox count. |
| [2026-06-04-fts-table-swap-rebuild](../superpowers/plans/2026-06-04-fts-table-swap-rebuild.md) | Explicit completed header (#48); preserve current FTS swap invariants. |
| [2026-06-06-claude-qoder-dir-reconcile](../superpowers/plans/2026-06-06-claude-qoder-dir-reconcile.md) | Explicit completed header; current project-move tests are the verifier. |
| [2026-06-06-project-move-gemini-iflow](../superpowers/plans/2026-06-06-project-move-gemini-iflow.md) | Explicit completed header (#65); not an open implementation batch. |
| [2026-06-10-audit-complete-remediation](../superpowers/plans/2026-06-10-audit-complete-remediation.md) | Historical audit campaign; current residuals are in followups. |
| [2026-06-27-session-implementation-timeline](../superpowers/plans/2026-06-27-session-implementation-timeline.md) | Extractor, persistence and Timeline implementation exist; unchecked procedural steps are stale. |
| [2026-07-10-wave7-43-item-remediation](../superpowers/plans/2026-07-10-wave7-43-item-remediation.md) | Terminal Wave 8 closeout in followups; do not reopen 43 historical findings. |
| [2026-07-10-wave7-engineering-zero-closeout](../superpowers/plans/2026-07-10-wave7-engineering-zero-closeout.md) | Terminal Wave 8 closeout; zero was a dated campaign count, not current project count. |
| [2026-07-11-exact-source-dual-replica-archive](../superpowers/plans/2026-07-11-exact-source-dual-replica-archive.md) | Implemented; conditional discovery/exporter/remote-GC residuals remain. |
| [2026-07-12-archive-remote-telemetry](../superpowers/plans/2026-07-12-archive-remote-telemetry.md) | ArchiveRemoteTelemetryStore and tests exist; historical implementation, not new queue. |
| [2026-07-12-archive-settings-sync-status-localization](../superpowers/plans/2026-07-12-archive-settings-sync-status-localization.md) | ArchiveSettingsSection and service status exist; acceptance is historical. |
| [2026-07-12-archive-sync-observability](../superpowers/plans/2026-07-12-archive-sync-observability.md) | ArchiveV2ServiceCoordinator/status implementation exists; no new task from unchecked steps. |
| [2026-07-12-archive-v2-automatic-reclamation](../superpowers/plans/2026-07-12-archive-v2-automatic-reclamation.md) | ArchiveReclamationCoordinator and tests exist; never infer authorization to enable or delete. |
| [2026-07-12-archive-v2-production-deployment](../superpowers/plans/2026-07-12-archive-v2-production-deployment.md) | Historical operational closeout; fresh production mutation requires authorization. |
| [2026-07-13-archive-v2-backlog-drain](../superpowers/plans/2026-07-13-archive-v2-backlog-drain.md) | ArchiveV2BacklogDrainer and tests exist; discovery limitation remains separate. |
| [2026-07-13-archive-v2-drain-fairness-remediation](../superpowers/plans/2026-07-13-archive-v2-drain-fairness-remediation.md) | Historical replication/coordinator fix; no claim of current host drain health. |
| [2026-07-13-claude-profile-registry](../superpowers/plans/2026-07-13-claude-profile-registry.md) | ClaudeCodeProfileResolver/Service and tests exist; not a new feature. |
| [2026-08-24-hq-live-session-ingest](../superpowers/plans/2026-08-24-hq-live-session-ingest.md) | Implemented historically; SLA/boot and retirement applicability remain operational. |
| [2026-09-05-collector-server-web](../superpowers/plans/2026-09-05-collector-server-web.md) | Implemented core with cutover/performance residuals listed above; W4.1/W4.5 closed by owner. |
| [2026-09-13-web-native-parity](../superpowers/plans/2026-09-13-web-native-parity.md) | Web read/write surfaces implemented; current actor/security and real-host acceptance residuals above. |
| [2026-09-14-hq-web-residuals](../superpowers/plans/2026-09-14-hq-web-residuals.md) | Explicit landed header (#446); do not rerun six historical fixes. |

### Specification inventory

All 24 baseline specifications were inventoried; this loop added the Web
project-audit addendum, alias-audit and keyword-ranking designs below. Paired specs use the plan route above;
a Draft/Accepted label alone neither opens nor closes an implementation task.

| Specification | Routing |
|---|---|
| [2026-10-23-keyword-ranking-design](../superpowers/specs/2026-10-23-keyword-ranking-design.md) | Local all-term ranking/offline CJK consistency implemented; 226 focused tests passed after behavioral RED. Broader search weighting/facets remain product decisions. |
| [2026-04-23-swift-single-stack-design](../superpowers/specs/2026-04-23-swift-single-stack-design.md) | Swift-only product runtime already authoritative; never revive Node product entrypoints. |
| [2026-06-01-today-workbench-design](../superpowers/specs/2026-06-01-today-workbench-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-06-04-fts-table-swap-rebuild-design](../superpowers/specs/2026-06-04-fts-table-swap-rebuild-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-06-06-claude-qoder-dir-reconcile-design](../superpowers/specs/2026-06-06-claude-qoder-dir-reconcile-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-10-wave7-43-item-remediation-design](../superpowers/specs/2026-07-10-wave7-43-item-remediation-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-11-exact-source-dual-replica-archive-design](../superpowers/specs/2026-07-11-exact-source-dual-replica-archive-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-12-archive-remote-telemetry-design](../superpowers/specs/2026-07-12-archive-remote-telemetry-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-12-archive-settings-sync-status-localization-design](../superpowers/specs/2026-07-12-archive-settings-sync-status-localization-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-12-archive-sync-observability-design](../superpowers/specs/2026-07-12-archive-sync-observability-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-12-archive-v2-automatic-reclamation-design](../superpowers/specs/2026-07-12-archive-v2-automatic-reclamation-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-13-archive-v2-backlog-drain-design](../superpowers/specs/2026-07-13-archive-v2-backlog-drain-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-13-archive-v2-drain-fairness-remediation-design](../superpowers/specs/2026-07-13-archive-v2-drain-fairness-remediation-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-13-claude-profile-registry-design](../superpowers/specs/2026-07-13-claude-profile-registry-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-07-16-typescript-7-upgrade-design](../superpowers/specs/2026-07-16-typescript-7-upgrade-design.md) | Explicit implemented/merged header; no dependency reimplementation. |
| [2026-08-24-hq-live-session-ingest-design](../superpowers/specs/2026-08-24-hq-live-session-ingest-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-09-05-collector-server-web-design](../superpowers/specs/2026-09-05-collector-server-web-design.md) | Paired plan/current follow-ups; historical status is not a fresh acceptance receipt. |
| [2026-10-02-collector-replay-loss-design](../superpowers/specs/2026-10-02-collector-replay-loss-design.md) | Draft header is stale: #447/#448 recovery fixes exist; real-host reboot proof remains separate. |
| [2026-10-02-collector-volume-identity-design](../superpowers/specs/2026-10-02-collector-volume-identity-design.md) | Draft header is stale: #447/#448 recovery fixes exist; real-host reboot proof remains separate. |
| [2026-10-02-hq-local-collector-cutover-design](../superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md) | Active host cutover R1-R10 and D1-D12; engineering/ops boundaries above. |
| [2026-10-08-web-tailscale-identity-auth-design](../superpowers/specs/2026-10-08-web-tailscale-identity-auth-design.md) | Phase 1 implemented; project actor propagation and alias storage verified locally; host acceptance remains separate. |
| [2026-10-23-web-project-audit-actor-addendum](../superpowers/specs/2026-10-23-web-project-audit-actor-addendum.md) | Added by this loop; current implementation scope, compatibility and acceptance contract. |
| [2026-10-23-web-alias-audit-design](../superpowers/specs/2026-10-23-web-alias-audit-design.md) | Added by this loop; implemented bounded transactional Web alias history, attribution and additive migration. |
| [2026-10-17-collector-native-epoch-reconcile-design](../superpowers/specs/2026-10-17-collector-native-epoch-reconcile-design.md) | Source implemented; epoch/operator/real-host residuals above. |
| [2026-10-18-collector-epoch-rotation-and-root-scope-design](../superpowers/specs/2026-10-18-collector-epoch-rotation-and-root-scope-design.md) | Source implemented; epoch/operator/real-host residuals above. |
| [2026-10-18-d7-legacy-local-origin-purge-design](../superpowers/specs/2026-10-18-d7-legacy-local-origin-purge-design.md) | Source implemented; epoch/operator/real-host residuals above. |
| [2026-10-18-hq-collector-epoch-approval-design](../superpowers/specs/2026-10-18-hq-collector-epoch-approval-design.md) | Source implemented; epoch/operator/real-host residuals above. |

### Root design inventory

Root designs are retained reference specifications. Paths below exist on this
baseline and establish navigation only; full criterion-by-criterion re-audit
remains UNVERIFIED unless a specific result appears above. Product choices
route to the reconciled roadmap, implementation defects to failing repros.

| Design | Existing source/test pointer |
|---|---|
| [adapter-format-drift-design-2026-07](../adapter-format-drift-design-2026-07.md) | `macos/Shared/EngramCore/Indexing/SessionTier.swift`; `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift` |
| [archive-list-index-robustness-design](../archive-list-index-robustness-design.md) | `macos/EngramRemoteServer/Core/ArchiveStore.swift`; `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift` |
| [archive-windowed-read-design](../archive-windowed-read-design.md) | `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`; `macos/EngramRemoteServer/Core/ArchiveStore.swift` |
| [build-provenance-perf-design-2026-07](../build-provenance-perf-design-2026-07.md) | `macos/Engram/App.swift`; `tests/scripts/build-release-script.test.ts` |
| [claude-workflow-subagents-design-2026-07](../claude-workflow-subagents-design-2026-07.md) | `macos/Shared/EngramCore/AI/SessionSemanticSearchPolicy.swift`; `macos/EngramCoreTests/Adapters/ClaudeCodeMultiRootAdapterTests.swift` |
| [codex-native-parentage-design-2026-07](../codex-native-parentage-design-2026-07.md) | `macos/EngramCoreWrite/Indexing/StartupBackfills.swift`; `macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift` |
| [cursor-cwd-ownership-design](../cursor-cwd-ownership-design.md) | `macos/Shared/EngramCore/Adapters/Sources/CursorAdapter.swift` |
| [diagnostic-bundle-design-2026-07](../diagnostic-bundle-design-2026-07.md) | `macos/Engram/Views/Settings/AboutSettingsSection.swift`; `macos/Engram/Core/Database.swift` |
| [embedding-guardrails-design-2026-07](../embedding-guardrails-design-2026-07.md) | `macos/Shared/EngramCore/AI/EmbeddingClient.swift`; `macos/Shared/EngramCore/AI/EmbeddingSettings.swift` |
| [file-index-state-orphan-prune-design-2026-07](../file-index-state-orphan-prune-design-2026-07.md) | `macos/EngramCoreTests/FileIndexStateOrphanPruneTests.swift` |
| [human-driven-sessions-design-2026-06](../human-driven-sessions-design-2026-06.md) | `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift`; `macos/Shared/EngramCore/Indexing/InstructionExtractor.swift` |
| [insight-supersede-filter-design-2026-07](../insight-supersede-filter-design-2026-07.md) | `macos/EngramService/Core/EngramServiceCommandHandler.swift`; `macos/Shared/Service/EngramCLIContextCommand.swift` |
| [mcp-2026-07-28-dual-era-design](../mcp-2026-07-28-dual-era-design.md) | `macos/EngramMCP/Core/MCPStdioServer.swift`; `macos/EngramMCPTests/EngramMCPExecutableTests.swift` |
| [mcp-activation-onboarding-design-2026-07](../mcp-activation-onboarding-design-2026-07.md) | `macos/Engram/App.swift`; `macos/Shared/Service/EngramCLIContextCommand.swift` |
| [mcp-cost-honesty-design-2026-07](../mcp-cost-honesty-design-2026-07.md) | `macos/EngramMCP/Core/MCPInsightsTool.swift`; `macos/EngramCoreWrite/Indexing/SessionSnapshotWriter.swift` |
| [mcp-protocol-alignment-design](../mcp-protocol-alignment-design.md) | `macos/EngramMCP/Core/MCPStdioServer.swift`; `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift` |
| [mcp-semantic-search-design-2026-07](../mcp-semantic-search-design-2026-07.md) | Current roadmap / semantic-memory residuals; review source before promotion. |
| [p1-semantic-memory-design-2026-06](../p1-semantic-memory-design-2026-06.md) | Current roadmap / semantic-memory residuals; review source before promotion. |
| [publish-readiness-design-2026-07](../publish-readiness-design-2026-07.md) | `macos/EngramTests/AppSearchServiceCutoverScanTests.swift`; `macos/EngramService/Core/IndexingSchedulePolicy.swift` |
| [remote-mcp-2026-07-28-design](../remote-mcp-2026-07-28-design.md) | `macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift`; `macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift` |
| [resume-suppression-subagents-design-2026-07](../resume-suppression-subagents-design-2026-07.md) | `macos/EngramService/Core/EngramServiceReadProvider.swift`; `macos/Shared/Service/EngramServiceModels.swift` |
| [service-resilience-design-2026-07](../service-resilience-design-2026-07.md) | `macos/Engram/AppNotifications.swift`; `tests/fixtures/mcp-golden/stats.source.json` |
| [source-health-predicate-design-2026-07](../source-health-predicate-design-2026-07.md) | `macos/EngramService/Core/EngramServiceReadProvider.swift`; `macos/Engram/Views/Pages/SourcePulseView.swift` |
| [tail-parse-design-2026-07](../tail-parse-design-2026-07.md) | `macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift`; `macos/EngramCoreWrite/Database/EngramMigrations.swift` |
| [transcript-find-rendering-design-2026-07](../transcript-find-rendering-design-2026-07.md) | `macos/Engram/Views/ContentSegmentViews.swift`; `macos/EngramTests/TranscriptLabelAndCopyTests.swift` |
| [transcript-paging-timing-design-2026-07](../transcript-paging-timing-design-2026-07.md) | `macos/EngramCoreTests/AdapterWindowedReadTests.swift`; `macos/EngramTests/MessageParserTests.swift` |
| [uiux-polish-a11y-design-2026-07](../uiux-polish-a11y-design-2026-07.md) | `scripts/invariant-gates.json`; `macos/EngramTests/PopoverUsageSectionTests.swift` |

Additional retained planning surfaces: `docs/engram-lifecycle-upgrade-plan.md`,
`docs/competitive-relaunch-2026-06.md`, `docs/competitive-mirror-2026-07.md`,
`docs/backlog-audit-2026-05-24.md`,
`docs/reviews/2026-08-12-stewardship-queue.md`, and
`docs/reviews/2026-09-07-collector-source-retirement-checklist.md`. The old
stewardship queue explicitly terminated on August 16; its scheduler is not
silently re-enabled by this new conversation goal. Competitive research is
historical, not a verified October market comparison.
