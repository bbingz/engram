# Round-2 Context: Engram Remote Archive — Open-Question Adjudication

## 1. Situation

Engram is a local macOS cross-tool AI session aggregator (SwiftUI app + Swift
EngramService/EngramMCP, SQLite via GRDB, FTS5 trigram, optional local
embeddings + RRF). Round 1 (22-agent research+design workflow, 2026-07-11)
produced a recommended architecture: invert ownership so a verbatim,
content-addressed, compressed transcript archive becomes the system of record;
Mac keeps a recent hot window; a 24/7 personal server (Tailscale Serve) holds
full cold history; analytics split local-hot / server-full.

The user has accepted the overall direction. Round 2 (this effort) must
adjudicate the open questions round 1 left behind. The user's engineering
culture (from org working agreements): simplicity first, minimum code, no
speculative features, solo developer, single user, personal data. Any design
that asks one person to babysit a small production data platform is wrong.

Hard constraints: Mac app bundle is Swift-only (no Node in product path);
server may run any stack (Linux/Docker/anything); all Mac writes go through
EngramService; idempotent GRDB migrations; existing session tiers
skip/lite/normal/premium; transport is Tailscale (preferred) or authenticated
public endpoint.

## 2. Round-1 Final Synthesis (verbatim)

# Engram Archival System of Record — Final Recommendation

## 1. Build-vs-integrate verdict

**No mature product can be adopted wholesale or as an upstream dependency for the archival core.** The space is crowded but every close analog fails at least one hard constraint:

- **Direct product analogs** — `Dicklesworthstone/coding_agent_session_search` (CASS, Rust/Tantivy, 22+ sources) and `kenn-io/agentsview` (Go, 29 sources) — prove the idea works and is already shipped by others, but are separate applications in incompatible runtimes. Mine their adapter lists and UX; import nothing.
- **Agent-memory platforms** (mem0, Letta, Zep/Graphiti, Cognee, claude-mem) are Python/Node and *extraction-first* — they distill conversations into facts, the opposite of verbatim archival. Research (CogCanvas ablation) supports keeping verbatim source.
- **LLM observability** (Langfuse, Phoenix, Opik) are all multi-service Docker stacks; none embeddable in Swift.
- **Sync engines**: Turso/libSQL and PowerSync both force a **client driver swap away from GRDB** (reject). ElectricSQL has no Swift client. rqlite gives no local copy.

**What *is* adoptable** are lower-level primitives: Apple Compression (LZFSE), the sqlar schema pattern, `sqlite3_blob_open`, Tailscale Serve, Litestream (server-side), DuckDB-swift, and zstd (server-side only).

⚠️ **Name collision**: `Gentleman-Programming/engram` (5k stars, MIT, active) already uses "Engram" for a near-identical cross-agent memory concept.

**Verdict: build the archival core in-house on Swift/GRDB; assemble from verified primitives; take zero runtime dependency on a sync engine or memory platform.**

## 2. Recommended architecture

**Base = Panel winner P2 (Verbatim Archive-of-Record)** — stock SQLite/GRDB, redaction-gated, server-optional, tightest phasing. Grafted with: **convergent encryption (P3)**, **compression/dedup spike before server sizing (P3)**, **base64 externalization (P1/P3)**, **server-side zstd dictionary (P1)**, **never-delete-last-copy + pause-aging-when-backup-lagging (P1)**, **get_compaction_delta + progressive disclosure (P1)**, and P2's own **redaction gate**.

### Layer diagram

