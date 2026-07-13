# Independent Review Findings — Engram Remote Archive

**Review date:** 2026-07-11

**Scope:** source-level review of the four named competitors, the two-round decision package, and the relevant current Engram Swift paths

**Overall verdict:** **PROCEED WITH CHANGES** — keep the archive-of-record direction, but do not implement the current Phase 1 or enable any deletion/GC from this design as written.

## Evidence baseline

The competitor conclusions below are pinned to these snapshots, not inferred from names, stars, or README summaries:

| Repository | Verified URL | Reviewed commit |
|---|---|---|
| CASS | <https://github.com/Dicklesworthstone/coding_agent_session_search> | `8110944f6ba3636e8f47a9b8593d085f25d53b7a` |
| AgentsView | <https://github.com/kenn-io/agentsview> | `02772c7e47c1279a78c357a9cd602f7335640d23` |
| claude-mem | <https://github.com/thedotmack/claude-mem> | `312d640b0188753acd92a1a82d95a84d5c7c43db` |
| Gentleman-Programming/engram | <https://github.com/Gentleman-Programming/engram> | `be4b61384ee154abbdea2f8760a5f1e43dd595ab` |

Citation form is `Repository@commit:path:lines`; `Gentleman-Engram` denotes `Gentleman-Programming/engram`. Engram citations are worktree-relative. Code claims refer to the pinned snapshots above.

## Executive verdict

The package gets the strategic direction mostly right: Engram should own the Swift archival boundary; Tailscale-only exposure is appropriate; server semantic search and ANN infrastructure should stay deferred; and the safest first release should delete nothing. The source review, however, overturns several implementation premises:

- The proposed message-normalized CAS is not a byte-verbatim archive. A raw, pre-parse source capture must be canonical; normalized messages and semantic chunks must be derived.
- The delete gate is not bound to the generation of the source file it proposes to unlink.
- The selected server-held-key topology has no independent key-recovery proof for the B2 disaster copy.
- The current remote `BlobStore` is overwritable and does not verify that a key names its content.
- `backed_up_at` plus two asynchronous copy systems does not identify one coherent, restorable archive generation.
- Putting archive bytes into the existing `index.sqlite` creates the wrong failure/maintenance boundary, and the Phase 0 `auto_vacuum` claim is false for an existing database unless it is rebuilt.

The appropriate first release is therefore **capture-only, local, exact-source, and never-delete**. Remote backup, remote reads, and source deletion should be separate gates, in that order.

## Top 10 findings, ranked

### 1. BLOCKER — “Verbatim” has no byte-exact canonical object

**Claim.** The proposed archive cannot presently satisfy its own verbatim/archive-of-record promise. It chunks parsed messages, externalizes payloads, and then claims exact recovery, but does not define how the original byte stream is reconstructed.

**Evidence.** The package specifies message-boundary chunking and base64 externalization before archival (`review-handoff/round2-context.md:71-79,91-95`) and promises that compaction recovery returns exactly what was evicted (`review-handoff/round2-context.md:113-121`). Current Claude parsing retains only `user`/`assistant` records, filters injected records, and replaces image bytes with a descriptive placeholder (`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:477-505,527-565`). Current MCP `includeRaw` only disables output redaction; it still returns normalized messages (`macos/EngramMCP/Core/MCPTranscriptTools.swift:4-47`). **[competitor-source: CASS]** CASS instead captures the source file before parsing, records source identity and provenance, and publishes a full-file BLAKE3 CAS object plus manifest (`CASS@8110944:src/indexer/mod.rs:24097-24167,24202-24234`; `CASS@8110944:src/raw_mirror.rs:778-932,982-1053,1109-1194`).

**Suggested change.** Make exact source bytes, or an explicitly versioned byte-canonical snapshot for database-backed sources, the archive system of record. Store `(source generation, full digest, byte length, provider/source identity)` in a versioned manifest. Treat message ordinals, externalized payload references, FTS text, summaries, decisions, and embeddings as rebuildable derivatives. If payload externalization remains, record reversible byte spans and require full-stream reassembly to match the original digest.

### 2. BLOCKER — the delete gate proves the archive, not the current source generation

**Claim.** A session may be captured correctly, then appended to or replaced, while the old durable state remains eligible to authorize deletion of the new file at the same path.

**Evidence.** The six conditions validate chunks, manifests, database health, remote state, backup state, and tombstones, but never require the file about to be unlinked to equal the generation that was captured (`review-handoff/round2-clusters.md:151-167`). The existing offload runner enqueues no generation, commits against `sync_version`, and the index snapshot currently emits a constant `syncVersion: 1` (`macos/EngramCoreWrite/RemoteSync/OffloadRunner.swift:44-54`; `macos/EngramCoreWrite/RemoteSync/OffloadRepo.swift:184-210`; `macos/EngramCoreWrite/Indexing/SwiftIndexer.swift:686-694`). **[competitor-source: CASS]** CASS rejects symlinks and identity changes, compares device/inode and metadata around capture, detects active writers, and refuses a source that changes while being copied (`CASS@8110944:src/indexer/mod.rs:110-203,228-245`; `CASS@8110944:src/raw_mirror.rs:982-1107`).

**Suggested change.** Bind every capture to a source generation: at minimum `(device, inode/resource-id, size, mtime/ctime, full content hash)`. Verify identity before and after capture. Immediately before unlink, reopen without following a substituted symlink, verify the same generation and full hash, and refuse active/growing sources. Any append, same-size rewrite, truncation, or path reuse invalidates the old delete eligibility. Keep deletion disabled until adversarial append/replace/race tests pass.

