# DeepSeek - Claude Code Provider-Root Session Format

Last researched: 2026-07-02.

DeepSeek sessions reached through the local `cc-ds` and `cc-dsc` wrappers use
Claude Code's on-disk JSONL format. Engram assigns the `deepseek` source from
the provider root path.

## Storage

| Aspect | Value |
|---|---|
| Engram source | `deepseek` |
| Roots | `~/.claude-ds/projects`, `~/.claude-dsc/projects` |
| On-disk schema | Same as Claude Code JSONL |
| Direct session locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| Subagent locators | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

For the shared record schema, see [claude-code.md](./claude-code.md).

## Engram Mapping

`SessionAdapterFactory.claudeCodeProviderAdapters()` registers
`ClaudeCodeAdapter` instances for both DeepSeek roots. `ClaudeCodeAdapter` maps
`.claude-ds` and `.claude-dsc` to `SourceName.deepseek`.

Provider-root classification is independent of `message.model`; the path owns
the source.

## Current Local Audit

2026-07-02 local smoke over the DeepSeek provider roots:

| Root | Listed JSONL | Parsed conversations | Subagents | Parent links | Source |
|---|---:|---:|---:|---:|---|
| `~/.claude-ds/projects` | 212 | 206 | 202 | 202 | `deepseek` |
| `~/.claude-dsc/projects` | 357 | 347 | 330 | 330 | `deepseek` |
| **Total** | **569** | **553** | **532** | **532** | `deepseek` |

Model values are not source classifiers for provider roots. Current parsed
metadata is `deepseek-v4-pro` (234), explicit `<synthetic>` (64), no model field
(3), plus proxy-returned GLM strings: `glm-5.2` (209), `frank/GLM-5.2` (36),
and `zai-org/GLM-5.2` (7). The local `cc-dsc` wrapper still names the `dsc`
provider root and passes the `deepseek-v4-pro` model, so these GLM model strings
are treated as backend/proxy metadata drift, not as source ownership.

The 16 skipped files are all workflow `journal.jsonl` status logs with only
`started` / `result` records.

DB/runtime check from the same pass:

- Installed `/Applications/Engram.app` build `20260701074505` has 553 `deepseek`
  rows under `/Users/bing/.claude-ds/%` and `/Users/bing/.claude-dsc/%`.
- `file_index_state` has 553 `ok` and 16 `retry` rows for `deepseek`, all still
  schema version 1. Locator coverage is closed for the parseable scanned
  provider-root corpus.
- The corrected visible-tool-result parser reports 0 field-stale current
  provider-root rows. The earlier 482-row stale-count note was a retained-TS
  audit-tooling false positive: TS was counting non-visible Claude
  `tool_result` rows that the Swift product already drops. This audit did not
  mutate `/Users/bing/.engram/index.sqlite`.

## Gotchas

- DeepSeek provider-root sessions are Claude Code JSONL at the byte level.
- Native `~/.claude/projects` sessions are not DeepSeek unless they are scanned
  through the explicit provider-root adapter.
- Do not reclassify provider-root sessions from `message.model`; current
  `cc-dsc` live metadata includes GLM model names even though the wrapper/root is
  DeepSeek.
- Installed runtime locator coverage is proven for the parseable scanned
  provider-root corpus; retry rows are non-conversation side channels, not
  missing source support.
- Current DB count fields align for indexed rows under the corrected parser
  semantics.
