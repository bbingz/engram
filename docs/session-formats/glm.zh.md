# GLM - Claude Code Provider-Root 会话格式

Last researched: 2026-07-02.

通过本机 `cc-glm` 和 `cc-glmc` wrapper 产生的 GLM 会话使用 Claude Code 的磁盘 JSONL 格式。Engram 根据 provider root 路径分配 `glm` source。

## 存储位置

| 方面 | 取值 |
|---|---|
| Engram source | `glm` |
| 根目录 | `~/.claude-glm/projects`，`~/.claude-glmc/projects` |
| 磁盘 schema | 与 Claude Code JSONL 相同 |
| 直接会话 locator | `<root>/<encoded-cwd>/<session-id>.jsonl` |
| 子代理 locator | `<root>/<encoded-cwd>/<session-id>/subagents/**/*.jsonl` |
| Originator | `Claude Code` |

共享记录 schema 见 [claude-code.md](./claude-code.md)。

## Engram 映射

`SessionAdapterFactory.claudeCodeProviderAdapters()` 为两个 GLM root 注册 `ClaudeCodeAdapter`。`ClaudeCodeAdapter` 将 `.claude-glm` 和 `.claude-glmc` 映射到 `SourceName.glm`。

source 由路径拥有：只要 conversation 位于任一 root 下且可解析，即使第一条 `message.model` 缺失或不包含 GLM 子串，也会归为 `glm`。

## 当前本机审计

2026-07-02 对 GLM provider roots 的本机 smoke：

| Root | Listed JSONL | Parsed conversations | Subagents | Parent links | Source |
|---|---:|---:|---:|---:|---|
| `~/.claude-glm/projects` | 1,177 | 1,154 | 1,136 | 1,136 | `glm` |
| `~/.claude-glmc/projects` | 776 | 768 | 765 | 765 | `glm` |
| **Total** | **1,953** | **1,922** | **1,901** | **1,901** | `glm` |

当前可解析语料里的 model 值只是路径归属后的 metadata，不参与 source
判定：`glm-5.2` 1,581 个，显式 `<synthetic>` 229 个，无 model 字段 18 个，
`frank/GLM-5.2` 47 个，`zai-org/GLM-5.2` 44 个，
`z-ai/glm-5.2-20260616` 2 个，以及 1 个 dedicated OpenCode GLM model 字符串。

跳过的文件都是非 conversation side channel：30 个 workflow `journal.jsonl`
只包含 `started` / `result` 记录；另有 1 个 local-command/system-injection
会话在过滤后没有可展示 conversation turn。

同次 DB/runtime 检查：

- 已安装 `/Applications/Engram.app` build `20260701074505` 在
  `/Users/bing/.claude-glm/%` 和 `/Users/bing/.claude-glmc/%` 下有 1,695 个
  `glm` 行：`.claude-glm` 1,154 个，`.claude-glmc` 541 个。
- `file_index_state` 对 `glm` 有 1,695 个 `ok` 行和 29 个 `retry` 行，全部仍是
  schema version 1。`.claude-glm` locator 覆盖已闭合，但新的 parser smoke
  仍看到 227 个可解析 `.claude-glmc` 文件不在 `sessions` 中、也没有
  `file_index_state`，因此外部 GLM workflow 持续写入时 `.claude-glmc` 的精确闭合数会移动。
- 字段级 DB 对比发现 9 个当前 `.claude-glmc` stale 行：DB 中的 counts/size 落后于一个仍在增长的
  transcript family。此前 1,570 行 stale-count 结论除这 9 行外是 retained TS 审计工具误报：
  TS 当时会计入 Swift 产品已丢弃的非可见 Claude `tool_result` 行。本次审计没有修改
  `/Users/bing/.engram/index.sqlite`。

## 注意点

- GLM provider-root 会话在字节层面是 Claude Code JSONL。
- Native `~/.claude/projects` 中模型或 prompt 正文提到 GLM 的文件不会被重新归类为 `glm`；当前 native-root 派生 source 只拆 MiniMax 和 LobsterAI。
- 已安装 runtime 的 locator 覆盖对 `.claude-glm` 已闭合；当前本机语料中的
  `.claude-glmc` 仍有 227 个 active-write frontier 文件。
- 按修正后的 parser 语义，`.claude-glm` 已索引行的 DB count 字段已对齐；
  `.claude-glmc` 仍有 9 个 active stale 行和 227 个 frontier 文件。
