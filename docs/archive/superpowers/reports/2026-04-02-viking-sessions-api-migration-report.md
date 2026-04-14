# Viking Sessions API 迁移报告

> **日期**: 2026-04-02  
> **状态**: ✅ 已完成，待推送  
> **分支**: `main` (本地)  
> **基线 SHA**: `60c5bd3` → **HEAD**: `0d2cac4`  
> **测试**: 687/687 通过 | **构建**: 通过  

---

## 1. 问题背景

Engram 的 OpenViking 集成在处理 ~500 个编码会话时消耗了超过 **1 亿 token**，且始终无法处理完毕。

### 根因分析

通过实时 API 测试（`http://10.0.8.9:1933`）确认：

| API | 每个会话的处理开销 | 500 个会话总消耗 |
|-----|-------------------|-----------------|
| **Resources API**（旧） | ~17 次 VLM 调用（Parser → TreeBuilder → AGFS → SemanticQueue → Vector Index） | ~8,500 次 VLM 任务 → **1 亿+ token** |
| **Sessions API**（新） | ~2-3 次 LLM 调用（Messages → Archive → L0/L1 Summary → Memory Extraction） | ~1,500 次 LLM 任务 → **~600 万 token** |

**核心问题**：代码使用了 `addResource()` 将整个会话作为"资源"上传，触发了 Viking 的完整文档处理流水线（包含大量 VLM 视觉理解调用），而非使用 Sessions API 的轻量会话归档流程。

### 额外发现的 Bug

在实时服务器验证中发现了一个**文档未记录的关键行为差异**：

| 端点 | 行为 |
|------|------|
| `POST /sessions/{id}/messages/async` | 返回 200 `"accepted"` 但 **不持久化消息**（message_count 始终为 0） |
| `POST /sessions/{id}/messages` | 正确持久化消息，message_count 递增 |
| `POST /sessions/{id}/commit` (sync) | 触发 LLM 处理，**连接超时** |
| `POST /sessions/{id}/commit/async` | 正确异步提交，立即返回 `"in_progress"` |

**结论**：必须使用 **同步 `/messages`** + **异步 `/commit/async`** 的组合。

---

## 2. 解决方案

从 Resources API 全面迁移到 Sessions API，预估降低 **~94%** 的 token 消耗。

### 架构变更

```
旧流程:
  indexer → addResource(viking://resources/..., 全文) → VLM Pipeline × 17 → Vector Index
                                                         ↑ 这是 token 消耗的根源

新流程:
  indexer → pushSession(composite_id, messages[]) → LLM Summary × 2-3 → Memory Extraction
                                                     ↑ 成本降低 ~94%

搜索流程变更:
  旧: find() → resources[] → sessionIdFromVikingUri() → DB lookup → 返回会话
  新: find() → memories[] + skills[] → 直接作为上下文使用 + DB 本地摘要补充
```

---

## 3. 变更清单

### 8 个 Commit

| # | SHA | 描述 |
|---|-----|------|
| 1 | `08270f8` | 修复 `pushSession` parts 格式、添加 agentId header、find() 包含 skills、修复 findMemories URI |
| 2 | `5e1601a` | bootstrap 传递 agentId 到 VikingBridge 构造函数 |
| 3 | `251b61b` | indexer 从 `addResource()` 切换到 `pushSession()` + 复合会话 ID |
| 4 | `40a84b1` | 重写 `get_context` Viking 增强段，使用 memory 片段替代 resource URI 映射 |
| 5 | `40c5717` | search.ts 添加 memory 管道，surface memories 为 `vikingMemories` 字段 |
| 6 | `5c3a31e` | web.ts backfill 端点从 `addResource()` 切换到 `pushSession()` |
| 7 | `4ea8dc0` | 添加 `@deprecated` 标记和澄清注释 |
| 8 | `0d2cac4` | **关键修复**：`/messages/async` → `/messages` (sync)，修复消息不持久化问题 |

### 12 个文件变更

```
src/core/viking-bridge.ts        — 主 HTTP 客户端，pushSession/find/findMemories 重写
src/core/indexer.ts               — pushToViking() 从 addResource → pushSession
src/core/bootstrap.ts             — 传递 agentId 配置
src/core/config.ts                — VikingSettings 添加 agentId 字段
src/tools/get_context.ts          — Viking 增强段重写为 memory-based
src/tools/search.ts               — 添加 vikingMemories 收集和返回
src/web.ts                        — backfill 端点迁移
tests/core/viking-bridge.test.ts  — 新增 4 个测试
tests/core/indexer-viking.test.ts — 更新 2 个测试
tests/tools/get_context-viking.test.ts — 重写 2 个测试
tests/tools/search-viking.test.ts — 新增 1 个测试
docs/superpowers/plans/...        — 实施计划
```

**统计**: `+1,046 / -85` 行（含 833 行计划文档）

---

## 4. 核心变更详解

### 4.1 VikingBridge (`viking-bridge.ts`)

**pushSession 消息格式修复**：
```typescript
// 旧（错误）
{ role: msg.role, content: msg.content }

// 新（正确）
{ role: msg.role, parts: [{ type: 'text', text: msg.content }] }
```

**消息端点修复**：
```typescript
// 旧（不持久化消息！）
await this.post(`${this.api}/sessions/${id}/messages/async`, ...)

// 新（正确持久化）
await this.post(`${this.api}/sessions/${id}/messages`, ...)
```

