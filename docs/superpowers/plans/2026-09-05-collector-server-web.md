# Collector / central Service / Web implementation plan

**Date:** 2026-09-05

**Governing design:** [collector-server-web-design](../specs/2026-09-05-collector-server-web-design.md)

**Worktree:** `.worktrees/collector-server-web-20260905`

**Branch / base:** `codex/collector-server-web-20260905` / `625ecc9737c219f401200d3c2e301f537582ff11`

**Status:** W1 `638a8454` and W2 `874a63f1` are pushed in Draft PR #446 with their
own required CI gates passing. W2 Tests `33965852625`, CodeQL `33965852598`, and
dependency review `33965852614` passed for its exact head; nothing is deployed.
Revised design passed the independent B1-B7 closure gate. Independently reviewed
host-role/capture-core, shared wire/socket, and first identity/durable-intake
slices are now locally integrated. The combined Core suite is 1,482 tests/one
existing performance skip/zero failures; combined App is 1,175/0, Service
833/one existing skip/0, MCP 270/0, Collector 9/0 and Remote 229/0. Cross-slice
source/target review passed; ten script suites are 190 passed/two existing
conditional skips. The next tranche's pushed-head CI remains pending.
Foundation follow-up: `248e64ab` is now pushed to the same Draft PR, with Tests
`33969590181`, CodeQL `33969590195` and dependency review `33969590247` all
passing for that exact SHA. The earlier pending statement above describes its
local checkpoint. These are foundations, not full W3-W6 completion.
The next local tranche is now integrated and independently approved: C1
generation/format-bound privacy and read-only machine identity, source/epoch/
parse-format registry, pure normalized-message continuation and typed client,
and optional-AI readiness/shutdown isolation. Its six full targets passed:
Core 1,521 and Service 858 (one existing skip each), App 1,175, MCP 270,
Remote 247 and Collector 35, all zero failures and producer exits 0.
Ten script suites passed 190/two existing conditional skips; invariant and
adapter-fixture checks passed. Logs are `/tmp/engram-w4-foundations-*-integrated.log`
with exact per-gate paths in CHANGELOG. This supersedes the earlier local
pending-suite statements; this tranche's new-head CI is still pending.
Inventory, bounded CAS/replay and real Web IPC remain separate next-wave work.
CI correction checkpoint: that tranche is pushed as `745de11d`. Tests
`33996341619` failed its existing macOS flock-retention fixture; Node quality,
Swift unit, Remote/package and UI smoke passed. The precise original CI race
is not attributed, but three new real-Popen TERM/INT/HUP repros proved a startup
lock-release gap before a minimal fix. The fixture now uses explicit shutdown
handshakes. HQ 12/12, four signal tests repeated 12 times, ten script suites
195/195, test typecheck, targeted Biome and diff checks passed locally. The
independent source/log gate passed; correction-head CI is pending. CAS/inventory/replay/Web
integration is excluded from this CI-fix commit. Detailed logs are in CHANGELOG.
Follow-up checkpoint (2026-09-06): correction `1660734` now has successful Tests,
CodeQL and dependency review. The next local bounded-CAS/Web-IPC/inventory/builder
tranche is integrated and independently reviewed. Coordinator focused results
are CAS Core 23/0, IPC+continuation 31/0, full Collector 68/0, and builder+legacy
indexer 127/0, all producer exits 0. New full combined gates and next-head CI are
pending. Replay donor 17+23 tests pass. Follow-up: Replay5's independent bounded
gate passed and all five files are now integrated by frozen SHA. The first full
combined Core run is 1,566/one existing performance skip/zero failures, producer
56778 exit 0; remaining combined targets and new-head CI are still pending.
The Web GET Origin rule is corrected in design section 5 using official Fetch
rules and a real Chrome 152 loopback probe; this is not implemented HTTP/browser
acceptance. Detailed source/log evidence and remaining work are in CHANGELOG.
Final local checkpoint: all six central targets passed with this tranche:
Core 1,566 and Service 875 (one existing skip each), App 1,175, MCP 270,
Remote 247, Collector 74, all zero failures and producer exits 0. The final
Collector count includes lexical-root and byte-exact Unicode binding RED/GREEN
corrections, independently reviewed. Ten script suites passed 205/two existing
conditional skips; invariants and safety checks passed. These results supersede
the preceding pending combined-suite checkpoints; new-head CI is still pending.
POSIX enumeration, claim state transitions and HTTP auth remain separate donor
candidates, not part of the verified central runtime or full W3-W6 acceptance.
Push follow-up: that completed tranche is `09de6304`; its Tests `34001362091`
and dependency review `34001362277` passed. CodeQL `34001362241` is still running
at 08:44 CST. The next candidate now has POSIX enumeration integrated (central
Collector 107/0) and independently approved T1 work leases integrated by SHA
(donor 44/0 plus 20 successful concurrency repetitions). The held-DIR entry
cancellation follow-up is donor 108/0, awaiting its independent gate/integration.
Web auth is donor 45/0 after a compile-only HTTP field alias correction, awaiting
review/integration. Central full Core is running; no new combined-suite or
end-to-end success is claimed. T2 atomic parsed/snapshot commit, runtime wiring,
FSEvents, upload queues, HTTP read routes, UI and W6 remain separate next work.
The entry-cancellation gate subsequently passed and the frozen pair is now
integrated: central Collector 108/0, producer 19173 exit 0. The new full central
Core is 1,596/one existing skip/0, producer 23643 exit 0; Service is 875/one
existing skip/0, producer 58632 exit 0. App and the remaining combined gates are
still pending. Exact logs are in CHANGELOG; these are not full W3-W6 results.
Final candidate checkpoint: independently reviewed Web auth is integrated by
seven exact hashes. All six central targets passed: Core 1,596 and Service 875
(one existing skip each), App 1,175, MCP 270, Collector 108, Remote 292, zero
failures and actual producer exits 0. Final ten-script rerun is 205/two existing
conditional skips; typecheck and five invariants pass. The initial Remote
executable-scheme selection executed zero tests and is recorded separately from
the corrected Core run. Integration-seam review and prior-head CodeQL remain
pending. Donor-only N1/T2/A4 RED drafts are excluded from this candidate.
The prior-head gate subsequently completed: `09de6304` Tests `34001362091`,
CodeQL `34001362241` and dependency review `34001362277` are all successful.
The current candidate still awaits its integration-seam gate and new-head CI.
The integration-seam gate then passed SPEC PASS / QUALITY APPROVED and verified
all 15 staged implementation/routing hashes unchanged; pinned project drift
passed. The 19-file candidate (including four records) is ready for the
authorized normal commit/push. New-head CI and full W3-W6 remain pending.
Push follow-up: this candidate is `1523487bbea97837043ada1ae6a3603157bb98c5`.
Its Tests `34003169069` and dependency review `34003169052` passed; CodeQL
`34003169055` is still running at 09:19 CST. Donor N1 complete Collector RED
executed 124 tests with 52 failures, including ten independent old-API
Unicode owner-fence assertions. A4's 49-test HTTP draft is reviewed and its
project regenerated; actual RED is next. Neither donor is integrated or
GREEN-verified, and T2 remains test preparation. Exact evidence is in CHANGELOG.
Subsequent donor gates: N1 full Collector passed 126/126 and awaits independent
review/integration. A4 focused HTTP passed 49/49 after a one-line fixture cut
correction; its first full 341 run has one pre-existing firmlink fixture/home
setup error and is being rerun with a verified workspace-local isolated home.
T2 corrected RED is 45/100 assertions/zero unexpected failures with all 44
old ledger/claim tests passing; its GREEN is in progress. These supersede
the earlier donor-preparation state, not the remaining W3-W6/runtime gaps.
At 09:43 CST the exact `1523487b` Tests, CodeQL and dependency review all
passed. N1 then passed independent SPEC/QUALITY gates, was integrated by
exact two-file hashes, and passed the coordinator's complete Collector
126/126 run (producer 48671 exit 0). A4's workspace-home full rerun passed
341/341, including the previously failing firmlink test; its independent
gate/integration are pending. T2's frozen 89-test GREEN is running. N2 is
limited to owner/enrollment tests and fail-closed scaffolds; no runtime or
end-to-end readiness is implied. See the newest CHANGELOG evidence entry.
A4 subsequently passed its independent two gates and exact four-file central
integration; the coordinator's full Remote Core run passed 341/341. T2's
donor GREEN passed 89/89, but its history materialization now has a test-first
bounded-result follow-up before review/integration. Central archive safety,
typecheck and five invariant gates pass; these do not cover later T2 changes.
Prepare a bounded N1+A4 commit now, excluding all donor T2/N2 changes.
Its two affected full targets pass centrally (Collector 126, Remote 341),
as do ten script suites (205/two existing conditional skips), typecheck,
archive safety and five invariants. The four unchanged Core/Service/App/MCP
targets are not rerun for this candidate. Combination/routing review and
staged project drift precede commit/push; new-head CI remains separate.
The combination/routing gate passed SPEC PASS / QUALITY APPROVED; the
coordinator also verified all seven staged source/routing hashes against
the worktree and passed pinned staged project drift. The eleven-file N1+A4
candidate is ready for authorized commit/push, with new-head CI pending.
This candidate was then committed/pushed as `9fd6db26d9d02fc77f3e0a5918b4cd831d6b36d3`;
Draft PR #446 remains open/unmerged. Its Tests `34005267338`, CodeQL
`34005267336` and dependency review `34005267340` are in progress. The
post-commit project-drift tests passed 10/10. T2's two added history tests
are awaiting RED, with its production files still frozen; N2 remains prep.
At 10:12 CST the exact-head Tests and dependency review passed; CodeQL
remained running. T2's added tests captured bounded-history RED, then the
minimal aggregate passed all 91 focused tests; independent review and
central integration remain pending. N2's 155-test RED preserved all old
126 passes, and one additive physical-alias test captured three intended
rejection failures after all real firmlink positive controls passed.
Only its two owner/POSIX production files are now allowed GREEN edits;
all 30 tests and routing remain frozen. A5a is DTO/test preparation only.
T2 then passed independent SPEC PASS / QUALITY APPROVED and exact four-file
central integration. Pinned XcodeGen generated only eight new project lines;
the full Core producer 15387 is running. Service/App/MCP combined gates
remain pending. T3a prepares only three new data-layer files and tests;
runtime/provider integration stays separate. First Web transcript authority
requires parsed/ready/current metadata to identify the same generation.
The central T2 full-target gates then passed: Core 1,643 and Service 875
(one existing skip each), App 1,175, MCP 270, all zero failures and actual
producer exits 0. The App scheme also reran the complete Core suite; this
is not another distinct set of tests. Ten scripts passed 205/two existing
conditional skips; typecheck/archive safety/five invariants passed. Remote
and Collector source is unchanged and their full suites were not rerun.
At 10:32 CST the prior-head CodeQL product gate still runs; next push waits.
A5a/T3a workers reported usage limits; their incomplete donor drafts are
preserved and excluded. N2 remains donor-only; the coordinator continues.
The final nine-path central integration/record gate then passed SPEC PASS /
QUALITY APPROVED. The coordinator verified prior-head `9fd6db26` CodeQL
success (Gate completed 10:33:35 CST), completing all three workflows for
that immutable SHA. Prepare the authorized T2 commit/push; its new-head CI
is still separate and pending. N2/T3a/A5a remain excluded.
T2 was then committed/pushed as `e94c05004aa9739ef54291d813fa1d8cee7815e4`.
Draft PR #446 remains open/unmerged; Tests `34007018809`, CodeQL
`34007018811` and dependency review `34007018820` started at 10:39 CST.
No new-head pass is claimed. N2 and the two quota-interrupted worker drafts
remain donor-only; the coordinator continues the unfinished W3-W6 plan.
At 11:03 CST, exact T2 head `e94c0500` Tests and dependency review have
succeeded; both CodeQL Swift builds remain running. N2 donor v3 passed
156/156 with zero failures/skips after two recorded synthetic temporary-
path fixture failures. Only the ordinary fixture initializer changed;
production and all 30 test bodies stayed frozen. Its independent gate and
central integration are pending. T3a now has 34 coordinator-owned draft
tests and unchanged fail-closed scaffolds, syntax parsing only; independent
draft review and executable RED remain pending. Runtime/W3-W6 is not done.
At 11:26 CST the exact T2 head has successful Tests, CodeQL and dependency
review. N2 passed its independent implementation gates and frozen-source
central integration; pinned project generation added only eight Owner lines.
The coordinator's complete central Collector suite passed 156/156, zero
failures/skips, producer 64757 exit 0. Ten scripts passed 205/two existing
conditional skips; typecheck/archive safety/five invariants passed. The five
unchanged full product targets were not rerun for this Collector-only slice.
Final routing/record review, staged project drift and new-head CI are pending.
T3a donor captured genuine 129-test RED, then passed 129/129 GREEN after
independently adjudicated corrections to two user-only skip fixtures; all
stale-job/last-good assertions and production hashes stayed unchanged. Its
implementation gate/integration remain pending and it is excluded from N2.
N3-A prepares additive Owner event-entry tests/scaffolds only in its donor;
A5a remains an interrupted draft. No full W3-W6/runtime/browser pass is implied.
The final N2 central integration/record gate passed SPEC PASS / QUALITY
APPROVED. Exactly ten approved paths are staged and pinned staged project
drift passed; pre-existing SQLite sidecars are excluded. Prepare the
authorized N2 commit/push; its new-head CI remains separately pending.
N2 is now pushed as `4216479b80dd3043e912d0f2aeb73f23a2f002cc` in the
same draft/open/unmerged PR. At 11:44 CST dependency review `34009528240`
passed; Tests `34009528242` and CodeQL `34009528232` remain in progress.
T3a passed its independent implementation/evidence gates and exact three-
file central integration; pinned generation added twelve project lines,
project.yml unchanged. The coordinator started complete central Core tests;
Service/App/MCP are pending. A5a now has 31 metadata tests plus the old 18,
DTO scaffolds and three unsupported client stubs, syntax parsing only;
test-draft review/RED are pending. N3-A remains tests/scaffolds only.
The T3a central complete gates then passed: Core 1,681 and Service 875
(one existing skip each), App 1,175, MCP 270, zero failures and producer
exits 0. Ten scripts passed 205/two existing conditional skips; typecheck,
archive safety and five invariants passed. The unchanged Collector/Remote
full suites were not rerun. Final integration/record gate and staged drift
remain pending. At 11:55 CST prior `4216479b` Tests and dependency review
passed while CodeQL still runs. A5a's 49-test draft passed independent
review and its first RED build is running; N3-A has 13 additive tests and
fail-closed event-entry scaffolds, pending independent draft review.
A5a subsequently captured corrected 49-test RED (27 failed cases) after
one test-only compile correction, then passed 49/49 GREEN with frozen
tests. Its full Remote and independent implementation/integration gates
remain pending; it is excluded from T3a. N3-A passed its independent
test-draft gates and is authorized for executable RED only, not GREEN.
The final T3a central eight-path integration/record gate returned SPEC PASS /
QUALITY APPROVED at 12:10 CST. The coordinator is staging only those paths
for pinned project drift; prior-head CodeQL and new-head CI remain pending.
The coordinator then verified staged source/routing hashes and passed pinned
staged drift. Exact prior `4216479b` now has successful Tests, dependency
review and CodeQL (Gate completed 12:11:58 CST). Prepare the authorized
eight-path T3a commit/push; its new-head CI remains separate. A5a complete
donor Remote passed 372/372 and awaits independent implementation review.
N3-A corrected full RED passed all old 156 and failed only the 13 new cases;
prior compile/Unicode fixture failures are retained. Only its Owner is
authorized GREEN; tests and other source/routing remain frozen.
T3a is now pushed as `f683ff71e7e555956b4854c21174090d72981df2` in the
same draft/open/unmerged PR. At 12:28 CST dependency review `34011185046`
passed; Tests `34011185057` and CodeQL `34011185083` still run. A5a and
N3-A passed independent implementation gates, then exact five-file central
integration without routing changes. A5a complete donor and central Remote
both passed 372/372 with zero failures/skips and actual producer exits 0.
N3-A donor GREEN passed all 169 after corrected RED v3 failed only the new
13 and preserved old 156. Central Service is running; App/MCP/Collector and
combined record/integration gates remain pending. T3b FTS consumer and N3-B
native events are read-only proposals, not implemented runtime or W6 proof.
CI priority checkpoint: exact `f683ff71` Tests `34011185057` failed Swift
unit/UI smoke compilation on Xcode 16.4 in the same readiness fixture helper;
no assertions ran. Node, scripts/fixtures and Remote/package passed. The
independently approved correction adds only an explicit nonoptional array
type to that helper; all 38 bodies/default values and production/workflow
files stay unchanged. Complete corrected local Core and correction-head CI
are pending; local Xcode-beta is not Xcode 16.4 evidence. The correction
commit excludes the five A5a/N3-A files. Those local combined targets now
pass Remote 372, Service 875 (one skip), App 1,175, MCP 270 and Collector
169, zero failures and producer exits 0; App also reran Core 1,681 (one
skip). Scripts are 207/207, typecheck/safety/invariants pass. Their own
integration gate/commit/CI remain separate; T3b/N3-B proposals pause for CI.
The corrected complete local Core then passed 1,681/one existing skip/zero
failures, producer 97659 exit 0 at 12:39:10 CST. Byte comparison proves
all 38 test bodies/default values unchanged; only the array annotation
differs. Final five-path correction review/commit/push and new Xcode 16.4
CI remain pending. A5a/N3-A source stays excluded from that correction.
The five-path correction then passed its final independent SPEC PASS / QUALITY
APPROVED gate at 12:42 CST and pinned staged drift. Normal commit/push both
exited 0, creating `5995ad66bad8d827f311dd04fef81f287a4d70be`. At 12:48 CST
Draft PR #446 stayed open/unmerged; dependency review `34012392885` passed,
Tests `34012392893` ran and CodeQL `34012392888` queued. All five A5a/N3-A
feature files remain uncommitted and byte-identical to approved donor versions;
their full combined local gates above passed, but their final integration/record
gate is pending. Their push must wait for all correction-head CI to pass.
N3-B1 fake-stream recovery and T3b capture FTS remain separate proposals;
neither native watch nor real Service/Web integration is claimed complete.
Tests `34012392893` subsequently passed Swift unit/UI smoke and CI Gate;
its full Xcode 16.4 Swift log independently confirms readiness 38/38 and
Core 1,681/one existing skip/zero failures. See
`/tmp/engram-5995-swift-unit-ci.log`. Swift CodeQL remains pending, so the
feature push is still gated independently from successful Tests.
That correction-head gate then completed: `5995ad66` Tests `34012392893`,
CodeQL `34012392888` and dependency review `34012392885` all succeeded.
A5a/N3-A independently passed the final nine-path integration/record gate;
frozen five-file hashes, index equality and diff checks passed. It is normally
committed/pushed as `8a53174b182baba1c2d671dcc6b42dfdd3eaf408`, with both
producers exiting 0. New dependency review `34013832384` passed, while
Tests `34013832379` and CodeQL `34013832367` are pending. N3-B1's two-file
fake-stream draft independently passed; root routed the donor project for
executable RED, not GREEN/native watch acceptance. T3b's separate 35-test
draft is under review. Neither draft is in the pushed feature SHA; full
W3-W6 runtime, upload and Web reader acceptance remains incomplete.
Later live verification confirms `8a53174b` Tests `34013832379` and dependency
review `34013832384` succeeded; CodeQL `34013832367` remains in progress.
N3-B1 now has executable 27-test RED/GREEN and full donor Collector 196/196
with zero skips/failures/runtime warnings. Independent implementation review
and central integration are pending; no native FSEvents evidence is implied.
T3b's initial 35/35 GREEN was followed by a 1,703-test Core run with two stale
Round5 scanner failures. Their minimal assertion-range correction passed all
36 Round5 tests in a subsequent 74-test run; all three newly added authority
regressions failed as expected (inside-writer policy revocation and absent/
revoked epoch history). The corresponding narrow fix is under GREEN/re-review.
A5b remains an unmounted donor draft being strengthened before executable RED.
These donor-only results do not close full W3-W6 or change W7 authority.
CodeQL `34013832367` then succeeded (Gate 06:05:08 UTC), completing all
three CI workflows for exact `8a53174b`. The coordinator independently passed
the N3-B1 implementation gate and integrated its two frozen source/test hashes,
one dependency-source assertion and generated routing. Central Collector
passed 196/196 with no skips, failures or runtime warnings; scripts passed
205/two dirty-project conditional skips and typecheck/safety/invariants passed.
The isolated nine-path N3-B1 integration/record candidate still awaits pinned
staged drift, final review, commit/push and new-head CI. No native stream exists
in this slice. T3b's donor full Core passed 1,706/one skip before independent
review found further sibling-registry/tier eligibility gaps; four new cases
have real RED and remain excluded from the N3-B1 candidate. A5b stays donor-only.
N3-B1 pinned staged drift v2 now passes: the first run regenerated non-pinned
project drift, and the final project differs from HEAD only by eight added
Coordinator source/test references. Final review/commit/push remain pending.
The owner authorized committing/pushing W1, running CI, then autonomous staged
implementation/review/CI through W6 on 2026-09-05. Production W7, credentials,
network changes, and merge/release remain separate authority boundaries.

