# Viking Sessions API 迁移 + 内容清洗

## 背景

当前 Viking 集成使用 **Resources API**（temp_upload → 作为文档导入），把会话对话当作 markdown 文档处理，按标题递归分解成树。导致：

1. **17× VLM 成本放大** — 1 个 session → ~17 个语义节点，每个都需要 kimi-k2.5 VLM 调用
2. **27,573 个卡死的语义任务** — VLM 周配额耗尽（84M tokens），队列永久阻塞
3. **噪声数据** — 系统提示、工具调用、密码全部未经过滤推送
4. **142K 向量** 存储于 VectorDB，实际只有 ~1,700 个 session（应为 ~15K）

Viking 有专门的 **Sessions API**（`/sessions/custom` → `messages` → `commit`）为对话设计 — 不做 markdown 分解，内置去重，每个 session 只需 ~1-2 次 VLM 调用。

**目标：** 从 Resources API 切换到 Sessions API，添加内容过滤，清理旧数据，重新回填。

## 需要修改的文件

| 文件 | 改动 |
|------|--------|
| `src/core/viking-bridge.ts` | 用 Sessions API 新增 `pushSession()`；保留 `addResource()` 向后兼容；新增 `deleteResources()` 清理方法 |
| `src/core/viking-filter.ts` | **新建** — 内容过滤管道（复用 adapter 的 `isSystemInjection` 模式） |
| `src/core/indexer.ts` | 更新 `pushToViking()` 使用新的 `pushSession()` + 过滤管道 |
| `src/web.ts` | 更新 backfill 端点使用 `pushSession()` + 过滤；新增数据清理端点 |
| `tests/core/viking-bridge.test.ts` | 更新 mock 适配 Sessions API 调用 |
| `tests/core/indexer-viking.test.ts` | 更新推送断言 |

**不需要改动的文件**（已验证安全）：
- `src/tools/search.ts` — 通过 `sessionIdFromVikingUri()` helper 获取 ID，与 API 路径无关
- `src/tools/get_context.ts` — 通过 `toVikingUri()` helper 构建 URI，与 API 路径无关
- `src/tools/get_memory.ts` — 通过 `find()` 加 URI 范围搜索，不变
- URI 辅助函数 `toVikingUri()` / `sessionIdFromVikingUri()` — URI 格式保持 `viking://session/...`

## 实施步骤

### 第 1 步：内容过滤器（`src/core/viking-filter.ts`）

新模块，接收 `{ role, content }[]` 返回过滤后的消息：

```typescript
export function filterForViking(messages: { role: string; content: string }[]): { role: string; content: string }[] {
  return messages
    .filter(m => !isSystemContent(m.content))
    .map(m => ({ role: m.role, content: redactSensitive(truncateContent(m.content)) }))
    .filter(m => m.content.trim().length > 0)
}
```

**过滤规则（复用 `claude-code.ts:isSystemInjection()` + `preamble-detector.ts` 模式）：**

1. **系统注入检测** — 跳过匹配以下模式的消息：
   - `startsWith('# AGENTS.md instructions for ')`
   - `includes('<INSTRUCTIONS>')` / `<system-reminder>` / `<environment_context>`
   - `startsWith('Base directory for this skill:')` / `startsWith('Invoke the superpowers:')`
   - `includes('<command-name>')` / `<command-message>` / `<local-command-caveat>`
   - `startsWith('<EXTREMELY_IMPORTANT>')` / `<EXTREMELY-IMPORTANT>`

2. **敏感数据脱敏** — 正则替换：
   - 密码模式：`PGPASSWORD=\S+` → `PGPASSWORD=***`
   - API 密钥：`sk-[a-zA-Z0-9]{20,}` → `sk-***`
   - Bearer token：`Bearer [a-zA-Z0-9-_]+` → `Bearer ***`

3. **内容截断** — 每条消息限制：
   - 最大 4000 字符（覆盖 99% 有意义内容）
   - 超长保留前 2000 + 后 2000，中间用 `\n...[truncated]...\n` 连接

