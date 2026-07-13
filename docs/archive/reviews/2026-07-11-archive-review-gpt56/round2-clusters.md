# Round-2 Cluster Designs + Red-team Reviews (Engram remote archive)


---

## Cluster: crypto-privacy

## Crypto & Privacy Chain — Recommended Design

### One master secret, restic/borg custody (G1)

The whole chain hangs off ONE 256-bit `master_data_key` generated on the Mac (`SecRandomCopyBytes`). Two sub-keys via HKDF: `id_key` (the per-user convergence secret / chunk-HMAC key) and `enc_key` (AES-256-GCM). This is Borg's exact structure — one keyfile yielding `id_key` + `enc_key`.

Custody follows **restic's wrapped-key model**, which decouples cheap credential rotation from expensive data rotation:
- `recovery_phrase` = 24-word mnemonic shown once at enable → KEK via scrypt. User records it **out-of-band** (password manager / paper). This is the only secret that survives total-Mac-loss.
- `master_data_key` (random) is **wrapped** by the KEK. The wrapped blob lives (a) in macOS Keychain (`com.engram.archive-master`, ThisDeviceOnly/WhenUnlocked — same pattern as the shipped bearer token) for fast unlock, and (b) replicated with the archive to server + every backup (safe: ciphertext under the phrase — this is borg `repokey` / a restic key file).

**Recovery after total Mac loss:** reinstall → fetch wrapped blob from any server/backup copy → enter recovery phrase → unwrap → repopulate Keychain → server ciphertext readable again. Two independent factors (a backup copy of the wrapped blob + the memorized/manager-held phrase); neither alone suffices; neither is "escrow encrypted to the same key" — the phrase is never stored under the data key.

**Rotation:** changing the phrase re-wraps only (cheap, restic model). Rotating `master_data_key` re-derives every id + ciphertext ⇒ full local re-encrypt + re-upload; do it only on suspected compromise, never on a schedule. The transport bearer token rotates freely and independently.

**Multi-machine distribution:** your existing password manager (iCloud Keychain / 1Password) already syncs the recovery phrase to your other tailnet machines — that IS the distribution channel. Each machine unwraps the same key. Reject building a custom key-exchange protocol.

### Encryption scheme — tiered by where the server lives (G4)

Threat table (✗ = reads plaintext, ~ = metadata only, ✓ = ciphertext/safe):

| Attacker | (a) keyed-convergent, client key | (b) per-chunk random key | (c) server-FDE + Tailscale, no client enc |
|---|---|---|---|
| Server box compromise (root, running) | ~ HMAC ids + ciphertext; **cannot confirm files** (keyed) | ~ ciphertext, no dedup-equality | ✗ full plaintext |
| Tailnet device compromise (non-key-holder) | ~ | ~ | ✗ (reads authorized bodies) |
| Backup-store compromise | ✓ | ✓ | ✗ unless backup separately encrypted |
| Stolen/lost Mac (FileVault, off) | ✓ | ✓ | ✓ |
| Physical server theft (off) | ✓ | ✓ | ✓ (FDE) |

Keyed HMAC (Borg's `id_key`) + a per-user convergence secret (Tahoe's `private/convergence`) **defeat the confirmation-of-a-file / dictionary attack** that plagues plain convergent encryption, because the server lacks the secret. Dedup only needs to work WITHIN one corpus, so the per-user secret costs nothing. (b)'s sole gain over (a) is hiding dedup-equality; it **breaks content-addressed integrity** (server can't verify blob==id without the key) and adds per-chunk wrapped keys plus a client-side id-map you must also back up — reject as gold-plating.

**Recommendation:** default to **(c)** — server full-disk encryption + Tailscale-only + separately-encrypted backups — WHEN the server and backup media are hardware you physically control. For a solo user's home mini on a tailnet with no public ports, live-server-root-compromise is low-probability and (c) removes all key-management burden. The shipped `ENGRAM_REMOTE_AT_REST_KEY` (server-held AES-GCM) already implements this. **Upgrade to (a)** — Borg-model keyed-convergent, client-held key — the instant any byte touches hardware you don't physically control: a rented VPS, or cloud backup (B2/S3). This selection is downstream of Cluster D's server-location decision (D1).

### Redaction ordering — verbatim CAS + egress-time redaction (G3, D4)

Redaction sits at **egress, never at ingestion**. Ingestion = chunk → `HMAC(id_key, plaintext)` → encrypt → store, verbatim. Hash stays stable (dedup intact), CAS stays content-addressed, `recover_compaction` stays byte-exact. Secrets-at-rest are neutralized by **encryption, not scrubbing** — the server holds only ciphertext.

Redaction is a filter on **decrypted bodies at the read resolver / MCP egress**: fetch chunk → decrypt → verify hash → redact → return. `recover_compaction` / `get_session` with `verbatim:true` bypass the filter (your data, your machine — the point is exact evicted bytes). This satisfies the release gate ("redaction capability before durable store") with zero verbatim contradiction. Reject redact-before-hash (kills verbatim + dedup) and dual-store (two keys/stores = gold-plating).

**Depth (D4):** strip only high-precision structured secrets — API keys/tokens (AWS `AKIA`, GitHub `ghp_`, OpenAI `sk-`), PEM private-key blocks, JWTs, connection strings — via an existing gitleaks/trufflehog regex ruleset plus a high-entropy-token check. **No ML, no broad PII** (names/emails): on code transcripts false positives are catastrophic — redacting a `password` variable destroys the archive's core value. Reversible for the owner by construction (verbatim ciphertext retained). Default-on for cross-machine/MCP egress; off for local verbatim recovery.

### Exposure (D3) and governance (D5)

**D3:** confirm **Tailscale-Serve-only, no Funnel.** Every device you own is on the tailnet; a non-tailnet device should install Tailscale, not trigger public exposure. Funnel is acceptable *effectively never* here (would demand mTLS + bearer + rate-limit for zero real need). Bonus simplification: Tailscale Serve terminates TLS with automatic certs — it can retire the nginx + private-CA + `add-trusted-cert` dance in the current runbook.

**D5:** default posture = **archive everything** (a complete personal record is the point), with per-project **exclusion** evaluated at the **ingestion/capture stage** — excluded projects never become durable (stay disk-only). Rule lives in `~/.engram/settings.json` as an `archiveExclude` list of project-ids / path-globs (sessions already carry cwd/project), not per-source (too coarse) nor per-session (unmanageable). Exclusion (whether to archive) composes with redaction (what to show): coarse gate at ingest, fine filter at egress.

### Decisions


**G1** [high] One 256-bit master_data_key on the Mac (HKDF → id_key + enc_key, Borg structure). Custody = restic wrapped-key model: a random data key wrapped by a KEK derived (scrypt) from a 24-word recovery phrase; wrapped blob in macOS Keychain (ThisDeviceOnly) for unlock AND replicated to server/backups for recovery. Total-Mac-loss recovery = fetch wrapped blob + type the phrase. Phrase rotation re-wraps only; data-key rotation forces full re-upload (compromise-only). Multi-machine distribution rides your existing password manager syncing the phrase.
- rationale: Fills the critique's single largest hole. The wrapped-key split is exactly how restic supports cheap password change without re-encrypting data, and borg repokey/keyfile store the key blob with/beside the repo; recovery needs two independent factors, neither being escrow-under-the-same-key. Keychain matches the shipped bearer-token pattern. Password-manager-as-distribution avoids inventing a key-exchange protocol for a solo user.
- user choice remaining: Which out-of-band store for the recovery phrase (paper in a safe vs 1Password/iCloud Keychain) — a genuine preference. Also whether client-held keys are enabled at all depends on the G4/D1 deployment choice.

**G3** [high] No-redaction-at-rest + retrieval-time redaction. Ingestion stores verbatim, keyed-HMAC-addressed, encrypted chunks (stable hash, dedup intact, recover_compaction byte-exact). Redaction is an egress filter applied to decrypted bodies at the read resolver / MCP boundary; verbatim:true bypasses it for local recovery. Secrets-at-rest are handled by whole-corpus encryption, not scrubbing.
- rationale: Resolves the three-way contradiction: redacting before hashing would break both the CAS/dedup and the verbatim promise, and dual-store (separate verbatim envelope) is two keys/stores of gold-plating for one user. Encryption already removes plaintext secrets from the server, so redaction's real job is display/egress hygiene, which belongs at egress. Satisfies the release gate that a redaction capability exist before the durable store ships.
- user choice remaining: Whether verbatim (unredacted) recover_compaction defaults on or off when the caller is a remote/other-machine MCP client vs the local app.

