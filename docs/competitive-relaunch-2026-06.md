# Engram Competitive Relaunch — 2026-06

> Source-level competitive intel (Agent Sessions + ReadOut, both inspected from
> local source/reverse-eng docs) + code-level self-inventory + 2026 landscape
> research, run as an 11-agent workflow and adversarially verified against the
> shipped Swift product and `docs/roadmap.md`. Verdicts below survived a pass
> whose only job was to kill already-shipped or ungrounded recommendations.

## TL;DR

Engram is not in the same category as its two nearest neighbors, and that is the
whole point:

- **Agent Sessions** (open-source Swift, v3.7.1) = the best human-facing
  **session browser + live cockpit + resume**. Not an MCP server.
- **ReadOut** (closed-source Swift, v0.0.10) = an **AI-native dashboard** where
  the human chats with an assistant that has dev-environment context cards and
  one-click shell actions. Not an MCP server.
- **Engram** = the only **MCP-first cross-tool memory/context layer** — the AI
  agent itself calls `get_context`/`search`/`save_insight`. Plus 17-source
  breadth, project-migration path repair, and encrypted remote offload that no
  competitor has.

The 2026-03 catch-up round already closed the obvious gaps (24 features). So the
relaunch is **not** more catch-up. It is: **(1) weaponize the MCP-first moat via
a Claude Code plugin that pushes context instead of waiting to be pulled, (2)
make the "memory" claim true with semantic retrieval + a real memory lifecycle,
(3) fix distribution.** Everything else is secondary.

## The three-player map

| | Engram | Agent Sessions | ReadOut |
|---|---|---|---|
| Category | MCP memory/context layer for **AI agents** | Session browser for **humans** | AI dashboard + chat for **humans** |
| Sources | **17** (Swift parity-tested) | 9 | ~10 |
| MCP server | **Yes (28 tools)** | No | No |
| Search | Keyword FTS5 | Keyword (2-phase, faster) | Full-text grep |
| Live cockpit | Popover only | **Agent Cockpit HUD** | WebSocket telemetry |
| Conversational AI | None | None | **ChatWorkflow + cards + actions** |
| Cost insights | get_insights (3 rules) | usage in HUD | **Enterprise-grade** |
| Distribution | Manual scripts, 0.1.0 | **brew + Sparkle** | **Sparkle + StoreKit** |
| Project migration | **Full pipeline** | None | None |
| Remote offload | **Encrypted, opt-in** | None | SSH (different model) |

## Engram's verified moat (only what the code backs)

1. **Cross-tool breadth**: 17 adapters with a Swift property-based parity suite —
   structurally hard to copy and rigorously maintained, not just a count.
2. **Project migration pipeline** (`project_move/archive/undo/batch/recover/review`):
   transactional path-rewriting across source formats + alias auto-create. **No
   competitor does this** and no single vendor ever will — it must span rivals.
3. **MCP-first consumption**: AI agents are the primary consumer. This is the
   2026-winning shape (OpenMemory/Pieces/Supermemory converged on local MCP), and
   no aggregator competitor is an MCP server at all.
4. **Cross-tool parent-child grouping**: 4 detection layers cluster dispatched
   subagent hierarchies across vendors; viewers and memory APIs show flat lists.
5. **One integrated local product** (browser + cost + memory + MCP) vs point
   tools (ccusage / Agent Sessions / Mem0 / SpecStory).
6. **Encrypted, opt-in, self-hosted remote offload** — privacy-forward, no SaaS
   lock-in.
7. **Vendor-neutral, local-first, zero-telemetry** — a trust stance a single
   platform owner structurally cannot hold.

## What the market now expects in 2026 (landscape findings)

- "Memory" baseline is **multi-signal retrieval** (FTS + vector + rerank).
  Keyword-only is below baseline. (Mem0 ~92.5 LoCoMo at ~6.9K tokens/query.)
- The hard, unsolved problem is the **forget/decay/supersession lifecycle** —
  high-confidence facts going confidently stale.
- **Idle-time background consolidation** (Letta "sleeptime") is the winning
  autonomous-memory pattern — and Engram already owns an always-on service.
- Tools are shipping **native per-tool memory/resume/rewind** (Codex Memories,
  Cursor memories, Claude Code automatic memory + `/rewind`). This commoditizes
  single-tool "remember/resume" AND widens the gap between silos — pushing value
  toward the **cross-tool** layer only Engram occupies.
- The market expects a **real-time working/waiting HUD**, not a static list.
- New direct entrant: **AgentsView** (kenn-io) — local-first, 20+ auto-discovered
  agents, dashboards/heatmaps/FTS/live updates, cache-efficiency + cost treemap,
  marketed as 80–220× faster ccusage. Watch closely.
- The **MCP plugin + hooks** pattern (claude-mem) is the proven distribution and
  activation channel.

## Relaunch roadmap (verified, de-duplicated)

### P0 — do first, they unlock everything else
1. **Engram Claude Code plugin** (L) — bundle `EngramMCP` + a `SessionStart` hook
   that auto-injects `get_context` + a `Stop`/`SessionEnd` hook that auto-calls
   `save_insight` + slash-command prompts. Converts the flagship from **PULL→PUSH**
   and fixes distribution in one artifact. No hooks/plugin exist today. Highest
   leverage. (claude-mem proves pattern + demand.)