```
MAC (Swift-only bundle)                      24/7 SERVER (any stack, Tailscale)
┌───────────────────────────────┐           ┌────────────────────────────────┐
│ SwiftUI app (read-only)       │           │ Blob store (CAS, SHA-256 keys) │
│  federation-aware detail/     │           │  convergent-encrypted chunks,  │
│  analytics; offline banner    │           │  zstd-dictionary compressed    │
├───────────────────────────────┤           ├────────────────────────────────┤
│ EngramService (sole writer)   │  HTTPS/   │ Postgres OR SQLite+Litestream: │
│  indexer dual-writes archive; │  JSON     │  session metadata mirror,      │
│  read resolver: disk→local    │◄────────► │  chunk manifests, sync_ledger, │
│  archive→remote; aging runner │  over     │  machine_registry, FTS mirror  │
├───────────────────────────────┤  Tailscale├────────────────────────────────┤
│ Local SQLite (GRDB, hot win.) │  Serve    │ DuckDB read-only sidecar over  │
│  metadata+FTS+summary (ALL,   │           │  Parquet exports; rollup tables│
│  forever) + archive_chunks    │           ├────────────────────────────────┤
│  (hot only) + session_archive │           │ Litestream → versioned object  │
│  reuse offload_queue/ledger   │           │  storage (backup + PITR)       │
└───────────────────────────────┘           └────────────────────────────────┘
       EngramMCP (this + other tailnet machines) ──► server read API
```

### Data model

**Local (additive, idempotent GRDB migrations — no rewrite of the live 743 MB DB):**
- `archive_chunks(hash TEXT PK, algo INT, uncompressed_size INT, data BLOB)` — content-addressed over the **plaintext** hash, LZFSE-compressed, deduped across sessions (Git CAS model).
- `session_archive(session_id PK, schema_version, source_format, chunk_manifest BLOB, total_bytes, content_hash, captured_at, durable_state)` where `durable_state ∈ captured|verified_remote|reclaimable`.
- Reuse existing `offload_state`→`archive_state`, `offload_queue`, `rehydrate_queue`, `sync_ledger`. Stream large blobs via `sqlite3_blob_open`.
- **Invariant:** `sessions` + `sessions_fts` + `summary` retained **forever for every session** (small, regenerable) so search/list/analytics stay functional offline.

**Server (outside Swift-only constraint):** SHA-256-keyed blob store holding convergent-encrypted, zstd-dictionary-compressed chunks; Postgres (or stock SQLite) mirror of metadata + manifests + `sync_ledger` + `machine_registry` (namespaces session IDs per host); DuckDB/Parquet read sidecar.

### Retention/aging lifecycle — three independent clocks, default-safe

1. **Original JSONL files**: never auto-deleted by default. Deletable only when captured+hash-verified locally **AND** (if server configured) replicated+hash-verified remotely **AND** present in a backup. Deletion → tombstone (path+hash) inside an undo window. Payoff: user can safely re-enable Claude Code's disabled 36500-day cleanup.
2. **Local blobs**: cold sessions' `archive_chunks` purged only after `verified_remote`; `PRAGMA incremental_vacuum` reclaims pages.
3. **Server**: append-mostly, immutable CAS; unreferenced blobs GC'd **only after a retention window**. Continuous Litestream replication + periodic snapshot.

**Hard safety gates (failing-first `_repro` tests):** never delete the last durable copy; pause aging whenever offline **or** backup/Litestream replication is lagging; restore re-verifies **every** hash before trusting bytes.

## 3b. Topology & sync

**Recent-window policy:** hot = recency (default **90 days**) ∪ all `normal`/`premium` tier sessions. `lite`/`skip` demote sooner; `skip`/subagent never archived.

**Ingestion/aging protocol:** chunk transcript on message boundaries → **detect & externalize embedded base64/binary payloads** → SHA-256 over plaintext → dedup → convergent-encrypt → LZFSE (local) / zstd-dict (server) → `HEAD`-then-`PUT` idempotent upload → server verifies content hash → ack → `sync_ledger` records `remote.contentHash == local`. Resumable via `sync_ledger` on reconnect.

**Read federation:** resolver transparently tries on-disk → local archive → remote body; fetched cold bodies LRU-cached locally.

**Offline/partition:** metadata+FTS+summary always local ⇒ search, list, and hot-window analytics keep working; only cold bodies are unreachable. Writes buffer in `offload_queue`.