## Execution rules

- Coordinator owns this plan, design, integration routing, and CHANGELOG/MEMO.
  Workers own explicit files. Never overwrite another worker or another worktree.
- Every behavioral fix needs captured RED then GREEN; independent review maps
  acceptance criteria to actual diff/tests, not worker self-report.
- At most three independent workers. Serialize heavy Xcode builds with jobs 2
  or less; use isolated temporary homes/data and identified DerivedData. Do not
  run production helpers, local Docker, provider requests, or broad filesystem
  inventories in tests.
- Preserve complete build/test logs and producer exits. Infrastructure failure
  is not RED; skipped tests are not PASS. Coordinator runs `git diff --check` and
  the appropriate product-boundary tests before each local closeout.
- Feature/network paths remain default OFF. A green implementation gate does
  not grant operational authority. Stop at exact authority boundaries.
- Independent next-wave work may proceed while an immutable prior head runs
  CI; the next push waits for the prior-head gate. Prior-head failures take
  priority, and evidence for one SHA never characterizes another. This replaces
  the coordinator's initial idle-wait sequencing, not any test, review, or
  production-authority requirement.
- The host-role worker uses `.worktrees/collector-host-role-20260905` so its
  App/MCP/Core edits and regenerated project cannot enter the W2 receiver
  tranche. Integrate that bounded diff only after its RED/GREEN and independent
  gate; regenerate the combined project from `project.yml`. Both worktrees
  still share the serialized heavy-build budget.
