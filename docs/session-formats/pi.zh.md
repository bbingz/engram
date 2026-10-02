# Pi 会话格式

最后核对：2026-09-21（产品适配器）

> **依据。** Swift 产品解析器
> `macos/Shared/EngramCore/Adapters/Sources/PiAdapter.swift`。没有 TypeScript
> 参考适配器；`SOURCE_NAMES` 含 `pi` 只为 schema/文档对齐。

## 1. 概览

**Pi** 是 JSONL 编码助手存储。Engram source id 为 `pi`。

- **内容：** 每个会话一份 JSONL。
- **位置：** `~/.pi/agent/sessions/**/*.jsonl`。
- **枚举：** 递归收集 `.jsonl`。会话 id 来自 `type: "session"` 的 `id`，否则用文件名。

## 2. 产品解析器消费的记录

| `type` | 作用 |
|---|---|
| `session` | 信封：`id`、`cwd`、`timestamp` |
| `model_change` | `modelId` |
| `message` | 嵌套 `message.role` + `message.content` |

角色：`user`、`assistant`、`toolResult`、`system`。匹配系统注入标记的 user
文本记为 `system`。缺少会话 id 和开始时间则判定为 malformed。

## 3. Engram 映射

| 字段 | 来源 |
|---|---|
| `source` | `pi` |
| `id` | `session.id` 或文件名 |
| `cwd` | `session.cwd` |
| `model` | `model_change.modelId` 或 `message.model` |
| `start_time` / `end_time` | 记录 `timestamp` |
| `summary` | 第一条非注入 user 文本，截断 200 字 |
