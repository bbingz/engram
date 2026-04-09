import Database from 'better-sqlite3';
import { beforeEach, describe, expect, it } from 'vitest';
import { UsageCollector } from '../../src/core/usage-collector.js';
import type { UsageProbe } from '../../src/core/usage-probe.js';

describe('UsageCollector', () => {
  let db: Database.Database;
  let collector: UsageCollector;
  let emitted: Array<{ event: string; data: unknown }>;

  beforeEach(() => {
    db = new Database(':memory:');
    db.exec(`
      CREATE TABLE usage_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL,
        metric TEXT NOT NULL,
        value REAL NOT NULL,
        unit TEXT DEFAULT '%',
        reset_at TEXT,
        collected_at TEXT NOT NULL
      )
    `);
    emitted = [];
    collector = new UsageCollector(db, (event, data) => {
      emitted.push({ event, data });
    });
  });

  it('stores snapshots from probe', async () => {
    const mockProbe: UsageProbe = {
      source: 'test',
      interval: 60000,
      probe: async () => [
        {
          source: 'test',
          metric: 'usage_5h',
          value: 65,
          collectedAt: new Date().toISOString(),
        },
      ],
    };
    collector.register(mockProbe);
    // Manually run probe (don't start timer in test)
    await (collector as any).runProbe(mockProbe);

    const latest = collector.getLatest();
    expect(latest).toHaveLength(1);
    expect(latest[0].source).toBe('test');
    expect(latest[0].value).toBe(65);
  });

  it('emits usage event', async () => {
    const mockProbe: UsageProbe = {
      source: 'test',
      interval: 60000,
      probe: async () => [
        {
          source: 'test',
          metric: 'm1',
          value: 50,
          collectedAt: new Date().toISOString(),
        },
      ],
    };
    collector.register(mockProbe);
    await (collector as any).runProbe(mockProbe);
    expect(emitted).toHaveLength(1);
    expect(emitted[0].event).toBe('usage');
  });

  it('handles probe failure gracefully', async () => {
    const failProbe: UsageProbe = {
      source: 'fail',
      interval: 60000,
      probe: async () => {
        throw new Error('network down');
      },
    };
    collector.register(failProbe);
    // Should not throw
    await (collector as any).runProbe(failProbe);
    expect(collector.getLatest()).toHaveLength(0);
  });
});
