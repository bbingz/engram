# Viking Sessions API 迁移 + 内容清洗 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Viking 集成从 Resources API（文档分解，17× VLM 放大）切换到 Sessions API（对话原生，1-2× VLM），同时添加内容过滤管道去除噪声和敏感数据。

**Architecture:** 新增 `viking-filter.ts` 过滤管道 → 修改 `viking-bridge.ts` 添加 `pushSession()` 使用 Sessions API → 更新 `indexer.ts` 和 `web.ts` 使用新路径。读取侧（search/get_context/get_memory）完全不变，因为它们通过 URI helper 抽象。

**Tech Stack:** TypeScript (ES2022), Vitest, OpenViking Sessions API (`/api/v1/sessions/*`)

**Spec:** `docs/superpowers/specs/2026-03-21-viking-sessions-api-migration-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/core/viking-filter.ts` | **NEW** — 内容过滤管道：系统注入检测、敏感数据脱敏、截断、工具噪声剥离 |
| `src/core/viking-bridge.ts` | 新增 `pushSession()` + `post()` helper + `deleteResources()`；保留 `addResource()` |
| `src/core/indexer.ts` | `pushToViking()` 改用 `pushSession()` + `filterForViking()` |
| `src/web.ts` | backfill 端点改用 Sessions API + 过滤；新增 cleanup 端点 |
| `tests/core/viking-filter.test.ts` | **NEW** — 过滤规则单元测试 |
| `tests/core/viking-bridge.test.ts` | 新增 `pushSession()` 测试 |
| `tests/core/indexer-viking.test.ts` | 更新断言为 `pushSession()` |

---

### Task 1: 内容过滤器 — 测试 + 实现

**Files:**
- Create: `src/core/viking-filter.ts`
- Create: `tests/core/viking-filter.test.ts`
- Reference: `src/adapters/claude-code.ts:211-222` (isSystemInjection patterns)

- [ ] **Step 1: 编写过滤器测试**

