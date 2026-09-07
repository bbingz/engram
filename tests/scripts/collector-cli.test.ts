import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  linkSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { parse } from 'yaml';

const repoRoot = resolve(import.meta.dirname, '../..');
const fixturePrefix = '.engram-collector-cli-test-';
const binary = process.env.ENGRAM_COLLECTOR_BINARY;
const mainPath = join(repoRoot, 'macos/EngramCollector/main.swift');
const canary = 'CLI_PRIVATE_CANARY_DO_NOT_PRINT';
const privateRef = 'cli-private-reference-do-not-print';
const tempRoots: string[] = [];

// Native cases never search DerivedData, PATH, or the user's home for a helper.
// A supplied but invalid binary path fails; only an absent opt-in skips them.
afterEach(() => {
  for (const root of tempRoots.splice(0)) {
    if (
      dirname(root) !== repoRoot ||
      !basename(root).startsWith(fixturePrefix)
    ) {
      throw new Error('Refusing cleanup outside this test invocation');
    }
    rmSync(root, { recursive: true, force: true });
  }
});

interface Fixture {
  root: string;
  home: string;
  temporary: string;
  settings: string;
  credentials: string;
  shadow: string;
  identity: string;
  sources: string;
}

function makeFixture(): Fixture {
  const root = mkdtempSync(join(repoRoot, fixturePrefix));
  tempRoots.push(root);
  const fixture: Fixture = {
    root,
    home: join(root, 'home'),
    temporary: join(root, 'tmp'),
    settings: join(root, `${canary}-settings.json`),
    credentials: join(root, `${canary}-credentials.json`),
    shadow: join(root, 'must-not-create-shadow'),
    identity: join(root, 'must-not-create-identity', 'archive.sqlite'),
    sources: join(root, 'must-not-discover-sources'),
  };
  mkdirSync(fixture.home, { mode: 0o700 });
  mkdirSync(fixture.temporary, { mode: 0o700 });
  mkdirSync(join(fixture.home, '.engram'), { mode: 0o700 });
  // If the executable guesses a default settings path, this is deliberately
  // invalid rather than another disabled document that could mask the mistake.
  writePrivate(join(fixture.home, '.engram/settings.json'), canary);
  writePrivate(join(fixture.home, 'untouched-canary'), canary);
  return fixture;
}

function writePrivate(path: string, contents: string | object): void {
  writeFileSync(
    path,
    typeof contents === 'string' ? contents : JSON.stringify(contents),
    { mode: 0o600 },
  );
}

function homeSnapshot(home: string): string[] {
  const entries: string[] = [];
  function visit(directory: string, prefix: string): void {
    for (const name of readdirSync(directory).sort()) {
      const path = join(directory, name);
      const relative = join(prefix, name);
      const info = lstatSync(path);
      entries.push(`${relative}:${info.mode}:${info.nlink}`);
      if (info.isSymbolicLink()) entries.push(readlinkSync(path));
      else if (info.isDirectory()) visit(path, relative);
      else if (info.isFile()) entries.push(readFileSync(path).toString('hex'));
    }
  }
  // The only recursive inspection is this invocation's newly created home.
  visit(home, '');
  return entries;
}

function runCLI(fixture: Fixture, args: string[]) {
  if (binary === undefined || !isAbsolute(binary)) {
    throw new Error(
      'ENGRAM_COLLECTOR_BINARY requires an explicit absolute path',
    );
  }
  const before = homeSnapshot(fixture.home);
  const result = spawnSync(binary, args, {
    cwd: fixture.root,
    encoding: 'utf8',
    timeout: 5_000,
    killSignal: 'SIGKILL',
    maxBuffer: 256 * 1024,
    // Do not inherit provider credentials, DYLD overrides, or real-home paths.
    env: {
      PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
      HOME: fixture.home,
      CFFIXED_USER_HOME: fixture.home,
      TMPDIR: fixture.temporary,
      LANG: 'C',
      LC_ALL: 'C',
    },
  });
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  expect(homeSnapshot(fixture.home)).toEqual(before);
  expect(existsSync(fixture.shadow)).toBe(false);
  expect(existsSync(dirname(fixture.identity))).toBe(false);
  expect(existsSync(fixture.sources)).toBe(false);
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  for (const privateValue of [canary, privateRef, fixture.root]) {
    expect(output).not.toContain(privateValue);
  }
  return result;
}

function expectDisabled(fixture: Fixture, args: string[]): void {
  const result = runCLI(fixture, args);
  expect(result.status).toBe(0);
  expect(result.stdout).toBe('engram-collector: disabled\n');
  expect(result.stderr).toBe('');
}

function expectRuntimeFailure(fixture: Fixture, args: string[]): void {
  const result = runCLI(fixture, args);
  expect(result.status).toBe(70);
  expect(result.stdout).toBe('');
  expect(result.stderr).toBe('engram-collector: runtime failed\n');
}

