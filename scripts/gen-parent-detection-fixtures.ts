import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import {
  DETECTION_VERSION,
  isDispatchPattern,
  pickBestCandidate,
  scoreCandidate,
} from '../src/core/parent-detection.js';

const repoRoot = resolve(import.meta.dirname, '..');

function parseArgs(argv = process.argv.slice(2)): { out: string } {
  const outIndex = argv.indexOf('--out');
  return {
    out:
      outIndex >= 0
        ? resolve(argv[outIndex + 1])
        : join(repoRoot, 'tests/fixtures/parent-detection'),
  };
}

function gitCommit(): string {
  try {
    return execFileSync('git', ['rev-parse', '--short', 'HEAD'], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return 'unknown';
  }
}

function sortJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortJson);
  if (!value || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value).sort()) {
    out[key] = sortJson((value as Record<string, unknown>)[key]);
  }
  return out;
}

function stableJson(value: unknown): string {
  return `${JSON.stringify(sortJson(value), null, 2)}\n`;
}

function extractDetectionVersionFromSource(): number {
  const source = readFileSync(
    join(repoRoot, 'src/core/parent-detection.ts'),
    'utf8',
  );
  const match = source.match(/export\s+const\s+DETECTION_VERSION\s*=\s*(\d+)/);
  if (!match) throw new Error('failed to extract DETECTION_VERSION');
  return Number(match[1]);
}

export function generateParentDetectionFixture(out: string): void {
  const extractedVersion = extractDetectionVersionFromSource();
  if (extractedVersion !== DETECTION_VERSION) {
    throw new Error(
      `extracted DETECTION_VERSION ${extractedVersion} does not match runtime ${DETECTION_VERSION}`,
    );
  }

  const dispatchInputs = [
    'Review this repository implementation',
    'What is 2+2?',
    'ok',
    '',
  ];
  const scoreCases = [
    {
      name: 'same-project-active-parent',
      score: scoreCandidate(
        '2026-04-23T10:10:00.000Z',
        '2026-04-23T10:00:00.000Z',
        null,
        'engram',
        'engram',
        '/Users/example/-Code-/engram',
        '/Users/example/-Code-/engram',
      ),
    },
    {
      name: 'agent-before-parent',
      score: scoreCandidate(
        '2026-04-23T09:50:00.000Z',
        '2026-04-23T10:00:00.000Z',
        null,
        'engram',
        'engram',
        '/Users/example/-Code-/engram',
        '/Users/example/-Code-/engram',
      ),
    },
  ];
  const fixture = {
    schemaVersion: 1,
    detectionVersion: extractedVersion,
    sourceFile: 'src/core/parent-detection.ts',
    sourceCommit: gitCommit(),
    dispatchCases: dispatchInputs.map((input) => ({
      input,
      isDispatch: isDispatchPattern(input),
    })),
    scoreCases,
    pickBestCases: [
      {
        input: [
          { parentId: 'parent-a', score: 0.2 },
          { parentId: 'parent-b', score: 0.8 },
        ],
        bestParentId: pickBestCandidate([
          { parentId: 'parent-a', score: 0.2 },
          { parentId: 'parent-b', score: 0.8 },
        ]),
      },
      {
        input: [{ parentId: 'parent-zero', score: 0 }],
        bestParentId: pickBestCandidate([
          { parentId: 'parent-zero', score: 0 },
        ]),
      },
    ],
  };

  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, 'detection-version.json'), stableJson(fixture));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { out } = parseArgs();
  generateParentDetectionFixture(out);
  console.log(`parent detection fixture generated: ${relative(repoRoot, out)}`);
}
