import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { VsCodeAdapter } from '../../src/adapters/vscode.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = join(__dirname, '../fixtures/vscode');

describe('VsCodeAdapter', () => {
  const adapter = new VsCodeAdapter(FIXTURE_DIR);

  it('name is vscode', () => {
    expect(adapter.name).toBe('vscode');
  });

  it('listSessionFiles yields JSONL files from chatSessions subdirs', async () => {
    const files: string[] = [];
    for await (const f of adapter.listSessionFiles()) files.push(f);
    expect(files.some((f) => f.endsWith('sess-001.jsonl'))).toBe(true);
  });

  it('parseSessionInfo reads from JSONL first line', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const info = await adapter.parseSessionInfo(jsonlPath);
    expect(info).not.toBeNull();
    expect(info?.id).toBe('sess-001');
    expect(info?.source).toBe('vscode');
    expect(info?.userMessageCount).toBe(2);
    expect(info?.summary).toContain('async/await');
  });

  it('parseSessionInfo decodes cwd from workspaceStorage/<hash>/workspace.json', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const info = await adapter.parseSessionInfo(jsonlPath);
    expect(info?.cwd).toBe('/Users/test/my-project');
  });

  it('messageCount equals real user+assistant text counts (no 1:1 padding)', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const info = await adapter.parseSessionInfo(jsonlPath);
    expect(info?.messageCount).toBe(
      (info?.userMessageCount ?? 0) + (info?.assistantMessageCount ?? 0),
    );
  });

  describe('multi-root .code-workspace resolution', () => {
    const tmpRoot = join(tmpdir(), `engram-vscode-multiroot-${Date.now()}`);
    const projDir = join(tmpRoot, 'project-a');
    const wsFile = join(tmpRoot, 'multi.code-workspace');
    const hashDir = join(tmpRoot, 'workspaceStorage', 'hash-mr');
    const sessPath = join(hashDir, 'chatSessions', 'sess.jsonl');

    beforeAll(() => {
      mkdirSync(projDir, { recursive: true });
      mkdirSync(dirname(sessPath), { recursive: true });
      writeFileSync(
        wsFile,
        JSON.stringify({
          folders: [{ path: 'project-a' }, { path: '/abs/other' }],
        }),
      );
      writeFileSync(
        join(hashDir, 'workspace.json'),
        JSON.stringify({ configuration: `file://${wsFile}` }),
      );
      writeFileSync(
        sessPath,
        `${JSON.stringify({
          kind: 0,
          v: {
            version: 3,
            sessionId: 'mr-1',
            creationDate: 1771392000000,
            requests: [
              {
                requestId: 'r1',
                message: { text: 'hi' },
                response: [
                  {
                    value: {
                      kind: 'markdownContent',
                      content: { value: 'hello' },
                    },
                  },
                ],
                timestamp: 1771392005000,
              },
            ],
          },
        })}\n`,
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('resolves multi-root cwd from folders[0].path relative to .code-workspace dir', async () => {
      const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
      const info = await a.parseSessionInfo(sessPath);
      expect(info?.cwd).toBe(projDir);
    });
  });

  it('returns empty cwd when workspace.json is missing', async () => {
    const tmpRoot = join(tmpdir(), `engram-vscode-no-wsjson-${Date.now()}`);
    const sessPath = join(
      tmpRoot,
      'workspaceStorage',
      'hash-x',
      'chatSessions',
      'sess.jsonl',
    );
    mkdirSync(dirname(sessPath), { recursive: true });
    writeFileSync(
      sessPath,
      `${JSON.stringify({
        kind: 0,
        v: {
          version: 3,
          sessionId: 's',
          creationDate: 1771392000000,
          requests: [
            {
              requestId: 'r1',
              message: { text: 'hi' },
              response: [
                {
                  value: { kind: 'markdownContent', content: { value: 'hi' } },
                },
              ],
            },
          ],
        },
      })}\n`,
    );
    try {
      const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
      const info = await a.parseSessionInfo(sessPath);
      expect(info?.cwd).toBe('');
    } finally {
      rmSync(tmpRoot, { recursive: true, force: true });
    }
  });

  describe('workspace.json edge cases', () => {
    function makeFixture(wsJsonContent: string): {
      tmpRoot: string;
      sessPath: string;
    } {
      const tmpRoot = join(
        tmpdir(),
        `engram-vscode-edge-${Date.now()}-${Math.random()}`,
      );
      const hashDir = join(tmpRoot, 'workspaceStorage', 'h');
      const sessPath = join(hashDir, 'chatSessions', 'sess.jsonl');
      mkdirSync(dirname(sessPath), { recursive: true });
      writeFileSync(join(hashDir, 'workspace.json'), wsJsonContent);
      writeFileSync(
        sessPath,
        `${JSON.stringify({
          kind: 0,
          v: {
            version: 3,
            sessionId: 'edge',
            creationDate: 1771392000000,
            requests: [
              {
                requestId: 'r1',
                message: { text: 'hi' },
                response: [
                  {
                    value: {
                      kind: 'markdownContent',
                      content: { value: 'hi' },
                    },
                  },
                ],
              },
            ],
          },
        })}\n`,
      );
      return { tmpRoot, sessPath };
    }

    it('strips localhost authority from file://localhost/path URIs', async () => {
      const { tmpRoot, sessPath } = makeFixture(
        JSON.stringify({ folder: 'file://localhost/Users/me/proj' }),
      );
      try {
        const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
        const info = await a.parseSessionInfo(sessPath);
        expect(info?.cwd).toBe('/Users/me/proj');
      } finally {
        rmSync(tmpRoot, { recursive: true, force: true });
      }
    });

    it('returns empty cwd for non-file URIs (vscode-remote://, vsls://, ...)', async () => {
      const { tmpRoot, sessPath } = makeFixture(
        JSON.stringify({
          folder: 'vscode-remote://ssh-remote+host/Users/me/proj',
        }),
      );
      try {
        const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
        const info = await a.parseSessionInfo(sessPath);
        expect(info?.cwd).toBe('');
      } finally {
        rmSync(tmpRoot, { recursive: true, force: true });
      }
    });

    it('returns empty cwd for malformed percent-encoding', async () => {
      const { tmpRoot, sessPath } = makeFixture(
        // %2 is an incomplete escape — decodeURIComponent throws
        JSON.stringify({ folder: 'file:///bad/%2' }),
      );
      try {
        const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
        const info = await a.parseSessionInfo(sessPath);
        expect(info?.cwd).toBe('');
      } finally {
        rmSync(tmpRoot, { recursive: true, force: true });
      }
    });

    it('returns empty cwd when workspace.json is corrupt JSON', async () => {
      const { tmpRoot, sessPath } = makeFixture('{not valid json');
      try {
        const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
        const info = await a.parseSessionInfo(sessPath);
        expect(info?.cwd).toBe('');
      } finally {
        rmSync(tmpRoot, { recursive: true, force: true });
      }
    });

    it('decodes Windows-style file:///C%3A/path URIs', async () => {
      const { tmpRoot, sessPath } = makeFixture(
        JSON.stringify({ folder: 'file:///C%3A/Users/me/proj' }),
      );
      try {
        const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
        const info = await a.parseSessionInfo(sessPath);
        expect(info?.cwd).toBe('/C:/Users/me/proj');
      } finally {
        rmSync(tmpRoot, { recursive: true, force: true });
      }
    });
  });

  describe('.code-workspace folders[].uri form', () => {
    const tmpRoot = join(tmpdir(), `engram-vscode-uri-folder-${Date.now()}`);
    const wsFile = join(tmpRoot, 'multi.code-workspace');
    const hashDir = join(tmpRoot, 'workspaceStorage', 'hash-uri');
    const sessPath = join(hashDir, 'chatSessions', 'sess.jsonl');

    beforeAll(() => {
      mkdirSync(dirname(sessPath), { recursive: true });
      writeFileSync(
        wsFile,
        JSON.stringify({
          folders: [
            { uri: 'file:///Users/me/uri-form-proj' },
            { path: 'second-folder' },
          ],
        }),
      );
      writeFileSync(
        join(hashDir, 'workspace.json'),
        JSON.stringify({ configuration: `file://${wsFile}` }),
      );
      writeFileSync(
        sessPath,
        `${JSON.stringify({
          kind: 0,
          v: {
            version: 3,
            sessionId: 'uri-1',
            creationDate: 1771392000000,
            requests: [
              {
                requestId: 'r1',
                message: { text: 'hi' },
                response: [
                  {
                    value: {
                      kind: 'markdownContent',
                      content: { value: 'hi' },
                    },
                  },
                ],
              },
            ],
          },
        })}\n`,
      );
    });

    afterAll(() => rmSync(tmpRoot, { recursive: true, force: true }));

    it('resolves cwd from folders[0].uri when present', async () => {
      const a = new VsCodeAdapter(join(tmpRoot, 'workspaceStorage'));
      const info = await a.parseSessionInfo(sessPath);
      expect(info?.cwd).toBe('/Users/me/uri-form-proj');
    });
  });

  it('streamMessages yields user and assistant alternating', async () => {
    const jsonlPath = join(
      FIXTURE_DIR,
      'ws-abc123/chatSessions/sess-001.jsonl',
    );
    const msgs: { role: string; content: string }[] = [];
    for await (const m of adapter.streamMessages(jsonlPath)) msgs.push(m);
    expect(msgs).toHaveLength(4);
    expect(msgs[0]).toMatchObject({
      role: 'user',
      content: 'How do I use async/await in TypeScript?',
    });
    expect(msgs[1].role).toBe('assistant');
    expect(msgs[2]).toMatchObject({
      role: 'user',
      content: 'Can you show an example?',
    });
    expect(msgs[3].role).toBe('assistant');
  });
});
