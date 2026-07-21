import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseDocument } from 'yaml';

const repoRoot = resolve(import.meta.dirname, '../..');
const testWorkflow = readFileSync(
  resolve(repoRoot, '.github/workflows/test.yml'),
  'utf8',
);
const releaseWorkflow = readFileSync(
  resolve(repoRoot, '.github/workflows/release.yml'),
  'utf8',
);
const codeqlWorkflow = readFileSync(
  resolve(repoRoot, '.github/workflows/codeql.yml'),
  'utf8',
);
const perfWorkflow = readFileSync(
  resolve(repoRoot, '.github/workflows/perf.yml'),
  'utf8',
);
const dependencyReviewPath = resolve(
  repoRoot,
  '.github/workflows/dependency-review.yml',
);
const dependencyReviewWorkflow = existsSync(dependencyReviewPath)
  ? readFileSync(dependencyReviewPath, 'utf8')
  : '';
const macosProject = readFileSync(
  resolve(repoRoot, 'macos/project.yml'),
  'utf8',
);
const engramScheme = readFileSync(
  resolve(
    repoRoot,
    'macos/Engram.xcodeproj/xcshareddata/xcschemes/Engram.xcscheme',
  ),
  'utf8',
);
const engramCoreTestsScheme = readFileSync(
  resolve(
    repoRoot,
    'macos/Engram.xcodeproj/xcshareddata/xcschemes/EngramCoreTests.xcscheme',
  ),
  'utf8',
);
const xcodegenWorkflows = [
  testWorkflow,
  releaseWorkflow,
  codeqlWorkflow,
  perfWorkflow,
];
const allWorkflows = [
  testWorkflow,
  releaseWorkflow,
  codeqlWorkflow,
  perfWorkflow,
  dependencyReviewWorkflow,
];
const actionPins = {
  'actions/cache': '55cc8345863c7cc4c66a329aec7e433d2d1c52a9',
  'actions/checkout': '9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0',
  'actions/download-artifact': '3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
  'actions/github-script': '3a2844b7e9c422d3c10d287c895573f7108da1b3',
  'actions/setup-node': '820762786026740c76f36085b0efc47a31fe5020',
  'actions/upload-artifact': '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
  'actions/dependency-review-action':
    'a1d282b36b6f3519aa1f3fc636f609c47dddb294',
  'github/codeql-action/analyze': '99df26d4f13ea111d4ec1a7dddef6063f76b97e9',
  'github/codeql-action/init': '99df26d4f13ea111d4ec1a7dddef6063f76b97e9',
} as const;
const packageJSON = JSON.parse(
  readFileSync(resolve(repoRoot, 'package.json'), 'utf8'),
) as { scripts: Record<string, string> };
const tsconfigTest = JSON.parse(
  readFileSync(resolve(repoRoot, 'tsconfig.test.json'), 'utf8'),
) as { include?: string[] };
const biomeConfig = JSON.parse(
  readFileSync(resolve(repoRoot, 'biome.json'), 'utf8'),
) as {
  files?: { includes?: string[] };
  overrides?: Array<{ includes?: string[] }>;
};
const gitignore = readFileSync(resolve(repoRoot, '.gitignore'), 'utf8');

const parsedTestWorkflow = parseDocument(testWorkflow).toJS() as {
  on?: Record<string, unknown>;
  jobs?: Record<
    string,
    {
      steps?: Array<{
        name?: string;
        run?: string;
        'continue-on-error'?: boolean;
      }>;
    }
  >;
};

