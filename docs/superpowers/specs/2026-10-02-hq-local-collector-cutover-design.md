# Design Doc: HQ-local collector and cutover completion

- **Status**: Draft (for owner authorization or redirection). Phase P1 (the §2 role gate, DECISION D8) is implemented in source with its `_repro` test and ledger entry "Legacy Host Scan Runs Only in the Local Role"; it is not deployed. Phase P0 measurements are done (results summarized in `CHANGELOG.md`, 2026-10-02): the cross-machine overlap is byte-identical or divergent, never a prefix, so §3 option B+ is not needed; the legacy `origin=local` rows have no user-state dependents; `pi` already overlaps Daily's capture, so use `grok` as the R6 canary.
- **Owner**: Engram maintainers (drafted 2026-10-02 for the cutover lead)
- **Date**: 2026-10-02
- **Related**: [Collector/Server/Web design](2026-09-05-collector-server-web-design.md)
  (DESIGN), [implementation plan](../plans/2026-09-05-collector-server-web.md)
  (PLAN), [source-retirement checklist](../../reviews/2026-09-07-collector-source-retirement-checklist.md)
  (CL), [invariants ledger](../../invariants.md).

## Reading conventions

- Code anchors are `path:line` at commit `00bb5809` (HEAD of `main` when this
  was written). DESIGN, PLAN and CL line numbers are taken from the committed
  HEAD version of those files. Other agents were editing those files in the
  working tree at the same time, so working-tree line numbers may differ.
- **Fact** means the author read the cited source line. **Runtime** means an
  observation from the read-only HQ runtime audit of 2026-10-02. That audit is
  not committed, and its counts are point-in-time. **INFERRED** means derived
  from code or observations without execution. **UNVERIFIED** means not
  checked. **Proposal** and **DECISION** mark design content and the questions
  the owner must answer.
- The repository is public, so hosts are named by role only: *Daily* (the
  owner's daily Mac), *HQ* (central index and receiver) and *M1* (the
  independent archive replica). The doc gives no host names, addresses,
  machine IDs, process IDs or credentials.

## Problem