2. **Frictionless distribution** (M) — Homebrew cask + Sparkle (EdDSA) auto-update
   + DMG automation. Confirmed absent (stuck at 0.1.0 manual notarytool). Table
   stakes, zero product risk. Ship bundled with the plugin as one install story.

### P1 — make the moat real
3. **Swift semantic memory** (XL) — finish sqlite-vec, port TS
   vector-store/chunker/embeddings, default to local Ollama, RRF hybrid fusion.
   Keyword-only leaves the memory moat hollow. Reference design already exists in
   TS — a porting+finishing job, not invention. Sequence **behind** the plugin.
4. **Memory lifecycle** (L) — decay/supersession/light typing
   (episodic/semantic/procedural) + actually rank by `importance` (today
   `get_memory` orders by `created_at DESC` and ignores stored importance). Even
   simple decay+supersede beats unbounded FTS rows going stale.
5. **Deepen the MCP surface** (M) — `resources` (@-mention sessions/insights),
   `prompts` (`/engram:catch-up`, `/engram:handoff`), tool `annotations`
   (`readOnlyHint`/`destructiveHint` — auto-approve reads, gate `project_move`),
   `outputSchema`/structured content + `resource_links`. Lands in Claude Code's
   UI today at low cost. (Note: protocol 2025-11-25 negotiation already exists —
   this is capability depth, not protocol catch-up.)
6. **Mine the 17-source corpus into reusable skills/rules/runbooks** (L) —
   SpecStory "Lore beat" pattern. Differentiated write-path value no
   aggregator+MCP competitor combines; natural `save_insight` extension.

### P2 — compounding differentiators
7. **Idle-time background consolidation** (M) — host the "sleeptime" pattern in
   `EngramService`: periodically dedupe/summarize/promote insights. (Usage probes
   already ship — only the consolidation half is new.)
8. **Standalone live HUD** (L) — pinnable cockpit with working/waiting/idle
   detection (app live view is popover-only). Build the **app HUD**, not the MCP
   path (MCP `live_sessions` unavailable is a deliberate contract).
9. **Managed memory block in CLAUDE.md / AGENTS.md / GEMINI.md** (M) — an
   idempotent, clearly-delimited block reaches tools that never call MCP. Sidecar
   precedent already exists (Gemini `.engram.json`, Layer 1c).
10. **Inline image thumbnails + per-session gallery + FSEvents watching** (M) —
    contained polish (screenshots) + perf (removes up-to-5-min poll latency).

### P3 — opportunistic / guardrails
11. **In-app "Ask Engram"** (L) — MCP-tool-backed **data cards + action
    state machine**, NOT chat-first, NOT `[[marker]]` syntax. Adopt ReadOut's
    actionability, reject its chat-first 32-page scope. Speculative, off-moat.
12. **Cost UI only** (S) — cost-attribution treemap + sub-second today-spend
    status line. (cache-hit-rate already computed in `get_insights`.)
13. **Naming/positioning** (S) — differentiate vs the OSS Go `engram` memory tool
    before SEO collision worsens as Engram leans into "memory."
14. **Guardrail / explicit non-goals** — do **NOT** build in-session
    resume/checkpoint/`/rewind`, a chat-first dashboard, or dual licensing. These
    are vendor-owned and improving fast; hold the cross-tool wedge instead.

## Anti-duplication ledger (already shipped — do NOT re-propose)

The synthesis pass re-proposed these; verification killed them. Future planning
should treat them as **done**:

- **quality_score + auto-title in Swift** — computed at index time:
  `SessionSnapshotWriter.generatedTitle(for:)` (line 415) + `quality_score` in
  `SessionSnapshotWriter`/`StartupBackfills`, consumed by `Session.valueBand`
  (`Session.swift:79`). (The adapter-layer field being NULL is by design — filled
  later by the indexer.) Verified firsthand.
- **Cache-hit-rate cost insight** — already in `get_insights`
  (`lowCacheRateSuggestionSince`, `MCPDatabase.swift:995`:
  `cacheRead/(cacheRead+input)`, <0.3 triggers a suggestion).
- **Real usage probes** — `StartupUsageCollector` writes 7-day `usage_snapshots`
  (roadmap: "Real usage probes DONE 2026-05-24"). Not a Noop.
- **`live_sessions` MCP "unavailable"** — a deliberate contract, not a stub
  (`MCPToolRegistry.swift`; roadmap: "Live session monitor DONE").
- **MCP 2025-11-25 protocol negotiation** — already handled
  (`MCPStdioServer.swift:112-115`).
- **The 2026-03 catch-up's 24 features** — health checks, 8-rule cost advisor,
  `get_context` env aggregation, transcript tool-call rendering, keychain
  migration, network hardening, resume improvements, session context menus,
  empty/skeleton states, onboarding, menu-bar usage bars, etc.

## The one-line strategy

Lead with the **plugin** (PULL→PUSH + distribution in one move); ship
**distribution** alongside; then make **memory real** (semantic + lifecycle) and
**MCP deep** (resources/prompts/annotations). Hold the vendor-neutral cross-tool
wedge platform owners structurally cannot enter; retreat from per-tool
resume/rewind parity battles.

---
*Generated by an 11-agent workflow (4 competitive intel + 5 self-inventory +
synthesis + adversarial verify), 2026-06-26. Run: `wf_f5e15474-c3d`.*