describe('CI workflow hardening', () => {
  it('parses every workflow as YAML', () => {
    for (const workflow of allWorkflows) {
      expect(parseDocument(workflow).errors).toEqual([]);
    }
  });

  it('pins every external action to an immutable commit SHA', () => {
    const combined = allWorkflows.join('\n');
    const uses = [...combined.matchAll(/^\s*(?:-\s*)?uses:\s*([^\s#]+)/gm)].map(
      (match) => match[1],
    );
    expect(uses.length).toBeGreaterThan(0);
    for (const specifier of uses) {
      if (specifier.startsWith('./')) continue;
      expect(specifier).toMatch(/^[^@\s]+@[0-9a-f]{40}$/);
    }
    for (const [action, sha] of Object.entries(actionPins)) {
      expect(combined).toContain(`${action}@${sha}`);
    }
  });

  it('runs checksum-pinned actionlint in the Node CI lane', () => {
    expect(testWorkflow).toContain('ACTIONLINT_VERSION: "1.7.12"');
    expect(testWorkflow).toContain(
      'ACTIONLINT_LINUX_AMD64_SHA256: "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"',
    );
    expect(testWorkflow).toContain('Validate GitHub Actions workflows');
    expect(testWorkflow).toContain('sha256sum --check -');
    expect(testWorkflow).toContain('"$RUNNER_TEMP/actionlint"');
  });

  it('keeps npm audit advisory handling identical on pull requests and pushes', () => {
    expect(parsedTestWorkflow.on).toMatchObject({
      pull_request: { branches: ['main'] },
      push: { branches: ['main'] },
    });
    const auditStep = parsedTestWorkflow.jobs?.typescript?.steps?.find(
      (step) =>
        step.name === 'Dependency audit' &&
        step.run === 'npm audit --audit-level=moderate',
    );
    expect(auditStep?.['continue-on-error']).toBe(true);
  });

  it('does not mask xcodegen install failures', () => {
    for (const workflow of xcodegenWorkflows) {
      expect(workflow).not.toContain('brew install xcodegen || true');
    }
  });

  it('pins the expected xcodegen generator version in CI', () => {
    for (const workflow of xcodegenWorkflows) {
      expect(workflow).toContain('XCODEGEN_VERSION: "2.45.4"');
      expect(workflow).toContain(
        'test "$(xcodegen --version)" = "Version: $XCODEGEN_VERSION"',
      );
    }
  });

  it('fails CI when generated Xcode project is stale', () => {
    expect(testWorkflow).toContain('git diff --exit-code Engram.xcodeproj');
  });

  it('keeps pull-request code off persistent self-hosted runners', () => {
    expect(testWorkflow).not.toContain('runs-on: [self-hosted');
    expect(codeqlWorkflow).not.toContain('runs-on: [self-hosted');

    const macosVitest = testWorkflow.slice(
      testWorkflow.indexOf('  macos-vitest:'),
      testWorkflow.indexOf('  swift-unit:'),
    );
    const swiftUnit = testWorkflow.slice(
      testWorkflow.indexOf('  swift-unit:'),
      testWorkflow.indexOf('  remote-server-swift:'),
    );
    const uiSmoke = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-smoke:'),
      testWorkflow.indexOf('  ui-test-full:'),
    );
    const uiFull = testWorkflow.slice(testWorkflow.indexOf('  ui-test-full:'));
    const releaseTests = releaseWorkflow.slice(
      releaseWorkflow.indexOf('  release-tests:'),
      releaseWorkflow.indexOf('  release-remote-server-tests:'),
    );
    for (const job of [macosVitest, swiftUnit, uiSmoke, uiFull, releaseTests]) {
      expect(job).toContain('runs-on: macos-15');
      expect(job).not.toContain(
        'runs-on: [self-hosted, macOS, macmini-m1, xcode]',
      );
    }

    const releaseBundleGate = releaseWorkflow.slice(
      releaseWorkflow.indexOf('  release-bundle-gate:'),
    );
    expect(releaseBundleGate).toContain(
      'runs-on: [self-hosted, macOS, macmini-m1, xcode]',
    );
  });

  it('runs macOS-only vitest suites on pull requests', () => {
    expect(testWorkflow).toContain('macos-vitest:');
    expect(testWorkflow).toContain('brew install xcodegen ripgrep');
    expect(testWorkflow).toContain(
      'npm test -- tests/scripts/build-release-script.test.ts',
    );
    expect(testWorkflow).toContain(
      'tests/scripts/swift-boundary-scripts.test.ts',
    );
    expect(testWorkflow).toContain(
      'tests/scripts/product-boundary-scripts.test.ts',
    );
    expect(testWorkflow).toContain('tests/scripts/version-guard.test.ts');
    expect(testWorkflow).toContain('Verify fixture determinism');
  });

  it('fails CI when generated MCP contract fixtures are stale', () => {
    expect(packageJSON.scripts['check:mcp-contract-fixtures']).toBeDefined();
    expect(testWorkflow).toContain('Check MCP contract fixture freshness');
    expect(testWorkflow).toContain('npm run check:mcp-contract-fixtures');
  });

  it('provisions Git LFS before UI jobs check out screenshot baselines', () => {
    const smokeJob = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-smoke:'),
      testWorkflow.indexOf('  ui-test-full:'),
    );
    const fullJob = testWorkflow.slice(testWorkflow.indexOf('  ui-test-full:'));

    for (const job of [smokeJob, fullJob]) {
      const installIndex = job.indexOf('brew install git-lfs');
      const checkoutIndex = job.indexOf(
        `- uses: actions/checkout@${actionPins['actions/checkout']}`,
      );
      expect(installIndex).toBeGreaterThan(-1);
      expect(job).toContain('git lfs version');
      expect(checkoutIndex).toBeGreaterThan(installIndex);
      expect(job).toContain('lfs: true');
    }
  });

  it('provides ripgrep before Linux coverage runs the archive safety gate', () => {
    const typescriptJob = testWorkflow.slice(
      testWorkflow.indexOf('  typescript:'),
      testWorkflow.indexOf('  macos-vitest:'),
    );
    const installIndex = typescriptJob.indexOf(
      'sudo apt-get install -y ripgrep',
    );
    const coverageIndex = typescriptJob.indexOf('npm run test:coverage');

    expect(installIndex).toBeGreaterThan(-1);
    expect(typescriptJob).toContain('sudo apt-get update');
    expect(coverageIndex).toBeGreaterThan(installIndex);
  });

  it('installs ripgrep before release coverage runs the archive safety gate', () => {
    const releaseTestsJob = releaseWorkflow.slice(
      releaseWorkflow.indexOf('  release-tests:'),
      releaseWorkflow.indexOf('  release-bundle-gate:'),
    );
    const installIndex = releaseTestsJob.indexOf(
      'brew install xcodegen ripgrep',
    );
    const coverageIndex = releaseTestsJob.indexOf('npm run test:coverage');

    expect(installIndex).toBeGreaterThan(-1);
    expect(coverageIndex).toBeGreaterThan(installIndex);
  });

  it('isolates remote-server Swift tests from shared DerivedData package products', () => {
    const normalWorkflow = readFileSync(
      resolve(repoRoot, '.github/workflows/test.yml'),
      'utf8',
    );
    const releaseWorkflow = readFileSync(
      resolve(repoRoot, '.github/workflows/release.yml'),
      'utf8',
    );
    expect(normalWorkflow).toContain('  remote-server-swift:');
    expect(releaseWorkflow).toContain('  release-remote-server-tests:');
    expect(normalWorkflow).toContain(
      '-derivedDataPath "$RUNNER_TEMP/engram-remote-tests-derived"',
    );
    expect(releaseWorkflow).toContain(
      '-derivedDataPath "$RUNNER_TEMP/engram-remote-tests-derived"',
    );
    expect(normalWorkflow).toContain('-enableCodeCoverage NO');
  });

  it('runs Hummingbird-linked Swift gates on the supported macOS 26 image', () => {
    const normalWorkflow = readFileSync(
      resolve(repoRoot, '.github/workflows/test.yml'),
      'utf8',
    );
    const releaseWorkflow = readFileSync(
      resolve(repoRoot, '.github/workflows/release.yml'),
      'utf8',
    );
    const swiftJob = normalWorkflow.slice(
      normalWorkflow.indexOf('  remote-server-swift:'),
      normalWorkflow.indexOf('  ui-test-smoke:'),
    );
    const releaseJob = releaseWorkflow.slice(
      releaseWorkflow.indexOf('  release-remote-server-tests:'),
      releaseWorkflow.indexOf('  release-bundle-gate:'),
    );

    expect(swiftJob).toContain('runs-on: macos-26');
    expect(releaseJob).toContain('runs-on: macos-26');
    expect(swiftJob).toContain(
      'sudo xcode-select -s /Applications/Xcode_26.6.app',
    );
    expect(releaseJob).toContain(
      'sudo xcode-select -s /Applications/Xcode_26.6.app',
    );
  });

  it('runs bundle hygiene + structural helper checks against the Debug app built in Swift CI (M11)', () => {
    expect(testWorkflow).toContain('Build/Products/Debug/Engram.app');
    expect(testWorkflow).toContain(
      'bash scripts/release-verify.sh "$ENGRAM_APP" --hygiene-only',
    );
    // release-verify --hygiene-only must still assert Helpers (script contract).
    const releaseVerify = readFileSync(
      resolve(repoRoot, 'macos/scripts/release-verify.sh'),
      'utf8',
    );
    const hygieneExit = releaseVerify.indexOf(
      'PASS (hygiene + structure only)',
    );
    const structureCheck = releaseVerify.indexOf(
      'missing Contents/Helpers/EngramService',
    );
    expect(hygieneExit).toBeGreaterThan(-1);
    expect(structureCheck).toBeGreaterThan(-1);
    expect(structureCheck).toBeLessThan(hygieneExit);
  });

  it('keys SPM cache on the real Package.resolved and scopes restore keys by runner lane', () => {
    expect(testWorkflow).toContain(
      'macos/Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    );
    expect(testWorkflow).not.toContain("'macos/Package.resolved'");
    const uiSmoke = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-smoke:'),
    );
    const uiFull = testWorkflow.slice(testWorkflow.indexOf('  ui-test-full:'));
    expect(uiSmoke).toContain(
      'restore-keys: spm-$' +
        '{{ runner.os }}-$' +
        '{{ runner.arch }}-xcode15-',
    );
    expect(uiFull).toContain(
      'restore-keys: spm-$' +
        '{{ runner.os }}-$' +
        '{{ runner.arch }}-xcode15-',
    );
  });

  it('cancels superseded runs and exposes an always-run aggregate gate', () => {
    for (const workflow of [testWorkflow, codeqlWorkflow]) {
      expect(workflow).toContain(
        'group: $' + '{{ github.workflow }}-$' + '{{ github.ref }}',
      );
      expect(workflow).toContain('cancel-in-progress: true');
    }
    expect(testWorkflow).toContain('name: CI Gate');
    expect(testWorkflow).toContain('if: always()');
    expect(testWorkflow).toContain('CHANGES: $' + '{{ needs.changes.result }}');
    expect(testWorkflow).toContain('bash scripts/ci/verify-test-gate.sh');
    const ciGate = testWorkflow.slice(
      testWorkflow.indexOf('  ci-gate:'),
      testWorkflow.indexOf('  ui-smoke-report:'),
    );
    expect(ciGate).toContain(
      `uses: actions/checkout@${actionPins['actions/checkout']}`,
    );
    expect(testWorkflow).toContain('Detect durable-docs-only changes');
    expect(codeqlWorkflow).toContain('name: CodeQL Gate');
    expect(codeqlWorkflow).toContain(
      'CHANGES: $' + '{{ needs.changes.result }}',
    );
    expect(codeqlWorkflow).toContain('bash scripts/ci/verify-codeql-gate.sh');
  });

  it('keeps durable records and historical reviews off heavy product lanes', () => {
    expect(testWorkflow).toContain(
      '.memory|.memory/*|CHANGELOG.md|MEMO.md|docs/archive/*|docs/reviews/*|docs/roadmap.md|docs/TODO.md|docs/followups.md)',
    );
    expect(testWorkflow).not.toContain('.memory|*.md|docs/*)');
  });

  it('runs PR smoke and main full UI without exposing AI-triage secrets', () => {
    const uiSmoke = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-smoke:'),
      testWorkflow.indexOf('  ui-test-full:'),
    );
    const uiFull = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-full:'),
      testWorkflow.indexOf('  ci-gate:'),
    );
    expect(uiSmoke).toContain("github.event_name == 'pull_request'");
    expect(uiFull).toContain("github.event_name == 'push'");
    expect(uiFull).not.toContain("github.event_name == 'pull_request'");
    expect(uiSmoke).not.toContain('DASHSCOPE_API_KEY');
    expect(uiSmoke).not.toContain('pull-requests: write');
    const uiReport = testWorkflow.slice(
      testWorkflow.indexOf('  ui-smoke-report:'),
    );
    expect(uiReport).toContain('pull-requests: write');
    expect(uiReport).not.toContain('actions/checkout@');
    expect(uiReport).toContain(
      `actions/download-artifact@${actionPins['actions/download-artifact']}`,
    );
  });

  it('scans the shipped Swift product and remote server in distinct CodeQL categories', () => {
    expect(codeqlWorkflow).toContain('runs-on: macos-15');
    expect(codeqlWorkflow).toContain('runs-on: macos-26');
    expect(codeqlWorkflow).toContain('-scheme EngramRemoteServer');
    expect(codeqlWorkflow).toContain(
      'category: /language:swift/target:product',
    );
    expect(codeqlWorkflow).toContain(
      'category: /language:swift/target:remote-server',
    );
  });

  it('caches CodeQL Swift product package clones and leaves analysis timeout headroom', () => {
    const swiftProduct = codeqlWorkflow.slice(
      codeqlWorkflow.indexOf('  swift:'),
      codeqlWorkflow.indexOf('  swift-remote-server:'),
    );

    expect(swiftProduct).toContain('timeout-minutes: 75');
    expect(swiftProduct).toContain(
      `uses: actions/cache@${actionPins['actions/cache']}`,
    );
    expect(swiftProduct).toContain('path: ~/.cache/engram-codeql-spm');
    expect(swiftProduct).toContain(
      "hashFiles('macos/Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')",
    );
    expect(swiftProduct).toContain(
      '-clonedSourcePackagesDirPath "$HOME/.cache/engram-codeql-spm"',
    );
  });

  it('routes CodeQL targets through the tested path classifier', () => {
    expect(codeqlWorkflow).toContain(
      'bash scripts/ci/classify-codeql-changes.sh "$BASE_SHA" "$HEAD_SHA" "$GITHUB_OUTPUT"',
    );
    expect(codeqlWorkflow).toContain(
      "if: needs.changes.outputs.typescript == 'true'",
    );
    expect(codeqlWorkflow).toContain(
      "if: needs.changes.outputs.swift_product == 'true'",
    );
    expect(codeqlWorkflow).toContain(
      "if: needs.changes.outputs.swift_remote_server == 'true'",
    );
    const codeqlGate = codeqlWorkflow.slice(
      codeqlWorkflow.indexOf('  codeql-gate:'),
    );
    const checkoutIndex = codeqlGate.indexOf(
      `actions/checkout@${actionPins['actions/checkout']}`,
    );
    const verifyIndex = codeqlGate.indexOf(
      'bash scripts/ci/verify-codeql-gate.sh',
    );
    expect(checkoutIndex).toBeGreaterThan(-1);
    expect(verifyIndex).toBeGreaterThan(checkoutIndex);
    expect(codeqlGate).not.toContain('security-events: write');
    expect(codeqlWorkflow.match(/security-events: write/g)).toHaveLength(3);
  });
});