- Capture-core extraction uses `.worktrees/collector-capture-core-20260905`;
  shared socket/wire extraction uses `.worktrees/collector-web-ipc-20260905`.
  Each has bounded source ownership and its own generated project. Their diffs
  enter the main implementation branch only after independent gates, followed
  by combined project regeneration. They never alter W2's frozen test inputs.

## Dependency order and parallel lanes

| Wave | Work | Dependency | Can run alongside |
|---|---|---|---|
| W1 | Hot query and App ownership fixes; freeze full design | Current source evidence | Each other; coordinator design |
| W2 | Publication/ACK/journal wire contract and receiver | Reviewed design | Headless packaging dry-run work; Web facade contracts |
| W3 | No-index collector, privacy proof, inventory and two-replica uploader | W2 fixtures/API | HQ ingest implementation using same fixtures |
| W4 | HQ ingest ledger/replay/identity and independent readiness | W2; W3 fixtures | Additional source exporters; Web implementation |
| W5 | Read-only Web reader and optional native module | W4 read contracts | Packaging and source coverage |
| W6 | Integrated shadow verification, complete source coverage, resource tests | W3-W5 plus packages | Independent security and operational review |
| W7 | Separately authorized one-host cutover and natural observation | W6 PASS plus owner transaction | No unrelated operations |

