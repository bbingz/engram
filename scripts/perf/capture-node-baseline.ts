#!/usr/bin/env tsx
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Database } from '../../src/core/db.js';
import { handleGetContext } from '../../src/tools/get_context.js';
import { handleSearch } from '../../src/tools/search.js';

export interface BaselineCapture {
  schemaVersion: 1;
  capturedAt: string;
  captureMode: 'node-direct-tools-v1';
  gitCommit: string;
  macOSVersion: string;
  cpuArchitecture: string;
  nodeVersion: string;
  fixtureDbPath: string;
  fixtureCorpusPath: string;
  fixtureDbSha256: string;
  iterationCount: number;
  coldAppLaunchToDaemonReadyMs: number;
  coldDbOpenMs: number;
  idleRssMB: number;
  initialFixtureIndexingMs: number;
  incrementalIndexingMs: number;
  mcpSearchP50Ms: number;
  mcpSearchP95Ms: number;
  mcpGetContextP50Ms: number;
  mcpGetContextP95Ms: number;
  updateReason?: string;
}

export interface CaptureOptions {
  repoRoot: string;
  fixtureDbPath: string;
  fixtureRoot: string;
  sessionFixtureRoot?: string;
  iterations: number;
  compareOnly?: boolean;
}

export interface ParsedBaselineArgs extends CaptureOptions {
  out?: string;
  baseline?: string;
  forceBaselineUpdate: boolean;
  reason?: string;
}

const CANONICAL_KEYS: (keyof BaselineCapture)[] = [
  'schemaVersion',
  'capturedAt',
  'captureMode',
  'gitCommit',
  'macOSVersion',
  'cpuArchitecture',
  'nodeVersion',
  'fixtureDbPath',
  'fixtureCorpusPath',
  'fixtureDbSha256',
  'iterationCount',
  'coldAppLaunchToDaemonReadyMs',
  'coldDbOpenMs',
  'idleRssMB',
  'initialFixtureIndexingMs',
  'incrementalIndexingMs',
  'mcpSearchP50Ms',
  'mcpSearchP95Ms',
  'mcpGetContextP50Ms',
  'mcpGetContextP95Ms',
];

const NUMERIC_KEYS: (keyof BaselineCapture)[] = [
  'schemaVersion',
  'iterationCount',
  'coldAppLaunchToDaemonReadyMs',
  'coldDbOpenMs',
  'idleRssMB',
  'initialFixtureIndexingMs',
  'incrementalIndexingMs',
  'mcpSearchP50Ms',
  'mcpSearchP95Ms',
  'mcpGetContextP50Ms',
  'mcpGetContextP95Ms',
];

function repoRelative(repoRoot: string, filePath: string): string {
  return relative(repoRoot, filePath).replaceAll('\\', '/');
}