**agentId 支持**：构造函数接受 `agentId` 参数，自动添加 `X-Agent-Id` header 到所有请求。

**find() 增强**：返回结果现在包含 `skills`（之前被丢弃）。

**findMemories() 双作用域搜索**：
```typescript
// 同时搜索 user 和 agent 作用域
const [userMems, agentMems] = await Promise.all([
  this.find(query, limit, 'viking://user/'),
  this.find(query, limit, 'viking://agent/')
]);
```

### 4.2 Indexer (`indexer.ts`)

从 `addResource()` 迁移到 `pushSession()`：

```typescript
// 旧
const uri = toVikingUri(info.source, info.project, info.id);
this.viking.addResource(uri, allContent, info.source);

// 新 — 复合会话 ID，避免路径冲突
const compositeId = `${info.source}::${info.project ?? 'unknown'}::${info.id}`;
this.viking.pushSession(compositeId, filtered);
```

保持 fire-and-forget 模式，Viking 推送不阻塞索引流程。

### 4.3 get_context (`get_context.ts`)

重写 Viking 增强段：

```
旧流程: find() → resource URIs → sessionIdFromVikingUri() → DB getSession → toVikingUri() → readFn
新流程: find() → memory snippets → 直接作为 [memory] 行输出 + DB 本地摘要补充
```

Memory 片段比原始会话内容更有用——它们是 Viking 提取的精华知识。

### 4.4 search (`search.ts`)

新增 `vikingMemories` 字段：

- Memory/skill URI（`viking://user/...`、`viking://agent/...`）不再被静默丢弃
- 收集为 `vikingMemoryResults`，返回时截取前 5 条
- Session URI 仍通过 `sessionIdFromVikingUri()` 映射到本地 DB

### 4.5 web.ts backfill

Backfill 端点同步迁移到 `pushSession()`，包含去重追踪（`viking_pushed_msg_count`）。

---

## 5. 配置变更

`~/.engram/settings.json` 新增字段：

```json
{
  "viking": {
    "url": "http://10.0.8.9:1933",
    "apiKey": "...",
    "agentId": "ffb1327b18bf"
  }
}
```

`agentId` 用于 `X-Agent-Id` header，将请求关联到特定 agent 的 memory 空间。不设置则使用 Viking 默认 agent。

---

## 6. 向后兼容性

| 场景 | 兼容性 |
|------|--------|
| 已推送的 Resources API 数据 | ✅ 保留，不受影响 |
| `viking_pushed_msg_count` 列 | ✅ 复用，语义不变（原始消息计数） |
| `toVikingUri()` 函数 | ✅ 保留（标记 `@deprecated`），测试仍引用 |
| `addResource()` 方法 | ✅ 保留在 VikingBridge 上，只是不再从热路径调用 |
| 无 Viking 配置的用户 | ✅ 无影响，所有 Viking 路径均有 null check |

---

## 7. 测试覆盖

| 变更点 | 测试 |
|--------|------|
| `parts` 格式 | ✅ `viking-bridge.test.ts` — 显式断言消息体 |
| `agentId` header 有/无 | ✅ 2 个专用测试 |
| `find()` 包含 skills | ✅ 专用测试 |
| 双作用域 `findMemories()` | ✅ 验证 2 次调用 + `target_uri` + 排序 |
| Indexer 使用 `pushSession()` | ✅ 更新 mock + 断言 |
| `get_context` memory 片段 | ✅ 2 个测试（纯 memory / memory + 摘要） |
| Search `vikingMemories` | ✅ 混合 session + memory 结果测试 |
| 同步 `/messages` 端点 | ✅ 断言 URL 匹配 `/messages$`（非 `/messages/async`） |
| Backfill 端点 | ⚠️ 无直接单测（共享 `pushSession()` + `filterForViking()` 代码路径） |

**总计**: 687/687 测试通过，耗时 ~8.5s

---

## 8. 实时验证结果

在 `http://10.0.8.9:1933` 上的验证：

```
✅ 服务器可达
✅ 会话创建成功 (POST /sessions/custom → 200)
✅ 同步消息推送成功 (POST /sessions/{id}/messages → 200, message_count 递增)
✅ 异步提交成功 (POST /sessions/{id}/commit/async → 200, "in_progress")
✅ find() 搜索返回结果 (POST /search/find → 200)
✅ 双作用域 memory 搜索工作正常
✅ 最终 message_count = 2 (消息正确持久化)
```

---

## 9. 已知限制

1. **`detail` 参数语义变更**：`get_context` 的 `abstract/overview/full` 三级详细度不再影响 Viking 返回内容（memory 无分级视图），仅影响环境信息深度。已添加代码注释说明。

2. **Agent ID 自动发现未实现**：设计规格中提到的自动发现功能未实施，当前仅支持手动配置。属于 nice-to-have。

3. **Memory 搜索结果无置信度评分**：`vikingMemories` 返回 `string[]`，不含 score/source 元数据。未来迭代可增强。

4. **`/messages/async` 行为未文档化**：Viking 官方文档未说明此端点不持久化消息。已记录在 memory 中避免将来踩坑。

---

## 10. 相关文档

- **设计规格**: [`docs/superpowers/specs/2026-04-02-viking-sessions-api-fix-design.md`](../specs/2026-04-02-viking-sessions-api-fix-design.md)
- **实施计划**: [`docs/superpowers/plans/2026-04-02-viking-sessions-api-fix.md`](../plans/2026-04-02-viking-sessions-api-fix.md)