W2-W5 may have fixture-backed parallel development, but may not claim an
end-to-end pass until their real integrations run together. No worker edits
`project.yml` or shared DTO ownership without coordinator coordination.

## W1 — remove measured blockers without claiming collector completion

### W1-A: bounded session embedding selection

Owner: query worker. Files: `macos/EngramCoreWrite/Indexing/InsightEmbeddingBackfill.swift`
and `macos/EngramCoreTests/AI/InsightEmbeddingBackfillTests.swift` only.

Acceptance:

1. Real production query fails a deterministic SQLite VM-step budget on the old
   implementation with many pending jobs/unrelated FTS rows, then passes.
2. Pending-before-retry/retry-count/creation/id ordering, nonempty text,
   hidden/skip/lite exclusion, complete ordered text, duplicate/NULL handling,
   and zero/negative/positive limits remain compatible.
3. No schema migration/index, dependency, or unrelated Runner change.
4. Focused Core tests and independent diff review pass; full Core suite follows.

### W1-B: external service connection-only lifecycle

Owner: lifecycle worker. Files: `macos/Engram/Core/EngramServiceLauncher.swift`
and `macos/EngramTests/EngramServiceLauncherTests.swift` only.

Acceptance:

1. An actually adopted Unix-socket service receives no shutdown after App quit,
   failed health probes, or manual reconnect; its runtime secret remains intact.
