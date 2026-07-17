# Finding disposition inventory

| ID | Area | Status | Batch/PR | Notes |
|----|------|--------|----------|-------|
| H1 | full-high | fixed | C | Project list counts / preview window |
| H2 | full-high | fixed | C | CJK/short keyword search |
| M1 | full-medium | pending-fix | D | |
| M2 | full-medium | pending-fix | D | |
| M3 | full-medium | pending-fix | D | |
| M4 | full-medium | pending-fix | D | |
| M5 | full-medium | fixed | D | MCP list_sessions top-level + non-skip defaults |
| M6 | full-medium | pending-fix | D | |
| M7 | full-medium | pending-fix | D | |
| M8 | full-medium | pending-fix | D | |
| M9 | full-medium | fixed | D | |
| M10 | full-medium | pending-fix | D | |
| M11 | full-medium | fixed | G | `--hygiene-only` runs structural helper checks per-PR |
| M12 | full-medium | fixed | D | |
| M13 | full-medium | pending-fix | D | |
| M14 | full-medium | pending-fix | D | |
| M15 | full-medium | pending-fix | D | |
| M16 | full-medium | pending-fix | D | |
| M17 | full-medium | pending-fix | D | |
| M18 | full-medium | fixed | D | |
| M19 | full-medium | fixed | D | |
| M20 | full-medium | fixed | D | |
| M21 | full-medium | pending-fix | D | |
| M22 | full-medium | pending-fix | D | |
| M23 | full-medium | fixed | D | |
| M24 | full-medium | fixed | D | |
| M25 | full-medium | pending-fix | D | |
| L1 | full-low | pending-fix | E | |
| L2 | full-low | pending-fix | E | |
| L3 | full-low | pending-fix | E | |
| L4 | full-low | pending-fix | E | |
| L5 | full-low | pending-fix | E | |
| L6 | full-low | fixed | G | sparklineData path-boundary cwd match |
| L7 | full-low | fixed | G | default subAgent nil hides skip tier |
| L8 | full-low | fixed | G | removed dead listSessionsChronologically / listSessionsInGroup |
| L9 | full-low | pending-fix | E | |
| L10 | full-low | pending-fix | E | |
| L11 | full-low | pending-fix | E | |
| L12 | full-low | pending-fix | E | |
| L13 | full-low | pending-fix | E | |
| L14 | full-low | pending-fix | E | |
| L15 | full-low | pending-fix | E | |
| L16 | full-low | pending-fix | E | |
| L17 | full-low | pending-fix | E | |
| L18 | full-low | pending-fix | E | |
| L19 | full-low | accepted-residual | residual | TS CLI for tables Swift never populates — TS-ref residual |
| L20 | full-low | pending-fix | E | |
| L21 | full-low | accepted-residual | residual | Notarization manual-only documented |
| L22 | full-low | pending-fix | E | |
| L23 | full-low | accepted-residual | residual | docs retention policy — docs-only residual |
| L24 | full-low | pending-fix | E | |
| L25 | full-low | pending-fix | E | |
| L26 | full-low | pending-fix | E | |
| L27 | full-low | pending-fix | E | |
| L28 | full-low | pending-fix | E | |
| L29 | full-low | pending-fix | E | |
| L30 | full-low | pending-fix | E | |
| L31 | full-low | pending-fix | E | |
| L32 | full-low | pending-fix | E | |
| L33 | full-low | pending-fix | E | |
| L34 | full-low | pending-fix | E | |
| L35 | full-low | accepted-residual | residual | EngramCoreSchemaTool unused target |
| L36 | full-low | pending-fix | E | |
| SEC-H1 | security | fixed | B | |
| SEC-H2 | security | fixed | A | |
| SEC-M1 | security | fixed | A | |
| SEC-M2 | security | fixed | B | |
| SEC-M3 | security | fixed | B | |
| SEC-M4 | security | accepted-residual | residual | Cleartext Archive HTTP on Tailscale IPs when requireTLS=false — ops risk |
| SEC-M5 | security | accepted-residual | residual | Product same-user MCP data plane; document only |
| SEC-L1 | security | fixed | G | protectedCommands matrix test covers full set |
| SEC-L2 | security | fixed | G | peer euid + socket 0600 behavioral tests |
| SEC-L3 | security | fixed | A | |
| SEC-L4 | security | accepted-residual | residual | Indirect prompt injection via stored sessions; design residual |
| SEC-L5 | security | fixed | G | resume CLI prefers absolute known install paths |
| SEC-I1 | security | accepted-residual | residual | Same-user capability model intentional |
| SEC-I2 | security | accepted-residual | residual | No cert pinning; system trust acceptable |

## Totals

| Bucket | Count |
|--------|-------|
| ALL findings | 77 (H=2 M=25 L=36 SEC=14) |
| Accepted residual | 9 — `L19`, `L21`, `L23`, `L35`, `SEC-M4`, `SEC-M5`, `SEC-I1`, `SEC-I2`, `SEC-L4` |
| Fixed (through batch G) | H1–H2; subset of M/SEC/L as marked above |
| Still pending-fix | remaining M/L rows not marked fixed or residual |

Rationale writeup: `docs/reviews/2026-07-17-accepted-residuals.md`.
