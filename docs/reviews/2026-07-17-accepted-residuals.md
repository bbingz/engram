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
| **L21** | ci | Low | Notarization/stapling has no CI backstop (manual release-machine step; documented). CI has no Apple credentials for stapling. Accept residual with release checklist ownership. |
| **L23** | docs | Low | `docs/archive` + `docs/reviews` lack an index/retention policy. Docs-only debt; not a runtime defect. |
| **L35** | tooling | Low | `EngramCoreSchemaTool` is a build target with no caller, no test, and no bundle wiring. Dead/unused target; accept residual or remove in a later cleanup PR. |
| **SEC-M4** (ops note) | — | — | Also listed in security adjudication as accepted ops risk when replicas run `requireTLS=false` on `http://100.x`. |

## Intentionally skipped lows (this residual batch)

The following lows were **not** implemented in batch G because they are larger
than "easy TDD" or better tracked as separate work:

| ID | Why skipped now |
|----|-----------------|
| L1–L5, L9–L18, L20, L22, L24–L34, L36 | Larger correctness/perf/process items; not in the easy-low batch list. Remain `pending-fix` or later batches unless disposition is updated. |
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
Closeout accepts as residual low backlog. Highs and defect-class mediums closed in PRs #188–#194. Prefer follow-up themed PRs rather than blocking multi-PR audit stack.

## M21 — AI settings per-keystroke I/O
Debounce (~400ms) landed in batch F. Full off-main flock/Keychain I/O remains residual: settings writes still run on MainActor after debounce.
