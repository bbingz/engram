# Accepted residuals — 2026-07-17 audit

Inventory of findings intentionally **not** fixed in product code after the
2026-07-17 full + security audits. Each residual is either a documented
threat-model choice, a TypeScript-reference-only surface, docs/process debt, or
dead tooling not on the shipped path.

| ID | Area | Severity | Rationale for acceptance |
|----|------|----------|--------------------------|
| **SEC-M4** | security | Medium | Archive V2 may use cleartext HTTP to Tailscale CGNAT IP literals when `requireTLS=false` (`.ts.net` still requires HTTPS). Live owner config uses this path; ops risk is "tailnet compromise = archive compromise." Prefer HTTPS on Tailscale when practical; not a coding defect. |
| **SEC-M5** | security | Medium (design) | MCP is a full same-user data-plane relay by product design. Any same-euid MCP client can read transcripts (default redacted; `include_raw` opt-in) and mutate via the capability token. Mitigations: peer euid, token on mutators, redaction, size caps. Fix would be product allowlists/confirmations, not a silent patch. |
| **SEC-I1** | security | Info | Same-user capability model is intentional: App and MCP share the socket + token; there is no per-client ACL between them. Document for security reviewers. |
| **SEC-I2** | security | Info | No certificate pinning on Archive HTTPS. System trust store only. Acceptable for MagicDNS/LE deployments; no defense against user-installed roots or CA compromise. |
| **SEC-L4** | security | Low | Stored-session / insight content returned by MCP (`get_session`, `get_context`, memory tools) can steer the current model (indirect prompt injection). Redaction covers secret shapes only, not instruction isolation. Optional untrusted-content wrappers are a product design track, not a batch fix. |
| **L19** | ts-ref | Low | `engram logs` / `traces` CLI queries tables the Swift runtime never populates — silently inert. TypeScript reference/dev surface only; do not expand product observability through Node. Accept or delete CLI later. |
| **L21** | ci | Low | Notarization/stapling has no CI backstop (manual release-machine step; documented). CI has no Apple credentials for stapling. Accept residual with release checklist ownership. Same home as review **L-h** / `docs/TODO.md` public release baseline. |
| **L25** | settings | Low | Release builds do not revalidate their own code signature on the main thread before Keychain. Installed Release still uses Keychain; only DEBUG may persist plaintext. Accepted with SEC-M3 / #347. |
| **L-j** | ts-ref | Info | TypeScript `safeMoveDir` still lacks a case-only rename exception. Reference/dev surface only; product moves are Swift. |
| **SEC-M4** (ops note) | — | — | Also listed in security adjudication as accepted ops risk when replicas run `requireTLS=false` on `http://100.x`. |

## L-i closeout — residual lows now have backlog homes (2026-08-13)

Review **L-i** was “~30 lows residual without backlog home.” Those rows now
live in `docs/followups.md` (closed themed PRs) or remain accepted here:

| ID | Home |
|----|------|
| L1–L18, L20, L22–L24, L26–L36 | closed in followups / this disposition |
| L19, L21, L25, L-j | this file |
| L-h / TODO 1.0.5 | `docs/TODO.md` (blocked on human auth) |
| ARCH-001 / R1 | `docs/followups.md` (CoreRead leftover) |
| R6 | `docs/followups.md` (writer-gate redesign deferred) |

## Intentionally skipped lows (this residual batch)

The following lows were **not** implemented in batch G because they are larger
than "easy TDD" or better tracked as separate work. Later stewardship PRs
closed most of the set; do not treat the original skip list as current status.

| ID | Why skipped then |
|----|------------------|
| L1–L5, L9–L18, L20, L22, L24–L34, L36 | Larger correctness/perf/process items at closeout time. |
| L8 | **Fixed** by removal in batch G (was previously marked accepted-residual as alternative). |

## Fixed in batch G (for cross-reference)

| ID | Fix summary |
|----|-------------|
| L6 | `sparklineData` anchors cwd as `cwd = path OR cwd LIKE path/%` |
| L7 | Default `subAgent == nil` excludes skip-tier (same as `false`) |
| L8 | Removed dead `listSessionsChronologically` / `listSessionsInGroup` |
| SEC-L1 | Token matrix test iterates full `protectedCommands` set |
| SEC-L2 | Unit tests for `peerIsAuthorized` + post-bind socket `0600` |
| SEC-L5 | Resume CLI locator prefers known absolute install paths over PATH |
| M11 | `--hygiene-only` still runs structural helper checks (per-PR CI) |

## Related docs

- Full audit: `docs/reviews/2026-07-17-engram-full-audit.md`
- Security audit: `docs/reviews/2026-07-17-engram-security-audit.md`
- Security adjudication: `docs/reviews/2026-07-17-engram-security-audit-adjudication.md`
- Disposition table: `docs/reviews/2026-07-17-finding-disposition.md`

## M15 — Archive discovery listings O(N) rescan
Latent throughput issue on listMachines/listReceipts. No data-loss path. Accepted residual until discovery is product-hot; HEAD (M14) fixed existence-only.

## Remaining Lows L1–L5, L9–L18, L20, L22, L24–L34, L36
Historical closeout text. The lumped set later received themed PRs; current
homes are the L-i table above and `docs/followups.md` § “Post-review residuals”.

## M21 — AI settings per-keystroke I/O
Debounce (~400ms) landed in batch F. Full off-main flock/Keychain I/O remains residual: settings writes still run on MainActor after debounce. Tracked as review **R9** in `docs/followups.md`.

## Status note (R11)
This file is the **accepted residual writeup**, not a pending-fix queue. Items here are intentionally not product fixes in the audit closeout. Do not re-mark them as “pending-fix” without promoting them to `docs/TODO.md` / `docs/followups.md` with an owner.
