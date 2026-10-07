import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

// Design §4.6 / test plan P6 (docs/superpowers/specs/2026-10-02-hq-local-collector-cutover-design.md):
// plan-hash mismatch refusal, no launchctl without --activate, rollback pointer
// round trip. Every host tool here is an inert stub inside a temp directory.
const workspace = resolve(import.meta.dirname, '../..');
const planner = join(workspace, 'scripts/plan-headless-install.mjs');
const executor = join(workspace, 'scripts/apply-headless-install.mjs');
const templates = join(workspace, 'macos/EngramCollector/Packaging');
const revisionA = 'a'.repeat(40);
const revisionB = 'b'.repeat(40);
const uid = process.getuid?.();
const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(workspace, '.engram-install-apply-test-'));
  roots.push(root);
  mkdirSync(join(root, 'tools/verifier'), { recursive: true, mode: 0o700 });
  mkdirSync(join(root, 'jobs'), { mode: 0o700 });
  writeFileSync(
    join(root, 'tools/verifier/package-collector.sh'),
    `#!/bin/bash\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'verifier-log'))}\nexit 0\n`,
    { mode: 0o700 },
  );
  // print: label not loaded; any mutation: accepted and logged, never real.
  writeFileSync(
    join(root, 'tools/launchctl'),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'launchctl-log'))}\nif [ "$1" = print ]; then echo 'Could not find service' >&2; exit 113; fi\nexit 0\n`,
    { mode: 0o700 },
  );
  writeFileSync(
    join(root, 'credentials.json'),
    JSON.stringify({ 'hq-token': 'CANARY-HQ', 'm1-token': 'CANARY-M1' }),
    { mode: 0o600 },
  );
  writeFileSync(join(root, 'settings.json'), 'never read by the executor\n', {
    mode: 0o600,
  });
  return root;
}

function makePackage(root: string, name: string, revision: string) {
  const directory = join(root, name);
  mkdirSync(join(directory, 'templates'), { recursive: true, mode: 0o700 });
  mkdirSync(join(directory, 'bin'), { mode: 0o700 });
  for (const [file, mode] of [
    ['run-engram-collector.zsh.template', 0o700],
    ['com.engram.collector.plist.template', 0o600],
  ] as const) {
    writeFileSync(
      join(directory, 'templates', file),
      readFileSync(join(templates, file)),
      { mode },
    );
  }
  // Inert collector: records its arguments; --initialize-identity leaves a
  // placeholder catalog file so later upgrade plans see an existing catalog.
  writeFileSync(
    join(directory, 'bin/EngramCollector'),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(join(root, 'collector-log'))}\nif [ "$1" = --initialize-identity ]; then mkdir -p "$(dirname "$2")"; : > "$2"; fi\nexit 0\n`,
    { mode: 0o700 },
  );
  writeFileSync(
    join(directory, 'BUILD-METADATA.json'),
    `${JSON.stringify({ product: 'EngramCollector', sourceRevision: revision })}\n`,
  );
  return directory;
}

function planArgs(root: string, extra: string[]) {
  return [
    '--dry-run',
    '--role',
    'collector',
    '--install-root',
    join(root, 'installation'),
    '--launch-agent-directory',
    join(root, 'jobs'),
    '--expected-home',
    join(root, 'home'),
    '--settings',
    join(root, 'settings.json'),
    '--credentials-file',
    join(root, 'credentials.json'),
    '--credential-ids',
    'hq-token,m1-token',
    '--identity-catalog',
    join(root, 'identity/archive.sqlite'),
    '--verifier-directory',
    join(root, 'tools/verifier'),
    '--launchctl',
    join(root, 'tools/launchctl'),
    ...extra,
  ];
}

function spawn(file: string, argv: string[], root: string) {
  const result = spawnSync(process.execPath, [file, ...argv], {
    cwd: root,
    encoding: 'utf8',
    timeout: 20_000,
    env: { PATH: '/usr/bin:/bin', CFFIXED_USER_HOME: join(root, 'unused') },
  });
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  return result;
}

function printPlan(root: string, name: string, extra: string[]) {
  const result = spawn(planner, planArgs(root, extra), root);
  expect(result.status, result.stderr).toBe(0);
  const file = join(root, `${name}.json`);
  writeFileSync(file, result.stdout, { mode: 0o600 });
  const plan = JSON.parse(result.stdout);
  return { file, plan, hash: plan.planHash as string };
}

