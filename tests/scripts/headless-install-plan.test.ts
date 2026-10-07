import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
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
const roleTemplates: Record<string, [string, string, string]> = {
  collector: [
    'macos/EngramCollector/Packaging',
    'run-engram-collector.zsh',
    'com.engram.collector',
  ],
  'service-index': [
    'macos/EngramService/Packaging',
    'run-engram-service-index.zsh',
    'com.engram.service-index',
  ],
  'remote-server': [
    'macos/EngramRemoteServer/Packaging',
    'run-engram-remote.zsh',
    'com.engram.remote-server',
  ],
};
const products: Record<string, string> = {
  collector: 'EngramCollector',
  'service-index': 'EngramService',
  'remote-server': 'EngramRemoteServer',
};

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

// Copies the real role templates into a package directory, as the package
// scripts do, so plans read the template's actual activation keys.
function writeTemplates(directory: string, role: string) {
  const [source, wrapper, label] = roleTemplates[role];
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  for (const [name, mode] of [
    [`${wrapper}.template`, 0o700],
    [`${label}.plist.template`, 0o600],
  ] as const) {
    writeFileSync(
      join(directory, name),
      readFileSync(join(workspace, source, name)),
      { mode },
    );
  }
}

function fixture(role = 'collector', templates = true) {
  const root = mkdtempSync(join(workspace, '.engram-install-plan-test-'));
  roots.push(root);
  mkdirSync(join(root, 'package'), { mode: 0o700 });
  // Host precondition: the launch agent directory (~/Library/LaunchAgents)
  // exists; the planner never creates it.
  mkdirSync(join(root, 'jobs'), { mode: 0o700 });
  if (templates) writeTemplates(join(root, 'package/templates'), role);
  if (role === 'collector') {
    mkdirSync(join(root, 'identity'), { mode: 0o700 });
    writeFileSync(
      join(root, 'identity/archive.sqlite'),
      'synthetic catalog\n',
      {
        mode: 0o600,
      },
    );
  }
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
      '--credential-ids',
      'hq-token,m1-token',
    );
  }
  if (role === 'collector')
    result.push('--identity-catalog', join(root, 'identity/archive.sqlite'));
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

const metadataFor = (role: string) => ({
  sourceRevision: revision,
  product: products[role],
});

// Exercise actual exported planning code with metadata, not a fake verifier.
// This branch deliberately cannot claim a verified package. Public CLI tests
// below exercise the real verifier and reject non-native packages.
function runPure(
  root: string,
  argv: string[],
  metadata = metadataFor('collector'),
  host: Record<string, unknown> = {},
) {
  const code = `import {parseArguments, makeInstallationPlan} from ${JSON.stringify(`file://${script}`)};
    const options=parseArguments(JSON.parse(process.argv[1]));
    console.log(JSON.stringify(makeInstallationPlan(options, JSON.parse(process.argv[2]), JSON.parse(process.argv[3]))));`;
  return spawnSync(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      code,
      JSON.stringify(argv),
      JSON.stringify(metadata),
      JSON.stringify(host),
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

function plan(result: ReturnType<typeof runPure>) {
  expect(result.error).toBeUndefined();
  expect(result.status, result.stderr).toBe(0);
  return JSON.parse(result.stdout);
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

function runCLI(root: string, argv: string[]) {
  return spawnSync(process.execPath, [script, ...argv], {
    cwd: root,
    encoding: 'utf8',
    timeout: 20_000,
    env: {
      PATH: '/usr/bin:/bin',
      CFFIXED_USER_HOME: join(root, 'unused-home'),
    },
  });
}

// Inert host tools for the public CLI: a verifier that records and accepts,
// and a launchctl that reports the label as not loaded (never the real one).
function stubTools(root: string, launchctlScript?: string) {
  const verifier = join(root, 'verifier');
  const tools = join(root, 'tools');
  mkdirSync(verifier, { mode: 0o700 });
  mkdirSync(tools, { mode: 0o700 });
  for (const name of [
    'package-collector.sh',
    'package-service.sh',
    'package-remote-server.sh',
  ]) {
    writeFileSync(
      join(verifier, name),
      `#!/bin/bash\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'verifier-log'))}\nexit 0\n`,
      { mode: 0o700 },
    );
  }
  writeFileSync(
    join(tools, 'launchctl'),
    launchctlScript ??
      `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'launchctl-log'))}\necho 'Could not find service' >&2\nexit 113\n`,
    { mode: 0o700 },
  );
  return [
    '--verifier-directory',
    verifier,
    '--launchctl',
    join(tools, 'launchctl'),
  ];
}

