# Grok 会话格式

最后核对：2026-09-22（产品适配器）

> **依据。** Swift 产品解析器
> `macos/Shared/EngramCore/Adapters/Sources/GrokAdapter.swift`。没有 TypeScript
> 参考适配器；`SOURCE_NAMES` 含 `grok` 只为 schema/文档对齐。archive/collector
> 可以把 `summary.json` 当作最后的主文件，那是它们自己的合同，不在本适配器里。

## 1. 概览

**Grok** 在 `~/.grok/sessions/` 下以目录存每个会话。

- **内容：** 会话目录，不是单文件 JSONL。
- **位置：** `~/.grok/sessions/<百分号编码的 cwd>/<session-id>/`。
  项目目录把 `A-Za-z0-9-._~` 以外的每个 UTF-8 字节编成大写十六进制，`/` 变成 `%2F`。
- **定位优先级：** `chat_history.jsonl` → `updates.jsonl` → `summary.json`。
  有 JSONL 时产品解析走转录；`summary.json` 和 `prompt_context.json` 提供
  元数据（`id`、时间、cwd、标题、模型）。

## 2. 会话目录里的文件

| 文件 | Engram 是否读 | 用途 |
|---|---|---|
| `chat_history.jsonl` | **是 — 主转录** | 对话轮次 |
| `updates.jsonl` | **是 — 回退转录** | 备选 JSONL |
| `summary.json` | **是 — 元数据**（也是最后定位） | `info.id`、时间、标题、模型 |
| `prompt_context.json` | **是 — 元数据** | `working_directory` |
| compaction 归档分段 | **磁盘上声明了才读** | 作为 system/archive 消息前置 |

会话 id 来自 `summary.info.id`，否则用目录名。

## 3. Engram 映射

| 字段 | 来源 |
|---|---|
| `source` | `grok` |
| `id` | `summary.info.id` 或目录名 |
| `start_time` | `summary.created_at` 或首条 JSONL 时间 |
| `end_time` | `summary.updated_at` 或末条 JSONL 时间 |
| `cwd` | summary / prompt_context / 路径 |
| `model` | `summary.current_model_id` 或首条 JSONL 模型 |
| `summary` | 首条 user 文本，否则 `session_summary` / `generated_title` |
