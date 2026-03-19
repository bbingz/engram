import { describe, it, expect } from 'vitest'
import { buildTitlePrompt, parseTitleResponse } from '../../src/core/title-generator.js'

describe('title-generator', () => {
  it('builds prompt from conversation turns', () => {
    const prompt = buildTitlePrompt([
      { role: 'user', content: '请帮我重构这个 Button 组件' },
      { role: 'assistant', content: '好的，我来看一下代码结构...' },
    ])
    expect(prompt).toContain('Generate a concise title')
    expect(prompt).toContain('≤30 characters')
    expect(prompt).toContain('重构')
  })

  it('truncates long messages to 200 chars', () => {
    const longMsg = 'a'.repeat(500)
    const prompt = buildTitlePrompt([{ role: 'user', content: longMsg }])
    expect(prompt.length).toBeLessThan(600)
  })

  it('parses clean title', () => {
    expect(parseTitleResponse('重构 Button 组件')).toBe('重构 Button 组件')
  })

  it('removes quotes', () => {
    expect(parseTitleResponse('"Fix login bug"')).toBe('Fix login bug')
  })

  it('removes Title: prefix', () => {
    expect(parseTitleResponse('Title: Add caching\n')).toBe('Add caching')
  })

  it('removes 标题: prefix', () => {
    expect(parseTitleResponse('标题：修复登录问题')).toBe('修复登录问题')
  })

  it('truncates to 30 chars', () => {
    const long = 'A very long title that exceeds thirty characters by quite a lot'
    expect(parseTitleResponse(long).length).toBeLessThanOrEqual(30)
  })
})
