# coding-memory

MCP Server：读取多个 AI 编程助手的会话日志，实现跨工具历史上下文共享。

在 Codex 里做了半天工作切到 Claude Code 继续时，不需要手动解释之前做了什么——AI 助手可以直接调用 `get_context` 查询历史。

## 支持的工具

| 工具 | 日志路径 |
|------|---------|
| Codex CLI/App | `~/.codex/sessions/` |
| Claude Code | `~/.claude/projects/` |
| Gemini CLI | `~/.gemini/tmp/` |
| OpenCode | `~/.local/share/opencode/` |

## 安装

```bash
git clone https://github.com/bbingz/coding-memory
cd coding-memory
npm install && npm run build
```

## 注册为 MCP Server

### Claude Code

在 `~/.claude/settings.json` 中加入：

```json
{
  "mcpServers": {
    "coding-memory": {
      "command": "node",
      "args": ["/absolute/path/to/coding-memory/dist/index.js"]
    }
  }
}
```

### Codex

在 `~/.codex/config.toml` 中加入：

```toml
[mcp_servers.coding-memory]
command = "node"
args = ["/absolute/path/to/coding-memory/dist/index.js"]
```

## MCP Tools

| Tool | 说明 |
|------|------|
| `get_context` | **核心**：为当前工作目录自动提取相关历史上下文 |
| `list_sessions` | 列出会话，支持按工具/项目/时间过滤 |
| `get_session` | 读取单个会话完整内容（分页） |
| `search` | 全文搜索对话内容（FTS5，毫秒级） |
| `project_timeline` | 某项目跨工具的操作时间线 |
| `stats` | 用量统计（按工具/项目/时间分组） |
| `export` | 导出会话为 Markdown 或 JSON |

## 工作原理

1. 首次启动时扫描所有会话文件，在 `~/.coding-memory/index.sqlite` 建立索引
2. 通过 chokidar 监听文件变化，增量更新索引
3. 200MB+ 的大文件逐行流式读取，不整体加载进内存
4. 全文搜索使用 SQLite FTS5 trigram 索引，支持中英文

## 开发

```bash
npm test          # 运行测试（42 tests）
npm run build     # 编译 TypeScript → dist/
npm run dev       # 开发模式（tsx 直接运行）
```