**G4** [high] Tiered. Default to (c): server full-disk encryption + Tailscale-only + separately-encrypted backups, when the server and backup media are hardware you physically control (home mini) — this is already shipped via server-held AES-GCM and needs no client key management. Upgrade to (a): Borg-model keyed-convergent client-held encryption (HMAC(id_key,plaintext) chunk id + AES-GCM under enc_key) the moment any byte lands on hardware you do not physically control (rented VPS or cloud backup). Reject (b) per-chunk random keys.
- rationale: The confirmation/dictionary attack only bites when dedup crosses users; single-corpus dedup plus a keyed HMAC (borg id_key) / per-user convergence secret (Tahoe) makes the server unable to confirm guessed plaintext, so (a) is the correct client-side scheme when needed. But (c)'s only exposure over (a) is a live-root-compromise of a box you physically own with no public ports — low probability — so paying full key-management cost there is gold-plating. (b) breaks content-addressed integrity and adds a client id-map to back up for only marginal metadata privacy.
- user choice remaining: The deployment decision that selects the tier: home box you own (→ c) vs rented VPS, and local-drive backup vs cloud object store (either untrusted target → a). This is the one real choice and it belongs to Cluster D (D1).

**D3** [high] Tailscale Serve only; no Funnel, no public endpoint. Additionally adopt Tailscale Serve's built-in automatic TLS to retire the nginx + private-CA + add-trusted-cert steps in the current runbook.
- rationale: All the user's devices are on the tailnet (WireGuard, device-authenticated); a device that needs access should join the tailnet rather than justify public exposure. Funnel would require mTLS+bearer+rate-limit to be safe and serves no real need for a single-user personal archive. Serve's managed certs are strictly simpler than the private-CA dance.
- user choice remaining: Whether to migrate off the existing nginx+private-CA TLS termination to Tailscale Serve's managed certs now or defer it as a cleanup.

**D4** [high] Strip only high-precision structured secrets: API keys/tokens (AWS AKIA, GitHub ghp_, OpenAI sk-), PEM private-key blocks, JWTs, connection strings — via an existing gitleaks/trufflehog regex ruleset plus a high-entropy-token check. No ML classifier; no broad PII (names/emails). Reversible for the owner (verbatim ciphertext retained); default-on for cross-machine/MCP egress, off for local verbatim recovery.
- rationale: On code transcripts, false positives are catastrophic — redacting a variable literally named password or a config value guts the archive's differentiating value (recovering what you were working on). High-precision regex+entropy detectors from mature secret scanners minimize false positives; ML is overkill and less predictable. Reversibility is free because the verbatim encrypted bytes remain.
- user choice remaining: Whether to add any narrow PII patterns (e.g., your own email) to the default high-precision ruleset, accepting the false-positive risk that entails.

**D5** [high] Default: archive everything. Provide per-project exclusion evaluated at the ingestion/capture stage (excluded projects never become durable; they stay disk-only). Store the rule in ~/.engram/settings.json as an archiveExclude list of project-ids / path-globs — not per-source (too coarse), not per-session (unmanageable). Exclusion (whether to archive) composes with egress redaction (what to show).
- rationale: A complete personal record is the product's point, so include-all is the right default with a cheap escape hatch. Project/path granularity matches how sessions already carry cwd/project and how a user thinks about NDA/work boundaries. Enforcing at ingest guarantees excluded NDA content never enters the durable, replicated, backed-up store — the strongest and simplest guarantee.
- user choice remaining: Which specific projects/paths (if any) to place on the NDA/work exclusion list — pure user content policy.


### Evidence

- Borg internals (primary): chunk id = id_hash(unencrypted_data) is a keyed HMAC using id_key stored in the keyfile, plus a per-repo chunk_seed, explicitly 'to prevent chunk size based fingerprinting attacks on your encrypted repo contents' — https://borgbackup.readthedocs.io/en/stable/internals/data-structures.html
- restic references (primary): a master encryption+MAC key is stored in the repo encrypted by scrypt-derived password keys; 'A repository can have several different passwords, with a key file for each … the password can be changed without having to re-encrypt all data' — the wrapped-key model — https://restic.readthedocs.io/en/stable/100_references.html
- Tahoe-LAFS convergence secret (primary): file identity derived from 'the content of the file and the upload client's convergence secret,' stored at <nodedir>/private/convergence; 'only someone who knows the convergence secret … can perform these attacks'; if lost, old caps still work but new uploads stop deduping — https://tahoe-lafs.readthedocs.io/en/latest/convergence-secret.html
- Convergent encryption confirmation-of-a-file / low-entropy dictionary attack, and the K=KDF(Hash(plaintext), user_secret) mitigation that trades cross-user dedup for confidentiality — https://en.wikipedia.org/wiki/Convergent_encryption and https://smarx.com/posts/2020/09/convergent-encryption-and-why-no-one-uses-it/
- Existing shipped scaffolding = option (c): docs/remote-offload.md — EngramRemoteServer stores AES-GCM at-rest under a server-held ENGRAM_REMOTE_AT_REST_KEY, bearer token in macOS Keychain (com.engram.remote-offload), Tailscale-IP transport over utun; rotating the at-rest key makes existing bundles undecryptable (confirms full-re-encrypt-on-rotation cost).
- Round-2 empirical ground truth: corpus ~15 GB across .claude/.codex/.gemini; Codex has ~1.6 GB of base64/binary outliers (gzip only 1.33x) → convergent dedup + externalization matter; index.sqlite has NO message-body table (get_session re-reads disk), so the durable body store is genuinely new surface the key scheme must protect.
- Task-stated invariant used as a design axiom: dedup only needs to work WITHIN one user corpus and 'escrow encrypted to the same key is useless' — drives the per-user-secret keyed-convergent choice (a) and the out-of-band recovery-phrase custody in G1.


### Reviews