The owner's intent is "thin client + central server": every Mac runs a
collection worker, and HQ is the server that collects the data. DESIGN already
puts an HQ collector for HQ-local sources in the role table
(DESIGN:213) and in the host order ("first the daily Mac, then HQ-local and
M1-local coverage", DESIGN:660-661). Neither piece has been built out or
deployed.

Observed state (Runtime unless marked otherwise):

1. Only Daily has ever fed HQ. Its last arrival was 2026-09-22 02:21 UTC. The
   HQ ingest poller keeps advancing its checkpoint timestamp but receives
   nothing new. Cause (verified on Daily, 2026-10-02): a reboot renumbered the
   data volume's `st_dev`, every stored root binding failed its identity
   check, and the collector silently suspended all roots. See
   `2026-10-02-collector-volume-identity-design.md`. The same trap applies to
   an HQ collector, so "still capturing after a reboot or OS update" belongs
   in the acceptance checks below.
2. HQ's central index service runs in the `index` role. An environment
   override disables the legacy filesystem scan for 17 of 19 sources, so it
   scans only HQ's own `grok` and `pi` directories. Those rows land as
   `origin=local` (about 6,140 rows), are not attributed to any machine
   stream, and are invisible to the capture-bound Web reader (Fact:
   `macos/EngramService/Core/ServiceWebMetadataProducer.swift:2651-2657`).
3. HQ's own Claude Code and Codex sessions do not reach the central index.
   They are indexed only by the old local service into its own DB, on a
   roughly hourly periodic cycle. An apparent stall after 2026-09-29 was a
   period with no new HQ transcripts, not a defect.
4. HQ has no collector binary, plist or process.
5. The old local stack still runs beside the new pair: the old `EngramService`
   under a system boot daemon, the old plain-HTTP hub, and a watchdog that
   restarts both. `/Applications/Engram.app` is a March 2026 Node-era build.
6. About 6,000 Claude Code and 3,000 Codex native session IDs exist both in
   Daily's central capture and on HQ's own disk. This is copied or shared
   history. A naive HQ collector would publish them a second time under
   another machine stream.

## Goals / Non-goals

Goals:

1. Run `EngramCollector` on HQ beside the index-role `EngramService`, using
   the existing code paths. Every HQ session reaches the central DB through
   capture exactly once.
2. Make it impossible for one HQ session to be stored once by the legacy scan
   and once by capture. The protection must not depend on an environment
   variable that someone might forget to set.
3. Define what happens to native session IDs that also exist on another
   machine, and build no more than the smallest correct mechanism.
4. Provide the minimum in-repo tooling to install, upgrade and roll back a
   collector, and the HQ index/receiver pair, from the repository.
5. Provide an ordered, reversible, owner-authorized HQ cutover runbook, plus
   checkable "done" criteria for Daily, M1 and the whole cutover.

Non-goals:

- No fixes for Daily's silent feed or the old local index stall. Both causes
  are unknown, and this doc lists only the checks to run.
- No W4.1 alias reconciliation, no W4.5 old-receipt bootstrap, and no W4.7
  operator epoch command, except where a DECISION below explicitly asks for
  one.
- No change to the Web authority model, the archive-v2 legacy receipts or
  reclamation semantics, or the collector CPU work.
- No Node product path, no sqlite-vec in the Swift product, no direct App or
  MCP SQLite writer, no tier change for subagents, and no Docker.
- No host mutation without fresh owner authorization (PLAN:1203-1219).

## Current state

### Roles and co-hosting (Fact)

- **Roles.** `local | collector | index | replica | invalidSettings`. A
  missing key means `local`, and only `local` and `index` allow a local index
  (`macos/Shared/EngramCore/RuntimeRoleSettings.swift:5-12`, `:61-69`). The
  settings file is `ENGRAM_SETTINGS_PATH`, else `CFFIXED_USER_HOME`, else
  `~/.engram/settings.json` (`RuntimeRoleSettings.swift:25-43`).
- **Collector settings.** The collector reads only the file passed with
  `--settings` (`macos/EngramCollector/main.swift:12-50`).
  - That file must contain `runtimeRole:"collector"` and an enabled
    `collector` block with exactly seven keys
    (`macos/EngramCollectorCore/CollectorRuntime.swift:749-760`).
  - The block must have exactly two replicas with server IDs `{hq, m1}`,
    distinct credential IDs and distinct endpoints (`CollectorRuntime.swift:789-792`).
  - The two bearer tokens must differ (`CollectorRuntime.swift:128`).
  - Endpoints must be `https`, or `http` only for `127.0.0.1` / `[::1]`
    (`CollectorRuntime.swift:907-913`). An HQ collector can therefore upload
    to its co-hosted receiver over loopback HTTP, and it still needs an M1
    HTTPS endpoint.
- **Index-role capture ingest.** Capture ingest reads the file at
  `ENGRAM_SETTINGS_PATH`. It accepts a missing role, `local` or `index`, and
  credential IDs `hq` or `m1`
  (`macos/EngramService/Core/ServiceCaptureIngestRuntime.swift:219-227`). The
  packaged index wrapper exports that variable
  (`macos/EngramService/Packaging/run-engram-service-index.zsh.template:93`).
  Separate settings files therefore make co-hosting legal.
- **Co-hosting is already exercised.** The opt-in real-binary shadow test
  runs a collector with its own settings and credentials file
  (`macos/EngramServiceCoreTests/CollectorBinaryShadowIntegrationTests.swift:389-397`).
  It uploads over `http://127.0.0.1:<port>` (`:285`) to an index-role service
  that has a separate settings file (`:485-503`). That test skips unless
  three binary paths are set (`:104-108`), so CI never runs it.
- **Identity.**
  - `--initialize-identity` creates a *new* catalog with a fresh UUID. It is
    for first-machine provisioning only
    (`macos/EngramCollectorCore/CollectorIdentityInitializer.swift:5-8`, `:65`).
  - Existing hosts borrow their catalog. `--initialize` creates a spool from
    the configured existing identity (`main.swift:62-70`, `:78-80`;
    `macos/EngramCollectorCore/CollectorSpoolInitializer.swift:20-22`).
  - DESIGN:245-254 requires a previously archived host to reuse its existing
    `archive_metadata.machine_id`.
  - HQ's old service has `~/.engram/archive-v2/archive.sqlite` open (Runtime).
    Whether that file holds a `machine_id` row is UNVERIFIED.
- **Identity on every start.** Every collector start re-reads the borrowed
  catalog (`macos/EngramCollectorCore/CollectorInventoryOwner.swift:137`,
  `:159`). For a WAL-mode catalog, the reader refuses to run if the `-wal`
  or `-shm` sidecars are missing
  (`macos/EngramCollectorCore/CollectorMachineIdentityReader.swift:39-50`).
- **Storage separation.** The spool and the identity-catalog directory must
  not be ancestors of each other (`CollectorInventoryOwner.swift:1221-1230`).
  Roots must not overlap either of them (`CollectorRuntime.swift:786-787`).
- **Source instances.** Source-instance IDs and epochs are allocated lazily,
  on the first capture per root/revision/source, inside the collector spool
  (`macos/EngramCollectorCore/CollectorInventoryStore.swift:640-650`).
- **HQ-side authority.**
  - HQ source authority is provisioned only at service startup, from
    `--capture-source-authority-file`
    (`macos/EngramService/Core/EngramServiceRunner.swift:374-376`, `:449-454`).
  - Provisioning requires the explicit `index` role, and every entry's source
    must be enabled in the settings `disabledSources` policy. A disabled
    source throws and aborts startup
    (`macos/EngramService/Core/ServiceCaptureSourceAuthority.swift:53-59`, `:89-109`).
  - The packaged index wrapper has no slot for that flag
    (`run-engram-service-index.zsh.template:20`, `:45-48`). The live HQ job
    passes it anyway (Runtime), which means the live job was built outside
    the repo.
- **Unprovisioned publications stay pending.** The ingest worker claims a
  ledger row only when its machine/instance/epoch joins a provisioned
  registry row (`macos/EngramService/Core/ServiceCaptureIngestWorker.swift:304-345`).
  An unprovisioned publication therefore stays `pending`, is not quarantined,
  and becomes eligible after provisioning. Section 1 uses this as the shadow
  mechanism.
- **One token per receiver.** The receiver authenticates every collector with
  one archive token (`macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift:214-217`).
  It has no per-machine credential.

### Legacy scan versus capture (Fact)

- **The runner has no role check.** `EngramServiceRunner.swift` contains no
  `runtimeRole` reference, and these all run in every role:
  - the initial scan, `RUN:605-622` (RUN = `EngramServiceRunner.swift`);
  - the periodic loop, `RUN:626-639`;
  - `indexRecentSessions`, `RUN:1586-1594`.
- **How they choose adapters.** Each path calls `readDisabledSources` /
  `readDisabledSourceConfiguration`:
  - initial scan, `RUN:1927-1936`;
  - periodic loop, `RUN:1319-1322`, `:1413-1417`, `:1525-1529`, `:1563-1571`,
    `:1587-1590`;
  - archive-v2 drainer, `RUN:475-489`.
- **`ENGRAM_DISABLED_SOURCES`.** This variable fully replaces the settings
  list (`RUN:2749-2758`), and the code documents it as "honored for
  tests/dev" (`RUN:2724-2726`).
- **Capture policy reads only settings.** Capture policy reads settings
  `disabledSources` and never reads the environment variable
  (`ServiceCaptureIngestRuntime.swift:233-241`). Two tests pin that
  separation:
  - `macos/EngramServiceCoreTests/WebSourceSettingsTests.swift:115-132`
    (`testEnvOverrideDoesNotReplaceCapturePolicyProjection`);
  - the comment at `macos/EngramServiceCoreTests/ServiceCaptureIngestRuntimeTests.swift:340-342`.
- **Settings `disabledSources` is not a substitute.** A toggle disables both
  paths. It also hides *all* rows of that source, capture rows included, by
  running `UPDATE sessions SET hidden_at … WHERE source = ?`
  (`macos/EngramService/Core/EngramServiceCommandHandler.swift:1676-1680`).
- **Fail-open default.** Today an index-role service started without the
  environment variable scans every enabled source in the real home.

### Identity and cross-machine copies (Fact)

- **Stored ID.** The stored session ID is
  `remote:capture-v1.<machine>.<sourceInstance>:<b64url([source,nativeID])>`
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestIdentity.swift:33-44`;
  `macos/EngramCoreWrite/RemoteSync/ImportRepo.swift:16-18`).
- **Binding key.** Bindings use the primary key
  `(machine_id, source_instance_id, source, native_id)`
  (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestCommitter.swift:174-184`).
