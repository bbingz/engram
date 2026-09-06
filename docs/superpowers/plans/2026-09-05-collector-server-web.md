# Collector / central Service / Web implementation plan

Checkpoint supersession clarification (2026-09-06): this file retains older
append-only entries whose labels say "Latest push/verification checkpoint".
The completed9b Tests/dependency results and integrated A5d central regressions
reported in the top follow-ups supersede those older Tests-pending/no-donor-
central statements, including under Execution rules. CodeQL, final integration
gate/commit and own-head CI remain independently pending; no runtime/full-wave
completion is substituted for these source/test checkpoints.

A5d additional regression: central App/Core2901(one existing skip)/zero failures
and MCP270/270 passed, actual0 producers. Pinned staged drift passed; independent
eight-path integration gate is running, old9b CodeQL still pending. T4a57-test
RED proved12 source gaps; independent trace/history fixture corrections retain
all assertions, and its targeted GREEN is now running. No runtime/fullW3-W6/W7
claim follows; full evidence and warning/skip attribution are in CHANGELOG.

A5d central result follow-up: full Service935 passed/one existing skip/zero
failures, scripts205 passed/two conditional skips, typecheck/safety/invariants
passed with actual0 producers. Final staged gate/commit/own CI are pending;
previous9b CodeQL is running. T4a57-test RED is a separate donor run. No Runner,
browser or full W3-W6/W7 acceptance follows; detailed evidence is in CHANGELOG.

Latest local checkpoint (2026-09-06): correction `9b969a9c` Tests and dependency
review succeeded; CodeQL remains pending. A5d donor full Service passed
924/one existing skip/zero failures and independent source/contract gate;
three matching files plus eight pinned generated references entered central,
whose full Service regression is running. N4a full donor Collector passed279/279
after independently approved fixture-only close/FD correction; source unchanged.
T4a's additive12-test draft passed independent gate; actual57-test RED is next.
All final integration/new-head CI and full W3-W6/W7 limitations remain explicit
in CHANGELOG; no donor-only or running test is counted as central completion.

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
N3-B1 subsequently passed its independent final nine-path integration/record
gate and was normally committed/pushed as `5073f3f8`, both producers exit 0.
Exact-head Tests `34016074877` and dependency review `34016074843` succeeded;
CodeQL `34016074803` remains pending. T3b's supplemental implementation gate
now passed independently after 45/45 GREEN and donor Core 1,713/one skip/zero
failures. The original 35 tests/helpers retain their exact inverse SHA256.
Its four frozen files were integrated; pinned generation adds only four test
references. Central Core 1,726 and Service 875 passed with one existing skip
each, zero failures, and 11/one QoS warnings respectively. Scripts passed
205/two conditional skips; typecheck/safety/invariants passed. App/MCP,
staged drift and final integration/commit/new-head CI remain separate gates.
A5b corrected only two test factory wrappers after a compile-only first attempt;
its real RED v2 passed all old 49 and failed 13 of the 17 new HTTP tests.
Two additive valid-DTO budget tests have passed independent draft review but
await RED; the old metadata-404 stage oracle may only be migrated after RED.
No native/uploader/runtime/browser or full W3-W6 acceptance is implied.
Final T3b combined-gate follow-up: pushed `5073f3f8` now has all three required
workflows successful; CodeQL Gate completed 06:49:03 UTC. Central App v1's
single failure was an obsolete call-string source scanner. Its one-line
correction preserves the skip-tier oracle; App v2 passed 2,901 total/one
existing skip/zero failures/11 QoS warnings, including App 1,175 and the Core
rerun. MCP passed 270/270 with no skips or runtime warnings; actual producers
exited 0. Pinned staged drift v1 passed. The final ten-path integration/record
gate, commit/push and new-head CI remain pending. Unchanged Remote/Collector
full suites are not rerun; browser/runtime/W6 remain unverified. A5b's two
valid-DTO budget tests captured real RED, then its Routes/App-only donor
implementation and one obsolete stage-oracle migration entered focused GREEN
verification. All 19 new tests remain frozen and excluded from T3b.
The final T3b ten-path integration and record/index gates then passed SPEC PASS /
QUALITY APPROVED. Worktree/index bytes, four donor hashes, the scanner-only
change, prior-head CI and pinned staged drift v2 are verified. Prepare the
authorized normal commit/push; new-head CI remains separate and pending.
T3b is now normally committed/pushed as `6a33a42a`, both producers exit 0;
dependency review `34017787161` succeeded while Tests `34017787159` and
CodeQL `34017787170` remain pending. A5b passed the coordinator's independent
implementation gate, donor focused 68/68 and full Remote 391/391, retaining
all 19 new test bytes and the exact inverse of old tests after only authorized
stage-oracle/factory adaptations. Four frozen files are integrated; pinned
generation adds four test references. Central full Remote passed 391/391,
no skips/failures/runtime warnings, actual exit 0. Scripts 205/two conditional
skips and typecheck/safety/invariants pass. Unchanged full targets are not rerun.
Final nine-path integration/record review and staged drift remain pending;
the next push waits for T3b CI. A5c is a read-only metadata producer proposal,
N3-B2 a separate native test draft; no Service/browser/runtime/W3-W6 pass.
The independent final A5b nine-path integration/record gate subsequently passed
SPEC PASS / QUALITY APPROVED, verifying index/worktree equality, frozen hashes,
the old-test inverse and three xcresults/producer exits. Pinned staged drift v1
passed. Exact T3b Tests `34017787159` now succeeded alongside dependency review;
CodeQL `34017787170` still runs, so A5b push waits and new-head CI remains
unverified. No A5c/N3-B2 implementation is included in this candidate.
Exact T3b CodeQL `34017787170` subsequently passed (Gate 07:31:39 UTC), so
all three prior-head workflows succeeded. A5b was normally committed/pushed as
`18c9bc06`, both producer exits 0, after pinned staged drift v2 passed. PR #446
is still Draft/open/unmerged. Its dependency review `34019523987` succeeded;
Tests `34019524050` and CodeQL `34019524056` remain separately pending.
N3-B2 RED v2 passed all old 196 tests and failed all new 58, zero skips/runtime
warnings, actual exit 65. V1 was compile-only; its five mechanical test fixes
preserve all behavioral assertions. The native source alone may enter GREEN.
A5c amended acceptance is below; only a two-file test draft is authorized,
with 15 previously verified ingest foundations synchronized to its donor.
Exact A5b Tests `34019524050` subsequently passed (CI Gate 07:45:31 UTC);
CodeQL `34019524056` remains pending. N3-B2 source passed its independent
implementation gate and full donor Collector 254/254, actual exit 0. A separate
real temporary-root smoke passed 1/1 after two retained fixture failures:
coalesced directory setup events intentionally require reconciliation; an
observed setup callback followed by FlushSync/drain fences the ordinary append.
The basic Unicode fixture makes no NFC-preservation assumption. Full donor
Collector with the smoke passed 255/255, actual exit 0; the focused smoke has
one setup semaphore QoS warning. Source/58 tests remain unchanged. Supplemental
smoke/routing review and central integration are pending. A5c initial draft
failed independent test-design gates; nine bounded corrections precede actual
RED and SQL implementation. Detailed evidence remains in CHANGELOG.
The owner authorized committing/pushing W1, running CI, then autonomous staged
implementation/review/CI through W6 on 2026-09-05. Production W7, credentials,
network changes, and merge/release remain separate authority boundaries.