### 3. BLOCKER — the B2 disaster copy has no independent key-recovery story

**Claim.** The final memo simultaneously chooses server-held encryption, sends the archive to third-party B2, and treats B2 as an independently durable copy, but does not preserve the decryption key in an independent recovery domain.

**Evidence.** Cluster A says scheme (c) is suitable only when both server and backup media are physically controlled and says any cloud backup should trigger client-held scheme (a) (`review-handoff/round2-clusters.md:24-38`). The final memo nevertheless descopes client key custody, retains scheme (c), and selects a B2 Object-Lock backup (`review-handoff/final-decision-memo.md:45-55,83-86`). Current operation supplies `ENGRAM_REMOTE_AT_REST_KEY` only from the server environment, and rotating it makes existing objects unreadable (`macos/EngramRemoteServer/Core/EngramRemoteServerConfig.swift:4-14,32-76`; `docs/remote-offload.md:71-99`). Object Lock preserves ciphertext, not the key needed to restore it.

**Suggested change.** Decide the disaster topology before selecting encryption. If B2 is in v1, either use a reviewed tool such as restic/borg with tested independent key recovery, or keep the server-held data key but wrap/escrow a recovery copy outside the server and B2 credential domain. A clean-machine drill using only the immutable backup plus the recovery material must pass before B2 counts as a durable copy. Do not hand-roll keyed-convergent crypto in v1.

### 4. BLOCKER — “durable” does not yet identify an immutable, coherent restore generation

**Claim.** Object existence, `backed_up_at`, and a Litestream heartbeat do not prove that one restorable generation contains the required blobs, their manifest, metadata transaction, algorithm tags, and usable key material.

**Evidence.** The package copies blobs and streams metadata independently, then treats per-chunk backup timestamps as proof for deletion and calls irreplaceable-data RPO zero (`review-handoff/round2-clusters.md:116-149,151-167`; `review-handoff/final-decision-memo.md:54-57`). Its own red-team notes that the mechanism for `backed_up_at` is unspecified and partial copy jobs can be mislabeled (`review-handoff/round2-clusters.md:228-244`). Worse, the existing server accepts an arbitrary safe filename with an arbitrary body, atomically overwrites an existing object, and exposes DELETE; it does not recompute a plaintext hash and compare it with the key (`macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift:88-115`; `macos/EngramRemoteServer/Core/BlobStore.swift:28-69`). The client `HEAD` then `PUT` sequence is not an atomic create-if-absent operation (`macos/EngramCoreWrite/RemoteSync/OffloadRunner.swift:80-88`).

**Suggested change.** First make the archive namespace immutable: the server must recompute the canonical plaintext/content ID, require it to match the requested key, publish with exclusive create, and verify identical content on an existing key; no ordinary DELETE endpoint. Then introduce a backup epoch/barrier: copy and verify all referenced blobs, commit the exact manifest/metadata generation, wait until remote metadata backup explicitly covers that transaction, and publish an immutable receipt last. The delete gate must verify one receipt, not independent timestamps. Restore drills must select a receipt and restore that exact epoch, including key recovery.

### 5. HIGH — the existing `index.sqlite` is the wrong blob boundary, and Phase 0 is not a no-rewrite migration

**Claim.** Putting the durable body CAS into the live metadata/FTS database couples regenerable indexes, irreplaceable bytes, WAL growth, backup, corruption, and space reclamation. The migration plan also incorrectly implies that `auto_vacuum=INCREMENTAL` can be enabled on the existing database without rebuilding it.

**Evidence.** The proposal adds `archive_chunks.data BLOB` to the live database while saying there will be no rewrite of the 743 MB file, then proposes enabling incremental auto-vacuum (`review-handoff/round2-context.md:71-79,101-105`). Current Engram has no active `auto_vacuum` setup; its only disk-return path is full `VACUUM`, which is non-transactional and may require roughly twice the database size in free space (`macos/EngramCoreWrite/Database/EngramDatabaseWriter.swift:57-80`). SQLite's official documentation states that changing an existing database from `NONE` to `FULL` or `INCREMENTAL` requires `VACUUM`, and `incremental_vacuum` is ineffective unless incremental auto-vacuum was enabled first (<https://sqlite.org/pragma.html#pragma_auto_vacuum>, <https://sqlite.org/pragma.html#pragma_incremental_vacuum>). **[competitor-source: CASS]** CASS keeps exact-source objects in a sharded file CAS with separate manifests (`CASS@8110944:src/raw_mirror.rs:778-932,1109-1194,1471-1533`). Engram's current remote backend already uses a file-backed object pattern (`macos/EngramRemoteServer/Core/BlobStore.swift:10-69`).

**Suggested change.** Use a dedicated file CAS plus manifest/reference tables in SQLite. Publish files via temporary write, fsync, hash verification, and exclusive create/atomic rename; commit the manifest only after the object is durable. A new dedicated `archive.sqlite` is the fallback if transactional BLOB behavior is proven necessary; configure auto-vacuum before its first table. Do not enlarge the current index DB before measuring WAL, backup, corruption-domain, and large-object behavior.

### 6. HIGH — the ingestion pipeline compresses ciphertext

