# Popover 项目标签 + 索引健康度面板 — Design Spec

**Date:** 2026-03-17
**Problem:** Popover 列表没有项目名，无法快速区分不同项目的会话；用户无法判断索引是否完整、哪些 source 在正常工作。
**Solution:** 两个独立功能：(1) 调整 popover 行布局，加入项目标签；(2) 新增索引健康度面板（popover 摘要 + Web UI 详情页）。

---

## 功能 1：Popover 项目标签

### 当前布局

```
[●] Claude Code   重构 VikingBridge 的 addResource 方法    2h ago
```

`[●]`=source 颜色圆点，`Claude Code`=source 名（固定 58px），标题占剩余空间，时间居右。

### 新布局

```
[●] coding-memory  重构 VikingBridge 的 addResource...    Claude  2h
```

- **左侧**：圆点（保留 source 颜色）+ 项目名（替换原 source 位置）
- **右侧**：source 缩写（带 source 颜色）+ 相对时间

### 详细规格

**项目名（左侧）：**
- 位置：圆点右侧，原 source 标签位置
- 宽度：`width: 72`，`alignment: .leading`
- 字体：`.caption2`
- 颜色：`.secondary`
- 截断：`.lineLimit(1)` + `.truncationMode(.tail)`
- 无项目名时：显示 `—`（em dash），灰色

**Source 缩写（右侧）：**
- 位置：标题右侧，时间左侧
- 字体：`.caption2`
- 颜色：`SourceDisplay.color(for: session.source)`
- 缩写映射：`Claude Code → Claude`，`Gemini CLI → Gemini`，`Codex → Codex`，等
- 不截断（缩写都很短）

**时间：**
- 缩短格式：`2h ago → 2h`，`5 min ago → 5m`，`1 day ago → 1d`
- 字体颜色不变

### 文件改动

| File | Change |
|------|--------|
| `macos/Engram/Views/PopoverView.swift` | 修改 `timelineRow()` 方法布局 |
| `macos/Engram/Core/SourceDisplay.swift` (if exists, or inline) | 新增 `shortLabel(for:)` 返回缩写 |

### Source 缩写表

| SourceName | 缩写 |
|-----------|------|
| claude-code | Claude |
| codex | Codex |
| gemini-cli | Gemini |
| cursor | Cursor |
| cline | Cline |
| copilot | Copilot |
| opencode | OCode |
| vscode | VSCode |
| antigravity | AG |
| windsurf | Wsurf |
| iflow | iFlow |
| qwen | Qwen |
| kimi | Kimi |
| minimax | MMax |
| lobsterai | Lobster |

---

## 功能 2：索引健康度

### 2a. Popover 摘要

在 popover 顶部（现有统计行下方或替换）添加一行健康摘要：

```
13/15 sources active · last 5 min
```

**规格：**
- `active` 定义：最近 7 天内有新 session 的 source 数
- `last` = 所有 source 中最近一次索引的相对时间
- 字体：`.caption2`，颜色：`.secondary`
- 颜色规则：
  - 全部 active → 绿色文字
  - 有 source 超过 24h 没新数据 → 黄色
  - 有 source 超过 7 天没新数据 → 不变色（可能用户就是不用那个工具）
- 点击：跳转 Web UI `/health` 页面

**数据来源：**
- 调用 daemon HTTP API `GET /api/health/sources`（新增）
- 或直接从 `DatabaseManager` 查询（Swift 侧 read-only）

**推荐：Swift 侧直接查 SQLite**，避免额外 HTTP 调用。查询：
```sql
SELECT source, COUNT(*) as count, MAX(start_time) as latest
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
| gemini-cli | 47 | 5h ago | ▁▁▁▁▁▇▃ | 🟢 Active |
| cursor | 2 | 18 months ago | ▁▁▁▁▁▁▁ | ⚪ Inactive |

**状态定义：**
- 🟢 Active：最近 24h 内有新 session
- 🟡 Stale：最近 7 天有但 24h 内没有
- ⚪ Inactive：超过 7 天没有新 session（可能用户不用这个工具，不算错误）

**7-Day Trend：**
- 7 个小块字符（▁▃▅▇），每天一个，高度按当天 session 数量相对本 source 最大值缩放
- 也可以用 CSS 画的小条形图

#### 区域 2：诊断面板

每个 source 展开后显示：

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

**数据需要：**
- 文件路径：从 adapter 的配置获取（每个 adapter 有默认路径）
- 路径是否存在：服务端检查 `fs.existsSync(path)`
- Watcher 类型：`WATCHED_SOURCES` set 决定是 watching 还是 polling
- 最后索引时间 + session 数：DB 查询

#### 区域 3：Viking 状态（if configured）

```
OpenViking: 🟢 Connected (10.0.8.9:1933)
  Embedding:  38168 processed, 0 errors
  Semantic:   1088/5300 processed (20%)
  VLM Tokens: 20.5M (kimi-k2.5)
```

从 Viking observer API 获取（`/api/v1/observer/queue` + `/api/v1/observer/vlm`）。

### 后端 API

**新增 `GET /api/health/sources`**

```json
{
  "sources": [
    {
      "name": "claude-code",
      "sessionCount": 1848,
      "latestSession": "2026-03-17T00:50:32Z",
      "path": "~/.claude/projects/",
      "pathExists": true,
      "watcherType": "watching",
      "dailyCounts": [12, 15, 8, 5, 14, 18, 10]
    }
  ],
  "viking": {
    "available": true,
    "embedding": { "processed": 38168, "errors": 0 },
    "semantic": { "processed": 1088, "pending": 4211, "total": 5300 },
    "vlmTokens": 20486312
  },
  "summary": {
    "totalSources": 15,
    "activeSources": 13,
    "lastIndexed": "2026-03-17T00:50:32Z"
  }
}
```

**实现方式：**
- Source 数据：`db.listSources()` + per-source `COUNT/MAX` 查询 + 7 天 `GROUP BY date(start_time)` 聚合
- 路径检测：遍历 adapters，对每个调用 `adapter.detect()` 或检查默认路径
- Watcher 类型：检查 `WATCHED_SOURCES.has(source)`
- Viking 数据：调用 Viking observer API（如果 Viking 可用）

### 文件改动

| File | Change |
|------|--------|
| `src/web.ts` | 新增 `GET /api/health/sources` 端点 |
| `src/web/views.ts` | 新增 `healthPage()` 渲染函数 |
| `src/core/db.ts` | 新增 `getSourceStats()` 方法（per-source 聚合 + 7 天趋势） |
| `macos/Engram/Views/PopoverView.swift` | 顶部加健康摘要行 |
| `macos/Engram/Core/DatabaseManager.swift` | 新增 source 聚合查询（read-only） |

---

## Scope Exclusions

- 不做 source 的启用/禁用开关（已有 adapter detect 机制）
- 不做告警通知（只是展示状态）
- 不改索引逻辑本身
- 不动 Viking 服务端配置
- Web UI 健康页不做实时刷新（手动刷新即可）
