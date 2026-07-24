---
name: catch-up
description: Explicitly load recent Engram project context for the current working directory. Use when the user asks to catch up, resume awareness, or see what was done in prior sessions.
disable-model-invocation: true
---

# Engram catch-up

Explicit skill — not an automatic write.

1. Call the Engram MCP tool `get_context` with:
   - `cwd`: absolute path of the active project (prefer `$CLAUDE_PROJECT_DIR` / current workspace root)
   - `detail`: `overview` unless the user asks for more depth
   - `include_environment`: `true` when cost/alerts are useful; otherwise `false`
   - optional `task`: short description of what the user is about to do
2. Summarize the returned context for the user in plain language.
3. Cite session sources when present; do not invent history.
4. Do **not** call `save_insight` from this skill.

If Engram MCP is unavailable, say so briefly and continue without blocking the task.
