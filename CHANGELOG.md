# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [0.0.1.1] - 2026-04-13

### Added
- **Agent Session Grouping**：父子会话关联，agent 子会话自动归组到父会话
  - Layer 1：从 Claude Code subagent 文件路径提取父 ID（确定性）
  - Layer 1b：Codex `originator === "Claude Code"` 自动标记 dispatched
  - Layer 1c：Gemini sidecar `.engram.json` 文件读取 parentSessionId
  - Layer 2：Dispatch pattern 匹配 + 时间/CWD 打分（启发式 → `suggested_parent_id`）
  - Layer 3：HTTP API 手动确认/解除关联
  - Swift UI：`ExpandableSessionCard` 折叠展开，HomeView/SessionList/Timeline 三处联动
  - Menu bar badge 显示今日父会话数量
- **Insight Hardening**：`save_insight` 输入校验（10~50K 字符）、文本去重、`sourceSessionId` 贯穿、删除双表一致性
- **Bootstrap Factories**：`createMCPDeps()` / `createDaemonDeps()` / `createShutdownHandler()` 统一初始化

### Changed
- **测试覆盖率提升**：767 → 909 tests

### Fixed
- MCP Server idle timeout 导致提前断连（已禁用 `idleTimeoutMs`）
- `importance` 默认值全局统一为 3

---

## [0.0.1.0] - 2026-04-13

### Added
- **本地语义搜索**：Viking/OpenViking 替换为 sqlite-vec + FTS5 trigram + RRF 融合
  - `save_insight` MCP 工具 — 主动记忆写入
  - `chunker.ts` — 消息边界优先的文本分块
  - `vector-store.ts` — chunk + insight 向量表 + model tracking
  - `embeddings.ts` — provider 策略（Ollama / OpenAI / Transformers.js opt-in）
  - `ServerInfo.instructions` — MCP 自描述协议
- **Insights 文本存储 + FTS 搜索**：`insights` 表 + `insights_fts`，无 embedding 也能保存和搜索知识
- **save_insight 优雅降级**：无 embedding → 纯文本保存 + warning；有 embedding → 双写
- **get_memory / search / get_context FTS 回退**：无 embedding provider 时关键词搜索 insights
- **Insight embedding 回填**：daemon 启动时自动将纯文本 insights 升级为向量
- **MCP 工具 API 参考文档**：`docs/mcp-tools.md` 记录全部 19 个 MCP 工具
- **CONTRIBUTING.md**：新增贡献者指南

### Changed
- **db.ts God Object 拆分**：1869 行拆分为 10 个领域模块 + facade 类 + ESM re-export shim（`src/core/db/`）
- **测试覆盖率提升**：691 → 767 tests，67% → 75% lines

### Fixed
- Flaky hygiene test 时间戳竞态条件修复
- CJK insight 搜索增加 LIKE 回退
- Insight FTS 原子性（事务包裹）

### Removed
- **Viking/OpenViking 全部移除**：删除 `viking-bridge.ts`（851 行）、`viking-filter.ts`、7 个 Viking API 路由、Swift 设置页面
- 移除未使用依赖 `js-yaml`
- 清理 14 个未使用导出、53 个未使用导出类型

---

## [0.0.0.9] - 2026-04-09

### Changed
- **Biome 代码规范强制执行**：pre-commit hook（husky + lint-staged），178 个文件 lint 清理
- **安全 + 性能 + DX 综合升级**：code review 修复轮次

---

## [0.0.0.8] - 2026-04-07

### Added
- **AI Audit Log**：所有外部 AI 调用（embedding、摘要、标题生成、Viking）的审计日志
  - `AiAuditWriter` + `AiAuditQuery` + schema migration
  - 自动提取 token 用量（input/output/cost）
  - `/api/ai/*` HTTP 端点查询审计记录
  - VikingBridge observer proxy 方法

### Fixed
- Viking `pushSession` parts 格式修复、`findMemories` URI 修复
- Viking 从 `addResource` 切换到 `pushSession` + composite session ID
- `get_context` 改用 memory snippets 替代 resource URI mapping
- `search` 增加 `vikingMemories` 记忆感知管道

---

## [0.0.0.7] - 2026-03-24

### Added
- **竞争力追赶（Competitive Catch-up）**
  - Health Rules Engine：9 项环境健康检查 + 可注入 `ShellExecutor`
  - Cost Advisor：费用优化引擎 + `get_insights` MCP 工具
  - `get_context` 环境数据块：活跃会话、今日费用、工具使用、告警
  - Hygiene 页面（macOS app）
  - Transcript 工具调用/结果卡片 + 语法高亮
- **可观测性（SP3 系列）**
  - SP3a：结构化日志（ALS 自动关联、stderr JSON、PII 过滤、request-id 贯穿）
  - SP3b：系统指标收集（DB query 自动计时 Proxy、FTS/vector 子查询计时、HTTP 错误计数）
  - SP3b-alerting：AlertRuleEngine + 6 条性能告警规则 + `alerts` 表
  - SP3d：AI 视觉验证（Kimi + Claude VLM 对比截图 AI 审查）
  - SP3e：测试覆盖扩展（33 个新测试，copilot/MCP/indexer/web/viking 错误路径）
- **自动化测试（SP1 + SP2）**
  - 截图对比管线 + baseline 管理
  - Test fixture 自动生成 + schema 校验
  - Viking quality test 脚本

### Fixed
- SQLite busy_timeout=5000ms 防止 `database is locked`
- Keychain 授权对话框问题（Debug 构建跳过 Keychain）
- Settings onChange 在 load 时触发导致 Viking API key 丢失
- Viking 重复推送跳过已发送的会话

---

## [0.0.0.6] - 2026-03-19

