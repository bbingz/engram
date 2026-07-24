# Design Doc: Adapter Format Drift Detection

- **Status**: Draft
- **Owner**: unassigned
- **Date**: 2026-07-24
- **Related**: `docs/competitive-mirror-2026-07.md` backlog row 23 (F5).
  Sibling specs from the same mirror pass, and the single authoritative
  implementation sequence, are indexed in that report's **Follow-up specs**
  section: `docs/insight-supersede-filter-design-2026-07.md` (row 1),
  `docs/source-health-predicate-design-2026-07.md` (row 2),
  `docs/codex-native-parentage-design-2026-07.md` (row 22). This spec is
  **fourth** in that sequence; it has one hard dependency on row 22 — see
  Accept path, step 6.

## Problem

The record kind `world_state` is present in **12 of the 12 newest** local Codex
rollouts (and in 49/49 rollouts modified in the last five days) and appears
**zero times** anywhere in `macos/`, `src/`, `scripts/`, or
`docs/session-formats/`. It is a record kind the Codex CLI writes today, that
`CodexAdapter` drops, that no format doc describes, and that nothing in the
repo knows exists.

The same measurement on Claude Code finds **ten** distinct
non-`user`/`assistant` top-level `type` values across the 40 newest
non-subagent transcripts, all silently discarded (file prevalence out of 40):

```
attachment 38 · last-prompt 40 · mode 22 · permission-mode 21 · ai-title 20
system 22 · queue-operation 35 · file-history-delta 18 · file-history-snapshot 21
pr-link 3
```

Measurement command, reproducible verbatim (this is what the numbers above came
from; re-run it before trusting them, the corpus moves daily):

```sh
find ~/.claude/projects -name '*.jsonl' -not -path '*/subagents/*' -type f \
  -exec stat -f '%m %N' {} + | sort -rn | head -40 | cut -d' ' -f2- \
| python3 -c '
import sys, json, collections
fc = collections.Counter()
for path in (l.strip() for l in sys.stdin):
    seen = set()
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line: continue
        try: o = json.loads(line)
        except Exception: continue
        if isinstance(o, dict): seen.add(o.get("type", "<missing-type>"))
    for t in seen: fc[t] += 1
for t, c in fc.most_common(): print(f"{t:28s} {c}/40")
'
```

An eleventh kind, `agent-name`, exists elsewhere in the corpus (e.g.
`~/.claude/projects/-Users-bing--Code--ServerCat/47b6923e-….jsonl`) but is
absent from the 40-newest window and from the 20 newest subagent transcripts.
That single fact is the design's justification for `baselineFiles: 200`: a
30-file or 40-file window under-covers the long tail, so an allowlist seeded
from one window is incomplete by construction (see slice 4).

Discarding lifecycle records is correct. The problem is that we cannot tell
that case apart from the failure case, because both are silent. Concretely:

- All 34 files under `docs/session-formats/` carry the identical stamp
  `Last researched: 2026-06-21` (`docs/session-formats/claude-code.md:3`,
  `docs/session-formats/codex.md:3`). Nothing under `scripts/`, `.github/`,
  `package.json`, or `macos/project.yml` reads that directory.
- The claude-code format doc was researched against Claude Code
  `2.1.146` → `2.1.185` (`docs/session-formats/claude-code.md:8`). The twelve
  newest non-subagent transcripts on this machine are all `2.1.218`.
- The codex format doc was researched to `0.142.0-alpha.6`
  (`docs/session-formats/codex.md:10`). The twelve newest rollouts report
  `cli_version` `0.146.0-alpha.4` / `-alpha.5` / `-alpha.6`.

The harm is specific to a memory layer. Ten of fifteen parsers have no
zero-visible-message guard, so a vendor record-kind rename produces
`parse_status='ok'` plus a session row with zero messages. `SessionTier.compute`
returns `.skip` for `messageCount <= 1`
(`macos/Shared/EngramCore/Indexing/SessionTier.swift:9-14`), and invariant 3
excludes `skip` from every read surface and from keyword search. The session
disappears with no error at any layer, and an agent calling `search` or
`get_context` receives a confidently incomplete answer.

## Goals / Non-goals

- Goals: detect an additive schema change in a vendor's on-disk session format
  against a committed baseline built from **real** local sessions, before the
  change silently degrades indexing.
- Goals: refuse to report green when the evidence behind the baseline is stale,
  keyed on the vendor version embedded in the samples, not only on file mtime.
- Goals: give an operator a one-command run, a readable diff, and an explicit
  accept path that records *why* a drift was accepted.
- Goals: make the two live drift cases regression-covered in Swift so an
  accepted drift stays accepted — `world_state` in slice 3, Claude Code
  lifecycle records in slice 4 (the latter depends on `unknownRecordKinds`, so
  the goal is satisfied only once both have landed).
- Non-goals: surfacing `file_index_state.failure_kind` to any UI, MCP tool, or
  service IPC command. That is mirror row 12 (F6), separately unselected. This
  design reads nothing from the product database at all.
- Non-goals: making the drift check a CI job or an invariant gate (see
  Alternatives).
- Non-goals: covering content-block drift (the `extractContent` allowlist at
  `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:735-768`).
  That is a second axis with a different failure mode — degraded content, not a
  missing session. Named here so a later slice can pick it up.
- Non-goals: any schema migration, any new SQLite writer, any change to product
  parse behavior.

## Current state

### Parse failures are recorded, and read only by the writer

`ParserFailure` has exactly 15 cases, `fileMissing` through `noVisibleMessages`
(`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:197-214`).
`file_index_state` persists `parse_status` (CHECK `ok|terminal|retry`),
`failure_kind`, `retry_after`, `retry_count`, `last_error`, keyed
`(source, locator)` (`macos/EngramCoreWrite/Database/EngramMigrations.swift:163-182`).

The mirror's claim that "nothing reads it" is **false** and must not be
repeated. Three production readers exist:

- `macos/EngramCoreWrite/Indexing/EngramDatabaseIndexer.swift:178-208` —
  hydrates known states for the skip/retry gate.
- `macos/EngramService/Core/ClaudeCodeProfileService.swift:196-217` — counts
  `parse_status='ok'` under a projects root.
- `macos/EngramService/Core/ArchiveV2ServiceCoordinator.swift:1870-1944` —
  index-generation trust proof, explicitly special-casing
  `failureKind == .noVisibleMessages`.

The accurate gap is narrower: **nothing aggregates `failure_kind` across
sources, and nothing surfaces it to an operator.** There is already a real
population behind that gap. Read-only query of `~/.engram/index.sqlite`:

```
claude-code | terminal | noVisibleMessages     | 693
claude-code | retry    | malformedJSON         | 262
codex       | retry    | malformedJSON         | 169
```

That population is normal noise, which is why a drift alarm keyed on failure
counts would be swamped. Surfacing it is row 12's job.

### The failure channel structurally cannot express record-kind drift

Failures are recorded from three call sites, all routing through one helper
(`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:229`, `:278`, `:325`;
helper at `:558-578`). That helper begins `guard let stat else { return }`
(`:565`), and `recordFileIndexSuccess` does the same (`:585`). For virtual
locators no outcome is persisted at all. Empirically, `opencode` has 411
indexed sessions and **0** `file_index_state` rows; `cursor` has 59 sessions
and **0** rows; `gemini-cli` has 403 sessions and 25 rows. Any monitoring built
on `file_index_state` is structurally blind to those sources.

Worse, only 5 of the 15 parsers under
`macos/Shared/EngramCore/Adapters/Sources/` guard against a zero-visible-message
parse, and they do not agree on the failure they raise:

- `.noVisibleMessages` — `ClaudeCodeAdapter.swift:310`, `QwenAdapter.swift:94`,
  `VsCodeAdapter.swift:49` and `:55`.
- `.malformedJSON` — `AntigravityAdapter.swift:219-220`,
  `CopilotAdapter.swift:108-109`.

