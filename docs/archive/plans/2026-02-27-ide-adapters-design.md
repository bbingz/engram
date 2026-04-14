# IDE AI 对话适配器设计

**日期：** 2026-02-27
**状态：** 已批准，待实现

## 背景

coding-memory 已支持 8 个 AI 编程助手的对话索引（codex, claude-code, gemini-cli, opencode, iflow, qwen, kimi, cline）。本设计新增对主流 IDE 内置 AI 对话的支持。

## 调查结论

### 本地存储格式

| IDE / 工具 | Source | 存储格式 | 存储位置 |
|-----------|--------|---------|---------|
| Antigravity 内置 cascade | `antigravity` | 加密 .pb → gRPC API | `~/.gemini/antigravity/daemon/ls_*.json`（含 port+token） |
| Windsurf 内置 cascade | `windsurf` | 加密 .pb → gRPC API | `~/.codeium/windsurf/daemon/*.json` |
| Cursor | `cursor` | SQLite `cursorDiskKV` | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |
| VS Code Copilot Chat | `vscode` | SQLite + JSONL | `~/Library/Application Support/Code/User/workspaceStorage/*/state.vscdb` + `chatSessions/*.jsonl` |

### 已覆盖（无需新增）

- **Claude 插件**（VS Code / Antigravity）：对话写入 `~/.claude/projects/`，由现有 `claude-code` 适配器索引
- **OpenAI Codex CLI**：已由 `codex` 适配器覆盖

### 暂不支持

- **ChatGPT 桌面 App**（`com.openai.chat/*.data`）：加密存储，无公开 API。用户记得有中转方案，后续实现。

## 方案：方案 B（gRPC 缓存）

Antigravity/Windsurf 的 .pb 文件完全加密（Shannon 熵接近 8.0 bits/byte）。唯一可行的访问路径是语言服务器暴露的 gRPC API：

- daemon 配置文件（JSON）明文存储 `httpsPort` 和 `csrfToken`
- gRPC 方法：`GetAllCascadeTrajectories()` + `ConvertTrajectoryToMarkdown(id)`
- 导出结果缓存到 `~/.coding-memory/cache/<adapter>/<uuid>.md`
- 适配器从缓存读取，不依赖 app 是否在运行

## 架构设计

### 新增文件

```
src/adapters/
  antigravity.ts         # Antigravity cascade gRPC 适配器
  windsurf.ts            # Windsurf cascade gRPC 适配器
  cursor.ts              # Cursor SQLite 适配器
  vscode.ts              # VS Code Copilot Chat 适配器
  grpc/
    cascade-client.ts    # Antigravity/Windsurf 共享 gRPC 客户端
```

### 修改文件

- `src/main.ts` — 注册 4 个新适配器
- `src/adapters/types.ts` — SourceName 添加 `antigravity | windsurf | cursor | vscode`
- `src/tools/list_sessions.ts` — source enum 添加新名称
- `src/tools/search.ts` — 同上

### 数据流

#### Antigravity / Windsurf

```
~/.gemini/antigravity/daemon/ls_*.json
  → httpsPort, csrfToken
  → gRPC GetAllCascadeTrajectories()         # 获取会话列表 + 标题 + 时间戳
  → gRPC ConvertTrajectoryToMarkdown(id)     # 获取完整对话 Markdown
  → ~/.coding-memory/cache/antigravity/<uuid>.md
  → parseSessionInfo() / streamMessages() 从缓存读取
```

缓存刷新策略：比对 `.pb` 文件的 mtime，有变化时重新拉取。

#### Cursor

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
  → cursorDiskKV: composerData:<uuid>      # 会话元数据（标题、时间戳）
  → cursorDiskKV: bubbleId:<id>:<msgId>    # 逐条消息（type 1=user, 2=assistant）
  → fallback: ItemTable 'workbench.panel.aichat.view.aichat.chatdata'  # 旧格式
```

#### VS Code Copilot Chat

```
~/Library/Application Support/Code/User/workspaceStorage/*/state.vscdb
  → chat.ChatSessionStore.index            # 会话列表（过滤 isEmpty: true）
  → chatSessions/<sessionId>.jsonl         # 消息内容（JSONL 格式）
```

### gRPC 客户端实现

新增依赖：`@grpc/grpc-js`、`@grpc/proto-loader`

```typescript
class CascadeGrpcClient {
  static async fromDaemonDir(dir: string): Promise<CascadeGrpcClient | null>
  async listConversations(): Promise<ConversationSummary[]>
  async getMarkdown(conversationId: string): Promise<string>
}
```

Proto 定义内联为最小子集（来源：extension.js 中嵌入的 FileDescriptorProto）。

### 缓存目录

```
~/.coding-memory/cache/
  antigravity/   # Antigravity 对话 Markdown 缓存
  windsurf/      # Windsurf 对话 Markdown 缓存
```

## 实现顺序

1. `src/adapters/types.ts` — 添加新 SourceName
2. `src/adapters/cursor.ts` — 最简单，纯 SQLite
3. `src/adapters/vscode.ts` — SQLite + JSONL
4. `src/adapters/grpc/cascade-client.ts` — gRPC 客户端
5. `src/adapters/antigravity.ts` — 依赖 cascade-client
6. `src/adapters/windsurf.ts` — 复用 cascade-client
7. `src/main.ts` + tools 更新

## 依赖变更

```json
{
  "@grpc/grpc-js": "^1.x",
  "@grpc/proto-loader": "^0.x"
}
```

## Future Work

- ChatGPT 桌面 App 适配器（`com.openai.chat/*.data`）：用户有中转方案，后续确认后实现
- Antigravity 中 Claude/Codex 插件的对话：Claude 已覆盖；Codex 即 ChatGPT 桌面 App，同上
