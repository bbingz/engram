# Web fleet dashboard

The **Machines** navigation item (`#/fleet`) is an operator dashboard, separate
from session analytics and the existing ingest Health page. `GET /web/api/fleet`
requires a Web **editor** session (anonymous: 401; viewer: 403). Fleet-wide counts
and host capacity are deliberately not ordinary viewer metadata.

## Overview and expanded details

The table-first presentation uses one overview row per machine. Desktop columns
compare sampled service state/attention notes, central sessions, captured/dirty/
unavailable files, upload tasks, central index tasks, free disk, and observation
freshness. The summary is a compact definition list, not five large cards.
**Sampled** means telemetry was obtained recently; it is not a service-health
verdict. Process state, capture gaps, retry errors, and low disk remain separate.

Select a machine name (keyboard: Enter/Space) to expand its metric, process,
replica, and source-inventory tables. Expanded machines and keyboard focus are
retained across refresh/reordering, and cleared on navigation, logout or access
denial. On small screens, the overview retains machine, service/attention, and
free-disk columns; the other values remain in expanded details. Wide detail
tables scroll within their own focusable regions, not the page.

**Upload tasks** sums pending/in-flight publication-replica states across targets,
not distinct capture generations. The replica detail table preserves each target's
ACK, privacy-withheld, and retry counts. Missing queues/process observations remain
**Not reported**, never healthy zeroes. Central values are labeled stale separately
from host observation freshness. PIDs are identifiers and retain ungrouped digits.

The table-first presentation was deployed on 2026-11-11 from compatible revision
`081426da` after PR #513 merged. The separate rollout records below distinguish
the initial `d83dcdd1` fleet release from this receiver-only presentation update.

## Data flow and guarantees

1. An opt-in operations exporter, `scripts/collector-fleet-status.py`, probes a
   private allowlist of hosts and state directories outside the Web request path.
2. It writes one atomic, owner-only JSON observation file. Failed host probes
   produce an unreachable sample with unknown metrics, not recycled healthy data.
3. The native Swift Web server securely reads at most 1 MiB from the configured
   file, validates the typed schema, and serializes only allowlisted DTO fields.
   It does not return arbitrary operator JSON or probe hosts, walk directories,
   launch Python, or access collector databases from HTTP handlers.
4. The browser refreshes every 30 seconds only while Machines is open. Logout,
   navigation, access denial, and superseded requests cannot repopulate private
   host data. Observation and snapshot times are shown; samples over 10 minutes
   old, or ahead of the browser clock, are explicitly marked stale/clock-ahead.

Python 3.9+ is needed only on the operator sampler and its configured probe hosts,
not by the shipped app, service, collector, or Web server startup. No Python
package installation is required. SSH uses existing operator authentication and
host-key policy; no credentials belong in this config or the snapshot.

## Opt-in configuration

Create a regular, owner-only (`0600`) configuration file **outside capture roots**.
The following paths/hostnames are examples, not defaults or production targets:

```json
{
  "machines": [
    {
      "id": "collector-a",
      "label": "Collector A",
      "role": "collector",
      "target": "collector-a",
      "collectorSpool": "/Users/operator/.engram-state/collector/spool",
      "diskPath": "/Users/operator/.engram-state",
      "jobs": [{"name": "Collector", "label": "com.engram.collector"}],
      "storageRoots": [
        {"name": "Collector spool", "path": "/Users/operator/.engram-state/collector/spool"}
      ]
    },
    {
      "id": "index",
      "label": "Central index",
      "role": "index",
      "diskPath": "/Users/operator/.engram-state",
      "jobs": [{"name": "Index", "label": "com.engram.service-index"}],
      "storageRoots": [
        {"name": "Index state", "path": "/Users/operator/.engram-state/service-index"}
      ]
    }
  ],
  "centralDatabase": "/Users/operator/.engram-state/service-index/database/index.sqlite"
}
```

Omit `target` for local probing. Roles are `collector`, `index`, and `replica`;
index hosts can also specify a collector spool. Configure 1–64 distinct machine
IDs, at most 16 launchd jobs and 16 storage roots per host. Only explicit bounded
absolute state directories are allowed; do not configure home or volume roots
for recursive storage measurement. Omitting a component means unknown/not
reported, not zero or proof that the component is unnecessary.

For a one-shot read-only observation:

```sh
python3 -I scripts/collector-fleet-status.py \
  --config /private/operator/fleet-config.json \
  --output /private/operator/fleet-status.json
```

For an independently supervised sampler, add `--watch --interval 300` (allowed
interval: 60–3600 seconds). The output parent must exist, be owned by the operator,
be canonical/non-symlinked, and not be group/world-writable. Output is atomic
`0600`; symlink/shared-inode output targets are rejected. Keep this entire state
location outside source/capture roots. An exporter failure leaves the previous
file in place; the Web timestamp then ages visibly instead of becoming healthy.

Enable reading in the Web receiver's existing environment:

```text
ENGRAM_REMOTE_WEB_FLEET_STATUS_PATH=/private/operator/fleet-status.json
```

The setting is ignored when Web is disabled. Unconfigured, missing, unsafe,
malformed, oversized, or unsupported snapshots return 503 with no host details;
viewers are rejected before the file is read. Extra query parameters are rejected.
No setting creates an SSH capability in the HTTP server.

## Metric semantics

- **Session totals** are central DB rows whose origin identifies a capture machine.
  **Non-hidden, non-skip** is a narrower SQL count, not a promise of Web admission:
  source/privacy/authority filters can further reduce browsable sessions. An
  archive-only host without a capture identity has unknown session counts.
- **Capture generations** are collector publication records, **captured files**
  are inventory locators with a prior capture, and **received generations** are
  central publication records. None of these units is a logical session count.
- **Dirty** includes cooling locators; do not add cooling again. Unsupported or
  untracked native files are absent from the inventory. Scan completion and an
  empty upload/ingest queue do not prove source completeness.
- **Replica pending/in-flight/ACK** count publication-replica states.
  Privacy-withheld is reported separately, not as failed or pending upload.
  Retry errors overlap queue states and must not be added as another backlog.
- **Central pending/processing/parsed/index-ready/retryable/quarantined** count
  ingest-ledger tasks, potentially including historical parser runs. Historical
  quarantine and intentionally skipped sessions are not a current FTS backlog.
  FTS pending and permanent failures are separately reported.
- **Disk** is configured-volume used/free/total space. Below 20 GiB or 10% free
  triggers an attention note, not cleanup or an exhaustion forecast.
  **Named directory usage** is `du -sk` allocated bytes (including contained state
  and backups), not logical file bytes or deduplicated APFS-clone consumption.
  Named directories can overlap; the UI does not sum them into fleet totals.
- **Processes** show launchd state/PID and the package revision associated with
  the loaded job's executable, never a possibly edited replacement plist.
  This is a sampled observation, not a binary-integrity attestation or heartbeat.
- **Epoch** compares the live FSEvents device UUID with the stored checkpoint;
  old stderr is not interpreted as current failure. Missing APIs/checkpoints
  remain unknown/no-checkpoint rather than mismatches.

No collector/native-retention policy, migration, queue, source file, archive,
credential, or stored generation is changed by this feature. No GC is performed.

## Rollout and rollback

This document does not authorize a service restart, SSH job installation, push,
or deployment. After deployment approval:

1. Keep the current compatible HQ deploy lineage. Until the live-migration work
   in #496 lands, build from `4b5b3e00` or its compatible descendants, not main.
2. Transfer only this feature's commits to that line, regenerate the Xcode project
   with pinned XcodeGen 2.45.4, and rerun RemoteServerCore and UI/exporter gates.
3. Create/verify the private snapshot and independently supervised sampler. Check
   actual schemas, timestamps, five-host reachability, storage scopes, and file
   permissions before changing the Web receiver environment.
4. Back up the receiver job, retain its old package, and replace/restart only the
   receiver. No collector or index restart is needed for this feature. Verify
   editor 200, viewer 403, secure/no-store response, cold `#/fleet` load, drilldown,
   stale/offline states, and existing session/search/Health behavior.
5. Roll back by restoring the receiver's prior job/package and stopping only the
   new sampler. Retain observations for diagnosis; no database rollback or data
   deletion is necessary.

## Initial fleet rollout — 2026-11-11

- Feature PR #511 merged as `8129554c` after 15 successful checks and two
  conditional skips. HQ uses compatible-line commit `d83dcdd1`, not a main build.
  Release receiver package: `remote-server-fleet-d83dcdd1-20261111`; SHA-256:
  `677fec616d5b90e116c36e9ed8e88482b34142f6dd670534018b8d3b7beca574`.
