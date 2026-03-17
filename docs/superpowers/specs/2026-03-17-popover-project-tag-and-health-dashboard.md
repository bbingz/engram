# Popover 项目标签 + 索引健康度面板 — Design Spec

**Date:** 2026-03-17
**Problem:** Popover 列表没有项目名，无法快速区分不同项目的会话；用户无法判断索引是否完整、哪些 source 在正常工作。
**Solution:** 两个独立功能：(1) 调整 popover 行布局，加入项目标签；(2) 新增索引健康度面板（popover 摘要 + Web UI 详情页）。
**Implementation order:** 功能 1 先做（纯 Swift，无后端依赖），功能 2 后做。

---

## 功能 1：Popover 项目标签

### 当前布局

```
[●] Claude Code   重构 VikingBridge 的 addResource 方法    2h
```

`[●]`=source 颜色圆点，`Claude Code`=source 名（固定 58pt），标题占剩余空间，时间居右。
注：`relativeTime()` 已经返回紧凑格式（`2h`/`5m`/`1d`），无需修改。

### 新布局

```
[●] coding-memory  重构 VikingBridge 的 addResource...    Claude  2h
```

- **左侧**：圆点（保留 source 颜色）+ 项目名（替换原 source 位置）
- **右侧**：source 标签（带 source 颜色）+ 相对时间

### 详细规格

**项目名（左侧）：**
- 位置：圆点右侧，原 source 标签位置
- 宽度：`.frame(width: 72, alignment: .leading)`
- 字体：`.caption2`
- 颜色：`.secondary`
- 截断：`.lineLimit(1)` + `.truncationMode(.tail)`
- 无项目名时：显示 `—`（em dash），灰色

**Source 标签（右侧）：**
- 位置：标题右侧，时间左侧
- 字体：`.caption2`
- 颜色：`SourceDisplay.color(for: session.source)`
- 使用现有 `SourceDisplay.label(for:)` 的返回值即可（已经足够短：Claude、Gemini、Codex 等）
- 不需要新增 `shortLabel` 方法

**注意：** `SourceDisplay` enum 定义在 `macos/Engram/Views/SessionDetailView.swift` 顶部（lines 6-45），不是独立文件。

### 文件改动

| File | Change |
|------|--------|
| `macos/Engram/Views/PopoverView.swift` | 修改 `timelineRow()` 方法布局 |

### 现有 SourceDisplay.label() 返回值（无需新增）

| SourceName | label() 返回 |
|-----------|-------------|
| claude-code | Claude |
| codex | Codex |
| gemini-cli | Gemini |
| cursor | Cursor |
| cline | Cline |
| copilot | Copilot |
| opencode | OpenCode |
| vscode | VS Code |
| antigravity | Antigravity |
| windsurf | Windsurf |
| iflow | iFlow |
| qwen | Qwen |
| kimi | Kimi |
| minimax | MiniMax |
| lobsterai | Lobster AI |

---

## 功能 2：索引健康度

### 2a. Popover 摘要

在 popover 顶部（现有统计行下方或替换）添加一行健康摘要：

```
13/15 sources active · last 5 min
```

**规格：**
- `active` 定义：最近 24h 内有新 session 的 source 数
- `total`：DB 中出现过的所有 source 数
- `last` = 所有 source 中最近一次 `indexed_at` 的相对时间（用 `indexed_at` 而非 `start_time`，更准确反映"最后索引时间"）
- 字体：`.caption2`，颜色：`.secondary`
- 颜色规则：
  - 全部 source 在 24h 内有新数据 → 绿色文字
  - 部分 source 超过 24h → 默认颜色（不标黄——可能用户就是不用那些工具）
- 点击：跳转 Web UI `/health` 页面

**数据来源：Swift 侧直接查 SQLite**（read-only，避免 HTTP 调用）

查询：
```sql
SELECT source, COUNT(*) as count, MAX(indexed_at) as latest_indexed
FROM sessions WHERE hidden_at IS NULL
GROUP BY source
```

### 2b. Web UI 健康详情页

新增 `/health` 页面，展示三个区域：

#### 区域 1：Source 状态表

| Source | Sessions | Last Indexed | 7-Day Trend | Status |
|--------|----------|-------------|-------------|--------|
| claude-code | 1848 | 3 min ago | ▇▇▅▃▇▇▇ | 🟢 Active |
| codex | 488 | 27 min ago | ▅▃▁▁▅▅▃ | 🟢 Active |
| gemini-cli | 47 | 5h ago | ▁▁▁▁▁▇▃ | 🟡 Stale |
| cursor | 2 | 18 months ago | ▁▁▁▁▁▁▁ | ⚪ Inactive |