`FileIndexState.isTerminalFailure` lists `.noVisibleMessages` as terminal and
`.malformedJSON` as retryable
(`macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:234` and `:240`), so on
antigravity and copilot a record-kind rename manifests as an **unbounded retry
loop** rather than a silent skip — a different failure worth naming separately.
For the other ten parsers a total record-kind rename yields `.success` with a
zero message count and no failure signal anywhere (verified absent:
`CodexAdapter.swift`, `CursorAdapter.swift`, `OpenCodeAdapter.swift`,
`QoderAdapter.swift`, `CommandCodeAdapter.swift`, `IflowAdapter.swift`,
`WindsurfAdapter.swift`).

There is also no single terminal-vs-retry policy. Four classifiers disagree:
`FileIndexState.isTerminalFailure`
(`macos/EngramCoreWrite/Indexing/IndexingWriteSink.swift:228-248`),
`SwiftIndexer.isTerminalTailFailure` (`:657-666`),
`IndexJobRunner.isTerminalFtsFailure`
(`macos/EngramCoreWrite/Indexing/IndexJobRunner.swift:259-278`), and
`EngramDatabaseIndexer.isTerminalInstructionBackfillFailure` (`:845-854`). This
design does not depend on any of them; it is recorded so nobody builds on the
assumption that one exists.

### Adapters drop unknown record kinds with zero signal

`ClaudeCodeAdapter` has no allowlist constant. It has a literal binary gate,
duplicated at two independent `private static` sites:

- `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:384-388`
  (`aggregateSessionInfo`, `continue`)
- `macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:674-678`
  (`message(from:)`, `return nil`)

Both are `guard let type = ..., type == "user" || type == "assistant" else`.
The same allowlist-then-drop shape is universal: `CodexAdapter`'s message
decoder ends in `default: return nil`, and its info pass inspects only
`session_meta` / `turn_context` / `response_item`
(`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:537-586`,
`:879-935`).

### Existing fixture and parity surface

- `scripts/check-adapter-parity-fixtures.ts` regenerates fixtures from
  `scripts/gen-adapter-parity-fixtures.ts` and diffs against the committed tree
  for 15 sources (`scripts/check-adapter-parity-fixtures.ts:30-46`). It proves
  our own generator is deterministic; it cannot see upstream change. It runs in
  CI at `.github/workflows/test.yml:131`.
- The committed claude-code parity fixture pins `"version":"2.1.58"`
  (`tests/fixtures/adapter-parity/claude-code/input/-Users-test-my-project/sample.jsonl:1`)
  — three vintages away from live. Diffing real sessions against these
  synthetic inputs would report roughly a dozen false unknown types on a
  healthy install.
- `tests/fixtures/claude-code/new-types.jsonl` and
  `tests/fixtures/{claude-code,codex,...}/schema_drift.jsonl` already exist, and
  `tests/adapters/schema-drift.test.ts:60-71` is a meta-test asserting every
  JSONL adapter has a `schema_drift.jsonl`.
- `macos/EngramCoreTests` is a real `bundle.unit-test` target whose sources are
  the whole directory, with `../tests/fixtures` mounted as a resources folder
  and dependencies on EngramCoreRead + EngramCoreWrite + GRDB
  (`macos/project.yml:60-79`). A new file joins on `xcodegen generate`.

### 17 adapters, 15 formats

`SessionAdapterFactory.defaultAdapters()` registers 17 adapters, but `minimax`
and `lobsterai` are `ClaudeCodeDerivedSourceAdapter` wrappers over the same
`ClaudeCodeAdapter` instance
(`macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:33-34`). There
are 15 distinct format surfaces, which is exactly the list
`scripts/check-adapter-parity-fixtures.ts:30-46` already enumerates.

## Proposed design

A local-only TypeScript dev script that fingerprints the newest real sessions
per **format** and diffs the fingerprint against a committed baseline, plus a
freshness gate that can veto a green result, plus one Swift test file seeding
the two observed drifts.

### The fingerprint

A fingerprint is **not a hash**. It is a bucketed set of top-level key names
with per-key file counts. A digest is recorded **inside the committed baseline
only**, where the corpus is frozen at accept time and the digest is therefore
stable; it is a provenance field for `git diff`, never the comparison unit, and
it is **not printed on the clean run**. (An observed digest would change on most
consecutive runs, because the observe window is a rolling 30-newest-by-mtime
sample and rare keys enter and leave it continuously — `pr-link` is in 3/40 of
the newest transcripts. An operator taught to read a digest as
changed/unchanged would be reading churn.)

**F1 — corpus selection.** Per format, declared in the support matrix: a list
of roots, a glob, `excludeGlobs`, and `requiredTypes`. Select the newest `N`
files by mtime (default `observeFiles: 30`; `baselineFiles: 200` when accepting)
whose head window contains at least one `requiredType`.

Selection records three counters that F7 needs to tell apart three very
different empty-corpus causes: `rootsPresent` (how many declared roots exist on
disk), `globMatches` (files matched before the `requiredTypes` filter), and
`corpusFiles` (files surviving the filter). A `requiredTypes` filter that
rejects every matched file is *itself the flagship drift signal* — a vendor
record-kind rename is exactly what makes it happen — so it must never collapse
into "you don't have this tool installed". See F7.

claude-code **must**
set `excludeGlobs: ["**/subagents/**"]` — the newest `~/.claude/projects` file
is frequently a subagent sidecar with a different key surface (`agentId`,
`entrypoint`, `attributionAgent`), and it is often mid-write. Traversal must
descend into dot-directories explicitly (antigravity transcripts live under
`.system_generated/logs/`).

Cost is not a concern: a full walk of `~/.claude/projects` (39,616 jsonl) plus
`~/.codex/sessions` (1,099) completed in 0.83s wall on warm cache.

**F2 — line sample: HEAD ∪ TAIL, never tail-only.** Keep the first
`headLines` (default 200) and last `tailLines` (default 800) non-blank lines.
This is a deliberate divergence from prior art. Agent Sessions keeps only the
last `max_lines` (`as-main/scripts/agent_watch.py:558-564`); measured against
our own corpus, Codex `session_meta` — which carries `cli_version` — is in the
first 200 lines of 12/12 files but the last 2500 lines of only 7/12. Tail-only
sampling silently loses the version axis on 42% of long sessions. A per-line
byte cap applies; a JSON parse error increments `parseErrors` and never aborts.

**F3 — bucketing via a declared descent ladder.** Never infer, never recurse
into undeclared objects. Missing discriminator becomes the literal
`<missing-type>`.

| format | ladder |
|---|---|
| claude-code | `$` → `record:{type}`; `$.message` → `message:{record.type}` |
| codex | `$` → `record:{type}`; `$.payload` → `payload:{record.type}/{payload.type ?? "-"}` |

**Both codex tiers are mandatory.** Tier 1 catches whole new record kinds:
`world_state` is a **top-level** `type`, and its `payload` carries no `type`
key, so it buckets as `payload:world_state/-`. Tier 2 is required for
resolution *inside* the two dominant kinds: measured over the 12 newest
rollouts, `response_item` fans out to 9 payload types (`agent_message`,
`custom_tool_call`, `custom_tool_call_output`, `function_call`,
`function_call_output`, `message`, `reasoning`, `tool_search_call`,
`tool_search_output`) and `event_msg` to 14. A tier-1-only fingerprint would
collapse the overwhelming majority of records into two buckets. Neither tier
subsumes the other; an implementer must not drop tier 1 as "uninformative".

**F4 — key collection: own top-level key names of the bucketed object, depth
1.** Values are read only for (a) the declared discriminator and (b) the
declared `versionField`. This is how per-session noise is excluded, and it needs
no scrub list: ids, timestamps, `cwd`, and message text are *values*, so they
are excluded by construction.

