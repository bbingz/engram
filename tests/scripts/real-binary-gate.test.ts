import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const gate = resolve(repoRoot, 'scripts/ci/check-real-binary-results.py');
const python = process.env.PYTHON3 ?? 'python3';
const testsDir = resolve(repoRoot, 'macos/EngramServiceCoreTests');
const realSources = [
  join(testsDir, 'CollectorBinaryShadowIntegrationTests.swift'),
  join(testsDir, 'CollectorCLIIntegrationTests.swift'),
];
const browserDemo = 'testRealBinaryHTTPSBrowserDemoWithBoundedHold';

type TestCase = { suite: string; name: string; result: string };

// Independent of the Python parser: XCTestCase classes and their extensions.
function realExpectedTests(): TestCase[] {
  const tests: TestCase[] = [];
  for (const source of realSources) {
    const testClasses = new Set<string>();
    let current: string | null = null;
    for (const line of readFileSync(source, 'utf8').split('\n')) {
      const cls = line.match(/^(?:final )?class (\w+): XCTestCase\b/);
      const ext = line.match(/^extension (\w+)\b/);
      if (cls) {
        current = cls[1];
        testClasses.add(current);
      } else if (ext) {
        current = testClasses.has(ext[1]) ? ext[1] : null;
      } else if (
        /^\S/.test(line) &&
        /\b(class|struct|enum|extension)\b/.test(line)
      ) {
        current = null;
      } else {
        const test = line.match(/^ {4}func (test\w+)\(/);
        if (test && current) {
          tests.push({ suite: current, name: test[1], result: 'Passed' });
        }
      }
    }
  }
  return tests;
}

function xcresult(cases: TestCase[]) {
  const suites = new Map<string, TestCase[]>();
  for (const testCase of cases) {
    suites.set(testCase.suite, [
      ...(suites.get(testCase.suite) ?? []),
      testCase,
    ]);
  }
  return {
    devices: [],
    testNodes: [
      {
        nodeType: 'Test Plan',
        name: 'EngramServiceCore',
        children: [
          {
            nodeType: 'Unit test bundle',
            name: 'EngramServiceCoreTests',
            children: [...suites].map(([suite, members]) => ({
              nodeType: 'Test Suite',
              name: suite,
              children: members.map((member) => ({
                nodeType: 'Test Case',
                name: `${member.name}()`,
                nodeIdentifier: `${suite}/${member.name}()`,
                result: member.result,
                durationInSeconds: 1.5,
                children:
                  member.result === 'Skipped'
                    ? [{ nodeType: 'Failure Message', name: 'skipped' }]
                    : [],
              })),
            })),
          },
        ],
      },
    ],
  };
}

let workdir: string;

function runGate(
  json: unknown,
  options: { exitCode?: string; sources?: string[] } = {},
) {
  const testsJson = join(workdir, 'tests.json');
  writeFileSync(
    testsJson,
    typeof json === 'string' ? json : JSON.stringify(json),
  );
  const binary = join(workdir, 'EngramCollector');
  writeFileSync(binary, 'collector-bytes');
  const receipt = join(workdir, 'receipt.json');
  const summary = join(workdir, 'receipt.md');
  const args = [
    gate,
    '--tests-json',
    testsJson,
    ...(options.sources ?? realSources).flatMap((source) => [
      '--source',
      source,
    ]),
    '--allow-skip',
    browserDemo,
    '--xcodebuild-exit-code',
    options.exitCode ?? '0',
    '--binary',
    `collector=${binary}`,
    '--git-sha',
    'deadbeef',
    '--xcode-version',
    'Xcode 26.4 Build version 17E192 ',
    '--dirty-paths',
    '0',
    '--receipt',
    receipt,
    '--summary',
    summary,
  ];
  const result = spawnSync(python, args, { encoding: 'utf8' });
  return { result, receipt, summary };
}

function withResult(
  cases: TestCase[],
  name: string,
  result: string,
): TestCase[] {
  return cases.map((testCase) =>
    testCase.name === name ? { ...testCase, result } : testCase,
  );
}

describe('real-binary chain result gate', () => {
  beforeEach(() => {
    workdir = mkdtempSync(join(tmpdir(), 'engram-real-binary-gate-'));
  });

  afterEach(() => {
    rmSync(workdir, { recursive: true, force: true });
  });

  it('parses the expected real-binary test set from the Swift sources', () => {
    const expected = realExpectedTests();
    const bySuite = Object.fromEntries(
      [
        'CollectorBinaryShadowIntegrationTests',
        'CollectorLargeHistoryBinaryTests',
        'CollectorCLIIntegrationTests',
      ].map((suite) => [
        suite,
        expected.filter((test) => test.suite === suite).length,
      ]),
    );
    expect(bySuite).toEqual({
      CollectorBinaryShadowIntegrationTests: 32,
      CollectorLargeHistoryBinaryTests: 1,
      CollectorCLIIntegrationTests: 17,
    });
    expect(expected.map((test) => test.name)).toContain(browserDemo);
  });

  it('accepts every test passed plus the opt-in browser skip and writes a receipt', () => {
    const cases = withResult(realExpectedTests(), browserDemo, 'Skipped');
    const { result, receipt, summary } = runGate(xcresult(cases));
    expect(result.stderr).toBe('');
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(
      'REAL_BINARY_GATE result=pass expected=50 passed=49 skipped=1 failed=0',
    );
    const written = JSON.parse(readFileSync(receipt, 'utf8'));
    expect(written).toMatchObject({
      schema: 1,
      result: 'pass',
      git_sha: 'deadbeef',
      dirty_paths: 0,
      xcode_version: 'Xcode 26.4 Build version 17E192',
      expected: 50,
      passed: 49,
      skipped: [`CollectorBinaryShadowIntegrationTests/${browserDemo}`],
      failed: [],
      reasons: [],
    });
    expect(written.binaries.collector.sha256).toBe(
      createHash('sha256').update('collector-bytes').digest('hex'),
    );
    expect(written.tests).toHaveLength(50);
    expect(readFileSync(summary, 'utf8')).toContain(
      'REAL_BINARY_GATE result=pass expected=50 passed=49 skipped=1 failed=0',
    );
  });

  it('accepts the browser demo when it passed', () => {
    const { result } = runGate(xcresult(realExpectedTests()));
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(
      'REAL_BINARY_GATE result=pass expected=50 passed=50 skipped=0 failed=0',
    );
  });

  // Repro for docs/TODO.md W6.2 (real-binary chain in a recorded gate): when
  // the binary-path variables never reach the test runner every real-binary
  // test reports Skipped and xcodebuild still exits 0, which looked green.
  it('rejects a run where every real-binary test skipped (repro)', () => {
    const cases = realExpectedTests().map((testCase) => ({
      ...testCase,
      result: 'Skipped',
    }));
    const { result, receipt } = runGate(xcresult(cases));
    expect(result.status).toBe(1);
    expect(result.stdout.trim()).toBe(
      'REAL_BINARY_GATE result=fail expected=50 passed=0 skipped=50 failed=0',
    );
    expect(result.stderr).toContain(
      'test skipped outside the allow-skip list: CollectorCLIIntegrationTests/',
    );
    expect(JSON.parse(readFileSync(receipt, 'utf8')).result).toBe('fail');
  });

  it('rejects a skipped test outside the allow-skip list', () => {
    const cases = withResult(
      realExpectedTests(),
      'testLargeHistoryIsByteExactOnBothReplicasAndCompleteAcrossWebPages',
      'Skipped',
    );
    const { result } = runGate(xcresult(cases));
    expect(result.status).toBe(1);
    expect(result.stderr).toContain(
      'test skipped outside the allow-skip list: CollectorLargeHistoryBinaryTests/testLargeHistoryIsByteExactOnBothReplicasAndCompleteAcrossWebPages',
    );
  });

  it('rejects a failed test and a nonzero xcodebuild exit code', () => {
    const failed = withResult(
      realExpectedTests(),
      'testRealPiNineMiBMessageReachesBothReplicasAndHQWebIPC',
      'Failed',
    );
    const failedRun = runGate(xcresult(failed), { exitCode: '65' });
    expect(failedRun.result.status).toBe(1);
    expect(failedRun.result.stdout).toContain('result=fail');
    expect(failedRun.result.stdout).toContain('failed=1');
    expect(failedRun.result.stderr).toContain(
      "test result 'Failed': CollectorBinaryShadowIntegrationTests/testRealPiNineMiBMessageReachesBothReplicasAndHQWebIPC",
    );

    const exitOnly = runGate(xcresult(realExpectedTests()), {
      exitCode: '65',
    });
    expect(exitOnly.result.status).toBe(1);
    expect(exitOnly.result.stderr).toContain(
      'xcodebuild test exited with code 65',
    );
  });

  it('rejects missing or unexpected tests', () => {
    const expected = realExpectedTests();
    const missing = runGate(
      xcresult(
        expected.filter(
          (test) => test.suite !== 'CollectorCLIIntegrationTests',
        ),
      ),
    );
    expect(missing.result.status).toBe(1);
    expect(missing.result.stderr).toContain(
      'expected test did not run: CollectorCLIIntegrationTests/',
    );

    const extra = runGate(
      xcresult([
        ...expected,
        {
          suite: 'CollectorBinaryPerformanceTests',
          name: 'testSomethingElse',
          result: 'Passed',
        },
      ]),
    );
    expect(extra.result.status).toBe(1);
    expect(extra.result.stderr).toContain(
      'unexpected test ran: CollectorBinaryPerformanceTests/testSomethingElse',
    );

    const source = join(workdir, 'Inline.swift');
    writeFileSync(
      source,
      [
        'final class InlineTests: XCTestCase {',
        '    func testRenamed() async throws {}',
        '}',
        'private struct Helper {',
        '    func testHelperIsNotATest() {}',
        '}',
        'extension InlineTests {',
        '    func testInExtension() {}',
        '}',
        '',
      ].join('\n'),
    );
    const renamed = runGate(
      xcresult([
        { suite: 'InlineTests', name: 'testOldName', result: 'Passed' },
        { suite: 'InlineTests', name: 'testInExtension', result: 'Passed' },
      ]),
      { sources: [source] },
    );
    expect(renamed.result.status).toBe(1);
    expect(renamed.result.stdout.trim()).toBe(
      'REAL_BINARY_GATE result=fail expected=2 passed=2 skipped=0 failed=0',
    );
    expect(renamed.result.stderr).toContain(
      'expected test did not run: InlineTests/testRenamed',
    );
    expect(renamed.result.stderr).toContain(
      'unexpected test ran: InlineTests/testOldName',
    );
    expect(renamed.result.stderr).not.toContain('testHelperIsNotATest');
  });

  it('rejects an empty or malformed result JSON', () => {
    const empty = runGate('');
    expect(empty.result.status).toBe(1);
    expect(empty.result.stderr).toContain('cannot parse xcresult tests JSON');

    const noNodes = runGate({ testNodes: [] });
    expect(noNodes.result.status).toBe(1);
    expect(noNodes.result.stderr).toContain(
      'xcresult contains zero Test Case nodes',
    );

    const wrongShape = runGate({ devices: [] });
    expect(wrongShape.result.status).toBe(1);
    expect(wrongShape.result.stderr).toContain(
      'xcresult tests JSON has no testNodes array',
    );
  });
});
