# Grok Build - 会话格式参考

Last researched: 2026-07-01.

本文说明当前 Grok Build 会话存储，以及 Engram Swift 产品适配器和 retained TypeScript 工具适配器如何消费它。Grok 是独立 source，不是 Claude Code provider-root 叠加层。

## 存储位置

| 方面 | 取值 |
|---|---|
| Engram source | `grok` |
| 适配器 | Swift: `macos/Shared/EngramCore/Adapters/Sources/GrokAdapter.swift`; TS retained tooling: `src/adapters/grok.ts` |
| 根目录 | `~/.grok/sessions` |
| 会话布局 | `~/.grok/sessions/<encoded-cwd>/<session-id>/` |
| locator 优先级 | `chat_history.jsonl`，然后 `updates.jsonl`，然后 `summary.json` |
| 元数据 sidecar | `summary.json`，`prompt_context.json` |

`GrokAdapter.listSessionLocators()` 扫描 `~/.grok/sessions` 下的项目目录和项目下的会话目录。只要会话目录里存在上述任一优先 locator，就会被视为候选会话。若最初选中的是 `summary.json`，解析时仍会优先使用同目录里的 `chat_history.jsonl` 或 `updates.jsonl`。

## 解析记录

Grok transcript 是逐行 JSON。当前 Swift parser 对这些当前记录类型做映射或有意跳过：

| 记录类型 | Engram role | 说明 |
|---|---|---|
| `user` | user | 读取 `content`；存在 `<user_query>...</user_query>` 外层时会剥掉。 |
| `assistant` | assistant | 读取 `content`、`tool_calls`、`usage`；无内容且无工具调用的 assistant 记录会丢弃。 |
| `tool_result` | tool | 读取非空 `content`。 |
| `system` | 只计入 system count | 作为系统元数据计数，不作为聊天 turn 流出。 |
| `reasoning` | 跳过 | 当前文件存储 `summary` 以及加密 reasoning 内容；Engram 不暴露 chain-of-thought/reasoning 记录。 |
| `backend_tool_call` | 跳过 | 后端搜索/工具元数据（`web_search`、`x_search` 等）；不作为聊天 turn 流出。 |

属于系统注入的 user 记录会计入 system message，不作为聊天 turn 暴露。当前过滤包含 `# AGENTS.md instructions`、`<INSTRUCTIONS>`、`<environment_context>`、`<system-reminder>` 等 agent 上下文包装。

## 元数据映射

| Engram 字段 | 来源 |
|---|---|
| `id` | `summary.info.id`，否则会话目录名 |
| `cwd` | `summary.info.cwd`，然后 `prompt_context.working_directory`，再退回解码后的项目目录 |
| `startTime` | `summary.created_at`，然后第一条 transcript timestamp，再退回 transcript/session mtime |
| `endTime` | `summary.updated_at`，然后最后一条 transcript timestamp |
| `model` | `summary.current_model_id`，然后第一条 transcript model |
| `summary` | 第一条 user message，然后 `summary.session_summary`，再到 `summary.generated_title` |
| `filePath` | 主 transcript 路径，不一定是最初选中的 locator |

## 当前本机审计

最新 2026-07-01 recheck 在 `~/.grok/sessions/<encoded-cwd>/<session>/` 下找到 344 个 Grok session 目录。当前每个目录都是同一个四文件形态：`chat_history.jsonl`、`updates.jsonl`、`summary.json`、`prompt_context.json`；因此每个当前 preferred locator 都是 `chat_history.jsonl`。这取代了同日更早的 345-session 计数：一个 `2026-Teaching-Plan` session 目录已经从磁盘消失。

当前 live transcript 有 0 条 raw JSON.parse 失败行。retained TS live smoke 和 env-gated Swift live smoke 都解析 344/344 个当前 session；Swift live smoke 向临时 DB 写入 344 个 `grok` rows。观测到的 record count 为：344 个 `system`、1,347 个 `user`、6,923 个 `assistant`、13,741 个 `tool_result`、7,614 个 `reasoning`、489 个 `backend_tool_call`。经过 parser filter 之后，映射出的 message count 为 470 user、6,923 assistant、13,605 tool、1,221 system。344 个当前 session 都由 `summary.json` 提供 `info.cwd` 和 `current_model_id`；当前观测到的 model 为 `grok-build` 和 `grok-composer-2.5-fast`。retained TS 工具也注册了 `GrokAdapter`，并用 fixture 覆盖同一条元数据、`<user_query>` 剥离、assistant tool-call 和 `tool_result` 映射路径。

已安装 `/Applications/Engram.app` build `20260701074505` 在
`/Users/bing/.grok/sessions/%` 下有 345 个 `grok` 行，`file_index_state` 也有
345 个 `grok` 行且 `parse_status='ok'`。344 个当前 parser locator 全部存在且
当前行字段级 stale 为 0，但一个已删除的
`/Users/bing/.grok/sessions/%2FUsers%2Fbing%2F-Code-%2F2026-Teaching-Plan/019e81cd-c8e3-79a3-a9a9-f49363691a29/chat_history.jsonl`
locator 仍作为 DB-only session row 和 DB-only `file_index_state` row 保留。因此结论现在是
`SOURCE_READY / CURRENT_LOCATOR_PASS / DB_ONLY_STALE_1`。

## 注意点

- `summary.json` 只是 fallback locator。同目录存在 transcript JSONL 时，Engram 会解析 transcript。
- `prompt_context.json` 只提供元数据，不是 transcript。
- 解码项目目录只是 fallback；存在 `summary.json` 或 `prompt_context.json` 的 cwd 元数据时优先使用元数据。
- 空 assistant/tool 记录会从 streamed messages 和计数中丢弃。
- 当前 live 文件中存在 `reasoning` 和 `backend_tool_call` 记录，但适配器会有意跳过；只暴露 user/assistant/tool_result turns。