4. **工具输出噪声** — 剥离纯工具调用消息：
   - 全部内容匹配 `` `ToolName`: ... `` 且无其他自然语言
   - 内容仅为反引号包裹的工具摘要（无有意义的分析文本）

### 第 2 步：VikingBridge Sessions API（`src/core/viking-bridge.ts`）

在现有 `addResource()` 旁新增 `pushSession()` 方法：

```typescript
async pushSession(
  sessionId: string,
  messages: { role: string; content: string }[],
): Promise<void> {
  // 第 1 步：创建 session（幂等 — 已存在则加载）
  await this.post(`${this.api}/sessions/custom`, { session_id: sessionId })

  // 第 2 步：添加消息（异步 + 去重）
  for (const msg of messages) {
    await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
      role: msg.role,
      content: msg.content,
    })
  }

  // 第 3 步：提交（异步，不阻塞）
  await this.post(`${this.api}/sessions/${sessionId}/commit/async`, {})
}

// 清理旧 resources 数据
async deleteResources(): Promise<void> {
  await fetch(`${this.api}/fs?uri=${encodeURIComponent('viking://resources/')}&recursive=true`, {
    method: 'DELETE',
    headers: this.headers,
    signal: AbortSignal.timeout(60000),
  })
}
```

新增通用 `post()` 辅助方法减少重复代码。

**Session ID 格式：** `engram-{source}-{project}-{sessionId}`（确定性、幂等）

**设计决策：**
- 使用 `/messages/async` 内置 MD5 去重（重复推送 = 自动忽略）
- 使用 `/commit/async` fire-and-forget（立即返回）
- 无需 multipart 上传 — 干净的 JSON API
- 每条消息超时：5s；提交超时：10s

### 第 3 步：更新 Indexer（`src/core/indexer.ts`）

修改 `pushToViking()`：

```typescript
private pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): void {
  if (!this.opts?.viking || messages.length === 0) return
  this.opts.viking.checkAvailable().then(ok => {
    if (!ok) return
    const filtered = filterForViking(messages)
    if (filtered.length === 0) return
    const sessionId = `engram-${info.source}-${info.project ?? 'unknown'}-${info.id}`
    this.opts!.viking!.pushSession(sessionId, filtered).catch(() => {})
  }).catch(() => {})
}
```

### 第 4 步：更新 Backfill 端点（`src/web.ts`）

1. 使用同样的内容过滤器 + Sessions API
2. 只推送 **premium-tier** session（当前代码推送了所有非 agent session）
3. 新增 `POST /api/viking/cleanup` 端点删除旧 resources 数据

### 第 5 步：数据迁移（手动操作）

1. **删除旧 resources 数据**：
   ```bash
   curl -X DELETE -H "Authorization: Bearer engram-viking-2026" \
     "http://10.0.8.9:1933/api/v1/fs?uri=viking://resources/&recursive=true"
   ```
2. **用过滤后的数据重新回填**：
   ```bash
   curl -X POST "http://localhost:3035/api/viking/backfill?limit=100&offset=0"
   # 逐步增加 offset 直到完成
   ```

### 第 6 步：更新测试

- `viking-bridge.test.ts`：新增 `pushSession()` 测试；mock `/sessions/custom`、`/messages/async`、`/commit/async`
- `indexer-viking.test.ts`：断言调用 `pushSession()` 而非 `addResource()`；验证过滤已生效
- 新增 `viking-filter.test.ts`：每条过滤规则的单元测试

## 验证方式

1. **单元测试**：`npm test` — 所有 278+ 测试通过
2. **构建**：`npm run build` 成功
3. **手动测试**：启动 daemon，触发一个 premium session 的重新索引，验证：
   - Viking `/sessions` 列表显示新 session
   - `viking://resources/` 下无新资源创建
   - 队列 Semantic 数量 ≈ session 数量（非 17× 放大）
4. **内容检查**：从 Viking 读取推送的 session — 无系统提示、无密码、无工具噪声
5. **搜索测试**：使用 MCP `search` 工具 — 验证结果仍返回正确 session ID
6. **回填验证**：对 5-10 个 session 执行 backfill，验证队列保持比例
