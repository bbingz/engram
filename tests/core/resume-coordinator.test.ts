import { describe, it, expect } from 'vitest'
import { buildResumeCommand } from '../../src/core/resume-coordinator.js'

describe('resume-coordinator', () => {
  it('builds claude resume command', () => {
    const result = buildResumeCommand('claude-code', 'session-abc', '/path/project')
    // Either a ResumeCommand (if claude is installed) or ResumeError
    if ('command' in result) {
      expect(result.args).toContain('--resume')
      expect(result.args).toContain('session-abc')
      expect(result.cwd).toBe('/path/project')
    } else {
      expect(result.error).toContain('not found')
    }
  })

  it('returns open-directory fallback for cursor', () => {
    const result = buildResumeCommand('cursor', 'id', '/path')
    expect('command' in result).toBe(true)
    if ('command' in result) {
      expect(result.command).toBe('open')
      expect(result.args).toContain('Cursor')
    }
  })

  it('returns open fallback for unknown source', () => {
    const result = buildResumeCommand('unknown-tool', 'id', '/some/path')
    expect('command' in result).toBe(true)
    if ('command' in result) {
      expect(result.command).toBe('open')
      expect(result.args).toContain('/some/path')
    }
  })

  it('builds codex resume command', () => {
    const result = buildResumeCommand('codex', 'session-xyz', '/some/dir')
    if ('command' in result) {
      expect(result.tool).toBe('codex')
      expect(result.args).toContain('--resume')
      expect(result.args).toContain('session-xyz')
      expect(result.cwd).toBe('/some/dir')
    } else {
      expect(result.error).toContain('not found')
    }
  })

  it('builds gemini resume command', () => {
    const result = buildResumeCommand('gemini-cli', 'session-123', '/home/user/proj')
    if ('command' in result) {
      expect(result.tool).toBe('gemini')
      expect(result.args).toContain('--resume')
      expect(result.args).toContain('session-123')
    } else {
      expect(result.error).toContain('not found')
    }
  })
})