**Claim.** The documented order `encrypt → LZFSE/zstd` is technically wrong; authenticated ciphertext is intentionally incompressible, and under client-held encryption the server cannot dictionary-compress plaintext it never sees.

**Evidence.** The sequence is explicit in the round-1 synthesis (`review-handoff/round2-context.md:91-95`), and Phase 3 is later described as unchanged (`review-handoff/final-decision-memo.md:83-89`).

**Suggested change.** Use `exact raw bytes / reversible externalization → content ID over canonical plaintext → compress → encrypt`. Authenticate the codec, chunker version, sizes, and content ID as header/AAD. Verify by decrypting, decompressing, and recomputing the canonical content ID. Measure LZFSE/zstd and payload externalization before choosing chunk size or server capacity.

### 7. HIGH — `skip` and subagent are being used as data-loss policy

**Claim.** Search quality classification is incorrectly coupled to durability. “Never archive skip/subagent” means the archive-of-record deliberately excludes the majority tier and unique delegated work.

**Evidence.** Round 1 says `skip`/subagent are never archived (`review-handoff/round2-context.md:89-95`). Current tiering assigns any agent role or `/subagents/` path to `skip`, and offload excludes both (`macos/Shared/EngramCore/Indexing/SessionTier.swift:3-20`; `macos/EngramCoreWrite/RemoteSync/OffloadPolicy.swift:45-56`; `macos/EngramCoreWrite/RemoteSync/OffloadRepo.swift:422-444`). The sizing cluster reports 26,222 `skip` sessions (`review-handoff/round2-clusters.md:249-259`), while the final D2 table gives skip a 90-day local window, implicitly requiring a durable copy elsewhere (`review-handoff/final-decision-memo.md:62-69`).

**Suggested change.** Separate `archive_eligibility` from search/embedding/display tier. Capture every exact source by default, including parent and subagent files, except explicit content-policy exclusions and proven disposable probes. `skip` may control FTS noise, semantic eligibility, UI visibility, and hot residency; it must not silently mean “discard the only body.”

### 8. HIGH — the delivery plan did not absorb its own simplicity critic

**Claim.** The main Phase 1 still bundles local CAS, remote server encryption, B2, Litestream, delete-gate machinery, server FTS, `get_decisions`, monitoring, and a restore drill, while the appended critic correctly says the safest useful v1 deletes nothing and defers search/mining/reclaim machinery.

**Evidence.** The main delivery plan is a large remote/durability/search bundle (`review-handoff/final-decision-memo.md:83-89`). The critic explicitly says all deletion/reclaim should be deferred, N2 and N7 are not archive prerequisites, and the main memo under-emphasizes the never-delete boundary (`review-handoff/final-decision-memo.md:103-133`). This is not merely prose: an ambiguous phase boundary risks shipping dormant-but-callable delete paths before their safety chain is complete.

**Suggested change.** Make the release gates explicit:

1. **v1a:** local exact-source capture, verify, replay, and `get_session` fallback; no unlink, local eviction, server GC, or delete command.
2. **v1b:** immutable offsite backup with independent key recovery and backup-epoch restore drill; still no deletion.
3. **v2:** optional remote cold reads and FTS federation.
4. **v3:** source deletion/local eviction only after generation-bound gates, reference-aware GC, failure-injection tests, and successful restore drills.

Keep `get_decisions`, server semantic, analytics sidecars, and remote MCP expansion out of the archival critical path.

### 9. HIGH — compaction recovery and the claude-mem provenance claim are overstated

**Claim.** The package presents “exact compaction delta” and `session_id + chunk_hash` progressive disclosure as if their semantics were established. Neither the current Engram parser nor claude-mem provides that proof.

**Evidence.** Current Claude parsing only emits normalized user/assistant messages and ignores other record types (`macos/Shared/EngramCore/Adapters/Sources/ClaudeCodeAdapter.swift:477-505`); the tests confirm that a `summary` record plus `/compact` command yields no visible messages (`macos/EngramCoreTests/AdapterMessageCountTests.swift:1044-1071`). **[competitor-source: claude-mem]** claude-mem does wire `search`, `timeline`, and batch `get_observations`, but dispatches them independently; timeline is optional, and results are observation IDs rather than archive chunk hashes (`claude-mem@312d640:src/servers/mcp-server.ts:437-531,869-898`; `claude-mem@312d640:docs/public/usage/search-tools.mdx:166-176,208-217`). Its local worker explicitly treats provider JSONL as the durable source and truncates observer tool content (`claude-mem@312d640:src/services/worker/SessionMessageBuffer.ts:21-40`; `claude-mem@312d640:src/sdk/prompts.ts:85-152`). **[competitor-source: AgentsView]** AgentsView provides a more concrete progression: ranked snippet with message ordinal → cheap session overview → bounded ordinal slice/around, with hard response caps (`AgentsView@02772c7:internal/mcp/server.go:63-112`; `AgentsView@02772c7:internal/mcp/shape.go:13-42`).

**Suggested change.** First define and fixture-test Claude compaction events, the pre/post boundary, and what “evicted” means for summaries, tool results, thinking blocks, and incomplete JSONL tails. Until that passes, call the feature “pre-compaction context retrieval,” not exact delta recovery. Adopt independent compact search, optional timeline/overview, and batch exact fetch. Cite raw object hash plus byte/ordinal range and transform version; if egress redaction changes returned bytes, also return a view hash rather than implying the raw chunk hash verifies the transformed response.

