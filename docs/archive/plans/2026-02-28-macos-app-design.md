# CodingMemory macOS App 设计

**日期：** 2026-02-28
**状态：** 已批准，待实现

## 目标

将 coding-memory MCP server 包装成 macOS 原生 App：Menu Bar 常驻、SwiftUI 全功能 UI、双模式 MCP 接口（stdio + HTTP/SSE）。

## 架构总览

```
┌─────────────────────────────────────────────────────┐
│              CodingMemory.app (Swift)               │
│                                                     │
│  Menu Bar (NSStatusItem)                            │
│    └─► SwiftUI Window                               │
│          SessionListView  / SearchView              │
│          TimelineView / FavoritesView / ExportView  │
│                                                     │
│  MCPServer (Hummingbird)                            │
│    TCP  localhost:3456  ← AI 工具 HTTP/SSE 直连     │
│    Unix /tmp/coding-memory.sock ← CLI bridge        │
│                                                     │
│  MCPTools.swift → Database.swift (GRDB, read-only)  │
│                                                     │
│  IndexerProcess.swift → Node.js 子进程              │
└──────────────────┬──────────────────────────────────┘
                   │ WAL SQLite
                   │ Swift reads / Node.js writes
┌──────────────────▼──────────────────────────────────┐
│         Node.js Indexer（精简，去掉 MCP server）     │
│         12 adapters + chokidar watcher               │
│         stdout: {"event":"indexed","count":16}       │
└─────────────────────────────────────────────────────┘

AI 工具 stdio 接入：
  config: command = "coding-memory-cli"
  coding-memory-cli (CLI bridge binary)
    stdin/stdout ↔ Unix socket /tmp/coding-memory.sock
```

## 组件

### Xcode 项目结构

```
CodingMemory/
  CodingMemory/                    # 主 App target
    App.swift                      # @main, NSApplicationDelegate, LaunchAgent 注册
    MenuBarController.swift        # NSStatusItem + 状态角标
    Views/
      ContentView.swift            # 主窗口容器（TabView）
      SessionListView.swift        # 会话列表 + source/project/date 筛选
      SessionDetailView.swift      # 消息阅读器（分页）
      SearchView.swift             # FTS5 全文搜索 + 关键词高亮
      TimelineView.swift           # 按项目的时间线视图
      FavoritesView.swift          # 收藏列表
      SettingsView.swift           # 端口配置、Node.js 路径等
    Core/
      Database.swift               # GRDB 查询封装（只读）
      IndexerProcess.swift         # 启动/重启 Node.js 子进程，解析 stdout
      MCPServer.swift              # Hummingbird HTTP/SSE + Unix socket server
      MCPTools.swift               # 7 个 MCP tool 的 Swift 实现
      LaunchAgent.swift            # ~/Library/LaunchAgents/ plist 管理
    Models/
      Session.swift                # GRDB record
      Message.swift

  CodingMemoryCLI/                 # stdio bridge target（独立 CLI 二进制）
    main.swift                     # stdin → Unix socket → stdout

  Shared/
    MCPProtocol.swift              # MCP JSON-RPC 结构体（两个 target 共用）
```

### Node.js 精简改动

- 删除 `src/index.ts` 中的 MCP server、工具注册、watcher 启动部分
- 保留：adapters、indexer、db（写入）、watcher
- 新增 `src/daemon.ts`：只跑 `indexer.indexAll()` + `startWatcher()`，状态输出到 stdout JSON lines
- 输出格式：`{"event":"ready","total":371}` / `{"event":"indexed","count":3,"total":374}`

### MCP 协议实现

**传输层：**
- TCP `localhost:3456`：Hummingbird HTTP server，`POST /mcp` 处理 JSON-RPC，`GET /mcp/sse` 处理 SSE
- Unix socket `/tmp/coding-memory.sock`：同协议，供 CLI bridge 内部使用

**工具列表（与现有 TypeScript 版一一对应）：**
- `list_sessions` — GRDB 查询 sessions 表
- `get_session` — 读取消息（暂时调用 Node.js adapter，或缓存到 SQLite messages 表）
- `search` — FTS5 全文检索
- `project_timeline` — 按 cwd 分组时间线
- `stats` — 聚合统计
- `get_context` — 最近 N 条相关会话
- `export` — 导出单条会话

### SQLite 扩展表（Swift App 管理）

```sql
-- App 启动时自动创建（不影响 Node.js 写入的表）
CREATE TABLE IF NOT EXISTS favorites (
  session_id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tags (
  session_id TEXT NOT NULL,
  tag        TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (session_id, tag)
);
```

### 配置文件

App 写入 `~/.coding-memory/app-config.json`：
```json
{
  "httpPort": 3456,
  "nodejsPath": "/usr/local/bin/node",
  "launchAtLogin": true
}
```

## AI 工具接入配置

**Claude Code** (`~/.claude/settings.json` 或 `.mcp.json`):
```json
{
  "mcpServers": {
    "coding-memory": {
      "command": "/Applications/CodingMemory.app/Contents/MacOS/coding-memory-cli"
    }
  }
}
```

**Codex** (`~/.codex/config.toml`):
```toml
[mcp_servers.coding-memory]
type = "stdio"
command = "/Applications/CodingMemory.app/Contents/MacOS/coding-memory-cli"
enabled = true
```

**HTTP/SSE 直连（未来支持）：**
```json
{
  "mcpServers": {
    "coding-memory": {
      "url": "http://localhost:3456/mcp/sse"
    }
  }
}
```

## 依赖

| 库 | 用途 |
|----|------|
| GRDB.swift | SQLite ORM（只读查询） |
| Hummingbird | HTTP/SSE server（轻量，SwiftNIO-based） |
| swift-argument-parser | CLI bridge 命令行解析 |
| swift-mcp-sdk（可选）| MCP 协议结构体（若成熟度够则用） |

## 分发

- Apple Developer 账号签名（Developer ID Application）
- `xcodebuild archive` → `xcrun notarytool` 公证
- `create-dmg` 打包为 `.dmg`
- Node.js indexer 以 `pkg` 或 `node_modules` + 入口脚本形式打包进 `.app/Contents/Resources/`

## 实现顺序（供后续 writing-plans 参考）

1. Xcode 项目骨架（两个 target + 共享模块）
2. Node.js 精简（daemon.ts，去掉 MCP server）
3. Database.swift（GRDB 只读查询，覆盖现有 7 个工具）
4. IndexerProcess.swift（启动/重启 Node.js，解析状态）
5. MCPServer.swift（Hummingbird TCP + Unix socket）
6. MCPTools.swift（7 个工具 Swift 实现）
7. CodingMemoryCLI stdio bridge
8. SwiftUI 基础 UI（Menu Bar + SessionList + Search）
9. SwiftUI 完整 UI（Timeline + Favorites + Tags + Export）
10. LaunchAgent 开机自启
11. 签名 + 公证 + DMG 打包