Depth 1 is also a privacy control, not just a stability one.
`file-history-snapshot.snapshot.trackedFileBackups` is an object **keyed by the
user's file names** (observed locally: `MEMO.md`, `CHANGELOG.md`,
`contribution-31433-draft.md`). Recursion would commit user filenames into a
public repo. The baseline writer must assert that no collected key matches
`/[\\/]|\.(md|ts|swift|json|jsonl)$/` and refuse to write if one does.

**F5 — aggregate with frequency.** Per format:

```
buckets: { <bucket>: { files: int, records: int, keys: { <key>: <fileCount> } } }
corpusFiles: int
digest: "sha256:<hex of canonical JSON of {bucket: sorted(keys)}>"   // baseline only
```

Per-key file counts are stored (prior art stores a flat sorted list) so the
accept diff can say `queuePriority 4/30 → 30/30` and prevalence gains history.

**F6 — compare: additive-only, prevalence-gated, symmetric in prevalence.**

The baseline is written at `baselineFiles: 200` and compared against
`observeFiles: 30`, so raw counts on the two sides are not commensurable. Both
sides are therefore reduced to a fraction before any comparison:

- `observedPrevalence[b][k] = observed.buckets[b].keys[k] / observed.corpusFiles`
- `baselinePrevalence[b][k] = baseline.buckets[b].keys[k] / baseline.corpusFiles`

Then:

- `newBuckets` = observed buckets absent from baseline.
- `newKeys[b]` = observed keys absent from `baseline[b]`.
- `observedPrevalence >= 0.5` → **DRIFT**, exit 1. A vendor format change lands
  in every new session.
- `observedPrevalence < 0.5` → **novel-rare**, informational, exit 0.
- Baseline entries not observed → **missing**, informational, never a failure,
  and **reported only when `baselinePrevalence >= 0.5`**. Without that gate a
  healthy run would emit an `info` line for every long-tail key the 200-file
  baseline recorded and the 30-file window happened to miss
  (`attributionMcpServer` is 12/200 in the seed baseline and absent from most
  30-file samples), and the clean run would never actually be clean. A finite
  corpus always under-covers; prior art makes the same call
  (`as-main/scripts/agent_watch.py:2803`, verdict is `unknown_only_is_empty`).

The 0.5 threshold is empirical, not arbitrary. Measured across 12 real
claude-code sessions, rare-but-old keys cluster at 1/12–5/12
(`attributionMcpServer` 1/12, `requestId` 5/12, whole record type `pr-link`
2/12) while stable keys sit at 11/12–12/12. Codex clusters the same way
(`sub_agent_activity` 1/12, `inter_agent_communication_metadata` 2/12, versus
`world_state` / `turn_context` / `response_item` at 12/12).

**F7 — freshness and corpus gate, evaluated before the diff is rendered.** It
vetoes *trust in a green verdict*; it never suppresses the diff. Three
freshness axes plus the empty-corpus triage below:

- (a) *sample recency*: newest observed mtime older than `freshnessWindowDays`
  (14) → `blocked_stale_sample`.
- (b) *vendor version coverage*: extract the declared `versionField`
  (claude-code `$.version`; codex `$.payload.cli_version` on `session_meta` —
  exactly why F2 must sample the head). If max observed version >
  `max_verified_version` in the support matrix → `blocked_stale_baseline`, even
  when the key diff is empty. Agent Sessions declares `version_field` in its
  matrix but no code reads it; automating this axis is the one genuinely
  un-taken piece of prior art here.
- (c) *doc stamp*: `last_checked_utc` older than `docStalenessDays` (90) →
  warn only, never exit 1.

**Blocked states still print the full diff.** Format drift only ever ships
*with* a vendor version bump, so `blocked_stale_baseline` and "a real drift just
landed" are the same event. Suppressing the diff would hide it exactly when it
matters, and the only documented exit — `--accept` — re-fingerprints and
overwrites the evidence. A blocked format therefore prints
`BLOCKED <format> <state>: <reason>`, then the complete DRIFT / note / info
diff under an `untrusted diff follows` marker, and exits 1. Cadence makes this
non-optional: the claude-code docs were researched at `2.1.146`→`2.1.185` and
live is `2.1.218`, roughly 33 patch versions in 33 days, so axis (b) is the
steady state after any vendor patch.

**Version comparison** is a ~25-line exported pure function
`compareVersions(a, b): -1 | 0 | 1` in `scripts/check-adapter-format-drift.ts`.
**No npm dependency is added** (`package.json` has no `semver` and this design
does not add one). Algorithm:

1. Split on the first `-`: numeric core and optional prerelease.
2. Split the core on `.`; compare segments numerically, missing segment = 0.
3. If cores are equal, absent prerelease sorts **above** present prerelease
   (`0.146.0 > 0.146.0-alpha.6`).
4. If both have a prerelease, split it on `.` and compare segment-wise: numeric
   vs numeric numerically, otherwise lexicographically, numeric below
   non-numeric; a longer prerelease with an equal prefix sorts above a shorter.

Lexicographic string comparison is specifically wrong here and would false-green
on live data: `"0.146.0-alpha.10" < "0.146.0-alpha.6"` and `"2.1.9" > "2.1.10"`
as strings, and the local corpus already mixes `0.146.0-alpha.3` through
`-alpha.6` while the 30-file claude-code window spans multiple `2.1.2xx` patches.

Two edge cases are defined, not left to the implementer:

- **Unparseable version string** (any segment that is neither an integer nor a
  prerelease identifier) → `blocked_stale_baseline` with reason
  `unparseable version "<raw>"`. Never green.
- **Observed max below `max_verified_version`** (older local toolchain, vendor
  rollback) → `stale_local_toolchain` warning, exit 0, diff still printed. It is
  not evidence of drift; it is evidence that this machine cannot refresh the
  baseline.

**Three distinguishable empty-corpus outcomes**, using F1's counters. Conflating
them would make the loudest possible drift and "you don't have this tool
installed" produce identical output:

| condition | state | exit |
|---|---|---|
| no declared root exists on disk (`rootsPresent == 0`) | `no_local_sample` | 0 |
| roots exist, `globMatches == 0` | `no_local_sample` | 0 |
| roots exist, `globMatches > 0`, `corpusFiles == 0` | `blocked_required_type_absent` | **1** |

`blocked_required_type_absent` is the record-kind-rename alarm. Its message
names the format, `globMatches`, and the `requiredTypes` that were absent from
every scanned file, e.g.
`BLOCKED claude-code blocked_required_type_absent: 30 files scanned, none contained any of ["user","assistant"]`.

Formats with no embedded version (`gemini-cli`, `antigravity`) declare
`versionField: not_logged` and fall back to axis (a) only. Formats with no
local corpus (`windsurf`, `cline` — verified empty/absent on this machine) emit
`no_local_sample`, exit 0, and are never reported as clean.

**F8 — console output.** House convention is a `failures: string[]` accumulator,
`console.error(failures.join('\n'))` + `process.exit(1)`, else
`console.log('<name> ok')`, all behind an
`if (import.meta.url === \`file://${process.argv[1]}\`)` guard
(`scripts/check-adapter-parity-fixtures.ts:316-324`).

**Output contract.** One line per format whose matrix entry has
`monitored: true` — `ok`, `skipped`, `DRIFT`, or `BLOCKED`. Formats marked
`monitored: false` print **nothing**. Zero or more `note` / `info` lines may
follow any format's line. The run ends with exactly one summary line that
carries the fingerprinted count; the token `ok` appears in the summary only when
that count is greater than zero and no format is DRIFT or BLOCKED. Machine
state names (`no_local_sample`, `blocked_stale_sample`, `blocked_stale_baseline`,
`blocked_required_type_absent`, `stale_local_toolchain`) are the identifiers
returned by `evaluateFreshness`; the console renders `no_local_sample` as
`skipped (no corpus at <root>)` and prints the other four verbatim.

Clean run:

