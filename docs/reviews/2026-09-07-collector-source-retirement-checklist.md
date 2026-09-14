# Collector source-retirement checklist

Owner acceptance handoff (2026-09-13): the owner requested delivery now and
iteration after feedback. Current deployed candidate is available for owner
acceptance; remaining performance work is explicitly deferred from this handoff,
not marked PASS. Existing resource7119 and append58055 jobs remain bounded and
running, with39 successful append observations so far. Autonomous development
is paused for feedback. On resume inspect their actual terminal evidence before
starting any new work. See CHANGELOG.md and web-claim-closeout-resume.json.

Current scheduling update (2026-09-13): Daily455 now runs the capture-schedule
package at10000ms periodic cadence with native mailbox checks<=1000ms. Parent
verified17 focused tests,7 packaged flows, live binary/framework, and paired
rollback assets. Local414-row CPU at10s is0.517%; this is not Daily acceptance.
Observer7119 waits fixed initial revisions then measures1800s; wrapper58055
waits fixedCodex86 then runs the unchanged60-slot latency workload. Both current
results are pending. Previous92844 CPUFAIL and appendPASS remain historical.
See collector-capture-schedule-daily-verified.json, capture-schedule-local-comparison.json
and CHANGELOG.md. Missing Mimo/Cline originals do not block delivery.

Current resource/deferral update (2026-09-13): observer49875 completed with
61 samples over1800.016s on unchanged Daily92844: CPU13.178%FAIL and sampled
RSS55.734MiBPASS. Parent recomputed metrics and checked loaded framework/settings;
see idle-batch-steady-terminal-49875.json. The new unavailable-deferral batch
passes10 focused tests and7 packaged flows. Local414-missing-row CPU falls
4.275%->3.375% with identical settings; it remains local because this does not
prove the Daily2% target. Existing deployed-package append/Web proof remains unchanged.
See defer-batch-parent-review.json and CHANGELOG.md. Earlier checkpoints follow.

Current idle-batch update (2026-09-13): Daily92844 replaces82327 after16
focused tests, seven current packaged flows and controlled local comparisons.
The full prior Daily window measured CPU17.769% FAIL / RSS48.922MiB PASS.
Current observer49875 waits for fixed initial revisions before1800s CPU/RSS.
The unchanged60-slot live append workload completed on92844:60/60success,
p95 33.056s, max63.278s, strictPASS, exact62messages and dual126976-byte proof.
Parent rechecked source hash and unchanged live role/framework guards;
append-idle-batch-terminal.json records terminal0 for wrapper36793. Current
latency acceptance passes; resource acceptance still waits fixedClaude80.
No zero-HTTP-error gate was added and earlier failed trials remain immutable.
Mimo/Cline historical originals remain nonblocking and Antigravity deferred.
See collector-idle-batch-daily-verified.json, idle-batch-local-comparison.json,
idle-batch-acceptance-adjudication.json, append-idle-batch-monitor.json and
CHANGELOG.md. All earlier current/running/not-run statements below are dated
historical checkpoints; they do not replace their newer named evidence.

Current Collector retry update (2026-09-13): Daily82327 adds the empty-Kimi
guard after7 targeted tests and4 actual binary flows, on top of the unavailable
source fix. The same six zero-byte locators retried1 time each over124.268s,
versus20 each over54.206s before; ACK0/no capture IDs preserved. New same-path
events wake immediately; budget/disk and already-captured retry semantics remain.
Settings unchanged and rollback retained. Resource observer1444 exited1 on the
verified replacement of PID76125, with zero steady samples. Observer93294 now
tracks fixed new-runtime initial targets, then1800s CPU<=2% / RSS<=150MiB.
Resource acceptance remains open. Bootstrap diagnostic RSS205488KiB is not a
steady result. Trial17628 stays terminal1: all60 exact-hit observations,
readiness p95/max48.611/84.575s,62messages and dual126976-byte proof; original
56success/1HTTP503/3TimeoutError, strictfalse/censoredp95null retained. No full
append rerun for this isolated Kimi change; actual Codex/Claude binary flows passed.
See kimi-empty-parent-review.json, collector-kimi-empty-daily-verified.json,
kimi-empty-live-cadence.json, collector-unavailable-observer-terminal.json,
collector-resource-kimi-empty-steady-observation.json and CHANGELOG.md.
Earlier running/no-deployment statements below are historical.

Current acceptance update (2026-09-13): trial10850 is terminal1, with all60
writes and exact search observations, final62messages and dual126976-byte proof.
All-observation readiness p95/max41.196/53.426s supports original numeric120s
target; strict verifier remains false (55success/5recoveredTimeoutError,
censoredp95null). Failures and original data remain unchanged. Fixedscan74
completed; observer3770 is terminal0 with61samples over1799.914s: CPU18.949%
fails2%, sampledRSS40.33MiB passes150MiB; bothreplicas+32ACKs. Cursor is implementing bounded missing
source retries with immediate same-path event wake; no new Collector deployed.
See append-unmapped-terminal-outcome.json, collector-steady-retry-diagnosis.json
and CHANGELOG.md. All earlier running/scan-wait statements below are historical.

Current indexing-delay update (2026-09-13): both mapped and unmapped
first-fill paths are repaired and live on HQ Service 84037. Existing owned
identity index avoids unrelated payload reads in the existence check and
empty/inconsistent-map deletion. Unknown layout fallback and all content/
embedding semantics remain. Parent verified the five-file diff, original-code
RED/new GREEN with identical bounds, 126 tests, two actual binary flows and
Release package/loaded framework hashes. Rollback package/plist retained.
Fresh same60-slot trial 10850 is running; full latency acceptance is still open.
Resource observer 32402 is terminal after its wait cap with no steady samples.
Read-only continuation 3770 keeps fixed original scan74 and the same gates;
Collector 62526 was not restarted. Current retirement recheck passes. Mimo/Cline originals remain nonblocking. Trial 82817 stays
terminal130 with7success/53cancelled, not accepted or overwritten.
See fts-unmapped-parent-review.json, fts-unmapped-hq-verified.json,
append-fts-unmapped-monitor.json and CHANGELOG.md. Historical updates follow.

Current live-verifier update (2026-09-12): first append trial81552 stopped with
25 successes/3 HTTP401/32 cancelled slots because the verifier omitted renewal
of the existing900s Web login session. Original failed evidence is retained;
fresh-login full30-message and dual94208-byte verification passed. Cursor
finished the verifier correction; parent offline review passed and new full
trial57437 is running with separate auth-aware evidence. Resource observer32402
is still live, now waiting for queued scan74 after scan72 completed. See
append-auth-expiry-outcome.json and append-auth-expiry-fresh-login-proof.json.

Current Web/claim update (2026-09-12): HQ Service62877 combines repeated ledger
aggregates after62 metadata tests and2 binary flows. The final20-round,
concurrency1 workload passes all260requests with no skipped steps; p95
list/search/detail/messages/overview145/646/48/77/1450ms. Normal desktop/mobile
first navigation succeeds (list591ms,50 rows visible1004ms,9overview pages4831ms).
Daily62526 fixes the acknowledged-history claim scan after217 tests/4 binary
flows; its60s restart window remains38.337% one-core CPU/125MiB sampled maximum.
The fixed-revision observer exited at901s before measurement, onlyClaude74/68
remaining. A new read-only observer (PID88835, tool session32402) now follows
the original fixed revision targets without restarting the Collector; it waits
up to7200s, then measures1800s. Scan frontier reached2093 completed/178 unfinished.
The corrected append verifier is now running (tool session81552), with baseline full transcript passed and the first two append searches at13.676/16.704s.
The remaining scheduled samples and final dual-byte proof are pending.
Current30-minute and small-append capture-lag gates remain open. Zero errors per20rounds is a separate
diagnostic signal, not an added spec gate. Older failed workloads stay below;
see overview-combined-parent-review.json, claim-predicate-parent-review.json,
web-read-acceptance-reconciliation.json and CHANGELOG.md.

