import {
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { isAbsolute, join, relative, resolve } from 'node:path';
import { generateAdapterParityFixtures } from './gen-adapter-parity-fixtures.js';

type SupportedFixtureSource =
  | 'antigravity'
  | 'claude-code'
  | 'cline'
  | 'codex'
  | 'commandcode'
  | 'copilot'
  | 'cursor'
  | 'gemini-cli'
  | 'iflow'
  | 'kimi'
  | 'opencode'
  | 'qoder'
  | 'qwen'
  | 'vscode'
  | 'windsurf';

const repoRoot = resolve(import.meta.dirname, '..');
const supportedSources = [
  'antigravity',
  'claude-code',
  'cline',
  'codex',
  'commandcode',
  'copilot',
  'cursor',
  'gemini-cli',
  'iflow',
  'kimi',
  'opencode',
  'qoder',
  'qwen',
  'vscode',
  'windsurf',
] as const satisfies readonly SupportedFixtureSource[];

const malformedCategories = [
  'invalidUtf8',
  'truncatedJSON',
  'truncatedJSONL',
  'malformedJSON',
  'malformedToolCall',
  'deeplyNestedRecord',
  'fileTooLarge',
  'messageLimitExceeded',
  'fileModifiedDuringParse',
] as const;

const requiredFixtureKeys = [
  'source',
  'inputPath',
  'locator',
  'sessionInfo',
  'messages',
  'toolCalls',
  'usageTotals',
  'fileToolCounts',
  'projectFields',
  'insightFields',
  'searchIndexFields',
  'statsFields',
  'failure',
  'nodeVersion',
  'generatedAtCommit',
] as const;

function parseArgs(argv = process.argv.slice(2)): { fixtureRoot: string } {
  const fixtureRootIndex = argv.indexOf('--fixture-root');
  return {
    fixtureRoot:
      fixtureRootIndex >= 0
        ? resolve(argv[fixtureRootIndex + 1])
        : join(repoRoot, 'tests/fixtures/adapter-parity'),
  };
}

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (!value || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) {
    const nested = (value as Record<string, unknown>)[key];
    out[key] =
      key === 'generatedAtCommit' || key === 'nodeVersion'
        ? '<volatile>'
        : sortJson(nested);
  }
  return out;
}

function stableJson(value: unknown): string {
  return `${JSON.stringify(sortJson(value), null, 2)}\n`;
}

function walkFiles(root: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(path));
    if (entry.isFile()) out.push(path);
  }
  return out;
}

type PhysicalFixturePathResult =
  | { path: string }
  | { failure: 'missing' | 'escaped' };

function physicalFixturePath(
  fixtureRoot: string,
  value: unknown,
): PhysicalFixturePathResult {
  if (typeof value !== 'string' || value.length === 0) {
    return { failure: 'missing' };
  }
  const physical = value.split('?')[0]?.split('::')[0];
  if (!physical) return { failure: 'missing' };

  const resolvedRoot = resolve(fixtureRoot);
  const resolvedPath = resolve(resolvedRoot, physical);
  const relativePath = relative(resolvedRoot, resolvedPath);
  if (
    relativePath === '' ||
    relativePath.startsWith('..') ||
    isAbsolute(relativePath)
  ) {
    return { failure: 'escaped' };
  }
  return { path: resolvedPath };
}

function assertBatchSizes(fixtureRoot: string, failures: string[]): void {
  const batchPath = join(fixtureRoot, 'batch-sizes.json');
  let batch: Record<string, unknown>;
  try {
    batch = readJson(batchPath);
  } catch {
    failures.push('missing batch-sizes.json');
    return;
  }
  if (batch.watchWriteStabilityMs !== 2000) {
    failures.push('batch-sizes.json watchWriteStabilityMs must be 2000');
  }
  if (batch.watchWriteStabilityPollMs !== 500) {
    failures.push('batch-sizes.json watchWriteStabilityPollMs must be 500');
  }
  if (batch.startupParentBackfillLimit !== 500) {
    failures.push('batch-sizes.json startupParentBackfillLimit must be 500');
  }
}

function assertMalformedManifest(
  fixtureRoot: string,
  failures: string[],
): void {
  const manifestPath = resolve(
    fixtureRoot,
    '..',
    'adapter-malformed',
    'manifest.json',
  );
  let manifest: Record<string, unknown>;
  try {
    manifest = readJson(manifestPath);
  } catch {
    failures.push('missing malformed manifest');
    return;
  }
  const categories = manifest.categories as Record<string, unknown> | undefined;
  for (const category of malformedCategories) {
    if (!categories?.[category]) {
      failures.push(`missing malformed category: ${category}`);
    }
  }
}