### 10. HIGH — the headline sizing mixes measurements, locator failures, and unmeasured scenarios

**Claim.** The reclaim arithmetic is usable, but “1.648 GB already lost,” “3.1–3.6 GB/month ingest,” and the 72 GB floor are stronger claims than their evidence supports.

**Evidence.** The evidence script checks only whether each recorded `file_path` currently exists (`review-handoff/round2-clusters.md:402-410`). That proves `missing-at-recorded-locator`, not absence from archive directories, moved paths, duplicate content, Time Machine, or other backups; current Codex discovery itself scans both `sessions` and `archived_sessions` (`macos/Shared/EngramCore/Adapters/Sources/CodexAdapter.swift:628-633`). The growth estimate groups current files by last modification month, not a longitudinal ingest ledger (`review-handoff/round2-clusters.md:341-350,409`). The package's own number review says 258 GB does not reproduce from the stated inputs (`review-handoff/round2-clusters.md:419-421`). The 72 GB floor assumes approximately `1.8×` compression and `2×` dedup without a corpus measurement (`review-handoff/round2-clusters.md:345-350`).

**Suggested change.** Relabel and separate:

- **Measured:** 1,158.1 MB reclaim under D2 (about 1.158 decimal GB / 1.131 GiB) and 3,513.8 MB under strict 90 days.
- **Observed but not proven loss:** 1,648 MB missing at stored locators; run a content-hash search across known provider archive roots and backups before calling it irrecoverable or ongoing.
- **Mtime-attributed stock:** 3.1–3.6 GB/month over the selected three months; do not call it an ingest rate until a capture ledger records new bytes.
- **Scenario model:** raw five-year incremental range is 232.5–270 GB from `3.1–3.6 × 60 × 1.25`; 258 GB corresponds to an unstated 3.44 GB/month midpoint. The 71.7 GB floor remains `UNVERIFIED` until compression and dedup are measured.

Capacity planning must also add the existing corpus and Object-Lock/version/snapshot overhead. A 300 GB backup is only about 1.16× the stated 258 GB incremental point and is not a credible WORM target ceiling.

## Competitor source deep-dives

### CASS (`coding_agent_session_search`)

#### a) Schema and chunking

CASS has three distinct layers: normalized SQLite conversations/messages/snippets, rebuildable lexical/semantic indexes, and a separate exact-source raw mirror (`CASS@8110944:src/storage/sqlite.rs:4867-4876,4915-4985`; `CASS@8110944:src/search/query.rs:3-31`; `CASS@8110944:src/raw_mirror.rs:778-932`). Its strongest idea is pre-parse capture: unknown or future parser records survive, and a manifest retains provider, source/origin, original-path identity, full digest, database links, and verification state (`CASS@8110944:src/indexer/mod.rs:24097-24167,24202-24234`; `CASS@8110944:src/raw_mirror.rs:801-825,877-929`). That is better than making parsed message chunks the sole canonical form.

It is not a drop-in archive design. The mirror is whole-file, so every append can create a mostly duplicate new blob; compression and encryption are currently `none`; fsync is optional; and capture/link failures are warnings rather than archival blockers (`CASS@8110944:src/raw_mirror.rs:24-28,909-919,1685-1716`; `CASS@8110944:src/indexer/mod.rs:24393-24434,24938-24959`). Engram should steal the exact-source layer and stable publication, not its best-effort durability policy.

#### b) Adapter coverage and drift

CASS's source contract is exactly 22 parse-capable factories, not an open-ended “22+”: aider, amp, antigravity, ChatGPT, Claude Code, Clawdbot, Cline, Codex, Copilot, Copilot CLI, Crush, Cursor, Factory, Gemini, Hermes, Kimi, OpenClaw, OpenCode, OpenHands, Pi Agent, Qwen, and Vibe (`CASS@8110944:tests/spec_connector_enumeration_completeness.rs:62-90`; `CASS@8110944:tests/agent_detection_completeness.rs:137-150`). Goose, Continue, and Windsurf are detection-only (`CASS@8110944:tests/agent_detection_completeness.rs:52-54,179-188`). Engram's current baseline is the 17 registered Swift source names/factories (`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-21`; `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:7-33`). After treating Copilot CLI as overlapping Engram's existing Copilot family, clear Engram gaps are Aider, Amp, ChatGPT, Clawdbot, Crush, Factory, Hermes, OpenClaw, OpenHands, Pi Agent, and Vibe. CASS is not a superset: Engram has iFlow, Qoder, Minimax, LobsterAI, Command Code, generic VS Code, and a parse-capable Windsurf adapter.

CASS pins parser implementations through `franken_agent_detection`, exact-set contract tests, and legacy/malformed/truncated fixtures (`CASS@8110944:src/connectors/mod.rs:1-44,200-222`; `CASS@8110944:Cargo.toml:84-92`; `CASS@8110944:tests/connector_copilot.rs:45-133,205-325`; `CASS@8110944:tests/connector_cursor.rs:149-336,371-401`). The external dependency's parser bodies were not separately cloned, so the fixture contracts are verified here, not every underlying implementation branch.

#### c) Retrieval and token efficiency