2. No replacement process/lock takeover is attempted, including a suspended
   health probe that resumes after quit/cancellation.
3. External recovery reconnects; unavailable status is honest.
4. App-owned shutdown, stderr drain, writer-lock conflict, timeout, and restart
   budget tests retain coverage. Remove only orphaned code created by this change.
5. Focused launcher behavior tests and independent review pass.

### W1-C: review and next-wave readiness

Coordinator checks the exact current diff and logs. A separate read-only worker
reviews this design/plan for unsafe privacy, protocol, identity, pagination,
capability, and cutover assumptions. Blocking findings are resolved in the
design before assigning cross-component production changes.

**Not included in W1 completion:** collector binary, new wire protocol, HQ ingest,
Web UI, changes to actual launchd/config/Keychain, or performance claims on the
installed build. Record those as remaining, not as implied work.

## W2 — freeze and implement durable publication intake

Scope: narrow ArchiveV2 wire models plus RemoteServer store/routes/tests;
coordinator owns target source lists. Preserve old canonical schema-1 bytes.

1. Write compatibility and negative fixtures for a separately versioned
   publication referencing an existing manifest; agree exact endpoints, bounded
   payload/page sizes, conflict/error/status codes, and server capability check
   from the design's W2 intake contract. Do not invent another wire shape.