function comparableJsonFiles(fixtureRoot: string): string[] {
  const roots = [fixtureRoot, resolve(fixtureRoot, '..', 'adapter-malformed')];
  const files: string[] = [];
  for (const root of roots) {
    for (const file of walkFiles(root)) {
      if (file.endsWith('.json')) files.push(file);
    }
  }
  return files.sort();
}

async function assertRegeneratedFixturesMatch(
  fixtureRoot: string,
  failures: string[],
): Promise<void> {
  const tempRoot = mkdtempSync(join(tmpdir(), 'adapter-parity-check-'));
  const tempFixtureRoot = join(tempRoot, 'adapter-parity');
  try {
    await generateAdapterParityFixtures(tempFixtureRoot);
    const committedFiles = comparableJsonFiles(fixtureRoot).map((file) =>
      relative(resolve(fixtureRoot, '..'), file),
    );
    const generatedFiles = comparableJsonFiles(tempFixtureRoot).map((file) =>
      relative(resolve(tempFixtureRoot, '..'), file),
    );
    const expected = new Set(committedFiles);
    const actual = new Set(generatedFiles);
    for (const file of committedFiles) {
      if (!actual.has(file)) {
        failures.push(`regenerated fixtures missing committed file: ${file}`);
      }
    }
    for (const file of generatedFiles) {
      if (!expected.has(file)) {
        failures.push(
          `regenerated fixtures produced uncommitted file: ${file}`,
        );
      }
    }
    for (const file of committedFiles) {
      if (!actual.has(file)) continue;
      const committedPath = join(resolve(fixtureRoot, '..'), file);
      const generatedPath = join(resolve(tempFixtureRoot, '..'), file);
      const committed = stableJson(
        JSON.parse(readFileSync(committedPath, 'utf8')),
      );
      const generated = stableJson(
        JSON.parse(readFileSync(generatedPath, 'utf8')),
      );
      if (committed !== generated) {
        failures.push(`fixture stale versus generator: ${file}`);
      }
    }
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
}

export function checkAdapterParityFixtures(fixtureRoot: string): string[] {
  const failures: string[] = [];
  for (const source of supportedSources) {
    const expectedPath = join(fixtureRoot, source, 'success.expected.json');
    let fixture: Record<string, unknown>;
    try {
      fixture = readJson(expectedPath);
    } catch {
      failures.push(`missing success fixture: ${source}`);
      continue;
    }
    for (const key of requiredFixtureKeys) {
      if (!(key in fixture)) failures.push(`${source} missing key: ${key}`);
    }
    if (fixture.source !== source) {
      failures.push(`${source} fixture source mismatch`);
    }
    const checkedPhysicalPaths = new Set<string>();
    for (const key of ['inputPath', 'locator']) {
      const physicalPath = physicalFixturePath(fixtureRoot, fixture[key]);
      if ('failure' in physicalPath) {
        if (physicalPath.failure === 'escaped') {
          failures.push(`${source} fixture path escapes fixture root: ${key}`);
          continue;
        }
        failures.push(`${source} missing physical fixture path: ${key}`);
        continue;
      }
      if (checkedPhysicalPaths.has(physicalPath.path)) continue;
      checkedPhysicalPaths.add(physicalPath.path);
      try {
        statSync(physicalPath.path);
      } catch {
        failures.push(`${source} missing fixture input file: ${key}`);
      }
    }
    for (const key of [
      'projectFields',
      'insightFields',
      'searchIndexFields',
      'statsFields',
    ]) {
      const value = fixture[key];
      if (!value || typeof value !== 'object') {
        failures.push(`${source} missing parity field object: ${key}`);
      }
    }
  }

  assertBatchSizes(fixtureRoot, failures);
  assertMalformedManifest(fixtureRoot, failures);

  try {
    for (const file of walkFiles(resolve(fixtureRoot, '..'))) {
      const size = statSync(file).size;
      if (size > 5 * 1024 * 1024) {
        failures.push(`fixture exceeds 5 MB: ${relative(repoRoot, file)}`);
      }
    }
  } catch {
    failures.push(`cannot scan fixture root: ${fixtureRoot}`);
  }

  return failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { fixtureRoot } = parseArgs();
  const failures = checkAdapterParityFixtures(fixtureRoot);
  await assertRegeneratedFixturesMatch(fixtureRoot, failures);
  if (failures.length > 0) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
  console.log('adapter parity fixtures ok');
}
