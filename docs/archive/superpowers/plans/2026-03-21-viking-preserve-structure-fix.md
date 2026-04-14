# Viking preserve_structure 修正 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Viking 推送从 Sessions API（内容不可搜索）切换回 Resources API + `preserve_structure: true`（内容可搜索、不分解），保留已有的 content filter 管道。

**Architecture:** 一行参数改动 `addResource()` 加 `preserve_structure: true` → indexer 和 backfill 从 `pushSession()` 改回 `addResource()` + filter → 测试 → 清理 Viking 数据 → 重新回填验证搜索。

**Tech Stack:** TypeScript (ES2022), Vitest, OpenViking Resources API

**实测验证基础：** `preserve_structure: true` 已在 Viking 上测试通过 — 1 resource = 1 file（无分解）、`find` 搜索 score=0.649 排第一、`grep` 可搜、`content/read` 内容完整。

---

## File Structure

| File | 改动 |
|------|------|
| `src/core/viking-bridge.ts:169` | `addResource()` import body 加 `preserve_structure: true` — **1 行** |
| `src/core/indexer.ts:12,27-35` | 恢复 `toVikingUri` import，`pushToViking()` 改回用 `addResource()` + filter |
| `src/web.ts:551-552` | backfill 改回用 `addResource()` + filter |
| `tests/core/viking-bridge.test.ts:73-74` | `addResource` 测试验证 import body 包含 `preserve_structure` |
| `tests/core/indexer-viking.test.ts:27-53` | mock 和断言改回 `addResource` |

不变的文件：
- `src/core/viking-filter.ts` — 完全保留，filter 管道不变
- `tests/core/viking-filter.test.ts` — 26 个测试不变
- `src/core/db.ts` — `listPremiumSessions()` 保留
- `pushSession()` 和 `deleteResources()` 保留在 `viking-bridge.ts` 中不删除

---

### Task 1: addResource 加 preserve_structure + 测试

**Files:**
- Modify: `src/core/viking-bridge.ts:169`
- Modify: `tests/core/viking-bridge.test.ts` (addResource 测试)

- [ ] **Step 1: 更新 addResource 测试，验证 preserve_structure**

在 `tests/core/viking-bridge.test.ts` 的 `addResource` describe 块中，修改现有测试 "uploads temp file then imports as resource"（约 line 65-75）。在断言 import call 时增加 body 检查：

在 `expect(mockFetch.mock.calls[1][0]).toBe(...)` 之后追加：
```typescript
    const importBody = JSON.parse(mockFetch.mock.calls[1][1].body);
    expect(importBody.preserve_structure).toBe(true);
```

- [ ] **Step 2: 运行测试确认 FAIL**

Run: `npx vitest run tests/core/viking-bridge.test.ts -t "uploads temp file"`
Expected: FAIL — `importBody.preserve_structure` is `undefined`

- [ ] **Step 3: 修改 addResource 加 preserve_structure**

在 `src/core/viking-bridge.ts` line 169，将：
```typescript
      body: JSON.stringify({ temp_path: tempPath, wait: false }),
```
改为：
```typescript
      body: JSON.stringify({ temp_path: tempPath, wait: false, preserve_structure: true }),
```

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: All PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "fix(viking): addResource passes preserve_structure: true to prevent decomposition"
```

---

### Task 2: indexer 改回 addResource + filter

**Files:**
- Modify: `src/core/indexer.ts:12,27-35`
- Modify: `tests/core/indexer-viking.test.ts:27-53`

- [ ] **Step 1: 更新 indexer 测试**

修改 `tests/core/indexer-viking.test.ts`：

第一个测试（line 27-54），mock 改为：
```typescript
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      addResource: vi.fn().mockResolvedValue(undefined),
    } as unknown as VikingBridge
```

断言改为：
```typescript
    expect(mockViking.addResource).toHaveBeenCalledWith(
      expect.stringContaining('viking://session/codex/'),
      expect.stringContaining('[user] Hello'),
      expect.objectContaining({ source: 'codex' })
    )
```

第二个测试（line 57-63），mock 改为：
```typescript
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      addResource: vi.fn().mockRejectedValue(new Error('server down')),
    } as unknown as VikingBridge
