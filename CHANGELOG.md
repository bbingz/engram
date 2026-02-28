# Changelog

## [未发布]

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
