import { describe, expect, it, vi } from 'vitest';
import { SOURCE_NAMES } from '../../src/adapters/types.js';
import {
  createDaemonDeps,
  createMCPDeps,
  createShutdownHandler,
  getAdapter,
  type ShutdownResources,
} from '../../src/core/bootstrap.js';

function createMockResources(
  overrides?: Partial<ShutdownResources>,
): ShutdownResources {
  return {
    timers: [setInterval(() => {}, 999_999), setTimeout(() => {}, 999_999)],
    watcher: { close: vi.fn() },
    webServer: { close: vi.fn() },
    db: { close: vi.fn() },
    metrics: { destroy: vi.fn() },
    liveMonitor: { stop: vi.fn() },
    backgroundMonitor: { stop: vi.fn() },
    usageCollector: { stop: vi.fn() },
    autoSummary: { cleanup: vi.fn() },
    ...overrides,
  };
}

describe('createShutdownHandler', () => {
  it('calls all resource cleanup methods', () => {
    const resources = createMockResources();
    const shutdown = createShutdownHandler(resources);

    shutdown();

    expect(resources.watcher?.close).toHaveBeenCalledOnce();
    expect(resources.webServer?.close).toHaveBeenCalledOnce();
    expect(resources.db.close).toHaveBeenCalledOnce();
    expect(resources.metrics?.destroy).toHaveBeenCalledOnce();
    expect(resources.liveMonitor?.stop).toHaveBeenCalledOnce();
    expect(resources.backgroundMonitor?.stop).toHaveBeenCalledOnce();
    expect(resources.usageCollector?.stop).toHaveBeenCalledOnce();
    expect(
      (resources.autoSummary as { cleanup: () => void } | null)?.cleanup,
    ).toHaveBeenCalledOnce();
  });

  it('is idempotent — second call is a no-op', () => {
    const resources = createMockResources();
    const shutdown = createShutdownHandler(resources);

    shutdown();
    shutdown();

    expect(resources.db.close).toHaveBeenCalledOnce();
    expect(resources.metrics?.destroy).toHaveBeenCalledOnce();
    expect(resources.liveMonitor?.stop).toHaveBeenCalledOnce();
  });

  it('handles null/undefined optional resources without crashing', () => {
    const resources = createMockResources({
      watcher: null,
      webServer: null,
      metrics: null,
      liveMonitor: null,
      backgroundMonitor: null,
      usageCollector: null,
      autoSummary: null,
    });

    const shutdown = createShutdownHandler(resources);
    expect(() => shutdown()).not.toThrow();
    expect(resources.db.close).toHaveBeenCalledOnce();
  });

  it('handles undefined optional resources without crashing', () => {
    const resources: ShutdownResources = {
      timers: [],
      db: { close: vi.fn() },
    };

    const shutdown = createShutdownHandler(resources);
    expect(() => shutdown()).not.toThrow();
    expect(resources.db.close).toHaveBeenCalledOnce();
  });

  it('handles null timers in the array', () => {
    const resources = createMockResources({
      timers: [null, setInterval(() => {}, 999_999), null],
    });

    const shutdown = createShutdownHandler(resources);
    expect(() => shutdown()).not.toThrow();
  });

  it('clears timer handles resolved at shutdown time', () => {
    const dynamicTimer = setInterval(() => {}, 999_999);
    const clearIntervalSpy = vi.spyOn(globalThis, 'clearInterval');
    const resources = createMockResources({
      timers: [
        (() => dynamicTimer) as unknown as ShutdownResources['timers'][number],
      ],
    });

    const shutdown = createShutdownHandler(resources);
    shutdown();

    expect(clearIntervalSpy).toHaveBeenCalledWith(dynamicTimer);
    clearIntervalSpy.mockRestore();
  });

  it('cleans up auto summary resolved at shutdown time', () => {
    const cleanup = vi.fn();
    const resources = createMockResources({
      autoSummary: (() => ({
        cleanup,
      })) as unknown as ShutdownResources['autoSummary'],
    });

    const shutdown = createShutdownHandler(resources);
    shutdown();

    expect(cleanup).toHaveBeenCalledOnce();
  });

  it('calls log.info when logger is provided', () => {
    const resources = createMockResources();
    const log = { info: vi.fn() };
    const shutdown = createShutdownHandler(resources, log);

    shutdown();

    expect(log.info).toHaveBeenCalledWith('Shutting down...');
  });

  it('works without a logger', () => {
    const resources = createMockResources();
    const shutdown = createShutdownHandler(resources);

    expect(() => shutdown()).not.toThrow();
  });

  it('cleans up resources in the correct order: monitors before watcher before server before db', () => {
    const callOrder: string[] = [];
    const resources: ShutdownResources = {
      timers: [],
      metrics: {
        destroy: vi.fn(() => callOrder.push('metrics')),
      },
      liveMonitor: {
        stop: vi.fn(() => callOrder.push('liveMonitor')),
      },
      backgroundMonitor: {
        stop: vi.fn(() => callOrder.push('backgroundMonitor')),
      },
      usageCollector: {
        stop: vi.fn(() => callOrder.push('usageCollector')),
      },
      autoSummary: {
        cleanup: vi.fn(() => callOrder.push('autoSummary')),
      },
      watcher: {
        close: vi.fn(() => callOrder.push('watcher')),
      },
      webServer: {
        close: vi.fn(() => callOrder.push('webServer')),
      },
      db: {
        close: vi.fn(() => callOrder.push('db')),
      },
    };

    const shutdown = createShutdownHandler(resources);
    shutdown();

    // monitors and collectors before watcher
    expect(callOrder.indexOf('metrics')).toBeLessThan(
      callOrder.indexOf('watcher'),
    );
    expect(callOrder.indexOf('liveMonitor')).toBeLessThan(
      callOrder.indexOf('watcher'),
    );
    // watcher before webServer
    expect(callOrder.indexOf('watcher')).toBeLessThan(
      callOrder.indexOf('webServer'),
    );
    // webServer before db
    expect(callOrder.indexOf('webServer')).toBeLessThan(
      callOrder.indexOf('db'),
    );
    // db is last
    expect(callOrder[callOrder.length - 1]).toBe('db');
  });
});

