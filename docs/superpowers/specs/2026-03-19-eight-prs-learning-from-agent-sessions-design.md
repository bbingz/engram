# Eight PRs: Learning from AgentSessions & Readout

**Date:** 2026-03-19
**Status:** Approved
**Branch:** feat/main-app-redesign
**Reference:** [AgentSessions](https://github.com/jazzyalex/agent-sessions) + Readout Workspace

## Overview

8 个独立 PR，从 AgentSessions 和 Readout 两个项目中学习最佳实践，全面提升 Engram 的交互体验、数据管理和 AI 辅助能力。每个 PR 是一个完整的可交付单元。

## PR Execution Order

| PR | 方向 | 依赖 | 核心变更 |
|----|------|------|---------|
| PR1 | Transcript 增强 | 无 | SessionDetailView 重写 |
| PR2 | 会话列表重设计 | 无 | SessionListView → SwiftUI Table |
| PR3 | 顶部功能区 | PR2 (软) | 全局搜索 + Resume 按钮 |
| PR4 | 会话梳理 | 无 | computeTier() 增强 |
| PR5 | 探针系统 | PR4 | UsageProbe + UsageCollector |
| PR6 | Workspace | 无 | 侧边栏 Workspace 分组 |
| PR7 | 会话恢复 | 无 | ResumeCoordinator + CLI |
| PR8 | AI 标题优化 | 无 | TitleGenerator + Settings |

---

## PR1: Transcript 增强

### 目标
将 SessionDetailView 从简单的气泡式文本查看器升级为交互式 transcript 浏览器，参考 AgentSessions 的工具栏设计。

### 子功能

#### 1A. 工具栏第一行
参考 AgentSessions 的紧凑设计：

```
★ | [Session] [Text] [JSON] | ID 62e1 |     | A− A+ | Copy | Find ⌘F
```

- **最左侧**: ★ 收藏按钮（新增，原来在 header）
- **模式切换**: Session / Text / JSON 三模式 segmented control（保留现有功能）
- **Session ID**: 点击复制，显示末 4 位
- **右侧工具**: A−/A+ 字体缩放 | Copy 全文 | Find ⌘F 搜索入口
- **无 emoji**: 全部用文字和色点

#### 1B. 工具栏第二行 — 分类 Chip
```
[All] | ● User 0/6 ∧∨ | ● Assistant 0/17 ∧∨ | ● Tools 0/12 ∧∨ | ● Error 0/1 ∧∨ | ● Code 0/3
```

- 每个 chip 显示色点 + 类型名 + 当前位置/总数
- ∧∨ 按钮跳转到上/下一条该类型消息
- **点击 chip 切换显示/隐藏**（比 AgentSessions 多的功能）
- Error chip（比 AgentSessions 多的类别）

#### 1C. 消息色条显示
替代气泡式布局：
- 左侧 3px 色条 + 浅色背景 + 类型标签
- User = 蓝(#3b82f6), Assistant = 紫(#8b5cf6), Tool = 绿(#10b981), Error = 红(#ef4444), Code = 靛(#6366f1)
- 标签格式: `USER #1`, `ASSISTANT #3`, `TOOL: Read`, `ERROR`, `CODE: swift`

#### 1D. 对话内搜索 (⌘F)
- Find bar 浮在 transcript 顶部
- 关键词即时高亮（黄色背景）
- 上/下跳转按钮 + "3/7" 计数器
- Escape 或 × 关闭
- 当前匹配项用更深的高亮色

#### 1E. 字体缩放 (⌘+/⌘-)
- 快捷键直接在 detail view 内调整
- 已有 `contentFontSize` @AppStorage (10-22pt) 基础
- 工具栏 A−/A+ 按钮同步

#### 1F. 复制增强
- 工具栏 Copy 按钮: 复制全部 transcript
- 右键菜单: 复制选中 / 复制整条消息 / 复制整段对话
- ⌥⌘C 快捷键复制全部

#### 1G. Raw/JSON 视图
- Session 模式: 色条渲染（新）
- Text 模式: 纯文本 + 前缀 (> user, → tool)
- JSON 模式: 格式化 JSON

### 消息类型检测逻辑
- **User/Assistant**: 由 `ChatMessage.role` 直接判定
- **Tool**: role == "assistant" 且内容匹配工具调用模式 (`Tool:`, `tool_call`, `Read`, `Write`, `Edit`, `Bash` 等)，或 `systemCategory == .agentComm`
- **Error**: 内容包含错误模式 (`Error:`, `error:`, `failed`, 非零 exit code, `permission denied` 等)
- **Code**: 内容包含 ``` 代码块 (由 ContentSegmentParser 已有的 `.codeBlock` 检测)

### 消息索引计算
解析后的 `[ChatMessage]` 通过一次 post-processing pass 生成索引，不修改 ChatMessage 本身：
```swift
struct IndexedMessage {
    let message: ChatMessage
    let typeIndex: Int      // "User #3" 中的 3
    let messageType: MessageType  // .user/.assistant/.tool/.error/.code
}
// 在 SessionDetailView.updateDisplayMessages() 中计算，结果缓存
```

### 技术实现
- **文件变更**: `SessionDetailView.swift` 重写, 新增 `TranscriptToolbar.swift`, `TranscriptFindBar.swift`, `MessageTypeChip.swift`, `IndexedMessage.swift`
- **数据模型**: 新增 `IndexedMessage` wrapper (不修改 ChatMessage)，`MessageTypeClassifier` 负责分类
- **键盘快捷键**: ⌘F (find), ⌘G/⇧⌘G (next/prev match), ⌘+/⌘- (zoom), ⌥⌘C (copy all)

---

## PR2: 会话列表重设计

### 目标
将卡片式分组列表改为可排序可筛选的表格，表格上方增加 Agent 筛选栏和 Project 搜索框。

### 布局

#### 2A. Agent 筛选栏（表格上方）
```
[All] | ● Claude 24 | ● Codex 8 | ● Gemini 15 | ● Cursor 6 |    | [Project...]
```

- Agent pill: 多选模式，色底 + 色边框 + 计数
- 只显示有会话的 agent
- 未选中 = 灰底灰文字
- 筛选状态持久化 (@AppStorage)

#### 2B. Project 搜索框
三种状态：
1. **未激活**: 紧凑 "Project..." 占位符
2. **输入中**: 展开输入框 + 模糊匹配下拉候选（显示项目名 + 会话数），↑↓ 导航, Enter 选中
3. **已选中**: 收起为蓝色 pill "coding-memory ×"，点 × 清除

#### 2C. 表格
SwiftUI Table 原生组件：

| ★ | Agent | Title | Date | Project | Msgs | Size |
|---|-------|-------|------|---------|------|------|

- 所有列可排序 (KeyPathComparator)
- 列可见性: 右键表头控制显隐
- 行内收藏: ★ 列直接点击
- 交替行背景
- 底部: session count + Clean Empty

### 技术实现
- **文件变更**: `SessionListView.swift` 重写, 新增 `AgentFilterBar.swift`, `ProjectSearchField.swift`, `ColumnVisibilityStore.swift`
- **数据**: Session 模型已有所有字段，无需 DB 变更
- **持久化**: selectedSources, selectedProject, sortField, columnVisibility → @AppStorage
- **列可见性**: SwiftUI Table 不原生支持列显隐。通过 `TableColumn` 的 `width` 设为 0 实现隐藏 (参考 AgentSessions 的做法)，ColumnVisibilityStore 管理 @AppStorage 状态。右键菜单通过 `.contextMenu` 附加到表头区域

---

## PR3: 顶部功能区集成

### 目标
在主窗口顶部右侧放置全局搜索和 Resume 按钮，设置和主题切换下沉到侧边栏底部。

### 布局
```
[左侧导航栏]  |                                    | [Search ⌘K] [▶ Resume]
```

#### 3A. 全局搜索 (⌘K)
- 右对齐，固定宽度 240px
- 沿用现有 SearchPageView 的 hybrid/keyword/semantic 三模式
- 搜索所有会话标题和内容
- 结果跳转到匹配的会话

#### 3B. Resume 按钮
- 选中会话时高亮可用（绿色）
- 未选中时灰色禁用
- 点击触发 PR7 的 Resume 工作流
- PR7 未实现前灰色占位

#### 3C. 侧边栏底部
```
☀/☾ Theme
⚙ Settings
```

#### 3D. ⌘K vs ⌘F 的区分
| | 全局搜索 (⌘K) | Transcript 搜索 (⌘F) |
|---|---|---|
| 范围 | 所有会话 | 当前打开的会话 |
| 位置 | 顶部栏 | 详情面板工具栏 |
| 引擎 | FTS + 语义搜索 | 纯文本匹配 |
| 结果 | 跳转到会话 | 跳转到匹配位置 |

### 技术实现
- **文件变更**: `MainWindowView.swift` 在 NavigationSplitView 的 detail 区域顶部添加持久 toolbar (`.toolbar` modifier 或自定义 VStack header)，该 toolbar 跨所有 detail 页面始终可见
- **视图层级**: `MainWindowView` → `VStack { TopToolbar; NavigationSplitView.detail }` 确保搜索和 Resume 始终在最顶部
- **依赖**: PR2 为软依赖 (PR3 可独立实现，PR2 只影响列表区内容)

---

## PR4: Agent 会话梳理

### 目标
增强 `computeTier()` 的分类智能，识别 preamble-only、no-reply、empty 等无意义会话，将其降级到 skip/lite tier。单一维度，不增加新列。

### 增强逻辑

| 会话特征 | 现有 tier | 增强后 tier |
|---------|----------|-----------|
| 0 条消息 / 文件 < 1KB | skip | skip (不变) |
| 只有 preamble (CLAUDE.md 等) | 可能是 normal | → **skip** |
| 有 user 消息但无 AI 回复 | 可能是 lite | → **lite** |
| probe 会话 (专用目录) | 可能是 lite | → **skip** |
| 正常对话 | normal/premium | 不变 |

### Preamble 检测模式
在 `computeTier()` 中新增检测：
- 文件标记: `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `environment_context`, `system-reminder`
- 系统角色: `<instructions>`, `you are an expert`, `system:`
- 长 markdown 块: >6 行且 >4 个 heading/bullet（通常是注入的项目说明）

### 内容访问策略
当前 `computeTier()` 只接收 `TierInput` (messageCount, source, filePath 等元数据)，无法看到消息内容。两步解决：
1. **扩展 TierInput**: 新增 `firstUserMessages: string[]` 字段 (前 3 条 user 消息，在 indexer `streamMessages` 阶段提取)
2. **Preamble 检测在 indexer 中执行**: `isPreambleOnly(messages)` 在索引阶段调用，结果作为 `TierInput.isPreamble: boolean` 传入 `computeTier()`

这与 Swift 侧 `MessageParser.classifySystem()` 的检测模式类似，但运行在 Node/TS 侧的索引阶段，不重复。

### 技术实现
- **文件变更**: `src/core/session-tier.ts` 扩展 `TierInput` + `computeTier()`, 新增 `src/core/preamble-detector.ts`
- **无 DB schema 变更**: tier 列已存在，值域不变
- **后台 backfill**: daemon 启动时重新计算所有会话 tier (需重新读取 firstUserMessages)
- **UI**: 现有 noiseFilter (hide-skip/hide-noise) 自动生效

---

## PR5: 探针系统

### 目标
采集各 AI 工具的用量/配额数据，在 Popover 和主窗口展示。

### 架构

#### 5A. 采集层 (Node daemon)
```typescript
interface UsageProbe {
  source: string;
  probe(): Promise<UsageSnapshot[]>;
  interval: number; // ms
}

interface UsageSnapshot {
  source: string;
  metric: string;        // "opus_5h", "opus_weekly", "sonnet_5h", etc.
  value: number;         // 0-100 percentage
  resetAt?: string;      // ISO timestamp
  collectedAt: string;
}
```

先支持 Claude (OAuth API / tmux fallback) 和 Codex (tmux probe)，其余工具后续扩展。

#### 5B. 用量显示 — Popover (方案 B)

**收起状态**: 每个模型只显示最紧急的窗口
```
Opus     ████████░░ 72%  5h
Sonnet   ████░░░░░░ 45%  5h
Spark    █████████░ 88%  5h   ← 红色
Codex    ██░░░░░░░░ 20%  5h
```

**展开状态** (点击 Show All): 每个模型显示所有窗口
```
Opus
  5h  ████████░░ 72%
  wk  ████░░░░░░ 35%
  Resets in 2h 15m
```

>80% 进度条变红。

#### 5C. 用量显示 — 主窗口 Sources 页
使用方案 A (双行完整视图)，空间充足无需折叠。

#### 5D. 数据存储
Node 侧 `src/core/db.ts:migrate()` 新增 idempotent migration:
```sql
CREATE TABLE IF NOT EXISTS usage_snapshots (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,
  metric TEXT NOT NULL,
  value REAL NOT NULL,
  unit TEXT DEFAULT '%',
  reset_at TEXT,
  collected_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_latest ON usage_snapshots(source, metric, collected_at DESC);
```
Swift 侧通过 read-only GRDB pool 查询，不写入此表。

#### 5E. Daemon → Swift
```json
{"event": "usage", "data": [{"source":"claude", "metric":"opus_5h", "value":72, "resetAt":"..."}]}
```

### Claude Usage Probe 细节
- **OAuth token 位置**: `~/.claude/credentials.json` 或 `~/.claude/.credentials` (JSON 格式，含 `accessToken`)
- **API 端点**: `GET https://api.claude.ai/api/organizations/{org_id}/usage` (Bearer token auth)
- **返回数据**: `{ "daily": { "opus": N, "sonnet": N, "haiku": N }, "limits": { ... } }`
- **Fallback (tmux probe)**: 当 OAuth 不可用时，启动 headless tmux 会话执行 `claude /usage`，解析文本输出。专用目录: `~/.engram/probes/claude/`

### 关键决策
- Probe 失败静默跳过 + 日志 (`os_log` via daemon stderr)
- Probe 产生的会话被 PR4 自动分类为 skip (因 cwd 在 probes 目录)
- Claude OAuth token 从 `~/.claude/` 自动读取，无 token 时 fallback 到 tmux
- 渐进式: 先 Claude + Codex，adapter 可选实现 `probeUsage()`

---

## PR6: Workspace — Git 仓库管理中心

### 目标
参考 Readout Workspace，在侧边栏新增 Workspace 分组，展示所有有 AI 会话的 Git 仓库状态。

### 侧边栏新增

```
WORKSPACE
  ├── Repos        ← 仓库总览
  ├── Work Graph   ← 提交活动
  └── Diffs        ← 会话文件变更 (后续)
```

#### 6A. Repos 页

**KPI 卡片**: Active | Dirty | Unpushed | Total

**仓库列表** (分 Active / Recent):
```
coding-memory  [feat/main-app-redesign]  ● 4 dirty  ↑7  ▁▂▅▃▇▅▂  ›
  refactor(macos): extract Sources + About — 2h ago
```

每个仓库行显示:
- 仓库名 (bold)
- Branch pill (绿色 = feature, 灰色 = main)
- Dirty count (橙色 pill)
- Unpushed count (紫色 pill ↑N)
- Activity sparkline (7 天)
- Last commit message + 时间

**Active 判定**: 24h 内有 AI 会话或 commit。7 天内 = Recent/Idle。超过 = Dormant。

#### 6B. Repo 详情页 (点击进入)
- 面包屑导航: ‹ Repos > coding-memory
- Branch + last commit + 时间
- Quick actions: Claude | VS Code | Terminal | Git Pull | Finder | Copy Path
- CLAUDE.md / GEMINI.md / AGENTS.md 内容查看
- 关联 AI 会话列表 (按时间倒序)

#### 6C. Work Graph 页
- KPI: Active | Idle | Dormant | Commits (30d)
- Commit Activity 柱状图 (30 天)
- Commits by Repo 水平条形图
- AI Sessions by Repo (Engram 独有：哪个项目用 AI 最多)

### Engram 独有优势 (vs Readout)
- **不扫全盘**: 只关注有 AI 会话的项目 (从 session.cwd 提取 git 根目录)
- **会话 × Git 交叉**: 每个 repo 关联 AI 会话数和 agent 类型
- **Resume 集成**: Quick actions 包含恢复最近会话 (连接 PR7)

### 技术实现
- **Node 侧**: `src/core/git-probe.ts` 定时 (5 min) 对已知 repo 跑 `git status/branch/log`。**所有 git 命令在 worker_threads 或 child_process 中运行**，避免阻塞 daemon 主事件循环 (防止慢 NFS 挂载或大仓库卡住 MCP 响应)
- **新增表**: `git_repos (path, name, branch, dirty, unpushed, last_commit_hash, last_commit_msg, last_commit_at, probed_at)`
- **HTTP API**: `GET /api/repos`, `GET /api/repos/:name`
- **Swift 侧**: `ReposView.swift`, `RepoDetailView.swift`, `WorkGraphView.swift`
- **安全**: 只运行只读 git 命令

---

## PR7: 会话恢复工作流

### 目标
从 GUI 和 CLI 两个入口恢复 AI 会话。

#### 7A. GUI Resume (主窗口)
点击顶部 Resume 按钮或右键会话 → Resume:
1. 弹出 Resume 对话框
2. 自动检测已安装的 CLI 工具 + 版本
3. 显示 resume 命令预览
4. 选择终端: Terminal / iTerm2 / Ghostty
5. 点击 Resume 启动

#### 7B. CLI Resume
```bash
$ cd ~/Code/my-project
$ engram --resume

Recent sessions in this project:
  1. Claude · 重构 Button 组件 · 2h ago · 23 msgs
  2. Gemini · Fix login bug · 5h ago · 8 msgs
  3. Cursor · Add API endpoint · 1d ago · 45 msgs

Select session (1-3): 1
Launching: claude --resume abc123...
```

#### 7C. 支持矩阵

| 工具 | Resume 命令 | 检测 |
|------|-----------|------|
| Claude Code | `claude --resume <id>` / `--continue` | `which claude` + 版本 |
| Codex | `codex --resume <id>` | `which codex` + 版本 |
| Gemini CLI | `gemini --resume <session-file>` | `which gemini` |
| Cursor | 打开项目目录 (无直接 resume) | `which cursor` / `open -a Cursor` |
| Others | adapter 可选实现 `resumeCommand()` | 按工具而定 |

#### 7D. Fallback
CLI 不支持 resume → 打开项目目录 + 提示手动恢复。

### 技术实现
- **Node 侧**: `src/core/resume-coordinator.ts` (探测 CLI + 构建命令), `POST /api/session/:id/resume` → `{ command, args[], cwd, tool }` 或 `{ error, hint }`
- **Swift 侧**: `ResumeDialog.swift` (UI), `TerminalLauncher.swift` (通过 AppleScript 启动 Terminal.app/iTerm2/Ghostty 并执行命令，参考 AgentSessions 的 `CodexResumeLauncher.swift`)
- **CLI 入口**: `src/cli/resume.ts`，通过 `package.json` 的 `bin` 字段注册为 `engram` 命令的子命令。daemon 端口发现: 读取 `~/.engram/settings.json` 中的 `httpPort` (默认 3456)，发 HTTP 请求给 daemon API
- **Fallback**: CLI 工具不支持 resume → 用 `open` 命令打开项目目录 + 输出提示

---

## PR8: AI 标题优化

### 目标
用小模型自动生成简洁会话标题，补 Viking 体系的短标题短板。

### 与 Viking 的关系

| 引擎 | 定位 | 输出 | 场景 |
|------|------|------|------|
| Viking | 深度 AI | embedding + 长摘要 + VLM + 上下文检索 | 搜索、理解、跨会话 |
| Title Generator | 轻量 AI | ≤30 字短标题 | 列表显示 |

两者共存互补，不替代。

### 标题优先级
```
customName (用户手动) > generated_title (小模型) > summary (Viking 摘要) > 首条消息截断
```

### Provider 支持

| Provider | 推荐模型 | 成本 | 需要 |
|----------|---------|------|------|
| Ollama (本地) | qwen2.5:3b / llama3.2:3b | 免费 | Ollama 已安装 |
| OpenAI | gpt-4o-mini | ≈$0.15/1M tokens | API Key |
| Dashscope | qwen-turbo | ≈¥0.3/1M tokens | API Key |
| Custom | 任意 OpenAI 兼容 API | — | URL + Key + Model |

### Settings UI
`Settings → AI Settings → Title Generation`:
- Provider segmented control (Ollama/OpenAI/Dashscope/Custom)
- URL / Model / API Key 配置
- Auto-generate toggle
- Test Connection 按钮
- Regenerate All Titles 按钮

### 生成逻辑
1. 触发: 新会话索引完成 + ≥2 条消息 + 无 customName + tier ∈ {normal, premium}
2. 输入: 前 3 轮对话 (每轮截断 200 字, 约 500 tokens)
3. Prompt: "Generate a concise title (≤30 chars, match conversation language)"
4. 输出: 写入 `generated_title` 列
5. Fallback: API 失败 → Ollama local → 首条消息截断

### AI 能力矩阵对比

| 能力 | Engram 现有 | Readout | AgentSessions | 优化后 |
|------|-----------|---------|--------------|-------|
| 语义搜索 | ● | ○ | ○ | ● |
| 长摘要 | ● | ● | ○ | ● |
| 短标题 | ○ | ● | ◐ | ● |
| VLM 视觉 | ● | ○ | ○ | ● |
| 分级处理 | ● | ○ | ◐ | ● |
| 上下文检索 | ● | ○ | ○ | ● |
| 离线 fallback | ● | ○ | ● | ●●● |
| **总计** | **6** | **2** | **1.5** | **7+** |

● = 完整支持 · ◐ = 部分支持 · ○ = 不支持

### 技术实现
- **Node 侧**: `src/core/title-generator.ts`, `db.ts:migrate()` 新增 `generated_title TEXT` 列 (idempotent: `ALTER TABLE sessions ADD COLUMN generated_title TEXT` wrapped in PRAGMA table_info check)
- **Node 侧 db.ts**: `rowToSession()` 增加 `generated_title` 字段映射
- **Swift 侧 Session 模型**: `Session.swift` 新增 `let generatedTitle: String?` + CodingKey，`displayTitle` 更新为: `customName ?? generatedTitle ?? summary ?? firstMessageTruncated ?? "Untitled"`
- **Swift 侧 GRDB**: `DatabaseManager` 查询增加 `generated_title` 列
- **Settings**: `~/.engram/settings.json` 新增 `titleProvider`, `titleModel`, `titleApiKey`, `titleApiUrl`, `titleAutoGenerate`
- **Swift 侧 UI**: `AISettingsSection.swift` 扩展 Title Generation 区域
- **批量回填**: 后台 backfill 带速率限制 (1 req/s API, 并行 for Ollama)
- **Ollama fallback 说明**: 如 Ollama 未安装且 API 也失败，直接降级到首条消息截断，不阻塞索引流程

---

## Cross-PR Dependencies

```
PR1 (Transcript) ──────────────────────────────────────→
PR2 (Session List) ─→ PR3 (Top Bar) ──────────────────→
PR4 (Housekeeping) ─→ PR5 (Probes) ───────────────────→
PR6 (Workspace) ───────────────────────────────────────→
PR7 (Resume) ──────────────────────────────────────────→
PR8 (AI Title) ────────────────────────────────────────→
```

PR1, PR2, PR4, PR6, PR7, PR8 无外部依赖，可独立开发。
PR3 软依赖 PR2 (共享列表容器，但 PR3 修改的是 MainWindowView 顶部，可独立实现)。
PR5 依赖 PR4 (probe 会话需要被 tier 自动分类为 skip)。
注意: PR4 (tier 增强) 会影响 PR2 (列表) 显示的会话集合，两者有软交互但可并行开发。