## Execution rules

Latest push/verification checkpoint: CI correction is pushed as `9b969a9c`,
Draft/open/unmerged PR #446; new dependency review passed, Tests/CodeQL pending.
A5d focused GREEN is 23/23, full donor Service running. N4a full GREEN is not
accepted: 276/279, three diagnostic failures occur on original-connection reuse
after main-file tampering, after successful rollback proofs; a test-contract
adjudication is pending. T4a source type correction is frozen and additive
full-binding/post-claim fence regressions are being drafted before correction.
No donor feature is central and no full W3-W6/W7 result is implied; see CHANGELOG.

Final correction gate: independent exact-five-path index/record review passed
SPEC PASS / QUALITY APPROVED, inverse one-token proof and producer/test hashes
unchanged from the corrected verification above. Normal corrective commit/push
is next; new-head CI remains mandatory and no donor feature enters this patch.

CI correction checkpoint: exact `010a2c5d` Tests failed at Xcode 16.4 test-helper
generic inference, before executable tests. Independent review approved only
the explicit self.records qualifier; all 38 test bodies/fixtures/assertions
and production bytes remain unchanged. Corrected central full Service passed
912/one existing skip/zero failures, one existing reader QoS warning, actual
exit 0. Five-path correction final gate, normal commit/push and authoritative
fixed-head 16.4 CI are next; no T4a/N4a/A5d donor source enters this correction.
A5d RED v1 is verified (4 pass/19 fail, zero skips/warnings); only its extension
source entered GREEN, with execution/full Service still pending. See CHANGELOG.

Push/RED checkpoint: A5c is normally committed/pushed as exact `010a2c5d`,
Draft/open/unmerged PR #446; its three new CI workflows are pending. T4a v5
is accepted behavioral RED (45 total, 2 pass/43 fail, no skips/warnings), now
source-only GREEN. N4a independent draft gate and full Collector RED v2 passed
the progression gate (old 255 pass/new 24 notImplemented failures, one existing
native smoke QoS warning); only Owner source enters GREEN. A5d's independent
23-test draft gate passed and coordinator-owned RED v1 is running, not GREEN.
Exact hashes, compile-only corrections, logs and exits are in CHANGELOG.
No next-slice donor files are central; runtime/full W3-W6/W7 remains incomplete.

