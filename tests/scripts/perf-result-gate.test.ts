import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const gate = resolve(repoRoot, 'scripts/ci/check-perf-results.py');
const python = process.env.PYTHON3 ?? 'python3';

let workdir: string;

function runGate(log: string, budget = '0.250') {
  const logPath = join(workdir, 'perf.log');
  const resultPath = join(workdir, 'perf-results.json');
  writeFileSync(logPath, log);
  const result = spawnSync(
    python,
    [
      gate,
      '--log',
      logPath,
      '--results',
      resultPath,
      '--max-average-seconds',
      budget,
    ],
    { encoding: 'utf8' },
  );
  return { result, resultPath };
}

describe('performance result gate', () => {
  beforeEach(() => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-perf-gate-'));
  });

  afterEach(() => {
    rmSync(workdir, { recursive: true, force: true });
  });

  it('records and accepts a measurement within the budget', () => {
    const { result, resultPath } = runGate(
      'Test measured [Clock Monotonic Time, s] average: 0.145, relative standard deviation: 21.510%\n',
    );
    expect(result.status).toBe(0);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      max_average_seconds: 0.25,
      observed_max_average_seconds: 0.145,
      passed: true,
    });
  });

  it('writes evidence and fails when the budget is exceeded', () => {
    const { result, resultPath } = runGate(
      'Test measured [Clock Monotonic Time, s] average: 0.251, relative standard deviation: 1.000%\n',
    );
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('exceeds budget');
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      observed_max_average_seconds: 0.251,
      passed: false,
    });
  });

  it('fails closed when XCTest emits no parseable measurement', () => {
    const { result } = runGate('** TEST SUCCEEDED **\n');
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('No XCTest measured lines found');
  });
});
