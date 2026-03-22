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

  // --- 敏感数据保留（个人知识库，不脱敏）---

  it('preserves PGPASSWORD (no redaction)', () => {
    const msgs = [{ role: 'assistant', content: 'Running: PGPASSWORD=TPmCa4FjQhRG psql -h 10.10.0.12' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('PGPASSWORD=TPmCa4FjQhRG')
  })

  it('preserves API keys (no redaction)', () => {
    const msgs = [{ role: 'user', content: 'sk-henhtN3lOMGKYoTkDX2PDFY0irmW8Rha14xO3OmAIolGipzJ' }]
    expect(filterForViking(msgs)[0].content).toContain('sk-henhtN3lOMGKYoTkDX2PDFY0irmW8Rha14xO3OmAIolGipzJ')
  })

  it('preserves Bearer tokens (no redaction)', () => {
    const msgs = [{ role: 'assistant', content: 'curl -H "Authorization: Bearer engram-viking-2026" http://...' }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('Bearer engram-viking-2026')
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

  // --- 脱敏在预算之前 ---

  it('preserves sensitive data even in large messages (no redaction before budget)', () => {
    const msgs = [{ role: 'user', content: 'A'.repeat(1_000_000) + ' PGPASSWORD=SuperSecret ' + 'B'.repeat(500_000) }]
    const result = filterForViking(msgs)
    expect(result[0].content).toContain('PGPASSWORD=SuperSecret')
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
    const msgs = [{ role: 'user', content: 'X'.repeat(1_900_000) }]
    const result = filterForViking(msgs)
    expect(result[0].content.length).toBe(1_900_000)
  })

  it('shrinks longest messages first when over budget', () => {
    const msgs = [
      { role: 'user', content: 'A'.repeat(500_000) },
      { role: 'assistant', content: 'B'.repeat(1_500_000) },
      { role: 'user', content: 'C'.repeat(1_000_000) },
    ]
    const result = filterForViking(msgs)
    const total = result.reduce((s, m) => s + m.content.length, 0)
    expect(total).toBeLessThanOrEqual(2_010_000)
    expect(result[0].content.length).toBe(500_000)
    expect(result[1].content).toContain('...[truncated')
    expect(result[1].content.length).toBeLessThan(1_500_000)
  })

  it('shrinks multiple messages when one is not enough', () => {
    const msgs = [
      { role: 'user', content: 'A'.repeat(1_000_000) },
      { role: 'assistant', content: 'B'.repeat(1_000_000) },
      { role: 'user', content: 'C'.repeat(1_000_000) },
    ]
    const result = filterForViking(msgs)
    const total = result.reduce((s, m) => s + m.content.length, 0)
    expect(total).toBeLessThanOrEqual(2_010_000)
    const shrunk = result.filter(m => m.content.includes('[truncated'))
    expect(shrunk.length).toBeGreaterThanOrEqual(1)
  })

  it('never shrinks messages ≤ 2000 chars', () => {
    const msgs = [
      { role: 'user', content: 'Short message' },
      { role: 'assistant', content: 'X'.repeat(2_500_000) },
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
