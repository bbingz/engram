# Engram Full-Project Audit Report

**Date:** 2026-06-28
**Scope:** Full read-only audit of the Engram codebase — native macOS SwiftUI app + Swift `EngramService`/`EngramMCP` runtime (product), plus TypeScript reference/dev tooling.
**Method:** 3-phase workflow. Phase 0–1 (recon + architecture mapping, main agent). Phase 2 (16 module-reviewer subagents in 4 batches of 4, read-only deep audit, structured findings). Phase 3 (cross-cutting synthesis, main agent).
**Coverage:** 16 modules, ~104K LOC Swift + ~33K LOC TS reviewed. 118 findings. 1.5M subagent tokens, 506 tool calls.

## 1. Executive Summary

Engram is architecturally sound and notably disciplined for a single-maintainer project: a clean app→service→writer separation, defense-in-depth IPC security (capability token + peer-euid + 0700/0600 mode bits + slow-loris deadlines), idempotent migrations, and a well-structured project-move pipeline with undo/recovery. The security *model* is strong.

The audit found **1 critical, 7 high, 20 medium, 87 low, 3 info** issues. The dominant theme is **untrusted-input hardening**: on-disk session files from 17 external AI tools are the trust boundary, and several parser/IPC paths crash or leak on crafted input. The single critical finding (VS Code mutation-log replay) is an OOM/stack-overflow DoS reachable from any indexed VS Code session file. Two high-severity MCP integer-overflow crashes and two high-severity adapter OOM paths share the same root cause: numeric/path inputs from untrusted files reach arithmetic or allocation without bounds.

Two high-severity issues are directly exploitable by a local attacker who can plant a session file or a remote-sync manifest: **path traversal in `LocalDirectoryBackend`** (arbitrary file read via crafted peer manifest `remoteKey`) and **command injection in `RepoDetailView`** (AppleScript `do script` with under-escaped repo path from untrusted `cwd`).

No findings indicate data-loss in normal operation today; the latent data-loss path (FTS rebuild wiping embedding tables without re-enqueueing) is inert until sqlite-vec ships.

**Health scores per module range 68–86** (median ~78). The weakest module is `write-indexing` (68) due to write-gate contention and error-isolation gaps in the index scan.

## 2. Architecture Overview

```
Engram.app (SwiftUI, menu bar + window)
  └─► Shared/Service (EngramServiceClient) ──framed JSON over Unix socket──► EngramService
       EngramService owns: schema, indexing, maintenance, project-move, remote-sync, web UI
         ├─► EngramCoreWrite  ─► Shared/EngramCore  (schema, migrations, indexer, writer)
         ├─► EngramCoreRead   ─► Shared/EngramCore  (GRDB read repos)
         └─► Shared/Service   (protocol, capability token)
EngramMCP (stdio helper) ─► Shared/Service, EngramCoreRead, Shared/EngramCore, Shared/MCP
EngramRemoteServer ─► EngramCoreWrite/RemoteSync (local backend + HTTP blob store)
```

