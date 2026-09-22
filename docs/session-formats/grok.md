# Grok Session Format

Last researched: 2026-09-22 (product adapter)

> **Evidence basis.** Swift product parser
> `macos/Shared/EngramCore/Adapters/Sources/GrokAdapter.swift`. There is no
> TypeScript reference adapter; `SOURCE_NAMES` includes `grok` for schema/docs
> alignment only. Archive/collector may treat `summary.json` as a last-resort
> primary file; that contract lives outside this adapter.

## 1. Overview

**Grok** stores each session as a directory under `~/.grok/sessions/`.

**What / where / how:**
- **What:** a session directory, not a single flat JSONL.
- **Where:** `~/.grok/sessions/<percent-encoded-cwd>/<session-id>/`.
  The project directory percent-encodes each UTF-8 byte outside
  `A-Za-z0-9-._~` with uppercase hex, so `/` is `%2F`.
- **How:** locator preference is `chat_history.jsonl`, then `updates.jsonl`,
  then `summary.json`. Product parsing uses JSONL as the transcript when
  present; `summary.json` and `prompt_context.json` supply metadata
  (`id`, `created_at`, `updated_at`, `cwd`, title/summary, model).

## 2. Files in a session directory

| File | Read by Engram? | Purpose |
|---|---|---|
| `chat_history.jsonl` | **yes — primary transcript** | Chat turns |
| `updates.jsonl` | **yes — fallback transcript** | Alternate JSONL log |
| `summary.json` | **yes — metadata** (and last-resort locator) | `info.id`, timestamps, title, model |
| `prompt_context.json` | **yes — metadata** | `working_directory` |
| compaction archive segments | **yes when declared on disk** | Prepended as system/archive messages |

A session id comes from `summary.info.id`, else the session directory name.
`cwd` comes from `summary.info.cwd`, then `prompt_context.working_directory`,
then a decoded project directory from the path.

## 3. Engram mapping

| Field | Source |
|---|---|
| `source` | `grok` |
| `id` | `summary.info.id` or directory name |
| `start_time` | `summary.created_at` or first JSONL timestamp |
| `end_time` | `summary.updated_at` or last JSONL timestamp |
| `cwd` | summary / prompt_context / path |
| `model` | `summary.current_model_id` or first JSONL model |
| `summary` | first user text, else `session_summary` / `generated_title` |
