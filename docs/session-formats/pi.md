# Pi Session Format

Last researched: 2026-09-21 (product adapter)

> **Evidence basis.** Swift product parser
> `macos/Shared/EngramCore/Adapters/Sources/PiAdapter.swift`. There is no
> TypeScript reference adapter; `SOURCE_NAMES` includes `pi` for schema/docs
> alignment only.

## 1. Overview

**Pi** is a JSONL coding-agent store. Engram source id is `pi`.

**What / where / how:**
- **What:** one JSONL transcript per session.
- **Where:** `~/.pi/agent/sessions/**/*.jsonl`.
- **How:** recursive `.jsonl` enumeration. Session id comes from a `type:
  "session"` record's `id`, or the filename stem.

## 2. Record types the product parser consumes

| `type` | Role |
|---|---|
| `session` | Envelope: `id`, `cwd`, `timestamp` |
| `model_change` | `modelId` |
| `message` | Nested `message.role` + `message.content` |

Message roles: `user`, `assistant`, `toolResult`, `system`. User text that
matches known system-injection markers is stored as `system`. Assistant
content may include tool-call blocks and `usage`.

A session is malformed if both session id and start time are missing after
the scan.

## 3. Engram mapping

| Field | Source |
|---|---|
| `source` | `pi` |
| `id` | `session.id` or filename stem |
| `cwd` | `session.cwd` |
| `model` | `model_change.modelId` or `message.model` |
| `start_time` / `end_time` | record `timestamp` |
| `summary` | first non-injection user text, truncated to 200 chars |