Final A5c checkpoint: seven-path independent staged integration/record review
passed SPEC PASS / QUALITY APPROVED, frozen source/test hashes unchanged and
pinned staged drift passed. Root refreshed all three successful workflows on
prior head `843d0038`; Draft/open/unmerged PR #446 is unchanged. Normal commit/
push is next and new-head CI remains unverified. T4a executable RED v3/v4 was
fixture-contaminated; import/canonical temporary-root-only corrections are
under RED v5, not GREEN authority. N4a/A5d remain TEST-DRAFT. Details and
nonblocking warnings are recorded in CHANGELOG; no W3-W6/W7 completion claim.

Latest integration checkpoint: A5c independent SPEC/QUALITY passed; exact
2aeb1355/5c7a3843 source/tests are central, with eight pinned-generator PBX adds.
Central full Service passed 912 with one existing opt-in skip and zero failures
(one reader QoS warning); donor v2 separately passed 901/one skip after exact
central old-scanner synchronization. Ten script suites passed 205/two conditional
skips; typecheck/safety/invariants passed. Final staged/integration gate and
new-head CI are pending. T4a final 45-test draft is executing RED; N4a and A5d
remain TEST-DRAFT only. Runner/browser/full W3-W6/W7 remain unverified.

Latest supersession: A5c full-byte NUL fixture and explicit snapshot-close
defects have independent failing evidence; focused GREEN v4 is 38/38, zero
skips/runtimeWarnings, actual exit 0 and no raw NULL/misuse SQLite logs.
Full donor Service and independent source/spec review are pending. T4a second
draft still failed root's complete gate and remains correction-only. N4a's
amended Owner-only queue-free fence passed feasibility; its accepted contract
below authorizes TEST-DRAFT only. Central source remains at `843d0038`.

Latest checkpoint: exact `843d0038` Tests, dependency review and CodeQL all
succeeded; PR #446 stays Draft/open/unmerged. A5c source GREEN v1 was compile-only
failure; minimal argument-array correction is under GREEN v2 with all 37 test
bytes unchanged. T4a initial test draft failed the independent gate and remains
draft correction, not RED. N4a Owner claim facade is only a proposed contract.
These states supersede earlier pending checkpoints; no full W3-W6/W7 claim.

A5c RED checkpoint: corrected two-file draft passed root independent complete
review; 37 tests are frozen at SHA256 2d535a3ee7a381cfe069c2d9b7c2d53dee860b68a5d7e2ddc6d31072f17aa41a.
The first compile-only failure was missing donor bounded-CAS baseline, fixed
by copying existing central bytes with A5c hashes unchanged. RED v2 executed
37 tests, five passed/32 failed/zero skips or runtime warnings, command session
16960 exit 65. Only producer source now has GREEN authority; handler/Runner,
browser and complete W3-W6/W7 remain excluded. Detailed evidence is in CHANGELOG.

Push follow-up: N3-B2 is normally committed/pushed as
`843d00384ee93a99ced8942e66a511fc7e920f3d`, both command exits 0; staged drift
v2 passed. PR #446 remains Draft/open/unmerged. New dependency review
`34024026926` passed; Tests `34024026924` and CodeQL `34024026923` are running.
A5c remains test-draft correction. Proposed T4a owns only one claim -> real CAS
replay -> parsed commit step and cancel/stop join; acceptance/implementation
are pending. Initial skip/no-job readiness and restart recovery remain T4b,
not a completed runtime or full W3-W6/W7 result.

Final N3-B2 gate follow-up: independent ten-path index/record/source review
passed SPEC PASS / QUALITY APPROVED with six hashes unchanged; pinned staged
drift v1 passed. Normal commit/push and new-head CI are next. Historical
"producer 34387" means execution command session (exit 0), not OS PID; the
central log identifies xcodebuild PID 16425. No test was rerun for this wording
clarification, and all runtime/W3-W6/W7 exclusions remain unchanged.

Checkpoint supersession (2026-09-06): exact A5b `18c9bc06` has successful
Tests `34019524050`, CodeQL `34019524056` and dependency review `34019523987`.
N3-B2 supplemental independent smoke/routing review passed; six frozen
implementation/routing files are integrated, including minimal pinned project
generation. Central Collector passed 255/255 with zero failures/skips and one
retained setup QoS warning, actual producer 34387 exit 0. Ten script suites
passed 205/two existing conditional skips; typecheck, archive safety and all
five invariants passed. Logs are in the newest CHANGELOG entry. The ten-path
candidate awaits staged drift, final independent index/record review,
commit/push and new-head CI. Unchanged App/Core/Service/MCP/Remote suites were
not rerun for this Collector-only slice. A5c's two-file draft correction is
now owned by the bounded Web worker before independent review and executable
RED; SQL implementation remains closed. No full W3-W6 or W7 claim is added.

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

