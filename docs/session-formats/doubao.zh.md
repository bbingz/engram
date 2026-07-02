# Doubao - Claude Code Provider-Root 会话格式

Last researched: 2026-07-02.

通过本机 `cc-doubao` wrapper 产生的 Doubao 会话使用 Claude Code 的磁盘 JSONL 格式。Engram 根据 provider root 路径分配 `doubao` source。

## 存储位置

| 方面 | 取值 |
|---|---|
| Engram source | `doubao` |
| 根目录 | `~/.claude-doubao/projects` |
| 磁盘 schema | 与 Claude Code JSONL 相同 |
| 直接会话 locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| 子代理 locator | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

共享记录 schema 见 [claude-code.md](./claude-code.md)。

## Engram 映射

`SessionAdapterFactory.claudeCodeProviderAdapters()` 注册 `ClaudeCodeAdapter(projectsRoot: "~/.claude-doubao/projects")`。`ClaudeCodeAdapter.providerRootSources` 将 `.claude-doubao` 路径组件映射到 `SourceName.doubao`，因此 source 分配不依赖 `message.model`。

## 当前本机审计

2026-07-02 对 `~/.claude-doubao/projects` 的本机 smoke 列出 30 个 JSONL 文件，并将 28 个 conversation 文件解析为 `doubao`。跳过的文件是 workflow `journal.jsonl` 状态日志。

这 28 个可解析会话里，24 个是带 parent link 的 subagent 会话；28/28 的 `originator` 都是 `Claude Code`，`model` 都是 `doubao-seed-2.0-code`。

已安装 `/Applications/Engram.app` build `20260701074505` 现在在
`/Users/bing/.claude-doubao/%` 下有 28 个 `doubao` 行；`file_index_state`
对该 source 有 28 个 `ok` 行和 2 个 `retry` 行。对可解析扫描语料而言，locator
覆盖已闭合。

30 个 Doubao `file_index_state` 行仍然都是 schema version 1，但修正后的
visible-tool-result parser 报告 0 个字段陈旧的当前 provider-root 行。此前 26 行
stale-count 结论是 retained TS 审计工具误报：TS 当时会计入 Swift 产品已丢弃的非可见
Claude `tool_result` 行。本次审计没有修改
`/Users/bing/.engram/index.sqlite`。

## 注意点

- Doubao provider-root 会话在字节层面是 Claude Code JSONL。
- Native `~/.claude/projects` 会话不会因为文本提到 Doubao 自动归为 Doubao；需要通过显式 provider-root adapter 扫描。
- 已安装 runtime 的 locator 覆盖已覆盖本次扫描中可解析的 provider-root 语料；剩余非
  `ok` 文件是 retry side channel，不是缺少 source 支持。
- 按修正后的 parser 语义，已索引行的 DB count 字段已对齐。