#### [needs-fixes] lens: Simplicity/practicality vs. baseline (server FDE + Tailscale + no client crypto) for a single user on a private tailnet
- (major) G1's entire master-key custody chain (24-word mnemonic → scrypt KEK → wrap/unwrap, dual Keychain+server+backup replication of the wrapped blob) is specified and presumably built as committed v1 design, but the design's own dependency section admits it is only needed if D1 selects untrusted hardware (rented VPS / cloud backup) — a decision explicitly left as an open user choice. G4 itself recommends tier (c), no client-side crypto, for the actual current deployment (home mini, owned backup). This is exactly the 'configurability nobody asked for' / speculative-feature pattern the project's own working agreement forbids: real, security-critical, hard-to-audit machinery being built ahead of a need that may never materialize. → FIX: Descope G1 to a stub for v1: ship tier (c) only (already shipped per the design's own evidence — ENGRAM_REMOTE_AT_REST_KEY). Do not implement the mnemonic/scrypt/wrap/Keychain-custody pipeline until D1 actually selects a rented VPS or cloud backup target. Document the HKDF id_key/enc_key split and keyed-HMAC scheme as a design note for that future trigger, not as code to write now.
- (major) Even conditional on G1 eventually being needed, the recovery-phrase/scrypt/KEK-wrap layer is solving a problem (human-writable, offline, memorable paper backup) that the design's own chosen distribution channel doesn't need: the doc states the password manager (iCloud Keychain/1Password) syncing the phrase to other machines 'IS the distribution channel.' If the phrase is never handwritten/memorized and always lives in a password manager, the BIP39-mnemonic + scrypt-derivation ceremony adds a full extra crypto layer (KEK derivation, wrap, unwrap, phrase-entry UX, phrase-display-once UX) for zero benefit over simply storing the raw 256-bit master key as an opaque secret in the same password manager. → FIX: If/when G1 is built, drop the mnemonic + scrypt + wrap layer entirely: generate the 256-bit master_data_key, store it directly as a password-manager secret/note plus a macOS Keychain copy (ThisDeviceOnly). Keep HKDF only for deriving id_key/enc_key from that raw key — that part is genuinely load-bearing for the keyed-convergent dedup scheme. This removes an entire subsystem (KEK derivation, wrap/unwrap, recovery-phrase generation and display flow) without losing any real capability for a solo user.
- (major) The design hand-rolls AES-256-GCM + HKDF + keyed-HMAC content-addressing + wrapped-key custody from scratch, explicitly modeling it on restic/borg, but never considers using restic (or age/rclone-crypt) itself as the sync/encryption backend for the untrusted-hardware tier. That is a large amount of new security-critical, unaudited code for a single-user personal tool, when mature, audited implementations of the exact same design already exist and are the design's own cited references. → FIX: Before writing any custom crypto for tier (a), spike shelling out to restic against an export of Engram's local CAS blob store as the sync mechanism to the untrusted target. Only fall back to hand-rolled HKDF/AES-GCM/keyed-HMAC if a concrete incompatibility (e.g., Engram's existing chunking/dedup model can't be reconciled with restic's) is demonstrated, and record that spike result in alternatives_rejected.
- (minor) The 'two independent factors' recovery claim is weaker than stated: the wrapped-key blob is deliberately replicated to the server and every backup (maximally available by design), so the practical secret boundary reduces almost entirely to 'whoever holds the phrase' — the same effective strength as just directly custodying the raw key in the password manager. The doc presents this as meaningfully stronger than single-secret custody, which isn't really true once the wrapped blob is everywhere. → FIX: Rephrase the recovery-model claim to be accurate: it's really single-factor (the phrase, held by the password manager) with a widely-replicated non-secret ciphertext blob, not two independent factors in the traditional sense. This also supports issue #2's fix — since the blob offers negligible confidentiality benefit, there is little reason to introduce it via scrypt/wrap rather than just distributing the raw key.
- (minor) The threat table's 'Tailnet device compromise (non-key-holder)' row is presented as a real distinct attacker class, but for a genuine single-user setup where all owned tailnet devices already share the same password-manager-synced key, this scenario is nearly vacuous (it only applies to a device that's on the tailnet but not logged into the user's password manager, e.g. a borrowed/shared machine) — the row implies more residual risk coverage than actually exists for the stated deployment. → FIX: Annotate the row to clarify it only applies to non-owned or not-yet-onboarded tailnet devices, so readers don't overweight it as a reason to build client-side crypto now.
- (overengineering) G1's full wrapped-key custody ceremony (mnemonic + scrypt KEK + wrap/unwrap + multi-location replication) built ahead of the D1 decision that would actually require it
- (overengineering) Mnemonic/scrypt layer duplicating what the chosen distribution channel (password manager) already provides for free by just storing the raw key
- (overengineering) Hand-rolled AES-GCM + HKDF + keyed-HMAC content-addressing implementation instead of evaluating restic/age as an off-the-shelf backend for the one case (untrusted hardware) where client crypto is actually justified
- (overengineering) Building tier (a) capability into the v1 design surface at all when the deployment choice that selects it is explicitly still an open user decision

---

## Cluster: durability

## Cluster B — Durability chain (G2, G5, N3, N4, N6)

### Core insight that shrinks the whole problem
Chunks are content-addressed: **the primary key IS the SHA-256 of the plaintext**. Integrity verification is therefore free everywhere — decompress a chunk, hash it, compare to its PK. This one fact removes the need for cksumvfs *and* makes the delete-gate a real recompute rather than a trusted flag. The blob store is an **immutable, append-only** set of content-addressed objects, which is the easiest thing in the world to back up.

### G2 — Server CAS blob-store backup

Recommendation: **`rclone sync` of the blob directory to a versioned / Object-Lock bucket** (Backblaze B2 via its S3-compatible endpoint), on the **same bucket/account** that already receives the Litestream metadata WAL. One backup story, one credential.

Why rclone over the alternatives: the blobs are immutable content-addressed files, so each maps 1:1 to an immutable object. rclone only ever *adds* objects (never rewrites — it compares by size), and B2 versioning + Object Lock makes them WORM, which is the entire durability requirement. restic/borg would layer a *second* dedup+pack+encryption format on top of chunks that are already deduped and convergent-encrypted — pure gold-plating. ZFS snapshots protect only the local server disk unless you also `zfs send` offsite, so they're a complement, not the offsite copy. A "second Mac/device copy" is more babysitting than a versioned bucket.

Config sketch (server, launchd/systemd timer, nightly):
```
# blobs are /var/engram/blobs/<aa>/<sha256>  (immutable, add-only)
rclone sync /var/engram/blobs b2:engram-archive/blobs \
  --immutable --b2-versions --transfers 8 --fast-list
# metadata already covered:
litestream replicate /var/engram/meta.sqlite b2:engram-archive/meta
```
Bucket lifecycle: keep all versions; Object Lock (compliance/governance) with a retention ≥ the CAS GC window so a bug can't erase history. Integrity of the backup itself: monthly `restore-drill` (below) — cheaper and more meaningful than `restic check --read-data` because it verifies *reassembly*, not just pack checksums.

### N4 — RPO / RTO + rehearsed restore drill

- **Metadata RPO ≤ 1 s** — Litestream's default sync-interval is 1 second (continuous WAL). [litestream.io/how-it-works]
- **Blob-backup RPO ≤ 24 h** (nightly rclone) — but **irreplaceable-data RPO = 0**, because the delete-gate (G5) forbids deleting an original until its chunks are in a completed backup. Anything inside the 24 h gap still exists as the original JSONL on the Mac. The gap costs re-upload work, never data.
- **RTO: degraded = 0** (Mac keeps hot window + metadata/FTS/summary locally and works offline; only *cold* bodies are unreachable). **Full server rebuild ≤ 2 h**, dominated by re-downloading a few GB of blobs over home internet.

Scripted + rehearsed drill — `restore-drill.sh`, run **monthly** by the server's timer, result pushed to the app via the `backup.status` capability so the menu bar shows "last drill: PASS 2026-07-01":
```
1. mkdir scratch/  (or ephemeral container)
2. litestream restore -o scratch/meta.sqlite  b2:.../meta
3. rclone sync b2:.../blobs scratch/blobs
4. VERIFY: sample N random session_archive rows → reassemble from
   scratch/blobs → recompute content_hash → assert == stored hash
5. REFERENTIAL: assert every chunk-hash in every sampled manifest
   exists in scratch/blobs  (zero dangling references)
6. print PASS/FAIL + counts; nonzero exit on any mismatch
```
Proof of success = step 4 hash equality + step 5 zero-dangling. A drill that only restores files without reassembling is not a drill.

### G5 — Local integrity + the exact delete-gate predicate

**cksumvfs: rejected.** It requires exactly 8 reserved bytes per page set at DB creation, is incompatible with any other reserve-byte user, and can't be applied to the live 741 MB DB without a full rebuild. [sqlite.org/cksumvfs.html] It would only protect *regenerable* metadata tables anyway. Instead: chunks self-verify via their CAS key (free); structural DB health via periodic `PRAGMA integrity_check`; the DB file itself is covered by Time Machine.

**Torn writes:** SQLite WAL + `synchronous=NORMAL` gives page-atomic commits (no torn pages). Torn blob writes during upload are caught by server content-hash re-verification. Silent bit-rot in a stored chunk is caught by the scrub.

**Scrub job** (weekly, via `IndexingBackgroundActivityScheduler`, throttled): iterate `archive_chunks`, decompress, recompute SHA-256, compare to PK. SHA-256 on Apple Silicon runs at ~1–2 GB/s, so a full ~6 GB scrub is seconds of CPU — hash-on-read is negligible, and we can verify at every gate. On mismatch: quarantine the chunk; self-heal by re-fetching from server (if `verified_remote`) or re-deriving from the original if still present; alert if neither.

**Delete-gate predicate** — an original file `O` for session `S` may be deleted **iff ALL hold, re-checked at gate time (no trusting stored flags):**
1. **Captured & complete:** `session_archive(S)` exists, `chunk_manifest` fully populated.
2. **Local recompute:** every chunk in `S`'s manifest read from `archive_chunks`, decompressed, SHA-256(plaintext) == its PK; reassembled transcript's `content_hash` == `session_archive.content_hash`.
3. **Structural health:** most recent `PRAGMA integrity_check` = ok and last scrub passed.
4. **Remote durable (if server configured):** `sync_ledger[S].remote_content_hash == local content_hash` AND server returned a verified ack AND `chunk.backed_up_at ≥ chunk.uploaded_at` for **every** chunk (present in a *completed* rclone/Litestream backup).
5. **Never-last-copy:** count of independently verified durable copies ≥ 2 after deletion. Server-configured cold session → {server blob, server backup} = 2. **Local-only Phase 2** → require the local `index.sqlite` covered by a *recent* Time Machine backup, else refuse (a lone copy inside one SQLite file is not durable).
6. **Tombstone:** deletion records `(path, hash)` inside the undo window.

Aging pauses whenever offline or backup replication is lagging (condition 4/5 can't be met).

### N6 — CAS / chunker format evolution (no forced re-upload)

Three **independent** per-record version tags decouple the concerns:
- `archive_chunks.algo` — **compression codec** (LZFSE / zstd), per chunk. New codec = new value; the decoder dispatches on `algo`; old chunks keep decoding forever.
- `manifest.chunker_version` — **boundary algorithm**, per session. Reads reassemble via the session's own recorded version, so old-format sessions read correctly forever.
- `session_archive.schema_version` — **manifest serialization**, per session; versioned decoder.

Because the CAS is keyed purely by content hash, old- and new-format chunks **coexist in the same store with zero conflict** — the store is format-agnostic. A format bump is purely additive: bump the *writer*, leave every existing session untouched. **Lazy re-chunk:** never re-chunk on a bump; only a session already being re-indexed for other reasons adopts the new chunker. The only cost is slightly reduced cross-session dedup *across* a version boundary (new chunks won't dedup against differently-bounded old chunks) — accepted as far cheaper than a full-corpus re-upload. Document: "dedup is best-effort within a chunker_version cohort."

### N3 — App ↔ server version skew

**Versioned, additive API + capability negotiation.** Major version in path (`/v1/...`); on connect the client GETs `/capabilities` → `{apiVersions:[1,2], capabilities:["blob.put","blob.head","manifest.v2","backup.status"]}` and selects the highest common major + feature-gates optional behavior on flags.

Behavior matrix:
- **New client / old server:** missing capability (e.g. `manifest.v2`) → client falls back to the v1 path. If the server lacks a capability required to *guarantee remote durability*, the client keeps **read-only federation** but **refuses to arm aging/delete** (safety: never delete originals when durable-remote can't be proven). Never silently break durability.
- **Old client / new server:** server keeps every `v1` endpoint mounted and backward-compatible (additive fields only, defaulted); serves old writes unchanged and may return a soft "upgrade recommended" advisory.

Rule: breaking changes bump the major and the server keeps the prior major mounted for a deprecation window. It's one owner, but the 24/7 server and the Mac app update at *different times*, so this window must exist — capability negotiation + refuse-to-delete-on-incompatibility is the safety net that makes skew harmless.

Sources: [litestream.io/how-it-works], [litestream.io/tips], [sqlite.org/cksumvfs.html], [restic check --read-data docs], [rclone S3 Object Lock / --immutable].

### Decisions


**G2** [high] Back up the server CAS blob directory with nightly `rclone sync --immutable --b2-versions` to the SAME versioned/Object-Lock bucket that already receives the Litestream metadata WAL. Do not layer restic/borg on top of already-deduped, already-encrypted content-addressed chunks.
- rationale: Blobs are immutable content-addressed objects that map 1:1 to WORM bucket objects; rclone only adds, versioning+Object-Lock make them ransomware/bug-proof. A second dedup/pack/encryption tool (restic/borg) is gold-plating over convergent-encrypted CAS. One bucket, one credential, unified with metadata backup.
- user choice remaining: Object-storage provider + region, and Object-Lock mode (governance vs compliance) and retention length. ZFS snapshots on the server are an optional local-disk complement, not a substitute for the offsite bucket.

**G5** [high] Reject cksumvfs; rely on CAS-key self-verification (chunk PK == SHA-256 of plaintext) for chunk integrity, weekly throttled scrub, PRAGMA integrity_check for structure, WAL+synchronous=NORMAL for torn writes, Time Machine for the DB file. Delete-gate = 6 AND-conditions recomputed at gate time (capture complete, local re-hash of every chunk + reassembled content_hash, structural health, remote-verified-AND-in-completed-backup if server configured, never-last-copy ≥2 with a Time-Machine requirement in local-only mode, tombstone).
- rationale: cksumvfs needs exactly 8 reserved bytes set at creation, is incompatible with other reserve-byte users, can't retrofit the live 741MB DB without a rebuild, and only guards regenerable metadata; CAS keys already give free per-chunk integrity. SHA-256 at ~1-2 GB/s makes full re-verification cheap enough to run at every gate. The gate must recompute, not trust a stored flag, and must never leave a single copy inside one SQLite file.
- user choice remaining: Scrub cadence (default weekly) and whether local-only Phase 2 deletion is allowed to depend on Time Machine presence or should simply wait for a server.

**N3** [high] Versioned additive API (`/v1/...`) + `/capabilities` negotiation. New-client/old-server: fall back on missing capability; if remote durability can't be proven, keep read-only federation but refuse to arm aging/delete. Old-client/new-server: server keeps prior major mounted, additive/defaulted fields, soft upgrade advisory. Breaking change bumps major with a deprecation window.
- rationale: One owner but the 24/7 server and Mac app update at different times, so a compat window must exist. Refuse-to-delete-on-incompatibility makes any skew durability-safe rather than silently destructive.
- user choice remaining: Deprecation-window length for retiring an old API major (can be short given single user).

**N4** [high] Targets: metadata RPO ≤ 1s (Litestream default sync-interval); blob-backup RPO ≤ 24h but irreplaceable-data RPO = 0 because the delete-gate forbids deleting an original before its chunks are in a completed backup; degraded RTO = 0 (Mac works offline), full server rebuild RTO ≤ 2h. Monthly automated `restore-drill.sh`: litestream restore + rclone sync to scratch, then reassemble N random sessions and assert recomputed content_hash equality + zero dangling manifest references; push PASS/FAIL to the app via backup.status.
- rationale: Coupling the delete-gate to backup-present collapses the 24h backup gap to zero data loss (originals persist until backed up). A drill that reassembles-and-rehashes proves recoverability; a drill that only copies files does not.
- user choice remaining: Drill cadence (default monthly), sample size N, and where the drill runs (server timer vs container).

**N6** [high] Three independent per-record version tags: `archive_chunks.algo` (compression codec, per chunk), `manifest.chunker_version` (boundary algorithm, per session), `session_archive.schema_version` (manifest format, per session). Reads dispatch on the stored tags, so old and new formats coexist in one content-keyed store. Never re-chunk on a bump; re-chunk only sessions already being re-indexed (lazy). Accept reduced cross-cohort dedup instead of full re-upload.
- rationale: CAS keyed purely by content hash is format-agnostic, so a format bump is additive — bump the writer, leave existing sessions untouched, zero forced re-upload. The only cost is marginally lower dedup across a version boundary, far cheaper than re-uploading the corpus.
- user choice remaining: None.


### Evidence

- Litestream default sync-interval = 1 second continuous WAL replication → metadata RPO ~1s: https://litestream.io/how-it-works/ and https://litestream.io/tips/
- cksumvfs requires reserve-bytes == exactly 8, set at DB creation, incompatible with other reserve-byte extensions (e.g. SQLCipher needs 16/48/80) → not retrofittable to the live 741MB DB: https://sqlite.org/cksumvfs.html
- restic check --read-data downloads and rehashes every blob to catch bit-rot — cited to contrast with a reassembly-based drill: https://restic.readthedocs.io/en/latest/045_working_with_repos.html
- rclone sync only re-uploads changed files (compare by size/mtime/MD5) and supports S3 Object Lock / --immutable / B2 versioning for WORM backups of immutable content-addressed objects: https://rclone.org/commands/rclone_sync/ and https://rcloneview.com/support/blog/immutable-backups-s3-object-lock-rcloneview
- Empirical ground truth (round2-context.md §5): corpus ~15 GB across sources, local index.sqlite 741MB, stray 719MB .bak; Codex has 3 outlier ~1.6GB files with gzip ratio ~1.33x (embedded base64) — informs 'few GB blob download' RTO estimate and scrub cost.
- CAS design fact (round2-context §Data model): archive_chunks(hash TEXT PK, algo INT, ...) keyed over PLAINTEXT hash — the basis for free per-chunk integrity and format-agnostic coexistence.
- SHA-256 hardware acceleration on Apple Silicon (~1-2 GB/s) makes full-corpus re-verification seconds of CPU, justifying gate-time recompute and cheap weekly scrub.


### Reviews


#### [needs-fixes] lens: Data-loss adversary: correlated failures, silent corruption windows, backup rot, stale-pass restore drills, delete-gate
- (blocker) Metadata durability is claimed solely via Litestream's ~1s continuous replication, but Litestream's default retention window is 24h (it prunes snapshots/WAL older than the retention setting, keeping at minimum one snapshot). Continuous replication actively propagates an accidental/buggy DELETE of session_archive/chunk_manifest rows to the replica in ~1s. On a single-user system that isn't checked daily, discovery of a logical corruption or mass-delete more than ~24h after it happens (default config) makes point-in-time restore impossible — even though the CAS blobs themselves are untouched and immortal, the manifest rows that map chunk-hashes back to a session are gone. History does not survive: chunks exist but nothing points to them. → FIX: Explicitly configure Litestream retention to a long window (e.g. 30d) or set retention.enabled=false and rely on the same Object-Lock/versioned bucket lifecycle already used for blobs; additionally take a periodic (daily) full metadata snapshot/export into that same immutable bucket, independent of the rolling WAL, so a mass-delete has a recovery window measured in weeks, not hours.
- (blocker) Local-only Phase 2's delete-gate condition 5 ('never-last-copy ≥2') is satisfied by a Time Machine backup of index.sqlite. Time Machine's default destination is a local external disk, almost always sitting in the same room/house as the Mac. This is exactly the lens's own named scenario: a house fire (or theft/flood) destroys the Mac and its TM disk together, and by then the original has already been deleted on the strength of that TM backup passing the gate. → FIX: In local-only mode, either (a) refuse to arm the delete-gate entirely until a server/offsite target is configured (consistent with the design's own 'never delete originals when durable-remote can't be proven' philosophy already applied to N3 skew), or (b) require the TM/equivalent destination be verified as off-premises/networked (NAS at another site, cloud-backed TM target) before it counts as an independent durable copy.
- (major) N6's 'lazy re-chunk' (a session gets re-chunked to adopt a new chunker_version because it's being re-indexed for unrelated reasons) is not itself gated by anything resembling G5. If that session's original file has already been deleted (post initial delete-gate pass), the existing chunk set IS the only surviving copy of the session. A crash between superseding the old manifest and durably writing+backing-up the new chunk set can destroy that only copy, because re-chunking isn't treated as a durability-sensitive operation anywhere in the design. → FIX: Require re-chunking of any session with no surviving original file to pass a mini delete-gate itself: write the new manifest and chunks, locally re-verify them, and get them into a completed backup before the old manifest/chunks are unlinked or marked superseded. Keep the old chunk set as fallback until the new one is confirmed durable.
- (major) The mechanism that populates `chunk.backed_up_at` (used in delete-gate condition 4) is unspecified. rclone sync can partially succeed (some objects transferred, job later times out/crashes). If `backed_up_at` is implemented as a job-level timestamp stamped optimistically at job start or on any exit rather than per-object confirmation parsed from rclone's per-file result, the delete-gate's core safety invariant ('every chunk present in a completed backup') can be silently violated — originals get deleted for chunks that were never actually uploaded. → FIX: State explicitly that `backed_up_at` is written per-object, only after rclone's per-file transfer success is confirmed (parse rclone's structured/JSON log, not just the job's aggregate exit code), and that a crashed or partially-failed sync leaves the un-transferred chunks' `backed_up_at` untouched (fail-closed).
- (minor) The delete-gate's local recompute (condition 2) and the actual unlink of the original are not stated to be atomic/locked together. A concurrent scrub-triggered quarantine or local disk fault occurring in the gap between 'hash verified' and 'original deleted' isn't re-checked, creating a narrow TOCTOU window where deletion proceeds on a now-stale verification. → FIX: Hold a lock on the session's chunk set spanning verify→delete (or re-run the hash check as the last statement immediately before unlink with nothing else able to run in between).
- (minor) The monthly restore-drill only samples N random session_archive rows and reassembles through their manifests — it never walks the raw CAS blob store directly. Chunks orphaned by a re-chunk (see N6 finding above) or any future GC have no live manifest pointing to them, so the drill can never select them for verification; they can rot silently and indefinitely even though they may still be needed for undo/audit. N's value and its coverage guarantee relative to a growing corpus are also unstated. → FIX: Define N as a fraction of corpus size (not a fixed constant) and add a separate, lower-frequency (e.g. quarterly) pass that iterates the raw blob store by content-hash directly — independent of any manifest — to catch orphaned-chunk rot the manifest-driven drill structurally cannot see.
- (overengineering) None significant found — the design already explicitly rejects restic/borg, cksumvfs, ZFS-as-primary, and second-Mac copies with sound reasoning; the weekly full-corpus scrub and gate-time full re-hash are justified by measured SHA-256 throughput and are not excessive for the stated corpus size.

#### [needs-fixes] lens: Solo-dev ops realism: cron/systemd drift, disk-full at 2am, unread monitoring, restore drills that lapse, silent failure
- (blocker) No dead-man's-switch / alerting on job failure anywhere in the chain. Nightly rclone sync, Litestream replication, weekly scrub, and even the monthly restore-drill only surface state passively (backup.status in a menu bar, a stored last-scrub flag). If the server reboots and the launchd/systemd timer doesn't come back, if a cron entry silently vanishes after an OS update, or if the drill script itself throws before writing PASS/FAIL, there is no push/email/notification — just an unread UI label. For a solo operator this is exactly the failure mode described in the brief: a dashboard nobody opens for a month, discovered only when a restore is actually needed. → FIX: Add a cheap heartbeat check (e.g. healthchecks.io-style ping-on-success, or a local watchdog comparing 'expected last-run' vs 'actual last-run') that pushes a macOS notification/email if the nightly backup or monthly drill is more than one missed cycle late. Wire drill FAIL and job failure directly to a push notification, not just a status field the user must go look at.
- (blocker) Litestream and rclone both write to the same B2 account/bucket/credential ('one backup story, one credential' is stated as a strength). This is also a single correlated failure point: an expired API key, billing lapse, or account suspension kills metadata replication and blob backup simultaneously and silently — both go dark at once, and the only detector is the monthly restore-drill, meaning up to ~30 days of undetected total backup outage. → FIX: Add a trivial daily liveness check independent of the full drill: list the bucket and confirm an object was written/modified in the last 24h for both the meta and blobs prefixes; alert loud on failure so credential/billing breakage is caught same-day, not next month.
- (major) Delete-gate condition 5 for local-only Phase 2 ('require the local index.sqlite covered by a recent Time Machine backup, else refuse') trusts an external system the design never actually verifies. Time Machine can be paused, have the volume excluded, target a disconnected disk, or simply be off — all silently, with nothing surfaced at the moment the delete-gate runs. → FIX: Query tmutil latestbackup/destinationinfo at gate time and require a completed snapshot newer than ~48h that covers the DB's volume; if freshness can't be confirmed, fail condition 5 closed (refuse deletion). Given the added complexity of verifying TM correctly, an even cheaper fix is to simply disallow local-only-Phase-2 deletion entirely until a server exists.
- (major) The weekly scrub job runs via IndexingBackgroundActivityScheduler, which only fires while the Mac app is active. A laptop closed for a few weeks means scrub silently never runs, and unlike the drill's backup.status there is no visible 'last scrub' timestamp anywhere in the design — integrity drift can go undetected indefinitely with no signal to the user. → FIX: Persist and surface last_scrub_completed_at in the same status surface as backup.status, and make the delete-gate's condition 3 ('last scrub passed') check staleness (e.g. refuse/warn if last scrub is >14 days old) instead of just checking pass/fail of whenever it last happened to run.
- (minor) Nightly rclone sync and the drill's scratch directory have no disk-space preflight. The corpus already has multi-GB outlier files (per the design's own evidence section), so a growing archive on a small disk can make the nightly sync or monthly drill fail exactly when space is tightest (2am, unattended), and a silent nonzero exit from a cron job is invisible without alerting. → FIX: Add a disk-free preflight check before both jobs (df threshold, abort+alert if less than ~2x expected transfer size free) and route any nonzero rclone/litestream exit code to the same alert path as a failed drill.
- (minor) Scrub's self-heal path ('alert if neither remote-verified nor original present') never specifies the alert channel/mechanism — the one place in the design that name-drops 'alert' without wiring it to backup.status or any concrete notification, unlike the rest of the doc which is otherwise precise about mechanisms. → FIX: Wire scrub's no-recovery-path case into the same push-notification/backup.status channel used for drill failures, so a solo operator has one alerting surface to watch instead of an implied-but-undefined one.
- (overengineering) The 6-condition delete-gate re-hashing every chunk at gate time is justified given SHA-256 is cheap on Apple Silicon — not flagged as overengineering.
- (overengineering) Three independent version tags (algo/chunker_version/schema_version) for format evolution is reasonable given the stated 'never forced re-upload' requirement; not excessive for a single append-only store.

---

## Cluster: search-mining

## Cluster C — Search & Mining

**Ground truth (this machine's `~/.engram/index.sqlite`, 741 MB):** 29,628 sessions — **26,222 `skip`** (subagents/noise, excluded from semantic search by policy), 1,132 `normal`, 1,960 `premium`, 314 `lite`. Semantic-eligible today = **3,092**. The shipped Swift path already does brute-force L2-normalized cosine KNN (`VectorSearch.swift`, "sub-millisecond for thousands"), embeddings via Mac Ollama, model/dimension tracked in `embedding_meta`. The server today (`EngramRemoteServer`) is a Hummingbird AES-GCM **blob store** over Tailscale that holds offloaded FTS + keeps a local keyword-searchable shadow line and rehydrates on open.

### G6 — semantic over the cold corpus

**Keep it out of v1.** The simplest sound design is **FTS-only on the server mirror + local semantic over the resident corpus**, and it is the right one here. Two reasons: (1) semantic value concentrates in the *hot* corpus you actually revisit; the cold corpus is exactly what gets offloaded, and offload already preserves keyword recall via the local shadow line + rehydrate-on-open. (2) Server-side semantic forces embedding vectors onto the server as plaintext float BLOBs (you cannot cosine over ciphertext) — that turns a dumb encrypted blob store into a semantically-searchable representation of your archive, weakening the one clean privacy property the offload design has. Not worth it for a single user who can rehydrate any session in seconds.

**Scale math confirms deferral costs nothing.** Even at the 5-year ceiling — say ~15–20k eligible sessions × ~30 message-boundary chunks ≈ **0.5–1M chunks, 768-dim** — brute-force stays cheap. sqlite-vec measures **17 ms for 1M×128-dim and 41 ms for 500k×960-dim on an M1 Mac mini** (SIFT1M/GIST); interpolating, 768-dim at ~0.6M chunks is **~15–30 ms per query, server CPU, single-user, one query at a time**. ANN (HNSW/pgvector) only earns its keep above ~1M vectors *and* when you need <10 ms at high QPS — neither applies within the horizon. Vector footprint at 1M×768×4B ≈ **3 GB** (int8 → 0.77 GB), trivial on a mac mini.

**If/when server semantic is wanted (v2):** reuse the existing brute-force path server-side — store embeddings as an extra derived artifact next to each FTS blob. **Do not add pgvector/Qdrant/LanceDB**: a sidecar service, its own storage engine, and ANN index maintenance are pure operational tax for a corpus that brute-force clears in tens of ms. sqlite-vec is the only escalation worth considering, and only past ~1M vectors. **Embeddings compute on the Mac via Ollama, always** (server is CPU-only; Ollama-on-CPU embedding is slow and adds a runtime dep to a process that must stay a blob store). Compute on-ingest (already how the hot path works); when a session offloads, ship its already-computed vector alongside the FTS blob. Backfill already-offloaded sessions with a one-time rehydrate→embed→re-offload job gated by `embedding_meta` model/dimension — the existing rebuild pattern, no new machinery. Embeddings are regenerable derivatives: no backup burden, drop and rebuild on model change.

### N2 — federated search consistency

By construction the two indices are **near-disjoint**: a session is resident (local, authoritative) or offloaded (server mirror), tracked by an offload-state column. True overlap only exists in the brief in-flight window (mid-offload / mid-rehydrate).

**Merge algorithm:**
1. Always fire local FTS (fast, offline-safe) — this is the floor.
2. In parallel, fire the server query **iff reachable**, short timeout (~800 ms).
3. Merge by `session_id`. **On collision, local wins** — local content is ground truth; the server is a lagging mirror.
4. **Freshness watermark:** each side carries a `sync_ledger` watermark (max offload/rehydrate seq or `indexed_at`). Use it to (a) stamp results "server index as of ⟨t⟩" and (b) detect a session marked offloaded locally but not yet on the server (watermark behind) — the local shadow line already covers it for keyword, so no gap.

**Degraded/offline UX:** never block on the server. Offline → return local immediately with a non-modal note: *"Offline — searched local index only; N archived sessions not covered."* Server times out mid-merge → return local + the note. Server-only client (Mac asleep) → server answers its mirror with the as-of watermark shown. Ties/dupes → local wins, dedup by `session_id`. The invariant: **local FTS alone is always a complete, correct keyword answer**; the server only *adds* offloaded coverage.

### N7 — get_decisions / timeline mining

**Optional, never blocks archival.** Start with the simplest sound answer and argue it first: **v1 needs no LLM.** `get_decisions` = structured/FTS query over the existing `insights` table (`save_insight` already captures curated decisions) plus a cheap heuristic pass (regex for "decided/chose/because", commit-linked messages) building the timeline. This ships value with zero model cost or latency and no archival coupling.

**If LLM mining is added:** compute **on the Mac, lazy/on-demand** — triggered when the user opens a project's decision timeline, **not on-ingest** (on-ingest mining would couple a slow, optional, failure-prone LLM call to the archival hot path — forbidden). Feed the session *summary + key messages* (not the full transcript). **Model: Claude Haiku 4.5 (`claude-haiku-4-5`, $1.00/$5.00 per M in/out)** for quality, or local Ollama for $0. Cost with Haiku at ~4k in + ~500 out per session: **~$0.0065/session ≈ $6.50 per 1k sessions** — a one-time backfill of today's 3,092 eligible sessions is **~$20**. **Cache** keyed by `(session_id, transcript_content_hash, model, prompt_version)`; **invalidate** when the re-index bumps the content hash or `prompt_version` changes. Mining runs in the service maintenance lane behind a feature flag; a failure logs and is skipped — archival proceeds regardless.

### Decisions


**G6** [high] Defer server-side semantic over the cold corpus. v1 = FTS-only server mirror + local brute-force cosine over the resident (normal/premium) corpus; cold sessions stay keyword-searchable via the offload shadow line and rehydrate-on-open. If ever escalated (v2), reuse the existing brute-force path server-side with plaintext float BLOBs next to each FTS blob; embeddings always computed on the Mac via Ollama (on-ingest for hot, rehydrate→embed→re-offload backfill gated by embedding_meta). No pgvector/Qdrant/LanceDB; consider sqlite-vec only past ~1M vectors.
- rationale: Semantic value concentrates in the hot corpus you revisit; the cold corpus is exactly what's offloaded and already keyword-covered. Server-side vectors would turn the encrypted blob store into a semantically-searchable copy of the archive, forfeiting its only clean privacy property. Scale math: even at the 5-yr ceiling (~0.5-1M chunks, 768-dim) brute-force is ~15-30ms/query single-user (sqlite-vec: 17ms/1M×128d, 41ms/500k×960d on M1 mini); ANN only pays off >~1M vectors at high QPS. Vectors ~3GB (int8 0.77GB) are trivial. Embeddings are regenerable — no backup burden, reuse the model/dimension rebuild pattern.
- user choice remaining: Whether server-side semantic is ever in scope at all (v2) versus permanently relying on rehydrate-on-open for cold-session recall.

**N2** [high] Always fire local FTS as the floor; fire the server mirror in parallel only when reachable (~800ms timeout). Merge by session_id with LOCAL WINS on collision. Carry a sync_ledger watermark on each side for freshness stamping and in-flight gap detection. Never block on the server: offline/timeout returns local results immediately with a non-modal 'searched local only, N archived not covered' note; server-only clients answer the mirror with an as-of watermark. Dedup by session_id.
- rationale: The two indices are near-disjoint by construction (a session is resident OR offloaded, tracked by offload state); real overlap only exists in the brief in-flight window, so dedup is a safety net, not the main path. Local content is authoritative and fresh; the server mirror lags, so local must win ties. The local shadow line already keeps offloaded sessions keyword-searchable, so a lagging server never creates a coverage gap. Non-blocking merge keeps search fast and fully functional offline on a personal tailnet where the server or the Mac is routinely asleep.
- user choice remaining: The server-reachability timeout value (suggested ~800ms) and whether to show the as-of watermark inline or only on hover.

**N7** [high] Keep mining optional and fully decoupled from archival. v1: no LLM — get_decisions/timeline from the existing insights table plus a heuristic (decided/chose/because regex, commit-linked messages). If LLM mining is added: run on the Mac, lazy/on-demand when a project timeline is opened (never on-ingest), feeding summary+key messages. Model = Claude Haiku 4.5 (claude-haiku-4-5, $1/$5 per M) at ~$6.50/1k sessions (~$20 to backfill today's 3,092 eligible), or Ollama for $0. Cache keyed by (session_id, transcript_content_hash, model, prompt_version); invalidate on content-hash or prompt_version change. Failures log-and-skip; archival always proceeds.
- rationale: On-ingest LLM mining couples a slow, optional, failure-prone external call to the archival hot path — the one thing the task forbids. Lazy on-demand computes only what's viewed and pays nothing until used. The insights table already captures curated decisions, so a heuristic v1 ships value with zero model cost or latency. Haiku 4.5 is the cheapest capable extraction model (verified $1/$5 per MTok); the per-1k-session cost is trivial for a solo archive, and Ollama offers a free local fallback. Content-hash + prompt_version cache keys make re-mining incremental and correct across re-indexes.
- user choice remaining: Whether to ship the heuristic-only v1 and stop there, or wire the optional Haiku/Ollama LLM pass; and if LLM, which provider (paid Haiku for quality vs free local Ollama).


### Evidence

- Corpus scale (this machine, ~/.engram/index.sqlite): SELECT tier,count(*) → skip 26,222 | premium 1,960 | normal 1,132 | lite 314; total 29,628; DB 741 MB. Semantic-eligible (normal+premium) = 3,092.
- Active semantic path: macos/Shared/EngramCore/AI/VectorSearch.swift — brute-force L2-normalized cosine KNN, comment 'sub-millisecond' for thousands of vectors; dimension/model tracked in embedding_meta (EngramMigrations.swift). sqlite-vec vec_* tables exist in the dev DB but the shipped path is plain-BLOB brute force.
- Existing server = blob store: docs/remote-offload.md — EngramRemoteServer (Hummingbird), AES-GCM at-rest, Tailscale-only, moves sessions_fts+summary, keeps local keyword shadow line + rehydrate-on-open; embeddings are regenerable derivatives (no backup burden).
- sqlite-vec brute-force latency (primary): 17 ms @ 1M×128-dim (SIFT1M) and 41 ms @ 500k×960-dim (GIST) on an M1 Mac mini; degrades at 3072-dim; no ANN index in sqlite-vec as of early 2026 — https://alexgarcia.xyz/blog/2024/sqlite-vec-stable-release/index.html and https://grokipedia.com/page/Comparison_of_sqlite-vec_and_pgvector
- ANN threshold (primary): pgvector parallel seq scan is fine for ~10k-50k and 'naive often succeeds' near 1M vectors; HNSW earns its keep at 1M-100M / sub-10ms high-QPS — https://clickhouse.com/resources/engineering/scale-vector-search-postgres
- Haiku pricing (verified via claude-api skill model table, cached 2026-06-24): claude-haiku-4-5, $1.00 input / $5.00 output per MTok, 200K context — N7 mining ≈ 4k in + 0.5k out/session = $0.0065/session ≈ $6.50/1k; ~$20 to backfill the 3,092 eligible sessions.
- Insights already store curated decisions (CLAUDE.md, save_insight / src/core/db/insight-repo.ts) — enables an LLM-free heuristic v1 for get_decisions.


### Reviews


#### [needs-fixes] lens: Scale & correctness check: brute-force/ANN latency math, retrieval token-cost claims, federated merge dedup/freshness, m
- (major) G6's latency interpolation is arithmetically wrong and understates cost by roughly 2-3x. The design's own primary source (sqlite-vec 'static' build benchmarks, verified via WebFetch of alexgarcia.xyz) gives 17ms @ 1M×128-dim and 41ms @ 500k×960-dim. Treating cost as roughly proportional to (vector_count × dimension) and interpolating to the design's own target (0.6-1M chunks, 768-dim) gives ~45-70ms per query, not the claimed '~15-30ms'. Using the 128-dim datapoint's implied constant gives ~60-100ms at the 1M-chunk ceiling — over 3x the claimed upper bound. → FIX: Recompute the interpolation explicitly (e.g. k = query_ms/(N×dim) from each benchmark row, apply to the target N×dim, and report the resulting range, e.g. '~45-70ms per query at the 5-year ceiling'). The conclusion (brute-force still beats the ANN threshold, single-user) survives at 45-70ms, but state the corrected number — don't publish a 2-3x-optimistic figure as 'confirms deferral costs nothing.'
- (major) Evidence line 'no ANN index in sqlite-vec as of early 2026' is stale/incorrect at the design's own citation date. GitHub releases (verified via WebFetch of asg017/sqlite-vec/releases) show v0.1.7 (March 17, 2026) shipped the first DiskANN work and v0.1.10-alpha.1 (March 31, 2026) is 'Initial alpha release of sqlite-vec with new ANN indexes: rescore, ivf (experimental, not enabled), and DiskANN' — both before the design's own '2026-06-24' pricing-cache date. Separately, sqlite.org/vec1 (a distinct official extension, currently v0.7 with IVFADC+OPQ) already has production ANN. The 'consider sqlite-vec only past ~1M vectors' framing implicitly relies on sqlite-vec being brute-force-only, which is no longer true. → FIX: Correct the evidence line to 'sqlite-vec brute-force is the stable/GA path; DiskANN/IVF ANN support landed as alpha in v0.1.10 (March 2026) and is not yet recommended for production' — and note vec1 as a second candidate to re-evaluate if the corpus ever approaches the 1M-vector threshold. Doesn't change the v1 recommendation, but the stated fact is wrong and should not be cited as settled evidence.
- (minor) Internal inconsistency in the chunk-count range: '~15-20k eligible sessions × ~30 message-boundary chunks ≈ 0.5-1M chunks' does not multiply out. 15,000×30=450,000 and 20,000×30=600,000 — the stated range should be ~0.45-0.6M, not up to 1M. Reaching 1M requires either ~33k sessions or ~50 chunks/session, neither of which is stated. → FIX: Either tighten the range to '~0.45-0.6M chunks' or justify the 1M ceiling explicitly (e.g., state a higher chunks/session assumption for long sessions). As-is the stated upper bound isn't derived from the stated inputs.
- (minor) The v2 server-side latency claim ('~15-30ms per query, server CPU') silently inherits Apple-Silicon-specific SIMD/NEON throughput from a benchmark run on an 8GB M1 Mac mini (confirmed via WebFetch), without stating that the server hardware must be Apple Silicon for the number to hold. If the offload server (EngramRemoteServer / Hummingbird) ever runs on non-Apple-Silicon hardware (Linux VM, Intel box, cloud instance), brute-force cosine throughput commonly degrades 2-5x without NEON, which would materially change the 'trivial, no ANN needed' conclusion at the top of the range. → FIX: State the hardware assumption explicitly: 'assumes the offload server itself is Apple Silicon (Mac mini or similar); re-benchmark before committing to brute-force if the server ever moves to non-Apple-Silicon hardware.'

---

## Cluster: sizing-ops

## Cluster D — Sizing, Ops & Multi-Machine

### G7 — Reclaim math (measured on a clone of the live 735MB DB, `cp -c`, session-count and on-disk-verified `size_bytes` per `file_path`, sample-verified 19/20 exact matches)

On-disk-verified bytes by tier × age (today = 2026-07-11):

| tier | ≤90d (MB / n) | 90–180d (MB / n) | >180d (MB / n) |
|---|---|---|---|
| skip | 4171.5 / 21174 | 1107.1 / 4993 | 0.0 / 55 |
| lite | 10.5 / 246 | 1.5 / 67 | 0.0 / 1 |
| normal | 40.4 / 1020 | 16.3 / 103 | 4.0 / 9 |
| premium | 8437.7 / 1472 | 2339.4 / 477 | 45.5 / 11 |

Total on-disk-verified: 16,174 MB. **DB-recorded total is 17,822 MB — a 1,648 MB / 2,755-session gap of transcripts already deleted from disk** (1,114 MB from `~/.claude/projects` alone) with no durable body anywhere. This is live, ongoing data loss, not a hypothetical — it's the strongest empirical argument for shipping Phase 1 soon.

Net reclaimable (only counting bytes that still exist):
- **(i) hot=90d ∪ normal/premium forever: 1.11 GB.** Round-1's own text describes this policy but cites "~3.2 GB" — that number actually belongs to (ii). Correction noted.
- **(ii) hot=90d strict, all tiers: 3.51 GB** — reclaims 3x more but evicts 2.4 GB of `premium`/`normal` bodies (the highest-value corpus) to remote-only after just 90 days.
- **(iii) hot=180d ∪ premium forever: 0.004 GB** — statistically useless; almost everything is either <180d or premium already.

### N8 — Growth projection (file mtimes, `~/.claude/projects` + `~/.codex/sessions` + `~/.gemini`)

Apr–Jun 2026 (last 3 full months): Claude ≈1,067 MB/mo, Codex ≈2,535 MB/mo (≈2,002 MB/mo excluding the one-time 1.6 GB April rollout outlier), Gemini ≈12 MB/mo and accelerating off a small base. Combined raw run-rate ≈3.1–3.6 GB/mo. **Not scanned but real:** `~/.claude-glm`, `-qwen`, `-kimi`, `-openai`, `~/.grok` already hold 6.3 GB accumulated — add ~25% headroom.

| horizon | raw (+25% hdrm) | compressed 1.33x floor (codex/base64) | compressed 3x (plain JSON) | realistic ~1.8x ÷ dedup 1.0/1.5/2.0x |
|---|---|---|---|---|
| 1yr | 51.6 GB | 38.8 GB | 17.2 GB | 28.7 / 19.1 / 14.3 GB |
| 3yr | 154.8 GB | 116.4 GB | 51.6 GB | 86.0 / 57.3 / 43.0 GB |
| 5yr | 258 GB | 194 GB | 86 GB | 143 / 95.7 / 71.7 GB |

Even the pessimistic no-compression, no-dedup 5-year figure (258 GB) is a small-NAS-sized number, not a "data platform" number.

### D1 — Server sizing, monitoring, TCO

**Storage floor:** 500 GB SSD covers the worst-case 5yr raw figure with 2x margin for indexes/WAL/snapshots. **Backup target:** ≥1x primary corpus, budget 300 GB (Litestream continuous WAL + periodic full snapshot to a second location). **Compute floor:** 2 vCPU / 4 GB RAM — generous for single-user Postgres/SQLite+Litestream+DuckDB-sidecar with zero concurrent load; almost any existing 24/7 box already clears this.

**Minimal monitoring (all fit healthchecks.io's free 20-check tier and ntfy.sh's free public push — no self-hosting needed):**
1. Backup-completed heartbeat (ping after each Litestream snapshot).
2. Service-alive heartbeat (archive-server health endpoint, ~10 min interval).
3. Disk >80% → ntfy push, daily cron.
4. Sync-lag >48h (Mac hasn't synced) → ntfy push, informational.

**Honest TCO:** ~4–8h one-time setup (schema, blob API, Litestream, alert wiring, restore drill); steady state ≈0.5–1 hr/month (patching + occasional alert response) + 1 hr/yr rehearsed restore drill. This is not a second job.

### D2 — Hot-window policy

**Recommendation: bounded rolling window, not "forever."** skip/lite = 90d; normal/premium = 180d rolling; **plus a hard local size-cap backstop** (default 15 GB on `archive_chunks`) that LRU-evicts oldest verified-remote bodies regardless of tier if exceeded. Round-1's "normal/premium forever" is unbounded, and premium already accounts for 67% of on-disk bytes (10.8/16.2 GB) growing ~1–2 GB/mo (N8) — "forever" recreates the exact unbounded-growth problem G7 measured. Pure 90d-for-everyone (policy ii) was considered and rejected: it reclaims more today but forces a remote round-trip for exactly the sessions most likely to be revisited soon. The size cap is the simplest sound backstop; a full access-frequency/LRU tiering engine would be gold-plating for one user.

### N1 — Multi-writer minimal semantics

Key insight: under normal operation there is exactly **one writer per source-dir per session** (Claude Code/Codex/Gemini each write locally, not natively cloud-synced) — so "multi-writer" only means multiple *machines'* `EngramService` instances pushing to one *shared server*, not concurrent writers to the same bytes. That's already handled by the round-1 plan: `machine_id` (a stable per-install Keychain UUID, not hostname) namespaces server rows as `(machine_id, session_id)`; content-hash dedup at the CAS layer makes double-archiving the same bytes from two machines harmless — worst case is a wasted HEAD check.

**What actually breaks:** if a source dir (e.g. `~/.claude`) is cloud-synced (iCloud/Dropbox) between two Macs, both `EngramService` instances see the same file, and a torn/mid-write read on one side can archive a truncated body under a hash that never matches the settled file — a corrupt CAS entry, not a race on our own writes.

**Cheap guard:** require a settle-time debounce (2 consecutive `stat()` size/mtime checks ~5–10s apart) before hashing/archiving any file, plus flag as `conflict` in `sync_ledger` (not silently overwrite) whenever the same `session_id` from two `machine_id`s produces a different `content_hash`. No distributed lock, no CRDT. Recommendation to the user: don't cloud-sync source directories across machines — use Engram's own server as the merge point instead.


### Decisions


**G7** [high] Adopt policy (i): hot=90d ∪ all normal/premium forever, but correct the reclaim figure to the measured 1.11 GB (not the ~3.2 GB round-1 cited, which actually matches policy (ii)). Also treat the newly-found 1,648 MB / 2,755-session already-missing-body gap as a P0 finding that raises the urgency of Phase 1 independent of reclaim size.
- rationale: Empirical measurement on the live DB clone shows (i) yields only 1.11 GB today because skip/lite already dominate the >90d cold set while normal/premium (the bulk of bytes) stay hot forever under (i). The pre-existing 1.6GB data-loss gap is a bigger, more urgent number than the reclaim debate.
- user choice remaining: none

**D1** [high] Server floor: 2 vCPU / 4GB RAM / 500GB SSD primary + 300GB backup target. Monitoring: healthchecks.io free tier (4 checks: backup heartbeat, service-alive, and two ntfy.sh pushes for disk>80% and sync-lag>48h). Budget ~0.5-1 hr/month steady-state TCO plus 1 hr/yr restore drill.
- rationale: 5-year worst-case (no compression, no dedup, +25% unscanned-provider headroom) is 258GB — a commodity SSD number. healthchecks.io free tier (20 checks) and ntfy.sh's free public instance cover all needed alerts with zero self-hosting or paid tier.
- user choice remaining: Which physical/cloud box hosts the server, and where the second backup location lives (another disk on the same box vs a second machine vs object storage) — specs unknown to this review, but the computed floor is low enough that almost any existing 24/7 box clears it.

**D2** [medium] Bounded rolling window: skip/lite=90d, normal/premium=180d (not forever), plus a hard 15GB local size-cap backstop that LRU-evicts oldest verified-remote bodies on overflow regardless of tier.
- rationale: Round-1's 'normal/premium forever' is unbounded growth by construction; premium is already 67% of on-disk bytes today and growing ~1-2GB/mo per N8. A rolling 180d window plus a simple size-cap backstop bounds growth without building a full access-frequency tiering system.
- user choice remaining: Exact cap size (15GB is a starting default) and exact rolling-window lengths (90d/180d) are tunable preferences, not load-bearing architecture — user can adjust once they see real local-disk pressure.

**N1** [high] machine_id (stable per-install Keychain UUID) namespaces server rows as (machine_id, session_id); content-hash dedup already makes double-archive harmless; add a settle-time debounce (2x stat checks, ~5-10s apart) before archiving any file, and flag same-session_id-different-hash as a sync_ledger conflict rather than silently overwriting. Explicitly tell the user not to cloud-sync source directories across machines.
- rationale: Under normal operation there is one writer per source-dir per session, so true multi-writer only exists at the server-ingest layer, which idempotent HEAD-then-PUT + content-hash already handles. Cloud-synced source dirs are the one case that breaks the single-writer assumption, and a cheap debounce + conflict flag (no distributed lock/CRDT) is sufficient given this is a personal single-user archive.
- user choice remaining: Confirm whether any source directory (~/.claude, ~/.codex, ~/.gemini, etc.) is currently cloud-synced across two machines; if yes, either stop that sync or accept the conflict-flagging guard as detection-only, not full protection.

**N8** [medium] Plan storage around a 5-year band of ~72-258GB (realistic-with-dedup floor to pessimistic-no-compression ceiling) rather than a single point estimate; add 25% headroom for unscanned provider directories (~/.claude-glm, -qwen, -kimi, -openai, ~/.grok) already totaling 6.3GB.
- rationale: Measured Apr-Jun 2026 combined raw ingest run-rate is 3.1-3.6GB/mo; codex content resists compression (1.33x floor) due to embedded base64/binary payloads per round-1's own finding, while plain JSON (claude/gemini) compresses closer to 3x — hence the band rather than one number.
- user choice remaining: None required now; re-measure in 6-12 months once base64 externalization (round-1 Phase 3) is live, since it should meaningfully raise the achievable compression ratio on the codex-heavy portion of the corpus.


### Evidence

- Live DB clone: `cp -c ~/.engram/index.sqlite <scratch>/ro-index.sqlite` (APFS clone, read-only; original never touched).
- Schema: `sqlite3 <clone> ".schema sessions"` — sessions has file_path, size_bytes, tier, start_time, agent_role columns.
- Sample validation: 20 random rows compared `size_bytes` (DB) vs `stat -f%z` (actual on-disk) — 19/20 exact match, 1/20 file already deleted.
- Full aggregation: python3 script joining `SELECT id, tier, start_time, file_path, size_bytes, agent_role FROM sessions` (29,628 rows) against `os.path.exists()` per file_path, bucketed by tier x age (today=2026-07-11, 90d/180d cutoffs) — script at /private/tmp/claude-501/-Users-bing--Code--engram/8b2cb205-7d30-44a8-9ddd-f265da85d380/scratchpad/g7_analysis.py (clone deleted after use, script retained).
- Missing-file breakdown by source path segment: claude 1114.0MB/1737 files, local 203.6MB/394, unknown 177.6MB/59, gemini 112.2MB/386, grok 24.8MB/130, claude-mimosg 15.9MB/43, kimi 0.1MB/6.
- N8: `find ~/.claude/projects|~/.codex/sessions|~/.gemini -type f -name '*.jsonl' -o -name '*.json' | xargs stat -f "%Sm %z" -t "%Y-%m" | awk` grouped by year-month, summed bytes.
- Other-provider accumulation check: `du -sm ~/.claude-glm ~/.claude-qwen ~/.claude-kimi ~/.claude-openai ~/.claude-mimosg ~/.grok` = 216+63+245+4406+15+1353 = 6298MB total, not included in the 3-dir N8 scan.
- healthchecks.io free tier: 20 checks, 3 months log history, email/Slack alerts, open-source self-host option — https://healthchecks.io/pricing/
- ntfy.sh: free public push server, simple curl POST/PUT to send alerts, systemd-timer-friendly — https://ntfy.sh/ and https://massivegrid.com/blog/self-host-ntfy-ubuntu-vps/
- Round-1 ground truth reused: ~/.codex/sessions 3 outlier files ~1.6GB (Apr 27-29 2026), gzip ratio ~1.33x due to embedded base64/binary payloads.


### Reviews


#### [needs-fixes] lens: Numbers audit: independent re-verification of G7 reclaim math and N8 growth/projection figures against a fresh APFS clon
- (minor) N8's 1-year 'raw (+25% hdrm)' figure of 51.6 GB does not reproduce from the stated methodology. Independently re-running the mtime scan gives Claude ≈1067 MB/mo, Codex ≈2535 MB/mo (full) / ≈2002 MB/mo (excl. outlier), Gemini ≈12 MB/mo — all of which match the design doc's per-source averages exactly. But annualizing the combined rate and applying +25% headroom lands in a 46.5–54.2 GB band depending on which base rate (low/high/excl.-outlier) and multiplication order is used — none of the straightforward reconstructions hit exactly 51.6 GB. The 3yr (154.8) and 5yr (258) figures are then pure linear multiples of 51.6 (×3, ×5), so the imprecision propagates unchanged through the whole table. → FIX: Show the exact arithmetic in N8 (e.g. 'combined_MB/mo × 12 × 1.25 = X') so the headline figure is auditable to the same MB precision as the per-source averages, or state explicitly which of the low/high/excl.-outlier bases was used for the table. This doesn't change the doc's directional conclusion (still small-NAS-scale either way) but the current 51.6/154.8/258 GB figures cannot be independently confirmed as stated.
- (minor) D2's rationale for the 180d rolling window asserts premium is 'growing ~1–2 GB/mo,' but this number is not backed by any query in the evidence list (N8 only measures aggregate bytes across all tiers/sources, not a premium-tier-specific rate). Directly querying premium-tier bytes by session start_time month on the clone gives Apr=3382 MB, May=3205 MB, Jun=2182 MB — average ≈2.9 GB/mo, roughly 1.5–3x higher than the doc's stated '1–2 GB/mo,' and actually declining month-over-month rather than accelerating. → FIX: Add an explicit per-tier growth query (SELECT substr(start_time,1,7), SUM(size_bytes) FROM sessions WHERE tier='premium' GROUP BY 1) to the evidence list and correct the D2 rationale to ≈3 GB/mo, which if anything strengthens (not weakens) the case for a size-cap backstop — but the current number is unsupported and understates the problem.
- (minor) D1 states the 500 GB SSD storage floor gives '2x margin' over the worst-case 5yr raw figure (258 GB), but 258 × 2 = 516 GB > 500 GB, so the actual margin is ≈1.94x, not 2x. → FIX: Either bump the recommended floor to 512/520 GB or soften the claim to '≈1.9x margin' — trivial but the stated multiplier doesn't match the stated inputs.