**Exposure — recommendation: Tailscale Serve by default, no public endpoint.** Auth = capability bearer token + peer-identity check + client-side convergent encryption. Public access only if ever truly needed, via Funnel **+ mTLS + bearer + rate-limit**. **Backup:** Litestream continuous WAL replication to a second, versioned object store + periodic full snapshot; documented restore drill.

## 3. Migration path (each phase independently shippable, default-OFF)

- **Phase 0 — Disk hygiene:** prune the stray 719 MB `.bak`, set `auto_vacuum=INCREMENTAL`, run `PRAGMA incremental_vacuum`.
- **Phase 1 — Local durable body store (no server):** `archive_chunks` + `session_archive`; indexer dual-writes LZFSE+CAS transcript with base64 externalization; `get_session` falls back to archive when the original is missing.
- **Phase 2 — Aging/reclaim (local-only):** confirmed-durable-before-delete gate, tombstone/undo, UI to safely re-enable Claude Code cleanup.
- **Spike (1 week, before Phase 3 sizing):** LZFSE vs zstd-dictionary on real JSONL; convergent-encryption dedup ratio; base64 externalization impact.
- **Phase 3 — Full-body remote tier:** ArchiveBundle v2, server BlobStore, convergent encryption, sync_ledger hash verify, read federation + offline degradation.
- **Phase 4 — Server upgrade + multi-machine:** Postgres/DuckDB analytics, Litestream backup/restore runbook, read-only MCP/API for other tailnet machines.
- **Phase 5 — Backtracking MCP surface** (§4).