describe('Perf workflow', () => {
  it('runs budgeted indexer measurements on macOS nightly and on demand', () => {
    expect(perfWorkflow).toContain('name: Perf');
    expect(perfWorkflow).toContain('cron: "30 19 * * *"');
    expect(perfWorkflow).toContain('workflow_dispatch:');
    expect(perfWorkflow).toContain(
      'runs-on: [self-hosted, macOS, macmini-m1, xcode]',
    );
    expect(perfWorkflow).toContain('timeout-minutes: 15');
    expect(perfWorkflow).toContain(
      'group: perf-$' + '{{ github.ref }}-$' + '{{ github.event_name }}',
    );
    expect(perfWorkflow).toContain('cancel-in-progress: true');
    expect(perfWorkflow).toContain('npm run generate:fixtures');
    expect(perfWorkflow).toContain('-scheme EngramCoreTests');
    expect(perfWorkflow).toContain('build-for-testing');
    expect(perfWorkflow).toContain(
      'xcrun xctest -XCTest IndexerPerformanceTests',
    );
    expect(perfWorkflow).not.toContain('xcodebuild test');
    expect(perfWorkflow).toContain('ENGRAM_PERF: "1"');
    expect(perfWorkflow).toContain('2>&1 | tee perf-xctest.log');
    expect(perfWorkflow).toContain('scripts/ci/check-perf-results.py');
    expect(perfWorkflow).toContain('--max-average-seconds 0.100');
    expect(perfWorkflow).toContain('--max-rsd-percent 10.0');
    expect(perfWorkflow).toContain('--build-exit-code');
    expect(perfWorkflow).toContain('--test-exit-code');
    expect(perfWorkflow).toContain('--expected-fixture-count 20');
    expect(perfWorkflow).toContain(
      '--fixture-root test-fixtures/sessions/generated',
    );
    expect(perfWorkflow).toContain(
      '--baseline-id run-29206691519-macmini-m1-xcode26.6',
    );
    expect(perfWorkflow).toContain('perf-results.json');
    expect(perfWorkflow).toContain(
      `uses: actions/upload-artifact@${actionPins['actions/upload-artifact']}`,
    );
    expect(perfWorkflow).toContain('name: indexer-perf-results');
    expect(perfWorkflow).toContain('retention-days: 90');
    expect(macosProject).toContain('ENGRAM_PERF: "$(TEST_RUNNER_ENGRAM_PERF)"');
    expect(engramScheme).toContain('key = "ENGRAM_PERF"');
    expect(engramScheme).toContain('value = "$(TEST_RUNNER_ENGRAM_PERF)"');
    expect(engramCoreTestsScheme).toContain('key = "ENGRAM_PERF"');
    expect(engramCoreTestsScheme).toContain(
      'value = "$(TEST_RUNNER_ENGRAM_PERF)"',
    );
  });
});

