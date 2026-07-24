import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const shimPath = resolve(repoRoot, 'macos/Engram/Support/PerfSignpost.swift');

/**
 * B-slice-3 regression guard (row 16 / build-provenance-perf):
 * Release must ship a signature-identical no-op for `enum Perf`, and the
 * stall monitor must stay DEBUG-only behind ENGRAM_PERF_MONITOR (not the
 * CI ENGRAM_PERF indexer flag). Guards the as-main 838c7396 Release-break.
 */
describe('PerfSignpost DEBUG/Release shim', () => {
  const source = readFileSync(shimPath, 'utf8');

  it('contains both #if DEBUG and #else Release branches', () => {
    expect(source).toContain('#if DEBUG');
    expect(source).toContain('#else');
    expect(source).toContain('#endif');
  });

  it('keeps MainThreadStallMonitor inside the DEBUG region only', () => {
    const debugIdx = source.indexOf('#if DEBUG');
    const elseIdx = source.indexOf('#else');
    const monitorIdx = source.indexOf('MainThreadStallMonitor');
    expect(debugIdx).toBeGreaterThan(-1);
    expect(elseIdx).toBeGreaterThan(debugIdx);
    expect(monitorIdx).toBeGreaterThan(debugIdx);
    expect(monitorIdx).toBeLessThan(elseIdx);
    // Must not reappear after #else.
    expect(source.indexOf('MainThreadStallMonitor', elseIdx)).toBe(-1);
  });

  it('gates the stall monitor on ENGRAM_PERF_MONITOR, not ENGRAM_PERF', () => {
    expect(source).toContain('ENGRAM_PERF_MONITOR');
    // The stall gate string must not be the bare CI indexer flag.
    const envChecks = [
      ...source.matchAll(/environment\["([^"]+)"\]/g),
      ...source.matchAll(/ProcessInfo\.processInfo\.environment\["([^"]+)"\]/g),
    ].map((m) => m[1]);
    expect(envChecks).toContain('ENGRAM_PERF_MONITOR');
    expect(envChecks).not.toContain('ENGRAM_PERF');
  });

  it('uses the Instruments-filterable com.engram.perf subsystem', () => {
    expect(source).toContain('com.engram.perf');
  });
});
