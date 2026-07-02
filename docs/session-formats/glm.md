# GLM - Claude Code Provider-Root Session Format

Last researched: 2026-07-02.

GLM sessions reached through the local `cc-glm` and `cc-glmc` wrappers use
Claude Code's on-disk JSONL format. Engram assigns the `glm` source from the
provider root path.

## Storage

| Aspect | Value |
|---|---|
| Engram source | `glm` |
| Roots | `~/.claude-glm/projects`, `~/.claude-glmc/projects` |
| On-disk schema | Same as Claude Code JSONL |
| Direct session locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| Subagent locators | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

For the shared record schema, see [claude-code.md](./claude-code.md).

## Engram Mapping

`SessionAdapterFactory.claudeCodeProviderAdapters()` registers
`ClaudeCodeAdapter` instances for both GLM roots. `ClaudeCodeAdapter` maps
`.claude-glm` and `.claude-glmc` to `SourceName.glm`.

The source is path-owned: a parseable conversation under either root is `glm`
even when the first `message.model` is missing or does not contain a GLM
substring.

## Current Local Audit

2026-07-02 local smoke over the GLM provider roots:

| Root | Listed JSONL | Parsed conversations | Subagents | Parent links | Source |
|---|---:|---:|---:|---:|---|
| `~/.claude-glm/projects` | 1,177 | 1,154 | 1,136 | 1,136 | `glm` |
| `~/.claude-glmc/projects` | 776 | 768 | 765 | 765 | `glm` |
| **Total** | **1,953** | **1,922** | **1,901** | **1,901** | `glm` |

Model values in the current parseable corpus are path-owned metadata, not source
detectors: `glm-5.2` (1,581), explicit `<synthetic>` (229), no model field (18),
`frank/GLM-5.2` (47), `zai-org/GLM-5.2` (44),
`z-ai/glm-5.2-20260616` (2), and one dedicated OpenCode GLM model string.

Skipped files are non-conversation side channels: 30 workflow `journal.jsonl`
files with only `started` / `result` records, plus one local-command/system
injection session with no displayable conversation turn after filtering.

DB/runtime check from the same pass:

- Installed `/Applications/Engram.app` build `20260701074505` has 1,695 `glm`
  rows under `/Users/bing/.claude-glm/%` and `/Users/bing/.claude-glmc/%`: 1,154
  under `.claude-glm` and 541 under `.claude-glmc`.
- `file_index_state` has 1,695 `ok` and 29 `retry` rows for `glm`, all still
  schema version 1. `.claude-glm` locator coverage is closed, but a fresh parser
  smoke still saw 227 parseable `.claude-glmc` files outside `sessions` and
  absent from `file_index_state`, so exact `.claude-glmc` closure can move while
  GLM workflows are writing.
- A field-level DB comparison found 9 stale current `.claude-glmc` rows where
  DB counts/sizes lag an actively growing transcript family. The earlier
  1,570-row stale-count note was a retained-TS audit-tooling false positive
  except for these 9 rows: TS was counting non-visible Claude `tool_result` rows
  that the Swift product already drops. This audit did not mutate
  `/Users/bing/.engram/index.sqlite`.

## Gotchas

- GLM provider-root sessions are Claude Code JSONL at the byte level.
- Native `~/.claude/projects` files whose model or prompt text mentions GLM are
  not reclassified as `glm`; the current native-root derived-source split only
  handles MiniMax and LobsterAI.
- Installed runtime locator coverage is closed for `.claude-glm`; `.claude-glmc`
  still has a 227-file active-write frontier in the current local corpus.
- Current DB count fields align for `.claude-glm`; `.claude-glmc` still has 9
  active stale rows plus the 227-file frontier.
