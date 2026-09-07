import { spawnSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const workspace = resolve(import.meta.dirname, '../..');
const script = join(workspace, 'scripts/plan-headless-install.mjs');
const roots: string[] = [];
const revision = 'a'.repeat(40);

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(workspace, '.engram-install-plan-test-'));
  roots.push(root);
  mkdirSync(join(root, 'package'), { mode: 0o700 });
  return root;
}

function args(root: string, role = 'collector') {
  const result = [
    '--dry-run',
    '--role',
    role,
    '--package',
    join(root, 'package'),
    '--install-root',
    join(root, 'installation'),
    '--launch-agent-directory',
    join(root, 'jobs'),
  ];
  if (role === 'remote-server') {
    result.push(
      '--legacy-env-file',
      join(root, 'installation/secrets/legacy-v1.env'),
      '--archive-env-file',
      join(root, 'installation/secrets/archive-v2.env'),
    );
  } else {
    result.push(
      '--expected-home',
      join(root, 'runtime-home'),
      '--settings',
      join(root, 'settings.json'),
      '--credentials-file',
      join(root, 'credentials.json'),
    );
  }
  if (role === 'service-index') {
    result.push(
      '--database-path',
      join(root, 'index/index.sqlite'),
      '--service-socket',
      join(root, 'socket/service.sock'),
    );
  }
  return result;
}

