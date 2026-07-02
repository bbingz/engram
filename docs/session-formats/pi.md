# Pi Session Format

Status: restored in the 2026-06-30 provider audit; current live-state
verification updated on 2026-07-01.

## Storage

- Root: `~/.pi/agent/sessions`
- Locator pattern: `~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<session-id>.jsonl`
- Local audit count on 2026-07-01: 230 JSONL files, all parseable by the restored TypeScript adapter.

## Records

Pi writes JSONL records with a top-level `type`.

| Type | Purpose | Engram handling |
|---|---|---|
| `session` | Session metadata: `id`, `timestamp`, `cwd`, `version` | Provides `id`, `startTime`, and `cwd`. |
| `model_change` | Active model switch: `modelId` | First/last observed value becomes session `model`. |
| `thinking_level_change` | Thinking-mode metadata | Ignored for message counts. |
| `message` | User, assistant, tool, and system content under `message` | Parsed by `message.role`. |
| `compaction` | Compaction summary metadata: `summary`, `tokensBefore`, `firstKeptEntryId`, file lists | Ignored for message counts and streaming. |
| `custom` | Custom side-channel records such as `web-search-results` | Ignored for message counts and streaming. |

`message.content` is an array of parts. Text parts use `{type:"text", text}`.
Assistant tool calls use `{type:"toolCall", name, arguments}` and are attached
to the assistant message as `toolCalls`. Current live files also contain
`thinking` and `image` parts; both Swift and TypeScript adapters ignore those
parts because `extractText` only joins `text` parts and `extractToolCalls` only
reads `toolCall` parts.

## Role Mapping

| Pi role | Engram role | Counted as |
|---|---|---|
| `user` | `user`, unless it is a system injection | user |
| `assistant` | `assistant` | assistant |
| `toolResult` | `tool` | tool |
| `system` | `system` | system only |
| `bashExecution` | skipped | not counted or streamed by the current adapters |

System-injection filtering matches the common Engram adapter rules for
`AGENTS.md`, `<INSTRUCTIONS>`, `<local-command-caveat>`, and
`<environment_context>`.

## Parser Notes

- Swift source: `macos/Shared/EngramCore/Adapters/Sources/PiAdapter.swift`
- TypeScript source: `src/adapters/pi.ts`
- Tests:
  - `AdapterMessageCountTests.testPiAdapterListsParsesAndStreamsSessions`
  - `tests/adapters/pi.test.ts`

## Current Local Audit

The 2026-07-01 live smoke found:

- 230 JSONL files listed and 230/230 parsed; 0 malformed JSON lines.
- Top-level record counts: 230 `session`, 239 `model_change`, 234
  `thinking_level_change`, 9,235 `message`, 8 `compaction`, and 2 `custom`.
- `message.role` counts: 452 `user`, 3,758 `assistant`, 5,024 `toolResult`,
  and 1 `bashExecution`.
- Content part counts: 6,734 `text`, 3,133 `thinking`, 5,028 `toolCall`, and
  2 `image`.
- Parsed message counts: 452 user, 3,758 assistant, 5,024 tool, and 0 system.
- 230/230 sessions have a `session` metadata record and a `model_change` record;
  observed final models are `gpt-5.4` (164), `gpt-5.3-codex` (21),
  `mimo-v2.5-pro` (17), `claude-sonnet-4-6` (14),
  `claude-opus-4-6-thinking` (9), and `gpt-5.5` (5).
- Adapter streaming matches parsed counts exactly: 9,234 streamed transcript
  messages and 0 stream/count mismatches.

Installed `/Applications/Engram.app` build `20260701074505` now has 230 `pi`
rows under `/Users/bing/.pi/agent/sessions/%`, and `file_index_state` has 230
`pi` rows with `parse_status='ok'`. Runtime DB coverage now matches the current
230/230 parsed session files, with 0 missing locators, 0 DB-only locators, and 0
field-stale current rows.
