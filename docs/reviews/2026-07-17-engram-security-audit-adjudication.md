# Adjudication: 2026-07-17 Engram Security Audit

**Target:** `docs/reviews/2026-07-17-engram-security-audit.md`  
**Method:** Source-grounded re-read of every High/Medium claim + live
`~/.engram` snapshot + solid-defense spot checks. No implementation.  
**Date:** 2026-07-17 (same day as report)

## Verdict summary

| Metric | Report | Adjudication |
|--------|--------|--------------|
| Finding count | 14 (0C / 2H / 5M / 5L / 2I) | **Confirmed** (IDs SEC-H1…I2) |
| Critical | 0 | **Agree** — no unauth remote/cross-user RCE in scope |
| High | 2 | **1 solid High, 1 High with severity softener** (see H2) |
| Fabricated findings | — | **None** |
| Closed injection claims | RepoDetail / unquoted shell | **Confirmed closed** |
| Overall trust | — | **Trustworthy**; ship as security closeout with the notes below |

---

## High / Medium claim table

| ID | Report severity | Verdict | Severity call | Evidence (primary) |
|----|-----------------|---------|---------------|-------------------|
| **SEC-H1** | High | **CONFIRMED** | Keep **High** for bare-label DNS footgun; live Tailscale config is a separate **ops Medium** | `EngramRemoteBackend.swift:32–68` lexical `isPrivateHost` includes bare single-label (`!h.contains(".")`); no resolve check; `URLSession.shared` for all methods; product default `?? false` at `RemoteSyncCoordinator.swift:89`. Live: offload **enabled**, `requireTLS=false`, `http://100.125.101.60:8787` (CGNAT literal — *not* the bare-label path). |
| **SEC-H2** | High | **CONFIRMED** | Prefer **Medium–High**; report already notes same-user caveat | `writeRuntimeAISecrets` writes 0600 JSON under `run/` (`EngramServiceLauncher.swift:95–133`). `UnixSocketServiceServer.stop` unlinks **token only** (lines 211–214). `stopIfOwned` / `stopProcessOnly` / `terminateProcess` do **not** delete `ai-secrets.json`. Live file present, mode **600**, parent **700**. Cross-user blocked if runtime perms hold. |
| **SEC-M1** | Medium | **CONFIRMED** | Keep Medium | `TerminalLauncher.swift:229,247,253,262` write/append `/tmp/engram-terminal.log` with full script/shell line. No 0600 enforcement. File absent on host right now → **latent** until next resume. |
| **SEC-M2** | Medium | **CONFIRMED** | Keep Medium (T2 race) | `EngramServiceReadProvider.swift:169–210`: symlink checks then `String(contentsOf:)` — no `O_NOFOLLOW`/`openat`. Bounds (memory tree + `.md` + 200 KiB) still hold for non-racy cases. |
| **SEC-M3** | Medium | **CONFIRMED** (residual) | Keep Medium; **not live on owner production path** | `AISettingsSection` Keychain-fail → plaintext JSON; `SettingsIO.shouldBypassKeychain` DEBUG/DerivedData. Live settings: `aiApiKey`/`titleApiKey` = `@keychain`. |
| **SEC-M4** | Medium | **CONFIRMED** | Keep Medium (accepted ops risk) | Archive origin allows HTTP only for Tailscale IP literals when `requireTLS=false` (`ArchiveReplicaBackend.swift:181–213`); hostname `.ts.net` requires HTTPS. Live replicas both `requireTLS=false` on `http://100.x`. **Stricter than H1** (no bare-label HTTP). |
| **SEC-M5** | Medium residual | **CONFIRMED** (design, not bug) | Residual OK; do not treat as defect fix gate | MCP `get_session` + `include_raw`; mutations need service socket (`MCPToolRegistry` `requiresServiceSocket` / `canReachEngramService`). Same-user trust model intentional. |

---

## Low / Info spot checks

