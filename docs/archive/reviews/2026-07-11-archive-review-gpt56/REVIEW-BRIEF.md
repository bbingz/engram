# Independent Review Brief — Engram Remote-Archive Decision Package

You are an independent senior reviewer (GPT-5.6-sol). Another AI (Claude) produced
a two-round research + design package for Engram. Your job: bring a DIFFERENT
perspective — challenge conclusions, find blind spots, and go deeper on the
competitor repos than the original research did (which relied on web search,
not source reading).

## The project

Engram (repo at your cwd): local macOS cross-tool AI session aggregator —
SwiftUI app + Swift EngramService/EngramMCP, SQLite via GRDB, FTS5 trigram,
optional local embeddings, MCP tools (search/get_context/get_session/
save_insight). It indexes AI coding session logs (Claude Code, Codex, Gemini,
17 adapters) into ~/.engram/index.sqlite. Read CLAUDE.md first.

## The decision under review

Promote Engram from "regenerable index over on-disk JSONL" to "archival system
of record": verbatim, content-addressed, compressed transcript archive; Mac
keeps a recent hot window; a 24/7 personal server (Tailscale Serve) holds full
cold history; analytics split local-hot / server-full; agents get history-
backtracking MCP tools (incl. recovering what Claude Code compaction drops).

## Materials (in ./review-handoff/)

1. `round2-context.md` — round-1 final architecture + completeness critique +
   item registry (G/D/N ids) + empirical ground truth. READ FIRST.
2. `round2-clusters.md` — round-2 deep-dives: 4 cluster designs
   (crypto/privacy, durability, search, sizing/ops) + adversarial reviews.
   Includes measured data from the user's real DB (e.g. 1,648 MB of
   transcripts already lost from disk; reclaim math; growth projections).
3. `final-decision-memo.md` — the consolidated round-2 decision memo +
   simplicity critique (what's minimal core vs deferrable vs gold-plating).

## Your tasks

### Task 1 — Competitor repo deep-dive (the part the original research could NOT do)

Clone and READ THE SOURCE of these four repos (verify exact URLs first — the
names come from web research and may be slightly off):

- CASS — `Dicklesworthstone/coding_agent_session_search` (Rust/Tantivy,
  22+ sources; closest architectural analog)
- AgentsView — likely `kenn-io/agentsview` (Go, 29 sources; closest product
  competitor)
- claude-mem — likely `thedotmack/claude-mem` (3-layer progressive-disclosure
  retrieval; hook-based capture)
- Gentleman-Programming/engram (5k+ stars; name collision; Go + SQLite+FTS5 +
  MCP cross-agent memory)

For each, answer from the actual code (cite file paths):
a) Schema design: how do they model sessions/messages/chunks? Anything better
   than our proposed `archive_chunks` + `session_archive` CAS design?
b) Adapter coverage: which sources do they parse that Engram's 17 adapters
   miss? How do they handle format drift?
c) Retrieval: ranking, chunking, token-efficiency patterns worth stealing
   (esp. claude-mem's progressive disclosure — is our reading of it accurate?)
d) Archival/retention: do ANY of them treat the DB as system of record and
   age out originals? Any prior art for our delete-gate?
e) Was the original research's verdict on this repo accurate? What did it miss?

### Task 2 — Independent architecture review

With fresh eyes, review the full decision chain in the materials:
- Where is the package WRONG (not just incomplete)?
- Where would you decide differently, and why? (e.g., SQLite CAS blobs vs
  plain files-on-disk + manifest; Tailscale-only stance; deferring semantic;
  the bounded hot window; heuristic-first get_decisions)
- What perspective is systematically missing from a Claude-only analysis?
- Sanity-check the headline numbers (1.11 GB reclaim, 3.1-3.6 GB/mo growth,
  ~72-258 GB 5-yr band) against the evidence in the materials.

### Task 3 — Verdict

Write `review-handoff/REVIEW-FINDINGS.md` with:
1. Top-10 findings ranked by importance (each: claim → evidence → suggested
   change), marking which came from reading competitor source.
2. A "steal list": concrete implementations from the four repos worth porting
   to Swift (file-path citations).
3. Your overall verdict: proceed as designed / proceed with changes / rethink.

Rules: cite file paths for every code-level claim; use web freely to verify;
do NOT modify Engram source in this pass — review only. Do NOT push, publish,
or create PRs. Everything stays local to this worktree.