```
adapter format drift: claude-code ok (30 files, 2.1.218, baseline 2026-07-24)
adapter format drift: codex ok (30 files, 0.146.0-alpha.6, baseline 2026-07-24)
adapter format drift: 2 of 2 monitored formats fingerprinted, 0 skipped — ok
```

Drift (exit 1):

```
DRIFT claude-code record:assistant +attributionPolicy 30/30 (100%)
DRIFT claude-code +record:pr-comment 28/30 (93%)
note  claude-code record:user +queuePriority 4/30 (13%) — novel-rare, informational
info  claude-code record:system -pendingBackgroundAgentCount (in baseline, unobserved)
adapter format drift: 2 drift, 1 novel-rare, 1 missing across 1 format
accept with: npm run baseline:adapter-format -- --format claude-code --accept --note "<why>"
```

Stale (exit 1, diff **is** printed):

```
BLOCKED codex blocked_stale_baseline: corpus cli_version 0.146.0-alpha.6 > max_verified_version 0.142.0-alpha.6
  untrusted diff follows — the baseline predates this vendor version
  DRIFT codex payload:response_item/- +tool_search_call 27/30 (90%)
  note  codex +payload:world_state/- 12/30 (40%) — novel-rare, informational
BLOCKED claude-code blocked_stale_sample: newest sample 2026-06-02 is 52d old (window 14d)
  untrusted diff follows — no drift or note lines
adapter format drift: 2 of 2 monitored formats fingerprinted, 2 blocked — fingerprint not trusted
review the diff, then: npm run baseline:adapter-format -- --format codex --accept --accept-drift --note "<why>"
```

Required-type-absent (exit 1) — the record-kind-rename alarm:

```
BLOCKED claude-code blocked_required_type_absent: 30 files scanned under ~/.claude/projects, none contained any of ["user","assistant"]
adapter format drift: 0 of 1 monitored formats fingerprinted, 1 blocked — fingerprint not trusted
```

No-corpus run (exit 0, inert). Note the summary never says `ok` when nothing was
checked — a run that fingerprinted zero formats must not read as green:

```
adapter format drift: claude-code skipped (no corpus at ~/.claude/projects)
adapter format drift: codex skipped (no corpus at ~/.codex/sessions)
adapter format drift: 0 of 2 monitored formats fingerprinted, 2 skipped — nothing was checked
```

### Baseline file

Location: `docs/session-formats/baselines/<format>.baseline.json`, co-located
with the format docs it is evidence for. **Not** under `tests/fixtures/` — that
tree is a resources build phase of `EngramCoreTests` (`macos/project.yml:64-68`)
and is size-gated at 5 MB by the existing parity checker.

Keyed by **format** (15), not by source (17). One `claude-code.baseline.json`
covers claude-code, minimax, and lobsterai; the source→format mapping is
declared once in the support matrix.

```json
{
  "schemaVersion": 1,
  "format": "claude-code",
  "sources": ["claude-code", "minimax", "lobsterai"],
  "acceptedAtUtc": "2026-07-24T00:00:00Z",
  "acceptedNote": "seed baseline from live 2.1.218 corpus",
  "vendorVersions": { "min": "2.1.214", "max": "2.1.218" },
  "corpusFiles": 200,
  "corpusNewestMtimeUtc": "2026-07-24T00:00:00Z",
  "sampling": { "headLines": 200, "tailLines": 800, "excludeGlobs": ["**/subagents/**"] },
  "digest": "sha256:…",
  "buckets": {
    "record:assistant": { "files": 200, "records": 18422,
      "keys": { "cwd": 200, "requestId": 71, "attributionMcpServer": 12 } }
  },
  "note": "key names only; no values are recorded"
}
```

`schemaVersion` is **read, not decorative.** The check script hard-fails on any
value it does not recognise: exit 1,
`unsupported baseline schemaVersion <n> in docs/session-formats/baselines/<f>.baseline.json`,
no diff printed, no other format's verdict affected. Symmetrically, `--accept`
refuses to overwrite a baseline whose recorded `schemaVersion` is higher than
the writer's. Without this, a bisect or a branch where an older script meets a
newer baseline emits an arbitrary green or an arbitrary DRIFT with no signal.

### Support matrix

`docs/session-formats/support-matrix.yml` — the first machine-read consumer of
`docs/session-formats/`. Per format: `sources`, `roots`, `glob`,
`excludeGlobs`, `requiredTypes`, `versionField` (dotted path or `not_logged`),
`max_verified_version`, `last_checked_utc`, `monitored`, and `docs` — a **list**
of the `docs/session-formats/*.md` files this format's evidence backs.
`yaml@^2.8.3` is already a dependency.

`docs` is a list rather than a single `doc` because there are 17 doc pairs (34
files) against 15 formats: the `claude-code` entry must list `claude-code.md`,
`claude-code.zh.md`, `minimax.md`, `minimax.zh.md`, `lobsterai.md`,
`lobsterai.zh.md`. With a single `doc` field the four derived-source docs would
have no matrix row at all and their stamps would rot with no signal — the exact
rot this design exists to stop. Axis (c) evaluates every file in the list, and
`--accept` stamps every file in the list.

The gate is on **staleness**, not row presence. A presence check rots exactly
the way the uniform `2026-06-21` stamp already did.

### Accept path

`npm run baseline:adapter-format -- --format <f> --accept --note "<why>"`,
mirroring the existing `baselines:generate` / `baselines:update` pair
(`package.json` scripts). Ordered steps, each of which can refuse:

1. Re-fingerprint at `baselineFiles` size.
2. Refuse without `--note` (exit 1).
3. Evaluate freshness axis (a). On `blocked_stale_sample`, refuse unless
   `--allow-stale-sample` is also passed. Without this, accept happily
   fingerprints a 60-day-old corpus and bakes a stale format shape in
   permanently, which the *check* would have blocked.
4. Print the old→new bucket and key diff, then refuse (exit 1) if any delta is
   DRIFT-class (`observedPrevalence >= 0.5`) unless `--accept-drift` is also
   passed. A version bump must never silently launder an unreviewed key change.
5. Refuse if the on-disk baseline's `schemaVersion` exceeds the writer's.
6. Write `docs/session-formats/baselines/<f>.baseline.json` **first**, then
   `docs/session-formats/support-matrix.yml`, then the `Last researched:` and
   researched-version-range lines in every file listed in the format's `docs`.
7. Set `max_verified_version = max(existing, observed)` — never a bare
   assignment. When the observed max is lower, print
   `version regression ignored: observed X < recorded Y` and leave the field
   alone. A maintainer on an older vendor build must not be able to push every
   other maintainer permanently into `blocked_stale_baseline`.

Step 6 also closes the docs half of the stated Problem: without it the matrix
would say claude-code verified at `2.1.218` / `2026-07-24` while
`docs/session-formats/claude-code.md:3` still says `Last researched: 2026-06-21`
against `2.1.146`→`2.1.185` (`:8`), and the two records would contradict each
other with no cross-reference.

**Hard ordering dependency on row 22 (integration pass, 2026-07-24).** Step 6
stamps `docs/session-formats/codex.md` and `codex.zh.md` as freshly researched.
`docs/codex-native-parentage-design-2026-07.md` (row 22, slice 4) flips
`codex.md:718` and `codex.zh.md:692` from "Codex's NATIVE subagent spawn tree …
NOT consumed by Engram" / "Engram 不消费" to naming the new consumer, plus the
coverage-table row. Different lines, so no textual conflict — but running the
first Codex `--accept` before row 22 slice 4 lands produces a doc that carries a
2026-07-24 verification stamp next to a claim that is about to become false.
**Land row 22 slice 4 first, or re-run the Codex accept after it lands.** The
claude-code accept has no such dependency and can run at any time.

The **baseline itself has no ordering dependency on row 22.** The fingerprint is
taken over the vendor's on-disk key surface in `~/.codex/sessions`; row 22
changes no adapter, no parse path, and no file on disk (it adds a startup
backfill that reads rollout heads and writes `sessions.parent_session_id`), so
the observed bucket/key set is identical before and after it. Capturing the seed
baseline before row 22 is safe and does not need to be re-taken.

