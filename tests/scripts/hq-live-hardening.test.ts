import type { ChildProcess } from 'node:child_process';
import { spawn, spawnSync } from 'node:child_process';
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const hqLiveRoot = resolve(repoRoot, 'scripts/hq-live');
const ensurePath = join(hqLiveRoot, 'ensure-hq-live');
const ensureFromMacPath = join(hqLiveRoot, 'ensure-hq-live-from-mac');
const flockExecPath = join(hqLiveRoot, 'flock-exec');
const installScriptPath = join(hqLiveRoot, 'install-hq-boot-daemons.sh');
const installHelperPath = join(hqLiveRoot, 'install-launchd-plist');
const remoteWrapperTemplatePath = resolve(
  repoRoot,
  'macos/EngramRemoteServer/Packaging/run-engram-remote.zsh.template',
);

const tempRoots: string[] = [];

afterEach(() => {
  for (const root of tempRoots) {
    rmSync(root, { force: true, recursive: true });
  }
  tempRoots.length = 0;
});

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'engram-hq-live-test-'));
  tempRoots.push(root);
  return root;
}

async function waitForFile(path: string): Promise<void> {
  const deadline = Date.now() + 3_000;
  while (!existsSync(path)) {
    if (Date.now() >= deadline) {
      throw new Error(`timed out waiting for ${path}`);
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 10));
  }
}

async function waitForExit(child: ChildProcess): Promise<number | null> {
  return await new Promise((resolveExit, rejectExit) => {
    child.once('error', rejectExit);
    child.once('exit', (status) => resolveExit(status));
  });
}

