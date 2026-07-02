# Doubao - Claude Code Provider-Root Session Format

Last researched: 2026-07-02.

Doubao sessions reached through the local `cc-doubao` wrapper use Claude Code's
on-disk JSONL format. Engram assigns the `doubao` source from the provider root
path.

## Storage

| Aspect | Value |
|---|---|
| Engram source | `doubao` |
| Root | `~/.claude-doubao/projects` |
| On-disk schema | Same as Claude Code JSONL |
| Direct session locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| Subagent locators | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

For the shared record schema, see [claude-code.md](./claude-code.md).

## Engram Mapping

`SessionAdapterFactory.claudeCodeProviderAdapters()` registers
`ClaudeCodeAdapter(projectsRoot: "~/.claude-doubao/projects")`.
`ClaudeCodeAdapter.providerRootSources` maps the `.claude-doubao` path
component to `SourceName.doubao`, so source assignment does not depend on
`message.model`.

## Current Local Audit

2026-07-02 local smoke over `~/.claude-doubao/projects` listed 30 JSONL files
and parsed 28 conversation files as `doubao`. Of those parseable conversations,
24 are subagent sessions with parent links. All 28 parseable sessions report
`originator='Claude Code'` and `model='doubao-seed-2.0-code'`. The skipped
files were workflow `journal.jsonl` status logs.

Installed `/Applications/Engram.app` build `20260701074505` now has 28 `doubao`
rows under `/Users/bing/.claude-doubao/%`; `file_index_state` has 28 `ok` rows
and 2 `retry` rows for the source. Locator coverage is closed for the parseable
scanned corpus.

All 30 Doubao `file_index_state` rows are still schema version 1, but the
corrected visible-tool-result parser reports 0 field-stale current provider-root
rows. The earlier 26-row stale-count note was a retained-TS audit-tooling false
positive: TS was counting non-visible Claude `tool_result` rows that the Swift
product already drops. This audit did not mutate
`/Users/bing/.engram/index.sqlite`.

## Gotchas

- Doubao provider-root sessions are Claude Code JSONL at the byte level.
- Native `~/.claude/projects` sessions are not Doubao unless they are scanned
  through the explicit provider-root adapter.
- Installed runtime locator coverage is proven for the parseable scanned
  provider-root corpus; remaining non-`ok` files are retry-side channels, not
  missing source support.
- Current DB count fields align for indexed rows under the corrected parser
  semantics.