// Exercise actual exported planning code with metadata, not a fake verifier.
// This branch deliberately cannot claim a verified package. Public CLI tests
// below exercise the real verifier and reject non-native packages.
function runPure(
  root: string,
  argv: string[],
  metadata = { sourceRevision: revision, product: 'EngramCollector' },
) {
  const code = `import {parseArguments, makeInstallationPlan} from ${JSON.stringify(`file://${script}`)};
    const options=parseArguments(JSON.parse(process.argv[1]));
    console.log(JSON.stringify(makeInstallationPlan(options, JSON.parse(process.argv[2]))));`;
  return spawnSync(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      code,
      JSON.stringify(argv),
      JSON.stringify(metadata),
    ],
    {
      cwd: root,
      encoding: 'utf8',
      timeout: 10_000,
      env: {
        PATH: '/usr/bin:/bin',
        CFFIXED_USER_HOME: join(root, 'unused-home'),
      },
    },
  );
}

function expectRejected(result: ReturnType<typeof runPure>, pattern: RegExp) {
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  expect(result.status).not.toBe(0);
  expect(`${result.stdout}${result.stderr}`).toMatch(pattern);
}

function checkTemplates(root: string, argv: string[]) {
  const code = `import {parseArguments, validatePackageTemplates} from ${JSON.stringify(`file://${script}`)};
    validatePackageTemplates(parseArguments(JSON.parse(process.argv[1])));`;
  return spawnSync(
    process.execPath,
    ['--input-type=module', '-e', code, JSON.stringify(argv)],
    {
      cwd: root,
      encoding: 'utf8',
      timeout: 10_000,
      env: {
        PATH: '/usr/bin:/bin',
        CFFIXED_USER_HOME: join(root, 'unused-home'),
      },
    },
  );
}

describe('headless installation dry-run boundaries', () => {
  for (const [role, product, label, wrapper] of [
    [
      'collector',
      'EngramCollector',
      'com.engram.collector',
      'run-engram-collector.zsh',
    ],
    [
      'service-index',
      'EngramService',
      'com.engram.service-index',
      'run-engram-service-index.zsh',
    ],
    [
      'remote-server',
      'EngramRemoteServer',
      'com.engram.remote-server',
      'run-engram-remote.zsh',
    ],
  ]) {
    it(`constructs an explicit non-executing ${role} release/current/template plan`, () => {
      const root = fixture();
      const result = runPure(root, args(root, role), {
        sourceRevision: revision,
        product,
      });
      expect(result.error).toBeUndefined();
      expect(result.status, result.stderr).toBe(0);
      const plan = JSON.parse(result.stdout);
      expect(plan.kind).toBe('installation-dry-run');
      expect(plan.packageVerified).toBe(false);
      expect(plan.deploymentAuthorized).toBe(false);
      expect(plan.role).toBe(role);
      expect(plan.sourceRevision).toBe(revision);
      expect(plan.targets).toEqual({
        release: join(root, 'installation/releases', revision),
        current: join(root, 'installation/current'),
        wrapper: join(root, 'installation', wrapper),
        launchAgent: join(root, 'jobs', `${label}.plist`),
      });
      expect(plan.activation).toEqual({
        disabled: true,
        runAtLoad: false,
        keepAlive: false,
        launchctl: 'NOT_RUN',
      });
      expect(
        plan.steps.map((step: { operation: string }) => step.operation),
      ).toEqual([
        'copy-new-release',
        'verify-copied-release',
        'render-wrapper',
        'render-disabled-launch-agent',
        'create-current-symlink',
      ]);
      expect(plan.blockersBeforeApply).toContain(
        'separately authorized host transaction',
      );
      const wrapperStep = plan.steps.find(
        (step: { operation: string }) => step.operation === 'render-wrapper',
      );
      const plistStep = plan.steps.find(
        (step: { operation: string }) =>
          step.operation === 'render-disabled-launch-agent',
      );
      if (role === 'remote-server') {
        expect(wrapperStep.bindings).toEqual({
          __ENGRAM_REMOTE_ROOT__: join(root, 'installation'),
        });
        expect(plistStep.bindings).toEqual({
          __ENGRAM_REMOTE_WRAPPER__: join(root, 'installation', wrapper),
        });
      } else {
        expect(wrapperStep.bindings).toEqual({});
        expect(plistStep.bindings).toEqual({
          __ENGRAM_WRAPPER__: join(root, 'installation', wrapper),
          __ENGRAM_PACKAGE_ROOT__: join(
            root,
            'installation/releases',
            revision,
          ),
          __ENGRAM_EXPECTED_HOME__: join(root, 'runtime-home'),
          __ENGRAM_SETTINGS__: join(root, 'settings.json'),
          __ENGRAM_CREDENTIALS__: join(root, 'credentials.json'),
          ...(role === 'service-index'
            ? {
                __ENGRAM_DATABASE_PATH__: join(root, 'index/index.sqlite'),
                __ENGRAM_SERVICE_SOCKET__: join(root, 'socket/service.sock'),
              }
            : {}),
        });
      }
      expect(existsSync(join(root, 'installation'))).toBe(false);
      expect(existsSync(join(root, 'jobs'))).toBe(false);
      expect(existsSync(join(root, 'runtime-home'))).toBe(false);
    });
  }

  it('does not read or execute settings and credential path contents', () => {
    const root = fixture();
    const contents = 'THIS IS NOT JSON; do not read me or source me\n';
    for (const name of ['settings.json', 'credentials.json'])
      writeFileSync(join(root, name), contents, { mode: 0o600 });
    const result = runPure(root, args(root));
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout).not.toContain(contents.trim());
    for (const name of ['settings.json', 'credentials.json'])
      expect(readFileSync(join(root, name), 'utf8')).toBe(contents);
  });

  it('preserves shell and XML metacharacters as JSON data', () => {
    const root = fixture();
    const argv = args(root);
    const unusual = join(root, 'space \'&<>" $() `literal` settings.json');
    argv[argv.indexOf('--settings') + 1] = unusual;
    const result = runPure(root, argv);
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).inputs.settings).toBe(unusual);
    expect(existsSync(unusual)).toBe(false);
  });

  it('requires an explicit dry-run and refuses apply/unknown/duplicate/missing options', () => {
    const root = fixture();
    for (const argv of [
      args(root).slice(1),
      [...args(root), '--apply'],
      [...args(root), '--role', 'collector'],
      [...args(root), '--mystery', 'x'],
      [...args(root), '--dry-run'],
      [...args(root), '--package'],
    ]) {
      expectRejected(runPure(root, argv), /dry-run|unknown|duplicate|missing/i);
    }
  });

  it('rejects unknown roles, cross-role flags, invalid revisions and wrong products', () => {
    const root = fixture();
    const wrongRole = args(root);
    wrongRole[wrongRole.indexOf('--role') + 1] = 'app';
    expectRejected(runPure(root, wrongRole), /role/);
    expectRejected(
      runPure(root, [
        ...args(root),
        '--database-path',
        join(root, 'index.sqlite'),
      ]),
      /role|unexpected/,
    );
    expectRejected(
      runPure(root, args(root), {
        sourceRevision: 'invalid',
        product: 'EngramCollector',
      }),
      /revision/,
    );
    expectRejected(
      runPure(root, args(root), {
        sourceRevision: revision,
        product: 'EngramService',
      }),
      /product/,
    );
  });

  it('rejects unsafe, unresolved and aliased target paths without creating parents', () => {
    const root = fixture();
    for (const path of [
      '/',
      'relative',
      `${join(root, '..', '..')}/..`,
      `${root}/../escape`,
      `${root}//repeat`,
      `${root}/__ENGRAM_ROOT__`,
      `${root}/line\nbreak`,
    ]) {
      const argv = args(root);
      argv[argv.indexOf('--install-root') + 1] = path;
      expectRejected(runPure(root, argv), /path|root|placeholder/);
    }
    symlinkSync(join(root, 'package'), join(root, 'alias'));
    const argv = args(root);
    argv[argv.indexOf('--install-root') + 1] = join(root, 'alias/nested');
    expectRejected(runPure(root, argv), /alias|symlink/);
    expect(existsSync(join(root, 'package/nested'))).toBe(false);
  });

  it('refuses pre-existing release/current/wrapper/job targets and preserves them', () => {
    for (const target of [
      `installation/releases/${revision}`,
      'installation/current',
      'installation/run-engram-collector.zsh',
      'jobs/com.engram.collector.plist',
    ]) {
      const root = fixture();
      const path = join(root, target);
      mkdirSync(resolve(path, '..'), { recursive: true, mode: 0o700 });
      writeFileSync(path, 'existing owner\n', { mode: 0o600 });
      expectRejected(runPure(root, args(root)), /existing|overwrite/);
      expect(readFileSync(path, 'utf8')).toBe('existing owner\n');
    }
  });

  it('refuses overlapping role/package/state paths', () => {
    const root = fixture();
    for (const [flag, value] of [
      ['--install-root', join(root, 'package/new')],
      ['--settings', join(root, 'installation/current/config.json')],
      ['--credentials-file', join(root, 'installation/releases/key.json')],
    ]) {
      const argv = args(root);
      argv[argv.indexOf(flag) + 1] = value;
      expectRejected(runPure(root, argv), /overlap|state|release|current/);
    }
    const service = args(root, 'service-index');
    service[service.indexOf('--service-socket') + 1] = join(
      root,
      'index/service.sock',
    );
    expectRejected(
      runPure(root, service, {
        sourceRevision: revision,
        product: 'EngramService',
      }),
      /independent|overlap/,
    );
  });

  it('uses the unchanged Remote wrapper secret locations and never sources them', () => {
    const root = fixture();
    const argv = args(root, 'remote-server');
    argv[argv.indexOf('--legacy-env-file') + 1] = join(root, 'elsewhere.env');
    expectRejected(
      runPure(root, argv, {
        sourceRevision: revision,
        product: 'EngramRemoteServer',
      }),
      /secret|location|remote/,
    );
  });

  it('public CLI invokes real verification after template preflight and rejects an incomplete package without effects', () => {
    const root = fixture();
    mkdirSync(join(root, 'package/templates'), { mode: 0o700 });
    for (const name of [
      'run-engram-collector.zsh.template',
      'com.engram.collector.plist.template',
    ]) {
      writeFileSync(
        join(root, 'package/templates', name),
        'synthetic template; no native executable',
      );
    }
    const result = spawnSync(process.execPath, [script, ...args(root)], {
      cwd: root,
      encoding: 'utf8',
      timeout: 10_000,
      env: {
        PATH: '/usr/bin:/bin',
        CFFIXED_USER_HOME: join(root, 'unused-home'),
      },
    });
    expectRejected(
      result,
      /package verification failed; no installation plan produced/,
    );
    expect(existsSync(join(root, 'installation'))).toBe(false);
    expect(existsSync(join(root, 'jobs'))).toBe(false);
  });

  for (const [role, wrapper, plist] of [
    [
      'collector',
      'run-engram-collector.zsh.template',
      'com.engram.collector.plist.template',
    ],
    [
      'service-index',
      'run-engram-service-index.zsh.template',
      'com.engram.service-index.plist.template',
    ],
    [
      'remote-server',
      'run-engram-remote.zsh.template',
      'com.engram.remote-server.plist.template',
    ],
  ]) {
    it(`requires both regular unaliased ${role} package templates before planning`, () => {
      for (const mutation of [
        'missing-directory',
        'missing-wrapper',
        'missing-plist',
        'wrapper-alias',
        'plist-alias',
        'directory-alias',
        'regular',
      ]) {
        const root = fixture();
        const directory = join(root, 'package/templates');
        if (mutation !== 'missing-directory') {
          const contents =
            mutation === 'directory-alias'
              ? join(root, 'package/actual-templates')
              : directory;
          mkdirSync(contents, { mode: 0o700 });
          if (mutation === 'directory-alias')
            symlinkSync('actual-templates', directory);
          for (const [name, kind] of [
            [wrapper, 'wrapper'],
            [plist, 'plist'],
          ]) {
            if (mutation === `missing-${kind}`) continue;
            const target = join(contents, name);
            if (mutation === `${kind}-alias`) {
              writeFileSync(
                `${target}.actual`,
                'synthetic template; not native verification',
              );
              symlinkSync(`${name}.actual`, target);
            } else
              writeFileSync(
                target,
                'synthetic template; not native verification',
              );
          }
        }
        const result = checkTemplates(root, args(root, role));
        if (mutation === 'regular')
          expect(result.status, result.stderr).toBe(0);
        else expectRejected(result, /template|alias|regular|missing/);
        expect(existsSync(join(root, 'installation'))).toBe(false);
        expect(existsSync(join(root, 'jobs'))).toBe(false);
      }
    });
  }
});
