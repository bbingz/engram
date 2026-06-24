# 子会话与会话归档容量排查报告（2026-06-24）

## 调研范围
- 系统目录：`~/.codex/sessions`、`~/.engram`、`~/.codex/backups`、`~/.codex/logs_2.sqlite*`、`~/.claude/backups`
- 数据源：`~/.engram/index.sqlite`（SQLite）
- 生成时间（本机）：`2026-06-24 13:55:10 CST`

## 1. 子 Agent（会话索引）识别现状
- `sessions` 总数：`13222`
- `agent_role='subagent'`：`4756`（占总量 `35.95%`，索引体积约 `1272.47 MB`，约占索引体积 `9.45%`）
- `agent_role` 为空：`4649`（占总量 `35.15%`）
- 其余 `agent_role`：`3892`
- `skip/premium/normal/lite` 分布：
  - `skip: 10328`（`2636.4 MB`）
  - `premium: 1552`（`10822.51 MB`）
  - `normal: 1038`（`110.25 MB`）
  - `lite: 304`（`29.29 MB`）
- `source` 维度下，`agent_role='subagent'` 主要来自：
  - `claude-code: 4587`
  - `kimi: 98`
  - `qoder: 44`
  - `codex: 27`
- 根会话与子会话：
  - `parent_session_id is null`: `5985`
  - `child session`: `7237`
- `offload_state='offloaded'` 仅 `6` 条（约 `177.5 MB`），其余为 `local`。
- 访问迹象近乎缺失：
  - `last_accessed_at` 非空：`1` 条
  - `access_count > 0`：`1` 条

### 基于文件路径的“子 Agent”识别（附加视角）
- 文件路径包含 `/subagents/` 的会话：`5783`
  - 其中 `agent_role='subagent'`：`4729`
  - 其余 `1054` 是其他角色路径也走了 `subagents` 目录（`general-purpose`、`Explore`、`kimi:*` 等）
- `agent_role='subagent'` 但文件路径不含 `/subagents/`：`27`（小体量，主要为历史/例外写入）

### 子 Agent 会话体量分层
- `size_bytes > 100MB` 的 `subagent`：`0`（这类大文件主要是顶层/非 subagent）
- Top 10 子 Agent 大文件（MB）：
  - 14.32 / 12.48 / 9.81 / 8.35 / 8.01 / 7.77 / 7.57 / 7.53 / 7.48 / 7.47

## 2. 磁盘占用现状
- `~/.codex/sessions`：`7.8G`，`2567` 个 `*.jsonl`
- `~/.engram`：`747M`
- `~/.engram/index.sqlite`：`535M`，`index.sqlite-wal` 36K、`index.sqlite-shm` 608K
- `~/.codex/logs_2.sqlite`：`1.34G`，`logs_2.sqlite-wal` `230MB`
- `~/.engram/backups/engram-index-raw-20260624-122241.sqlite.zst`：`207M`
- `~/.codex/backups` 与 `~/.claude/backups` 未出现 `.backup-* 8个 519M` 这类批量备份；仅有零散的 `.bak`/`*.backup.*` 小文件（小于 1MB~1GB 以内的单文件）。
- `~/.codex/sessions` 最大文件（前 8）：
  - `645.35 MB`
  - `480.69 MB`
  - `438.35 MB`
  - `263.79 MB`
  - `225.85 MB`
  - `207.70 MB`
  - `188.91 MB`
  - `186.25 MB`

## 3. 年龄与索引“可清理性”
- `start_time` 年龄桶（按会话）：
  - `0-7d`：`446` 会话，`694.95 MB`
  - `7-30d`：`1167` 会话，`1647.89 MB`
  - `30-90d`：`7551` 会话，`7090.03 MB`
  - `90-180d`：`3985` 会话，`3809.53 MB`
  - `180d+`：`73` 会话，`216.51 MB`
- 可见点：`30-90d` 与 `90-180d` 的容量占比最大，但目前缺少持续“访问”字段，难以从“是否被机器回溯”维度做自动裁剪。

## 4. 建议（按你“允许有一定丢失、以机器回溯为主”的前提）
1. 先做一次高压缩整机可恢复归档再清理：
   - 归档 `~/.codex/sessions` 与 `~/.engram/index.sqlite`（含 WAL/SHM）到本地/外挂盘；
   - 归档文件命名最好按时间戳和版本打点，便于回滚。
2. 清理先手不碰 premium：
   - 先处理 `source`/`tier='skip'` 且 `agent_role='subagent'` 为主线；
   - 非人类子会话（`agent_role='subagent'`）优先出清，保留 `7-30d` 的最小窗口以防短期回滚检索。
3. 同步补齐生命周期元数据再做自动化：
   - 目前 `last_accessed_at/access_count` 基本为空，当前无法按“回溯频次”做决策；
   - 建议优先补字段更新链路，再做“自动老化 + 自动归档”。
4. 缩小扫描范围：
   - 当前的超大文件大多不是 subagent，可仅对 `size_bytes > 20MB` 且 `tier='skip'` 这类分层进行压缩归档，避免误删“高价值”会话。

## 5. 关联现有资料
- 已有可复用的设计方向可参考：`docs/engram-lifecycle-upgrade-plan.md`