| ID | Verdict | Notes |
|----|---------|-------|
| **SEC-L1** | **CONFIRMED** | Socket matrix test lists **22** commands; `protectedCommands` has **40**. Missing from matrix include all `remote*`, all `archive*`, `setParentSession`, `clearParentSession`, `recordSessionAccess`, `configureClaudeCodeProfiles`, etc. Production set still complete (no missing mutator vs handler). |
| **SEC-L2** | **CONFIRMED** (test gap) | `peerIsAuthorized` + `chmod(..., 0o600)` exist in source; no dedicated behavioral assert found in hardening suite. |
| **SEC-L3** | **CONFIRMED live** | `cache`/`exports` **755**; core secrets still 600/700. |
| **SEC-L4 / L5** | Accept | Design residuals; not re-proved exhaustively. |
| **SEC-I1 / I2** | Accept | Accurate design notes. |

---

## Solid defenses (spot-confirmed)

| Claim | Verdict |
|-------|---------|
| Runtime 0700 + owner | **CONFIRMED** — `secureRuntimeDirectory` / live `700` |
| Socket 0600 | **CONFIRMED** — `bindSocket` chmod; live socket mode 600 |
| Peer euid | **CONFIRMED** — accept loop + `getpeereid` |
| All mutators token-gated | **CONFIRMED** — handler cases vs `protectedCommands` (re-run: no missing mutator; hygiene/triggerSync non-mutating) |
| Archive V2 client hardening | **CONFIRMED** — ephemeral, cookies off, redirect handler, size limits |
| RepoDetail uses shell+AS escape | **CONFIRMED** — `appleScriptCommandLine` at `RepoDetailView.swift:57` |
| Product os_log not `.public` | **CONFIRMED** earlier; not re-grepped this pass beyond prior audit |
| Live core perms | **CONFIRMED** — `~/.engram` 700, `run` 700, sock/token/secrets/db/settings 600 |

---

## Severity / framing notes (not overturns)

1. **SEC-H1 is two issues glued together**
   - **(A)** bare single-label HTTP + no post-DNS private check → real misconfig → public cleartext. **High**.
   - **(B)** product default `requireTLS=false` + intentional Tailscale HTTP → ops posture. **Medium** if tailnet is trusted; matches live owner config.
   - Report correctly refuses “Critical” and notes opt-in. Do not over-read live Tailscale use as proof of the bare-label DNS bug.

2. **SEC-H2 severity softener**  
   Same-user process that can read `run/ai-secrets.json` can often also talk to Keychain or the socket. Still a **real easier scrape surface** and lacks stop cleanup — keep as finding; “High” is only justified if T2 is in scope as first-class.

3. **SEC-M1 “world-readable”**  
   Code path confirmed; actual mode depends on umask (typically 644). File not present until resume runs — claim is about **code**, not continuous live exposure.

4. **No overcount**  
   2+5+5+2 = 14 matches enumerated IDs. Executive summary matches body.

5. **Not a product defect list alone**  
   M5/I1 are trust-boundary documentation. Priority fix order in report (M1 → H1 → M2 → H2) remains sensible.

---

## Overturned / partial

| Claim | Result |
|-------|--------|
| Any finding fabricated | **None** |
| “No missing mutator” | **CONFIRMED** |
| “hygiene mutates without token” (if implied by outsiders) | **OVERTURNED** — read-only (report already says this) |
| Live production holds plaintext API keys in settings | **OVERTURNED as live state** — `@keychain`; M3 remains valid for DEBUG/fail paths |
| Archive origin as weak as offload bare-label | **OVERTURNED** — archive HTTP limited to Tailscale IPs; offload is the weaker host policy |

---

## Recommended report edits (optional, non-blocking)

1. Split SEC-H1 into H1a (bare-label/DNS) and H1b (default requireTLS=false / transport parity).
2. Annotate SEC-H2 severity: “High under T2; Medium if same-user malware already owns Keychain.”
3. SEC-M1: note “latent until resume; mode umask-dependent.”

These are polish, not reasons to retract the closeout.

## Final adjudication

**APPROVED as security closeout.** Findings are source-backed; counts reconcile; highest claims survive adversarial re-check with only severity-framing caveats on H2 and the dual nature of H1. Safe next steps remain: fix M1 (cheap), then H1 transport policy, then M2/H2.