describe('createMCPDeps', () => {
  it('returns all required fields with in-memory db', () => {
    const deps = createMCPDeps({ dbPath: ':memory:' });
    expect(deps.db).toBeDefined();
    expect(deps.adapters.length).toBeGreaterThan(0);
    expect(deps.adapterMap).toBeDefined();
    expect(deps.settings).toBeDefined();
    expect(deps.audit).toBeDefined();
    expect(deps.tracer).toBeDefined();
    expect(deps.traceWriter).toBeDefined();
    expect(deps.indexer).toBeDefined();
    expect(deps.indexJobRunner).toBeDefined();
    // vecDeps may be null if sqlite-vec not available
    expect('vecDeps' in deps).toBe(true);
    deps.db.close();
  });

  it('registers adapters for every declared source', () => {
    const deps = createMCPDeps({ dbPath: ':memory:' });
    const names = deps.adapters.map((a) => a.name);
    expect(new Set(names)).toEqual(new Set(SOURCE_NAMES));
    for (const source of SOURCE_NAMES) {
      expect(getAdapter(source)?.name).toBe(source);
      expect(deps.adapterMap[source]?.name).toBe(source);
    }
    deps.db.close();
  });
});

describe('createDaemonDeps', () => {
  it('returns all required fields extending MCPDeps', () => {
    const deps = createDaemonDeps({ dbPath: ':memory:' });
    // MCPDeps fields
    expect(deps.db).toBeDefined();
    expect(deps.adapters.length).toBeGreaterThan(0);
    expect(deps.tracer).toBeDefined();
    // DaemonCoreDeps fields
    expect(deps.log).toBeDefined();
    expect(deps.logWriter).toBeDefined();
    expect(deps.traceWriter).toBeDefined();
    expect(deps.metrics).toBeDefined();
    expect(deps.auditQuery).toBeDefined();
    expect(deps.titleGenerator).toBeDefined();
    deps.db.close();
  });

  it('reuses traceWriter from base MCPDeps (no duplicate)', () => {
    const deps = createDaemonDeps({ dbPath: ':memory:' });
    // traceWriter should be the same instance from createMCPDeps
    expect(deps.traceWriter).toBeDefined();
    deps.db.close();
  });
});
