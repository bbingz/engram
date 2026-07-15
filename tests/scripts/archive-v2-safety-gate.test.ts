import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = resolve(import.meta.dirname, '../..');
const script = resolve(repoRoot, 'scripts/check-archive-v2-safety.sh');

function runGate(root = repoRoot): {
  status: number | null;
  stdout: string;
  stderr: string;
} {
  try {
    const stdout = execFileSync('bash', [script], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        ENGRAM_ARCHIVE_V2_GATE_ROOT: root,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { status: 0, stdout, stderr: '' };
  } catch (error) {
    const failure = error as {
      status?: number | null;
      stdout?: string;
      stderr?: string;
    };
    return {
      status: failure.status ?? 1,
      stdout: failure.stdout ?? '',
      stderr: failure.stderr ?? '',
    };
  }
}

function write(root: string, relativePath: string, content: string): void {
  const target = join(root, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content, 'utf8');
}

function makeSafeFixture(): string {
  const root = mkdtempSync(join(tmpdir(), 'engram-archive-v2-gate-'));
  write(
    root,
    'macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift',
    [
      'public protocol ArchiveReplicaBackend {',
      '  func getObject(digest: String) async throws -> Data',
      '}',
    ].join('\n'),
  );
  write(
    root,
    'macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift',
    [
      'guard Darwin.unlink(objectURL.path) == 0 else {',
      '  throw TestError()',
      '}',
      '_ = Darwin.unlink(temporaryURL.path)',
    ].join('\n'),
  );
  write(
    root,
    'macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift',
    [
      'guard Darwin.unlink(quarantineURL.path) == 0 else {',
      '  throw TestError()',
      '}',
    ].join('\n'),
  );
  write(
    root,
    'macos/EngramRemoteServer/Core/ArchiveStore.swift',
    '_ = Darwin.unlink(temporaryURL.path)\n',
  );
  write(
    root,
    'macos/EngramRemoteServer/Core/ArchiveRoutes.swift',
    [
      'for path in ["/v2/archive/objects/:digest"] {',
      '  router.delete(RouterPath(path)) { request, _ in',
      '    await observed(request, endpoint: endpoint, telemetry: telemetry) {',
      '      guard authorized(request, token: token) else { return unauthorized() }',
      '      return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")',
      '    }',
      '  }',
      '}',
      'router.delete("/v2/archive/**") { request, _ in',
      '  await observed(request, endpoint: "unknown", telemetry: telemetry) {',
      '    guard authorized(request, token: token) else { return unauthorized() }',
      '    return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")',
      '  }',
      '}',
    ].join('\n'),
  );
  write(
    root,
    'macos/EngramRemoteServer/Core/EngramRemoteServerApp.swift',
    'router.delete("/v1/bundles/:key") { _, _ in legacyDelete() }\n',
  );
  write(
    root,
    'macos/EngramService/Core/ArchiveTranscriptResolver.swift',
    'try FileManager.default.removeItem(at: replay.directoryURL)\n',
  );
  return root;
}

describe('archive v2 release safety gate', () => {
  it('is present and passes against the repository', () => {
    expect(existsSync(script)).toBe(true);
    const result = runGate();
    expect(result.status).toBe(0);
    expect(result.stdout).toContain('archive v2 safety gate ok');
  });

  it('accepts only the explicit archive cleanup and reclamation sites', () => {
    const result = runGate(makeSafeFixture());
    expect(result.status).toBe(0);
  });

  it('rejects a duplicate quarantine unlink in ArchiveSourceReclaimer', () => {
    const root = makeSafeFixture();
    const reclaimer = join(
      root,
      'macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift',
    );
    const duplicate = [
      readFileSync(reclaimer, 'utf8'),
      'guard Darwin.unlink(quarantineURL.path) == 0 else {',
      '  throw TestError()',
      '}',
    ].join('\n');
    writeFileSync(reclaimer, duplicate, 'utf8');

    const result = runGate(root);

    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'ArchiveSourceReclaimer quarantine unlink must occur exactly once',
    );
  });

  it('rejects a duplicate object unlink in ImmutableArchiveCAS', () => {
    const root = makeSafeFixture();
    const cas = join(
      root,
      'macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift',
    );
    const duplicate = [
      readFileSync(cas, 'utf8'),
      'guard Darwin.unlink(objectURL.path) == 0 else {',
      '  throw TestError()',
      '}',
    ].join('\n');
    writeFileSync(cas, duplicate, 'utf8');

    const result = runGate(root);

    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'ImmutableArchiveCAS object unlink must occur exactly once',
    );
  });

  it.each([
    {
      path: 'macos/EngramService/Core/ArchiveSourceReclaimer.swift',
      content: [
        'guard Darwin.unlink(quarantineURL.path) == 0 else {',
        '  throw TestError()',
        '}',
      ].join('\n'),
    },
    {
      path: 'macos/EngramService/Core/ArchiveStore.swift',
      content: '_ = Darwin.unlink(temporaryURL.path)\n',
    },
    {
      path: 'macos/EngramRemoteServer/Core/ArchiveTranscriptResolver.swift',
      content: 'try FileManager.default.removeItem(at: replay.directoryURL)\n',
    },
  ])('rejects a basename allowlist collision at $path', ({ path, content }) => {
    const root = makeSafeFixture();
    write(root, path, content);

    const result = runGate(root);

    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'forbidden archive deletion primitive',
    );
  });

  it.each([
    {
      path: 'macos/EngramCoreWrite/ArchiveV2/ArchiveSourceReclaimer.swift',
      content:
        'guard Darwin.unlink(sourceURL.path) == 0 else { throw TestError() }\n',
    },
    {
      path: 'macos/EngramCoreWrite/ArchiveV2/OtherReclaimer.swift',
      content:
        'guard Darwin.unlink(quarantineURL.path) == 0 else { throw TestError() }\n',
    },
    {
      path: 'macos/EngramCoreWrite/ArchiveV2/ImmutableArchiveCAS.swift',
      content:
        'guard Darwin.unlink(sourceURL.path) == 0 else { throw TestError() }\n',
    },
    {
      path: 'macos/EngramCoreWrite/ArchiveV2/OtherCAS.swift',
      content:
        'guard Darwin.unlink(objectURL.path) == 0 else { throw TestError() }\n',
    },
  ])('rejects a non-allowlisted unlink at $path', ({ path, content }) => {
    const root = makeSafeFixture();
    write(root, path, content);

    const result = runGate(root);

    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'forbidden archive deletion primitive',
    );
  });

  it('rejects a source-file removal path', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramService/Core/ArchiveSourceCleanup.swift',
      'try FileManager.default.removeItem(at: sourceURL)\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'forbidden archive deletion primitive',
    );
  });

  it.each([
    {
      name: 'multiline Darwin unlink',
      content: ['Darwin', '  . unlink (', '    sourceURL.path', '  )'].join(
        '\n',
      ),
      primitive: 'Darwin.unlink',
    },
    {
      name: 'multiline unknown receiver removeItem',
      content: [
        'unknownReceiver',
        '  . removeItem (',
        '    at: sourceURL',
        '  )',
      ].join('\n'),
      primitive: 'receiver.removeItem',
    },
    {
      name: 'multiline unlinkat',
      content: ['unlinkat', '  (directoryFD, sourceName, 0)'].join('\n'),
      primitive: 'unlinkat',
    },
  ])('rejects $name without echoing source content', ({
    content,
    primitive,
  }) => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramService/Core/ArchiveSourceCleanup.swift',
      `${content}\n`,
    );

    const result = runGate(root);
    const output = `${result.stdout}${result.stderr}`;

    expect(result.status).not.toBe(0);
    expect(output).toContain(`ArchiveSourceCleanup.swift:`);
    expect(output).toContain(primitive);
    expect(output).not.toContain('sourceURL');
    expect(output).not.toContain('unknownReceiver');
    expect(output).not.toContain('directoryFD');
  });

  it('rejects delete capability on ArchiveReplicaBackend', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramCoreWrite/ArchiveV2/ArchiveReplicaBackend.swift',
      'public protocol ArchiveReplicaBackend { func delete(key: String) async throws }\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'ArchiveReplicaBackend exposes a delete-like capability',
    );
  });

  it('rejects legacy offload commit, purge, or vacuum coupling', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramService/Core/ArchiveLegacyBridge.swift',
      'try OffloadRepo.commitOffloaded(db, sessionID: id)\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'legacy offload coupling',
    );
  });

  it('rejects any v2 DELETE handler in the full remote-server surface', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramRemoteServer/Core/DangerousRoutes.swift',
      'router.delete("/v2/archive/object") { _, _ in ok() }\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'unexpected v2 DELETE handler',
    );
  });

  it('rejects a multiline router.delete registration in a renamed file', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramRemoteServer/Core/Housekeeping.swift',
      [
        'router',
        '  .delete(',
        '    "/v2/archive/object"',
        '  ) { _, _ in ok() }',
      ].join('\n'),
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'unexpected v2 DELETE handler',
    );
  });

  it('rejects common method-based DELETE registration outside router.delete', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramRemoteServer/Core/MaintenanceRoutes.swift',
      'router.on("/v2/archive/object", method: .delete) { _, _ in ok() }\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'unexpected remote-server DELETE registration',
    );
  });

  it('rejects a fully qualified Hummingbird DELETE method registration', () => {
    const root = makeSafeFixture();
    write(
      root,
      'macos/EngramRemoteServer/Core/Diagnostics.swift',
      'router.on("/v2/archive/object", method: HTTPRequest.Method.delete) { _, _ in ok() }\n',
    );
    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'unexpected remote-server DELETE registration',
    );
  });

  it('rejects a successful branch hidden inside an allowed DELETE guard', () => {
    const root = makeSafeFixture();
    const routes = join(
      root,
      'macos/EngramRemoteServer/Core/ArchiveRoutes.swift',
    );
    const unsafe = readFileSync(routes, 'utf8').replace(
      'return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")',
      [
        'if allowDelete { return ok() }',
        '    return errorResponse(status: .methodNotAllowed, code: "method_not_allowed")',
      ].join('\n'),
    );
    writeFileSync(routes, unsafe, 'utf8');

    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'v2 DELETE guards must contain only auth rejection and 405',
    );
  });

  it('rejects an extra operation inside an allowed DELETE guard', () => {
    const root = makeSafeFixture();
    const routes = join(
      root,
      'macos/EngramRemoteServer/Core/ArchiveRoutes.swift',
    );
    const unsafe = readFileSync(routes, 'utf8').replace(
      'guard authorized(request, token: token) else { return unauthorized() }',
      [
        'await performDeleteSideEffect()',
        '      guard authorized(request, token: token) else { return unauthorized() }',
      ].join('\n'),
    );
    writeFileSync(routes, unsafe, 'utf8');

    const result = runGate(root);
    expect(result.status).not.toBe(0);
    expect(`${result.stdout}${result.stderr}`).toContain(
      'v2 DELETE guards must contain only auth rejection and 405',
    );
  });
});