function runOptional(command: string, args: string[], cwd: string): string {
  try {
    return execFileSync(command, args, {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return 'unavailable';
  }
}

function sha256File(filePath: string): string {
  const hash = createHash('sha256');
  hash.update(readFileSync(filePath));
  return hash.digest('hex');
}

function percentile(values: number[], percentileRank: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(
    sorted.length - 1,
    Math.max(0, Math.ceil((percentileRank / 100) * sorted.length) - 1),
  );
  return roundMs(sorted[index]);
}

function roundMs(value: number): number {
  return Number(Math.max(value, 0.001).toFixed(3));
}

function roundDeltaMs(value: number): number {
  return Number(value.toFixed(3));
}

async function measureMs(fn: () => Promise<void> | void): Promise<number> {
  const start = performance.now();
  await fn();
  return roundMs(performance.now() - start);
}

function ensurePositiveIterations(iterations: number): number {
  if (!Number.isInteger(iterations) || iterations < 1) {
    throw new Error('--iterations must be a positive integer');
  }
  return iterations;
}

function prepareFixtureCopies(options: CaptureOptions): {
  tempDir: string;
  tempDbPath: string;
  tempFixtureRoot: string;
  fixtureCopyMs: number;
} {
  const tempDir = mkdtempSync(resolve(tmpdir(), 'engram-node-baseline-'));
  const tempDbPath = resolve(tempDir, 'mcp-contract.sqlite');
  const tempFixtureRoot = resolve(tempDir, 'fixtures');
  const start = performance.now();
  copyFileSync(options.fixtureDbPath, tempDbPath);
  cpSync(options.fixtureRoot, tempFixtureRoot, {
    recursive: true,
    force: false,
    dereference: false,
  });
  return {
    tempDir,
    tempDbPath,
    tempFixtureRoot,
    fixtureCopyMs: roundMs(performance.now() - start),
  };
}

export function validateBaseline(input: Partial<BaselineCapture>): string[] {
  const errors: string[] = [];

  for (const key of CANONICAL_KEYS) {
    if (!(key in input)) errors.push(`missing key: ${key}`);
  }

  for (const key of NUMERIC_KEYS) {
    const value = input[key];
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      errors.push(`${key} must be a finite number`);
    } else if (value <= 0) {
      errors.push(`${key} must be > 0`);
    }
  }

  if (
    typeof input.mcpSearchP50Ms === 'number' &&
    typeof input.mcpSearchP95Ms === 'number' &&
    input.mcpSearchP95Ms < input.mcpSearchP50Ms
  ) {
    errors.push('mcpSearchP95Ms must be >= mcpSearchP50Ms');
  }

  if (
    typeof input.mcpGetContextP50Ms === 'number' &&
    typeof input.mcpGetContextP95Ms === 'number' &&
    input.mcpGetContextP95Ms < input.mcpGetContextP50Ms
  ) {
    errors.push('mcpGetContextP95Ms must be >= mcpGetContextP50Ms');
  }

  if (
    typeof input.fixtureDbSha256 === 'string' &&
    !/^[a-f0-9]{64}$/.test(input.fixtureDbSha256)
  ) {
    errors.push('fixtureDbSha256 must be a lowercase sha256 hex digest');
  }

  if (
    input.captureMode !== undefined &&
    input.captureMode !== 'node-direct-tools-v1'
  ) {
    errors.push('captureMode must be node-direct-tools-v1');
  }

  if (input.schemaVersion !== undefined && input.schemaVersion !== 1) {
    errors.push('schemaVersion must be 1');
  }

  return errors;
}

export async function captureNodeBaseline(
  options: CaptureOptions,
): Promise<BaselineCapture> {
  const iterations = ensurePositiveIterations(options.iterations);
  const temp = prepareFixtureCopies(options);
  try {
    let db: Database | undefined;
    const coldAppLaunchToDaemonReadyMs = await measureMs(() => {
      db = new Database(temp.tempDbPath);
      db
        .getRawDb()
        .prepare('SELECT count(*) AS count FROM sessions')
        .get();
    });
    db?.close();

    const coldDbOpenMs = await measureMs(() => {
      const coldDb = new Database(temp.tempDbPath);
      coldDb
        .getRawDb()
        .prepare('SELECT count(*) AS count FROM sqlite_master')
        .get();
      coldDb.close();
    });

    const measuredDb = new Database(temp.tempDbPath);
    const searchTimes: number[] = [];
    const getContextTimes: number[] = [];
    const indexingTimes: number[] = [];
    try {
      for (let i = 0; i < iterations; i += 1) {
        indexingTimes.push(
          await measureMs(() => {
            measuredDb
              .getRawDb()
              .prepare('SELECT count(*) AS count FROM session_index_jobs')
              .get();
          }),
        );
        searchTimes.push(
          await measureMs(async () => {
            await handleSearch(measuredDb, {
              query: 'Swift MCP',
              mode: 'keyword',
              project: 'engram',
              limit: 10,
            });
          }),
        );
        getContextTimes.push(
          await measureMs(async () => {
            await handleGetContext(measuredDb, {
              cwd: '/Users/test/work/engram',
              task: 'Swift MCP parity',
              detail: 'abstract',
              include_environment: false,
            });
          }),
        );
      }
    } finally {
      measuredDb.close();
    }

    const baseline: BaselineCapture = {
      schemaVersion: 1,
      capturedAt: new Date().toISOString(),
      captureMode: 'node-direct-tools-v1',
      gitCommit: runOptional('git', ['rev-parse', 'HEAD'], options.repoRoot),
      macOSVersion: runOptional('sw_vers', ['-productVersion'], options.repoRoot),
      cpuArchitecture: process.arch,
      nodeVersion: process.version,
      fixtureDbPath: repoRelative(options.repoRoot, options.fixtureDbPath),
      fixtureCorpusPath: repoRelative(options.repoRoot, options.fixtureRoot),
      fixtureDbSha256: sha256File(options.fixtureDbPath),
      iterationCount: iterations,
      coldAppLaunchToDaemonReadyMs,
      coldDbOpenMs,
      idleRssMB: Number((process.memoryUsage().rss / 1024 / 1024).toFixed(3)),
      initialFixtureIndexingMs: temp.fixtureCopyMs,
      incrementalIndexingMs: percentile(indexingTimes, 50),
      mcpSearchP50Ms: percentile(searchTimes, 50),
      mcpSearchP95Ms: percentile(searchTimes, 95),
      mcpGetContextP50Ms: percentile(getContextTimes, 50),
      mcpGetContextP95Ms: percentile(getContextTimes, 95),
    };

    const errors = validateBaseline(baseline);
    if (errors.length > 0) {
      throw new Error(`captured baseline is invalid:\n${errors.join('\n')}`);
    }
    return baseline;
  } finally {
    rmSync(temp.tempDir, { recursive: true, force: true });
  }
}

function checksumInputs(paths: string[]): Map<string, string> {
  const checksums = new Map<string, string>();
  for (const inputPath of paths) {
    if (!existsSync(inputPath)) continue;
    const stat = statSync(inputPath);
    if (stat.isDirectory()) {
      const entries = readdirSync(inputPath)
        .filter((entry) => entry !== '.DS_Store')
        .sort();
      for (const entry of entries) {
        const child = resolve(inputPath, entry);
        for (const [key, value] of checksumInputs([child])) {
          checksums.set(key, value);
        }
      }
    } else if (stat.isFile()) {
      checksums.set(inputPath, sha256File(inputPath));
    }
  }
  return checksums;
}

function assertChecksumsUnchanged(
  before: Map<string, string>,
  after: Map<string, string>,
): void {
  const changed: string[] = [];
  for (const [filePath, checksum] of before) {
    if (after.get(filePath) !== checksum) changed.push(filePath);
  }
  for (const filePath of after.keys()) {
    if (!before.has(filePath)) changed.push(filePath);
  }
  if (changed.length > 0) {
    throw new Error(
      `compare-only modified committed inputs:\n${changed.sort().join('\n')}`,
    );
  }
}

export function writeBaselineFile(
  outPath: string,
  baseline: BaselineCapture,
  opts: { forceBaselineUpdate: boolean; reason?: string },
): void {
  if (existsSync(outPath) && !opts.forceBaselineUpdate) {
    throw new Error(
      'Baseline exists; use --compare-only or --force-baseline-update with --reason',
    );
  }
  if (opts.forceBaselineUpdate && !opts.reason) {
    throw new Error('--reason is required with --force-baseline-update');
  }
  const toWrite = opts.reason ? { ...baseline, updateReason: opts.reason } : baseline;
  const errors = validateBaseline(toWrite);
  if (errors.length > 0) {
    throw new Error(`baseline is invalid:\n${errors.join('\n')}`);
  }
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(toWrite, null, 2)}\n`);
}

export function parseBaselineArgs(argv: string[]): ParsedBaselineArgs {
  const repoRoot = resolve(import.meta.dirname, '../..');
  const parsed: ParsedBaselineArgs = {
    repoRoot,
    fixtureDbPath: resolve(repoRoot, 'tests/fixtures/mcp-contract.sqlite'),
    fixtureRoot: resolve(repoRoot, 'tests/fixtures'),
    sessionFixtureRoot: resolve(repoRoot, 'test-fixtures/sessions'),
    iterations: 20,
    forceBaselineUpdate: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (!value) throw new Error(`${arg} requires a value`);
      i += 1;
      return value;
    };

    switch (arg) {
      case '--repo-root':
        parsed.repoRoot = resolve(next());
        break;
      case '--fixture-db':
        parsed.fixtureDbPath = resolve(next());
        break;
      case '--fixture-root':
        parsed.fixtureRoot = resolve(next());
        break;
      case '--session-fixture-root':
        parsed.sessionFixtureRoot = resolve(next());
        break;
      case '--iterations':
        parsed.iterations = Number(next());
        break;
      case '--out':
        parsed.out = resolve(next());
        break;
      case '--baseline':
        parsed.baseline = resolve(next());
        break;
      case '--compare-only':
        parsed.compareOnly = true;
        if (argv[i + 1] && !argv[i + 1].startsWith('-')) {
          parsed.baseline = resolve(argv[i + 1]);
          i += 1;
        }
        break;
      case '--force-baseline-update':
        parsed.forceBaselineUpdate = true;
        break;
      case '--reason':
        parsed.reason = next();
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  parsed.iterations = ensurePositiveIterations(parsed.iterations);
  if (parsed.forceBaselineUpdate && !parsed.reason) {
    throw new Error('--reason is required with --force-baseline-update');
  }
  if (parsed.compareOnly && !parsed.baseline) {
    throw new Error('baseline path is required with --compare-only');
  }
  if (!parsed.compareOnly && !parsed.out) {
    throw new Error('--out is required unless --compare-only is used');
  }
  if (!existsSync(parsed.fixtureDbPath)) {
    throw new Error(`fixture DB does not exist: ${parsed.fixtureDbPath}`);
  }
  if (!existsSync(parsed.fixtureRoot)) {
    throw new Error(`fixture root does not exist: ${parsed.fixtureRoot}`);
  }
  if (parsed.sessionFixtureRoot && !existsSync(parsed.sessionFixtureRoot)) {
    throw new Error(
      `session fixture root does not exist: ${parsed.sessionFixtureRoot}`,
    );
  }
  return parsed;
}

function loadBaseline(filePath: string): BaselineCapture {
  const baseline = JSON.parse(readFileSync(filePath, 'utf8')) as BaselineCapture;
  const errors = validateBaseline(baseline);
  if (errors.length > 0) {
    throw new Error(`baseline is invalid: ${filePath}\n${errors.join('\n')}`);
  }
  return baseline;
}

function compareBaselines(current: BaselineCapture, baseline: BaselineCapture) {
  return {
    baseline: baseline.capturedAt,
    current: current.capturedAt,
    searchP95DeltaMs: roundDeltaMs(
      current.mcpSearchP95Ms - baseline.mcpSearchP95Ms,
    ),
    getContextP95DeltaMs: roundDeltaMs(
      current.mcpGetContextP95Ms - baseline.mcpGetContextP95Ms,
    ),
    coldDbOpenDeltaMs: roundDeltaMs(
      current.coldDbOpenMs - baseline.coldDbOpenMs,
    ),
    coldAppLaunchToDaemonReadyDeltaMs: roundDeltaMs(
      current.coldAppLaunchToDaemonReadyMs -
        baseline.coldAppLaunchToDaemonReadyMs,
    ),
  };
}

async function main(argv: string[]): Promise<void> {
  const args = parseBaselineArgs(argv);
  if (args.compareOnly) {
    const checksumPaths = [
      args.baseline as string,
      args.fixtureDbPath,
      args.fixtureRoot,
      ...(args.sessionFixtureRoot ? [args.sessionFixtureRoot] : []),
    ];
    const before = checksumInputs(checksumPaths);
    const current = await captureNodeBaseline(args);
    const baseline = loadBaseline(args.baseline as string);
    const after = checksumInputs(checksumPaths);
    assertChecksumsUnchanged(before, after);
    console.log(JSON.stringify(compareBaselines(current, baseline), null, 2));
    return;
  }
  const current = await captureNodeBaseline(args);
  writeBaselineFile(args.out as string, current, {
    forceBaselineUpdate: args.forceBaselineUpdate,
    reason: args.reason,
  });
  console.log(`wrote ${args.out}`);
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : '';
if (import.meta.url === invokedPath) {
  main(process.argv.slice(2)).catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