**Baseline/matrix desync is checked on read.** Because the two artifacts are
written in sequence, a `^C`, crash, or partial `git add` can leave them
describing different corpora. Before comparing anything, the check script
asserts `baseline.format` equals the matrix key and
`baseline.vendorVersions.max === matrix.max_verified_version`. On mismatch:
exit 1, `baseline/matrix desync for <format>: baseline X, matrix Y — re-run accept`,
no diff printed for that format.

An accept is **not** the end of triage when the drift is semantic — i.e. when
the new record kind is something Engram should parse. That case additionally
requires a line appended to `tests/fixtures/<source>/new-types.jsonl` (which
already exists for claude-code) and a named case in
`macos/EngramCoreTests/AdapterSchemaDriftTests.swift`. The script prints that
requirement whenever a *new bucket* (as opposed to a new key on an existing
bucket) is accepted.

That path writes to the **hand-written** `tests/fixtures/<source>/` tree only.
It must never touch `tests/fixtures/adapter-parity/<source>/`, whose inputs and
goldens are regenerated from `src/adapters/*.ts` by
`scripts/gen-adapter-parity-fixtures.ts` and diffed in CI by
`scripts/check-adapter-parity-fixtures.ts` — editing that tree forces TypeScript
work and breaks the byte-diff. `docs/codex-native-parentage-design-2026-07.md`
(row 22) states the same prohibition from the other side; the two are
consistent.

### `unknownRecordKinds`: counted, asserted, not persisted

`ClaudeCodeAdapter` gains a `knownIgnoredRecordKinds: Set<String>` constant
covering the record kinds we deliberately drop, and the two gate sites at
`:384-388` and `:674-678` accumulate kinds outside that set.

The set is seeded from the **union** of (a) the live-corpus measurement in the
Problem section and (b) every `type` present in the committed claude-code
fixtures, because neither alone is complete — `agent-name` is in the corpus but
not the 40-newest window, and `system` is in the fixtures at 55% live prevalence
but was missing from the first draft of the corpus enumeration. The literal:

```swift
private static let knownIgnoredRecordKinds: Set<String> = [
    "agent-name", "ai-title", "attachment", "file-history-delta",
    "file-history-snapshot", "last-prompt", "mode", "permission-mode",
    "pr-link", "queue-operation", "result", "started", "summary", "system",
]
```

(`started` and `result` come from the subagent transcripts, which
`excludeGlobs` removes from the fingerprint corpus but which the adapter still
parses. `summary` is included pre-emptively; if it is not observed by slice 4 it
is dropped, since an over-broad allowlist silences signal.)

Storage decision: **do not persist.** The set is returned as data on
`IndexingScan` and asserted in a Swift test. `IndexingScan`
(`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:224-241`) declares an
**explicit** `public init(info:messages:checkpointParsedOffset:checkpointBoundaryHash:)`
at `:230-241`, not a synthesized memberwise init, so slice 4 must add both the
stored property (`public var unknownRecordKinds: Set<String> = []`) **and** a
trailing defaulted parameter on that init — adding the property alone leaves the
field permanently empty at every construction site. All 7 construction sites
repo-wide use labeled arguments
(`ClaudeCodeAdapter.swift:241`, `CodexAdapter.swift:681`,
`SessionAdapter.swift:357`, `IndexerParseOnceTests.swift:1106`,
`IndexerPerformanceTests.swift:223`,
`ArchiveV2ServiceCoordinatorTests.swift:3274` and `:3396`), so a trailing
defaulted parameter is source-compatible.

**Coverage is claude-code-source-only, deliberately.** The counter is populated
only by `ClaudeCodeAdapter.scanForIndexing`
(`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:217`).
`ClaudeCodeDerivedSourceAdapter` (`:997`, the wrapper for `minimax` and
`lobsterai`) overrides only `parseSessionInfo` / `streamMessages` /
`streamMessagesWithMetadata` (`:1041`, `:1052`, `:1059`) and takes the protocol
default `scanForIndexing` (`SessionAdapter.swift:347-357`), which constructs a
fresh `IndexingScan` with no access to the accumulator — so those two sources
report an empty set. Accepted rather than fixed: all three sources read the same
on-disk format, the fingerprinter already covers them from one baseline, and a
forwarder would be code with no additional signal. The baseline's
`"sources": ["claude-code", "minimax", "lobsterai"]` describes *format*
coverage, not counter coverage.

Rationale for not persisting:

- Adapters compile into EngramCoreRead and reach the database only through
  `IndexingWriteSink`. `scripts/check-app-mcp-cli-direct-writes.sh:63-73`
  rg-scans `macos/Shared`, so any write inside an adapter hard-fails invariant
  1's gate.
- A new `file_index_state` column costs an idempotent migration kept aligned
  with the inline CREATE TABLE, under invariant 11, for a counter with no
  reader.
- The existing dormant `metrics` table
  (`macos/EngramCoreWrite/Database/EngramMigrations.swift:336-348`) is not
  covered by `ObservabilityRetention.prune`, which deletes only from
  `ai_audit_log` and `usage_snapshots`
  (`macos/EngramCoreWrite/ObservabilityRetention.swift:48-49`). Routing there
  would ship an unbounded table to every user.

The counter's value is the **delta against the allowlist**, never the raw count.
A raw count fires on ten legitimate kinds on every healthy claude-code scan
(`attachment` at 38/40 files and `system` at 22/40 are the two highest-prevalence
ones), and on the committed parity fixture, which already contains a
`file-history-snapshot` record. The allowlist must land before or with the
counter, never after.

If a later slice does emit this via `os_log`, record-kind names must be marked
`privacy: .public`. Surrounding indexer log statements use `privacy: .private`
(`macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:81-83`, `:236-238`), which
would render every kind as `<private>` in `log show` and make the signal
unreadable.

### Implementation slices

Ordered. Each is independently landable and independently reverts.

**Slice 1 — support matrix + fingerprinter, claude-code and codex only.**
Adds `docs/session-formats/support-matrix.yml` (entries for all 15 formats;
`roots`/`glob`/`versionField` filled for claude-code and codex, the rest marked
`monitored: false`), `scripts/check-adapter-format-drift.ts`,
`scripts/baseline-adapter-format.ts`, two npm scripts
(`check:adapter-format-drift`, `baseline:adapter-format`), and two committed
baselines under `docs/session-formats/baselines/`.
*Done when*: `npm run check:adapter-format-drift` exits 0 with the clean-run
output above on the author's machine; exits 0 with
`0 of 2 monitored formats fingerprinted, 2 skipped — nothing was checked` when
`HOME` is pointed at an empty directory; `npm run lint`, `npm run knip`, and
`npm run typecheck:test` pass. The seed baselines are accepted at today's
corpus, so `max_verified_version` becomes `2.1.218` / `0.146.0-alpha.6` and
axis (b) is green at commit time.

**Slice 2 — freshness gate + comparator unit coverage.**
Adds `tests/scripts/adapter-format-drift.test.ts` driving the pure comparison,
freshness, and version functions over in-memory fixtures (no `~/` access, no
`~/.engram` access — see invariant 6 note below).
*Done when*: vitest cases cover DRIFT / novel-rare / missing (baseline
prevalence ≥ 0.5) / missing-suppressed (baseline prevalence < 0.5) /
stale-sample / stale-baseline / `stale_local_toolchain` / `no_local_sample` /
`blocked_required_type_absent` / baseline-matrix desync / unknown
`schemaVersion`, plus `compareVersions` over `0.146.0-alpha.10` vs
`0.146.0-alpha.6`, `2.1.9` vs `2.1.10`, `2.1.218` vs `2.1.58`, `2.2.0` vs
`2.1.218`, `0.146.0` vs `0.146.0-alpha.6`, and one unparseable input; and
`npm test` passes on a machine with no session corpus.

