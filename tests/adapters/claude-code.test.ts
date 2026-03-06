// tests/adapters/claude-code.test.ts
import { describe, it, expect } from 'vitest'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURE = join(__dirname, '../fixtures/claude-code/sample.jsonl')
const TOOL_FIXTURE = join(__dirname, '../fixtures/claude-code/with-tools.jsonl')

describe('ClaudeCodeAdapter', () => {
  const adapter = new ClaudeCodeAdapter()

  it('name is claude-code', () => {
    expect(adapter.name).toBe('claude-code')
  })

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.id).toBe('cc-session-001')
    expect(info!.source).toBe('claude-code')
    expect(info!.cwd).toBe('/Users/test/my-project')
    expect(info!.userMessageCount).toBe(2)
    expect(info!.summary).toBe('请帮我添加用户注册功能')
  })

  it('streamMessages filters only user and assistant', async () => {
    const messages = []
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg)
    }
    expect(messages.every(m => m.role === 'user' || m.role === 'assistant')).toBe(true)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('请帮我添加用户注册功能')
  })

  it('counts tool_result messages separately from user messages', async () => {
    const info = await adapter.parseSessionInfo(TOOL_FIXTURE)
    expect(info).not.toBeNull()
    expect(info!.userMessageCount).toBe(2)       // "帮我查看" + "好的，谢谢"
    expect(info!.toolMessageCount).toBe(1)        // tool_result
    expect(info!.assistantMessageCount).toBe(2)   // tool_use response + text response
    expect(info!.messageCount).toBe(5)            // 2 user + 2 asst + 1 tool
  })

  it('decodeCwd converts encoded path to real path', () => {
    // 规则：-- 是 -，单 - 是 /
    // 注：编码方式是 / → -，字面量 - 保持不变，因此 -- 可能是 /- 或 -/，解码有歧义
    // 算法：先替换 -- 为占位符，再替换单 - 为 /，再恢复占位符为 -
    expect(ClaudeCodeAdapter.decodeCwd('-Users-bing--Code--project'))
      .toBe('/Users/bing-Code-project')
  })
})