function apply(root: string, file: string, hash: string, extra: string[] = []) {
  return spawn(
    executor,
    [
      '--plan',
      file,
      '--plan-hash',
      hash,
      '--launchctl',
      join(root, 'tools/launchctl'),
      '--verifier-directory',
      join(root, 'tools/verifier'),
      ...extra,
    ],
    root,
  );
}

const current = (root: string) =>
  readlinkSync(join(root, 'installation/current'));
const rollback = (root: string) =>
  readlinkSync(join(root, 'installation/rollback'));
const plist = (root: string) =>
  readFileSync(join(root, 'jobs/com.engram.collector.plist'), 'utf8');
// The planner's read-only `print` probe is logged too; only mutations matter.
const mutations = (root: string) =>
  existsSync(join(root, 'launchctl-log'))
    ? readFileSync(join(root, 'launchctl-log'), 'utf8')
        .split('\n')
        .filter((line) => line && !line.startsWith('print '))
    : [];

describe('headless install executor', () => {
  it('refuses a plan whose hash does not match and changes nothing', () => {
    const root = fixture();
    const pkg = makePackage(root, 'package', revisionA);
    const { file, plan, hash } = printPlan(root, 'plan', [
      '--package',
      pkg,
      '--assert-no-identity-catalog',
    ]);
    const wrong = apply(
      root,
      file,
      `${hash.slice(0, 63)}${hash.endsWith('0') ? '1' : '0'}`,
    );
    expect(wrong.status).not.toBe(0);
    expect(wrong.stderr).toMatch(/plan hash mismatch; refusing to apply/);
    writeFileSync(
      file,
      JSON.stringify({ ...plan, deploymentAuthorized: true }),
    );
    const tampered = apply(root, file, hash);
    expect(tampered.status).not.toBe(0);
    expect(tampered.stderr).toMatch(/plan hash mismatch; refusing to apply/);
    for (const path of ['installation', 'collector-log', 'identity'])
      expect(existsSync(join(root, path)), path).toBe(false);
    expect(mutations(root)).toEqual([]);
    expect(readFileSync(join(root, 'verifier-log'), 'utf8')).toBe(
      `--verify-only ${pkg}\n`,
    );
  });

  it('applies an install plan but runs no launchctl command without --activate', () => {
    const root = fixture();
    const pkg = makePackage(root, 'package', revisionA);
    const { file, plan, hash } = printPlan(root, 'plan', [
      '--package',
      pkg,
      '--assert-no-identity-catalog',
    ]);
    const result = apply(root, file, hash);
    expect(result.status, result.stderr).toBe(0);
    const report = JSON.parse(result.stdout);
    expect(report.applied).toEqual(
      plan.steps.map((step: { operation: string }) => step.operation),
    );
    expect(report.activation).toEqual({
      launchctl: 'NOT_RUN',
      commands: plan.activation.commands,
    });
    expect(mutations(root)).toEqual([]);
    const release = join(root, 'installation/releases', revisionA);
    expect(current(root)).toBe(release);
    expect(
      lstatSync(join(root, 'installation/run-engram-collector.zsh')).mode &
        0o7777,
    ).toBe(0o700);
    expect(
      lstatSync(join(root, 'jobs/com.engram.collector.plist')).mode & 0o7777,
    ).toBe(0o600);
    const rendered = plist(root);
    expect(rendered).not.toMatch(/__ENGRAM_[A-Z_]+__/);
    expect(rendered).toContain(`<string>${release}</string>`);
    expect(rendered).toContain('<key>Disabled</key>');
    expect(readFileSync(join(root, 'collector-log'), 'utf8')).toBe(
      `--initialize-identity ${join(root, 'identity/archive.sqlite')}\n--settings ${join(root, 'settings.json')} --initialize\n`,
    );
    expect(readFileSync(join(root, 'verifier-log'), 'utf8')).toBe(
      `--verify-only ${pkg}\n--verify-only ${release}\n`,
    );
    expect(readFileSync(join(root, 'settings.json'), 'utf8')).toBe(
      'never read by the executor\n',
    );
    // The same plan cannot be applied twice onto the state it created.
    const again = apply(root, file, hash);
    expect(again.status).not.toBe(0);
    expect(again.stderr).toMatch(/existing target/);
    expect(mutations(root)).toEqual([]);
  });

  it('activates only with --activate and only after an owner-only credentials metadata check', () => {
    const root = fixture();
    const pkg = makePackage(root, 'package', revisionA);
    const { file, hash } = printPlan(root, 'plan', [
      '--package',
      pkg,
      '--assert-no-identity-catalog',
    ]);
    chmodSync(join(root, 'credentials.json'), 0o644);
    const refused = apply(root, file, hash, ['--activate']);
    expect(refused.status).not.toBe(0);
    expect(refused.stderr).toMatch(
      /refusing activation: credentials file is not an owner-only/,
    );
    expect(JSON.parse(refused.stdout).applied).toHaveLength(7);
    expect(mutations(root)).toEqual([]);
    expect(`${refused.stdout}${refused.stderr}`).not.toContain('CANARY');

    const second = fixture();
    const secondPackage = makePackage(second, 'package', revisionA);
    const secondPlan = printPlan(second, 'plan', [
      '--package',
      secondPackage,
      '--assert-no-identity-catalog',
    ]);
    const activated = apply(second, secondPlan.file, secondPlan.hash, [
      '--activate',
    ]);
    expect(activated.status, activated.stderr).toBe(0);
    expect(
      JSON.parse(activated.stdout).activation.results.every(
        (entry: { ok: boolean }) => entry.ok,
      ),
    ).toBe(true);
    expect(mutations(second)).toEqual([
      `enable gui/${uid}/com.engram.collector`,
      `bootstrap gui/${uid} ${join(second, 'jobs/com.engram.collector.plist')}`,
      `kickstart -k gui/${uid}/com.engram.collector`,
    ]);
  });

  it('round-trips the rollback pointer across upgrade and rollback', () => {
    const root = fixture();
    const packageA = makePackage(root, 'package-a', revisionA);
    const packageB = makePackage(root, 'package-b', revisionB);
    const releaseA = join(root, 'installation/releases', revisionA);
    const releaseB = join(root, 'installation/releases', revisionB);
    const install = printPlan(root, 'install', [
      '--package',
      packageA,
      '--assert-no-identity-catalog',
    ]);
    expect(apply(root, install.file, install.hash).status).toBe(0);
    expect(current(root)).toBe(releaseA);
    expect(existsSync(join(root, 'installation/rollback'))).toBe(false);

    const upgrade = printPlan(root, 'upgrade', [
      '--package',
      packageB,
      '--kind',
      'upgrade',
    ]);
    expect(upgrade.plan.previousRelease).toBe(releaseA);
    expect(apply(root, upgrade.file, upgrade.hash).status).toBe(0);
    expect(current(root)).toBe(releaseB);
    expect(rollback(root)).toBe(releaseA);
    expect(plist(root)).toContain(`<string>${releaseB}</string>`);

    const back = printPlan(root, 'rollback', ['--kind', 'rollback']);
    expect(back.plan.sourceRevision).toBe(revisionA);
    expect(back.plan.previousRelease).toBe(releaseB);
    expect(apply(root, back.file, back.hash).status).toBe(0);
    expect(current(root)).toBe(releaseA);
    expect(rollback(root)).toBe(releaseB);
    expect(plist(root)).toContain(`<string>${releaseA}</string>`);
    expect(plist(root)).not.toContain(revisionB);

    // The applied rollback plan no longer matches the host state.
    const stale = apply(root, back.file, back.hash);
    expect(stale.status).not.toBe(0);
    expect(stale.stderr).toMatch(/changed since planning/);

    const forward = printPlan(root, 'rollback-again', ['--kind', 'rollback']);
    expect(forward.plan.sourceRevision).toBe(revisionB);
    expect(apply(root, forward.file, forward.hash).status).toBe(0);
    expect(current(root)).toBe(releaseB);
    expect(rollback(root)).toBe(releaseA);
    expect(plist(root)).toContain(`<string>${releaseB}</string>`);
    expect(mutations(root)).toEqual([]);
    expect(
      lstatSync(join(root, 'installation/run-engram-collector.zsh')).mode &
        0o7777,
    ).toBe(0o700);
  });
});
