# Engram Security Audit — 2026-07-17

## Purpose

Completes the **security** slice deliberately excluded from the full-codebase
audit (`docs/reviews/2026-07-17-engram-full-audit.md`). That report covered
correctness, concurrency, read-parity, and CI; it deferred:

- Unix-socket / capability-token / peer-UID trust boundary
- ArchiveCredentialStore and HTTP replica TLS/auth posture
- Path traversal / TOCTOU in file operations
- `TerminalLauncher` AppleScript/shell escaping
- os_log privacy of transcript content
- `~/.engram` file permissions
- MCP prompt-injection / data-exfil relay surface

This document is the security closeout for that list.

## Methodology

| Layer | What |
|-------|------|
| Scope map | Product Swift surfaces only (app, EngramService, EngramMCP, CoreRead/Write ArchiveV2 + RemoteSync, EngramRemoteServer). TS reference is out of product runtime threat model. |
| Parallel review | Three independent read-only reviewers: (1) IPC trust boundary, (2) credentials + TLS + path confinement, (3) injection + log privacy + MCP relay. |
| Adversarial verify | Orchestrator re-checked every High/Medium claim against source and live `~/.engram` state on the owner machine. |
| Threat model | **T1** other local user · **T2** same-user local process / malicious MCP · **T3** network path to remote offload / archive replica · **T4** compromised replica with valid bearer |

**Outcome: 14 findings (0 critical / 2 high / 5 medium / 5 low / 2 info), 0 unverified in scope.** Several older injection claims (RepoDetailView AppleScript, unquoted resume shell) are **closed** in current code.

## Executive summary

**Cross-user local isolation is strong.** The service runtime directory is forced
to `0700` with owner checks, the Unix socket is `chmod 0600` after bind, every
accepted connection is `getpeereid`-gated to the service euid, and destructive
IPC commands require a per-launch 0600 capability token. Live check on this host
confirmed `~/.engram` `700`, `run/` `700`, `engram-service.sock` `srw-------`,
`cmd.token` `600`, `index.sqlite` `600`, `settings.json` `600`.

**Same-user is a trusted peer by design.** Any process running as the same euid
(including EngramMCP under Claude Code) can read the index/transcripts without a
token and can mutate after reading `cmd.token`. The token is defense-in-depth
against non-same-user reachability, **not** a per-client ACL between app and MCP.

**Network posture splits:** Archive V2 client transport is high quality
(ephemeral session, no cookies/proxy creds, redirect rejection, response size
caps, Tailscale-aware origin rules). Remote offload HTTP (`EngramRemoteBackend`)
is weaker: lexical “private host” checks without post-DNS resolve validation,
product default `remoteOffloadRequireTLS=false`, and `URLSession.shared` without
redirect/size guards. On this machine remote offload is **enabled** with
`http://100.x` Tailscale IPs and `requireTLS=false` — intentional for WireGuard
paths, but cleartext-on-tailnet is real if the tailnet assumption fails.

**No currently exploitable command-injection RCE** was found in TerminalLauncher /
RepoDetailView resume paths. The highest-value local residual is resume debug
logging to `/tmp/engram-terminal.log` (world-readable when present).

## Solid defenses (keep)