```

- [ ] **Step 2: 运行测试确认 FAIL**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: FAIL — indexer 仍调 `pushSession`

- [ ] **Step 3: 修改 indexer pushToViking**

在 `src/core/indexer.ts`：

1. Line 12 的 import 改回：
```typescript
import { toVikingUri, type VikingBridge } from './viking-bridge.js'
```

2. `pushToViking` 方法（line 27-36）替换为：
```typescript
  private pushToViking(info: SessionInfo, messages: { role: string; content: string }[]): void {
    if (!this.opts?.viking || messages.length === 0) return
    this.opts.viking.checkAvailable().then(ok => {
      if (!ok) return
      const filtered = filterForViking(messages)
      if (filtered.length === 0) return
      const uri = toVikingUri(info.source, info.project, info.id)
      const content = filtered.map(m => `[${m.role}] ${m.content}`).join('\n\n')
      this.opts!.viking!.addResource(uri, content, {
        source: info.source,
        project: info.project ?? '',
        startTime: info.startTime,
        model: info.model ?? '',
      }).catch(() => {})
    }).catch(() => {})
  }
```

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: All PASS

- [ ] **Step 5: 运行全量测试**

Run: `npm test`
Expected: All tests PASS

- [ ] **Step 6: 提交**

```bash
git add src/core/indexer.ts tests/core/indexer-viking.test.ts
git commit -m "fix(viking): indexer uses addResource + filter (not pushSession)

Resources API with preserve_structure keeps content searchable.
Sessions API commit clears content, making it unsearchable."
```

---

### Task 3: backfill 改回 addResource + filter

**Files:**
- Modify: `src/web.ts:548-552`

- [ ] **Step 1: 修改 backfill 端点**

在 `src/web.ts`，将 backfill 循环中的推送代码（约 line 548-552）从：
```typescript
        const sessionId = `engram-${session.source}-${session.project ?? 'unknown'}-${session.id}`
        await viking.pushSession(sessionId, filtered)
```
改为：
```typescript
        const content = filtered.map(m => `[${m.role}] ${m.content}`).join('\n\n')
        const uri = `viking://session/${session.source}/${session.project ?? 'unknown'}/${session.id}`
        await viking.addResource(uri, content, {
          source: session.source,
          project: session.project ?? '',
          startTime: session.startTime,
        })
```

需要在文件顶部确认已有 `filterForViking` import（Task 4 已添加，应该还在）。

- [ ] **Step 2: 构建 + 全量测试**

Run: `npm run build && npm test`
Expected: Build 成功，所有测试 PASS

- [ ] **Step 3: 提交**

```bash
git add src/web.ts
git commit -m "fix(viking): backfill uses addResource + filter (not pushSession)"
```

---

### Task 4: 验收 — 清理 Viking + 回填 + 搜索验证

**手动操作步骤。**

- [ ] **Step 1: 构建并重启 daemon**

```bash
npm run build
pkill -f "node dist/daemon" 2>/dev/null; sleep 2
node dist/daemon.js > /tmp/engram-daemon.log 2>&1 &
sleep 8
```

- [ ] **Step 2: 删除 Viking 所有旧数据**

```bash
# 删除所有旧 sessions（Sessions API 推送的，内容为空）
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions" --max-time 30 | \
  python3 -c "import sys,json; [print(s['session_id']) for s in json.load(sys.stdin).get('result',[])]" | \
  while read sid; do
    curl -s -X DELETE -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions/$sid" --max-time 10 > /dev/null
  done
echo "Sessions deleted"

# 删除残留 resources
curl -s -X DELETE -H "Authorization: Bearer engram-viking-2026" \
  "http://10.0.8.9:1933/api/v1/fs?uri=viking%3A%2F%2Fresources%2F&recursive=true" --max-time 120
echo "Resources deleted"
```

验证干净：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions" --max-time 15 | python3 -c "import sys,json; print(f'Sessions: {len(json.load(sys.stdin).get(\"result\",[]))}')"
```
Expected: `Sessions: 0`

- [ ] **Step 3: 回填 5 个 session 测试**

