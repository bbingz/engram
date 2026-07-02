# Mimo - Claude Code Provider-Root Session Format

Last researched: 2026-07-02.

Mimo sessions reached through the local `cc-mimo` and `cc-mimosg` wrappers use
Claude Code's on-disk JSONL format. Engram assigns the `mimo` source from the
provider root path, not from model-name substring detection.

## Storage

| Aspect | Value |
|---|---|
| Engram source | `mimo` |
| Roots | `~/.claude-mimo/projects`, `~/.claude-mimosg/projects` |
| On-disk schema | Same as Claude Code JSONL |
| Direct session locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| Subagent locators | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

For record types, content blocks, counts, timestamps, cwd extraction, tool
messages, and subagent transcript details, see
[claude-code.md](./claude-code.md). The bytes are Claude Code JSONL; only the
root-to-source mapping differs.

## Engram Mapping

`SessionAdapterFactory.claudeCodeProviderAdapters()` registers
`ClaudeCodeAdapter` instances for both Mimo roots. `ClaudeCodeAdapter` maps the
root components `.claude-mimo` and `.claude-mimosg` to `SourceName.mimo`.

Provider-root mode has two important properties:

- `source` is fixed to `mimo` for every parseable conversation under those
  roots.
- `originator` is set to `Claude Code`, preserving that the session was written
  by a Claude Code-compatible client.

This path-based source assignment is separate from the native
`~/.claude/projects` derived-source model detection used for MiniMax and
LobsterAI.

## Current Local Audit

2026-07-02 local smoke over the Mimo provider roots:

| Root | Listed JSONL | Raw records | Parsed conversations | Subagents with parent links | Source | Model notes |
|---|---:|---:|---:|---:|---|---|
| `~/.claude-mimo/projects` | 180 | 14,578 | 174 | 168 | `mimo` | model-bearing records are mostly `mimo-v2.5-pro`, with 4 `<synthetic>` records |
| `~/.claude-mimosg/projects` | 92 | 10,634 | 89 | 80 | `mimo` | model-bearing records are mostly `mimo-v2.5-pro`, with 11 `<synthetic>` records |
| **Total** | **272** | **25,212** | **263** | **248** | `mimo` | 0 malformed lines and 0 stream/count mismatches |

The skipped files were workflow `journal.jsonl` status logs, not normal
conversation parser failures.

The two non-`mimo-v2.5-pro` cases are raw-transcript realities, not source
mapping drift: one assistant message explicitly carries `message.model =
"<synthetic>"`; one child transcript has only user/attachment records and no
assistant model field.

Installed `/Applications/Engram.app` build `20260701074505` now has 263 `mimo`
rows under `/Users/bing/.claude-mimo/%` and `/Users/bing/.claude-mimosg/%`.
`file_index_state` has 263 `ok` and 9 `retry/malformedJSON` rows for `mimo`,
all still schema version 1. Locator diff is closed (0 missing parseable adapter
locators and 0 DB-only current locators), and the corrected visible-tool-result
parser reports 0 field-stale current provider-root rows. The earlier 261-row
stale-count note was a retained-TS audit-tooling false positive: TS was counting
non-visible Claude `tool_result` rows that the Swift product already drops.

## Gotchas

- Do not classify native `~/.claude/projects` files as Mimo just because their
  message text mentions Mimo. The provider-root source comes from the
  `.claude-mimo` or `.claude-mimosg` path component.
- Nested workflow subagents are part of the supported locator surface because
  `ClaudeCodeAdapter.listSessionLocators()` recursively scans `subagents/`.
- Installed runtime locator coverage is proven for the parseable scanned
  provider-root corpus; retry rows are non-conversation side channels, not
  missing source support. Current count fields align for indexed rows under the
  corrected parser semantics.
