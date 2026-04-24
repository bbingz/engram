import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

type SupportedFixtureSource =
  | 'antigravity'
  | 'claude-code'
  | 'cline'
  | 'codex'
  | 'copilot'
  | 'cursor'
  | 'gemini-cli'
  | 'iflow'
  | 'kimi'
  | 'opencode'
  | 'qwen'
  | 'vscode'
  | 'windsurf';

const repoRoot = resolve(import.meta.dirname, '..');
const supportedSources = [
  'antigravity',
  'claude-code',
  'cline',
  'codex',
  'copilot',
  'cursor',
  'gemini-cli',
  'iflow',
  'kimi',
  'opencode',
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

function walkFiles(root: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(path));
    if (entry.isFile()) out.push(path);
  }
  return out;
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
  if (failures.length > 0) {
    console.error(failures.join('\n'));
    process.exit(1);
  }
  console.log('adapter parity fixtures ok');
}
