import { describe, it, expect } from 'vitest'
import { isPreambleContent, isPreambleOnly } from '../../src/core/preamble-detector.js'

describe('preamble-detector', () => {
  it('detects CLAUDE.md content', () => {
    expect(isPreambleContent('Contents of CLAUDE.md\n# Project\nBuild with npm run build')).toBe(true)
  })
  it('detects system-reminder blocks', () => {
    expect(isPreambleContent('<system-reminder>\nYou have access to tools\n</system-reminder>')).toBe(true)
  })
  it('detects environment_context', () => {
    expect(isPreambleContent('<environment_context>\nOS: macOS\n</environment_context>')).toBe(true)
  })
  it('detects agents.md instructions', () => {
    expect(isPreambleContent('# agents.md instructions for Claude\nFollow these rules...')).toBe(true)
  })
  it('does NOT flag normal user messages', () => {
    expect(isPreambleContent('请帮我重构这个组件')).toBe(false)
  })
  it('does NOT flag short questions', () => {
    expect(isPreambleContent('What does this function do?')).toBe(false)
  })
  it('isPreambleOnly returns true when all messages are preamble', () => {
    expect(isPreambleOnly([
      'Contents of CLAUDE.md\n# Project',
      '<system-reminder>tools</system-reminder>'
    ])).toBe(true)
  })
  it('isPreambleOnly returns false when any message is real', () => {
    expect(isPreambleOnly([
      'Contents of CLAUDE.md',
      '请帮我重构这个组件'
    ])).toBe(false)
  })
})
