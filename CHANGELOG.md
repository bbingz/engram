# Changelog

## [0.0.1.0] - 2026-04-13

### Added
- **Insights 文本存储 + FTS 搜索**：新增 `insights` 表和 `insights_fts`（trigram），即使没有 embedding provider 也能保存和搜索知识
- **save_insight 优雅降级**：无 embedding 时自动保存为纯文本，有 embedding 时双写（向量 + 文本）
- **get_memory / search / get_context FTS 回退**：无 embedding provider 时通过 FTS 关键词搜索 insights，附带降级警告
- **Insight embedding 回填**：daemon 启动时自动将纯文本 insights 升级为向量（当 embedding provider 可用时）
- **MCP 工具 API 参考文档**：`docs/mcp-tools.md` 记录全部 19 个 MCP 工具
- **CONTRIBUTING.md**：新增贡献者指南

### Changed
- **db.ts God Object 拆分**：1869 行的 `src/core/db.ts` 拆分为 10 个领域模块 + facade 类 + ESM re-export shim（`src/core/db/`）
- **测试覆盖率提升**：691 → 767 tests，67% → 75% lines，覆盖率阈值恢复为 75/70/80

### Fixed
- **Flaky hygiene test**：时间戳竞态条件修复（1ms → 50ms delay）
- **CJK insight 搜索**：insight FTS 搜索增加 CJK LIKE 回退（与 session 搜索一致）
- **Insight FTS 原子性**：`saveInsightText` 包裹在事务中
- **importance 默认值对齐**：repo 默认值从 5 改为 3（与工具文档一致）

### Removed
- 移除未使用依赖 `js-yaml`
- 清理 14 个未使用导出、53 个未使用导出类型

---

## [未发布]

### 新功能

#### Antigravity 会话项目识别（`src/adapters/grpc/cascade-client.ts`、`src/adapters/antigravity.ts`）
- **从 `GetAllCascadeTrajectories` 提取项目路径**：将 `listConversations()` 改为 ConnectRPC JSON 调用（gRPC proto 中未定义 `workspaces` 字段），从 `workspaces[0].workspaceFolderAbsoluteUri` 提取 `cwd`（去掉 `file://` 前缀）。
- **时间格式适配**：ConnectRPC JSON 返回 ISO 8601 字符串（如 `"2026-02-20T10:14:41.164983Z"`），而非 gRPC 的 `{seconds: number}` 格式，兼容两种格式。
- **标题来源修正**：ConnectRPC JSON 没有 `annotations.title` 字段，title 就是 `summary` 字段。
- **gRPC 降级**：ConnectRPC JSON 失败时回退到 `listConversationsGrpc()`（无 workspace 信息但仍可列出会话）。
- **扫描 `.pb` 文件补全旧会话**：`GetAllCascadeTrajectories` 只返回最近 ~10 个会话，但 `.pb` 目录有全部历史。新增 `syncFromPbFiles()` 方法扫描 `~/.gemini/antigravity/conversations/*.pb`，对 API 未覆盖的 ID 逐个调用 `GetCascadeTrajectory` 读取内容，用文件 mtime/birthtime 作为时间。
- 示例：原先只有 10 个会话 → 现在全部 46 个会话（2025-11 至 2026-02）都能读取，项目信息也正确关联。

#### Antigravity 会话完整内容读取（`src/adapters/grpc/cascade-client.ts`）
- **通过 `GetCascadeTrajectory` API 读取完整对话**：发现 `ConvertTrajectoryToMarkdown` 返回空正文是因为它需要传入完整 trajectory 对象而非仅 ID。真正的消息读取 API 是 `GetCascadeTrajectory`（ConnectRPC JSON 协议），返回所有 trajectory steps。
- **解析三类步骤为用户/助手消息**：
  - `CORTEX_STEP_TYPE_USER_INPUT` → `userInput.userResponse` → 用户消息
  - `CORTEX_STEP_TYPE_PLANNER_RESPONSE` → `plannerResponse.response` → AI 回复
  - `CORTEX_STEP_TYPE_NOTIFY_USER` → `notifyUser.notificationContent` → AI 通知
- **三级降级策略**：优先 `GetCascadeTrajectory`（ConnectRPC JSON），若失败回退到 `ConvertTrajectoryToMarkdown`（gRPC），最后用 `summary` 字段兜底。
- 示例：原先所有会话 0 条消息 → 现在 "Analyzing Log Exploits" 会话读出 4 条用户消息 + 4 条 AI 回复。