- **Collision rule.** With no prior binding, the committer refuses only an
  *occupied proposed ID*: "Unrelated local/native IDs coexist"
  (`CaptureIngestCommitter.swift:92-96`). A copy from another machine
  proposes a different ID, so it never collides and creates a second
  `sessions` row and a second binding (`:107-120`). A test pins this
  behavior: `testMachineInstanceSourceAndExactNativeBytesKeepDistinctIdentities`
  (`macos/EngramCoreTests/CaptureIngest/CaptureIngestCommitTests.swift:2090-2109`).
  DESIGN:470-471 intends the same: "Two machines with an identical native ID
  cannot overwrite each other."
- **Root-overlap rules are per machine.** Overlapping roots are refused only
  within one machine (`macos/EngramCoreWrite/CaptureIngest/CaptureIngestSourceRegistry.swift:117-118`,
  `:174-177`, `:352-356`). They do nothing across machines.
- **Web lists every binding.** Each binding joins to its session
  (`ServiceWebMetadataProducer.swift:1446-1452`, registry join `:2371-2378`).
  A `sessionId` filter matches the stored ID *or* the native ID
  (`:2674-2677`), so both copies come back.
- **Collision error is not quarantined.** When `identityConflict` is thrown,
  the worker does not map it to a ledger quarantine: it rethrows
  (`ServiceCaptureIngestWorker.swift:222-233`). Cross-machine copies never
  reach that path.

### App and MCP on an index host (Fact)

- **App.**
  - The App always reads `<home>/.engram/index.sqlite` and the default
    socket. It takes its role from the default settings path
    (`macos/Engram/Core/AppEnvironment.swift:34-41`).
  - In the `index` role it never spawns a service
    (`macos/Engram/Core/EngramServiceLauncher.swift:223-228`).
  - DESIGN:229-230 forbids showing stale local DB contents as the central
    corpus.
- **MCP.**
  - EngramMCP takes the DB path from `ENGRAM_MCP_DB_PATH` (default
    `~/.engram/index.sqlite`) and the socket from `ENGRAM_MCP_SERVICE_SOCKET`
    / `ENGRAM_SERVICE_SOCKET`. Its role comes from the settings path, which
    `ENGRAM_SETTINGS_PATH` can override (`macos/EngramMCP/Core/MCPConfig.swift:9-36`;
    `macos/Shared/Service/UnixSocketEngramServiceTransport.swift:134-148`).
  - A custom socket uses a `<socket>.cmd.token` sidecar, so no token is
    copied (`macos/Shared/Service/ServiceCapabilityToken.swift:124-138`).
  - EngramCoreRead and EngramMCP contain no capture-binding awareness: a
    repository search for `capture_ingest` or `authoritative_node` returns
    nothing.
  - MCP `get_session` reads the transcript from `file_path`
    (`macos/EngramMCP/Core/MCPTranscriptTools.swift:16-41`;
    `macos/EngramMCP/Core/MCPDatabase.swift:2945`). For capture rows,
    `file_path` is the *origin machine's* logical locator
    (`macos/EngramCoreWrite/Indexing/AuthoritativeSessionSnapshotBuilder.swift:176`;
    `CaptureIngestCommitter.swift:107-109`).

### Packaging and host tooling (Fact)

- **Planner scope.** `scripts/plan-headless-install.mjs` plans a dry run only
  (`:2-3`, `:92`). It refuses any existing target, so it has no upgrade path
  (`:146-152`). It always plans `--initialize`, never
  `--initialize-identity`, and never checks for a catalog (`:229-238`).
- **Planner defects.**
  - It reports `disabled/runAtLoad:false/keepAlive:false` for every role
    (`:211-216`), but the remote-server plist sets `RunAtLoad` and
    `KeepAlive` to true and has no `Disabled` key
    (`macos/EngramRemoteServer/Packaging/com.engram.remote-server.plist.template:12-15`).
  - It binds only `__ENGRAM_REMOTE_ROOT__` (`:244-248`), so the
    `__ENGRAM_REMOTE_SOURCE_REVISION__` placeholder stays unbound
    (`run-engram-remote.zsh.template:28`).
  - Tests pin both defects (`tests/scripts/headless-install-plan.test.ts:208-213`,
    `:257-263`).
- **Label and Web gaps.**
  - The planner's remote-server label `com.engram.remote-server`
    (`plan-headless-install.mjs:22-27`) is the *old hub's* live label on HQ.
    The new HQ receiver runs under a label that exists only outside the repo
    (Runtime).
  - The remote wrapper sources only `legacy-v1.env` and `archive-v2.env`
    (`run-engram-remote.zsh.template:7-10`). The repo cannot render the live
    receiver's Web environment.
- **`scripts/hq-live` targets only legacy labels.**
  - It installs system boot daemons for `com.engram.service` and
    `com.engram.remote-server` (`scripts/hq-live/install-hq-boot-daemons.sh:13-14`,
    `:41-46`).
  - `ensure-hq-live` restarts the *old* hub and the *old* service. If
    launchctl fails, it falls back to `nohup`
    (`scripts/hq-live/ensure-hq-live:21-22`, `:95-106`, `:143-174`).
  - The repo ships `com.engram.hq-live-ensure.plist` with a 120-second
    interval (`scripts/hq-live/com.engram.hq-live-ensure.plist:5-14`). That
    interval matches the cadence observed in the logs. The Runtime label
    listing did not show this label, so its invoker remains UNVERIFIED.
- **`deploy-local.sh` kills by name.**
  `macos/scripts/deploy-local.sh:41-44` runs `pkill -TERM -x EngramService`
  by process name, which also matches an index-role service. The script then
  fails after 15 seconds when launchd respawns it (`:46-61`). The test at
  `tests/scripts/build-release-script.test.ts:270-288` pins the
  `BLOCKING_PROCESS_NAMES=(Engram EngramService)` line.

## Proposed design

### 1. HQ-local collection (co-hosted collector)

HQ runs three independently managed processes:

- `EngramService` in the `index` role (existing);
- `EngramRemoteServer` as receiver and Web (existing);
- `EngramCollector` (new on HQ).

Each has its own settings file. Proposal:

| Item | HQ value | Source rule |
|---|---|---|
| Collector settings | New owner-only file outside `~/.engram/settings.json`, containing `runtimeRole:"collector"` plus the seven-key `collector` block | `CollectorRuntime.swift:749-760`. It must not be the default path, or the App and MCP would see `collector` |
| Identity | `identityCatalog` = HQ's existing archive-v2 catalog. Run `--settings <file> --initialize`. **Never** `--initialize-identity` on HQ | `main.swift:78-80`; DESIGN:245-254. Pre-check that `archive_metadata.machine_id` exists (UNVERIFIED) |
| Spool | New private directory that does not overlap the catalog directory or any root | `CollectorInventoryOwner.swift:1221-1230`; `CollectorRuntime.swift:786-787` |
| Replica `hq` | `http://127.0.0.1:<receiver port>`, the loopback listener the receiver already uses (Runtime) | `CollectorRuntime.swift:912`. Removes the tailnet/TLS hop. Whether any receiver-side Host/Origin check applies to publication routes while Web is enabled is UNVERIFIED; the R5 probe below verifies it |
| Replica `m1` | M1's HTTPS collector endpoint | Required by the exactly-two-replicas rule (`:789-792`) |
| Credentials | Owner-only JSON `{credentialID: token}`, never in the repo. The `hq` token is the receiver's archive token. The `m1` token is M1's, and the two must differ | `CollectorRuntime.swift:120-128`; shape as in `CollectorBinaryShadowIntegrationTests.swift:394-395` |
| Roots | Explicit per-source roots from a read-only HQ inventory. Only sources that DECISION D3 accepts. `kimi` needs `projectRegistryPath` | `CollectorRuntime.swift:765-788`, `:881-891` |
| HQ authority | Append HQ entries to the index service's authority file, using the machine ID plus the spool's lazily allocated instance IDs and epochs | `ServiceCaptureSourceAuthority.swift:23-43`; `CollectorInventoryStore.swift:640-650`. The source must be enabled in the index settings, or startup fails (`:57-59`) |

**Shadow without a second DB (Proposal).** Run the HQ collector before
provisioning any HQ source instance. Its publications get both ACKs and land
in the HQ ledger as `pending`. They cannot be claimed
(`ServiceCaptureIngestWorker.swift:313-327`), so no `sessions` row or Web row
appears.

- This replaces PLAN W6.2's "separate shadow DB" for the HQ-local case. The
  production DB gains only inert ledger and publication rows.
- Provisioning is the go-live switch.
- **Caveat.** No command removes a provisioned registry row. Provisioning
  cannot be undone in the DB, and rollback only stops new publications. This
  is DECISION D11.

### 2. No double storage: the index role never runs the legacy scan

**Recommendation: option (ii), a role gate in the runner.** Option (i), the
existing environment lever, fails open. A missing or truncated
`ENGRAM_DISABLED_SOURCES` silently re-enables the legacy scan for every
enabled source in the real home (`RUN:2749-2786`, `:1930-1936`), and the
code labels the lever "tests/dev" (`RUN:2724-2726`). The live job already
depends on it, and because it omits `grok` and `pi`, the double-ingest risk
is already real for those two sources.

The rule: **the legacy filesystem scan runs only when the role is `local`.**
DESIGN:213 puts HQ-local sources on the collector. Collector, replica and
invalid roles never intended a scan.

**Touch points (minimum diff).** The gate reuses the tested override
mechanism instead of threading a new parameter:

1. `RUN:373`: after `settingsURL` is resolved, derive
   `scanEnvironment = legacyScanEnvironment(environment, settingsURL:)`. This
   is a new helper. It returns `environment` unchanged when
   `RuntimeRoleSettings.load(at: settingsURL) == .local`. Otherwise it
   returns `environment` with `ENGRAM_DISABLED_SOURCES` set to every
   `SourceName.allCases` raw value.
2. Pass `scanEnvironment` instead of `environment` at four places:
   - the `runInitialScan` call, `RUN:607-616`;
   - the `runIndexingLoop` call, `RUN:628-637`;
   - the archive-v2 drainer `adapterProvider` and
     `excludedSnapshotSourcesProvider` closures, `RUN:480-488`.
3. Leave the capture runtime (`RUN:555-558`), source authority
   (`RUN:449-454`) and `setSourceEnabled`
   (`EngramServiceCommandHandler.swift:1597-1600`) untouched. Capture policy
   keeps reading settings only.
4. Correct the doc comment at `RUN:2721-2728` so it states that the index role
   ignores the variable.

The orphan scan keeps its all-adapter list (`RUN:1937-1939`).
`local`-role behavior, including the dev/test environment lever, is
unchanged.

**Repro test (new, fails before the fix).**
`testIndexRoleLegacyScanNeverStoresHostSessionTwice_repro`, in
`macos/EngramServiceCoreTests/`. It reuses the full-runner harness pattern of
`ServiceCaptureIngestRuntimeTests.swift:330-350`.

- Setup: a temporary home containing one native session file for a source
  that is enabled in index-role settings with `captureIngest`. The
  environment does **not** set `ENGRAM_DISABLED_SOURCES`.
- Action: let the initial scan complete, then commit a capture of the same
  bytes through the existing capture fixtures.
- Assertions: exactly one `sessions` row for that native session, which is
  the capture row; zero rows with `authoritative_node = 'local'`.
- Before the fix, the scan writes the local row, so the test sees two rows
  and fails.
- Companion unit test: `testLegacyScanEnvironmentRunsOnlyForLocalRole` (new).
  It covers missing settings, `local`, `index`, `collector`, `replica` and
  invalid settings.

**The existing ~6,140 `origin=local` grok/pi rows (DECISION D7).**

- Under the gate they stop updating. Nothing deletes or rewrites them, so
  the no-silent-rewrite rule (DESIGN:500-501) holds.
- Web never shows them, because it is capture-bound.
- They duplicate the new HQ capture rows only for readers that ignore
  capture bindings: App or MCP pointed at the central DB, and service IPC
  reads.

Recommendation: leave them inert during cutover. Before any App or MCP reader
on HQ switches to the central DB (D4/D5), first run a read-only count of
dependents: insights, parent links and `session_local_state` rows that
reference those IDs. Then choose:

- (a) keep them;
- (b) a narrow same-host W4.1 alias. This is the design-sanctioned path
  (DESIGN:500-508; PLAN:715-718): HQ rows have exact same-host provenance of
  locator, native ID and bytes;
- (c) an explicit, dry-run-first operator purge through `ServiceWriterGate`,
  acceptable only if the dependent count is zero.

### 3. Cross-machine duplicate history

**What happens today if HQ publishes a copy of a Daily session** (Fact, with
the step ordering INFERRED from the cited code):