```typescript
// tests/core/viking-filter.test.ts
import { describe, it, expect } from 'vitest'
import { filterForViking } from '../../src/core/viking-filter.js'

describe('filterForViking', () => {
  it('keeps normal user/assistant messages', () => {
    const msgs = [
      { role: 'user', content: 'Fix the login bug' },
      { role: 'assistant', content: 'The issue is in auth.ts line 42...' },
    ]
    const result = filterForViking(msgs)
    expect(result).toHaveLength(2)
    expect(result[0].content).toBe('Fix the login bug')
  })

  it('strips AGENTS.md system injections', () => {
    const msgs = [
      { role: 'user', content: '# AGENTS.md instructions for /Users/bing/-Code-/project\n\n<INSTRUCTIONS>\nAct like a senior engineer...' },
      { role: 'user', content: 'Fix the bug' },
    ]
    expect(filterForViking(msgs)).toHaveLength(1)
    expect(filterForViking(msgs)[0].content).toBe('Fix the bug')
  })

  it('strips <system-reminder> messages', () => {
    const msgs = [{ role: 'user', content: '<system-reminder>\nThe following deferred tools...\n</system-reminder>' }]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips <INSTRUCTIONS> messages', () => {
    const msgs = [{ role: 'user', content: '<INSTRUCTIONS>\nYou are a helpful assistant\n</INSTRUCTIONS>' }]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips skill injection messages', () => {
    const msgs = [
      { role: 'user', content: 'Base directory for this skill: /path/to/skill\n\n# Brainstorming Ideas...' },
      { role: 'user', content: 'Invoke the superpowers:brainstorming skill' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips <command-name> / <command-message> messages', () => {
    const msgs = [{ role: 'user', content: 'Some text <command-name>commit</command-name> more text' }]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips <environment_context> messages', () => {
    const msgs = [{ role: 'user', content: '<environment_context>\nOS: macOS\n</environment_context>' }]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips <EXTREMELY_IMPORTANT> messages', () => {
    const msgs = [{ role: 'user', content: '<EXTREMELY_IMPORTANT>\nYou have superpowers...' }]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('redacts PGPASSWORD', () => {
    const msgs = [{ role: 'assistant', content: 'Running: PGPASSWORD=TPmCa4FjQhRG psql -h 10.10.0.12' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('PGPASSWORD=***')
    expect(result[0].content).not.toContain('TPmCa4FjQhRG')
  })

  it('redacts API keys (sk-...)', () => {
    const msgs = [{ role: 'assistant', content: 'Use key sk-henhtN3lOMGKYoTkDX2PDFY0irmW8Rha14xO3OmAIolGipzJ for auth' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('sk-***')
    expect(result[0].content).not.toContain('henhtN3l')
  })

  it('redacts Bearer tokens', () => {
    const msgs = [{ role: 'assistant', content: 'curl -H "Authorization: Bearer engram-viking-2026" http://...' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('Bearer ***')
    expect(result[0].content).not.toContain('engram-viking-2026')
  })

  it('truncates messages over 4000 chars', () => {
    const long = 'A'.repeat(5000)
    const msgs = [{ role: 'user', content: long }]
    const result = filterForViking(msgs)
    expect(result[0].content.length).toBeLessThan(4200) // 2000 + separator + 2000
    expect(result[0].content).toContain('...[truncated]...')
  })

  it('does not truncate messages under 4000 chars', () => {
    const msgs = [{ role: 'user', content: 'A'.repeat(3999) }]
    expect(filterForViking(msgs)[0].content.length).toBe(3999)
  })

  it('strips tool-only messages (backtick format)', () => {
    const msgs = [
      { role: 'assistant', content: '`Bash`: ls -la /tmp' },
      { role: 'assistant', content: '`Read`: /path/to/file.ts' },
      { role: 'assistant', content: 'The issue is in the Bash command `ls`. Let me fix it.' },
    ]
    const result = filterForViking(msgs)
    expect(result).toHaveLength(1)
    expect(result[0].content).toContain('The issue is')
  })

  it('strips empty messages after filtering', () => {
    const msgs = [
      { role: 'user', content: '   ' },
      { role: 'assistant', content: '' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('handles mixed content — keeps valuable, strips noise', () => {
    const msgs = [
      { role: 'user', content: '# AGENTS.md instructions for /foo\n<INSTRUCTIONS>Be helpful</INSTRUCTIONS>' },
      { role: 'user', content: 'Help me fix the auth bug in login.ts' },
      { role: 'assistant', content: '`Read`: /src/login.ts' },
      { role: 'assistant', content: 'The bug is on line 42. The token validation skips expired tokens. Here is the fix...' },
      { role: 'user', content: '<system-reminder>Task tools available</system-reminder>' },
    ]
    const result = filterForViking(msgs)
    expect(result).toHaveLength(2)
    expect(result[0].content).toBe('Help me fix the auth bug in login.ts')
    expect(result[1].content).toContain('The bug is on line 42')
  })
})
```

- [ ] **Step 2: 运行测试确认全部 FAIL**

Run: `npx vitest run tests/core/viking-filter.test.ts`
Expected: FAIL — module `viking-filter.js` not found

- [ ] **Step 3: 实现过滤器**

```typescript
// src/core/viking-filter.ts

/** System content detection — matches patterns from claude-code adapter's isSystemInjection() */
function isSystemContent(text: string): boolean {
  return (
    text.startsWith('# AGENTS.md instructions for ') ||
    text.includes('<INSTRUCTIONS>') ||
    text.includes('<system-reminder>') ||
    text.includes('<environment_context>') ||
    text.includes('<command-name>') ||
    text.includes('<command-message>') ||
    text.startsWith('<local-command-caveat>') ||
    text.startsWith('<local-command-stdout>') ||
    text.startsWith('Unknown skill: ') ||
    text.startsWith('Invoke the superpowers:') ||
    text.startsWith('Base directory for this skill:') ||
    text.startsWith('<EXTREMELY_IMPORTANT>') ||
    text.startsWith('<EXTREMELY-IMPORTANT>')
  )
}

/** Tool-only message: entire content is just a backtick tool summary with no natural language */
function isToolOnlyMessage(text: string): boolean {
  // Matches: `ToolName`: some-args  OR  `ToolName`  (entire message)
  return /^`[A-Z][a-zA-Z]+`(: .+)?$/.test(text.trim())
}

const SENSITIVE_PATTERNS: [RegExp, string][] = [
  [/PGPASSWORD=\S+/g, 'PGPASSWORD=***'],
  [/sk-[a-zA-Z0-9]{20,}/g, 'sk-***'],
  [/Bearer [a-zA-Z0-9_-]{8,}/g, 'Bearer ***'],
]

/** Redact passwords, API keys, bearer tokens */
function redactSensitive(text: string): string {
  let result = text
  for (const [pattern, replacement] of SENSITIVE_PATTERNS) {
    result = result.replace(pattern, replacement)
  }
  return result
}

const MAX_MESSAGE_LENGTH = 4000
const HALF = 2000

/** Truncate messages over MAX_MESSAGE_LENGTH, keeping start and end */
function truncateContent(text: string): string {
  if (text.length <= MAX_MESSAGE_LENGTH) return text
  return text.slice(0, HALF) + '\n...[truncated]...\n' + text.slice(-HALF)
}

/** Filter and clean messages before pushing to Viking Sessions API */
export function filterForViking(
  messages: { role: string; content: string }[]
): { role: string; content: string }[] {
  return messages
    .filter(m => !isSystemContent(m.content) && !isToolOnlyMessage(m.content))
    .map(m => ({ role: m.role, content: redactSensitive(truncateContent(m.content)) }))
    .filter(m => m.content.trim().length > 0)
}
```

