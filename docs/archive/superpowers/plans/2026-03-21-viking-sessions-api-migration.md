# Viking Sessions API 迁移 + 内容清洗 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Viking 集成从 Resources API（文档分解，17× VLM 放大）切换到 Sessions API（对话原生，1-2× VLM），同时添加内容过滤管道去除噪声和敏感数据。

**Architecture:** 新增 `viking-filter.ts` 过滤管道 → 修改 `viking-bridge.ts` 添加 `pushSession()` 使用 Sessions API → 更新 `indexer.ts` 和 `web.ts` 使用新路径。读取侧（search/get_context/get_memory）完全不变，因为它们通过 URI helper 抽象。

**Tech Stack:** TypeScript (ES2022), Vitest, OpenViking Sessions API (`/api/v1/sessions/*`)

**Spec:** `docs/superpowers/specs/2026-03-21-viking-sessions-api-migration-design.md`

**关键设计决策：不做逐条截断、不做同角色合并。** 实测 316 个 premium session 中最大的（264MB/2808 条）过滤后仅 0.8MB，全部在 kimi-k2.5 的 1M context（~4MB）范围内。用 session 级 2MB 预算兜底极端 case，99%+ session 零内容丢失，保留完整消息边界利于 Viking 结构化存储。

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/core/viking-filter.ts` | **NEW** — 内容过滤管道：系统注入检测、敏感数据脱敏、session 级预算、工具噪声剥离 |
| `src/core/viking-bridge.ts` | 新增 `pushSession()` + `post()` with retry + `deleteResources()`；保留 `addResource()` |
| `src/core/indexer.ts` | `pushToViking()` 改用 `pushSession()` + `filterForViking()` |
| `src/core/db.ts` | 新增 `listPremiumSessions()` 支持 premium-only 分页查询 |
| `src/web.ts` | backfill 端点改用 Sessions API + 过滤 + premium 分页；新增 cleanup 端点 |
| `tests/core/viking-filter.test.ts` | **NEW** — 过滤规则 + session 预算单元测试 |
| `tests/core/viking-bridge.test.ts` | 新增 `pushSession()` / retry / `deleteResources()` 测试 |
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
  // --- 基础过滤 ---

  it('keeps normal user/assistant messages unchanged', () => {
    const msgs = [
      { role: 'user', content: 'Fix the login bug' },
      { role: 'assistant', content: 'The issue is in auth.ts line 42...' },
    ]
    const result = filterForViking(msgs)
    expect(result).toHaveLength(2)
    expect(result[0].content).toBe('Fix the login bug')
    expect(result[1].content).toBe('The issue is in auth.ts line 42...')
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
    expect(filterForViking([{ role: 'user', content: 'sk-henhtN3lOMGKYoTkDX2PDFY0irmW8Rha14xO3OmAIolGipzJ' }])[0].content).toBe('sk-***')
    expect(filterForViking([{ role: 'user', content: 'sk-ant-api03-abcdefghijklmnop' }])[0].content).toBe('sk-***')
    expect(filterForViking([{ role: 'user', content: 'sk-proj-abcdefghijklmnopqrstuv' }])[0].content).toBe('sk-***')
  })

  it('redacts Bearer tokens', () => {
    const msgs = [{ role: 'assistant', content: 'curl -H "Authorization: Bearer engram-viking-2026" http://...' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('Bearer ***')
    expect(result[0].content).not.toContain('engram-viking-2026')
  })

  // --- 工具噪声 ---

  it('strips tool-only messages (single line backtick format)', () => {
    const msgs = [
      { role: 'assistant', content: '`Bash`: ls -la /tmp' },
      { role: 'assistant', content: '`Read`: /path/to/file.ts' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  it('strips multiline tool-only messages', () => {
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
    expect(filterForViking(msgs)).toHaveLength(2)
  })

  it('strips empty messages', () => {
    const msgs = [
      { role: 'user', content: '   ' },
      { role: 'assistant', content: '' },
    ]
    expect(filterForViking(msgs)).toHaveLength(0)
  })

  // --- 脱敏在预算之前（安全性先于裁剪） ---

  it('redacts sensitive data before budget check', () => {
    // A 2.5MB message with a password buried inside — redaction must happen
    // before budget shrinking, otherwise the password could end up in the kept portion
    const msgs = [{ role: 'user', content: 'A'.repeat(1_000_000) + ' PGPASSWORD=SuperSecret ' + 'B'.repeat(1_500_000) }]
    const result = filterForViking(msgs)
    expect(result[0].content).not.toContain('SuperSecret')
    expect(result[0].content).toContain('PGPASSWORD=***')
  })

  // --- Session 级预算（2MB） ---

  it('does not touch messages when total content is under budget', () => {
    const msgs = [
      { role: 'user', content: 'A'.repeat(100_000) },
      { role: 'assistant', content: 'B'.repeat(100_000) },
    ]
    const result = filterForViking(msgs)
    expect(result[0].content.length).toBe(100_000)
    expect(result[1].content.length).toBe(100_000)
  })

  it('does not touch a large message if total is under budget', () => {
    // Single 1.9MB message — under 2MB budget, should not be touched
    const msgs = [{ role: 'user', content: 'X'.repeat(1_900_000) }]
    const result = filterForViking(msgs)
    expect(result[0].content.length).toBe(1_900_000)
  })

  it('shrinks longest messages first when over budget', () => {
    // 3 messages totaling 3MB — over the 2MB budget
    const msgs = [
      { role: 'user', content: 'A'.repeat(500_000) },        // 500KB — shortest
      { role: 'assistant', content: 'B'.repeat(1_500_000) },  // 1.5MB — longest, shrinks first
      { role: 'user', content: 'C'.repeat(1_000_000) },       // 1MB — second longest
    ]
    const result = filterForViking(msgs)
    const total = result.reduce((s, m) => s + m.content.length, 0)
    expect(total).toBeLessThanOrEqual(2_100_000) // budget + marker overhead tolerance
    // Shortest message untouched
    expect(result[0].content.length).toBe(500_000)
    // Longest got shrunk
    expect(result[1].content).toContain('...[truncated')
    expect(result[1].content.length).toBeLessThan(1_500_000)
  })

  it('shrinks multiple messages when one is not enough', () => {
    // 3 messages each 1MB = 3MB total, need to cut 1MB
    // After shrinking the first (longest by index order among equals), if still over, shrink next
    const msgs = [
      { role: 'user', content: 'A'.repeat(1_000_000) },
      { role: 'assistant', content: 'B'.repeat(1_000_000) },
      { role: 'user', content: 'C'.repeat(1_000_000) },
    ]
    const result = filterForViking(msgs)
    const total = result.reduce((s, m) => s + m.content.length, 0)
    expect(total).toBeLessThanOrEqual(2_100_000)
    // At least one message was shrunk
    const shrunk = result.filter(m => m.content.includes('[truncated'))
    expect(shrunk.length).toBeGreaterThanOrEqual(1)
  })

  it('never shrinks messages ≤ 2000 chars', () => {
    // 1 tiny message + 1 huge message totaling > 2MB
    const msgs = [
      { role: 'user', content: 'Short message' },           // 13 chars — must not be touched
      { role: 'assistant', content: 'X'.repeat(2_500_000) }, // 2.5MB — will be shrunk
    ]
    const result = filterForViking(msgs)
    expect(result[0].content).toBe('Short message')
    expect(result[1].content).toContain('[truncated')
  })

  it('includes char count in truncation marker', () => {
    const msgs = [{ role: 'user', content: 'X'.repeat(2_500_000) }]
    const result = filterForViking(msgs)
    expect(result[0].content).toMatch(/\[truncated [\d,]+ chars\]/)
  })

  it('preserves head and tail of truncated messages', () => {
    const head = 'HEAD_MARKER_' + 'A'.repeat(988)
    const tail = 'B'.repeat(988) + '_TAIL_MARKER'
    const middle = 'M'.repeat(2_000_000)
    const msgs = [{ role: 'user', content: head + middle + tail }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('HEAD_MARKER_')
    expect(result[0].content).toContain('_TAIL_MARKER')
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

/** Session-level budget: if total content exceeds this, shrink the longest messages.
 *  2MB ≈ 500K tokens, well within kimi-k2.5's 1M context window.
 *  Tested: largest session (264MB file) has only 0.8MB after filtering → no shrinking needed. */
const SESSION_BUDGET = 2_000_000

function applySessionBudget(
  messages: { role: string; content: string }[]
): { role: string; content: string }[] {
  let total = messages.reduce((sum, m) => sum + m.content.length, 0)
  if (total <= SESSION_BUDGET) return messages // 99%+ sessions: direct return

  // Sort indices by content length descending — shrink longest first
  const indices = messages
    .map((_, i) => i)
    .sort((a, b) => messages[b].content.length - messages[a].content.length)

  const result = messages.map(m => ({ role: m.role, content: m.content }))
  const MIN_KEEP = 2000 // always keep at least 1000 head + 1000 tail

  for (const i of indices) {
    if (total <= SESSION_BUDGET) break
    const content = result[i].content
    if (content.length <= MIN_KEEP) continue
    const excess = total - SESSION_BUDGET
    const shrinkBy = Math.min(excess, content.length - MIN_KEEP)
    const keepLen = content.length - shrinkBy
    const half = Math.floor(keepLen / 2)
    // NOTE: tail uses keepLen - half (not half) to handle odd keepLen correctly.
    // total -= shrinkBy ignores the ~35 char marker overhead — acceptable at 2MB budget scale.
    const marker = `\n...[truncated ${shrinkBy.toLocaleString()} chars]...\n`
    result[i].content = content.slice(0, half) + marker + content.slice(-(keepLen - half))
    total -= shrinkBy
  }

  return result
}

/** Filter and clean messages before pushing to Viking Sessions API.
 *  Pipeline: strip noise → redact secrets → session budget → drop empties
 *  No per-message hard truncation. No same-role merging. Preserves message boundaries. */
export function filterForViking(
  messages: { role: string; content: string }[]
): { role: string; content: string }[] {
  const cleaned = messages
    .filter(m => !isSystemContent(m.content) && !isToolOnlyMessage(m.content))
    .map(m => ({ role: m.role, content: redactSensitive(m.content) }))
    .filter(m => m.content.trim().length > 0)

  return applySessionBudget(cleaned)
}
```