**Trust boundaries:**
- On-disk session files (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.gemini/`, etc.) — **untrusted**. Parsed by 15 Swift adapters.
- Unix service socket — bounded to current user via peer-euid + 0600 capability token file.
- Remote sync store (NAS mount / multi-Mac) — peer manifests are **untrusted**.
- MCP stdio — tool args come from the AI client, which may be prompt-injected by untrusted session content.
- Web UI (opt-in) — local bind, Host/CORS allowlist, bearer auth for mutating `/api/*`.

## 3. Findings by Module

### Critical & High (full detail)

| # | Sev | Module | File:Line | Issue |
|---|-----|--------|-----------|-------|
| 1 | 🔴 CRITICAL | adapters-rest | `Shared/EngramCore/Adapters/Sources/VsCodeAdapter.swift:191` | VS Code mutation-log replay (`setting()`/`pushing()`) pads an array to an unbounded attacker-controlled index (`while array.count <= index`) and recurses without depth limit. A crafted single entry `{"kind":1,"k":[9999999999],"v":"x"}` OOM-kills the indexer; a 100k-deep path stack-overflows. Reachable from any indexed VS Code session file. Existing tests only cover string paths. |
| 2 | 🟠 HIGH | service-web-remote | `EngramCoreWrite/RemoteSync/RemoteStorageBackend.swift:46` | `LocalDirectoryBackend.get(key:)` builds `root.appendingPathComponent(key)` with **no key validation**; `key` is the attacker-controlled `remoteKey` from a peer manifest. `appendingPathComponent` does not collapse `..`. Arbitrary file read + OOM on huge traversal target. HTTP backend validates (`BlobStore.validate`); local backend does not — direct asymmetry. |
| 3 | 🟠 HIGH | mcp | `EngramMCP/Core/MCPDatabase.swift:827` | `get_context` `max_tokens` has no schema max; `maxTokens * 4` overflows `Int` and traps the MCP helper. Reachable via prompt-injected tool call from untrusted session content. |
| 4 | 🟠 HIGH | mcp | `EngramMCP/Core/MCPTranscriptReader.swift:33` | `get_session` `page` has no schema max; `(page-1)*50` overflows `Int` and traps. Same reachability as #3. |
| 5 | 🟠 HIGH | adapters-major | `Shared/EngramCore/Adapters/Sources/GeminiCliAdapter.swift:219` | `readSidecar()` does `Data(contentsOf:)` with no size cap, bypassing the 100MB `prepareFile` guard that protects session files. Multi-GB sidecar → jetsam kill. |
| 6 | 🟠 HIGH | adapters-major | `Shared/EngramCore/Adapters/Sources/CopilotAdapter.swift:362` | Copilot aux files (`workspace.yaml`, `index.md`, checkpoint `.md`) read via `String(contentsOf:)` with no cap; `checkpointBody` loads full file then truncates. Same OOM class as #5. |
| 7 | 🟠 HIGH | app-models | `Engram/Models/ReplayState.swift:96` | `densityBuckets` clamps upper bound only; out-of-order timestamps (parsed from untrusted files, ordered by adapter index not time) yield negative `bucket` → index-out-of-bounds crash on `@MainActor` replay view. Service-side counterpart already clamps with `max(0,...)`. |
| 8 | 🟠 HIGH | app-views-2 | `Engram/Views/Workspace/RepoDetailView.swift:58` | Command injection: `repo.path` (from untrusted session `cwd`) interpolated into AppleScript `do script "cd \"\(safePath)\" && claude"`. `escapeForAppleScript` only escapes `\` and `"` — not shell metacharacters (`$(`, backticks). `cwd="$(rm -rf ~)"` executes on click. The correct helper (`appleScriptCommandLine`) exists but is bypassed. |

### Module roll-up (health, finding count, top themes)

| Module | Health | # | Top themes |
|--------|-------:|--:|------------|
| write-database | 86 | 5 | FTS-rebuild embedding-wipe latent path; startup full-scan UPDATE; resume branch untested; status CHECK missing |
| write-indexing | 68 | 11 | Write-gate held across async file I/O (user write timeouts); CancellationError swallowed; scan-abort isolation; side-table savepoint gaps; backfill starvation |
| service-core | 80 | 7 | Log sanitizer ordering hole; unbounded write-gate wait; protectedCommands set drift; symlink bypass in memoryFile confinement |
| shared-service-ipc | 80 | 4 | Newline injection in resume rendering; token-file create→chmod window; connect() no timeout; FdBox cancellation race |
| service-web-remote | 72 | 8 | LocalBackend path traversal; commitRehydrated atomicity gap; no blob quota; OffloadRunner swallows Cancellation; auth-compare leaks token length |
| mcp | 72 | 9 | Int-overflow crashes (×2); unescaped LIKE in keywordSearch; `until` semantics inconsistency; cancelled call no response; get_memory loads all embeddings |
| adapters-major | 72 | 9 | Aux-file OOM (Gemini sidecar, Copilot aux); Gemini sidecar path traversal; ClaudeCodeSourceHintCache sync I/O in actor; counting drift |
| adapters-rest | 72 | 9 | **VS Code critical DoS**; messageCount parity drift (Qwen/CommandCode/Iflow/Qoder); OpenCode sizeBytes undercount; Qoder parent linking untested; Antigravity/Windsurf cache path traversal (gated) |
| project-move | 80 | 6 | GitDirty treats git-failure as clean; patchFileStreaming FD leak; temp-file permission window; MigrationLock stale-break race |
| app-core | 74 | 13 | OSLogReader unbounded memory; unescaped LIKE (sparkline/timeline); sessionTimeline no LIMIT; retain cycle in launcher; MessageParser drops multi-part content |
| read-shared-logic | 78 | 9 | VectorMath truncation/divergent dimension checks; HumanDrivenFilter unparenthesized SQL; unstable tie-break in parent pick; CJK supplementary-plane miss |
| app-models | 76 | 2 | densityBuckets crash; unused PersistableRecord surfacing direct-write APIs |
| app-views-1 | 78 | 8 | TimelinePage error misattribution; ProjectsView eager list; TerminalLauncher logs cwd+args to world-readable /tmp; MemoryView stale insights |
| app-views-2 | 72 | 7 | AppleScript command injection; force-unwrap on titleBaseURL; settings.json TOCTOU; N+1 sparkline/cwd lookups; observability timer reload dedup gaps |
| app-components-onboarding | 84 | 9 | Onboarding stale source count; pulse ignores reduceMotion; HeatmapGrid input assumptions; ExpandableSessionCard swallows DB errors; duplicated relativeTime helper |
| ts-reference | 83 | 2 | FTS rebuild policy drift from Swift authority (3 ways); finalize schema-recovery divergence |

## 4. Cross-Cutting Issues

**4.1 Untrusted-input bounds checking is inconsistent.**
The codebase has the right primitives (`ParserLimits.validateFileSize`, `prepareFile`, 100MB cap, `escapeLike`, `appleScriptCommandLine`, `BlobStore.validate`) but applies them unevenly. Five of 8 high/critical findings are "the guard exists, this path bypasses it":
- VS Code replay: no index/path-depth bound (VsCodeAdapter).
- Gemini sidecar + Copilot aux files: bypass `prepareFile` size cap.
- LocalDirectoryBackend: bypasses `BlobStore.validate` key check.
- RepoDetailView: bypasses `appleScriptCommandLine` shell escaping.
- MCP `max_tokens`/`page`: no schema `maximum`.
**Pattern fix:** a single audit pass to route all untrusted-file reads through `prepareFile`, all untrusted path components through a shared `RemoteStorageKey.validate`, all shell-bound strings through `appleScriptCommandLine`, and all numeric tool args through schema `maximum`/clamping.

**4.2 Unescaped LIKE repeats across modules.**
`escapeLike`/ESCAPE is applied correctly in `sessionsForRepo` and `listSessions` but missing in `Database.sparklineData`/`projectTimeline` (app-core), `Database.getContext`, and `MCPDatabase.keywordSearch` (mcp). Underscore in directory names (`my_repo`) acts as a wildcard → over-matching sibling repos. One fix pattern, four call sites.

**4.3 CancellationError handling is asymmetric.**
`write-indexing` swallows `CancellationError` in backfill loops (blocks shutdown); `OffloadRunner` swallows it and charges a failure; `RemoteSyncCoordinator` re-throws it correctly. This blocks prompt service shutdown and distorts retry accounting. Standardize on re-throwing `CancellationError` before any failure accounting.

**4.4 Capability-token / protectedCommands set drift.**
`ServiceWriterGate.protectedCommands` is out of sync with mutating dispatch: `refreshUsage` (clears+rewrites usage snapshots) and `test.write_intent` acquire the write gate without requiring a capability token. The token is the documented defense-in-depth for destructive commands; these mutating paths bypass it.

**4.5 Temp-file permission window.**
A recurring pattern: create file (default umask, possibly world-readable) → `chmod` to source mode. Found in `JsonlPatch`, `GeminiProjectsJSON` (project-move) and the capability-token file (shared-service-ipc, though bounded by 0700 parent). For private session files this exposes a brief world-readable window. Use `FileManager.createFile(atPath:contents:attributes:)` with `.posixPermissions` set at creation, or write to a 0700 temp dir.

**4.6 Vector-math dimension handling diverges by consumer.**
`VectorMath.decode` silently truncates non-multiple-of-4 BLOBs; `MCPDatabase` guards dimensions, `EngramServiceReadProvider` does not. Corrupted embedding blobs degrade semantic search without error. Decide on one contract (reject vs clamp) and enforce at the decode boundary.

**4.7 TS reference drift from Swift authority.**
`src/core/db/fts-rebuild-policy.ts` diverges from `FTSRebuildPolicy.swift` in three ways (rebuild-table seeding, `size_bytes` reset, `reopenCompletedFtsJobs` gating). CLAUDE.md positions the TS file as a parity mirror; the drift can mislead anyone consulting it as source of truth. Either reconcile or document each divergence. (Session-tier and parent-link logic are at parity — no issues there.)

**4.8 Dependency versions (no CVE scanner run; versions noted for monitoring).**
Swift SPM: GRDB 6.29.3 (7.x is current; 6.x maintained), Hummingbird 2.20.1, async-http-client 1.32.0, swift-crypto 4.2.0, swift-certificates 1.18.0. TS: better-sqlite3 ^12.10, @grpc/grpc-js ^1.14.3, @modelcontextprotocol/sdk ^1.10.2, openai ^6.25, **sqlite-vec 0.1.9** (very old; reference-only, not shipped). No active CVE scanner was run as part of this audit; recommend a periodic `swift package audit` / `npm audit` cadence and upgrading sqlite-vec if the TS reference is revived.

## 5. Remediation Roadmap

### P0 — Fix immediately (exploitable / crash-on-untrusted-input)
1. **VS Code replay bounds** (VsCodeAdapter:191) — cap array index (reject >1e6) and path depth (reject >64); add crafted-input regression test. *Critical DoS.*
2. **LocalDirectoryBackend key validation** (RemoteStorageBackend:46) — add `RemoteStorageKey.validate` shared with `BlobStore.validate`; call at every backend entry point + defense-in-depth in `pullProject`.
3. **AppleScript command injection** (RepoDetailView:58) — replace inline script with `TerminalLauncher.appleScriptCommandLine(command:args:cwd:)`.
4. **MCP integer overflows** (MCPDatabase:827, MCPTranscriptReader:33) — clamp `max_tokens`/`page` and add schema `maximum`/`minimum`.
5. **Adapter aux-file size caps** (GeminiCliAdapter:219, CopilotAdapter:362) — route through `prepareFile`/`validateFileSize`; bounded read for `checkpointBody`.
6. **ReplayState.densityBuckets clamp** (ReplayState:96) — `max(0, min(99, ...))` + out-of-order timestamp test.

### P1 — High-leverage consistency & data-integrity
7. **Unescaped LIKE sweep** — apply `escapeLike`/ESCAPE in `Database.sparklineData`, `projectTimeline`, `getContext`, `MCPDatabase.keywordSearch`.
8. **CancellationError standardization** — re-throw before failure accounting in `write-indexing` backfills and `OffloadRunner`.
9. **Capability-token set sync** — require token for `refreshUsage` and `test.write_intent`, or document why they are exempt.
10. **GitDirty failure semantics** (GitDirty:71) — treat non-zero git exit as dirty (fail-closed) or surface an error; never silently bypass the destructive-move guard.
11. **commitRehydrated atomicity** (OffloadRepo:312) — add the `sync_version`/`offload_state` guard that `commitOffloaded` has.
12. **Log sanitizer ordering** (ServiceLogSanitizer:71) — run path regex before literal home-dir replace; cover non-`/Users` roots.
13. **Temp-file permissions** — create with `.posixPermissions` at write time across `JsonlPatch`/`GeminiProjectsJSON`/token file.

### P2 — Robustness & performance
14. **Write-gate contention** (write-indexing, service-core) — don't hold the gate across async file I/O in FTS drain; bound queued-write wait behind long commands.
15. **OSLogReader / sessionTimeline bounds** — cap memory and add LIMIT.
16. **Index-scan error isolation** (SwiftIndexer:84) — isolate `upsertFileIndexState` failures so one bad session doesn't abort the scan.
17. **VS Code / ProjectsView eager lists** — `LazyVStack`.
18. **VectorMath dimension contract** — pick reject-or-clamp, enforce at decode.
19. **HumanDrivenFilter SQL** — return parenthesized clause; eliminate string-replacement aliasing.
20. **FTS rebuild resume test** — lock the interrupted-rebuild contract with a test.

### P3 — Tech debt / parity
21. **TS FTS-rebuild-policy drift** — reconcile with Swift authority or document divergences.
22. **Duplicated helpers** — `relativeTime` (SessionCard vs ExpandableSessionCard), `escapeLike` call sites.
23. **Dead code** — `IflowAdapter.decodeCwd` (orphaned).
24. **Onboarding re-scan path**; **pulse `accessibilityReduceMotion`**; **messageCount parity** across Qwen/CommandCode/Iflow/Qoder adapters.

## 6. Highlights (what's done well)

- **IPC security model** is genuinely defense-in-depth: peer-euid check + per-launch 0600 capability token + 0700 runtime dir + 0600 socket + per-frame slow-loris deadlines. Few single-maintainer projects bother.
- **Project-move pipeline** has undo, recovery, migration log, lock, retry policy, and git-dirty guard — a serious destructive-operation design.
- **Migration discipline** — idempotent, version-gated (`swift_aux_schema_version`), per-table V2 rebuild pattern; FTS rebuild is version-gated and resume-aware.
- **Session-tiering / parent-detection** logic is at full TS↔Swift parity with no findings.
- **TS reference SQL is parameterized**, adapters close file descriptors in `try/finally`, sanitizer resets `regex.lastIndex` — the reference layer is clean.
- **Test coverage** on the happy paths of adapters, migrations, and project-move is substantial; the gaps found are specifically on untrusted-crafted-input and resume paths, not on core behavior.

---

*Generated by a 3-phase read-only audit workflow (16 parallel module reviewers). Findings are reviewer-assessed with confidence levels; P0 items were traced to concrete file:line by high-confidence reviewers. No production code was modified.*