const sha256 = (file: string) =>
  createHash('sha256').update(readFileSync(file)).digest('hex');

// SHA256SUMS as macos/scripts/package-*.sh generate_manifest writes it:
// `<sha256>  <relative path>` for every regular file except itself, sorted.
function writeManifest(directory: string) {
  const files: string[] = [];
  const walk = (relative: string) => {
    for (const entry of readdirSync(join(directory, relative), {
      withFileTypes: true,
    })) {
      const child = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(child);
      else if (entry.isFile() && child !== 'SHA256SUMS') files.push(child);
    }
  };
  walk('');
  writeFileSync(
    join(directory, 'SHA256SUMS'),
    files
      .sort()
      .map((file) => `${sha256(join(directory, file))}  ${file}\n`)
      .join(''),
    { mode: 0o600 },
  );
}

// Writes the metadata last and then the manifest over the whole bundle.
function writeMetadata(directory: string, role: string, rev = revision) {
  writeFileSync(
    join(directory, 'BUILD-METADATA.json'),
    `${JSON.stringify({ product: products[role], sourceRevision: rev })}\n`,
  );
  writeManifest(directory);
}

function runVerifyInstalled(root: string, bundle: string, role = 'collector') {
  const code = `import {roles, verifyInstalledRelease} from ${JSON.stringify(`file://${script}`)};
    console.log(JSON.stringify(verifyInstalledRelease(process.argv[1], roles[process.argv[2]])));`;
  return spawnSync(
    process.execPath,
    ['--input-type=module', '-e', code, bundle, role],
    {
      cwd: root,
      encoding: 'utf8',
      timeout: 10_000,
      env: { PATH: '/usr/bin:/bin', CFFIXED_USER_HOME: join(root, 'unused') },
    },
  );
}

// An already installed release: current -> releases/<rev>, rendered wrapper
// and launch agent files, as a previous install transaction leaves them.
function installed(root: string, role: string, rev: string) {
  const [, wrapper, label] = roleTemplates[role];
  const release = join(root, 'installation/releases', rev);
  writeTemplates(join(release, 'templates'), role);
  writeMetadata(release, role, rev);
  symlinkSync(release, join(root, 'installation/current'));
  writeFileSync(join(root, 'installation', wrapper), '#!/bin/zsh\n', {
    mode: 0o700,
  });
  writeFileSync(join(root, 'jobs', `${label}.plist`), '<plist/>\n', {
    mode: 0o600,
  });
  return release;
}

function step(result: { steps: { operation: string }[] }, operation: string) {
  return result.steps.find((entry) => entry.operation === operation) as Record<
    string,
    unknown
  >;
}

describe('headless installation dry-run boundaries', () => {
  for (const role of ['collector', 'service-index']) {
    it(`allows ${role} installation inside its expected user home`, () => {
      const root = fixture(role);
      const argv = args(root, role);
      argv[argv.indexOf('--expected-home') + 1] = root;
      const result = plan(runPure(root, argv, metadataFor(role)));
      expect(result.activation.launchctl).toBe('NOT_RUN');
      expect(existsSync(join(root, 'installation'))).toBe(false);
    });
    it(`rejects ${role} user context inside package or installation targets`, () => {
      const root = fixture(role);
      const wrapper = roleTemplates[role][1];
      for (const target of [
        'package',
        'jobs',
        'installation/releases',
        'installation/current',
        `installation/${wrapper}`,
      ]) {
        for (const suffix of ['', '/runtime-home']) {
          const argv = args(root, role);
          argv[argv.indexOf('--expected-home') + 1] =
            join(root, target) + suffix;
          expectRejected(
            runPure(root, argv, metadataFor(role)),
            /user home is inside/,
          );
        }
      }
    });
  }
  for (const [role, [, wrapper, label]] of Object.entries(roleTemplates)) {
    it(`constructs an explicit non-executing ${role} release/current/template plan`, () => {
      const root = fixture(role);
      const result = plan(runPure(root, args(root, role), metadataFor(role)));
      expect(result.kind).toBe('installation-dry-run');
      expect(result.transaction).toBe('install');
      expect(result.packageVerified).toBe(false);
      expect(result).not.toHaveProperty('deploymentAuthorized');
      expect(result.role).toBe(role);
      expect(result.product).toBe(products[role]);
      expect(result.sourceRevision).toBe(revision);
      expect(result.previousRelease).toBeNull();
      expect(result.targets).toEqual({
        release: join(root, 'installation/releases', revision),
        current: join(root, 'installation/current'),
        wrapper: join(root, 'installation', wrapper),
        launchAgent: join(root, 'jobs', `${label}.plist`),
        rollbackPointer: join(root, 'installation/rollback'),
      });
      expect(result.activation.launchctl).toBe('NOT_RUN');
      expect(result.activation.launchd).toBe('NOT_PROBED');
      expect(result.activation.label).toBe(label);
      expect(result.activation.domain).toBe(`gui/${process.getuid?.()}`);
      expect(
        result.steps.map((entry: { operation: string }) => entry.operation),
      ).toEqual([
        'copy-new-release',
        'verify-copied-release',
        ...(role === 'collector' ? ['initialize-collector-spool'] : []),
        'render-wrapper',
        'render-launch-agent',
        'create-current-symlink',
      ]);
      expect(result.blockersBeforeApply.join('\n')).toMatch(
        /separately authorized host transaction/,
      );
      if (role === 'collector') {
        expect(result.identity).toEqual({
          catalog: join(root, 'identity/archive.sqlite'),
          status: 'existing',
        });
        expect(step(result, 'initialize-collector-spool')).toEqual({
          operation: 'initialize-collector-spool',
          executable: join(
            root,
            'installation/releases',
            revision,
            'bin/EngramCollector',
          ),
          arguments: [
            '--settings',
            join(root, 'settings.json'),
            '--initialize',
          ],
          overwrite: false,
          startsCollection: false,
        });
      }
      const plistStep = step(result, 'render-launch-agent');
      expect(plistStep.overwrite).toBe(false);
      expect(step(result, 'render-wrapper').overwrite).toBe(false);
      if (role === 'remote-server') {
        expect(result.credentials).toBeNull();
        expect(plistStep.bindings).toEqual({
          __ENGRAM_REMOTE_WRAPPER__: join(root, 'installation', wrapper),
        });
      } else {
        expect(result.credentials).toEqual({
          file: join(root, 'credentials.json'),
          expectedIDs: ['hq-token', 'm1-token'],
          status: 'absent',
          ownerOnly: false,
        });
        expect(result.blockersBeforeApply.join('\n')).toMatch(
          /provision owner-only 0600 credentials for hq-token,m1-token/,
        );
        expect(step(result, 'render-wrapper').bindings).toEqual({});
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
                __ENGRAM_CAPTURE_SOURCE_AUTHORITY__: null,
              }
            : {}),
        });
      }
      expect(existsSync(join(root, 'installation'))).toBe(false);
      expect(readdirSync(join(root, 'jobs'))).toEqual([]);
      expect(existsSync(join(root, 'runtime-home'))).toBe(false);
    });
  }

  // PR #454, design §4.5 (docs/superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md),
  // followup cutover-install-tooling-1: the plan used to hard-code
  // disabled/runAtLoad:false/keepAlive:false for every role although the
  // remote-server plist template sets RunAtLoad and KeepAlive and has no
  // Disabled key.
  it('reports each role launch agent activation from the template keys, not hard-coded values (repro)', () => {
    for (const [role, [source, , label]] of Object.entries(roleTemplates)) {
      const root = fixture(role);
      const template = readFileSync(
        join(workspace, source, `${label}.plist.template`),
        'utf8',
      );
      const key = (name: string) => {
        const match = new RegExp(`<key>${name}</key>\\s*<(true|false)/>`).exec(
          template,
        );
        return match ? match[1] === 'true' : null;
      };
      const expected = {
        disabled: key('Disabled'),
        runAtLoad: key('RunAtLoad'),
        keepAlive: key('KeepAlive'),
      };
      expect(expected).toEqual(
        role === 'remote-server'
          ? { disabled: null, runAtLoad: true, keepAlive: true }
          : { disabled: true, runAtLoad: false, keepAlive: false },
      );
      const result = plan(runPure(root, args(root, role), metadataFor(role)));
      expect(result.activation).toMatchObject(expected);
      expect(step(result, 'render-launch-agent')).toMatchObject(expected);
      const operations = result.activation.commands.map(
        (command: string[]) => command[0],
      );
      expect(operations).toEqual(
        role === 'remote-server'
          ? ['bootstrap']
          : ['enable', 'bootstrap', 'kickstart'],
      );
      expect(result.activation.commands).toContainEqual([
        'bootstrap',
        `gui/${process.getuid?.()}`,
        join(root, 'jobs', `${label}.plist`),
      ]);
    }
  });

  // PR #454, design §4.5, followup cutover-install-tooling-1: only
  // __ENGRAM_REMOTE_ROOT__ was bound, leaving __ENGRAM_REMOTE_SOURCE_REVISION__
  // unbound in the plan.
  it('binds the remote wrapper source revision from BUILD-METADATA (repro)', () => {
    const root = fixture('remote-server');
    const result = plan(
      runPure(root, args(root, 'remote-server'), metadataFor('remote-server')),
    );
    expect(step(result, 'render-wrapper').bindings).toEqual({
      __ENGRAM_REMOTE_ROOT__: join(root, 'installation'),
      __ENGRAM_REMOTE_SOURCE_REVISION__: revision,
    });
  });

  it('accepts an optional remote web.env source only at the wrapper location', () => {
    const root = fixture('remote-server');
    const accepted = plan(
      runPure(
        root,
        [
          ...args(root, 'remote-server'),
          '--web-env-file',
          join(root, 'installation/secrets/web.env'),
        ],
        metadataFor('remote-server'),
      ),
    );
    expect(accepted.inputs.webEnvFile).toBe(
      join(root, 'installation/secrets/web.env'),
    );
    expectRejected(
      runPure(
        root,
        [
          ...args(root, 'remote-server'),
          '--web-env-file',
          join(root, 'elsewhere/web.env'),
        ],
        metadataFor('remote-server'),
      ),
      /secret|location|remote/,
    );
    const wrapper = readFileSync(
      join(root, 'package/templates/run-engram-remote.zsh.template'),
      'utf8',
    );
    expect(wrapper).toMatch(
      /\[\[ -f "\$remote_root\/secrets\/web\.env" && ! -L "\$remote_root\/secrets\/web\.env" \]\]/,
    );
  });

  it('binds the optional service-index capture source authority slot', () => {
    const root = fixture('service-index');
    const authority = join(root, 'authority/sources.json');
    const result = plan(
      runPure(
        root,
        [
          ...args(root, 'service-index'),
          '--capture-source-authority-file',
          authority,
        ],
        metadataFor('service-index'),
      ),
    );
    expect(
      (step(result, 'render-launch-agent').bindings as Record<string, string>)
        .__ENGRAM_CAPTURE_SOURCE_AUTHORITY__,
    ).toBe(authority);
    expectRejected(
      runPure(
        root,
        [
          ...args(root, 'service-index'),
          '--capture-source-authority-file',
          join(root, 'installation/current/sources.json'),
        ],
        metadataFor('service-index'),
      ),
      /overlap|state/,
    );
    expectRejected(
      runPure(root, [
        ...args(root),
        '--capture-source-authority-file',
        authority,
      ]),
      /unexpected|role/,
    );
  });

  describe('identity catalog branch', () => {
    it('plans only --initialize against an existing catalog and rejects a contradicting assertion', () => {
      const root = fixture();
      const result = plan(runPure(root, args(root)));
      expect(result.identity.status).toBe('existing');
      expect(step(result, 'initialize-collector-identity')).toBeUndefined();
      expectRejected(
        runPure(root, [...args(root), '--assert-no-identity-catalog']),
        /asserted no identity catalog but one exists/,
      );
    });

    it('fails closed without a catalog unless the owner asserts none exists', () => {
      const root = fixture();
      // No catalog and no catalog directory: the initializer creates the latter.
      rmSync(join(root, 'identity'), { recursive: true });
      expectRejected(
        runPure(root, args(root)),
        /no identity catalog found; pass --assert-no-identity-catalog/,
      );
      const result = plan(
        runPure(root, [...args(root), '--assert-no-identity-catalog']),
      );
      expect(result.identity).toEqual({
        catalog: join(root, 'identity/archive.sqlite'),
        status: 'new',
      });
      expect(
        result.steps.map((entry: { operation: string }) => entry.operation),
      ).toEqual([
        'copy-new-release',
        'verify-copied-release',
        'initialize-collector-identity',
        'initialize-collector-spool',
        'render-wrapper',
        'render-launch-agent',
        'create-current-symlink',
      ]);
      expect(step(result, 'initialize-collector-identity')).toEqual({
        operation: 'initialize-collector-identity',
        executable: join(
          root,
          'installation/releases',
          revision,
          'bin/EngramCollector',
        ),
        arguments: [
          '--initialize-identity',
          join(root, 'identity/archive.sqlite'),
        ],
        overwrite: false,
        startsCollection: false,
      });
      expect(existsSync(join(root, 'identity/archive.sqlite'))).toBe(false);
    });

    it('refuses a new identity when the catalog directory exists or its parent is missing', () => {
      const root = fixture();
      rmSync(join(root, 'identity/archive.sqlite'));
      // CollectorIdentityInitializer creates `identity/` itself.
      expectRejected(
        runPure(root, [...args(root), '--assert-no-identity-catalog']),
        /identity catalog directory already exists/,
      );
      rmSync(join(root, 'identity'), { recursive: true });
      const argv = args(root);
      argv[argv.indexOf('--identity-catalog') + 1] = join(
        root,
        'missing/identity/archive.sqlite',
      );
      expectRejected(
        runPure(root, [...argv, '--assert-no-identity-catalog']),
        /grandparent directory is missing/,
      );
      const result = plan(
        runPure(root, [...args(root), '--assert-no-identity-catalog']),
      );
      expect(result.identity.status).toBe('new');
    });

    it('treats sidecars without a catalog, a non-regular catalog and a misnamed new catalog as ambiguous', () => {
      const root = fixture();
      rmSync(join(root, 'identity/archive.sqlite'));
      writeFileSync(join(root, 'identity/archive.sqlite-wal'), '', {
        mode: 0o600,
      });
      expectRejected(
        runPure(root, [...args(root), '--assert-no-identity-catalog']),
        /sidecars/,
      );
      rmSync(join(root, 'identity/archive.sqlite-wal'));
      mkdirSync(join(root, 'identity/archive.sqlite'));
      expectRejected(runPure(root, args(root)), /not a regular file/);
      const misnamed = args(root);
      misnamed[misnamed.indexOf('--identity-catalog') + 1] = join(
        root,
        'identity/catalog.sqlite',
      );
      expectRejected(
        runPure(root, [...misnamed, '--assert-no-identity-catalog']),
        /archive\.sqlite/,
      );
      expectRejected(
        runPure(root, [
          ...args(root, 'service-index'),
          '--assert-no-identity-catalog',
        ]),
        /collector install/,
      );
    });
  });

  describe('credentials', () => {
    it('checks owner-only mode and expected credential IDs without printing values', () => {
      const root = fixture();
      const settingsText = 'THIS IS NOT JSON; do not read me or source me\n';
      writeFileSync(join(root, 'settings.json'), settingsText, { mode: 0o600 });
      const secret = 'CANARY-SECRET-VALUE-9f1c';
      const credentials = `${JSON.stringify({ 'hq-token': secret, 'm1-token': `${secret}-m1` })}\n`;
      writeFileSync(join(root, 'credentials.json'), credentials, {
        mode: 0o600,
      });
      const result = runPure(root, args(root));
      expect(result.status, result.stderr).toBe(0);
      expect(JSON.parse(result.stdout).credentials).toEqual({
        file: join(root, 'credentials.json'),
        expectedIDs: ['hq-token', 'm1-token'],
        status: 'verified',
        ownerOnly: true,
      });
      expect(`${result.stdout}${result.stderr}`).not.toContain(secret);
      expect(result.stdout).not.toContain(settingsText.trim());
      expect(readFileSync(join(root, 'settings.json'), 'utf8')).toBe(
        settingsText,
      );
      expect(readFileSync(join(root, 'credentials.json'), 'utf8')).toBe(
        credentials,
      );
      chmodSync(join(root, 'credentials.json'), 0o644);
      const rejected = runPure(root, args(root));
      expectRejected(rejected, /owner-only 0600/);
      expect(`${rejected.stdout}${rejected.stderr}`).not.toContain(secret);
      chmodSync(join(root, 'credentials.json'), 0o600);
      writeFileSync(
        join(root, 'credentials.json'),
        JSON.stringify({ 'hq-token': secret }),
        { mode: 0o600 },
      );
      const missing = runPure(root, args(root));
      expectRejected(missing, /lacks credential ID m1-token/);
      expect(`${missing.stdout}${missing.stderr}`).not.toContain(secret);
      writeFileSync(join(root, 'credentials.json'), 'not json', {
        mode: 0o600,
      });
      expectRejected(runPure(root, args(root)), /JSON object/);
    });

    it('requires distinct identifier credential IDs for capture roles', () => {
      const root = fixture();
      for (const ids of ['hq-token,hq-token', 'hq token,m1', '']) {
        const argv = args(root);
        argv[argv.indexOf('--credential-ids') + 1] = ids;
        expectRejected(runPure(root, argv), /credential IDs|missing/);
      }
    });
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
      [...args(root), '--activate'],
      [...args(root), '--role', 'collector'],
      [...args(root), '--mystery', 'x'],
      [...args(root), '--dry-run'],
      [...args(root), '--package'],
      [...args(root), '--kind', 'reinstall'],
      [
        ...args(root).filter(
          (value) =>
            value !== '--credential-ids' && value !== 'hq-token,m1-token',
        ),
      ],
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
      runPure(root, [
        ...args(root, 'remote-server'),
        '--identity-catalog',
        join(root, 'identity/archive.sqlite'),
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

  it('refuses pre-existing release/current/wrapper/job/rollback targets and preserves them', () => {
    for (const target of [
      `installation/releases/${revision}`,
      'installation/current',
      'installation/rollback',
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

  it('fails when the launch agent directory does not exist', () => {
    const root = fixture();
    rmSync(join(root, 'jobs'), { recursive: true });
    expectRejected(
      runPure(root, args(root)),
      /launch agent directory does not exist/,
    );
    expect(existsSync(join(root, 'jobs'))).toBe(false);
    writeFileSync(join(root, 'jobs'), 'not a directory\n');
    expectRejected(
      runPure(root, args(root)),
      /launch agent directory does not exist/,
    );
  });

  it('refuses overlapping role/package/state paths', () => {
    const root = fixture();
    for (const [flag, value] of [
      ['--install-root', join(root, 'package/new')],
      ['--settings', join(root, 'installation/current/config.json')],
      ['--credentials-file', join(root, 'installation/releases/key.json')],
      ['--identity-catalog', join(root, 'jobs/archive.sqlite')],
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
      runPure(root, service, metadataFor('service-index')),
      /independent|overlap/,
    );
  });

  it('uses the unchanged Remote wrapper secret locations and never sources them', () => {
    const root = fixture('remote-server');
    const argv = args(root, 'remote-server');
    argv[argv.indexOf('--legacy-env-file') + 1] = join(root, 'elsewhere.env');
    expectRejected(
      runPure(root, argv, metadataFor('remote-server')),
      /secret|location|remote/,
    );
  });

  it('fails the plan when the label is already loaded by a different job', () => {
    const root = fixture();
    const argv = args(root);
    expectRejected(
      runPure(root, argv, metadataFor('collector'), {
        launchd: {
          loaded: true,
          path: '/elsewhere/com.engram.collector.plist',
        },
      }),
      /already loaded by a different job/,
    );
    // A loaded job at the install target is stale evidence for a fresh install.
    expectRejected(
      runPure(root, argv, metadataFor('collector'), {
        launchd: {
          loaded: true,
          path: join(root, 'jobs/com.engram.collector.plist'),
        },
      }),
      /already loaded by a different job/,
    );
    const result = plan(
      runPure(root, argv, metadataFor('collector'), {
        launchd: { loaded: false, path: null },
      }),
    );
    expect(result.activation.launchd).toEqual({ loaded: false, path: null });
    expect(result.activation.commands[0][0]).toBe('enable');
  });

  describe('upgrade and rollback plan kinds', () => {
    const previous = 'b'.repeat(40);

    it('upgrade accepts existing current/wrapper/plist, writes a new release and records the rollback pointer', () => {
      const root = fixture();
      const old = installed(root, 'collector', previous);
      const result = plan(runPure(root, [...args(root), '--kind', 'upgrade']));
      expect(result.kind).toBe('upgrade-dry-run');
      expect(result.transaction).toBe('upgrade');
      expect(result.previousRelease).toBe(old);
      expect(
        result.steps.map((entry: { operation: string }) => entry.operation),
      ).toEqual([
        'copy-new-release',
        'verify-copied-release',
        'render-wrapper',
        'render-launch-agent',
        'swap-current-symlink',
        'record-rollback-pointer',
      ]);
      expect(step(result, 'render-wrapper').overwrite).toBe(true);
      expect(step(result, 'render-launch-agent')).toMatchObject({
        overwrite: true,
        bindings: {
          __ENGRAM_PACKAGE_ROOT__: join(
            root,
            'installation/releases',
            revision,
          ),
        },
      });
      expect(step(result, 'swap-current-symlink')).toEqual({
        operation: 'swap-current-symlink',
        path: join(root, 'installation/current'),
        target: join(root, 'installation/releases', revision),
        previous: old,
        atomic: true,
      });
      expect(step(result, 'record-rollback-pointer')).toEqual({
        operation: 'record-rollback-pointer',
        path: join(root, 'installation/rollback'),
        target: old,
        previous: null,
        atomic: true,
      });
      // A loaded job at our own launch agent path is booted out before bootstrap.
      const loaded = plan(
        runPure(
          root,
          [...args(root), '--kind', 'upgrade'],
          metadataFor('collector'),
          {
            launchd: {
              loaded: true,
              path: join(root, 'jobs/com.engram.collector.plist'),
            },
          },
        ),
      );
      expect(
        loaded.activation.commands.map((command: string[]) => command[0]),
      ).toEqual(['bootout', 'enable', 'bootstrap', 'kickstart']);
    });

    it('upgrade resolves a relative current link against the installation root', () => {
      const root = fixture();
      const old = installed(root, 'collector', previous);
      rmSync(join(root, 'installation/current'));
      symlinkSync(`releases/${previous}`, join(root, 'installation/current'));
      const result = plan(runPure(root, [...args(root), '--kind', 'upgrade']));
      expect(result.previousRelease).toBe(old);
      expect(step(result, 'swap-current-symlink')).toMatchObject({
        previous: old,
      });
    });

    it('upgrade refuses a missing current, the same revision and an existing release', () => {
      const root = fixture();
      expectRejected(
        runPure(root, [...args(root), '--kind', 'upgrade']),
        /requires an existing current release/,
      );
      installed(root, 'collector', revision);
      expectRejected(
        runPure(root, [...args(root), '--kind', 'upgrade']),
        /already|current/,
      );
    });

    it('rollback swaps current back to the pointer release and re-renders from that release', () => {
      const root = fixture();
      const old = installed(root, 'collector', previous);
      // Move current to a newer release and point rollback at the old one.
      const newer = join(root, 'installation/releases', revision);
      writeTemplates(join(newer, 'templates'), 'collector');
      writeMetadata(newer, 'collector');
      rmSync(join(root, 'installation/current'));
      symlinkSync(newer, join(root, 'installation/current'));
      symlinkSync(old, join(root, 'installation/rollback'));
      const argv = args(root).filter(
        (value, index, all) =>
          value !== '--package' && all[index - 1] !== '--package',
      );
      const result = plan(
        runPure(root, [...argv, '--kind', 'rollback'], {
          sourceRevision: previous,
          product: 'EngramCollector',
        }),
      );
      expect(result.kind).toBe('rollback-dry-run');
      expect(result.sourceRevision).toBe(previous);
      expect(result.previousRelease).toBe(newer);
      expect(
        result.steps.map((entry: { operation: string }) => entry.operation),
      ).toEqual([
        'verify-existing-release',
        'render-wrapper',
        'render-launch-agent',
        'swap-current-symlink',
        'record-rollback-pointer',
      ]);
      expect(step(result, 'verify-existing-release').bundle).toBe(old);
      expect(step(result, 'render-launch-agent')).toMatchObject({
        template: join(old, 'templates/com.engram.collector.plist.template'),
        bindings: { __ENGRAM_PACKAGE_ROOT__: old },
      });
      expect(step(result, 'record-rollback-pointer')).toMatchObject({
        target: newer,
        previous: old,
      });
      expectRejected(
        runPure(
          root,
          [...argv, '--kind', 'rollback'],
          metadataFor('collector'),
        ),
        /does not match the rollback pointer/,
      );
      expectRejected(
        runPure(root, [...args(root), '--kind', 'rollback']),
        /unexpected|package/,
      );
      rmSync(join(root, 'installation/rollback'));
      expectRejected(
        runPure(root, [...argv, '--kind', 'rollback'], {
          sourceRevision: previous,
          product: 'EngramCollector',
        }),
        /rollback pointer/,
      );
    });
  });

  describe('public CLI', () => {
    it('invokes real verification after template preflight and rejects an incomplete package without effects', () => {
      const root = fixture('collector', false);
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
      expectRejected(
        runCLI(root, args(root)),
        /package verification failed; no installation plan produced/,
      );
      expect(existsSync(join(root, 'installation'))).toBe(false);
      expect(readdirSync(join(root, 'jobs'))).toEqual([]);
    });

    it('probes launchd read-only, marks the package verified and prints a canonical plan hash', () => {
      const root = fixture();
      writeMetadata(join(root, 'package'), 'collector');
      const tools = stubTools(root);
      const result = runCLI(root, [...args(root), ...tools]);
      expect(result.status, result.stderr).toBe(0);
      const printed = JSON.parse(result.stdout);
      expect(printed.packageVerified).toBe(true);
      expect(printed.verifierDirectory).toBe(join(root, 'verifier'));
      expect(printed.launchctl).toBe(join(root, 'tools/launchctl'));
      expect(printed.packageDigest).toBe(
        sha256(join(root, 'package/SHA256SUMS')),
      );
      expect(printed.activation.launchd).toEqual({ loaded: false, path: null });
      expect(readFileSync(join(root, 'launchctl-log'), 'utf8')).toBe(
        `print gui/${process.getuid?.()}/com.engram.collector\n`,
      );
      expect(readFileSync(join(root, 'verifier-log'), 'utf8')).toBe(
        `--verify-only ${join(root, 'package')}\n`,
      );
      const hashCode = `import {canonicalPlanHash} from ${JSON.stringify(`file://${script}`)};
        console.log(canonicalPlanHash(JSON.parse(process.argv[1])));`;
      const recomputed = spawnSync(
        process.execPath,
        ['--input-type=module', '-e', hashCode, result.stdout],
        { encoding: 'utf8', timeout: 10_000 },
      );
      expect(recomputed.stdout.trim()).toBe(printed.planHash);
      expect(printed.planHash).toMatch(/^[0-9a-f]{64}$/);
      expect(existsSync(join(root, 'installation'))).toBe(false);
    });

    it('fails when launchd already runs the label from a different job', () => {
      const root = fixture();
      writeMetadata(join(root, 'package'), 'collector');
      const tools = stubTools(
        root,
        `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'launchctl-log'))}\necho 'com.engram.collector = {'\necho '\tpath = /Library/LaunchAgents/com.engram.collector.plist'\necho '}'\nexit 0\n`,
      );
      expectRejected(
        runCLI(root, [...args(root), ...tools]),
        /already loaded by a different job/,
      );
      expect(existsSync(join(root, 'installation'))).toBe(false);
    });

    // A release packaged before a template change fails the checkout
    // verifier's byte-equality template check, so an installed release is
    // verified by its own SHA256SUMS and BUILD-METADATA instead.
    it('plans a rollback onto a release whose templates differ from the checkout without the checkout verifier', () => {
      const root = fixture();
      const previous = 'b'.repeat(40);
      const old = installed(root, 'collector', previous);
      const template = join(old, 'templates/run-engram-collector.zsh.template');
      writeFileSync(
        template,
        `${readFileSync(template, 'utf8')}\n# packaged before the template change\n`,
        { mode: 0o700 },
      );
      writeManifest(old);
      const newer = join(root, 'installation/releases', revision);
      writeTemplates(join(newer, 'templates'), 'collector');
      writeMetadata(newer, 'collector');
      rmSync(join(root, 'installation/current'));
      symlinkSync(newer, join(root, 'installation/current'));
      symlinkSync(old, join(root, 'installation/rollback'));
      const tools = stubTools(root);
      const argv = args(root).filter(
        (value, index, all) =>
          value !== '--package' && all[index - 1] !== '--package',
      );
      const result = runCLI(root, [...argv, '--kind', 'rollback', ...tools]);
      expect(result.status, result.stderr).toBe(0);
      const printed = JSON.parse(result.stdout);
      expect(printed.kind).toBe('rollback-dry-run');
      expect(printed.sourceRevision).toBe(previous);
      expect(printed.packageVerified).toBe(true);
      expect(printed.packageDigest).toBe(sha256(join(old, 'SHA256SUMS')));
      expect(existsSync(join(root, 'verifier-log'))).toBe(false);
      // Bytes that drift from the manifest are refused.
      writeFileSync(template, '#!/bin/zsh\n', { mode: 0o700 });
      expectRejected(
        runCLI(root, [...argv, '--kind', 'rollback', ...tools]),
        /does not match SHA256SUMS: templates\/run-engram-collector\.zsh\.template/,
      );
    });

    it('verifies an installed release by manifest coverage, digests, template modes and metadata', () => {
      const root = fixture();
      const release = installed(root, 'collector', revision);
      const ok = runVerifyInstalled(root, release);
      expect(ok.status, ok.stderr).toBe(0);
      expect(JSON.parse(ok.stdout)).toEqual({
        manifestDigest: sha256(join(release, 'SHA256SUMS')),
        files: 3,
        sourceRevision: revision,
      });
      writeFileSync(join(release, 'extra.txt'), 'unlisted\n');
      expectRejected(
        runVerifyInstalled(root, release),
        /does not exactly cover/,
      );
      rmSync(join(release, 'extra.txt'));
      chmodSync(
        join(release, 'templates/com.engram.collector.plist.template'),
        0o644,
      );
      expectRejected(runVerifyInstalled(root, release), /wrong mode/);
      chmodSync(
        join(release, 'templates/com.engram.collector.plist.template'),
        0o600,
      );
      expectRejected(
        runVerifyInstalled(root, release, 'service-index'),
        /template|metadata/,
      );
      writeFileSync(join(release, 'SHA256SUMS'), 'not a manifest\n');
      expectRejected(runVerifyInstalled(root, release), /invalid line/);
    });
  });

  for (const [role, [, wrapper, label]] of Object.entries(roleTemplates)) {
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
        const root = fixture(role, false);
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
            [`${wrapper}.template`, 'wrapper'],
            [`${label}.plist.template`, 'plist'],
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
        expect(readdirSync(join(root, 'jobs'))).toEqual([]);
      }
    });
  }
});