interface Target {
  type: string;
  sources: { path: string }[];
  dependencies: { target?: string; package?: string; product?: string }[];
  settings: Record<string, unknown>;
}

describe('collector native CLI static boundary (always runs)', () => {
  it('has an explicit native tool target without product or server dependencies', () => {
    const project = parse(
      readFileSync(join(repoRoot, 'macos/project.yml'), 'utf8'),
    ) as {
      targets: Record<string, Target>;
      schemes: Record<string, { build: { targets: Record<string, string> } }>;
    };
    const target = project.targets.EngramCollector;
    expect(target).toBeDefined();
    expect(target.type).toBe('tool');
    expect(target.sources).toContainEqual({
      path: 'EngramCollector/main.swift',
    });
    for (const source of target.sources) {
      expect(source.path).toMatch(/^EngramCollector\/[A-Za-z0-9_-]+\.swift$/);
    }
    expect(target.dependencies.filter((entry) => entry.target)).toEqual([
      { target: 'EngramCollectorCore' },
    ]);
    for (const entry of target.dependencies.filter((entry) => !entry.target)) {
      expect(entry).toEqual({ package: 'GRDB', product: 'GRDB-dynamic' });
    }
    const paths = target.settings.LD_RUNPATH_SEARCH_PATHS;
    expect(Array.isArray(paths) ? paths : String(paths).split(/\s+/)).toContain(
      '@executable_path/../Frameworks',
    );
    expect(project.schemes.EngramCollector.build.targets.EngramCollector).toBe(
      'all',
    );
  });

  it('keeps the entry point native and outside home, Keychain, and product startup helpers', () => {
    expect(existsSync(mainPath)).toBe(true);
    const source = readFileSync(mainPath, 'utf8');
    expect(source).toMatch(/^import EngramCollectorCore$/m);
    const imports = [...source.matchAll(/^import ([A-Za-z0-9_]+)$/gm)].map(
      (match) => match[1],
    );
    for (const name of imports) {
      expect([
        'Darwin',
        'Dispatch',
        'Foundation',
        'EngramCollectorCore',
      ]).toContain(name);
    }
    expect(source).not.toMatch(
      /\b(?:NSHomeDirectory|homeDirectoryForCurrentUser|ArchiveCredentialStore|KeychainSecretStore|SecItemCopyMatching|SecItemAdd|SecItemUpdate|EngramServiceRunner|EngramDatabaseWriter)\b/,
    );
    expect(source).not.toMatch(/\\\(error(?:\b|\.)/);
  });

  it('never treats an explicitly supplied relative binary path as a conditional skip', () => {
    if (binary !== undefined) expect(isAbsolute(binary)).toBe(true);
  });
});

describe.skipIf(binary === undefined)(
  'collector native process contract (conditional: ENGRAM_COLLECTOR_BINARY absolute path required)',
  () => {
    it('prints standalone help and states that once is only one bounded cycle', () => {
      const fixture = makeFixture();
      const result = runCLI(fixture, ['--help']);
      expect(result.status).toBe(0);
      expect(result.stderr).toBe('');
      for (const flag of ['--settings', '--credentials-file', '--once']) {
        expect(result.stdout).toContain(flag);
      }
      expect(result.stdout).toContain(
        '--once runs one bounded cycle; it does not wait for bootstrap or replica acknowledgements.',
      );
    });

    const argumentCases: {
      name: string;
      args: (fixture: Fixture) => string[];
    }[] = [
      { name: 'no arguments', args: () => [] },
      { name: 'unknown argument', args: () => [`--${canary}`] },
      { name: 'missing settings value', args: () => ['--settings'] },
      { name: 'once without settings', args: () => ['--once'] },
      {
        name: 'relative settings',
        args: () => ['--settings', `${canary}.json`],
      },
      { name: 'empty settings', args: () => ['--settings', ''] },
      {
        name: 'settings value is another flag',
        args: () => ['--settings', '--once'],
      },
      {
        name: 'duplicate settings',
        args: (f) => ['--settings', f.settings, '--settings', f.settings],
      },
      {
        name: 'duplicate once',
        args: (f) => ['--settings', f.settings, '--once', '--once'],
      },
      {
        name: 'missing credentials value',
        args: (f) => ['--settings', f.settings, '--credentials-file'],
      },
      {
        name: 'relative credentials',
        args: (f) => [
          '--settings',
          f.settings,
          '--credentials-file',
          `${canary}.json`,
        ],
      },
      {
        name: 'duplicate credentials',
        args: (f) => [
          '--settings',
          f.settings,
          '--credentials-file',
          f.credentials,
          '--credentials-file',
          f.credentials,
        ],
      },
      {
        name: 'help combined with settings',
        args: (f) => ['--help', '--settings', f.settings],
      },
      { name: 'help combined with once', args: () => ['--help', '--once'] },
      { name: 'duplicate help', args: () => ['--help', '--help'] },
      { name: 'positional settings', args: (f) => [f.settings] },
    ];
    it.each(argumentCases)(
      'rejects $name with usage status and no private text',
      ({ args }) => {
        const fixture = makeFixture();
        const result = runCLI(fixture, args(fixture));
        expect(result.status).toBe(64);
        expect(result.stderr).toContain(
          'engram-collector: invalid arguments\n',
        );
      },
    );

    for (const once of [false, true]) {
      const suffix = once ? ['--once'] : [];
      it(`treats missing explicit settings as OFF in ${once ? 'once' : 'resident'} mode`, () => {
        const fixture = makeFixture();
        expectDisabled(fixture, ['--settings', fixture.settings, ...suffix]);
        expect(existsSync(fixture.settings)).toBe(false);
      });

      it.each([
        { name: 'empty document', document: {} },
        {
          name: 'absent collector block',
          document: { runtimeRole: 'collector' },
        },
        {
          name: 'explicit OFF',
          document: { runtimeRole: 'collector', collector: { enabled: false } },
        },
      ])(
        `keeps $name cold in ${once ? 'once' : 'resident'} mode`,
        ({ document }) => {
          const fixture = makeFixture();
          writePrivate(fixture.settings, document);
          const before = readFileSync(fixture.settings);
          expectDisabled(fixture, ['--settings', fixture.settings, ...suffix]);
          expect(readFileSync(fixture.settings)).toEqual(before);
        },
      );
    }

    it.each(['missing', 'unsafe', 'symlink'] as const)(
      'does not read or repair a %s credentials file while OFF',
      (kind) => {
        const fixture = makeFixture();
        writePrivate(fixture.settings, { collector: { enabled: false } });
        if (kind === 'unsafe') {
          writePrivate(fixture.credentials, `${canary}:${privateRef}:not-json`);
          chmodSync(fixture.credentials, 0o644);
        }
        if (kind === 'symlink')
          symlinkSync(fixture.settings, fixture.credentials);
        const before =
          kind === 'missing' ? undefined : lstatSync(fixture.credentials);
        expectDisabled(fixture, [
          '--settings',
          fixture.settings,
          '--credentials-file',
          fixture.credentials,
          '--once',
        ]);
        if (before) {
          const after = lstatSync(fixture.credentials);
          expect(after.mode).toBe(before.mode);
          expect(after.ino).toBe(before.ino);
        } else expect(existsSync(fixture.credentials)).toBe(false);
        if (kind === 'unsafe') {
          expect(readFileSync(fixture.credentials, 'utf8')).toBe(
            `${canary}:${privateRef}:not-json`,
          );
        }
      },
    );

    it.each(['local', 'index', 'replica', canary])(
      'rejects enabled non-collector role %s before credentials or allocation',
      (role) => {
        const fixture = makeFixture();
        writePrivate(fixture.settings, {
          runtimeRole: role,
          collector: {
            enabled: true,
            shadowRoot: fixture.shadow,
            identityCatalog: fixture.identity,
            roots: [{ rootID: privateRef, rootPath: fixture.sources }],
          },
        });
        expectRuntimeFailure(fixture, [
          '--settings',
          fixture.settings,
          '--credentials-file',
          fixture.credentials,
          '--once',
        ]);
        expect(existsSync(fixture.credentials)).toBe(false);
      },
    );

    it.each([
      'permissions',
      'symlink',
      'hardlink',
      'directory',
      'malformed',
      'oversized',
    ] as const)(
      'rejects %s settings with only the fixed safe runtime classification',
      (kind) => {
        const fixture = makeFixture();
        const target = join(fixture.root, 'private-settings-target.json');
        if (kind === 'directory') mkdirSync(fixture.settings, { mode: 0o700 });
        else if (kind === 'symlink' || kind === 'hardlink') {
          writePrivate(target, {
            collector: { enabled: false },
            canary,
            privateRef,
          });
          if (kind === 'symlink') symlinkSync(target, fixture.settings);
          else linkSync(target, fixture.settings);
        } else {
          writePrivate(
            fixture.settings,
            kind === 'malformed'
              ? `${canary}:${privateRef}:not-json`
              : kind === 'oversized'
                ? ' '.repeat(1024 * 1024 + 1)
                : { collector: { enabled: false }, canary, privateRef },
          );
          if (kind === 'permissions') chmodSync(fixture.settings, 0o644);
        }
        const before = lstatSync(fixture.settings);
        const original = before.isFile()
          ? readFileSync(fixture.settings)
          : undefined;
        const linkedOriginal = existsSync(target)
          ? readFileSync(target)
          : undefined;
        expectRuntimeFailure(fixture, [
          '--settings',
          fixture.settings,
          '--once',
        ]);
        const after = lstatSync(fixture.settings);
        expect(after.mode).toBe(before.mode);
        expect(after.ino).toBe(before.ino);
        expect(after.nlink).toBe(before.nlink);
        if (original) expect(readFileSync(fixture.settings)).toEqual(original);
        if (linkedOriginal)
          expect(readFileSync(target)).toEqual(linkedOriginal);
      },
    );
  },
);
