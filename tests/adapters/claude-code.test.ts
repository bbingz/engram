// tests/adapters/claude-code.test.ts

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js';
import type { Message } from '../../src/adapters/types.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(__dirname, '../fixtures/claude-code/sample.jsonl');
const TOOL_FIXTURE = join(
  __dirname,
  '../fixtures/claude-code/with-tools.jsonl',
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

  it('streamMessages filters only user and assistant', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE)) {
      messages.push(msg);
    }
    expect(
      messages.every((m) => m.role === 'user' || m.role === 'assistant'),
    ).toBe(true);
    expect(messages[0].role).toBe('user');
    expect(messages[0].content).toBe('请帮我添加用户注册功能');
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
      expect(toolResultMsg.role).toBe('user');
      // tool_result content without "User has answered" is filtered out
      expect(toolResultMsg.content).toBe('');
    });
  });

  it('decodeCwd converts encoded path to real path', () => {
    // 规则：-- 是 -，单 - 是 /
    // 注：编码方式是 / → -，字面量 - 保持不变，因此 -- 可能是 /- 或 -/，解码有歧义
    // 算法：先替换 -- 为占位符，再替换单 - 为 /，再恢复占位符为 -
    expect(ClaudeCodeAdapter.decodeCwd('-Users-bing--Code--project')).toBe(
      '/Users/bing-Code-project',
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
});