CASS defaults to hybrid search, adjusts lexical/semantic candidate ratios by query class, RRF-fuses results, and uses stable source/path/conversation/line/content dedup with deterministic tie-breaking (`CASS@8110944:src/search/query.rs:380-390,608-677,1808-2025,5752-5855`). Hybrid fails open to lexical with an explicit fallback reason unless strict semantic was requested (`CASS@8110944:src/lib.rs:22613-22617,22714-22757,22923-22957`). It supports field projection, lazy hydration, a max-token envelope, and a deterministic evidence-pack planner (`CASS@8110944:src/lib.rs:23198-23223,24566-24602`; `CASS@8110944:src/search/pack_planner.rs:57-85,791-977,1033-1075`). Do not copy its `chars / 4` estimate as a hard token guarantee (`CASS@8110944:src/search/pack_planner.rs:1339-1343`).

#### d) Archival/retention/delete gate

CASS treats its canonical archive database as the repair authority over derived indexes and refuses several coverage-shrinking repairs (`CASS@8110944:src/lib.rs:35110-35145,35180-35228,40330-40502`). It does **not** automatically age out provider originals and explicitly warns when CASS may be the sole archival copy (`CASS@8110944:src/lib.rs:31146-31163`). Raw-mirror prune is dry-run-first, has hold-down/pins/audit, and deletes a blob only when all referencing manifests are selected, but it does not prove backup freshness, independent copies, or restore receipts (`CASS@8110944:src/raw_mirror.rs:271-459,545-702`). This is useful reference-aware GC prior art, not a delete-gate precedent.

#### e) Original verdict

“Do not import its Rust runtime” is correct. “Mine only adapter lists and UX” is materially incomplete. The highest-value ideas are pre-parse exact-source capture, source-generation checks, versioned manifests, authority/repair states, lexical-floor hybrid fallback, and evidence budgets. CASS's whole-file duplication, optional fsync, best-effort capture, and weaker prune safety should not be copied.

### AgentsView

#### a) Schema and chunking

AgentsView stores normalized sessions, ordinal messages, tool calls/results, source UUIDs, compaction flags, parser-version/fidelity state, and provenance for derived recall (`AgentsView@02772c7:internal/db/schema.sql:2-103,217-282,314-376`). It has no raw-byte CAS; `archive_metadata` is only key/value metadata (`AgentsView@02772c7:internal/db/schema.sql:488-493`). Its model is better than the package for structured tool chronology and derived-memory provenance, but worse as a verbatim archive because parser normalization remains the durable content.

The provider boundary is especially strong: providers own source shape/identity, expose stable `SourceRef` and `SourceFingerprint`, and return explicit completeness/retry/data-version state (`AgentsView@02772c7:internal/parser/provider.go:69-94,155-198,269-349`). That is directly useful for Engram's format-drift and source-generation contracts.

#### b) Adapter coverage and drift

The original “29 sources” claim is outdated. The registry defines 50 source types (`AgentsView@02772c7:internal/parser/types.go:12-63`); the factory switch makes Claude.ai and ChatGPT import-only while the rest have provider factories (`AgentsView@02772c7:internal/parser/provider.go:393-507`). Against Engram's 17 registered Swift source names/factories (`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-21`; `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:7-33`), the clear provider-family gaps after obvious aliases are OpenClaude, Cowork, Kilo, OpenHands, Amp, Zencoder, Visual Studio Copilot, Pi/OMP, DeepSeek TUI, OpenClaw/QClaw, Kiro/Kiro IDE, Cortex, Hermes, WorkBuddy, Forge, Devin, Piebald, Warp, Positron/Posit Assistant, ZCode, Antigravity CLI, Vibe, Zed, QwenPaw, gptme, Shelley, Aider, Reasonix, and iCodemate; Claude.ai and ChatGPT add import surfaces. `mimocode` needs fixture-level comparison with Engram's Minimax family before being counted as a distinct gap.

Drift handling is stronger than a switch statement: provider capabilities and fingerprints, per-result `data_version`, future-version refusal, parse-diff tooling, and complete-line JSONL offsets are first-class (`AgentsView@02772c7:internal/parser/provider.go:69-94,269-349`; `AgentsView@02772c7:internal/db/db.go:250-316`; `AgentsView@02772c7:cmd/agentsview/parse_diff.go:51-69,165-194,258-282`; `AgentsView@02772c7:internal/parser/linereader.go:24-63,125-159`). Its OpenCode, Cursor, Windsurf, and Antigravity providers also cover multiple live/legacy storage shapes that merit fixture-by-fixture comparison rather than a source-name count.

#### c) Retrieval and token efficiency

AgentsView's MCP flow is concrete and enforceable at the response-shape level: ranked snippets include a `match_ordinal`; agents can request a cheap overview and then a bounded ordinal page/window (`AgentsView@02772c7:internal/mcp/server.go:63-112`). Default/max message counts and per-message character limits are explicit (`AgentsView@02772c7:internal/mcp/shape.go:13-42`). Search units distinguish user messages from assistant runs, retain stable source UUID/ordinal anchors, and combine candidate lists with RRF (`AgentsView@02772c7:internal/db/messages.go:420-463,510-560`; `AgentsView@02772c7:internal/vector/mirror.go:81-115`; `AgentsView@02772c7:internal/db/search_content.go:860-934,983-1019`). This is a better immediate model for Engram than inventing a compulsory timeline protocol.

#### d) Archival/retention/delete gate

