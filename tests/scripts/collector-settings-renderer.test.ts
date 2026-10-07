import { spawnSync } from 'node:child_process';
import {
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const workspace = resolve(import.meta.dirname, '../..');
const script = join(workspace, 'scripts/render-collector-settings.mjs');
const fixtures = join(workspace, 'tests/fixtures/collector-install');
const profiles = join(fixtures, 'budget-profiles.json');
const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(workspace, '.engram-settings-render-test-'));
  roots.push(root);
  return root;
}

// The exact command that produced tests/fixtures/collector-install/rendered-settings.json.
function baseArgs(output: string, budgetProfiles = profiles) {
  return [
    '--home',
    '/Users/example',
    '--root',
    'codex-sessions:codex:~/.codex/sessions',
    '--root',
    'claude-projects:claude-code:~/.claude/projects',
    '--identity-catalog',
    '~/.engram-collector/identity/archive.sqlite',
    '--spool',
    '~/.engram-collector/spool',
    '--hq-url',
    'https://hq.example.invalid:8787',
    '--hq-credential-id',
    'hq-token',
    '--m1-url',
    'https://m1.example.invalid:8787',
    '--m1-credential-id',
    'm1-token',
    '--exclude-project-root',
    '~/Private',
    '--budget-profiles',
    budgetProfiles,
    '--budget-profile',
    'fixture',
    '--output',
    output,
  ];
}

function run(root: string, argv: string[]) {
  const result = spawnSync(process.execPath, [script, ...argv], {
    cwd: root,
    encoding: 'utf8',
    timeout: 10_000,
    env: { PATH: '/usr/bin:/bin', CFFIXED_USER_HOME: join(root, 'unused') },
  });
  expect(result.error).toBeUndefined();
  return result;
}

function replace(argv: string[], flag: string, value: string) {
  const copy = [...argv];
  copy[copy.indexOf(flag) + 1] = value;
  return copy;
}

