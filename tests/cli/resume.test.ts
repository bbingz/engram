import { describe, expect, it } from 'vitest';
import { runResume } from '../../src/cli/resume.js';

describe('runResume', () => {
  it('selects a matching session and launches the returned resume command', async () => {
    const output: string[] = [];
    const errors: string[] = [];
    const spawned: unknown[][] = [];
    const calls: string[] = [];

    const code = await runResume({
      cwd: '/work/engram',
      env: { HOME: '/tmp/missing-home' },
      input: async () => '1',
      output: (line) => output.push(line),
      error: (line) => errors.push(line),
      spawnSync: (...args) => {
        spawned.push(args);
        return { status: 0 };
      },
      fetch: async (url, init) => {
        calls.push(`${init?.method ?? 'GET'} ${url}`);
        if (String(url).endsWith('/api/sessions?limit=10')) {
          return {
            json: async () => ({
              sessions: [
                {
                  id: 's1',
                  source: 'codex',
                  cwd: '/work/engram',
                  project: 'engram',
                  generated_title: 'Fix resume',
                  message_count: 7,
                  start_time: new Date(Date.now() - 90_000).toISOString(),
                },
                {
                  id: 'other',
                  source: 'codex',
                  cwd: '/work/other',
                  project: 'other',
                },
              ],
            }),
          };
        }
        expect(String(url)).toBe('http://127.0.0.1:3457/api/session/s1/resume');
        expect(init?.method).toBe('POST');
        return {
          json: async () => ({
            command: 'codex',
            args: ['resume', 's1'],
            cwd: '/work/engram',
          }),
        };
      },
    });

    expect(code).toBe(0);
    expect(errors).toEqual([]);
    expect(output.join('\n')).toContain('Recent sessions in this project');
    expect(calls).toEqual([
      'GET http://127.0.0.1:3457/api/sessions?limit=10',
      'POST http://127.0.0.1:3457/api/session/s1/resume',
    ]);
    expect(spawned).toEqual([
      ['codex', ['--resume', 's1'], { cwd: '/work/engram', stdio: 'inherit' }],
    ]);
  });

  it('does not execute arbitrary commands returned by the daemon', async () => {
    const spawned: unknown[][] = [];

    const code = await runResume({
      cwd: '/work/engram',
      env: { HOME: '/tmp/missing-home' },
      input: async () => '1',
      output: () => {},
      error: () => {},
      spawnSync: (...args) => {
        spawned.push(args);
        return { status: 0 };
      },
      fetch: async (url) => {
        if (String(url).endsWith('/api/sessions?limit=10')) {
          return {
            json: async () => ({
              sessions: [
                {
                  id: 's1',
                  source: 'codex',
                  cwd: '/work/engram',
                  project: 'engram',
                },
              ],
            }),
          };
        }
        return {
          json: async () => ({
            command: 'sh',
            args: ['-c', 'touch /tmp/engram-resume-pwned'],
            cwd: '/work/engram',
          }),
        };
      },
    });

    expect(code).toBe(0);
    expect(spawned).toEqual([
      ['codex', ['--resume', 's1'], { cwd: '/work/engram', stdio: 'inherit' }],
    ]);
  });

  it('rejects invalid selections without launching a command', async () => {
    const errors: string[] = [];
    const spawned: unknown[][] = [];

    const code = await runResume({
      cwd: '/work/engram',
      env: {},
      input: async () => '9',
      output: () => {},
      error: (line) => errors.push(line),
      spawnSync: (...args) => {
        spawned.push(args);
        return { status: 0 };
      },
      fetch: async () => ({
        json: async () => ({
          sessions: [
            {
              id: 's1',
              source: 'codex',
              cwd: '/work/engram',
              project: 'engram',
            },
          ],
        }),
      }),
    });

    expect(code).toBe(1);
    expect(errors).toEqual(['Invalid selection.']);
    expect(spawned).toEqual([]);
  });

  it('returns a daemon-unavailable error when the session list cannot be fetched', async () => {
    const errors: string[] = [];

    const code = await runResume({
      cwd: '/work/engram',
      env: {},
      input: async () => '1',
      output: () => {},
      error: (line) => errors.push(line),
      spawnSync: () => ({ status: 0 }),
      fetch: async () => {
        throw new Error('ECONNREFUSED');
      },
    });

    expect(code).toBe(1);
    expect(errors).toEqual([
      'Error: Could not connect to Engram daemon. Is it running?',
    ]);
  });
});