- [ ] **Step 4: 运行测试确认全部 PASS**

Run: `npx vitest run tests/core/viking-filter.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-filter.ts tests/core/viking-filter.test.ts
git commit -m "feat(viking): add content filter pipeline for Sessions API migration

Filters system injections, redacts sensitive data, truncates long messages,
and strips tool-only noise before pushing to Viking."
```

---

### Task 2: VikingBridge — 新增 pushSession() 方法

**Files:**
- Modify: `src/core/viking-bridge.ts:80-125` (add after `checkAvailable()`, before `addResource()`)
- Modify: `tests/core/viking-bridge.test.ts` (add new describe blocks)

- [ ] **Step 1: 编写 pushSession 测试**

在 `tests/core/viking-bridge.test.ts` 末尾追加：

```typescript
describe('pushSession', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('creates session, adds messages, then commits', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }),
    });
    vi.stubGlobal('fetch', mockFetch);

    await bridge.pushSession('engram-claude-code-myproject-abc123', [
      { role: 'user', content: 'Fix the bug' },
      { role: 'assistant', content: 'Found the issue...' },
    ]);

    // 1 create + 2 messages + 1 commit = 4 calls
    expect(mockFetch).toHaveBeenCalledTimes(4);
    // Call 0: POST /sessions/custom
    expect(mockFetch.mock.calls[0][0]).toBe('http://localhost:1933/api/v1/sessions/custom');
    const createBody = JSON.parse(mockFetch.mock.calls[0][1].body);
    expect(createBody.session_id).toBe('engram-claude-code-myproject-abc123');
    // Call 1: POST /sessions/{id}/messages/async (user)
    expect(mockFetch.mock.calls[1][0]).toBe('http://localhost:1933/api/v1/sessions/engram-claude-code-myproject-abc123/messages/async');
    // Call 2: POST /sessions/{id}/messages/async (assistant)
    expect(mockFetch.mock.calls[2][0]).toBe('http://localhost:1933/api/v1/sessions/engram-claude-code-myproject-abc123/messages/async');
    // Call 3: POST /sessions/{id}/commit/async
    expect(mockFetch.mock.calls[3][0]).toBe('http://localhost:1933/api/v1/sessions/engram-claude-code-myproject-abc123/commit/async');
  });

  it('throws if session creation fails', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 500, text: () => Promise.resolve('Internal error'),
    }));
    await expect(bridge.pushSession('id', [{ role: 'user', content: 'hi' }]))
      .rejects.toThrow('Viking pushSession');
  });
});

describe('deleteResources', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('sends DELETE to /fs with recursive flag', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.deleteResources();
    expect(mockFetch).toHaveBeenCalledTimes(1);
    const url = mockFetch.mock.calls[0][0] as string;
    expect(url).toContain('/api/v1/fs');
    expect(url).toContain('recursive=true');
    expect(mockFetch.mock.calls[0][1].method).toBe('DELETE');
  });
});
```

- [ ] **Step 2: 运行测试确认 FAIL**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — `pushSession` / `deleteResources` is not a function

- [ ] **Step 3: 实现 pushSession + post helper + deleteResources**

在 `src/core/viking-bridge.ts` 的 `VikingBridge` 类中，`checkAvailable()` 之后（line 79）添加：