async function runChild(
  command: string,
  args: string[],
): Promise<{ status: number | null; output: string }> {
  const child = spawn(command, args, {
    cwd: repoRoot,
    env: { ...process.env, LC_ALL: 'C' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout?.on('data', (chunk) => {
    output += String(chunk);
  });
  child.stderr?.on('data', (chunk) => {
    output += String(chunk);
  });
  const status = await waitForExit(child);
  return { status, output };
}

describe('HQ live boot hardening', () => {
  it('keeps the advisory lock held across exec and routes ensure through it_repro', async () => {
    const root = makeTempRoot();
    const lock = join(root, 'ensure.lock');
    const ready = join(root, 'ready');
    const release = join(root, 'release');
    const secondRan = join(root, 'second-ran');
    const holder = spawn(
      flockExecPath,
      [
        lock,
        '/bin/sh',
        '-c',
        'printf ready > "$1"; while [ ! -e "$2" ]; do sleep 0.02; done',
        'holder',
        ready,
        release,
      ],
      { stdio: 'ignore' },
    );

    try {
      await waitForFile(ready);
      const contender = spawnSync(
        flockExecPath,
        [lock, '/bin/sh', '-c', 'printf second > "$1"', 'contender', secondRan],
        { encoding: 'utf8' },
      );
      expect(contender.status).toBe(0);
      expect(existsSync(secondRan)).toBe(false);
    } finally {
      writeFileSync(release, 'release\n');
      expect(await waitForExit(holder)).toBe(0);
    }

    const ensure = readFileSync(ensurePath, 'utf8');
    expect(ensure).toContain('flock-exec');
    expect(ensure).not.toContain('lockdir');
    expect(ensure).not.toMatch(/kill\s+-0|\/bin\/kill\s+-0/);
  });

  it('exits without launching a second remote server when health is already ready_repro', async () => {
    const root = makeTempRoot();
    const currentBin = join(root, 'current/bin');
    const secrets = join(root, 'secrets');
    mkdirSync(currentBin, { recursive: true });
    mkdirSync(secrets, { recursive: true });

    const server = createServer((request, response) => {
      if (request.url === '/v1/health') {
        response.writeHead(200, { 'content-type': 'text/plain' });
        response.end('ok\n');
        return;
      }
      response.writeHead(404);
      response.end();
    });
    await new Promise<void>((resolveListen) => {
      server.listen(0, '127.0.0.1', resolveListen);
    });

    try {
      const port = (server.address() as AddressInfo).port;
      writeFileSync(
        join(secrets, 'legacy-v1.env'),
        `ENGRAM_REMOTE_HOST='127.0.0.1'\nENGRAM_REMOTE_PORT='${port}'\n`,
      );
      writeFileSync(join(secrets, 'archive-v2.env'), '');
      const launched = join(root, 'current/launched');
      const executable = join(currentBin, 'EngramRemoteServer');
      writeFileSync(
        executable,
        '#!/bin/sh\nprintf launched > "$(dirname "$0")/../launched"\n',
      );
      chmodSync(executable, 0o700);

      const renderedWrapper = readFileSync(remoteWrapperTemplatePath, 'utf8')
        .replace('__ENGRAM_REMOTE_ROOT__', root)
        .replace('__ENGRAM_REMOTE_SOURCE_REVISION__', 'a'.repeat(40));
      const wrapper = join(root, 'run-engram-remote');
      writeFileSync(wrapper, renderedWrapper);
      chmodSync(wrapper, 0o700);

      const result = await runChild('/bin/zsh', [wrapper]);

      expect(result.status, result.output).toBe(0);
      expect(existsSync(launched)).toBe(false);
    } finally {
      await new Promise<void>((resolveClose, rejectClose) => {
        server.close((error) => (error ? rejectClose(error) : resolveClose()));
      });
    }
  });

  it('installs a validated plist from a no-follow source fd with atomic replacement_repro', () => {
    expect(existsSync(installHelperPath)).toBe(true);
    if (!existsSync(installHelperPath)) return;

    const root = makeTempRoot();
    const source = join(root, 'source.plist');
    const sourceLink = join(root, 'source-link.plist');
    const destination = join(root, 'installed.plist');
    const plist = [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0"><dict><key>Label</key><string>com.engram.test</string></dict></plist>',
      '',
    ].join('\n');
    writeFileSync(source, plist);
    writeFileSync(destination, 'preserve on rejection\n');

    const install = spawnSync(
      installHelperPath,
      [
        source,
        destination,
        String(process.getuid?.() ?? 0),
        String(process.getgid?.() ?? 0),
        '0644',
        'com.engram.test',
      ],
      { encoding: 'utf8' },
    );
    expect(`${install.stdout}${install.stderr}`).toBe('');
    expect(install.status).toBe(0);
    expect(readFileSync(destination, 'utf8')).toBe(plist);
    expect(statSync(destination).mode & 0o777).toBe(0o644);

    symlinkSync(source, sourceLink);
    writeFileSync(destination, 'preserve on rejection\n');
    const rejected = spawnSync(
      installHelperPath,
      [
        sourceLink,
        destination,
        String(process.getuid?.() ?? 0),
        String(process.getgid?.() ?? 0),
        '0644',
        'com.engram.test',
      ],
      { encoding: 'utf8' },
    );
    expect(rejected.status).not.toBe(0);
    expect(readFileSync(destination, 'utf8')).toBe('preserve on rejection\n');

    const helper = readFileSync(installHelperPath, 'utf8');
    const installer = readFileSync(installScriptPath, 'utf8');
    expect(helper).toContain('os.O_NOFOLLOW');
    expect(helper).toContain('os.fstat');
    expect(helper).toContain('os.replace');
    expect(helper).toContain('dir_fd=destination_directory_fd');
    expect(installer).toContain('install-launchd-plist');
    expect(installer).not.toContain('/bin/cp');
  });

  it('validates only the two packaged LaunchDaemon labels without a tmp source_repro', () => {
    const root = makeTempRoot();
    const bundle = join(root, 'bundle');
    const untrustedWorkingDirectory = join(root, 'untrusted');
    mkdirSync(bundle);
    mkdirSync(untrustedWorkingDirectory);
    for (const name of [
      'install-hq-boot-daemons.sh',
      'install-launchd-plist',
      'com.engram.remote-server.boot.plist',
      'com.engram.service.boot.plist',
    ]) {
      copyFileSync(join(hqLiveRoot, name), join(bundle, name));
    }
    chmodSync(join(bundle, 'install-hq-boot-daemons.sh'), 0o700);
    chmodSync(join(bundle, 'install-launchd-plist'), 0o700);

    const validate = spawnSync(
      join(bundle, 'install-hq-boot-daemons.sh'),
      ['--validate-only'],
      {
        cwd: untrustedWorkingDirectory,
        env: { ...process.env, TMPDIR: untrustedWorkingDirectory },
        encoding: 'utf8',
      },
    );
    expect(`${validate.stdout}${validate.stderr}`).toContain(
      'validated com.engram.remote-server.boot com.engram.service.boot',
    );
    expect(validate.status).toBe(0);

    const servicePlist = join(bundle, 'com.engram.service.boot.plist');
    writeFileSync(
      servicePlist,
      readFileSync(servicePlist, 'utf8').replace(
        '<string>com.engram.service.boot</string>',
        '<string>com.attacker.service.boot</string>',
      ),
    );
    const rejected = spawnSync(
      join(bundle, 'install-hq-boot-daemons.sh'),
      ['--validate-only'],
      { cwd: untrustedWorkingDirectory, encoding: 'utf8' },
    );
    expect(rejected.status).not.toBe(0);

    const installer = readFileSync(installScriptPath, 'utf8');
    expect(installer).not.toContain('/tmp/engram-hq-boot-daemons');
  });

  it('persists degraded state and makes the marker visible to the Mac watchdog_repro', () => {
    const ensure = readFileSync(ensurePath, 'utf8');
    const ensureFromMac = readFileSync(ensureFromMacPath, 'utf8');

    expect(ensure).toContain('hq-boot-ensure.degraded');
    expect(ensure).toContain('ENGRAM_HQ_ENSURE_STATUS=degraded');
    expect(ensure).toMatch(/rm\s+-f\s+"\$degraded_sentinel"/);
    expect(ensureFromMac).toContain('ENGRAM_HQ_ENSURE_STATUS=degraded');
    expect(ensureFromMac).toContain('reported degraded');
  });
});