| Control | Location | Notes |
|---------|----------|-------|
| Runtime dir 0700 + owner + non-symlink | `UnixSocketEngramServiceTransport.secureRuntimeDirectory` | Creates/repairs; rejects wrong owner |
| Socket inode 0600 | `bindSocket` post-bind `chmod` | macOS does not honor `fchmod` on AF_UNIX fd |
| Peer euid gate | `UnixSocketServiceServer.peerIsAuthorized` | Fail-closed on `getpeereid` failure |
| Capability token on **all** mutators | `ServiceCapabilityToken.protectedCommands` | Full handler↔set audit: **no missing mutator** |
| Frame DoS bounds | 256 KiB frames, 30s whole-frame deadline, 32 clients, 10s SO_* | Slow-loris resistant |
| Project path confinement | `validateProjectPathConfined` | Home-bound, rejects HOME root, Keychains/`.ssh`/`.aws`, symlink escape; `force` does not relax |
| memoryFileContent bounds | `FileSystemEngramServiceReadProvider` H09 | Under `~/.claude/projects/*/memory/*.md`, 200 KiB cap, symlink leaf reject |
| Export confinement | `TranscriptExportService` | Under `~/.engram/exports`, symlink-ancestor checks, file 0600 |
| Settings/DB secure modes | `SecureSettingsFileWriter`, `SQLiteFileSecurity` | 0600 files, 0700 dirs |
| Archive V2 HTTP client | `HTTPArchiveReplicaBackend` | Ephemeral, redirect reject, final-URL match, body caps |
| Archive/remote server auth | `EngramRemoteServerApp.authorized` | Bearer + SHA-256 constant-time compare; archive bind restricted; distinct archive vs v1 secrets |
| Keychain for secrets | `ArchiveCredentialStore`, `KeychainSecretStore`, `RemoteCredentialStore` | Not in settings when migration succeeds |
| Shell → AppleScript escape order | `shellEscaped` then `escapeForAppleScript` | Single-quote POSIX shell quoting |
| os_log privacy | `EngramLogger`, `ServiceLogger` | Bodies `privacy: .private`; ring sanitizes for UI |
| MCP write fail-closed | `MCPToolRegistry` | Mutating tools need live service + capability token path |
| Transcript redaction default | `TranscriptRedactionPolicy` | `get_session` redacts unless `include_raw` |

## Findings

Severity scale: **Critical** = remote unauth RCE / cross-user data theft without local foothold; **High** = realistic compromise of secrets or data under product defaults or common config; **Medium** = exploitable with realistic conditions or clear defense gap; **Low** = residual / regression risk / same-user ease; **Info** = design note.

---

### High

#### SEC-H1. Remote offload HTTP host policy is lexical; default `requireTLS=false`

**Where:** `macos/EngramCoreWrite/RemoteSync/EngramRemoteBackend.swift:32–68`,
`macos/EngramService/Core/RemoteSyncCoordinator.swift:85–90`

**Claim:** When `backend=http` and `requireTLS` is false, plain HTTP is allowed to
hosts classified as “private” by **string** rules (RFC1918 / Tailscale CGNAT
literals, `.ts.net`, `.local`, **and any bare single-label name**). There is no
post-DNS check that the resolved A/AAAA is still private. Product default for
`remoteOffloadRequireTLS` is **false**. Client uses `URLSession.shared` with no
redirect rejection or response size caps (contrast Archive V2).

**Failure scenarios:**

1. Operator configures `http://myserver:8787` (bare label allowed). DNS resolves
   to a **public** address → Bearer token + session bundles travel cleartext on
   the public internet.
2. Hostile LAN / broken VPN with `requireTLS=false` → passive MITM of token and
   plaintext bundles (documented “trust the private path” tradeoff).
3. Redirect + Authorization header behavior of shared URLSession is unhardened
   relative to Archive V2.

**Live evidence (owner machine, 2026-07-17):**
`remoteOffloadEnabled=true`, `remoteOffloadBackend=http`,
`remoteOffloadRequireTLS=false`, server `http://100.125.101.60:8787` (CGNAT —
allowed). So the feature is in active use under the weaker default.

**Not critical because:** opt-in feature; public dotted names and public IPv4
literals are refused even with `requireTLS=false`.

**Fix (priority):** Prefer default `remoteOffloadRequireTLS=true`; after resolve
(or via connect metrics) require address ∈ loopback ∪ RFC1918 ∪ CGNAT/Tailscale;
drop bare single-label for HTTP; mirror Archive V2 ephemeral session + redirect
reject + size caps.

**Tests:** Origin unit tests exist; missing resolve-to-public negative case and
redirect tests.

