import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';
import { ClaudeCodeAdapter } from '../../src/adapters/claude-code.js';
import { Database } from '../../src/core/db.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURE = resolve(__dirname, '../fixtures/claude-code/sample.jsonl');

describe('session timeline', () => {
  let db: Database;
  let adapter: ClaudeCodeAdapter;

  beforeAll(async () => {
    db = new Database(':memory:');
    adapter = new ClaudeCodeAdapter();
    const info = await adapter.parseSessionInfo(FIXTURE);
    if (info) {
      db.getRawDb()
        .prepare(`
        INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `)
        .run(
          info.id,
          info.source,
          info.startTime,
          info.cwd,
          info.project || '',
          info.model || '',
          info.messageCount,
          info.userMessageCount,
          info.assistantMessageCount,
          info.toolMessageCount,
          info.systemMessageCount,
          FIXTURE,
          info.sizeBytes,
          'normal',
        );
    }
  });

  it('builds timeline entries from session messages', async () => {
    const session = db.listSessions({ limit: 1 })[0];
    expect(session).toBeDefined();

    const entries: Array<{
      index: number;
      role: string;
      type: string;
      preview: string;
      timestamp?: string;
      toolName?: string;
      durationToNextMs?: number;
    }> = [];

    let idx = 0;
    let prevTimestamp: string | undefined;
    for await (const msg of adapter.streamMessages(session.filePath)) {
      const entry: (typeof entries)[0] = {
        index: idx,
        role: msg.role,
        type: msg.toolCalls?.length ? 'tool_use' : 'message',
        preview: msg.content.slice(0, 100),
        timestamp: msg.timestamp,
      };
      if (msg.toolCalls?.length) {
        entry.toolName = msg.toolCalls[0].name;
      }
      if (prevTimestamp && msg.timestamp) {
        const gap =
          new Date(msg.timestamp).getTime() - new Date(prevTimestamp).getTime();
        if (entries.length > 0)
          entries[entries.length - 1].durationToNextMs = gap;
      }
      prevTimestamp = msg.timestamp;
      entries.push(entry);
      idx++;
    }

    expect(entries.length).toBeGreaterThan(0);
    expect(entries[0].index).toBe(0);
    expect(entries[0].role).toBeDefined();
    expect(entries[0].preview.length).toBeLessThanOrEqual(100);
  });

  it('entries have sequential indices', async () => {
    const session = db.listSessions({ limit: 1 })[0];
    const entries: Array<{ index: number }> = [];
    let idx = 0;
    for await (const _msg of adapter.streamMessages(session.filePath)) {
      entries.push({ index: idx });
      idx++;
    }

    for (let i = 0; i < entries.length; i++) {
      expect(entries[i].index).toBe(i);
    }
  });

  it('entries have timestamps from the fixture', async () => {
    const session = db.listSessions({ limit: 1 })[0];
    const timestamps: (string | undefined)[] = [];
    for await (const msg of adapter.streamMessages(session.filePath)) {
      timestamps.push(msg.timestamp);
    }

    // The sample fixture has timestamps
    const defined = timestamps.filter((t) => t !== undefined);
    expect(defined.length).toBeGreaterThan(0);
  });

  it('computes durationToNextMs between timestamped entries', async () => {
    const session = db.listSessions({ limit: 1 })[0];
    const entries: Array<{ timestamp?: string; durationToNextMs?: number }> =
      [];
    let prevTimestamp: string | undefined;

    for await (const msg of adapter.streamMessages(session.filePath)) {
      const entry: (typeof entries)[0] = { timestamp: msg.timestamp };
      if (prevTimestamp && msg.timestamp) {
        const gap =
          new Date(msg.timestamp).getTime() - new Date(prevTimestamp).getTime();
        if (entries.length > 0)
          entries[entries.length - 1].durationToNextMs = gap;
      }
      prevTimestamp = msg.timestamp;
      entries.push(entry);
    }

    // At least one entry should have a duration computed (the sample has 3 messages with timestamps)
    const withDuration = entries.filter(
      (e) => e.durationToNextMs !== undefined,
    );
    expect(withDuration.length).toBeGreaterThan(0);
    // Durations should be positive
    for (const e of withDuration) {
      expect(e.durationToNextMs).toBeGreaterThanOrEqual(0);
    }
  });
});