- `com.engram.web-fleet-status` is a separate user LaunchAgent, one-shot at load
  and every 300 seconds, with an immutable script/private config and snapshot
  under the existing HQ shadow state. System Python 3.9 was verified; three
  publications, including an automatic scheduled run, succeeded with empty
  stderr. All five configured hosts and central observations were available.
- The receiver job changed only its executable and fleet snapshot setting.
  Collector/index/archive PIDs and revisions did not change. Compatible-tree
  RemoteServerCore 550/550 and UI/exporter 388/388 passed; package/signature,
  typecheck and project-generation gates passed. Real Serve tests verified
  editor 200, anonymous 401, foreign-origin 403, query 400, method 405, no-store,
  typed projection and existing session/filter/search/Insights reads. No live
  viewer authority was created merely for testing; the native viewer-403 gate
  passed against the deployed-line implementation. Four real-Serve browser
  combinations (desktop/mobile × dark/light) verified Machines cold load, refresh,
  source-table layout, machine drilldown, reload, navigation privacy clearing,
  identity-mode API logout, and equality of served JS with the compatible source.
- Rollback receiver job: `hq/state/web-fleet/receiver-before.plist` under the
  existing shadow root. Restore that job and restart only the receiver, then
  unload `com.engram.web-fleet-status` if rolling back the whole feature. The
  previous receiver package remains available; no database rollback is needed.
- Separate unresolved observation: the existing Health/Overview chain fails
  at page 19 with `limit=2` (503); the preceding pages/default first page work.
  Its read code and the index process were not changed by this deployment.
  Root cause is unverified. The separate Machines snapshot remains available;
  do not reinterpret the Health failure as zero pending work or claim this
  rollout remediated it. Named directory usage can be unreported if the bounded
  `du` measurement times out; volume capacity/free are reported independently.
  Private diagnostic evidence and browser results are
  referenced from the deployment entry in `CHANGELOG.md`.

## Table-first rollout — 2026-11-11

- Self-review: spec PASS / quality APPROVED. PR #513 merged as `874a9914`
  after 13 successful CI checks and four conditional skips. HQ Release uses
  compatible commit `081426da`, retaining the deployed AI-save conflict guard
  and write-route wiring; this is not a main-built HQ executable.
- Package `remote-server-fleet-table-081426da-20261111`, SHA-256
  `e24acd12a0c4425192151bb4f8018a81f3d9dc37f898c5bf34553570cc8a4cc0`.
  Receiver PID changed 61479→58762; only its executable argument changed, health
  and actual served JS readiness passed. Old process exit was verified before
  bootstrap; automatic rollback covers readiness failure.
- Compatible RemoteServerCore 550/550 and UI/exporter 395/395 passed, together
  with typecheck, project drift, Release package/signature verification. Live
  editor/anonymous/origin/query/method/privacy/no-store checks passed, and served
  JS/CSS matched compatible source. Four real desktop/mobile × dark/light cases
  passed cold load, tables, keyboard interaction/contained scrolling, refresh
  focus/expansion, drilldown, reload, navigation clearing and identity-mode API
  logout. Viewer 403 is covered by native HTTP tests; no live viewer authority
  was created merely for acceptance. Physical-device/Safari testing was not run.
- Configured collector/index/archive PIDs and reported revision fields were
  unchanged, as were PIDs for M1's additional receiver and archive jobs. Sampler job/config fingerprints were unchanged;
  its next automatic publication observed five reachable hosts and the new receiver
  PID/revision, with last sampler exit 0. No sampler reload, schema, credentials,
  retention, deletion or GC changes.
- **UI-only rollback:** restore the private
  `hq/state/web-fleet/table-081426da-20261111/receiver-before.plist` and restart only
  the receiver to retained `d83dcdd1`. **Leave the existing sampler loaded**; unlike
  initial feature rollback, this update does not install or remove it. No database
  rollback is needed.
- Overview remains intermittently unavailable: six 503 responses were recorded
  across live browser acceptance; two Health views failed and two loaded. The
  index/read implementation was not changed, root cause remains unverified, and
  this rollout does not claim to repair it or capture gaps. Evidence references
  are in the table-first deployment entry in `CHANGELOG.md`; raw data remains private.