Current list-index update (2026-09-12): HQ Service10184 now has the additive
idx_sessions_web_list_keys, with58 metadata/17 migration tests and2 binary flows
passed. ServiceCore queries are unchanged; native index and loaded CoreWrite are
verified. First navigation has list200 in532ms,50 visible sessions at1032ms and
all9 overview pages by4859ms. The full260-request window passed all20 lists,20
details,20 message reads and180 overview pages. Search failed2/20; overall
acceptance remains false. See web-read-latency-web-list-index-full-window.json. Daily58605
continues backfill; current steady-state and capture-to-search gates remain open.
See web-list-index-parent-review.json and CHANGELOG.md; older status follows.

Current Web UI update (2026-09-12): HQ Receiver63666 restores a reload after one
503 retry or displays a clear error after the second failure.70 JS tests,2 binary
flows and2 browser fault cases passed; normal first-navigation still returned503
twice. This fixes silent failure only. See web-restore-parent-review.json and
CHANGELOG.md. Backend read and steady-state resource acceptance remain open.

Current search update (2026-09-12): HQ Service22768 runs hit-driven initial MATCH
search.57 metadata regressions and two actual-binary flows passed. Loaded
ServiceCore is verified in search-hit-order-hq-verified.json. The new mixed workload
completed18 rounds, then round19 search returned503; first browser navigation also
failed. Full Web acceptance remains open. Daily58605 now runs the10s legacy
observation package after118 tests and4 actual-binary flows. The60s restart/backfill
window measured54.667% one-core CPU and78.9MiB max RSS; steady-state remains open. This supersedes
the current-runtime claims below; see CHANGELOG.md for historical evidence.

Web search update (2026-09-12): HQ Service82017 now runs guarded MATCH identity
projection and one byte-keyed current-page freshness check.55metadata tests and
two actual-binary flows passed; loaded framework is verified. Browser first
navigation passes desktop/mobile, but mixed round7 search still returns503 and
a native probe reproduces it. Full Web acceptance remains open. DailyCollector53303
continues backfill; the latest60s window is10.130% of one core/max80.531MiB,
with active reconciliation, not steady-state acceptance. This supersedes the
runtime/performance figures immediately below; see search-projection-hq-verified.json,
web-read-latency-search-projection-mixed.json and CHANGELOG.md. Mimo/Cline missing
originals remain low priority with no user response required.

Restart and performance update (2026-09-12): Daily Collector now uses a private
same-ID identity catalog independent of the retired Service. Both old and new
binaries had failed before readiness against the borrowed legacy catalog; the
native probe and old-package recovery isolate this dependency. Tested candidate
PID 53303 is uploading; see `peer-observation-daily-verified.json` under the task
evidence directory. Restart reconciliation remains active, so the 53.715% CPU
window is not steady-state acceptance. Current list/search probes return 503;
prior successful overview pagination does not close Web reliability. See
`CHANGELOG.md` and `web-read-latency-identity-fixed-mixed.json` for current evidence.

Web progress update (2026-09-12): the viewer now follows all overview pages,
and HQ Service59146 performs full counts only for returned streams. Real browser
and same-snapshot HTTP walks passed all17 streams; see
`output/collector-goal-20260908/overview-pagination-browser-lookahead-first-navigation.json`.
This supersedes the earlier undifferentiated overview503 note for the observed
paged flow, without claiming cold/p95 acceptance. Daily resource acceptance
remains open: current backfill measured24.492% of one core /75.172MiB over60s.
The repeated Cursor peer scan is the next measured optimization lead. Neither a
zero historical queue nor reboot was added as a new retirement prerequisite.

Daily cutover update (2026-09-12): the old com.engram.service job is now disabled
and unloaded, PID 25371 has exited, and the installed App/MCP uses collector role.
Nine old MCP helpers exited without stopping their eight parent processes;
Collector 66519 and its settings are unchanged. Old App/DB/config are retained.
See `output/collector-goal-20260908/daily-retirement-cutover-verified.json` and
`daily-retirement-retained-db-check.json`. This supersedes the preparation status
below. Backfill, steady-state acceptance and a newly observed HQ overview HTTP503
remain open; Daily retirement is not a claim of complete historical migration.

Retirement preparation update (2026-09-12): the four identified missing live HQ
read samples (iFlow, Qoder, Qwen, OpenCode), plus Gemini's normal sample, now pass
complete HTTP transcript checks, 97 messages total. Four manifest identities link
to existing dual-byte receipts; OpenCode sequence 5 has fresh HQ/M1 raw/ACK proof.
See `output/collector-goal-20260908/retirement-source-web-final.json` and
`retirement-opencode-live-bytes.json`. This is bounded replacement-path evidence,
not full historical catchup. The 30-minute backfill observer has completed.
`com.engram.service` must be disabled/booted out before the role-aware bundle
transition because its old launcher can respawn the local indexer. A fresh online
database/App/config rollback pack is verified in `daily-retirement-rollback-prepared.json`.
Actual cutover and steady-state acceptance remain incomplete; see `CHANGELOG.md`.

User priority update (2026-09-12): continue looking for the 43 Mimo / 3 Cline
originals autonomously through existing migration and backup leads. The user
does not know a backup location and considers this low priority. Do not wait
for another user answer or let this search block the core delivery. Missing
originals remain unverified; no recovery or full coverage is claimed for them.

Preservation update (2026-09-12): both Daily Windsurf PB originals (2,271,442 bytes) now have hash-verified private recovery copies on Daily, HQ and M1. See `output/collector-goal-20260908/windsurf-raw-independent-backups.json`. This closes raw-file preservation only; native parsing, Web readability and source retirement remain unverified. No provider app/API was started.

User scope update (2026-09-11): defer Antigravity cache/PB investigation and
implementation. It is not a blocker for the current core collector/HQ/M1/browser
stage. Preserve existing Antigravity data; no migration or retirement coverage
is claimed for that deferred source. This supersedes earlier work-priority notes.

Current-source correction (2026-09-11): the three default Windsurf cache roots
are present but empty. The daily Mac has two regular PB candidates under the
source-defined `.codeium/windsurf/cascade` root, with no running Windsurf process
or default daemon discovery directory observed. Metadata counts do not establish
valid sessions, archive durability or HQ parsing. See
`output/collector-goal-20260908/windsurf-real-source-inventory-20260911.json`.
Cache-only draft support does not close this original-file preservation question.

Antigravity metadata counts (2026-09-11): cache JSONL candidates HQ58/daily58/M1
0; CLI transcript path candidates22/172/0; provider PB candidates12/61/7. The
existing CLI implementation does not establish cache or PB coverage. File counts
are not unique sessions or durability evidence. See
`output/collector-goal-20260908/actual-cache-and-provider-candidates-20260911.json`.

## Current reading note (2026-09-11)

The original September 7 source matrix below is historical; later dated entries
and linked receipts supersede its local implementation status. It must not be
read as the current runtime allow-list or as real-host acceptance. In particular,
Windsurf hook JSONL has local binary/browser proof, while the legacy cache and
real hook history/retention remain separate coverage questions.

Fresh read-only inventory on September 11 confirmed HQ (Bing-HuaQiao.local)
and M1 (Bing-M1-MacMini.local). Both have the legacy Windsurf cache directory;
neither has `/Users/bing/.windsurf/transcripts`. HQ settings report `local`;
M1 settings are absent, so the inventory's `local` value is only its fallback,
not an observed running role. No transcript content or database was opened.
These observations do not establish full profile coverage, archive durability,
HQ read readiness, or permission to retire an indexer.

Evidence: `output/collector-goal-20260908/real-host-acceptance-20260911.json`
and its two dated inventory receipts. The daily Mac has not been refreshed in
this slice. Static daemon-boundary and boot-plist validation passed; neither
check starts or validates a live service. Full GOAL and retirement gates remain open.


Date: 2026-09-07. Scope: the local, synthetic W6 candidate in
`collector-server-web-20260905`, with source coverage reviewed against `c8a9cdc4`
and the subsequent Claude test-only addition.
Runtime measurement results are reported separately below.
This is a coverage gate, not a host inventory, cutover approval, or a claim that
any host is fully lightweight. W7 remains separately authorized.

## Evidence and interpretation

