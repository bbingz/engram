import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

describe('AutoSummaryManager', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  async function createManager(
    overrides: {
      cooldownMs?: number;
      minMessages?: number;
      hasSummary?: (id: string) => boolean;
    } = {},
  ) {
    const { AutoSummaryManager } = await import(
      '../../src/core/auto-summary.js'
    );
    const onTrigger = vi
      .fn<(sessionId: string) => Promise<void>>()
      .mockResolvedValue(undefined);
    const hasSummary = overrides.hasSummary ?? vi.fn().mockReturnValue(false);

    const manager = new AutoSummaryManager({
      cooldownMs: overrides.cooldownMs ?? 1000,
      minMessages: overrides.minMessages ?? 2,
      onTrigger,
      hasSummary,
    });

    return { manager, onTrigger, hasSummary };
  }

  it('fires callback after cooldown when session has no summary', async () => {
    const { manager, onTrigger } = await createManager({
      cooldownMs: 1000,
      minMessages: 2,
    });

    manager.onSessionIndexed('s1', 5);
    await vi.advanceTimersByTimeAsync(1000);

    expect(onTrigger).toHaveBeenCalledOnce();
    expect(onTrigger).toHaveBeenCalledWith('s1');

    manager.cleanup();
  });

  it('resets timer on repeated indexing', async () => {
    const { manager, onTrigger } = await createManager({
      cooldownMs: 1000,
      minMessages: 2,
    });

    manager.onSessionIndexed('s1', 5);
    await vi.advanceTimersByTimeAsync(800);
    expect(onTrigger).not.toHaveBeenCalled();

    // Reset the timer by indexing again
    manager.onSessionIndexed('s1', 6);
    await vi.advanceTimersByTimeAsync(800);
    // Only 800ms since reset, not enough
    expect(onTrigger).not.toHaveBeenCalled();

    // 200 more to reach 1000ms since last reset
    await vi.advanceTimersByTimeAsync(200);
    expect(onTrigger).toHaveBeenCalledOnce();

    manager.cleanup();
  });

  it('skips when session already has summary', async () => {
    const { manager, onTrigger } = await createManager({
      cooldownMs: 1000,
      minMessages: 2,
      hasSummary: () => true,
    });

    manager.onSessionIndexed('s1', 5);
    await vi.advanceTimersByTimeAsync(1000);

    expect(onTrigger).not.toHaveBeenCalled();

    manager.cleanup();
  });

  it('skips when message count below threshold', async () => {
    const { manager, onTrigger } = await createManager({
      cooldownMs: 1000,
      minMessages: 10,
    });

    manager.onSessionIndexed('s1', 3);
    await vi.advanceTimersByTimeAsync(1000);

    expect(onTrigger).not.toHaveBeenCalled();

    manager.cleanup();
  });

  it('cleanup clears all timers', async () => {
    const { manager, onTrigger } = await createManager({
      cooldownMs: 1000,
      minMessages: 2,
    });

    manager.onSessionIndexed('s1', 5);
    manager.onSessionIndexed('s2', 10);
    manager.cleanup();

    await vi.advanceTimersByTimeAsync(2000);

    expect(onTrigger).not.toHaveBeenCalled();
  });
});