```typescript
  /** Generic POST helper with timeout */
  private async post(url: string, body: Record<string, unknown>, timeout = 10000): Promise<unknown> {
    const res = await fetch(url, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeout),
    });
    if (!res.ok) {
      throw new Error(`Viking pushSession failed (${res.status}): ${await res.text()}`);
    }
    return res.json();
  }

  /** Push a session via Sessions API (create → add messages → commit) */
  async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
    // Step 1: Create session (idempotent — loads existing if already created)
    await this.post(`${this.api}/sessions/custom`, { session_id: sessionId });

    // Step 2: Add messages (async with built-in MD5 dedup)
    for (const msg of messages) {
      await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
        role: msg.role,
        content: msg.content,
      }, 5000);
    }

    // Step 3: Commit (async, non-blocking — returns immediately)
    await this.post(`${this.api}/sessions/${sessionId}/commit/async`, {});
  }

  /** Delete all old resources data (cleanup after migration) */
  async deleteResources(): Promise<void> {
    await fetch(
      `${this.api}/fs?uri=${encodeURIComponent('viking://resources/')}&recursive=true`,
      { method: 'DELETE', headers: this.headers, signal: AbortSignal.timeout(60000) }
    );
  }
```

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): add pushSession() using Sessions API + deleteResources()

Sessions API: create → messages/async → commit/async
No markdown decomposition, built-in dedup, ~94% VLM cost reduction."
```

---

### Task 3: 更新 Indexer — 使用 pushSession + 过滤

**Files:**
- Modify: `src/core/indexer.ts:1` (add import) and `src/core/indexer.ts:26-39` (rewrite pushToViking)
- Modify: `tests/core/indexer-viking.test.ts` (update mock + assertion)

- [ ] **Step 1: 更新测试断言**

修改 `tests/core/indexer-viking.test.ts`：

将 line 27-30 的 mock 改为：
```typescript
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      pushSession: vi.fn().mockResolvedValue(undefined),
    } as unknown as VikingBridge
```

将 line 49-53 的断言改为：
```typescript
    expect(mockViking.pushSession).toHaveBeenCalledWith(
      expect.stringContaining('engram-codex-'),
      expect.arrayContaining([
        expect.objectContaining({ role: 'user', content: 'Hello' }),
      ])
    )
```

将 line 59-62 的第二个测试 mock 改为：
```typescript
    const mockViking = {
      checkAvailable: vi.fn().mockResolvedValue(true),
      pushSession: vi.fn().mockRejectedValue(new Error('server down')),
    } as unknown as VikingBridge
```

- [ ] **Step 2: 运行测试确认 FAIL**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: FAIL — `pushSession` is not a function (indexer still calls `addResource`)

- [ ] **Step 3: 更新 indexer.ts**

在 `src/core/indexer.ts` line 1 区域添加 import：
```typescript
import { filterForViking } from './viking-filter.js'
```

将 `pushToViking` 方法（line 26-39）替换为：
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

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/indexer-viking.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 运行全量测试确认无回归**

Run: `npm test`
Expected: All 278+ tests PASS

- [ ] **Step 6: 提交**

```bash
git add src/core/indexer.ts tests/core/indexer-viking.test.ts
git commit -m "refactor(viking): indexer uses pushSession + content filter

