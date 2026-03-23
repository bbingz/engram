import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { CodexAdapter } from '../../src/adapters/codex.js'
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js'
import { CopilotAdapter } from '../../src/adapters/copilot.js'
import { mkdtempSync, writeFileSync, mkdirSync, rmSync, unlinkSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

describe('Adapter edge cases', () => {
  let tmpDir: string

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), 'engram-adapter-edge-'))
  })

  afterEach(() => {
    rmSync(tmpDir, { recursive: true })
  })

  // 1. Empty JSONL file → 0 messages
  it('empty JSONL file yields 0 messages', async () => {
    const sessionsDir = join(tmpDir, 'sessions')
    mkdirSync(sessionsDir, { recursive: true })
    const emptyFile = join(sessionsDir, 'rollout-empty.jsonl')
    writeFileSync(emptyFile, '')

    const adapter = new CodexAdapter(sessionsDir)
    const messages = []
    for await (const msg of adapter.streamMessages(emptyFile)) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(0)
  })

  // 2. File not found → skip (no throw) — parseSessionInfo returns null
  it('file not found returns null from parseSessionInfo', async () => {
    const adapter = new CodexAdapter(tmpDir)
    const result = await adapter.parseSessionInfo(join(tmpDir, 'nonexistent.jsonl'))
    expect(result).toBeNull()
  })

  // 3. Corrupted JSON line → skip line, continue
  it('corrupted JSON lines are skipped, valid lines still parsed', async () => {
    const sessionsDir = join(tmpDir, 'sessions')
    mkdirSync(sessionsDir, { recursive: true })
    const filePath = join(sessionsDir, 'rollout-corrupt.jsonl')

    const lines = [
      '{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"sess-corrupt","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/test","originator":"codex","cli_version":"0.60.1","source":"cli","model_provider":"openai"}}',
      '{this is not valid json!!!}',
      '{"timestamp":"2026-01-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello world"}]}}',
      'totally broken line @@##',
      '{"timestamp":"2026-01-01T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi there"}]}}',
    ]
    writeFileSync(filePath, lines.join('\n'))

    const adapter = new CodexAdapter(sessionsDir)
    const messages = []
    for await (const msg of adapter.streamMessages(filePath)) {
      messages.push(msg)
    }
    // Should get 2 valid messages (user + assistant), corrupted lines skipped
    expect(messages).toHaveLength(2)
    expect(messages[0].role).toBe('user')
    expect(messages[0].content).toBe('hello world')
    expect(messages[1].role).toBe('assistant')
  })

  // 4. File with only whitespace → 0 messages
  it('file with only whitespace yields 0 messages', async () => {
    const sessionsDir = join(tmpDir, 'sessions')
    mkdirSync(sessionsDir, { recursive: true })
    const filePath = join(sessionsDir, 'rollout-whitespace.jsonl')
    writeFileSync(filePath, '   \n  \n\n   \n')

    const adapter = new CodexAdapter(sessionsDir)
    const messages = []
    for await (const msg of adapter.streamMessages(filePath)) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(0)
  })

  // 5. Very large message content → still parsed
  it('very large message content is still parsed', async () => {
    const sessionsDir = join(tmpDir, 'sessions')
    mkdirSync(sessionsDir, { recursive: true })
    const filePath = join(sessionsDir, 'rollout-large.jsonl')

    const largeContent = 'x'.repeat(100_000)
    const lines = [
      '{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"sess-large","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/test","originator":"codex","cli_version":"0.60.1","source":"cli","model_provider":"openai"}}',
      `{"timestamp":"2026-01-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"${largeContent}"}]}}`,
    ]
    writeFileSync(filePath, lines.join('\n'))

    const adapter = new CodexAdapter(sessionsDir)
    const messages = []
    for await (const msg of adapter.streamMessages(filePath)) {
      messages.push(msg)
    }
    expect(messages).toHaveLength(1)
    expect(messages[0].content).toHaveLength(100_000)
  })

  // 6. Session directory doesn't exist → detect() returns false
  it('detect() returns false when session directory does not exist', async () => {
    const adapter = new CodexAdapter(join(tmpDir, 'nonexistent-sessions-dir'))
    const result = await adapter.detect()
    expect(result).toBe(false)
  })

  // 7. listSessionFiles() on empty dir → empty generator
  it('listSessionFiles() on empty directory yields nothing', async () => {
    const sessionsDir = join(tmpDir, 'empty-sessions')
    mkdirSync(sessionsDir, { recursive: true })

    const adapter = new CodexAdapter(sessionsDir)
    const files = []
    for await (const f of adapter.listSessionFiles()) {
      files.push(f)
    }
    expect(files).toHaveLength(0)
  })

  // 9. Binary content → streamMessages should not crash
  it('binary content in file does not crash streamMessages', async () => {
    const sessionRoot = join(tmpDir, 'copilot-binary')
    const sessionDir = join(sessionRoot, 'session-bin')
    mkdirSync(sessionDir, { recursive: true })
    const filePath = join(sessionDir, 'events.jsonl')
    // Write non-UTF8 bytes (0xFF 0xFE + some garbage)
    writeFileSync(filePath, Buffer.from([0xff, 0xfe, 0x00, 0x01, 0xab, 0xcd, 0xef]))

    const adapter = new CopilotAdapter(sessionRoot)
    const messages: unknown[] = []
    // Should not throw — may yield 0 messages or skip unreadable lines
    await expect(async () => {
      for await (const msg of adapter.streamMessages(filePath)) {
        messages.push(msg)
      }
    }).not.toThrow()
    // Binary content can't be valid JSON events, so 0 messages expected
    expect(messages.length).toBe(0)
  })

  // 10. parseSessionInfo returns null for JSONL with no parseable session metadata
  it('parseSessionInfo returns null when JSONL has no session metadata', async () => {
    const sessionRoot = join(tmpDir, 'copilot-no-meta')
    const sessionDir = join(sessionRoot, 'session-no-meta')
    mkdirSync(sessionDir, { recursive: true })
    const filePath = join(sessionDir, 'events.jsonl')
    // Valid JSON lines but no user.message or assistant.message events
    writeFileSync(filePath, '{"type":"debug.log","data":{"msg":"started"}}\n{"type":"system.event","data":{}}\n')

    const adapter = new CopilotAdapter(sessionRoot)
    const result = await adapter.parseSessionInfo(filePath)
    // No user/assistant messages + no id = null
    expect(result).toBeNull()
  })

  // 11. File deleted after listing → parseSessionInfo returns null
  it('file deleted after listing returns null from parseSessionInfo', async () => {
    const sessionRoot = join(tmpDir, 'copilot-deleted')
    const sessionDir = join(sessionRoot, 'session-del')
    mkdirSync(sessionDir, { recursive: true })
    const filePath = join(sessionDir, 'events.jsonl')
    writeFileSync(filePath, '{"type":"user.message","timestamp":"2026-01-01T00:00:00Z","data":{"content":"hi"}}\n')

    const adapter = new CopilotAdapter(sessionRoot)

    // Collect the yielded path
    const listedFiles: string[] = []
    for await (const f of adapter.listSessionFiles()) {
      listedFiles.push(f)
    }
    expect(listedFiles).toHaveLength(1)
    expect(listedFiles[0]).toBe(filePath)

    // Delete file before parsing
    unlinkSync(filePath)

    const result = await adapter.parseSessionInfo(filePath)
    expect(result).toBeNull()
  })

  // 12. Truncated JSON line → corrupted line skipped, other lines parsed
  it('truncated JSON line is skipped and other lines still parsed', async () => {
    const sessionRoot = join(tmpDir, 'copilot-truncated')
    const sessionDir = join(sessionRoot, 'session-trunc')
    mkdirSync(sessionDir, { recursive: true })
    const filePath = join(sessionDir, 'events.jsonl')
    // workspace.yaml so we have an id
    writeFileSync(join(sessionDir, 'workspace.yaml'), 'id: sess-trunc\ncwd: /tmp\ncreated_at: 2026-01-01T00:00:00Z\n')
    const lines = [
      '{"type":"user.message","timestamp":"2026-01-01T00:00:00Z","data":{"content":"good line"}}',
      '{"role":"user","c',  // truncated mid-JSON
      '{"type":"assistant.message","timestamp":"2026-01-01T00:01:00Z","data":{"content":"response"}}',
    ]
    writeFileSync(filePath, lines.join('\n'))

    const adapter = new CopilotAdapter(sessionRoot)
    const messages: unknown[] = []
    for await (const msg of adapter.streamMessages(filePath)) {
      messages.push(msg)
    }
    // Truncated line skipped; 2 valid messages parsed
    expect(messages).toHaveLength(2)
  })

  // 8. Mixed valid/invalid session files → valid ones processed
  it('mixed valid and invalid session files: valid ones still process', async () => {
    const sessionsDir = join(tmpDir, 'mixed-sessions')
    mkdirSync(sessionsDir, { recursive: true })

    // Valid session file
    const validFile = join(sessionsDir, 'rollout-valid.jsonl')
    const validLines = [
      '{"timestamp":"2026-01-01T10:00:00.000Z","type":"session_meta","payload":{"id":"sess-valid","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/test","originator":"codex","cli_version":"0.60.1","source":"cli","model_provider":"openai"}}',
      '{"timestamp":"2026-01-01T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"test message"}]}}',
    ]
    writeFileSync(validFile, validLines.join('\n'))

    // Invalid session file (no session_meta)
    const invalidFile = join(sessionsDir, 'rollout-invalid.jsonl')
    writeFileSync(invalidFile, '{"type":"unknown","payload":{}}')

    const adapter = new CodexAdapter(sessionsDir)

    // Valid file should parse
    const validInfo = await adapter.parseSessionInfo(validFile)
    expect(validInfo).not.toBeNull()
    expect(validInfo!.id).toBe('sess-valid')

    // Invalid file should return null (no session_meta → null)
    const invalidInfo = await adapter.parseSessionInfo(invalidFile)
    expect(invalidInfo).toBeNull()
  })
})
