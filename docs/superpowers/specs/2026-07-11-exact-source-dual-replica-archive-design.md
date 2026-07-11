# Exact-Source Dual-Replica Archive Design

**Date:** 2026-07-11

**Baseline:** `main` at `95c73bf7`

**Deployment topology:** `macmini-hq` primary read target plus `macmini-m1` independent replica, in different physical locations with independent power and network exits

**Delivery mode:** local implementation and verification only; production installation, remote deployment, service restart, and source deletion require a later explicit operation

## Goal

Make Engram capable of preserving the exact source bytes behind supported AI sessions, replicating every committed archive generation to two independently operated Mac mini servers, and reconstructing a session when its live source is unavailable.

The first release is intentionally additive:

- no source-file deletion;
- no local archive eviction;
- no remote delete or garbage collection API;
- no public endpoint;
- no change to the existing `/v1/bundles` offload protocol;
- no claim that composite-directory or database-backed locators are archived until their adapter-specific canonical export exists.

Parsed messages, FTS rows, summaries, embeddings, tiers, and legacy offload bundles remain derived data. The exact captured bytes and their self-verifying manifest are the archive fact source.

## Accepted Decisions

1. Engram performs direct application-level replication to two independent servers. The servers do not replicate to each other.
2. `macmini-hq` is tried first for cold reads; `macmini-m1` is the fallback. Durability requires receipts from both.
3. Each server has a distinct bearer token, AES-at-rest key, archive root, and stable server identifier.
4. Both servers are reachable only over Tailscale. Tailnet membership does not replace bearer authorization.
5. The new protocol uses an isolated `/v2/archive` namespace with no DELETE route. Existing `/v1/bundles` behavior remains byte-for-byte compatible.
6. Local capture precedes parsing for supported regular-file locators. Parser failure does not discard a successfully captured generation.
7. Compression occurs after hashing the raw bytes and before encryption.
8. A remote object is durable only after immutable publication, file and parent-directory synchronization, read-back verification, and a server-issued receipt whose identity and contents the client independently verifies. A HEAD response alone is not a receipt.
9. The first release never treats an archive or receipt as authorization to unlink a live source.

## Non-Goals

- Replacing GRDB or the existing index database.
- Reintroducing a Node product runtime.
- Server-side semantic/vector search.
- Cross-server consensus, CRDTs, or multi-primary database replication.
- Cloud/VPS storage or third-party object storage.
- Automatic retention, source deletion, archive deletion, eviction, or GC.
- A public MCP or HTTP history API.
- Exact capture of virtual, composite, or database-backed locators without an adapter-specific canonical source exporter.
- Redesigning the existing legacy offload feature.

## System Boundary

```text
supported live source file
        |
        | pre-parse exact capture
        v
~/.engram/archive-v2/                  EngramService
  archive.sqlite  <--------------->   capture/bind/replicate/read coordinator
  objects/sha256/...                         |
  manifests/sha256/...                      | HTTPS over Tailscale
                                             +-----------------------+
                                             |                       |
                                             v                       v
                                      macmini-hq               macmini-m1
                                      /v2/archive              /v2/archive
                                      own token/key/root       own token/key/root

live reads: live file -> local archive -> hq -> m1 -> structured unavailable
```

The local archive and each remote server are independently self-verifying. `index.sqlite` is not the fact source and does not contain archive payload blobs.

## Exact Capture Contract

### Supported locator policy

The first release supports locators that resolve to one regular file without following a symbolic link. Capture eligibility is independent of session tier; `skip` sessions are not excluded merely because they are omitted from search.

Every enumerated locator is classified as one of:

- `regularFile`: eligible for exact capture;
- `missing`: transient retry state;
- `unsupportedComposite`: a directory or multi-file logical source;
- `unsupportedVirtual`: a locator containing adapter-specific selectors such as `::` or `?composer=`;
- `unsafe`: symlink, non-regular object, path outside the adapter's enumerated locator, or an identity race;
- `excluded`: local capture remains allowed, but remote replication is forbidden by project policy.

