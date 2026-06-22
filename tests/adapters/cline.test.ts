import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
import { ClineAdapter } from '../../src/adapters/cline.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_TASKS = join(__dirname, '../fixtures/cline/tasks');
const FIXTURE_FILE = join(FIXTURE_TASKS, '1770000000000/ui_messages.json');

describe('ClineAdapter', () => {
  const adapter = new ClineAdapter(FIXTURE_TASKS);

  it('name is cline', () => {
    expect(adapter.name).toBe('cline');
  });

  it('listSessionFiles yields ui_messages.json paths', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files).toHaveLength(1);
    expect(files[0]).toContain('ui_messages.json');
  });

  it('parseSessionInfo extracts metadata', async () => {
    const info = await adapter.parseSessionInfo(FIXTURE_FILE);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('1770000000000');
    expect(info?.source).toBe('cline');
    expect(info?.cwd).toBe('/Users/test/my-project');
    expect(info?.summary).toBe('帮我写单元测试');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.model).toBe('glm-5');
  });

  it('streamMessages yields user and assistant', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE_FILE))
      messages.push(msg);
    expect(messages.some((m) => m.role === 'user')).toBe(true);
    expect(messages.some((m) => m.role === 'assistant')).toBe(true);
    expect(messages[0].content).toBe('帮我写单元测试');
  });

  it('streamMessages attaches api request token usage to the assistant reply', async () => {
    const messages = [];
    for await (const msg of adapter.streamMessages(FIXTURE_FILE))
      messages.push(msg);
    expect(messages.find((m) => m.role === 'assistant')?.usage).toEqual({
      inputTokens: 100,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    });
  });

  it('lists legacy claude_messages.json when ui_messages.json is absent', async () => {
    const tmpRoot = join(tmpdir(), `engram-cline-legacy-${Date.now()}`);
    const taskDir = join(tmpRoot, 'tasks', 'legacy-task');
    const legacyPath = join(taskDir, 'claude_messages.json');
    mkdirSync(taskDir, { recursive: true });
    writeFileSync(
      legacyPath,
      JSON.stringify([
        {
          ts: 1771392000000,
          type: 'say',
          say: 'task',
          text: 'legacy task',
        },
      ]),
    );
    try {
      const adapter = new ClineAdapter(join(tmpRoot, 'tasks'));
      const files: string[] = [];
      for await (const file of adapter.listSessionFiles()) files.push(file);
      expect(files).toEqual([legacyPath]);
      const info = await adapter.parseSessionInfo(legacyPath);
      expect(info?.id).toBe('legacy-task');
      expect(info?.summary).toBe('legacy task');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });
});

describe('ClineAdapter cwd with parentheses (R5-32)', () => {
  let tmp: string;
  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('extracts a cwd that itself contains a closing paren', async () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-cline-paren-'));
    const taskDir = join(tmp, 'task-1');
    mkdirSync(taskDir, { recursive: true });
    const filePath = join(taskDir, 'ui_messages.json');
    const cwdWithParen = '/Users/test/proj (work)/repo';
    const request = `<task>\nhi\n</task>\n\nCurrent Working Directory (${cwdWithParen}) Files\n`;
    const ui = [
      { ts: 1770000000000, type: 'say', say: 'task', text: 'hi' },
      {
        ts: 1770000000001,
        type: 'say',
        say: 'api_req_started',
        text: JSON.stringify({ request, tokensIn: 1, tokensOut: 0 }),
      },
    ];
    writeFileSync(filePath, JSON.stringify(ui));
    const adapter = new ClineAdapter(tmp);
    const info = await adapter.parseSessionInfo(filePath);
    // Previously the [^)]+ pattern stopped at the first ')', truncating to
    // '/Users/test/proj (work'. Anchoring on ') Files' keeps the full path.
    expect(info?.cwd).toBe(cwdWithParen);
  });

  it('does not treat multi-root Primary labels as cwd paths', async () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-cline-primary-'));
    const taskDir = join(tmp, 'task-primary');
    mkdirSync(taskDir, { recursive: true });
    const filePath = join(taskDir, 'ui_messages.json');
    const ui = [
      {
        ts: 1770000000000,
        type: 'say',
        say: 'api_req_started',
        text: JSON.stringify({
          request:
            '# Current Working Directory (Primary: workspace-a) Files\n- file.ts',
        }),
      },
      { ts: 1770000000001, type: 'say', say: 'task', text: 'hello' },
    ];
    writeFileSync(filePath, JSON.stringify(ui));
    const adapter = new ClineAdapter(tmp);
    const info = await adapter.parseSessionInfo(filePath);
    expect(info?.cwd).toBe('');
  });
});