### N3-B2 native adapter draft contract

This next slice owns only new `CollectorNativeEventStream.swift` and its tests.
Coordinator/Owner/Store and old tests remain frozen; the coordinator owns
framework/project routing and the exact additional dependency-source assertion.
The independently reviewed draft contract requires:

- A per-device stream with one descriptor-verified, device-relative root and
  WatchRoot/FileEvents/FullHistory flags. Epoch is `fsevents-device-v1:<UUID>`
  from the canonical FSEvents database UUID, not runtime dev_t. Resume cursors
  are canonical decimal 1 through UInt64.max-1; zero, SinceNow sentinel,
  noncanonical values and mismatched/unknown epochs fail closed without rebasing.
- Nil checkpoint alone subscribes SinceNow. After successful start and the
  post-start root fence, an explicitly synthetic historyDone is ordered on the
  same serial callback queue, with no synthetic checkpoint. Existing checkpoints
  wait for native HistoryDone. FullHistory lower/repeated IDs retain every dirty
  path while checkpoint candidates use the maximum high-water value.
- Validate and bounded-copy the whole borrowed native batch before admission;
  no callback filesystem access, Owner writes or Task creation. Loss outranks
  HistoryDone, seals once, and never advances a checkpoint. Directory/root
  structural or unknown directory events conservatively request reconciliation:
  the frozen dirty-locator API cannot expand a moved-in populated subtree.
  This is application inventory uncertainty, not a kernel-drop claim or a W6
  latency pass. Ordinary file events remain bounded dirty batches.
- Private root-FD/mount identity fences and exactly-once native resource cleanup;
  external stop seals, stops/invalidates, drains, then releases. Callback-reentrant
  synchronous drain is unsupported and must not falsely claim completion or
  introduce hidden background cleanup. Native fault-injection tests and later
  real temporary-root callback smoke remain distinct evidence levels.

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

### T3b bounded readiness contract (runtime wiring pending)

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

### N4a owner-mediated dirty work acceptance

Frozen after supplemental independent SPEC PASS / QUALITY APPROVED and root
source verification on 2026-09-06. Only the two-file TEST-DRAFT is authorized;
root must accept it before RED and owns all builds and central integration.

#### Why this is the next narrow W3 seam

CollectorInventoryStore already owns bounded round-robin claimDirty,
acknowledge and deferClaim. Its only runtime owner deliberately keeps Store
and DatabaseQueue private. Native events and bootstrap can now mark work through
the Owner, but stable-capture work cannot claim/finish through that boundary.
This slice adds the value-only facade; it does not implement capture, privacy,
publication allocation, uploader, daemon wiring or source retirement.

#### Scope and API behavior

Only CollectorInventoryOwner.swift and CollectorInventoryOwnerTests.swift may
change after independent acceptance. Store, Models, bootstrap/native event
files, old tests, project routing and all other lanes remain frozen. No new
database/catalog/writer, migration, provider, live source or external operation.

- Add value-only Owner methods to claim bounded dirty work, acknowledge a
  capture ID and defer a claim. Receive explicit full root configuration on
  every method, not just rootID. Do not expose Queue/Store or return closures
  that outlive the Owner mutex. Keep exact byte identity for configuration.
- Claim uses the existing Store round-robin API with candidate limit 1...64,
  nonnegative Unix now, no hidden looping to refill an empty result, and no
  claim that the queue is empty when candidates were deferred/in-flight.
- Claim and acknowledge require the exact enrolled and active root binding
  and a fresh physical root fence. Reject closed, unactivated, replaced,
  missing, stale-revision or mismatched-source/path roots without silently
  enrolling/rebinding them. All storage/owner locks remain in force.
- Root physical validity, storage validity and caller cancellation must be
  rechecked inside the Store's existing beforeCommit hook, after a test hook
  can mutate state. On failure, roll back claim/cursor or acknowledgement,
  including last_capture_id and cleared leases. Borrow UnsafeCurrentTask on
  the calling thread and only across the synchronous locked Store operation.
- Acknowledgement accepts a valid lowercase 64-character SHA256 capture ID,
  checks claim rootID/rootRevision against the supplied configuration, and
  delegates the existing owner-run/claim-generation/dirty-revision authority
  to Store. It is a caller assertion that durable capture exists, NOT proof of
  CAS residency, privacy eligibility or remote ACK. Never mint a publication.
- An invalid capture ID throws CollectorInventoryOwnerError.invalidCaptureID
  before Store access; do not conflate malformed input with a stale claim.
  Claim/config rootID byte or revision mismatch throws unknownRoot before
  Store access. Apply this same identity gate to deferral.
