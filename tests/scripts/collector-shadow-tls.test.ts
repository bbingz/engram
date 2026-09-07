import type { ChildProcess } from 'node:child_process';
import { spawn, spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import { createServer } from 'node:http';
import { request as httpsRequest } from 'node:https';
import type { Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const helperPath = resolve(repoRoot, 'scripts/collector-shadow-tls.mjs');
const opensslPath = '/usr/bin/openssl';
const helperExists = existsSync(helperPath);
const isolatedEnv: NodeJS.ProcessEnv = {
  PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
  LANG: 'C',
  LC_ALL: 'C',
};

let tempRoots: string[] = [];
const ownedChildren: ChildProcess[] = [];

afterEach(async () => {
  for (const child of ownedChildren.splice(0)) {
    await stopOwnedChild(child);
  }
  for (const root of tempRoots) {
    rmSync(root, { force: true, recursive: true });
  }
  tempRoots = [];
});

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'engram-collector-shadow-tls-test-'));
  tempRoots.push(root);
  return root;
}

function runOpenssl(args: string[]): {
  status: number | null;
  output: string;
} {
  const result = spawnSync(opensslPath, args, {
    encoding: 'utf8',
    env: isolatedEnv,
    killSignal: 'SIGKILL',
    timeout: 3_000,
  });
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  return {
    status: result.status,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`,
  };
}

function mintLoopbackTls(directory: string): { cert: string; key: string } {
  const cert = join(directory, 'cert.pem');
  const key = join(directory, 'key.pem');
  const keyResult = runOpenssl(['genrsa', '-out', key, '2048']);
  expect(keyResult.status).toBe(0);
  chmodSync(key, 0o600);
  const certResult = runOpenssl([
    'req',
    '-new',
    '-x509',
    '-key',
    key,
    '-out',
    cert,
    '-days',
    '1',
    '-subj',
    '/CN=127.0.0.1',
  ]);
  expect(certResult.status).toBe(0);
  chmodSync(cert, 0o644);
  return { cert, key };
}

function runHelperSync(args: string[]): {
  status: number | null;
  signal: NodeJS.Signals | null;
  error: Error | undefined;
  stdout: string;
  stderr: string;
  output: string;
} {
  const result = spawnSync(process.execPath, [helperPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    env: isolatedEnv,
    killSignal: 'SIGKILL',
    timeout: 3_000,
  });
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';
  return {
    status: result.status,
    signal: result.signal,
    error: result.error,
    stdout,
    stderr,
    output: `${stdout}${stderr}`,
  };
}

function expectRejectedBeforeListen(
  result: ReturnType<typeof runHelperSync>,
  expected: RegExp,
): void {
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  expect(result.status).toEqual(expect.any(Number));
  expect(result.status).not.toBe(0);
  expect(result.output).toMatch(expected);
  expect(readReadyLine(result.stdout)).toBeNull();
}

function dummyPair(root = makeTempRoot()): {
  cert: string;
  key: string;
  root: string;
} {
  return {
    root,
    cert: join(root, 'dummy-cert.pem'),
    key: join(root, 'dummy-key.pem'),
  };
}

function readReadyLine(stdout: string): Record<string, unknown> | null {
  const lines = stdout.split(/\r?\n/).filter((line) => line.length > 0);
  if (lines.length !== 1) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(lines[0] ?? '');
    if (
      parsed === null ||
      typeof parsed !== 'object' ||
      Array.isArray(parsed)
    ) {
      return null;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

function firstReadyPort(stdout: string): number | null {
  const first = stdout.split(/\r?\n/).find((line) => line.length > 0);
  if (first === undefined) {
    return null;
  }
  try {
    const parsed: unknown = JSON.parse(first);
    if (
      parsed === null ||
      typeof parsed !== 'object' ||
      Array.isArray(parsed) ||
      typeof (parsed as { actualPort?: unknown }).actualPort !== 'number'
    ) {
      return null;
    }
    const actualPort = (parsed as { actualPort: number }).actualPort;
    if (
      !Number.isInteger(actualPort) ||
      actualPort <= 0 ||
      actualPort >= 65536
    ) {
      return null;
    }
    return actualPort;
  } catch {
    return null;
  }
}

function parseReadyLine(stdout: string): { actualPort: number } {
  const parsed = readReadyLine(stdout);
  expect(parsed).not.toBeNull();
  expect(Object.keys(parsed ?? {}).sort()).toEqual(['actualPort']);
  expect(typeof parsed?.actualPort).toBe('number');
  const actualPort = parsed?.actualPort as number;
  expect(Number.isInteger(actualPort)).toBe(true);
  expect(actualPort).toBeGreaterThan(0);
  expect(actualPort).toBeLessThan(65536);
  return { actualPort };
}

const childClosed = new WeakMap<ChildProcess, Promise<void>>();

async function waitForClose(
  child: ChildProcess,
  timeoutMs: number,
): Promise<void> {
  const closed = childClosed.get(child);
  if (closed === undefined) {
    throw new Error(`close waiter was not preinstalled for pid ${child.pid}`);
  }
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      closed,
      new Promise<never>((_, rejectClose) => {
        timer = setTimeout(() => {
          rejectClose(
            new Error(`timed out waiting for pid ${child.pid} to close`),
          );
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer);
    }
  }
}

function childStillLive(child: ChildProcess): boolean {
  return child.exitCode === null && child.signalCode === null;
}

async function stopOwnedChild(child: ChildProcess): Promise<void> {
  const pid = child.pid;
  if (pid !== undefined && childStillLive(child)) {
    try {
      process.kill(pid, 'SIGTERM');
    } catch {
      // Process already gone; still wait for the preinstalled close.
    }
  }
  try {
    await waitForClose(child, 1_000);
  } catch {
    if (pid !== undefined && childStillLive(child)) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        return;
      }
    }
    await waitForClose(child, 1_000);
  }
}

type TrackedHelper = {
  child: ChildProcess;
  stdout: string;
  stderr: string;
};

function startHelper(args: string[]): TrackedHelper {
  const child = spawn(process.execPath, [helperPath, ...args], {
    cwd: repoRoot,
    env: isolatedEnv,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  childClosed.set(
    child,
    new Promise((resolveClosed) => {
      child.once('close', () => resolveClosed());
    }),
  );
  const tracked: TrackedHelper = { child, stdout: '', stderr: '' };
  child.stdout?.setEncoding('utf8');
  child.stderr?.setEncoding('utf8');
  child.stdout?.on('data', (chunk) => {
    tracked.stdout += String(chunk);
  });
  child.stderr?.on('data', (chunk) => {
    tracked.stderr += String(chunk);
  });
  ownedChildren.push(child);
  return tracked;
}

async function waitForFirstReadyPort(
  tracked: TrackedHelper,
  timeoutMs = 3_000,
): Promise<number> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (tracked.child.exitCode !== null || tracked.child.signalCode !== null) {
      throw new Error(
        `helper exited before ready JSON: ${tracked.stdout}${tracked.stderr}`,
      );
    }
    const port = firstReadyPort(tracked.stdout);
    if (port !== null) {
      return port;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(
    `timed out waiting for ready JSON from pid ${tracked.child.pid}: ${tracked.stdout}${tracked.stderr}`,
  );
}

function listenAddress(pid: number, port: number): string {
  const result = spawnSync(
    'lsof',
    ['-nP', '-p', String(pid), '-a', '-iTCP', '-sTCP:LISTEN'],
    {
      encoding: 'utf8',
      env: isolatedEnv,
      killSignal: 'SIGKILL',
      timeout: 3_000,
    },
  );
  expect(result.error).toBeUndefined();
  expect(result.signal).toBeNull();
  expect(result.status).toBe(0);
  const output = `${result.stdout ?? ''}${result.stderr ?? ''}`;
  const listens = [...output.matchAll(/TCP\s+(\S+)\s+\(LISTEN\)/g)].map(
    (match) => match[1] ?? '',
  );
  expect(listens.length).toBeGreaterThan(0);
  for (const address of listens) {
    expect(address.startsWith('127.0.0.1:')).toBe(true);
  }
  expect(listens).toContain(`127.0.0.1:${port}`);
  return output;
}

async function startUpstream(
  handler: (request: IncomingMessage, response: ServerResponse) => void,
): Promise<{ port: number; close: () => Promise<void> }> {
  const server: Server = createServer(handler);
  const sockets = new Set<Socket>();
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => {
      sockets.delete(socket);
    });
  });
  await new Promise<void>((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(0, '127.0.0.1', () => resolveListen());
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('upstream did not bind a TCP port');
  }
  return {
    port: address.port,
    close: async () => {
      let settled = false;
      await new Promise<void>((resolveClose, rejectClose) => {
        const finish = (error?: Error) => {
          if (settled) {
            return;
          }
          settled = true;
          clearTimeout(timer);
          for (const socket of sockets) {
            socket.destroy();
          }
          sockets.clear();
          if (error) rejectClose(error);
          else resolveClose();
        };
        const timer = setTimeout(() => finish(), 1_000);
        server.close((error) => finish(error ?? undefined));
      });
    },
  };
}

async function requestThroughTerminator(
  port: number,
  options: {
    method: string;
    path: string;
    headers?: Record<string, string>;
    body?: string;
  },
): Promise<{ status: number | undefined; headers: string[]; body: string }> {
  const deadline = Date.now() + 3_000;
  return await new Promise((resolveRequest, rejectRequest) => {
    let settled = false;
    const settle = (action: () => void) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      action();
    };
    const request = httpsRequest(
      {
        hostname: '127.0.0.1',
        port,
        path: options.path,
        method: options.method,
        headers: options.headers,
        rejectUnauthorized: false,
        agent: false,
      },
      (response) => {
        const chunks: Buffer[] = [];
        let ended = false;
        response.on('data', (chunk) => {
          chunks.push(Buffer.from(chunk));
        });
        response.on('end', () => {
          ended = true;
          settle(() =>
            resolveRequest({
              status: response.statusCode,
              headers: response.rawHeaders,
              body: Buffer.concat(chunks).toString('utf8'),
            }),
          );
        });
        response.on('aborted', () => {
          settle(() => rejectRequest(new Error('response aborted')));
        });
        response.on('error', (error) => {
          settle(() => rejectRequest(error));
        });
        response.on('close', () => {
          if (!ended) {
            settle(() => rejectRequest(new Error('response closed')));
          }
        });
      },
    );
    const timer = setTimeout(
      () => {
        request.destroy(new Error('requestThroughTerminator timed out'));
        settle(() =>
          rejectRequest(new Error('requestThroughTerminator timed out')),
        );
      },
      Math.max(0, deadline - Date.now()),
    );
    request.on('error', (error) => {
      settle(() => rejectRequest(error));
    });
    if (options.body !== undefined) {
      request.write(options.body);
    }
    request.end();
  });
}

describe('collector shadow TLS openssl fixture mint', () => {
  it('uses the installed Apple openssl CLI to mint a temp loopback cert and 0600 key', () => {
    expect(existsSync(opensslPath)).toBe(true);
    const version = runOpenssl(['version']);
    expect(version.status).toBe(0);
    expect(version.output).toMatch(/LibreSSL|OpenSSL/);
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    expect(lstatSync(key).isFile()).toBe(true);
    expect(lstatSync(key).isSymbolicLink()).toBe(false);
    expect(lstatSync(key).mode & 0o777).toBe(0o600);
    expect(lstatSync(cert).isFile()).toBe(true);
    expect(lstatSync(cert).isSymbolicLink()).toBe(false);
    expect(lstatSync(cert).mode & 0o777).toBe(0o644);
    expect(
      runOpenssl(['x509', '-in', cert, '-noout', '-subject']).output,
    ).toContain('127.0.0.1');
  });
});

describe.skipIf(!helperExists)('collector shadow TLS helper contract', () => {
  it.each([
    { name: 'no arguments', args: () => [], expected: /usage:|missing/i },
    {
      name: 'unknown argument',
      args: () => ['--unknown'],
      expected: /unknown argument/i,
    },
    {
      name: 'missing cert value',
      args: () => ['--cert'],
      expected: /missing value|usage:/i,
    },
    {
      name: 'duplicate cert',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--cert',
          join(files.root, 'other-cert.pem'),
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /duplicate/i,
    },
    {
      name: 'duplicate key',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--key',
          join(files.root, 'other-key.pem'),
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /duplicate/i,
    },
    {
      name: 'duplicate upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9',
          '--upstream',
          'http://127.0.0.1:10',
          '--port',
          '0',
        ];
      },
      expected: /duplicate/i,
    },
    {
      name: 'duplicate port',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '0',
          '--port',
          '1',
        ];
      },
      expected: /duplicate/i,
    },
    {
      name: 'relative cert',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          'relative-cert.pem',
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /absolute/i,
    },
    {
      name: 'relative key',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          'relative-key.pem',
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /absolute/i,
    },
    {
      name: 'nonloopback upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://8.8.8.8:80',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream/i,
    },
    {
      name: 'localhost upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://localhost:9',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream/i,
    },
    {
      name: '127.1 upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.1:9',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream/i,
    },
    {
      name: 'integer-host upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://2130706433:9',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream/i,
    },
    {
      name: 'userinfo upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://user:pass@127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream|userinfo/i,
    },
    {
      name: 'query upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9?x=1',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream|query/i,
    },
    {
      name: 'fragment upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9#frag',
          '--port',
          '0',
        ];
      },
      expected: /loopback|127\.0\.0\.1|upstream|fragment/i,
    },
    {
      name: 'path upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9/open',
          '--port',
          '0',
        ];
      },
      expected: /upstream|path|loopback/i,
    },
    {
      name: 'https upstream',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'https://127.0.0.1:9',
          '--port',
          '0',
        ];
      },
      expected: /upstream|http/i,
    },
    {
      name: 'port out of range',
      args: () => {
        const files = dummyPair();
        return [
          '--cert',
          files.cert,
          '--key',
          files.key,
          '--upstream',
          'http://127.0.0.1:9',
          '--port',
          '65536',
        ];
      },
      expected: /port/i,
    },
  ])(
    'rejects invalid invocation before listen: $name',
    ({ args, expected }) => {
      expectRejectedBeforeListen(runHelperSync(args()), expected);
    },
  );

  it('rejects a leaf symlink key before listen', () => {
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    const link = join(root, 'key-link.pem');
    symlinkSync(key, link);
    expectRejectedBeforeListen(
      runHelperSync([
        '--cert',
        cert,
        '--key',
        link,
        '--upstream',
        'http://127.0.0.1:9',
        '--port',
        '0',
      ]),
      /symlink|regular|key/i,
    );
  });

  it('rejects a non-regular key before listen', () => {
    const root = makeTempRoot();
    const { cert } = mintLoopbackTls(root);
    const directoryKey = join(root, 'key-dir');
    mkdirSync(directoryKey);
    expectRejectedBeforeListen(
      runHelperSync([
        '--cert',
        cert,
        '--key',
        directoryKey,
        '--upstream',
        'http://127.0.0.1:9',
        '--port',
        '0',
      ]),
      /regular|directory|key/i,
    );
  });

  it('rejects a leaf symlink cert before listen', () => {
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    const link = join(root, 'cert-link.pem');
    symlinkSync(cert, link);
    expectRejectedBeforeListen(
      runHelperSync([
        '--cert',
        link,
        '--key',
        key,
        '--upstream',
        'http://127.0.0.1:9',
        '--port',
        '0',
      ]),
      /symlink|regular|cert/i,
    );
  });

  it('rejects a non-regular cert before listen', () => {
    const root = makeTempRoot();
    const { key } = mintLoopbackTls(root);
    const directoryCert = join(root, 'cert-dir');
    mkdirSync(directoryCert);
    expectRejectedBeforeListen(
      runHelperSync([
        '--cert',
        directoryCert,
        '--key',
        key,
        '--upstream',
        'http://127.0.0.1:9',
        '--port',
        '0',
      ]),
      /regular|directory|cert/i,
    );
  });

  it('rejects a key whose mode is not 0600 before listen', () => {
    // Owner 0600 applies only to the private key. Cert 0644 remains valid.
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    chmodSync(key, 0o644);
    expectRejectedBeforeListen(
      runHelperSync([
        '--cert',
        cert,
        '--key',
        key,
        '--upstream',
        'http://127.0.0.1:9',
        '--port',
        '0',
      ]),
      /mode|0600|permission|key/i,
    );
    expect(lstatSync(key).mode & 0o777).toBe(0o644);
  });

  it('rejects malformed cert without leaking path or bytes', () => {
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    const canary = 'SHADOWTLS_MALFORMED_CERT_CANARY_7f3c';
    writeFileSync(cert, canary, { mode: 0o644 });
    const result = runHelperSync([
      '--cert',
      cert,
      '--key',
      key,
      '--upstream',
      'http://127.0.0.1:9',
      '--port',
      '0',
    ]);
    expectRejectedBeforeListen(result, /cert|key|read|failed|invalid/i);
    expect(result.stderr).not.toContain(cert);
    expect(result.stderr).not.toContain(key);
    expect(result.output).not.toContain(canary);
    expect(result.output).not.toMatch(/BEGIN |PRIVATE KEY/);
  });

  it('rejects malformed key without leaking path or bytes', () => {
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    const canary = 'SHADOWTLS_MALFORMED_KEY_CANARY_9e1a';
    writeFileSync(key, canary, { mode: 0o600 });
    const result = runHelperSync([
      '--cert',
      cert,
      '--key',
      key,
      '--upstream',
      'http://127.0.0.1:9',
      '--port',
      '0',
    ]);
    expectRejectedBeforeListen(result, /cert|key|read|failed|invalid/i);
    expect(result.stderr).not.toContain(cert);
    expect(result.stderr).not.toContain(key);
    expect(result.output).not.toContain(canary);
    expect(result.output).not.toMatch(/BEGIN |PRIVATE KEY/);
  });

  it('binds 127.0.0.1 only, prints one ready JSON line with actualPort, and proxies Host/Origin/Cookie/method/path/body', async () => {
    const root = makeTempRoot();
    const { cert, key } = mintLoopbackTls(root);
    const seen: {
      method?: string;
      url?: string;
      host?: string;
      origin?: string;
      cookie?: string;
      body: string;
    } = { body: '' };
    const upstream = await startUpstream((request, response) => {
      const chunks: Buffer[] = [];
      request.on('data', (chunk) => {
        chunks.push(Buffer.from(chunk));
      });
      request.on('end', () => {
        seen.method = request.method;
        seen.url = request.url;
        seen.host = request.headers.host;
        seen.origin = Array.isArray(request.headers.origin)
          ? request.headers.origin[0]
          : request.headers.origin;
        seen.cookie = Array.isArray(request.headers.cookie)
          ? request.headers.cookie[0]
          : request.headers.cookie;
        seen.body = Buffer.concat(chunks).toString('utf8');
        response.statusCode = 201;
        response.setHeader('Set-Cookie', ['a=1', 'b=2']);
        response.end('upstream-ok');
      });
    });
    let tracked: TrackedHelper | undefined;
    try {
      tracked = startHelper([
        '--cert',
        cert,
        '--key',
        key,
        '--upstream',
        `http://127.0.0.1:${upstream.port}`,
        '--port',
        '0',
      ]);
      expect(tracked.child.pid).toEqual(expect.any(Number));
      const actualPort = await waitForFirstReadyPort(tracked);
      listenAddress(tracked.child.pid as number, actualPort);
      const proxied = await requestThroughTerminator(actualPort, {
        method: 'PUT',
        path: '/v1/web?x=1',
        headers: {
          Host: `127.0.0.1:${actualPort}`,
          Origin: 'http://127.0.0.1:9',
          Cookie: 'session=shadow',
          'Content-Type': 'text/plain',
        },
        body: 'payload-body',
      });
      expect(seen.method).toBe('PUT');
      expect(seen.url).toBe('/v1/web?x=1');
      expect(seen.host).toBe(`127.0.0.1:${actualPort}`);
      expect(seen.origin).toBe('http://127.0.0.1:9');
      expect(seen.cookie).toBe('session=shadow');
      expect(seen.body).toBe('payload-body');
      expect(proxied.status).toBe(201);
      expect(proxied.body).toBe('upstream-ok');
      const cookieHeader = proxied.headers
        .map((value, index) =>
          index % 2 === 0
            ? `${value}: ${proxied.headers[index + 1]}`
            : undefined,
        )
        .filter((value): value is string => value !== undefined)
        .join('\n');
      expect(cookieHeader).toMatch(/Set-Cookie: a=1/i);
      expect(cookieHeader).toMatch(/Set-Cookie: b=2/i);
      process.kill(tracked.child.pid as number, 'SIGTERM');
      await waitForClose(tracked.child, 2_000);
      expect(tracked.child.exitCode).toBe(0);
      expect(tracked.child.signalCode).toBeNull();
      parseReadyLine(tracked.stdout);
    } finally {
      if (tracked !== undefined) {
        await stopOwnedChild(tracked.child);
      }
      await upstream.close();
    }
  });

  it.each(['SIGTERM', 'SIGINT', 'SIGHUP'] as const)(
    'drains one pending request then exits 0 after %s',
    async (signal) => {
      const root = makeTempRoot();
      const { cert, key } = mintLoopbackTls(root);
      let sawPending: () => void = () => {};
      const pending = new Promise<void>((resolvePending) => {
        sawPending = resolvePending;
      });
      let releaseUpstream: () => void = () => {};
      const released = new Promise<void>((resolveRelease) => {
        releaseUpstream = resolveRelease;
      });
      const upstream = await startUpstream((_request, response) => {
        sawPending();
        void released.then(() => {
          response.statusCode = 204;
          response.end();
        });
      });
      let tracked: TrackedHelper | undefined;
      try {
        tracked = startHelper([
          '--cert',
          cert,
          '--key',
          key,
          '--upstream',
          `http://127.0.0.1:${upstream.port}`,
          '--port',
          '0',
        ]);
        const pid = tracked.child.pid;
        expect(pid).toEqual(expect.any(Number));
        const actualPort = await waitForFirstReadyPort(tracked);
        const inFlight = requestThroughTerminator(actualPort, {
          method: 'GET',
          path: '/drain',
        });
        try {
          await Promise.race([
            pending,
            new Promise((_, reject) => {
              setTimeout(
                () =>
                  reject(new Error('upstream never saw the pending request')),
                3_000,
              );
            }),
          ]);
        } catch (error) {
          await Promise.allSettled([inFlight]);
          throw error;
        }
        process.kill(pid as number, signal);
        releaseUpstream();
        const settled = await inFlight;
        expect(settled.status).toBe(204);
        await waitForClose(tracked.child, 2_000);
        expect(tracked.child.exitCode).toBe(0);
        expect(tracked.child.signalCode).toBeNull();
        parseReadyLine(tracked.stdout);
        await expect(
          requestThroughTerminator(actualPort, {
            method: 'GET',
            path: '/',
          }),
        ).rejects.toThrow();
      } finally {
        releaseUpstream();
        if (tracked !== undefined) {
          await stopOwnedChild(tracked.child);
        }
        await upstream.close();
      }
    },
  );
});