1. The receiver ACKs it, because one archive token serves all machines
   (`EngramRemoteServerConfig.swift:214-217`).
2. It stays `pending` until HQ's instance is provisioned
   (`ServiceCaptureIngestWorker.swift:313-327`).
3. It then commits as a **second session**: different proposed ID, new
   binding, no collision and no quarantine (`CaptureIngestCommitter.swift:92-120`).
   The pinned test asserts the same
   (`CaptureIngestCommitTests.swift:2090-2109`).
4. Web lists both copies, distinguishable only by machine and source
   instance. A native-ID lookup returns both
   (`ServiceWebMetadataProducer.swift:1446-1452`, `:2674-2677`). Search hits,
   counts and usage totals include both. That usage totals double is
   INFERRED from the shared join.
5. Each copy's subagents link to that copy's own parent, because parent
   identity is resolved inside the publishing stream
   (`CaptureIngestCommitter.swift:105`).

Scale (Runtime): about 6,044 Claude Code and 2,981 Codex identities. Many
Claude Code rows are skip-tier. The number of *visible* overlaps is
UNVERIFIED, and so is whether each pair is byte-identical, a prefix of the
other, or divergent.

**Options.**

| Option | Mechanism | Cost / failure mode |
|---|---|---|
| A. Accept duplicates | No code | Duplicate search hits, double usage/cost totals, two Web rows per copied session |
| B. Exact-content quarantine at commit | For a first generation (no prior binding), if another machine already binds the same `(source, native_id)` and its last parsed generation has an identical `normalized_messages_sha256`, quarantine the new publication with a new code `cross_machine_duplicate`. No session row and no binding are created; bytes stay in CAS and the ledger. Divergent content still coexists (DESIGN:470-471) | New committer branch and quarantine code, plus one idempotent index on bindings `(source, native_id)`. The pinned test must split into "identical content: quarantined" and "divergent content: distinct rows". Misses copies that are a strict prefix |
| B+. B plus strict-prefix rule | Also quarantine when the new normalized message list is a strict prefix of the other machine's head | Exact, no fuzziness, but more logic. A session later continued on HQ becomes non-prefix and commits as its own row |
| C. First-binding-wins by `(source, native_id)` | Quarantine any second machine's identity | Loses genuinely continued sessions. Order-dependent, flips after an epoch reset, and contradicts DESIGN:470-471 |
| D. Collector-side native-ID exclusion list | New collector config key holding ~9,000 IDs | Changes the strict collector schema (`CollectorRuntime.swift:760`), goes stale, and drops sessions continued on HQ. `privacy.excludedProjectRoots` works by project root and cannot separate copies from native sessions in the same directories |
| E. Read-time grouping in Web | Group by `(source, native_id)` in the producer | Touches many queries in a 4,695-line producer, counts and usage. Storage stays doubled |

**Recommendation.**

1. Phase P0 (read-only) classifies the overlap on HQ as identical, HQ-prefix
   or divergent. Compare the HQ file SHA-256 against the central capture
   manifest digests for single-file Claude Code and Codex.
2. If identical copies dominate, build **B**, the smallest correct mechanism.
   It is exact, symmetric (the first committed copy wins), reversible
   (quarantined bytes are retained) and visible (quarantine is an existing,
   counted state).
3. If HQ-prefix copies dominate, the owner chooses between B+ and A (D6).

**Code touch points for B.**

- `CaptureIngestCommitter.swift:92-96`: the no-prior-binding branch. Compare
  against the digest computed at `:136`.
- `macos/EngramCoreWrite/CaptureIngest/CaptureIngestLedger.swift:51-59`: new
  `QuarantineCode.crossMachineDuplicate`.
- `ServiceCaptureIngestWorker.swift:226-230`: map the new error the way
  `obsoleteGeneration` is mapped.
- Schema: `CREATE INDEX IF NOT EXISTS` on
  `capture_ingest_identity_bindings(source, native_id)`, in the binding
  schema at `CaptureIngestCommitter.swift:172-184`.

**What not to build.**

- Fuzzy matching by cwd, title or time (DESIGN:507-508).
- Read-time dedupe in Web.
- Collector-side ID lists.
- Merging divergent copies into one session.
- A general cross-machine alias table or authority election.
- Retroactive deletion: there are no committed duplicates today, because only
  one machine has fed HQ.

**Relation to W4.1.** W4.1 aliases existing local or live rows to the capture
stream of the *same* machine. It requires exact
machine/source/locator/native-ID provenance and byte proof (DESIGN:500-508;
PLAN:715-718). Cross-machine copies differ in machine, and often in locator,
so W4.1 does not and must not cover them. W4.1 stays unbuilt. It remains the
right tool only for HQ's own legacy rows (D7) and the old local history
(D9).

### 4. Install tooling: minimum for "each Mac runs a collector"

The tooling stays repo-side. A Node `.mjs` script follows the existing
`plan-headless-install.mjs` precedent and is never bundled (invariant 7).

1. **Collector settings renderer (new script).**
   - Inputs: home, explicit roots, identity catalog path, spool path, the two
     replica endpoints and credential IDs, privacy exclusions, and a budget
     profile.
   - Output: an owner-only settings JSON that satisfies every rule at
     `CollectorRuntime.swift:749-795`. It never reads or writes tokens.
   - Budget values must come from an owner-reviewed profile. Daily's
     deployed values live outside the repo (UNVERIFIED).
2. **Identity branch in the planner.** Plan `--initialize` against an
   existing catalog when one is present. Plan `--initialize-identity` and
   then `--initialize` only when the owner asserts that no catalog exists on
   the host. Fail closed when the evidence is ambiguous.
3. **Credentials.** The owner provisions them out of band. The planner checks
   only owner, `0600` mode and the presence of the expected credential IDs,
   and never prints values.
