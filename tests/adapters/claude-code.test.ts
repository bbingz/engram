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
    expect(info?.project).toBe('my-project');
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

  it('does not throw when AskUserQuestion questions is encoded as a string', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-ask-user-string-${Date.now()}`);
    const filePath = join(tmpRoot, 'ask-user-string.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          type: 'assistant',
          sessionId: 'ask-user-string-session',
          timestamp: '2026-04-29T10:00:00.000Z',
          message: {
            role: 'assistant',
            model: 'claude-sonnet-4-20250514',
            content: [
              {
                type: 'tool_use',
                id: 'toolu_ask_user_string',
                name: 'AskUserQuestion',
                input: {
                  questions: JSON.stringify([
                    {
                      header: 'Scope',
                      question: 'Which option?',
                      options: [{ label: 'A', description: 'First' }],
                    },
                  ]),
                },
              },
            ],
          },
        }),
      ].join('\n'),
    );

    try {
      const messages: Message[] = [];
      for await (const message of adapter.streamMessages(filePath)) {
        messages.push(message);
      }
      expect(messages).toHaveLength(1);
      expect(messages[0].content).toBe('`AskUserQuestion`');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('maps Claude Code provider roots to provider source with originator', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-provider-${Date.now()}`);
    const projectsRoot = join(tmpRoot, '.claude-mimo', 'projects');
    const projectDir = join(projectsRoot, '-Users-test-provider');
    const filePath = join(projectDir, 'provider-session.jsonl');
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/provider',
          sessionId: 'provider-session',
          timestamp: '2026-04-29T10:00:00.000Z',
          message: { role: 'user', content: 'hello' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId: 'provider-session',
          timestamp: '2026-04-29T10:00:01.000Z',
          message: {
            role: 'assistant',
            model: 'mimo-v2.5-pro',
            content: [{ type: 'text', text: 'hi' }],
          },
        }),
      ].join('\n'),
    );

    try {
      const providerAdapter = new ClaudeCodeAdapter(projectsRoot);
      const info = await providerAdapter.parseSessionInfo(filePath);
      expect(providerAdapter.name).toBe('mimo');
      expect(info?.source).toBe('mimo');
      expect(info?.originator).toBe('Claude Code');
      expect(info?.model).toBe('mimo-v2.5-pro');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('skips system injections from provider-root streamed messages', async () => {
    const tmpRoot = join(
      tmpdir(),
      `engram-cc-provider-injection-${Date.now()}`,
    );
    const projectsRoot = join(tmpRoot, '.claude-qwen', 'projects');
    const projectDir = join(projectsRoot, '-Users-test-provider');
    const filePath = join(projectDir, 'provider-session.jsonl');
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/provider',
          sessionId: 'provider-session',
          timestamp: '2026-04-29T10:00:00.000Z',
          message: {
            role: 'user',
            content:
              '<command-message>goal</command-message>\n<command-name>/goal</command-name>',
          },
        }),
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/provider',
          sessionId: 'provider-session',
          timestamp: '2026-04-29T10:00:01.000Z',
          message: { role: 'user', content: 'real question' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId: 'provider-session',
          timestamp: '2026-04-29T10:00:02.000Z',
          message: {
            role: 'assistant',
            model: 'qwen3.7-plus',
            content: [{ type: 'text', text: 'real answer' }],
          },
        }),
      ].join('\n'),
    );

    try {
      const providerAdapter = new ClaudeCodeAdapter(projectsRoot);
      const info = await providerAdapter.parseSessionInfo(filePath);
      expect(info?.source).toBe('qwen');
      expect(info?.systemMessageCount).toBe(1);
      expect(info?.userMessageCount).toBe(1);
      expect(info?.assistantMessageCount).toBe(1);
      expect(info?.messageCount).toBe(2);

      const messages = [];
      for await (const msg of providerAdapter.streamMessages(filePath)) {
        messages.push(msg);
      }
      expect(info?.messageCount).toBe(messages.length);
      expect(messages.map((m) => m.content)).toEqual([
        'real question',
        'real answer',
      ]);

      const offsetMessages = [];
      for await (const msg of providerAdapter.streamMessages(filePath, {
        offset: 1,
      })) {
        offsetMessages.push(msg);
      }
      expect(offsetMessages.map((m) => m.content)).toEqual(['real answer']);
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('discovers nested workflow subagents under provider roots', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-workflow-${Date.now()}`);
    const projectsRoot = join(tmpRoot, '.claude-glmc', 'projects');
    const projectDir = join(projectsRoot, '-Users-test-workflow');
    const parentId = 'workflow-parent';
    const parentPath = join(projectDir, `${parentId}.jsonl`);
    const directSubagentPath = join(
      projectDir,
      parentId,
      'subagents',
      'direct-agent.jsonl',
    );
    const workflowSubagentPath = join(
      projectDir,
      parentId,
      'subagents',
      'workflows',
      'wf_123',
      'workflow-agent.jsonl',
    );

    const transcript = (sessionId: string, agentId?: string) =>
      [
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/workflow',
          sessionId,
          agentId,
          timestamp: '2026-04-29T10:00:00.000Z',
          message: { role: 'user', content: 'hello' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId,
          agentId,
          timestamp: '2026-04-29T10:00:01.000Z',
          message: {
            role: 'assistant',
            model: 'glm-5.2',
            content: [{ type: 'text', text: 'hi' }],
          },
        }),
      ].join('\n');

    mkdirSync(dirname(parentPath), { recursive: true });
    mkdirSync(dirname(directSubagentPath), { recursive: true });
    mkdirSync(dirname(workflowSubagentPath), { recursive: true });
    writeFileSync(parentPath, transcript(parentId));
    writeFileSync(directSubagentPath, transcript(parentId, 'direct-agent'));
    writeFileSync(workflowSubagentPath, transcript(parentId, 'workflow-agent'));

    try {
      const providerAdapter = new ClaudeCodeAdapter(projectsRoot);
      const files: string[] = [];
      for await (const file of providerAdapter.listSessionFiles()) {
        files.push(file);
      }
      expect(new Set(files)).toEqual(
        new Set([parentPath, directSubagentPath, workflowSubagentPath]),
      );

      const info = await providerAdapter.parseSessionInfo(workflowSubagentPath);
      expect(providerAdapter.name).toBe('glm');
      expect(info?.id).toBe('workflow-agent');
      expect(info?.source).toBe('glm');
      expect(info?.originator).toBe('Claude Code');
      expect(info?.agentRole).toBe('subagent');
      expect(info?.parentSessionId).toBe(parentId);
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  it('classifies MiniMax and Lobster AI as derived Claude-compatible sources', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-derived-${Date.now()}`);
    const minimaxPath = join(tmpRoot, 'project', 'minimax.jsonl');
    const lobsterPath = join(tmpRoot, 'lobsterai-project', 'claude.jsonl');
    const hiddenLobsterPath = join(
      tmpRoot,
      '.lobsterai-project',
      'claude.jsonl',
    );
    const hiddenDecoyPath = join(tmpRoot, '.lobsteraiproject', 'claude.jsonl');
    const decoyPath = join(tmpRoot, 'notlobsterai-project', 'claude.jsonl');
    mkdirSync(dirname(minimaxPath), { recursive: true });
    mkdirSync(dirname(lobsterPath), { recursive: true });
    mkdirSync(dirname(hiddenLobsterPath), { recursive: true });
    mkdirSync(dirname(hiddenDecoyPath), { recursive: true });
    mkdirSync(dirname(decoyPath), { recursive: true });

    const fixture = (sessionId: string, model: string) =>
      [
        JSON.stringify({
          type: 'user',
          cwd: '/proj',
          sessionId,
          timestamp: '2026-04-29T10:00:00.000Z',
          message: { role: 'user', content: 'hello' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId,
          timestamp: '2026-04-29T10:00:01.000Z',
          message: {
            role: 'assistant',
            model,
            content: [{ type: 'text', text: 'hi' }],
          },
        }),
      ].join('\n');

    writeFileSync(minimaxPath, fixture('minimax-session', 'minimax-m1'));
    writeFileSync(lobsterPath, fixture('lobster-session', 'claude-sonnet'));
    writeFileSync(
      hiddenLobsterPath,
      fixture('hidden-lobster-session', 'claude-sonnet'),
    );
    writeFileSync(
      hiddenDecoyPath,
      fixture('hidden-claude-session', 'claude-sonnet'),
    );
    writeFileSync(decoyPath, fixture('claude-session', 'claude-sonnet'));

    try {
      await expect(
        adapter.parseSessionInfo(minimaxPath),
      ).resolves.toMatchObject({
        source: 'minimax',
        model: 'minimax-m1',
      });
      await expect(
        adapter.parseSessionInfo(lobsterPath),
      ).resolves.toMatchObject({
        source: 'lobsterai',
        model: 'claude-sonnet',
      });
      await expect(
        adapter.parseSessionInfo(hiddenLobsterPath),
      ).resolves.toMatchObject({
        source: 'lobsterai',
        model: 'claude-sonnet',
      });
      await expect(
        adapter.parseSessionInfo(hiddenDecoyPath),
      ).resolves.toMatchObject({
        source: 'claude-code',
        model: 'claude-sonnet',
      });
      await expect(adapter.parseSessionInfo(decoyPath)).resolves.toMatchObject({
        source: 'claude-code',
        model: 'claude-sonnet',
      });
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

  it('counts and streams only visible tool_result records', async () => {
    const tmpRoot = join(tmpdir(), `engram-cc-visible-tool-${Date.now()}`);
    const filePath = join(tmpRoot, 'visible-tool.jsonl');
    mkdirSync(tmpRoot, { recursive: true });
    writeFileSync(
      filePath,
      [
        JSON.stringify({
          type: 'user',
          cwd: '/Users/test/proj',
          sessionId: 'visible-tool-1',
          timestamp: '2026-01-01T00:00:00.000Z',
          message: { role: 'user', content: 'do the thing' },
        }),
        JSON.stringify({
          type: 'assistant',
          sessionId: 'visible-tool-1',
          timestamp: '2026-01-01T00:00:01.000Z',
          message: { role: 'assistant', content: 'on it' },
        }),
        JSON.stringify({
          type: 'user',
          sessionId: 'visible-tool-1',
          timestamp: '2026-01-01T00:00:02.000Z',
          message: {
            role: 'user',
            content: [{ type: 'tool_result', content: 'raw output' }],
          },
        }),
        JSON.stringify({
          type: 'user',
          sessionId: 'visible-tool-1',
          timestamp: '2026-01-01T00:00:03.000Z',
          message: {
            role: 'user',
            content: [
              { type: 'tool_result', content: 'User has answered: yes' },
            ],
          },
        }),
      ].join('\n'),
    );

    try {
      const info = await adapter.parseSessionInfo(filePath);
      const messages = [];
      for await (const msg of adapter.streamMessages(filePath)) {
        messages.push(msg);
      }

      expect(info?.userMessageCount).toBe(1);
      expect(info?.assistantMessageCount).toBe(1);
      expect(info?.toolMessageCount).toBe(1);
      expect(info?.messageCount).toBe(3);
      expect(messages.map((m) => m.role)).toEqual([
        'user',
        'assistant',
        'tool',
      ]);
      expect(messages.map((m) => m.content)).toEqual([
        'do the thing',
        'on it',
        'User has answered: yes',
      ]);
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
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

  it('does not count non-visible tool_result records as user turns', async () => {
    const info = await adapter.parseSessionInfo(TOOL_FIXTURE);
    expect(info).not.toBeNull();
    expect(info?.userMessageCount).toBe(2); // "帮我查看" + "好的，谢谢"
    expect(info?.toolMessageCount).toBe(0); // raw tool output is hidden
    expect(info?.assistantMessageCount).toBe(2); // tool_use response + text response
    expect(info?.messageCount).toBe(4); // 2 user + 2 asst
  });

  describe('tool formatting in streamMessages', () => {
    it('formats Read and Bash tools with summaries, filters noise tools', async () => {
      const messages = [];
      for await (const msg of adapter.streamMessages(FMT_FIXTURE)) {
        messages.push(msg);
      }
      // msg-001: user text, msg-002: assistant with tools, msg-003: tool results, msg-004: assistant text
      expect(messages.length).toBe(3);

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
      // msg-003 is a tool_result without "User has answered"; it is not a
      // visible transcript turn and must not be streamed.
      expect(messages.map((m) => m.role)).toEqual([
        'user',
        'assistant',
        'assistant',
      ]);
    });
  });

  it('decodeCwd round-trips unambiguous paths exactly', () => {
    // No dash-run ambiguity here: every single '-' is a path separator.
    expect(ClaudeCodeAdapter.decodeCwd('-Users-example-project')).toBe(
      '/Users/example/project',
    );
    expect(ClaudeCodeAdapter.decodeCwd('-tmp-a-b-c')).toBe('/tmp/a/b/c');
  });

  it('decodeCwd is intentionally lossy for ambiguous dash-runs (R5-7)', () => {
    // The encoding maps '/' → '-' and keeps literal '-' verbatim, so a run of
    // dashes ("[trailing dashes][slash][leading dashes]") cannot be inverted
    // unambiguously. `--Code--` could be `/-Code-/`, `/-Code/-`, or `/Code-/-`.
    // We pick ONE consistent disambiguation (every '--' → literal '-'); this
    // test pins that choice so any future change is deliberate, and must stay
    // byte-for-byte aligned with the Swift adapter for parity.
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

    it('extracts parentSessionId for nested workflow subagent files', async () => {
      const workflowFile = join(
        tmpRoot,
        'project-dir',
        parentId,
        'subagents',
        'workflows',
        'wf_456',
        `${agentId}-workflow.jsonl`,
      );
      mkdirSync(dirname(workflowFile), { recursive: true });
      writeFileSync(
        workflowFile,
        [
          JSON.stringify({
            type: 'user',
            cwd: '/Users/test/project',
            sessionId: parentId,
            agentId,
            message: { role: 'user', content: 'Do the workflow task' },
            timestamp: '2026-04-13T10:00:00.000Z',
          }),
          JSON.stringify({
            type: 'assistant',
            cwd: '/Users/test/project',
            sessionId: parentId,
            agentId,
            message: {
              role: 'assistant',
              content: [{ type: 'text', text: 'Done.' }],
            },
            timestamp: '2026-04-13T10:00:05.000Z',
          }),
        ].join('\n'),
      );

      const info = await adapter.parseSessionInfo(workflowFile);
      expect(info).not.toBeNull();
      expect(info?.id).toBe(agentId);
      expect(info?.agentRole).toBe('subagent');
      expect(info?.parentSessionId).toBe(parentId);
    });

    it('treats legacy root-level agent files as subagents', async () => {
      const legacyAgentFile = join(
        tmpRoot,
        'project-dir',
        `agent-${agentId}.jsonl`,
      );
      writeFileSync(
        legacyAgentFile,
        [
          JSON.stringify({
            type: 'user',
            isSidechain: true,
            cwd: '/Users/test/project',
            sessionId: parentId,
            agentId,
            message: { role: 'user', content: 'Warmup' },
            timestamp: '2026-04-13T10:00:00.000Z',
          }),
          JSON.stringify({
            type: 'assistant',
            isSidechain: true,
            cwd: '/Users/test/project',
            sessionId: parentId,
            agentId,
            message: {
              role: 'assistant',
              content: [{ type: 'text', text: 'Ready.' }],
            },
            timestamp: '2026-04-13T10:00:05.000Z',
          }),
        ].join('\n'),
      );

      const info = await adapter.parseSessionInfo(legacyAgentFile);
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