- Deferral accepts only a typed finite local reason, not raw error text/path,
  and a nonnegative retryNotBefore. It requires exact current configuration,
  enrolled and active identity plus Store claim authority, but may persist a
  retry when that root is now physically missing/replaced. Deferral never
  acknowledges work or overwrites binding; this exception avoids stranding
  a claim merely because capturing its source failed. Storage/cancellation
  commit fences still apply. Pin the new Owner-local enum CollectorDirtyDeferReason
  raw codes to sourceMissing, rootReplaced and unavailable; these describe only
  local work deferral, not capture/CAS/privacy/upload success or classification.
  Persist only the enum rawValue, never an error string, path or errno text.
- Deferral still calls the POSIX root validator before its operation and in
  its pre-commit fence. Only CollectorPOSIXEnumerationError.io(_, ENOENT) and
  rootIdentityChanged are tolerated; unsafePath/symlink/other errors fail.
  Do not skip the validator entirely after an earlier tolerated result.
- Negative now/retryNotBefore or claim limit outside 1...64 throws
  CollectorInventoryError.invalidBudget before Store access. Pass the valid
  limit through unchanged; no refill loop. Closed owner calls still fail closed.
- Extend the existing weak Store beforeCommit callback with an operation-local
  fence, reset by defer on every exit. It must run AFTER beforeInventoryCommit
  so injected cancellation/storage/root changes are checked inside the current
  transaction. Never call today's validateStorage there: it reenters the same
  DatabaseQueue.read at Owner.swift:468. Within Owner only, extract/reuse its
  existing filesystem/FD/directory/lock/main/sidecar identity checks as a truly
  queue-free storage fence. Keep the existing complete validateStorage (including
  its SQLite connection-path check) at the outer operation entry/exit. No Store
  API/hook signature change is needed. The pre-commit callback calls only that
  queue-free fence and static root validators; never withStore/withEventStore,
  any DatabaseQueue API, or another public Owner method. Borrowed task and
  operation fence cannot survive the synchronous locked Store call.
- Stale claims retain Store's stale/false neutral results and mutate no row.
  Newer dirty events survive an older successful acknowledgement. Reopening
  under a new ownerRunID allows takeover and rejects the old owner's results.
  Completion after close throws closed and does not resurrect a writer.

#### Required tests before RED

Tests use the existing private temporary Owner fixture and independent
readonly SQL observations, with positive baselines before each negative.
Keep all existing test bodies unchanged and append cases for bounded/fair
claims through Owner, retry due boundaries, in-flight exclusion, current-root
and configuration fences, Unicode byte identity, exact capture-ID validation,
stale/forged claim authority, newer-dirty survival, reopen takeover, closed
calls, typed deferral on missing/replaced root, precancel and injected
post-mutation/pre-commit cancellation/root replacement rollback. Read-only
verification must include claim_cursor, owner/generation/revisions and last
capture/retry/error values, not merely successful-return counters. Prove the
live catalog remains unchanged. This is no native capture/upload result.

The draft must independently prove post-hook storage-mutation rollback as
well as cancellation and physical-root replacement. No GREEN or runtime
capture/upload wiring is authorized by this contract freeze.

### T4a bounded Service replay worker acceptance

Frozen after the independent supplemental feasibility gate returned SPEC PASS /
QUALITY APPROVED on 2026-09-06. This acceptance authorizes only the two-file
test draft below, not GREEN, runtime wiring or T4b completion.

#### Scope

Only new `macos/EngramService/Core/ServiceCaptureIngestWorker.swift` and
`macos/EngramServiceCoreTests/ServiceCaptureIngestWorkerTests.swift` are authorized for
TEST-DRAFT only; root must accept the draft before executable RED. Root owns project routing. Do not edit Ledger,
Registry, Replay, Committer, NormalizedStore, Readiness, WriterGate, Runner,
DTOs, migrations, Web, Collector, packaging or old tests. No provider,
credentials, production roots, network, SSH, Docker, deployment or W7.

T4a integrates claim -> actual CAS replay -> parsed commit, not a scheduler.
The existing T3b FTS runner is not wired here. Initial skip/no-job readiness
and restart recovery are explicitly the next T4b slice, not silently complete.

#### Lifecycle and concurrency

- Cold construction borrows one existing ServiceWriterGate, an existing CAS,
  a precreated staging parent, fresh synchronous parser/source policy and a
  Unix-seconds clock. No new writer/database/catalog, schema, directory creation,
  provider lookup, task or loop in init. Missing policy defaults OFF.
- One actor-owned work Task per step; concurrent step attempts do not claim a
  second item or await the first and then silently start another. Stop seals
  future admission, cancels and joins the owned task, and is idempotent. Caller
  cancellation also cancels and joins it. No untracked task or retained waiter.
- Explicitly override ServiceWriterGate.preserveAcceptedWriteProducer to false
  around worker operations: accepted Unix-socket task-local inheritance must
  never create a detached write that escapes stop/cancel join.