---

#### SEC-H2. `ai-secrets.json` plaintext Keychain bridge without stop cleanup

**Where:** `macos/Engram/Core/EngramServiceLauncher.swift:87–133`

**Claim:** At service launch, AI API keys are copied from Keychain into
`~/.engram/run/ai-secrets.json` (0600) so the helper can read them. `cmd.token`
is unlinked on server `stop()`; **ai-secrets is not**.

**Failure scenario:** Same-user process (or backup that snapshots `run/`) reads
live or leftover `ai-secrets.json` and recovers `aiApiKey` / `titleApiKey` /
`embeddingApiKey` without going through Keychain ACL UX.

**Mitigations already present:** parent `run/` 0700 + owner check; file 0600;
cross-user blocked if home/runtime modes hold. Live host showed `ai-secrets.json`
`600` under `run/` `700`.

**Severity note:** High under T2 (same-user malware / careless shared-home tools);
Medium if T2 is considered “already owns the user.” Kept High because the file is
an easier scrape surface than Keychain and outlives a clean service intent.

**Fix:** Prefer XPC/Keychain for the helper; if the file bridge remains, shred on
stop/crash, exclusive create, document residual same-user risk.

---

### Medium

#### SEC-M1. Resume debug log at `/tmp/engram-terminal.log`

**Where:** `macos/Engram/Views/Resume/TerminalLauncher.swift` (~228–253)

**Claim:** Terminal/iTerm AppleScript source, Ghostty shell line, and Warp errors
are written to `/tmp/engram-terminal.log` via `write(toFile:atomically:)`. Typical
umask yields a **world-readable** file containing cwd, CLI path, and resume args
(session identifiers).

**Failure scenario:** Other local users read project paths and session IDs after
any resume launch (T1). Bypasses the entire os_log `privacy: .private` model.

**Not injection:** payloads are escaped before log/exec.

**Fix:** Delete the file log, or write under `~/.engram/` with 0600 via
`EngramLogger` only.

---

#### SEC-M2. `memoryFileContent` check-then-read without `O_NOFOLLOW`

**Where:** `macos/EngramService/Core/EngramServiceReadProvider.swift:169–210`

**Claim:** Path is confined under `~/.claude/projects/*/memory/*.md` with symlink
leaf checks and a 200 KiB cap, but the open is `String(contentsOf:)` after
validate — not `open(..., O_NOFOLLOW)` / openat as in `ArchiveTranscriptResolver`.

**Failure scenario:** Same-user who can write the memory tree races leaf or
intermediate path between check and open to exfiltrate another file’s content
through the IPC client (T2). Cross-user needs write into the victim tree.

**Tests:** symlink leaf and non-memory paths covered; race / O_NOFOLLOW not.

**Fix:** Copy ArchiveTranscriptResolver open discipline; re-check final path under
projects root after open.

---

#### SEC-M3. DEBUG / Keychain-failure plaintext API keys in `settings.json`

**Where:** `macos/Engram/Views/Settings/AISettingsSection.swift` (Keychain save
fallback), `SettingsIO.shouldBypassKeychain` (DEBUG / DerivedData)

**Claim:** When Keychain save fails or DEBUG bypass is on, API keys can remain
plaintext in settings JSON. Embedding migration is careful; shared `aiApiKey`
plaintext is still returned as-is by the embedding reader when not `@keychain`.

**Failure scenario:** Ad-hoc or DEBUG installs leave long-lived secrets on disk;
interrupted migration keeps recoverable plaintext by design.

**Mitigations:** secure 0600 settings writer; production path uses `@keychain`
(live host: `aiApiKey` / `titleApiKey` = `@keychain`).

**Fix:** Release fail-closed if Keychain set fails; keep DEBUG exception explicit
and never ship as Release default.

---

#### SEC-M4. Archive V2 optional cleartext HTTP to Tailscale IP literals

