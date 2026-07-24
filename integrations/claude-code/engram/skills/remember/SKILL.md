---
name: remember
description: Explicitly save a durable Engram insight via save_insight. This is the only write path for plugin memory — never auto-save on Stop or SessionEnd.
disable-model-invocation: true
---

# Engram remember

**This skill is the only plugin path that may call `save_insight`.**

When the user asks to remember a decision, lesson, or fact:

1. Confirm the content is durable knowledge (not a transient scratch note or secret).
2. Call Engram MCP `save_insight` with:
   - `content`: the insight text (min ~10 chars after trim)
   - optional `type`: `semantic` | `episodic` | `procedural` (default `semantic`)
   - optional `importance`: 0–5 (default 5)
   - optional `wing` / `room` for project sub-area
3. Report success or the tool error clearly.
4. Never write secrets, tokens, raw transcripts, or full message dumps.

Do not call `save_insight` from SessionStart, Stop, SessionEnd, catch-up, or handoff.
