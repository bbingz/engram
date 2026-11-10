# Design Spec: Central Archive on `10.0.0.9` (Intel Mac 1TB), 30-Day Local Retention, and Historical Deduplication Merge

**Date:** 2026-11-09  
**Status:** Draft for Cross-Agent Workflow Review (Antigravity + Claude Code)  
**Target Host:** `10.0.0.9` (Intel `x86_64` Mac, 1 TB Storage, currently being cleaned/prepared)  
**Client Hosts:** `macmini-hq`, `macbookpro` (Daily), `macmini-m1`, `macmini-m2`

---

## 1. Context & Problem Statement

A read-only four-machine audit on 2026-11-09 revealed severe storage bloat (~496.8 GB total across `macmini-hq`, `macbookpro`, `macmini-m1`) and operational friction caused by running two overlapping generations of Engram storage architectures simultaneously:

1. ** Current Four-Machine Storage & Operational State:**
   - **`macmini-hq` (~264.8 GB Engram usage):** Runs two parallel stacks:
     - Legacy/Local stack (`~/.engram` 32 GB + `~/.engram-remote` 6.6 GB): `com.engram.service.boot` indexes local sessions (65,732 sessions) into `~/.engram/index.sqlite` (1.75 GB) and captures local `claude-code`/`codex` into `~/.engram/archive-v2` (30 GB).
     - Shadow-Core stack (`~/.engram-shadow-core-20260911/hq` 221 GB): `com.engram.capture-core.receiver` stores 33 GB of encrypted EAV2 archives (`76,388` publications/manifests, `70,191` objects), while `com.engram.service-index` stores a **duplicate 117 GB** uncompressed CAS copy in `service-index/database/capture-ingest` plus a **35 GB** `index.sqlite` (`1,072,742` rows in `capture_ingest_generation_messages` + `76,388` canonical publication blobs) and **~30 GB** of pre-deploy rollback SQLite snapshots.
   - **`macbookpro` (~189.1 GB Engram usage, Data Volume at 96% full / only 76–82 GiB free):**
     - Runs `EngramCollector` (`~/.engram-shadow-core-20260911/daily` 134 GB), where `spool/capture/objects` retains **117 GB** of local CAS chunks that have already been acknowledged (`76,388` ACKs) by both `hq` and `m1`.
     - Retains retired `~/.engram` (**51 GB**, stopped on 2026-09-12) and old release/migration directories (**3.7 GB**).
     - Since a reboot on 2026-11-05, 8/16 collector roots are suspended due to FSEvents native epoch UUID rotation (`CollectorRuntimeError.reconciliationRequired`).
   - **`macmini-m1` (~42.9 GB Engram usage):**
     - Runs two `EngramRemoteServer` instances: `:8787` (`~/.engram-remote/archive-v2-m1`, 3.9 GB, `35,804` manifests) and `:18787`/`:9443` (`~/.engram-shadow-core-20260911/m1`, 37 GB, `76,388` publications/manifests).
   - **`macmini-m2` (0 B Engram usage, ~18 GB raw AI sessions uncollected):**
     - Has ~18 GB of raw sessions (`.claude` 5.4G, `.claude-minimax` 4.3G, `.codex` 2.4G, `.grok` 2.2G, `.gemini` 2.1G, `.antigravity` 818M, etc.) not yet ingested into Engram.

2. **Owner's Target Architecture Goal:**
   - Move centralized storage to **`10.0.0.9`** (an older Intel `x86_64` Mac with **1 TB** storage).
   - Keep **only the last 30 days of sessions locally** on each terminal machine (`macmini-hq`, `macbookpro`, `macmini-m1`, `macmini-m2`), archiving everything older to `10.0.0.9`.
   - **Deduplicate and merge** all historical archives across all machines into `10.0.0.9`.

---

## 2. Architectural Analysis & Key Trade-offs

### 2.1 Two Candidate Runtime Models for "30-Day Local + Central Archive on `10.0.0.9`"

We must choose between (or cleanly unify) two models currently present in the codebase:

#### Option A: Unified Local-30d Service + Central Archive Store on `10.0.0.9` (Recommended for Simplicity)
- **How it works:**
  - Each client Mac (`macmini-hq`, `macbookpro`, `macmini-m1`, `macmini-m2`) runs standard `EngramService` (`runtimeRole = "local"`) + local SQLite index for fast local CLI/MCP/App access, with **Archive V2 + 30-Day Reclamation + Remote Offload** enabled (`hotWindowDays = 30`, `coldAgeDays = 30`).
  - `10.0.0.9` runs **`EngramRemoteServer`** (`x86_64`), acting as the single authoritative Archive V2 + Offload store (and optional Central Web/Index if desired, or purely storage).
  - Once a session on a client Mac is archived to `10.0.0.9` (receipt verified):
    1. **Immediate Local CAS Eviction:** Local `~/.engram/archive-v2/objects` chunks are evicted immediately after remote receipt verification (not waiting 30 days, since the raw source file is still on disk during the 30-day hot window).
    2. **30-Day Raw Source Reclamation (`ArchiveSourceReclaimer`):** Once a session is inactive for `> 30 days` (`!isLive`, `!isFavorite`), the raw source file (`~/.claude/...`, `~/.codex/...`, `~/.grok/...`, etc.) is quarantined and unlinked locally.
    3. **30-Day Index Offload (`OffloadRunner`):** Cold session message chunks/FTS in local `index.sqlite` older than 30 days can be offloaded to `10.0.0.9` (keeping lightweight session metadata header rows locally or on `10.0.0.9`), while cold transcript reads transparently hydrate from `10.0.0.9` via `ArchiveTranscriptResolver`.
- **Pros:**
  - Every terminal machine has working local `Engram.app` and `EngramMCP` with sub-millisecond access to the last 30 days of hot work.
  - `10.0.0.9` (Intel Mac) only needs to run `EngramRemoteServer` (~10 MB RAM, ~0% CPU, sequential object I/O), avoiding heavy FTS5 trigram indexing on an older Intel CPU.
  - Eliminates the entire `service-index` 117 GB duplicate `capture-ingest` CAS + 35 GB normalized-message SQLite overhead.

#### Option B: Headless `EngramCollector` on Clients + Central `service-index` & `EngramRemoteServer` on `10.0.0.9`
- **How it works:**
  - Client Macs run `EngramCollector` (`runtimeRole = "collector"`) and push publications to `10.0.0.9`.
  - `10.0.0.9` runs both `EngramRemoteServer` AND `EngramService (role = "index")` + Web UI.
  - **Required New Code in `EngramCollector`:** `EngramCollector` currently has **no source reclamation** and **no local spool CAS eviction** (`macbookpro` accumulated 117 GB in `spool/capture/objects` and never deletes old `~/.claude` files). We would have to port `ArchiveReclamationPolicy`, `ArchiveSourceReclaimer`, and `ArchiveCASEvictor` into `EngramCollectorCore`.
  - **Required Fix in `service-index`:** When `service-index` and `EngramRemoteServer` run on the same host (`10.0.0.9`), `ServiceCapturePublicationConsumer` must not duplicate 117 GB of chunks into `service-index/database/capture-ingest` when they already exist in `remote-server/archive`.