**Where:** Archive replica origin rules + live settings `remoteArchiveV2.replicas[].requireTLS=false` with `http://100.x:8787`

**Claim:** When `requireTLS=false`, cleartext HTTP to Tailscale CGNAT IPs is
allowed (`.ts.net` hostnames still require HTTPS). Server itself speaks plain HTTP
behind the “private/VPN or reverse-proxy TLS” model.

**Failure scenario:** Compromised tailnet node or broken WireGuard assumption →
archive bearer + object/manifest bytes visible on path (T3/T4 related).

**Not a coding bug** so much as an ops/threat-model acceptance. Live owner config
uses this path for both archive replicas and offload.

**Fix / ops:** Prefer HTTPS even on Tailscale; or document “tailnet compromise =
archive compromise” as accepted risk.

---

#### SEC-M5. MCP is a full same-user data-plane relay (by design residual)

**Where:** `macos/EngramMCP/Core/MCPToolRegistry.swift` — `get_session`,
`get_context`, `search`, `export`, project ops

**Claim:** Any MCP client the user attaches can page transcripts (default
redacted; `include_raw` opt-in), pull context, and — with live service + readable
token — mutate. No per-tool ACL, rate limit, or session allowlist.

**Failure scenario:** Malicious or prompt-injected model exfiltrates local AI
history through tool results (T2). Indirect prompt injection via stored
sessions/insights is classic agent-memory risk (SEC-L4).

**Mitigations that work:** write path fail-closed without service; capability
token; default redaction; page/size caps; peer euid on IPC.

**Fix (product):** document trust boundary; optional confirmation for
`include_raw`; optional session/project allowlists for MCP.

---

### Low

#### SEC-L1. Capability-token regression tests omit part of the mutator matrix

**Where:** `ServiceSecurityHardeningTests.testEveryMutatingCommandRequiresCapabilityToken`
vs full `protectedCommands` set

**Claim:** Production set is complete today (adversarial re-check: no mutator
missing). The socket-layer “wrong token never reaches handler” list is only a
subset; remote/archive mutators rely on scattered tests.

**Fix:** Generate the test list from `protectedCommands` itself.

---

#### SEC-L2. Peer-euid and socket-0600 lack direct behavioral unit tests

**Where:** `peerIsAuthorized`, `bindSocket` chmod

**Claim:** Runtime 0700 and token 0600 are tested; post-bind socket mode and euid
reject are not. Refactor could drop either and stay green.

**Fix:** Assert socket mode after bind; unit-test `peerIsAuthorized` with
`socketpair` where possible.

---

#### SEC-L3. `~/.engram` subdirs with world-traversable modes (live)

**Where:** live `~/.engram/cache`, `exports`, `probes` at **755** (2026-07-17)

**Claim:** Core secrets (DB, settings, run/) are 600/700, but group/other can
traverse some subtrees. Export files are forced 0600 when written by product
code; directory listing may still leak filenames.

**Fix:** Create cache/exports/probes at 0700; periodic repair similar to runtime
dir.

---

#### SEC-L4. Stored-session indirect prompt injection via MCP reads

**Claim:** Content returned by `get_session` / `get_context` / insights can steer
the current model. Redaction covers secret shapes only, not instruction
isolation.

**Fix:** Optional untrusted-content wrappers / strip patterns; product docs.

---

#### SEC-L5. Resume CLI binary chosen via service PATH

**Where:** `EngramServiceReadProvider` command locator

**Claim:** First executable named `claude`/`codex`/`gemini` on PATH wins. PATH
poisoning → resume launches attacker binary (not string injection).

**Fix:** Prefer fixed absolute paths or a curated allowlist of install locations.

---

### Info

#### SEC-I1. Same-user capability model is intentional

Token + socket do not isolate App from MCP. Document for security reviewers.

#### SEC-I2. No certificate pinning on Archive HTTPS

System trust only. Acceptable for MagicDNS/LE; no defense against user-installed
roots or trusted-CA compromise.