Unsupported and unsafe locators are recorded honestly and are never reported as remotely durable. This release does not guess that an opaque locator string is a file path.

### Generation identity

For a regular file, capture opens one descriptor using `O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, then records `fstat` before and after streaming. A generation is stable only when both observations match for:

- device;
- inode;
- byte size;
- modification time at nanosecond precision;
- change time at nanosecond precision;
- regular-file mode.

The generation also records SHA-256 of the complete raw byte sequence. A change during capture quarantines the attempt and schedules a retry; it cannot produce a verified manifest.

The future deletion design must re-open and re-check this complete generation tuple plus full hash immediately before unlink. No such deletion path exists in this release.

### Chunking and manifest

- Fixed raw chunk size: 8 MiB.
- Object identifier: lowercase hex SHA-256 of the raw chunk bytes.
- Whole-source identifier: lowercase hex SHA-256 of the exact source bytes.
- Empty files have zero chunks and the standard SHA-256 digest of empty bytes.
- Chunk order is manifest order; reconstruction concatenates chunks without text decoding.

The canonical manifest is UTF-8 JSON with sorted keys and no insignificant whitespace. Its identifier is SHA-256 of the exact canonical JSON bytes. Schema version 1 includes:

```text
schemaVersion
captureID
machineID
source
locator
sessionID?          # bound after normal indexing identifies the session
capturedAt
generation          # device/inode/size/mtimeNs/ctimeNs/mode
wholeSourceSHA256
rawByteCount
chunkSize
chunks[]             # ordinal, rawSHA256, rawByteCount
```

`machineID` is a persisted random UUID, not a hostname. `captureID` is derived from machine ID, source, normalized locator, generation tuple, and whole-source digest. Binding a session produces a new canonical manifest that references the same immutable objects; the unbound capture remains auditable.

### Local storage

```text
~/.engram/archive-v2/
  archive.sqlite
  objects/sha256/<first-two>/<digest>
  manifests/sha256/<first-two>/<digest>.json
  tmp/
