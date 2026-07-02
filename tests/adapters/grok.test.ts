import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { GrokAdapter } from '../../src/adapters/grok.js';

describe('GrokAdapter', () => {
  let root: string;
  let sessionDir: string;
  let transcript: string;

  beforeEach(() => {
    root = join(tmpdir(), `engram-grok-${Date.now()}-${Math.random()}`);
    sessionDir = join(
      root,
      '%2FUsers%2Fbing%2F-Automations-%2FPrefict-Trading-Bot',
      '019f179d-0888-76b1-9325-5a91ace595df',
    );
    mkdirSync(sessionDir, { recursive: true });

    writeFileSync(
      join(sessionDir, 'summary.json'),
      JSON.stringify({
        info: {
          id: '019f179d-0888-76b1-9325-5a91ace595df',
          cwd: '/Users/bing/-Automations-/Prefict-Trading-Bot',
        },
        session_summary:
          'Reconstruct Technical Route from X Post Clues and Validate Closed Loop',
        generated_title:
          'Reconstruct Technical Route from X Post Clues and Validate Closed Loop',
        created_at: '2026-06-30T08:19:55.275395Z',
        updated_at: '2026-06-30T11:12:27.482957Z',
        current_model_id: 'grok-build',
      }),
    );
    writeFileSync(
      join(sessionDir, 'prompt_context.json'),
      JSON.stringify({
        working_directory: '/Users/bing/-Automations-/Prefict-Trading-Bot',
        system_prompt_label: 'Grok',
      }),
    );

    transcript = join(sessionDir, 'chat_history.jsonl');
    const lines = [
      { type: 'system', content: 'You are Grok released by xAI.' },
      {
        type: 'user',
        content: [
          {
            type: 'text',
            text: '<user_info>\nWorkspace Path: /Users/bing/-Automations-/Prefict-Trading-Bot\n</user_info>',
          },
        ],
      },
      {
        type: 'reasoning',
        content: 'Inspecting public clues before writing the route.',
      },
      {
        type: 'backend_tool_call',
        name: 'list_dir',
        arguments: '{"target_directory":"."}',
      },
      {
        type: 'user',
        content: [
          {
            type: 'text',
            text: '<user_query>\nhttps://x.com/ZhanweiC/status/2071750256715505947\n\n你按他说的线索，完整还原出他的技术路线？\n</user_query>',
          },
        ],
      },
      {
        type: 'assistant',
        content: '我会先抓取线索并还原技术路线。',
        tool_calls: [
          {
            id: 'call-1',
            name: 'web_fetch',
            arguments: '{"url":"https://github.com/PredictDotFun/sdk-python"}',
          },
        ],
        model_id: 'grok-build',
      },
      {
        type: 'tool_result',
        tool_call_id: 'call-1',
        content: 'Predict.fun SDK README',
      },
    ].map((line) => JSON.stringify(line));
    writeFileSync(transcript, `${lines.join('\n')}\n`);
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  it('lists preferred chat transcripts', async () => {
    const adapter = new GrokAdapter(root);
    const files: string[] = [];
    for await (const file of adapter.listSessionFiles()) files.push(file);
    expect(files).toEqual([transcript]);
  });

  it('parses Grok metadata and streams normalized transcript messages', async () => {
    const adapter = new GrokAdapter(root);
    const info = await adapter.parseSessionInfo(transcript);

    expect(info).toMatchObject({
      id: '019f179d-0888-76b1-9325-5a91ace595df',
      source: 'grok',
      startTime: '2026-06-30T08:19:55.275395Z',
      endTime: '2026-06-30T11:12:27.482957Z',
      cwd: '/Users/bing/-Automations-/Prefict-Trading-Bot',
      model: 'grok-build',
      messageCount: 3,
      userMessageCount: 1,
      assistantMessageCount: 1,
      toolMessageCount: 1,
      systemMessageCount: 2,
    });

    const messages = [];
    for await (const message of adapter.streamMessages(transcript)) {
      messages.push(message);
    }

    expect(messages.map((message) => message.role)).toEqual([
      'user',
      'assistant',
      'tool',
    ]);
    expect(messages[0].content).toBe(
      'https://x.com/ZhanweiC/status/2071750256715505947\n\n你按他说的线索，完整还原出他的技术路线？',
    );
    expect(messages[1]).toMatchObject({
      role: 'assistant',
      content: '我会先抓取线索并还原技术路线。',
      toolCalls: [
        {
          name: 'web_fetch',
          input: '{"url":"https://github.com/PredictDotFun/sdk-python"}',
        },
      ],
    });
    expect(messages[2]).toMatchObject({
      role: 'tool',
      content: 'Predict.fun SDK README',
    });
  });
});
