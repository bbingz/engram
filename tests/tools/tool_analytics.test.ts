import { beforeAll, describe, expect, it } from 'vitest';
import { Database } from '../../src/core/db.js';

describe('tool_analytics', () => {
  let db: Database;

  beforeAll(() => {
    db = new Database(':memory:');
    // Insert test sessions
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary) VALUES ('s1', 'claude-code', '2026-03-20T10:00:00Z', '/test', 'my-project', 'claude-sonnet-4-6', 10, 3, 5, 1, 1, '/test/s1.jsonl', 1000, 'normal', 'Session one summary')`,
    );
    db.getRawDb().exec(
      `INSERT INTO sessions (id, source, start_time, cwd, project, model, message_count, user_message_count, assistant_message_count, tool_message_count, system_message_count, file_path, size_bytes, tier, summary) VALUES ('s2', 'claude-code', '2026-03-20T11:00:00Z', '/test2', 'other-project', 'claude-sonnet-4-6', 5, 2, 2, 0, 1, '/test/s2.jsonl', 500, 'normal', 'Session two summary')`,
    );
    // Insert tool data
    db.upsertSessionTools(
      's1',
      new Map([
        ['Read', 15],
        ['Edit', 8],
        ['Bash', 12],
        ['Write', 3],
      ]),
    );
    db.upsertSessionTools(
      's2',
      new Map([
        ['Read', 5],
        ['Grep', 3],
      ]),
    );
  });

  it('returns tool usage sorted by call count (default group_by=tool)', () => {
    const result = db.getToolAnalytics({});
    expect(result.length).toBe(5); // Read, Bash, Edit, Write, Grep
    expect(result[0].key).toBe('Read');
    expect(result[0].callCount).toBe(20); // 15 + 5
    expect(result[0].sessionCount).toBe(2);
    expect(result[1].key).toBe('Bash');
    expect(result[1].callCount).toBe(12);
  });

  it('filters by project', () => {
    const result = db.getToolAnalytics({ project: 'my-project' });
    expect(result.length).toBe(4);
  });

  it('filters by project with no match', () => {
    const result = db.getToolAnalytics({ project: 'nonexistent' });
    expect(result.length).toBe(0);
  });

  it('escapes LIKE wildcards in project filter', () => {
    // % and _ should not act as wildcards
    const result = db.getToolAnalytics({ project: '100%_done' });
    expect(result.length).toBe(0); // no match, but no SQL error
  });

  it('group_by session returns per-session aggregates', () => {
    const result = db.getToolAnalytics({ groupBy: 'session' });
    expect(result.length).toBe(2);
    // s1 has 38 total calls, s2 has 8
    const s1 = result.find((r: any) => r.key === 's1');
    const s2 = result.find((r: any) => r.key === 's2');
    expect(s1).toBeDefined();
    expect(s1.callCount).toBe(38);
    expect(s1.toolCount).toBe(4);
    expect(s1.label).toBe('Session one summary');
    expect(s2).toBeDefined();
    expect(s2.callCount).toBe(8);
    expect(s2.toolCount).toBe(2);
  });

  it('group_by project returns per-project aggregates', () => {
    const result = db.getToolAnalytics({ groupBy: 'project' });
    expect(result.length).toBe(2);
    const myProj = result.find((r: any) => r.key === 'my-project');
    const otherProj = result.find((r: any) => r.key === 'other-project');
    expect(myProj).toBeDefined();
    expect(myProj.callCount).toBe(38);
    expect(myProj.sessionCount).toBe(1);
    expect(myProj.toolCount).toBe(4);
    expect(otherProj).toBeDefined();
    expect(otherProj.callCount).toBe(8);
    expect(otherProj.sessionCount).toBe(1);
  });
});