describe('collector settings renderer', () => {
  it('renders the committed fixture byte-for-byte as an owner-only 0600 file', () => {
    const root = fixture();
    const output = join(root, 'settings.json');
    const result = run(root, baseArgs(output));
    expect(result.status, result.stderr).toBe(0);
    expect(lstatSync(output).mode & 0o7777).toBe(0o600);
    expect(readFileSync(output, 'utf8')).toBe(
      readFileSync(join(fixtures, 'rendered-settings.json'), 'utf8'),
    );
    expect(JSON.parse(result.stdout)).toEqual({
      kind: 'collector-settings-rendered',
      output,
      mode: '0600',
      roots: 2,
      budgetProfile: 'fixture',
      credentialIDs: ['hq-token', 'm1-token'],
    });
    const document = JSON.parse(readFileSync(output, 'utf8'));
    expect(Object.keys(document).sort()).toEqual(['collector', 'runtimeRole']);
    expect(document.runtimeRole).toBe('collector');
    expect(Object.keys(document.collector).sort()).toEqual([
      'budgets',
      'enabled',
      'identityCatalog',
      'privacy',
      'replicas',
      'roots',
      'shadowRoot',
    ]);
    expect(document.collector.enabled).toBe(true);
    expect(
      document.collector.replicas.map((r: { serverID: string }) => r.serverID),
    ).toEqual(['hq', 'm1']);
    expect(Object.keys(document.collector.budgets)).toHaveLength(17);
    expect(
      document.collector.roots.map((r: { rootPath: string }) => r.rootPath),
    ).toEqual([
      '/Users/example/.codex/sessions',
      '/Users/example/.claude/projects',
    ]);
    expect(document.collector.privacy).toEqual({
      revision: 1,
      excludedProjectRoots: ['/Users/example/Private'],
    });
  });

  it('never overwrites an existing settings file', () => {
    const root = fixture();
    const output = join(root, 'settings.json');
    writeFileSync(output, 'existing owner\n', { mode: 0o600 });
    const result = run(root, baseArgs(output));
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/EEXIST|exists/);
    expect(readFileSync(output, 'utf8')).toBe('existing owner\n');
  });

  it('takes credential IDs only; a token value has no option', () => {
    const root = fixture();
    const result = run(root, [
      ...baseArgs(join(root, 'settings.json')),
      '--hq-token',
      'x',
    ]);
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/unknown option/);
    expect(existsSync(join(root, 'settings.json'))).toBe(false);
  });

  it('accepts a kimi root with a project registry and an explicit parse format', () => {
    const root = fixture();
    const output = join(root, 'settings.json');
    const result = run(root, [
      ...baseArgs(output),
      '--root',
      'kimi-sessions:kimi:~/.kimi/sessions',
      '--project-registry',
      'kimi-sessions=~/.kimi/projects.json',
      '--parse-format',
      'claude-projects=claudeCustomProfile',
      '--root-revision',
      '3',
      '--privacy-revision',
      '2',
    ]);
    expect(result.status, result.stderr).toBe(0);
    const roots = JSON.parse(readFileSync(output, 'utf8')).collector.roots;
    expect(roots).toContainEqual({
      revision: 3,
      rootID: 'kimi-sessions',
      source: 'kimi',
      rootPath: '/Users/example/.kimi/sessions',
      projectRegistryPath: '/Users/example/.kimi/projects.json',
    });
    expect(
      roots.find((r: { rootID: string }) => r.rootID === 'claude-projects')
        .parseFormat,
    ).toBe('claudeCustomProfile');
  });

  it('rejects inputs the Swift collector settings parser would reject, without writing', () => {
    const root = fixture();
    const output = join(root, 'settings.json');
    const base = baseArgs(output);
    const narrow = join(root, 'profiles.json');
    const parsed = JSON.parse(readFileSync(profiles, 'utf8'));
    parsed.profiles.fixture.maxEntriesVisited = 0;
    writeFileSync(narrow, JSON.stringify(parsed));
    const cases: [string, string[], RegExp][] = [
      [
        'relative home',
        replace(base, '--home', 'Users/example'),
        /home must be/,
      ],
      [
        'http off loopback',
        replace(base, '--hq-url', 'http://hq.example.invalid'),
        /endpoint/,
      ],
      [
        'query string',
        replace(base, '--hq-url', 'https://hq.example.invalid/?x=1'),
        /endpoint/,
      ],
      [
        'same credential IDs',
        replace(base, '--m1-credential-id', 'hq-token'),
        /distinct/,
      ],
      [
        'same endpoint',
        replace(base, '--m1-url', 'https://HQ.example.invalid:8787/'),
        /distinct/,
      ],
      [
        'misnamed catalog',
        replace(
          base,
          '--identity-catalog',
          '~/.engram-collector/identity/catalog.sqlite',
        ),
        /archive\.sqlite/,
      ],
      [
        'root under the spool',
        [...base, '--root', 'x:codex:~/.engram-collector/spool/x'],
        /overlaps/,
      ],
      [
        'kimi without registry',
        [...base, '--root', 'k:kimi:~/.kimi'],
        /requires --project-registry/,
      ],
      [
        'registry for codex',
        [...base, '--project-registry', 'codex-sessions=~/r.json'],
        /does not take a project registry/,
      ],
      [
        'unknown source',
        [...base, '--root', 'x:notepad:~/x'],
        /unsupported source/,
      ],
      [
        'format mismatch',
        [...base, '--parse-format', 'codex-sessions=claudeDefault'],
        /not valid/,
      ],
      [
        'duplicate root ID',
        [...base, '--root', 'codex-sessions:codex:~/other'],
        /duplicate root ID/,
      ],
      [
        'unknown profile',
        replace(base, '--budget-profile', 'nope'),
        /unknown budget profile/,
      ],
      [
        'budget out of range',
        baseArgs(output, narrow),
        /outside the collector range/,
      ],
      [
        'trailing slash root',
        [...base, '--root', 'x:codex:~/x/'],
        /not normalized/,
      ],
      [
        'excluded root not absolute',
        [...base, '--exclude-project-root', 'relative'],
        /not normalized/,
      ],
    ];
    for (const [name, argv, pattern] of cases) {
      const result = run(root, argv);
      expect(result.status, name).not.toBe(0);
      expect(result.stderr, name).toMatch(pattern);
      expect(existsSync(output), name).toBe(false);
    }
  });
});