4. **Service-index wrapper and template.** Add an optional
   `--capture-source-authority-file` slot (the template's `:20`, `:45-48`).
   After §2, `ENGRAM_DISABLED_SOURCES` is no longer needed for the index
   role.
5. **Planner defects.**
   - Report the template's real activation keys instead of hard-coded values
     (`plan-headless-install.mjs:211-216`).
   - Bind `__ENGRAM_REMOTE_SOURCE_REVISION__` from `BUILD-METADATA`
     sourceRevision (`:244-248`).
   - Give the remote wrapper an optional `secrets/web.env` source for the
     receiver's Web environment (`run-engram-remote.zsh.template:7-10`).
   - Fail the plan when the target label is already loaded by a different
     job, which is the old hub label collision on HQ.
6. **Upgrade and rollback (dry-run first).**
   - Add an `upgrade` plan kind. It accepts existing `current`, wrapper and
     plist targets, writes a new `releases/<rev>`, swaps `current` atomically
     and records the previous target as the rollback pointer.
   - `rollback` swaps back.
   - An optional executor (DECISION D12) applies only a previously printed
     plan whose hash matches. It never reads secrets, and it stops before
     `launchctl bootstrap/kickstart` unless `--activate` is passed.
7. **`deploy-local.sh`.** Terminate only `EngramService` processes whose
   executable lies inside the App bundle being replaced, instead of
   `pkill -x` by name (`deploy-local.sh:41-44`). Update the pinned test
   (`build-release-script.test.ts:270-288`).
8. **`scripts/hq-live`.** Add boot plists for `com.engram.service-index` and
   the receiver, and retire the legacy `ensure-hq-live` watchdog and the
   legacy boot daemons. Covered by `tests/scripts/hq-live-hardening.test.ts`.
   Installing these needs root and is owner-run.

**Deferred:**

- Keychain-backed credentials.
- Developer ID signing or notarization.
- Automatic updates.
- Moving `output/web-parity-20260913/*.py` into tested tooling.
- Running the real-binary shadow suite in CI.
- Promoting the central DB to the default paths (D5 alternative).

### 5. HQ cutover runbook (W7, HQ-local)

**Authorization.** Every step from R2 on is a host mutation and needs fresh
owner authorization. R1 is read-only. Root-domain steps (R8b, R10) are run by
the owner.

**Rollback assets.** Every step keeps the prior binary, plist, settings and a
checked DB backup (DESIGN:726-730; PLAN:1216-1219).

| # | Read-only pre-check | Mutation | Verification probe | Rollback |
|---|---|---|---|---|
| R1 | Refresh the W7 baseline (PLAN:1205-1207): executable hashes, jobs, sockets, config shapes, disk free. Also: the catalog's `machine_id` row, journal mode and sidecars; P0 overlap classification; D7 dependent counts; which `EngramMCP` binary HQ MCP clients spawn (the installed App has no `Contents/Helpers`, Runtime: UNVERIFIED); remaining old-hub clients (recent manifests by peer); the watchdog's invoker | none | Recorded receipt | n/a |
| R2 | Recent reclamation activity on the old local stack | Set `archiveReclamation.enabled=false` in `~/.engram/settings.json` (backup first) so no on-disk source is deleted before first capture. Whether the old service rereads this without a restart is UNVERIFIED | No new reclamation events | Restore the settings backup |
| R3 | Package `--verify-only` | Install the collector release, wrapper and **disabled** plist | Plist `Disabled`; no collector process | Remove the new release and plist; nothing else changed |
| R4 | Collector settings path differs from `~/.engram/settings.json`; credentials file is `0600` | Render the settings (§1). Owner writes the credentials. Run `--initialize` | Spool `archive.sqlite` `machine_id` equals the catalog's (`CollectorSpoolInitializer.swift:20-40`) | Disable the job; keep the spool (never delete) |
| R5 | Receiver and M1 healthy | One `--once` cycle, then enable the LaunchAgent | HQ ledger gains `pending` rows for the HQ machine, and its `sessions` count is unchanged. M1 holds arrivals for the HQ machine (M1-side check). `--once` does not wait for ACKs (`main.swift:67`), so ACKs are checked on both receivers | `bootout` the collector; pending rows stay inert |
| R6 (canary) | P0 shows no cross-machine overlap for the canary sources (e.g. grok, pi) | Add HQ canary entries to the authority file; restart service-index (current binary) | Canary rows reach `index_ready`; one HQ session per canary source passes Web search plus a full transcript read. The legacy grok/pi rows keep updating until R7, so App/MCP readers temporarily see doubles | Stop the HQ collector. Registry rows cannot be deprovisioned (D11) |
| R7 | §2 build (and §3-B if D6) passes its gates; Web proof exists for every planned HQ source | Deploy service-index with the gate; add all remaining HQ authority entries; restart | No new `origin=local` rows over the observation window. Each HQ source is fresh and `index_ready`, with Web proof. The quarantine count matches the P0 prediction | Restore the prior binary and authority file; the legacy grok/pi scan resumes |
| R8a | Watchdog invoker identified | Disable the `ensure-hq-live` job. It restarts the old hub and service, including via `nohup` (`ensure-hq-live:143-174`) | No `hq-boot-ensure.log` lines after the change | Re-enable the job |
| R8b | Re-identify the old service process by path and start time | `bootout` the system `com.engram.service.boot` and disable the gui `com.engram.service` | Old socket gone. **Restart the HQ collector once** and confirm it opens: the identity reader needs WAL sidecars (`CollectorMachineIdentityReader.swift:42-50`) | Bootstrap the retained plists |
| R8c | No other client writes to the old hub (R1) | `bootout` the old hub `com.engram.remote-server` and its `.boot` | Plain-HTTP tailnet port closed; receiver unaffected | Bootstrap the retained plists |
| R8d | App not running | Move the Node-era `/Applications/Engram.app` aside, keeping it as a rollback asset. It contains `Resources/node` (Runtime), which violates invariant 7 | Bundle absent | Move it back |
| R8e | Backup | Set `~/.engram/settings.json` `runtimeRole:"index"` so a future App or MCP never spawns a local service (`EngramServiceLauncher.swift:223-228`) | App/MCP role probe | Restore the settings |
| R9 | D4/D5 decided | Configure MCP clients (see below) | `get_session` on one HQ-captured and one Daily-captured row; verify the transcript source | Revert the MCP client env |
| R10 | Owner present | Install boot daemons for the new pair (§4.8). Reboot testing is separately authorized (DESIGN:723-724) | After an authorized reboot, the pair runs before login | Remove the daemons |

**MCP and App on HQ after cutover.**

- **MCP (D4).** To read the central corpus, set these in the MCP client
  config:
  - `ENGRAM_MCP_DB_PATH=<central DB>`;
  - `ENGRAM_MCP_SERVICE_SOCKET=<central socket>`, whose token sidecar is
    resolved automatically;
  - `ENGRAM_SETTINGS_PATH=<index settings>`, so the role is `index` and the
    full tools are available.

  Behavior changes for MCP users:
  - Capture rows carry `remote:capture-v1…` IDs instead of native IDs.
  - The corpus includes Daily's sessions and any D7 legacy rows.
  - `get_session` reads the transcript from `file_path`, which for capture
    rows is the *origin machine's* path. On HQ that resolves to HQ's own
    copy, which may differ, or to nothing. INFERRED from
    `MCPTranscriptTools.swift:22-41`; must be probed at R9.
- **App (D5).** The App reads only `~/.engram/index.sqlite` and the default
  socket (`AppEnvironment.swift:38-39`). In the `index` role it would show
  the stale old DB as if it were the corpus, which DESIGN:229-230 forbids.
  Keep the App off HQ, and rename the old DB aside (retained) after
  observation so no default-path reader can mistake it for the central
  corpus.

### 6. Daily and M1

**Daily.** It has been silent since 2026-09-22. Read-only checks *on Daily*:

- collector job state and last exit code. `main.swift:159-161` reports
  failures only as exit 70;
- whether the process is alive;
- spool backlog per replica and the last ACK per replica;
- reachability and TLS to HQ's endpoint and to M1;
- credential acceptance;
- disk admission;
- identity-catalog sidecars (same WAL rule as R8b);
- whether the old local service has stayed disabled.

From HQ, check receiver storage health. The receiver logged
`storage_unavailable` PUT 503s on 2026-09-21 and 2026-09-22 (Runtime).

Done for Daily means:

- the collector runs from a repo-built package;
- HQ arrivals for Daily resume, and the backlog since 2026-09-22 drains;
- every enabled Daily source shows a fresh `index_ready` row with Web proof;
- the CPU status is recorded per D2.

**M1.** By design, M1 is an independent archive replica and not an ingest
source (DESIGN:142-144, :214). HQ pulling only from the `hq` replica is
expected (Runtime). M1-local sessions reach HQ only through an M1 collector
that uploads to `hq`. Checks *on M1*:

- receiver health and storage;
- arrivals per machine (Daily, and HQ after R5);
- an inventory of enabled local sources with recent activity;
- old local services or hubs still running.

Done for M1 means:

- M1 holds ACKed arrivals for every collector;
- either an M1 collector passes the same R3-R7 proof, or the owner records
  "no enabled local sources" (D1).

### 7. Definition of finished (owner DECISIONs)

| ID | Decision | Recommendation | Consequence of the alternative |
|---|---|---|---|
| D1 | Hosts in scope | Daily, HQ, and M1 only if it has active local sources. Also confirm whether any other client exists: the old hub holds a manifest from a third client host last written 2026-08-11 (Runtime) | Unlisted hosts' sessions never reach HQ |
| D2 | Is the ≤2% collector CPU target (DESIGN:710-713) binding? | Track it separately. It does not block "cutover finished", but it blocks any "fully lightweight" claim (PLAN:1199-1201). Daily is currently 13.178%, FAIL, deferred (CL:21-27) | Making it binding blocks cutover on unrelated performance work |
| D3 | Antigravity cache/PB and Windsurf cache/PB | Record them as explicit per-host exceptions (CL:200-205; HQ has Antigravity candidates, CL:215-219). Keep old data and the old DB read-only. Make no lightweight claim for affected hosts | Treating them as blockers keeps the old local indexer running indefinitely (DESIGN:455-456) |
| D4 | HQ MCP | Point it at the central DB and socket (§5), with the behavior changes documented, after the R9 probe. The old DB is stale either way | "Unavailable on HQ" (DESIGN:145-146, :736-737) removes local MCP on the busiest host |
| D5 | HQ App | No App on HQ; Web is the reader | Promoting central to the default paths (a large move on one volume) makes the App work, at the cost of a riskier cutover |
| D6 | Cross-machine copies | §3-B after P0; B+ only if P0 shows prefix copies dominate | A: duplicate rows and double usage/cost totals |
| D7 | 6,140 legacy grok/pi rows | Keep them inert; decide (b) or (c) after the dependent count, before D4 | Purging without counting risks losing insights or manual links |
| D8 | Legacy-scan protection | §2 role gate | Environment lever: a fail-open misconfiguration recreates double storage |
| D9 | HQ history not on disk (reclaimed or deleted files that exist only in the old DB or archive-v2) | Accept the gap for cutover. Retain the old DB and archives. W4.5 is a later decision | Building W4.5 first delays cutover |
| D10 | Reboot recovery | Boot daemons for the new pair (R10) | The central pair runs only after login |
| D11 | Production-ledger shadow (§1) | Accept it: rows are inert until provisioned | A separate shadow service duplicates the CAS and the operational cost |
| D12 | Apply executor (§4.6) | Build it, guarded by plan hash and `--activate` | Manual execution of printed plans stays error-prone |

**Cutover is finished when all of the following hold:**

- every D1 host runs a repo-packaged collector;
- every enabled source per host has a dated real capture, both ACKs, an
  `index_ready` row and Web search/transcript proof in CL, with nothing left
  `UNVERIFIED`;
- the central DB gains no `origin=local` rows;
- the old HQ stack, hub, watchdog and Node-era App are retired, with
  rollback assets kept;
- D2, D3 and D9 exceptions are recorded in CL.

### 8. Decisions recorded 2026-10-02

The owner delegated these decisions to the cutover lead on 2026-10-02. Each
follows the recommendation in §7 unless noted; any of them can be reopened.

| ID | Decision |
|---|---|
| D1 | Hosts in scope: Daily and HQ. M1 joins only if a read-only check finds active local sources there; that check is not done. |
| D2 | The collector CPU target is tracked separately. It does not block "cutover finished"; it blocks any "lightweight" claim. |
| D3 | Antigravity cache/PB and Windsurf cache/PB are per-host exceptions, recorded in the retirement checklist. |
| D4 | HQ MCP will read the central DB, as a new configuration, after a current `EngramMCP` build is installed and the R9 probe passes. |
| D5 | No App on HQ. The Node-era bundle is moved aside at R8d. |
| D6 | Option B (exact-content quarantine at commit). P0 found identical and divergent copies but no prefix copies, so B+ is not built. Before implementation, confirm that equal bytes under the same parser give an equal `normalized_messages_sha256`. |
| D7 | The legacy `origin=local` grok/pi rows stay inert. They have no user-state dependents, so option (c), a dry-run-first purge that also clears their derived rows, is the planned follow-up before D4. |
| D8 | Role gate. Implemented (P1). |
| D9 | Accept the history gap; keep the old DB and archives. |
| D10 | Boot daemons for the new pair. Root steps are run by the owner. |
| D11 | Accept the production-ledger shadow. |
| D12 | Build the plan executor as part of P3, after P2. |

Sequencing decided the same day:

1. Deploy the fixed collector to Daily first and prove recovery there. That
   run is also the first real-host evidence for the volume-identity fix.
2. Build P2 (D6) and the P3 install tooling next.
3. Execute the HQ runbook (R2-R10) in a dedicated session after P2 and P3,
   because it needs credentials provisioning and root steps by the owner.
   Add "still capturing after a reboot" to the per-host acceptance checks.
4. The older HQ local Service is not restarted to catch up its Codex backlog;
   that stack is retired at R8, and the HQ collector walks Codex roots without
   a date window.

## Invariants affected

- **1 Single-Writer.** Preserved. The collector writes only its spool, and
  every product write still goes through `ServiceWriterGate`.
- **2/3 Skip and visibility.** Preserved. §3-B creates no session row, and
  tiers are untouched.
- **6 Tests avoid production data.** The new tests use temporary homes, as
  the existing harness does.
- **7 No Node bundle.** Preserved. Tooling stays repo-side, and R8d removes
  the violating bundle from HQ.
- **8 Socket security.** Preserved. MCP uses the socket-namespaced token
  sidecar.
- **9 Ordered backfills.** Not reordered.
- **11 Idempotent migrations.** The §3-B index is `IF NOT EXISTS`.
- **12 MCP read-only.** Preserved by D4.
- **External Service Ownership and Persisted Host Role.** Touched by §4.7 and
  R8e. Their statements stand.
- **Source and Epoch Authority Precedes Capture Replay.** §1's shadow relies
  on it unchanged.
- **New entries, added in the same PRs as the code (DESIGN:672-675):**
  - "Only the local role runs the legacy filesystem scan" (§2);
  - "Identical cross-machine captures are stored once" (§3-B, only if D6
    adopts it).

## Alternatives considered

- **Keep the environment lever (§2 option i).** Zero Swift code and already
  pinned by `WebSourceSettingsTests.swift:115-132`, but it fails open and is
  labeled dev-only. Rejected as the primary protection.
- **Declare the index-role legacy scan the HQ-local path.** HQ sessions would
  never appear on the capture-bound Web, and the Claude Code and Codex roots
  would duplicate Daily's copies under `local` IDs. Rejected; this also
  contradicts DESIGN:213.
- **Use settings `disabledSources` to stop the scan.** It also disables
  capture, hides capture rows (`EngramServiceCommandHandler.swift:1676-1680`),
  and makes authority provisioning fail. Rejected.
- **Separate shadow HQ DB for HQ-local (PLAN W6.2).** Safe, but it duplicates
  a large CAS and needs a second service. Superseded by the pending-ledger
  shadow (D11).

## Test plan

| Phase | Scope (one PR each) | Tests |
|---|---|---|
| P0 | Read-only measurements (R1) | None; a recorded receipt |
| P1 | §2 role gate | `testIndexRoleLegacyScanNeverStoresHostSessionTwice_repro`, `testLegacyScanEnvironmentRunsOnlyForLocalRole` (both new). The existing `WebSourceSettingsTests` and `ServiceCaptureIngestRuntimeTests` must stay green. Add the ledger entry and run `bash scripts/check-invariants-ledger.sh` |
| P2 | §3-B (if D6) | `testIdenticalCrossMachineCaptureIsQuarantinedNotDuplicated_repro` (new). Update `testMachineInstanceSourceAndExactNativeBytesKeepDistinctIdentities` so the other-machine fixture has divergent content and still yields distinct rows. Add a migration idempotence check for the new index |
| P3 | §4.1-4.5 tooling | Vitest cases whose titles end in `(repro)`, for the remote activation truthfulness and the revision binding. Both replace pins at `headless-install-plan.test.ts:208-213`, `:257-263`. Add renderer shape tests and a Swift test that loads a rendered fixture through the collector settings parser |
| P4 | §4.7 deploy-local | Replace the pin at `build-release-script.test.ts:270-288` with a `(repro)` test proving that an index-role `EngramService` outside the bundle is not targeted |
| P5 | §4.8 hq-live | `tests/scripts/hq-live-hardening.test.ts` extended for the new labels and the watchdog retirement |
| P6 | §4.6 upgrade, rollback and executor (if D12) | Plan-hash mismatch refusal; no `launchctl` without `--activate`; rollback pointer round trip |
| O1-O3 | Runbook R2-R10; Daily and M1 checks | Probes in §5 and §6. Record CL and CHANGELOG entries |

Repro tests carry a comment that references their PR, as CLAUDE.md requires.
Not tested automatically:

- live-host behavior, covered by the runbook probes;
- the real-binary shadow suite, which stays opt-in (deferred).

## Rollout

- P1 and P2 ship in a service-index build that R7 deploys. They are inert on
  `local` hosts except for the §2 rule, which does not change `local`.
- P3-P6 are tooling only.
- Ordering: P0 → P1 (and P2) merged → R1-R6 → R7 → R8-R10.
- Revert path:
  - P1: redeploy the prior binary while the environment lever remains in the
    live job.
  - P2: quarantined rows keep their bytes. A future epoch or reconcile can
    revisit them, but no command exists today.
  - Runbook steps: per-row rollback above.

## Risks and open questions

- **Identity catalog after the old service exits** (high impact, UNVERIFIED).
  A WAL catalog without sidecars blocks every collector start
  (`CollectorMachineIdentityReader.swift:42-50`). R8b probes this on HQ, and
  the same check applies to Daily.
- **Provisioning cannot be undone** (D11). A mis-provisioned HQ instance can
  only be stopped at the collector.
- **The live HQ job is not reproducible from the repo.** Its extra flags and
  environment are not in the template. P3 closes this.
- **Old reclamation may already have deleted HQ files** (D9). R2 stops
  further deletion.
- **Receiver host checks on loopback publication with Web enabled** are
  UNVERIFIED. The R5 probe covers them.
- **Identity collisions are retried, not quarantined.** `identityConflict` is
  rethrown, not quarantined (`ServiceCaptureIngestWorker.swift:222-233`).
  Same-machine occupied-ID collisions may therefore retry on each lease
  expiry (INFERRED). This is not on the HQ path, but CL should not call it a
  "collision quarantine".
- **Open.** The exact budget profile for HQ, and whether HQ bootstrap load
  (tens of thousands of historical files) needs a temporary tighter budget.
