import {
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  type BaselineCapture,
  captureNodeBaseline,
  parseBaselineArgs,
  validateBaseline,
  writeBaselineFile,
} from '../../scripts/perf/capture-node-baseline.js';

const repoRoot = resolve(import.meta.dirname, '../..');
const fixtureDbPath = resolve(repoRoot, 'tests/fixtures/mcp-contract.sqlite');
const fixtureRoot = resolve(repoRoot, 'tests/fixtures');

function makeBaseline(
  overrides: Partial<BaselineCapture> = {},
): BaselineCapture {
  return {
    schemaVersion: 1,
    capturedAt: '2026-04-23T00:00:00.000Z',
    captureMode: 'node-direct-tools-v1',
    gitCommit: 'test-commit',
    macOSVersion: 'test-macos',
    cpuArchitecture: 'arm64',
    nodeVersion: 'v20.0.0',
    fixtureDbPath: 'tests/fixtures/mcp-contract.sqlite',
    fixtureCorpusPath: 'tests/fixtures',
    fixtureDbSha256:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    iterationCount: 5,
    coldAppLaunchToDaemonReadyMs: 20,
    coldDbOpenMs: 10,
    idleRssMB: 100,
    initialFixtureIndexingMs: 5,
    incrementalIndexingMs: 2,
    mcpSearchP50Ms: 3,
    mcpSearchP95Ms: 4,
    mcpGetContextP50Ms: 6,
    mcpGetContextP95Ms: 8,
    ...overrides,
  };
}

describe('validateBaseline', () => {
  it('accepts a complete canonical baseline', () => {
    expect(validateBaseline(makeBaseline())).toEqual([]);
  });

  it('rejects missing canonical keys', () => {
    const baseline = makeBaseline() as Partial<BaselineCapture>;
    delete baseline.mcpSearchP95Ms;
    expect(validateBaseline(baseline)).toContain('missing key: mcpSearchP95Ms');
  });

  it('rejects non-finite numeric metrics', () => {
    expect(validateBaseline(makeBaseline({ idleRssMB: Number.NaN }))).toContain(
      'idleRssMB must be a finite number',
    );
  });

  it('rejects zero and negative metric values', () => {
    expect(validateBaseline(makeBaseline({ coldDbOpenMs: 0 }))).toContain(
      'coldDbOpenMs must be > 0',
    );
    expect(
      validateBaseline(makeBaseline({ incrementalIndexingMs: -1 })),
    ).toContain('incrementalIndexingMs must be > 0');
  });

  it('rejects percentile ranges where p95 is below p50', () => {
    expect(
      validateBaseline(makeBaseline({ mcpSearchP50Ms: 10, mcpSearchP95Ms: 9 })),
    ).toContain('mcpSearchP95Ms must be >= mcpSearchP50Ms');
  });
});

describe('parseBaselineArgs', () => {
  it('requires an update reason when force-updating a baseline', () => {
    expect(() =>
      parseBaselineArgs([
        '--out',
        '/tmp/baseline.json',
        '--force-baseline-update',
      ]),
    ).toThrow(/--reason is required/);
  });

  it('requires a baseline path for compare-only mode', () => {
    expect(() => parseBaselineArgs(['--compare-only'])).toThrow(
      /baseline path is required/,
    );
  });

  it('accepts the reviewed compare-only positional baseline syntax', () => {
    const args = parseBaselineArgs([
      '--compare-only',
      '/tmp/baseline.json',
      '--fixture-db',
      fixtureDbPath,
      '--fixture-root',
      fixtureRoot,
    ]);

    expect(args.compareOnly).toBe(true);
    expect(args.baseline).toBe('/tmp/baseline.json');
  });
});

describe('writeBaselineFile', () => {
  let tmp: string;

  afterEach(() => {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  });

  it('refuses to overwrite a baseline without force and reason', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-baseline-test-'));
    const out = join(tmp, 'baseline.json');
    writeFileSync(out, '{}');

    expect(() =>
      writeBaselineFile(out, makeBaseline(), {
        forceBaselineUpdate: false,
        reason: undefined,
      }),
    ).toThrow(
      /Baseline exists; use --compare-only or --force-baseline-update with --reason/,
    );
  });

  it('writes stable formatted JSON when force and reason are present', () => {
    tmp = mkdtempSync(join(tmpdir(), 'engram-baseline-test-'));
    const out = join(tmp, 'baseline.json');
    writeFileSync(out, '{}');

    writeBaselineFile(out, makeBaseline(), {
      forceBaselineUpdate: true,
      reason: 'test update',
    });

    const parsed = JSON.parse(readFileSync(out, 'utf8'));
    expect(parsed.updateReason).toBe('test update');
    expect(readFileSync(out, 'utf8')).toMatch(/\n$/);
  });
});

describe('captureNodeBaseline', () => {
  it('measures from temporary fixture copies and leaves source fixtures unchanged', async () => {
    const fixtureStatBefore = statSync(fixtureDbPath).mtimeMs;
    const baseline = await captureNodeBaseline({
      repoRoot,
      fixtureDbPath,
      fixtureRoot,
      iterations: 2,
      compareOnly: true,
    });
    const fixtureStatAfter = statSync(fixtureDbPath).mtimeMs;

    expect(validateBaseline(baseline)).toEqual([]);
    expect(baseline.fixtureDbPath).toBe('tests/fixtures/mcp-contract.sqlite');
    expect(baseline.fixtureCorpusPath).toBe('tests/fixtures');
    expect(baseline.iterationCount).toBe(2);
    expect(baseline.coldAppLaunchToDaemonReadyMs).toBeGreaterThan(0);
    expect(baseline.initialFixtureIndexingMs).toBeGreaterThan(0);
    expect(baseline.incrementalIndexingMs).toBeGreaterThan(0);
    expect(fixtureStatAfter).toBe(fixtureStatBefore);
  });
});
