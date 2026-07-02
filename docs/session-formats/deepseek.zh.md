# DeepSeek - Claude Code Provider-Root 会话格式

Last researched: 2026-07-02.

通过本机 `cc-ds` 和 `cc-dsc` wrapper 产生的 DeepSeek 会话使用 Claude Code 的磁盘 JSONL 格式。Engram 根据 provider root 路径分配 `deepseek` source。

## 存储位置

| 方面 | 取值 |
|---|---|
| Engram source | `deepseek` |
| 根目录 | `~/.claude-ds/projects`，`~/.claude-dsc/projects` |
| 磁盘 schema | 与 Claude Code JSONL 相同 |
| 直接会话 locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| 子代理 locator | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

共享记录 schema 见 [claude-code.md](./claude-code.md)。

## Engram 映射

`SessionAdapterFactory.claudeCodeProviderAdapters()` 为两个 DeepSeek root 注册 `ClaudeCodeAdapter`。`ClaudeCodeAdapter` 将 `.claude-ds` 和 `.claude-dsc` 映射到 `SourceName.deepseek`。

Provider-root 分类独立于 `message.model`；source 由路径拥有。

## 当前本机审计

2026-07-02 对 DeepSeek provider roots 的本机 smoke：

| Root | Listed JSONL | Parsed conversations | Subagents | Parent links | Source |
|---|---:|---:|---:|---:|---|
| `~/.claude-ds/projects` | 212 | 206 | 202 | 202 | `deepseek` |
| `~/.claude-dsc/projects` | 357 | 347 | 330 | 330 | `deepseek` |
| **Total** | **569** | **553** | **532** | **532** | `deepseek` |

provider-root 的 model 值不是 source 分类依据。当前可解析 metadata 是
`deepseek-v4-pro` 234 个，显式 `<synthetic>` 64 个，无 model 字段 3 个；
另外有代理返回的 GLM 字符串：`glm-5.2` 209 个，`frank/GLM-5.2` 36 个，
`zai-org/GLM-5.2` 7 个。本机 `cc-dsc` wrapper 仍然使用 `dsc` provider root，
并传入 `deepseek-v4-pro` model，因此这些 GLM model 字符串按
backend/proxy metadata 漂移处理，不改变 source 归属。

16 个跳过文件全部是 workflow `journal.jsonl` 状态日志，只包含
`started` / `result` 记录。

同次 DB/runtime 检查：

- 已安装 `/Applications/Engram.app` build `20260701074505` 在
  `/Users/bing/.claude-ds/%` 和 `/Users/bing/.claude-dsc/%` 下有 553 个
  `deepseek` 行。
- `file_index_state` 对 `deepseek` 有 553 个 `ok` 行和 16 个 `retry` 行，全部仍是
  schema version 1。对可解析扫描语料而言，locator 覆盖已闭合。
- 修正后的 visible-tool-result parser 报告 0 个字段陈旧的当前 provider-root 行。
  此前 482 行 stale-count 结论是 retained TS 审计工具误报：TS 当时会计入 Swift 产品已丢弃的非可见
  Claude `tool_result` 行。本次审计没有修改 `/Users/bing/.engram/index.sqlite`。

## 注意点

- DeepSeek provider-root 会话在字节层面是 Claude Code JSONL。
- Native `~/.claude/projects` 会话不会自动归为 DeepSeek；需要通过显式 provider-root adapter 扫描。
- 不要按 `message.model` 反向重分类 provider-root session；当前 `cc-dsc`
  live metadata 虽然包含 GLM model 名，但 wrapper/root 仍然是 DeepSeek。
- 已安装 runtime 的 locator 覆盖已覆盖本次扫描中可解析的 provider-root 语料；retry
  行是非 conversation side channel，不是缺少 source 支持。
- 按修正后的 parser 语义，已索引行的 DB count 字段已对齐。
