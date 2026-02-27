// tests/types.test.ts
import { describe, it, expect } from 'vitest'
import type { SessionInfo, Message, SourceName } from '../src/adapters/types.js'

describe('types', () => {
  it('SessionInfo shape is correct', () => {
    const session: SessionInfo = {
      id: 'test-id',
      source: 'codex',
      startTime: '2026-01-01T00:00:00.000Z',
      cwd: '/Users/test',
      messageCount: 10,
      userMessageCount: 5,
      filePath: '/path/to/file.jsonl',
      sizeBytes: 1024,
    }
    expect(session.id).toBe('test-id')
    expect(session.source).toBe('codex')
  })

  it('Message role values are valid', () => {
    const roles: Message['role'][] = ['user', 'assistant', 'system', 'tool']
    expect(roles).toHaveLength(4)
  })

  it('SourceName values are valid', () => {
    const sources: SourceName[] = ['codex', 'claude-code', 'gemini-cli', 'opencode']
    expect(sources).toHaveLength(4)
  })
})