- Check cancellation and optional monotonic deadline at every worker await
  boundary and before/after synchronous writes. These are acceptance fences,
  not a hard-preemption guarantee for existing parser/JSON/SQLite operations.

#### Selection and authority

- Select at most one eligible due ledger key with scalar SQL and LIMIT 1,
  parameterized current parser revision/enabled sources, valid matching source
  registry/epoch/history/parse-format and deterministic ordering. Never load
  normalized BLOBs or materialize the entire backlog. Future retry, live lease,
  terminal, unknown/disabled/changed/unprovisioned authority stay unchanged.
- This is scalar PRESELECTION, not full manifest eligibility. Project only
  ledger publication_sha256/parser_revision; join publication scalar machine/
  instance/epoch to registry source/format/approved epoch and matching history.
  No CAS access or canonical_bytes/manifest_json/normalized_messages_json in
  this selection. Match the ledger's pending/null-lease, due retry and expired
  processing predicates, and order by ledger.created_at ASC then digest BINARY
  ASC. Only the chosen claim may read its canonical publication bytes through
  the existing Ledger API. Full Registry.eligibility requires verifiedManifest
  and is checked only after actual replay, then again by commitParsed.
- Within one existing gate/writer transaction: reread fresh policy, validate
  full registry binding/history, and call CaptureIngestLedger.claim. Use its
  existing canonical publication verification; do not reimplement claim CAS.
  A policy race after selection must roll back the claim and attempt increment.
- Lease duration is explicit 1...300 (default 300 seconds); retry delay explicit
  1...3600 (default 30 seconds). Invalid inputs and overflowing clock arithmetic
  fail closed. Never refresh a lease or synthesize a token on the caller's own.
- Execute the real public CaptureIngestReplay.replay outside the writer gate,
  with the accepted publication/binding/CAS/staging parent. Test-only barriers
  may bracket it; no fabricated replay result or substituted successful parser.
  Recheck fresh parser/source policy and complete registry identity after
  replay, before any commit or failure write.
- Barriers bracket the public replay call, not internal CoreWrite parse hooks.
  Unix Int64 clock is used only for lease/backoff. Deadline uses independent
  ContinuousClock. Derive indexedAt using the existing UTC ISO8601 snapshot
  timestamp convention; do not invent a new wire/storage timestamp format.
- Gate command names are captureIngestClaim, captureIngestCommit and
  captureIngestFailure, none matching the gate's long-running classifications.
  The actor returns an explicit busy result immediately if an owned task exists;
  it never queues a second step behind completion.

#### Writes and outcomes

- Use the existing gate and actual writer.write transaction to invoke
  CaptureIngestCommitter.commitParsed. Fresh policy, registry/history, current
  claim and clock are checked immediately before it. After it, check fresh
  policy/binding, cancellation/deadline and new clock before outer commit.
  The committer clears the claim: the post-commit lease check uses the accepted
  claimedAt <= freshNow < expiresAt, not requireCurrentClaim on a parsed row.
- Borrow UnsafeCurrentTask before entering GRDB's synchronous callback, not
  inside the GCD callback. It must not escape the synchronous writer call.
  Trigger/barrier-induced cancellation, policy change and lease expiry after
  materialization must roll back sessions, normalized data, jobs and ledger.
- A parsed receipt is only parsed, not index_ready or visible. Preserve prior
  ready head, user state, tier/child skip, ordering and existing job semantics.
- Only current-authority/current-lease Replay errors receive recordFailure.
  Explicit mappings: invalidManifest/manifestMismatch -> invalidManifest;
  unsupportedCaptureShape/invalidReplayLayout -> unsupportedCaptureShape;
  sourceIntegrityMismatch -> sourceIntegrityMismatch;
  bindingMismatch/sourceMismatch -> bindingMismatch;
  invalidNativeIdentity -> invalidNativeIdentity;
  unsafeStaging -> retry stagingUnavailable (local safety is not bad input);
  retry reasons retain their CAS/staging codes; parse failures retain ParserFailure.
  Cancellation/deadline, stale policy/binding/claim/order or unknown epoch are
  neutral: no fabricated retry/quarantine; a claimed row remains processing
  until its existing natural lease expiry. Unexpected DB/commit/infrastructure
  errors propagate without raw error strings or arbitrary persistent codes.
- CancellationError/deadline MUST NOT use recordFailure, including the existing
  retryable.interrupted case. Ledger/Registry/Committer errors never acquire a
  made-up replay failure code. The post-call in-memory claim time bounds and
  all policy/binding/cancel checks remain inside the outer writer transaction
  so a thrown fence failure rolls back even after an inner savepoint committed.
- The same fresh before/after clock/policy/binding/cancel fences surround
  recordFailure; its claim clearing likewise requires explicit post-clock bounds.

#### Required draft tests before actual RED

