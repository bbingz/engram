import { mkdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { LiveSessionMonitor } from '../../src/core/live-sessions.js';

const TEST_DIR = join(tmpdir(), `engram-live-test-${Date.now()}`);
const CLAUDE_DIR = join(TEST_DIR, '.claude', 'projects', 'test-project');

function createSessionFile(
  name: string,
  content: string,
  mtime?: Date,
): string {
  const filePath = join(CLAUDE_DIR, name);
  writeFileSync(filePath, content, 'utf-8');
  if (mtime) {
    utimesSync(filePath, mtime, mtime);
  }
  return filePath;
}

describe('LiveSessionMonitor', () => {
  beforeAll(() => {
    mkdirSync(CLAUDE_DIR, { recursive: true });
  });

  afterAll(() => {
    rmSync(TEST_DIR, { recursive: true, force: true });
  });

  it('detects recently modified .jsonl files as live sessions', async () => {
    // Create a "live" session file (recent mtime)
    const line = JSON.stringify({
      type: 'system',
      subtype: 'init',
      sessionId: 'live-1',
      cwd: '/test/project',
      timestamp: new Date().toISOString(),
    });
    createSessionFile('live-session.jsonl', `${line}\n`);

    const monitor = new LiveSessionMonitor({
      watchDirs: [
        {
          path: join(TEST_DIR, '.claude', 'projects'),
          source: 'claude-code' as any,
        },
      ],
      stalenessMs: 60_000,
    });
    await monitor.scan();
    const sessions = monitor.getSessions();

    expect(sessions.length).toBe(1);
    expect(sessions[0].source).toBe('claude-code');
    expect(sessions[0].filePath).toContain('live-session.jsonl');
  });

  it('excludes stale files (modified > staleness threshold ago)', async () => {
    // Create a stale file (old mtime)
    const line = JSON.stringify({
      type: 'system',
      subtype: 'init',
      sessionId: 'stale-1',
      cwd: '/test/project',
      timestamp: '2026-01-01T00:00:00Z',
    });
    const staleDate = new Date(Date.now() - 120_000); // 2 minutes ago
    createSessionFile('stale-session.jsonl', `${line}\n`, staleDate);

    const monitor = new LiveSessionMonitor({
      watchDirs: [
        {
          path: join(TEST_DIR, '.claude', 'projects'),
          source: 'claude-code' as any,
        },
      ],
      stalenessMs: 60_000,
    });
    await monitor.scan();
    const sessions = monitor.getSessions();

    // Only the live one from previous test, not the stale one
    const staleSession = sessions.find((s) =>
      s.filePath.includes('stale-session'),
    );
    expect(staleSession).toBeUndefined();
  });

  it('extracts currentActivity from last tool_use line', async () => {
    const lines = [
      JSON.stringify({
        type: 'system',
        subtype: 'init',
        sessionId: 'activity-1',
        cwd: '/code/myapp',
        timestamp: new Date().toISOString(),
      }),
      JSON.stringify({
        type: 'assistant',
        message: {
          role: 'assistant',
          content: [
            {
              type: 'tool_use',
              name: 'Read',
              input: { file_path: 'src/auth.ts' },
            },
          ],
        },
        timestamp: new Date().toISOString(),
      }),
    ];
    createSessionFile('activity-session.jsonl', `${lines.join('\n')}\n`);

    const monitor = new LiveSessionMonitor({
      watchDirs: [
        {
          path: join(TEST_DIR, '.claude', 'projects'),
          source: 'claude-code' as any,
        },
      ],
      stalenessMs: 60_000,
    });
    await monitor.scan();
    const sessions = monitor.getSessions();
    const session = sessions.find((s) =>
      s.filePath.includes('activity-session'),
    );
    expect(session).toBeDefined();
    expect(session?.currentActivity).toContain('Read');
  });

  it('start/stop controls polling interval', async () => {
    const monitor = new LiveSessionMonitor({
      watchDirs: [],
      stalenessMs: 60_000,
    });
    monitor.start(100_000); // very long interval, won't fire during test
    expect(monitor.isRunning()).toBe(true);
    monitor.stop();
    expect(monitor.isRunning()).toBe(false);
  });
});