- **Cons:**
  - Running `service-index` (35+ GB SQLite with 774k+ FTS5 trigram rows and 19 adapters) on an older Intel Mac (`10.0.0.9`) may suffer high CPU/IO latency.
  - Client Macs in `collector` role lose local `Engram.app` and local `EngramMCP` search (even for the last 30 days of local sessions), contrary to "各机的终端维持本地30天的会话".

> **Design Recommendation:** Adopt **Option A** (or a hybrid where `10.0.0.9` runs `EngramRemoteServer` as the central archive + optional read-only index, while each terminal Mac keeps a 30-day rolling local window and reclaims >30d raw files & CAS objects).

---

## 3. Detailed Technical Design & Code Changes

### 3.1 WP1: Single-Primary Archive Topology (`10.0.0.9`) + NAS Backup (`10.0.0.11`)

Currently, dual-replica (`hq` + `m1`) is hardcoded in multiple places:
- `macos/EngramCaptureShared/ArchiveCatalog.swift`: `public static let currentReplicaIDs = ["hq", "m1"]`
- `macos/EngramCoreWrite/ArchiveV2/ArchiveReclamationPolicy.swift:80`: `private static let requiredReplicaIDs = Set(["hq", "m1"])`
- `macos/EngramCoreWrite/ArchiveV2/ArchiveCASEvictor.swift:134`: `Set(receipts.keys) == Set(ArchiveCatalog.currentReplicaIDs)`
- `macos/EngramCollectorCore/CollectorRuntimeConfiguration`: requires both `hq` and `m1` endpoints.

**Proposed Change:**
1. Make `requiredReplicaIDs` configurable via `settings.json` (`remoteArchiveV2.requiredReplicaIDs: ["central"]` or `["hq"]`), defaulting to the configured active replica set (minimum 1 verified remote replica when single-primary mode is enabled).
2. Still require a valid recovery drill lease (`recoveryLeaseVerifiedAtNs`) on the primary archive server (`10.0.0.9`) within the last 30 days before allowing local source deletion.
3. Configure `10.0.0.9` to run a daily append-only backup (`rsync --ignore-existing`) of its encrypted `archive-v2` root to the existing 19 TB NAS (`the NAS share`), preserving durability without forcing every client Mac to upload twice over the network.

### 3.2 WP2: 30-Day Local Retention & Immediate Local CAS Eviction

To ensure each terminal machine only keeps 30 days of sessions locally and minimal Engram overhead:

1. **Immediate CAS Eviction After Remote Receipt (`ArchiveCASEvictor.swift`):**
   - Currently, `ArchiveCASEvictor.evictEligibleObjects` (line 40) waits until `targetIntent.phase == .sourceDeleted` (i.e., after 30 days!) before evicting local chunks from `~/.engram/archive-v2/objects`.
   - **Why this wastes 30–117 GB per machine:** During the first 30 days, the raw source file is *already present on local disk* (`~/.claude/projects/...`). Keeping a duplicate copy in `~/.engram/archive-v2/objects` for 30 days doubles disk usage for hot files.
   - **Change:** Allow `ArchiveCASEvictor` to evict local CAS objects as soon as **all referencing manifests have verified remote receipt(s)** on `10.0.0.9` (and if `sourceDeleted` is not yet reached, the local raw file still exists; if `sourceDeleted` is reached, `10.0.0.9` serves cold reads). This reduces local `~/.engram/archive-v2/objects` to near **0 GB** in steady state!

2. **Expand 30-Day Source Reclamation Beyond `claude-code` and `codex` (`ArchiveReclamationPolicy.swift`):**
   - Currently `ArchiveReclamationPolicy.supportedSources` (line 81) only includes `["claude-code", "codex"]`.
   - **Change:** Expand exact-source capture & 30-day reclamation to all file-per-session / directory-per-session sources that dominate disk usage across the 4 Macs:
     - `claude-code` (including `minimax` / `.claude-*` profile roots)
     - `codex`
     - `grok` (`~/.grok/sessions/<project>/<session>/` — 14 GB on HQ, 2.2 GB on M2)
     - `gemini-cli` (`~/.gemini/tmp/<project>/chats/*.json`)
     - `antigravity` (`~/.gemini/antigravity*/brain/<id>/` — 10 GB on HQ, 818 MB on M2)
     - `pi` (`~/.pi/agent/sessions/**/*.jsonl`)
     - `kimi` (`~/.kimi/sessions/<ws>/<session>/`)
   - *Note:* Monolithic SQLite sources (`cursor` `state.vscdb`, `opencode` `opencode.db`) remain excluded from file-unlink reclamation because multiple sessions share one SQLite file.

3. **30-Day Local Database Trim (`OffloadPolicy.swift`):**
   - Set `coldAgeDays = 30` in `OffloadPolicy` so sessions older than 30 days offload their heavy FTS/message payloads to `10.0.0.9` (or keep header-only metadata locally), keeping each client's `~/.engram/index.sqlite` small (< 300 MB).

### 3.3 WP3: `10.0.0.9` (Intel `x86_64`) Build, Network & Transport Gate