2. Implement per-replica durable acceptance and a restart-safe arrival journal.
   Verify referenced content before ACK, and test every crash boundary that
   could separate acknowledgement from later discoverability.
3. Test sequence conflicts, epoch policy, two independent server identities,
   missing/corrupt chunks, retransmission, unavailable old servers, and no DELETE.
4. Preserve all bound receipt/recovery/reclamation and archive MCP tests.

Gate: Remote Core full suite; canonical golden comparison; independent protocol
and safety review. A bare `putManifest` 2xx is not enough.

Local checkpoint (2026-09-05 19:56 CST): the coordinator independently ran the
final-built full Remote XCTest bundle in an isolated test home: 229/0, no skips,
producer exit 0, `/tmp/engram-w2-remote-full.log`. This includes all legacy
archive/recovery/MCP paths and the new publication models/config/routes/store.
The first combined attempt's child-test timeout was corrected only in its
inherited XCTest coordination environment; the real independent-process ACK
recovery assertion remains and passes. Final read-only Store/Codec review checked
the exact four-file hashes and logs and returned PASS / APPROVED at approximately
20:00 CST. The model gate separately passed; coordinator source/HTTP/full-suite
checks cover routes and opt-in integration. W2 PR CI is pending.

Final integration checkpoint (20:14 CST): unchanged no-delete gates required
the existing temporary-file naming convention and reuse of ArchiveRoutes'
enumerated auth-to-405 guard. The actual routing test disproved wildcard method
fallback; three exact publication paths now use that same guard, with all
401/405 assertions retained. Final full Xcode Remote build/test is 229/0,
no skips, producer 0 (`/tmp/engram-w2-remote-final3.log`); nine script suites are
143 passed/two dirty-project conditional skips. Prior failures remain recorded
in CHANGELOG rather than being relabeled as success.

## W3 — genuine no-index collector

Scope: native collector target and narrow reusable capture code, tests, packaging
source list by coordinator. No direct product-index writer dependencies.