The normalized SQLite archive is the product's source of truth, with orphan-safe rebuild/swap logic that preserves old rows when current provider coverage shrinks (`AgentsView@02772c7:internal/db/orphaned.go:27-40,141-168,194-225,701-822`; `AgentsView@02772c7:internal/sync/engine.go:1509-1574,1610-1676`). It does not provide raw transcript CAS or a durability-aware gate for deleting provider originals. Its prune behavior is therefore not evidence that Engram's proposed source deletion is safe.

#### e) Original verdict

“Separate Go product, no runtime import” remains correct. The source count and product characterization need updating, and the original research missed its most reusable engineering: provider contracts, stable fingerprints, data-version migration, parse-diff, orphan-safe rebuild, ordinal retrieval, response caps, and recall provenance.

### claude-mem

#### a) Schema and chunking

claude-mem's main local database stores sessions, observations, summaries, and prompts, not normalized transcript chunks (`claude-mem@312d640:src/services/sqlite/SessionStore.ts:478-543,697-714,743-775`). Hosted Postgres adds raw hook-event payloads, generation jobs, observations, and `observation_sources`; event ingestion and its async job are committed transactionally (`claude-mem@312d640:src/storage/postgres/schema.ts:169-256`; `claude-mem@312d640:src/server/services/IngestEventsService.ts:96-153`; `claude-mem@312d640:src/storage/postgres/observations.ts:199-290`). This is valuable provenance/outbox design, but hook-event payloads are not a complete, reassemblable transcript CAS. The local worker explicitly calls provider JSONL the durable source of truth (`claude-mem@312d640:src/services/worker/SessionMessageBuffer.ts:21-40`).

#### b) Adapter coverage and drift

Against Engram's 17 registered Swift source names/factories (`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-21`; `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:7-33`), the one clear new product source is OpenClaw; raw input and a schema-driven watcher are extension mechanisms, not additional products (`claude-mem@312d640:src/cli/adapters/index.ts:1-21`; `claude-mem@312d640:openclaw/src/index.ts:747-876`). The declarative transcript schema supports field paths, coalesce/default, predicates, and actions, while the watcher stores byte offsets and resets after truncation (`claude-mem@312d640:src/services/transcripts/types.ts:1-49`; `claude-mem@312d640:src/services/transcripts/field-utils.ts:67-99,116-170`; `claude-mem@312d640:src/services/transcripts/watcher.ts:43-82`). Configuration validation is shallow and malformed JSONL is skipped, so this belongs behind strict Codable validation and quarantine, not in place of Engram's typed core adapters (`claude-mem@312d640:src/services/transcripts/config.ts:64-77`; `claude-mem@312d640:src/services/transcripts/watcher.ts:277-300`).

#### c) Retrieval and token efficiency

The reading is only partially accurate. Search, timeline, and batch fetch exist, but each tool dispatches independently; timeline is optional, and there is no archive `chunk_hash` (`claude-mem@312d640:src/servers/mcp-server.ts:437-531,869-898`). Search is FTS **or** Chroma with fallback, not lexical+semantic RRF, and hydration can reorder semantic results (`claude-mem@312d640:src/services/sqlite/SessionSearch.ts:234-290`; `claude-mem@312d640:src/services/worker/SearchManager.ts:312-528`; `claude-mem@312d640:src/services/sqlite/SessionStore.ts:1624-1633`). Compact index rows, optional anchor timelines, and batch detail fetch are worth stealing; `chars / 4` token estimates and any “10×” claim are not verified guarantees (`claude-mem@312d640:src/services/worker/FormattingService.ts:30-48`; `claude-mem@312d640:src/services/context/TokenCalculator.ts:6-36`).

#### d) Archival/retention/delete gate

claude-mem does not age out original transcript files and has no backup-confirmed, never-last-copy gate. Hosted hard deletion is scoped erasure, not durability-aware aging (`claude-mem@312d640:src/storage/postgres/data-deletion.ts:21-53`; `claude-mem@312d640:src/server/routes/v1/ServerV1PostgresRoutes.ts:1065-1113`). It is not delete-gate prior art.

#### e) Original verdict

“Extraction-first” is directionally right but incomplete because hosted storage now retains hook events and provenance. “Three-layer progressive disclosure” is a recommended UX, not an enforced protocol. “Learn from design only” is correct. The package missed the transactional event/outbox pattern, source provenance, OpenClaw, the generic watcher, content truncation, and the actual non-RRF search behavior.

### Gentleman-Programming/engram

#### a) Schema and chunking

This product stores curated sessions, observations, prompts, FTS rows, and sync mutations—not provider transcripts (`Gentleman-Engram@be4b613:internal/store/store.go:79-141,695-802`). Sync exports append-only gzip JSON chunks plus a manifest and applies dependency-safe imports (`Gentleman-Engram@be4b613:internal/sync/sync.go:1-19,74-97,427-500,505-639`). Its chunk ID truncates SHA-256 to eight hex characters—32 bits—and must not be copied for archival identity (`Gentleman-Engram@be4b613:internal/cloud/chunkcodec/chunkcodec.go:13-16`). The schema is not better than `archive_chunks + session_archive` for verbatim data; it solves a different, curated-memory problem.

#### b) Adapter coverage and drift