---

## Refuted / closed claims

| Claim | Disposition |
|-------|-------------|
| `hygiene` / `triggerSync` mutate without token | **False** — hygiene is read-only counts; triggerSync is a “not implemented” stub |
| Mutating command missing from `protectedCommands` | **False** — full set matches handler |
| RepoDetailView AppleScript path injection (historical HIGH) | **Closed** — uses `appleScriptCommandLine` |
| Unquoted resume shell / Ghostty single-argv footgun | **Closed** — shell-escaped line + tests |
| Cross-user can call unprotected `search`/`handoff` | **False** — blocked by dir + socket + euid before dispatch |
| Local IPC non-constant-time token compare is practical oracle | **Refuted** — other users cannot reach compare; same user can read token file |
| os_log `privacy: .public` product leak | **False** — no production `.public`; gated tests assert absence |

## Threat-model conclusions

| Actor | Practical risk |
|-------|----------------|
| **T1 other local user** | Well contained if `~/.engram` / `run` stay 0700 and socket 0600. Residual: world-readable `/tmp` resume log (SEC-M1), 755 subdirs (SEC-L3). |
| **T2 same-user / MCP** | Trusted peer: full read + mutate. Hardening is accidental-escape prevention and secret hygiene (SEC-H2, M3), not multi-tenant isolation. |
| **T3 network → offload HTTP** | Weakest **product** path once enabled (SEC-H1). Live config uses Tailscale IPs with TLS off. |
| **T3/T4 network → Archive V2** | Strong client transport; residual cleartext-on-tailnet when `requireTLS=false` (SEC-M4). Compromised replica with valid token is fully trusted by design. |

## Priority fix order

1. **SEC-M1** — remove or privatize `/tmp/engram-terminal.log` (small, high certainty).
2. **SEC-H1** — harden remote offload HTTP (default TLS, resolve-IP check, Archive-parity transport).
3. **SEC-M2** — `O_NOFOLLOW` open for `memoryFileContent`.
4. **SEC-H2** — lifecycle for `ai-secrets.json` (shred on stop / better bridge).
5. **SEC-M3** — Release fail-closed on Keychain write failure.
6. **SEC-L3** — 0700 for cache/exports/probes + repair.
7. **SEC-L1/L2** — expand IPC security regression tests.
8. **SEC-M5 / L4** — product docs + optional MCP allowlists / include_raw confirm.

## Coverage and residual limits

**Covered:** Unix-socket trust boundary; capability-token completeness; Keychain +
settings + runtime secrets; Archive V2 + remote offload + remote server auth/TLS
posture; project path confinement; memory/export path bounds; TerminalLauncher /
RepoDetailView injection; os_log + ServiceLogSanitizer; MCP write gates and
read/relay surface; live permission sample on owner machine.

**Not deep-dived:** full TOCTOU races inside ProjectMove multi-stage FS ops beyond
JsonlPatch CAS; EngramUITests harness security; third-party terminal apps’
handling of `do script` after we escape correctly; formal crypto review of
at-rest AES-GCM parameters beyond “uses CryptoKit + server key validation.”

**Relationship to full audit:** Correctness findings H1/H2/M12/M23 etc. remain in
`2026-07-17-engram-full-audit.md`. This file does **not** re-score them as
security unless they create a trust-boundary bypass (none of those did under the
models above).

---

*Security closeout for the 2026-07-17 Engram full audit. Source-backed review
with three parallel domain passes and orchestrator adversarial verification.
0 critical / 2 high / 5 medium / 5 low / 2 info.*

**Adjudication (same day):** independent source re-check of every High/Medium
claim — see `docs/reviews/2026-07-17-engram-security-audit-adjudication.md`.
Verdict: **APPROVED** as closeout; no fabricated findings; H1 is two issues
(bare-label DNS High + default TLS-off ops Medium); H2 High only if same-user
malware is in scope.
