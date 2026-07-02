# Mimo - Claude Code Provider-Root 会话格式

Last researched: 2026-07-02.

通过本机 `cc-mimo` 和 `cc-mimosg` wrapper 产生的 Mimo 会话使用 Claude Code 的磁盘 JSONL 格式。Engram 根据 provider root 路径分配 `mimo` source，而不是靠模型名子串检测。

## 存储位置

| 方面 | 取值 |
|---|---|
| Engram source | `mimo` |
| 根目录 | `~/.claude-mimo/projects`，`~/.claude-mimosg/projects` |
| 磁盘 schema | 与 Claude Code JSONL 相同 |
| 直接会话 locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| 子代理 locator | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

记录类型、内容块、计数、时间戳、cwd 提取、tool message 和子代理 transcript 细节见 [claude-code.md](./claude-code.md)。磁盘字节是 Claude Code JSONL；差异只在 root 到 source 的映射。

## Engram 映射

`SessionAdapterFactory.claudeCodeProviderAdapters()` 为两个 Mimo root 注册 `ClaudeCodeAdapter`。`ClaudeCodeAdapter` 将 `.claude-mimo` 和 `.claude-mimosg` 路径组件映射为 `SourceName.mimo`。

Provider-root 模式有两个关键属性：

- 这些 root 下所有可解析 conversation 的 `source` 固定为 `mimo`。
- `originator` 设置为 `Claude Code`，保留会话由 Claude Code 兼容客户端写入这一事实。

这种路径 source 分配与 native `~/.claude/projects` 下 MiniMax/LobsterAI 使用的模型检测派生 source 是两条不同路径。

## 当前本机审计

2026-07-02 对 Mimo provider roots 的本机 smoke：

| Root | Listed JSONL | Raw records | Parsed conversations | 带 parent link 的 subagents | Source | Model 说明 |
|---|---:|---:|---:|---:|---|---|
| `~/.claude-mimo/projects` | 180 | 14,578 | 174 | 168 | `mimo` | 带 model 的记录大多是 `mimo-v2.5-pro`，另有 4 条 `<synthetic>` |
| `~/.claude-mimosg/projects` | 92 | 10,634 | 89 | 80 | `mimo` | 带 model 的记录大多是 `mimo-v2.5-pro`，另有 11 条 `<synthetic>` |
| **Total** | **272** | **25,212** | **263** | **248** | `mimo` | 0 条畸形行，0 个 stream/count mismatch |

跳过的文件是 workflow `journal.jsonl` 状态日志，不是正常 conversation parser failure。

两个非 `mimo-v2.5-pro` 案例来自原始 transcript 本身,不是 source 映射漂移:一个 assistant
message 明确携带 `message.model = "<synthetic>"`;另一个子会话只有 user/attachment 记录,
没有 assistant model 字段。

已安装 `/Applications/Engram.app` build `20260701074505` 现在在
`/Users/bing/.claude-mimo/%` 和 `/Users/bing/.claude-mimosg/%` 下有 263 个 `mimo`
行。`file_index_state` 对 `mimo` 有 263 个 `ok` 行和 9 个 `retry/malformedJSON` 行，
且全部仍是 schema version 1。locator diff 已闭合（0 个缺失的可解析 adapter locator，
0 个 DB-only current locator），且修正后的 visible-tool-result parser 报告 0 个字段陈旧的
当前 provider-root 行。此前 261 行 stale-count 结论是 retained TS 审计工具误报：TS 当时会计入
Swift 产品已丢弃的非可见 Claude `tool_result` 行。

## 注意点

- 不要因为 native `~/.claude/projects` 文件正文提到 Mimo 就归类为 Mimo。Provider-root source 来自 `.claude-mimo` 或 `.claude-mimosg` 路径组件。
- 嵌套 workflow subagent 属于支持的 locator surface，因为 `ClaudeCodeAdapter.listSessionLocators()` 会递归扫描 `subagents/`。
- 已安装 runtime 的 locator 覆盖已覆盖本次扫描中可解析的 provider-root 语料；retry 行是非
  conversation side channel,不是缺少 source 支持。按修正后的 parser 语义，已索引行的
  count 字段已对齐。
