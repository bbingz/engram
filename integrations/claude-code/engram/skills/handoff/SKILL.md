---
name: handoff
description: Produce an explicit handoff summary of current Engram project context for another session or teammate. Read-only — does not save insights.
disable-model-invocation: true
---

# Engram handoff

Explicit, read-only skill.

1. Prefer Engram MCP `handoff` when available (cwd = project root).
2. Otherwise call `get_context` with `detail: overview` and optional `task` describing the handoff goal.
3. Produce a concise handoff note covering:
   - current goal / open work
   - key decisions already made
   - risks / blockers
   - suggested next steps
4. Do **not** call `save_insight` unless the user separately invokes the remember skill.
5. Do not dump raw transcripts or secrets.