The repository integrates MCP/instruction surfaces for OpenCode, Pi, Claude Code, Gemini CLI, Codex, Antigravity, Windsurf, Qwen, Kiro, Cursor, VS Code Copilot, and KiloCode (`Gentleman-Engram@be4b613:internal/setup/agents.go:15-163`). These are setup adapters, not transcript parsers. Compared with Engram's 17 registered Swift source names/factories (`macos/Shared/EngramCore/Adapters/SessionAdapter.swift:3-21`; `macos/Shared/EngramCore/Adapters/SessionAdapterFactory.swift:7-33`), Pi, Kiro, and KiloCode are useful coverage leads, but the source does not prove it can parse their histories. There is therefore no parser drift strategy to port from this layer.

#### c) Retrieval and token efficiency

Search checks an exact `topic_key` before FTS and supports all/any modes and result limits (`Gentleman-Engram@be4b613:internal/store/store.go:3102-3203`). MCP returns short search previews, optional bounded timeline context, and full observation fetch (`Gentleman-Engram@be4b613:internal/mcp/mcp.go:959-1138,1741-1845`). This validates the preview → optional context → full record interaction, but over curated observations rather than raw transcript chunks.

#### d) Archival/retention/delete gate

Its SQLite database is the source of truth for curated memory and its sync stream carries mutations/tombstones. Session deletion is blocked by dependent observations; prompts and observations have explicit hard/soft delete mutation handling (`Gentleman-Engram@be4b613:internal/store/store.go:2728-2847,2937-2989`). There are no original provider logs to age, no raw CAS, and no backup/durability gate. Tombstones and dependency-safe import ordering are reusable; the design is not precedent for deleting transcripts.

#### e) Original verdict

The name collision is real. “Near-identical cross-agent memory concept” is overstated: this is curated persistent memory distributed through agent integrations, not a session aggregator or verbatim archive. Its retrieval UX, mutation/tombstone ordering, and compact sync chunks are useful design references, but it should not influence Engram's archive schema or adapter count.

## Headline-number sanity check

| Claim | Adjudication | Recalculation / limitation |
|---|---|---|
| `~1.11 GB` under 90d plus normal/premium forever | **CONFIRMED** | `1107.1 + 1.5 = 1108.6 MB` from `round2-clusters.md:327-338`. |
| `~1.1–1.2 GB` under final D2 | **CONFIRMED** | `1107.1 + 1.5 + 4.0 + 45.5 = 1158.1 MB` = 1.158 decimal GB / 1.131 GiB. |
| strict 90-day `3.51 GB` | **CONFIRMED** | `1107.1 + 1.5 + 16.3 + 4.0 + 2339.4 + 45.5 = 3513.8 MB`. |
| `1,648 MB / 2,755 sessions already lost, ongoing` | **OVERCLAIM** | Confirmed only as DB rows whose stored locator did not exist. No archive-root/content-hash/backup search was performed. |
| `3.1–3.6 GB/month measured ingest` | **PARTIAL** | Arithmetic is reproducible from three current-file mtime buckets, but mtime is not ingest time and rewrites reattribute an entire file. |
| five-year `258 GB` | **PARTIAL** | Within the stated raw range, but not derived transparently: `3.1–3.6 × 60 × 1.25 = 232.5–270 GB`; 258 implies 3.44 GB/month. Existing corpus and versioned-backup overhead are not added. |
| five-year `~72 GB` floor | **UNVERIFIED** | `258 / 1.8 / 2 ≈ 71.7`, but both compression and dedup factors are assumptions awaiting the proposed spike. |
| 500 GB primary is `2×` the 258 GB ceiling | **FALSE AS STATED** | `500 / 258 = 1.94×` before existing data, indexes, WAL, snapshots, or safety reserve. |
| 300 GB backup is sufficient | **UNSUPPORTED** | Only 1.16× the stated 258 GB incremental point; Object Lock versions and metadata snapshots need additional capacity. |

## Decisions I would keep, change, or defer

| Decision | Review ruling | Reason |
|---|---|---|
| Build the archival boundary in Swift/GRDB | **Keep** | All four competitors are separate products and none closes Engram's exact-source plus delete-gate requirements. |
| SQLite BLOB CAS in current `index.sqlite` | **Change** | Use a file CAS with SQLite manifests/reference state; isolate irreplaceable bytes from the regenerable index. |
| Tailscale Serve only, no Funnel | **Keep** | Appropriate exposure boundary for a solo private deployment, provided bearer authorization remains mandatory on every read path. |
| Defer server semantic/ANN | **Keep** | Correct scope cut. The archive and exact keyword/ordinal retrieval must be trustworthy first. |
| Bounded hot window | **Keep later** | A size/window bound is sensible only after a verified remote generation exists. v1 should have no eviction. |
| Heuristic-first `get_decisions` | **Defer** | Regex decisions are low-confidence product behavior, not archive infrastructure; ship it only with provenance and explicit confidence. |
| `recover_compaction` / exact delta | **Prototype first** | Requires provider-format fixtures and byte/ordinal semantics before it can be promised as exact. |
| Archive-everything default + WORM backup | **Change default for remote** | Local exact capture may default on; irreversible remote replication should be policy-gated per project until exclusion/erasure semantics are proven. |

The systematic missing perspective is **source-generation and recovery semantics**. The package is strong at synthesizing components and policies, but repeatedly treats labels (`content-addressed`, `backed_up_at`, `verbatim`, `RPO=0`) as if they were proofs. Competitor source exposed the implementation-level questions the synthesis skipped: what exact bytes are canonical, which generation was copied, whether an object can be overwritten, what transaction the backup contains, which key survives the disaster, and how a parser upgrade is replayed. Governance also needs a deletion/erasure design before immutable third-party replication; egress redaction does not solve at-rest retention of excluded material.