**Release gate:** land body redaction (roadmap #82) **before** any durable verbatim store is enabled by default.

## 4. Agent history-backtracking interface

- **`get_session`** — archive-backed (disk→local→remote).
- **`search`** — federated keyword+semantic over full corpus, RRF-fused, **project-scoped by default**, recency-decay ranked.
- **`project_timeline(project, from, to)`** — bi-temporal (event-time vs indexed-time).
- **`get_decisions(project)`** — Cline-Memory-Bank taxonomy mined from transcripts, grounded in verbatim chunks.
- **`recover_compaction(session)` + `get_compaction_delta(session)`** — surface exactly the verbatim tool outputs and reasoning Claude Code compaction evicted. **The core differentiator.**

**Retrieval contract:** claude-mem 3-layer progressive disclosure (search/list → timeline → fetch-by-id); every result cites `session_id + chunk_hash`. **Multi-machine:** other machines run EngramMCP against the server API, or a thin server-hosted MCP endpoint; authed by capability token over Tailscale.

## 5. Analytics plan

*Local/hot:* keep today's Swift read facades over sessions/git_repos/session_work_beats/session_costs/session_tools aggregates. *Full-history/server:* DuckDB read-only sidecar over Parquet exports of the metadata mirror, plus incrementally-refreshed rollup tables updated on ingest — cross-tool token/cost rollups, per-project sparklines, multi-year trends. App analytics call the server API when online, fall back to local hot-window aggregates offline with a "hot window only" indicator. Analytics read metadata/aggregates only — never decrypt bodies.

## 6. Upstream components

Adopt: Apple Compression (LZFSE, client), Tailscale Serve/ACL, sqlar schema pattern, sqlite3_blob_open, Litestream (server-side), DuckDB-swift (read-only sidecar), zstd+dictionary (server-side only). Learn-from-design only: CASS, AgentsView, claude-mem, Graphiti, Letta, Cline Memory Bank, Git CAS, notmuch, CogCanvas. Reject: libSQL/Turso, PowerSync (client driver swap abandons GRDB).

**Build in-house:** Swift archive-capture stage, CAS chunker + base64 externalizer, convergent-encryption layer, federation read resolver, aging/reclaim runner, MCP tool surface, server ingest/verify API.

## 7. Top risks + open decisions

Risks: permanent history loss (mitigated by verified-durable gates); credential/PII vault (redaction gate); encryption-vs-dedup collision (convergent encryption); weak compression on base64 (externalization); server SPOF (local metadata invariant); migration disk exhaustion (Phase 0); name collision + shipped competitors.

Open decisions: server OS/specs/storage; recent-window length (rec: 90d ∪ normal/premium); public exposure appetite (rec: Tailscale-only); redaction depth/reversibility; convergent-encryption tradeoff.

## 3. Round-1 Completeness Critique (verbatim)

### gaps
- KEY MANAGEMENT IS ENTIRELY ABSENT. Convergent encryption is prescribed but there is no story for where keys live (Keychain?), master-secret vs pure-deterministic derivation, rotation, or recovery after Mac loss/wipe. If the key is lost, 100% of server ciphertext is permanently unreadable, which contradicts the 'server-loss alone != data loss' safety claim. Single largest hole.
- SERVER-SIDE THREAT MODEL NOT EXAMINED. Convergent encryption keyed by plaintext hash means a compromised server can mount a confirmation/dictionary attack to recover low-entropy content. 'Tailscale-only' says nothing about what an attacker who owns the box can read.
- VERBATIM vs REDACTION vs CAS is an unresolved three-way contradiction. Redacting changes the plaintext hash, so redacted chunks can't dedup against or verify equal to the original bytes, and recover_compaction may hand back redacted-not-verbatim content. Whether redaction runs before or after hashing is never worked out.
- SEMANTIC SEARCH OVER FULL CORPUS HAS NO SERVER VECTOR STORE. §4 promises federated keyword+semantic search, but the architecture stores only FTS + metadata on the server; embeddings are local-only (brute-force cosine KNN). Semantic federation is claimed but architecturally impossible as drawn; brute-force KNN won't scale to a multi-year corpus.
- BLOB-STORE DURABILITY IS AMBIGUOUS. Litestream covers the metadata DB; the CAS blob store (the actual archive bytes) has no stated replication/backup path. If the server SSD dies, Litestream restores metadata pointing at blobs that are gone.
- CAS RE-CHUNKING COST ON FORMAT EVOLUTION unaddressed. Any change to the chunker changes every hash, breaks dedup, and forces a full re-upload. Migration across chunker/schema versions is not planned.
- MULTI-WRITER SEMANTICS UNDER-SPECIFIED. Multi-machine federation means N EngramService instances mutate one shared server metadata mirror. Concurrent writes, idempotency under races, same logical session on two machines (cloud-synced ~/.claude) — double-archive / conflict resolution — not covered.
- FEDERATED SEARCH RESULT CONSISTENCY not designed. Local FTS (fresh) and server FTS mirror (lagging) can return overlapping/divergent/duplicated hits.
- LOCAL BLOB INTEGRITY / DB CORRUPTION not handled. Hash verification described only for the remote path. Local archive_chunks bit-rot, torn writes, SQLite corruption recovery unaddressed — yet Phase 2 lets the local archive authorize deletion of originals.
- APP<->SERVER VERSION SKEW absent. No API versioning, compat matrix, or forward/backward behavior.
- RECLAIM MATH LIKELY OVERSTATED. Hot = 90d UNION all normal/premium means the >90d normal/premium portion stays local; the cited ~3.2 GB reclaim doesn't subtract it.
- get_decisions MINING has no compute home (Mac? server? which model? cost?).
- OPERATIONAL TCO / OWNERSHIP of a 24/7 personal server not examined.
- STORAGE GROWTH PROJECTION missing (multi-year, multi-machine).
- DATA GOVERNANCE / LEGAL modality not run (third-party PII, NDA code in a long-lived personal vault).

### must_resolve_before_deciding
- Key management & recovery design (custody, master-secret vs pure-convergent, device-loss recovery).
- Blob-store (CAS) durability/backup path on the server.
- Verbatim vs redaction vs content-hash reconciliation.
- Server-compromise threat model for convergent encryption.
- Local blob integrity + corruption verification before Phase 2's delete-original gate.
- Whether semantic search over full history is in scope — if yes, needs a server-side vector store + ANN plan.
- User decision: willingness to own 24/7 server maintenance; whether work/NDA content is permitted in the archive.

### nice_to_have
- Multi-writer / same-session-on-two-machines conflict resolution spec.
- Federated search result dedup + freshness reconciliation.
- App<->server API version/compat matrix.
- Concrete RPO/RTO targets and a rehearsed restore drill.
- Recomputed net-reclaimable-bytes estimate.
- CAS re-chunking/migration cost model.
- Compute location/cost for get_decisions mining.
- Multi-year storage growth projection.

## 4. Item Registry (use these IDs in all outputs)

Cluster A — crypto & privacy chain:
- G1: key management & recovery (custody, rotation, device-loss recovery, multi-machine distribution)
- G3: verbatim vs redaction vs content-hash/CAS three-way contradiction
- G4: server-compromise threat model for convergent encryption
- D3: public exposure appetite (Tailscale-only vs Funnel/public)
- D4: redaction depth & reversibility
- D5: work/NDA content governance (per-project exclusion, consent scope)

Cluster B — durability chain:
- G2: CAS blob-store backup/replication path (Litestream covers only metadata DB)
- G5: local blob integrity & corruption verification before the Phase-2 delete gate
- N3: app<->server API version skew / compat matrix
- N4: RPO/RTO targets + rehearsed restore drill
- N6: CAS re-chunking / format-evolution migration cost

Cluster C — search & mining architecture:
- G6: server-side vector store / semantic search over cold corpus (or explicit descoping)
- N2: federated search result dedup + freshness reconciliation
- N7: get_decisions / timeline mining compute home + cost

Cluster D — sizing, ops & multi-machine:
- G7: recompute NET reclaimable bytes under policy variants (empirical, from the real DB)
- D1: server OS/specs/storage recommendation + minimal monitoring set + TCO
- D2: hot-window length policy
- N1: multi-writer / same-session-on-two-machines semantics
- N8: multi-year storage growth projection

## 5. Empirical Ground Truth (round-1 recon)

- ~/.claude/projects: 5,832 MB, 28,280 files, oldest 2025-12-13, >90d = 1,947 MB
- ~/.codex/sessions: 8,628 MB, 2,701 files, oldest 2025-11-20, >90d = 1,273 MB; 3 outlier files total ~1.6 GB (Apr 27-29 2026 rollouts), gzip ratio only ~1.33x → embedded base64/binary payloads
- ~/.gemini: 861 MB, 5,288 files, >90d = 31 MB
- ~/.engram/index.sqlite: 741 MB (+wal/shm = 743 MB); stray backup index.sqlite.before-kimi-rescan-20260701133916.bak = 719 MB
- Claude Code cleanupPeriodDays = 36500 (cleanup effectively disabled)
- Codebase: DB has NO message-body table; sessions_fts + summary are regenerable derivatives; get_session re-reads original file from disk (MCPTranscriptReader); opt-in remote-offload scaffolding exists (offload_state/offload_queue/rehydrate_queue/sync_ledger, RemoteSessionBundle AES-GCM, EngramRemoteServer) but ships only FTS+summary artifacts, never raw transcripts.
- Live local DB path: ~/.engram/index.sqlite — READ-ONLY access only; the app may be running. To query safely: `cp -c ~/.engram/index.sqlite <scratch>/ro-index.sqlite` (APFS clone) and query the clone.

## 6. Further Detail (readable files)

- Round-1 research digest + judge verdicts (extracted): /Users/bing/.claude/projects/-Users-bing--Code--engram/8b2cb205-7d30-44a8-9ddd-f265da85d380/tool-results/bevz39vsb.txt
- Full round-1 workflow output JSON: /private/tmp/claude-501/-Users-bing--Code--engram/8b2cb205-7d30-44a8-9ddd-f265da85d380/tasks/wrhzfd292.output

## 7. Adjudication ground rules

- Simplicity-first: prefer the minimal sound design; call out when a "secure/robust" option is gold-plating for a single-user personal archive on a private tailnet.
- Every recommendation must state what the user still has to choose (if anything) — aim to shrink user decisions to genuine preference questions.
- Web research is allowed and encouraged for prior art (e.g., Tahoe-LAFS convergence secret, restic/borg key+repo models, backup tooling, vector stores); verify claims against primary sources.