Real migrated temporary DB + existing gate, exact canonical publication/CAS
and real replay fixtures; selection SQL/statement-trace evidence of no BLOB/full
backlog delivery during preselection, allowing one canonical envelope at claim.
Use public writer.write access to install a test trace; private writer factory
configuration need not change. Do not replace GRDB's internal authorizer for
this worker test. Cases: cold/default OFF; eligibility variants; one item among >1;
concurrent step; future retry/live lease/expired takeover; parser/registry
revocation queued at gate and suspended around replay; normal exact parsed
snapshot/job provenance; child skip stays parsed/skip with no invented ready;
last-good remains; missing/corrupt CAS and parse/unsafe-stage classifications;
stale claim/unknown epoch do not poison ledger; caller cancel/stop join both
queued and replay-entered; inherited accepted-write task-local; real writer
trigger cancellation, policy flip and fresh-clock expiry cause total rollback.
Test barriers must actually be entered; timeouts fail tests, never OR true.

Independent draft gate precedes root-owned actual RED. Only after executed
behavioral failure may the source implementation be opened. Compile errors
are recorded separately, not called RED. Full Service and impacted Core suites,
invariants, project drift and independent implementation gate follow GREEN.

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

### A5c metadata producer acceptance (before W6)

The independently reviewed next W5 slice owns only new
`ServiceWebMetadataProducer.swift` and `WebMetadataProducerTests.swift` in the
Web-reader donor. The coordinator owns later handler/init/extension/Runner
wiring and real IPC tests. A5a DTO/client and all four A5b files remain frozen.
Tests precede implementation; this contract is not a running producer result.

- The initial corpus is capture-bound, visible top-level sessions only; legacy
  local coverage remains W6 work. Lists retain lite; keyword uses the existing
  searchable-tier rule. Excluded detail is nil. Inject a callable current
  parser/enabled-source policy, re-evaluated before and after asynchronous work;
  absent/invalid/empty policy is unavailable, never inferred from table presence.
- Own a private readonly GRDB pool using the existing
  `SQLiteConnectionPolicy.immediateReaderConfiguration()`: the ordinary reader
  has a 30-second busy timeout and does not meet this two-second request budget.
  Do not instantiate the chmod-performing CoreRead reader, change CoreRead,
  migrate schema, use a writer, or read manifest/publication/normalized BLOBs.
  Create immutable WAL snapshots outside transactions, with bounded SQL and
  cancellation during creation and reads, not only a post-query checkpoint.
- One Service-owned producer retains at most eight snapshots for a hard maximum
  30 seconds from creation. No idle extension. Oldest eviction, independent
  weakly-held expiry timer, explicit stop/close and deinit release the leases;
  expired leases admit no new page. Entered work is joined and remains within
  its two-second SQL budget. Test expiration without another client request.
- Bind byte-exact query, all filters, requested limit, sort version, snapshot
  and visibility/registry/FTS view. Sort by start time descending, unknown last,
  then session-ID UTF-8; overview uses machine/instance binary order. Use random
  opaque cursor tokens with server-held keysets, not encoded IDs/paths. Retain
  at most 128 cursor positions per snapshot, evict oldest positions to stale,
  and reuse a cached successor when replaying a cursor rather than allocating
  unbounded tokens. Expired, evicted, mismatched and unknown cursors are stale.
- Every page, including the first, and detail recheck fresh source/registry/
  epoch-history and current visibility/parent authority after preparation.
  A would-be page row losing authority returns stale/unavailable, not silent
  omission with cursor advancement; excluded detail is nil. Previously returned
  rows are not retroactively revoked. Unrelated inserts stay absent from the
  held snapshot; do not invalidate all snapshots on writer databaseGeneration.
- Count stored stream publications, parser tasks and logical sessions separately.
  Ready-session counts require matching parsed/ready/generation heads, current
  owner/source/version/hash, parser policy, registry/history tuple, index-ready
  ledger and FTS row, using scalar evidence only. Divergent heads may be metadata
  provenance, never available transcript authority. lastCapture/heartbeat/ACK/AI
  observations remain nil; transcript availability is unavailable/generation nil.
  A healthy supplied SQL producer may measure missing capture tables as empty;
  an absent producer must never return a successful empty corpus.
- Redact title/projectLabel with the existing full-string policy before a
  conservative path/NUL/byte-length fence. Emit projectKey only if the existing
  value is a valid token and redaction leaves it unchanged; no cwd/native/root
  fallback. Omit unsafe fields, do not prefix-truncate secrets. Preserve DTO
  round-trip validation, strict integer counts and safe symbolic errors.
- Encode the entire success envelope, including result Data base64, at no more
  than 261120 bytes. Shrink pages coherently; one oversize item is unavailable.
  Provider tests cover ordering/filter/Unicode, expiry/eviction, policy and
  visibility revocation, false-ready scalars, redaction, cancellation/timeouts,
  readonly/no-BLOB behavior, envelope budgets and honest unknown observations.
  Handler extra-payload, real dispatch and Runner injection tests belong to the
  later coordinator slice, not a fake dispatcher in these provider tests.

