import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import { runInitialScan } from '../../src/core/daemon-startup.js';

describe('runInitialScan', () => {
  it('emits the initial ready count after parent-link backfills finish', async () => {
    let parentBackfillDone = false;
    const events: Array<Record<string, unknown>> = [];
    const callOrder: string[] = [];

    await runInitialScan({
      emit: (event) => {
        events.push(event);
        if (event.event === 'ready') {
          callOrder.push('ready');
        }
      },
      log: { info: vi.fn(), warn: vi.fn() },
      usageCollector: { start: vi.fn() },
      indexer: {
        indexAll: vi.fn(async () => 2),
        backfillCounts: vi.fn(async () => 0),
        backfillCosts: vi.fn(async () => 0),
      },
      indexJobRunner: {
        runRecoverableJobs: vi.fn(async () => ({
          completed: 0,
          notApplicable: 0,
        })),
        backfillInsightEmbeddings: vi.fn(async () => 0),
      },
      db: {
        countSessions: vi.fn(() => 2),
        countTodayParentSessions: vi.fn(() => (parentBackfillDone ? 1 : 0)),
        backfillScores: vi.fn(() => 0),
        deduplicateFilePaths: vi.fn(() => 0),
        optimizeFts: vi.fn(),
        vacuumIfNeeded: vi.fn(() => false),
        reconcileInsights: vi.fn(() => ({
          resetEmbedding: 0,
          orphanedVector: 0,
        })),
        backfillFilePaths: vi.fn(() => 0),
        downgradeSubagentTiers: vi.fn(() => {
          callOrder.push('downgradeSubagentTiers');
          return 0;
        }),
        backfillParentLinks: vi.fn(() => {
          parentBackfillDone = true;
          callOrder.push('backfillParentLinks');
          return { linked: 1 };
        }),
        resetStaleDetections: vi.fn(() => 0),
        backfillCodexOriginator: vi.fn(async () => 0),
        backfillSuggestedParents: vi.fn(() => ({ checked: 0, suggested: 0 })),
        cleanupStaleMigrations: vi.fn(() => 0),
        detectOrphans: vi.fn(async () => ({
          scanned: 0,
          newlyFlagged: 0,
          confirmed: 0,
          recovered: 0,
          skipped: 0,
        })),
      },
      adapters: [],
    });

    expect(events).toContainEqual({
      event: 'backfill',
      type: 'parent_links',
      linked: 1,
    });
    expect(events).toContainEqual({
      event: 'ready',
      indexed: 2,
      total: 2,
      todayParents: 1,
    });
    expect(callOrder).toEqual([
      'downgradeSubagentTiers',
      'backfillParentLinks',
      'ready',
    ]);
  });

  // Shared deps factory so the abort tests differ only by signal.
  function makeDeps(
    detectOrphans: () => Promise<{
      scanned: number;
      newlyFlagged: number;
      confirmed: number;
      recovered: number;
      skipped: number;
    }>,
  ) {
    const events: Array<Record<string, unknown>> = [];
    return {
      events,
      deps: {
        emit: (event: Record<string, unknown>) => events.push(event),
        log: { info: vi.fn(), warn: vi.fn() },
        usageCollector: { start: vi.fn() },
        indexer: {
          indexAll: vi.fn(async () => 0),
          backfillCounts: vi.fn(async () => 0),
          backfillCosts: vi.fn(async () => 0),
        },
        indexJobRunner: {
          runRecoverableJobs: vi.fn(async () => ({
            completed: 0,
            notApplicable: 0,
          })),
          backfillInsightEmbeddings: vi.fn(async () => 0),
        },
        db: {
          countSessions: vi.fn(() => 0),
          countTodayParentSessions: vi.fn(() => 0),
          backfillScores: vi.fn(() => 0),
          deduplicateFilePaths: vi.fn(() => 0),
          optimizeFts: vi.fn(),
          vacuumIfNeeded: vi.fn(() => false),
          reconcileInsights: vi.fn(() => ({
            resetEmbedding: 0,
            orphanedVector: 0,
          })),
          backfillFilePaths: vi.fn(() => 0),
          downgradeSubagentTiers: vi.fn(() => 0),
          backfillParentLinks: vi.fn(() => ({ linked: 0 })),
          resetStaleDetections: vi.fn(() => 0),
          backfillCodexOriginator: vi.fn(async () => 0),
          backfillSuggestedParents: vi.fn(() => ({ checked: 0, suggested: 0 })),
          cleanupStaleMigrations: vi.fn(() => 0),
          detectOrphans: vi.fn(detectOrphans),
        },
        adapters: [],
      },
    };
  }

  const flushSetImmediate = () =>
    new Promise<void>((resolve) => setImmediate(resolve));

  it('skips the background orphan scan when the shutdown signal is already aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    const { deps } = makeDeps(async () => ({
      scanned: 1,
      newlyFlagged: 1,
      confirmed: 0,
      recovered: 0,
      skipped: 0,
    }));

    await runInitialScan({ ...deps, signal: controller.signal });
    await flushSetImmediate();

    expect(deps.db.detectOrphans).not.toHaveBeenCalled();
  });

  it('drops orphan-scan results when shutdown begins mid-scan', async () => {
    const controller = new AbortController();
    const { deps, events } = makeDeps(async () => {
      // Simulate shutdown racing while detectOrphans is in flight.
      controller.abort();
      return {
        scanned: 5,
        newlyFlagged: 3,
        confirmed: 0,
        recovered: 0,
        skipped: 0,
      };
    });

    await runInitialScan({ ...deps, signal: controller.signal });
    await flushSetImmediate();
    await flushSetImmediate();

    // detectOrphans ran, but its result must not be emitted post-abort.
    expect(deps.db.detectOrphans).toHaveBeenCalled();
    expect(events.find((e) => e.event === 'orphan_scan')).toBeUndefined();
  });

  it('keeps daemon startup wired to the shared initial scan sequencing', () => {
    const source = readFileSync('src/daemon.ts', 'utf8');

    expect(source).toContain(
      "import { runInitialScan } from './core/daemon-startup.js';",
    );
    expect(source).toContain('runInitialScan({');
  });
});
