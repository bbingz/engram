# Grok Build - Session Format Reference

Last researched: 2026-07-01.

This document describes the current Grok Build session store as consumed by
Engram's Swift product adapter and retained TypeScript tooling adapter. Grok is
a standalone source, not a Claude Code provider-root overlay.

## Storage

| Aspect | Value |
|---|---|
| Engram source | `grok` |
| Adapter | Swift: `macos/Shared/EngramCore/Adapters/Sources/GrokAdapter.swift`; TS retained tooling: `src/adapters/grok.ts` |
| Root | `~/.grok/sessions` |
| Session layout | `~/.grok/sessions/<encoded-cwd>/<session-id>/` |
| Preferred locator order | `chat_history.jsonl`, then `updates.jsonl`, then `summary.json` |
| Metadata sidecars | `summary.json`, `prompt_context.json` |

`GrokAdapter.listSessionLocators()` walks direct children under
`~/.grok/sessions`, then direct session directories under each project
directory. A directory is considered a session when one of the preferred locator
files exists. If the selected locator is `summary.json`, parsing still prefers a
real transcript file in the same directory when `chat_history.jsonl` or
`updates.jsonl` exists.

## Parsed Records

Grok transcript files are line-delimited JSON. The current Swift parser maps or
intentionally skips these current record types:

| Record type | Engram role | Notes |
|---|---|---|
| `user` | user | Reads `content`; strips a surrounding `<user_query>...</user_query>` wrapper when present. |
| `assistant` | assistant | Reads `content`, `tool_calls`, and `usage`; drops empty assistant records with no tool calls. |
| `tool_result` | tool | Reads non-empty `content`. |
| `system` | system count only | Counted as system metadata, not streamed as a chat turn. |
| `reasoning` | skipped | Current files store `summary` plus encrypted reasoning content; Engram does not expose chain-of-thought/reasoning records. |
| `backend_tool_call` | skipped | Backend search/tool metadata (`web_search`, `x_search`, etc.); not streamed as a chat turn. |

User records that are system injections are counted as system messages and not
surfaced as chat turns. The current filter includes `# AGENTS.md instructions`,
`<INSTRUCTIONS>`, `<environment_context>`, `<system-reminder>`, and related
agent context wrappers.

## Metadata Mapping

| Engram field | Source |
|---|---|
| `id` | `summary.info.id`, otherwise session directory name |
| `cwd` | `summary.info.cwd`, then `prompt_context.working_directory`, then decoded project directory |
| `startTime` | `summary.created_at`, then first transcript timestamp, then transcript/session mtime |
| `endTime` | `summary.updated_at`, then last transcript timestamp |
| `model` | `summary.current_model_id`, then first transcript model value |
| `summary` | first user message, then `summary.session_summary`, then `summary.generated_title` |
| `filePath` | primary transcript path, not necessarily the originally selected locator |

## Current Local Audit

The latest 2026-07-01 recheck found 344 Grok session directories under
`~/.grok/sessions/<encoded-cwd>/<session>/`. Every current directory has the
same four-file shape: `chat_history.jsonl`, `updates.jsonl`, `summary.json`, and
`prompt_context.json`; therefore every current preferred locator is
`chat_history.jsonl`. This supersedes an earlier same-day 345-session count after
one `2026-Teaching-Plan` session directory disappeared from disk.

Current live transcripts have 0 malformed raw JSON lines. Retained TS live smoke
and the env-gated Swift live smoke both parsed 344/344 current sessions; the
Swift live smoke wrote 344 `grok` rows into a temp DB. Observed record counts
are: 344 `system`, 1,347 `user`, 6,923 `assistant`, 13,741 `tool_result`, 7,614
`reasoning`, and 489 `backend_tool_call`. After the parser's filters, the mapped
message counts are 470 user, 6,923 assistant, 13,605 tool, and 1,221 system
messages. `summary.json` provides `info.cwd` and `current_model_id` for all 344
current sessions. Current observed models are `grok-build` and
`grok-composer-2.5-fast`. Retained TS tooling also registers a `GrokAdapter` and
has fixture coverage for the same metadata, `<user_query>` unwrap, assistant
tool-call, and `tool_result` mapping path.

Installed `/Applications/Engram.app` build `20260701074505` has 345 `grok` rows
under `/Users/bing/.grok/sessions/%`, and `file_index_state` has 345 `grok` rows
with `parse_status='ok'`. All 344 current parser locators are present and have 0
field-stale current rows, but one deleted
`/Users/bing/.grok/sessions/%2FUsers%2Fbing%2F-Code-%2F2026-Teaching-Plan/019e81cd-c8e3-79a3-a9a9-f49363691a29/chat_history.jsonl`
locator remains as both a DB-only session row and DB-only `file_index_state` row.
This is now classified as `SOURCE_READY / CURRENT_LOCATOR_PASS /
DB_ONLY_STALE_1`.

## Gotchas

- `summary.json` is only a fallback locator. When transcript JSONL exists in
  the same directory, Engram parses the transcript.
- `prompt_context.json` is metadata only; it is not a transcript.
- The decoded project directory is a fallback. Prefer explicit cwd metadata
  when `summary.json` or `prompt_context.json` provides it.
- Empty assistant/tool records are dropped from streamed messages and counts.
- `reasoning` and `backend_tool_call` records are present in current live files
  but intentionally skipped by the adapter; only user/assistant/tool_result
  turns are exposed.
