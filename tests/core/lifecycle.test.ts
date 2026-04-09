import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setupProcessLifecycle } from '../../src/core/lifecycle.js';

describe('setupProcessLifecycle', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
  });

  // 1. Signal handlers registered without throwing
  it('registers signal handlers and returns a heartbeat handle', () => {
    // setupProcessLifecycle should not throw and should return a handle
    const handle = setupProcessLifecycle({
      idleTimeoutMs: 0, // disable idle timeout so it doesn't interfere
      onExit: () => {},
    });
    expect(handle).toBeDefined();
    expect(typeof handle.heartbeat).toBe('function');
  });

  // 2. Idle timeout calls cleanup callback
  it('idle timeout triggers onExit callback', () => {
    const onExit = vi.fn();
    // Mock process.exit to prevent actual exit
    const exitSpy = vi
      .spyOn(process, 'exit')
      .mockImplementation((() => {}) as any);

    setupProcessLifecycle({
      idleTimeoutMs: 5000,
      onExit,
    });

    // Before timeout — not yet called
    vi.advanceTimersByTime(4999);
    expect(onExit).not.toHaveBeenCalled();

    // Advance past the timeout
    vi.advanceTimersByTime(1);
    expect(onExit).toHaveBeenCalled();
    expect(exitSpy).toHaveBeenCalledWith(0);

    exitSpy.mockRestore();
  });

  // 3. Heartbeat resets the idle timer
  it('heartbeat resets idle timer (does not exit prematurely)', () => {
    const onExit = vi.fn();
    const exitSpy = vi
      .spyOn(process, 'exit')
      .mockImplementation((() => {}) as any);

    const handle = setupProcessLifecycle({
      idleTimeoutMs: 10_000,
      onExit,
    });

    // Advance 8s, then heartbeat to reset
    vi.advanceTimersByTime(8000);
    handle.heartbeat();

    // Advance 8s more — total 16s from start, but only 8s since heartbeat
    vi.advanceTimersByTime(8000);
    expect(onExit).not.toHaveBeenCalled();

    // Advance past the reset timeout (2s more = 10s since heartbeat)
    vi.advanceTimersByTime(2000);
    expect(onExit).toHaveBeenCalled();

    exitSpy.mockRestore();
  });
});