### 修复

#### Antigravity 适配器 gRPC 端口检测（`src/adapters/grpc/cascade-client.ts`）
- **macOS `lsof -p PID` 不过滤 LISTEN 行的问题**：原先用 `lsof -p ${pid} -i -P -n | grep LISTEN` 会把所有进程的监听端口都列出来（如 rapportd:49152），导致连接到错误端口。现改为 `lsof -i -P -n | grep "^[^ ]*[[:space:]]*${pid}[[:space:]].*LISTEN"` 按 PID 列精确过滤。
- **TLS 端口与明文 gRPC 端口共存问题**：Language server 同时监听 TLS 端口（如 :57814）和明文 gRPC 端口（如 :57815）。现在会逐个探测所有候选端口——使用 insecure 客户端连接 TLS 端口时会在 ~16ms 内失败（code 14 UNAVAILABLE），取第一个成功接受明文连接的端口。
- **新版 Antigravity（1.18+）不再写 JSON 发现文件**：改为从 `ps aux` 解析 `language_server_macos_arm` 进程的命令行参数，提取 `--csrf_token` 和 PID，再通过 lsof 找端口。保留读取旧版 JSON 文件的 `fromDaemonDir()` 作为兜底。

#### Antigravity 会话内容展示（`src/adapters/antigravity.ts`）
- **会话显示「no messages found」**：Cascade 智能体会话通常只有工具调用/文件编辑，没有用户↔助手的对话，导致 `ConvertTrajectoryToMarkdown` 返回的 Markdown 中没有 `## User` / `## Cascade` 段落。现在当解析到 0 条消息时，自动将 gRPC 返回的 `summary` 字段作为一条合成助手消息写入缓存，确保会话有内容可展示。
- **会话 summary 为空**：将 `conv.summary`（如"Reviewing Refactoring Progress"）同时写入缓存 meta，`parseSessionInfo` 优先取 `meta.summary` 作为会话摘要展示。

#### 索引器去重一致性（`src/core/indexer.ts`）
- **Antigravity 会话显示 0 KB**：缓存文件本身只有 135 字节（仅 meta 行），而数据库记录的 `size_bytes` 也是 135，导致重复跳过真实的 `.pb` 文件大小。新增两段去重：先用 `fileStat.size` 快速跳过，若不匹配再用 `info.sizeBytes`（即 `.pb` 文件大小）二次去重。

#### 孤儿 Node 进程（`macos/CodingMemory/Core/IndexerProcess.swift`）
- **Xcode 用 SIGKILL 终止 App 时不触发 `applicationWillTerminate`**，导致子 Node 进程变成孤儿占满 CPU（发现时有 10 个孤儿进程，每个占用 20%~84% CPU）。现在在 `IndexerProcess.start()` 启动新进程前，先用 `pkill` 清理同名旧进程。

---

## 历史版本（按提交时间倒序）

### feat: Antigravity 适配器（gRPC）& Windsurf 适配器
- 接入 Antigravity（Google 的 AI 编程 IDE）的 Language Server gRPC API，通过 `GetAllCascadeTrajectories` 获取会话列表，`ConvertTrajectoryToMarkdown` 获取内容
- 新增 Windsurf 适配器

### feat: agent 检测、会话排序、多选过滤、时间轴展开
- Claude Code 会话中识别 agent 子进程消息并标记 badge
- 会话列表按来源/项目/时间多维度排序
- 多选过滤器（来源、项目）支持显示条目数量
- 时间轴视图支持展开/折叠单个条目

### feat: 消息 clean/raw 视图、系统注入过滤
- 对话详情页新增 clean 视图（过滤掉系统注入的上下文）和 raw 视图（显示完整内容）

### feat: 菜单栏右键 → 独立窗口
- 右键菜单栏图标可打开独立的 Session 浏览窗口

### feat: LaunchAgent 登录时自启动

### feat: 完整 SwiftUI 界面
- SessionList、搜索、时间轴、收藏夹、设置

### feat: 发布脚本（归档、公证、DMG 打包）

### fix: MCP Server 各类启动问题
- HTTP/1.1 Unix socket 通信
- stamp 文件、serverInfo、写入池泄漏
- stdin 关闭时退出，防止 MCP 孤儿进程