Replaces addResource with pushSession (Sessions API).
Messages filtered through filterForViking before push."
```

---

### Task 4: 更新 Backfill 端点 + 新增 Cleanup 端点

**Files:**
- Modify: `src/web.ts:515-559` (rewrite backfill endpoint)

- [ ] **Step 1: 重写 backfill 端点**

将 `src/web.ts` 的 backfill 端点（line 515-559）替换为：

```typescript
  // --- Viking backfill: push existing sessions to OpenViking via Sessions API ---
  app.post('/api/viking/backfill', async (c) => {
    if (!opts?.viking || !opts?.adapters) {
      return c.json({ error: 'Viking not configured or no adapters' }, 501)
    }
    const viking = opts.viking
    const available = await viking.checkAvailable()
    if (!available) {
      return c.json({ error: 'Viking server unreachable' }, 503)
    }

    const limit = parseInt(c.req.query('limit') ?? '100', 10)
    const offset = parseInt(c.req.query('offset') ?? '0', 10)
    const source = c.req.query('source')
    // Only push premium-tier sessions (not all sessions)
    const sessions = db.listSessions({ source: source as any, limit, offset, agents: 'hide' })
      .filter(s => s.tier === 'premium')

    let pushed = 0
    let skipped = 0
    let errors = 0
    for (const session of sessions) {
      try {
        const adapter = opts.adapters.find(a => a.name === session.source)
        if (!adapter) continue

        const messages: { role: string; content: string }[] = []
        for await (const msg of adapter.streamMessages(session.filePath)) {
          if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim()) {
            messages.push({ role: msg.role, content: msg.content })
          }
        }
        if (messages.length === 0) continue

        const filtered = filterForViking(messages)
        if (filtered.length === 0) { skipped++; continue }

        const sessionId = `engram-${session.source}-${session.project ?? 'unknown'}-${session.id}`
        await viking.pushSession(sessionId, filtered)
        pushed++
      } catch {
        errors++
      }
    }

    return c.json({ pushed, skipped, errors, total: sessions.length, offset, limit })
  })

  // --- Viking cleanup: delete old resources data ---
  app.post('/api/viking/cleanup', async (c) => {
    if (!opts?.viking) {
      return c.json({ error: 'Viking not configured' }, 501)
    }
    try {
      await opts.viking.deleteResources()
      return c.json({ status: 'ok', message: 'Resources data deleted' })
    } catch (err) {
      return c.json({ error: err instanceof Error ? err.message : String(err) }, 500)
    }
  })
```

在文件顶部区域添加 import：
```typescript
import { filterForViking } from './core/viking-filter.js'
```

- [ ] **Step 2: 构建确认**

Run: `npm run build`
Expected: Build succeeds, no type errors

- [ ] **Step 3: 运行全量测试**

Run: `npm test`
Expected: All tests PASS

- [ ] **Step 4: 提交**

```bash
git add src/web.ts
git commit -m "refactor(viking): backfill uses Sessions API + filter; add cleanup endpoint

Backfill now only pushes premium-tier sessions through content filter.
POST /api/viking/cleanup deletes old resources data from Viking."
```

---

### Task 5: 数据迁移 — 清理旧数据并重新回填

**注意：** 此 task 是手动操作步骤，不涉及代码修改。

- [ ] **Step 1: 构建并启动 daemon**

Run: `npm run build`
Verify: `dist/` 目录已更新

- [ ] **Step 2: 清理 Viking 旧 resources 数据**

通过新的 cleanup 端点清理（需要 daemon 运行中）：
```bash
curl -X POST "http://localhost:3035/api/viking/cleanup"
```
Expected: `{ "status": "ok", "message": "Resources data deleted" }`

验证清理成功：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/"
```
Expected: `{ "result": [] }` 或空列表

- [ ] **Step 3: 确认队列已清空**

```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue" | python3 -m json.tool
```
Expected: Pending 数大幅下降（可能需要 Viking 重启才能清零）

- [ ] **Step 4: 回填前 5 个 session 测试**

```bash
curl -X POST "http://localhost:3035/api/viking/backfill?limit=5&offset=0"
```
Expected: `{ "pushed": N, "skipped": 0, "errors": 0 ... }`，且 N <= 5

验证 Sessions API 被使用：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions"
```
Expected: 列表中出现 `engram-*` 格式的 session ID

- [ ] **Step 5: 检查队列放大比（关键验证！）**

```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue"
```
Expected: Semantic 队列中新增项目数 ≈ pushed session 数（非 17× 放大）

- [ ] **Step 6: 全量回填**

循环执行直到完成：
```bash
for i in $(seq 0 100 400); do
  curl -X POST "http://localhost:3035/api/viking/backfill?limit=100&offset=$i"
  sleep 2
done
```
（316 个 premium sessions，4-5 次即可覆盖）

---

## 验证清单

| 验证项 | 命令 | 期望结果 |
|--------|------|----------|
| 单元测试通过 | `npm test` | All PASS |
| 构建成功 | `npm run build` | 无错误 |
| Viking Sessions 列表非空 | `curl .../api/v1/sessions` | 返回 engram-* session |
| Resources 已清空 | `curl .../api/v1/fs/ls?uri=viking://resources/` | 空列表 |
| Semantic 队列无放大 | `curl .../api/v1/observer/queue` | Semantic pending ≈ session 数 |
| 推送内容无噪声 | 从 Viking 读取一个 session 的消息 | 无系统提示、密码、工具噪声 |
| MCP search 正常 | 使用 search 工具搜索 | 返回结果带正确 session ID |