- [ ] **Step 4: 运行测试确认全部 PASS**

Run: `npx vitest run tests/core/viking-filter.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-filter.ts tests/core/viking-filter.test.ts
git commit -m "feat(viking): add content filter with session-level budget

Pipeline: strip system/tool noise → redact secrets → 2MB session budget.
No per-message truncation. No same-role merging. Preserves message boundaries.
Budget only kicks in for extreme sessions (>2MB); 99%+ are zero-loss."
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
    expect(mockFetch.mock.calls[0][0]).toBe('http://localhost:1933/api/v1/sessions/custom');
    expect(JSON.parse(mockFetch.mock.calls[0][1].body).session_id).toBe('engram-claude-code-myproject-abc123');
    // Messages in order
    expect(mockFetch.mock.calls[1][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[1][1].body).role).toBe('user');
    expect(mockFetch.mock.calls[2][0]).toContain('/messages/async');
    expect(JSON.parse(mockFetch.mock.calls[2][1].body).role).toBe('assistant');
    // Commit
    expect(mockFetch.mock.calls[3][0]).toContain('/commit/async');
  });

  it('throws on session creation failure with descriptive error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 400, text: () => Promise.resolve('Bad request'),
    }));
    await expect(bridge.pushSession('id', [{ role: 'user', content: 'hi' }]))
      .rejects.toThrow(/sessions\/custom.*400/);
  });
});

describe('post retry logic', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('retries on 429 and succeeds', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: false, status: 429, text: () => Promise.resolve('rate limited') })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.pushSession('test-retry', []);
    expect(mockFetch).toHaveBeenCalledTimes(3); // retry create + succeed + commit
  });

  it('retries on 500 and succeeds', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn()
      .mockResolvedValueOnce({ ok: false, status: 500, text: () => Promise.resolve('error') })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) })
      .mockResolvedValueOnce({ ok: true, json: () => Promise.resolve({ status: 'ok', result: {} }) });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.pushSession('test-retry-500', []);
    expect(mockFetch).toHaveBeenCalledTimes(3);
  });

  it('throws after 3 retries on persistent 429', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 429, text: () => Promise.resolve('rate limited'),
    }));
    await expect(bridge.pushSession('test-exhaust', []))
      .rejects.toThrow(/after 3 retries/);
  });

  it('does NOT retry on 400 client error', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false, status: 400, text: () => Promise.resolve('bad request'),
    });
    vi.stubGlobal('fetch', mockFetch);
    await expect(bridge.pushSession('test-no-retry', []))
      .rejects.toThrow(/400/);
    expect(mockFetch).toHaveBeenCalledTimes(1);
  });
});

describe('deleteResources', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('sends DELETE to /fs with recursive flag', async () => {
    const bridge = new VikingBridge('http://localhost:1933', 'key');
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);
    await bridge.deleteResources();
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

- [ ] **Step 3: 实现 pushSession + post with retry + deleteResources**

在 `src/core/viking-bridge.ts` 的 `VikingBridge` 类中，`checkAvailable()` 之后（line 79）添加：

```typescript
  /** Generic POST helper with retry on 429/5xx. Retries up to 3 times with linear backoff. */
  private async post(url: string, body: Record<string, unknown>, timeout = 10000): Promise<unknown> {
    const MAX_RETRIES = 3;
    const path = url.replace(this.api, '');
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      const res = await fetch(url, {
        method: 'POST',
        headers: this.headers,
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(timeout),
      });
      if (res.ok) return res.json();
      if (res.status === 429 || res.status >= 500) {
        if (attempt < MAX_RETRIES - 1) {
          await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
          continue;
        }
      }
      throw new Error(`Viking ${path} failed (${res.status}): ${await res.text()}`);
    }
    throw new Error(`Viking ${path} failed after ${MAX_RETRIES} retries`);
  }

  /** Push a session via Sessions API (create → add messages serially → commit).
   *  Messages sent serially to preserve conversation order (Viking stores by arrival order).
   *  Built-in MD5 dedup: re-pushing same messages is a no-op. */
  async pushSession(sessionId: string, messages: { role: string; content: string }[]): Promise<void> {
    await this.post(`${this.api}/sessions/custom`, { session_id: sessionId });

    for (const msg of messages) {
      await this.post(`${this.api}/sessions/${sessionId}/messages/async`, {
        role: msg.role,
        content: msg.content,
      }, 5000);
    }

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

- [ ] **Step 4: 运行测试确认 PASS**

Run: `npx vitest run tests/core/viking-bridge.test.ts`
Expected: All tests PASS

- [ ] **Step 5: 提交**

```bash
git add src/core/viking-bridge.ts tests/core/viking-bridge.test.ts
git commit -m "feat(viking): add pushSession() with retry + deleteResources()

Sessions API: create → serial messages/async → commit/async.
post() retries 429/5xx up to 3× with linear backoff.
Serial sending preserves conversation order."
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
Expected: FAIL — indexer still calls `addResource`

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

- [ ] **Step 4: 运行全量测试**

Run: `npm test`
Expected: All 278+ tests PASS

- [ ] **Step 5: 提交**

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

在 `src/web.ts` 顶部区域添加 import：
```typescript
import { filterForViking } from './core/viking-filter.js'
```

将 backfill 端点（line 515-559）替换为：

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

- [ ] **Step 3: 构建 + 全量测试**

Run: `npm run build && npm test`
Expected: Build succeeds, all tests PASS

- [ ] **Step 4: 提交**

```bash
git add src/core/db.ts src/web.ts
git commit -m "refactor(viking): backfill uses Sessions API + DB-level premium pagination

listPremiumSessions() ensures correct pagination over premium sessions.
Backfill reports failures array for diagnostics.
POST /api/viking/cleanup deletes old resources data."
```

---

### Task 5: 数据迁移 — 验证、清理、回填

**回滚方案：** 先验证 Sessions API 搜索质量，确认无退化后再清理旧数据。`addResource()` 保留在代码中。

- [ ] **Step 1: 构建**

```bash
npm run build
```

- [ ] **Step 2: 回填 5 个 session 做质量验证**

```bash
curl -X POST "http://localhost:3035/api/viking/backfill?limit=5&offset=0"
```
Expected: `{ "pushed": N, "errors": 0 ... }`

验证 Sessions API 被使用：
```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions"
```
Expected: 列表中出现 `engram-*` session

- [ ] **Step 3: 检查队列放大比**

```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue" | python3 -m json.tool
```
Expected: Semantic 新增 ≈ pushed 数（非 17× 放大）

- [ ] **Step 4: 搜索质量验证（确认后再 cleanup）**

```bash
curl -s -X POST -H "Authorization: Bearer engram-viking-2026" -H "Content-Type: application/json" \
  "http://10.0.8.9:1933/api/v1/search/find" -d '{"query":"bug fix","limit":5}' | python3 -m json.tool
```
Expected: 返回带 `engram-*` URI 的搜索结果

- [ ] **Step 5: 清理旧 resources 数据（仅在 Step 4 验证通过后）**

```bash
curl -X POST "http://localhost:3035/api/viking/cleanup"
```
验证：`curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/"`
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

- [ ] **Step 7: VLM 成本对比**

```bash
curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/vlm" | python3 -m json.tool
```
Expected: 新增 token 消耗远低于旧方案的 84M tokens

---

## 验证清单

| 验证项 | 命令 | 期望结果 |
|--------|------|----------|
| 单元测试 | `npm test` | All PASS |
| 构建 | `npm run build` | 无错误 |
| Sessions 列表 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/sessions"` | engram-* sessions |
| Resources 清空 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/fs/ls?uri=viking://resources/"` | 空列表 |
| 队列无放大 | `curl -s -H "Authorization: Bearer engram-viking-2026" "http://10.0.8.9:1933/api/v1/observer/queue"` | Semantic ≈ session 数 |
| 内容无噪声 | 从 Viking 读取一个 session | 无系统提示/密码/工具噪声 |
| 搜索正常 | MCP search 工具 | 返回正确 session ID |
| VLM 成本 | observer/vlm 对比 | 远低于 84M tokens |