describe('archive v2 documentation contract', () => {
  it('records the accepted topology, safety boundary, and operational limits', () => {
    const runbookPath = resolve(repoRoot, 'docs/remote-archive-v2.md');
    expect(existsSync(runbookPath)).toBe(true);
    const runbook = readFileSync(runbookPath, 'utf8');
    for (const requiredText of [
      'macmini-hq',
      'macmini-m1',
      'Tailscale-only',
      'default OFF',
      'operator-enabled',
      'local source reclamation',
      'remote deletion and GC remain forbidden',
      'online compromise',
      'Claude Code',
      'Codex',
      'O(N)',
      'durable locator inventory',
      'FSEvents',
      'archiveV2Status',
      'archiveV2Retry',
      'EngramCLI archive status --json',
    ]) {
      expect(runbook).toContain(requiredText);
    }
    expect(runbook).not.toContain(
      'Production deployment is not part of this branch',
    );
  });

  it('keeps the README backlog summary and v1/v2 routing current', () => {
    const readme = readFileSync(resolve(repoRoot, 'README.md'), 'utf8');
    expect(readme).toContain('operator-enabled');
    expect(readme).toContain('3 conditional archive-v2 boundaries');
    expect(readme).toContain('docs/remote-archive-v2.md');
    expect(readme).not.toContain('one active, not-deployed delivery');
  });

  it('documents the real opt-in embedding network boundary', () => {
    const privacy = readFileSync(resolve(repoRoot, 'docs/PRIVACY.md'), 'utf8');
    const readme = readFileSync(resolve(repoRoot, 'README.md'), 'utf8');
    const normalizedPrivacy = privacy.replace(/\s+/g, ' ');

    for (const requiredText of [
      'configured embedding provider',
      '/embeddings',
      'session chunks',
      'insight content',
      'semantic/hybrid query text',
      'aiApiKey',
      'No embedding content or query text is sent when no usable embedding provider is configured',
    ]) {
      expect(normalizedPrivacy).toContain(requiredText);
    }
    expect(privacy).not.toContain(
      'the current Swift product path does not generate embeddings',
    );
    expect(readme).toContain('session chunks and insight content');
    expect(readme).toContain('semantic/hybrid query text');
    expect(readme).toContain('/embeddings');
  });

  it('documents active semantic storage and recoverable plaintext-key migration', () => {
    const privacy = readFileSync(resolve(repoRoot, 'docs/PRIVACY.md'), 'utf8');
    const readme = readFileSync(resolve(repoRoot, 'README.md'), 'utf8');
    const privacyStorage = privacy
      .split('## What Engram Stores')[1]
      ?.split('## Network Activity')[0]
      ?.replace(/`/g, '')
      .replace(/\s+/g, ' ');
    const readmeStorage = readme
      .split('## 数据存储与隐私')[1]
      ?.split('### Restoring user data')[0]
      ?.replace(/`/g, '')
      .replace(/\s+/g, ' ');

    expect(privacyStorage).toBeDefined();
    expect(readmeStorage).toBeDefined();
    for (const requiredText of [
      'semantic_chunks',
      'embedding_meta',
      'insight_embeddings',
      'actively written and queried',
      'App UI remains keyword-only',
      'New secrets use macOS Keychain with @keychain markers',
      'legacy plaintext embeddingApiKey or aiApiKey may remain in settings.json',
      'Keychain set, read-back verification, and settings rewrite all succeed',
      'Migration failure preserves recoverable plaintext',
      'Inspect settings.json and complete the migration without printing secret values',
    ]) {
      expect(privacyStorage).toContain(requiredText);
    }
    expect(privacyStorage).not.toContain(
      'compatibility fields/tables for future vector search',
    );
    expect(privacyStorage).not.toContain('non-sensitive configuration only');
    expect(privacyStorage).not.toContain('not in plaintext files');

    for (const requiredText of [
      'semantic_chunks',
      'embedding_meta',
      'insight_embeddings',
      '当前写入和查询',
      'App UI 仍故意保持 keyword-only',
      '旧的明文 embeddingApiKey 或 aiApiKey',
      '迁移失败时保留可恢复明文',
    ]) {
      expect(readmeStorage).toContain(requiredText);
    }
    expect(readmeStorage).not.toContain('兼容保留的 embedding 表');
  });

  it('documents independent per-site secrets and preserves deployment authorization', () => {
    const runbook = readFileSync(
      resolve(repoRoot, 'docs/remote-archive-v2.md'),
      'utf8',
    );
    const normalizedRunbook = runbook.replace(/\s+/g, ' ');
    for (const requiredText of [
      'Generate secrets independently on each server',
      'umask 077',
      'openssl rand -base64 32',
      'chmod 0600',
      'chmod 0700',
      'LaunchAgent plist contains no secrets',
      'Keychain Access',
      'replica:hq',
      'replica:m1',
      'shell history',
      'Actual paths, Keychain writes, and launchctl operations require separate deployment authorization',
    ]) {
      expect(normalizedRunbook).toContain(requiredText);
    }
  });
});

describe('archive v2 CI contract', () => {
  it('runs the safety gate and remote-server scheme in normal and release CI', () => {
    const normalCI = readFileSync(
      resolve(repoRoot, '.github/workflows/test.yml'),
      'utf8',
    );
    const releaseCI = readFileSync(
      resolve(repoRoot, '.github/workflows/release.yml'),
      'utf8',
    );

    expect(normalCI).toContain('bash scripts/check-archive-v2-safety.sh');
    expect(normalCI).toContain('-scheme EngramRemoteServerCore');
    expect(releaseCI).toContain('-scheme EngramRemoteServerCore');
    expect(normalCI).toContain(
      'release-verify.sh "$ENGRAM_APP" --hygiene-only',
    );
    expect(releaseCI).toContain('./scripts/release-verify.sh');
  });
});