describe('Dependency Review workflow', () => {
  it('fail-closes pull requests that introduce moderate-or-higher vulnerabilities', () => {
    expect(dependencyReviewWorkflow).toContain('name: Dependency Review');
    expect(dependencyReviewWorkflow).toContain('pull_request:');
    expect(dependencyReviewWorkflow).toContain('contents: read');
    expect(dependencyReviewWorkflow).toContain('timeout-minutes: 5');
    expect(dependencyReviewWorkflow).toContain(
      `actions/dependency-review-action@${actionPins['actions/dependency-review-action']}`,
    );
    expect(dependencyReviewWorkflow).toContain('fail-on-severity: moderate');
    expect(dependencyReviewWorkflow).toContain(
      'fail-on-scopes: runtime, development, unknown',
    );
    expect(dependencyReviewWorkflow).toContain(
      'x-github-dependency-graph-snapshot-warnings',
    );
    expect(dependencyReviewWorkflow).toContain('core.setFailed');
    expect(dependencyReviewWorkflow).not.toContain('warn-only: true');
  });
});

describe('local build metadata and script coverage', () => {
  it('has no stale root VERSION file competing with project.yml', () => {
    expect(existsSync(resolve(repoRoot, 'VERSION'))).toBe(false);
  });

  it('typechecks and lints nested TypeScript scripts', () => {
    expect(packageJSON.scripts['typecheck:test']).toContain(
      'tsconfig.test.json',
    );
    expect(tsconfigTest.include).toContain('scripts/**/*.ts');
    expect(biomeConfig.files?.includes).toContain('scripts/**');
    const overrideIncludes = biomeConfig.overrides?.flatMap(
      (override) => override.includes ?? [],
    );
    expect(overrideIncludes).toContain('scripts/**');
  });

  it('tracks the Husky pre-push shim used by core.hooksPath', () => {
    expect(gitignore).toContain('!.husky/pre-push');
    expect(existsSync(resolve(repoRoot, '.husky/pre-push'))).toBe(true);
  });
});
