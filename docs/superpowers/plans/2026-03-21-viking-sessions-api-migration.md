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
| `src/core/db.ts` | 新增 `listPremiumSessions()` 支持 premium-only 分页查询 |
| `src/web.ts` | backfill 端点改用 Sessions API + 过滤 + premium 分页；新增 cleanup 端点 |
| `tests/core/viking-filter.test.ts` | **NEW** — 过滤规则单元测试 |
| `tests/core/viking-bridge.test.ts` | 新增 `pushSession()` / `deleteResources()` 测试 |
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

  // --- 敏感数据脱敏 ---

  it('redacts PGPASSWORD', () => {
    const msgs = [{ role: 'assistant', content: 'Running: PGPASSWORD=TPmCa4FjQhRG psql -h 10.10.0.12' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('PGPASSWORD=***')
    expect(result[0].content).not.toContain('TPmCa4FjQhRG')
  })

  it('redacts MYSQL_PWD', () => {
    const msgs = [{ role: 'assistant', content: 'MYSQL_PWD=secret123 mysql -u root' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('MYSQL_PWD=***')
    expect(result[0].content).not.toContain('secret123')
  })

  it('redacts sk- API keys including dash/underscore formats', () => {
    // Standard format
    expect(filterForViking([{ role: 'user', content: 'sk-henhtN3lOMGKYoTkDX2PDFY0irmW8Rha14xO3OmAIolGipzJ' }])[0].content).toBe('sk-***')
    // Anthropic format: sk-ant-api03-xxxx
    expect(filterForViking([{ role: 'user', content: 'sk-ant-api03-abcdefghijklmnop' }])[0].content).toBe('sk-***')
    // Project format: sk-proj-xxxx
    expect(filterForViking([{ role: 'user', content: 'sk-proj-abcdefghijklmnopqrstuv' }])[0].content).toBe('sk-***')
  })

  it('redacts Bearer tokens', () => {
    const msgs = [{ role: 'assistant', content: 'curl -H "Authorization: Bearer engram-viking-2026" http://...' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('Bearer ***')
    expect(result[0].content).not.toContain('engram-viking-2026')
  })

  // --- 脱敏优先于截断（安全性先于裁剪）---

  it('redacts sensitive data BEFORE truncation', () => {
    // Password at position 1990-2020 — straddles the truncation boundary
    const prefix = 'A'.repeat(1985)
    const secret = ' PGPASSWORD=SuperSecret123 '
    const suffix = 'B'.repeat(3000)
    const msgs = [{ role: 'user', content: prefix + secret + suffix }]
    const result = filterForViking(msgs)
    expect(result[0].content).not.toContain('SuperSecret123')
    expect(result[0].content).toContain('PGPASSWORD=***')
  })

  // --- 截断 ---

  it('truncates messages over 4000 chars', () => {
    const long = 'A'.repeat(5000)
    const msgs = [{ role: 'user', content: long }]
    const result = filterForViking(msgs)
    expect(result[0].content.length).toBeLessThan(4200)
    expect(result[0].content).toContain('...[truncated]...')
  })

  it('does not truncate messages under 4000 chars', () => {
    const msgs = [{ role: 'user', content: 'A'.repeat(3999) }]
    expect(filterForViking(msgs)[0].content.length).toBe(3999)
  })

  // --- 工具噪声 ---

  it('strips tool-only messages (single line backtick format)', () => {
    const msgs = [
      { role: 'assistant', content: '`Bash`: ls -la /tmp' },
      { role: 'assistant', content: '`Read`: /path/to/file.ts' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips multiline tool-only messages (tool + output, no analysis)', () => {
    const msgs = [
      { role: 'assistant', content: '`Bash`: ls -la /tmp\n`Read`: /path/to/file.ts\n`Grep`: pattern' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('keeps messages that mix tools with natural language', () => {
    const msgs = [
      { role: 'assistant', content: 'The issue is in the Bash command `ls`. Let me fix it.' },
      { role: 'assistant', content: '`Read`: /src/auth.ts\n\nAfter reading, I found the bug on line 42.' },
    ]
    const result = filterForViking(msgs)
    expect(result).toHaveLength(2)
  })

  // --- 空消息 ---

  it('strips empty messages after filtering', () => {
    const msgs = [
      { role: 'user', content: '   ' },
      { role: 'assistant', content: '' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  // --- 综合测试 ---

  it('handles mixed content — keeps valuable, strips noise', () => {
    const msgs = [
      { role: 'user', content: '# AGENTS.md instructions for /foo\n<INSTRUCTIONS>Be helpful</INSTRUCTIONS>' },
      { role: 'user', content: 'Help me fix the auth bug in login.ts' },
      { role: 'assistant', content: '`Read`: /src/login.ts' },
      { role: 'assistant', content: 'The bug is on line 42. The token validation skips expired tokens.' },
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

/** System content detection — patterns from claude-code adapter's isSystemInjection() */
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

/** Tool-only message: ALL lines are backtick tool summaries, no natural language */
const TOOL_LINE_RE = /^`[A-Z][a-zA-Z]+`(: .+)?$/
function isToolOnlyMessage(text: string): boolean {
  const lines = text.trim().split('\n').filter(l => l.trim())
  if (lines.length === 0) return false
  return lines.every(line => TOOL_LINE_RE.test(line.trim()))
}

const SENSITIVE_PATTERNS: [RegExp, string][] = [
  [/PGPASSWORD=\S+/g, 'PGPASSWORD=***'],
  [/MYSQL_PWD=\S+/g, 'MYSQL_PWD=***'],
  [/sk-[a-zA-Z0-9_-]{16,}/g, 'sk-***'],
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

/** Filter and clean messages before pushing to Viking Sessions API.
 *  Order: strip system → strip tool-only → redact sensitive → truncate → strip empty */
export function filterForViking(
  messages: { role: string; content: string }[]
): { role: string; content: string }[] {
  return messages
    .filter(m => !isSystemContent(m.content) && !isToolOnlyMessage(m.content))
    .map(m => ({ role: m.role, content: truncateContent(redactSensitive(m.content)) }))
    .filter(m => m.content.trim().length > 0)
}
```

**注意：** 管道顺序为 `redactSensitive` → `truncateContent`（先脱敏再截断），确保跨截断边界的敏感数据不会泄漏。

- [ ] **Step 4: 运行测试确认全部 PASS**

Run: `npx vitest run tests/core/viking-filter.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-filter.ts tests/core/viking-filter.test.ts
git commit -m "feat(viking): add content filter pipeline for Sessions API migration

Filters system injections, redacts sensitive data (PGPASSWORD, sk-*, Bearer),
truncates long messages, strips tool-only noise. Redaction before truncation."
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

  it('creates session, adds messages serially, then commits', async () => {
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
    // Call 1-2: POST /sessions/{id}/messages/async (preserving order)
    expect(mockFetch.mock.calls[1][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).role).toBe('user');
    expect(mockFetch.mock.calls[2][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[2][1].body).role).toBe('assistant');
    // Call 3: POST /sessions/{id}/commit/async
    expect(mockFetch.mock.calls[3][0]).toContain('/commit/async');
  });

  it('throws on session creation failure with descriptive error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 500, text: () => Promise.resolve('Internal error'),
    }));
    await expect(bridge.pushSession('id', [{ role: 'user', content: 'hi' }]))
      .rejects.toThrow(/sessions\/custom.*500/);
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

  it('throws on delete failure', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 500, text: () => Promise.resolve('delete failed'),
    }));
    await expect(bridge.deleteResources()).rejects.toThrow(/deleteResources.*500/);
  });
});
```

- [ ] **Step 2: 运行测试确认 FAIL**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: FAIL — `pushSession` / `deleteResources` is not a function

- [ ] **Step 3: 实现 pushSession + post helper + deleteResources**

在 `src/core/viking-bridge.ts` 的 `VikingBridge` 类中，`checkAvailable()` 之后（line 79）添加：

```typescript
  /** Generic POST helper — error message includes the URL path for debuggability */
  private async post(url: string, body: Record<string, unknown>, timeout = 10000): Promise<unknown> {
    const res = await fetch(url, {
      method: 'POST',
      headers: this.headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeout),
    });
    if (!res.ok) {
      const path = url.replace(this.api, '');
      throw new Error(`Viking ${path} failed (${res.status}): ${await res.text()}`);
    }
    return res.json();
  }

  /** Push a session via Sessions API (create → add messages serially → commit).
   *  Messages sent serially to preserve conversation order (Viking stores by arrival order). */
  async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
    // Step 1: Create session (idempotent — loads existing if already created)
    await this.post(`${this.api}/sessions/custom`, { session_id: sessionId });

    // Step 2: Add messages serially to preserve order (Viking /messages/async has built-in MD5 dedup)
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
    const res = await fetch(
      `${this.api}/fs?uri=${encodeURIComponent('viking://resources/')}&recursive=true`,
      { method: 'DELETE', headers: this.headers, signal: AbortSignal.timeout(60000) }
    );
    if (!res.ok) {
      throw new Error(`Viking deleteResources failed (${res.status}): ${await res.text()}`);
    }
  }
```

**关键设计：**
- `post()` 错误消息包含 URL path（非硬编码方法名），方便调试
- messages 串行发送保持对话顺序（Viking 按到达顺序存储，并发会乱序）
- `deleteResources()` 检查 `res.ok`，失败时抛出错误

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): add pushSession() with batched messages + deleteResources()

Sessions API: create → messages/async (batches of 10) → commit/async.
post() includes URL path in errors. deleteResources() validates response."
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

在 `src/core/indexer.ts` 顶部 import 区域添加：
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
- Modify: `src/core/db.ts` (add `listPremiumSessions()`)
- Modify: `src/web.ts:515-559` (rewrite backfill + add cleanup)

- [ ] **Step 1: 在 db.ts 添加 premium 分页查询**

在 `src/core/db.ts` 的 `listSessions()` 方法之后添加：

```typescript
  /** List premium-tier sessions with proper DB-level pagination (for Viking backfill) */
  listPremiumSessions(opts: { limit?: number; offset?: number; source?: string } = {}): SessionInfo[] {
    const conditions: string[] = ["hidden_at IS NULL", "tier = 'premium'"]
    const params: Record<string, unknown> = {}
    if (opts.source) { conditions.push('source = @source'); params.source = opts.source }
    const limit = opts.limit ?? 100
    const offset = opts.offset ?? 0
    const rows = this.db.prepare(`
      SELECT s.*, ls.local_readable_path
      FROM sessions s
      LEFT JOIN session_local_state ls ON ls.session_id = s.id
      WHERE ${conditions.join(' AND ')}
      ORDER BY start_time DESC
      LIMIT @limit OFFSET @offset
    `).all({ ...params, limit, offset }) as Record<string, unknown>[]
    return rows.map(r => this.rowToSession(r))
  }
```

- [ ] **Step 2: 重写 backfill 端点 + 新增 cleanup**

将 `src/web.ts` 的 backfill 端点（line 515-559）替换为：

```typescript
  // --- Viking backfill: push premium sessions to OpenViking via Sessions API ---
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
    // DB-level premium filter — offset/limit apply correctly to premium sessions only
    const sessions = db.listPremiumSessions({ source: source || undefined, limit, offset })

    let pushed = 0
    let skipped = 0
    const failures: { id: string; error: string }[] = []
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
      } catch (err) {
        failures.push({ id: session.id, error: err instanceof Error ? err.message : String(err) })
      }
    }

    return c.json({ pushed, skipped, errors: failures.length, failures: failures.slice(0, 10), total: sessions.length, offset, limit })
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

在 `src/web.ts` 顶部区域添加 import：
```typescript
import { filterForViking } from './core/viking-filter.js'
```

- [ ] **Step 3: 构建确认**

Run: `npm run build`
Expected: Build succeeds, no type errors

- [ ] **Step 4: 运行全量测试**

Run: `npm test`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/db.ts src/web.ts
git commit -m "refactor(viking): backfill uses Sessions API + DB-level premium pagination

listPremiumSessions() ensures offset/limit correctly page over premium sessions.
POST /api/viking/cleanup deletes old resources data."
```

---

### Task 5: 数据迁移 — 验证、清理、回填

**注意：** 此 task 是手动操作步骤，不涉及代码修改。

**回滚方案：** 先验证 Sessions API 的搜索质量，确认无退化后再清理旧数据。`addResource()` 保留在代码中作为回退路径。

- [ ] **Step 1: 构建并启动 daemon**

```bash
npm run build
```
Verify: `dist/` 目录已更新

- [ ] **Step 2: 回填 5 个 session 做质量验证**

```bash
curl -X POST "http://localhost:3035/api/viking/backfill?limit=5&offset=0"
```
Expected: `{ "pushed": N, ... }` 且 N > 0

验证 Sessions API 被使用：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions"
```
Expected: 列表中出现 `engram-*` 格式的 session ID

- [ ] **Step 3: 检查队列放大比（关键验证！）**

```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue" -o /tmp/q.json && cat /tmp/q.json | python3 -m json.tool
```
Expected: Semantic 新增项目 ≈ pushed session 数（而非 17× 放大）

- [ ] **Step 4: 搜索质量验证（确认后再 cleanup）**

等待 Viking 处理完 5 个 session 的 semantic pipeline，然后测试搜索：
```bash
curl -s -X POST -H "Authorization: Bearer engram-viking-2026" -H "Content-Type: application/json" \
  "http://10.0.8.9:1933/api/v1/search/find" -d '{"query":"bug fix","limit":5}' | python3 -m json.tool
```
Expected: 返回带 `engram-*` URI 的搜索结果（新 session 的结果可用）

- [ ] **Step 5: 清理旧 resources 数据**

**只在 Step 4 验证通过后执行：**
```bash
curl -X POST "http://localhost:3035/api/viking/cleanup"
```
Expected: `{ "status": "ok", "message": "Resources data deleted" }`

验证清理：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/"
```
Expected: `{ "result": [] }`

- [ ] **Step 6: 全量回填**

```bash
for i in $(seq 0 100 400); do
  echo "Backfill offset=$i"
  curl -s -X POST "http://localhost:3035/api/viking/backfill?limit=100&offset=$i"
  echo
  sleep 2
done
```
（DB 中 316 个 premium session，`listPremiumSessions` 直接分页，4 次即可覆盖）

- [ ] **Step 7: VLM 成本对比验证**

记录 backfill 前后的 VLM token 消耗：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/vlm" -o /tmp/vlm.json && cat /tmp/vlm.json | python3 -m json.tool
```
Expected: 新增 token 消耗 ≈ 316 sessions × ~3K tokens ≈ ~1M tokens（而非旧方案的 ~84M tokens）

---

## 验证清单

| 验证项 | 命令 | 期望结果 |
|--------|------|----------|
| 单元测试通过 | `npm test` | All PASS |
| 构建成功 | `npm run build` | 无错误 |
| Viking Sessions 列表非空 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions"` | 返回 engram-* session |
| Resources 已清空 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/"` | 空列表 |
| Semantic 队列无放大 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue"` | Semantic total ≈ session 数 |
| 推送内容无噪声 | 从 Viking 读取一个 session 的消息 | 无系统提示、密码、工具噪声 |
| MCP search 正常 | 使用 search 工具搜索 | 返回结果带正确 session ID |
| VLM 成本合理 | 对比 observer/vlm 前后数据 | 新增 ~1M tokens（非 84M） |
