import { spawnSync } from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const gate = resolve(repoRoot, 'scripts/ci/check-perf-results.py');
const python = process.env.PYTHON3 ?? 'python3';

let workdir: string;
let fixtureRoot: string;

function runGate(
  log: string,
  options: {
    budget?: string;
    maxRsd?: string;
    buildExit?: string;
    testExit?: string;
  } = {},
) {
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
      options.budget ?? '0.100',
      '--max-rsd-percent',
      options.maxRsd ?? '10.0',
      '--build-exit-code',
      options.buildExit ?? '0',
      '--test-exit-code',
      options.testExit ?? '0',
      '--fixture-root',
      fixtureRoot,
      '--expected-fixture-count',
      '2',
      '--baseline-id',
      'test-baseline',
      '--baseline-average-seconds',
      '0.050',
      '--git-sha',
      'deadbeef',
      '--runner-name',
      'test-runner',
      '--runner-os',
      'macOS',
      '--runner-arch',
      'ARM64',
      '--xcode-version',
      'Xcode 26.6',
      '--sdk-version',
      '26.5',
    ],
    { encoding: 'utf8' },
  );
  return { result, resultPath };
}

describe('performance result gate', () => {
  beforeEach(() => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-perf-gate-'));
    fixtureRoot = join(workdir, 'fixtures');
    mkdirSync(fixtureRoot);
    writeFileSync(join(fixtureRoot, 'one.json'), '{"id":1}\n');
    writeFileSync(join(fixtureRoot, 'two.jsonl'), '{"id":2}\n');
  });

  afterEach(() => {
    rmSync(workdir, { recursive: true, force: true });
  });

  it('records and accepts a measurement within the budget', () => {
    const { result, resultPath } = runGate(
      'ENGRAM_PERF_WORKLOAD fixtures=2 bytes=18 indexed=2\n' +
        'Test measured [Clock Monotonic Time, s] average: 0.054, relative standard deviation: 5.079%\n',
    );
    expect(result.status).toBe(0);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'passed',
      max_average_seconds: 0.1,
      max_relative_standard_deviation_percent: 10,
      observed_max_average_seconds: 0.054,
      passed: true,
      baseline: { id: 'test-baseline', average_seconds: 0.05 },
      environment: { runner_name: 'test-runner', git_sha: 'deadbeef' },
      workload: { fixture_count: 2, fixture_bytes: 18, indexed_count: 2 },
    });
  });

  it('writes evidence and fails when the budget is exceeded', () => {
    const { result, resultPath } = runGate(
      'ENGRAM_PERF_WORKLOAD fixtures=2 bytes=18 indexed=2\n' +
        'Test measured [Clock Monotonic Time, s] average: 0.101, relative standard deviation: 1.000%\n',
    );
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('exceeds budget');
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'regression',
      observed_max_average_seconds: 0.101,
      passed: false,
    });
  });

  it('marks a high-variance sample noisy', () => {
    const { result, resultPath } = runGate(
      'ENGRAM_PERF_WORKLOAD fixtures=2 bytes=18 indexed=2\n' +
        'Test measured [Clock Monotonic Time, s] average: 0.054, relative standard deviation: 10.001%\n',
    );
    expect(result.status).toBe(1);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'noisy',
      passed: false,
    });
  });

  it('does not report pass when XCTest exits nonzero after measuring', () => {
    const { result, resultPath } = runGate(
      'ENGRAM_PERF_WORKLOAD fixtures=2 bytes=18 indexed=2\n' +
        'Test measured [Clock Monotonic Time, s] average: 0.054, relative standard deviation: 1.000%\n',
      { testExit: '1' },
    );
    expect(result.status).toBe(1);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'test_failure',
      test_exit_code: 1,
      passed: false,
    });
  });

  it('classifies known test-runner connection failures as infrastructure', () => {
    const { result, resultPath } = runGate(
      'Timed out while waiting for connection to test runner\n',
      { testExit: '65' },
    );
    expect(result.status).toBe(1);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'infrastructure_failure',
      passed: false,
    });
  });

  it('fails when the indexed workload is incomplete', () => {
    const { result, resultPath } = runGate(
      'ENGRAM_PERF_WORKLOAD fixtures=2 bytes=18 indexed=1\n' +
        'Test measured [Clock Monotonic Time, s] average: 0.020, relative standard deviation: 1.000%\n',
    );
    expect(result.status).toBe(1);
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'test_failure',
      passed: false,
    });
  });

  it('fails closed when XCTest emits no parseable measurement', () => {
    const { result, resultPath } = runGate('** TEST SUCCEEDED **\n');
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('No XCTest measured lines found');
    expect(JSON.parse(readFileSync(resultPath, 'utf8'))).toMatchObject({
      status: 'test_failure',
      passed: false,
    });
  });
});
