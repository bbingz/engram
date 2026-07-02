# Pi 会话格式

状态：已在 2026-06-30 provider 审计中恢复；当前 live-state verification 更新于 2026-07-01。

## 存储位置

- 根目录：`~/.pi/agent/sessions`
- locator 形态：`~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<session-id>.jsonl`
- 2026-07-01 本机审计：230 个 JSONL，恢复后的 TypeScript adapter 可解析 230/230。

## 记录类型

Pi 使用顶层 `type` 字段区分 JSONL 记录。

| Type | 用途 | Engram 处理 |
|---|---|---|
| `session` | 会话元数据：`id`、`timestamp`、`cwd`、`version` | 提供 `id`、`startTime`、`cwd`。 |
| `model_change` | 当前模型切换：`modelId` | 最后观测到的 `modelId` 成为会话 `model`（后出现的 `model_change` 覆盖先前的；若不存在则回退到消息级 `model`）。 |
| `thinking_level_change` | 思考模式元数据 | 不计入消息数。 |
| `message` | `message` 下的用户、助手、工具和系统内容 | 按 `message.role` 解析。 |
| `compaction` | compaction 摘要元数据：`summary`、`tokensBefore`、`firstKeptEntryId`、文件列表 | 不计入消息数，不 stream。 |
| `custom` | 自定义 side-channel 记录，例如 `web-search-results` | 不计入消息数，不 stream。 |

`message.content` 是 part 数组。文本 part 使用 `{type:"text", text}`。
助手工具调用使用 `{type:"toolCall", name, arguments}`，Engram 会挂到助手消息的
`toolCalls` 上。当前 live 文件还包含 `thinking` 和 `image` part；Swift 和 TypeScript
adapter 都会忽略这些 part，因为 `extractText` 只拼接 `text` part，`extractToolCalls`
只读取 `toolCall` part。

## Role 映射

| Pi role | Engram role | 计数 |
|---|---|---|
| `user` | `user`，除非是系统注入 | user |
| `assistant` | `assistant` | assistant |
| `toolResult` | `tool` | tool |
| `system` | `system` | 只计 system |
| `bashExecution` | 跳过 | 当前 adapter 不计数、不 stream |

系统注入过滤沿用常见 Engram adapter 规则：`AGENTS.md`、`<INSTRUCTIONS>`、
`<local-command-caveat>`、`<environment_context>`。

## 解析器说明

- Swift 源码：`macos/Shared/EngramCore/Adapters/Sources/PiAdapter.swift`
- TypeScript 源码：`src/adapters/pi.ts`
- 测试：
  - `AdapterMessageCountTests.testPiAdapterListsParsesAndStreamsSessions`
  - `tests/adapters/pi.test.ts`

## 当前本机审计

2026-07-01 live smoke 发现：

- 列出 230 个 JSONL，230/230 可解析；0 条 malformed JSON line。
- 顶层 record count：230 个 `session`、239 个 `model_change`、234 个
  `thinking_level_change`、9,235 个 `message`、8 个 `compaction`、2 个 `custom`。
- `message.role` count：452 个 `user`、3,758 个 `assistant`、5,024 个
  `toolResult`、1 个 `bashExecution`。
- content part count：6,734 个 `text`、3,133 个 `thinking`、5,028 个
  `toolCall`、2 个 `image`。
- 解析后的 message count：452 user、3,758 assistant、5,024 tool、0 system。
- 230/230 session 都有 `session` 元数据记录和 `model_change` 记录；观测到的最终
  model 为 `gpt-5.4`(164)、`gpt-5.3-codex`(21)、`mimo-v2.5-pro`(17)、
  `claude-sonnet-4-6`(14)、`claude-opus-4-6-thinking`(9)、`gpt-5.5`(5)。
- Adapter streaming 与解析计数完全一致：stream 出 9,234 条 transcript message，
  stream/count mismatch 为 0。

已安装 `/Applications/Engram.app` build `20260701074505` 现在在
`/Users/bing/.pi/agent/sessions/%` 下有 230 个 `pi` 行，`file_index_state`
有 230 个 `pi` 行且 `parse_status='ok'`。Runtime DB coverage 现在匹配当前
230/230 个已解析 session 文件，且缺失 locator 为 0、DB-only locator 为 0、
当前行字段级 stale 为 0。