1. **Intel `x86_64` / Universal Build Support (`macos/project.yml` & build scripts):**
   - `EngramRemoteServer` and `GRDB-dynamic` currently build for host arch (`arm64`).
   - Add `--arch x86_64` / Universal Binary (`ARCHS="arm64 x86_64"`) support to `scripts/package-remote-server.sh` (and verify `MACOSX_DEPLOYMENT_TARGET` matches `10.0.0.9`'s macOS version once `10.0.0.9` is online; currently `14.0`).
2. **Transport Security Policy (`HTTPArchiveReplicaBackend.swift`):**
   - Currently, `HTTPArchiveReplicaBackend` only allows `http://` over literal Tailscale CGNAT IPs (`<tailnet-ip>/10`) or `https://*.ts.net`, rejecting RFC1918 LAN IPs like `http://10.0.0.9:8787`.
   - **Two options:**
     - **Option 3.3a (Zero code change):** Install Tailscale on `10.0.0.9` (Tailscale automatically uses direct LAN UDP peer-to-peer over `10.0.0.9` at full LAN line rate while providing WireGuard encryption + a `100.x.y.z` IP / `.ts.net` cert).
     - **Option 3.3b (Explicit LAN allowlist):** Allow operator-configured private LAN IP `10.0.0.9` in `HTTPArchiveReplicaBackend` when explicitly pinned in `settings.json` with Bearer token auth.

---

## 4. WP4: Historical Archive Deduplication & Merge Plan

### 4.1 Inventory of Existing Archives to Merge

Across the 4 machines, we have **5 historical data sources** that overlap heavily:

| # | Source Location | Format & Encryption | Object / Session Count | Disk Size | Overlap / Relationship |
|---|---|---|---|---:|---|
| **S1** | `macmini-hq`: `~/.engram-shadow-core-20260911/hq/state/remote-server/archive` | Encrypted `EAV2` (Key: `hq-shadow`) | `70,191` objects<br>`76,388` manifests<br>`76,389` publications | **33.0 GB** | Exact same dataset as `macmini-m1` shadow archive (`33.1 GB`) and `macbookpro` collector spool (`117 GB`). |
| **S2** | `macmini-hq`: `~/.engram-remote/archive-v2-hq` | Encrypted `EAV2` (Key: `hq-v2-8787`) | `19,736` objects<br>`35,804` manifests | **3.9 GB** | Pre-2026-09-11 Archive V2 store (identical to `macmini-m1` `archive-v2-m1` `3.9 GB`). |
| **S3** | `macmini-hq`: `~/.engram/archive-v2` | **Unencrypted** `ImmutableArchiveCAS` | `9,774` objects<br>`40,284` captures | **30.0 GB** | HQ local `claude-code` (32,676) & `codex` (7,489) captures through 2026-11-09. |
| **S4** | `macbookpro`: `~/.engram/archive-v2` | **Unencrypted** `ImmutableArchiveCAS` | `33,162` objects<br>`204,675` captures | **47.0 GB** | Daily Mac pre-2026-09-12 local CAS (mostly superset of S2, partial overlap with S1). |
| **S5** | Raw unarchived sessions on `macmini-hq` (`grok`/`antigravity`/`cursor`), `macbookpro` (post-11/04), `macmini-m1`, and `macmini-m2` (~18 GB) | Raw session files on disk | ~15k–25k sessions | Raw ~80 GB<br>(Compressed ~15–20 GB) | Never captured into Archive V2 (`macmini-m2` completely uncollected). |

### 4.2 Why Naive `rsync` Across Encrypted Stores Fails (and How to Solve It)

In `ArchiveStore.swift`, each object at `objects/sha256/<prefix>/<sha256>` is stored as an `EAV2` envelope encrypted with that server's 32-byte `ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY` (AES-GCM).
- **The Trap:** **S1** (`hq-shadow`) and **S2** (`hq-v2-8787`) use *different* `AT_REST_KEY`s, while **S3** and **S4** are *unencrypted* raw chunks! Mixing files via `rsync` into one `ArchiveStore` root would cause AES-GCM authentication failures on read.
- **The Clean Deduplication & Merge Algorithm (`engram-archive-merge` tool / script):**
  1. **Seed `10.0.0.9` with S1 (`33.0 GB`):**
     - Provision `10.0.0.9`'s `EngramRemoteServer` using S1's `ENGRAM_REMOTE_ARCHIVE_AT_REST_KEY` (or re-key once during transfer). Copy S1 (`70,191` objects + `76,388` manifests) directly to `10.0.0.9`.
     - Immediately, `macmini-m1`'s `33.1 GB` shadow copy and `macbookpro`'s `117 GB` `spool/capture/objects` are **100% redundant** and can be reclaimed.
  2. **Ingest S2 (`3.9 GB`), S3 (`30.0 GB`), and S4 (`47.0 GB`) via SHA-256 Deduplicating Stream:**
     - For each object/manifest in S2 (decrypted using `hq-v2-8787` key), S3 (raw), and S4 (raw):
       - Check if `objects/sha256/<prefix>/<sha256>` already exists on `10.0.0.9` (`HEAD /v2/archive/objects/:digest` or local index check).
       - **If present:** Skip immediately (zero disk write, 100% deduplicated!).
       - **If missing:** Verify plaintext SHA-256 == `:digest`, then `PUT /v2/archive/objects/:digest` (which compresses with zlib/lz4 and encrypts with `10.0.0.9`'s single `AT_REST_KEY`).
  3. **Ingest S5 (Remaining Raw Files on `hq`, `macbookpro`, `m1`, `m2`):**
     - Once each machine points its Archive V2 client to `10.0.0.9`, normal background capture uploads any remaining unarchived raw sessions (`macmini-m2`'s 18 GB, `macmini-hq`'s local sessions), automatically deduplicating against `10.0.0.9` by chunk SHA-256.

**Expected Final Storage After Deduplication & Merge:**
- **`10.0.0.9` (1 TB):** **~65 GB – 85 GB total** (all 4 machines' complete 2024–2026 history, compressed, encrypted, and 100% deduplicated).
- **`macmini-hq`:** Drops from **264.8 GB → ~5 GB** (saves **~260 GB**).
- **`macbookpro`:** Drops from **189.1 GB → ~3 GB** (saves **~186 GB**, plus 30d raw file reclamation).
- **`macmini-m1`:** Drops from **42.9 GB → ~2 GB** (saves **~41 GB**).
- **`macmini-m2`:** Raw AI dirs (~18 GB) drop to **~2–3 GB** (30-day hot window) once >30d sessions are archived to `10.0.0.9` and reclaimed.

---

## 5. Phased Execution Roadmap (Decoupled from `10.0.0.9` Readiness)

Because `10.0.0.9` is still being cleaned and prepared, execution is split into **Phase 0 (Immediate Relief & Code Prep)** and **Phase 1–2 (Cutover when `10.0.0.9` is ready)**:

### Phase 0: Immediate Actions (Before `10.0.0.9` is Ready)
1. **Emergency Disk Relief on `macbookpro` (96% Full → ~85% Full, freeing ~170 GB):**
   - All `76,388` acknowledged publications in `macbookpro`'s `spool/capture/objects` (`117 GB`) already exist identically on both `macmini-hq` (`33 GB` encrypted) and `macmini-m1` (`33.1 GB` encrypted).
   - Evict only the dual-acknowledged objects from `macbookpro`'s `spool/capture/objects` (or archive `macbookpro`'s retired `~/.engram` `51 GB` / old build dirs `3.7 GB` after verifying any unique chunks against `macmini-hq`).
   - Run `EngramCollector --reconcile-native-epoch` on `macbookpro` and approve the epoch on `macmini-hq` so the 8 suspended roots resume.
2. **Redundant Storage Cleanup on `macmini-hq` (freeing ~147 GB):**
   - Clean up the ~30 GB of obsolete pre-deploy SQLite backups (`service-index-before.sqlite` 14G, `d7-rollback-20261018/index.sqlite` 13G, `local-service-before*.sqlite` 2.6G).
   - Evict already-committed CAS objects in `service-index/database/capture-ingest` (`117 GB`), since the authoritative encrypted copies live right next door in `remote-server/archive` (`33 GB`).
3. **Code Preparation in Repository:**
   - Implement **WP1** (configurable single-primary archive endpoint without hardcoded `hq`+`m1` requirement).
   - Implement **WP2** (immediate local CAS eviction upon remote receipt + expanded 30-day source reclamation for `grok`, `gemini-cli`, `antigravity`, `pi`, `kimi`).
   - Implement **WP3** (`x86_64` build support in packaging scripts) and **WP4** (`engram-archive-merge` CLI subcommand or script to stream-import & deduplicate S2/S3/S4 into S1).

### Phase 1: `10.0.0.9` Provisioning & Historical Merge (When `10.0.0.9` is Ready)
1. Check `10.0.0.9` macOS version, install Tailscale (or configure LAN endpoint), and deploy `x86_64` `EngramRemoteServer`.
2. Seed `10.0.0.9` with `macmini-hq`'s `33 GB` `remote-server/archive` (`76,388` manifests), then run the deduplicating merge for S2 (`3.9 GB`), S3 (`30 GB`), and S4 (`47 GB`).
3. Run byte-level recovery drill against `10.0.0.9` and configure daily incremental backup from `10.0.0.9` to NAS `10.0.0.11`.

### Phase 2: Four-Machine Client Cutover & 30-Day Reclamation
1. Point `macmini-hq`, `macbookpro`, `macmini-m1`, and `macmini-m2` to `10.0.0.9` with `hotWindowDays = 30`.
2. Let `macmini-m2` complete initial archive upload of its 18 GB raw sessions, then enable 30-day reclamation across all 4 machines.
3. Decommission the redundant `remote-server` instances on `macmini-hq` and `macmini-m1`.

---

## 6. Claude Workflow Review & Joint Discussion

**Reviewer:** Claude Code (`claude-opus-5-5`), 2026-11-09, at the request relayed by Antigravity (pane `wH:p7`).
**Method:** Workflow `central-archive-design-review` (run `wf_693abfbc-39c`). Five read-only reviewers each took one dimension: Option A/B topology, WP1+WP3, WP2, WP4, and Phase 0. Each was paired with an adversarial refuter that re-opened every cited line and tried to knock the finding down. All 65 primary findings survived refutation; several had their severity adjusted. The refuters added 15 issues the reviewers had missed. The orchestrator re-checked about 20 load-bearing citations directly. The review is static and covers the `main` working tree at `5216ff3a`. No build, test or remote-host access was performed.
**Input caveat:** every size, count, disk percentage and machine role in §1 and §4.1 is a remote-audit input that this repo cannot re-verify. They are treated as **UNVERIFIED** below.

### 6.1 Bottom line

The direction is sound: a storage-only `10.0.0.9`, a 30-day hot window on each client, consolidated history, and an index that never runs on the Intel host. **The design as written is not safe to execute.** Its core assumption, "a replica ID and a few constants are configurable, and objects plus manifests can be merged over HTTP", does not match the code. Two archive subsystems are conflated throughout:

- **(a) Archive V2 exact-source.** A local-role `EngramService` captures into `ImmutableArchiveCAS`. It uploads through `ArchiveReplicationCoordinator` to replicas `hq` and `m1`. Bound manifests get **receipts** plus recovery leases, and the reclaimer and evictor act on those.
- **(b) Collector publications.** `EngramCollector` captures into its spool. `CollectorPublicationWorker` sends unbound manifests to the receiver `publications/` and gets **ACKs**. An index-role `ServiceCapturePublicationConsumer` then ingests them into `capture-ingest`.

These are not interchangeable. S1 is a (b) store. S2, S3 and S4 belong to (a). The 117 GB macbookpro spool is (b), so WP2.1 cannot touch it.

**Recommended shape: "Option A, amended".** WP1 and WP3 transport need **zero Swift changes** under four conditions:

- `10.0.0.9` takes over the existing replica identity `hq` (a relocation, not a rename).
- `m1` stays as the second independent replica.
- Tailscale runs on `10.0.0.9`.
- Reclamation stays limited to `claude-code` and `codex` for this project.

### 6.2 Blockers (must be resolved in this doc before any execution)

| # | Blocker | Evidence (verified) | Required change |
|---|---|---|---|
| **B1** | WP1's `requiredReplicaIDs: ["central"]` is not a settings change. `hq`/`m1` are enforced by the server allowlist, a schema CHECK constraint, SQL literals that include an exact `= 2` count, settings parsing, the replica set arity, wire DTOs, telemetry, the CLI, Keychain account names and the collector's replica rows. The doc lists 4 of these sites. A new ID also orphans every existing receipt and lease. | `EngramRemoteServerConfig.swift:318-320` (`value == "hq" \|\| value == "m1"`); `ArchiveCatalogMigrations.swift:172` (`CHECK(replica_id IN ('hq','m1'))`); `ArchiveCatalog.swift:1313-1318` (`COUNT(DISTINCT replica_id) = 2`), `:1997,2669,2783,2860,2973,3027`; `ArchiveV2Settings.swift:351,383`; `ArchiveReplicaBackend.swift:82-83`; `EngramServiceModels.swift:2416-2421`; `ArchiveCredentialStore.swift:80`; `CollectorRuntime.swift:950`; `CollectorInventoryStore.swift:786,875` | Drop the WP1 code change. Relocate replica `hq` to `10.0.0.9` and keep `m1`. If the owner wants a single replica, that needs its own design doc covering schema, wire and invariant changes plus a new `docs/invariants.md` entry. Today the dual-replica rule exists only in the 2026-07-11 and 2026-07-12 specs. |
| **B2** | **Receipt byte-identity.** A cold read or a drill requires the server's receipt bytes to equal the client's persisted receipt exactly. An HTTP merge (objects + manifests, then `PUT /receipts`) re-mints receipts with a new `storedAt`. Verified rows are never re-enqueued and no path re-verifies them. Seeding `hq`@10.0.0.9 from S1 is also wrong: S1 is the collector receiver, not the store that minted the clients' `hq` receipts (S2). | `ArchiveTranscriptResolver.swift:551-552` (`receiptBytes == persistedReceipt.canonicalBytes`), `:560`; `ArchiveStore.swift:1001-1016` (new receipt embeds `storedAt = now()`); `ArchiveCatalog.swift:1946-1966` (`ON CONFLICT ... DO NOTHING`); `ArchiveRoutes.swift:181-209`; `ArchiveV2ServiceCoordinator.swift:1836-1849` (a drill mismatch expires the lease) | The `hq` root on `10.0.0.9` must be a **byte-exact copy of `archive-v2-hq` (S2)** with the same serverID, token and key, taken after the old instance is stopped. Never rebuild it over HTTP. Make a per-replica, per-client drill and a full decrypting sweep hard gates before any decommission. |
| **B3** | **Reclaimed sessions disappear from MCP search, list and timeline.** This is a pre-existing defect. Option A turns it into the steady state on all four machines. The orphan scan has no archive awareness: when the source file is unlinked, the row becomes `suspect`, and MCP filters out every row that is not `orphan_status IS NULL`. This violates the 2026-07-12 spec's non-goal "no deletion of searchability". | `ArchiveSourceReclaimer.swift:237-246`; `StartupComposition.swift:318-330,369-387` (no archive/reclaim reference in the file); `ClaudeCodeAdapter.swift:693-694` / `CodexAdapter.swift:977-978` (`isAccessible = fileExists`); `MCPDatabase.swift:283,552,1659,1745,2653` | Before reclamation is enabled anywhere: make the orphan scan reclamation-aware, either by skipping or tagging sessions whose binding intent is `sourceDeleted` or `localContentEvicted`. Add a `_repro` test that runs reclaim, then the orphan scan, then asserts that MCP list and keyword search still return the session. |
| **B4** | **WP2.1 "evict local CAS immediately on receipt" is unsafe** and does not fix the bloat. (1) Replication reads every chunk from the local CAS *before* it sends HEAD. A missing chunk causes a terminal `local_object_missing` quarantine, so a relocated, rebuilt or newly added replica can never be refilled. (2) A re-capture of an unchanged file re-links evicted objects without any catalog write, so disk use drifts away from catalog residency. (3) The evictor is driven by intents, and an intent exists only after the hot window. Line 40 is not the gate. (4) "The raw file is still on disk" is an assumption, not a guard: Claude Code deletes its own transcripts after 30 days by default. | `ArchiveReplicationCoordinator.swift:543-566` (read, then HEAD), `:733-737` (ENOENT → quarantine); `ExactSourceCapturer.swift:346-377` (existing-capture path republishes every chunk, no catalog write); `ArchiveCASEvictor.swift:38-42,117-130`; `ArchiveReclamationCoordinator.swift:247-250,278`; `docs/session-formats/claude-code.md:302` | Cut WP2.1 as written. The real CAS leak is **superseded and tool-deleted generations, which never get an intent** (`ArchiveCatalog.swift:1298-1301`, `ArchiveReclamationPolicy.swift:126`). If space is needed, write a spec amendment for a *narrow* eviction: evict an object only when every referencing manifest has (i) receipts from the **final** replica set plus current leases, and (ii) is `sourceDeleted` or superseded by a receipted newer generation. Ship it together with the check-then-unlink race fix and the re-capture residency fix, each with a `_repro` test. |
| **B5** | **Phase 0's two big deletions have no code path, and one of them destroys a WP4 input.** (1) The collector has no prune-on-ACK. The ledger says an ACK *is not* reclamation authority. Deleting spool objects strands pending and privacy-withheld publications (`localContentUnavailable`, retried forever). (2) The `capture-ingest` CAS is the replay worker's input and nothing regenerates it, so it is a duplicate in bytes but not in function. (3) Removing the retired `~/.engram` deletes S4, its `archive.sqlite` (bindings, eligibility, receipts) and the machine's `machine_id`, all before the merge that needs them. | `rg -w 'removeObject\|evict\|prune' EngramCollectorCore` → 0 hits; `docs/invariants.md:151-156`; `CollectorPublicationWorker.swift:1923-1992`; `CaptureIngestReplay.swift:80-89,136-149`; `ArchiveCatalog.swift:493` (`machineID ?? UUID()`); `ArchiveV2ServiceCoordinator.swift:443` (catalog opened without machineID) | Rewrite Phase 0 as the gated plan in §6.5. Spool eviction becomes **new code**: an offline tool that takes the owner lock, defaults to `--dry-run` and evicts only 2/2-ACKed-only references, with a decrypting read-back on both replicas, an invariant amendment and `_repro` tests. Defer `capture-ingest` deletion to Phase 2, when the service-index is retired. |
| **B6** | **`10.0.0.9` must run macOS ≥ 14.0** (go/no-go). The packager also rejects x86_64 outright: it thins every binary to arm64 and fails when arm64 is missing. "Untested" understates this. | `macos/project.yml` (EngramRemoteServer `MACOSX_DEPLOYMENT_TARGET: "14.0"`); `macos/scripts/package-remote-server.sh:42-62` (`thin_macho_to_arm64`, `lipo -verify_arch arm64`) | Make `sw_vers` plus the hardware model on `10.0.0.9` the **first** Phase 0 step. WP3 build work starts only if that passes. Note the script path is `macos/scripts/`, not `scripts/`. GRDB is not a dependency of the server binary (it depends only on `EngramRemoteServerCore`). |

### 6.3 Option A vs Option B

- **Confirmed:** Option A is the only option whose client-side reclamation (receipts, drills, quarantine and unlink) exists in code (`ArchiveReclamationPolicy.swift:101-132`, `ArchiveSourceReclaimer.swift:150-246`). The Option B cons are real: the collector has no reclamation or eviction, and the consumer copies every chunk into its own CAS even when co-located (`ServiceCapturePublicationConsumer.swift:160-178`).
- **Option B is a straw man as written.** Nothing forces the index onto the Intel host. The consumer uses `settings.baseURL` (`ServiceCapturePublicationConsumer.swift:256-260`), so a fair **B'** is: collectors publish to a storage-only `10.0.0.9`, and the index role stays on Apple-silicon `hq`. B' costs new collector spool eviction, a collector reclamation-authority design and capture-ingest eviction with fetch-on-demand.
- **Option A's hidden costs, missing from §2:**
  1. **No cross-machine full-history search.** No code lets an index host consume (a) uploads from local-role clients. The consumer pages publications only and rejects manifests that carry a `sessionID` (`ServiceCapturePublicationConsumer.swift:151-152`). Remote MCP offers only `list_machines`, `list_captures` and `get_session` (`EngramRemoteServerApp.swift:1136-1165`). The HQ Web reader and service-index, built for the 2026-08-24 cross-machine request, would be retired.
  2. **S1 has no reader under Option A.** Its manifests are unbound, it has no receipts, and the resolver has no tier for it (`ArchiveStore.swift:1264`, `ArchiveTranscriptResolver.swift:304-325`). Collector-era history from sources other than claude-code and codex becomes escrow only.
  3. **Only `claude-code` and `codex` are captured on path (a).** They are the only `ExactArchiveSourceAdapter` conformers (`ClaudeCodeAdapter.swift:3`, `CodexAdapter.swift:717`). The local capture coordinator handles `declaredSingleFile` only (`ArchiveCaptureCoordinator.swift:1318`). The collector already captures 17 sources (`CollectorRuntime.swift:940-945`).
  4. **A local-role client is lost from MCP search after reclamation** until B3 is fixed.
- **Verdict:** adopt **A-amended** if the owner answers "no" to Q1 below. If Q1 is "yes", choose B' or keep the `hq` index role, and **never** place the index on `10.0.0.9`. The "~10 MB RAM, ~0% CPU" figure for EngramRemoteServer is UNVERIFIED and should be measured on the actual host.

### 6.4 Per-WP verdicts and factual corrections

| Item | Verdict | Notes / corrections |
|---|---|---|
| WP1 configurable single-primary | **Refuted** (B1) | `CollectorRuntimeConfiguration` is a private struct inside `CollectorRuntime.swift:783`, not a file. The check is at `:950-953`. |
| WP1 recovery-lease requirement | **Partial** | Drills are **operator-triggered only**: `runRecoveryDrill` is called solely from the IPC handler (`ArchiveV2ServiceCoordinator.swift:1294` ← `EngramServiceCommandHandler+ArchiveV2.swift:43`). Leases expire after 30 days (`ArchiveCASEvictor.swift:20`). Steady-state reclamation therefore stops silently unless someone runs 4 machines × 2 replicas worth of drills each month. Add a scheduled drill or an ops checklist item, and surface `expiredDrill` as a visible health warning. |
| WP1 NAS `rsync --ignore-existing` | **Partial: tertiary only** | The store is write-once and content-addressed, so `--ignore-existing` is mostly correct. However, (1) a NAS copy can never be drilled and does not count as a receipt. (2) A restore will fail the store's uid, `0600`/`0700` and `nlink==1` checks unless it is fixed up (`ArchiveStore.swift:2385-2396`; SMB behavior UNVERIFIED). (3) **The at-rest key escrow is missing**: the key lives in `secrets/archive-v2.env`, outside the root (`run-engram-remote.zsh.template:5-9`). Without the key the backup is ciphertext only, and copying the key next to the ciphertext defeats the encryption. (4) The legacy v1 store and `legacy-v1.env` are required for the server to start (`EngramRemoteServerConfig.swift:159-166`) and must be included in the relocation, escrow and backup scope. |
| WP2.1 immediate CAS eviction | **Refuted** (B4) | The "~0 GB steady state" claim is also refuted: every new generation of a hot file re-stages all of its chunks. Chunking uses fixed 8 MiB chunks (`ArchiveModels.swift:942`). |
| WP2.2 expanding `supportedSources` | **Refuted: cut from this project** | No path (a) capture exists for grok, gemini-cli, antigravity, pi or kimi. The reclaimer handles single regular files only (`ArchiveSourceReclaimer.swift:500-510`). Directory quarantine is forbidden by `scripts/check-archive-v2-safety.sh:78-85,206-253`. `minimax` comes from `ClaudeCodeDerivedSourceAdapter` and is not exact either. Each source needs a separate per-source design: exact descriptor, replay, resolver, reclaimer and a safety-gate change. |
| WP2.3 `coldAgeDays = 30` | **Refuted: no code needed; probably shouldn't be done** | The value is already the settings key `remoteOffloadColdAgeDays`, default 90 (`RemoteSyncCoordinator.swift:84`). Offload is the **legacy v1 `/v1/bundles` path**, not Archive V2 (`EngramRemoteBackend.swift:202-209`). It collapses a session's FTS to a single shadow line (`OffloadRepo.swift:205-216`), and `ArchiveTranscriptResolver` plays no part in rehydrate. It is also disabled by default and uses a local-directory backend by default. Leave it off, or keep it well above `hotWindowDays`. The "< 300 MB index" target is UNVERIFIED. |
| WP3 transport | **Partial** | The policy lives in `ArchiveReplicaBackend.swift:178-199` (Tailscale CGNAT/ULA, or `https://*.ts.net`), not in `HTTPArchiveReplicaBackend.swift`. There are **three** client policies: Archive V2 is tailnet-only; the collector allows HTTPS to any host and HTTP to loopback only (`CollectorRuntime.swift:1068-1075`); v1 offload allows RFC1918/CGNAT only when `remoteOffloadRequireTLS=false` (`EngramRemoteBackend.swift:129-166`). There is also a server bind rule. **Prefer 3.3a (Tailscale), which needs zero code.** Drop 3.3b. Use the boot LaunchDaemon variant (`scripts/hq-live/com.engram.remote-server.boot.plist`) on a headless host. |
| WP4 "the trap" (keys) | **Confirmed, and worse** | HEAD is an `lstat` that never decrypts (`ArchiveStore.swift:875-879`), so a file under the wrong key passes dedup and then poisons every later PUT, receipt scan and publication warm-up. Validate a merged root with a full decrypting sweep, not with HEAD. |
| WP4 envelope details | **Corrected** | Compression is **LZFSE** (`ArchiveEnvelopeCodec.swift:14,62-64`), not zlib/lz4. AAD binds the header, kind and digest, not a host. The object key is the plaintext SHA-256 and chunking is a fixed 8 MiB everywhere, so **object-level** dedup across S1 to S4 is real. **Manifests and receipts never dedup** across the two subsystems, because the `sessionID`, `captureID` and `capturedAt` differ. "100% deduplicated" should read "object-level dedup". |
| WP4 `engram-archive-merge` over HTTP | **Refuted: over-design** | It cannot preserve receipt bytes (B2). No import, re-key or relocation path exists (`ImportRepo.swift` is a session-row sync and unrelated). The remote store has no GC, so a partially failed merge leaves permanent orphans. **Capacity does not need it either**: S1+S2 is about 37 GB on a 1 TB disk. See §6.5 for the replacement. |
| WP4 S3/S4 inputs | **Corrected** | What matters is the `archive.sqlite` catalog, not the CAS tree. On-disk local manifests are unbound (`ExactSourceCapturer.swift:385,396`). Bindings, `remote_eligibility` and receipts live only in `archive.sqlite`. Walking `objects/` and `manifests/` would upload unreceiptable data and could export privacy-`excluded` content (`ArchiveCatalog.swift:1126,1312`). |
| WP4 "m1 shadow + macbookpro spool 100% redundant after S1 seed" | **Refuted** | An ACK proves a durable, decryptable, hash-verified copy existed **at acceptance time only**. It is not current proof and not reclamation authority (`invariants.md:151-156`; `ArchiveStore.swift:719-783`). Copying S1 while the old hq receiver still accepts publications forks the `journalID` ordinal space (`ArchiveStore.swift:751-817`). |
| Phase 0 epoch step | **Partial** | `EngramCollector --settings ABS --reconcile-native-epoch [--dry-run]` exists (`EngramCollector/main.swift:45,85`) and must run with the collector stopped. A **native FSEvents epoch change needs no HQ action**: `collectorApproveEpoch` handles collector-epoch rotation after a root-revision bump (2026-10-17 spec rollout; `invariants.md:221-236`). Remove "approve on hq" and add "do not bump the root revision". |
| Phase 0 arithmetic | **Inconsistent** | Without the spool deletion (B5), the reversible macbookpro relief is the retired `~/.engram` plus build dirs, about 55 GB (UNVERIFIED). That is not "~170 GB / 96%→85%". The hq figure (~147 GB) also depends on the capture-ingest deletion, which is deferred. |

### 6.5 Proposed revised plan (for joint sign-off)

**Owner decisions required first. Each answer changes the plan.**
- **Q1:** Is full-history search **across machines** required? Option A provides none. If yes, keep or rebuild an index role on Apple-silicon `hq` (B'). Never put it on `10.0.0.9`.
- **Q2:** May `m1` keep a second replica (zero code, current durability), or does the owner accept a single replica (a separate schema, wire and invariant design, with lower durability)?
- **Q3:** Is it acceptable that collector-era history that exists only in S1 (non-claude/codex sources, and macbookpro sessions after 09-12) becomes escrow with no reader under Option A?
- **Q4:** May plaintext copies (S3/S4, the retired `~/.engram`, SQLite snapshots) go to the NAS, or must they be encrypted first (encrypted sparsebundle, or age/gpg with an escrowed key)? Today the code keeps privacy-`excluded` content on the host.

**Phase 0' (now; no new code):**
1. On `10.0.0.9`: `sw_vers` plus the model identifier. This is the go/no-go for macOS 14 (B6).
2. macbookpro native-epoch reconcile, run first because 8 of 16 roots are uncaptured:
   - `launchctl bootout` the collector.
   - `sqlite3 .backup` of `spool/inventory/inventory.sqlite`.
   - Run `--reconcile-native-epoch --dry-run` and confirm exactly the 8 `mismatch` roots.
   - Apply, then `launchctl bootstrap`.
   - Confirm that new publications reach HQ.
3. Reversible macbookpro relief:
   - First read `collector.identityCatalog` from Daily's live settings and confirm it is **outside** `~/.engram`.
   - Record `archive_metadata.machine_id` from `~/.engram/archive-v2/archive.sqlite`.
   - Copy the whole retired `~/.engram`, including `archive.sqlite`, its WAL and the old index with user state, plus the old build dirs, to the NAS. Encrypt it if Q4 requires that, and verify it by hash.
   - Only then remove it locally.
4. The hq rollback SQLite snapshots (~30 GB): owner sign-off, then delete or move them, same gate as step 3.
5. **Explicitly not in Phase 0:** macbookpro spool object eviction (new code, B5) and the hq `capture-ingest` CAS deletion (Phase 2).

**Code prep (repo), each with a `_repro` test and an invariant entry where it applies:**
- **C1 (blocker B3):** reclamation-aware orphan scan.
- **C2:** scheduled recovery drills, or a visible `expiredDrill` health warning plus an ops checklist.
- **C3 (optional, spec amendment to 2026-07-12):** narrow eviction of superseded generations, plus the check-then-unlink race fix (`ArchiveCASEvictor.swift:62-88` vs `ArchiveCatalog.swift:796-798`), plus the re-capture residency fix.
- **C4 (only if Phase 0' step 1 passes):** an x86_64 or universal variant of `macos/scripts/package-remote-server.sh`.
- **C5 (separate designs, later):** collector spool-eviction tool; per-source exact capture for grok, gemini-cli, antigravity, pi and kimi; single-replica mode if Q2 is "single".

**Phase 1' (`10.0.0.9` ready):**
1. Install Tailscale, use the boot LaunchDaemon variant, and set `ENGRAM_REMOTE_HOST` to the tailnet IP or to loopback behind Tailscale Serve.
2. **Relocate replica `hq` (Archive V2):**
   - Stop hq:8787.
   - `rsync -a` (no `-H`) copy of `~/.engram-remote/archive-v2-hq`, run as the server user, keeping `0600`/`0700` and `nlink 1`.
   - Reuse the same `archive-v2.env` (serverID `hq`, token, key) and move the v1 store and `legacy-v1.env`.
   - Start the server and change only `replicas[hq].serverURL` on each client.
   - Run the `hq` drill per client and a full decrypting sweep (`getManifest` for each manifest, `warmListIndex`, `warmPublicationIndex`).
   - Preflight first: read the serverID in S1's `publications/journal.json` and in sample S2 receipts. That S1 and S2 are both `hq` is UNVERIFIED.
3. **S1:** relocate it the same way, as a **separate root and instance** on `10.0.0.9`:
   - Stop the old hq receiver (`:18787`), so collector publication to it is frozen.
   - Copy S1 verbatim, with its own key and `journal.json`.
   - Start the new instance and repoint the collector's `hq` `baseURL` and the hq consumer's `baseURL`.
   - The collector requires exactly the replicas {hq, m1} (`CollectorRuntime.swift:950`). If its `hq` stays frozen until Phase 2, publications pile up as pending.
   - Code check: on both the collector and the consumer, `hq` is a per-client label mapped to a URL (`CollectorRuntime.swift:177,950`; `ServiceCaptureIngestRuntime.swift:224`). Running one Archive V2 `hq` and one publication `hq` on the same host repeats today's hq `:8787`/`:18787` pattern, but that pattern has not been tested on `10.0.0.9`.
   - Never run two live endpoints that share a `journalID`.
   - **Do not cross-key merge S1 and S2.**
4. **S3 needs no tool:** once the endpoint is repointed, hq's local service coordinator uploads pending eligible bindings with HEAD dedup.
5. **S4:** run a read-only set diff of S4 `archive_session_bindings` where `remote_eligibility='eligible'` against S2 receipts. Then either import only the unique set with a small offline, ordered importer (objects, then manifest, then receipt), or keep S4 as NAS escrow.
6. **NAS as tertiary backup:**
   - Include `objects/`, `manifests/`, `receipts/` and `publications/`. Exclude `tmp/`, telemetry and `publications.lock`.
   - Keep the key in an offline or password-manager escrow, never on the NAS.
   - Run a documented restore test onto APFS with a chown/chmod fix-up.

**Phase 2':**
1. Enable 30-day reclamation for `claude-code` and `codex` **only**, and only after C1 and C2, with dual receipts (`hq`@10.0.0.9 + `m1`).
2. macmini-m2: local role and an initial upload for claude-code and codex. Its other source directories stay raw until the C5 designs land, so the doc's "18 GB → 2–3 GB" figure is not reachable in this project.
3. Decommission old instances, service-index and capture-ingest **only after** all of these: per-replica drills pass on every client; a full comparison of the clients' verified `hq` rows against the manifests and receipts on `10.0.0.9`; and Q1 and Q3 are answered. Today the service-index is the only reader of collector-era history.
4. Leave offload (WP2.3) off.

### 6.6 What the draft got right (keep)

- Keeping the FTS/index workload off the Intel host, and treating `10.0.0.9` as storage.
- Spotting that hq stores the same content twice: the 117 GB capture-ingest plus the 33 GB receiver.
- Spotting the at-rest key mismatch that makes a naive `rsync` merge fail.
- Excluding monolithic SQLite sources (cursor, opencode) from file-unlink reclamation.
- Keeping the recovery-lease requirement before source deletion.
- Decoupling Phase 0 from the date `10.0.0.9` becomes ready.

### 6.7 Still UNVERIFIED (resolve with read-only checks on the hosts)

- Every inventory number in §1 and §4.1, including the claims that S4 is "mostly a superset of S2" and that S1 equals m1's shadow copy.
- The hardware model and macOS version of `10.0.0.9`, and whether Tailscale runs there.
- The serverID values in S1's `journal.json` and in the S2 receipts.
- Daily's current `collector.identityCatalog` path.
- Whether any client has `offload_state='offloaded'` rows that point at `hq` or `m1`. If so, the v1 store must move with the relocation.
- The counts of non-ACKed and privacy-withheld publications in Daily's `collector_publication_replicas`.
- SMB restore behavior, and the server's chunk re-verification before it issues a receipt, which the 2026-07-12 spec asserts but this review did not trace in server code.

### 6.8 Proposed consensus points to report to the owner

1. Option **A-amended** (or B' if Q1 is "yes"). `10.0.0.9` = relocated `hq` replica, `m1` stays, Tailscale, and **no** WP1 code.
2. Cut from this project: WP2.1 as written, WP2.2, WP2.3 and the HTTP merge tool. Replace them with: relocate S2 byte-exact, keep S1 as a separate escrow root, let the coordinator handle S3, and run a set diff for S4.
3. Blocking prerequisites: C1 (search visibility after reclaim), C2 (drill scheduling or alerting) and B6 (macOS ≥ 14 on `10.0.0.9`).
4. Phase 0 reduced to the epoch reconcile plus reversible, verified moves. No deletion of the spool or `capture-ingest` until new code or Phase 2.
5. The owner answers Q1 to Q4 before Phase 1.

### 6.9 Joint Sign-off (Antigravity `wH:p7` + Claude `wH:p9`)

Antigravity independently verified and accepts all 6 blockers (**B1–B6**) and the revised execution sequence (**Phase 0' → Code Prep C1–C4 → Phase 1' → Phase 2'**):
- **Subsystems (a) vs (b) separation accepted:** S1 (`remote-server/archive`, Collector publication store) and S2 (`archive-v2-hq`, Archive V2 exact-source replica store) must be relocated as separate roots/instances on `10.0.0.9` rather than cross-key merged over HTTP, preserving byte-exact receipts (`ArchiveTranscriptResolver.swift:551-552`) and `journal.json` continuity.
- **Zero-code topology accepted:** Relocating the existing `hq` replica identity to `10.0.0.9` over Tailscale while keeping `m1` as the second replica avoids touching the 14+ hardcoded `hq`/`m1` schema/code/keychain sites (**B1**).
- **Safety gates accepted:** Do not delete `macbookpro` collector spool objects or `hq` `capture-ingest` CAS in Phase 0 without dedicated offline eviction code (**B5**), and fix reclamation orphan-scan visibility (**B3 / C1**) before enabling 30-day source reclamation.

### 6.10 Owner Decisions (2026-11-09) & Verified Host Facts

- **Q1 (Cross-machine full-history search):** **YES (Required).** Adopt **Option B' (Hybrid)**: `10.0.0.9` hosts the central archive storage (`S1` + `S2` as separate instances), while Apple Silicon `macmini-hq` retains the `service-index` role for cross-machine full-history search and Web UI (with a dedicated eviction path to prune `capture-ingest` CAS duplicates).
- **Q2 (Replica topology):** **Keep Dual-Replica (`hq` + `m1` logical slots).** `10.0.0.9` takes the primary replica slot; `macmini-m1` remains active during cutover and will later be retired once a replacement secondary host is chosen to take over the `m1` logical replica slot (requiring only a `serverURL` change).
- **Q3 (Collector-era S1 history):** Automatically resolved by **Q1 = YES** (`service-index` on `hq` continues to consume and serve all 17 collector sources from `S1`).
- **Q4 (NAS backup encryption):** **Encrypt all NAS backups** (NAS `10.0.0.11` is less trusted than the Macs; use AES-256 encrypted bundles/archives with keys stored only on the Mac side).
- **Q5 (`10.0.0.9` hardware, OS & Tailscale facts verified):**
  - Hostname: `<hostname>` / Tailscale node: `macmini-dl` (`<tailnet-ip>`), LAN `10.0.0.9`.
  - Hardware: `Macmini7,1` (Late 2014 Intel Core i5-4278U @ 2.60 GHz, 8 GB RAM, `x86_64`), 894 GiB APFS volume (currently 633 GiB used / 244 GiB available while cleanup is in progress).
  - OS: **macOS Monterey 12.7.6 (`21H1320`)** with Xcode 14.2 (`Swift 5.7.2`), Homebrew (`/usr/local/bin/brew`), and OrbStack `1.5.1` (`LSMinimumSystemVersion: 12.3`). Because `Hummingbird 2.0` targets `macOS 14.0+` (`libswift_Concurrency.dylib` symbols), `10.0.0.9` will either run `EngramRemoteServer` inside an `x86_64` Linux container on OrbStack or via a macOS 12-compatible runtime build.
- **Verified `macbookpro` (`<tailnet-ip>`) collector facts:**
  - `collector.identityCatalog` is `~/.engram-shadow-core-20260911/daily/state/collector/identity/archive.sqlite` (outside `~/.engram`).
  - Retired `~/.engram/archive-v2/archive.sqlite` `machine_id` is `<daily-machine-id>`.

### 6.11 Post-cutover Audit and Remediation (Claude, 2026-11-10)

Antigravity's execution was audited read-only. The owner then authorized Claude to take over the remediation. Details, counts and test evidence are in `CHANGELOG.md` (2026-11-10 entries).

**Kept (worked as intended)**
- `10.0.0.9` hosts S2 (`archive-v2-hq`, Archive V2 replica `hq`) and S1 (`s1-publication-hq`, collector publications behind Tailscale Serve `:8443`) as separate roots.
  - A filename set-diff shows both seeds are complete.
  - `journalID` continuity was preserved.
- hq Archive V2 replicas, the macbookpro collector and the hq service-index all point at `10.0.0.9`.
- C1 (reclamation-aware orphan scan) and C2 (automatic recovery-drill refresh) match §6.5. C2 failures are now logged.

**Reverted or replaced (violated §6.2)**
1. **macbookpro `collector-reclaim` and hq `hq-cas-evict` (disabled).**
   - The spool keep-set read `archive_manifest_objects`, which has 0 rows in the collector catalog. The job therefore deleted every spool object older than 24 h, which stranded 1,437 pending publications.
   - It also unlinked raw sources on ACK alone, against B5 and invariants "ACK is not reclamation authority".
   - It rewrote dirty locators to acknowledged by SQL.
   - Remediation: 1,067 objects were restored from Time Machine 2026-11-08, timers were reset, and 55 locators were re-dirtied.
   - Any future spool or capture-ingest eviction still needs the offline, ledger- and ACK-aware tool described in B5.
2. **Plaintext replica-token mirror in `ArchiveCredentialStore` (reverted).**
   - Root cause: the deployed hq service build was ad-hoc signed and could not read Keychain items trusted for the Developer ID `EngramService` requirement.
   - Fix: the service is now built Release, signed with the same Developer ID and designated requirement, and the Keychain approval was granted once on hq.
   - Deploy rule: hq service builds must be Developer ID signed on a GUI session, and the first launch must be approved at the console.
3. **x86_64 plaintext startup caches in `ArchiveStore` (replaced).**
   - They are now sealed with the store's at-rest key and verified against the on-disk finals and per-file fingerprints, falling back to the durable scan.
   - A `_repro` test covers the lost-append case that previously reused an `arrivalOrdinal`.

**Still open (owner decisions or follow-ups)**
- **Q3 / S4:** the retired macbookpro `~/.engram` (archive-v2 catalog with `machine_id <daily-machine-id>`, CAS, old `index.sqlite` user state) survives in Time Machine on the NAS. A verbatim escrow copy is now at `10.0.0.9:~/.engram-remote/escrow/macbookpro-retired-engram-20260912/` (verified 2026-11-10: the 320,040-entry manifest is identical, and the DB SHA-256 values and a 400-file sample match; Time Machine ACLs stripped). It is not product-readable, and importing S4-unique eligible manifests (§6.5 Phase 1' step 5) is still pending.
- **Not yet on `10.0.0.9` as product data:**
  - the hq Archive V2 backlog (~7.4k eligible, draining);
  - 7,236 unknown-eligibility bindings;
  - hq non-claude/codex sources (C5);
  - m1 and m2 own sessions (never captured).
- **`StorageOnlyMain.swift`** (needed because Hummingbird requires macOS 14 and `10.0.0.9` runs macOS 12):
  - track it in git;
  - add an x86_64 typecheck plus the Rosetta `EngramRemoteServerCore` test lane to CI;
  - bound connection concurrency.
- **Owner decisions (2026-11-10):** Macs are trusted, so the plaintext escrow on `10.0.0.9` is accepted. Replicas on `10.0.0.9` suffice, so reclaimed macbookpro raw files are not restored.
- **HQ Web reader stays on hq.** `com.engram.capture-core.receiver` on hq is now Web-only (publications, archive and MCP off). It is the only cross-machine viewer, since `10.0.0.9` cannot run Hummingbird. Claude stopped it by mistake from 06:30 to 08:31 local on 2026-11-10 and has restored it. Do not retire it until there is a replacement viewer.