```

Raw chunks are stored in immutable, hash-addressed files. Local publication uses a same-filesystem temporary file, full-write loops, `fsync`, exclusive final publication, and parent-directory `fsync`. Existing objects are read back and re-hashed before being accepted as deduplicated content. Symlinks and overwrites are rejected.

Local archive files are owner-only. `archive.sqlite` uses a separate idempotent GRDB migration runner and `synchronous=FULL`. It is a rebuildable catalog, not the byte authority. The minimum tables are:

- `archive_captures`: source/locator/generation, manifest hashes, status, diagnostics, timestamps;
- `archive_session_bindings`: session ID to capture/manifest, source snapshot fingerprint, bound timestamp;
- `archive_replica_receipts`: capture/manifest plus replica ID, retry state, receipt bytes/digest, verified timestamp;
- `archive_metadata`: schema and persisted machine ID.

No archive payload table is added to `index.sqlite`.

### Indexing integration

EngramService runs exact-source capture as a distinct pre-index phase, outside the `ServiceWriterGate` that owns `index.sqlite` writes:

1. Enumerate current locators from the registered Swift adapters.
2. Classify and capture stable regular-file generations into the local archive.
3. Run the existing Swift indexer unchanged through `ServiceWriterGate`.
4. Reconcile unbound captures to indexed sessions by exact `(source, locator)` match.
5. Create bound canonical manifests.
6. Queue eligible bound manifests for both replicas.

This deliberately permits a captured but unbound generation when parsing fails. It also lets a previously unchanged/index-skipped locator receive its first exact archive capture. Archive capture failures do not make the existing index scan unusable; they are surfaced independently in archive status.

## Remote Archive Protocol

### Server configuration

The existing native `EngramRemoteServer` gains an opt-in v2 store. Legacy v1 configuration remains valid when v2 is disabled.

Required when v2 is enabled:

- `ENGRAM_REMOTE_ARCHIVE_ENABLED=1`
- `ENGRAM_REMOTE_ARCHIVE_SERVER_ID=<stable-id>`
- `ENGRAM_REMOTE_ARCHIVE_ROOT=<absolute-path>`
- existing bearer token mechanism, with a token distinct per server
- existing at-rest AES key mechanism, with a key distinct per server

Recommended deployment IDs are `hq` and `m1`. The server binds only to a Tailscale-reachable interface or loopback behind Tailscale Serve; public binding is outside the supported runbook.

### Object API

```text
PUT  /v2/archive/objects/:sha256
HEAD /v2/archive/objects/:sha256
GET  /v2/archive/objects/:sha256
```

- PUT body is the raw chunk bytes.
- The server recomputes SHA-256 and returns `422` on path/body mismatch.
- Maximum raw body is exactly 8 MiB; 8 MiB + 1 returns `413`.
- Successful first publication returns `201`; an already present, fully reverified identical object returns `200`.
- HEAD/GET verify the stored envelope before claiming presence or returning plaintext.
- No object DELETE route exists; DELETE under `/v2/archive/*` returns `405`.

### Manifest API

```text
PUT  /v2/archive/manifests/:sha256
HEAD /v2/archive/manifests/:sha256
GET  /v2/archive/manifests/:sha256
```

The body is the exact canonical manifest bytes. The server verifies:

1. body digest equals the path digest;
2. strict schema/version and size limits;
3. every referenced object exists;
4. every object decrypts, decompresses, matches its raw length and digest;
5. chunk order, count, aggregate bytes, and whole-source digest are coherent.

Missing references return `409`; invalid digest/schema/content returns `422`. A manifest is published only after all checks pass.

### Receipt and recovery API

```text
PUT /v2/archive/receipts/:manifest-sha256
GET /v2/archive/receipts/:manifest-sha256
GET /v2/archive/receipts?machine_id=<uuid>&cursor=<opaque>&limit=<bounded>
```

Receipt creation is idempotent. The server emits a canonical receipt only after the bound manifest and every referenced object are durably published and reverified. It includes:

```text
schemaVersion
serverID
machineID
sessionID
captureID
manifestSHA256
wholeSourceSHA256
objectCount
rawByteCount
storedAt
```

The receipt identifier is the SHA-256 of its canonical bytes. The client stores the exact receipt bytes and digest. Listing receipts by machine ID provides clean-machine discovery without trusting a mutable catalog copied from the client.

### Immutable encrypted storage

Each remote envelope applies:

```text
raw bytes -> raw SHA-256 -> LZFSE compression when smaller -> AES-GCM encryption
```

Authenticated additional data binds protocol version, object kind, digest, codec, and raw length. Publication uses an owner-only temporary file, a full short-write loop, file `fsync`, exclusive no-overwrite final publication, and directory `fsync`. If the final name exists, the server opens without following symlinks and fully verifies it; it never repairs corruption by overwriting the named object.

The remote layout is sharded by digest and keeps objects, manifests, and receipts in separate namespaces. Temporary cleanup is allowed; final-object deletion and GC are absent.

### HTTP status contract

- `200`: verified existing object or successful read/idempotent receipt;
- `201`: newly durably published object/manifest/receipt;
- `400`: malformed request/path/query;
- `401`: missing or invalid bearer token;
- `404`: absent object/manifest/receipt;
- `405`: forbidden method, including every v2 DELETE;
- `409`: missing references or existing named content that fails verification;
- `413`: request exceeds its bound;
- `415`: unsupported content type where applicable;
- `422`: hash, canonical encoding, schema, or coherence failure;
- `500`/`503`: local storage or transient service failure.

Error bodies are bounded structured JSON and never include keys, plaintext payloads, or absolute storage paths.

## Dual-Replica Client

### Configuration and credentials

Archive v2 is default-off and separate from legacy offload settings. Enabling it requires exactly two replicas with distinct IDs and normalized URLs:

```json
{
  "exactArchiveEnabled": true,
  "remoteArchiveV2": {
    "enabled": true,
    "batchSize": 20,
    "replicas": [
      {"id": "hq", "serverURL": "http://<hq-tailnet-ip>:8787", "requireTLS": false},
      {"id": "m1", "serverURL": "http://<m1-tailnet-ip>:8787", "requireTLS": false}
    ],
    "excludedProjectRoots": []
  }
}
```

Plain HTTP is accepted only for Tailscale IPs/hostnames or loopback. Other non-TLS URLs fail closed. Bearer tokens live in Keychain service `com.engram.remote-archive-v2` under accounts `replica:hq` and `replica:m1`. Server AES keys never leave their servers.

### Replication state machine

The new `ArchiveReplicaBackend` exposes only object, manifest, receipt, and receipt-list operations. It has no delete, catalog mutation, offload, rehydrate, or vacuum method.

For each bound, policy-eligible capture and each replica:

```text
pending -> uploadingObjects -> uploadingManifest -> requestingReceipt
        -> verifyingReceipt -> verified
        -> retryWait | quarantined
```

- States are persisted independently by `(captureID, replicaID)`.
- A failure on one replica never re-uploads a verified replica.
- Retry is exponential with jitter and a 24-hour cap.
- Cancellation does not increment attempts.
- Work left in an in-flight state for more than ten minutes is recovered to retry.
- Hash/schema/protocol contradictions quarantine that replica entry; network and 5xx failures retry.
- Dual durability is a derived condition requiring two currently configured, distinct replica IDs with verified receipts for the same bound manifest digest.
- Replication never changes `sessions.offload_state`, FTS rows, summaries, local CAS, legacy queue rows, or database vacuum state.

Legacy v1 offload and v2 archive may coexist because their storage, protocol, credentials, tables, and coordinators are disjoint. Tests must prove v2 activity cannot invoke legacy purge/delete paths.

### Remote policy

Remote replication is fail-closed when project root is absent or ambiguous. Configured absolute project-root exclusions prevent remote upload while retaining local capture. This is an ingestion policy, because an immutable remote archive cannot promise retroactive erasure.

## Read and Recovery Behavior

The service owns Keychain and network access. MCP does not receive remote credentials.

For transcript reads and exports:

1. Use the current live source when it exists.
2. Only for missing/unavailable source, resolve the latest verified local bound manifest.
3. If local objects are missing/corrupt, try `hq` using its verified receipt.
4. On absence, transport failure, or integrity failure, try `m1`.
5. Reconstruct to an owner-only temporary file, verify every chunk plus whole-source digest, and invoke the existing source adapter/parser.
6. Return a structured unavailable/corrupt error if no source passes verification.

An existing live source that fails parsing does not silently fall back to an older archived generation. This prevents stale history from masking a current parser regression.

Service export and MCP `get_session` share this resolution policy. MCP keeps its fast direct local-file path and calls the service only for the archive fallback, so the normal local contract and pagination remain unchanged.

Raw archive bytes never bypass existing output redaction/role/pagination policy. Exactness is a storage property, not automatic plaintext egress authorization.

Clean-machine recovery is proven by an integration test that starts with no local catalog, lists receipts by machine ID from one replica, downloads and verifies a manifest and its objects, and reconstructs byte-identical source data. A user-facing restore CLI is deferred.

## Service and IPC Surface

Add read-only archive status that reports:

- capture counts by state;
- unsupported/unsafe locator counts;
- queued/retrying/quarantined counts per replica;
- verified single-replica and dual-replica counts;
- latest successful receipt per replica;
- last capture/replication error, bounded and redacted.

Add a manual retry command protected by the existing service writer/command boundary. Do not add delete, evict, GC, or source-reclaim commands.

Normal indexing and the app remain usable when either or both servers are offline. Remote replication is bounded background maintenance and cannot make service readiness depend on remote health.

## Privacy and Operational Contract

Documentation must clearly distinguish:

- legacy v1 offload: regenerable FTS/summary artifacts only;
- exact archive v2: explicit opt-in transfer of raw source bytes to two user-operated Tailscale-only servers.

At-rest encryption protects powered-off disks and copied archive files. It does not protect plaintext from a compromised server while that server is running with its key available. Bearer tokens limit API access but do not make a compromised tailnet device trusted.

The runbook must generate separate tokens and keys, use owner-only LaunchAgent environment files, prohibit public/Funnel exposure, and document verification without performing deployment in this branch.

## Failure Invariants

1. No archive failure deletes or mutates a live source.
2. No v2 endpoint overwrites or deletes a final object.
3. A path digest is never trusted without recomputing the body digest.
4. A receipt cannot exist before every referenced object and the manifest are verified durable on that server.
5. One server's receipt cannot satisfy the other replica's state.
6. A missing server never blocks local indexing or reads of live/local data.
7. An unsupported locator is never counted as captured or durable.
8. Legacy v1 offload state is never used as archive durability evidence.
9. Local and remote reconstruction must be byte-identical, including invalid UTF-8, CRLF, BOMs, embedded NULs, base64 payloads, and truncated trailing records.
10. There is no code path in this release that unlinks a source or deletes a final archive object.

## Test Strategy

### Local capture

- byte-identical round trips for binary/text edge cases;
- deduplication and zero-byte input;
- symlink/non-regular/virtual/composite rejection;
- append, replacement, or metadata change during capture never verifies;
- first archive backfill still runs when indexing would skip unchanged content;
- parser failure retains an unbound capture;
- archive catalog migrations are repeatable and independent of `index.sqlite`;
- source files are never modified or deleted.

### Server v2

- exact 8 MiB body accepted and 8 MiB + 1 rejected;
- path/body mismatch rejected;
- repeat identical PUT succeeds without changing the stored file;
- corrupt existing object returns conflict and is not overwritten;
- symlink final path rejected;
- short-write/fsync/publish failure never creates a receipt;
- manifest rejects missing/corrupt references and incoherent aggregate hash;
- DELETE always returns `405` while legacy v1 DELETE retains its current behavior;
- authentication and error-body redaction;
- restart reads previously written objects with the same key and rejects the wrong key.

### Dual replication and recovery

- hq success plus m1 failure remains single-replica and retries only m1;
- distinct verified receipts are required for dual durability;
- forged/wrong-server/wrong-manifest receipts are rejected;
- stale in-flight recovery and retry classification;
- remote work never changes v1 offload/FTS state;
- reads prefer live, then local archive, then hq, then m1;
- clean-machine receipt discovery and byte-identical restore;
- both servers unavailable leaves normal local behavior intact.

## Delivery Sequence

1. Shared canonical models, local immutable CAS, and separate archive catalog.
2. Pre-index regular-file capture and post-index session binding.
3. Immutable single-server `/v2/archive` store and routes, preserving v1.
4. Separate archive HTTP client, Keychain/config contract, and dual-replica coordinator.
5. Service scheduling, status/retry IPC, and offline behavior.
6. Local/remote transcript fallback and clean-machine recovery integration test.
7. Privacy, runbook, CI/test-matrix updates, and final full verification.

Each step is test-first, independently committed, and reviewed before the next step. Production deployment is not part of this implementation branch.

## Final Verification Gate

The implementation is ready for deployment planning only when:

1. focused RED/GREEN evidence exists for every new behavior;
2. all Swift schemes affected by archive changes pass;
3. `xcodegen generate` produces no uncommitted project drift when target membership changes;
4. a two-server local integration harness proves independent receipts and hq-to-m1 fallback;
5. a clean-machine reconstruction test proves exact bytes without local catalog state;
6. static search proves no v2 DELETE/source-unlink/GC path exists;
7. legacy `/v1/bundles` tests remain green;
8. `git diff --check` passes and unrelated user changes are absent.
