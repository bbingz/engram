import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

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
const xcodegenWorkflows = [
  testWorkflow,
  releaseWorkflow,
  codeqlWorkflow,
  perfWorkflow,
];
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

describe('CI workflow hardening', () => {
  it('does not hard-gate pull requests on npm audit advisory churn', () => {
    expect(testWorkflow).toContain(
      'continue-on-error: $' + "{{ github.event_name == 'pull_request' }}",
    );
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
    expect(testWorkflow).toContain(
      'git diff --exit-code Engram.xcodeproj/project.pbxproj',
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
  });

  it('installs ripgrep before Ubuntu coverage runs the archive safety gate', () => {
    const typescriptJob = testWorkflow.slice(
      testWorkflow.indexOf('  typescript:'),
      testWorkflow.indexOf('  macos-vitest:'),
    );
    const installIndex = typescriptJob.indexOf(
      'sudo apt-get install --yes ripgrep',
    );
    const coverageIndex = typescriptJob.indexOf('npm run test:coverage');

    expect(installIndex).toBeGreaterThan(-1);
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
    const isolatedInvocation =
      'run_xcode_tests EngramRemoteServerCore -derivedDataPath "$RUNNER_TEMP/engram-remote-tests-derived"';

    expect(normalWorkflow).toContain(isolatedInvocation);
    expect(releaseWorkflow).toContain(isolatedInvocation);
  });

  it('runs bundle hygiene against the Debug app built in Swift CI', () => {
    expect(testWorkflow).toContain('Build/Products/Debug/Engram.app');
    expect(testWorkflow).toContain(
      'bash scripts/release-verify.sh "$ENGRAM_APP" --hygiene-only',
    );
  });

  it('keys SPM cache on Package.resolved and gives UI jobs restore keys', () => {
    expect(testWorkflow).toContain(
      'spm-$' +
        "{{ hashFiles('macos/project.yml', 'macos/Package.resolved') }}",
    );
    const uiSmoke = testWorkflow.slice(
      testWorkflow.indexOf('  ui-test-smoke:'),
    );
    const uiFull = testWorkflow.slice(testWorkflow.indexOf('  ui-test-full:'));
    expect(uiSmoke).toContain('restore-keys: spm-');
    expect(uiFull).toContain('restore-keys: spm-');
  });
});

describe('Perf workflow', () => {
  it('runs report-only indexer measurements on macOS nightly and on demand', () => {
    expect(perfWorkflow).toContain('name: Perf');
    expect(perfWorkflow).toContain('cron: "30 19 * * *"');
    expect(perfWorkflow).toContain('workflow_dispatch:');
    expect(perfWorkflow).toContain('runs-on: macos-15');
    expect(perfWorkflow).toContain('timeout-minutes: 30');
    expect(perfWorkflow).toContain('npm run generate:fixtures');
    expect(perfWorkflow).toContain(
      '-only-testing:EngramCoreTests/IndexerPerformanceTests',
    );
    expect(perfWorkflow).toContain('ENGRAM_PERF: "1"');
    expect(perfWorkflow).toContain('TEST_RUNNER_ENGRAM_PERF=1');
    expect(perfWorkflow).toContain('2>&1 | tee perf-xcodebuild.log');
    expect(perfWorkflow).toContain('if "measured" in line.lower()');
    expect(perfWorkflow).toContain('"average_seconds"');
    expect(perfWorkflow).toContain('No XCTest measured lines found');
    expect(perfWorkflow).toContain('perf-results.json');
    expect(perfWorkflow).toContain('uses: actions/upload-artifact@v7');
    expect(perfWorkflow).toContain('name: indexer-perf-results');
    expect(perfWorkflow).toContain('retention-days: 90');
    expect(macosProject).toContain('ENGRAM_PERF: "$(TEST_RUNNER_ENGRAM_PERF)"');
    expect(engramScheme).toContain('key = "ENGRAM_PERF"');
    expect(engramScheme).toContain('value = "$(TEST_RUNNER_ENGRAM_PERF)"');
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
