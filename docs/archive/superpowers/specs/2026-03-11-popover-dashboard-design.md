# Popover Dashboard 设计

Date: 2026-03-11

## Problem

菜单栏弹出窗口（popover）当前显示完整的四标签界面（Sessions/Search/Timeline/Favorites），760x640px，与独立窗口内容完全重复。对于一个 menu bar app 来说太重了——用户只想快速看到状态和最近活动。

## Design

将 popover 从完整 app 瘦身为轻量 dashboard，400px 宽。完整功能保留在双击打开的独立窗口中。

### Layout（从上到下）

**1. 头部**
```
Engram                              ⚙️
● Web :3457  ● MCP  ● Embedding 82%
```
- 第一行：标题 + 设置按钮
- 第二行：服务状态指示器

**2. 统计卡片**（2x2 网格，背景色 secondarySystemBackground）
```
Sessions  1,247    Sources   6
Projects  23       DB Size   42.3 MB
```

**3. Timeline**（按日期分组，最近的在前）
```
TODAY
● claude-code  修复认证 bug，重构 AuthManager     2m
● codex        添加注册功能，邮箱验证              1h
YESTERDAY
● claude-code  实现 link_sessions 工具            1d
```

**4. 底部**
```
              Open Window →
```

### 状态指示器

三个服务各有四种状态：

| 状态 | 显示 | 条件 |
|------|------|------|
| Running | `● 绿色` | 服务正常运行 |
| In progress | `● 黄色 + 进度` | 仅 Embedding：正在索引 |
| Error | `● 红色` | 出错（连接失败等） |
| Unavailable | `○ 灰色` | 未配置或不可用 |

- **Web**: 绿色时显示端口号 `:3457`
- **MCP**: 基于 IndexerProcess.status 判断
- **Embedding**: 从 `/api/search/status` 获取 `available`、`progress`

### Source 颜色映射

Timeline 中各 source 用固定颜色区分：
- claude-code: `.green`
- codex: `.orange`
- gemini: `.blue`
- copilot: `.pink`
- cursor: `.purple`
- 其他: `.gray`

### 主题适配

使用 SwiftUI 语义色，自动适配 Light/Dark mode：
- 背景: `Color(.windowBackgroundColor)` (popover 自带)
- 卡片背景: `Color(.secondarySystemFill)` 或类似 NSColor 语义色
- 主文字: `Color.primary`
- 次文字: `Color.secondary`
- 状态色: `Color.green`, `Color.orange`, `Color.red`

### 数据源

| 数据 | 来源 |
|------|------|
| Session count | `indexer.totalSessions` (已有) |
| Source/Project count | `db.listSources()` / `db.listProjects()` (已有) |
| DB size | `FileManager` 读 sqlite 文件大小 |
| Timeline | `db.listSessionsChronologically(limit: 20)` (已有) |
| Web port | `indexer.port` (已有) |
| MCP status | `indexer.status` (已有) |
| Embedding status | HTTP GET `/api/search/status` → `{ available, progress, embeddedCount, totalSessions }` |

### Popover 尺寸

从 760x640 改为 **400x420**（高度根据内容自适应）。

## Files to Change

| File | Change |
|------|--------|
| `macos/Engram/Views/PopoverView.swift` | **新建** — dashboard 视图 |
| `macos/Engram/MenuBarController.swift` | popover 改用 PopoverView，缩小尺寸 |
| `macos/Engram/Core/DatabaseManager.swift` | 添加 `countSources()`, `dbSizeBytes()` 方法 |

ContentView 保持不变，仍用于独立窗口。

## Not in Scope

- Popover 中的搜索/筛选功能（用独立窗口）
- 点击 timeline 项跳转到详情（后续可加）
- Embedding 配置入口（通过设置按钮进入）