### Added
- **macOS App 大重构**
  - 主窗口全新设计：Sidebar + Pages 架构
  - Session Pipeline Tiering：4 级会话分级（skip/lite/normal/premium）
  - Settings 重新设计：General/AI/Network/Sources 分区
  - 8 个 PR 系列功能：
    - PR1：Transcript 增强（颜色条、chips、查找、工具栏）
    - PR2：Session List 重写（SwiftUI Table、agent 过滤、项目搜索）
    - PR3：Top Bar（⌘K 搜索、Resume 按钮、主题切换）
    - PR4：Session Housekeeping（preamble 检测、tier 增强）
    - PR5：Usage Probes（采集器、DB、API、Popover UI）
    - PR6：Workspace（repos、detail、work graph）
    - PR7：Session Resume（GUI 对话框、CLI `engram --resume`、终端启动器）
    - PR8：AI Title（生成器、设置、indexer 触发、regenerate-all）
- **Popover Dashboard**：Menu bar 弹出窗口仪表盘（KPI 卡片、热力图）
- **UI Performance 优化**：虚拟滚动、懒加载、缓存

---

## [0.0.0.5] - 2026-03-16

### Added
- **OpenViking 集成**：外部语义搜索引擎接入（后于 v0.0.1.0 移除）
  - VikingBridge + VikingFilter
  - 会话自动推送到 Viking
  - `get_memory` MCP 工具

---

## [0.0.0.4] - 2026-03-10

### Added
- **AI Summary Redesign**：AI 摘要管线重构（多 provider 支持）
- **Popover Dashboard 设计**：menu bar 弹出窗口交互设计

---

## [0.0.0.3] - 2026-03-03

### Added
- **Web UI + 多机同步**
  - Hono HTTP 服务器 + 纯 HTML/JS 前端
  - `/api/sessions`、`/api/search`、`/api/stats` 等 REST 端点
  - 会话列表、详情、搜索、用量统计页面
  - SQLite-based 多机同步（pull-based，增量同步元数据）
  - 配置文件：`~/.engram/settings.json`
- **RAG 向量搜索基础**
  - sqlite-vec 集成（embedding 向量存储）
  - Ollama + nomic-embed-text 本地 embedding
  - OpenAI embedding fallback
  - 后台异步索引

### Changed
- **消息计数重设计**：精确区分 user/assistant/tool 消息数

---

## [0.0.0.2] - 2026-02-28

### Added
- **macOS SwiftUI 应用**
  - Menu bar 菜单栏应用 + Popover + 独立窗口
  - SessionList、搜索、时间轴、收藏夹、设置 UI
  - GRDB 数据库只读访问（Node 拥有 schema，Swift 只读）
  - Node.js daemon 子进程管理（`IndexerProcess`）
  - MCP Server（Hummingbird 2、TCP + Unix socket）
  - stdio ↔ Unix socket 桥接（CodingMemoryCLI）
  - LaunchAgent 登录自启动
  - 发布脚本（归档、公证、DMG 打包）
- **IDE 适配器（4 个）**
  - Cursor（SQLite cursorDiskKV）
  - VS Code Copilot Chat（JSONL kind:0 格式）
  - Antigravity（gRPC → JSONL cache，cascade client）
  - Windsurf（gRPC cascade adapter）
- **会话浏览增强**
  - Clean/raw 对话视图 + 系统注入过滤
  - Agent badge + 过滤 chips（Claude Code agent 子进程识别）
  - 会话排序、多选过滤、时间轴展开/折叠

### Fixed
- Antigravity gRPC 端口检测（lsof PID 精确过滤、TLS/明文端口区分）
- Antigravity 会话内容读取（GetCascadeTrajectory API、三级降级策略）
- 索引器去重一致性（缓存文件 vs .pb 文件大小）
- 孤儿 Node 进程清理（Xcode SIGKILL 后 pkill 旧进程）
- MCP Server 启动问题（HTTP/1.1 Unix socket、stamp 文件、write pool 泄漏、stdin 关闭退出）

---

## [0.0.0.1] - 2026-02-27

### Added
- **项目初始化**：TypeScript MCP Server 脚手架（Node.js 20+、ES modules、vitest）
- **核心架构**
  - `SessionAdapter` 接口定义（detect/listSessionFiles/parseSessionInfo/streamMessages）
  - SQLite 数据库层（better-sqlite3、WAL 模式、FTS5 全文搜索）
  - 会话索引器（全量扫描 + skip-unchanged 优化）
  - 文件监听器（chokidar 增量更新）
  - 项目名解析器（git remote / basename）
- **CLI 适配器（4 个）**
  - Codex CLI（`~/.codex/sessions/` JSONL 逐行流式读取）
  - Claude Code（`~/.claude/projects/` JSONL，路径编码解析）
  - Gemini CLI（`~/.gemini/tmp/` JSON，projectHash 反推）
  - OpenCode（`~/.local/share/opencode/` SQLite + JSON）
- **第二批适配器（5 个）**
  - iflow、Qwen、Kimi、Cline、MiniMax、Lobster AI
- **MCP 工具（7 个）**
  - `list_sessions` — 列出会话（按来源/项目/时间过滤）
  - `get_session` — 读取会话内容（分页，每页 50 条）
  - `search` — FTS5 全文搜索
  - `project_timeline` — 项目跨工具时间线
  - `stats` — 用量统计（按来源/项目/天/周分组）
  - `get_context` — 智能上下文提取（token 预算控制）
  - `export` — 导出会话为 Markdown/JSON

### Fixed
- Codex `environment_context` 系统注入过滤
- Claude Code `superpowers` skill injection 过滤
- Cline malformed JSON 处理
- Kimi readline stream 提前退出关闭
- Watcher watchMap 非空断言移除
