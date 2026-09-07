#!/usr/bin/env node
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  openSync,
  readSync,
} from 'node:fs';
import { request as httpRequest } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { isAbsolute } from 'node:path';

const usage = `usage:
  collector-shadow-tls.mjs --cert <abs> --key <abs> \\
    --upstream http://127.0.0.1:<port> --port 0|<port>
`;

function fail(message) {
  process.stderr.write(`shadow-tls: ERROR: ${message}\n`);
  process.exit(1);
}

function requireValue(flag, rest) {
  if (rest.length < 1) {
    fail(`missing value for ${flag}`);
  }
  return rest.shift();
}

function parseArgs(argv) {
  if (argv.length === 0) {
    fail(`${usage.trimEnd()}\nmissing arguments`);
  }
  let cert;
  let key;
  let upstream;
  let port;
  const rest = [...argv];
  while (rest.length > 0) {
    const flag = rest.shift();
    switch (flag) {
      case '--cert':
        if (cert !== undefined) fail('duplicate argument: --cert');
        cert = requireValue('--cert', rest);
        break;
      case '--key':
        if (key !== undefined) fail('duplicate argument: --key');
        key = requireValue('--key', rest);
        break;
      case '--upstream':
        if (upstream !== undefined) fail('duplicate argument: --upstream');
        upstream = requireValue('--upstream', rest);
        break;
      case '--port':
        if (port !== undefined) fail('duplicate argument: --port');
        port = requireValue('--port', rest);
        break;
      default:
        fail('unknown argument');
    }
  }
  if (
    cert === undefined ||
    key === undefined ||
    upstream === undefined ||
    port === undefined
  ) {
    fail('missing required argument');
  }
  return { cert, key, upstream, port };
}

function parseListenPort(raw) {
  if (!/^\d+$/.test(raw)) {
    fail('invalid port');
  }
  const value = Number(raw);
  if (value !== 0 && (value < 1 || value > 65535)) {
    fail('invalid port');
  }
  return value;
}

function parseExactLoopbackUpstream(raw) {
  const match = /^http:\/\/127\.0\.0\.1:(\d+)$/.exec(raw);
  if (match === null) {
    fail('invalid upstream: exact http://127.0.0.1 loopback required');
  }
  const value = Number(match[1]);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    fail('invalid upstream port');
  }
  return value;
}

function errorCode(error) {
  if (error !== null && typeof error === 'object' && 'code' in error) {
    return error.code;
  }
  return undefined;
}

function loadRegularFile(path, label, asKey) {
  if (!isAbsolute(path)) {
    fail(`${label} must be absolute`);
  }
  let fd;
  try {
    fd = openSync(
      path,
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK,
    );
  } catch (error) {
    const code = errorCode(error);
    if (code === 'ELOOP' || code === 'EMLINK') {
      fail(`${label} must not be a symlink`);
    }
    fail(`missing ${label}`);
  }
  try {
    const stats = fstatSync(fd);
    if (stats.isSymbolicLink()) {
      fail(`${label} must not be a symlink`);
    }
    if (!stats.isFile()) {
      fail(`${label} must be a regular file`);
    }
    if (asKey) {
      if ((stats.mode & 0o7777) !== 0o600) {
        fail('key mode must be 0600');
      }
      const euid = process.geteuid?.();
      if (euid !== undefined && stats.uid !== euid) {
        fail('key owner permission');
      }
    }
    const size = stats.size;
    if (!Number.isInteger(size) || size < 0 || size > 1_048_576) {
      fail(`invalid ${label}`);
    }
    const buffer = Buffer.alloc(size);
    if (size > 0) {
      const bytesRead = readSync(fd, buffer, 0, size, 0);
      if (bytesRead !== size) {
        fail(`invalid ${label}`);
      }
    }
    return buffer;
  } finally {
    closeSync(fd);
  }
}

function loadCert(path) {
  return loadRegularFile(path, 'cert', false);
}

function loadKey(path) {
  return loadRegularFile(path, 'key', true);
}

function proxyRequest(clientReq, clientRes, upstreamPort) {
  const headers = { ...clientReq.headers };
  delete headers.connection;
  const upstreamReq = httpRequest(
    {
      hostname: '127.0.0.1',
      port: upstreamPort,
      method: clientReq.method,
      path: clientReq.url,
      headers,
    },
    (upstreamRes) => {
      clientRes.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
      upstreamRes.pipe(clientRes);
    },
  );
  upstreamReq.on('error', () => {
    if (!clientRes.headersSent) {
      clientRes.writeHead(502);
      clientRes.end();
    } else {
      clientRes.destroy();
    }
  });
  clientReq.on('aborted', () => {
    upstreamReq.destroy();
  });
  clientReq.pipe(upstreamReq);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const listenPort = parseListenPort(options.port);
  const upstreamPort = parseExactLoopbackUpstream(options.upstream);
  if (!isAbsolute(options.cert)) {
    fail('cert must be absolute');
  }
  if (!isAbsolute(options.key)) {
    fail('key must be absolute');
  }
  const cert = loadCert(options.cert);
  const key = loadKey(options.key);

  let admitting = true;
  let shuttingDown = false;
  let exited = false;
  const server = createHttpsServer({ cert, key }, (clientReq, clientRes) => {
    if (!admitting) {
      clientReq.destroy();
      return;
    }
    proxyRequest(clientReq, clientRes, upstreamPort);
  });
  server.keepAliveTimeout = 0;
  server.maxRequestsPerSocket = 1;

  const finish = () => {
    if (exited) {
      return;
    }
    exited = true;
    process.exit(0);
  };

  const shutdown = () => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    admitting = false;
    const timer = setTimeout(() => {
      server.closeAllConnections?.();
      finish();
    }, 2_000);
    timer.unref?.();
    server.close(() => {
      clearTimeout(timer);
      finish();
    });
    server.closeIdleConnections?.();
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
  process.on('SIGHUP', shutdown);

  server.on('error', () => {
    fail('listen failed');
  });
  server.listen(listenPort, '127.0.0.1', () => {
    const address = server.address();
    if (address === null || typeof address === 'string') {
      fail('listen failed');
    }
    process.stdout.write(`${JSON.stringify({ actualPort: address.port })}\n`);
  });
}

try {
  main();
} catch {
  fail('startup failed');
}
