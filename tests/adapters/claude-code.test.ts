// tests/adapters/claude-code.test.ts

import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js';
import type { Message } from '../../src/adapters/types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/claude-code/sample.jsonl');
const TOOL_FIXTURE = join(
  __dirname,
  '../fixtures/claude-code/with-tools.jsonl',
);
const NEW_TYPES_FIXTURE = join(
  __dirname,
  '../fixtures/claude-code/new-types.jsonl',
);
const FMT_FIXTURE = join(
  __dirname,
  '../fixtures/claude-code/tool-formatting.jsonl',
);
const USAGE_FIXTURE = join(
  __dirname,
  '../fixtures/claude-code/session-with-usage.jsonl',
);

describe('ClaudeCodeAdapter', () => {
  const adapter = new ClaudeCodeAdapter();

  it('name is claude-code', () => {
    expect(adapter.name).toBe('claude-code');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('cc-session-001');
    expect(info?.source).toBe('claude-code');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toBe('请帮我添加用户注册功能');
  });

  it('keeps Claude project sessions as claude-code when the model is routed through another CLI provider', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-routed-model-${Date.now()}`);
    const filePath = join(tmpRoot, 'routed-model.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          type: 'user',
          cwd: '/proj',
          sessionId: 'routed-model-session',
          timestamp: '2026-04-29T10:00:00.000Z',
          message: { role: 'user', content: 'hello' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId: 'routed-model-session',
          timestamp: '2026-04-29T10:00:01.000Z',
          message: {
            role: 'assistant',
            model: 'kimi-k2',
            content: [{ type: 'text', text: 'hi' }],
          },
        }),
      ].join('\n'),
    );

    try {
      const info = await adapter.parseSessionInfo(filePath);
      expect(info?.source).toBe('claude-code');
      expect(info?.model).toBe('kimi-k2');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('streamMessages filters only user/assistant/tool', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(
      messages.every(
        (m) => m.role === 'user' || m.role === 'assistant' || m.role === 'tool',
      ),
    ).toBe(true);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('请帮我添加用户注册功能');
  });

  it('streamMessages yields role="tool" for tool_result records', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(TOOL_FIXTURE)) {
      messages.push(msg);
    }
    // with-tools fixture line 3 is type=user wrapping tool_result content;
    // it must surface as role='tool' so stream agrees with toolMessageCount.
    const toolMsgs = messages.filter((m) => m.role === 'tool');
    expect(toolMsgs).toHaveLength(1);
    // Content for non-"User has answered" tool_results is filtered to '',
    // matching formatToolResult behavior. The role itself is what we care about.
    expect(messages[2].role).toBe('tool');
  });

  it('ignores non-message record types (attachment, permission-mode, etc.)', async () => {
    const info = await adapter.parseSessionInfo(NEW_TYPES_FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('new-types-001');
    expect(info?.userMessageCount).toBe(1);
    expect(info?.assistantMessageCount).toBe(1);
    expect(info?.messageCount).toBe(2);

    const messages = [];
    for await (const msg of adapter.streamMessages(NEW_TYPES_FIXTURE)) {
      messages.push(msg);
    }
    expect(messages.map((m) => m.role)).toEqual(['user', 'assistant']);
  });

  it('returns null for files with sessionId but no user/assistant records', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-metaonly-${Date.now()}`);
    const filePath = join(tmpRoot, 'meta-only.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        '{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"meta-only-1"}',
        '{"type":"attachment","sessionId":"meta-only-1","attachment":{"type":"hook_success","hookName":"SessionStart"}}',
      ].join('\n'),
    );
    try {
      const info = await adapter.parseSessionInfo(filePath);
      expect(info).toBeNull();
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('falls back to file mtime when message records carry no timestamps', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-no-ts-${Date.now()}`);
    const filePath = join(tmpRoot, 'no-ts.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        '{"type":"user","cwd":"/proj","sessionId":"no-ts-1","message":{"role":"user","content":"hello"}}',
        '{"type":"assistant","sessionId":"no-ts-1","message":{"id":"r","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}]}}',
      ].join('\n'),
    );
    try {
      const info = await adapter.parseSessionInfo(filePath);
      expect(info).not.toBeNull();
      expect(info?.id).toBe('no-ts-1');
      // startTime must be a real ISO string (not '') so downstream Date math works
      expect(info?.startTime).toMatch(/^\d{4}-\d{2}-\d{2}T/);
      expect(info?.userMessageCount).toBe(1);
      expect(info?.assistantMessageCount).toBe(1);
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('counts tool_result messages separately from user messages', async () => {
    const info = await adapter.parseSessionInfo(TOOL_FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.userMessageCount).toBe(2); // "帮我查看" + "好的，谢谢"
    expect(info?.toolMessageCount).toBe(1); // tool_result
    expect(info?.assistantMessageCount).toBe(2); // tool_use response + text response
    expect(info?.messageCount).toBe(5); // 2 user + 2 asst + 1 tool
  });

  describe('tool formatting in streamMessages', () => {
    it('formats Read and Bash tools with summaries, filters noise tools', async () => {
      const messages = [];
      for await (const msg of adapter.streamMessages(FMT_FIXTURE)) {
        messages.push(msg);
      }
      // msg-001: user text, msg-002: assistant with tools, msg-003: tool results, msg-004: assistant text
      expect(messages.length).toBe(4);

      // Assistant message with tool_use (msg-002) should format tools
      const assistantWithTools = messages[1];
      expect(assistantWithTools.role).toBe('assistant');
      // Should contain text + Read summary + Bash summary, but NOT TodoWrite (noise)
      expect(assistantWithTools.content).toContain('好的，让我查看一下。');
      expect(assistantWithTools.content).toContain(
        '`Read`: /Users/test/proj/src/main.ts',
      );
      expect(assistantWithTools.content).toContain(
        '`Bash`: ls -la /Users/test/proj/src',
      );
      expect(assistantWithTools.content).not.toContain('TodoWrite');
    });

    it('filters tool_reference items from tool results', async () => {
      const messages = [];
      for await (const msg of adapter.streamMessages(FMT_FIXTURE)) {
        messages.push(msg);
      }
      // msg-003 is tool_result — should produce empty content (no "User has answered" prefix)
      const toolResultMsg = messages[2];
      expect(toolResultMsg.role).toBe('tool');
      // tool_result content without "User has answered" is filtered out
      expect(toolResultMsg.content).toBe('');
    });
  });

  it('decodeCwd converts encoded path to real path', () => {
    // 规则：-- 是 -，单 - 是 /
    // 注：编码方式是 / → -，字面量 - 保持不变，因此 -- 可能是 /- 或 -/，解码有歧义
    // 算法：先替换 -- 为占位符，再替换单 - 为 /，再恢复占位符为 -
    expect(ClaudeCodeAdapter.decodeCwd('-Users-example--Code--project')).toBe(
      '/Users/example-Code-project',
    );
  });

  describe('streamMessages with usage data', () => {
    it('extracts token usage from assistant messages', async () => {
      const messages: Message[] = [];
      for await (const msg of adapter.streamMessages(USAGE_FIXTURE)) {
        messages.push(msg);
      }
      const assistantMsgs = messages.filter((m) => m.role === 'assistant');
      expect(assistantMsgs.length).toBeGreaterThanOrEqual(2);

      // First assistant message should have usage
      const first = assistantMsgs[0];
      expect(first.usage).toBeDefined();
      expect(first.usage?.inputTokens).toBe(1500);
      expect(first.usage?.outputTokens).toBe(50);
      expect(first.usage?.cacheCreationTokens).toBe(1000);
      expect(first.usage?.cacheReadTokens).toBe(500);

      // Second assistant message
      const second = assistantMsgs[1];
      expect(second.usage).toBeDefined();
      expect(second.usage?.inputTokens).toBe(2000);
      expect(second.usage?.outputTokens).toBe(100);
    });

    it('extracts toolCalls from assistant messages', async () => {
      const messages: Message[] = [];
      for await (const msg of adapter.streamMessages(USAGE_FIXTURE)) {
        messages.push(msg);
      }
      const assistantMsgs = messages.filter((m) => m.role === 'assistant');

      const first = assistantMsgs[0];
      expect(first.toolCalls).toBeDefined();
      expect(first.toolCalls?.length).toBe(1);
      expect(first.toolCalls?.[0].name).toBe('Read');

      const second = assistantMsgs[1];
      expect(second.toolCalls).toBeDefined();
      expect(second.toolCalls?.[0].name).toBe('Edit');
    });
  });

  describe('parentSessionId extraction from subagent paths', () => {
    const tmpRoot = join(tmpdir(), `engram-test-subagent-${Date.now()}`);
    const parentId = 'parent-session-uuid-123';
    const agentId = 'subagent-uuid-456';
    const subagentDir = join(tmpRoot, 'project-dir', parentId, 'subagents');
    const subagentFile = join(subagentDir, `${agentId}.jsonl`);

    beforeAll(() => {
      mkdirSync(subagentDir, { recursive: true });
      const lines = [
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/project',
          sessionId: parentId,
          agentId,
          message: { role: 'user', content: 'Do the task' },
          uuid: 'msg-001',
          timestamp: '2026-04-13T10:00:00.000Z',
        }),
        JSON.stringify({
          type: 'assistant',
          cwd: '/Users/test/project',
          sessionId: parentId,
          agentId,
          message: {
            id: 'resp-001',
            type: 'message',
            role: 'assistant',
            content: [{ type: 'text', text: 'Done.' }],
          },
          uuid: 'msg-002',
          timestamp: '2026-04-13T10:00:05.000Z',
        }),
      ];
      writeFileSync(subagentFile, `${lines.join('\n')}\n`);
    });

    afterAll(() => {
      rmSync(tmpRoot, { recursive: true, force: true });
    });

    it('extracts parentSessionId for subagent files', async () => {
      const info = await adapter.parseSessionInfo(subagentFile);
      expect(info).not.toBeNull();
      expect(info?.id).toBe(agentId);
      expect(info?.agentRole).toBe('subagent');
      expect(info?.parentSessionId).toBe(parentId);
    });

    it('returns undefined parentSessionId for regular sessions', async () => {
      const info = await adapter.parseSessionInfo(FIXTURE);
      expect(info).not.toBeNull();
      expect(info?.parentSessionId).toBeUndefined();
    });
  });
});