**Slice 3 — Swift codex drift guard test.**
Adds `macos/EngramCoreTests/AdapterSchemaDriftTests.swift` with the
`world_state` guard test, seeded from real shapes on disk. The Claude Code half
of the "both live drift cases covered" goal lands in slice 4, because it depends
on the `unknownRecordKinds` field.
*Done when*: `xcodegen generate` picks up the file with no `project.yml` change,
and the EngramCoreTests target passes.

**Slice 4 — `knownIgnoredRecordKinds` + counter in `ClaudeCodeAdapter`.**
The plumbing, stated explicitly because both gates live inside `private static`
pure functions with no accumulator parameter:

1. Add `private final class UnknownRecordKindSink: Sendable` mirroring the
   existing `UsageMessageIdSet` reference-type accumulator at
   `ClaudeCodeAdapter.swift:652`.
2. Add the `knownIgnoredRecordKinds` constant.
3. `aggregateSessionInfo(from:)` (`:375`, gate at `:384-388`) gains a sink
   parameter; its two call sites are `:274` and `:308`.
4. `message(from:seenUsageMessageIds:)` (`:670`, gate at `:674-678`) gains a
   sink parameter; its two call sites are `:661` (inside
   `makeMessageTransform()`, `:658`) and `:667` (inside `messages(from:)`,
   `:665`). `messages(from:)` therefore gains one too; its call sites are `:243`
   and `:273`.
5. The streaming paths at `:438` and `:455` pass a **discarded** sink — they
   have no `IndexingScan` to attach it to and their behavior is unchanged.
6. `scanForIndexing` (`:217`) passes one sink through `messages(from:)` at `:243`
   and reads it into the `IndexingScan` initializer at `:241`. Because both
   gates execute on that path, `unknownRecordKinds` must be a `Set`, not a
   count.
7. Add `public var unknownRecordKinds: Set<String> = []` **and** the matching
   trailing defaulted parameter on the explicit `IndexingScan` init
   (`SessionAdapter.swift:230-241`).

*Done when*: `bash scripts/check-app-mcp-cli-direct-writes.sh` exits 0 and
`npm test -- tests/scripts/product-boundary-scripts.test.ts` passes (invariant 1
gate unchanged), the two new Swift assertions pass, and no migration is added.

**Not in any slice**: extending the fingerprinter past claude-code and codex,
content-block drift, SQLite-backed formats (opencode/cursor/vscode need a
different fingerprint shape that is not designed here), and any operator surface
for `failure_kind`.

### Acceptance criteria

Criteria 1–5 are **manual smoke checks** against a live corpus; the
deterministic equivalents are slice 2's vitest cases over committed synthetic
fingerprints, which is where the pass/fail contract actually lives. Criteria 2
and 3 are driven from a single recorded run so the two sides share a
denominator.

1. Running `npm run check:adapter-format-drift` on a machine with a live
   claude-code and codex corpus exits 0, prints one `ok` line per monitored
   format, prints no `DRIFT` and no `BLOCKED` line, and ends with a summary
   containing `2 of 2 monitored formats fingerprinted`. Zero or more `note` /
   `info` lines are permitted (this is not an exact-line-count assertion).
2. Record the per-key **observed** prevalence log from one run (slice 1 logs it
   for every key; see Risks). Pick a key the run reports at prevalence 1.0,
   remove it from the committed baseline, re-run: exit 1 with exactly one
   `DRIFT` line naming that key at `30/30 (100%)`.
3. From that same recorded run, pick a key reported at observed prevalence below
   0.5, remove it from the committed baseline, re-run: exit 0 with exactly one
   `note` line naming it. Selecting by the baseline's recorded count instead
   would be non-deterministic, because the baseline denominator is
   `baselineFiles: 200` and the run's denominator is `observeFiles: 30`.
4. Lowering `max_verified_version` for codex in the support matrix makes the
   command exit 1 with `blocked_stale_baseline` **and still print the full
   diff** under the `untrusted diff follows` marker.
5. Running with `HOME` pointed at an empty directory (no root exists) exits 0
   and prints only `skipped (no corpus at …)` lines followed by
   `… 0 of 2 monitored formats fingerprinted, 2 skipped — nothing was checked`.
   The summary must not contain the token `ok`.
6. Pointing the claude-code matrix entry's `requiredTypes` at a value present in
   no file (e.g. `["user-v2"]`) exits **1** with
   `blocked_required_type_absent`, naming the scanned file count and the absent
   types. This is the case criterion 5 must never be confused with.
7. No baseline file contains any string matching
   `/[\\/]|\.(md|ts|swift|json|jsonl)$/` as a key name.
8. `bash scripts/check-app-mcp-cli-direct-writes.sh` exits 0 after slice 4. This
   is the invariant 1 enforcer itself (`docs/invariants.md:9`), whose pattern is
   strictly broader than any hand-written `rg` — it also catches `.write  {`
   with extra whitespace and literal `sql: "UPDATE …"`. For reference, that
   pattern currently returns **zero** hits under
   `macos/Shared/EngramCore/Adapters/`.
9. `git grep -c 'Last researched' docs/session-formats/` is unchanged **in
   count**, and after an accept the stamp in every file listed in that format's
   matrix `docs` list has advanced to the accept date while no other format's
   stamp changed. This design updates the stamps; it does not add or remove
   them.
10. `dist/` after `npm run build` contains no file whose path contains
    `adapter-format-drift`.

## Invariants affected

**None.** The ledger is not amended by this design, and no entry in
`scripts/invariant-gates.json` is added.

(Integration note, 2026-07-24: the three sibling mirror specs *do* amend
`docs/invariants.md` — row 1 appends a new entry 14, row 2 amends entry 3, row
22 amends entries 2/3/9/10. This spec adds nothing to the ledger, so it has no
merge surface there; if it lands last as sequenced, no rebase is needed at all.)

Justification per potentially-adjacent entry:

- **Invariant 1 (Single-Writer Discipline)** — slice 4 adds no write. The
  counter is returned as data on `IndexingScan` and consumed by a test. The
  existing gate `scripts/check-app-mcp-cli-direct-writes.sh` continues to scan
  `macos/Shared` (`:67`) unchanged and must stay green (acceptance criterion 8).
- **Invariant 6 (Tests Avoid Production Engram Data)** — the drift script reads
  `~/.claude/projects` and `~/.codex/sessions`, never `~/.engram`. It is a dev
  script under `scripts/`, not a test. Slice 2's vitest coverage drives pure
  functions over in-memory fixtures and must not be given a homedir path;
  wiring the corpus walk into vitest would both violate invariant 6's spirit
  and be vacuous in CI.
- **Invariant 7 (Bundle Hygiene Excludes Node Artifacts)** — unaffected and
  independently reinforced. `tsconfig.json` sets `rootDir: "src"` and
  `include: ["src/**/*"]`, so `npm run build` never compiles `scripts/`. The
  `Engram` app target's only declared resource is `Engram/Resources/Assets.xcassets`
  (`macos/project.yml:163-164`) and its postbuild scripts copy three Swift
  helpers (`macos/project.yml:178-187`) and replace `AppIcon.icns`
  (`:188-189`); none touch Node artifacts. A `scripts/*.ts` file cannot reach
  the bundle.
- **Invariant 11 (Sessions Schema Migrations Are Idempotent)** — no migration is
  added. This is the explicit reason the counter is not persisted.
- **Invariant 13 (JSONL Tail Checkpoints Stop at Complete Lines)** — the script
  only opens session files read-only and never touches `parsed_offset` or
  `boundary_hash`. Stated explicitly so nobody assumes the fingerprinter shares
  the tail-checkpoint path.

## Alternatives considered