Two package-hygiene corrections should also be made: `N5` is declared unaddressed in `final-decision-memo.md:43` but no `N5` exists in the registry at `round2-context.md:177-204`; and the main decision table should not be treated as the final plan while its appended critic materially contradicts its Phase 1 boundary.

## Prioritized steal list for Swift

1. **Exact-source capture before parse** — stable identity checks, symlink refusal, changed-during-copy rejection, temp publication, exclusive create, existing-object rehash, and a self-hashed manifest. `CASS@8110944:src/raw_mirror.rs:778-932,982-1194,1489-1533`; wiring at `CASS@8110944:src/indexer/mod.rs:24097-24167,24202-24234`.
2. **Authority matrix and source-preserving repair** — explicitly classify live source, exact raw mirror, normalized archive, remote backup, and derived indexes as authoritative/candidate/refused for each repair. `CASS@8110944:src/lib.rs:35110-35228,40330-40502`; `AgentsView@02772c7:internal/db/orphaned.go:27-40,141-225,701-822`.
3. **Provider contracts with stable identity and drift versioning** — Swift protocol equivalents of capabilities, `SourceRef`, `SourceFingerprint`, completeness, retry state, and parser data version. `AgentsView@02772c7:internal/parser/provider.go:69-94,155-198,269-349`.
4. **Registry exact-set and format-matrix tests** — current/legacy/malformed/truncated fixtures per provider, plus a test that every registered source has a factory and documentation. `CASS@8110944:tests/spec_connector_enumeration_completeness.rs:62-90`; `CASS@8110944:tests/agent_detection_completeness.rs:137-188`; `AgentsView@02772c7:cmd/agentsview/parse_diff.go:51-69,165-194,258-282`.
5. **Complete-line incremental JSONL boundaries** — persist byte offset only through the last complete line and force full parse on fingerprint/data-version mismatch. `AgentsView@02772c7:internal/parser/linereader.go:24-63,125-159`.
6. **Compact search → cheap overview/optional timeline → exact ordinal slice** — bounded defaults, max per-message bytes/chars, stable ordinals, and explicit truncation flags. `AgentsView@02772c7:internal/mcp/server.go:63-112`; `AgentsView@02772c7:internal/mcp/shape.go:13-42`; `claude-mem@312d640:src/servers/mcp-server.ts:437-531`.
7. **Derived-memory provenance** — link every decision/summary to raw object hash, byte/ordinal range, extractor version, and transform version. `AgentsView@02772c7:internal/db/schema.sql:314-376`; `claude-mem@312d640:src/storage/postgres/observations.ts:199-290`.
8. **Transactional event plus outbox** — commit archive metadata/idempotency record and optional extraction job together; publish the job only after commit. `claude-mem@312d640:src/server/services/IngestEventsService.ts:96-153`; `claude-mem@312d640:src/storage/postgres/agent-events.ts:142-180`.
9. **Lexical floor with explicit semantic fallback and evidence budget** — query-class candidate ratios, RRF, stable dedup, projection/lazy hydration, realized-mode/fallback reason, and deterministic evidence packs. `CASS@8110944:src/search/query.rs:380-390,608-677,1808-2025`; `CASS@8110944:src/search/pack_planner.rs:57-85,791-1075`. Replace `chars/4` with tokenizer/serialized-envelope tests.
10. **Reference-aware GC, dry-run, and audit only after deletion is armed** — never delete a blob while any manifest references it; pin/hold-down and produce an audit record. `CASS@8110944:src/raw_mirror.rs:271-459,545-702`. Add Engram's stronger generation, backup-epoch, independent-copy, and restore gates.
11. **Mutation/tombstone ordering and dependency-safe import** — useful for future multi-device metadata sync, but use a full cryptographic digest rather than the competitor's 32-bit chunk ID. `Gentleman-Engram@be4b613:internal/store/store.go:2728-2847,2937-2989`; `Gentleman-Engram@be4b613:internal/sync/sync.go:505-639`; unsafe ID at `Gentleman-Engram@be4b613:internal/cloud/chunkcodec/chunkcodec.go:13-16`.
12. **Coverage leads, not runtime dependencies** — prioritize OpenClaw, Aider, Amp, OpenHands, Pi, Kiro, and KiloCode after fixture validation. Sources: CASS factory contract, AgentsView registry/factories, claude-mem OpenClaw hook, and Gentleman setup registry cited above.

## Required gates before proceeding beyond capture-only

1. A fixture proves arbitrary source bytes—including CRLF/BOM, unknown records, malformed/truncated tail, images/base64, and multi-file sessions—round-trip byte-identically.
2. Capture and unlink are bound to one source generation and survive append/replace/symlink/race failure injection.
3. The server object namespace is immutable and self-verifying; key/content mismatch and overwrite attempts fail.
4. A clean-machine restore succeeds from one named backup epoch plus independently recovered key material.
5. The backup receipt proves its metadata transaction references only verified blobs in that same or earlier durable generation.
6. No source deletion, local eviction, or remote GC is reachable in v1a/v1b.
7. Real capture-ledger data replaces mtime growth, compression, dedup, and missing-locator assumptions before capacity or reclaim policy is finalized.

With those changes, the architecture is worth pursuing. Without them, it is an index/offload extension described as an archive, and its deletion promises are unsafe.
