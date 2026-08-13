import { execFileSync } from 'node:child_process';
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
const xcodegenInstallerPath = resolve(
  repoRoot,
  'scripts/ci/install-xcodegen.sh',
);
const xcodegenInstaller = existsSync(xcodegenInstallerPath)
  ? readFileSync(xcodegenInstallerPath, 'utf8')
  : '';
const dependencyReviewPath = resolve(
  repoRoot,
  '.github/workflows/dependency-review.yml',
);
const dependencyReviewWorkflow = existsSync(dependencyReviewPath)
  ? readFileSync(dependencyReviewPath, 'utf8')
  : '';
const dependabotConfig = parseDocument(
  readFileSync(resolve(repoRoot, '.github/dependabot.yml'), 'utf8'),
).toJS() as {
  updates?: Array<{
    'package-ecosystem'?: string;
    groups?: Record<string, { patterns?: string[] }>;
  }>;
};
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
  'actions/checkout': '3d3c42e5aac5ba805825da76410c181273ba90b1',
  'actions/download-artifact': '3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c',
  'actions/github-script': '3a2844b7e9c422d3c10d287c895573f7108da1b3',
  'actions/setup-node': '820762786026740c76f36085b0efc47a31fe5020',
  'actions/upload-artifact': '043fb46d1a93c77aae656e7c1c64a875d1fc6a0a',
  'actions/dependency-review-action':
    'a1d282b36b6f3519aa1f3fc636f609c47dddb294',
  'github/codeql-action/analyze': '5595ccaf912efad79be6eef63a5619ff05969be3',
  'github/codeql-action/init': '5595ccaf912efad79be6eef63a5619ff05969be3',
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

  it('groups CodeQL action updates into one atomic Dependabot pull request', () => {
    const githubActions = dependabotConfig.updates?.find(
      (update) => update['package-ecosystem'] === 'github-actions',
    );

    expect(githubActions?.groups?.['codeql-action']?.patterns).toEqual([
      'github/codeql-action/*',
    ]);
  });

  it('blocks expensive jobs behind the workflow pin contract', () => {
    for (const workflow of [testWorkflow, codeqlWorkflow]) {
      const parsed = parseDocument(workflow).toJS() as {
        jobs?: Record<
          string,
          {
            steps?: Array<{ name?: string; run?: string }>;
          }
        >;
      };
      const steps = parsed.jobs?.changes?.steps ?? [];
      const classifyIndex = steps.findIndex((step) =>
        step.name?.startsWith('Detect '),
      );
      const preflightIndex = steps.findIndex(
        (step) => step.name === 'Verify workflow pin contract',
      );

      expect(classifyIndex).toBeGreaterThan(-1);
      expect(preflightIndex).toBeGreaterThan(classifyIndex);
      expect(steps[preflightIndex]?.run).toContain(
        'npm test -- tests/scripts/ci-workflow.test.ts',
      );
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

  // A PR based on a feature branch used to trigger only Dependency Review and
  // report all-green, so "no Swift test ran" was indistinguishable from "every
  // Swift test passed". Dropping the base filter here is what makes a stacked
  // PR actually verified; codeql.yml keeps its filter on purpose.
  it('runs tests for pull requests against any base branch', () => {
    const on = parsedTestWorkflow.on;
    expect(on).toBeDefined();
    expect(on?.push).toEqual({ branches: ['main'] });
    expect(on).toHaveProperty('pull_request');
    expect(on?.pull_request ?? null).toBeNull();

    const parsedCodeql = parseDocument(codeqlWorkflow).toJS() as {
      on: { pull_request?: { branches?: string[] } };
    };
    expect(parsedCodeql.on.pull_request).toEqual({ branches: ['main'] });
  });

  it('keeps npm audit advisory handling identical on pull requests and pushes', () => {
    expect(parsedTestWorkflow.on).toMatchObject({
      push: { branches: ['main'] },
    });
    const auditStep = parsedTestWorkflow.jobs?.typescript?.steps?.find(
      (step) =>
        step.name === 'Dependency audit' &&
        step.run === 'npm audit --audit-level=moderate',
    );
    expect(auditStep?.['continue-on-error']).toBe(true);
  });

  it('installs the expected xcodegen release with a pinned checksum', () => {
    const installerCommand =
      'bash scripts/ci/install-xcodegen.sh "$XCODEGEN_VERSION" "$XCODEGEN_SHA256"';
    for (const workflow of xcodegenWorkflows) {
      expect(workflow).toContain('XCODEGEN_VERSION: "2.45.4"');
      expect(workflow).toContain(
        'XCODEGEN_SHA256: "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"',
      );
      expect(workflow).toContain(installerCommand);
      expect(workflow).not.toContain('brew install xcodegen');
    }
    expect(xcodegenInstaller).toContain(
      'https://github.com/yonaskolb/XcodeGen/releases/download/$' +
        '{version}/xcodegen.zip',
    );
    expect(xcodegenInstaller).toContain('shasum -a 256 -c -');
    expect(xcodegenInstaller).toContain('>> "$GITHUB_PATH"');
    expect(xcodegenInstaller).toContain('"$binary" --version');
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
    expect(testWorkflow).toContain('brew install ripgrep');
    expect(testWorkflow).toContain(
      'npm test -- tests/scripts/build-release-script.test.ts',
    );
    expect(testWorkflow).toContain(
      'tests/scripts/swift-boundary-scripts.test.ts',
    );
    // pure-rg gates stay on ubuntu coverage; do not re-pin on macos-vitest
    expect(testWorkflow).not.toContain(
      'tests/scripts/product-boundary-scripts.test.ts',
    );
    expect(testWorkflow).not.toContain(
      'tests/scripts/swift-conventions.test.ts',
    );
    expect(testWorkflow).toContain('tests/scripts/version-guard.test.ts');
    expect(testWorkflow).toContain('Check test fixture schema and freshness');
    expect(testWorkflow).toContain('run: npm run check:fixtures');
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
    const installIndex = releaseTestsJob.indexOf('brew install ripgrep');
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
      '.memory|.memory/*|CHANGELOG.md|MEMO.md|docs/archive/*|docs/reviews/*|docs/roadmap.md|docs/TODO.md|docs/followups.md|docs/competitive-*.md)',
    );
    expect(testWorkflow).not.toContain('.memory|*.md|docs/*)');
    // docs/archive/scripts/* is carved back out above the allowlist: those files
    // are scanned by tests/tooling/no-static-viking-creds.test.ts.
    // History-index READMEs are carved out for tests/docs/history-index-policy.test.ts.
    const carveOutIndex = testWorkflow.indexOf('docs/archive/scripts/*)');
    const indexCarveOutIndex = testWorkflow.indexOf(
      'docs/archive/README.md|docs/reviews/README.md)',
    );
    const allowlistIndex = testWorkflow.indexOf('.memory|.memory/*|');
    expect(carveOutIndex).toBeGreaterThan(-1);
    expect(indexCarveOutIndex).toBeGreaterThan(-1);
    expect(allowlistIndex).toBeGreaterThan(-1);
    expect(carveOutIndex).toBeLessThan(allowlistIndex);
    expect(indexCarveOutIndex).toBeLessThan(allowlistIndex);
  });

  // The allowlist is shell, and a shell `case` can be wrong in ways no string
  // assertion sees — a stray pattern, a missing `;;`, a carve-out placed after
  // the clause it must precede. This extracts the real `case`/`esac` block from
  // the workflow and runs it under bash against representative paths, so the
  // behaviour is checked rather than the text. (repro)
  it('executes the real classifier and routes representative paths correctly', () => {
    const workflowLines = testWorkflow.split('\n');
    const caseStart = workflowLines.findIndex(
      (line) => line.trim() === 'case "$path" in',
    );
    expect(caseStart, 'classifier case block not found').toBeGreaterThan(-1);

    let caseDepth = 0;
    let caseEnd = -1;
    for (let index = caseStart; index < workflowLines.length; index += 1) {
      const line = workflowLines[index]?.trim() ?? '';
      if (/^case\b.*\bin$/.test(line)) caseDepth += 1;
      if (line !== 'esac') continue;
      caseDepth -= 1;
      if (caseDepth === 0) {
        caseEnd = index;
        break;
      }
    }
    expect(caseEnd, 'matching classifier esac not found').toBeGreaterThan(
      caseStart,
    );
    const body = workflowLines.slice(caseStart, caseEnd + 1).join('\n');

    const classify = (paths: string[]): string => {
      const script = [
        'set -euo pipefail',
        'heavy=false',
        'while IFS= read -r path; do',
        body,
        "done <<'PATHS'",
        ...paths,
        'PATHS',
        'printf %s "$heavy"',
      ].join('\n');
      return execFileSync('bash', ['-c', script], { encoding: 'utf8' }).trim();
    };

    // Durable records: light.
    expect(classify(['CHANGELOG.md'])).toBe('false');
    expect(classify(['docs/roadmap.md', 'MEMO.md'])).toBe('false');
    expect(classify(['docs/competitive-mirror-2026-07.md'])).toBe('false');
    expect(classify(['docs/reviews/some-review.md'])).toBe('false');
    expect(classify(['.memory'])).toBe('false');

    // Product and config: heavy.
    expect(classify(['macos/Engram/App.swift'])).toBe('true');
    expect(classify(['src/core/db.ts'])).toBe('true');
    expect(classify(['package.json'])).toBe('true');

    // CLAUDE.md is a checked root path for the invariants gate: must stay heavy.
    expect(classify(['CLAUDE.md'])).toBe('true');

    // The carve-out has to win over docs/archive/*, which means it has to come
    // first in the case; ordering is the whole mechanism.
    expect(classify(['docs/archive/scripts/search-audit.sh'])).toBe('true');
    expect(classify(['docs/archive/README.md'])).toBe('true');
    expect(classify(['docs/reviews/README.md'])).toBe('true');
    expect(classify(['docs/archive/plans/old-plan.md'])).toBe('false');

    // One heavy path in an otherwise-durable set still goes heavy.
    expect(classify(['CHANGELOG.md', 'macos/Engram/App.swift'])).toBe('true');
    expect(
      classify(['docs/archive/plans/a.md', 'docs/archive/scripts/b.sh']),
    ).toBe('true');
  });

  // A classified-light path skips every job, Node included. If a test or gate
  // reads such a path, a change to it ships with the check that covers it
  // silently skipped — the same shape as the stacked-PR blind spot #258 closed.
  // This is a lower-bound guard over existing quoted literal repo paths. Dynamic
  // path construction and directory walks still require direct audit when the
  // allowlist changes. (repro)
  it('keeps existing literal paths named by tests or scripts out of the light allowlist', () => {
    const clause = testWorkflow
      .split('\n')
      .map((line) => line.trim())
      .find((line) => line.startsWith('.memory|') && line.endsWith(')'));
    expect(clause, 'durable-docs allowlist clause not found').toBeDefined();

    const carveOuts = testWorkflow
      .split('\n')
      .map((line) => line.trim())
      .filter(
        (line) =>
          line.endsWith(')') &&
          (line.startsWith('docs/archive/') ||
            line.startsWith('docs/reviews/README.md')),
      )
      .flatMap((line) => line.slice(0, -1).split('|'));

    // Shell `case` globs match `/` freely, so `*` is `.*` here — translating it
    // as `[^/]*` under-approximates the allowlist and lets real offenders pass.
    const toRegExp = (pattern: string): RegExp =>
      new RegExp(
        `^${pattern.replace(/[.+^${}()[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`,
      );
    const allow = (clause as string).slice(0, -1).split('|').map(toRegExp);
    const deny = carveOuts.map(toRegExp);
    const isLight = (path: string): boolean =>
      !deny.some((re) => re.test(path)) && allow.some((re) => re.test(path));

    // Every existing repo-relative path a file under tests/ or scripts/ names as
    // a quoted string, kept with the file that names it: this test necessarily
    // mentions allowlisted paths in its own fixtures, and only those are
    // discounted.
    const selfPath = 'tests/scripts/ci-workflow.test.ts';
    const namedBy = new Map<string, Set<string>>();
    for (const line of execFileSync(
      'git',
      [
        'grep',
        '-oI',
        '-E',
        '[\'"][A-Za-z0-9_./-]+\\.(md|sh|ts|json|jsonl)[\'"]',
        '--',
        'tests',
        'scripts',
      ],
      { cwd: repoRoot, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
    ).split('\n')) {
      const separator = line.indexOf(':');
      if (separator < 0) continue;
      const source = line.slice(0, separator);
      const named = line
        .slice(separator + 1)
        .trim()
        .replace(/^['"]|['"]$/g, '');
      if (named.length === 0 || !existsSync(resolve(repoRoot, named))) continue;
      const sources = namedBy.get(named) ?? new Set<string>();
      sources.add(source);
      namedBy.set(named, sources);
    }

    const offenders = [...namedBy.entries()]
      .filter(([, sources]) => ![...sources].every((s) => s === selfPath))
      .map(([named]) => named)
      .filter(isLight);

    expect(
      offenders,
      `these literal paths are named by tests/ or scripts/ but classify as durable-docs, so a change to them would skip the check that names them: ${offenders.join(', ')}`,
    ).toEqual([]);

    // docs/competitive-*.md is the new allowlist surface in this change. Check
    // its stable prefix separately so literal globs and directory-walk roots are
    // not lost merely because the generic path extractor requires a real file.
    const competitiveConsumers = execFileSync(
      'git',
      ['grep', '-lF', 'docs/competitive-', '--', 'tests', 'scripts'],
      { cwd: repoRoot, encoding: 'utf8' },
    )
      .split('\n')
      .filter(Boolean)
      .filter((path) => path !== selfPath);
    expect(competitiveConsumers).toEqual([]);
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
  it('documents nightly on-demand perf as non-gating_repro', () => {
    expect(perfWorkflow).toMatch(
      /^# Policy: nightly\/workflow_dispatch only; this workflow is not a pull-request or merge gate\.\nname: Perf/,
    );
  });

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
