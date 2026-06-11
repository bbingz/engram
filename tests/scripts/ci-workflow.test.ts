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
    for (const workflow of [testWorkflow, releaseWorkflow, codeqlWorkflow]) {
      expect(workflow).not.toContain('brew install xcodegen || true');
    }
  });

  it('pins the expected xcodegen generator version in CI', () => {
    for (const workflow of [testWorkflow, releaseWorkflow, codeqlWorkflow]) {
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
    expect(testWorkflow).toContain(
      'npm test -- tests/scripts/build-release-script.test.ts',
    );
    expect(testWorkflow).toContain(
      'tests/scripts/swift-boundary-scripts.test.ts',
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