```bash
curl -s -X POST "http://localhost:3457/api/viking/backfill?limit=5&offset=0" --max-time 300 | python3 -m json.tool
```
Expected: `pushed >= 3, errors = 0`

- [ ] **Step 4: 等待 Semantic 处理 + 验证搜索**

```bash
# 等 2 分钟让 VLM 处理
sleep 120

# 检查 queue
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue" --max-time 15 | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['status'])"

# 搜索验证
curl -s -X POST -H "Authorization: Bearer engram-viking-2026" -H "Content-Type: application/json" \
  "http://10.0.8.9:1933/api/v1/search/find" -d '{"query":"bug fix code","limit":5}' --max-time 30 | \
  python3 -c "
import sys, json
r = json.load(sys.stdin).get('result', {})
items = (r.get('resources', []) or []) + (r.get('memories', []) or []) if isinstance(r, dict) else []
resources = [i for i in items if '/resources/' in i.get('uri', '')]
print(f'Results: {len(items)}, resources (new): {len(resources)}')
for i in items[:3]:
    print(f'  score={i.get(\"score\",0):.3f}  {i.get(\"uri\",\"?\")[:80]}')
"
```
Expected: 搜索结果包含 `viking://resources/` 开头的新 resource

- [ ] **Step 5: 验证无分解（关键！）**

```bash
# 检查一个新 resource 的子节点数
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/" --max-time 30 | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('result',[]); uri=items[0]['uri'] if items else ''; print(f'First resource: {uri}')" > /tmp/first_resource.txt
cat /tmp/first_resource.txt

first=$(cat /tmp/first_resource.txt | sed 's/First resource: //')
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=$first" --max-time 15 | \
  python3 -c "import sys,json; items=json.load(sys.stdin).get('result',[]); print(f'Sub-nodes: {len(items)} (should be 1 = no decomposition)')"
```
Expected: `Sub-nodes: 1`

- [ ] **Step 6: 全量回填（温和模式）**

```bash
for i in $(seq 0 5 300); do
  result=$(curl -s -X POST "http://localhost:3457/api/viking/backfill?limit=5&offset=$i" --max-time 300 2>/dev/null)
  total=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null)
  pushed=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pushed',0))" 2>/dev/null)
  echo "offset=$i: pushed=$pushed total=$total"
  if [ "$total" = "0" ]; then echo "=== ALL DONE ==="; break; fi
  sleep 30
done
```

- [ ] **Step 7: 最终验证**

```bash
# Sessions 应为 0（没用 Sessions API）
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions" --max-time 15 | python3 -c "import sys,json; print(f'Sessions: {len(json.load(sys.stdin).get(\"result\",[]))}')"

# Resources 数量应 ≈ pushed 数
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/" --max-time 30 | python3 -c "import sys,json; print(f'Resources: {len(json.load(sys.stdin).get(\"result\",[]))}')"

# Queue 验证
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue" --max-time 15 | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['status'])"

# 搜索验证
curl -s -X POST -H "Authorization: Bearer engram-viking-2026" -H "Content-Type: application/json" \
  "http://10.0.8.9:1933/api/v1/search/find" -d '{"query":"fix implementation code","limit":5}' --max-time 30 | \
  python3 -c "
import sys, json
r = json.load(sys.stdin).get('result', {})
items = (r.get('resources', []) or []) + (r.get('memories', []) or []) if isinstance(r, dict) else []
resources = [i for i in items if '/resources/' in i.get('uri', '')]
print(f'Search results: {len(items)}, from resources: {len(resources)}')
"
```
Expected: Resources 数 > 0，搜索结果包含 resources

---

## 验证清单

| 验证项 | 命令 | 期望 |
|--------|------|------|
| 全量测试 | `npm test` | All PASS |
| 构建 | `npm run build` | 无错误 |
| addResource 包含 preserve_structure | 测试断言 | importBody.preserve_structure === true |
| 无文件分解 | `fs/ls` 子节点数 | 1（非 17+）|
| 语义搜索可用 | `find` 返回 resources | score > 0.4 |
| 关键词搜索可用 | `grep` 匹配 | 返回结果 |
| Sessions API 未使用 | `GET /sessions` | 0 |
| content/read 有内容 | 读取 resource | 非空 |