### A5d metadata IPC adapter acceptance

Frozen after independent feasibility PASS / proposal quality APPROVED and
root source verification on 2026-09-06. This authorizes only three-file
TEST-DRAFT; root owns routing and actual RED. Deadline capture and separate
client-versus-server cancellation evidence are part of this frozen contract.

#### Narrow scope

Only existing EngramServiceCommandHandler.swift, new
EngramServiceCommandHandler+WebMetadata.swift and new WebMetadataIPCTests.swift.
Constructor injection and actual dispatch for webOverview/webSessions/
webSessionDetail; no new schema, writer, provider lookup or runtime process.
Keep producer, DTO/client, Remote HTTP, transcript provider/continuation,
capability/auth/transport, WriterGate and Runner frozen. Root owns routing.

The metadata producer is injected as one retained Service-owned instance,
defaulting to UnavailableServiceWebMetadataProducer. No per-request pool or
producer creation. Runner composition, its policy source and stop ordering
remain an explicit later slice: this adapter does not claim running HQ metadata.

#### Behavior

- Route only the three exact commands through the real handler.handle dispatch.
  Do not substitute a fake router in tests. Preserve all existing commands.
- Parse a JSON object with exact allowed-key sets for each command, then decode
  the existing strict DTO. Reject missing/malformed payloads, extra command,
  locator/path/capability/hidden/deadline/budget fields before producer entry.
  Allowed sets are the existing DTO CodingKeys, not a new generic schema layer.
- Supply the request ID byte-exactly and a fresh monotonic deadline no more
  than two seconds from handler entry. Check cancellation/deadline before and
  after awaiting the producer and encoding. The adapter does not create an
  untracked timeout Task or promise preemption of an uncooperative provider.
  Caller cancellation must await the producer's cooperative exit; never return
  early while the owned producer keeps working.
  Capture that deadline at the start of handler.handle and carry it through
  dispatch, rather than starting a renewed budget inside the extension.
  This join promise is Service-side only. The existing client may cancel and
  close its FD first; tests must separately observe producer exit and server
  drain, never infer server cleanup from client cancellation completion.
- Encode the typed result and whole success envelope; reject any whole frame
  above the existing 261120-byte budget. Round-trip through the existing strict
  DTO decoder before success so injected invalid values cannot bypass wire
  validation. Do not relax A5a client or schema validation to make this pass.
- Symbolic safe errors only: malformed request -> InvalidRequest/never;
  stale -> StaleCursor/never; cancellation -> Cancelled/never; unavailable,
  response-too-large, unexpected DB/encoding/provider errors ->
  ServiceUnavailable/safe. Never expose raw errors, SQL, roots or file paths.
- Read-only IPC does not load a capability token or mutate the writer gate.
  Same-UID socket admission and transport protections remain unchanged.
  No fallback to legacy readers or successful-empty result for absent provider.

#### Test-draft requirements

Use the existing short temporary socket harness pattern: actual
UnixSocketServiceServer -> handler.handle -> injected provider, with the actual
EngramServiceWebReadClient. Verify every command, request ID/deadline/filter
byte fidelity, default unavailable, independent extra/missing/malformed inputs,
safe stale/cancel/oversize/unexpected failures, and no provider entry on invalid
input. Include unknown-command behavior without changing its existing contract.
Assert InvalidRequest/Cancelled names and retry policy using rawExchange: the
unchanged typed client maps those server errors to malformed, while its local
Task cancellation still throws CancellationError. Use the typed client for
valid/stale/unavailable and local-cancellation behavior. Exact overview keys
are limit/snapshotId/cursor; sessions keys are query/source/machineId/
sourceInstanceId/projectKey/limit/snapshotId/cursor; detail accepts sessionId.
Use local narrow checks, not widening the main handler's private helper access.

Use thread-safe observations and cancellation-aware registration-safe barriers.
Join/drain handlers before releasing provider/gate and deleting fixture storage.
Independently assert gate databaseGeneration unchanged and no capability fields
sent. Test all three endpoints with a real A5c producer against a migrated,
temporary empty DB and valid injected policy; an empty metadata corpus is then
measured, while the default unavailable producer is not. Add a seeded real
capture-bound list/detail/continuation fixture if needed for endpoint authority;
do not invent an alternate production query/decoder. Existing A5c tests remain
unchanged and cover nonempty SQL authority/expiry/readonly/cancellation details.

No browser, production Web, source coverage, transcript readiness, Runner
composition, W6 end-to-end or W7 completion claim follows from this slice.
Require independent feasibility before freezing TEST-DRAFT, then actual RED,
minimal GREEN, full Service regression and independent source/spec gate.

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