1. Start with Claude/Codex exact files and a minimal generation-bound metadata
   privacy proof; fail closed for unknown/excluded/ambiguous roots. Use the frozen
   parser projection and conservative conflict policy. Provision an independent
   shadow catalog with the existing machine UUID; never share its writer with
   the live Service catalog.
2. Add durable root inventory and dirty queue, resumable bootstrap, FSEvents
   reconciliation, stable capture, byte/file/concurrency budgets, and disk-pressure
   status. Do not replace an O(N) crawl with an undocumented O(N) crawl.
3. Add persisted epoch/sequence publication allocation and two independent upload
   queues with bounded backoff, idempotency, wrong-ACK rejection and restart tests.
4. Prove launch without App, product DB, FTS tables, embedding/config credentials,
   repository scan, or model network access. Capture stats must use correct units.
   Implement persisted host-role gating before App DB open/service spawn, with
   cold/absent-socket, Spotlight-style launch, quit/cancellation and invalid-role
   tests. A launchd-only environment setting does not satisfy this criterion.
5. Build the enabled-source coverage matrix per host. Add replay-proven exporters
   for database/composite/cache sources before retiring their old collector path.
   Treat missing Grok/Pi support as an explicit source decision, not silent loss.

Gate: hermetic capture/upload integration with two local test stores, privacy
adversarial tests, target-dependency guard, restart/overflow/disk-pressure tests.
Actual production source inspection is separate and read-only until authorized.

## W4 — central replay, identity, and ready states

Scope: Service/CoreWrite ingest ledger/replay integration and tests; share the
W2 fixtures. Coordinator serializes schema/Runner/DTO changes.

1. Implement the frozen ImportRepo-based identity encoding, binding/alias table,
   original-locator replay and parent mapping. Prove collisions are quarantined
   and aliases preserve existing insights/user state. Provision source-instance
   maps before legacy receipt bootstrap; do not auto-invent a legacy stream.
2. Implement durable ingest ledger and transaction-safe cursor advancement;
   replay original bytes through existing adapters in confined staging.
3. Preserve last-good generations, reject out-of-order replacement and unknown
   epoch promotion, and classify parse/retry/quarantine distinctly.
4. Add explicit capture/ACK/parse/FTS-ready/AI/freshness read DTOs; do not infer
   readiness from `running`, counts, a healthy socket, or archive durability.
   Freeze and implement IPC message+UTF-8-offset continuation below the encoded
   256 KiB frame ceiling, redacting before fragmentation. Reassemble oversized
   Unicode messages in tests; stale-generation cursors fail explicitly.
5. Bootstrap old receipts with restart-safe dedup and EOF-reset discovery;
   preserve existing remote snapshot and local session behavior.
6. Move optional AI work off required readiness, checking provider/backoff before
   backlog work. Keep bounded maintenance and terminal-failure semantics.
7. Implement read-only epoch-recovery dry-run plus authenticated local operator
   reconciliation with expected-binding checks. Keep unapproved epochs and old
   last-good data without automatic retraction or promotion. Never expose this
   mutation through Web.

Gate: full Core/Service suites, fixture transcript/usage/tier/parent parity,
crash/reorder/namespace tests, direct-writer and migration guards. Demonstrate
capture and keyword-ready when the AI provider is absent or indefinitely failing.

### T3b bounded test-draft contract (not implemented)

The next W4 slice owns only `IndexJobRunner.swift`, `FTSRebuildPolicy.swift`,
new `CaptureIngestIndexJobRunnerTests.swift`, and, if needed, existing policy
tests. The coordinator owns generated test routing. No Service, schema,
Startup, ImportRepo, OffloadRepo, AI, Readiness or NormalizedStore changes.

- Capture ownership is the indexed stored-session binding OR the reserved
  `capture-v1.` authority / `remote:capture-v1.` ID prefix, even if tables or
  bindings are missing. The branch is IF capture-owned THEN capture eligibility
  ELSE legacy eligibility, never IF eligible capture ELSE legacy. Recheck this
  at selection, process entry before skip/offload/locator/adapter access, and
  inside every legacy writer transaction before FTS, completed, not-applicable
  or retry writes. A legacy adapter suspended while ownership becomes capture
  must return without modifying that job or any FTS data.
- One shared SQL predicate governs selection, due count, future backlog and
  finalization. An independent fresh parser/source policy closure defaults OFF;
  it is not derived from available adapters. Missing/disabled/stale authority
  remains unchanged and is not actionable backlog. Capture offloaded rows are
  excluded before BLOB loading and fenced again inside the writer. They never
  enter legacy shadow handling or rematerialize full normalized FTS; the existing
  rebuild copy preserves last-good. Capture-offload support remains incomplete.
- Neither `invalidStoredRecord` nor a size/count error alone authorizes retry.
  Before any retry, reread and compare the frozen job ID/session/kind/version/
  status/retry-count/not-before, generation/required-job identity, identity head,
  registry epoch/authority and session owner/hash/version, under fresh policy.
  Any changed authority defers without mutation. Only a still-current record's
  metadata/payload corruption receives a stable, bounded error code and bounded
  retry/permanent handling; never persist raw error text. DB infrastructure
  errors propagate. Cancellation/deadline never becomes a retry or N/A write.