**Diff real sessions against `tests/fixtures/adapter-parity/`.** Rejected on
measurement, not principle: the committed claude-code parity input pins
`"version":"2.1.58"` and exposes **9** distinct top-level keys on `user` records
(`cwd`, `message`, `permissionMode`, `sessionId`, `timestamp`, `todos`, `type`,
`uuid`, `version`), while the union across the 12 newest live sessions is **26**.
A real-vs-synthetic diff reports 18 false unknown keys on the first record type
alone.

**Fingerprint synthetic corpora instead of real sessions.** Rejected on outside
evidence. Agent Sessions' own matrix records a 2026-07-17 run where a green
synthetic/pre-bump fingerprint reported `fresh_matches_baseline=True` while the
weekly scan of real sessions correctly flagged the Claude `mode` record — the
one-shot synthetic driver never emits interactive-only records. The people who
tried it wrote down why it failed.

**Make the check a CI job or an invariant gate.** Rejected as decisive.
`scripts/invariant-gates.json` accepts only `["bash", "scripts/<name>.sh"]`
argv, and `tests/scripts/invariants-ledger.test.ts` executes registered gates
inside the `macos-vitest` job on `macos-15` (`.github/workflows/test.yml:107`,
`:125`). A GitHub-hosted runner has no session corpus, so the gate would either
fail on every heavy PR or report vacuous green forever — the exact rot mode the
uniform `2026-06-21` stamp already demonstrates.

**Run it on the self-hosted `macmini-m1` runner** (which does have a real
corpus; see `scripts/sync-from-macmini.sh`). Rejected for now on data-handling
grounds: that machine's transcripts are the user's real work, and CI logs and
uploaded artifacts are retained. Revisit only with an explicit
names-and-counts-only output contract; the script already never prints content,
so this is a scheduling decision, not a redesign.

**Declare discovery-path contracts in `SourceCatalog.swift` (mirror item e).**
Cut. `macos/Engram/Models/SourceCatalog.swift:26-44` is an app-target UI mirror
consumed only by `SourcePulseView`, carries a single scalar `defaultPath` per
source, and `macos/EngramTests/SourceCatalogTests.swift` never asserts that path
against the adapter. It is wrong for antigravity (three roots, one of them a
dot-directory) and for claude-code (runtime-configurable multi-root profiles via
`ClaudeCodeProfileResolver`), and it is unreachable from `scripts/`. Probe
config lives in the support matrix instead.

**Persist `unknownRecordKinds` to `file_index_state` or `metrics`.** Cut for
this design; see the storage rationale under Proposed design.

**Emit a digest-only fingerprint.** Rejected: a digest says something changed
without saying what, which converts every vendor patch release into manual
bisection.

**TypeScript vs Swift for the script.** TypeScript, argued explicitly.
`CLAUDE.md` forbids Node in the *product* path; `scripts/` is provably outside
it (invariant 7 paragraph above, plus acceptance criterion 10). `scripts/` is
already TypeScript with tsx, biome, and knip configured
(`knip.json` globs `scripts/**/*.ts` as entry, so no exemption is needed), and
`scripts/baselines-generate.ts` is the existing precedent for a local-only,
homedir-reading, CI-never script that produces committed baselines. A Swift CLI
would need a new target, a build step, and a distribution story for a script
that runs on a maintainer's laptop.

## Test plan

**Slice 3 — `macos/EngramCoreTests/AdapterSchemaDriftTests.swift`** (new file,
joins the target automatically per `macos/project.yml:60-68`). House pattern for
fixtures in this target is inline temp dirs —
`FileManager.default.temporaryDirectory.appendingPathComponent("engram-…-\(UUID().uuidString)")`
with a `defer { try? FileManager.default.removeItem(at:) }`, as used throughout
`macos/EngramCoreTests/AdapterParityTests.swift:6-16`. The
`sessionInfo(_:)` / `parseFailure(_:)` / `drain(_:locator:)` / `jsonLine(_:)`
helpers at `macos/EngramCoreTests/AdapterMessageCountTests.swift:15-51` are
`private` to that class, so the new file re-declares the two it needs
(`jsonLine`, `sessionInfo`); that duplication is the existing house pattern, not
new debt.

- `func testCodexWorldStateRecordDoesNotSuppressVisibleMessages()` — **guard
  test, not a repro; the `_repro` suffix is deliberately not used** because
  `CLAUDE.md` reserves it for a test that is red before a fix and green after,
  and this one passes before and after slice 3. Writes a rollout with
  `session_meta`, one `response_item` user turn, one `response_item` assistant
  turn, and a `world_state` record interleaved. Asserts `scanForIndexing`
  returns `.success` and
  `info.userMessageCount == 1 && info.assistantMessageCount == 1`. Its standing
  job is to pin the accepted-drift decision so a later "handle world_state"
  change cannot silently regress counts.
- `func testClaudeCodeUnknownRecordKindIsCountedNotDropped_repro()` (lands with
  slice 4) — writes a transcript containing one `user`, one `assistant`, and one
  `"type":"copilot-usage-checkpoint"` record. Asserts
  `scan.unknownRecordKinds == ["copilot-usage-checkpoint"]` and that message
  counts are unchanged. **Fails before slice 4** (the field does not exist),
  passes after. This is the only `_repro` in the plan.
- `func testClaudeCodeKnownIgnoredRecordKindsCoverFixtureCorpus()` (slice 4) —
  parses **every** committed claude-code JSONL fixture and asserts
  `scan.unknownRecordKinds.isEmpty` for each. Scoping it to
  `tests/fixtures/claude-code/new-types.jsonl` alone would be insufficient: that
  file carries `attachment`, `last-prompt`, `permission-mode`,
  `queue-operation`, `file-history-snapshot` but **no `system` record**, so a
  55%-live-prevalence false positive would ship with every test green. The
  explicit file list:
  `tests/fixtures/claude-code/new-types.jsonl`,
  `tests/fixtures/claude-code/schema_drift.jsonl` (`system`),
  `tests/fixtures/claude-code/session-with-usage.jsonl` (`system`),
  `tests/fixtures/claude-code/sample.jsonl`,
  `tests/fixtures/claude-code/tool-formatting.jsonl`,
  `tests/fixtures/claude-code/with-tools.jsonl`, and
  `tests/fixtures/adapter-parity/claude-code/input/-Users-test-my-project/sample.jsonl`
  (`file-history-snapshot`). This is the guard that keeps the counter from being
  noise on day one.

**Slice 2 — `tests/scripts/adapter-format-drift.test.ts`** (new file, vitest).
Exports from `scripts/check-adapter-format-drift.ts` are driven directly over
literal fingerprint objects: `compareFingerprints(baseline, observed)` and
`evaluateFreshness(matrixEntry, observed)`, plus the exported
`compareVersions(a, b)`. Cases:

- high-prevalence new key → one DRIFT;
- low-prevalence new key → one note;
- baseline key at baseline prevalence ≥ 0.5 absent from observed → one info,
  exit 0;
- baseline key at baseline prevalence < 0.5 absent from observed → **no line at
  all** (this is what keeps a 200-vs-30 comparison from emitting a long info
  tail on every healthy run);
- observed version above `max_verified_version` → `blocked_stale_baseline` with
  the diff list **non-empty and still returned**;
- observed version below `max_verified_version` → `stale_local_toolchain`,
  exit 0, diff returned;
- unparseable version string → `blocked_stale_baseline`, never green;
- newest mtime beyond the window → `blocked_stale_sample`;
- `rootsPresent == 0` and `globMatches == 0` → `no_local_sample`, exit 0;
- `globMatches > 0` and `corpusFiles == 0` → `blocked_required_type_absent`,
  exit 1;
- `baseline.vendorVersions.max !== matrix.max_verified_version` → desync error,
  exit 1, no diff;
- unrecognised `schemaVersion` → hard fail, exit 1, no diff;
- `compareVersions`: `0.146.0-alpha.10` > `0.146.0-alpha.6`; `2.1.10` >
  `2.1.9`; `2.1.218` > `2.1.58`; `2.2.0` > `2.1.218`; `0.146.0` >
  `0.146.0-alpha.6`; `"nightly"` → unparseable.