**状态定义：**
- 🟢 Active：最近 24h 内有新 session
- 🟡 Stale：最近 7 天有但 24h 内没有
- ⚪ Inactive：超过 7 天没有新 session

**7-Day Trend：**
- 用 CSS 画的小条形图（7 列），每列高度按当天 session 数量相对本 source 7 天最大值缩放

#### 区域 2：诊断面板

每个 source 可展开显示：

```
claude-code
  Path:    ~/.claude/projects/          ✅ exists
  Watcher: watching (jsonl)             ✅ active
  Last:    2026-03-17T00:50:32          3 min ago
  Count:   1848 sessions

cursor
  Path:    ~/Library/.../state.vscdb    ✅ exists
  Watcher: polling (10 min interval)    🟡 non-watchable
  Last:    2024-09-13T03:32:00          18 months ago
  Count:   2 sessions
```

**获取 adapter 路径的方式：**

`SessionAdapter` 接口没有 `basePath` 属性。为诊断面板新增：

```typescript
// 在 web.ts 的 /api/health/sources 端点中，遍历 adapters
// 每个 adapter 调用 detect()，返回 true/false
// 路径信息通过 hardcoded map 提供（与 watcher.ts 的 watchEntries 和 macOS SettingsView 的 dataSources 一致）
```

在 `src/web.ts` 中维护一个 `SOURCE_PATHS` map（从现有 `dataSources` 数组和 watcher 配置提取），不修改 adapter 接口。

**注意：`lobsterai` 和 `minimax` 是派生 source**（共享 claude-code 的目录，无独立 adapter），诊断面板中标注为 "derived from claude-code"。

#### 区域 3：Viking 状态（if configured）

```
OpenViking: 🟢 Connected (10.0.8.9:1933)
  Embedding:  38168 processed, 0 errors
  Semantic:   1088/5300 processed (20%)
  VLM Tokens: 20.5M (kimi-k2.5)
```

从 Viking observer API 获取（`/api/v1/observer/queue` + `/api/v1/observer/vlm`）。Viking 不可用时显示 "⚪ Not configured" 或 "🔴 Unreachable"。

### 后端 API

**新增 `GET /api/health/sources`**

```json
{
  "sources": [
    {
      "name": "claude-code",
      "sessionCount": 1848,
      "latestIndexed": "2026-03-17T00:50:32Z",
      "path": "~/.claude/projects/",
      "pathExists": true,
      "watcherType": "watching",
      "derived": false,
      "dailyCounts": [12, 15, 8, 5, 14, 18, 10]
    },
    {
      "name": "lobsterai",
      "sessionCount": 26,
      "latestIndexed": "2026-03-08T09:19:00Z",
      "path": "~/.claude/projects/",
      "pathExists": true,
      "watcherType": "watching",
      "derived": true,
      "derivedFrom": "claude-code",
      "dailyCounts": [0, 0, 0, 0, 0, 0, 0]
    }
  ],
  "viking": {
    "available": true,
    "embedding": { "processed": 38168, "errors": 0 },
    "semantic": { "processed": 1088, "pending": 4211, "total": 5300 },
    "vlmTokens": 20486312
  },
  "summary": {
    "totalSources": 13,
    "activeSources": 5,
    "lastIndexed": "2026-03-17T00:50:32Z"
  }
}
```

**实现方式：**
- Source 数据：`db.getSourceStats()` 新方法（per-source `COUNT`/`MAX(indexed_at)` + 7 天 `GROUP BY date(start_time)` 聚合）
- 路径检测：`SOURCE_PATHS` hardcoded map + `fs.existsSync()`
- Watcher 类型：`WATCHED_SOURCES.has(source)`
- 派生 source：hardcoded list `{ lobsterai: 'claude-code', minimax: 'claude-code' }`
- Viking 数据：调用 Viking observer API（如果 Viking 可用），catch errors 返回 null

### 文件改动

| File | Change |
|------|--------|
| `src/web.ts` | 新增 `GET /api/health/sources` 端点、`/health` HTML 路由 |
| `src/web/views.ts` | 新增 `healthPage()` 渲染函数 |
| `src/core/db.ts` | 新增 `getSourceStats()` 方法 |
| `macos/Engram/Views/PopoverView.swift` | 顶部加健康摘要行 |
| `macos/Engram/Core/Database.swift` | 新增 `sourceStats()` 查询方法（read-only） |

---

## Scope Exclusions

- 不做 source 的启用/禁用开关（已有 adapter detect 机制）
- 不做告警通知（只是展示状态）
- 不改索引逻辑本身
- 不动 Viking 服务端配置
- Web UI 健康页不做实时刷新（手动刷新即可）
- 不修改 `SessionAdapter` 接口（路径信息通过 hardcoded map 提供）