- A single read-only detached task may load bounded normalized data, with parent
  cancellation forwarded and its value joined; it performs no writes. JSON
  decoding remains bounded but not hard-interruptible. Borrow the parent task
  with `withUnsafeCurrentTask` BEFORE entering synchronous pool.read/pool.write,
  not inside GRDB's GCD callback. The borrowed handle never escapes that call.
  Check cancellation/deadline before and after readiness and subsequent
  embedding/finalize writes so the entire writer transaction rolls back.
- Readiness, optional first-FTS embedding requeue and fresh-policy finalization
  share one writer transaction. Initial skip generations without a job remain
  a later ingest-consumer obligation. A test-only async barrier after load and
  before parent commit exercises policy/epoch/job/head/version/offload races;
  cancellation inside the actual writer must also prove complete rollback.

Required RED groups include real T2 fixtures, default OFF and ON with adapters
empty, reserved/alias/missing bindings or tables, excluded rows without BLOB
delivery, normalized rather than locator text, legacy-to-capture ownership
races, stale-authority versus genuine corruption retries, last-good/rebuild,
future debounce ordering, skip with an actual job and cancellation fences.

## W5 — native read-only Web

Scope: optional RemoteServer Web module/assets/read facade/tests. Shared IPC
read DTO extraction is coordinator-owned and must not link DB writer libraries.

1. Freeze narrow overview/list/search/detail/message-continuation DTOs. Prove
   every non-allowlisted command is rejected before any IPC/token loading.
   W4's real IPC continuation is a prerequisite; HTTP-only fixture pagination
   cannot close full-transcript acceptance.
2. Implement dedicated viewer authentication, short-lived cookie, exact
   Host/Origin/CSRF controls, page/body/time budgets, safe errors and no-store.
   Follow the corrected GET contract: fixed API header, exact Origin when
   present, otherwise all three exact same-origin fetch metadata checks. Present
   invalid Origin never falls back; login/logout still require exact Origin.
3. Implement same-origin static reader with source/machine/project filters and
   safe transcript text. Full content remains pageable even for oversized messages.
4. Test no token/secret leakage and all attempted write methods/routes; preserve
   existing archive/v1/MCP auth contracts.
5. Use browser/render checks on the real test server: login/logout, keyboard,
   empty/stale/error states, long transcript, XSS fixture, and narrow viewport.

Gate: Remote + relevant Service/MCP suites; negative authority tests; browser
acceptance. Production Web remains OFF without approved HTTPS/credential setup.

## W6 — packages, coverage, and shadow integration

1. Build complete role-specific packages with dependency hashes, verify-only and
   dry-run installers; test missing/mismatched framework rejection.
2. In temporary homes run collector -> two independent RemoteServers -> HQ
   Service -> Web with real binary boundaries and synthetic append/rename/crash
   cases. Compare exact bytes, messages, roles, timestamps, usage and tiering.
   Shadow HQ uses a separate product DB/socket; shadow collectors use separate
   CAS/catalogs with explicitly copied machine identity. No live catalog gets
   a second writer, and no shadow row enters the production read corpus.
3. Verify the design's resource/latency targets with declared workload, then
   separately request a bounded real-host shadow transaction. Keep old ingestion.
4. Independently review privacy, authorization, overwrite/order, source coverage,
   old-client compatibility, and operational rollback; fix blockers, not nits.

Gate: all contract tests plus end-to-end browser/read evidence and a source-by-
source retirement checklist. Any enabled unsupported source keeps its old path
and blocks a claim that the host has become fully lightweight.

## W7 — production transaction, separately authorized

Before mutation refresh each host's executable/hash, version, job domain,
PID/start time, socket/listener, config shape (no secrets), source coverage,
backups and rollback pointer. Present exact targets and blast radius to owner.

Deploy compatible receiver first, then HQ ingest, then shadow collector and Web.
Do not alter root plists, credentials, tailnet exposure or watchdogs implicitly.
Cut over one host only after both ACKs and full HQ search/transcript proof.
Observe natural cycles, including the existing watchdog path where applicable.
Do not manually trigger external-message jobs, force-kill uncertain processes,
or reboot for evidence without explicit authority.

Rollback on lost coverage, repeated durable-ACK mismatch, last-good overwrite,
privacy failure, unrecoverable ingest lag, or resource failure. Restore the
identified old role/config with matching checked backup if necessary; preserve
all source bytes, new archives, and ledgers. Stop and report on identity ambiguity.

## Local closeout record

After each implemented tranche, update CHANGELOG/MEMO minimally with actual
changed paths, RED/GREEN and independent gates, complete log paths, skipped
checks, and remaining waves. Do not mark this full plan complete on W1 tests.