- The 17 registered Swift sources are enumerated by
  `macos/Shared/EngramCore/Adapters/SourceName.swift:3` and
  `SessionAdapterFactory.swift:59`. The factory paths below are code defaults,
  not observed paths or enabled settings on any host. `<home>` means the
  adapter's explicitly resolved home, not a discovered user directory.
- `macos/EngramCollectorCore/CollectorRuntime.swift:511` and
  `CollectorPublicationWorker.swift:120` accept only `codex` and `claude-code`
  roots. Their collector representation is a stable, exact single-file
  generation, discovered through the bounded inventory/native-event path.
- `CollectorPrivacyProof.swift:155` requires unambiguous source/native identity,
  cwd, exclusion-policy eligibility and captured-generation binding.
  Primitive support for derived Claude sources at line 168 is not runtime
  enablement: Runtime policy comes only from its two accepted root sources.
  Worker line 476 uses `forceClaudeCodeSource: false`; a nondefault Claude
  profile must not be assumed equivalent to the default profile.
- `CollectorPrivacyProofTests.swift:20` covers both initial formats;
  `CollectorInventoryOwnerTests.swift:397` checks both root identities.
  Those are component contracts, not host capture/HQ evidence.
- Actual synthetic Codex real-binary evidence: two generations across Collector,
  independent HQ/M1 RemoteServers, HQ Service and Web IPC passed in
  `/tmp/engram-binary-shadow-first-root-v3.{log,xcresult}`. The later private
  HTTPS/browser run passed two tests with zero failures at 09:34 CST in
  `/tmp/engram-binary-browser-root-v2.{log,xcresult}`; rendered evidence is in
  `output/playwright/binary-shadow-20260907/browser-v2-findings.md`.
  These receipts are local-only, synthetic, and do not prove any real source
  root, Claude profile, tailnet path, or production HQ record.
- Synthetic `.claudeDefault` two-generation replay now passed using the explicit
  complete `c8a9cdc4` packages: actual Collector, two independent RemoteServers,
  HQ Service and Web IPC, exact bytes/ACKs, stable native/session identity,
  roles/timestamps/model, positive per-message/aggregate usage and normal tier.
  `/tmp/engram-w6-handoff-binary-shadow-v3.{log,xcresult}` ran six tests with
  one opt-in browser-hold skip and zero failures; Claude itself passed in 2.908s.
  Full Service then passed 1,156 tests with five opt-in/live skips and zero
  failures in `/tmp/engram-w6-handoff-full-service-v1.{log,xcresult}`.
  The two earlier attempts exposed fixture layout/append-guard mistakes; their
  failures and temporary fixtures remain retained. Only the Claude fixture was
  corrected; product rules, Codex/recovery bodies and deadlines are unchanged.
  This does not establish real default or nondefault profile coverage.
- Tests and CodeQL for exact revision `87cc453c` passed in runs `34083556529`
  and `34083556503`: https://github.com/bbingz/engram/actions/runs/34083556529
  and https://github.com/bbingz/engram/actions/runs/34083556503. Both full
  30-minute synthetic windows failed CPU: `9e90471b` at 2.144809%, `87cc453c`
  at 2.120649%, each versus 2% of one core. All other second-window metrics
  and final content passed. Healthy-tailnet measurement remains unverified.
  See `CHANGELOG.md` for retained failure evidence and local regression results.
- A subsequent two-route storage-open optimization passed actual RED/GREEN,
  295 CollectorCore tests and 1,155 Service tests (five opt-in/live skips), with
  independent source/log approval. Source enablement and retirement boundaries
  are unchanged. Neither this regression nor the separately labeled CPU profile
  replaces the failed 30-minute measurements. The subsequent unchanged full
  Release window at `c8a9cdc4` separately passed: 1,800.010043s, 1,801 samples,
  CPU 1.648439% of one core, maximum sampled RSS 24.093750 MiB; p95 append
  3.800301s and sessions/detail/messages 0.200195/0.198147/0.075098s. All 1,140
  attempts and three authentications succeeded; eight owned children joined.
  Independent artifact accounting passed. Final hash/316-publication/632-ACK/
  248-4-4 session-bucket checks are executed harness assertions; the successful
  fixture was removed, so no independent post-run SQLite check is claimed.
  Evidence: `/tmp/engram-performance-c8a9cdc4-v1.{log,xcresult}`,
  `output/native-release-c8a9cdc4-20260907/performance-run-v1/`, and
  `/tmp/engram-w6-handoff-performance-independent-v1.log`.
  Tests `34089038847`, Dependency Review `34089038897` and CodeQL `34089038877`
  all passed for that exact product revision. A later test/docs-only revision
  does not rename the measurement or inherit its CI result.

## Registered sources

For **every row**, host enablement, approved real roots, latest successful real
capture, latest real HQ index, and retirement approval are `UNVERIFIED`.
The old ingestion path must remain enabled wherever the source is enabled.
No absence-of-support row may be interpreted as an absence-of-use finding.