No filesystem access outside a vitest temp dir.

**Intentionally not tested**: the corpus walk itself, and end-to-end behavior
against `~/.claude/projects`. Both depend on machine-local state that CI cannot
reproduce; acceptance criteria 1–6 are the manual verification for them and must
be recorded in the PR description with pasted output.

## Rollout

No version bump, no migration, no service or app rebuild required for slices
1–3. Slice 4 changes `ClaudeCodeAdapter`, so it takes effect on the next app +
service build; behavior is unchanged for every existing record kind, and the new
field is additive with a default.

Baselines are seeded from the author's live corpus at accept time, which means
slice 1 ships green on both freshness axes rather than permanently red — the
doc-stamp axis (c) is warn-only precisely so the uniform `2026-06-21` stamp does
not block adoption.

Revert story: slices 1–3 are pure additions under `scripts/`, `docs/`, and
`macos/EngramCoreTests/`; deleting the files and the two npm script entries
restores the prior state exactly. Slice 4 is **not** a two-line revert, because
the accumulator threads through private signatures: reverting means deleting
`UnknownRecordKindSink` and the constant, removing the sink parameter from
`aggregateSessionInfo(from:)`, `messages(from:)`, and
`message(from:seenUsageMessageIds:)` and from their six call sites
(`ClaudeCodeAdapter.swift:243`, `:273`, `:274`, `:308`, `:661`, `:667`), and
removing the defaulted `IndexingScan` property plus its init parameter. All of
it is compiler-checked and none of it is persisted, so the revert is mechanical
— but it is a dozen edits, not two.

Cadence and ownership: the check is run manually before tagging a release and
whenever a vendor CLI is upgraded. Prior art runs the equivalent weekly by hand
and *not* in CI, and their matrix carries 20+ dated "weekly check: bumped X→Y"
notes — each a human decision. A drift finding becomes work by appending an
entry to `docs/followups.md` naming the format, the new buckets or keys, and
whether the accept was cosmetic or semantic; that file is on the CI docs
fast-path allowlist (`.github/workflows/test.yml:46`) so routing a finding is
cheap.

## Risks and open questions

**Risk — the accept path becomes a rubber stamp** (medium likelihood, medium
impact after revision). If `--accept` is easier than triage, every drift is an
instant baseline rewrite. Machine-enforced mitigations: `--note` is mandatory,
`--accept-drift` is required whenever any delta is DRIFT-class, and
`--allow-stale-sample` is required on a stale corpus. Not machine-enforced:
accepting a *new bucket* prints a hard requirement for a `new-types.jsonl` line
plus a named Swift case, but nothing checks that the operator complied. That
remains the design's weakest joint and should be reviewed after the first real
drift.

**Risk — the 0.5 prevalence threshold is calibrated on one machine** (medium /
medium). It cleanly separates the two clusters in both local corpora at n=12,
but was not swept at n=30 or n=200, and a heavier-MCP or different-entrypoint
corpus may cluster differently. Slice 1 should log observed prevalence for every
new key, drift or not, so the threshold can be re-tuned from evidence.

**Risk — a baseline committed from one maintainer's machine bakes in one
install** (medium / medium). Per-source sample ages on this machine span two
orders of magnitude (claude-code 0.0d, iflow 147.2d). Two maintainers running
the check will disagree, and the disagreement will look like drift. Scoping
slice 1 to the two formats with fresh corpora on any active machine contains
this; it will bite when the matrix is extended.

**Risk — head+tail sampling still misses mid-file-only kinds** (low / low). The
largest observed codex rollout is 45,131 lines; head 200 + tail 800 covers 2.2%
of it. A vendor kind appearing only mid-session is invisible. Accepted: the
corpus is 30 files, so a kind must be mid-file-only in *all* of them to hide.

**Open question — does the `macmini-m1` self-hosted runner execute as a user
whose `HOME` contains the session corpus?** `scripts/sync-from-macmini.sh:7,35-47`
proves the *host* holds `~/.claude/projects` and `~/.codex/sessions`; it does not
prove the runner process can read them. Unverified — no SSH was performed. Must
be confirmed before any scheduled-run proposal.

**Open question — how do the SQLite-backed formats (opencode, cursor, vscode)
get fingerprinted?** Their table and column surface was confirmed
(`session.version` = 1.18.3 for opencode; `ItemTable` / `cursorDiskKV` for the
others) but their parse paths were not read, and a row-shaped fingerprint needs a
different descent ladder than a JSONL one. Not designed here. Note these are also
the formats with zero `file_index_state` coverage, so they are doubly unmonitored.

**Open question — is Copilot's `auto_mode_resolved` / `usage_checkpoint` drift
reproducible locally?** The newest local `~/.copilot/session-state/*/events.jsonl`
reports `data.copilotVersion` 1.0.65 — the same version Agent Sessions says emits
those records — yet neither appears in our sample, and the file is 26 days old.
Either the events predate the drift within one version, or the drift is
config-gated. Unresolved; this is why the Swift drift tests are seeded from Codex
`world_state` and Claude Code lifecycle records rather than from Copilot.

**Resolved (was open) — does adding a defaulted field to `IndexingScan` break
any construction site?** No. All 7 sites repo-wide were enumerated and all use
labeled arguments; the init is explicit, not synthesized, so slice 4 adds the
parameter to it. Full list under *`unknownRecordKinds`: counted, asserted, not
persisted*. Slice 4 must still compile-check all targets, not just
EngramCoreRead.

**Resolved (was open) — which of the `.md` / `.zh.md` pair is authoritative for
the doc-staleness axis?** Neither; the matrix carries a `docs` **list** and axis
(c) evaluates every file in it. This also gives the four derived-source docs
(`minimax`, `lobsterai`) coverage they would not have had under a single-`doc`
field.

**Resolved (was open) — do the two `ClaudeCodeAdapter` gate sites both execute
in the parse-once `IndexingScan` path?** Yes. `scanForIndexing` (`:217`) reaches
`messages(from:)` at `:243` (gate at `:674-678`) and `aggregateSessionInfo` at
`:308` (gate at `:384-388`). This is why `unknownRecordKinds` must be a `Set`,
not a count, and why the accumulator must be a shared reference type rather than
two independent locals.

**Reviewer claim rejected — "only 3 of 15 parsers guard against a zero-visible-message
parse."** One reviewer derived this from `rg -c noVisibleMessages`, which is a
narrower criterion than the claim it tests. `AntigravityAdapter.swift:219-220`
and `CopilotAdapter.swift:108-109` both carry a real
`guard … userCount + assistantCount + toolCount > 0 else` — they simply map it
to `.malformedJSON`. The count of guards is 5; the count of *terminal* guards is
3. Both figures now appear in Current state, with the retry-loop consequence
spelled out, because the distinction matters to the harm model.

**Reviewer claim rejected — "the codex baseline's `sources` list overstates
`unknownRecordKinds` coverage, so add a `scanForIndexing` forwarder to
`ClaudeCodeDerivedSourceAdapter`."** The observation is correct and verified
(`ClaudeCodeAdapter.swift:997` declares no `scanForIndexing`;
`SessionAdapter.swift:347-357` is the default it inherits), but the proposed
forwarder is rejected as scope: minimax and lobsterai read the same on-disk
format as claude-code, so the counter would report the same kinds from the same
allowlist and add no signal. The asymmetry is documented instead.

**Noted, out of scope** — the live database holds 3,819 `file_index_state` rows
under source values that are not `SourceName` cases at all (`glm` 2359,
`deepseek` 569, `grok` 359, `mimo` 272, `pi` 230, `doubao` 30), all frozen around
2026-07-02/03. Any future reader keyed on `source` must enumerate from
`SourceName`, not `SELECT DISTINCT source`, and must distinguish "clean" from
"not a live source". Whether these are expected residue from the Grok alias
cleanup (`f8719b6c`) or an unreported regression is unverified.