| Source | Factory default root or dependency | Collector discovery / representation | Privacy and parser/replay evidence | Replacement gate / unsupported reason |
|---|---|---|---|---|
| codex | `<home>/.codex/sessions` | Bounded inventory + native events; exact single-file generations | Generation-bound privacy component tests; synthetic two-generation native/HQ/Web receipt above | Local synthetic subset only; three runtime roots below and real capture/HQ evidence unverified |
| claude-code | Claude profile resolver from `<home>/.engram/settings.json` | Bounded inventory + native events; exact single-file generations | Generation-bound privacy/root tests; synthetic `.claudeDefault` two-generation real-binary/HQ/Web replay above | Actual default and nondefault profiles need separate approved roots and real replay evidence |
| minimax | Derived from resolved Claude adapter | No accepted Collector runtime root | Primitive derived-source opt-in test only; runtime policy does not enable it | Unsupported runtime source; do not relabel as claude-code |
| lobsterai | Derived from resolved Claude adapter | No accepted Collector runtime root | Primitive allow-list entry; no Lobster-specific eligibility/replay proof | Unsupported runtime source; do not relabel as claude-code |
| gemini-cli | `<home>/.gemini/tmp` plus `projects.json` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| opencode | `<home>/.local/share/opencode/opencode.db` | No scoped consistent database export | No Collector replacement privacy/replay proof | Unsupported runtime source; copying a live main DB without WAL is not coverage |
| iflow | `<home>/.iflow/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| qwen | `<home>/.qwen/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| qoder | `<home>/.qoder/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| kimi | `<home>/.kimi/sessions` plus `kimi.json` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source |
| commandcode | `<home>/.commandcode/projects` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |
| cline | `<home>/.cline/data/tasks` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source |
| cursor | `<home>/Library/Application Support/Cursor/User/globalStorage/state.vscdb` plus `.cursor` | No scoped consistent DB/composite export | No Collector replacement privacy/replay proof | Unsupported runtime source; main-file-only copies do not cover WAL/dependencies |
| vscode | `<home>/Library/Application Support/Code/User/workspaceStorage` | No scoped consistent DB/composite export | No Collector replacement privacy/replay proof | Unsupported runtime source |
| windsurf | `<home>/.engram/cache/windsurf` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source; no live provider API access authorized |
| antigravity | `.engram/cache/antigravity`, `.gemini/antigravity/conversations`, `.gemini/antigravity-cli/brain`, all under `<home>` | No verified composite dependency manifest | No Collector replacement privacy/replay proof | Unsupported runtime source; no live provider API access authorized |
| copilot | `<home>/.copilot/session-state` | Not implemented in Collector runtime | No Collector replacement privacy/replay proof | Unsupported runtime source |

## Codex runtime roots and diagnostics stay separate

No real agent runtime was inspected for this checklist. A synthetic Codex-format
JSONL fixture is not evidence about any of the following installed runtimes.
The shared six diagnostic fields are deliberately recorded separately.

| Runtime | Executable path | Version | Config home | Config file | Actually loaded instruction chain | Session start time | Approved source roots / capture / HQ |
|---|---|---|---|---|---|---|---|
| Standard Codex CLI | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |
| Orca-launched Codex | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |
| OpenAI-bundled Codex | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED | UNVERIFIED / UNVERIFIED / UNVERIFIED |

## Missing adapters tracked separately

Grok and Pi are not members of the current registered 17-source enum. Their
approved roots, enabled use and replacement status are `UNVERIFIED`; they are
missing adapter coverage, not regressions in registered adapters. Do not scan
their real stores or infer they are unused without the bounded host transaction.

## Per-host retirement verifier, not executed

1. Obtain authorization for named hosts and exact source/config roots. Inventory
   enabled sources and Claude profiles without reading credentials or widening
   discovery; record each source instance and the three Codex runtimes separately.
2. For every enabled instance, record approved roots, actual discovery mechanism,
   exact representation/dependency set, privacy-policy revision, and a parser/
   replay fixture. Database exports must include a consistent WAL-aware snapshot;
   composite sources require a verified dependency manifest. Cache-only sources
   must not silently become live API readers.
3. Record dated generation, canonical manifest/publication digest, both independent
   durable ACKs, and the matching HQ generation/ledger/FTS/search/transcript proof.
   Compare exact bytes, messages, roles, timestamps, usage and tiering; include
   append/rename/restart, exclusion and last-good-data preservation checks.
4. Keep old ingestion for every unproved or unsupported enabled source. Stop
   retirement on any gap; do not change jobs/configs, mark a host lightweight,
   or use this local checklist as production transaction authority.

CHECKS_RUN: current enum/factory/runtime/worker/privacy source inspection; synthetic
Codex/Claude real-binary and full Service regression; complete package verification;
30-minute Release performance and independent artifact accounting; exact product-head
CI refreshed. Table-to-enum coverage is checked separately.

CHECKS_NOT_RUN: real host enablement/root inventory, all real-source capture/HQ
checks, actual Claude profile coverage, Grok/Pi inventory, healthy-tailnet latency,
retirement and W7. Existing browser render evidence was not rerun for this
Claude test-only addition; its hold is explicitly skipped in normal regression.

WHY_NOT: host operations require the separately authorized bounded transaction;
synthetic/component evidence is intentionally not promoted into real coverage.

EVIDENCE_PATH: the source and test/log paths above; governing design section 3
at `docs/superpowers/specs/2026-09-05-collector-server-web-design.md:391` and W6
at `docs/superpowers/plans/2026-09-05-collector-server-web.md:1184`.

## 2026-09-08 continuation: custom Claude and bounded host presence

The earlier snapshot above remains historical. The uncommitted continuation now
adds explicit native spool initialization and per-root `parseFormat` authority
for `claudeCustomProfile`. The new two-generation custom-profile native binary
chain and default-HQ reinterpretation refusal passed in the affected Service
suite: 84 total, 83 passed, one opt-in browser-hold skip, zero failures. The new
Collector Debug binary used unchanged aff8353c Service/RemoteServer packages.
Existing default-Claude/Codex binary tests also passed in that invocation.
This upgrades only synthetic custom-profile evidence; no real automatic/custom
profile root has been accepted or retired.

Only named settings fields and lstat of exact factory-default paths were read
on daily Mac, HQ and M1. Respectively 13, 13 and six configured-enabled source
IDs have at least one standard path present. M1 has no settings file at that
named path, so its enablement/role values are code-default assumptions. Runtime
environment overrides, path contents, automatic profile enumeration and actual
source activity were not examined. Do not convert these counts into active
session counts, completed source coverage or retirement authority.

Qwen and the remaining file/database/composite/cache sources are still active
implementation gaps. A source=qwen/format=qwen slice must preserve native
identity, cwd privacy evidence and central replay; it must not reuse Claude
classification. Database sources still require consistent WAL-aware exports.

Evidence: `output/collector-goal-20260908/progress.json`,
`candidate-service-green.xcresult`, `initializer-race-green.xcresult`, and
`inventory-daily-mac.json`, `inventory-hq.json`, `inventory-m1.json`. Independent
initializer dirty-victim probing remains in progress. No production roles were
changed; the full user objective remains active.

## 2026-09-08 Qwen continuation

This supersedes the earlier Qwen unsupported-runtime row for the current local
candidate only. Native `source=qwen`/`parseFormat=qwen` now spans bounded direct
project/chats discovery, metadata privacy proof, exact capture, both replica
publication receivers, HQ source eligibility/strict replay, FTS and Web IPC.
Two-generation current-Debug-binary acceptance passed, including source identity,
exact bytes and message/model/usage checks. Missing timestamps use the manifest
source-generation mtime rather than a new staging-file timestamp.

Evidence: `output/collector-goal-20260908/qwen-binary-green.{log,json,xcresult}`;
`qwen-replica-red-v2`/`qwen-replica-green`, `qwen-eligibility-red`/`qwen-eligibility-green`,
and `qwen-replay-green`/`qwen-core-green` preserve the separate admission and
mtime RED/GREEN evidence. Initializer dirty-victim adjudication is complete for
the tested families: nine tests passed; tested hot/WAL/symlink victims unchanged.

Qwen actual host instances, natural input, rendered Web, Release/CI and retirement
remain UNVERIFIED. Qoder, CommandCode and remaining database/composite/cache sources
are still required. No host can be declared fully lightweight from this subset.

## 2026-09-08 Qoder and CommandCode continuation

This supersedes the earlier unsupported-runtime rows for the current local
candidate only. Native Qoder and CommandCode formats now span configured
Collector roots, bounded layout discovery, complete captured-generation privacy,
independent Remote publication ACKs, HQ source authority, native replay and Web
IPC reads. Qoder subagents remain skip; CommandCode slug fallback preserves later
explicit cwd and original captured mtime. Native source/model/usage identities
remain distinct from Claude-derived labels.

Executed RED and GREEN are retained under
`output/collector-goal-20260908/native-pair-*`. Core 146, CollectorCore 320,
Remote publication 51 and Runtime/worker 64 passed; three Debug builds passed;
CLI/shadow 27 passed with one opt-in browser hold skipped. Both new sources
passed two-generation exact-byte dual-replica/HQ/FTS/Web IPC cases. A further
2-test run verified all 8 local linked artifacts stayed unchanged; main
executable hashes alone do not cover dynamic product frameworks.

Real host instances, natural input, rendered Web, current Release/CI and source
retirement remain UNVERIFIED. Gemini and Copilot need explicit auxiliary-file
capture; the coordinator checked Gemini cwd/sidecar and Copilot YAML/checkpoint
source dependencies behind the next proposal. Database/composite/cache sources,
M1 identity provisioning, all actual profiles and distinct Codex runtime roots
remain in the full goal. This entry grants no deployment or retirement authority.

## 2026-09-08 declared file-set foundation; native composite sources still open

This addendum does not change any real-host retirement gate. The explicitly
requested schema-2 capture/model foundation passes 54 tests; the broader
ArchiveV2/CaptureIngest 501, Collector 320, Remote 51 and Runtime/worker 64 gates
also pass on the current uncommitted product code. Captures preserve per-member
bytes, generations, hashes, offsets and absence under bounded no-follow walks.
These are declarations, not source-specific complete membership discovery.

Two subsequently added Copilot Runtime acceptance tests fail at
`Runtime.open` with `invalidConfiguration` (two tests/four assertions), before
capture/recovery/upload. Their acceptance requires workspace-only changes and
checkpoint-body-only changes despite start-only events, unchanged primary stat,
complete member bytes and dual replica ACKs. Copilot and Gemini remain unsupported
through the native Collector-to-HQ replacement path. No host may retire the old
path based on this foundation. Remaining work includes dependency fan-in,
reservation/recovery snapshots with old-binary refusal, membership fencing,
privacy, Remote/HQ replay, actual instances and natural-source acceptance.

Gemini must capture only its session-ID sidecar, and registry-only cwd must have
project-scoped derived provenance. Uploading shared projects.json, all sibling
sidecars, or relabeling generated metadata as a native .project_root is not an
accepted shortcut. See `CHANGELOG.md` and
`output/collector-goal-20260908/{file-set-*,copilot-composite-runtime-red}.*`.

## 2026-09-08 Copilot composite continuation

This supersedes the historical Copilot unsupported-runtime row for the current
local uncommitted candidate only. Native Copilot events/workspace/checkpoint
file sets now preserve exact present members and canonical absence witnesses,
including hidden and uppercase-extension checkpoint bodies. Discovery lists
stat-only lexical candidates; publication selects the native primary with
complete-input byte eligibility and matching dependency-generation fences.
Versioned reservations preserve membership for immutable recovery, and captured
privacy matches native directory identity fallback while checking every observed
cwd. HQ/replicas verify each member independently of the aggregate digest.

Current evidence: HQ replay/registry 70, Remote 54, full Collector 327 and
Runtime/worker 73 passed. Three fresh Debug builds succeeded. Both actual Copilot
binary cases passed for two auxiliary-only generations through independent local
HQ/M1 replicas and HQ FTS/Web IPC. The checkpoint case includes a hidden .MD
member. All eight linked local Mach-O hashes are stable across execution.

The initial combined 103-test run had 101 passes, one opt-in browser-hold skip,
and one checkpoint Web deadline. The retained fixture proved one checkpoint was
correctly skip, with both ACKs and the normalized HQ payload preserved. The
fixture now has two checkpoints for normal visibility; two focused binary cases
passed after that test-only correction. Product skip rules were unchanged.
Receipts/logs: `output/collector-goal-20260908/copilot-*.{json,log,xcresult}`;
`copilot-checkpoint-skip-adjudication.json` records the retained failure review.

This does not prove real Copilot roots/profiles, current Release/CI, rendered Web,
healthy-tailnet latency, resource budgets or host retirement. Gemini and the
remaining enabled database/composite/cache sources remain required. The separate
Codex runtime rows above remain unverified by this synthetic source work.

## 2026-09-08 Gemini captured-context checkpoint

The original Gemini row is partially superseded for the uncommitted local
candidate: schema-2 native file sets and schema-3 project-scoped registry
provenance now replay at HQ without original inputs or host registry access.
Extended Core 145, replica storage 43 and publication routes 13 passed. Final
session-ID sidecar binding and positive native usage/dispatch parity are covered.

Collector integration remains incomplete. Executed REDs cover large/invalid
JSONL metadata updates, registry changes across fresh capture, changed configured
registry authority, native-root exclusion and sidecar privacy. One registry-only
Runtime variant ended at a deadline; the other returned CancellationError and
must be rerun without inventing a cause. Same-path recovery of an already durable
capture preserved the reserved context successfully. Cursor owns the bounded
repairs; parent owns independent tests and review. Receipts:
`output/collector-goal-20260908/gemini-*.{json,log,xcresult}`.

No Gemini real-binary/real-source, current Release/CI, rendered-browser, resource
or retirement gate is passed by this checkpoint. Remaining enabled sources and
M1-local identity are still required. See `CHANGELOG.md` for exact evidence.

## 2026-09-08 Gemini native binary acceptance supersession

The historical Gemini unsupported/incomplete local rows above are superseded by
current synthetic evidence, not by a real-host retirement approval. Persistent
outside-root registry observation and snapshot-bound recovery pass Runtime/worker
88, including paging/restart, absence/reappearance, offline changes, configured
locator changes and unused-registry native-root recovery.

A native transcript-size versus aggregate-capture-size commit defect has actual
capture/replay/commit RED/GREEN. Full ArchiveV2/CaptureIngest 519 passed. Three
fresh Debug builds and both actual Gemini binary cases passed: native project-root
only and project-registry only changes produce two generations through independent
local HQ/M1 archives and HQ FTS/Web IPC, preserving primary bytes/stat, identity,
messages and usage. Eight linked local Mach-O artifacts are stable across the run.
The shared registry is never uploaded. Original failures/fixtures are retained;
the old processing lease was not evidence of a parser hang.

Receipts: `output/collector-goal-20260908/gemini-binary-final-green.json`,
`gemini-archive-ingest-final-green.json`, `gemini-runtime-worker-green.json`, and
their logs/xcresults. See `CHANGELOG.md` for the exact size defect and timeline.
Current Release/CI, rendered Web, actual roots/profiles, natural-source changes,
resources and host retirement remain UNVERIFIED. Other enabled database/cache/
composite sources and M1-local identity remain part of the full active goal.

Final CollectorCore regression also passed 333 tests after the observer locator
fix (`gemini-collector-final-green.*`). A separate read-only source comparison
identifies OpenCode's WAL-aware, per-session SQLite representation as the next
missing primitive; Cursor has related SQLite and composite inputs. This priority
is a source-format judgment, not evidence that either is currently enabled.
Correction to the historical VS Code row: the current `VsCodeAdapter.swift`
reads `chatSessions/*.jsonl` and sibling `workspace.json` metadata (which may
refer to a workspace file), not a session SQLite database. Kimi needs context
shards/wire plus scoped cwd provenance; Windsurf and Antigravity remain cache or
native transcript inputs without new live-provider API authority.

## 2026-09-08 OpenCode database foundation; replacement gate remains closed

OpenCode now has an executed Runtime admission RED from a synthetic database
whose initial and second commits live only in WAL while main bytes remain stable.
The scoped export helper is under independent verification: exact SQLite storage
types and raw session/message/part cells, other-session exclusion, pinned read
transaction, bounded byte/row/VM work, original main/WAL preservation, missing-SHM
private fallback, hot-journal refusal and path-race checks. It does not yet supply
Collector inventory, reservations, publication, privacy or HQ source admission.

Schema 4 explicitly marks the derived session image and carries native virtual
locator/session ID, original DB generation, native payload size and optional WAL
observation. Schema-1 file semantics are preserved. Model 33 and the complete
ArchiveV2/CaptureIngest regression 523 passed. Foundation plus dependency checks
passed 21 after actual source-root race RED; full Collector and native replay
results are recorded separately in `CHANGELOG.md` when completed.

Evidence: `output/collector-goal-20260908/opencode-*.{json,log,xcresult}`.
This checkpoint does not supersede the unsupported OpenCode replacement row.
The private-copy fallback currently runs per snapshot call; amortized root-level
reuse/incremental scheduling and resource acceptance remain implementation work.
All real-host, remaining-source, M1-local identity and retirement gates stay open.

Final foundation evidence supersedes the pending test sentence above: complete
Collector 353 and native adapter image parity 1 passed in
`opencode-collector-final-green` / `opencode-native-image-final-parity`. Original
source removal, metadata/messages/positive usage/parent/dispatched preservation
are asserted. The two final offline failures were actually reproduced first:
private checkpointed DB WAL-index initialization and private root alias refusal.
Only the disposable copy opens writable/query-only; source main/WAL remain
unchanged in the covered tests. Runtime/CAS/privacy/HQ admission, snapshot lease
batching and live-sidecar race/resource acceptance remain open.

## 2026-09-08 OpenCode lease and CAS supersession; Runtime gate still closed

The historical per-call private-copy and missing-CAS statements above are now
superseded. One private main/WAL lease serves bounded session-ID pages and multiple
images. Native SQLite never opens source paths; aggregate VM and fallback-copy
budgets, immutable post-seal replay, before-seal path fences and FD cleanup have
executed coverage. Schema-4 image capture preserves DB/WAL stat provenance,
separate image bytes, canonical capture identity/time and CAS recovery.

Current receipts under output/collector-goal-20260908/:
- opencode-image-capture-core-regression: 527 ArchiveV2/CaptureIngest tests passed.
- opencode-private-lease-collector-green-v2: 363 full Collector tests passed.
- opencode-image-cas-native-parity: two native adapter tests passed, including CAS
  reconstruction after original source removal and full metadata/message parity.

This does not enable OpenCode Runtime or prove HQ/M1 delivery. Durable per-session
reservation/pagination, WAL-only dirty observation, snapshot-bound privacy,
replica admission and HQ replay/commit remain required. A primary-database claim
cannot be acknowledged after only its first session image. All actual-source,
real-host, resource, Release/CI, rendered-Web and retirement gates remain open.

## 2026-09-08 OpenCode durable walk and replica storage checkpoint

Inventory APIs now persist a source DB/WAL pair, bounded native-ID progress and
per-session typed reservations. Publication/cursor advancement is atomic, the
primary remains dirty until matching-pair EOF, and old CAS recovery cannot skip
sessions in a newer WAL walk. Legacy publication schemas 1/2/3 migrate to 4 while
preserving reservations. Full Collector 373 and publication worker 52 passed.

Replica storage accepts only explicit schema-4 OpenCode images; schema-1
OpenCode remains refused. Two independent local hq/m1 ArchiveStore fixtures
retain exact image/manifest bytes, distinct WAL provenance and idempotent ACKs.
Store 44, actual route class 13, and ArchiveV2/CaptureIngest 527 passed. See
CHANGELOG and output/collector-goal-20260908/opencode-durable-*.{json,log,xcresult},
opencode-replica-*.{json,log,xcresult}, and opencode-walk-identity-core-green.*.

The OpenCode replacement gate remains closed. Worker paging/WAL observation,
policy-bound skip outcomes, captured-image privacy, Runtime admission and HQ
native ingest are not connected. No actual-host, binary-chain, rendered-Web,
resource or retirement claim follows from these API/storage tests.

## 2026-09-08 OpenCode local Runtime and privacy supersession

WAL observation, bounded worker paging, captured-image privacy and Runtime
admission are now wired. Two local independent HTTP replicas accept WAL-only
versions without source mutation or a local product index. Restart resumes a
one-image walk after an excluded first session, completes remaining sessions,
and reauthorizes the saved first image after original DB deletion. Interrupted
CAS-only capture recovers without source reads; a changed uncaptured reservation
is abandoned without relabeling new bytes as its old generation.

Parent verified full Collector 379 and final Runtime/worker 93. A new actual RED
exposed one-day privacy backoff surviving policy changes; the fix persists the
policy SHA and resets only pending privacy-withheld deadlines/attempts. Same-policy
restart and transport backoff remain unchanged. See CHANGELOG and
output/collector-goal-20260908/privacy-policy-requeue-{red,green}.* plus
opencode-wired-*.{json,log,xcresult} for complete local evidence.

The OpenCode replacement gate remains CLOSED: HQ registry/replay/commit and the
actual native binary chain remain incomplete. No current Release/CI, real-host
natural-input, rendered-Web, resource or host-retirement acceptance is implied.

## 2026-09-08 OpenCode HQ native ingest supersession

HQ schema-4 registration, exact configuredRoot/opencode.db binding, staged native
replay and native payload-size commit are now wired. The adapter validates image
identity/ownership and reuses the existing native parser. Parent reproduced and
fixed commit-time rebinding of an otherwise consistent native identity away from
the immutable context. Normal sessions enqueue index jobs; dispatched children
remain skip. Final Archive/Ingest plus 16 native OpenCode tests: 553 passed.

Actual Collector snapshot -> CAS -> HQ registry/replay after deleting originals
also passed; all three Service native replay tests passed. See CHANGELOG and
output/collector-goal-20260908/opencode-hq-native-core-green.*,
opencode-hq-native-review-v2.* and opencode-snapshot-hq-pipeline-green.*.

The replacement gate remains CLOSED until rebuilt native process-chain acceptance,
OpenCode FTS/Web query proof, actual enabled-source/profile coverage, M1-local
identity, real-host natural input and current Release/CI/resource/retirement gates
are independently verified. This supersedes only the prior HQ-not-connected
checkpoint, not the unverified operational requirements.

## 2026-09-08 OpenCode native binaries and browser supersession

Three fresh Debug builds passed. The actual Collector, independent hq/m1 local
RemoteServers and HQ Service now pass two WAL-only generations through schema-4
images, native identity/size/usage, completed FTS and Web queries. Direct FTS MATCH,
source main/WAL equality, scoped sibling exclusion and no Collector index are
asserted. CLI/binary regression: 33 total, 32 passed, one opt-in Codex browser hold
skipped. All eight linked local artifact hashes remained stable.

A separate explicit OpenCode browser hold was exercised with Playwright: HTTPS
login, source/keyword filtering, detail and three rendered messages, no-match
search and zero console errors/warnings. Parent inspected the screenshot. The
owned fixture and browser were stopped and joined. See CHANGELOG and
output/playwright/opencode-browser-receipt.json / opencode-native-web.png plus
output/collector-goal-20260908/opencode-browser-fixture-v2.*.

The replacement gate remains CLOSED: this supersedes the local OpenCode native
process/FTS/rendered-Web gaps only. Actual enabled-source/profile coverage,
M1-local identity, real hosts/natural inputs, current Release/CI, production TLS,
resource limits and installed-service retirement still require independent proof.


## 2026-09-08 Kimi dependency and native replay foundation

A bounded metadata-only observer now covers native context shards, optional wire
presence/absence and scoped external work_dirs provenance. Full Collector 392
passed, including two parent-reproduced registry projection regressions. Actual
file-set CAS reconstruction after original source/registry removal passed two
native KimiAdapter parity cases, with and without wire. See CHANGELOG and
output/collector-goal-20260908/kimi-collector-final.* / kimi-native-cas-replay-v2.*.

The Kimi replacement gate remains CLOSED. Scoped cwd context is only carried
in-process by these tests; immutable transport/reservation representation, live
dirty observation, captured-input privacy, publication and HQ admission/commit
remain required. No network, FTS/browser, real-host, resource or retirement proof
is implied. Existing historical unsupported rows are superseded only for this
local dependency/CAS/native-replay foundation.


## 2026-09-08 Kimi immutable provenance and recovery supersession

Schema-5 scoped cwd now survives the actual immutable manifest and inventory
reservation. The observer supplies it directly; callers need no in-process-only
projection bridge. Restart with a reopened DB, original-source removal, exact
context-bound CAS completion, corruption refusal, old-schema migration and
transaction rollback passed. Archive/Ingest 543, Collector 399 and affected
Service 98 passed; two native Kimi cases preserve full output using the persisted
manifest context. See CHANGELOG and kimi-schema-*.{json,log,xcresult} under
output/collector-goal-20260908/.

Replacement gate remains CLOSED: Kimi dependency/registry event scheduling,
captured-input privacy, Runtime and replica transport, HQ native ingest/FTS/Web,
rebuilt binary and actual enabled-source/host/resource/retirement acceptance are
not supplied by these storage/domain tests. The earlier in-process-context-only
limitation is superseded; all operational and remaining-source requirements stay.

## 2026-09-08 Kimi Runtime and replica transport supersession

Kimi Runtime/privacy/replica transport is now locally verified: full Collector
404, affected Service 101, ArchivePublicationStore 45 and routes 13 passed,
actual producer exits 0. Four source/dependency/context generations were fetched
and compared byte-for-byte from two independent loopback HTTP replicas. An
excluded capture was reauthorized after Runtime restart with original source
and registry deleted. Durable registry pagination resumes after DB reopen.
Evidence: `output/collector-goal-20260908/kimi-runtime-collector-regression.json`,
`kimi-runtime-service-regression.json`, `kimi-replica-green.json`, and
`kimi-replica-routes-green.json`, with matching full logs/xcresults.

This supersedes earlier Kimi Runtime/privacy/transport pending notes only.
Kimi HQ registry/replay/commit and resulting FTS/Web remain incomplete; existing
native adapter replay does not prove them. All source/host replacement gates
remain CLOSED pending actual profile coverage, independent identity/natural
inputs, current binaries/Release/CI, operational Web/resource evidence and the
separately authorized host transaction. No deployment or retirement occurred.

Follow-up: Cursor identified uncaptured missing-input recovery blocking. Actual
Service RED 102/one failure was fixed only at the Kimi uncaptured preflight;
Service GREEN 103/zero failures proves primary and registry loss can retry after
restoration, while a separate durable-but-unpublished capture recovers the same
sequence/epoch without either original input. Receipts:
`output/collector-goal-20260908/kimi-uncaptured-recovery-{red,green}.json` and full
logs/xcresults. This supersedes the Service 101 count above; host gates stay closed.

## 2026-09-09 Kimi HQ replay, commit and FTS supersession

Kimi HQ source registry, native captured-input replay and bound commit are now
locally verified. Final Archive/Ingest plus native Kimi regression passed 563;
affected Service passed 107; final focused commit/FTS suite passed 63. All actual
xcodebuild exits were 0. The real IndexJobRunner consumed saved normalized
messages with no adapters after original source/registry removal, returned the
expected session for FTS MATCH aurora and transitioned to index_ready. A
registry-only version updated the same stored session. Independent REDs exposed
wire-inclusive size acceptance, consistent native identity forgery and cwd drift;
all are rejected by the final captured-context commit checks.

Evidence: output/collector-goal-20260908/kimi-hq-native-core-green.json,
kimi-hq-service-green.json and kimi-hq-fts-commit-green.json, with matching full
logs/xcresults. Work started September 8 and finished September 9.
This supersedes Kimi HQ/domain-FTS pending notes only. Fresh linked native binary
chain and rendered Kimi Web remain pending; previous OpenCode binary hashes are
historical. All host/source retirement gates remain CLOSED pending real profile,
identity, natural-input, Release/CI, Web/TLS and resource evidence, and the
separately authorized operational transaction. No deployment/retirement occurred.

## 2026-09-09 Kimi native binary and rendered Web supersession

Fresh Collector/Service/RemoteServer Debug builds passed. Real Kimi binary chain
verified initial context/wire, added shard and registry-only cwd versions across
two independent replica processes and actual HQ Service FTS/Web IPC. CLI/binary
34 total:33 passed, one existing opt-in Codex browser skip. Separate Kimi browser
fixture:1 passed in202.812s. All8 linked local artifacts stayed stable per run.
Playwright verified login, Kimi search/detail, full3 messages, updated project and
no-match clearing. Initial automation submitted the whole credential JSON and
received401; corrected login204 and data200 succeeded. The sole console error is
that setup401, warnings0. Screenshot was visually inspected. Test-only loopback
TLS/ignoreHTTPSErrors does not establish production TLS trust.

Evidence: output/collector-goal-20260908/kimi-binary-cli-regression.json and
kimi-browser-fixture.json with logs/xcresults; output/playwright/kimi-browser-
receipt.json and kimi-native-web.png. Named browser closed and exact owned
fixture removed; all owned producers/children joined. This supersedes only the
Kimi local binary/rendered-Web pending note. All real-host/source retirement
gates remain CLOSED, including remaining enabled families/profiles, independent
identity, natural inputs, Release/CI, persistent Web/TLS and resource evidence.
No deployment or retirement occurred.

## 2026-09-09 Cursor dependency discovery foundation

Modern native-shaped discovery is locally implemented and tested: exact-ID
chats/projects pairing, all observed SQLite sidecars/meta/transcript and known
absence, bounded no-follow enumeration, input/directory replacement fences and
native hidden-child exclusions. Actual RED13/41 assertions and hidden-directory
RED14/one assertion preceded full Collector418/zero failures, actual exit0.
Evidence: output/collector-goal-20260908/cursor-discovery-receipt.json and its
full logs/xcresults. cursor-capture-contract.md retains BOTH modern and legacy
requirements. This supersedes only the missing-modern-discovery foundation;
private coherent SQLite capture, transport/privacy/persistence, independent
replicas and HQ native replay/FTS/Web remain open. No upload route is enabled.
All real host/source-retirement gates remain CLOSED; default path counts do not
prove enabled profiles, corpus completeness or operational acceptance.

Review follow-up supersedes418: final Collector421 passed, zero failures/skips,
actual exit0 after demonstrated REDs for whole-call budget, pre-fdopendir CLOEXEC
and unrelated child-link handling. Shared byte-preserving decoder reused;
configured roots/fixed directories/primary/sidecar links still refuse. Same pane
review is done524 and all parent producers joined. Discovery-only scope and
all CLOSED retirement gates above remain unchanged.

## 2026-09-09 Cursor private SQLite custody checkpoint

The modern Cursor store component now uses the shared physical lease also used
by OpenCode. Source files are read without live SQLite opens; private main/WAL,
root/name/generation fences, separate staging ancestry and owned-FD cleanup are
verified. Caller-observed metadata/transcript dependencies and relevant directory
identities must still match before the Cursor body reads a committed private
WAL generation. Original source removal after seal is supported. Initial69/76
assertion RED and private-pair70/12 assertion RED preceded final focused70,
Collector438 and Service107 success, actual exits0. Source/SQL equality and full
logs/xcresults are linked from output/collector-goal-20260908/cursor-sqlite-
snapshot-receipt.json. Same pane review done533; all parent producers joined.
This is database-component custody, not Cursor archive publication: composite
exact JSONL/meta, new representation/context, privacy/persistence/dual replicas,
legacy composer export/frozen ownership and HQ/FTS/Web remain pending. Earlier
binary hashes are historical for the changed candidate. Every real-host/source
retirement gate remains CLOSED; no installed service or production data changed.

## 2026-09-09 Cursor raw composite capture checkpoint

Modern main/WAL/meta/JSONL bytes now retain original per-file generations without
source SQLite opens. SHM/journal never enter payload. Five synthetic native
replay cases passed after original-tree deletion, preserving complete info and
messages with only logical locator remapping. Same-pane review deadline and
ENOENT issues have actual RED32/4 and final Collector449/Service112 GREENs.
Evidence: output/collector-goal-20260908/cursor-composite-capture-receipt.json.
This supersedes the prior database-component-only status above. It does not prove
Cursor durable CAS/publication, captured-input privacy, HQ ingest/FTS/Web or
legacy composer extraction/ownership. Existing schema 2 is the next durable
file-set target; no new schema is necessary for self-contained modern inputs.
Every real-host/resource/profile/Release/CI/production-transition gate remains
CLOSED. No old local indexer is authorized for retirement.

## 2026-09-09 Cursor durable sealed-member checkpoint

Existing schema 2 now stores modern raw members with original generations and
hashes. persistModern carries the captured root and sealed bytes without a live
source or staging restat. Five native replay fixtures now delete originals before
persistence and reconstruct only reopened catalog/CAS contents. Archive RED77/10
and persistence RED5/5 have final Archive/Ingest553, Collector449 and Service112
GREENs, actual exit0; same-pane review done545. Evidence:
output/collector-goal-20260908/cursor-sealed-archive-receipt.json.
This supersedes the prior CAS-pending checkpoint, but does not enable Cursor
runtime/replica/HQ admission. Captured-input privacy, reservations/recovery,
independent delivery and HQ replay/commit/FTS/Web remain next. Legacy composer
rows/frozen ownership remain required. Real-host/profile/resource/Release/CI and
production transition acceptance stay CLOSED; no source retirement is authorized.

## 2026-09-09 Cursor metadata projection checkpoint

Native Cursor now shares hex-first/live-overlay/cwd selection with a narrow
metadata projection that also retains losing roots and malformed/type flags.
Actual RED12/60 became native/projection/index52, Service113 and Collector449
GREENs, exit0. Six native replay cases include raw historical main/WAL metadata
that differs from current native cwd; this proves raw custody, not sanitization.
Evidence: output/collector-goal-20260908/cursor-metadata-projection-receipt.json.
No Cursor privacy assessment, runtime admission or source retirement is enabled.
Next: bounded captured-only SQLite metadata reading, conservative recognized-root
privacy proof, reservations/restart, independent delivery and HQ ingest/FTS/Web.
Legacy scoped export/ownership and every real-host/profile/resource/Release/CI /
production transition gate remain open. Retirement remains CLOSED.

## 2026-09-09 Cursor captured-only privacy checkpoint

This supersedes the earlier reader/privacy-pending checkpoints for modern
Cursor only. Verified CAS main/WAL metadata and live meta.json now produce a
capture/policy-bound proof with recognized-root exclusion/conflict and resource
checks. Raw-byte historical residue is not scrubbed. Default policy and Cursor
runtime/HQ admission remain closed. Physical staging retains the caller's
canonical path, avoiding Foundation's /private/var-to-/var alias rewrite without
allowing symlink traversal. Stored/live records both consume the record budget.

Actual final Service124, Collector459 and Archive/Ingest553 passed, exit0.
Original deletion/CAS reopen, WAL-only metadata, member-hash forgery and three
ordinary indexed table shapes are covered. Prior REDs, fixture-only corrections,
Grok finding withdrawal and exact source/log hashes are in
output/collector-goal-20260908/cursor-captured-privacy-receipt.json.

Next: durable dependency snapshot/reservation/restart proof. Paired sessions
reserve transcript as primary, otherwise store.db. Existing publication schema5
reuse is not proven yet. Independent delivery, native HQ ingest/FTS/Web, legacy
scoped export/frozen ownership, actual enabled profiles/hosts and fresh
binary/Release/CI/resource/retirement evidence remain required. Gates stay CLOSED.

## 2026-09-09 Cursor durable reservation checkpoint

Modern Cursor now reserves, reloads and finishes a closed dependency snapshot
using existing publication schema5 rows and schema2 captures. Transcript wins
when paired. Catalog/database reopen and source removal still permit finishing
the saved capture; auxiliary-only replacement is rejected. Unicode byte-distinct
handles cannot reuse the reservation, access/overwrite recovery state, or abandon
it. Final Collector466 and affected Service124 passed, exit0; actual RED466/17,
466/1 and expanded102/6 are retained. Grok review done575 has no remaining finding.
See output/collector-goal-20260908/cursor-reservation-receipt.json.

This supersedes schema5 reuse and sealed reservation/restart uncertainty only.
Synthetic sealed bytes/generations and two pending replica rows do not prove live
Cursor worker delivery or active-journal capture. Discovery-to-snapshot bridging,
runtime admission/retry, independent replicas, HQ ingest/FTS/Web, legacy scoped
export, actual hosts/profiles and current binary/Release/CI/resources remain
required. No source retirement or production transition is authorized by this.

## 2026-09-09 Cursor modern runtime and independent local replica checkpoint

Bounded observation/bootstrap/events now produce transcript-first durable Cursor
snapshots and worker publications. Alias acknowledgement follows durable capture;
auxiliary-only generations retain identity and preserve newer dirty work. Four
generations, including stopped-runtime metadata changes, reached two independent
loopback HTTP replicas with exact bytes. Excluded archived captures survive
source deletion and are published after policy revision/restart. Separate stores
verify idempotent ACKs and reject legacy shared DB/mismatched modern file sets.
Actual recovery RED129/1 led to the minimal uncaptured-primary fallback; durable
unpublished recovery preserves its original epoch/sequence after catalog reopen.
Final Collector471, Service129 and replica47 passed; all command receipts are in
output/collector-goal-20260908/cursor-runtime-receipt.json.

This supersedes modern runtime/local transport uncertainty only. It does not
prove HQ Cursor native replay/commit/FTS/Web, standalone binaries, legacy scoped
export/frozen ownership, real hosts/profiles/natural input, current Release/CI or
resource acceptance. All source-retirement gates remain CLOSED; no operational
transition is authorized by these tests.

## 2026-09-09 Cursor HQ native replay, commit and FTS checkpoint

Explicit modern Cursor source registration, captured-layout native replay and
bound commit now preserve native identity, metadata, timestamp fallback and
main+transcript size. Actual Collector/CAS reopen after original removal reaches
HQ replay; commit tests run persisted-message IndexJobRunner/FTS and verify the
index_ready ledger. Closed schema2 admission continues to refuse legacy shared
DB/mismatched-session layouts. SQLite replay stages preserve existing sealed
directory/member checks. Final Archive/Ingest560 and Service129 pass; native
adapter regressions and actual REDs are recorded in
output/collector-goal-20260908/cursor-hq-native-receipt.json.

This supersedes modern HQ/domain-FTS uncertainty only. Fresh standalone binaries,
rendered Web, legacy scoped export/frozen ownership, remaining enabled profiles,
real host identity/natural inputs/resources, current Release/CI and separately
authorized operational transition remain required. Retirement remains CLOSED.

## Cursor modern binary and rendered-Web checkpoint (2026-09-09)

Supersedes the preceding modern binary/browser-pending checkpoint only. Full
Collector474 and affected Service132 pass; fresh native Collector/Service/Remote
builds and actual CLI/binary35 (34pass/1existing optional skip) pass. Four content
versions traverse both independent loopback replicas and HQ native ingest/FTS.
Repeated event work was reproduced and removed with full dependency fingerprints;
held-open WAL notification gaps were separately reproduced and repaired with
bounded known-capture stat probes. The final stream settled at sequence7 with
four publications and no dirty/reservation/scan work for2s. Reservation sequences
are monotonic, not necessarily consecutive publication counts.

Authenticated rendered Web now proves source-filtered search, latest title,
project, three full messages and no-match clearing. Browser v2 passes1 test,
console0errors/0warnings, stable8 linked artifacts, named-browser close and owned
fixture removal. The first parent's0644 stop-file failure is preserved separately;
v2 obeys the existing0600 control contract. Evidence and all historical failures:
`output/collector-goal-20260908/cursor-binary-web-receipt.json`,
`output/playwright/cursor-browser-receipt.json`, and
`output/playwright/cursor-native-web-v2.png`.

This proves local synthetic modern behavior only. Metadata-invisible mutation,
large-inventory latency, current Release/CI/resource windows, actual enabled roots
and profiles, natural inputs, legacy scoped export/ownership and authorized host
cutover are not established. Every host retirement gate stays CLOSED.

## Cursor legacy raw-row checkpoint (2026-09-09)

Local scoped raw-row extraction now has sixteen cases passing within Collector490
and affected Service132, both zero failures. Exact row ownership, opaque values,
WAL/no-WAL custody, source/private mutation, hidden ROWID and output budgets are
covered by `output/collector-goal-20260908/cursor-legacy-rows-receipt.json`. This
does not establish frozen workspace ownership, legacy Collector publication or
HQ replay. Legacy and all actual-source/host retirement gates remain closed.

## Cursor legacy ownership checkpoint (2026-09-09)

Scoped rows plus coherent frozen workspace cwd now pass twenty-three ownership
cases within Collector513/0 and affected Service132/0. See
`output/collector-goal-20260908/cursor-ownership-receipt.json`. The result is
in-memory only; legacy durable publication, captured-only native replay/FTS/Web,
all actual source profiles/hosts and retirement remain unproved and closed.

## Cursor legacy durable body checkpoint (2026-09-09)

Typed scoped rows, original logical locator/generations and frozen cwd now persist
as canonical bytes and replay through native SQLite without live source reads.
Final Collector514/0, Archive/Ingest569/0, native52/0 and Service133/0 include actual
Collector -> saved file -> deleted User -> CoreRead parity. Evidence:
`output/collector-goal-20260908/cursor-legacybody-receipt.json`.

Legacy manifest/context/CAS admission, discovery/same-ID modern suppression,
scoped revision scheduling, reservation/retry/dual ACK and HQ FTS/Web/binaries
still require implementation and proof. This checkpoint does not establish
transport, real-host resource relief or production retirement. All actual enabled
source/profile/host gates stay CLOSED pending their own current evidence.

## Cursor legacy CAS and HQ checkpoint (2026-09-09)

Explicit schema 6 and Cursor context now bind the canonical scoped body to CAS,
full source generation, frozen cwd and distinct raw/native counts. HQ's sealed
replay, source-root eligibility, commit and FTS index_ready pass; two versions
update one session. Real Collector -> saved body -> deleted User -> CAS -> HQ
parity and independent local replica-store reopen/idempotent ACK are verified.
Final Core590/0, Collector514/0, Service133/0, native52/0 and replica48/0:
`output/collector-goal-20260908/cursor-legacycapture-receipt.json`.

These are local synthetic/module/store tests, not CollectorRuntime HTTP delivery,
real HQ/M1 hosts or rendered Web. Legacy privacy admission, paired-root discovery,
modern same-ID suppression, scoped-content revisions/reservations/retry, actual
runtime ACK and fresh binary/Web acceptance remain. Every enabled profile, real
host identity/natural input/resource window and authorized cutover still requires
current evidence. All host retirement gates remain CLOSED.
